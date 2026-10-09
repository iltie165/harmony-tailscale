// Package main exposes a deliberately small C ABI for the HarmonyOS bridge.
package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"runtime/debug"
	"sort"
	"strings"
	"sync"
	"time"
	"unsafe"

	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/net/netmon"
	"tailscale.com/net/netns"
	"tailscale.com/tsnet"
	"tailscale.com/types/logger"
	"tailscale.com/util/eventbus"
	"tailscale.com/version"
)

const (
	abiVersion  = 3
	maxLogLines = 512
)

func init() {
	// OpenHarmony selects Tailscale's Linux compatibility files. The Linux
	// netns dialer falls back to SO_BINDTODEVICE("lo") when route discovery is
	// unavailable, which traps control and log traffic on HarmonyOS. tsnet uses
	// userspace networking, so match tailscaled --tun=userspace-networking and
	// leave outbound sockets on the platform's normal network path.
	netns.SetEnabled(false)
}

type operationResult struct {
	OK        bool   `json:"ok"`
	Operation string `json:"operation"`
	State     string `json:"state"`
	Error     string `json:"error,omitempty"`
	DataDir   string `json:"dataDir,omitempty"`
	Hostname  string `json:"hostname,omitempty"`
	Message   string `json:"message,omitempty"`
}

type interfaceInfo struct {
	Name      string   `json:"name"`
	Index     int      `json:"index"`
	MTU       int      `json:"mtu"`
	Flags     string   `json:"flags"`
	Addresses []string `json:"addresses"`
}

type checkResult struct {
	OK     bool   `json:"ok"`
	Detail string `json:"detail,omitempty"`
	Error  string `json:"error,omitempty"`
}

type diagnosticsResult struct {
	OK             bool            `json:"ok"`
	Operation      string          `json:"operation"`
	GOOS           string          `json:"goos"`
	GOARCH         string          `json:"goarch"`
	Storage        checkResult     `json:"storage"`
	TCP            checkResult     `json:"tcpSocket"`
	UDP            checkResult     `json:"udpSocket"`
	DNS            checkResult     `json:"dns"`
	ControlPlane   checkResult     `json:"controlPlane"`
	DefaultRoute   checkResult     `json:"defaultRoute"`
	NetworkMonitor checkResult     `json:"networkMonitor"`
	Interfaces     []interfaceInfo `json:"interfaces"`
	Error          string          `json:"error,omitempty"`
}

type peerInfo struct {
	ID           string   `json:"id"`
	HostName     string   `json:"hostName,omitempty"`
	DNSName      string   `json:"dnsName,omitempty"`
	OS           string   `json:"os,omitempty"`
	UserID       string   `json:"userId,omitempty"`
	UserLogin    string   `json:"userLogin,omitempty"`
	UserName     string   `json:"userName,omitempty"`
	Online       bool     `json:"online"`
	Active       bool     `json:"active"`
	TailscaleIPs []string `json:"tailscaleIPs,omitempty"`
	Tags         []string `json:"tags,omitempty"`
	Relay        string   `json:"relay,omitempty"`
	LastSeen     string   `json:"lastSeen,omitempty"`
}

type tailnetInfo struct {
	Name            string `json:"name,omitempty"`
	MagicDNSSuffix  string `json:"magicDNSSuffix,omitempty"`
	MagicDNSEnabled bool   `json:"magicDNSEnabled"`
}

type controlStatusResult struct {
	OK             bool         `json:"ok"`
	Operation      string       `json:"operation"`
	LifecycleState string       `json:"lifecycleState"`
	BackendState   string       `json:"backendState,omitempty"`
	AuthURL        string       `json:"authUrl,omitempty"`
	LoggedIn       bool         `json:"loggedIn"`
	TailscaleIPs   []string     `json:"tailscaleIPs,omitempty"`
	Self           *peerInfo    `json:"self,omitempty"`
	Tailnet        *tailnetInfo `json:"tailnet,omitempty"`
	Health         []string     `json:"health,omitempty"`
	DebugLogs      []string     `json:"debugLogs,omitempty"`
	Error          string       `json:"error,omitempty"`
}

