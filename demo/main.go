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
	"github.com/theappfoundryco/catalyst/internal/sysdata"
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
		// Status, Battery and Ports, all invented.
		"sw_vers -productVersion":                       {Stdout: "15.3"},
		"sysctl -n hw.ncpu":                             {Stdout: "10"},
		"sysctl -n vm.loadavg":                          {Stdout: "{ 2.84 2.61 2.40 }"},
		"sysctl -n kern.memorystatus_vm_pressure_level": {Stdout: "1"},
		"sysctl -n kern.boottime":                       {Stdout: fmt.Sprintf("{ sec = %d, usec = 0 }", now.Add(-77*time.Hour).Unix())},
		"pmset -g batt":                                 {Stdout: "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t82%; discharging; 6:40 remaining present: true"},
		"pmset -g":                                      {Stdout: " lowpowermode         0\n"},
		"pmset -g therm":                                {Stdout: "Note: No thermal warning level has been recorded\n"},
		"system_profiler -json SPPowerDataType":         {Stdout: `{"SPPowerDataType":[{"sppower_battery_health_info":{"sppower_battery_cycle_count":212,"sppower_battery_health":"Good","sppower_battery_health_maximum_capacity":"94%"}}]}`},
		"ioreg -rn AppleSmartBattery":                   {Stdout: "\"Temperature\" = 2980\n\"DesignCapacity\" = 6075\n\"AppleRawMaxCapacity\" = 5710\n\"DesignCycleCount9C\" = 1000\n\"Voltage\" = 12410\n\"InstantAmperage\" = 18446744073709550916\n\"BatteryData\" = {\"CellVoltage\"=(4137,4136,4137)}\n"},
		"ps -Aceo pcpu=,rss=,comm=":                     {Stdout: " 38.0 2400000 Xcode\n 22.0 1800000 Google Chrome\n  9.0  300000 Google Chrome Helper (Renderer)\n 14.0  900000 node\n  3.0 1100000 Slack\n  1.0  200000 Terminal\n"},
		"docker ps -q":                                  {Stdout: "a1\nb2\n"},
		"lsof -nP -iTCP -sTCP:LISTEN -F pcun +c 0":      {Stdout: "p4120\ncnode\nu501\nn127.0.0.1:3000\np4188\ncpostgres\nu501\nn127.0.0.1:5432\np5020\ncredis-server\nu501\nn127.0.0.1:6379\np6230\ncPython\nu501\nn*:8000\np377\ncrapportd\nu501\nn*:49152\n"},
		"ps -o lstart= -p 4120":                         {Stdout: "Thu Mar 12 08:55:10 2026"},
		"ps -o command= -p 4120":                        {Stdout: "node /Users/alex/Developer/shop-api/node_modules/.bin/next dev"},
		// System Data: macOS's own volumes and the snapshots, invented.
		"diskutil apfs list":          {Stdout: "APFS Volume Disk (Role):   disk3s1 (System)\nCapacity Consumed:         11258822656 B\nAPFS Volume Disk (Role):   disk3s2 (Preboot)\nCapacity Consumed:         7381000000 B\nAPFS Volume Disk (Role):   disk3s3 (Recovery)\nCapacity Consumed:         1043000000 B\nAPFS Volume Disk (Role):   disk3s6 (VM)\nCapacity Consumed:         3221225472 B\n"},
		"tmutil listlocalsnapshots /": {Stdout: "Snapshots for disk /:\ncom.apple.TimeMachine.2026-03-12-080011.local\ncom.apple.TimeMachine.2026-03-12-090014.local\ncom.apple.TimeMachine.2026-03-12-093002.local\n"},
	}
	tools := map[string]string{"zsh": "/bin/zsh", "git": bin + "git", "node": bin + "node", "npm": bin + "npm", "python3": bin + "python3", "pip3": bin + "pip3", "docker": bin + "docker", "colima": bin + "colima", "huggingface-cli": bin + "huggingface-cli"}
	for _, d := range []string{".colima", ".cache/huggingface", "Library/Developer/Xcode/DerivedData"} {
		os.MkdirAll(filepath.Join(home, d), 0o700)
	}
	// What System Data measures outside the home folder is invented too, so no real machine reaches a screenshot.
	sizes := map[string]int64{
		".colima": 9_400_000_000, ".cache/huggingface": 6_800_000_000, "Library/Developer/Xcode/DerivedData": 4_100_000_000,
		"/Applications/Install macOS Sequoia.app": 15_200_000_000, "/Library/Application Support/com.apple.idleassetsd/Customer": 2_900_000_000,
		"/private/var/folders": 1_400_000_000, "/private/var/db/diagnostics": 1_100_000_000, "/private/var/db/uuidtext": 640_000_000,
		"/System/Library/AssetsV2": 3_600_000_000, "/Library/Developer/CommandLineTools": 2_300_000_000, "/Library/Caches": 410_000_000,
	}
	sysdata.Exists = func(p string) bool {
		if strings.HasPrefix(p, home) {
			_, err := os.Stat(p)
			return err == nil
		}
		_, ok := sizes[p]
		return ok
	}
	sysdata.Glob = func(string) ([]string, error) { return []string{"/Applications/Install macOS Sequoia.app"}, nil }
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
	store.Record(state.Health{Date: now.Add(-40 * time.Minute), Score: 72, Issues: 4})
	name := "Alex"
	store.SaveConfig(state.Config{Name: &name, SetupDone: true})
	u := ui.New()
	u.Mascot = true
	e.Hostname = func() string { return "alex-mbp" }
	a := &cli.App{U: u, E: e, Store: store, Journal: journal.New(store.Dir), SizeOf: func(p string) int64 {
		if n, ok := sizes[strings.TrimPrefix(p, home+"/")]; ok {
			return n
		}
		return sizes[p]
	}}
	fmt.Fprint(os.Stdout, "")
	cli.Dispatch(a, os.Args[1:])
}
