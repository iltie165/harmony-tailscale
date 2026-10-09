// Package main exposes a deliberately small C ABI for the HarmonyOS bridge.
package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"reflect"
	"runtime"
	"strings"
	"unsafe"

	"tailscale.com/tsnet"
	"tailscale.com/version"
)

const abiVersion = 1

//export tailscale_ohos_abi_version
func tailscale_ohos_abi_version() C.uint32_t {
	return C.uint32_t(abiVersion)
}

//export tailscale_ohos_version
func tailscale_ohos_version() *C.char {
	return C.CString(version.Short())
}

//export tailscale_ohos_go_version
func tailscale_ohos_go_version() *C.char {
	return C.CString(runtime.Version())
}

//export tailscale_ohos_core_probe
func tailscale_ohos_core_probe() C.int {
	// Taking the program counter of tsnet.Server.Start keeps a real tsnet core
	// entry point reachable in the shared library without starting networking.
	pc := reflect.ValueOf((*tsnet.Server).Start).Pointer()
	fn := runtime.FuncForPC(pc)
	if fn != nil && strings.Contains(fn.Name(), "tailscale.com/tsnet.(*Server).Start") {
		return 1
	}
	return 0
}

//export tailscale_ohos_string_free
func tailscale_ohos_string_free(value unsafe.Pointer) {
	C.free(value)
}

func main() {}