type onlinePeersResult struct {
	OK         bool       `json:"ok"`
	Operation  string     `json:"operation"`
	Filter     string     `json:"filter,omitempty"`
	FilterKind string     `json:"filterKind"`
	Count      int        `json:"count"`
	Peers      []peerInfo `json:"peers"`
	Error      string     `json:"error,omitempty"`
}

var lifecycle = struct {
	sync.RWMutex
	server    *tsnet.Server
	state     string
	dataDir   string
	hostname  string
	lastError string
}{state: "idle"}

// tsnet documents that Close must not run before or concurrently with Start.
var operationMu sync.Mutex

var logs = struct {
	sync.Mutex
	lines []string
}{}

func appendLog(format string, args ...any) {
	line := sanitizeLogLine(strings.TrimSpace(fmt.Sprintf(format, args...)))
	if line == "" {
		return
	}
	line = time.Now().UTC().Format(time.RFC3339Nano) + " " + line
	logs.Lock()
	defer logs.Unlock()
	logs.lines = append(logs.lines, line)
	if len(logs.lines) > maxLogLines {
		copy(logs.lines, logs.lines[len(logs.lines)-maxLogLines:])
		logs.lines = logs.lines[:maxLogLines]
	}
}

func sanitizeLogLine(line string) string {
	return strings.ReplaceAll(line, "\x00", "\\x00")
}

func recentLogLines(limit int) []string {
	logs.Lock()
	defer logs.Unlock()
	if limit <= 0 || len(logs.lines) == 0 {
		return nil
	}
	start := len(logs.lines) - limit
	if start < 0 {
		start = 0
	}
	result := make([]string, len(logs.lines)-start)
	copy(result, logs.lines[start:])
	return result
}

func bridgeLogf(format string, args ...any) {
	appendLog("%s", redactLoginURLs(fmt.Sprintf(format, args...)))
}

func redactLoginURLs(value string) string {
	const loginURL = "https://login.tailscale.com/"
	for {
		start := strings.Index(value, loginURL)
		if start < 0 {
			return value
		}
		end := start
		for end < len(value) && value[end] != ' ' && value[end] != '\n' && value[end] != '\r' && value[end] != '\t' {
			end++
		}
		value = value[:start] + "[REDACTED_TAILSCALE_LOGIN_URL]" + value[end:]
	}
}

func cJSON(value any) *C.char {
	data, err := json.Marshal(value)
	if err != nil {
		data = []byte(fmt.Sprintf(`{"ok":false,"error":%q}`, err.Error()))
	}
	return C.CString(string(data))
}

func panicResult(operation string, output **C.char) {
	if recovered := recover(); recovered != nil {
		message := fmt.Sprintf("panic: %v", recovered)
		stack := string(debug.Stack())
		appendLog("%s\n%s", message, stack)
		if operation == "start" || operation == "close" {
			lifecycle.Lock()
			lifecycle.state = "panic"
			lifecycle.lastError = message
			lifecycle.Unlock()
		}
		*output = cJSON(operationResult{
			OK:        false,
			Operation: operation,
			State:     "panic",
			Error:     message,
			Message:   stack,
		})
	}
}

func stateResult(operation string) operationResult {
	lifecycle.RLock()
	defer lifecycle.RUnlock()
	return operationResult{
		OK:        lifecycle.state == "started" || lifecycle.state == "closed" || lifecycle.state == "idle",
		Operation: operation,
		State:     lifecycle.state,
		Error:     lifecycle.lastError,
		DataDir:   lifecycle.dataDir,
		Hostname:  lifecycle.hostname,
	}
}

func currentServer() (*tsnet.Server, string, error) {
	lifecycle.RLock()
	defer lifecycle.RUnlock()
	if lifecycle.server == nil || lifecycle.state == "idle" || lifecycle.state == "closed" {
		return nil, lifecycle.state, fmt.Errorf("tsnet server is not initialized")
	}
	return lifecycle.server, lifecycle.state, nil
}

