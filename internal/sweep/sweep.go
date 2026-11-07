// Package sweep finds build artifacts that are safe to reclaim. Being safe is the whole point, so a folder has to clear
// four separate tests before it is offered: a marker proves what kind of project it is, it cannot be a symlink, git must
// confirm it is ignored and holds no tracked files, and the project must have been idle for a while.
package sweep

import (
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/theappfoundryco/catalyst/internal/host"
)

// Cost says what getting it back takes.
type Cost string

// The two costs.
const (
	Safe    Cost = "safe"    // rebuilds itself on next use
	Rebuild Cost = "rebuild" // needs a command to get back
)

// Rule describes one kind of artifact. New ecosystems are one line here.
type Rule struct {
	Dir      string   // folder name
	Needs    []string // one of these must sit beside it, proving the project type. Empty means none needed.
	Inside   string   // or this must sit inside it
	Title    string
	Restore  string // how to get it back
	Cost     Cost
	NeedsGit bool // a name too common to trust on its own: only offered when git confirms it is ignored
}

// Rules is the table. Order only matters for two rules with the same folder name.
var Rules = []Rule{
	{Dir: "node_modules", Needs: []string{"package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb"}, Title: "Node packages", Restore: "npm install", Cost: Rebuild},
	{Dir: ".venv", Inside: "pyvenv.cfg", Title: "Python virtual environment", Restore: "python3 -m venv", Cost: Rebuild},
	{Dir: "venv", Inside: "pyvenv.cfg", Title: "Python virtual environment", Restore: "python3 -m venv", Cost: Rebuild},
	{Dir: "__pycache__", Title: "Python bytecode", Restore: "rebuilds itself", Cost: Safe},
	{Dir: ".pytest_cache", Title: "pytest cache", Restore: "rebuilds itself", Cost: Safe},
	{Dir: ".mypy_cache", Title: "mypy cache", Restore: "rebuilds itself", Cost: Safe},
	{Dir: ".ruff_cache", Title: "Ruff cache", Restore: "rebuilds itself", Cost: Safe},
	{Dir: ".tox", Needs: []string{"tox.ini", "pyproject.toml", "setup.cfg"}, Title: "tox environments", Restore: "tox", Cost: Rebuild},
	{Dir: "target", Needs: []string{"Cargo.toml"}, Title: "Rust build output", Restore: "cargo build", Cost: Rebuild},
	{Dir: "target", Needs: []string{"pom.xml"}, Title: "Maven build output", Restore: "mvn package", Cost: Rebuild},
	{Dir: "build", Needs: []string{"build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"}, Title: "Gradle build output", Restore: "gradle build", Cost: Rebuild},
	{Dir: ".gradle", Needs: []string{"build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"}, Title: "Gradle project cache", Restore: "rebuilds itself", Cost: Safe},
	{Dir: "build", Needs: []string{"Makefile", "CMakeLists.txt", "package.json", "pubspec.yaml", "setup.py", "pyproject.toml"}, Title: "Build output", Restore: "run your build", Cost: Rebuild, NeedsGit: true},
	{Dir: "dist", Needs: []string{"package.json", "setup.py", "pyproject.toml"}, Title: "Build output", Restore: "run your build", Cost: Rebuild, NeedsGit: true},
	{Dir: ".next", Needs: []string{"package.json"}, Title: "Next.js build", Restore: "next build", Cost: Rebuild},
	{Dir: ".nuxt", Needs: []string{"package.json"}, Title: "Nuxt build", Restore: "nuxt build", Cost: Rebuild},
	{Dir: ".svelte-kit", Needs: []string{"package.json"}, Title: "SvelteKit build", Restore: "vite build", Cost: Rebuild},
	{Dir: ".turbo", Needs: []string{"package.json"}, Title: "Turborepo cache", Restore: "rebuilds itself", Cost: Safe},
	{Dir: ".parcel-cache", Needs: []string{"package.json"}, Title: "Parcel cache", Restore: "rebuilds itself", Cost: Safe},
	{Dir: "Pods", Needs: []string{"Podfile"}, Title: "CocoaPods", Restore: "pod install", Cost: Rebuild},
	{Dir: ".dart_tool", Needs: []string{"pubspec.yaml"}, Title: "Dart tool cache", Restore: "dart pub get", Cost: Rebuild},
	{Dir: "zig-cache", Needs: []string{"build.zig"}, Title: "Zig cache", Restore: "rebuilds itself", Cost: Safe},
	{Dir: ".zig-cache", Needs: []string{"build.zig"}, Title: "Zig cache", Restore: "rebuilds itself", Cost: Safe},
}

