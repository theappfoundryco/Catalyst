package checks

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/run"
)

func env(t *testing.T, goos string, tools map[string]string, replies map[string]run.Result) (*host.Env, *run.Fake) {
	t.Helper()
	f := &run.Fake{Replies: replies}
	e := host.ForTest(t.TempDir(), goos, f)
	e.Look = func(n string) (string, error) {
		if p, ok := tools[n]; ok {
			return p, nil
		}
		return "", exec.ErrNotFound
	}
	return e, f
}

func write(t *testing.T, path, text string, mode os.FileMode) {
	t.Helper()
	os.MkdirAll(filepath.Dir(path), 0o700)
	if err := os.WriteFile(path, []byte(text), mode); err != nil {
		t.Fatal(err)
	}
	os.Chmod(path, mode)
}

func one(t *testing.T, rs []d.Result) d.Result {
	t.Helper()
	if len(rs) != 1 {
		t.Fatalf("want one result: %+v", rs)
	}
	return rs[0]
}

func TestEveryRegisteredCheckIsComplete(t *testing.T) {
	seen := map[string]bool{}
	valid := map[string]bool{d.GroupShell: true, d.GroupTools: true, d.GroupKeys: true, d.GroupMachine: true}
	for _, c := range d.All() {
		if c.ID == "" || c.Name == "" || c.Run == nil || !valid[c.Group] {
			t.Errorf("incomplete: %+v", c)
		}
		if seen[c.ID] {
			t.Errorf("duplicate id %s", c.ID)
		}
		seen[c.ID] = true
	}
	if len(seen) < 18 {
		t.Errorf("only %d checks registered", len(seen))
	}
}

func TestShellSyntaxReportsTheBrokenFile(t *testing.T) {
	e, _ := env(t, "linux", map[string]string{"zsh": "/bin/zsh"}, nil)
	rc := e.Path(".zshrc")
	write(t, rc, "if true\n", 0o644)
	e.Run.(*run.Fake).Replies = map[string]run.Result{"zsh -n " + rc: {Code: 1, Stderr: "line 2: parse error\nmore\n"}}
	r := one(t, shellSyntax(e))
	if r.Severity != d.Critical || !strings.Contains(r.Hint, "parse error") || strings.Contains(r.Hint, "more") {
		t.Fatalf("%+v", r)
	}
	e.Run.(*run.Fake).Replies["zsh -n "+rc] = run.Result{}
	if r := one(t, shellSyntax(e)); r.State != d.Passed {
		t.Fatalf("%+v", r)
	}
}

func TestShellStartupThresholds(t *testing.T) {
	cases := []struct {
		took time.Duration
		want d.State
		sev  d.Severity
	}{{100 * time.Millisecond, d.Passed, ""}, {700 * time.Millisecond, d.Issue, d.Info}, {1800 * time.Millisecond, d.Issue, d.Warning}}
	for _, c := range cases {
		e, _ := env(t, "linux", nil, map[string]run.Result{"/bin/zsh -i -c exit": {}})
		e.Shell = "/bin/zsh"
		t0 := time.Now()
		n := 0
		e.Now = func() time.Time {
			n++
			if n == 1 {
				return t0
			}
			return t0.Add(c.took)
		}
		if r := one(t, shellStartup(e)); r.State != c.want || r.Severity != c.sev {
			t.Errorf("%v: %+v", c.took, r)
		}
	}
}

func TestShellStartupNamesWhatItCanSee(t *testing.T) {
	e, _ := env(t, "linux", nil, nil)
	write(t, e.Path(".zshrc"), `[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"`, 0o644)
	if got := culprit(e); !strings.Contains(got, "nvm") || strings.Contains(got, "conda") {
		t.Fatal(got)
	}
}

func TestPathFindsDeadRepeatsAndRelative(t *testing.T) {
	e, _ := env(t, "linux", nil, nil)
	real := e.Home
	e.Entries = []string{real, real, filepath.Join(real, "gone"), "."}
	rs := pathEntries(e)
	joined := fmt.Sprintf("%+v", rs)
	for _, want := range []string{"does not exist", "twice", "relative"} {
		if !strings.Contains(joined, want) {
			t.Errorf("missing %q in %s", want, joined)
		}
	}
	e.Entries = []string{real}
	if r := one(t, pathEntries(e)); r.State != d.Passed {
		t.Fatalf("%+v", r)
	}
}

