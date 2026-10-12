package main

import (
	"context"
	"net"
	"time"
)

// Account hosting is explicit, permission-free and uses the same official
// backend/profile as the extension. The shared lease prevents two writers.
func startAccountCore(dir, hostname string) operationResult {
	lockMutation()
	defer operationMu.Unlock()
	if err := validateStartInput(dir, hostname); err != nil {
		return operationResult{Operation: "startAccount", State: "error", Error: err.Error()}
	}
	lifecycle.RLock()
	server, state := lifecycle.server, lifecycle.state
	lifecycle.RUnlock()
	if server != nil && state == "started" {
		if proxy, ok := server.(*remoteBackend); ok {
			if err := proxy.Start(); err == nil {
				return operationResult{OK: true, Operation: "startAccount", State: state, Message: "existing VPN client reused"}
			}
			state = "error"
		} else if owner, ok := server.(*serviceBackend); ok {
			if owner.VPNState(context.Background()).CoreAlive {
				return operationResult{OK: true, Operation: "startAccount", State: state, Message: "existing account host reused"}
			}
			if !owner.foreground {
				return operationResult{Operation: "startAccount", State: "error", Error: "VPN core requires explicit recovery"}
			}
			if err := owner.Close(); err != nil {
				return operationResult{Operation: "startAccount", State: "error", Error: err.Error()}
			}
			lifecycle.Lock()
			lifecycle.server = nil
			lifecycle.state = "closed"
			lifecycle.Unlock()
		}
	}
	if _, proxy := server.(*remoteBackend); proxy && state == "error" {
		server.Close()
		lifecycle.Lock()
		lifecycle.server = nil
		lifecycle.state = "closed"
		lifecycle.Unlock()
	}
	// A failed pre-interface bootstrap closes its own resources in Start's
	// defer. Retry only a confirmed dead, detached account/never-attached host.
	if owner, ok := server.(*serviceBackend); ok && state == "error" {
		live := owner.VPNState(context.Background())
		neverAttached := owner.router == nil || !owner.router.attached
		if !live.CoreAlive && !live.Attached && (owner.foreground || neverAttached) {
			if err := owner.Close(); err != nil {
				return operationResult{Operation: "startAccount", State: "error", Error: err.Error()}
			}
			lifecycle.Lock()
			lifecycle.server = nil
			lifecycle.state = "closed"
			lifecycle.lastError = ""
			lifecycle.Unlock()
		}
	}
	r := startWithBackendLocked(dir, hostname, func(dir, hostname string) backend {
		if conn, err := net.DialTimeout("unix", serviceSocket(dir), time.Second); err == nil {
			conn.Close()
			return remoteService(dir)
		}
		return &serviceBackend{dir: dir, hostname: hostname, foreground: true}
	})
	r.Operation = "startAccount"
	return r
}

// Called only after an authorized extension has acknowledged handoff_wait.
// Never close an extension-owned engine through this account API.
func releaseAccountCore() operationResult {
	lockMutation()
	defer operationMu.Unlock()
	server, state, err := currentServer()
	if err != nil {
		return operationResult{OK: true, Operation: "releaseAccount", State: state}
	}
	owner, account := server.(*serviceBackend)
	if !account || !owner.foreground {
		return operationResult{OK: true, Operation: "releaseAccount", State: state, Message: "VPN owner retained"}
	}
	if err := owner.Close(); err != nil {
		lifecycle.Lock()
		lifecycle.state = "error"
		lifecycle.lastError = err.Error()
		lifecycle.Unlock()
		return operationResult{Operation: "releaseAccount", State: "error", Error: err.Error()}
	}
	lifecycle.Lock()
	lifecycle.server = nil
	lifecycle.state = "closed"
	lifecycle.lastError = ""
	lifecycle.Unlock()
	return operationResult{OK: true, Operation: "releaseAccount", State: "closed"}
}
