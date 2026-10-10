package main

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
)

// Exercise the real pinned LocalClient and real streaming JSON watcher with an
// in-process HTTP fake. Only the daemon boundary is mocked, not its Go client.
func TestLocalAPIStreamingIntegration(t *testing.T) {
	for _, scenario := range []string{"url", "backendError", "brokenStream", "timeout", "httpError"} {
		t.Run(scenario, func(t *testing.T) {
			login := make(chan struct{})
			closed := make(chan struct{}, 1)
			var calls atomic.Int32
			daemon := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/localapi/v0/status":
					json.NewEncoder(w).Encode(&ipnstate.Status{BackendState: "NeedsLogin"})
				case "/localapi/v0/watch-ipn-bus":
					defer func() { closed <- struct{}{} }()
					if scenario == "httpError" {
						http.Error(w, "watch unavailable", 503)
						return
					}
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(200)
					w.(http.Flusher).Flush()
					select {
					case <-login:
					case <-r.Context().Done():
						return
					}
					switch scenario {
					case "url":
						json.NewEncoder(w).Encode(ipn.Notify{BrowseToURL: ptr("https://login.tailscale.com/a/integration")})
					case "backendError":
						json.NewEncoder(w).Encode(ipn.Notify{ErrMessage: ptr("control blocked")})
					case "brokenStream":
						w.Write([]byte("{broken\n"))
					}
					w.(http.Flusher).Flush()
					<-r.Context().Done()
				case "/localapi/v0/login-interactive":
					if r.Method != "POST" {
						t.Errorf("method=%s", r.Method)
					}
					calls.Add(1)
					close(login)
					w.WriteHeader(204)
				default:
					http.NotFound(w, r)
				}
			}))
			defer daemon.Close()
			transport := &http.Transport{DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "tcp", daemon.Listener.Addr().String())
			}}
			defer transport.CloseIdleConnections()
			adapter := localAdapter{&local.Client{Transport: transport, OmitAuth: true}}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			if scenario == "timeout" {
				cancel()
				ctx, cancel = context.WithTimeout(context.Background(), 50*time.Millisecond)
				defer cancel()
			}
			result := runLogin(ctx, adapter, "started")
			if result.OK != (scenario == "url") {
				t.Fatalf("%+v", result)
			}
			if scenario == "url" && !strings.HasSuffix(result.AuthURL, "/integration") {
				t.Fatal(result)
			}
			if scenario != "httpError" && calls.Load() != 1 {
				t.Fatalf("login calls=%d", calls.Load())
			}
			select {
			case <-closed:
			case <-time.After(time.Second):
				t.Fatal("watch response body leaked")
			}
		})
	}
}
