package main

import (
	"context"
	"fmt"
	"time"

	"tailscale.com/ipn"
)

// runLogin consumes the official bus. The caller owns the bounded context;
// canceling it stops this observation, not the backend's authentication context.
func runLogin(ctx context.Context, client controlClient, state string) controlStatusResult {
	status, err := client.Status(ctx)
	if err != nil || status == nil {
		return controlStatus("login", state, status, err)
	}
	if status.BackendState == "Running" || status.AuthURL != "" {
		return controlStatus("login", state, status, nil)
	}
	watcher, err := client.WatchIPNBus(ctx, ipn.NotifyInitialState|ipn.NotifyNoPrivateKeys)
	if err != nil {
		appendLog("interactive login watcher failed: %v", err)
		return controlStatus("login", state, status, fmt.Errorf("watch login events: %w", err))
	}
	defer watcher.Close()

	snapshot := func(authURL string, operationErr error) controlStatusResult {
		statusCtx, statusCancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer statusCancel()
		latest, statusErr := client.Status(statusCtx)
		if statusErr != nil || latest == nil {
			if statusErr == nil {
				statusErr = fmt.Errorf("Tailscale returned an empty status")
			}
			result := controlStatus("login", state, status, nil)
			result.OK = false
			result.Error = statusErr.Error()
			if operationErr != nil {
				result.Error = operationErr.Error() + "; status: " + statusErr.Error()
			}
			if authURL != "" {
				result.AuthURL = authURL
			}
			result.DebugLogs = recentLogLines(24)
			return result
		}
		result := controlStatus("login", state, latest, nil)
		if authURL != "" {
			result.AuthURL = authURL
		}
		if operationErr != nil {
			result.OK = false
			result.Error = operationErr.Error()
			result.DebugLogs = recentLogLines(24)
		}
		return result
	}

	appendLog("interactive login requested")
	if err := client.StartLoginInteractive(ctx); err != nil {
		appendLog("interactive login request failed: %v", err)
		return snapshot("", err)
	}
	for {
		notify, err := watcher.Next()
		if err != nil {
			if ctx.Err() != nil {
				err = fmt.Errorf("timed out waiting for Tailscale login URL: %w", ctx.Err())
			} else {
				err = fmt.Errorf("watch login events: %w", err)
			}
			appendLog("interactive login failed: %v", err)
			return snapshot("", err)
		}
		if notify.ErrMessage != nil && *notify.ErrMessage != "" {
			err := fmt.Errorf("Tailscale backend: %s", *notify.ErrMessage)
			appendLog("interactive login backend error: %v", err)
			return snapshot("", err)
		}
		if notify.BrowseToURL != nil && *notify.BrowseToURL != "" {
			appendLog("interactive login URL received from IPN bus")
			return snapshot(*notify.BrowseToURL, nil)
		}
		if notify.State != nil {
			appendLog("interactive login state notification=%q", *notify.State)
			if *notify.State == ipn.Running {
				return snapshot("", nil)
			}
		}
	}
}
