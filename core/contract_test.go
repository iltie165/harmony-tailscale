package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"tailscale.com/ipn/ipnstate"
)

func TestJSONErrorEncoding(t *testing.T) {
	for _, value := range []any{make(chan int), errors.New("example"), map[string]string{"nul": "before\x00after", "utf8": "中文"}} {
		result := encodeJSON(value)
		if !json.Valid(result) || strings.ContainsRune(string(result), 0) {
			t.Fatalf("invalid C ABI JSON: %q", result)
		}
	}
}
func TestNilStatusIsAnError(t *testing.T) {
	if r := controlStatus("status", "started", nil, nil); r.OK || r.Error == "" {
		t.Fatal(r)
	}
	c := loginClient()
	c.status = nil
	if r := runLogin(context.Background(), c, "started"); r.OK || r.Error == "" {
		t.Fatal(r)
	}
	b := &fakeBackend{client: c}
	setupBackend(t, b)
	startCore(t.TempDir(), "host")
	if r := onlinePeersCore(""); r.OK {
		t.Fatal(r)
	}
}
func TestLogsRedactEveryEntryPoint(t *testing.T) {
	appendLog("error: https://login.tailscale.com/a/secret1\x00 latest")
	bridgeLogf("auth: https://login.tailscale.com/a/secret2 https://login.tailscale.com/a/secret3")
	result := strings.Join(recentLogLines(2), "\n")
	if strings.Contains(result, "secret") || strings.ContainsRune(result, 0) || !strings.Contains(result, "latest") {
		t.Fatal(result)
	}
}

type fakeHTTP struct {
	response *http.Response
	err      error
	request  *http.Request
}

func (c *fakeHTTP) Do(request *http.Request) (*http.Response, error) {
	c.request = request
	return c.response, c.err
}

type trackedBody struct {
	io.Reader
	closed bool
}

func (b *trackedBody) Close() error { b.closed = true; return nil }
func TestHTTPSProbeFailureAndBodyOwnership(t *testing.T) {
	for _, code := range []int{200, 204, 401, 500} {
		t.Run(http.StatusText(code), func(t *testing.T) {
			body := &trackedBody{Reader: strings.NewReader("test")}
			c := &fakeHTTP{response: &http.Response{StatusCode: code, Status: http.StatusText(code), Body: body}}
			r := probeHTTPS(context.Background(), c, "https://controlplane.tailscale.com/key?v=123")
			if r.OK != (code < 300) || !body.closed || c.request.URL.RawQuery != "v=123" {
				t.Fatal(r)
			}
		})
	}
	c := &fakeHTTP{err: errors.New("TLS failed")}
	if r := probeHTTPS(context.Background(), c, "https://host"); r.OK || !strings.Contains(r.Error, "TLS failed") {
		t.Fatal(r)
	}
	if r := probeHTTPS(context.Background(), c, ":bad-url"); r.OK {
		t.Fatal(r)
	}
}

// Generate real Go response fixtures and let the UI decoder consume them in the
// same CI run. A hand-written JS mock alone cannot detect producer schema drift.
func TestWriteUIContracts(t *testing.T) {
	dir := os.Getenv("HARMONY_CONTRACT_DIR")
	if dir == "" {
		t.Skip("contract output not requested")
	}
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	s := peerStatus()
	c := loginClient()
	c.status = s
	b := &fakeBackend{client: c}
	setupBackend(t, b)
	startCore(t.TempDir(), "host")
	cases := map[string]any{
		"running": controlStatus("status", "started", s, nil),
		"peers":   onlinePeersCore(""), "emptyPeers": onlinePeersCore("missing"),
		"statusFailure": controlStatus("status", "started", nil, errors.New("control unavailable")),
		"groupFailure":  onlinePeersCore("group:dev"),
		"started":       stateResult("start"), "closed": closeCore(),
	}
	for name, result := range cases {
		if err := os.WriteFile(filepath.Join(dir, name+".json"), encodeJSON(result), 0644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestControlStatusMetadataAndOwnership(t *testing.T) {
	s := peerStatus()
	for _, peer := range s.Peer {
		if peer.Online && peer.UserID == 1 {
			s.Self = peer
			break
		}
	}
	s.AuthURL = "https://login.tailscale.com/a/current"
	s.Health = []string{"sample warning"}
	s.TailscaleIPs = []netip.Addr{netip.MustParseAddr("100.64.0.1")}
	s.CurrentTailnet = &ipnstate.TailnetStatus{Name: "example", MagicDNSSuffix: "example.ts.net", MagicDNSEnabled: true}
	r := controlStatus("status", "started", s, nil)
	if !r.OK || !r.LoggedIn || r.Self == nil || r.Self.UserLogin != "alice@example.com" || r.Tailnet == nil || !r.Tailnet.MagicDNSEnabled || r.AuthURL != s.AuthURL || len(r.TailscaleIPs) != 1 {
		t.Fatalf("%+v", r)
	}
	r.Health[0] = "changed"
	if s.Health[0] == "changed" {
		t.Fatal("status aliases health slice")
	}
}

func TestDiagnosticsOrchestration(t *testing.T) {
	pass := func() checkResult { return checkResult{OK: true, Detail: "mock success"} }
	fail := func() checkResult { return checkResult{Error: "mock denied"} }
	for _, fault := range []string{"none", "storage", "tcp", "udp", "dns", "control", "route", "monitor", "interfaces"} {
		t.Run(fault, func(t *testing.T) {
			p := diagnosticProbes{storage: func(string) checkResult { return pass() }, tcp: pass, udp: pass, dns: pass, control: pass, route: pass, monitor: pass, interfaces: func() ([]interfaceInfo, error) { return []interfaceInfo{{Name: "mock0"}}, nil }}
			switch fault {
			case "storage":
				p.storage = func(string) checkResult { return fail() }
			case "tcp":
				p.tcp = fail
			case "udp":
				p.udp = fail
			case "dns":
				p.dns = fail
			case "control":
				p.control = fail
			case "route":
				p.route = fail
			case "monitor":
				p.monitor = fail
			case "interfaces":
				p.interfaces = func() ([]interfaceInfo, error) { return nil, errors.New("interfaces denied") }
			}
			r := runDiagnostics("/private/state", p)
			if r.OK != (fault == "none" || fault == "route") {
				t.Fatalf("%+v", r)
			}
			if fault == "route" && r.DefaultRoute.Error != "mock denied" {
				t.Fatal("unsupported route hidden")
			}
			if fault == "interfaces" && r.Error == "" {
				t.Fatal("enumeration error missing")
			}
		})
	}
}
