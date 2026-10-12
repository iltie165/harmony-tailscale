package main

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
)

func peerFromStatus(status *ipnstate.Status, peer *ipnstate.PeerStatus) peerInfo {
	result := peerInfo{
		ID:       string(peer.ID),
		HostName: peer.HostName,
		DNSName:  strings.TrimSuffix(peer.DNSName, "."),
		OS:       peer.OS,
		UserID:   peer.UserID.String(),
		Online:   peer.Online,
		Active:   peer.Active,
		Relay:    peer.Relay,
	}
	for _, address := range peer.TailscaleIPs {
		result.TailscaleIPs = append(result.TailscaleIPs, address.String())
	}
	if peer.Tags != nil {
		result.Tags = append(result.Tags, peer.Tags.AsSlice()...)
		sort.Strings(result.Tags)
	}
	if !peer.LastSeen.IsZero() {
		result.LastSeen = peer.LastSeen.UTC().Format(time.RFC3339)
	}
	if user, ok := status.User[peer.UserID]; ok {
		result.UserLogin = user.LoginName
		result.UserName = user.DisplayName
	}
	return result
}

func controlStatus(operation, lifecycleState string, status *ipnstate.Status, err error) controlStatusResult {
	result := controlStatusResult{Operation: operation, LifecycleState: lifecycleState}
	if err != nil {
		result.Error = err.Error()
		return result
	}
	if status == nil {
		result.Error = "Tailscale returned an empty status"
		return result
	}
	result.OK = true
	result.BackendState = status.BackendState
	result.AuthURL = status.AuthURL
	result.LoggedIn = status.BackendState == "Running"
	result.Health = append(result.Health, status.Health...)
	for _, address := range status.TailscaleIPs {
		result.TailscaleIPs = append(result.TailscaleIPs, address.String())
	}
	if status.Self != nil {
		self := peerFromStatus(status, status.Self)
		result.Self = &self
	}
	if status.CurrentTailnet != nil {
		result.Tailnet = &tailnetInfo{
			Name:            status.CurrentTailnet.Name,
			MagicDNSSuffix:  status.CurrentTailnet.MagicDNSSuffix,
			MagicDNSEnabled: status.CurrentTailnet.MagicDNSEnabled,
		}
	}
	return result
}

// Authentication survives engine restarts and VPN OFF. Read official prefs,
// not a UI boolean or the mere presence of a state file. Never export keys.
func restoreAccountStatus(result controlStatusResult, prefs *ipn.Prefs) controlStatusResult {
	// LocalAPI deliberately strips private keys. A saved server-assigned NodeID
	// survives that sanitization; an unregistered generated key does not suffice.
	if prefs == nil || prefs.LoggedOut || prefs.Persist == nil || prefs.Persist.NodeID == "" {
		return result
	}
	result.LoggedIn = true
	if result.Self == nil {
		result.Self = &peerInfo{UserLogin: prefs.Persist.UserProfile.LoginName,
			UserName: prefs.Persist.UserProfile.DisplayName, HostName: prefs.Hostname}
	}
	return result
}

func filterKind(filter string) string {
	switch {
	case filter == "":
		return "all"
	case strings.HasPrefix(strings.ToLower(filter), "tag:"):
		return "tag"
	case strings.HasPrefix(strings.ToLower(filter), "user:"):
		return "user"
	case strings.HasPrefix(strings.ToLower(filter), "group:"):
		return "acl-group"
	default:
		return "text"
	}
}

func peerMatchesFilter(peer peerInfo, filter string) bool {
	filter = strings.TrimSpace(filter)
	if filter == "" {
		return true
	}
	lower := strings.ToLower(filter)
	switch {
	case strings.HasPrefix(lower, "tag:"):
		for _, tag := range peer.Tags {
			if strings.EqualFold(tag, filter) {
				return true
			}
		}
		return false
	case strings.HasPrefix(lower, "user:"):
		value := strings.TrimSpace(filter[len("user:"):])
		return strings.EqualFold(peer.UserLogin, value) || strings.EqualFold(peer.UserName, value)
	default:
		return strings.Contains(strings.ToLower(peer.HostName), lower) ||
			strings.Contains(strings.ToLower(peer.DNSName), lower) ||
			strings.Contains(strings.ToLower(peer.UserLogin), lower)
	}
}

func validateStartInput(dataDir, hostname string) error {
	if dataDir == "" {
		return fmt.Errorf("data directory is empty")
	}
	if !filepath.IsAbs(dataDir) {
		return fmt.Errorf("data directory must be absolute: %q", dataDir)
	}
	if hostname == "" || len(hostname) > 63 {
		return fmt.Errorf("hostname length must be between 1 and 63 bytes")
	}
	for _, r := range hostname {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' {
			continue
		}
		return fmt.Errorf("hostname contains unsupported character %q", r)
	}
	if hostname[0] == '-' || hostname[len(hostname)-1] == '-' {
		return fmt.Errorf("hostname cannot start or end with '-'")
	}
	return nil
}