func TestPathBrewOrderOnlyMatters(t *testing.T) {
	e, _ := env(t, "darwin", nil, nil)
	e.Entries = []string{"/usr/bin", "/opt/homebrew/bin"}
	if rs := pathEntries(e); !strings.Contains(fmt.Sprintf("%+v", rs), "before Homebrew") {
		t.Fatalf("%+v", rs)
	}
	e.Entries = []string{"/opt/homebrew/bin", "/usr/bin"}
	if rs := pathEntries(e); strings.Contains(fmt.Sprintf("%+v", rs), "before Homebrew") {
		t.Fatalf("%+v", rs)
	}
}

func TestGitIsNeverRunOnAMacWithoutTools(t *testing.T) {
	e, f := env(t, "darwin", map[string]string{"git": "/usr/bin/git"}, nil)
	e.SetCLT(false)
	r := one(t, gitIdentity(e))
	if r.Severity != d.Critical {
		t.Fatalf("%+v", r)
	}
	if len(f.Calls) != 0 {
		t.Fatalf("ran %v, which would open Apple's install dialog", f.Calls)
	}
}

func TestGitIdentity(t *testing.T) {
	base := map[string]run.Result{"/g/git --version": {Stdout: "git version 2"}}
	e, f := env(t, "linux", map[string]string{"git": "/g/git"}, base)
	if r := one(t, gitIdentity(e)); r.Severity != d.Warning {
		t.Fatalf("%+v", r)
	}
	f.Replies["/g/git config --global user.email"] = run.Result{Stdout: "alex@example.com\n"}
	f.Replies["/g/git config --global user.name"] = run.Result{Stdout: "Alex\n"}
	if r := one(t, gitIdentity(e)); r.Severity != d.Info {
		t.Fatalf("%+v", r)
	}
	f.Replies["/g/git config --global user.email"] = run.Result{Stdout: "alex@testville.test\n"}
	if r := one(t, gitIdentity(e)); r.State != d.Passed {
		t.Fatalf("%+v", r)
	}
}

func TestToolsRunCatchesResolvesButFails(t *testing.T) {
	e, _ := env(t, "linux", map[string]string{"npm": "/x/npm", "node": "/x/node"}, map[string]run.Result{
		"/x/node --version": {Stdout: "v22"},
		"/x/npm --version":  {Code: 127, Stderr: "env: node: No such file or directory\n"},
	})
	rs := toolsRun(e)
	if len(rs) != 2 || rs[0].Severity != d.Critical || !strings.Contains(rs[0].Hint, "No such file") || rs[1].State != d.Passed {
		t.Fatalf("%+v", rs)
	}
}

func TestPythonPipMismatch(t *testing.T) {
	e, _ := env(t, "linux", map[string]string{"python3": "/x/python3", "pip3": "/y/pip3"}, map[string]run.Result{
		"/x/python3 -m pip --version": {Stdout: "pip 24 from /x/lib/site-packages/pip (python 3.12)"},
		"/y/pip3 --version":           {Stdout: "pip 22 from /y/lib/site-packages/pip (python 3.9)"},
	})
	if r := one(t, pythonSetup(e)); r.Severity != d.Warning || !strings.Contains(r.Title, "different Python") {
		t.Fatalf("%+v", r)
	}
}

func TestSystemPythonIsOnlyAProblemOnAMac(t *testing.T) {
	replies := map[string]run.Result{"/usr/bin/python3 -c import sys; print(sys.executable)": {Stdout: "/usr/bin/python3\n"}}
	e, _ := env(t, "darwin", map[string]string{"python3": "/usr/bin/python3"}, replies)
	e.SetCLT(true)
	if r := one(t, pythonSetup(e)); r.Severity != d.Warning {
		t.Fatalf("%+v", r)
	}
	e, _ = env(t, "linux", map[string]string{"python3": "/usr/bin/python3"}, replies)
	if r := one(t, pythonSetup(e)); r.State != d.Passed {
		t.Fatalf("%+v", r)
	}
}

func TestNodeShadowedByBrewWhenNvmIsThere(t *testing.T) {
	e, _ := env(t, "darwin", map[string]string{"npm": "/opt/homebrew/bin/npm"}, nil)
	e.NvmDir = "/home/alex/.nvm"
	if r := one(t, nodeSetup(e)); r.Severity != d.Warning {
		t.Fatalf("%+v", r)
	}
	e.NvmDir = ""
	if r := one(t, nodeSetup(e)); r.State != d.Passed {
		t.Fatalf("%+v", r)
	}
}

