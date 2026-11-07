// Package trash moves things to the system Trash. Every removal in Catalyst goes through here, and it only ever
// renames: nothing is copied or deleted, so a failure leaves the original exactly where it was.
package trash

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Moved says where something went.
type Moved struct {
	From, To string
	Info     string // the freedesktop .trashinfo file, on Linux
}

// Bin is the Trash for one user.
type Bin struct {
	OS   string
	Home string
	UID  int
	Now  func() time.Time
}

// New uses the real system.
func New(home string) *Bin {
	return &Bin{OS: runtime.GOOS, Home: home, UID: os.Getuid(), Now: time.Now}
}

func device(p string) (uint64, error) {
	var st syscall.Stat_t
	if err := syscall.Lstat(p, &st); err != nil {
		return 0, err
	}
	return uint64(st.Dev), nil
}

// top finds the root of the volume holding p, by walking up until the device changes.
func top(p string) string {
	d, err := device(p)
	if err != nil {
		return "/"
	}
	cur := filepath.Dir(p)
	for {
		parent := filepath.Dir(cur)
		if parent == cur {
			return cur
		}
		pd, err := device(parent)
		if err != nil || pd != d {
			return cur
		}
		cur = parent
	}
}

// folder picks the Trash folder on the same volume as path, so moving it is an instant rename.
func (b *Bin) folder(path string) (files, info string, err error) {
	pd, err := device(path)
	if err != nil {
		return "", "", err
	}
	hd, err := device(b.Home)
	if err != nil {
		return "", "", err
	}
	same := pd == hd
	if b.OS == "darwin" {
		if same {
			return filepath.Join(b.Home, ".Trash"), "", nil
		}
		return filepath.Join(top(path), ".Trashes", strconv.Itoa(b.UID)), "", nil
	}
	if same {
		root := filepath.Join(b.Home, ".local", "share", "Trash")
		return filepath.Join(root, "files"), filepath.Join(root, "info"), nil
	}
	root := filepath.Join(top(path), ".Trash-"+strconv.Itoa(b.UID))
	return filepath.Join(root, "files"), filepath.Join(root, "info"), nil
}

// Move sends path to the Trash under a name nothing else can have.
func (b *Bin) Move(path string) (Moved, error) {
	path = filepath.Clean(path)
	if !filepath.IsAbs(path) {
		return Moved{}, fmt.Errorf("%s is not a full path", path)
	}
	files, infoDir, err := b.folder(path)
	if err != nil {
		return Moved{}, err
	}
	if err := os.MkdirAll(files, 0o700); err != nil {
		return Moved{}, err
	}
	base := filepath.Base(path)
	name := base
	for i := 0; ; i++ {
		if i > 0 {
			name = fmt.Sprintf("%s.%d-%d", base, b.Now().Unix(), i)
		}
		if _, err := os.Lstat(filepath.Join(files, name)); errors.Is(err, os.ErrNotExist) {
			break
		}
		if i > 1000 {
			return Moved{}, fmt.Errorf("could not find a free name in the Trash for %s", base)
		}
	}
	m := Moved{From: path, To: filepath.Join(files, name)}
	if infoDir != "" {
		if err := os.MkdirAll(infoDir, 0o700); err != nil {
			return Moved{}, err
		}
		m.Info = filepath.Join(infoDir, name+".trashinfo")
		body := fmt.Sprintf("[Trash Info]\nPath=%s\nDeletionDate=%s\n", encode(path), b.Now().Format("2006-01-02T15:04:05"))
		if err := os.WriteFile(m.Info, []byte(body), 0o600); err != nil {
			return Moved{}, err
		}
	}
	if err := os.Rename(path, m.To); err != nil {
		if m.Info != "" {
			os.Remove(m.Info)
		}
		return Moved{}, err
	}
	return m, nil
}

func encode(p string) string {
	parts := strings.Split(p, "/")
	for i, s := range parts {
		parts[i] = url.PathEscape(s)
	}
	return strings.Join(parts, "/")
}

// Restore puts something back. It refuses to overwrite whatever has since appeared at the old path.
func Restore(from, to, info string) error {
	if _, err := os.Lstat(from); err == nil {
		return fmt.Errorf("something new is already at %s, so it was left in the Trash", from)
	}
	if _, err := os.Lstat(to); err != nil {
		return fmt.Errorf("it is no longer in the Trash (%s)", to)
	}
	if err := os.MkdirAll(filepath.Dir(from), 0o755); err != nil {
		return err
	}
	if err := os.Rename(to, from); err != nil {
		return err
	}
	if info != "" {
		os.Remove(info)
	}
	return nil
}
