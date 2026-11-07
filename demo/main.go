// Command demo runs the real doctor against an invented machine, for the README. Nothing here reads your own setup: every tool
// answer is made up, and the home folder is thrown away afterwards. `make demo` records it.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/theappfoundryco/catalyst/internal/cli"
	_ "github.com/theappfoundryco/catalyst/internal/doctor/checks"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/journal"
	"github.com/theappfoundryco/catalyst/internal/run"
	"github.com/theappfoundryco/catalyst/internal/state"
	"github.com/theappfoundryco/catalyst/internal/ui"
	"github.com/theappfoundryco/catalyst/internal/version"
)

// slowRunner answers from a table, and moves a fake clock forward when a shell starts, so the timing check has something to say.
type slowRunner struct {
	fake  *run.Fake
	clock *time.Time
}

func (s slowRunner) Run(t time.Duration, name string, args ...string) run.Result {
	if strings.Join(args, " ") == "-i -c exit" {
		*s.clock = s.clock.Add(1800 * time.Millisecond)
	}
	time.Sleep(60 * time.Millisecond) // long enough to see the spinner, short enough to record
	return s.fake.Run(t, name, args...)
}

func main() {
	version.Version = "0.1.1" // a screenshot should not say "dev"
	home, err := os.MkdirTemp("", "catalyst-demo-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(home)
	write := func(p, text string, mode os.FileMode) {
		full := filepath.Join(home, p)
		os.MkdirAll(filepath.Dir(full), 0o700)
		os.WriteFile(full, []byte(text), mode)
	}
	write(".zshrc", `export NVM_DIR="$HOME/.nvm"`+"\n"+`[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"`+"\n", 0o644)
	write(".zsh_history", ": 1:0;export STRIPE=sk_live_"+strings.Repeat("x1", 13)+"\n: 2:0;ls\n", 0o600)
	key := "-----BEGIN OPENSSH PRIVATE " + "KEY-----\ninvented\n"
	write(".ssh/id_ed25519", key, 0o600)
	write(".ssh/work_laptop", key, 0o600)
	os.Chmod(filepath.Join(home, ".ssh"), 0o700)
	now := time.Date(2026, 3, 12, 9, 41, 0, 0, time.Local)
	clock := now
	bin := "/opt/homebrew/bin/"
	replies := map[string]run.Result{
		"zsh -n " + filepath.Join(home, ".zshrc"):                          {},
		"/bin/zsh -i -c exit":                                              {},
		bin + "git --version":                                              {Stdout: "git version 2.50"},
		bin + "git config --global user.email":                             {Stdout: "alex@example.org\n"},
		bin + "git config --global user.name":                              {Stdout: "Alex\n"},
		bin + "node --version":                                             {Stdout: "v22"},
		bin + "npm --version":                                              {Stdout: "10"},
		bin + "python3 --version":                                          {Stdout: "Python 3.13"},
		bin + "pip3 --version":                                             {Stdout: "pip 25 from /opt/homebrew/lib/pip (python 3.13)"},
		bin + "python3 -c import sys; print(sys.executable)":               {Stdout: bin + "python3\n"},
		bin + "python3 -m pip --version":                                   {Stdout: "pip 25 from /opt/homebrew/lib/pip (python 3.13)"},
		bin + "docker --version":                                           {Stdout: "Docker version 29.0"},
		"go version":                                                       {},
		"/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate": {Stdout: "Firewall is enabled. (State = 1)"},
		"df -kP":               {Stdout: "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3s5 488000000 330000000 158000000 68% /System/Volumes/Data\n"},
		"sysctl -n hw.memsize": {Stdout: "34359738368"},
		"vm_stat":              {Stdout: "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages active: 500000.\nPages wired down: 200000.\n"},
		"sysctl vm.swapusage":  {Stdout: "vm.swapusage: total = 1024.00M  used = 120.00M  free = 900.00M"},
		"docker info --format {{.ServerVersion}}": {Stdout: "29.0"},
		"docker ps -aq -f status=exited":          {Stdout: "a\nb\nc\n"},
		"docker images -q -f dangling=true":       {},
		"launchctl list":                          {},
		"/usr/libexec/java_home":                  {Code: 1},
	}
	tools := map[string]string{"zsh": "/bin/zsh", "git": bin + "git", "node": bin + "node", "npm": bin + "npm", "python3": bin + "python3", "pip3": bin + "pip3", "docker": bin + "docker"}
	e := host.ForTest(home, "darwin", slowRunner{&run.Fake{Replies: replies}, &clock})
	e.SetCLT(true)
	e.Shell = "/bin/zsh"
	e.Now = func() time.Time { return clock }
	e.Entries = []string{"/opt/homebrew/bin", "/usr/bin", "/bin"}
	e.NvmDir = filepath.Join(home, ".nvm")
	e.Look = func(n string) (string, error) {
		if p, ok := tools[n]; ok {
			return p, nil
		}
		return "", exec.ErrNotFound
	}
	store := state.New(home, nil)
	store.Record(state.Health{Date: now.AddDate(0, 0, -2), Score: 44, Issues: 6})
	u := ui.New()
	u.Mascot = true
	a := &cli.App{U: u, E: e, Store: store, Journal: journal.New(store.Dir)}
	fmt.Fprint(os.Stdout, "")
	cli.Dispatch(a, os.Args[1:])
}
