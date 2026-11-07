package host

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/theappfoundryco/catalyst/internal/run"
)

const dfMac = `Filesystem     1024-blocks      Used Available Capacity  Mounted on
/dev/disk3s1s1   239363072  10700000 100000000    10%    /
devfs                  200       200         0   100%    /dev
/dev/disk3s6     239363072   2097152 100000000     3%    /System/Volumes/VM
/dev/disk3s5     239363072 120000000 100000000    55%    /System/Volumes/Data
map auto_home            0         0         0   100%    /System/Volumes/Data/home
/dev/disk5s1      61000000  30000000  31000000    50%    /Volumes/Backup Drive`

func TestParseDFMac(t *testing.T) {
	v := ParseDFMac(dfMac)
	if len(v) != 2 {
		t.Fatalf("%+v", v)
	}
	if v[0].Mount != "/" || v[0].Name != "Internal disk" || v[0].Free != 100000000*1024 {
		t.Errorf("%+v", v[0])
	}
	if v[1].Name != "Backup Drive" {
		t.Errorf("%+v", v[1])
	}
}

const dfLinux = `Filesystem     Type     1024-blocks      Used Available Capacity Mounted on
/dev/nvme0n1p2 ext4       492000000 120000000 347000000      26% /
tmpfs          tmpfs       16000000         0  16000000       0% /run
/dev/loop3     squashfs       65000     65000         0     100% /snap/core/1
/dev/nvme0n1p1 vfat          500000      6000    494000       2% /boot/efi
/dev/sda1      ext4       120000000  10000000 104000000       9% /mnt/backup
overlay        overlay     50000000  10000000  40000000      20% /var/lib/docker/overlay2/x/merged`

func TestParseDFLinux(t *testing.T) {
	v := ParseDFLinux(dfLinux)
	if len(v) != 2 || v[0].Mount != "/" || v[1].Mount != "/mnt/backup" {
		t.Fatalf("%+v", v)
	}
}

func TestHomeVolumePicksTheLongestMatch(t *testing.T) {
	f := &run.Fake{Replies: map[string]run.Result{"df -kPT": {Stdout: dfLinux}}}
	e := ForTest("/mnt/backup/alex", "linux", f)
	v, ok := e.HomeVolume()
	if !ok || v.Mount != "/mnt/backup" {
		t.Fatalf("%+v", v)
	}
}

func TestParseMacMemory(t *testing.T) {
	vm := `Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               10000.
Pages active:                            100000.
Pages inactive:                           90000.
Pages wired down:                         50000.
Pages occupied by compressor:             25000.`
	m, ok := ParseMacMemory("17179869184\n", vm, "vm.swapusage: total = 2048.00M  used = 1024.00M  free = 1024.00M")
	if !ok {
		t.Fatal("not ok")
	}
	if want := int64(175000 * 16384); m.Used != want {
		t.Errorf("used %d want %d", m.Used, want)
	}
	if m.SwapUsed != 1024*1024*1024 || m.SwapTotal != 2048*1024*1024 {
		t.Errorf("%+v", m)
	}
}

func TestParseMeminfo(t *testing.T) {
	m, ok := ParseMeminfo("MemTotal: 1000 kB\nMemFree: 100 kB\nMemAvailable: 400 kB\nSwapTotal: 200 kB\nSwapFree: 150 kB\n")
	if !ok || m.Total != 1000*1024 || m.Used != 600*1024 || m.SwapUsed != 50*1024 || m.Percent() != 60 {
		t.Fatalf("%+v", m)
	}
}

func TestParsePmset(t *testing.T) {
	cases := []struct {
		in       string
		pct      int
		charging bool
		left     string
		source   string
	}{
		{"Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t100%; charged; 0:00 remaining present: true", 100, false, "", "Power adapter"},
		{"Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t62%; discharging; 4:12 remaining present: true", 62, false, "4:12", "Battery"},
		{"Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t40%; charging; 1:02 remaining present: true", 40, true, "", "Power adapter"},
		{"Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t50%; discharging; (no estimate) present: true", 50, false, "", "Battery"},
	}
	for _, c := range cases {
		b := ParsePmset(c.in)
		if !b.Present || b.Percent != c.pct || b.Charging != c.charging || b.TimeLeft != c.left || b.Source != c.source {
			t.Errorf("%q: %+v", c.in, b)
		}
	}
	if b := ParsePmset("Now drawing from 'AC Power'\n"); b.Present {
		t.Error("a desktop has no battery")
	}
}

func TestParseProfilerAndIoreg(t *testing.T) {
	var b Battery
	ParseProfiler(`{"SPPowerDataType":[{"sppower_battery_health_info":{"sppower_battery_cycle_count":532,"sppower_battery_health":"Good","sppower_battery_health_maximum_capacity":"87%"}},{"sppower_ac_charger_watts":"60"}]}`, &b)
	if b.Cycles != 532 || b.Condition != "Good" || b.Health != 87 {
		t.Fatalf("%+v", b)
	}
	ParseIoreg(`"Temperature" = 3120`, &b)
	if b.TemperatureC != 31.2 {
		t.Fatalf("%v", b.TemperatureC)
	}
}

