package core

import "testing"

func TestAllocatePortsStaysInRange(t *testing.T) {
	if b := allocatePorts(nil, 49000, 49099); b < 49000 || b+portCount-1 > 49099 || b%10 != 0 {
		t.Fatalf("base %d outside 49000-49099", b)
	}
	used := map[int32]bool{}
	for b := int32(49000); b < 49100; b += 10 {
		used[b] = true
	}
	if b := allocatePorts(used, 49000, 49099); b != 49000 {
		t.Fatalf("full range should fall back to its start, got %d", b)
	}
	if b := allocatePorts(map[int32]bool{49000: true}, 49000, 49099); b != 49010 {
		t.Fatalf("expected the next block, got %d", b)
	}
}
