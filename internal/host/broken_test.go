package host

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// machO is the smallest 64-bit Mac program debug/macho accepts: a header and one LC_LOAD_DYLIB per library.
func machO(cpu uint32, libs ...string) []byte {
	var cmds bytes.Buffer
	for _, l := range libs {
		name := append([]byte(l), 0)
		for (24+len(name))%8 != 0 {
			name = append(name, 0)
		}
		binary.Write(&cmds, binary.LittleEndian, []uint32{0xc, uint32(24 + len(name)), 24, 0, 0, 0})
		cmds.Write(name)
	}
	var b bytes.Buffer
	binary.Write(&b, binary.LittleEndian, []uint32{0xfeedfacf, cpu, 0, 2, uint32(len(libs)), uint32(cmds.Len()), 0, 0})
	b.Write(cmds.Bytes())
	return b.Bytes()
}

// elfWith is a 64-bit Linux program header with one PT_INTERP naming its loader.
func elfWith(machine uint16, loader string) []byte {
	var b bytes.Buffer
	b.Write([]byte{0x7f, 'E', 'L', 'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0})
	interp := append([]byte(loader), 0)
	binary.Write(&b, binary.LittleEndian, struct {
		Type, Machine                    uint16
		Version                          uint32
		Entry, Phoff, Shoff              uint64
		Flags                            uint32
		Ehsize, Phentsize, Phnum, Shentz uint16
		Shnum, Shstrndx                  uint16
	}{2, machine, 1, 0, 64, 0, 0, 64, 56, 1, 64, 0, 0})
	binary.Write(&b, binary.LittleEndian, struct {
		Type, Flags                          uint32
		Off, Vaddr, Paddr, Filesz, Memsz, Al uint64
	}{3, 4, 120, 0, 0, uint64(len(interp)), uint64(len(interp)), 1})
	b.Write(interp)
	return b.Bytes()
}

func prog(t *testing.T, name string, body []byte) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, body, 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func machine(goos, arch string, present ...string) Machine {
	have := map[string]bool{}
	for _, p := range present {
		have[p] = true
	}
	return Machine{OS: goos, Arch: arch, Exists: func(p string) bool { return have[p] },
		OnPath: func(n string) bool { return have["path:"+n] }, Emulates: func(string) bool { return false }}
}

func TestBrokenScripts(t *testing.T) {
	m := machine("linux", "amd64", "/usr/bin/env", "path:node", "/opt/homebrew/bin/python3")
	for body, want := range map[string]string{
		"#!/home/alex/.pyenv/versions/3.11.4/bin/python\nprint(1)\n": "runs /home/alex/.pyenv/versions/3.11.4/bin/python, which is gone",
		"#!/usr/bin/env python2\n":                                   "needs python2, which nothing on your PATH provides",
		"#!/usr/bin/env -S node --no-warnings\n":                     "",
		"#!/usr/bin/env node\n":                                      "",
		"#!/opt/homebrew/bin/python3\n":                              "",
	} {
		why, _ := Broken(prog(t, "tool", []byte(body)), m)
		if !strings.Contains(why, want) || (want == "") != (why == "") {
			t.Errorf("%q: got %q", body, why)
		}
	}
}

func TestBrokenLink(t *testing.T) {
	dir := t.TempDir()
	os.Symlink(filepath.Join(dir, "gone"), filepath.Join(dir, "tool"))
	if why, _ := Broken(filepath.Join(dir, "tool"), machine("linux", "amd64")); !strings.Contains(why, "which is gone") {
		t.Fatalf("%q", why)
	}
}

func TestBrokenMacPrograms(t *testing.T) {
	const arm, intel = 0x0100000c, 0x01000007
	lib := "/opt/homebrew/opt/icu4c/lib/libicuuc.73.dylib"
	ok := prog(t, "a", machO(arm, "/usr/lib/libSystem.B.dylib", "@rpath/libfoo.dylib"))
	if why, _ := Broken(ok, machine("darwin", "arm64")); why != "" {
		t.Errorf("Apple's libraries and @rpath are not files to check: %q", why)
	}
	gone := prog(t, "b", machO(arm, lib))
	if why, _ := Broken(gone, machine("darwin", "arm64")); !strings.Contains(why, lib) {
		t.Errorf("%q", why)
	}
	if why, _ := Broken(gone, machine("darwin", "arm64", lib)); why != "" {
		t.Errorf("%q", why)
	}
	x86 := prog(t, "c", machO(intel))
	if why, isIntel := Broken(x86, machine("darwin", "arm64")); !isIntel || !strings.Contains(why, "Rosetta is not installed") {
		t.Errorf("%q %v", why, isIntel)
	}
	m := machine("darwin", "arm64")
	m.Rosetta = true
	if why, isIntel := Broken(x86, m); why != "" || !isIntel {
		t.Errorf("with Rosetta it starts, and is still Intel-only: %q %v", why, isIntel)
	}
	if why, isIntel := Broken(x86, machine("darwin", "amd64")); why != "" || isIntel {
		t.Errorf("an Intel Mac runs it: %q", why)
	}
}

func TestBrokenLinuxPrograms(t *testing.T) {
	glibc := prog(t, "a", elfWith(0x3e, "/lib64/ld-linux-x86-64.so.2"))
	if why, _ := Broken(glibc, machine("linux", "amd64")); !strings.Contains(why, "built for glibc") {
		t.Errorf("a glibc program on a musl system: %q", why)
	}
	if why, _ := Broken(glibc, machine("linux", "amd64", "/lib64/ld-linux-x86-64.so.2")); why != "" {
		t.Errorf("%q", why)
	}
	arm := prog(t, "b", elfWith(0xb7, "/lib/ld-linux-aarch64.so.1"))
	if why, _ := Broken(arm, machine("linux", "amd64", "/lib/ld-linux-aarch64.so.1")); !strings.Contains(why, "built for arm64, and this machine is x86_64") {
		t.Errorf("%q", why)
	}
	m := machine("linux", "amd64", "/lib/ld-linux-aarch64.so.1")
	m.Emulates = func(a string) bool { return a == "arm64" }
	if why, _ := Broken(arm, m); why != "" {
		t.Errorf("qemu runs it: %q", why)
	}
}
