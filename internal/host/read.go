package host

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Volume is one real disk mount.
type Volume struct {
	Name        string
	Mount       string
	Size, Used  int64
	Free        int64
	UsedPercent int
}

var skipFS = map[string]bool{"tmpfs": true, "devtmpfs": true, "overlay": true, "squashfs": true, "efivarfs": true, "devfs": true, "autofs": true, "proc": true, "sysfs": true, "nullfs": true, "ramfs": true, "fuse.lxcfs": true, "cgroup": true, "cgroup2": true}

// Volumes lists real disks. Mounted Disk images and system helper volumes are left out.
func (e *Env) Volumes() []Volume {
	if e.Mac() {
		out, _ := e.Out("df", "-kP")
		return ParseDFMac(out)
	}
	out, _ := e.Out("df", "-kPT")
	return ParseDFLinux(out)
}

// ParseDFMac reads df -kP on a Mac. The data volume is the one that matters, and it shows up as "/".
func ParseDFMac(text string) []Volume {
	var out []Volume
	lines := strings.Split(text, "\n")
	for i, line := range lines {
		f := strings.Fields(line)
		if i == 0 || len(f) < 6 {
			continue
		}
		mount := strings.Join(f[5:], " ")
		name := filepath.Base(mount)
		switch {
		case mount == "/System/Volumes/Data":
			mount, name = "/", "Internal disk"
		case mount == "/", strings.HasPrefix(mount, "/System/Volumes/"), strings.HasPrefix(mount, "/private/var/"), strings.HasPrefix(mount, "/Library/Developer/CoreSimulator/"):
			continue
		case !strings.HasPrefix(f[0], "/dev/"):
			continue
		case strings.HasPrefix(mount, "/Volumes/") && strings.Contains(strings.ToLower(mount), "simulator"):
			continue
		}
		if v, ok := volume(name, mount, f[1], f[2], f[3]); ok {
			out = append(out, v)
		}
	}
	return out
}

// ParseDFLinux reads df -kPT.
func ParseDFLinux(text string) []Volume {
	var out []Volume
	seen := map[string]bool{}
	for i, line := range strings.Split(text, "\n") {
		f := strings.Fields(line)
		if i == 0 || len(f) < 7 {
			continue
		}
		mount := strings.Join(f[6:], " ")
		if (skipFS[f[1]] && mount != "/") || strings.HasPrefix(mount, "/snap/") || strings.HasPrefix(mount, "/boot") || strings.HasPrefix(mount, "/proc") || strings.HasPrefix(mount, "/sys") || strings.HasPrefix(mount, "/dev") || strings.HasPrefix(mount, "/etc/") {
			continue
		}
		if seen[f[0]] && mount != "/" { // the same disk mounted twice, as Docker does
			continue
		}
		seen[f[0]] = true
		name := filepath.Base(mount)
		if mount == "/" {
			name = "System disk"
		}
		if v, ok := volume(name, mount, f[2], f[3], f[4]); ok {
			out = append(out, v)
		}
	}
	return out
}

func volume(name, mount, size, used, free string) (Volume, bool) {
	s, err1 := strconv.ParseInt(size, 10, 64)
	u, err2 := strconv.ParseInt(used, 10, 64)
	f, err3 := strconv.ParseInt(free, 10, 64)
	if err1 != nil || err2 != nil || err3 != nil || s == 0 {
		return Volume{}, false
	}
	// Used against what is usable: APFS and ext4 both hide space, so size minus free would overstate it.
	pct := 0
	if u+f > 0 {
		pct = int(u * 100 / (u + f))
	}
	return Volume{Name: name, Mount: mount, Size: s * 1024, Used: u * 1024, Free: f * 1024, UsedPercent: pct}, true
}

// HomeVolume is the volume holding the home folder.
func (e *Env) HomeVolume() (Volume, bool) {
	vols := e.Volumes()
	var best Volume
	for _, v := range vols {
		if (e.Home == v.Mount || v.Mount == "/" || strings.HasPrefix(e.Home, strings.TrimRight(v.Mount, "/")+"/")) && len(v.Mount) >= len(best.Mount) {
			best = v
		}
	}
	return best, best.Mount != ""
}

