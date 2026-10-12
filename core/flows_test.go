package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
	"tailscale.com/types/views"
)

type fakeWatcher struct {
	ctx    context.Context
	events []ipn.Notify
	err    error
	closed int
}

func (w *fakeWatcher) Next() (ipn.Notify, error) {
	if len(w.events) > 0 {
		n := w.events[0]
		w.events = w.events[1:]
		return n, nil
	}
	if w.err != nil {
		return ipn.Notify{}, w.err
	}
	<-w.ctx.Done()
	return ipn.Notify{}, w.ctx.Err()
}
func (w *fakeWatcher) Close() error { w.closed++; return nil }

type fakeClient struct {
	prefs                                            *ipn.Prefs
	prefsErr                                         error
	status                                           *ipnstate.Status
	statusErr, watchErr, startErr, logoutErr         error
	snapshotErr                                      error
	statusCalls, watchCalls, startCalls, logoutCalls int
	watcher                                          *fakeWatcher
	order                                            []string
	snapshotCtx                                      context.Context
}

func (c *fakeClient) GetPrefs(context.Context) (*ipn.Prefs, error) { return c.prefs, c.prefsErr }

func (c *fakeClient) Status(ctx context.Context) (*ipnstate.Status, error) {
	c.statusCalls++
	if c.statusCalls > 1 {
		c.snapshotCtx = ctx
		if c.snapshotErr != nil {
			return nil, c.snapshotErr
		}
	}
	return c.status, c.statusErr
}
func (c *fakeClient) WatchIPNBus(ctx context.Context, mask ipn.NotifyWatchOpt) (loginWatcher, error) {
	c.watchCalls++
	c.order = append(c.order, "watch")
	if mask != ipn.NotifyInitialState|ipn.NotifyNoPrivateKeys {
		panic("unsafe watcher flags")
	}
	if c.watchErr != nil {
		return nil, c.watchErr
	}
	c.watcher.ctx = ctx
	return c.watcher, nil
}
func (c *fakeClient) StartLoginInteractive(context.Context) error {
	c.startCalls++
	c.order = append(c.order, "login")
	return c.startErr
}
func (c *fakeClient) Logout(context.Context) error { c.logoutCalls++; return c.logoutErr }
func loginClient(events ...ipn.Notify) *fakeClient {
	return &fakeClient{status: &ipnstate.Status{BackendState: "NeedsLogin"}, watcher: &fakeWatcher{events: events}}
}
func ptr[T any](value T) *T { return &value }

