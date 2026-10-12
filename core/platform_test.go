package main

import (
	"strings"
	"testing"
	"unsafe"

	"tailscale.com/hostinfo"
)

func TestPlatformMetadataOverridesRealUpstreamHostinfo(t *testing.T) {
	setupBackend(t, &fakeBackend{})
	old := reportedPlatform.Load()
	t.Cleanup(func() { reportedPlatform.Store(old) })
	for _, raw := range []string{`{`, `{"os":"linux"}`, `{"os":"openharmony","osVersion":"bad\u0000version"}`,
		`{"os":"openharmony","deviceModel":"` + strings.Repeat("x", 257) + `"}`} {
		if configurePlatform(raw).OK {
			t.Fatal("invalid metadata accepted", raw)
		}
	}
	for _, platform := range []string{"openharmony", "harmonyos"} {
		raw := `{"os":"` + platform + `","osVersion":"6.1.1.120","deviceModel":"HUAWEI Mate 70"}`
		if r := configurePlatform(raw); !r.OK {
			t.Fatal(r)
		}
		hi := hostinfo.New()
		if hi.OS != platform || hi.OSVersion != "6.1.1.120" || hi.DeviceModel != "HUAWEI Mate 70" ||
			hi.Distro != "" || hi.DistroVersion != "" || hi.Package != "hap" || hi.GoVersion == "" || hi.IPNVersion == "" {
			t.Fatal(hi)
		}
	}
	if r := configurePlatform(`{"os":"openharmony"}`); !r.OK || hostinfo.New().OSVersion != "" {
		t.Fatal("unknown OS version became a Linux kernel version", r)
	}
	if jsonOwned(t, unsafe.Pointer(tailscale_ohos_configure_platform(nil)))["ok"] != false {
		t.Fatal("invalid ABI argument accepted")
	}
	startCore(t.TempDir(), "same-node")
	if !configurePlatform(`{"os":"openharmony"}`).OK {
		t.Fatal("idempotent metadata configuration failed")
	}
	if configurePlatform(`{"os":"openharmony","osVersion":"changed"}`).OK {
		t.Fatal("live metadata silently replaced without a hostinfo update")
	}
}