// Memory is RAM and swap, in bytes.
type Memory struct {
	Total, Used         int64
	SwapTotal, SwapUsed int64
}

// Percent is RAM used out of 100.
func (m Memory) Percent() int {
	if m.Total == 0 {
		return 0
	}
	return int(m.Used * 100 / m.Total)
}

// Memory reads RAM and swap.
func (e *Env) Memory() (Memory, bool) {
	if e.Mac() {
		total, ok1 := e.Out("sysctl", "-n", "hw.memsize")
		vm, ok2 := e.Out("vm_stat")
		swap, _ := e.Out("sysctl", "vm.swapusage")
		if !ok1 || !ok2 {
			return Memory{}, false
		}
		return ParseMacMemory(total, vm, swap)
	}
	b, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return Memory{}, false
	}
	return ParseMeminfo(string(b))
}

var vmLine = regexp.MustCompile(`(?m)^(Pages [a-z ]+|Pages occupied by compressor):\s+(\d+)\.`)
var pageSize = regexp.MustCompile(`page size of (\d+) bytes`)
var swapRe = regexp.MustCompile(`total = ([\d.]+)([MG]).*used = ([\d.]+)([MG])`)

// ParseMacMemory works out used memory the way Activity Monitor does: app memory plus wired plus compressed. Free and
// file cache do not count, since macOS gives those back when asked.
func ParseMacMemory(totalText, vm, swap string) (Memory, bool) {
	total, err := strconv.ParseInt(strings.TrimSpace(totalText), 10, 64)
	if err != nil {
		return Memory{}, false
	}
	size := int64(4096)
	if m := pageSize.FindStringSubmatch(vm); m != nil {
		size, _ = strconv.ParseInt(m[1], 10, 64)
	}
	pages := map[string]int64{}
	for _, m := range vmLine.FindAllStringSubmatch(vm, -1) {
		pages[m[1]], _ = strconv.ParseInt(m[2], 10, 64)
	}
	used := (pages["Pages active"] + pages["Pages wired down"] + pages["Pages occupied by compressor"]) * size
	mem := Memory{Total: total, Used: used}
	if m := swapRe.FindStringSubmatch(swap); m != nil {
		mem.SwapTotal = swapBytes(m[1], m[2])
		mem.SwapUsed = swapBytes(m[3], m[4])
	}
	return mem, true
}

func swapBytes(v, unit string) int64 {
	f, _ := strconv.ParseFloat(v, 64)
	if unit == "G" {
		return int64(f * 1024 * 1024 * 1024)
	}
	return int64(f * 1024 * 1024)
}

// ParseMeminfo reads /proc/meminfo.
func ParseMeminfo(text string) (Memory, bool) {
	vals := map[string]int64{}
	for _, l := range strings.Split(text, "\n") {
		f := strings.Fields(l)
		if len(f) >= 2 {
			vals[strings.TrimSuffix(f[0], ":")], _ = strconv.ParseInt(f[1], 10, 64)
		}
	}
	if vals["MemTotal"] == 0 {
		return Memory{}, false
	}
	return Memory{
		Total: vals["MemTotal"] * 1024, Used: (vals["MemTotal"] - vals["MemAvailable"]) * 1024,
		SwapTotal: vals["SwapTotal"] * 1024, SwapUsed: (vals["SwapTotal"] - vals["SwapFree"]) * 1024,
	}, true
}

// Load is the one-minute load average and the number of CPU threads.
func (e *Env) Load() (float64, int) {
	cores := 1
	if e.Mac() {
		if s, ok := e.Out("sysctl", "-n", "hw.ncpu"); ok {
			cores, _ = strconv.Atoi(s)
		}
		s, _ := e.Out("sysctl", "-n", "vm.loadavg")
		f := strings.Fields(strings.Trim(s, "{} "))
		if len(f) > 0 {
			v, _ := strconv.ParseFloat(f[0], 64)
			return v, cores
		}
		return 0, cores
	}
	if s, ok := e.Out("nproc"); ok {
		cores, _ = strconv.Atoi(s)
	}
	b, _ := os.ReadFile("/proc/loadavg")
	f := strings.Fields(string(b))
	if len(f) > 0 {
		v, _ := strconv.ParseFloat(f[0], 64)
		return v, cores
	}
	return 0, cores
}