func peerFromStatus(status *ipnstate.Status, peer *ipnstate.PeerStatus) peerInfo {
	result := peerInfo{
		ID:       string(peer.ID),
		HostName: peer.HostName,
		DNSName:  strings.TrimSuffix(peer.DNSName, "."),
		OS:       peer.OS,
		UserID:   peer.UserID.String(),
		Online:   peer.Online,
		Active:   peer.Active,
		Relay:    peer.Relay,
	}
	for _, address := range peer.TailscaleIPs {
		result.TailscaleIPs = append(result.TailscaleIPs, address.String())
	}
	if peer.Tags != nil {
		result.Tags = append(result.Tags, peer.Tags.AsSlice()...)
		sort.Strings(result.Tags)
	}
	if !peer.LastSeen.IsZero() {
		result.LastSeen = peer.LastSeen.UTC().Format(time.RFC3339)
	}
	if user, ok := status.User[peer.UserID]; ok {
		result.UserLogin = user.LoginName
		result.UserName = user.DisplayName
	}
	return result
}

func controlStatus(operation, lifecycleState string, status *ipnstate.Status, err error) controlStatusResult {
	result := controlStatusResult{Operation: operation, LifecycleState: lifecycleState}
	if err != nil {
		result.Error = err.Error()
		return result
	}
	result.OK = true
	result.BackendState = status.BackendState
	result.AuthURL = status.AuthURL
	result.LoggedIn = status.BackendState == "Running"
	result.Health = append(result.Health, status.Health...)
	for _, address := range status.TailscaleIPs {
		result.TailscaleIPs = append(result.TailscaleIPs, address.String())
	}
	if status.Self != nil {
		self := peerFromStatus(status, status.Self)
		result.Self = &self
	}
	if status.CurrentTailnet != nil {
		result.Tailnet = &tailnetInfo{
			Name:            status.CurrentTailnet.Name,
			MagicDNSSuffix:  status.CurrentTailnet.MagicDNSSuffix,
			MagicDNSEnabled: status.CurrentTailnet.MagicDNSEnabled,
		}
	}
	return result
}

func filterKind(filter string) string {
	switch {
	case filter == "":
		return "all"
	case strings.HasPrefix(strings.ToLower(filter), "tag:"):
		return "tag"
	case strings.HasPrefix(strings.ToLower(filter), "user:"):
		return "user"
	case strings.HasPrefix(strings.ToLower(filter), "group:"):
		return "acl-group"
	default:
		return "text"
	}
}

func peerMatchesFilter(peer peerInfo, filter string) bool {
	filter = strings.TrimSpace(filter)
	if filter == "" {
		return true
	}
	lower := strings.ToLower(filter)
	switch {
	case strings.HasPrefix(lower, "tag:"):
		for _, tag := range peer.Tags {
			if strings.EqualFold(tag, filter) {
				return true
			}
		}
		return false
	case strings.HasPrefix(lower, "user:"):
		value := strings.TrimSpace(filter[len("user:"):])
		return strings.EqualFold(peer.UserLogin, value) || strings.EqualFold(peer.UserName, value)
	default:
		return strings.Contains(strings.ToLower(peer.HostName), lower) ||
			strings.Contains(strings.ToLower(peer.DNSName), lower) ||
			strings.Contains(strings.ToLower(peer.UserLogin), lower)
	}
}

func validateStartInput(dataDir, hostname string) error {
	if dataDir == "" {
		return fmt.Errorf("data directory is empty")
	}
	if !filepath.IsAbs(dataDir) {
		return fmt.Errorf("data directory must be absolute: %q", dataDir)
	}
	if hostname == "" || len(hostname) > 63 {
		return fmt.Errorf("hostname length must be between 1 and 63 bytes")
	}
	for _, r := range hostname {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' {
			continue
		}
		return fmt.Errorf("hostname contains unsupported character %q", r)
	}
	if hostname[0] == '-' || hostname[len(hostname)-1] == '-' {
		return fmt.Errorf("hostname cannot start or end with '-'")
	}
	return nil
}