func TestLoginEvents(t *testing.T) {
	cases := []struct {
		name       string
		events     []ipn.Notify
		ok, logged bool
		auth, err  string
	}{
		{"browse URL", []ipn.Notify{{BrowseToURL: ptr("https://login.tailscale.com/a/token")}}, true, false, "https://login.tailscale.com/a/token", ""},
		{"ignore empty and initial state", []ipn.Notify{{}, {State: ptr(ipn.NeedsLogin)}, {BrowseToURL: ptr("")}, {BrowseToURL: ptr("https://login.tailscale.com/a/token")}}, true, false, "https://login.tailscale.com/a/token", ""},
		{"backend error", []ipn.Notify{{ErrMessage: ptr("dial failed")}}, false, false, "", "dial failed"},
		{"error takes priority over URL", []ipn.Notify{{ErrMessage: ptr("denied"), BrowseToURL: ptr("https://login.tailscale.com/a/token")}}, false, false, "", "denied"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := loginClient(tc.events...)
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			r := runLogin(ctx, c, "started")
			if r.OK != tc.ok || r.AuthURL != tc.auth || r.LoggedIn != tc.logged || (tc.err != "" && !strings.Contains(r.Error, tc.err)) {
				t.Fatalf("result: %+v", r)
			}
			if c.watcher.closed != 1 {
				t.Fatalf("watcher not closed: %d", c.watcher.closed)
			}
			if strings.Join(c.order, ",") != "watch,login" {
				t.Fatalf("must subscribe before login: %v", c.order)
			}
			if !r.OK && len(r.DebugLogs) == 0 {
				t.Fatal("failure lacks diagnostics")
			}
		})
	}
}
func TestLoginAlreadyRunningOrExistingURL(t *testing.T) {
	for _, state := range []string{"Running", "NeedsLogin"} {
		t.Run(state, func(t *testing.T) {
			c := loginClient()
			c.status.BackendState = state
			if state == "NeedsLogin" {
				c.status.AuthURL = "https://login.tailscale.com/a/existing"
			}
			r := runLogin(context.Background(), c, "started")
			if !r.OK || c.startCalls != 0 || c.watchCalls != 0 {
				t.Fatalf("unnecessary login restart: %+v %+v", r, c)
			}
		})
	}
}
func TestLoginFaultsAndCleanup(t *testing.T) {
	for _, fault := range []string{"status", "watch", "request", "stream", "snapshot", "timeout", "canceled"} {
		t.Run(fault, func(t *testing.T) {
			c := loginClient(ipn.Notify{BrowseToURL: ptr("https://login.tailscale.com/a/new")})
			boom := errors.New("injected " + fault)
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
			defer cancel()
			switch fault {
			case "status":
				c.statusErr = boom
			case "watch":
				c.watchErr = boom
			case "request":
				c.startErr = boom
			case "stream":
				c.watcher.events = nil
				c.watcher.err = io.EOF
			case "snapshot":
				c.snapshotErr = boom
			case "timeout":
				c.watcher.events = nil
			case "canceled":
				c.watcher.events = nil
				cancel()
			}
			r := runLogin(ctx, c, "started")
			if r.OK || r.Error == "" {
				t.Fatalf("failure turned into success: %+v", r)
			}
			if fault != "status" && fault != "watch" && c.watcher.closed != 1 {
				t.Fatal("watcher leak")
			}
			if fault == "snapshot" && r.AuthURL == "" {
				t.Fatal("one-time URL lost on snapshot failure")
			}
			if fault == "timeout" || fault == "canceled" {
				if !strings.Contains(r.Error, "waiting for Tailscale login URL") {
					t.Fatal(r.Error)
				}
				if c.snapshotCtx == nil {
					t.Fatal("missing independent snapshot context")
				}
				if _, ok := c.snapshotCtx.Deadline(); !ok {
					t.Fatal("unbounded snapshot")
				}
			}
		})
	}
}
func TestLoginRunningNotification(t *testing.T) {
	c := loginClient(ipn.Notify{State: ptr(ipn.Running)})
	c.status.BackendState = "Running"
	// To test the event branch, provide an initial NeedsLogin and Running snapshot.
	client := &transitionClient{fakeClient: c}
	r := runLogin(context.Background(), client, "started")
	if !r.OK || !r.LoggedIn || c.watcher.closed != 1 {
		t.Fatalf("%+v", r)
	}
}

type transitionClient struct{ *fakeClient }

func (c *transitionClient) Status(ctx context.Context) (*ipnstate.Status, error) {
	if c.statusCalls == 0 {
		c.statusCalls++
		return &ipnstate.Status{BackendState: "NeedsLogin"}, nil
	}
	return c.fakeClient.Status(ctx)
}

type fakeBackend struct {
	client                        controlClient
	startErr, closeErr, clientErr error
	starts, closes                int
	onStart                       func()
}

