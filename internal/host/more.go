package host

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Cell details a Mac's battery reports through ioreg, beyond what Settings shows.
type Cells struct {
	DesignMAh  int       `json:"design_mah,omitempty"`
	FullMAh    int       `json:"full_mah,omitempty"` // what a full charge holds now
	Volts      float64   `json:"volts,omitempty"`
	Watts      float64   `json:"watts,omitempty"` // into the battery when positive, out of it when negative
	AdapterW   int       `json:"adapter_watts,omitempty"`
	RatedCycle int       `json:"rated_cycles,omitempty"`
	CellVolts  []float64 `json:"cell_volts,omitempty"`
	LowPower   *bool     `json:"low_power_mode,omitempty"`
	FullyFull  bool      `json:"fully_charged,omitempty"`
}

var ioregInt = regexp.MustCompile(`"(DesignCapacity|AppleRawMaxCapacity|NominalChargeCapacity|Voltage|Amperage|InstantAmperage|DesignCycleCount9C)" = (\d+)`)
var ioregWatts = regexp.MustCompile(`"AdapterDetails" = \{[^}]*"Watts"=(\d+)`)
var ioregCells = regexp.MustCompile(`"CellVoltage"=\(([\d,]+)\)`)

// ParseCells reads ioreg -rn AppleSmartBattery for capacity in mAh, voltage, power and the cells.
func ParseCells(text string) Cells {
	var c Cells
	vals := map[string]int64{}
	for _, m := range ioregInt.FindAllStringSubmatch(text, -1) {
		if _, seen := vals[m[1]]; seen {
			continue
		}
		u, err := strconv.ParseUint(m[2], 10, 64)
		if err != nil {
			continue
		}
		vals[m[1]] = int64(u) // a current going out is written as a huge unsigned number; this makes it negative again
	}
	c.DesignMAh = int(vals["DesignCapacity"])
	c.FullMAh = int(vals["AppleRawMaxCapacity"])
	if c.FullMAh == 0 {
		c.FullMAh = int(vals["NominalChargeCapacity"])
	}
	c.RatedCycle = int(vals["DesignCycleCount9C"])
	if mv := vals["Voltage"]; mv > 0 {
		c.Volts = float64(mv) / 1000
		amps := vals["InstantAmperage"]
		if amps == 0 {
			amps = vals["Amperage"]
		}
		c.Watts = float64(amps) / 1000 * c.Volts
	}
	if m := ioregWatts.FindStringSubmatch(text); m != nil {
		c.AdapterW, _ = strconv.Atoi(m[1])
	}
	if m := ioregCells.FindStringSubmatch(text); m != nil {
		for _, f := range strings.Split(m[1], ",") {
			if mv, err := strconv.Atoi(f); err == nil && mv > 0 {
				c.CellVolts = append(c.CellVolts, float64(mv)/1000)
			}
		}
	}
	c.FullyFull = strings.Contains(text, `"FullyCharged" = Yes`)
	return c
}

// BatteryCells reads the details. On Linux they come from the kernel's power supply files.
func (e *Env) BatteryCells() Cells {
	if e.Linux() {
		return linuxCells("/sys/class/power_supply")
	}
	s, _ := e.Out("ioreg", "-rn", "AppleSmartBattery")
	c := ParseCells(s)
	if pm, ok := e.Out("pmset", "-g"); ok {
		if m := regexp.MustCompile(`lowpowermode\s+(\d)`).FindStringSubmatch(pm); m != nil {
			on := m[1] == "1"
			c.LowPower = &on
		}
	}
	return c
}

func linuxCells(root string) Cells {
	dirs, _ := filepath.Glob(filepath.Join(root, "BAT*"))
	if len(dirs) == 0 {
		return Cells{}
	}
	num := func(n string) float64 {
		b, _ := os.ReadFile(filepath.Join(dirs[0], n))
		v, _ := strconv.ParseFloat(strings.TrimSpace(string(b)), 64)
		return v
	}
	c := Cells{Volts: num("voltage_now") / 1e6}
	if p := num("power_now"); p > 0 {
		c.Watts = p / 1e6
	} else if a := num("current_now"); a > 0 {
		c.Watts = a / 1e6 * c.Volts
	}
	return c
}

// Uptime is how long since the machine started.
func (e *Env) Uptime() (time.Duration, bool) {
	if e.Linux() {
		b, err := os.ReadFile("/proc/uptime")
		if err != nil {
			return 0, false
		}
		f := strings.Fields(string(b))
		if len(f) == 0 {
			return 0, false
		}
		s, err := strconv.ParseFloat(f[0], 64)
		return time.Duration(s) * time.Second, err == nil
	}
	s, ok := e.Out("sysctl", "-n", "kern.boottime")
	if !ok {
		return 0, false
	}
	return ParseBoottime(s, e.Now())
}

