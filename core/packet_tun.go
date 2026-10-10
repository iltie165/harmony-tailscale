package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"sync/atomic"

	"github.com/tailscale/wireguard-go/tun"
	"golang.org/x/sys/unix"
)

// packetTun owns a duplicate, never the descriptor borrowed from ArkTS. Raw
// syscalls deliberately avoid os.File's metadata/type probing: the phone
// sandbox denies fstat on a perfectly usable VPN descriptor.
type packetTun struct {
	mu        sync.RWMutex
	fd        int
	done      chan struct{}
	events    chan tun.Event
	once      sync.Once
	closeErr  error
	errMu     sync.Mutex
	lastError string
	txPackets atomic.Uint64
	txBytes   atomic.Uint64
	rxPackets atomic.Uint64
	rxBytes   atomic.Uint64
}

func newPacketTun(borrowed int) (*packetTun, error) {
	fd, err := unix.FcntlInt(uintptr(borrowed), unix.F_DUPFD_CLOEXEC, 0)
	if err != nil {
		return nil, fmt.Errorf("duplicate VPN descriptor: %w", err)
	}
	flags, err := unix.FcntlInt(uintptr(fd), unix.F_GETFL, 0)
	if err == nil && flags&unix.O_ACCMODE != unix.O_RDWR {
		err = errors.New("VPN descriptor is not read-write")
	}
	if err == nil {
		err = unix.SetNonblock(fd, true)
	}
	if err != nil {
		unix.Close(fd)
		return nil, err
	}
	t := &packetTun{fd: fd, done: make(chan struct{}), events: make(chan tun.Event, 1)}
	t.events <- tun.EventUp
	return t, nil
}

func (t *packetTun) File() *os.File           { return nil }
func (t *packetTun) Name() (string, error)    { return "harmony-vpn", nil }
func (t *packetTun) MTU() (int, error)        { return 1280, nil }
func (t *packetTun) BatchSize() int           { return 1 }
func (t *packetTun) Events() <-chan tun.Event { return t.events }
func (t *packetTun) fail(err error) error {
	if err != nil && !errors.Is(err, os.ErrClosed) {
		t.errMu.Lock()
		t.lastError = err.Error()
		t.errMu.Unlock()
	}
	return err
}

// Poll with a short deadline so Close can join both I/O paths before releasing
// the fd. Closing a descriptor while another goroutine is using it could act
// on an unrelated recycled descriptor or leave a blocked read behind.
func (t *packetTun) transfer(buffer []byte, write bool) (int, error) {
	for {
		select {
		case <-t.done:
			return 0, os.ErrClosed
		default:
		}
		t.mu.RLock()
		if t.fd < 0 {
			t.mu.RUnlock()
			return 0, os.ErrClosed
		}
		event := int16(unix.POLLIN)
		if write {
			event = unix.POLLOUT
		}
		p := []unix.PollFd{{Fd: int32(t.fd), Events: event}}
		n, err := unix.Poll(p, 100)
		if err == unix.EINTR {
			t.mu.RUnlock()
			continue
		}
		if err != nil {
			t.mu.RUnlock()
			return 0, t.fail(err)
		}
		if n == 0 {
			t.mu.RUnlock()
			continue
		}
		if p[0].Revents&(unix.POLLNVAL|unix.POLLERR|unix.POLLHUP) != 0 {
			t.mu.RUnlock()
			return 0, t.fail(errors.New("VPN descriptor became unavailable"))
		}
		if write {
			n, err = unix.Write(t.fd, buffer)
		} else {
			n, err = unix.Read(t.fd, buffer)
		}
		t.mu.RUnlock()
		if err == unix.EAGAIN || err == unix.EINTR {
			continue
		}
		if err != nil {
			return 0, t.fail(err)
		}
		if n == 0 {
			return 0, t.fail(io.ErrUnexpectedEOF)
		}
		return n, nil
	}
}

func (t *packetTun) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	if len(bufs) == 0 || len(sizes) == 0 || offset < 0 || offset >= len(bufs[0]) {
		return 0, errors.New("invalid TUN read buffers")
	}
	n, err := t.transfer(bufs[0][offset:], false)
	if err != nil {
		return 0, err
	}
	sizes[0] = n
	t.txPackets.Add(1)
	t.txBytes.Add(uint64(n))
	return 1, nil
}
func (t *packetTun) Write(bufs [][]byte, offset int) (int, error) {
	for i, buf := range bufs {
		if offset < 0 || offset >= len(buf) {
			return i, errors.New("invalid TUN write offset")
		}
		n, err := t.transfer(buf[offset:], true)
		if err != nil {
			return i, err
		}
		if n != len(buf)-offset {
			return i, t.fail(io.ErrShortWrite)
		}
		t.rxPackets.Add(1)
		t.rxBytes.Add(uint64(n))
	}
	return len(bufs), nil
}
func (t *packetTun) Close() error {
	t.once.Do(func() {
		close(t.done)
		t.mu.Lock()
		t.closeErr = unix.Close(t.fd)
		t.fd = -1
		t.mu.Unlock()
		close(t.events)
	})
	return t.closeErr
}
