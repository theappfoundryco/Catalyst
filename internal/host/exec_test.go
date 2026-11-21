package host

import (
	"os"
	"testing"
)

func TestExecKind(t *testing.T) {
	elf := func(machine byte) []byte {
		b := make([]byte, 64)
		copy(b, []byte{0x7f, 'E', 'L', 'F', 2, 1})
		b[18] = machine
		return b
	}
	macho := func(cpu uint32) []byte {
		b := []byte{0xcf, 0xfa, 0xed, 0xfe, byte(cpu), byte(cpu >> 8), byte(cpu >> 16), byte(cpu >> 24)}
		return append(b, make([]byte, 24)...)
	}
	cases := []struct {
		head []byte
		want string
	}{
		{elf(0x3e), "x86_64"},
		{elf(0xb7), "arm64"},
		{macho(0x0100000c), "arm64"},
		{macho(0x01000007), "x86_64"},
		{[]byte{0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2}, "universal"},
		{[]byte("#!/usr/bin/env node\nrequire('x')\n"), "script (node)"},
		{[]byte("#!/usr/bin/env -S python3 -u\n"), "script (python3)"},
		{[]byte("#!/bin/bash\n"), "script (bash)"},
		{[]byte("hello"), ""},
		{nil, ""},
	}
	for _, c := range cases {
		if got := ExecKind(c.head); got != c.want {
			t.Errorf("%q: %q", c.head, got)
		}
	}
	self, _ := os.Executable()
	if k := ExecKindOf(self); k != "x86_64" && k != "arm64" {
		t.Errorf("this test binary: %q", k)
	}
}
