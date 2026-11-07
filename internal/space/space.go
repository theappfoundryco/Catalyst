// Package space answers "where did my disk go?". It measures, names and explains. It never removes anything: big things
// that belong to another tool are shown with that tool's own way to remove them, because only that tool knows what is
// safe to drop from its own data.
package space

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"

	"github.com/theappfoundryco/catalyst/internal/host"
)

// Landmark is a place known to grow large, with what it is and how to make it smaller.
type Landmark struct {
	Rel   string // under the home folder
	Name  string
	How   string // the owner's way to remove it, or why it should stay
	Clean bool   // catalyst clean can take it, because it rebuilds itself
	OS    string // "darwin", "linux" or "" for both
}

// Landmarks are checked in this order. Only the ones over the floor in Measure are shown.
var Landmarks = []Landmark{
	{Rel: "Library/Application Support/Claude/vm_bundles", Name: "Claude app's virtual machine", How: "Belongs to the Claude app, which manages it. Leave it.", OS: "darwin"},
	{Rel: ".cache/huggingface", Name: "Hugging Face models", How: "huggingface-cli delete-cache"},
	{Rel: ".ollama/models", Name: "Ollama models", How: "ollama rm NAME"},
	{Rel: ".lmstudio/models", Name: "LM Studio models", How: "Remove models in LM Studio"},
	{Rel: ".colima", Name: "Colima virtual machine", How: "colima delete  (its containers go with it)"},
	{Rel: ".lima", Name: "Lima virtual machines", How: "limactl delete NAME"},
	{Rel: ".orbstack", Name: "OrbStack", How: "In OrbStack, Settings, Storage"},
	{Rel: "Library/Containers/com.docker.docker", Name: "Docker Desktop's disk", How: "docker system prune, then Docker Desktop, Settings, Resources", OS: "darwin"},
	{Rel: ".local/share/containers", Name: "Podman containers and images", How: "podman system prune", OS: "linux"},
	{Rel: ".local/share/docker", Name: "Docker (rootless)", How: "docker system prune", OS: "linux"},
	{Rel: "Library/Developer/CoreSimulator", Name: "iOS simulators", How: "xcrun simctl delete unavailable", OS: "darwin"},
	{Rel: "Library/Developer/Xcode/iOS DeviceSupport", Name: "Xcode device support", How: "Delete the iOS versions you no longer test on", OS: "darwin"},
	{Rel: "Library/Developer/Xcode/DerivedData", Name: "Xcode build data", How: "It rebuilds itself.", Clean: true, OS: "darwin"},
	{Rel: "Library/Application Support/MobileSync/Backup", Name: "iPhone and iPad backups", How: "Finder, your device, Manage Backups", OS: "darwin"},
	{Rel: ".android/avd", Name: "Android emulators", How: "Android Studio, Device Manager"},
	{Rel: "Library/Caches", Name: "App caches", How: "They rebuild themselves.", Clean: true, OS: "darwin"},
	{Rel: ".cache", Name: "Tool caches", How: "Most rebuild themselves", OS: "linux"},
	{Rel: "Library/Logs", Name: "App logs", How: "Old ones can go.", Clean: true, OS: "darwin"},
	{Rel: "Library/Mail", Name: "Mail", How: "Mail, Settings, Accounts", OS: "darwin"},
	{Rel: "Library/Messages/Attachments", Name: "Messages attachments", How: "System Settings, General, Storage, Messages", OS: "darwin"},
	{Rel: ".Trash", Name: "Trash", How: "Empty the Trash in Finder", OS: "darwin"},
	{Rel: ".local/share/Trash", Name: "Trash", How: "Empty the Trash", OS: "linux"},
	{Rel: "Downloads", Name: "Downloads", How: "Yours to sort through"},
}

// Entry is one measured folder.
type Entry struct {
	Path  string   `json:"path"`
	Name  string   `json:"name"`
	Bytes int64    `json:"bytes"`
	How   string   `json:"how,omitempty"`
	Clean bool     `json:"cleanable,omitempty"`
	Top   []string `json:"-"`
}

// System is what macOS shows as "macOS" in its storage settings: its own volumes, none of which a person can clear.
type System struct {
	Sealed, Boot, Recovery, Swap int64
}

// Total is all of it.
func (s System) Total() int64 { return s.Sealed + s.Boot + s.Recovery + s.Swap }

// Report is a measured disk.
type Report struct {
	Disk       host.Volume `json:"disk"`
	DiskOK     bool        `json:"-"`
	Home       []Entry     `json:"home"`
	Apps       int64       `json:"applications,omitempty"`
	System     *System     `json:"system,omitempty"`
	Landmarks  []Entry     `json:"landmarks"`
	Unreadable int         `json:"unreadable_folders"`
}

// Options control a measure. Floor hides anything smaller from the landmark list.
type Options struct {
	Env      *host.Env
	Floor    int64
	Progress func(path string)
}

