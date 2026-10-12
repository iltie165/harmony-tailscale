package main

import (
	"net/netip"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/tailcfg"
	"tailscale.com/types/netmap"
)

// Running additionally waits for a live peer or DERP. An authorized current
// netmap and an applied engine address suffice to attach the system interface;
// neither saved UI peers nor a saved account can provide this proof.
func authorizedMapIPv4(nm *netmap.NetworkMap, now time.Time) netip.Addr {
	if nm == nil || !nm.SelfNode.Valid() || nm.SelfNode.ID() == 0 || nm.NodeKey.IsZero() ||
		nm.GetMachineStatus() != tailcfg.MachineAuthorized || nm.SelfNode.Expired() ||
		(!nm.Expiry.IsZero() && !nm.Expiry.After(now)) ||
		(!nm.SelfNode.KeyExpiry().IsZero() && !nm.SelfNode.KeyExpiry().After(now)) {
		return netip.Addr{}
	}
	for _, prefix := range nm.GetAddresses().All() {
		ip := prefix.Addr()
		if ip.Is4() && netip.MustParsePrefix("100.64.0.0/10").Contains(ip) {
			return ip
		}
	}
	return netip.Addr{}
}

func (b *serviceBackend) readyIPv4() netip.Addr {
	if b.lb == nil || b.router == nil {
		return netip.Addr{}
	}
	if b.sys == nil {
		return netip.Addr{}
	}
	engine, ok := b.sys.Engine.GetOK()
	if !ok {
		return netip.Addr{}
	}
	select {
	case <-engine.Done():
		return netip.Addr{}
	default:
	}
	state := b.lb.State()
	if state != ipn.Starting && state != ipn.Running {
		return netip.Addr{}
	}
	prefs := b.lb.Prefs()
	if !prefs.Valid() || prefs.LoggedOut() || !prefs.WantRunning() {
		return netip.Addr{}
	}
	nm := b.lb.NetMap()
	ip := authorizedMapIPv4(nm, time.Now())
	if !ip.IsValid() || nm.NodeKey != b.lb.NodeKey() {
		return netip.Addr{}
	}
	b.router.mu.Lock()
	defer b.router.mu.Unlock()
	if b.router.address != ip || b.router.err != "" {
		return netip.Addr{}
	}
	return ip
}
