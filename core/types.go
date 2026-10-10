package main

import "encoding/json"

type operationResult struct {
	OK        bool   `json:"ok"`
	Operation string `json:"operation"`
	State     string `json:"state"`
	Error     string `json:"error,omitempty"`
	DataDir   string `json:"dataDir,omitempty"`
	Hostname  string `json:"hostname,omitempty"`
	Message   string `json:"message,omitempty"`
}

type interfaceInfo struct {
	Name      string   `json:"name"`
	Index     int      `json:"index"`
	MTU       int      `json:"mtu"`
	Flags     string   `json:"flags"`
	Addresses []string `json:"addresses"`
}

type checkResult struct {
	OK     bool   `json:"ok"`
	Detail string `json:"detail,omitempty"`
	Error  string `json:"error,omitempty"`
}

type diagnosticsResult struct {
	OK             bool            `json:"ok"`
	Operation      string          `json:"operation"`
	GOOS           string          `json:"goos"`
	GOARCH         string          `json:"goarch"`
	Storage        checkResult     `json:"storage"`
	TCP            checkResult     `json:"tcpSocket"`
	UDP            checkResult     `json:"udpSocket"`
	DNS            checkResult     `json:"dns"`
	ControlPlane   checkResult     `json:"controlPlane"`
	DefaultRoute   checkResult     `json:"defaultRoute"`
	NetworkMonitor checkResult     `json:"networkMonitor"`
	Interfaces     []interfaceInfo `json:"interfaces"`
	Error          string          `json:"error,omitempty"`
}

type peerInfo struct {
	ID           string   `json:"id"`
	HostName     string   `json:"hostName,omitempty"`
	DNSName      string   `json:"dnsName,omitempty"`
	OS           string   `json:"os,omitempty"`
	UserID       string   `json:"userId,omitempty"`
	UserLogin    string   `json:"userLogin,omitempty"`
	UserName     string   `json:"userName,omitempty"`
	Online       bool     `json:"online"`
	Active       bool     `json:"active"`
	TailscaleIPs []string `json:"tailscaleIPs,omitempty"`
	Tags         []string `json:"tags,omitempty"`
	Relay        string   `json:"relay,omitempty"`
	LastSeen     string   `json:"lastSeen,omitempty"`
}

type tailnetInfo struct {
	Name            string `json:"name,omitempty"`
	MagicDNSSuffix  string `json:"magicDNSSuffix,omitempty"`
	MagicDNSEnabled bool   `json:"magicDNSEnabled"`
}

type controlStatusResult struct {
	OK             bool         `json:"ok"`
	Operation      string       `json:"operation"`
	LifecycleState string       `json:"lifecycleState"`
	BackendState   string       `json:"backendState,omitempty"`
	AuthURL        string       `json:"authUrl,omitempty"`
	LoggedIn       bool         `json:"loggedIn"`
	TailscaleIPs   []string     `json:"tailscaleIPs,omitempty"`
	Self           *peerInfo    `json:"self,omitempty"`
	Tailnet        *tailnetInfo `json:"tailnet,omitempty"`
	Health         []string     `json:"health,omitempty"`
	DebugLogs      []string     `json:"debugLogs,omitempty"`
	Error          string       `json:"error,omitempty"`
}

type onlinePeersResult struct {
	OK         bool       `json:"ok"`
	Operation  string     `json:"operation"`
	Filter     string     `json:"filter,omitempty"`
	FilterKind string     `json:"filterKind"`
	Count      int        `json:"count"`
	Peers      []peerInfo `json:"peers"`
	Error      string     `json:"error,omitempty"`
}

// encodeJSON always returns valid JSON, including marshaler failures.
func encodeJSON(value any) []byte {
	data, err := json.Marshal(value)
	if err != nil {
		data, _ = json.Marshal(operationResult{OK: false, State: "error", Error: err.Error()})
	}
	return data
}
