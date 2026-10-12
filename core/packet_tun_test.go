package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/net/dns"
	"tailscale.com/net/netmon"
	"tailscale.com/net/packet"
	"tailscale.com/tailcfg"
	"tailscale.com/tsd"
	"tailscale.com/types/ipproto"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
	"tailscale.com/types/netmap"
	"tailscale.com/util/eventbus"
	"tailscale.com/wgengine"
	"tailscale.com/wgengine/filter"
	"tailscale.com/wgengine/magicsock"
	"tailscale.com/wgengine/router"
	"tailscale.com/wgengine/wgcfg"
)

func socketTun(t *testing.T) (*packetTun, int, int) {
	t.Helper()
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { unix.Close(fds[0]); unix.Close(fds[1]) })
	tun, err := newPacketTun(fds[0])
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { tun.Close() })
	return tun, fds[0], fds[1]
}
func receivePacket(t *testing.T, fd int) []byte {
	t.Helper()
	ready, err := waitTestPacket(fd, 10*time.Second)
	if err != nil || !ready {
		t.Fatalf("packet receive timed out: %v", err)
	}
	buffer := make([]byte, 2048)
	n, err := unix.Read(fd, buffer)
	if err != nil {
		t.Fatal(err)
	}
	return buffer[:n]
}
func TestPacketTunOwnershipAndBidirectionalIO(t *testing.T) {
	tun, original, peer := socketTun(t)
	if tun.File() != nil || tun.BatchSize() != 1 {
		t.Fatal("invalid platform TUN contract")
	}
	if _, err := tun.Name(); err != nil {
		t.Fatal(err)
	}
	if mtu, _ := tun.MTU(); mtu != 1280 {
		t.Fatal(mtu)
	}
	<-tun.Events()
	if _, err := unix.Write(peer, []byte("outbound")); err != nil {
		t.Fatal(err)
	}
	bufs := [][]byte{make([]byte, 100)}
	sizes := make([]int, 1)
	n, err := tun.Read(bufs, sizes, 7)
	if err != nil || n != 1 || string(bufs[0][7:7+sizes[0]]) != "outbound" {
		t.Fatalf("read %d %v", n, err)
	}
	if n, err = tun.Write([][]byte{[]byte("padreply")}, 3); err != nil || n != 1 {
		t.Fatalf("write %d %v", n, err)
	}
	if string(receivePacket(t, peer)) != "reply" {
		t.Fatal("incorrect inbound packet")
	}
	if tun.txPackets.Load() != 1 || tun.rxPackets.Load() != 1 || tun.txBytes.Load() != 8 || tun.rxBytes.Load() != 5 {
		t.Fatal("incorrect counters")
	}
	if err = tun.Close(); err != nil {
		t.Fatal(err)
	}
	if err = tun.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err = unix.FcntlInt(uintptr(original), unix.F_GETFL, 0); err != nil {
		t.Fatal("closed borrowed original")
	}
	if _, err = tun.Read(bufs, sizes, 0); !errors.Is(err, os.ErrClosed) {
		t.Fatal(err)
	}
}
func TestPacketTunCloseJoinsPendingRead(t *testing.T) {
	tun, _, _ := socketTun(t)
	joined := make(chan error, 1)
	go func() { _, err := tun.Read([][]byte{make([]byte, 1280)}, make([]int, 1), 0); joined <- err }()
	if err := tun.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-joined:
		if !errors.Is(err, os.ErrClosed) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("blocked read leaked")
	}
}
func TestPacketTunInvalidInputs(t *testing.T) {
	if _, err := newPacketTun(-1); err == nil {
		t.Fatal("accepted invalid fd")
	}
	file, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if _, err = newPacketTun(int(file.Fd())); err == nil {
		t.Fatal("accepted read-only fd")
	}
	tun, _, _ := socketTun(t)
	if _, err = tun.Read(nil, nil, 0); err == nil {
		t.Fatal("accepted empty read")
	}
	if _, err = tun.Write([][]byte{{}}, 0); err == nil {
		t.Fatal("accepted empty write")
	}
}

func TestStateLeaseExclusiveAndReusable(t *testing.T) {
	dir := t.TempDir()
	first, err := acquireStateLease(dir)
	if err != nil {
		t.Fatal(err)
	}
	if second, err := acquireStateLease(dir); err == nil {
		second.Close()
		t.Fatal("two owners acquired same state")
	}
	first.Close()
	second, err := acquireStateLease(dir)
	if err != nil {
		t.Fatal(err)
	}
	second.Close()
}

