// Package main exposes a deliberately small C ABI for the HarmonyOS bridge.
package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"fmt"
	"reflect"
	"runtime"
	"runtime/debug"
	"strings"
	"time"
	"unsafe"

	"tailscale.com/tsnet"
	"tailscale.com/version"
)

const (
	abiVersion  = 3
	maxLogLines = 512
)

func cJSON(value any) *C.char {
	return C.CString(string(encodeJSON(value)))
}

func panicResult(operation string, output **C.char) {
	if recovered := recover(); recovered != nil {
		message := fmt.Sprintf("panic: %v", recovered)
		stack := string(debug.Stack())
		appendLog("%s\n%s", message, stack)
		if operation == "start" || operation == "startVpn" || operation == "close" {
			lifecycle.Lock()
			lifecycle.state = "panic"
			lifecycle.lastError = message
			lifecycle.Unlock()
		}
		*output = cJSON(operationResult{
			OK:        false,
			Operation: operation,
			State:     "panic",
			Error:     message,
			Message:   stack,
		})
	}
}

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
	pc := reflect.ValueOf((*tsnet.Server).Start).Pointer()
	fn := runtime.FuncForPC(pc)
	if fn != nil && strings.Contains(fn.Name(), "tailscale.com/tsnet.(*Server).Start") {
		return 1
	}
	return 0
}

//export tailscale_ohos_start
func tailscale_ohos_start(cDataDir, cHostname *C.char) (output *C.char) {
	defer panicResult("start", &output)
	return cJSON(startCore(C.GoString(cDataDir), C.GoString(cHostname)))
}

//export tailscale_ohos_start_vpn
func tailscale_ohos_start_vpn(cDataDir, cHostname, cAddress *C.char, fd C.int) (output *C.char) {
	defer panicResult("startVpn", &output)
	return cJSON(startVpnCore(C.GoString(cDataDir), C.GoString(cHostname), C.GoString(cAddress), int(fd)))
}

//export tailscale_ohos_vpn_status
func tailscale_ohos_vpn_status() (output *C.char) {
	defer panicResult("vpnStatus", &output)
	return cJSON(vpnStateCore())
}

//export tailscale_ohos_network_changed
func tailscale_ohos_network_changed() (output *C.char) {
	defer panicResult("networkChanged", &output)
	return cJSON(networkChangedCore())
}

//export tailscale_ohos_status
func tailscale_ohos_status() (output *C.char) {
	defer panicResult("status", &output)
	operationMu.Lock()
	defer operationMu.Unlock()
	return cJSON(fetchControlStatus("status"))
}

//export tailscale_ohos_login
func tailscale_ohos_login() (output *C.char) {
	defer panicResult("login", &output)
	operationMu.Lock()
	defer operationMu.Unlock()

	server, state, err := currentServer()
	if err != nil {
		return cJSON(controlStatus("login", state, nil, err))
	}
	client, err := server.LocalClient()
	if err != nil {
		return cJSON(controlStatus("login", state, nil, err))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return cJSON(runLogin(ctx, client, state))
}

//export tailscale_ohos_logout
func tailscale_ohos_logout() (output *C.char) {
	defer panicResult("logout", &output)
	return cJSON(logoutCore())
}

//export tailscale_ohos_online_peers
func tailscale_ohos_online_peers(cFilter *C.char) (output *C.char) {
	defer panicResult("onlinePeers", &output)
	return cJSON(onlinePeersCore(C.GoString(cFilter)))
}

//export tailscale_ohos_close
func tailscale_ohos_close() (output *C.char) {
	defer panicResult("close", &output)
	return cJSON(closeCore())
}

//export tailscale_ohos_diagnostics
func tailscale_ohos_diagnostics(cDataDir *C.char) (output *C.char) {
	defer panicResult("diagnostics", &output)
	return cJSON(diagnosticsCore(C.GoString(cDataDir)))
}

//export tailscale_ohos_logs
func tailscale_ohos_logs() (output *C.char) {
	defer panicResult("logs", &output)
	logs.Lock()
	defer logs.Unlock()
	return C.CString(strings.Join(logs.lines, "\n"))
}

//export tailscale_ohos_string_free
func tailscale_ohos_string_free(value unsafe.Pointer) {
	C.free(value)
}

func main() {}