// Global is a cache outside any project. These always rebuild themselves.
type Global struct {
	Path  string
	Title string
}

// Globals lists the caches for this system. Only developer tools: Catalyst does not clean the system or other apps.
func Globals(e *host.Env) []Global {
	var out []Global
	if e.Mac() {
		out = append(out, Global{e.Path("Library", "Caches", "Homebrew"), "Homebrew downloads"})
		out = append(out, Global{e.Path("Library", "Caches", "pip"), "pip cache"})
		out = append(out, Global{e.Path("Library", "Caches", "Yarn"), "Yarn cache"})
		out = append(out, Global{e.Path("Library", "Caches", "go-build"), "Go build cache"})
		out = append(out, Global{e.Path("Library", "Developer", "Xcode", "DerivedData", "ModuleCache.noindex"), "Xcode shared module cache"})
	} else {
		out = append(out, Global{e.Path(".cache", "Homebrew"), "Homebrew downloads"})
		out = append(out, Global{e.Path(".cache", "pip"), "pip cache"})
		out = append(out, Global{e.Path(".cache", "yarn"), "Yarn cache"})
		out = append(out, Global{e.Path(".cache", "go-build"), "Go build cache"})
	}
	out = append(out, Global{e.Path(".npm", "_cacache"), "npm cache"})
	return out
}

// Item is one folder that can be reclaimed.
type Item struct {
	Path    string    `json:"path"`
	Title   string    `json:"title"`
	Project string    `json:"project"`
	Restore string    `json:"restore"`
	Cost    Cost      `json:"cost"`
	Size    int64     `json:"size"`
	Active  time.Time `json:"last_active"`
	Global  bool      `json:"global"`
}

// Options control a scan.
type Options struct {
	Roots     []string
	OlderThan time.Duration
	MinSize   int64
	Globals   bool
	Env       *host.Env
	Progress  func(scanned int, path string)
}

// Report is what a scan found. Skipped counts are shown to people, because seeing what was protected is what builds trust.
type Report struct {
	Items         []Item `json:"items"`
	SkippedRecent int    `json:"skipped_recent"`
	SkippedGit    int    `json:"skipped_tracked"`
	SkippedSmall  int    `json:"skipped_small"`
	Scanned       int    `json:"scanned"`
}

// Total is the size of all items.
func (r Report) Total() int64 {
	var t int64
	for _, i := range r.Items {
		t += i.Size
	}
	return t
}

// skipAlways never contains projects, and some hold things deleting would really hurt.
var skipAlways = map[string]bool{".git": true, ".Trash": true, ".Trashes": true, ".ssh": true, ".gnupg": true, "Library": true, ".cache": true, ".npm": true, ".nvm": true, ".cargo": true, ".rustup": true, ".pyenv": true, ".rbenv": true, ".local": true, ".config": true, ".vscode": true, ".cursor": true}

// mediaFolders are the top-level home folders --deep leaves alone.
var mediaFolders = map[string]bool{"Library": true, "Music": true, "Pictures": true, "Movies": true, "Public": true, "Applications": true, "snap": true}

// DefaultRoots are where projects usually live.
func DefaultRoots(e *host.Env) []string {
	var out []string
	for _, n := range []string{"Desktop", "Documents", "Developer", "Projects", "projects", "Code", "code", "src", "dev", "work", "repos", "git", "Downloads", "workspace"} {
		p := e.Path(n)
		if st, err := os.Stat(p); err == nil && st.IsDir() && !slices.Contains(out, p) {
			out = append(out, p)
		}
	}
	return out
}

// DeepRoots is every visible folder in home, leaving out media and app folders.
func DeepRoots(e *host.Env) []string {
	var out []string
	entries, _ := os.ReadDir(e.Home)
	for _, ent := range entries {
		if ent.IsDir() && !strings.HasPrefix(ent.Name(), ".") && !mediaFolders[ent.Name()] {
			out = append(out, e.Path(ent.Name()))
		}
	}
	return out
}