func TestLeasedBackendFailureCleanupAndCloseRetry(t *testing.T) {
	dir := t.TempDir()
	lease, err := acquireStateLease(dir)
	if err != nil {
		t.Fatal(err)
	}
	inner := &fakeBackend{}
	b := &leasedBackend{backend: inner, dir: dir}
	if b.Start() == nil {
		t.Fatal("overlap accepted")
	}
	b.Close()
	if inner.starts != 0 || inner.closes != 0 {
		t.Fatal("touched core without ownership")
	}
	lease.Close()
	inner = &fakeBackend{startErr: errors.New("startup failed")}
	b = &leasedBackend{backend: inner, dir: dir}
	if b.Start() == nil {
		t.Fatal("ignored startup failure")
	}
	if b.Close() != nil || inner.closes != 1 {
		t.Fatal("repeated cleanup called upstream Close twice")
	}
	inner = &fakeBackend{}
	b = &leasedBackend{backend: inner, dir: dir}
	if err = b.Start(); err != nil {
		t.Fatal(err)
	}
	inner.closeErr = errors.New("close blocked")
	if b.Close() == nil {
		t.Fatal("close failure hidden")
	}
	if second, err := acquireStateLease(dir); err == nil {
		second.Close()
		t.Fatal("released ownership with unclosed core")
	}
	inner.closeErr = nil
	if err = b.Close(); err != nil {
		t.Fatal(err)
	}
	lease, err = acquireStateLease(dir)
	if err != nil {
		t.Fatal("state lock leaked")
	}
	lease.Close()
}
func TestRemoteVPNLocalAPIAndOwnerDisappearance(t *testing.T) {
	dir := t.TempDir()
	listener, err := net.Listen("unix", serviceSocket(dir))
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/localapi/v0/status":
			json.NewEncoder(w).Encode(ipnstate.Status{BackendState: "Running"})
		case "/harmony/vpn":
			json.NewEncoder(w).Encode(vpnState{OK: true, Connected: true, State: "connected", IPv4: "100.64.1.1", TxPackets: 3})
		default:
			http.NotFound(w, r)
		}
	})}
	go server.Serve(listener)
	defer server.Close()
	remote := remoteService(dir)
	defer remote.Close()
	if err = remote.Start(); err != nil {
		t.Fatal(err)
	}
	if _, ok := newBackend(dir, "test").(*remoteBackend); !ok {
		t.Fatal("UI created second core instead of proxy")
	}
	client, _ := remote.LocalClient()
	status, err := client.Status(context.Background())
	if err != nil || status.BackendState != "Running" {
		t.Fatal(err)
	}
	s := remote.VPNState(context.Background())
	if !s.Connected || s.TxPackets != 3 {
		t.Fatal(s)
	}
	remote.Close()
	if err = remote.Start(); err != nil {
		t.Fatal("closing proxy stopped service")
	}
	server.Close()
	s = remote.VPNState(context.Background())
	if s.OK || s.Connected || s.Error == "" {
		t.Fatal("lost owner shown connected", s)
	}
}
func TestPlatformRouterAddressMismatch(t *testing.T) {
	r := &platformRouter{address: netip.MustParseAddr("100.64.1.1")}
	if err := r.Set(&router.Config{LocalAddrs: []netip.Prefix{netip.MustParsePrefix("100.64.1.2/32")}}); err == nil {
		t.Fatal("accepted mismatched interface address")
	}
}

