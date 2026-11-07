// Package clean finds what can go outside your projects: app caches and old logs, which rebuild themselves. It is the
// other half of sweep, which handles what sits inside projects.
//
// Three rules keep it safe, learned from what system cleaners get wrong:
//   - Only what rebuilds itself is offered, and an app's cache only while the app is closed. Apple's own caches are left
//     to macOS, which manages them.
//   - Things that are big but are someone's chosen data, like models, virtual machines and backups, are reported with
//     their own tool's way to remove them. Catalyst never deletes those.
//   - Areas that need admin rights are measured and explained, never touched. Where a command helps, it is printed for
//     the person to run.
package clean

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"

	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/space"
	"github.com/theappfoundryco/catalyst/internal/sweep"
)

// Item is one folder that can go to the Trash.
type Item struct {
	Path  string `json:"path"`
	Name  string `json:"name"`
	Kind  string `json:"kind"` // "cache" or "logs"
	Bytes int64  `json:"bytes"`
	About string `json:"about"`
}

// Admin is an area that needs admin rights. Command is empty when the system manages it by itself.
type Admin struct {
	Name    string `json:"name"`
	Bytes   int64  `json:"bytes,omitempty"`
	Count   int    `json:"count,omitempty"`
	Note    string `json:"note"`
	Command string `json:"command,omitempty"`
}

// Report is what a scan found.
type Report struct {
	Items   []Item        `json:"items"`
	Open    []string      `json:"skipped_open_apps"` // apps whose cache was left because they are running
	Owned   []space.Entry `json:"owned_by_other_tools"`
	Admin   []Admin       `json:"admin"`
	Skipped int           `json:"skipped_small"`
}

// Total is the size of every item.
func (r Report) Total() int64 {
	var t int64
	for _, i := range r.Items {
		t += i.Bytes
	}
	return t
}

// Options control a scan.
type Options struct {
	Env      *host.Env
	MinSize  int64 // a cache smaller than this is not worth a row
	Progress func(path string)
}

// Known names for cache folders that are not named after an app.
var known = map[string]string{
	"ms-playwright":     "Playwright browsers",
	"claude-cli-nodejs": "Claude Code's cache",
	"JetBrains":         "JetBrains IDEs",
	"node-gyp":          "node-gyp headers",
	"typescript":        "TypeScript",
	"Cypress":           "Cypress",
	"electron":          "Electron downloads",
	"pnpm":              "pnpm store cache",
	"bun":               "Bun",
	"composer":          "Composer",
	"CocoaPods":         "CocoaPods",
	"puppeteer":         "Puppeteer browsers",
	"google-chrome":     "Chrome",
	"mozilla":           "Firefox",
	"thumbnails":        "Thumbnails",
}

// Left alone, because they are not caches in practice or belong to the system:
// Apple's own services, account and keychain helpers, iCloud, and anything sweep already offers.
var leave = map[string]bool{
	"CloudKit": true, "FamilyCircle": true, "GeoServices": true, "com.apple.bird": true,
	"Homebrew": true, "pip": true, "Yarn": true, "yarn": true, "go-build": true, // these are in sweep
	"huggingface": true, // models, not a cache: reported instead
	"mole":        true,
}

// Scan looks, measures and decides. It changes nothing.
func Scan(o Options) Report {
	e := o.Env
	r := Report{}
	if o.MinSize == 0 {
		o.MinSize = 50_000_000
	}
	running := Running(e)
	names := AppNames(e)
	var cacheRoot string
	if e.Mac() {
		cacheRoot = e.Path("Library", "Caches")
	} else {
		cacheRoot = e.Path(".cache")
	}
	type cand struct {
		path, name, kind, about, owner string
	}
	var cands []cand
	if entries, err := os.ReadDir(cacheRoot); err == nil {
		for _, ent := range entries {
			n := ent.Name()
			if !ent.IsDir() || leave[n] || strings.HasPrefix(n, "com.apple.") || strings.HasPrefix(n, ".") {
				continue
			}
			label, owner := label(n, names)
			cands = append(cands, cand{filepath.Join(cacheRoot, n), label, "cache", "Cached data for " + label + ". It is made again when needed.", owner})
		}
	}
	if e.Mac() {
		if entries, err := os.ReadDir(e.Path("Library", "Logs")); err == nil {
			for _, ent := range entries {
				n := ent.Name()
				if !ent.IsDir() || n == "mole" {
					continue
				}
				label, owner := label(n, names)
				cands = append(cands, cand{e.Path("Library", "Logs", n), label + " logs", "logs", "Old log files. Apps write new ones as they need them.", owner})
			}
		}
	}
	var mu sync.Mutex
	var wg sync.WaitGroup
	slots := make(chan struct{}, 8)
	seen := sweep.NewSeen()
	openSet := map[string]bool{}
	for _, c := range cands {
		c := c
		if isRunning(c.owner, filepath.Base(c.path), running) {
			if c.kind == "cache" {
				openSet[c.name] = true
			}
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			slots <- struct{}{}
			defer func() { <-slots }()
			if o.Progress != nil {
				mu.Lock()
				o.Progress(c.path)
				mu.Unlock()
			}
			n := sweep.DirSize(c.path, seen)
			mu.Lock()
			defer mu.Unlock()
			min := o.MinSize
			if c.kind == "logs" {
				min = o.MinSize / 5
			}
			if n < min {
				r.Skipped++
				return
			}
			r.Items = append(r.Items, Item{Path: c.path, Name: c.name, Kind: c.kind, Bytes: n, About: c.about})
		}()
	}
	for name := range openSet {
		r.Open = append(r.Open, name)
	}
	sort.Strings(r.Open)
	var owned space.Report
	wg.Add(1)
	go func() {
		defer wg.Done()
		owned = space.Measure(space.Options{Env: e, Floor: 500_000_000, LandmarksOnly: true})
	}()
	wg.Wait()
	sort.Slice(r.Items, func(i, j int) bool { return r.Items[i].Bytes > r.Items[j].Bytes })
	for _, l := range owned.Landmarks {
		if !l.Clean && l.Name != "Downloads" {
			r.Owned = append(r.Owned, l)
		}
	}
	r.Admin = admin(e)
	return r
}

