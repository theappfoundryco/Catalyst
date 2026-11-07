package host

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// StartupItem is something that starts by itself.
type StartupItem struct {
	Name    string
	Kind    string // "User agent", "System agent", "System daemon", "User service", "System service", "Autostart", "Cron"
	Program string // what it runs, "" when unknown
	Path    string // the file that defines it
	Loaded  bool
	Broken  bool // its program no longer exists
	Mine    bool // can be changed without root
}

// StartupItems lists everything that starts by itself on this machine.
func (e *Env) StartupItems() []StartupItem {
	if e.Mac() {
		return e.macStartup()
	}
	return e.linuxStartup()
}

// LaunchPlist is the part of a launchd plist Catalyst reads.
type LaunchPlist struct {
	Label            string   `json:"Label"`
	Program          string   `json:"Program"`
	ProgramArguments []string `json:"ProgramArguments"`
}

// ParseLaunchPlist reads plutil's JSON output. It returns the label and the program it starts.
func ParseLaunchPlist(text string) (LaunchPlist, bool) {
	var p LaunchPlist
	if json.Unmarshal([]byte(text), &p) != nil {
		return p, false
	}
	if p.Program == "" && len(p.ProgramArguments) > 0 {
		p.Program = p.ProgramArguments[0]
	}
	return p, true
}

func (e *Env) macStartup() []StartupItem {
	loaded := map[string]bool{}
	if s, ok := e.Out("launchctl", "list"); ok {
		for _, l := range strings.Split(s, "\n") {
			if f := strings.Fields(l); len(f) >= 3 {
				loaded[f[2]] = true
			}
		}
	}
	dirs := []struct {
		dir, kind string
		mine      bool
	}{
		{e.Path("Library", "LaunchAgents"), "User agent", true},
		{"/Library/LaunchAgents", "System agent", false},
		{"/Library/LaunchDaemons", "System daemon", false},
	}
	var out []StartupItem
	for _, d := range dirs {
		files, _ := filepath.Glob(filepath.Join(d.dir, "*.plist"))
		for _, f := range files {
			it := StartupItem{Name: strings.TrimSuffix(filepath.Base(f), ".plist"), Kind: d.kind, Path: f, Mine: d.mine}
			if s, ok := e.Out("plutil", "-convert", "json", "-o", "-", f); ok {
				if p, ok := ParseLaunchPlist(s); ok {
					if p.Label != "" {
						it.Name = p.Label
					}
					it.Program = p.Program
					// Only an absolute path can be checked. A bare name is found by launchd's own search.
					it.Broken = strings.HasPrefix(p.Program, "/") && !Exists(p.Program)
				}
			}
			it.Loaded = loaded[it.Name]
			out = append(out, it)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Mine && !out[j].Mine })
	return out
}

func (e *Env) linuxStartup() []StartupItem {
	var out []StartupItem
	add := func(kind string, mine bool, args ...string) {
		s, ok := e.Out("systemctl", args...)
		if !ok {
			return
		}
		for _, name := range ParseUnitFiles(s) {
			out = append(out, StartupItem{Name: name, Kind: kind, Mine: mine, Loaded: true})
		}
	}
	add("User service", true, "--user", "list-unit-files", "--type=service", "--state=enabled", "--no-legend", "--plain")
	add("System service", false, "list-unit-files", "--type=service", "--state=enabled", "--no-legend", "--plain")
	files, _ := filepath.Glob(e.Path(".config", "autostart", "*.desktop"))
	for _, f := range files {
		out = append(out, StartupItem{Name: strings.TrimSuffix(filepath.Base(f), ".desktop"), Kind: "Autostart", Path: f, Mine: true})
	}
	if s, ok := e.Out("crontab", "-l"); ok {
		for _, l := range strings.Split(s, "\n") {
			l = strings.TrimSpace(l)
			if l != "" && !strings.HasPrefix(l, "#") {
				out = append(out, StartupItem{Name: l, Kind: "Cron", Mine: true})
			}
		}
	}
	return out
}

// ParseUnitFiles reads the unit names from systemctl list-unit-files.
func ParseUnitFiles(text string) []string {
	var out []string
	for _, l := range strings.Split(text, "\n") {
		if f := strings.Fields(l); len(f) > 0 && strings.Contains(f[0], ".") {
			out = append(out, f[0])
		}
	}
	return out
}

// ParseFailedUnits reads the unit names from systemctl --failed.
func ParseFailedUnits(text string) []string { return ParseUnitFiles(text) }

// SSHKey is one key pair in ~/.ssh.
type SSHKey struct {
	Name        string
	Type        string
	Bits        int
	Fingerprint string
	Comment     string
	Private     string // path, "" when only the public half is here
	Public      string
	Mode        os.FileMode // of the private key
	Weak        bool
}

// PrivateKeyFiles finds private keys by their content, so a key not named id_* is still found. It reads no more than the header.
func (e *Env) PrivateKeyFiles() []string {
	dir := e.Path(".ssh")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, ent := range entries {
		if !ent.Type().IsRegular() || strings.HasSuffix(ent.Name(), ".pub") {
			continue
		}
		f, err := os.Open(filepath.Join(dir, ent.Name()))
		if err != nil {
			continue
		}
		buf := make([]byte, 64)
		n, _ := f.Read(buf)
		f.Close()
		if strings.Contains(string(buf[:n]), "PRIVATE KEY-----") {
			out = append(out, filepath.Join(dir, ent.Name()))
		}
	}
	return out
}

var keygenRe = regexp.MustCompile(`^(\d+)\s+(\S+)\s+(.*?)\s*\((\w+)\)\s*$`)

// ParseKeygen reads one line of ssh-keygen -l: "256 SHA256:abc comment (ED25519)".
func ParseKeygen(line string) (bits int, fingerprint, comment, kind string, ok bool) {
	m := keygenRe.FindStringSubmatch(strings.TrimSpace(line))
	if m == nil {
		return 0, "", "", "", false
	}
	bits, _ = strconv.Atoi(m[1])
	return bits, m[2], m[3], m[4], true
}

// SSHKeys lists the key pairs in ~/.ssh. Fingerprints come from the public half when it exists, so nothing has to unlock a key.
func (e *Env) SSHKeys() []SSHKey {
	dir := e.Path(".ssh")
	byName := map[string]*SSHKey{}
	for _, p := range e.PrivateKeyFiles() {
		k := &SSHKey{Name: filepath.Base(p), Private: p}
		if st, err := os.Stat(p); err == nil {
			k.Mode = st.Mode().Perm()
		}
		byName[k.Name] = k
	}
	pubs, _ := filepath.Glob(filepath.Join(dir, "*.pub"))
	for _, p := range pubs {
		name := strings.TrimSuffix(filepath.Base(p), ".pub")
		k, ok := byName[name]
		if !ok {
			k = &SSHKey{Name: name}
			byName[name] = k
		}
		k.Public = p
	}
	var out []SSHKey
	for _, k := range byName {
		target := k.Public
		if target == "" {
			target = k.Private
		}
		if s, ok := e.Out("ssh-keygen", "-l", "-f", target); ok {
			if bits, fp, c, kind, ok := ParseKeygen(s); ok {
				k.Bits, k.Fingerprint, k.Comment, k.Type = bits, fp, c, kind
				k.Weak = kind == "DSA" || (kind == "RSA" && bits < 2048)
			}
		}
		out = append(out, *k)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}
