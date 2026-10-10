package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

func startCore(dataDir, hostname string) operationResult {
	return startWithBackend(dataDir, hostname, newBackend)
}

func startWithBackend(dataDir, hostname string, factory func(string, string) backend) operationResult {
	operationMu.Lock()
	defer operationMu.Unlock()

	if dataDir != "" {
		dataDir = filepath.Clean(dataDir)
	}
	if err := validateStartInput(dataDir, hostname); err != nil {
		appendLog("start validation failed: %v", err)
		return operationResult{OK: false, Operation: "start", State: "error", Error: err.Error()}
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		appendLog("create state directory %q: %v", dataDir, err)
		return operationResult{OK: false, Operation: "start", State: "error", Error: err.Error(), DataDir: dataDir, Hostname: hostname}
	}

	lifecycle.Lock()
	if lifecycle.server != nil && lifecycle.state != "closed" {
		result := operationResult{OK: lifecycle.state == "started", Operation: "start", State: lifecycle.state, Error: lifecycle.lastError, DataDir: lifecycle.dataDir, Hostname: lifecycle.hostname, Message: "server already initialized; close it before retrying"}
		lifecycle.Unlock()
		return result
	}
	server := factory(dataDir, hostname)
	lifecycle.server = server
	lifecycle.state = "starting"
	lifecycle.dataDir = dataDir
	lifecycle.hostname = hostname
	lifecycle.lastError = ""
	lifecycle.Unlock()

	appendLog("platform adapter: Tailscale netns disabled for userspace networking")
	appendLog("tsnet.Start begin dir=%q hostname=%q", dataDir, hostname)
	err := server.Start()
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if err != nil {
		lifecycle.state = "error"
		lifecycle.lastError = err.Error()
		appendLog("tsnet.Start failed: %v", err)
		return operationResult{OK: false, Operation: "start", State: lifecycle.state, Error: err.Error(), DataDir: dataDir, Hostname: hostname}
	}
	lifecycle.state = "started"
	appendLog("tsnet.Start returned successfully")
	return operationResult{OK: true, Operation: "start", State: lifecycle.state, DataDir: dataDir, Hostname: hostname, Message: "tsnet.Server.Start returned nil"}
}

func logoutCore() controlStatusResult {
	operationMu.Lock()
	defer operationMu.Unlock()

	server, state, err := currentServer()
	if err != nil {
		return controlStatus("logout", state, nil, err)
	}
	client, err := server.LocalClient()
	if err != nil {
		return controlStatus("logout", state, nil, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := client.Logout(ctx); err != nil {
		appendLog("logout failed: %v", err)
		return controlStatus("logout", state, nil, err)
	}
	status, err := client.Status(ctx)
	appendLog("logout completed")
	return controlStatus("logout", state, status, err)
}

func onlinePeersCore(filter string) onlinePeersResult {
	operationMu.Lock()
	defer operationMu.Unlock()

	filter = strings.TrimSpace(filter)
	result := onlinePeersResult{
		Operation:  "onlinePeers",
		Filter:     filter,
		FilterKind: filterKind(filter),
		Peers:      []peerInfo{},
	}
	if result.FilterKind == "acl-group" {
		result.Error = "ACL group membership is not exposed by the node LocalAPI; use a management backend with Tailscale OAuth"
		return result
	}
	server, _, err := currentServer()
	if err != nil {
		result.Error = err.Error()
		return result
	}
	client, err := server.LocalClient()
	if err != nil {
		result.Error = err.Error()
		return result
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil {
		result.Error = err.Error()
		return result
	}
	if status == nil {
		result.Error = "Tailscale returned an empty status"
		return result
	}
	if status.BackendState != "Running" {
		result.Error = fmt.Sprintf("Tailscale backend is %q; login must complete before peers are available", status.BackendState)
		return result
	}
	for _, key := range status.Peers() {
		peer := status.Peer[key]
		if peer == nil || !peer.Online {
			continue
		}
		item := peerFromStatus(status, peer)
		if peerMatchesFilter(item, filter) {
			result.Peers = append(result.Peers, item)
		}
	}
	sort.Slice(result.Peers, func(i, j int) bool {
		left := result.Peers[i].DNSName
		right := result.Peers[j].DNSName
		if left == "" {
			left = result.Peers[i].HostName
		}
		if right == "" {
			right = result.Peers[j].HostName
		}
		return strings.ToLower(left) < strings.ToLower(right)
	})
	result.OK = true
	result.Count = len(result.Peers)
	appendLog("online peers query filter=%q kind=%s count=%d", filter, result.FilterKind, result.Count)
	return result
}

func closeCore() operationResult {
	operationMu.Lock()
	defer operationMu.Unlock()

	lifecycle.RLock()
	server := lifecycle.server
	state := lifecycle.state
	lifecycle.RUnlock()
	if server == nil || state == "idle" || state == "closed" {
		return operationResult{OK: true, Operation: "close", State: state, Message: "server is not running"}
	}
	appendLog("tsnet.Close begin")
	err := server.Close()
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if err != nil {
		lifecycle.state = "error"
		lifecycle.lastError = err.Error()
		appendLog("tsnet.Close failed: %v", err)
		return operationResult{OK: false, Operation: "close", State: lifecycle.state, Error: err.Error(), DataDir: lifecycle.dataDir, Hostname: lifecycle.hostname}
	}
	lifecycle.server = nil
	lifecycle.state = "closed"
	lifecycle.lastError = ""
	appendLog("tsnet.Close returned successfully")
	return operationResult{OK: true, Operation: "close", State: lifecycle.state, DataDir: lifecycle.dataDir, Hostname: lifecycle.hostname}
}

func fetchControlStatus(operation string) controlStatusResult {
	server, state, err := currentServer()
	if err != nil {
		return controlStatus(operation, state, nil, err)
	}
	client, err := server.LocalClient()
	if err != nil {
		return controlStatus(operation, state, nil, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	status, err := client.Status(ctx)
	return controlStatus(operation, state, status, err)
}
