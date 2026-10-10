package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"tailscale.com/net/netmon"
	"tailscale.com/net/netns"
	"tailscale.com/types/logger"
	"tailscale.com/util/eventbus"
)

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

type httpDoer interface {
	Do(*http.Request) (*http.Response, error)
}

// Use the same netns dialer family as control traffic rather than testing an
// unrelated http.DefaultClient path. This catches socket-adapter regressions.
func probeControlPlane() checkResult {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	transport := &http.Transport{DialContext: netns.NewDialer(logger.Discard, netmon.NewStatic()).DialContext}
	defer transport.CloseIdleConnections()
	return probeHTTPS(ctx, &http.Client{Transport: transport}, "https://controlplane.tailscale.com/key?v=123")
}

func probeHTTPS(ctx context.Context, client httpDoer, url string) checkResult {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return checkResult{Error: err.Error()}
	}
	response, err := client.Do(request)
	if err != nil {
		return checkResult{Error: err.Error()}
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return checkResult{Detail: response.Status, Error: fmt.Sprintf("control endpoint returned %s", response.Status)}
	}
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

type diagnosticProbes struct {
	storage                                func(string) checkResult
	tcp, udp, dns, control, route, monitor func() checkResult
	interfaces                             func() ([]interfaceInfo, error)
}

func diagnosticsCore(dataDir string) diagnosticsResult {
	return runDiagnostics(dataDir, diagnosticProbes{
		storage: probeStorage, tcp: probeTCP, udp: probeUDP, dns: probeDNS,
		control: probeControlPlane, route: probeDefaultRoute, monitor: probeNetworkMonitor,
		interfaces: probeInterfaces,
	})
}

// Orchestration is testable without assuming the host behaves like HarmonyOS.
func runDiagnostics(dataDir string, probes diagnosticProbes) diagnosticsResult {
	if dataDir != "" {
		dataDir = filepath.Clean(dataDir)
	}
	appendLog("platform diagnostics begin dir=%q", dataDir)
	result := diagnosticsResult{Operation: "diagnostics", GOOS: runtime.GOOS, GOARCH: runtime.GOARCH}
	result.Storage = probes.storage(dataDir)
	result.TCP = probes.tcp()
	result.UDP = probes.udp()
	result.DNS = probes.dns()
	result.ControlPlane = probes.control()
	result.DefaultRoute = probes.route()
	result.NetworkMonitor = probes.monitor()
	interfaces, err := probes.interfaces()
	if err != nil {
		result.Error = err.Error()
	} else {
		result.Interfaces = interfaces
	}
	result.OK = result.Storage.OK && result.TCP.OK && result.UDP.OK && result.DNS.OK && result.ControlPlane.OK && result.NetworkMonitor.OK && err == nil
	appendLog("platform diagnostics finished ok=%v dns=%v control=%v route=%v interfaces=%d", result.OK, result.DNS.OK, result.ControlPlane.OK, result.DefaultRoute.OK, len(result.Interfaces))
	return result
}
