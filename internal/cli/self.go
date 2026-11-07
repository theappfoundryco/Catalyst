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
	"strconv"
	"strings"
	"time"

	"github.com/theappfoundryco/catalyst/internal/journal"
	"github.com/theappfoundryco/catalyst/internal/shellpath"
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
	u.Say("  " + u.Bold(tag) + " is out. You have " + version.Version + ".")
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
	if a.inSession { // this running copy is still the old one
		u.Say("  " + u.Dim("Run catalyst again to use it."))
		a.outcome.Quit = true
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
	u.Hint("Catalyst's line in your shell startup file, if it added one")
	u.Hint(a.E.Tilde(a.Store.Dir) + " and " + a.E.Tilde(a.Store.ConfigDir))
	u.Hint("What is in the Trash stays there. Anything it moved is yours to keep or empty.")
	if !u.Ask("Remove Catalyst?") {
		return ExitOK
	}
	for _, rc := range []string{shellpath.RCFile(a.E.Home, "zsh", a.E.OS, os.Getenv("ZDOTDIR")), shellpath.RCFile(a.E.Home, "bash", a.E.OS, ""), shellpath.RCFile(a.E.Home, "fish", a.E.OS, ""), shellpath.RCFile(a.E.Home, "", a.E.OS, "")} {
		if did, _ := shellpath.Remove(rc); did {
			u.Ok("Took the line out of " + a.E.Tilde(rc))
		}
	}
	os.RemoveAll(a.Store.Dir)
	os.RemoveAll(a.Store.ConfigDir)
	if err := os.Remove(self); err != nil {
		u.Stop("Could not remove " + self + ": " + err.Error())
		return ExitFailed
	}
	u.Ok("Catalyst is gone.")
	a.outcome.Quit = true
	a.outcome.Farewell = []string{"  Catalyst is gone. What it moved to the Trash is still there."}
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
		u.Hint("A backup is made first, and your .zshrc is checked afterwards.")
		if u.Ask("Remove that line?") {
			if err := a.removeSourceLine(rc, string(b)); err != nil {
				u.Stop(err.Error())
			} else {
				u.Ok("Removed. A backup is at ~/.zshrc.catalyst-backup")
			}
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

// removeSourceLine edits .zshrc the careful way: back up, write, have zsh check it, and put it back if zsh objects.
func (a *App) removeSourceLine(rc, text string) error {
	backup := rc + ".catalyst-backup"
	mode := os.FileMode(0o644)
	if st, err := os.Stat(rc); err == nil {
		mode = st.Mode().Perm()
	}
	if err := os.WriteFile(backup, []byte(text), 0o600); err != nil {
		return err
	}
	var keep []string
	for _, l := range strings.Split(text, "\n") {
		if !strings.Contains(l, legacySource) {
			keep = append(keep, l)
		}
	}
	if err := os.WriteFile(rc, []byte(strings.Join(keep, "\n")), mode); err != nil {
		return err
	}
	if _, err := a.E.Look("zsh"); err == nil {
		if r := a.E.Run.Run(0, "zsh", "-n", rc); !r.OK() {
			if werr := os.WriteFile(rc, []byte(text), mode); werr != nil {
				return fmt.Errorf("zsh rejected the result, and restoring failed: %v. Your backup is at %s", werr, backup)
			}
			return fmt.Errorf("zsh rejected the result, so your .zshrc was put back as it was")
		}
	}
	return nil
}
