package main

import (
	"context"
	"net"
	"time"

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

func (b tsnetBackend) Start() error {
	if err := b.Server.Start(); err != nil {
		return err
	}
	client, err := b.Server.LocalClient()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// No system DNS integration in this Alpha. Do not request split DNS from
	// the Linux/no-op configurator even in discovery-only mode.
	_, err = client.EditPrefs(ctx, &ipn.MaskedPrefs{Prefs: ipn.Prefs{CorpDNS: false}, CorpDNSSet: true})
	return err
}

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
	if conn, err := net.DialTimeout("unix", serviceSocket(dir), time.Second); err == nil {
		conn.Close()
		return remoteService(dir)
	}
	return &leasedBackend{backend: tsnetBackend{&tsnet.Server{Dir: dir, Hostname: hostname, Logf: bridgeLogf, UserLogf: bridgeLogf}}, dir: dir}
}
