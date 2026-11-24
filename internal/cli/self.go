package cli

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/theappfoundryco/catalyst/internal/journal"
	"github.com/theappfoundryco/catalyst/internal/ui"
	"github.com/theappfoundryco/catalyst/internal/version"
)

// Newer reports whether release a is newer than b, comparing number by number. A dev build counts as older than anything.
func Newer(a, b string) bool {
	pa, pb := parts(a), parts(b)
	for i := 0; i < 3; i++ {
		if pa[i] != pb[i] {
			return pa[i] > pb[i]
		}
	}
	return strings.Contains(b, "-") && !strings.Contains(a, "-")
}

func parts(v string) [3]int {
	v = strings.TrimPrefix(v, "v")
	if i := strings.IndexByte(v, '-'); i >= 0 {
		v = v[:i]
	}
	var out [3]int
	for i, s := range strings.SplitN(v, ".", 3) {
		out[i], _ = strconv.Atoi(s)
	}
	return out
}

func fetch(url string, limit int64) ([]byte, error) {
	c := &http.Client{Timeout: 2 * time.Minute}
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "catalyst/"+version.Version)
	resp, err := c.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("the server answered %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, limit))
}

func cmdUpdate(a *App, args []string) int {
	fs := a.flags("update", "[--check] [--yes]")
	check := fs.Bool("check", false, "")
	yes := fs.Bool("yes", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	a.U.Yes = a.U.Yes || *yes
	u := a.U
	self, err := os.Executable()
	if err != nil {
		u.Stop(err.Error())
		return ExitFailed
	}
	self, _ = filepath.EvalSymlinks(self)
	if strings.Contains(self, "/Cellar/") {
		u.Say("  Homebrew installed this copy, so update it with: brew upgrade catalyst")
		return ExitOK
	}
	var tag string
	u.Blank()
	if err := u.Step("Asking GitHub for the newest release", "Found the newest release", func(*ui.Spinner) (string, error) {
		b, err := fetch("https://api.github.com/repos/"+version.Repo+"/releases/latest", 1<<20)
		if err != nil {
			return "", err
		}
		var r struct {
			Tag string `json:"tag_name"`
		}
		if err := json.Unmarshal(b, &r); err != nil {
			return "", err
		}
		tag = r.Tag
		return "", nil
	}); err != nil {
		return ExitFailed
	}
	if !Newer(tag, version.Version) {
		u.Ok("You are on the newest version (" + strings.TrimPrefix(version.Version, "v") + ").")
		u.Blank()
		return ExitOK
	}
	u.Say("  " + u.Bold(strings.TrimPrefix(tag, "v")) + " is out. You have " + strings.TrimPrefix(version.Version, "v") + ".")
	u.Hint("What changed: https://github.com/" + version.Repo + "/releases/tag/" + tag)
	if *check {
		u.Blank()
		return ExitOK
	}
	if !u.AskYes("Update now?") {
		return ExitOK
	}
	name := fmt.Sprintf("catalyst_%s_%s.tar.gz", a.E.OS, a.E.Arch)
	base := "https://github.com/" + version.Repo + "/releases/download/" + tag + "/"
	var bin []byte
	if err := u.Step("Downloading "+tag, "Downloaded and verified "+tag, func(*ui.Spinner) (string, error) {
		archive, err := fetch(base+name, 200<<20)
		if err != nil {
			return "", err
		}
		sums, err := fetch(base+"SHA256SUMS", 1<<20)
		if err != nil {
			return "", err
		}
		if err := VerifySum(archive, name, string(sums)); err != nil {
			return "", err
		}
		bin, err = extractBinary(archive)
		return "", err
	}); err != nil {
		return ExitFailed
	}
	tmp := self + ".new"
	if err := os.WriteFile(tmp, bin, 0o755); err != nil {
		u.Stop("Could not write the new version: " + err.Error())
		return ExitFailed
	}
	if err := os.Rename(tmp, self); err != nil {
		os.Remove(tmp)
		u.Stop("Could not replace the old version: " + err.Error())
		return ExitFailed
	}
	u.Ok("Now on " + tag)
	if a.linkKit(self) == kitAdded {
		u.Ok("You can also type kit now.")
	}
	if a.inSession { // this running copy is still the old one, so the session restarts as the new one
		u.Say("  " + u.Dim("Press Enter to open "+tag+"."))
		a.outcome.Restart = self
		a.outcome.Farewell = []string{"  Catalyst is now on " + tag + ". Run catalyst again to use it."}
	}
	u.Blank()
	return ExitOK
}

// VerifySum checks an archive against a SHA256SUMS file. A release with no matching line is refused, never trusted.
func VerifySum(data []byte, name, sums string) error {
	got := sha256.Sum256(data)
	for _, l := range strings.Split(sums, "\n") {
		f := strings.Fields(l)
		if len(f) == 2 && strings.TrimPrefix(f[1], "*") == name {
			if f[0] == hex.EncodeToString(got[:]) {
				return nil
			}
			return fmt.Errorf("the download does not match its checksum, so it was not used")
		}
	}
	return fmt.Errorf("the release has no checksum for %s, so it was not used", name)
}

func extractBinary(archive []byte) ([]byte, error) {
	gz, err := gzip.NewReader(bytes.NewReader(archive))
	if err != nil {
		return nil, err
	}
	t := tar.NewReader(gz)
	for {
		h, err := t.Next()
		if err != nil {
			return nil, fmt.Errorf("the download holds no catalyst program")
		}
		if filepath.Base(h.Name) == "catalyst" && h.Typeflag == tar.TypeReg {
			return io.ReadAll(io.LimitReader(t, 200<<20))
		}
	}
}

func cmdUninstall(a *App, args []string) int {
	fs := a.flags("uninstall", "[--yes]")
	yes := fs.Bool("yes", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	a.U.Yes = a.U.Yes || *yes
	u := a.U
	self, _ := os.Executable()
	self, _ = filepath.EvalSymlinks(self)
	if strings.Contains(self, "/Cellar/") {
		u.Say("  Homebrew installed this copy, so remove it with: brew uninstall catalyst")
		return ExitOK
	}
	u.Sect("This removes")
	u.Hint(a.E.Tilde(self))
	u.Hint("Catalyst's line in your shell startup file, if it added one, and the kit shortcut")
	u.Hint(a.E.Tilde(a.Store.Dir) + " and " + a.E.Tilde(a.Store.ConfigDir))
	u.Hint("What is in the Trash stays there. Anything it moved is yours to keep or empty.")
	u.Sect("This stays")
	if a.brew() != "" {
		u.Hint("Homebrew, and everything installed with it, such as smartmontools. Catalyst never removes them.")
	} else {
		u.Hint("Helper tools such as smartmontools, and everything else your package manager installed. Catalyst never removes them.")
	}
	if !u.Ask("Remove Catalyst?") {
		return ExitOK
	}
	a.removePathLines()
	if a.ownKit(filepath.Join(filepath.Dir(self), "kit")) {
		os.Remove(filepath.Join(filepath.Dir(self), "kit"))
	}
	os.RemoveAll(a.Store.Dir)
	os.RemoveAll(a.Store.ConfigDir)
	if err := os.Remove(self); err != nil {
		u.Stop("Could not remove " + self + ": " + err.Error())
		return ExitFailed
	}
	u.Ok("Catalyst is gone.")
	a.outcome.Quit = true
	a.outcome.Farewell = []string{"  Catalyst is gone. What it moved to the Trash is still there, and Homebrew is untouched."}
	u.Blank()
	return ExitOK
}

// The names the old Mac app left things under.
const (
	legacyKeychain = "com.catalyst.app.adminCredential"
	legacyHelper   = "com.shivanggulati.catalyst.helper"
	legacyBundle   = "com.shivanggulati.catalyst"
	legacySource   = ".zshrc_catalyst"
)

// cmdLegacy cleans up after the old Mac app. It shows each thing first and removes it only with a yes.
func cmdLegacy(a *App, args []string) int {
	fs := a.flags("legacy", "[--yes]")
	yes := fs.Bool("yes", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	a.U.Yes = a.U.Yes || *yes
	u := a.U
	if !a.E.Mac() {
		u.Say("  " + u.Dim("The old Catalyst app only ran on a Mac, so there is nothing to clean up here."))
		return ExitOK
	}
	batch := journal.NewBatch(a.E.Now())
	found := 0
	u.Sect("Left behind by the old Catalyst app")
	trashIt := func(path, what string) {
		if _, err := os.Lstat(path); err != nil {
			return
		}
		found++
		u.Say("  " + what)
		u.Hint(a.E.Tilde(path))
		if u.Ask("Move it to the Trash?") {
			if err := a.moveToTrash(path, "Old Catalyst app: "+what, batch, 0); err != nil {
				u.Stop(err.Error())
			} else {
				u.Ok("Moved")
			}
		}
	}
	trashIt("/Applications/Catalyst.app", "The app itself")
	trashIt(a.E.Path("Library", "Application Support", legacyBundle), "Its settings and history")
	trashIt(a.E.Path("Library", "Caches", legacyBundle), "Its cache")
	rc := a.E.Path(".zshrc")
	if b, err := os.ReadFile(rc); err == nil && strings.Contains(string(b), legacySource) {
		found++
		u.Say("  The line in ~/.zshrc that loads ~/" + legacySource)
		if a.editStartup(startupEdit{Path: rc, Title: "Remove the line that loads ~/" + legacySource, Change: dropSourceLines, Ask: true, Batch: batch, Mends: true, Quiet: true}) {
			u.Ok("Removed. Undo puts it back.")
		}
		for _, n := range sharedSourceLines(string(b)) {
			u.Note(fmt.Sprintf("Line %d of ~/.zshrc loads ~/%s along with other commands, so it was left for you to edit.", n, legacySource))
		}
	}
	trashIt(a.E.Path(legacySource), "~/"+legacySource+", which holds aliases and shortcuts the app wrote. Look through it first if you made any you want to keep")
	trashIt(a.E.Path(legacySource+".backup"), "Its backup")
	if a.E.Run.Run(0, "security", "find-generic-password", "-s", legacyKeychain).OK() { // never asks for or prints the value
		found++
		u.Say("  The admin password the app saved in your Keychain")
		if u.AskYes("Delete it from the Keychain?") {
			if a.E.Run.Run(0, "security", "delete-generic-password", "-s", legacyKeychain).OK() {
				u.Ok("Deleted")
			} else {
				u.Stop("Could not delete it. Open Keychain Access and search for " + legacyKeychain)
			}
		}
	}
	helper := "/Library/PrivilegedHelperTools/" + legacyHelper
	plist := "/Library/LaunchDaemons/" + legacyHelper + ".plist"
	if _, err := os.Lstat(helper); err == nil {
		found++
		u.Say("  The app's helper tool, which runs as root")
		u.Hint("Catalyst never asks for your password, so run this yourself:")
		u.Hint("sudo launchctl bootout system/" + legacyHelper + "; sudo rm " + helper + " " + plist)
	}
	if found == 0 {
		u.Ok("Nothing. This Mac is clean.")
	}
	u.Blank()
	return ExitOK
}

// sourceLine is a line that does nothing but load the old app's file: source ~/.zshrc_catalyst, . "$HOME/...", or
// either after a test that the file is there. A line that does more than that is never removed whole.
var sourceLine = regexp.MustCompile(`^\s*((\[\[?|test)\s+-[fers]\s+\S*` + regexp.QuoteMeta(legacySource) + `\S*\s*(\]\]?)?\s*&&\s*)?(source|\.)\s+\S*` + regexp.QuoteMeta(legacySource) + `\S*\s*(#.*)?$`)

// dropSourceLines removes the lines that only load the old app's file.
func dropSourceLines(lines []string) []string {
	var out []string
	for _, l := range lines {
		if !sourceLine.MatchString(strings.TrimRight(l, "\r")) {
			out = append(out, l)
		}
	}
	return out
}

// sharedSourceLines are the lines that load the old app's file among other commands, by line number.
func sharedSourceLines(text string) []int {
	var out []int
	for i, l := range strings.Split(text, "\n") {
		t := strings.TrimSpace(l)
		if strings.Contains(l, legacySource) && !strings.HasPrefix(t, "#") && !sourceLine.MatchString(strings.TrimRight(l, "\r")) {
			out = append(out, i+1)
		}
	}
	return out
}

// The kit command is a link to catalyst, in the same folder, so either name runs the same program.
const (
	kitAdded = iota
	kitThere
	kitTaken // something else is called kit, and it is left alone
	kitNo    // not here: Homebrew owns this copy, or the folder cannot be written
)

// ownKit says whether path is our kit link: a link to catalyst, and not someone else's program.
func (a *App) ownKit(path string) bool {
	to, err := os.Readlink(path)
	return err == nil && filepath.Base(to) == "catalyst"
}

// linkKit puts the kit link beside the program. It never replaces anything, and never shadows another kit on the PATH.
func (a *App) linkKit(self string) int {
	if self == "" || strings.Contains(self, "/Cellar/") {
		return kitNo
	}
	kit := filepath.Join(filepath.Dir(self), "kit")
	if a.ownKit(kit) {
		return kitThere
	}
	if _, err := os.Lstat(kit); err == nil {
		return kitTaken
	}
	if p, err := a.E.Look("kit"); err == nil && !a.ownKit(p) {
		return kitTaken
	}
	if os.Symlink("catalyst", kit) != nil {
		return kitNo
	}
	return kitAdded
}