func (b *fakeBackend) Start() error {
	b.starts++
	if b.onStart != nil {
		b.onStart()
	}
	return b.startErr
}
func (b *fakeBackend) Close() error                        { b.closes++; return b.closeErr }
func (b *fakeBackend) LocalClient() (controlClient, error) { return b.client, b.clientErr }
func setupBackend(t *testing.T, b *fakeBackend) {
	t.Helper()
	old := newBackend
	lifecycle.Lock()
	lifecycle.server = nil
	lifecycle.state = "idle"
	lifecycle.lastError = ""
	lifecycle.dataDir = ""
	lifecycle.hostname = ""
	lifecycle.Unlock()
	newBackend = func(string, string) backend { return b }
	t.Cleanup(func() {
		newBackend = old
		lifecycle.Lock()
		lifecycle.server = nil
		lifecycle.state = "idle"
		lifecycle.lastError = ""
		lifecycle.Unlock()
	})
}
func TestLifecycle(t *testing.T) {
	b := &fakeBackend{}
	setupBackend(t, b)
	dir := t.TempDir()
	if r := closeCore(); !r.OK {
		t.Fatal(r)
	}
	if r := startCore(dir, "test-host"); !r.OK || r.State != "started" {
		t.Fatal(r)
	}
	if r := startCore(dir, "test-host"); !r.OK || b.starts != 1 {
		t.Fatal(r)
	}
	if r := closeCore(); !r.OK || r.State != "closed" {
		t.Fatal(r)
	}
	if r := closeCore(); !r.OK || b.closes != 1 {
		t.Fatal(r)
	}
	if _, _, err := currentServer(); err == nil {
		t.Fatal("closed backend remained usable")
	}
	if r := startCore(dir, "test-host"); !r.OK || b.starts != 2 {
		t.Fatal(r)
	}
}
func TestLifecycleFaults(t *testing.T) {
	for _, fault := range []string{"start", "close", "storage"} {
		t.Run(fault, func(t *testing.T) {
			b := &fakeBackend{}
			setupBackend(t, b)
			dir := t.TempDir()
			if fault == "start" {
				b.startErr = errors.New("start failed")
			}
			if fault == "storage" {
				f := filepath.Join(dir, "file")
				if err := os.WriteFile(f, []byte("x"), 0600); err != nil {
					t.Fatal(err)
				}
				dir = filepath.Join(f, "child")
			}
			r := startCore(dir, "host")
			if fault != "close" {
				if r.OK || r.Error == "" {
					t.Fatal(r)
				}
				return
			}
			b.closeErr = errors.New("close failed")
			r = closeCore()
			if r.OK || r.State != "error" {
				t.Fatal(r)
			}
			b.closeErr = nil
			if r = closeCore(); !r.OK {
				t.Fatal(r)
			}
		})
	}
}
func TestStartCloseSerialized(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	b := &fakeBackend{onStart: func() { close(entered); <-release }}
	setupBackend(t, b)
	startDone := make(chan operationResult, 1)
	closeDone := make(chan operationResult, 1)
	closeEntered := make(chan struct{})
	dir := t.TempDir()
	go func() { startDone <- startCore(dir, "host") }()
	<-entered
	go func() { close(closeEntered); closeDone <- closeCore() }()
	<-closeEntered
	select {
	case <-closeDone:
		t.Fatal("Close overlapped Start")
	case <-time.After(20 * time.Millisecond):
	}
	close(release)
	if r := <-startDone; !r.OK {
		t.Fatal(r)
	}
	if r := <-closeDone; !r.OK || b.closes != 1 {
		t.Fatal(r)
	}
}
func TestValidateStartInput(t *testing.T) {
	for _, tc := range []struct {
		dir, host string
		valid     bool
	}{
		{"", "host", false}, {"relative", "host", false}, {"/state", "", false}, {"/state", "-host", false}, {"/state", "host-", false},
		{"/state", "host_name", false}, {"/state", "a\x00b", false}, {"/state", strings.Repeat("a", 64), false},
		{"/state", strings.Repeat("a", 63), true}, {"/state", "Host-123", true},
	} {
		t.Run(fmt.Sprintf("%q-%q", tc.dir, tc.host), func(t *testing.T) {
			if got := validateStartInput(tc.dir, tc.host) == nil; got != tc.valid {
				t.Fatalf("valid=%v want %v", got, tc.valid)
			}
		})
	}
}
func TestStatusAndLogoutFaults(t *testing.T) {
	for _, fault := range []string{"idle", "client", "status", "logout", "success"} {
		t.Run(fault, func(t *testing.T) {
			c := loginClient()
			b := &fakeBackend{client: c}
			setupBackend(t, b)
			if fault != "idle" {
				if r := startCore(t.TempDir(), "host"); !r.OK {
					t.Fatal(r)
				}
			}
			switch fault {
			case "client":
				b.clientErr = errors.New("client failed")
			case "status":
				c.statusErr = errors.New("status failed")
			case "logout":
				c.logoutErr = errors.New("logout failed")
			}
			r := logoutCore()
			if r.OK != (fault == "success") {
				t.Fatal(r)
			}
			s := fetchControlStatus("status")
			if s.OK != (fault == "success" || fault == "logout") {
				t.Fatal(s)
			}
		})
	}
}
func peerStatus() *ipnstate.Status {
	p1 := key.NewNode().Public()
	p2 := key.NewNode().Public()
	p3 := key.NewNode().Public()
	return &ipnstate.Status{BackendState: "Running", User: map[tailcfg.UserID]tailcfg.UserProfile{1: {LoginName: "alice@example.com", DisplayName: "Alice"}}, Peer: map[key.NodePublic]*ipnstate.PeerStatus{
		p1: {ID: "a", HostName: "z-host", DNSName: "z.ts.net.", Online: true, UserID: 1, TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.1")}, Tags: ptr(views.SliceOf([]string{"tag:server", "tag:ci"})), LastSeen: time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)},
		p2: {ID: "b", HostName: "alpha", Online: true, OS: "linux"},
		p3: {ID: "c", HostName: "offline", Online: false},
	}}
}
func TestOnlinePeersQueries(t *testing.T) {
	c := loginClient()
	c.status = peerStatus()
	b := &fakeBackend{client: c}
	setupBackend(t, b)
	if r := startCore(t.TempDir(), "host"); !r.OK {
		t.Fatal(r)
	}
	for _, tc := range []struct {
		filter string
		count  int
		ok     bool
	}{{"", 2, true}, {" TAG:SERVER ", 1, true}, {"user:Alice", 1, true}, {"z.ts", 1, true}, {"missing", 0, true}, {"group:dev", 0, false}} {
		r := onlinePeersCore(tc.filter)
		if r.OK != tc.ok || r.Count != tc.count || r.Peers == nil {
			t.Fatalf("%q: %+v", tc.filter, r)
		}
		if tc.filter == "" {
			if r.Peers[0].HostName != "alpha" || r.Peers[1].DNSName != "z.ts.net" || strings.Join(r.Peers[1].Tags, ",") != "tag:ci,tag:server" {
				t.Fatal(r)
			}
		}
	}
	c.status.BackendState = "NeedsLogin"
	if r := onlinePeersCore(""); r.OK || r.Error == "" {
		t.Fatal(r)
	}
	c.statusErr = errors.New("dial error")
	if r := onlinePeersCore(""); r.OK || !strings.Contains(r.Error, "dial error") {
		t.Fatal(r)
	}
	b.clientErr = errors.New("local error")
	if r := onlinePeersCore(""); r.OK || !strings.Contains(r.Error, "local error") {
		t.Fatal(r)
	}
	closeCore()
	if r := onlinePeersCore(""); r.OK {
		t.Fatal(r)
	}
}
func TestLogsBoundedSanitizedAndSnapshotOwned(t *testing.T) {
	logs.Lock()
	old := logs.lines
	logs.lines = nil
	logs.Unlock()
	t.Cleanup(func() { logs.Lock(); logs.lines = old; logs.Unlock() })
	bridgeLogf("before\x00after https://login.tailscale.com/a/private")
	got := recentLogLines(1)
	if len(got) != 1 || strings.ContainsRune(got[0], 0) || strings.Contains(got[0], "private") || !strings.Contains(got[0], "after") {
		t.Fatal(got)
	}
	got[0] = "mutated"
	if recentLogLines(1)[0] == "mutated" {
		t.Fatal("snapshot aliases buffer")
	}
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for n := 0; n < 100; n++ {
				appendLog("line %d", n)
				recentLogLines(24)
			}
		}()
	}
	wg.Wait()
	if got := recentLogLines(1000); len(got) != maxLogLines {
		t.Fatal(len(got))
	}
	if recentLogLines(0) != nil {
		t.Fatal("zero limit")
	}
}
func TestStorageProbe(t *testing.T) {
	dir := t.TempDir()
	if r := probeStorage(dir); !r.OK {
		t.Fatal(r)
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 0 {
		t.Fatalf("probe leaked files: %v %v", entries, err)
	}
	for _, dir := range []string{"", "relative"} {
		if r := probeStorage(dir); r.OK {
			t.Fatal(r)
		}
	}
}
func TestLoopbackProbes(t *testing.T) {
	if r := probeTCP(); !r.OK {
		t.Fatal(r)
	}
	if r := probeUDP(); !r.OK {
		t.Fatal(r)
	}
}
