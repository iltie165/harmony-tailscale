package main

import (
	"context"
	"net/netip"
	"time"
)

func startVpnCore(dir, hostname, address string, fd int) operationResult {
	ip, err := netip.ParseAddr(address)
	if err != nil || !ip.Is4() || !netip.MustParsePrefix("100.64.0.0/10").Contains(ip) || fd < 0 {
		return operationResult{Operation: "startVpn", State: "error", Error: "VPN requires an assigned Tailnet IPv4 and valid descriptor"}
	}
	tun, err := newPacketTun(fd)
	if err != nil {
		return operationResult{Operation: "startVpn", State: "error", Error: err.Error()}
	}
	used := false
	result := startWithBackend(dir, hostname, func(dir, hostname string) backend {
		used = true
		return &serviceBackend{dir: dir, hostname: hostname, address: address, tun: tun}
	})
	if !used {
		tun.Close()
		if result.OK {
			result.Error = "close the discovery core before attaching VPN"
		}
		result.OK = false
	}
	result.Operation = "startVpn"
	return result
}

func vpnStateCore() vpnState {
	operationMu.Lock()
	defer operationMu.Unlock()
	server, _, err := currentServer()
	if err != nil {
		return vpnState{OK: true, State: "disconnected"}
	}
	if provider, ok := server.(vpnStateProvider); ok {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		return provider.VPNState(ctx)
	}
	return vpnState{OK: true, State: "disconnected"}
}

func networkChangedCore() operationResult {
	operationMu.Lock()
	defer operationMu.Unlock()
	server, state, err := currentServer()
	if err != nil {
		return operationResult{Operation: "networkChanged", State: state, Error: err.Error()}
	}
	owner, ok := server.(*serviceBackend)
	if !ok || owner.sys == nil {
		return operationResult{Operation: "networkChanged", State: state, Error: "VPN owner is not running in this process"}
	}
	owner.sys.NetMon.Get().InjectEvent()
	return operationResult{OK: true, Operation: "networkChanged", State: state}
}