var bootSec = regexp.MustCompile(`sec = (\d+)`)

// ParseBoottime reads sysctl kern.boottime.
func ParseBoottime(s string, now time.Time) (time.Duration, bool) {
	m := bootSec.FindStringSubmatch(s)
	if m == nil {
		return 0, false
	}
	sec, _ := strconv.ParseInt(m[1], 10, 64)
	return now.Sub(time.Unix(sec, 0)), true
}

// Pressure is how hard memory is working: "normal", "warning" or "critical". It says more than a percentage, since a
// Mac fills its memory on purpose and only pressure means it is short.
func (e *Env) Pressure() (string, bool) {
	if e.Linux() {
		b, err := os.ReadFile("/proc/pressure/memory")
		if err != nil {
			return "", false
		}
		return ParsePSI(string(b))
	}
	s, ok := e.Out("sysctl", "-n", "kern.memorystatus_vm_pressure_level")
	if !ok {
		return "", false
	}
	switch strings.TrimSpace(s) {
	case "1":
		return "normal", true
	case "2":
		return "warning", true
	case "4":
		return "critical", true
	}
	return "", false
}

var psiSome = regexp.MustCompile(`some avg10=([\d.]+)`)

// ParsePSI reads /proc/pressure/memory: the share of time something waited for memory in the last ten seconds.
func ParsePSI(s string) (string, bool) {
	m := psiSome.FindStringSubmatch(s)
	if m == nil {
		return "", false
	}
	v, _ := strconv.ParseFloat(m[1], 64)
	switch {
	case v >= 30:
		return "critical", true
	case v >= 10:
		return "warning", true
	}
	return "normal", true
}

var speedLimit = regexp.MustCompile(`CPU_Speed_Limit\s*=\s*(\d+)`)

// Thermal says whether the machine is slowing itself down to cool off: "" when it cannot tell.
func (e *Env) Thermal() string {
	if !e.Mac() {
		return ""
	}
	s, ok := e.Out("pmset", "-g", "therm")
	if !ok {
		return ""
	}
	return ParseTherm(s)
}

// ParseTherm reads pmset -g therm.
func ParseTherm(s string) string {
	if m := speedLimit.FindStringSubmatch(s); m != nil {
		if n, _ := strconv.Atoi(m[1]); n < 100 {
			return "slowed to " + m[1] + "% to cool down"
		}
		return "normal"
	}
	if strings.Contains(s, "No thermal warning level has been recorded") {
		return "normal"
	}
	if strings.Contains(s, "thermal warning level") {
		return "warm, slowing down a little"
	}
	return ""
}

// Proc is one program and what it uses, with its helpers counted in.
type Proc struct {
	Name string  `json:"name"`
	CPU  float64 `json:"cpu_percent"`
	RSS  int64   `json:"memory_bytes"`
}

// TopProcs lists programs by CPU or by memory.
func (e *Env) TopProcs(n int, byMemory bool) []Proc {
	args := []string{"-eo", "pcpu=,rss=,comm="}
	if e.Mac() {
		args = []string{"-Aceo", "pcpu=,rss=,comm="}
	}
	s, ok := e.Out("ps", args...)
	if !ok {
		return nil
	}
	return ParsePS(s, n, byMemory)
}

// ParsePS sums ps output by program name, so an app and its helper processes count as one.
func ParsePS(s string, n int, byMemory bool) []Proc {
	sum := map[string]*Proc{}
	var order []string
	for _, l := range strings.Split(s, "\n") {
		f := strings.Fields(l)
		if len(f) < 3 {
			continue
		}
		cpu, _ := strconv.ParseFloat(f[0], 64)
		kb, _ := strconv.ParseInt(f[1], 10, 64)
		name := strings.Join(f[2:], " ")
		for _, suffix := range []string{" Helper (Renderer)", " Helper (GPU)", " Helper (Plugin)", " Helper"} {
			name = strings.TrimSuffix(name, suffix)
		}
		name = filepath.Base(name)
		p, ok := sum[name]
		if !ok {
			p = &Proc{Name: name}
			sum[name] = p
			order = append(order, name)
		}
		p.CPU += cpu
		p.RSS += kb * 1024
	}
	out := make([]Proc, 0, len(order))
	for _, k := range order {
		out = append(out, *sum[k])
	}
	sort.SliceStable(out, func(i, j int) bool {
		if byMemory {
			return out[i].RSS > out[j].RSS
		}
		return out[i].CPU > out[j].CPU
	})
	if len(out) > n {
		out = out[:n]
	}
	return out
}

// WiFi is the current wireless connection. The network's name needs location access, so it is often hidden.
type WiFi struct {
	Name    string `json:"name,omitempty"`
	Channel string `json:"channel,omitempty"`
	Mode    string `json:"mode,omitempty"`
	RateMb  int    `json:"rate_mbps,omitempty"`
	Signal  int    `json:"signal_dbm,omitempty"`
	Noise   int    `json:"noise_dbm,omitempty"`
}

