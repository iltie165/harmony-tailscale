package main

import (
	"context"
	"net/http/httptest"
	"net/netip"
	"path/filepath"
	"testing"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/ipn/store"
	"tailscale.com/tailcfg"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
	"tailscale.com/types/netmap"
)

func TestAuthorizedMapReadinessRejectsUnapprovedExpiredAndAddresslessMaps(t *testing.T) {
	now := time.Now()
	node := &tailcfg.Node{ID: 1, MachineAuthorized: true, Addresses: []netip.Prefix{netip.MustParsePrefix("100.64.1.1/32")}}
	makeMap := func(n *tailcfg.Node) *netmap.NetworkMap {
		return &netmap.NetworkMap{SelfNode: n.View(), NodeKey: key.NewNode().Public()}
	}
	if got := authorizedMapIPv4(makeMap(node), now); got.String() != "100.64.1.1" {
		t.Fatal(got)
	}
	if authorizedMapIPv4(nil, now).IsValid() || authorizedMapIPv4(&netmap.NetworkMap{}, now).IsValid() {
		t.Fatal("missing map authorized")
	}
	for _, edit := range []func(*tailcfg.Node){
		func(n *tailcfg.Node) { n.MachineAuthorized = false },
		func(n *tailcfg.Node) { n.Expired = true },
		func(n *tailcfg.Node) { n.KeyExpiry = now },
		func(n *tailcfg.Node) { n.ID = 0 },
		func(n *tailcfg.Node) { n.Addresses = []netip.Prefix{netip.MustParsePrefix("192.168.1.1/32")} },
	} {
		copy := *node
		edit(&copy)
		if authorizedMapIPv4(makeMap(&copy), now).IsValid() {
			t.Fatal("unusable node authorized", copy)
		}
	}
	nm := makeMap(node)
	nm.Expiry = now
	if authorizedMapIPv4(nm, now).IsValid() {
		t.Fatal("expired map authorized")
	}
	nm.Expiry = time.Time{}
	nm.NodeKey = key.NodePublic{}
	if authorizedMapIPv4(nm, now).IsValid() {
		t.Fatal("missing key authorized")
	}
}

// An actual upstream core receives an authorized map from the local encrypted
// test control server, with no peer or DERP available. Starting is expected.
func TestRealStartingCoreWithoutDERPCanAttachAuthorizedNetworkMap(t *testing.T) {
	setupBackend(t, &fakeBackend{})
	control := &testcontrol.Server{Logf: t.Logf, DERPMap: &tailcfg.DERPMap{Regions: map[int]*tailcfg.DERPRegion{}}}
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
		if err := stateStore.WriteState(k, v); err != nil {
			t.Fatal(err)
		}
	}
	if r := startServiceCore(dir, "test-starting"); !r.OK {
		t.Fatal(r)
	}
	defer closeCore()
	server, _, _ := currentServer()
	owner := server.(*serviceBackend)
	if err := owner.client.StartLoginInteractive(context.Background()); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for !owner.readyIPv4().IsValid() && time.Now().Before(deadline) {
		owner.sys.MagicSock.Get().SetNetworkUp(true)
		time.Sleep(10 * time.Millisecond)
	}
	ip := owner.readyIPv4()
	if !ip.IsValid() || owner.lb.State() != ipn.Starting {
		t.Fatal("expected ready map before peer/DERP Running", owner.lb.State(), ip)
	}
	if s := fetchControlStatus("status"); !s.OK || !s.LoggedIn || s.BackendState != "Starting" {
		t.Fatal(s)
	}
	if p := onlinePeersCore(""); !p.OK || p.Count != 0 {
		t.Fatal("empty authorized tailnet must be ready", p)
	}
	_, original, _ := socketTun(t)
	if r := startVpnCore(dir, "test-starting", ip.String(), original); !r.OK {
		t.Fatal(r)
	}
	s := vpnStateCore()
	if !s.Connected || !s.Attached || !s.NetworkMapReady || s.AssignedIPv4 != ip.String() {
		t.Fatal(s)
	}
	if owner.lb.State() != ipn.Starting {
		t.Fatal("test accidentally established a relay")
	}
	if r := detachVpnCore(); !r.OK {
		t.Fatal(r)
	}
	if s := vpnStateCore(); s.Connected || !s.NetworkMapReady {
		t.Fatal(s)
	}
}