// OSName is a person's name for this system, like "macOS 15.6".
func (e *Env) OSName() string {
	if e.Mac() {
		if v, ok := e.Out("sw_vers", "-productVersion"); ok {
			return "macOS " + v
		}
		return "macOS"
	}
	b, err := os.ReadFile("/etc/os-release")
	if err == nil {
		return ParseOSRelease(string(b))
	}
	return "Linux"
}

// ParseOSRelease pulls PRETTY_NAME out of /etc/os-release.
func ParseOSRelease(text string) string {
	for _, l := range strings.Split(text, "\n") {
		if strings.HasPrefix(l, "PRETTY_NAME=") {
			return strings.Trim(strings.TrimPrefix(l, "PRETTY_NAME="), `"`)
		}
	}
	return "Linux"
}

// Battery is a laptop's battery state. Present is false on a desktop or server.
type Battery struct {
	Present      bool
	Percent      int
	Charging     bool
	Source       string
	TimeLeft     string
	Cycles       int
	Health       int // percent of design capacity, 0 when unknown
	Condition    string
	TemperatureC float64
}

// Battery reads it. system_profiler is slow and has hung before, so it gets its own limit and the rest still reports without it.
func (e *Env) Battery() Battery {
	if e.Linux() {
		return readLinuxBattery("/sys/class/power_supply")
	}
	pm, _ := e.Out("pmset", "-g", "batt")
	b := ParsePmset(pm)
	if !b.Present {
		return b
	}
	if r := e.Run.Run(15*time.Second, "system_profiler", "-json", "SPPowerDataType"); r.OK() {
		ParseProfiler(r.Stdout, &b)
	}
	if io, ok := e.Out("ioreg", "-rn", "AppleSmartBattery"); ok {
		ParseIoreg(io, &b)
	}
	return b
}

var pmsetRe = regexp.MustCompile(`(\d+)%;\s*([a-zA-Z ]+);\s*(.*?)(?:\s+present|$)`)

// ParsePmset reads pmset -g batt.
func ParsePmset(text string) Battery {
	b := Battery{}
	if strings.Contains(text, "AC Power") {
		b.Source = "Power adapter"
	} else if strings.Contains(text, "Battery Power") {
		b.Source = "Battery"
	}
	m := pmsetRe.FindStringSubmatch(text)
	if m == nil {
		return b
	}
	b.Present = true
	b.Percent, _ = strconv.Atoi(m[1])
	state := strings.TrimSpace(m[2])
	b.Charging = state == "charging" || state == "finishing charge"
	if b.Source == "Battery" && strings.Contains(m[3], "remaining") && !strings.Contains(m[3], "no estimate") {
		if left := strings.TrimSpace(strings.Split(m[3], "remaining")[0]); left != "0:00" {
			b.TimeLeft = left
		}
	}
	return b
}

// ParseProfiler reads system_profiler's JSON, the figures macOS itself shows in Settings.
func ParseProfiler(text string, b *Battery) {
	var d struct {
		Power []struct {
			Health struct {
				Cycles    int    `json:"sppower_battery_cycle_count"`
				Condition string `json:"sppower_battery_health"`
				Max       string `json:"sppower_battery_health_maximum_capacity"`
			} `json:"sppower_battery_health_info"`
		} `json:"SPPowerDataType"`
	}
	if json.Unmarshal([]byte(text), &d) != nil {
		return
	}
	for _, p := range d.Power {
		if p.Health.Condition != "" || p.Health.Cycles > 0 {
			b.Cycles, b.Condition = p.Health.Cycles, p.Health.Condition
			b.Health, _ = strconv.Atoi(strings.TrimSuffix(p.Health.Max, "%"))
		}
	}
}

var ioregTemp = regexp.MustCompile(`"Temperature" = (\d+)`)

// ParseIoreg reads the temperature, in hundredths of a degree.
func ParseIoreg(text string, b *Battery) {
	if m := ioregTemp.FindStringSubmatch(text); m != nil {
		t, _ := strconv.Atoi(m[1])
		b.TemperatureC = float64(t) / 100
	}
}