func TestLinuxBattery(t *testing.T) {
	root := t.TempDir()
	d := filepath.Join(root, "BAT0")
	os.MkdirAll(d, 0o755)
	for k, v := range map[string]string{"capacity": "71", "status": "Discharging", "cycle_count": "210", "energy_full": "45000", "energy_full_design": "50000"} {
		os.WriteFile(filepath.Join(d, k), []byte(v+"\n"), 0o644)
	}
	b := readLinuxBattery(root)
	if !b.Present || b.Percent != 71 || b.Cycles != 210 || b.Health != 90 || b.Charging {
		t.Fatalf("%+v", b)
	}
	if readLinuxBattery(t.TempDir()).Present {
		t.Error("a server has no battery")
	}
}

func TestParseLsof(t *testing.T) {
	l := ParseLsof("p501\ncnode\nualex\nn*:3000\nn[::1]:3000\np88\ncPython\nualex\nn127.0.0.1:8000\n")
	if len(l) != 2 || l[0].Port != 3000 || l[0].PID != 501 || l[0].Command != "node" || l[0].Address != "*" || l[1].Port != 8000 {
		t.Fatalf("%+v", l)
	}
}

func TestParseSS(t *testing.T) {
	l := ParseSS(`LISTEN 0 4096 127.0.0.1:3095 0.0.0.0:* users:(("docker-proxy",pid=1234,fd=4))
LISTEN 0 128 0.0.0.0:22 0.0.0.0:*
LISTEN 0 128 [::]:22 [::]:*`)
	if len(l) != 2 || l[0].Port != 3095 || l[0].Command != "docker-proxy" || l[0].PID != 1234 || l[1].Port != 22 || l[1].Command != "" {
		t.Fatalf("%+v", l)
	}
}

func TestParseKeygen(t *testing.T) {
	bits, fp, comment, kind, ok := ParseKeygen("256 SHA256:abc123 alex@example.com (ED25519)")
	if !ok || bits != 256 || fp != "SHA256:abc123" || comment != "alex@example.com" || kind != "ED25519" {
		t.Fatal(bits, fp, comment, kind, ok)
	}
	if _, _, _, _, ok := ParseKeygen("not a key"); ok {
		t.Error("should not parse")
	}
}

func TestParseLaunchPlist(t *testing.T) {
	p, ok := ParseLaunchPlist(`{"Label":"com.example.a","ProgramArguments":["/opt/a/run","--x"]}`)
	if !ok || p.Program != "/opt/a/run" || p.Label != "com.example.a" {
		t.Fatalf("%+v", p)
	}
}

func TestParseDiskutil(t *testing.T) {
	d := ParseDiskutil(`<plist><dict>
<key>APFSPhysicalStores</key>
<array><dict><key>APFSPhysicalStore</key><string>disk0s2</string></dict></array>
<key>MediaName</key><string>APPLE SSD AP0256Q</string>
<key>ParentWholeDisk</key><string>disk3</string>
<key>SMARTStatus</key><string>Verified</string>
</dict></plist>`)
	if d.Device != "/dev/disk0" || d.Model != "APPLE SSD AP0256Q" || !d.OK {
		t.Fatalf("%+v", d)
	}
}

func TestParseSmartctl(t *testing.T) {
	d := Drive{WearPercent: -1}
	ok := ParseSmartctl(`{"model_name":"Example NVMe","smart_status":{"passed":true},"temperature":{"current":41},"power_on_time":{"hours":9000},"nvme_smart_health_information_log":{"percentage_used":7,"data_units_written":1000,"media_errors":0}}`, &d)
	if !ok || !d.HasSmart || d.WearPercent != 7 || d.TemperatureC != 41 || d.BytesWritten != 512000000 {
		t.Fatalf("%+v", d)
	}
	if ParseSmartctl(`{"smartctl":{"messages":[{"string":"Permission denied"}]}}`, &Drive{}) {
		t.Error("no permission must not read as healthy")
	}
}

func TestSafeToolNeverRunsAMacStub(t *testing.T) {
	e := ForTest("/home", "darwin", &run.Fake{})
	e.SetCLT(false)
	e.Look = func(n string) (string, error) { return "/usr/bin/" + n, nil }
	if _, ok := e.SafeTool("git"); ok {
		t.Fatal("running git here opens Apple's install dialog")
	}
	if _, ok := e.SafeTool("ls"); !ok {
		t.Fatal("ls is not a stub")
	}
	e.Look = func(n string) (string, error) { return "/opt/homebrew/bin/" + n, nil }
	if _, ok := e.SafeTool("git"); !ok {
		t.Fatal("Homebrew's git is real")
	}
}

func TestLoadShellIgnoresWhatStartupFilesPrint(t *testing.T) {
	f := &run.Fake{}
	e := ForTest("/home/alex", "linux", f)
	e.Shell = "/bin/zsh"
	script := `printf '\n` + pathMark + `%s\n%s\n%s\n` + pathMark + `\n' "$PATH" "$JAVA_HOME" "$NVM_DIR"`
	f.Replies = map[string]run.Result{
		"/bin/zsh -l -i -c " + script: {Stdout: "Welcome back!\n" + pathMark + "/a/bin:/b/bin\n/jdk\n/nvm\n" + pathMark + "\n"},
	}
	e.LoadShell()
	if strings.Join(e.Entries, ":") != "/a/bin:/b/bin" || e.JavaHome != "/jdk" || e.NvmDir != "/nvm" {
		t.Fatalf("%+v", e)
	}
}

func TestParseOSRelease(t *testing.T) {
	if got := ParseOSRelease("NAME=x\nPRETTY_NAME=\"Ubuntu 24.04 LTS\"\n"); got != "Ubuntu 24.04 LTS" {
		t.Fatal(got)
	}
}
