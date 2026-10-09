package main

import (
	"testing"

	"tailscale.com/net/netmon"
	"tailscale.com/net/netns"
	"tailscale.com/types/logger"
)

func TestPlatformAdapterDisablesNetNS(t *testing.T) {
	listener := netns.Listener(logger.Discard, netmon.NewStatic())
	if listener.Control != nil {
		t.Fatal("netns socket control is enabled; HarmonyOS control traffic can be bound to loopback")
	}
}

func TestPeerMatchesFilter(t *testing.T) {
	peer := peerInfo{
		HostName:  "build-server",
		DNSName:   "build-server.example.ts.net",
		UserLogin: "alice@example.com",
		UserName:  "Alice",
		Tags:      []string{"tag:server", "tag:ci"},
	}
	tests := []struct {
		filter string
		want   bool
	}{
		{"", true},
		{"tag:server", true},
		{"TAG:SERVER", true},
		{"tag:desktop", false},
		{"user:alice@example.com", true},
		{"user:Alice", true},
		{"build", true},
		{"missing", false},
	}
	for _, test := range tests {
		if got := peerMatchesFilter(peer, test.filter); got != test.want {
			t.Errorf("peerMatchesFilter(%q) = %v, want %v", test.filter, got, test.want)
		}
	}
}

func TestFilterKind(t *testing.T) {
	tests := map[string]string{
		"":               "all",
		"tag:server":     "tag",
		"user:alice":     "user",
		"group:platform": "acl-group",
		"hostname":       "text",
	}
	for filter, want := range tests {
		if got := filterKind(filter); got != want {
			t.Errorf("filterKind(%q) = %q, want %q", filter, got, want)
		}
	}
}

func TestRedactLoginURLs(t *testing.T) {
	input := "To authenticate, visit https://login.tailscale.com/a/secret-token now"
	want := "To authenticate, visit [REDACTED_TAILSCALE_LOGIN_URL] now"
	if got := redactLoginURLs(input); got != want {
		t.Fatalf("redactLoginURLs() = %q, want %q", got, want)
	}
}

func TestSanitizeLogLineEscapesNUL(t *testing.T) {
	input := "before\x00after"
	want := `before\x00after`
	if got := sanitizeLogLine(input); got != want {
		t.Fatalf("sanitizeLogLine() = %q, want %q", got, want)
	}
}
