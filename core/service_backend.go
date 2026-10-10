package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"sync"
	"time"

	"golang.org/x/sys/unix"
	"tailscale.com/client/local"
	"tailscale.com/control/controlclient"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnauth"
	"tailscale.com/ipn/ipnlocal"
	"tailscale.com/ipn/localapi"
	"tailscale.com/ipn/store"
	"tailscale.com/net/netmon"
	"tailscale.com/net/tsdial"
	"tailscale.com/tsd"
	"tailscale.com/types/logid"
	"tailscale.com/wgengine"
	"tailscale.com/wgengine/router"
)

// The lifetime lock is shared by UI tsnet and the VPN extension. The private
// Unix LocalAPI is served only by the VPN owner; UI clients never open its state.
func serviceSocket(dir string) string { return filepath.Join(dir, "vpn.sock") }

type stateLease struct{ fd int }

func acquireStateLease(dir string) (*stateLease, error) {
	fd, err := unix.Open(filepath.Join(dir, "core.lock"), unix.O_CREAT|unix.O_RDWR|unix.O_CLOEXEC, 0600)
	if err != nil {
		return nil, err
	}
	if err = unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("another core owns this login state: %w", err)
	}
	return &stateLease{fd}, nil
}
func (l *stateLease) Close() error {
	if l == nil || l.fd < 0 {
		return nil
	}
	err := unix.Close(l.fd)
	l.fd = -1
	return err
}

type leasedBackend struct {
	backend
	dir     string
	lease   *stateLease
	entered bool
	closed  bool
}

func (b *leasedBackend) Start() error {
	l, err := acquireStateLease(b.dir)
	if err != nil {
		return err
	}
	b.lease = l
	b.entered = true
	if err = b.backend.Start(); err != nil {
		if cleanupErr := b.Close(); cleanupErr != nil {
			return fmt.Errorf("start: %v; cleanup: %w", err, cleanupErr)
		}
		return err
	}
	return nil
}
func (b *leasedBackend) Close() error {
	if b.closed {
		return nil
	}
	if b.entered {
		if err := b.backend.Close(); err != nil {
			return err
		}
	}
	err := b.lease.Close()
	b.closed = true
	return err
}

type vpnState struct {
	OK        bool     `json:"ok"`
	Connected bool     `json:"connected"`
	State     string   `json:"state"`
	IPv4      string   `json:"ipv4"`
	TxPackets uint64   `json:"txPackets"`
	RxPackets uint64   `json:"rxPackets"`
	TxBytes   uint64   `json:"txBytes"`
	RxBytes   uint64   `json:"rxBytes"`
	Error     string   `json:"error"`
	DebugLogs []string `json:"debugLogs,omitempty"`
}
type vpnStateProvider interface {
	VPNState(context.Context) vpnState
}
type remoteBackend struct {
	client     *local.Client
	httpClient *http.Client
}

func remoteService(dir string) *remoteBackend {
	path := serviceSocket(dir)
	dial := func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", path)
	}
	return &remoteBackend{client: &local.Client{Dial: dial}, httpClient: &http.Client{Transport: &http.Transport{DialContext: dial}, Timeout: 3 * time.Second}}
}
func (b *remoteBackend) Start() error {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_, err := b.client.Status(ctx)
	return err
}
func (b *remoteBackend) Close() error                        { b.httpClient.CloseIdleConnections(); return nil }
func (b *remoteBackend) LocalClient() (controlClient, error) { return localAdapter{b.client}, nil }
func (b *remoteBackend) VPNState(ctx context.Context) vpnState {
	req, err := http.NewRequestWithContext(ctx, "GET", "http://local-tailscaled.sock/harmony/vpn", nil)
	if err != nil {
		return vpnState{State: "error", Error: err.Error()}
	}
	response, err := b.httpClient.Do(req)
	if err != nil {
		return vpnState{State: "error", Error: err.Error()}
	}
	defer response.Body.Close()
	var result vpnState
	if err = json.NewDecoder(response.Body).Decode(&result); err != nil || response.StatusCode != 200 {
		return vpnState{State: "error", Error: fmt.Sprintf("invalid VPN service response: %v", err)}
	}
	return result
}

// ArkTS installs the fixed IPv4 Tailnet route with the assigned /32. This
// configurator never invokes Linux netlink/iptables or installs a default route.
// Address changes fail closed: the interface must be recreated before use.
type platformRouter struct {
	address netip.Addr
	mu      sync.Mutex
	err     string
}

func (r *platformRouter) Up() error                                { return nil }
func (r *platformRouter) Close() error                             { return nil }
func (r *platformRouter) UpdateMagicsockPort(uint16, string) error { return nil }
func (r *platformRouter) Set(c *router.Config) error {
	if c == nil {
		return nil
	}
	for _, prefix := range c.LocalAddrs {
		if prefix.Addr().Is4() && prefix.Addr() != r.address {
			err := fmt.Errorf("Tailnet address changed; reconnect VPN")
			r.mu.Lock()
			r.err = err.Error()
			r.mu.Unlock()
			return err
		}
	}
	return nil
}