// WiFi reads the connection. system_profiler is slow, so it has its own limit.
func (e *Env) WiFi() (WiFi, bool) {
	if !e.Mac() {
		return WiFi{}, false
	}
	r := e.Run.Run(12*time.Second, "system_profiler", "-json", "SPAirPortDataType")
	if !r.OK() {
		return WiFi{}, false
	}
	return ParseAirport(r.Stdout)
}

var dbm = regexp.MustCompile(`(-?\d+) dBm / (-?\d+) dBm`)

// ParseAirport reads system_profiler -json SPAirPortDataType.
func ParseAirport(text string) (WiFi, bool) {
	var d struct {
		Data []struct {
			Ifaces []struct {
				Current *struct {
					Name    string `json:"_name"`
					Channel string `json:"spairport_network_channel"`
					Mode    string `json:"spairport_network_phymode"`
					Rate    int    `json:"spairport_network_rate"`
					SN      string `json:"spairport_signal_noise"`
				} `json:"spairport_current_network_information"`
			} `json:"spairport_airport_interfaces"`
		} `json:"SPAirPortDataType"`
	}
	if json.Unmarshal([]byte(text), &d) != nil {
		return WiFi{}, false
	}
	for _, x := range d.Data {
		for _, i := range x.Ifaces {
			c := i.Current
			if c == nil || c.SN == "" {
				continue
			}
			w := WiFi{Channel: c.Channel, Mode: c.Mode, RateMb: c.Rate}
			if c.Name != "<redacted>" {
				w.Name = c.Name
			}
			if m := dbm.FindStringSubmatch(c.SN); m != nil {
				w.Signal, _ = strconv.Atoi(m[1])
				w.Noise, _ = strconv.Atoi(m[2])
			}
			return w, true
		}
	}
	return WiFi{}, false
}

// Tunnels are the VPN and overlay networks this machine is on, by interface and address.
func Tunnels() []string {
	ifs, err := net.Interfaces()
	if err != nil {
		return nil
	}
	_, cgnat, _ := net.ParseCIDR("100.64.0.0/10")
	var out []string
	for _, i := range ifs {
		n := i.Name
		if i.Flags&net.FlagUp == 0 || !(strings.HasPrefix(n, "utun") || strings.HasPrefix(n, "tun") || strings.HasPrefix(n, "wg") || strings.HasPrefix(n, "tailscale") || strings.HasPrefix(n, "ppp") || strings.HasPrefix(n, "ipsec")) {
			continue
		}
		addrs, _ := i.Addrs()
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if !ok || ipn.IP.To4() == nil {
				continue
			}
			what := "a VPN"
			if cgnat.Contains(ipn.IP) {
				what = "Tailscale"
			}
			out = append(out, what+" ("+n+", "+ipn.IP.String()+")")
		}
	}
	return out
}

// DNSServers are the servers this machine asks, in order.
func (e *Env) DNSServers() []string {
	var text string
	if e.Mac() {
		text, _ = e.Out("scutil", "--dns")
	} else if b, err := os.ReadFile("/etc/resolv.conf"); err == nil {
		text = string(b)
	}
	return ParseNameservers(text)
}

var nsLine = regexp.MustCompile(`(?m)^\s*nameserver(?:\[\d+\])?\s*:?\s*(\S+)`)

// ParseNameservers reads scutil --dns or resolv.conf.
func ParseNameservers(text string) []string {
	seen := map[string]bool{}
	var out []string
	for _, m := range nsLine.FindAllStringSubmatch(text, -1) {
		if !seen[m[1]] {
			seen[m[1]] = true
			out = append(out, m[1])
		}
	}
	return out
}

// Proxy is the web proxy this machine uses, or "".
func (e *Env) Proxy() string {
	if e.Mac() {
		s, _ := e.Out("scutil", "--proxy")
		return ParseProxy(s)
	}
	for _, k := range []string{"HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"} {
		if e.Getenv != nil && e.Getenv(k) != "" {
			return e.Getenv(k)
		}
	}
	return ""
}

var proxyHost = regexp.MustCompile(`HTTPSProxy : (\S+)`)
var proxyPort = regexp.MustCompile(`HTTPSPort : (\d+)`)

// ParseProxy reads scutil --proxy.
func ParseProxy(s string) string {
	if !strings.Contains(s, "HTTPSEnable : 1") {
		if strings.Contains(s, "ProxyAutoConfigEnable : 1") {
			return "set by a configuration script"
		}
		return ""
	}
	h := proxyHost.FindStringSubmatch(s)
	if h == nil {
		return "on"
	}
	if p := proxyPort.FindStringSubmatch(s); p != nil {
		return h[1] + ":" + p[1]
	}
	return h[1]
}