type candidate struct {
	path string
	rule Rule
}

// Scan walks the roots and returns what is safe to offer.
func Scan(o Options) Report {
	var rep Report
	var cands []candidate
	repos := newRepoCache(o.Env)
	for _, root := range o.Roots {
		root = filepath.Clean(root)
		walk(root, &rep.Scanned, o.Progress, func(dir string, name string) bool {
			rule, ok := ruleFor(dir, name)
			if !ok {
				return false
			}
			cands = append(cands, candidate{filepath.Join(dir, name), rule})
			return true
		})
	}
	seen := NewSeen()
	now := o.Env.Now()
	var mu sync.Mutex
	var wg sync.WaitGroup
	slots := make(chan struct{}, 4)
	for _, c := range cands {
		wg.Add(1)
		slots <- struct{}{}
		go func(c candidate) {
			defer wg.Done()
			defer func() { <-slots }()
			item, why := assess(c, repos, o, seen, now)
			mu.Lock()
			defer mu.Unlock()
			switch why {
			case "":
				rep.Items = append(rep.Items, item)
			case "recent":
				rep.SkippedRecent++
			case "git":
				rep.SkippedGit++
			case "small":
				rep.SkippedSmall++
			}
		}(c)
	}
	wg.Wait()
	if o.Globals {
		rep.Items = append(rep.Items, scanGlobals(o, seen)...)
		rep.Items = append(rep.Items, derivedData(o, seen, now)...)
	}
	// Biggest first: where the space is matters more than where the folder is.
	sort.Slice(rep.Items, func(i, j int) bool { return rep.Items[i].Size > rep.Items[j].Size })
	return rep
}

// walk visits every folder without following symlinks, and asks visit about each child folder. true means it was claimed,
// so nothing inside it needs looking at.
func walk(root string, scanned *int, progress func(int, string), visit func(dir, name string) bool) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return
	}
	for _, ent := range entries {
		if !ent.IsDir() { // a symlink to a folder reports false here, so it is never entered or offered
			continue
		}
		name := ent.Name()
		*scanned++
		if progress != nil && *scanned%200 == 0 {
			progress(*scanned, root)
		}
		if skipAlways[name] || isBundle(name) {
			continue
		}
		if visit(root, name) {
			continue
		}
		walk(filepath.Join(root, name), scanned, progress, visit)
	}
}

// isBundle spots macOS app packages. An Electron app holds a node_modules beside a package.json, and removing it breaks the app.
func isBundle(name string) bool {
	for _, ext := range []string{".app", ".framework", ".bundle", ".xcarchive", ".appex", ".plugin", ".kext"} {
		if strings.HasSuffix(name, ext) {
			return true
		}
	}
	return false
}

func ruleFor(dir, name string) (Rule, bool) {
	for _, r := range Rules {
		if r.Dir != name {
			continue
		}
		if r.Inside != "" {
			if host.Exists(filepath.Join(dir, name, r.Inside)) {
				return r, true
			}
			continue
		}
		if len(r.Needs) == 0 {
			return r, true
		}
		for _, n := range r.Needs {
			if host.Exists(filepath.Join(dir, n)) {
				return r, true
			}
		}
	}
	return Rule{}, false
}

func assess(c candidate, repos *repoCache, o Options, seen *Seen, now time.Time) (Item, string) {
	if st, err := os.Lstat(c.path); err != nil || st.Mode()&os.ModeSymlink != 0 || !st.IsDir() {
		return Item{}, "git"
	}
	parent := filepath.Dir(c.path)
	repo := repos.root(parent)
	if repo != "" {
		switch repos.disposable(repo, c.path) {
		case verdictNo, verdictUnknown:
			return Item{}, "git"
		}
	} else if c.rule.NeedsGit {
		return Item{}, "git" // "build" or "dist" with no git to confirm it: could be anything
	}
	active := Activity(parent, repo, c.rule.Dir)
	if o.OlderThan > 0 && now.Sub(active) < o.OlderThan {
		return Item{}, "recent"
	}
	size := DirSize(c.path, seen)
	if size < o.MinSize {
		return Item{}, "small"
	}
	project := filepath.Base(parent)
	if repo != "" {
		project = filepath.Base(repo)
		if rel, err := filepath.Rel(repo, parent); err == nil && rel != "." {
			project = filepath.Join(project, rel)
		}
	}
	return Item{Path: c.path, Title: c.rule.Title, Project: project, Restore: c.rule.Restore, Cost: c.rule.Cost, Size: size, Active: active}, ""
}

