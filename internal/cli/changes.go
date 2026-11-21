package cli

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/theappfoundryco/catalyst/internal/state"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

// snapTools are the tools whose version a snapshot keeps, each with the flag that only prints it.
var snapTools = []struct{ name, flag string }{
	{"git", "--version"}, {"node", "--version"}, {"npm", "--version"}, {"python3", "--version"}, {"pip3", "--version"},
	{"go", "version"}, {"ruby", "--version"}, {"java", "-version"}, {"docker", "--version"}, {"brew", "--version"},
	{"cargo", "--version"}, {"rustc", "--version"}, {"make", "--version"}, {"cc", "--version"},
}

// snapshot reads the toolchain as a new terminal sees it. Versions are asked at the same time, so it adds about as
// long as the slowest tool takes.
func (a *App) snapshot(score int) state.Snapshot {
	s := state.Snapshot{Date: a.E.Now(), Score: score, Tools: map[string]string{}, Files: map[string]string{}, Path: append([]string{}, a.E.Entries...)}
	p := a.E.Platform()
	s.OS = strings.TrimSpace(p.Pretty + " " + p.Kernel)
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, t := range snapTools {
		path, ok := a.E.SafeTool(t.name)
		if !ok {
			continue
		}
		wg.Add(1)
		go func(name, path, flag string) {
			defer wg.Done()
			v := "does not run"
			if r := a.E.Run.Run(8*time.Second, path, flag); r.OK() {
				v = firstText(r.Stdout + "\n" + r.Stderr)
			}
			mu.Lock()
			s.Tools[name] = path + " " + v
			mu.Unlock()
		}(t.name, path, t.flag)
	}
	wg.Wait()
	for _, rc := range a.E.RCFiles() {
		h := ""
		if b, err := os.ReadFile(rc); err == nil {
			sum := sha256.Sum256(b)
			h = hex.EncodeToString(sum[:6])
		}
		s.Files[a.E.Tilde(rc)] = h
	}
	return s
}

// Diff lists what changed from one snapshot to the next, in words, most telling first: the system, then tools,
// then startup files, then PATH.
func Diff(old, now state.Snapshot) []string {
	var out []string
	if old.OS != now.OS && old.OS != "" {
		out = append(out, "The system changed: "+old.OS+" is now "+now.OS)
	}
	names := map[string]bool{}
	for n := range old.Tools {
		names[n] = true
	}
	for n := range now.Tools {
		names[n] = true
	}
	var sorted []string
	for n := range names {
		sorted = append(sorted, n)
	}
	sort.Strings(sorted)
	for _, n := range sorted {
		was, is := old.Tools[n], now.Tools[n]
		switch {
		case was == "":
			out = append(out, n+" appeared: "+is)
		case is == "":
			out = append(out, n+" is gone (it was "+was+")")
		case was != is:
			wp, wv, _ := strings.Cut(was, " ")
			ip, iv, _ := strings.Cut(is, " ")
			switch {
			case wp != ip && wv == iv:
				out = append(out, n+" now runs from "+ip+" instead of "+wp)
			case wp != ip:
				out = append(out, n+" changed: "+wv+" from "+wp+" is now "+iv+" from "+ip)
			default:
				out = append(out, n+" changed: "+wv+" is now "+iv)
			}
		}
	}
	var files []string
	for f := range now.Files {
		files = append(files, f)
	}
	sort.Strings(files)
	for _, f := range files {
		was, is := old.Files[f], now.Files[f]
		_, known := old.Files[f]
		switch {
		case !known || was == is:
		case was == "":
			out = append(out, f+" was created")
		case is == "":
			out = append(out, f+" was deleted")
		default:
			out = append(out, f+" was edited")
		}
	}
	before := map[string]bool{}
	for _, d := range old.Path {
		before[d] = true
	}
	after := map[string]bool{}
	for _, d := range now.Path {
		if !before[d] && !after[d] && len(old.Path) > 0 {
			out = append(out, "PATH gained "+d)
		}
		after[d] = true
	}
	lost := map[string]bool{}
	for _, d := range old.Path {
		if !after[d] && !lost[d] {
			lost[d] = true
			out = append(out, "PATH lost "+d)
		}
	}
	if len(out) == 0 && strings.Join(old.Path, ":") != strings.Join(now.Path, ":") && len(old.Path) > 0 {
		out = append(out, "PATH has the same folders in a different order")
	}
	return out
}

// cmdChanges says what moved in the toolchain since an earlier day: versions, where tools run from, startup files,
// PATH and the system itself. Doctor saves a snapshot each day it runs. Nothing is changed.
func cmdChanges(a *App, args []string) int {
	fs := a.flags("changes", "[--json]")
	asJSON := fs.Bool("json", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	u := a.U
	saved := a.Store.Snapshots()
	var base *state.Snapshot
	for i := len(saved) - 1; i >= 0; i-- {
		if !sameDay(saved[i].Date, a.E.Now()) {
			base = &saved[i]
			break
		}
	}
	if base == nil && len(saved) > 0 {
		base = &saved[0]
	}
	a.E.LoadShell()
	now := a.snapshot(-1)
	if *asJSON {
		type report struct {
			Since   *time.Time `json:"since"`
			Changes []string   `json:"changes"`
		}
		r := report{Changes: []string{}}
		if base != nil {
			r.Since, r.Changes = &base.Date, Diff(*base, now)
			if r.Changes == nil {
				r.Changes = []string{}
			}
		}
		return emit(a, r)
	}
	u.Hdr("What changed")
	if base == nil {
		u.Say("  " + u.Dim("Nothing to compare with yet. Doctor saves what your tools look like each day it runs, and this compares today with an earlier day."))
		u.Hint("Run catalyst doctor now, and come back when something stops working.")
		u.Blank()
		return ExitOK
	}
	diff := a.scrubHome(Diff(*base, now))
	since := "Since " + ui.When(base.Date)
	if base.Score >= 0 {
		since += ", when doctor scored " + strconv.Itoa(base.Score)
	}
	u.Say("  " + u.Dim(since))
	u.Blank()
	if len(diff) == 0 {
		u.Ok("Nothing changed: the same tools, versions, startup files and PATH")
	}
	for _, line := range diff {
		u.Note(line)
	}
	u.Blank()
	return ExitOK
}

func (a *App) scrubHome(lines []string) []string {
	out := make([]string, len(lines))
	for i, l := range lines {
		out[i] = strings.ReplaceAll(l, a.E.Home+"/", "~/")
	}
	return out
}

func sameDay(x, y time.Time) bool {
	ay, am, ad := x.Local().Date()
	by, bm, bd := y.Local().Date()
	return ay == by && am == bm && ad == bd
}

func firstText(s string) string {
	for _, l := range strings.Split(s, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			return l
		}
	}
	return ""
}
