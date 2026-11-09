package main

import (
	"errors"
	"testing"
)

func TestLockHomeAllowsOneServer(t *testing.T) {
	home := t.TempDir()
	first, err := lockHome(home)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lockHome(home); !errors.Is(err, errAlreadyRunning) {
		t.Fatalf("second lock: got %v, want errAlreadyRunning", err)
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	again, err := lockHome(home)
	if err != nil {
		t.Fatalf("lock after release: %v", err)
	}
	again.Close()
}
