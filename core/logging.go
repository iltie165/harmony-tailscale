package main

import (
	"fmt"
	"strings"
	"time"
)

func appendLog(format string, args ...any) {
	line := sanitizeLogLine(redactLoginURLs(strings.TrimSpace(fmt.Sprintf(format, args...))))
	if line == "" {
		return
	}
	line = time.Now().UTC().Format(time.RFC3339Nano) + " " + line
	logs.Lock()
	defer logs.Unlock()
	logs.lines = append(logs.lines, line)
	if len(logs.lines) > maxLogLines {
		copy(logs.lines, logs.lines[len(logs.lines)-maxLogLines:])
		logs.lines = logs.lines[:maxLogLines]
	}
}

func sanitizeLogLine(line string) string {
	return strings.ReplaceAll(line, "\x00", "\\x00")
}

func recentLogLines(limit int) []string {
	logs.Lock()
	defer logs.Unlock()
	if limit <= 0 || len(logs.lines) == 0 {
		return nil
	}
	start := len(logs.lines) - limit
	if start < 0 {
		start = 0
	}
	result := make([]string, len(logs.lines)-start)
	copy(result, logs.lines[start:])
	return result
}

func bridgeLogf(format string, args ...any) {
	appendLog("%s", redactLoginURLs(fmt.Sprintf(format, args...)))
}

func redactLoginURLs(value string) string {
	const loginURL = "https://login.tailscale.com/"
	for {
		start := strings.Index(value, loginURL)
		if start < 0 {
			return value
		}
		end := start
		for end < len(value) && value[end] != ' ' && value[end] != '\n' && value[end] != '\r' && value[end] != '\t' {
			end++
		}
		value = value[:start] + "[REDACTED_TAILSCALE_LOGIN_URL]" + value[end:]
	}
}
