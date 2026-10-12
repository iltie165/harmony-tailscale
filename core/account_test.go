package main

import (
	"context"
	"testing"
	"time"

	"tailscale.com/ipn/ipnstate"
)

type waitingAccountClient struct {
	*fakeClient
	entered chan struct{}
}

func (c waitingAccountClient) Status(ctx context.Context) (*ipnstate.Status, error) {
	close(c.entered)
	<-ctx.Done()
	return nil, ctx.Err()
}

func TestMutationCancelsNativeSlowDeviceQueryBeforeClosingCore(t *testing.T) {
	c := waitingAccountClient{fakeClient: &fakeClient{}, entered: make(chan struct{})}
	b := &fakeBackend{client: c}
	setupBackend(t, b)
	if r := startCore(t.TempDir(), "test"); !r.OK {
		t.Fatal(r)
	}
	query := make(chan onlinePeersResult, 1)
	go func() { query <- onlinePeersCore("") }()
	<-c.entered
	closed := make(chan operationResult, 1)
	go func() { closed <- closeCore() }()
	select {
	case result := <-closed:
		if !result.OK || b.closes != 1 {
			t.Fatal(result, b.closes)
		}
	case <-time.After(time.Second):
		t.Fatal("OFF/shutdown waited for the slow query deadline")
	}
	if result := <-query; result.OK || result.Error != context.Canceled.Error() {
		t.Fatal(result)
	}
}

func TestAccountReleaseCannotCloseAnExtensionOwnerOrProxy(t *testing.T) {
	setupBackend(t, &fakeBackend{})
	owner := &serviceBackend{coreID: "owner"}
	lifecycle.Lock()
	lifecycle.server = owner
	lifecycle.state = "started"
	lifecycle.Unlock()
	if r := releaseAccountCore(); !r.OK {
		t.Fatal(r)
	}
	server, _, _ := currentServer()
	if server != owner {
		t.Fatal("account release replaced the VPN owner")
	}
	proxy := remoteService(t.TempDir())
	lifecycle.Lock()
	lifecycle.server = proxy
	lifecycle.Unlock()
	if r := releaseAccountCore(); !r.OK {
		t.Fatal(r)
	}
	server, _, _ = currentServer()
	if server != proxy {
		t.Fatal("account release closed the VPN client")
	}
}

func TestAccountStartupRetryCannotStealLeaseButSucceedsAfterOwnerRelease(t *testing.T) {
	setupBackend(t, &fakeBackend{})
	dir := t.TempDir()
	lease, err := acquireStateLease(dir)
	if err != nil {
		t.Fatal(err)
	}
	if r := startAccountCore(dir, "account-retry"); r.OK {
		t.Fatal("stole another writer's state", r)
	}
	lease.Close()
	if r := startAccountCore(dir, "account-retry"); !r.OK {
		t.Fatal("failed bootstrap poisoned account retry", r)
	}
	defer closeCore()
	if state := vpnStateCore(); !state.CoreAlive || state.CoreHost != "account" || state.Attached {
		t.Fatal(state)
	}
}