// Measure walks the home folder, the apps and the known landmarks. Folders it may not read are counted, never guessed.
func Measure(o Options) Report {
	e := o.Env
	r := Report{}
	r.Disk, r.DiskOK = e.HomeVolume()
	sizer := newSizer()
	entries, _ := os.ReadDir(e.Home)
	var mu sync.Mutex
	var wg sync.WaitGroup
	slots := make(chan struct{}, 8)
	measure := func(p string, done func(int64)) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			slots <- struct{}{}
			defer func() { <-slots }()
			if o.Progress != nil {
				mu.Lock()
				o.Progress(p)
				mu.Unlock()
			}
			n := sizer.size(p)
			mu.Lock()
			done(n)
			mu.Unlock()
		}()
	}
	for _, ent := range entries {
		p := filepath.Join(e.Home, ent.Name())
		if !ent.IsDir() {
			var st syscall.Stat_t
			if syscall.Lstat(p, &st) == nil {
				r.Home = append(r.Home, Entry{Path: p, Name: ent.Name(), Bytes: int64(st.Blocks) * 512})
			}
			continue
		}
		name := ent.Name()
		measure(p, func(n int64) { r.Home = append(r.Home, Entry{Path: p, Name: name, Bytes: n}) })
	}
	if e.Mac() {
		measure("/Applications", func(n int64) { r.Apps = n })
	}
	// Landmarks sit inside the home folder, so they get their own pass with a fresh inode set: shared hard links
	// would otherwise be counted only for whichever walk reached them first.
	marks := newSizer()
	for _, l := range Landmarks {
		if l.OS != "" && l.OS != e.OS {
			continue
		}
		p := e.Path(strings.Split(l.Rel, "/")...)
		if _, err := os.Stat(p); err != nil {
			continue
		}
		l := l
		wg.Add(1)
		go func() {
			defer wg.Done()
			slots <- struct{}{}
			defer func() { <-slots }()
			n := marks.size(p)
			mu.Lock()
			r.Landmarks = append(r.Landmarks, Entry{Path: p, Name: l.Name, Bytes: n, How: l.How, Clean: l.Clean})
			mu.Unlock()
		}()
	}
	wg.Wait()
	r.Landmarks = apart(r.Landmarks, o.Floor)
	sort.Slice(r.Home, func(i, j int) bool { return r.Home[i].Bytes > r.Home[j].Bytes })
	sort.Slice(r.Landmarks, func(i, j int) bool { return r.Landmarks[i].Bytes > r.Landmarks[j].Bytes })
	r.Unreadable = sizer.denied
	if e.Mac() {
		if out, ok := e.Out("diskutil", "apfs", "list"); ok {
			s := ParseAPFS(out, r.Disk.Name)
			if s.Total() > 0 {
				r.System = &s
			}
		}
	}
	return r
}

// apart stops one place being counted twice: a landmark that holds another, like ~/.cache holding Hugging Face's
// models, keeps only what is left once the one inside has its own row. Then anything under the floor goes.
func apart(marks []Entry, floor int64) []Entry {
	var out []Entry
	for _, m := range marks {
		n := m.Bytes
		for _, inner := range marks {
			if inner.Path != m.Path && strings.HasPrefix(inner.Path, m.Path+string(filepath.Separator)) {
				n -= inner.Bytes
			}
		}
		if n >= floor && n > 0 {
			m.Bytes = n
			out = append(out, m)
		}
	}
	return out
}

// sizer adds up the blocks folders really take, counting each hard-linked file once, and counts what it could not read.
type sizer struct {
	mu     sync.Mutex
	seen   map[[2]uint64]bool
	denied int
}

func newSizer() *sizer { return &sizer{seen: map[[2]uint64]bool{}} }

func (z *sizer) first(dev, ino uint64) bool {
	z.mu.Lock()
	defer z.mu.Unlock()
	k := [2]uint64{dev, ino}
	if z.seen[k] {
		return false
	}
	z.seen[k] = true
	return true
}

func (z *sizer) size(root string) int64 {
	var total int64
	var top syscall.Stat_t
	if syscall.Lstat(root, &top) != nil {
		return 0
	}
	var visit func(dir string)
	visit = func(dir string) {
		entries, err := os.ReadDir(dir)
		if err != nil {
			if os.IsPermission(err) {
				z.mu.Lock()
				z.denied++
				z.mu.Unlock()
			}
			return
		}
		for _, ent := range entries {
			p := filepath.Join(dir, ent.Name())
			var st syscall.Stat_t
			if syscall.Lstat(p, &st) != nil {
				continue
			}
			if uint64(st.Dev) != uint64(top.Dev) { // another disk mounted inside, such as a network share
				continue
			}
			if st.Nlink <= 1 || ent.IsDir() || z.first(uint64(st.Dev), uint64(st.Ino)) {
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

var (
	volLine  = regexp.MustCompile(`APFS Volume Disk \(Role\):\s+(\S+)\s+\(([^)]*)\)`)
	usedLine = regexp.MustCompile(`Capacity Consumed:\s+(\d+) B`)
)

// ParseAPFS reads `diskutil apfs list` for the volumes macOS counts as itself. Only the container that holds the data
// volume counts: an external APFS disk has its own roles. dataDevice is the data volume's device, such as /dev/disk3s1.
func ParseAPFS(text, dataDevice string) System {
	var s System
	want := ""
	if m := regexp.MustCompile(`disk(\d+)s\d+`).FindStringSubmatch(dataDevice); m != nil {
		want = "disk" + m[1] + "s"
	}
	role := ""
	dev := ""
	for _, line := range strings.Split(text, "\n") {
		if m := volLine.FindStringSubmatch(line); m != nil {
			dev, role = m[1], m[2]
			continue
		}
		m := usedLine.FindStringSubmatch(line)
		if m == nil || role == "" {
			continue
		}
		if want != "" && !strings.HasPrefix(dev, want) {
			role = ""
			continue
		}
		n, _ := strconv.ParseInt(m[1], 10, 64)
		switch role {
		case "System":
			s.Sealed += n
		case "Preboot":
			s.Boot += n
		case "Recovery":
			s.Recovery += n
		case "VM":
			s.Swap += n
		}
		role = ""
	}
	return s
}
