package main

import (
	"context"
	"fmt"
	"net/netip"
	"time"
)

// The product starts the same official backend before attaching any system
// interface. Existing healthy instances are reused by startWithBackend.
func startServiceCore(dir, hostname string) operationResult {
	r := startWithBackend(dir, hostname, func(dir, hostname string) backend {
		return &serviceBackend{dir: dir, hostname: hostname}
	})
	r.Operation = "startService"
	return r
}

func connectServiceCore(dir, hostname string) operationResult {
	r := startWithBackend(dir, hostname, func(dir, hostname string) backend { return remoteService(dir) })
	r.Operation = "connectService"
	return r
}
func disconnectServiceClient() operationResult {
	operationMu.Lock()
	defer operationMu.Unlock()
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if lifecycle.server == nil {
		return operationResult{OK: true, Operation: "disconnectClient", State: "closed"}
	}
	if _, owner := lifecycle.server.(*serviceBackend); owner {
		return operationResult{OK: true, Operation: "disconnectClient", State: lifecycle.state, Message: "owner retained"}
	}
	proxy, ok := lifecycle.server.(*remoteBackend)
	if !ok {
		return operationResult{Operation: "disconnectClient", State: lifecycle.state, Error: "unexpected legacy state owner"}
	}
	proxy.Close()
	lifecycle.server = nil
	lifecycle.state = "closed"
	lifecycle.lastError = ""
	return operationResult{OK: true, Operation: "disconnectClient", State: "closed"}
}

func startVpnCore(dir, hostname, address string, fd int) operationResult {
	ip, err := netip.ParseAddr(address)
	if err != nil || !ip.Is4() || !netip.MustParsePrefix("100.64.0.0/10").Contains(ip) || fd < 0 {
		return operationResult{Operation: "startVpn", State: "error", Error: "VPN requires an assigned Tailnet IPv4 and valid descriptor"}
	}
	operationMu.Lock()
	server, state, currentErr := currentServer()
	if currentErr == nil {
		owner, ok := server.(*serviceBackend)
		if !ok || owner.dir != dir || state != "started" {
			operationMu.Unlock()
			return operationResult{Operation: "startVpn", State: "error", Error: "VPN must attach in the authoritative service process"}
		}
		err = owner.AttachVPN(fd, ip)
		operationMu.Unlock()
		if err != nil {
			return operationResult{Operation: "startVpn", State: "error", Error: err.Error()}
		}
		return operationResult{OK: true, Operation: "startVpn", State: "started", Message: "existing core reused"}
	}
	operationMu.Unlock()
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

func (b *serviceBackend) AttachVPN(fd int, ip netip.Addr) error {
	if b.lb == nil || b.device == nil {
		return fmt.Errorf("core is not initialized")
	}
	if assigned := b.readyIPv4(); !assigned.IsValid() || assigned != ip {
		return fmt.Errorf("VPN address is not assigned to the live core")
	}
	device, err := newPacketTun(fd)
	if err != nil {
		return err
	}
	if err = b.device.attach(device); err != nil {
		device.Close()
		return err
	}
	b.router.mu.Lock()
	b.router.address = ip
	b.router.attached = true
	b.router.err = ""
	b.router.mu.Unlock()
	return nil
}
func detachVpnCore() operationResult {
	operationMu.Lock()
	defer operationMu.Unlock()
	server, state, err := currentServer()
	if err != nil {
		return operationResult{Operation: "detachVpn", State: state, Error: err.Error()}
	}
	owner, ok := server.(*serviceBackend)
	if !ok || owner.device == nil {
		return operationResult{Operation: "detachVpn", State: state, Error: "VPN owner is not in this process"}
	}
	err = owner.device.detach()
	owner.router.mu.Lock()
	owner.router.attached = false
	owner.router.err = ""
	owner.router.mu.Unlock()
	if err != nil {
		return operationResult{Operation: "detachVpn", State: "error", Error: err.Error()}
	}
	return operationResult{OK: true, Operation: "detachVpn", State: "started", Message: "interface detached; core and account retained"}
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
