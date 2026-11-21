package host

import (
	"bytes"
	"encoding/binary"
	"os"
	"strings"
)

// ExecKind reads the first bytes of a program and says what it is built for: "arm64", "x86_64", "universal" (a Mac
// binary for both), "script (bash)" and so on, or "" when it cannot tell. Plain parsing, so it runs on any file.
func ExecKind(head []byte) string {
	switch {
	case len(head) >= 2 && head[0] == '#' && head[1] == '!':
		line := string(head[2:])
		if i := strings.IndexByte(line, '\n'); i >= 0 {
			line = line[:i]
		}
		f := strings.Fields(line)
		if len(f) == 0 {
			return "script"
		}
		interp := f[0][strings.LastIndex(f[0], "/")+1:]
		if interp == "env" && len(f) > 1 {
			interp = f[len(f)-1]
			if strings.HasPrefix(interp, "-") && len(f) > 2 {
				interp = f[2]
			}
		}
		return "script (" + interp + ")"
	case len(head) >= 20 && bytes.Equal(head[:4], []byte{0x7f, 'E', 'L', 'F'}):
		order := binary.ByteOrder(binary.LittleEndian)
		if head[5] == 2 {
			order = binary.BigEndian
		}
		switch order.Uint16(head[18:20]) {
		case 0x3e:
			return "x86_64"
		case 0xb7:
			return "arm64"
		case 0x03:
			return "x86 (32-bit)"
		case 0x28:
			return "arm (32-bit)"
		}
		return "Linux program"
	case len(head) >= 8 && (bytes.Equal(head[:4], []byte{0xcf, 0xfa, 0xed, 0xfe}) || bytes.Equal(head[:4], []byte{0xce, 0xfa, 0xed, 0xfe})):
		switch binary.LittleEndian.Uint32(head[4:8]) {
		case 0x01000007:
			return "x86_64"
		case 0x0100000c:
			return "arm64"
		}
		return "Mac program"
	case len(head) >= 4 && bytes.Equal(head[:4], []byte{0xca, 0xfe, 0xba, 0xbe}):
		return "universal"
	}
	return ""
}

// ExecKindOf reads a file's header.
func ExecKindOf(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	head := make([]byte, 256)
	n, _ := f.Read(head)
	return ExecKind(head[:n])
}