func cruftName(name string) bool {
	if name == ".git" || name == ".DS_Store" {
		return true
	}
	for _, r := range Rules {
		if r.Dir == name {
			return true
		}
	}
	return false
}

// Activity is the newest sign of a person working on a project: git state or source files, whichever is later.
// Artifact folders are ignored, since a background tool touching node_modules is not work. Editing without staging still
// counts, which is the case the old app missed.
func Activity(project, repo, artifact string) time.Time {
	var newest time.Time
	see := func(t time.Time) {
		if t.After(newest) {
			newest = t
		}
	}
	if repo != "" {
		for _, m := range []string{".git/index", ".git/HEAD", ".git/logs/HEAD"} {
			if st, err := os.Stat(filepath.Join(repo, m)); err == nil {
				see(st.ModTime())
			}
		}
	}
	budget := 5000
	var visit func(dir string, depth int)
	visit = func(dir string, depth int) {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, ent := range entries {
			if budget <= 0 {
				return
			}
			budget--
			name := ent.Name()
			if name == artifact || cruftName(name) {
				continue
			}
			info, err := ent.Info()
			if err != nil {
				continue
			}
			see(info.ModTime())
			if ent.IsDir() && depth < 4 {
				visit(filepath.Join(dir, name), depth+1)
			}
		}
	}
	visit(project, 0)
	return newest
}

// Seen counts each file once across a whole scan, so hard links (pnpm is built on them) do not inflate the total.
type Seen struct {
	mu sync.Mutex
	m  map[[2]uint64]bool
}

// NewSeen starts an empty set.
func NewSeen() *Seen { return &Seen{m: map[[2]uint64]bool{}} }

func (s *Seen) first(dev, ino uint64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [2]uint64{dev, ino}
	if s.m[k] {
		return false
	}
	s.m[k] = true
	return true
}

// DirSize adds up the blocks a folder really takes on disk, which is what you get back. Symlinks count only as themselves.
func DirSize(root string, seen *Seen) int64 {
	var total int64
	var visit func(dir string)
	visit = func(dir string) {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, ent := range entries {
			p := filepath.Join(dir, ent.Name())
			var st syscall.Stat_t
			if syscall.Lstat(p, &st) != nil {
				continue
			}
			if st.Nlink <= 1 || ent.IsDir() || seen.first(uint64(st.Dev), uint64(st.Ino)) {
				total += int64(st.Blocks) * 512
			}
			if ent.IsDir() {
				visit(p)
			}
		}
	}
	visit(root)
	return total
}

func scanGlobals(o Options, seen *Seen) []Item {
	var out []Item
	for _, g := range Globals(o.Env) {
		if !host.Exists(g.Path) {
			continue
		}
		size := DirSize(g.Path, seen)
		if size < o.MinSize {
			continue
		}
		out = append(out, Item{Path: g.Path, Title: g.Title, Project: g.Title, Restore: "rebuilds itself", Cost: Safe, Size: size, Global: true})
	}
	return out
}

// derivedData offers Xcode's per-project build folders. Each counts as its own project, so one built this week stays.
func derivedData(o Options, seen *Seen, now time.Time) []Item {
	if !o.Env.Mac() {
		return nil
	}
	root := o.Env.Path("Library", "Developer", "Xcode", "DerivedData")
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	var out []Item
	for _, ent := range entries {
		if !ent.IsDir() || strings.HasSuffix(ent.Name(), ".noindex") {
			continue
		}
		info, err := ent.Info()
		if err != nil || (o.OlderThan > 0 && now.Sub(info.ModTime()) < o.OlderThan) {
			continue
		}
		p := filepath.Join(root, ent.Name())
		size := DirSize(p, seen)
		if size < o.MinSize {
			continue
		}
		name := ent.Name()
		if i := strings.LastIndex(name, "-"); i > 0 {
			name = name[:i]
		}
		out = append(out, Item{Path: p, Title: "Xcode build output", Project: name, Restore: "rebuilds next time you build", Cost: Safe, Size: size, Active: info.ModTime(), Global: true})
	}
	return out
}