// Two real upstream engines, real localhost UDP, real WireGuard handshakes and
// encryption, and the production fd adapter. Only the control plane and OS
// TUN endpoint are supplied by the test. No public network or root TUN needed.
func TestOfficialEngineEncryptedIPv4PacketsBothDirections(t *testing.T) {
	var engines [2]wgengine.Engine
	var systems [2]*tsd.System
	var fds [2]int
	var keys = [2]key.NodePrivate{key.NewNode(), key.NewNode()}
	var ips = [2]netip.Prefix{netip.MustParsePrefix("100.64.1.1/32"), netip.MustParsePrefix("100.64.1.2/32")}
	for i := range engines {
		tun, _, fd := socketTun(t)
		fds[i] = fd
		sys := tsd.NewSystem()
		systems[i] = sys
		mon := netmon.NewStatic()
		sys.Set(mon)
		engine, err := wgengine.NewUserspaceEngine(t.Logf, wgengine.Config{Tun: tun, Router: &platformRouter{address: ips[i].Addr()}, NetMon: mon, SetSubsystem: sys.Set, EventBus: sys.Bus.Get(), HealthTracker: sys.HealthTracker(), Metrics: sys.UserMetricsRegistry()})
		if err != nil {
			t.Fatal(err)
		}
		engines[i] = engine
		sys.Set(engine)
		installLocalPingResponder(sys, ips[i].Addr())
		engine.SetFilter(filter.NewAllowAllForTest(logger.Discard))
		sys.Tun.Get().Start()
		t.Cleanup(func() {
			tun.Close()
			engine.Close()
			<-engine.Done()
			sys.Dialer.Get().Close()
			mon.Close()
			sys.Bus.Get().Close()
		})
	}
	for i, engine := range engines {
		peer := i ^ 1
		node := &tailcfg.Node{ID: tailcfg.NodeID(peer + 1), Key: keys[peer].Public(), Addresses: []netip.Prefix{ips[peer]}, AllowedIPs: []netip.Prefix{ips[peer]}, IsWireGuardOnly: true, Endpoints: []netip.AddrPort{netip.AddrPortFrom(netip.MustParseAddr("127.0.0.1"), systems[peer].MagicSock.Get().LocalPort())}}
		self := (&tailcfg.Node{ID: tailcfg.NodeID(i + 1), Key: keys[i].Public(), Addresses: []netip.Prefix{ips[i]}}).View()
		engine.SetNetworkMap(&netmap.NetworkMap{PrivateKey: keys[i], NodeKey: keys[i].Public(), SelfNode: self, Peers: []tailcfg.NodeView{node.View()}})
		client := systems[i].Bus.Get().Client("offline-control-map")
		publisher := eventbus.Publish[magicsock.NodeViewsUpdate](client)
		publisher.Publish(magicsock.NodeViewsUpdate{SelfNode: self, Peers: []tailcfg.NodeView{node.View()}})
		systems[i].MagicSock.Get().Synchronize()
		systems[i].MagicSock.Get().SetNetworkUp(true) // --network none has only loopback, which this test deliberately uses.
		client.Close()
		cfg := &wgcfg.Config{PrivateKey: keys[i], Addresses: []netip.Prefix{ips[i]}, MTU: 1280, Peers: []wgcfg.Peer{{PublicKey: keys[peer].Public(), AllowedIPs: []netip.Prefix{ips[peer]}}}}
		if err := engine.Reconfig(cfg, &router.Config{LocalAddrs: []netip.Prefix{ips[i]}, Routes: []netip.Prefix{ips[peer]}}, &dns.Config{}); err != nil {
			t.Fatal(err)
		}
	}
	for _, protocol := range []byte{17, 6} {
		for i := 0; i < 2; i++ {
			packet := ipv4TestPacket(ips[i].Addr(), ips[i^1].Addr(), protocol)
			if _, err := unix.Write(fds[i], packet); err != nil {
				t.Fatal(err)
			}
			if got := receivePacket(t, fds[i^1]); !bytes.Equal(packet, got) {
				t.Fatalf("protocol %d decrypted packet differs: %x != %x", protocol, got, packet)
			}
		}
	}
	t.Run("ICMPRepliesThroughEncryptedTransportWithoutOS", func(t *testing.T) {
		for i := 0; i < 2; i++ {
			request := echoTestPacket(ips[i].Addr(), ips[i^1].Addr())
			if _, err := unix.Write(fds[i], request); err != nil {
				t.Fatal(err)
			}
			reply := receivePacket(t, fds[i])
			var parsed packet.Parsed
			parsed.Decode(reply)
			if !parsed.IsEchoResponse() || parsed.Src.Addr() != ips[i^1].Addr() || parsed.Dst.Addr() != ips[i].Addr() || !bytes.Equal(reply[24:], request[24:]) {
				t.Fatalf("invalid ICMP reply: %x", reply)
			}
			if !validChecksum(reply[:20]) || !validChecksum(reply[20:]) {
				t.Fatalf("invalid reply checksum: %x", reply)
			}
			assertNoPacket(t, fds[i^1]) // consumed, not delivered to the OS
			assertNoPacket(t, fds[i])   // exactly one reply
		}
	})
	t.Run("ICMPDeniedByOfficialInboundFilterGetsNoReply", func(t *testing.T) {
		engines[1].SetFilter(filter.NewAllowNone(logger.Discard, nil))
		if _, err := unix.Write(fds[0], echoTestPacket(ips[0].Addr(), ips[1].Addr())); err != nil {
			t.Fatal(err)
		}
		assertNoPacket(t, fds[0])
		assertNoPacket(t, fds[1])
	})
}