//export tailscale_ohos_abi_version
func tailscale_ohos_abi_version() C.uint32_t {
	return C.uint32_t(abiVersion)
}

//export tailscale_ohos_version
func tailscale_ohos_version() *C.char {
	return C.CString(version.Short())
}

//export tailscale_ohos_go_version
func tailscale_ohos_go_version() *C.char {
	return C.CString(runtime.Version())
}

//export tailscale_ohos_core_probe
func tailscale_ohos_core_probe() C.int {
	pc := reflect.ValueOf((*tsnet.Server).Start).Pointer()
	fn := runtime.FuncForPC(pc)
	if fn != nil && strings.Contains(fn.Name(), "tailscale.com/tsnet.(*Server).Start") {
		return 1
	}
	return 0
}

//export tailscale_ohos_start
func tailscale_ohos_start(cDataDir, cHostname *C.char) (output *C.char) {
	defer panicResult("start", &output)
	operationMu.Lock()
	defer operationMu.Unlock()

	dataDir := filepath.Clean(C.GoString(cDataDir))
	hostname := C.GoString(cHostname)
	if err := validateStartInput(dataDir, hostname); err != nil {
		appendLog("start validation failed: %v", err)
		return cJSON(operationResult{OK: false, Operation: "start", State: "error", Error: err.Error()})
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		appendLog("create state directory %q: %v", dataDir, err)
		return cJSON(operationResult{OK: false, Operation: "start", State: "error", Error: err.Error(), DataDir: dataDir, Hostname: hostname})
	}

	lifecycle.Lock()
	if lifecycle.server != nil && lifecycle.state != "closed" {
		result := operationResult{OK: lifecycle.state == "started", Operation: "start", State: lifecycle.state, Error: lifecycle.lastError, DataDir: lifecycle.dataDir, Hostname: lifecycle.hostname, Message: "server already initialized; close it before retrying"}
		lifecycle.Unlock()
		return cJSON(result)
	}
	server := &tsnet.Server{
		Dir:      dataDir,
		Hostname: hostname,
		Logf:     logger.Logf(bridgeLogf),
		UserLogf: logger.Logf(bridgeLogf),
	}
	lifecycle.server = server
	lifecycle.state = "starting"
	lifecycle.dataDir = dataDir
	lifecycle.hostname = hostname
	lifecycle.lastError = ""
	lifecycle.Unlock()

	appendLog("platform adapter: Tailscale netns disabled for userspace networking")
	appendLog("tsnet.Start begin dir=%q hostname=%q", dataDir, hostname)
	err := server.Start()
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if err != nil {
		lifecycle.state = "error"
		lifecycle.lastError = err.Error()
		appendLog("tsnet.Start failed: %v", err)
		return cJSON(operationResult{OK: false, Operation: "start", State: lifecycle.state, Error: err.Error(), DataDir: dataDir, Hostname: hostname})
	}
	lifecycle.state = "started"
	appendLog("tsnet.Start returned successfully")
	return cJSON(operationResult{OK: true, Operation: "start", State: lifecycle.state, DataDir: dataDir, Hostname: hostname, Message: "tsnet.Server.Start returned nil"})
}

