package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync/atomic"
	"unicode"

	"tailscale.com/hostinfo"
	"tailscale.com/tailcfg"
)

// Platform metadata comes from the owning extension's system API, not uname
// on the Linux-compatible Go runtime. Register the hook once during init;
// RegisterHostinfoNewHook itself is not safe to mutate during backend startup.
type platformInfo struct {
	OS          string `json:"os"`
	OSVersion   string `json:"osVersion"`
	DeviceModel string `json:"deviceModel"`
}

var reportedPlatform atomic.Pointer[platformInfo]

func init() {
	hostinfo.RegisterHostinfoNewHook(func(hi *tailcfg.Hostinfo) {
		if p := reportedPlatform.Load(); p != nil {
			hi.OS, hi.OSVersion, hi.DeviceModel = p.OS, p.OSVersion, p.DeviceModel
			hi.Distro, hi.DistroVersion, hi.DistroCodeName = "", "", ""
			hi.Container, hi.Env, hi.Cloud, hi.Desktop = "", "", "", ""
			hi.Package = "hap"
		}
	})
}

func configurePlatform(raw string) operationResult {
	operationMu.Lock()
	defer operationMu.Unlock()
	fail := func(err error) operationResult {
		return operationResult{Operation: "configurePlatform", Error: err.Error()}
	}
	var p platformInfo
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		return fail(fmt.Errorf("invalid platform metadata: %w", err))
	}
	if p.OS != "openharmony" && p.OS != "harmonyos" {
		return fail(fmt.Errorf("unsupported platform identity"))
	}
	for _, value := range []string{p.OSVersion, p.DeviceModel} {
		if len(value) > 256 || strings.IndexFunc(value, unicode.IsControl) >= 0 {
			return fail(fmt.Errorf("invalid platform metadata field"))
		}
	}
	if old := reportedPlatform.Load(); old != nil && *old == p {
		return operationResult{OK: true, Operation: "configurePlatform"}
	}
	lifecycle.RLock()
	active := lifecycle.server != nil && lifecycle.state != "closed"
	lifecycle.RUnlock()
	if active {
		return fail(fmt.Errorf("configure platform metadata before starting the core"))
	}
	reportedPlatform.Store(&p)
	return operationResult{OK: true, Operation: "configurePlatform"}
}