func TestJavaHome(t *testing.T) {
	e, _ := env(t, "linux", map[string]string{"javac": "/x/javac"}, nil)
	e.JavaHome = "/nowhere/jdk"
	if r := one(t, javaSetup(e)); r.Severity != d.Warning {
		t.Fatalf("%+v", r)
	}
	e.JavaHome = ""
	if r := one(t, javaSetup(e)); r.Severity != d.Info {
		t.Fatalf("%+v", r)
	}
	e, _ = env(t, "linux", nil, nil)
	if r := one(t, javaSetup(e)); r.State != d.Skipped {
		t.Fatalf("no JDK, nothing to say: %+v", r)
	}
}

func TestBrew(t *testing.T) {
	e, _ := env(t, "darwin", nil, nil)
	has := func(paths ...string) func(string) bool {
		return func(p string) bool {
			for _, x := range paths {
				if x == p {
					return true
				}
			}
			return false
		}
	}
	if r := one(t, brewAt(e, has())); r.State != d.Skipped {
		t.Fatalf("%+v", r)
	}
	if r := one(t, brewAt(e, has("/usr/local/bin/brew"))); !strings.Contains(r.Title, "Intel") {
		t.Fatalf("%+v", r)
	}
	if r := one(t, brewAt(e, has("/opt/homebrew/bin/brew"))); !strings.Contains(r.Title, "cannot find") {
		t.Fatalf("%+v", r)
	}
	e.Entries = []string{"/opt/homebrew/bin"}
	if r := one(t, brewAt(e, has("/opt/homebrew/bin/brew"))); r.State != d.Passed {
		t.Fatalf("%+v", r)
	}
}

const fakeKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nnot a real key\n-----END OPENSSH PRIVATE KEY-----\n"

func TestSSHFindsKeysByContentAndFixesPermissions(t *testing.T) {
	e, _ := env(t, "linux", nil, nil)
	if r := one(t, sshPerms(e)); r.State != d.Skipped {
		t.Fatalf("%+v", r)
	}
	write(t, e.Path(".ssh", "work_laptop"), fakeKey, 0o644) // not named id_*
	write(t, e.Path(".ssh", "config"), "Host x\n", 0o644)   // not a key, so 644 is fine
	os.Chmod(e.Path(".ssh"), 0o755)
	rs := sshPerms(e)
	if len(rs) != 2 {
		t.Fatalf("%+v", rs)
	}
	if rs[0].Fix == nil || rs[0].Fix.Mode != 0o700 || rs[1].Severity != d.Critical || rs[1].Fix.Mode != 0o600 || rs[1].Fix.Path != e.Path(".ssh", "work_laptop") {
		t.Fatalf("%+v", rs)
	}
	os.Chmod(e.Path(".ssh"), 0o700)
	os.Chmod(e.Path(".ssh", "work_laptop"), 0o600)
	if r := one(t, sshPerms(e)); r.State != d.Passed {
		t.Fatalf("%+v", r)
	}
}

func TestWeakKeys(t *testing.T) {
	e, f := env(t, "linux", nil, nil)
	key := e.Path(".ssh", "old")
	write(t, key, fakeKey, 0o600)
	os.Chmod(e.Path(".ssh"), 0o700)
	f.Replies = map[string]run.Result{"ssh-keygen -l -f " + key: {Stdout: "1024 SHA256:abc alex@example.com (RSA)\n"}}
	if r := one(t, sshPerms(e)); !strings.Contains(r.Title, "weak") {
		t.Fatalf("%+v", r)
	}
}

// The whole point of this test: a secret found is a secret that must not be repeated anywhere, including --json.
func TestHistorySecretsAreCountedAndNeverShown(t *testing.T) {
	e, _ := env(t, "linux", nil, nil)
	if r := one(t, historySecrets(e)); r.State != d.Skipped {
		t.Fatalf("%+v", r)
	}
	secrets := []string{
		"AKIA" + "ABCDEFGHIJKLMNOP",
		"sk_live_" + strings.Repeat("a1", 12),
		"ghp_" + strings.Repeat("b2", 18),
		"sk-ant-" + strings.Repeat("c3", 12),
	}
	text := ": 1:0;ls -la\n: 2:0;cd projects\n"
	for _, s := range secrets {
		text += ": 3:0;export TOKEN=" + s + "\n"
	}
	text += ": 4:0;git status\n"
	write(t, e.Path(".zsh_history"), text, 0o600)
	r := one(t, historySecrets(e))
	if r.Severity != d.Critical || !strings.HasPrefix(r.Title, "4 lines in your shell history look like") {
		t.Fatalf("%+v", r)
	}
	out, _ := json.Marshal(r)
	for _, s := range secrets {
		if strings.Contains(string(out), s) {
			t.Fatalf("leaked %s in %s", s[:6], out)
		}
	}
}

