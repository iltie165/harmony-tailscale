package main

import (
	"net/netip"

	"tailscale.com/net/packet"
	"tailscale.com/net/tstun"
	"tailscale.com/tsd"
	"tailscale.com/types/ipproto"
	"tailscale.com/wgengine/filter"
	"tailscale.com/wgengine/netstack/gro"
)

// Some mobile VPN interfaces deliver TCP/UDP to applications but do not
// provide OS ICMP echo replies. Reply only to this node's assigned IPv4, AFTER
// the official inbound ACL/shields-up filter. Never use the engine's fake-mode
// RespondToPing option, which replies to all destinations and also passes the
// request to the OS (potential duplicate replies).
func installLocalPingResponder(sys *tsd.System, address netip.Addr) {
	sys.Tun.Get().PostFilterPacketInboundFromWireGuard = func(p *packet.Parsed, t *tstun.Wrapper, g *gro.GRO) (filter.Response, *gro.GRO) {
		if p.IPVersion != 4 || p.IPProto != ipproto.ICMPv4 || p.Dst.Addr() != address || !p.IsEchoRequest() {
			return filter.Accept, g
		}
		// The first four payload bytes carry the identifier and sequence.
		// Preserve them verbatim with the echo data in the generated response.
		if len(p.Payload()) < 4 {
			return filter.DropSilently, g
		}
		h := p.ICMP4Header()
		h.ToResponse()
		if err := t.InjectOutbound(packet.Generate(&h, p.Payload())); err != nil {
			bridgeLogf("VPN ICMP reply: %v", err)
		}
		// Consume the request to avoid a second reply if the OS also supports it.
		return filter.DropSilently, g
	}
}
