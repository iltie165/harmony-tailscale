package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"golang.org/x/sys/unix"
	"tailscale.com/derp"
	"tailscale.com/derp/derphttp"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/ipn/store"
	"tailscale.com/tailcfg"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

func TestSwitchTunDetachesWithoutEOFOrBorrowedDescriptorLoss(t *testing.T) {
	device := newSwitchTun()
	defer device.Close()
	bufs := [][]byte{make([]byte, 1280)}
	sizes := make([]int, 1)
	read := make(chan error, 1)
	go func() { _, e := device.Read(bufs, sizes, 0); read <- e }()
	select {
	case <-read:
		t.Fatal("detached read completed")
	case <-time.After(20 * time.Millisecond):
	}
	first, original, peer := socketTun(t)
	if err := device.attach(first); err != nil {
		t.Fatal(err)
	}
	if err := device.detach(); err != nil {
		t.Fatal(err)
	}
	if _, err := unix.FcntlInt(uintptr(original), unix.F_GETFL, 0); err != nil {
		t.Fatal("borrowed FD closed", err)
	}
	if _, err := device.Write([][]byte{[]byte("discard")}, 0); err != nil {
		t.Fatal(err)
	}
	assertNoPacket(t, peer)
	second, _, peer2 := socketTun(t)
	if err := device.attach(second); err != nil {
		t.Fatal(err)
	}
	if _, err := unix.Write(peer2, []byte("new interface")); err != nil {
		t.Fatal(err)
	}
	select {
	case e := <-read:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(time.Second):
		t.Fatal("reattached read did not resume")
	}
	if string(bufs[0][:sizes[0]]) != "new interface" {
		t.Fatal("old attachment data delivered")
	}
	if _, err := device.Write([][]byte{[]byte("inbound")}, 0); err != nil {
		t.Fatal(err)
	}
	if string(receivePacket(t, peer2)) != "inbound" {
		t.Fatal("wrong packet")
	}
}

func TestMissingServiceNeverCreatesDiscoveryOwner(t *testing.T) {
	fake := &fakeBackend{}
	setupBackend(t, fake)
	dir := t.TempDir()
	r := connectServiceCore(dir, "test-service")
	if r.OK || r.Operation != "connectService" || fake.starts != 0 {
		t.Fatal("UI connection fell back to creating an owner", r)
	}
	if _, err := os.Stat(filepath.Join(dir, "tailscaled.state")); !os.IsNotExist(err) {
		t.Fatal("UI proxy opened account state", err)
	}
	if r = disconnectServiceClient(); !r.OK {
		t.Fatal(r)
	}
	if _, _, err := currentServer(); err == nil {
		t.Fatal("failed proxy retained after disconnect")
	}
}

func TestRefusedServiceProxyRetriesWhenOwnerBeginsListening(t *testing.T) {
	fake := &fakeBackend{}
	setupBackend(t, fake)
	dir := t.TempDir()
	// Leave the same stale Unix socket a terminated extension leaves behind.
	old, err := net.Listen("unix", serviceSocket(dir))
	if err != nil {
		t.Fatal(err)
	}
	old.(*net.UnixListener).SetUnlinkOnClose(false)
	old.Close()
	for i := 0; i < 2; i++ {
		if r := connectServiceCore(dir, "test-service"); r.OK || r.Error == "" {
			t.Fatal("missing listener reported ready", r)
		}
	}
	if err := os.Remove(serviceSocket(dir)); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", serviceSocket(dir))
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(ipnstate.Status{BackendState: "Starting"})
	})}
	go server.Serve(listener)
	defer server.Close()
	// No explicit disconnect, logout, service replacement or remote login.
	if r := connectServiceCore(dir, "test-service"); !r.OK {
		t.Fatal("failed proxy poisoned subsequent startup", r)
	}
	if fake.starts != 0 {
		t.Fatal("UI started a second owner")
	}
	if _, err := os.Stat(filepath.Join(dir, "tailscaled.state")); !os.IsNotExist(err) {
		t.Fatal("proxy opened login state", err)
	}
}

func TestSwitchTunRejectsDoubleAttachAndSurvivesDescriptorFailure(t *testing.T) {
	device := newSwitchTun()
	first, _, peer := socketTun(t)
	if err := device.attach(first); err != nil {
		t.Fatal(err)
	}
	other, _, _ := socketTun(t)
	if device.attach(other) == nil {
		t.Fatal("accepted duplicate attachment")
	}
	unix.Close(peer)
	read := make(chan error, 1)
	go func() { _, e := device.Read([][]byte{make([]byte, 1280)}, make([]int, 1), 0); read <- e }()
	if err := device.Close(); err != nil {
		t.Fatal(err)
	}
	if err := device.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case e := <-read:
		if !errors.Is(e, os.ErrClosed) {
			t.Fatal(e)
		}
	case <-time.After(time.Second):
		t.Fatal("permanent read leaked")
	}
	if !errors.Is(device.attach(other), os.ErrClosed) {
		t.Fatal("closed permanent device accepted attach")
	}
	if _, e := device.Write([][]byte{[]byte("x")}, 0); !errors.Is(e, os.ErrClosed) {
		t.Fatal(e)
	}
	if _, e := device.Read(nil, nil, 0); e == nil {
		t.Fatal("bad read accepted")
	}
	if _, e := device.Write([][]byte{{}}, 0); e == nil {
		t.Fatal("bad write accepted")
	}
}

