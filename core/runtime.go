package main

import (
	"fmt"
	"sync"

	"tailscale.com/net/netns"
)

func init() {
	// OpenHarmony selects Tailscale's Linux compatibility files. The Linux
	// netns dialer falls back to SO_BINDTODEVICE("lo") when route discovery is
	// unavailable, which traps control and log traffic on HarmonyOS. tsnet uses
	// userspace networking in legacy discovery mode. The product service boots
	// detached, then calls protectProcessNet before attaching a real vNIC. Keep that platform
	// transport exclusion instead of invoking Linux netlink/socket controls.
	netns.SetEnabled(false)
}

var lifecycle = struct {
	sync.RWMutex
	server    backend
	state     string
	dataDir   string
	hostname  string
	lastError string
}{state: "idle"}

// tsnet documents that Close must not run before or concurrently with Start.
var operationMu sync.RWMutex

var logs = struct {
	sync.Mutex
	lines []string
}{}

func stateResult(operation string) operationResult {
	lifecycle.RLock()
	defer lifecycle.RUnlock()
	return operationResult{
		OK:        lifecycle.state == "started" || lifecycle.state == "closed" || lifecycle.state == "idle",
		Operation: operation,
		State:     lifecycle.state,
		Error:     lifecycle.lastError,
		DataDir:   lifecycle.dataDir,
		Hostname:  lifecycle.hostname,
	}
}

func currentServer() (backend, string, error) {
	lifecycle.RLock()
	defer lifecycle.RUnlock()
	if lifecycle.server == nil || lifecycle.state == "idle" || lifecycle.state == "closed" {
		return nil, lifecycle.state, fmt.Errorf("tsnet server is not initialized")
	}
	return lifecycle.server, lifecycle.state, nil
}
