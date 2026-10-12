package main

import (
	"errors"
	"os"
	"sync"
	"sync/atomic"

	"github.com/tailscale/wireguard-go/tun"
)

// switchTun is the engine's permanent device. A platform descriptor is only a
// replaceable attachment. Detach never returns EOF to WireGuard or closes the
// permanent event stream; OFF discards inbound packets, rather than queueing
// them for the next attachment.
type switchTun struct {
	mu                                     sync.Mutex
	current                                *packetTun
	changed                                chan struct{}
	done                                   chan struct{}
	events                                 chan tun.Event
	closed                                 bool
	lastError                              string
	txPackets, rxPackets, txBytes, rxBytes atomic.Uint64
}

func newSwitchTun() *switchTun {
	t := &switchTun{changed: make(chan struct{}), done: make(chan struct{}), events: make(chan tun.Event, 8)}
	// The engine's logical device stays available while no platform FD is
	// attached. VPN connected is independently gated on the real attachment.
	t.events <- tun.EventUp
	return t
}
func (t *switchTun) File() *os.File           { return nil }
func (t *switchTun) Name() (string, error)    { return "harmony-service", nil }
func (t *switchTun) MTU() (int, error)        { return 1280, nil }
func (t *switchTun) BatchSize() int           { return 1 }
func (t *switchTun) Events() <-chan tun.Event { return t.events }
func (t *switchTun) notifyLocked(event tun.Event) {
	close(t.changed)
	t.changed = make(chan struct{})
	// Do not take the permanent WireGuard interface down on a platform OFF.
	// The attachment state, not logical device events, controls system traffic.
}
func (t *switchTun) attach(device *packetTun) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return os.ErrClosed
	}
	if t.current != nil {
		return errors.New("VPN descriptor is already attached")
	}
	t.current = device
	t.lastError = ""
	t.notifyLocked(tun.EventUp)
	return nil
}
func (t *switchTun) detach() error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return os.ErrClosed
	}
	device := t.current
	if device == nil {
		t.lastError = ""
		return nil
	}
	// packetTun.Close joins descriptor I/O before returning. Keep the attachment
	// lock until then so a new FD cannot inherit an old packet/read result.
	err := device.Close()
	t.current = nil
	t.lastError = ""
	if err != nil {
		t.lastError = err.Error()
	}
	t.notifyLocked(tun.EventDown)
	return err
}
func (t *switchTun) snapshot() (bool, string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.current != nil && !t.closed, t.lastError
}
func (t *switchTun) fail(device *packetTun, err error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.current != device || t.closed {
		return
	}
	device.Close()
	t.current = nil
	t.lastError = err.Error()
	t.notifyLocked(tun.EventDown)
}
func (t *switchTun) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	if len(bufs) == 0 || len(sizes) == 0 || offset < 0 || offset >= len(bufs[0]) {
		return 0, errors.New("invalid TUN read buffers")
	}
	for {
		t.mu.Lock()
		device, changed, closed := t.current, t.changed, t.closed
		t.mu.Unlock()
		if closed {
			return 0, os.ErrClosed
		}
		if device == nil {
			select {
			case <-changed:
				continue
			case <-t.done:
				return 0, os.ErrClosed
			}
		}
		n, err := device.Read(bufs, sizes, offset)
		if err != nil {
			t.fail(device, err)
			continue
		}
		t.mu.Lock()
		valid := t.current == device && !t.closed
		if valid {
			t.txPackets.Add(uint64(n))
			t.txBytes.Add(uint64(sizes[0]))
		}
		t.mu.Unlock()
		if valid {
			return n, nil
		}
	}
}
func (t *switchTun) Write(bufs [][]byte, offset int) (int, error) {
	for _, buf := range bufs {
		if offset < 0 || offset >= len(buf) {
			return 0, errors.New("invalid TUN write offset")
		}
	}
	t.mu.Lock()
	device, closed := t.current, t.closed
	t.mu.Unlock()
	if closed {
		return 0, os.ErrClosed
	}
	if device == nil {
		return len(bufs), nil
	}
	n, err := device.Write(bufs, offset)
	if err != nil {
		t.fail(device, err)
		return len(bufs), nil
	}
	t.mu.Lock()
	if t.current == device && !t.closed {
		t.rxPackets.Add(uint64(n))
		for _, buf := range bufs[:n] {
			t.rxBytes.Add(uint64(len(buf) - offset))
		}
	}
	t.mu.Unlock()
	return n, nil
}
func (t *switchTun) Close() error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return nil
	}
	t.closed = true
	close(t.done)
	var err error
	if t.current != nil {
		err = t.current.Close()
		t.current = nil
	}
	close(t.changed)
	close(t.events)
	return err
}