// label is the name a person knows for a cache folder, and the app it belongs to when that is known.
func label(folder string, names map[string]string) (string, string) {
	if n, ok := names[folder]; ok {
		return n, folder
	}
	if n, ok := known[folder]; ok {
		return n, folder
	}
	// "com.adobe.LightroomClassicCC7" reads better as its last part.
	if strings.Count(folder, ".") >= 2 {
		parts := strings.Split(folder, ".")
		return parts[len(parts)-1], folder
	}
	return folder, folder
}

// isRunning matches a cache folder to a running app by its bundle identifier, or on Linux by its program's name.
func isRunning(owner, folder string, running map[string]bool) bool {
	for _, k := range []string{owner, folder, strings.ToLower(folder)} {
		if running[k] {
			return true
		}
	}
	// A helper's cache, such as com.spotify.client.helper, belongs to the app it starts with.
	for id := range running {
		if strings.Contains(id, ".") && strings.HasPrefix(folder, id+".") {
			return true
		}
	}
	return false
}

var bundleID = regexp.MustCompile(`bundleID="([^"]+)"`)

// Running lists what is open: bundle identifiers on a Mac, program names on Linux.
func Running(e *host.Env) map[string]bool {
	out := map[string]bool{}
	if e.Mac() {
		if s, ok := e.Out("lsappinfo", "list"); ok {
			for _, m := range bundleID.FindAllStringSubmatch(s, -1) {
				out[m[1]] = true
			}
		}
		return out
	}
	if s, ok := e.Out("ps", "-eo", "comm="); ok {
		for _, l := range strings.Split(s, "\n") {
			if l = strings.TrimSpace(l); l != "" {
				out[strings.ToLower(filepath.Base(l))] = true
			}
		}
	}
	return out
}

// AppNames maps bundle identifiers to the names people see, from the apps in /Applications.
func AppNames(e *host.Env) map[string]string {
	out := map[string]string{}
	if !e.Mac() {
		return out
	}
	var apps []string
	// Some apps sit one folder down, such as /Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app.
	for _, pattern := range []string{"/Applications/*.app", "/Applications/*/*.app", e.Path("Applications") + "/*.app"} {
		found, _ := filepath.Glob(pattern)
		apps = append(apps, found...)
	}
	for _, app := range apps {
		if id, ok := e.Out("plutil", "-extract", "CFBundleIdentifier", "raw", "-o", "-", filepath.Join(app, "Contents", "Info.plist")); ok {
			out[strings.TrimSpace(id)] = strings.TrimSuffix(filepath.Base(app), ".app")
		}
	}
	return out
}

var journalUse = regexp.MustCompile(`take up ([\d.]+)([KMGT])`)

// admin measures what needs admin rights and says what can be done about each. It never touches them.
func admin(e *host.Env) []Admin {
	var out []Admin
	if e.Mac() {
		if s, ok := e.Out("tmutil", "listlocalsnapshots", "/"); ok {
			if n := strings.Count(s, "com.apple.TimeMachine."); n > 0 {
				out = append(out, Admin{Name: "Time Machine snapshots on this disk", Count: n,
					Note:    "macOS removes these by itself when space runs low. To remove them now:",
					Command: "sudo tmutil deletelocalsnapshots /"})
			}
		}
		for _, p := range []struct{ path, name string }{{"/Library/Caches", "System caches"}, {"/private/var/log", "System logs"}} {
			if n := sweep.DirSize(p.path, sweep.NewSeen()); n > 200_000_000 {
				out = append(out, Admin{Name: p.name, Bytes: n, Note: "macOS manages these itself, so Catalyst leaves them."})
			}
		}
		return out
	}
	if s, ok := e.Out("journalctl", "--disk-usage"); ok {
		if m := journalUse.FindStringSubmatch(s); m != nil {
			f, _ := strconv.ParseFloat(m[1], 64)
			mult := map[string]float64{"K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12}[m[2]]
			if n := int64(f * mult); n > 200_000_000 {
				out = append(out, Admin{Name: "System journal", Bytes: n, Note: "Keeps every log. To keep two weeks of it:", Command: "sudo journalctl --vacuum-time=2weeks"})
			}
		}
	}
	for _, p := range []struct{ path, name, cmd string }{
		{"/var/cache/apt/archives", "Downloaded apt packages", "sudo apt-get clean"},
		{"/var/cache/dnf", "Downloaded dnf packages", "sudo dnf clean all"},
		{"/var/cache/pacman/pkg", "Downloaded pacman packages", "sudo paccache -r"},
	} {
		if n := sweep.DirSize(p.path, sweep.NewSeen()); n > 200_000_000 {
			out = append(out, Admin{Name: p.name, Bytes: n, Note: "Copies of installed packages. To remove them:", Command: p.cmd})
		}
	}
	return out
}
