package main

import (
	"context"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
)

// These ports describe only the upstream operations used by our client.
// Tests inject fakes here; production always delegates to pinned Tailscale.
type loginWatcher interface {
	Next() (ipn.Notify, error)
	Close() error
}
type controlClient interface {
	Status(context.Context) (*ipnstate.Status, error)
	WatchIPNBus(context.Context, ipn.NotifyWatchOpt) (loginWatcher, error)
	StartLoginInteractive(context.Context) error
	Logout(context.Context) error
}
type backend interface {
	Start() error
	Close() error
	LocalClient() (controlClient, error)
}
type tsnetBackend struct{ *tsnet.Server }
type localAdapter struct{ *local.Client }

func (b tsnetBackend) LocalClient() (controlClient, error) {
	c, err := b.Server.LocalClient()
	if err != nil {
		return nil, err
	}
	return localAdapter{c}, nil
}
func (c localAdapter) WatchIPNBus(ctx context.Context, mask ipn.NotifyWatchOpt) (loginWatcher, error) {
	return c.Client.WatchIPNBus(ctx, mask)
}

// Only replaced in serialized unit tests. No test hooks are exported in the ABI.
var newBackend = func(dir, hostname string) backend {
	return tsnetBackend{&tsnet.Server{Dir: dir, Hostname: hostname, Logf: bridgeLogf, UserLogf: bridgeLogf}}
}