type serviceBackend struct {
	dir, hostname, address string
	tun                    *packetTun
	lease                  *stateLease
	sys                    *tsd.System
	lb                     *ipnlocal.LocalBackend
	router                 *platformRouter
	api                    *http.Server
	listener               net.Listener
	client                 *local.Client
	once                   sync.Once
	closeErr               error
}

func (b *serviceBackend) Start() (err error) {
	defer func() {
		if err != nil {
			b.Close()
		}
	}()
	b.lease, err = acquireStateLease(b.dir)
	if err != nil {
		return err
	}
	sys := tsd.NewSystem()
	b.sys = sys
	mon, err := netmon.New(sys.Bus.Get(), bridgeLogf)
	if err != nil {
		return err
	}
	sys.Set(mon)
	dialer := &tsdial.Dialer{Logf: bridgeLogf}
	b.router = &platformRouter{address: netip.MustParseAddr(b.address)}
	engine, err := wgengine.NewUserspaceEngine(bridgeLogf, wgengine.Config{
		Tun: b.tun, Router: b.router, NetMon: mon, Dialer: dialer, EventBus: sys.Bus.Get(),
		SetSubsystem: sys.Set, ControlKnobs: sys.ControlKnobs(), HealthTracker: sys.HealthTracker(), Metrics: sys.UserMetricsRegistry(),
	})
	if err != nil {
		return err
	}
	sys.Set(engine)
	stateStore, err := store.New(bridgeLogf, filepath.Join(b.dir, "tailscaled.state"))
	if err != nil {
		return err
	}
	sys.Set(stateStore)
	b.lb, err = ipnlocal.NewLocalBackend(bridgeLogf, logid.PublicID{}, sys, controlclient.LocalBackendStartKeyOSNeutral)
	if err != nil {
		return err
	}
	b.lb.SetVarRoot(b.dir)
	prefs := ipn.NewPrefs()
	prefs.Hostname = b.hostname
	prefs.WantRunning = true
	prefs.CorpDNS = false
	prefs.RouteAll = false
	if err = b.lb.Start(ipn.Options{UpdatePrefs: prefs}); err != nil {
		return err
	}
	sys.Tun.Get().Start()
	path := serviceSocket(b.dir)
	// Safe only under the state lease. A crashed owner may leave a socket name.
	if err = os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	b.listener, err = net.Listen("unix", path)
	if err != nil {
		return err
	}
	if err = os.Chmod(path, 0600); err != nil {
		return err
	}
	handler := localapi.NewHandler(ipnauth.Self, b.lb, bridgeLogf, logid.PublicID{})
	handler.PermitRead = true
	handler.PermitWrite = true
	mux := http.NewServeMux()
	mux.HandleFunc("/harmony/vpn", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(b.VPNState(r.Context()))
	})
	mux.Handle("/", handler)
	b.api = &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	b.client = remoteService(b.dir).client
	go func() {
		if e := b.api.Serve(b.listener); e != nil && e != http.ErrServerClosed {
			appendLog("VPN LocalAPI: %v", e)
		}
	}()
	return nil
}
func (b *serviceBackend) LocalClient() (controlClient, error) {
	if b.client == nil {
		return nil, fmt.Errorf("VPN core not started")
	}
	return localAdapter{b.client}, nil
}
func (b *serviceBackend) VPNState(context.Context) vpnState {
	s := vpnState{OK: true, State: "connecting", IPv4: b.address}
	s.DebugLogs = recentLogLines(24)
	if b.tun == nil {
		return s
	}
	s.TxPackets = b.tun.txPackets.Load()
	s.RxPackets = b.tun.rxPackets.Load()
	s.TxBytes = b.tun.txBytes.Load()
	s.RxBytes = b.tun.rxBytes.Load()
	b.tun.errMu.Lock()
	s.Error = b.tun.lastError
	b.tun.errMu.Unlock()
	if b.router != nil {
		b.router.mu.Lock()
		if b.router.err != "" {
			s.Error = b.router.err
		}
		b.router.mu.Unlock()
	}
	select {
	case <-b.tun.done:
		s.State = "disconnected"
		return s
	default:
	}
	if s.Error != "" {
		s.OK = false
		s.State = "error"
		return s
	}
	if b.lb != nil && b.lb.State() == ipn.Running {
		s.Connected = true
		s.State = "connected"
	}
	return s
}
func (b *serviceBackend) Close() error {
	b.once.Do(func() {
		// LocalBackend owns and joins the engine. Closing TUN first wakes reads.
		if b.tun != nil {
			b.closeErr = b.tun.Close()
		}
		if b.api != nil {
			b.api.Close()
		}
		if b.listener != nil {
			b.listener.Close()
		}
		if b.lb != nil {
			b.lb.Shutdown()
		} else if b.sys != nil {
			if engine, ok := b.sys.Engine.GetOK(); ok {
				engine.Close()
				<-engine.Done()
			}
		}
		if b.sys != nil {
			if dialer, ok := b.sys.Dialer.GetOK(); ok {
				dialer.Close()
			}
			if mon, ok := b.sys.NetMon.GetOK(); ok {
				mon.Close()
			}
		}
		b.lease.Close()
		if b.sys != nil {
			b.sys.Bus.Get().Close()
		}
	})
	return b.closeErr
}
