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
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"time"
	"unsafe"

	"tailscale.com/net/netmon"
	"tailscale.com/tsnet"
	"tailscale.com/types/logger"
	"tailscale.com/util/eventbus"
	"tailscale.com/version"
)

const (
	abiVersion  = 2
	maxLogLines = 512
)

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
	DefaultRoute   checkResult     `json:"defaultRoute"`
	NetworkMonitor checkResult     `json:"networkMonitor"`
	Interfaces     []interfaceInfo `json:"interfaces"`
	Error          string          `json:"error,omitempty"`
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
	line := strings.TrimSpace(fmt.Sprintf(format, args...))
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

func bridgeLogf(format string, args ...any) {
	appendLog(format, args...)
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

//export tailscale_ohos_status
func tailscale_ohos_status() (output *C.char) {
	defer panicResult("status", &output)
	return cJSON(stateResult("status"))
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
	result.DefaultRoute = probeDefaultRoute()
	result.NetworkMonitor = probeNetworkMonitor()
	interfaces, err := probeInterfaces()
	if err != nil {
		result.Error = err.Error()
	} else {
		result.Interfaces = interfaces
	}
	result.OK = result.Storage.OK && result.TCP.OK && result.UDP.OK && result.NetworkMonitor.OK && err == nil
	appendLog("platform diagnostics finished ok=%v dns=%v route=%v interfaces=%d", result.OK, result.DNS.OK, result.DefaultRoute.OK, len(result.Interfaces))
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
