package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"unsafe"

	"tailscale.com/ipn/ipnstate"
)

// Inspect and release actual C-owned buffers from the exported functions. The
// independent Python/Node lanes also load a compiled .so across process APIs.
func consumeOwned(t *testing.T, p unsafe.Pointer) string {
	t.Helper()
	if p == nil {
		t.Fatal("nil ABI buffer")
	}
	defer tailscale_ohos_string_free(p)
	result := []byte{}
	for offset := 0; offset < 1<<20; offset++ {
		b := *(*byte)(unsafe.Add(p, offset))
		if b == 0 {
			return string(result)
		}
		result = append(result, b)
	}
	t.Fatal("unterminated C string")
	return ""
}
func jsonOwned(t *testing.T, p unsafe.Pointer) map[string]any {
	t.Helper()
	raw := consumeOwned(t, p)
	var result map[string]any
	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		t.Fatalf("invalid JSON %q: %v", raw, err)
	}
	return result
}
func TestExportedIdleABI(t *testing.T) {
	setupBackend(t, &fakeBackend{})
	if tailscale_ohos_abi_version() != 3 || tailscale_ohos_core_probe() != 1 {
		t.Fatal("ABI version/core mismatch")
	}
	if consumeOwned(t, unsafe.Pointer(tailscale_ohos_version())) == "" || consumeOwned(t, unsafe.Pointer(tailscale_ohos_go_version())) == "" {
		t.Fatal("missing versions")
	}
	results := []map[string]any{
		jsonOwned(t, unsafe.Pointer(tailscale_ohos_start(nil, nil))),
		jsonOwned(t, unsafe.Pointer(tailscale_ohos_status())),
		jsonOwned(t, unsafe.Pointer(tailscale_ohos_login())),
		jsonOwned(t, unsafe.Pointer(tailscale_ohos_logout())),
		jsonOwned(t, unsafe.Pointer(tailscale_ohos_online_peers(nil))),
	}
	for _, r := range results {
		if r["ok"] != false {
			t.Fatal(r)
		}
	}
	if jsonOwned(t, unsafe.Pointer(tailscale_ohos_close()))["ok"] != true {
		t.Fatal("idle close failed")
	}
	tailscale_ohos_string_free(nil)
	appendLog("prefix\x00suffix latest")
	text := consumeOwned(t, unsafe.Pointer(tailscale_ohos_logs()))
	if !strings.Contains(text, `prefix\x00suffix latest`) {
		t.Fatal("C string lost its suffix")
	}
	if jsonOwned(t, unsafe.Pointer(cJSON(make(chan int))))["ok"] != false {
		t.Fatal("marshal failure")
	}
}

type panicBackend struct{ *fakeBackend }

func (b panicBackend) Close() error { panic("injected close panic") }

type panicClient struct{ *fakeClient }

func (c panicClient) Status(_context context.Context) (*ipnstate.Status, error) {
	panic("injected status panic")
}
func TestPanicRecoveredAtABIBoundary(t *testing.T) {
	for _, operation := range []string{"close", "status", "login"} {
		t.Run(operation, func(t *testing.T) {
			b := &fakeBackend{client: panicClient{loginClient()}}
			setupBackend(t, b)
			startCore(t.TempDir(), "host")
			var p unsafe.Pointer
			switch operation {
			case "close":
				lifecycle.Lock()
				lifecycle.server = panicBackend{b}
				lifecycle.Unlock()
				p = unsafe.Pointer(tailscale_ohos_close())
			case "status":
				p = unsafe.Pointer(tailscale_ohos_status())
			case "login":
				p = unsafe.Pointer(tailscale_ohos_login())
			}
			result := jsonOwned(t, p)
			if result["ok"] != false || result["state"] != "panic" || !strings.Contains(result["error"].(string), "injected") {
				t.Fatal(result)
			}
			if !strings.Contains(consumeOwned(t, unsafe.Pointer(tailscale_ohos_logs())), "injected") {
				t.Fatal("panic evidence missing")
			}
			if operation == "close" && stateResult("status").State != "panic" {
				t.Fatal("lifecycle panic state missing")
			}
		})
	}
}