func readLinuxBattery(root string) Battery {
	dirs, _ := filepath.Glob(filepath.Join(root, "BAT*"))
	if len(dirs) == 0 {
		return Battery{}
	}
	d := dirs[0]
	read := func(n string) string { b, _ := os.ReadFile(filepath.Join(d, n)); return strings.TrimSpace(string(b)) }
	num := func(n string) int64 { v, _ := strconv.ParseInt(read(n), 10, 64); return v }
	b := Battery{Present: true, Source: "Battery", Percent: int(num("capacity")), Cycles: int(num("cycle_count"))}
	st := read("status")
	b.Charging = st == "Charging"
	if st == "Charging" || st == "Full" || st == "Not charging" {
		b.Source = "Power adapter"
	}
	full, design := num("energy_full"), num("energy_full_design")
	if design == 0 {
		full, design = num("charge_full"), num("charge_full_design")
	}
	if design > 0 {
		b.Health = int(full * 100 / design)
	}
	return b
}

// Listener is a process waiting for connections on a TCP port.
type Listener struct {
	Port    int
	PID     int
	Command string
	Address string
	User    string
}

// Listeners lists TCP listeners, sorted by port.
func (e *Env) Listeners() []Listener {
	var out []Listener
	if e.Linux() {
		if s, ok := e.Out("ss", "-tlnpH"); ok {
			out = ParseSS(s)
		}
	}
	if len(out) == 0 {
		// +c 0 asks for the full command name. -F gives machine-readable fields, so nothing depends on column widths.
		if s, ok := e.Out("lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcun", "+c", "0"); ok {
			out = ParseLsof(s)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Port < out[j].Port })
	return out
}

// ParseLsof reads lsof -F pcun.
func ParseLsof(text string) []Listener {
	var out []Listener
	var pid int
	var cmd, user string
	seen := map[string]bool{}
	for _, l := range strings.Split(text, "\n") {
		if l == "" {
			continue
		}
		v := l[1:]
		switch l[0] {
		case 'p':
			pid, _ = strconv.Atoi(v)
		case 'c':
			cmd = v
		case 'u':
			user = v
		case 'n':
			i := strings.LastIndex(v, ":")
			if i < 0 {
				continue
			}
			port, err := strconv.Atoi(v[i+1:])
			if err != nil {
				continue
			}
			key := fmt.Sprintf("%d/%d", pid, port)
			if seen[key] {
				continue
			}
			seen[key] = true
			out = append(out, Listener{Port: port, PID: pid, Command: cmd, Address: v[:i], User: user})
		}
	}
	return out
}

var ssProc = regexp.MustCompile(`users:\(\("([^"]+)",pid=(\d+)`)

// ParseSS reads ss -tlnpH. Without root, other users' processes come back with no name.
func ParseSS(text string) []Listener {
	var out []Listener
	seen := map[string]bool{}
	for _, l := range strings.Split(text, "\n") {
		f := strings.Fields(l)
		if len(f) < 4 {
			continue
		}
		addr := f[3]
		i := strings.LastIndex(addr, ":")
		if i < 0 {
			continue
		}
		port, err := strconv.Atoi(addr[i+1:])
		if err != nil {
			continue
		}
		li := Listener{Port: port, Address: addr[:i]}
		if m := ssProc.FindStringSubmatch(l); m != nil {
			li.Command = m[1]
			li.PID, _ = strconv.Atoi(m[2])
		}
		key := fmt.Sprintf("%d/%d", li.PID, port)
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, li)
	}
	return out
}

// Folder is a process's working folder, or "" when it cannot be read.
func (e *Env) Folder(pid int) string {
	if e.Linux() {
		p, err := os.Readlink(fmt.Sprintf("/proc/%d/cwd", pid))
		if err == nil {
			return p
		}
		return ""
	}
	out, ok := e.Out("lsof", "-a", "-p", strconv.Itoa(pid), "-d", "cwd", "-Fn")
	if !ok {
		return ""
	}
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, "n") {
			return l[1:]
		}
	}
	return ""
}