func echoTestPacket(src, dst netip.Addr) []byte {
	h := packet.ICMP4Header{IP4Header: packet.IP4Header{Src: src, Dst: dst, IPProto: ipproto.ICMPv4}, Type: packet.ICMP4EchoRequest}
	return packet.Generate(&h, []byte{0x12, 0x34, 0x56, 0x78, 'p', 'i', 'n', 'g', '!'})
}

func validChecksum(buf []byte) bool {
	var sum uint32
	for len(buf) >= 2 {
		sum += uint32(binary.BigEndian.Uint16(buf[:2]))
		buf = buf[2:]
	}
	if len(buf) != 0 {
		sum += uint32(buf[0]) << 8
	}
	for sum>>16 != 0 {
		sum = sum&0xffff + sum>>16
	}
	return uint16(sum) == 0xffff
}

func assertNoPacket(t *testing.T, fd int) {
	t.Helper()
	if ready, err := waitTestPacket(fd, 250*time.Millisecond); err != nil || ready {
		t.Fatalf("unexpected packet or poll failure: %v, %v", ready, err)
	}
}

// Go's async preemption can interrupt poll, especially under -race. Retrying
// EINTR must keep the original deadline; it is not a packet arrival or timeout.
func waitTestPacket(fd int, timeout time.Duration) (bool, error) {
	deadline := time.Now().Add(timeout)
	p := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
	for {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return false, nil
		}
		n, err := unix.Poll(p, int((remaining+time.Millisecond-1)/time.Millisecond))
		if err == unix.EINTR {
			continue
		}
		return n > 0, err
	}
}

func TestLocalPingResponderDoesNotConsumeOtherTraffic(t *testing.T) {
	sys := tsd.NewSystem()
	tun, _, _ := socketTun(t)
	// Obtain the official wrapper from a real engine, with no public networking.
	mon := netmon.NewStatic()
	sys.Set(mon)
	address := netip.MustParseAddr("100.64.1.1")
	engine, err := wgengine.NewUserspaceEngine(t.Logf, wgengine.Config{Tun: tun, Router: &platformRouter{address: address}, NetMon: mon, SetSubsystem: sys.Set, EventBus: sys.Bus.Get(), HealthTracker: sys.HealthTracker(), Metrics: sys.UserMetricsRegistry()})
	if err != nil {
		t.Fatal(err)
	}
	sys.Set(engine)
	defer func() {
		tun.Close()
		engine.Close()
		<-engine.Done()
		sys.Dialer.Get().Close()
		mon.Close()
		sys.Bus.Get().Close()
	}()
	installLocalPingResponder(sys, address)
	for _, raw := range [][]byte{
		ipv4TestPacket(netip.MustParseAddr("100.64.1.2"), address, 6),
		ipv4TestPacket(netip.MustParseAddr("100.64.1.2"), address, 17),
		echoTestPacket(netip.MustParseAddr("100.64.1.2"), netip.MustParseAddr("100.64.1.3")),
	} {
		var parsed packet.Parsed
		parsed.Decode(raw)
		if verdict, _ := sys.Tun.Get().PostFilterPacketInboundFromWireGuard(&parsed, sys.Tun.Get(), nil); verdict != filter.Accept {
			t.Fatal("consumed non-local echo or application traffic")
		}
	}
}
func ipv4TestPacket(src, dst netip.Addr, protocol byte) []byte {
	n := 32
	if protocol == 6 {
		n = 44
	}
	p := make([]byte, n)
	p[0] = 0x45
	p[8] = 64
	p[9] = protocol
	binary.BigEndian.PutUint16(p[2:4], uint16(n))
	s, d := src.As4(), dst.As4()
	copy(p[12:16], s[:])
	copy(p[16:20], d[:])
	var sum uint32
	for i := 0; i < 20; i += 2 {
		sum += uint32(binary.BigEndian.Uint16(p[i : i+2]))
	}
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	binary.BigEndian.PutUint16(p[10:12], ^uint16(sum))
	binary.BigEndian.PutUint16(p[20:22], 12345)
	binary.BigEndian.PutUint16(p[22:24], 23456)
	if protocol == 17 {
		binary.BigEndian.PutUint16(p[24:26], uint16(n-20))
		copy(p[28:], "test")
	} else {
		p[32] = 0x50
		p[33] = 0x02
		copy(p[40:], "test")
	}
	return p
}

