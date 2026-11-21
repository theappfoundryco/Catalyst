package host

import (
	"bytes"
	"debug/elf"
	"debug/macho"
	"os"
	"path/filepath"
	"strings"
)

// Machine is what a program needs from the system to start: where it runs and what is there.
type Machine struct {
	OS, Arch string                 // "darwin" or "linux"; "arm64" or "amd64", the hardware's
	Exists   func(path string) bool // a system file, such as a library or an interpreter
	OnPath   func(name string) bool // a command the PATH of a new terminal finds
	Rosetta  bool                   // Intel programs can run on this Apple silicon Mac
	Emulates func(arch string) bool // Linux runs programs for another architecture (binfmt_misc)
}

// Broken says why the program at path cannot start, in plain words, or "" when it can as far as its file shows.
// It never runs the program. intel is true for a Mac program built only for Intel on Apple silicon, which starts
// today only through Rosetta.
func Broken(path string, m Machine) (why string, intel bool) {
	if target, err := os.Readlink(path); err == nil {
		if !filepath.IsAbs(target) {
			target = filepath.Join(filepath.Dir(path), target)
		}
		if _, err := os.Stat(target); err != nil {
			return "it links to " + target + ", which is gone", false
		}
	}
	f, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer f.Close()
	head := make([]byte, 512)
	n, _ := f.Read(head)
	head = head[:n]
	switch {
	case bytes.HasPrefix(head, []byte("#!")):
		return brokenScript(head, m), false
	case bytes.HasPrefix(head, []byte{0x7f, 'E', 'L', 'F'}) && m.OS == "linux":
		return brokenELF(path, m), false
	case m.OS == "darwin" && len(head) >= 4:
		return brokenMachO(path, head, m)
	}
	return "", false
}

// brokenScript looks at the #! line: an interpreter that is gone, or a name env cannot find.
func brokenScript(head []byte, m Machine) string {
	line := string(head[2:])
	if i := strings.IndexByte(line, '\n'); i >= 0 {
		line = line[:i]
	}
	f := strings.Fields(strings.TrimSpace(line))
	if len(f) == 0 {
		return ""
	}
	if filepath.Base(f[0]) == "env" {
		for _, a := range f[1:] {
			if strings.HasPrefix(a, "-") || strings.Contains(a, "=") {
				continue // env's own flags (-S, -i) and variables it sets
			}
			if strings.Contains(a, "/") {
				if !m.Exists(a) {
					return "it runs " + a + ", which is gone"
				}
			} else if !m.OnPath(a) {
				return "it needs " + a + ", which nothing on your PATH provides"
			}
			return ""
		}
		return ""
	}
	if !m.Exists(f[0]) {
		return "it runs " + f[0] + ", which is gone"
	}
	return ""
}

// The CPU names in ELF headers, against Go's names for the hardware.
var elfArch = map[elf.Machine]string{elf.EM_X86_64: "amd64", elf.EM_AARCH64: "arm64", elf.EM_386: "386", elf.EM_ARM: "arm", elf.EM_RISCV: "riscv64"}

func brokenELF(path string, m Machine) string {
	f, err := elf.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	if a, ok := elfArch[f.Machine]; ok && a != m.Arch && !(m.Arch == "amd64" && a == "386") && !m.Emulates(a) {
		return "it is built for " + archWords(a) + ", and this machine is " + archWords(m.Arch)
	}
	for _, p := range f.Progs {
		if p.Type != elf.PT_INTERP {
			continue
		}
		b := make([]byte, p.Filesz)
		if _, err := p.ReadAt(b, 0); err != nil {
			return ""
		}
		loader := strings.TrimRight(string(b), "\x00")
		if loader != "" && !m.Exists(loader) {
			if strings.Contains(loader, "ld-linux") || strings.Contains(loader, "ld64.so") {
				return "it is built for glibc and needs " + loader + ", which this system does not have"
			}
			return "it needs " + loader + ", which this system does not have"
		}
	}
	return ""
}

func brokenMachO(path string, head []byte, m Machine) (string, bool) {
	var file *macho.File
	if bytes.HasPrefix(head, []byte{0xca, 0xfe, 0xba, 0xbe}) {
		fat, err := macho.OpenFat(path)
		if err != nil {
			return "", false // also a Java class file, which shares the magic
		}
		defer fat.Close()
		want := macho.CpuArm64
		if m.Arch == "amd64" {
			want = macho.CpuAmd64
		}
		for _, a := range fat.Arches {
			if a.Cpu == want {
				file = a.File
			}
		}
		if file == nil {
			if m.Arch == "arm64" {
				for _, a := range fat.Arches {
					if a.Cpu == macho.CpuAmd64 {
						return intelOnly(a.File, m)
					}
				}
			}
			return "it has no part built for " + archWords(m.Arch), false
		}
	} else {
		f, err := macho.Open(path)
		if err != nil {
			return "", false
		}
		defer f.Close()
		file = f
		switch {
		case f.Cpu == macho.CpuAmd64 && m.Arch == "arm64":
			return intelOnly(f, m)
		case f.Cpu == macho.CpuArm64 && m.Arch == "amd64":
			return "it is built for Apple silicon, and this Mac is Intel", false
		}
	}
	return missingLibrary(file, m), false
}

func intelOnly(f *macho.File, m Machine) (string, bool) {
	if !m.Rosetta {
		return "it is built for Intel, and Rosetta is not installed", true
	}
	return missingLibrary(f, m), true
}

// missingLibrary finds a library the program loads by a fixed path that is no longer there. Apple's own libraries
// live in the system's shared cache rather than as files, and @rpath names are resolved at run time, so both are left out.
func missingLibrary(f *macho.File, m Machine) string {
	for _, l := range f.Loads {
		lib, ok := l.(*macho.Dylib)
		if !ok || !strings.HasPrefix(lib.Name, "/") || strings.HasPrefix(lib.Name, "/usr/lib/") || strings.HasPrefix(lib.Name, "/System/") {
			continue
		}
		if !m.Exists(lib.Name) {
			return "it needs " + lib.Name + ", which is gone"
		}
	}
	return ""
}

func archWords(a string) string {
	switch a {
	case "amd64":
		return "x86_64"
	case "386":
		return "32-bit x86"
	}
	return a
}
