// Package sysdata explains what macOS calls "System Data" and "macOS" in its storage settings, and which parts of it can
// be given back safely. It changes nothing: the command that shows it asks first, and runs only what Apple or the owning
// app supports.
//
// What is here came from measuring real machines and from what Apple, its forums and long-time macOS writers say about
// each place. The rule it follows: an area is offered only when there is a supported way to remove it, and that way is
// what runs. Everything else is shown, measured and explained, and locked.
package sysdata

import (
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/space"
	"github.com/theappfoundryco/catalyst/internal/sweep"
)

// Way is how an area can be removed, if it can.
type Way int

// The ways, from gentlest to the ones that need a password. Locked means never.
const (
	Trash    Way = iota // moved to the Trash, so Undo brings it back
	Owner               // the app that made it removes it, with its own command
	Settings            // the supported switch is in System Settings
	Root                // a supported system command, which needs your password
	Locked              // never touched
)

// Area is one place that takes space.
type Area struct {
	Name     string   `json:"name"`
	Path     string   `json:"path,omitempty"`
	Bytes    int64    `json:"bytes"`
	Count    int      `json:"count,omitempty"`
	Way      Way      `json:"way"`
	About    string   `json:"about"`              // what it is, in plain words
	Cost     string   `json:"cost,omitempty"`     // what removing it means
	Command  []string `json:"command,omitempty"`  // with Owner or Root
	Settings string   `json:"settings,omitempty"` // with Settings
	Admin    bool     `json:"-"`                  // its size can only be read in full with admin rights
}

// Report is everything found, biggest first within each way.
type Report struct {
	Areas []Area `json:"areas"`
}

// Measure is how big a folder is. Tests replace it.
type Measure func(path string) int64

func defaultMeasure(p string) int64 { return sweep.DirSize(p, sweep.NewSeen()) }

const (
	settingsWallpaper = "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
	settingsUpdate    = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
)