func TestOrdinaryHistoryIsNotReported(t *testing.T) {
	e, _ := env(t, "linux", nil, nil)
	write(t, e.Path(".bash_history"), "ls\ngit commit -m 'add skeleton for the desktop app'\nsk-short\necho AKIA\n", 0o600)
	if r := one(t, historySecrets(e)); r.State != d.Passed {
		t.Fatalf("%+v", r)
	}
}

func TestFirewall(t *testing.T) {
	const fw = "/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate"
	e, _ := env(t, "darwin", nil, map[string]run.Result{fw: {Stdout: "Firewall is enabled. (State = 1)"}})
	if r := one(t, firewall(e)); r.State != d.Passed {
		t.Fatalf("%+v", r)
	}
	e, _ = env(t, "darwin", nil, map[string]run.Result{fw: {Stdout: "Firewall is disabled. (State = 0)"}})
	if r := one(t, firewall(e)); r.Severity != d.Info {
		t.Fatalf("%+v", r)
	}
	e, _ = env(t, "linux", map[string]string{"ufw": "/x/ufw"}, nil)
	if r := one(t, firewall(e)); r.State != d.Skipped {
		t.Fatalf("needing root is a skip, not a pass: %+v", r)
	}
}

func TestDiskFreeThresholds(t *testing.T) {
	row := func(used, free int) string {
		return fmt.Sprintf("Filesystem Type 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 ext4 %d %d %d 50%% /\n", used+free, used, free)
	}
	cases := []struct {
		used, free int
		want       d.Severity
	}{{900_000_000, 20_000_000, d.Critical}, {850_000_000, 100_000_000, d.Warning}, {300_000_000, 700_000_000, ""}}
	for _, c := range cases {
		e, _ := env(t, "linux", nil, map[string]run.Result{"df -kPT": {Stdout: row(c.used, c.free)}})
		e.Home = "/home/alex"
		if r := one(t, diskFree(e)); r.Severity != c.want {
			t.Errorf("%+v: %+v", c, r)
		}
	}
}

func TestInodes(t *testing.T) {
	if p, ok := InodePercent("Filesystem Inodes IUsed IFree IUse% Mounted on\n/dev/sda1 100 95 5 95% /\n"); !ok || p != 95 {
		t.Fatal(p, ok)
	}
}

func TestDocker(t *testing.T) {
	e, _ := env(t, "linux", nil, nil)
	if r := one(t, dockerState(e)); r.State != d.Skipped {
		t.Fatalf("%+v", r)
	}
	e, _ = env(t, "linux", map[string]string{"docker": "/x/docker"}, map[string]run.Result{
		"docker info --format {{.ServerVersion}}": {Stdout: "29.0"},
		"docker ps -aq -f status=exited":          {Stdout: "aa\nbb\n"},
		"docker images -q -f dangling=true":       {Stdout: ""},
	})
	r := one(t, dockerState(e))
	if !strings.HasPrefix(r.Title, "2 stopped") || r.Fix == nil || r.Fix.Kind != d.FixRun {
		t.Fatalf("%+v", r)
	}
}

func TestFailedServices(t *testing.T) {
	e, _ := env(t, "linux", map[string]string{"systemctl": "/x/systemctl"}, map[string]run.Result{
		"systemctl --failed --no-legend --plain":        {Stdout: "nginx.service loaded failed failed nginx\n"},
		"systemctl --user --failed --no-legend --plain": {Stdout: ""},
	})
	if r := one(t, startupItems(e)); !strings.Contains(r.Title, "nginx.service") {
		t.Fatalf("%+v", r)
	}
}

func TestJournalBytes(t *testing.T) {
	if b := JournalBytes("Archived and active journals take up 3.2G in the file system."); b != 3_200_000_000 {
		t.Fatal(b)
	}
}