// Use the pinned upstream's local encrypted control server, never a public
// account or a fake authentication field. Production attach checks remain on.
func TestRealServiceCoreIsReusedAcrossRepeatedVpnAttachments(t *testing.T) {
	setupBackend(t, &fakeBackend{})
	previousPlatform := reportedPlatform.Load()
	t.Cleanup(func() { reportedPlatform.Store(previousPlatform) })
	if r := configurePlatform(`{"os":"openharmony","osVersion":"6.1.1.120","deviceModel":"test-phone"}`); !r.OK {
		t.Fatal(r)
	}
	relayCore := derp.NewServer(key.NewNode(), t.Logf)
	defer relayCore.Close()
	relay := httptest.NewTLSServer(derphttp.Handler(relayCore))
	defer relay.Close()
	_, portText, _ := net.SplitHostPort(relay.Listener.Addr().String())
	portNumber, _ := strconv.Atoi(portText)
	control := &testcontrol.Server{Logf: t.Logf, DERPMap: &tailcfg.DERPMap{Regions: map[int]*tailcfg.DERPRegion{
		1: {RegionID: 1, RegionCode: "local", Nodes: []*tailcfg.DERPNode{{Name: "local", RegionID: 1, HostName: "127.0.0.1", IPv4: "127.0.0.1", IPv6: "none", DERPPort: portNumber, STUNPort: -1, InsecureForTests: true}}},
	}}}
	httpServer := httptest.NewServer(control)
	defer httpServer.Close()
	control.HTTPTestServer = httpServer
	dir := t.TempDir()
	stateStore, err := store.New(logger.Discard, filepath.Join(dir, "tailscaled.state"))
	if err != nil {
		t.Fatal(err)
	}
	prefs := savedTestPrefs()
	prefs.ControlURL = httpServer.URL
	profile := &ipn.LoginProfile{ID: "test", Key: "profile-test", Name: "Saved", UserProfile: prefs.Persist.UserProfile, ControlURL: prefs.ControlURL}
	for k, v := range map[ipn.StateKey][]byte{ipn.KnownProfilesStateKey: encodeJSON(map[ipn.ProfileID]*ipn.LoginProfile{profile.ID: profile}), ipn.CurrentProfileStateKey: []byte(profile.Key), profile.Key: encodeJSON(prefs)} {
		if err = stateStore.WriteState(k, v); err != nil {
			t.Fatal(err)
		}
	}
	if r := startServiceCore(dir, "test-service"); !r.OK {
		t.Fatal(r)
	}
	defer closeCore()
	server, _, err := currentServer()
	if err != nil {
		t.Fatal(err)
	}
	owner := server.(*serviceBackend)
	actualPrefs, err := owner.client.GetPrefs(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if actualPrefs.ControlURL != httpServer.URL {
		t.Fatal("saved control URL changed", actualPrefs.ControlURL)
	}
	if err := owner.client.StartLoginInteractive(context.Background()); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for owner.lb.State() != ipn.Running && time.Now().Before(deadline) {
		// The offline test namespace has only loopback. Explicitly make that
		// test transport available, as in the real dual-engine packet test.
		owner.sys.MagicSock.Get().SetNetworkUp(true)
		time.Sleep(10 * time.Millisecond)
	}
	status := owner.lb.StatusWithoutPeers()
	if status.BackendState != "Running" {
		t.Log(recentLogLines(40))
		t.Fatal("local registration did not become Running", status.BackendState)
	}
	nodes := control.AllNodes()
	if len(nodes) != 1 || nodes[0].Hostinfo.OS() != "openharmony" ||
		nodes[0].Hostinfo.OSVersion() != "6.1.1.120" || nodes[0].Hostinfo.DeviceModel() != "test-phone" {
		t.Fatal("real encrypted control registration lost platform metadata", nodes)
	}
	address := ""
	for _, ip := range status.TailscaleIPs {
		if ip.Is4() {
			address = ip.String()
		}
	}
	if address == "" {
		t.Fatal("no assigned address")
	}
	id := owner.coreID
	if r := disconnectServiceClient(); !r.OK || vpnStateCore().CoreID != id || !vpnStateCore().CoreOwner {
		t.Fatal("disconnecting an in-process UI client closed the owner", r)
	}
	before, err := owner.client.GetPrefs(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		if r := startServiceCore(dir, "test-service"); !r.OK {
			t.Fatal(r)
		}
		_, original, _ := socketTun(t)
		if r := startVpnCore(dir, "test-service", address, original); !r.OK {
			t.Fatal(r)
		}
		active := vpnStateCore()
		if !active.Connected || !active.CoreAlive || !active.CoreOwner || active.CoreID != id {
			t.Fatal(active)
		}
		if r := detachVpnCore(); !r.OK {
			t.Fatal(r)
		}
		idle := vpnStateCore()
		if idle.Connected || idle.Attached || !idle.CoreAlive || idle.CoreID != id {
			t.Fatal(idle)
		}
		after, e := owner.client.GetPrefs(context.Background())
		if e != nil || after.Persist.NodeID != before.Persist.NodeID {
			t.Fatal("identity changed", e)
		}
		if duplicate, e := acquireStateLease(dir); e == nil {
			duplicate.Close()
			t.Fatal("OFF released live core lease")
		}
	}
	if control.NumNodes() != 1 {
		t.Fatal("toggle registered duplicate nodes", control.NumNodes())
	}
}