// Scan finds the areas. sys is macOS's own volumes from space.Measure, or nil.
func Scan(e *host.Env, sys *space.System, size Measure) Report {
	if size == nil {
		size = defaultMeasure
	}
	var out []Area
	add := func(a Area, floor int64) {
		if a.Bytes >= floor || a.Count > 0 {
			out = append(out, a)
		}
	}
	at := func(p string) (string, bool) {
		if strings.HasPrefix(p, "~/") {
			p = e.Path(strings.Split(p[2:], "/")...)
		}
		_, err := os.Stat(p)
		return p, err == nil
	}
	look := func(tool string) bool { _, err := e.Look(tool); return err == nil }
	const big = 300_000_000

	// Things another app made and removes properly.
	type owned struct {
		path, name, about, cost string
		cmd                     []string
		os                      string
	}
	for _, o := range []owned{
		{"~/.colima", "Colima's virtual machine", "The Linux machine Colima runs Docker in, with its images and containers.", "Its containers, images and volumes go with it. colima start makes a fresh one.", []string{"colima", "delete"}, ""},
		{"~/Library/Containers/com.docker.docker", "Docker Desktop's disk", "Docker Desktop's images, containers and build cache.", "Removes stopped containers, unused images and the build cache. It asks first.", []string{"docker", "system", "prune"}, "darwin"},
		{"~/.local/share/containers", "Podman's images", "Podman's images and containers.", "Removes what no container uses. It asks first.", []string{"podman", "system", "prune"}, "linux"},
		{"~/.cache/huggingface", "Hugging Face models", "Models downloaded by Python libraries such as transformers.", "You choose which models go. They download again when a script needs them.", []string{"huggingface-cli", "delete-cache"}, ""},
		{"~/Library/Developer/CoreSimulator", "iOS simulators", "Simulated iPhones and iPads for Xcode.", "Removes only simulators your Xcode can no longer run.", []string{"xcrun", "simctl", "delete", "unavailable"}, "darwin"},
	} {
		if o.os != "" && o.os != e.OS {
			continue
		}
		p, ok := at(o.path)
		if !ok {
			continue
		}
		a := Area{Name: o.name, Path: p, Way: Owner, About: o.about, Cost: o.cost, Command: o.cmd}
		if !look(o.cmd[0]) {
			a.Way, a.Command = Locked, nil
			a.Cost = "The tool that made it is not on your PATH, so there is no safe way to remove it from here."
		}
		a.Bytes = size(p)
		add(a, big)
	}
	if e.Mac() {
		if p, ok := at("~/Library/Developer/Xcode/DerivedData"); ok {
			add(Area{Name: "Xcode build data", Path: p, Way: Trash, Bytes: size(p), About: "Xcode's build products and indexes. They are made again on the next build.", Cost: "The next build of each project takes longer."}, big)
		}
		installers, _ := filepath.Glob("/Applications/Install macOS*.app")
		for _, p := range installers {
			add(Area{Name: strings.TrimSuffix(filepath.Base(p), ".app"), Path: p, Way: Trash, Bytes: size(p), About: "A full macOS installer, left after an upgrade or downloaded by hand.", Cost: "Only needed to make a bootable installer. It can be downloaded again."}, 1)
		}
		if s, ok := e.Out("tmutil", "listlocalsnapshots", "/"); ok {
			if n := strings.Count(s, "com.apple.TimeMachine."); n > 0 {
				out = append(out, Area{Name: "Time Machine snapshots", Count: n, Way: Root, About: "Hourly copies Time Machine keeps on this disk until the next backup reaches your backup drive.", Cost: "Restoring to those hours from this disk is no longer possible. macOS also removes them by itself when space runs low.", Command: []string{"tmutil", "deletelocalsnapshots", "/"}})
			}
		}
		if p, ok := at("/Library/Application Support/com.apple.idleassetsd/Customer"); ok {
			add(Area{Name: "Downloaded aerial wallpapers", Path: p, Way: Settings, Settings: settingsWallpaper, Bytes: size(p), About: "Moving wallpapers and screen savers macOS downloaded.", Cost: "Choose a still wallpaper, then remove the downloads in Wallpaper settings. Deleting the files by hand does not last: macOS downloads them again."}, big)
		}
		if p, ok := at("/Library/Updates"); ok {
			add(Area{Name: "Downloaded macOS update", Path: p, Way: Settings, Settings: settingsUpdate, Bytes: size(p), About: "An update macOS downloaded and has not installed yet.", Cost: "Install it in Software Update, and macOS removes the download by itself."}, 100_000_000)
		}
		// Owned by an app that manages it and has no command for it.
		for _, o := range []struct{ path, name, about string }{
			{"~/Library/Application Support/Claude/vm_bundles", "Claude app's virtual machine", "The Claude app's own sandbox. The app manages it and downloads it again if it goes, so leave it to the app."},
			{"~/Library/Application Support/MobileSync/Backup", "iPhone and iPad backups", "Local backups of your devices. Remove old ones in Finder: select the device, then Manage Backups."},
			{"~/.ollama/models", "Ollama models", "Models you pulled. Remove one with: ollama rm NAME"},
		} {
			if p, ok := at(o.path); ok {
				add(Area{Name: o.name, Path: p, Way: Locked, Bytes: size(p), About: o.about}, big)
			}
		}
		// macOS itself. Measured, explained, and never touched.
		if sys != nil {
			out = append(out,
				Area{Name: "The sealed system", Bytes: sys.Sealed, Way: Locked, About: "macOS itself, on a read-only volume that Apple signs and your Mac checks at every start. Nothing can change it, and nothing should try."},
				Area{Name: "Boot files", Bytes: sys.Boot, Way: Locked, About: "What your Mac needs to start, plus files kept for updates. It shrinks by itself after an update finishes."},
				Area{Name: "Recovery", Bytes: sys.Recovery, Way: Locked, About: "The small macOS you can start into to repair or reinstall this one. Keep it."},
			)
		}
		swap := Area{Name: "Swap and sleep image", Path: "/private/var/vm", Way: Locked, About: "Memory moved onto the disk when apps need more than the Mac has, plus a copy of memory kept for deep sleep. Quit big apps or restart, and it shrinks by itself."}
		if sys != nil {
			swap.Bytes = sys.Swap
		}
		out = append(out, swap)
		for _, l := range []struct{ path, name, about string }{
			{"/private/var/folders", "Temporary files", "Every app's temporary files, for every user. Deleting them under running apps can crash them. A restart clears what can safely go."},
			{"/private/var/db/diagnostics", "System logs", "Kept at a steady size by macOS itself. Deleting them breaks crash reports and Apple's diagnostics, and gives back little."},
			{"/private/var/db/uuidtext", "Log index", "What the system logs need to be read. It is managed with them."},
			{"/System/Library/AssetsV2", "Apple's downloaded assets", "Voices, dictionaries, Siri and Apple Intelligence models. macOS adds and removes them as features need. Deleting them by hand needs Recovery mode, Apple does not support it, and they download again."},
			{"/Library/Developer/CommandLineTools", "Command Line Tools", "git, make and the compilers come from here. Removing it breaks them."},
			{"/Library/Caches", "System caches", "Caches for the system's own services. macOS clears them when it needs to."},
		} {
			if _, err := os.Stat(l.path); err != nil {
				continue
			}
			out = append(out, Area{Name: l.name, Path: l.path, Way: Locked, Bytes: size(l.path), About: l.about, Admin: true})
		}
	} else {
		if s, ok := e.Out("journalctl", "--disk-usage"); ok {
			if n := journalBytes(s); n > 200_000_000 {
				out = append(out, Area{Name: "System journal", Path: "/var/log/journal", Bytes: n, Way: Root, About: "Every system log since it began.", Cost: "Logs older than two weeks go. Recent ones stay.", Command: []string{"journalctl", "--vacuum-time=2weeks"}})
			}
		}
		for _, p := range []struct {
			path, name, tool string
			cmd              []string
		}{
			{"/var/cache/apt/archives", "Downloaded apt packages", "apt-get", []string{"apt-get", "clean"}},
			{"/var/cache/dnf", "Downloaded dnf packages", "dnf", []string{"dnf", "clean", "all"}},
			{"/var/cache/pacman/pkg", "Downloaded pacman packages", "paccache", []string{"paccache", "-r"}},
		} {
			if !look(p.tool) {
				continue
			}
			if n := size(p.path); n > 100_000_000 {
				out = append(out, Area{Name: p.name, Path: p.path, Bytes: n, Way: Root, About: "Copies of packages already installed.", Cost: "They download again only if you reinstall something.", Command: p.cmd})
			}
		}
		if look("apt-get") {
			out = append(out, Area{Name: "Packages nothing needs", Way: Root, About: "Old kernels and libraries left after updates.", Cost: "apt lists exactly what it would remove and asks you before it does.", Command: []string{"apt-get", "autoremove"}})
		}
		for _, l := range []struct{ path, name, about string }{
			{"/usr", "Installed programs", "Everything your package manager installed. Remove programs with it, never by hand."},
			{"/boot", "Kernels", "What the machine starts from. Old kernels go with apt autoremove."},
		} {
			if _, err := os.Stat(l.path); err == nil {
				out = append(out, Area{Name: l.name, Path: l.path, Bytes: size(l.path), Way: Locked, About: l.about})
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Way != out[j].Way {
			return out[i].Way < out[j].Way
		}
		return out[i].Bytes > out[j].Bytes
	})
	return Report{Areas: out}
}

func journalBytes(s string) int64 {
	i := strings.Index(s, "take up ")
	if i < 0 {
		return 0
	}
	f := strings.Fields(s[i+len("take up "):])
	if len(f) == 0 {
		return 0
	}
	v := f[0]
	mult := map[byte]float64{'K': 1e3, 'M': 1e6, 'G': 1e9, 'T': 1e12}
	m, ok := mult[v[len(v)-1]]
	if !ok {
		return 0
	}
	var n float64
	for _, c := range v[:len(v)-1] {
		switch {
		case c >= '0' && c <= '9':
			n = n*10 + float64(c-'0')
		case c == '.':
			// keep the whole part; the size only needs to be about right
			return int64(n * m)
		}
	}
	return int64(n * m)
}

// Selectable says whether an area can be ticked.
func (a Area) Selectable() bool { return a.Way != Locked }

// Undoable says whether removing it can be reversed.
func (a Area) Undoable() bool { return a.Way == Trash }

// WayWords is the short label beside an area.
func (a Area) WayWords() string {
	switch a.Way {
	case Trash:
		return "to the Trash, undo works"
	case Owner:
		return "its own app removes it"
	case Settings:
		return "the switch is in Settings"
	case Root:
		return "needs your password"
	}
	return "never touched"
}
