package main

import (
	"context"
	"sync"
	"time"
)

var reads = struct {
	sync.Mutex
	next   uint64
	active map[uint64]context.CancelFunc
}{active: make(map[uint64]context.CancelFunc)}

func readContext(timeout time.Duration) (context.Context, func()) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	reads.Lock()
	reads.next++
	id := reads.next
	reads.active[id] = cancel
	reads.Unlock()
	return ctx, func() {
		cancel()
		reads.Lock()
		delete(reads.active, id)
		reads.Unlock()
	}
}

func lockMutation() {
	reads.Lock()
	for _, cancel := range reads.active {
		cancel()
	}
	reads.Unlock()
	operationMu.Lock()
}