func fetchControlStatus(operation string) controlStatusResult {
	server, state, err := currentServer()
	if err != nil {
		return controlStatus(operation, state, nil, err)
	}
	client, err := server.LocalClient()
	if err != nil {
		return controlStatus(operation, state, nil, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	status, err := client.Status(ctx)
	return controlStatus(operation, state, status, err)
}

//export tailscale_ohos_status
func tailscale_ohos_status() (output *C.char) {
	defer panicResult("status", &output)
	operationMu.Lock()
	defer operationMu.Unlock()
	return cJSON(fetchControlStatus("status"))
}

//export tailscale_ohos_login
func tailscale_ohos_login() (output *C.char) {
	defer panicResult("login", &output)
	operationMu.Lock()
	defer operationMu.Unlock()

	server, state, err := currentServer()
	if err != nil {
		return cJSON(controlStatus("login", state, nil, err))
	}
	client, err := server.LocalClient()
	if err != nil {
		return cJSON(controlStatus("login", state, nil, err))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil {
		return cJSON(controlStatus("login", state, nil, err))
	}
	if status.BackendState == "Running" || status.AuthURL != "" {
		return cJSON(controlStatus("login", state, status, nil))
	}
	watcher, err := client.WatchIPNBus(ctx, ipn.NotifyInitialState|ipn.NotifyNoPrivateKeys)
	if err != nil {
		appendLog("interactive login watcher failed: %v", err)
		return cJSON(controlStatus("login", state, status, fmt.Errorf("watch login events: %w", err)))
	}
	defer watcher.Close()

	snapshot := func(authURL string, operationErr error) controlStatusResult {
		statusCtx, statusCancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer statusCancel()
		latest, statusErr := client.Status(statusCtx)
		if statusErr != nil {
			result := controlStatus("login", state, status, nil)
			result.OK = false
			result.Error = statusErr.Error()
			if operationErr != nil {
				result.Error = operationErr.Error() + "; status: " + statusErr.Error()
			}
			if authURL != "" {
				result.AuthURL = authURL
			}
			result.DebugLogs = recentLogLines(24)
			return result
		}
		result := controlStatus("login", state, latest, nil)
		if authURL != "" {
			result.AuthURL = authURL
		}
		if operationErr != nil {
			result.OK = false
			result.Error = operationErr.Error()
			result.DebugLogs = recentLogLines(24)
		}
		return result
	}

	appendLog("interactive login requested")
	if err := client.StartLoginInteractive(ctx); err != nil {
		appendLog("interactive login request failed: %v", err)
		return cJSON(snapshot("", err))
	}
	for {
		notify, err := watcher.Next()
		if err != nil {
			if ctx.Err() != nil {
				err = fmt.Errorf("timed out waiting for Tailscale login URL: %w", ctx.Err())
			} else {
				err = fmt.Errorf("watch login events: %w", err)
			}
			appendLog("interactive login failed: %v", err)
			return cJSON(snapshot("", err))
		}
		if notify.ErrMessage != nil && *notify.ErrMessage != "" {
			err := fmt.Errorf("Tailscale backend: %s", *notify.ErrMessage)
			appendLog("interactive login backend error: %v", err)
			return cJSON(snapshot("", err))
		}
		if notify.BrowseToURL != nil && *notify.BrowseToURL != "" {
			appendLog("interactive login URL received from IPN bus")
			return cJSON(snapshot(*notify.BrowseToURL, nil))
		}
		if notify.State != nil {
			appendLog("interactive login state notification=%q", *notify.State)
			if *notify.State == ipn.Running {
				return cJSON(snapshot("", nil))
			}
		}
	}
}

//export tailscale_ohos_logout
func tailscale_ohos_logout() (output *C.char) {
	defer panicResult("logout", &output)
	operationMu.Lock()
	defer operationMu.Unlock()

	server, state, err := currentServer()
	if err != nil {
		return cJSON(controlStatus("logout", state, nil, err))
	}
	client, err := server.LocalClient()
	if err != nil {
		return cJSON(controlStatus("logout", state, nil, err))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := client.Logout(ctx); err != nil {
		appendLog("logout failed: %v", err)
		return cJSON(controlStatus("logout", state, nil, err))
	}
	status, err := client.Status(ctx)
	appendLog("logout completed")
	return cJSON(controlStatus("logout", state, status, err))
}

//export tailscale_ohos_online_peers
func tailscale_ohos_online_peers(cFilter *C.char) (output *C.char) {
	defer panicResult("onlinePeers", &output)
	operationMu.Lock()
	defer operationMu.Unlock()

	filter := strings.TrimSpace(C.GoString(cFilter))
	result := onlinePeersResult{
		Operation:  "onlinePeers",
		Filter:     filter,
		FilterKind: filterKind(filter),
		Peers:      []peerInfo{},
	}
	if result.FilterKind == "acl-group" {
		result.Error = "ACL group membership is not exposed by the node LocalAPI; use a management backend with Tailscale OAuth"
		return cJSON(result)
	}
	server, _, err := currentServer()
	if err != nil {
		result.Error = err.Error()
		return cJSON(result)
	}
	client, err := server.LocalClient()
	if err != nil {
		result.Error = err.Error()
		return cJSON(result)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil {
		result.Error = err.Error()
		return cJSON(result)
	}
	if status.BackendState != "Running" {
		result.Error = fmt.Sprintf("Tailscale backend is %q; login must complete before peers are available", status.BackendState)
		return cJSON(result)
	}
	for _, key := range status.Peers() {
		peer := status.Peer[key]
		if peer == nil || !peer.Online {
			continue
		}
		item := peerFromStatus(status, peer)
		if peerMatchesFilter(item, filter) {
			result.Peers = append(result.Peers, item)
		}
	}
	sort.Slice(result.Peers, func(i, j int) bool {
		left := result.Peers[i].DNSName
		right := result.Peers[j].DNSName
		if left == "" {
			left = result.Peers[i].HostName
		}
		if right == "" {
			right = result.Peers[j].HostName
		}
		return strings.ToLower(left) < strings.ToLower(right)
	})
	result.OK = true
	result.Count = len(result.Peers)
	appendLog("online peers query filter=%q kind=%s count=%d", filter, result.FilterKind, result.Count)
	return cJSON(result)
}

//export tailscale_ohos_close
func tailscale_ohos_close() (output *C.char) {
	defer panicResult("close", &output)
	operationMu.Lock()
	defer operationMu.Unlock()

	lifecycle.RLock()
	server := lifecycle.server
	state := lifecycle.state
	lifecycle.RUnlock()
	if server == nil || state == "idle" || state == "closed" {
		return cJSON(operationResult{OK: true, Operation: "close", State: state, Message: "server is not running"})
	}
	appendLog("tsnet.Close begin")
	err := server.Close()
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if err != nil {
		lifecycle.state = "error"
		lifecycle.lastError = err.Error()
		appendLog("tsnet.Close failed: %v", err)
		return cJSON(operationResult{OK: false, Operation: "close", State: lifecycle.state, Error: err.Error(), DataDir: lifecycle.dataDir, Hostname: lifecycle.hostname})
	}
	lifecycle.server = nil
	lifecycle.state = "closed"
	lifecycle.lastError = ""
	appendLog("tsnet.Close returned successfully")
	return cJSON(operationResult{OK: true, Operation: "close", State: lifecycle.state, DataDir: lifecycle.dataDir, Hostname: lifecycle.hostname})
}

func probeStorage(dataDir string) checkResult {
	if dataDir == "" || !filepath.IsAbs(dataDir) {
		return checkResult{Error: "data directory must be a non-empty absolute path"}
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return checkResult{Error: err.Error()}
	}
	file, err := os.CreateTemp(dataDir, "tailscale-ohos-probe-*")
	if err != nil {
		return checkResult{Error: err.Error()}
	}
	name := file.Name()
	if _, err = file.WriteString("ok"); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	removeErr := os.Remove(name)
	if err == nil {
		err = closeErr
	}
	if err == nil {
		err = removeErr
	}
	if err != nil {
		return checkResult{Error: err.Error()}
	}
	return checkResult{OK: true, Detail: dataDir}
}

func probeInterfaces() ([]interfaceInfo, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	result := make([]interfaceInfo, 0, len(interfaces))
	for _, iface := range interfaces {
		addresses, addressErr := iface.Addrs()
		if addressErr != nil {
			appendLog("interface %q address enumeration failed: %v", iface.Name, addressErr)
		}
		item := interfaceInfo{Name: iface.Name, Index: iface.Index, MTU: iface.MTU, Flags: iface.Flags.String()}
		for _, address := range addresses {
			item.Addresses = append(item.Addresses, address.String())
		}
		result = append(result, item)
	}
	return result, nil
}

func probeTCP() checkResult {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return checkResult{Error: err.Error()}
	}
	detail := listener.Addr().String()
	if err := listener.Close(); err != nil {
		return checkResult{Error: err.Error()}
	}
	return checkResult{OK: true, Detail: detail}
}

func probeUDP() checkResult {
	packet, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		return checkResult{Error: err.Error()}
	}
	detail := packet.LocalAddr().String()
	if err := packet.Close(); err != nil {
		return checkResult{Error: err.Error()}
	}
	return checkResult{OK: true, Detail: detail}
}

func probeDNS() checkResult {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	addresses, err := net.DefaultResolver.LookupHost(ctx, "login.tailscale.com")
	if err != nil {
		return checkResult{Error: err.Error()}
	}
	return checkResult{OK: true, Detail: strings.Join(addresses, ",")}
}

func probeControlPlane() checkResult {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://controlplane.tailscale.com/", nil)
	if err != nil {
		return checkResult{Error: err.Error()}
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return checkResult{Error: err.Error()}
	}
	defer response.Body.Close()
	return checkResult{OK: true, Detail: response.Status}
}

func probeDefaultRoute() checkResult {
	route, err := netmon.DefaultRoute()
	if err != nil {
		return checkResult{Error: err.Error()}
	}
	return checkResult{OK: true, Detail: fmt.Sprintf("interface=%s index=%d", route.InterfaceName, route.InterfaceIndex)}
}

func probeNetworkMonitor() checkResult {
	bus := eventbus.New()
	defer bus.Close()
	monitor, err := netmon.New(bus, logger.Logf(bridgeLogf))
	if err != nil {
		return checkResult{Error: err.Error()}
	}
	monitor.Start()
	detail := fmt.Sprint(monitor.InterfaceState())
	if err := monitor.Close(); err != nil {
		return checkResult{Error: err.Error()}
	}
	return checkResult{OK: true, Detail: detail}
}

//export tailscale_ohos_diagnostics
func tailscale_ohos_diagnostics(cDataDir *C.char) (output *C.char) {
	defer panicResult("diagnostics", &output)
	dataDir := filepath.Clean(C.GoString(cDataDir))
	appendLog("platform diagnostics begin dir=%q", dataDir)
	result := diagnosticsResult{Operation: "diagnostics", GOOS: runtime.GOOS, GOARCH: runtime.GOARCH}
	result.Storage = probeStorage(dataDir)
	result.TCP = probeTCP()
	result.UDP = probeUDP()
	result.DNS = probeDNS()
	result.ControlPlane = probeControlPlane()
	result.DefaultRoute = probeDefaultRoute()
	result.NetworkMonitor = probeNetworkMonitor()
	interfaces, err := probeInterfaces()
	if err != nil {
		result.Error = err.Error()
	} else {
		result.Interfaces = interfaces
	}
	result.OK = result.Storage.OK && result.TCP.OK && result.UDP.OK && result.DNS.OK && result.ControlPlane.OK && result.NetworkMonitor.OK && err == nil
	appendLog("platform diagnostics finished ok=%v dns=%v control=%v route=%v interfaces=%d", result.OK, result.DNS.OK, result.ControlPlane.OK, result.DefaultRoute.OK, len(result.Interfaces))
	return cJSON(result)
}

//export tailscale_ohos_logs
func tailscale_ohos_logs() (output *C.char) {
	defer panicResult("logs", &output)
	logs.Lock()
	defer logs.Unlock()
	return C.CString(strings.Join(logs.lines, "\n"))
}

//export tailscale_ohos_string_free
func tailscale_ohos_string_free(value unsafe.Pointer) {
	C.free(value)
}

func main() {}