func TestServiceCleanupOnStateLeaseConflict(t *testing.T) {
	dir := t.TempDir()
	lease, err := acquireStateLease(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	tun, _, _ := socketTun(t)
	b := &serviceBackend{dir: dir, hostname: "test", address: "100.64.1.1", tun: tun}
	if err = b.Start(); err == nil {
		t.Fatal("started overlapping core")
	}
	select {
	case <-tun.done:
	default:
		t.Fatal("failure leaked owned TUN")
	}
	if _, err = os.Stat(filepath.Join(dir, "tailscaled.state")); !os.IsNotExist(err) {
		t.Fatal("mutated state before acquiring lease")
	}
}

func TestRealVPNBackendStartupControlAndCleanup(t *testing.T) {
	setupBackend(t, &fakeBackend{})
	tun, original, _ := socketTun(t)
	dir := t.TempDir()
	r := startVpnCore(dir, "test-vpn", "100.64.1.1", original)
	if !r.OK {
		t.Fatal(r)
	}
	defer closeCore()
	owner, _, err := currentServer()
	if err != nil {
		t.Fatal(err)
	}
	b := owner.(*serviceBackend)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	prefs, err := b.client.GetPrefs(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if prefs.CorpDNS || prefs.RouteAll || len(prefs.AdvertiseRoutes) != 0 {
		t.Fatal("unsupported DNS/route configuration enabled")
	}
	status := vpnStateCore()
	if !status.OK || status.Connected || status.State != "connecting" {
		t.Fatal("unauthenticated core reported VPN connected", status)
	}
	if !networkChangedCore().OK {
		t.Fatal("native network change dispatch failed")
	}
	if r = closeCore(); !r.OK {
		t.Fatal(r)
	}
	if s := vpnStateCore(); !s.OK || s.Connected || s.State != "disconnected" {
		t.Fatal(s)
	}
	if networkChangedCore().OK {
		t.Fatal("not running yet accepts network event")
	}
	lease, err := acquireStateLease(dir)
	if err != nil {
		t.Fatal("state lease leaked", err)
	}
	lease.Close()
	if _, err = unix.FcntlInt(uintptr(original), unix.F_GETFL, 0); err != nil {
		t.Fatal("core took ownership of ArkTS descriptor", err)
	}
	tun.Close()
}
func TestVPNStartupValidationAndOccupiedLifecycle(t *testing.T) {
	b := &fakeBackend{}
	setupBackend(t, b)
	for _, ip := range []string{"", "not-ip", "192.168.1.1", "fd7a:115c:a1e0::1"} {
		if r := startVpnCore(t.TempDir(), "host", ip, 0); r.OK || r.Error == "" {
			t.Fatal(r)
		}
	}
	if r := startVpnCore(t.TempDir(), "host", "100.64.1.1", 2147483647); r.OK {
		t.Fatal(r)
	}
	_, fd, _ := socketTun(t)
	if r := startVpnCore("relative", "host", "100.64.1.1", fd); r.OK || !strings.Contains(r.Error, "absolute") {
		t.Fatal(r)
	}
	if r := startCore(t.TempDir(), "host"); !r.OK {
		t.Fatal(r)
	}
	if r := startVpnCore(t.TempDir(), "host", "100.64.1.1", fd); r.OK {
		t.Fatal("silently reused discovery engine", r)
	}
	if vpnStateCore().Connected {
		t.Fatal("discovery core shown as VPN")
	}
	if networkChangedCore().OK {
		t.Fatal("discovery core accepts VPN network event")
	}
}
