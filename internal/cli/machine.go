package cli

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/journal"
	"github.com/theappfoundryco/catalyst/internal/session"
	"github.com/theappfoundryco/catalyst/internal/shellpath"
	"github.com/theappfoundryco/catalyst/internal/sweep"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

func cmdDisk(a *App, args []string) int {
	fs := a.flags("disk", "[--folders] [--json]")
	folders := fs.Bool("folders", false, "")
	asJSON := fs.Bool("json", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	u := a.U
	a.outcome.Refresh = true
	vols := a.E.Volumes()
	health := a.E.DriveHealth()
	if *asJSON {
		return emit(a, map[string]any{"volumes": vols, "drive": health})
	}
	u.Hdr("Disks")
	for _, v := range vols {
		mark := a.row(a.revealKey(v.Mount), a.copyKey("y", "copy path", v.Mount, "the path"))
		u.Row(v.Name, mark+u.Bar(v.UsedPercent, 18, 75, 90)+"  "+u.Dim(ui.Size(v.Free)+" free of "+ui.Size(v.Size)))
	}
	u.Hdr("Drive health")
	if health.Model != "" {
		u.Row("Drive", u.Bold(health.Model))
	}
	if health.Status != "" {
		style := u.Green
		if !health.OK {
			style = u.Red
		}
		u.Row("Self-test", style(health.Status)+u.Dim("  the drive's own verdict on itself"))
	}
	if health.WearPercent >= 0 && health.HasSmart {
		u.Row("Wear", u.Bar(health.WearPercent, 18, 80, 90)+"  "+u.Level(health.WearPercent, 80, 90)(fmt.Sprintf("%d%% used, %d%% of its rated life left", health.WearPercent, 100-health.WearPercent)))
	}
	if health.HasSmart && health.Spare > 0 {
		note := fmt.Sprintf("%d%% of the spare cells left", health.Spare)
		if health.SpareLimit > 0 {
			note += u.Dim(fmt.Sprintf(", it warns below %d%%", health.SpareLimit))
		}
		u.Row("Spare", u.Level(100-health.Spare, 50, 90)(note))
	}
	if health.BytesWritten > 0 {
		u.Row("Written", ui.Size(health.BytesWritten)+u.Dim("  in its whole life"))
	}
	if health.BytesRead > 0 {
		u.Row("Read", ui.Size(health.BytesRead))
	}
	if health.TemperatureC > 0 {
		u.Row("Temperature", u.Level(health.TemperatureC, 55, 70)(fmt.Sprintf("%d°C", health.TemperatureC)))
	}
	if health.PowerOnHours > 0 {
		u.Row("Power on", fmt.Sprintf("%d hours %s", health.PowerOnHours, u.Dim(fmt.Sprintf("(%d days)", health.PowerOnHours/24))))
	}
	if health.PowerCycles > 0 {
		u.Row("Started", fmt.Sprintf("%d times", health.PowerCycles))
	}
	if health.Unsafe > 0 {
		u.Row("Hard shutdowns", fmt.Sprintf("%d", health.Unsafe)+u.Dim("  power lost or forced off, not a problem on its own"))
	}
	if health.HasSmart {
		style := u.Green
		if health.MediaErrors > 0 {
			style = u.Red
		}
		u.Row("Media errors", style(strconv.FormatInt(health.MediaErrors, 10)))
	}
	switch {
	case health.NoTool:
		u.Blank()
		a.helperHint("smartmontools", "Wear, total read and written, and temperature need smartmontools. Install it from Helpers (h).")
	case health.Note != "":
		u.Hint(health.Note)
	}
	if health.HasSmart {
		u.Blank()
		u.Hint("A drive is rated for a lifetime of writing. Wear counts toward it. Most Macs are replaced long before 100%.")
	}
	if *folders {
		u.Hdr("Biggest folders in your home")
		type row struct {
			name string
			size int64
		}
		var rows []row
		entries, _ := os.ReadDir(a.E.Home)
		sp := u.Spin("Measuring")
		for _, ent := range entries {
			if !ent.IsDir() {
				continue
			}
			sp.Detail(ent.Name())
			rows = append(rows, row{ent.Name(), sweep.DirSize(a.E.Path(ent.Name()), sweep.NewSeen())})
		}
		sp.Stop()
		sort.Slice(rows, func(i, j int) bool { return rows[i].size > rows[j].size })
		for i, r := range rows {
			if i == 8 {
				break
			}
			u.Say(fmt.Sprintf("  %s  %s", u.Cyan(fmt.Sprintf("%9s", ui.Size(r.size))), r.name))
		}
	}
	if a.inSession {
		a.outcome.Actions = append(a.outcome.Actions, goTo("s", "space", "Space", "space"))
	}
	u.Blank()
	return ExitOK
}

func cmdBattery(a *App, args []string) int {
	fs := a.flags("battery", "[--json]")
	asJSON := fs.Bool("json", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	u := a.U
	var b host.Battery
	if *asJSON {
		b = a.E.Battery()
		return emit(a, map[string]any{"battery": b, "details": a.E.BatteryCells()})
	}
	a.outcome.Refresh = true
	a.outcome.Live = 3 * time.Second
	u.Blank()
	sp := u.Spin("Reading the battery")
	b = a.E.Battery()
	c := a.E.BatteryCells()
	sp.Stop()
	if !b.Present {
		u.Say("  " + u.Dim("This machine has no battery."))
		u.Blank()
		return ExitOK
	}
	u.Hdr("Battery")
	u.Row("Charge", u.HealthBar(b.Percent, 18)+"%")
	state := b.Source
	switch {
	case b.Charging:
		state = "Charging"
	case c.FullyFull && b.Source == "Power adapter":
		state = "Power adapter, fully charged"
	}
	if c.AdapterW > 0 && b.Source == "Power adapter" {
		state += u.Dim(fmt.Sprintf(", %d W charger", c.AdapterW))
	}
	if b.TimeLeft != "" {
		state += u.Dim(", " + b.TimeLeft + " left")
	}
	u.Row("Now", state)
	switch {
	case c.Watts > 0.3:
		u.Row("Power", fmt.Sprintf("%.1f W going in", c.Watts))
	case c.Watts < -0.3:
		u.Row("Power", fmt.Sprintf("%.1f W going out", -c.Watts)+u.Dim("  what this Mac is using right now"))
	case c.Volts > 0:
		u.Row("Power", u.Dim("resting, nothing in or out"))
	}
	if b.Health > 0 {
		u.Row("Capacity", u.ScoreStyle(b.Health)(fmt.Sprintf("%d%%", b.Health))+u.Dim(" of when it was new, as macOS reports it"))
	}
	if c.DesignMAh > 0 && c.FullMAh > 0 {
		u.Row("Holds", fmt.Sprintf("%s mAh when full", thousands(c.FullMAh))+u.Dim(fmt.Sprintf(", %s when new", thousands(c.DesignMAh))))
	}
	if b.Condition != "" {
		u.Row("Condition", b.Condition)
	}
	if b.Cycles > 0 {
		v := strconv.Itoa(b.Cycles)
		if c.RatedCycle > 0 {
			pct := b.Cycles * 100 / c.RatedCycle
			v = u.Bar(pct, 18, 80, 100) + "  " + fmt.Sprintf("%d of %s", b.Cycles, thousands(c.RatedCycle)) + u.Dim(" it is rated for")
		}
		u.Row("Cycles", v)
	}
	if b.TemperatureC > 0 {
		u.Row("Temperature", u.Level(int(b.TemperatureC), 35, 45)(fmt.Sprintf("%.0f°C", b.TemperatureC)))
	}
	if len(c.CellVolts) > 1 {
		lo, hi := c.CellVolts[0], c.CellVolts[0]
		var parts []string
		for _, v := range c.CellVolts {
			lo, hi = math.Min(lo, v), math.Max(hi, v)
			parts = append(parts, fmt.Sprintf("%.3f V", v))
		}
		verdict := u.Green("  balanced")
		if hi-lo > 0.1 {
			verdict = u.Orange("  uneven, worth a check at a service centre")
		}
		u.Row("Cells", strings.Join(parts, "  ")+verdict)
	}
	if c.Volts > 0 {
		u.Row("Voltage", fmt.Sprintf("%.2f V", c.Volts))
	}
	if c.LowPower != nil {
		v := "off"
		if *c.LowPower {
			v = "on"
		}
		u.Row("Low Power Mode", v)
	}
	u.Blank()
	u.Hint("Batteries last longest kept between about 20% and 80%, and away from heat. Optimized Charging in Battery settings does this for you.")
	if a.inSession && a.E.Mac() {
		a.outcome.Actions = append(a.outcome.Actions, a.urlKey("s", "Battery settings", settingsBattery))
	}
	u.Blank()
	return ExitOK
}

// thousands writes 5103 as 5,103.
func thousands(n int) string {
	s := strconv.Itoa(n)
	for i := len(s) - 3; i > 0; i -= 3 {
		s = s[:i] + "," + s[i:]
	}
	return s
}

func cmdNet(a *App, args []string) int {
	fs := a.flags("net", "[test HOST | speed | ip | trace HOST]")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	switch {
	case fs.NArg() == 2 && fs.Arg(0) == "test":
		return a.netTest(fs.Arg(1))
	case fs.NArg() == 1 && fs.Arg(0) == "test":
		target := strings.TrimSpace(a.U.Text("Address to test " + a.U.Dim("(a domain, an IP, or host:port) ")))
		if target == "" {
			a.outcome.SkipWait = true
			return ExitOK
		}
		return a.netTest(target)
	case fs.NArg() == 2 && fs.Arg(0) == "trace":
		return a.netTrace(fs.Arg(1))
	case fs.NArg() == 1 && fs.Arg(0) == "speed":
		return a.netSpeed()
	case fs.NArg() == 1 && fs.Arg(0) == "ip":
		return a.publicIP()
	case fs.NArg() == 1:
		return a.netTest(fs.Arg(0)) // catalyst net example.com, as before
	case fs.NArg() > 1:
		fs.Usage()
		return ExitUsage
	}
	u := a.U
	a.outcome.Refresh = true
	u.Hdr("Network")
	ok := true
	if ip := localIP(); ip != "" {
		u.Row("This machine", ip)
	}
	gw := a.E.Gateway()
	if gw != "" {
		u.Row("Router", gw)
	} else {
		u.Warn("No route to the internet. Check your Wi-Fi or cable.")
		ok = false
	}
	if w, found := a.E.WiFi(); found {
		name := w.Name
		if name == "" {
			name = u.Dim("name hidden by macOS")
		}
		u.Row("Wi-Fi", name+u.Dim(fmt.Sprintf("  %s, channel %s, %d Mb/s", w.Mode, w.Channel, w.RateMb)))
		if w.Signal != 0 {
			snr := w.Signal - w.Noise
			word := "excellent"
			switch {
			case snr < 15:
				word = "poor, move closer to the router"
			case snr < 25:
				word = "fair"
			case snr < 40:
				word = "good"
			}
			u.Row("Signal", u.Level(60-snr, 35, 45)(fmt.Sprintf("%d dBm, %s", w.Signal, word))+u.Dim(fmt.Sprintf("  noise %d dBm", w.Noise)))
		}
	}
	for _, t := range host.Tunnels() {
		u.Row("Tunnel", t)
	}
	if p := a.E.Proxy(); p != "" {
		u.Row("Proxy", p)
	}
	servers := a.E.DNSServers()
	if len(servers) > 0 {
		list := servers
		if len(list) > 3 {
			list = list[:3]
		}
		u.Row("DNS servers", strings.Join(list, ", "))
	}
	u.Sect("Checks")
	if !a.dnsCompare("github.com") {
		ok = false
	}
	if ms, reached := bestDial("1.1.1.1:443", 3); reached {
		word := "excellent"
		if ms >= 100 {
			word = "slow"
		} else if ms >= 50 {
			word = "okay"
		}
		u.Row("Internet", u.Level(ms, 50, 100)(fmt.Sprintf("✓ %d ms, %s", ms, word)))
	} else {
		u.Row("Internet", u.Red("✗ could not reach the internet"))
		ok = false
	}
	for _, h := range []struct{ host, name string }{{"github.com", "GitHub"}, {"registry.npmjs.org", "npm"}, {"pypi.org", "PyPI"}} {
		if ms, reached := bestDial(h.host+":443", 1); reached {
			u.Row(h.name, u.Green(fmt.Sprintf("✓ %d ms", ms))+u.Dim("  "+h.host))
		} else {
			u.Row(h.name, u.Red("✗ "+h.host+" does not answer on port 443"))
			ok = false
		}
	}
	u.Blank()
	if a.inSession {
		a.outcome.Actions = append(a.outcome.Actions,
			goTo("t", "test an address", "Network", "net", "test"),
			goTo("p", "public IP", "Network", "net", "ip"))
		if a.E.Mac() {
			a.outcome.Actions = append(a.outcome.Actions, goTo("s", "speed test", "Network", "net", "speed"), a.urlKey("n", "Network settings", settingsNetwork))
		}
	} else {
		u.Hint("Test any address: catalyst net test example.com   Speed: catalyst net speed   Public IP: catalyst net ip")
	}
	u.Blank()
	if !ok {
		return ExitIssues
	}
	return ExitOK
}

// bestDial connects a few times and keeps the fastest, in milliseconds.
func bestDial(addr string, tries int) (int, bool) {
	best, reached := time.Duration(0), false
	for i := 0; i < tries; i++ {
		t := time.Now()
		c, err := net.DialTimeout("tcp", addr, 3*time.Second)
		if err != nil {
			continue
		}
		c.Close()
		if d := time.Since(t); !reached || d < best {
			best, reached = d, true
		}
	}
	return int(best.Milliseconds()), reached
}

// dnsCompare looks a name up through this machine's own DNS, and through two public ones, so a slow or broken
// resolver shows up as exactly that.
func (a *App) dnsCompare(name string) bool {
	u := a.U
	look := func(server string) (time.Duration, error) {
		r := &net.Resolver{}
		if server != "" {
			r = &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
				d := net.Dialer{Timeout: 3 * time.Second}
				return d.DialContext(ctx, "udp", server)
			}}
		}
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		defer cancel()
		t := time.Now()
		_, err := r.LookupHost(ctx, name)
		return time.Since(t), err
	}
	mine, err := look("")
	if err != nil {
		u.Row("DNS", u.Red("✗ could not look up "+name))
	} else {
		u.Row("DNS", u.Level(int(mine.Milliseconds()), 80, 300)(fmt.Sprintf("✓ %d ms", mine.Milliseconds()))+u.Dim("  yours"))
	}
	for _, s := range []struct{ addr, name string }{{"1.1.1.1:53", "Cloudflare"}, {"8.8.8.8:53", "Google"}} {
		if d, err := look(s.addr); err == nil {
			u.Row("", u.Dim(fmt.Sprintf("  %d ms through %s", d.Milliseconds(), s.name)))
		}
	}
	if err != nil {
		u.Hint("If the checks below work, your DNS is the problem, not your connection.")
		return false
	}
	return true
}

// netTest checks one address end to end: its name, ping, the port, and for a website its certificate.
func (a *App) netTest(target string) int {
	u := a.U
	host, port := target, ""
	if strings.Contains(target, "://") {
		if p, err := url.Parse(target); err == nil {
			host, port = p.Hostname(), p.Port()
			if port == "" && p.Scheme == "http" {
				port = "80"
			}
		}
	} else if h, p, err := net.SplitHostPort(target); err == nil {
		host, port = h, p
	}
	host = strings.TrimSuffix(host, "/")
	u.Hdr("Testing " + target)
	ok := true
	ips := []string{host}
	if net.ParseIP(host) == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		t := time.Now()
		addrs, err := net.DefaultResolver.LookupHost(ctx, host)
		cancel()
		if err != nil {
			u.Row("Name", u.Red("✗ "+host+" does not resolve"))
			u.Hint("Check the spelling. If it is a private name, you may need your VPN.")
			u.Blank()
			return ExitIssues
		}
		ips = addrs
		shown := addrs
		if len(shown) > 3 {
			shown = shown[:3]
		}
		u.Row("Name", u.Green(fmt.Sprintf("✓ %d ms", time.Since(t).Milliseconds()))+"  "+u.Dim(strings.Join(shown, ", ")))
	}
	pingArgs := []string{"-c", "3", "-W", "2", ips[0]}
	if a.E.Mac() {
		pingArgs = []string{"-c", "3", "-t", "5", ips[0]}
	}
	r := a.E.Run.Run(8*time.Second, "ping", pingArgs...)
	if avg, loss, found := parsePing(r.Stdout); found {
		note := fmt.Sprintf("%.0f ms", avg)
		if loss > 0 {
			note += fmt.Sprintf(", %d%% of replies lost", loss)
		}
		u.Row("Ping", u.Level(int(avg), 80, 200)("✓ "+note))
	} else {
		u.Row("Ping", u.Dim("no reply, which many servers do on purpose"))
	}
	ports := []string{port}
	if port == "" {
		ports = []string{"443", "80"}
	}
	open := ""
	for _, p := range ports {
		t := time.Now()
		c, err := net.DialTimeout("tcp", net.JoinHostPort(host, p), 4*time.Second)
		if err != nil {
			u.Row("Port "+p, u.Red("✗ closed or filtered"))
			continue
		}
		c.Close()
		u.Row("Port "+p, u.Green(fmt.Sprintf("✓ open, %d ms", time.Since(t).Milliseconds())))
		if open == "" {
			open = p
		}
	}
	if open == "" {
		ok = false
	}
	if open == "443" || port == "443" {
		conn, err := tls.DialWithDialer(&net.Dialer{Timeout: 5 * time.Second}, "tcp", net.JoinHostPort(host, "443"), &tls.Config{ServerName: host})
		if err != nil {
			u.Row("Certificate", u.Red("✗ "+plainTLS(err)))
			ok = false
		} else {
			cert := conn.ConnectionState().PeerCertificates[0]
			conn.Close()
			days := int(time.Until(cert.NotAfter).Hours() / 24)
			issuer := cert.Issuer.Organization
			who := "unknown issuer"
			if len(issuer) > 0 {
				who = issuer[0]
			}
			u.Row("Certificate", u.Level(60-days, 30, 53)(fmt.Sprintf("✓ valid for %d more days", days))+u.Dim("  from "+who))
		}
	}
	if open == "443" || open == "80" {
		scheme := "https"
		if open == "80" {
			scheme = "http"
		}
		client := &http.Client{Timeout: 6 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
		t := time.Now()
		if resp, err := client.Head(scheme + "://" + net.JoinHostPort(host, open) + "/"); err == nil {
			resp.Body.Close()
			u.Row("Web", fmt.Sprintf("%s  %s", resp.Status, u.Dim(fmt.Sprintf("in %d ms", time.Since(t).Milliseconds()))))
		}
	}
	u.Blank()
	if a.inSession {
		a.outcome.Refresh = true
		a.outcome.Actions = append(a.outcome.Actions, goTo("w", "trace the route", "Network", "net", "trace", host), goTo("t", "test another", "Network", "net", "test"))
	}
	if !ok {
		return ExitIssues
	}
	return ExitOK
}

func plainTLS(err error) string {
	s := err.Error()
	switch {
	case strings.Contains(s, "expired"):
		return "the certificate has expired"
	case strings.Contains(s, "not valid for"), strings.Contains(s, "doesn't contain"):
		return "the certificate is for a different name"
	case strings.Contains(s, "unknown authority"):
		return "the certificate is not from a known authority"
	}
	return "the secure connection failed"
}

var pingAvg = regexp.MustCompile(`= [\d.]+/([\d.]+)/`)
var pingLoss = regexp.MustCompile(`([\d.]+)% packet loss`)

func parsePing(s string) (avg float64, loss int, ok bool) {
	m := pingAvg.FindStringSubmatch(s)
	if m == nil {
		return 0, 0, false
	}
	avg, _ = strconv.ParseFloat(m[1], 64)
	if l := pingLoss.FindStringSubmatch(s); l != nil {
		f, _ := strconv.ParseFloat(l[1], 64)
		loss = int(f)
	}
	return avg, loss, true
}

// netTrace shows each hop to an address. It can take a while, so it is only run when asked.
func (a *App) netTrace(host string) int {
	u := a.U
	u.Hdr("Route to " + host)
	sp := u.Spin("Tracing, up to 15 hops")
	r := a.E.Run.Run(45*time.Second, "traceroute", "-n", "-m", "15", "-q", "1", "-w", "1", host)
	sp.Stop()
	if r.NotFound {
		u.Stop("traceroute is not installed here.")
		return ExitFailed
	}
	for _, l := range strings.Split(strings.TrimSpace(r.Stdout), "\n") {
		f := strings.Fields(l)
		if len(f) < 2 {
			continue
		}
		if f[1] == "*" {
			u.Say(fmt.Sprintf("  %3s  %s", f[0], u.Dim("no answer")))
			continue
		}
		ms := ""
		if len(f) >= 3 {
			ms = f[2] + " ms"
		}
		u.Say(fmt.Sprintf("  %3s  %-16s %s", f[0], f[1], u.Dim(ms)))
	}
	u.Blank()
	u.Hint("Hops that do not answer are normal. A big jump in time between two hops shows where it slows down.")
	u.Blank()
	return ExitOK
}

// netSpeed runs macOS's own network quality test, which talks to Apple's servers.
func (a *App) netSpeed() int {
	u := a.U
	u.Hdr("Speed test")
	if _, err := a.E.Look("networkQuality"); err != nil {
		u.Stop("This needs macOS 12 or later.")
		return ExitFailed
	}
	u.Say("  " + u.Dim("This uses macOS's own test, which downloads and uploads from Apple's servers for about 20 seconds."))
	sp := u.Spin("Testing")
	r := a.E.Run.Run(60*time.Second, "networkQuality", "-c")
	sp.Stop()
	var q struct {
		Down float64 `json:"dl_throughput"`
		Up   float64 `json:"ul_throughput"`
		RPM  float64 `json:"responsiveness"`
	}
	if json.Unmarshal([]byte(r.Stdout), &q) != nil || q.Down == 0 {
		u.Stop("The test did not finish.")
		return ExitFailed
	}
	u.Row("Download", fmt.Sprintf("%.0f Mb/s", q.Down/1e6))
	u.Row("Upload", fmt.Sprintf("%.0f Mb/s", q.Up/1e6))
	if q.RPM > 0 {
		word := "high, good for calls and games"
		switch {
		case q.RPM < 200:
			word = "low, calls may stutter when the line is busy"
		case q.RPM < 800:
			word = "medium"
		}
		u.Row("Responsiveness", fmt.Sprintf("%.0f RPM, %s", q.RPM, word))
	}
	u.Blank()
	if a.inSession {
		a.outcome.Refresh = true
	}
	return ExitOK
}

// publicIP asks Cloudflare which address the internet sees. It is the one lookup that tells an outside service
// something, so it only runs when asked.
func (a *App) publicIP() int {
	u := a.U
	u.Hdr("Public IP")
	client := &http.Client{Timeout: 6 * time.Second}
	resp, err := client.Get("https://1.1.1.1/cdn-cgi/trace")
	if err != nil {
		u.Stop("Could not reach Cloudflare to ask.")
		return ExitFailed
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	vals := map[string]string{}
	for _, l := range strings.Split(string(b), "\n") {
		if k, v, ok := strings.Cut(l, "="); ok {
			vals[k] = v
		}
	}
	ip := vals["ip"]
	if ip == "" {
		u.Stop("Cloudflare did not say.")
		return ExitFailed
	}
	u.Row("Seen as", u.Bold(ip))
	if loc := vals["loc"]; loc != "" {
		u.Row("Country", loc)
	}
	if vals["warp"] == "on" {
		u.Row("Through", "Cloudflare WARP")
	}
	u.Blank()
	u.Hint("This is the address websites see. Behind a VPN, it is the VPN's.")
	if a.inSession {
		a.outcome.Actions = append(a.outcome.Actions, a.copyKey("y", "copy", ip, "the address"))
	}
	u.Blank()
	return ExitOK
}

func localIP() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ""
	}
	for _, addr := range addrs {
		if n, ok := addr.(*net.IPNet); ok && n.IP.To4() != nil && n.IP.IsPrivate() {
			return n.IP.String()
		}
	}
	return ""
}

// protectedProcs must never be stopped from here, whatever port they hold.
var protectedProcs = map[string]bool{"launchd": true, "loginwindow": true, "systemd": true, "sshd": true, "ControlCenter": true, "Finder": true, "Dock": true, "init": true, "tailscaled": true, "mDNSResponder": true, "rapportd": true}

func cmdPorts(a *App, args []string) int {
	fs := a.flags("ports", "[stop | kill PORT] [--yes] [--json]")
	asJSON := fs.Bool("json", false, "")
	yes := fs.Bool("yes", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	a.U.Yes = a.U.Yes || *yes
	if fs.NArg() == 1 && fs.Arg(0) == "stop" {
		return a.pickPort()
	}
	if fs.NArg() >= 1 && fs.Arg(0) == "kill" {
		if fs.NArg() != 2 {
			fs.Usage()
			return ExitUsage
		}
		port, err := strconv.Atoi(fs.Arg(1))
		if err != nil || port < 1 || port > 65535 {
			a.U.Stop(fs.Arg(1) + " is not a port number.")
			return ExitUsage
		}
		return a.killPort(port)
	}
	list := a.E.Listeners()
	if *asJSON {
		if list == nil {
			list = []host.Listener{}
		}
		return emit(a, list)
	}
	u := a.U
	a.outcome.Refresh = true
	u.Hdr("What is listening")
	if len(list) == 0 {
		u.Say("  " + u.Dim("Nothing that this user can see."))
		u.Blank()
		return ExitOK
	}
	open, stoppable := 0, 0
	var guarded []string
	for _, l := range list {
		if wide(l) {
			open++
		}
		if a.canStop(l) {
			stoppable++
		} else if protectedProcs[l.Command] {
			guarded = append(guarded, fmt.Sprintf("%s (%d)", l.Command, l.Port))
		}
	}
	head := u.Bold(ui.Count(len(list), "program is listening", "programs are listening"))
	if open > 0 {
		head += u.Faint("  ·  ") + u.Orange(fmt.Sprintf("%d can be reached from your network", open))
	}
	u.Say("  " + head)
	u.Blank()
	nameW := 8
	for _, l := range list {
		if n := len(l.Command); n > nameW {
			nameW = n
		}
	}
	if nameW > 24 {
		nameW = 24
	}
	u.Say("  " + u.Faint(fmt.Sprintf("%-7s %-*s  %-7s %s", "PORT", nameW, "PROGRAM", "PID", "REACHABLE FROM")))
	for _, l := range list {
		l := l
		name := l.Command
		if name == "" {
			name = "(another user's)"
		}
		reach := u.Faint("● ") + u.Dim("this machine only")
		if wide(l) {
			reach = u.Orange("● your whole network")
		}
		pid := ""
		if l.PID > 0 {
			pid = strconv.Itoa(l.PID)
		}
		if protectedProcs[l.Command] {
			reach += u.Faint("  protected")
		}
		keys := []session.Action{a.page("⏎", "details", fmt.Sprintf("Port %d", l.Port), func() { a.portDetails(l) })}
		if a.canStop(l) {
			keys = append(keys, goTo("s", "stop it", "Ports", "ports", "kill", strconv.Itoa(l.Port)))
		}
		keys = append(keys, a.urlKey("w", "open in browser", fmt.Sprintf("http://localhost:%d", l.Port)))
		u.Say(fmt.Sprintf("  %s%s %s  %s %s", a.row(keys...), u.Accent(fmt.Sprintf("%-7d", l.Port)), fmt.Sprintf("%-*s", nameW, ui.Fit(name, nameW)), u.Faint(fmt.Sprintf("%-7s", pid)), reach))
	}
	u.Blank()
	if stoppable > 0 {
		u.Warn("Stopping a port stops the program behind it. Unsaved work in it can be lost, and apps that rely on it may misbehave until it starts again.")
	}
	if len(guarded) > 0 {
		u.Note("Never stopped from here, because the system needs them: " + strings.Join(guarded, ", ") + ".")
	}
	switch {
	case stoppable == 0:
		u.Say("  " + u.Dim("None of these can be stopped from here: they belong to the system or another user."))
	case !a.inSession:
		u.Say("  " + u.Accent("i") + "  " + u.Dim("To stop one: ") + "catalyst ports stop" + u.Dim("  or  ") + "catalyst ports kill " + u.Accent("PORT"))
	}
	u.Blank()
	return ExitOK
}

// portDetails is everything known about one listener, for the screen a row opens.
func (a *App) portDetails(l host.Listener) {
	u := a.U
	u.Hdr(fmt.Sprintf("Port %d", l.Port))
	u.Row("Program", u.Bold(orDash(l.Command)))
	if l.PID > 0 {
		u.Row("Process", strconv.Itoa(l.PID))
	}
	if l.User != "" {
		u.Row("Runs as", l.User)
	}
	reach := "this machine only, at " + l.Address
	if wide(l) {
		reach = u.Orange("every network this machine is on")
	}
	u.Row("Reachable from", reach)
	if l.PID > 0 {
		if s, ok := a.E.Out("ps", "-o", "lstart=", "-p", strconv.Itoa(l.PID)); ok && s != "" {
			u.Row("Started", strings.Join(strings.Fields(s), " "))
		}
		if s, ok := a.E.Out("ps", "-o", "command=", "-p", strconv.Itoa(l.PID)); ok && s != "" {
			u.Row("Command", s)
		}
		if dir := a.E.Folder(l.PID); dir != "" {
			u.Row("Working in", a.E.Tilde(dir))
		}
	}
	u.Blank()
	switch {
	case protectedProcs[l.Command]:
		u.Note(l.Command + " is part of the system, so Catalyst never stops it.")
	case a.canStop(l):
		u.Hint("Stopping it quits " + l.Command + ". It is asked to quit first, and only forced if you say so.")
		a.outcome.Actions = append(a.outcome.Actions, goTo("s", "stop it", "Ports", "ports", "kill", strconv.Itoa(l.Port)))
	default:
		u.Note("It belongs to another user, so it can only be stopped as root.")
	}
	a.outcome.Actions = append(a.outcome.Actions, a.urlKey("w", "open in browser", fmt.Sprintf("http://localhost:%d", l.Port)),
		a.copyKey("y", "copy address", fmt.Sprintf("localhost:%d", l.Port), "the address"))
	u.Blank()
}

func orDash(s string) string {
	if s == "" {
		return "unknown"
	}
	return s
}

// wide says whether a listener answers on every network the machine is on, not only to itself.
func wide(l host.Listener) bool {
	return l.Address == "*" || l.Address == "0.0.0.0" || l.Address == "[::]" || l.Address == "::"
}

// canStop is true for what this user may stop: their own process, not part of the system, and not Catalyst.
func (a *App) canStop(l host.Listener) bool {
	return l.PID > 0 && !protectedProcs[l.Command] && l.PID != os.Getpid()
}

// pickPort lists what can be stopped and stops the one chosen, the same careful way as ports kill.
func (a *App) pickPort() int {
	u := a.U
	var can []host.Listener
	for _, l := range a.E.Listeners() {
		if a.canStop(l) {
			can = append(can, l)
		}
	}
	if len(can) == 0 {
		u.Say("  " + u.Dim("Nothing here can be stopped by this user."))
		return ExitOK
	}
	u.Say("  " + u.Bold("Which one should stop?") + u.Faint("  ·  ") + u.Dim("it is asked to quit, and only forced if you say so"))
	u.Blank()
	items := make([]ui.Item, len(can))
	for i, l := range can {
		about := fmt.Sprintf("Process %d", l.PID)
		if dir := a.E.Folder(l.PID); dir != "" {
			about += ", running in " + a.E.Tilde(dir)
		}
		reach := "this machine only"
		if wide(l) {
			reach = "your whole network"
		}
		items[i] = ui.Item{Label: fmt.Sprintf("%-6d %s", l.Port, l.Command), Right: reach, About: about}
	}
	m := &ui.Menu{Items: items, Single: true, Action: "stop", Cancel: "back"}
	if !m.Run(u) {
		a.outcome.SkipWait = true
		return ExitOK
	}
	return a.killPort(can[m.Chosen].Port)
}

func (a *App) killPort(port int) int {
	u := a.U
	find := func() *host.Listener {
		for _, l := range a.E.Listeners() {
			if l.Port == port && l.PID > 0 {
				return &l
			}
		}
		return nil
	}
	l := find()
	if l == nil {
		u.Say("  Nothing you can stop is listening on port " + strconv.Itoa(port) + ".")
		return ExitOK
	}
	if protectedProcs[l.Command] {
		u.Stop(fmt.Sprintf("%s is part of the system, so it stays running.", l.Command))
		return ExitIssues
	}
	if l.PID == os.Getpid() {
		u.Stop("That is Catalyst itself.")
		return ExitIssues
	}
	u.Blank()
	u.Say(fmt.Sprintf("  Port %d is held by %s %s", port, u.Bold(l.Command), u.Dim(fmt.Sprintf("(process %d)", l.PID))))
	if dir := a.E.Folder(l.PID); dir != "" {
		u.Hint("running in " + a.E.Tilde(dir))
	}
	u.Hint("Stopping it quits " + l.Command + ". Unsaved work in it can be lost.")
	if !u.Ask("Stop it?") {
		return ExitOK
	}
	a.outcome.Changed = true
	batch := journal.NewBatch(a.E.Now())
	proc, err := os.FindProcess(l.PID)
	if err == nil {
		err = proc.Signal(syscall.SIGTERM)
	}
	if err != nil {
		u.Stop("Could not stop it: " + err.Error())
		return ExitIssues
	}
	a.Journal.Add(journal.Entry{Time: a.E.Now(), Batch: batch, Kind: journal.KindRun, Title: fmt.Sprintf("Stopped %s on port %d", l.Command, port), Command: []string{"kill", "-TERM", strconv.Itoa(l.PID)}})
	for i := 0; i < 25; i++ {
		time.Sleep(200 * time.Millisecond)
		if now := find(); now == nil || now.PID != l.PID {
			u.Ok(fmt.Sprintf("Stopped %s. Port %d is free.", l.Command, port))
			return ExitOK
		}
	}
	u.Warn(fmt.Sprintf("%s did not stop when asked.", l.Command))
	if !u.Ask("Force it? It will not get a chance to save anything") {
		return ExitIssues
	}
	// Check again that it is still the same process holding the port: process numbers get reused.
	if now := find(); now == nil || now.PID != l.PID {
		u.Ok(fmt.Sprintf("It stopped by itself. Port %d is free.", port))
		return ExitOK
	}
	if err := proc.Signal(syscall.SIGKILL); err != nil {
		u.Stop("Could not force it: " + err.Error())
		return ExitIssues
	}
	a.Journal.Add(journal.Entry{Time: a.E.Now(), Batch: batch, Kind: journal.KindRun, Title: fmt.Sprintf("Forced %s on port %d to stop", l.Command, port), Command: []string{"kill", "-KILL", strconv.Itoa(l.PID)}})
	u.Ok(fmt.Sprintf("Port %d is free.", port))
	return ExitOK
}

func cmdStartup(a *App, args []string) int {
	fs := a.flags("startup", "[disable NAME | enable NAME] [--json] [--yes]")
	asJSON := fs.Bool("json", false, "")
	yes := fs.Bool("yes", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	a.U.Yes = a.U.Yes || *yes
	u := a.U
	items := a.E.StartupItems()
	if fs.NArg() >= 1 {
		if fs.NArg() != 2 || (fs.Arg(0) != "disable" && fs.Arg(0) != "enable") {
			fs.Usage()
			return ExitUsage
		}
		return a.toggleStartup(items, fs.Arg(0), fs.Arg(1))
	}
	if *asJSON {
		if items == nil {
			items = []host.StartupItem{}
		}
		return emit(a, items)
	}
	a.outcome.Refresh = true
	u.Hdr("What starts by itself")
	if len(items) == 0 {
		u.Say("  " + u.Dim("Nothing found."))
	} else {
		u.Say("  " + u.Green("●") + u.Dim(" running   ") + u.Dim("-") + u.Dim(" not running now   ") + u.Red("✗") + u.Dim(" its program is gone"))
	}
	group := ""
	for _, it := range items {
		it := it
		if it.Kind != group {
			group = it.Kind
			u.Blank()
			u.Say("  " + u.Bold(group+"s"))
		}
		mark := u.Dim("-")
		if it.Loaded {
			mark = u.Green("●")
		}
		if it.Broken {
			mark = u.Red("✗")
		}
		keys := []session.Action{a.page("⏎", "details", it.Name, func() { a.startupDetails(it) })}
		if it.Path != "" {
			keys = append(keys, a.revealKey(it.Path))
		}
		if a.E.Mac() || it.Kind == "User service" || it.Kind == "System service" {
			keys = append(keys, goTo("t", "turn off", "Startup", "startup", "disable", it.Name))
		}
		line := "  " + a.row(keys...) + mark + " " + ui.Fit(it.Name, u.Width()-6)
		if it.Broken {
			line += u.Red("  its program is gone")
		}
		u.Say(line)
	}
	if a.E.Mac() {
		u.Blank()
		u.Say("  " + u.Dim("Apps you added under Login Items are in System Settings, General, Login Items."))
		if a.inSession {
			a.outcome.Actions = append(a.outcome.Actions, a.urlKey("L", "Login Items", settingsLoginItems))
		}
	}
	u.Blank()
	return ExitOK
}

// startupDetails is one startup item on its own screen.
func (a *App) startupDetails(it host.StartupItem) {
	u := a.U
	u.Hdr(it.Name)
	u.Row("Kind", it.Kind)
	state := u.Dim("not running now")
	if it.Loaded {
		state = u.Green("running")
	}
	u.Row("Now", state)
	if it.Program != "" {
		p := a.E.Tilde(it.Program)
		if it.Broken {
			p += u.Red("  (gone)")
		}
		u.Row("Runs", p)
	}
	if it.Path != "" {
		u.Row("Defined in", a.E.Tilde(it.Path))
		a.outcome.Actions = append(a.outcome.Actions, a.revealKey(it.Path), a.editKey(it.Path, 0))
	}
	who := "you"
	if !it.Mine {
		who = "the system (changing it needs your password)"
	}
	u.Row("Changed by", who)
	u.Blank()
	switch {
	case it.Broken:
		u.Warn("What it starts no longer exists, so it fails at every login. Turning it off is safe.")
	case a.E.Mac() && strings.HasPrefix(it.Name, "com.apple."):
		u.Note("This is part of macOS. Leave it on.")
	default:
		u.Hint("Turning it off stops it now and at every login. It is recorded, and you can turn it on again here or with: catalyst startup enable " + it.Name)
	}
	if a.E.Mac() || strings.Contains(it.Kind, "service") {
		a.outcome.Actions = append(a.outcome.Actions, goTo("t", "turn off", "Startup", "startup", "disable", it.Name),
			goTo("n", "turn on", "Startup", "startup", "enable", it.Name))
	}
	u.Blank()
}

func (a *App) toggleStartup(items []host.StartupItem, action, name string) int {
	u := a.U
	var it *host.StartupItem
	for i := range items {
		if items[i].Name == name {
			it = &items[i]
		}
	}
	if it == nil {
		u.Stop("Nothing called " + name + " starts by itself here.")
		return ExitUsage
	}
	if !it.Mine {
		return a.toggleSystemStartup(it, action)
	}
	var cmds [][]string
	switch {
	case a.E.Mac():
		target := "gui/" + strconv.Itoa(os.Getuid()) + "/" + name
		cmds = append(cmds, []string{"launchctl", action, target})
		if action == "disable" {
			cmds = append(cmds, []string{"launchctl", "bootout", target})
		}
	case it.Kind == "User service":
		cmds = append(cmds, []string{"systemctl", "--user", action, "--now", name})
	default:
		u.Stop("Change this one by hand: " + it.Kind + " items are not managed here.")
		return ExitIssues
	}
	for _, c := range cmds {
		u.Hint(strings.Join(c, " "))
	}
	if !u.Ask(strings.ToUpper(action[:1]) + action[1:] + " " + name + "?") {
		return ExitOK
	}
	batch := journal.NewBatch(a.E.Now())
	for _, c := range cmds {
		r := a.E.Run.Run(0, c[0], c[1:]...)
		// bootout reports failure when the item was not running, and that is fine: the goal is that it is stopped.
		if !r.OK() && c[1] != "bootout" {
			u.Stop(strings.TrimSpace(r.Stderr))
			return ExitIssues
		}
		a.Journal.Add(journal.Entry{Time: a.E.Now(), Batch: batch, Kind: journal.KindRun, Title: action + " " + name, Command: c})
	}
	a.outcome.Changed = true
	u.Ok(strings.ToUpper(action[:1]) + action[1:] + "d " + name)
	return ExitOK
}

// toggleSystemStartup changes an item that belongs to the system. Each command is shown first and runs only on a yes,
// through sudo's own password prompt.
func (a *App) toggleSystemStartup(it *host.StartupItem, action string) int {
	u := a.U
	var cmds [][]string
	switch {
	case a.E.Mac() && strings.HasPrefix(it.Name, "com.apple."):
		u.Stop(it.Name + " is part of macOS, so Catalyst leaves it alone.")
		return ExitIssues
	case a.E.Mac():
		domain := "system/"
		cmds = append(cmds, []string{"launchctl", action, domain + it.Name})
		if action == "disable" {
			cmds = append(cmds, []string{"launchctl", "bootout", domain + it.Name})
		}
	case it.Kind == "System service":
		cmds = append(cmds, []string{"systemctl", action, "--now", it.Name})
	default:
		u.Stop("Change this one by hand: " + it.Kind + " items are not managed here.")
		return ExitIssues
	}
	u.Say("  " + it.Name + u.Dim(" belongs to the system. This needs admin rights:"))
	for _, c := range cmds {
		u.Hint("sudo " + strings.Join(c, " "))
	}
	if !u.Ask(strings.ToUpper(action[:1]) + action[1:] + " " + it.Name + "?") {
		return ExitOK
	}
	if !a.sudoReady() {
		return ExitIssues
	}
	batch := journal.NewBatch(a.E.Now())
	for _, c := range cmds {
		if !a.asRoot(c...) && c[1] != "bootout" {
			u.Stop("That did not work, so it was left as it was.")
			return ExitIssues
		}
		a.Journal.Add(journal.Entry{Time: a.E.Now(), Batch: batch, Kind: journal.KindRun, Title: action + " " + it.Name, Command: append([]string{"sudo"}, c...)})
	}
	a.outcome.Changed = true
	u.Ok(strings.ToUpper(action[:1]) + action[1:] + "d " + it.Name)
	return ExitOK
}

func cmdSSH(a *App, args []string) int {
	fs := a.flags("ssh", "[--json]")
	asJSON := fs.Bool("json", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	u := a.U
	keys := a.E.SSHKeys()
	if *asJSON {
		if keys == nil {
			keys = []host.SSHKey{}
		}
		return emit(a, keys)
	}
	u.Hdr("SSH keys")
	dir := a.E.Path(".ssh")
	st, err := os.Stat(dir)
	if err != nil {
		u.Say("  " + u.Dim("No ~/.ssh on this machine. Make a key with: ssh-keygen -t ed25519"))
		u.Blank()
		return ExitOK
	}
	code := ExitOK
	if st.Mode().Perm()&0o077 != 0 {
		u.Warn(fmt.Sprintf("~/.ssh can be read by other users (%o). Fix: catalyst doctor --fix", st.Mode().Perm()))
		code = ExitIssues
	}
	if len(keys) == 0 {
		u.Say("  " + u.Dim("No keys in ~/.ssh."))
	}
	for _, k := range keys {
		k := k
		mark := a.row(a.sshKeys(k, false)...)
		detail := strings.TrimSpace(fmt.Sprintf("%s %d", k.Type, k.Bits))
		safe := true
		if k.Private != "" && k.Mode&0o077 != 0 {
			safe = false
			u.Stop(fmt.Sprintf("%s%s  %s  other users can read it (%o)", mark, k.Name, u.Dim(detail), k.Mode))
			code = ExitIssues
		} else if k.Weak {
			safe = false
			u.Warn(fmt.Sprintf("%s%s  %s  weak, make a new one", mark, k.Name, u.Dim(detail)))
			code = ExitIssues
		}
		if safe {
			kind := ""
			if k.Private == "" {
				kind = u.Dim("  public half only")
			}
			u.Ok(mark + k.Name + "  " + u.Dim(detail) + kind)
		}
		if k.Fingerprint != "" {
			u.Hint(k.Fingerprint)
		}
	}
	if a.inSession && len(keys) > 0 {
		u.Blank()
		u.Say("  " + u.Dim("Public keys can be copied. Private keys never are: nothing should ask for one, and a copied private key can reach your other devices through the clipboard."))
	}
	u.Blank()
	return code
}

// sshKeys are the keys for one key pair. details is true on the key's own screen, where Enter would open nothing new.
func (a *App) sshKeys(k host.SSHKey, details bool) []session.Action {
	var keys []session.Action
	if !details {
		keys = append(keys, a.page("⏎", "details", k.Name, func() { a.sshDetails(k) }))
	}
	if k.Public != "" {
		if b, err := os.ReadFile(k.Public); err == nil {
			keys = append(keys, a.copyKey("y", "copy public key", strings.TrimSpace(string(b)), "the public key of "+k.Name))
		}
	}
	if k.Fingerprint != "" {
		keys = append(keys, a.copyKey("f", "copy fingerprint", k.Fingerprint, "the fingerprint"))
	}
	target := k.Private
	if target == "" {
		target = k.Public
	}
	return append(keys, a.revealKey(target))
}

// sshDetails is one key pair on its own screen: what it is, where it lives, and where it is used.
func (a *App) sshDetails(k host.SSHKey) {
	u := a.U
	u.Hdr(k.Name)
	u.Row("Kind", strings.TrimSpace(fmt.Sprintf("%s, %d bits", k.Type, k.Bits)))
	if k.Fingerprint != "" {
		u.Row("Fingerprint", k.Fingerprint)
	}
	if k.Comment != "" {
		u.Row("Label", k.Comment)
	}
	if k.Private != "" {
		perm := u.Green(fmt.Sprintf("%o, only you can read it", k.Mode))
		if k.Mode&0o077 != 0 {
			perm = u.Red(fmt.Sprintf("%o, other users can read it", k.Mode))
		}
		u.Row("Private half", a.E.Tilde(k.Private))
		u.Row("Permissions", perm)
	}
	if k.Public != "" {
		u.Row("Public half", a.E.Tilde(k.Public))
	}
	hosts := sshHosts(a.E.Path(".ssh", "config"), a.E.Home, k)
	if len(hosts) > 0 {
		u.Row("Used for", strings.Join(hosts, ", "))
	} else {
		u.Row("Used for", u.Dim("no Host in ~/.ssh/config names it"))
	}
	u.Blank()
	if k.Public != "" {
		u.Hint("To use it on GitHub, copy the public key and add it under Settings, SSH and GPG keys.")
		a.outcome.Actions = append(a.outcome.Actions, a.urlKey("g", "GitHub keys page", "https://github.com/settings/keys"))
	}
	a.outcome.Actions = append(a.sshKeys(k, true), a.outcome.Actions...)
	u.Blank()
}

// sshHosts reads ~/.ssh/config for the Host blocks whose IdentityFile is this key.
func sshHosts(config, home string, k host.SSHKey) []string {
	b, err := os.ReadFile(config)
	if err != nil {
		return nil
	}
	var out, current []string
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(strings.TrimSpace(line))
		if len(f) < 2 {
			continue
		}
		switch strings.ToLower(f[0]) {
		case "host":
			current = f[1:]
		case "identityfile":
			p := strings.Trim(f[1], `"`)
			p = strings.Replace(p, "~", home, 1)
			if p == k.Private || p+".pub" == k.Public || p == k.Public {
				out = append(out, current...)
			}
		}
	}
	return out
}

func cmdPath(a *App, args []string) int {
	fs := a.flags("path", "[add | remove | status]")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	u := a.U
	action := fs.Arg(0)
	self, _ := os.Executable()
	a.E.LoadShell()
	st := shellpath.Check(a.E.Home, a.E.Shell, a.E.OS, os.Getenv("ZDOTDIR"), a.E.Entries, self, a.E.Look)
	switch action {
	case "status":
		fmt.Fprintf(u.Out, "%s %s\n", st.State, a.E.Tilde(st.RC))
		return ExitOK
	case "add":
		switch st.State {
		case "ready":
			u.Ok("The catalyst command is already in your terminal.")
		case "clash":
			u.Warn("Something else called catalyst comes first on your PATH: " + st.Found)
			u.Hint("It was left alone. Run this copy with its full path: " + self)
			return ExitIssues
		default:
			if err := shellpath.Add(st.RC); err != nil {
				u.Stop("Could not write to " + a.E.Tilde(st.RC) + ": " + err.Error())
				return ExitIssues
			}
			u.Ok("Added one line to " + a.E.Tilde(st.RC) + ". It works in new terminals.")
		}
		return ExitOK
	case "remove":
		changed := false
		for _, rc := range []string{shellpath.RCFile(a.E.Home, "zsh", a.E.OS, os.Getenv("ZDOTDIR")), shellpath.RCFile(a.E.Home, "bash", a.E.OS, ""), shellpath.RCFile(a.E.Home, "fish", a.E.OS, ""), shellpath.RCFile(a.E.Home, "", a.E.OS, "")} {
			if did, _ := shellpath.Remove(rc); did {
				u.Ok("Removed the line from " + a.E.Tilde(rc))
				changed = true
			}
		}
		if !changed {
			u.Say("  " + u.Dim("There was no Catalyst line to remove."))
		}
		return ExitOK
	case "":
	default:
		fs.Usage()
		return ExitUsage
	}
	return a.showPath()
}

func (a *App) showPath() int {
	u := a.U
	a.outcome.Refresh = true
	u.Hdr("Your PATH, in the order it is searched")
	type entry struct {
		dir, note, src string
		line           int
		mark           string
	}
	seen := map[string]bool{}
	dead, dupes := 0, 0
	var rows []entry
	dirW := 6
	for _, p := range a.E.Entries {
		clean := filepath.Clean(p)
		st, err := os.Stat(p)
		e := entry{dir: p, mark: u.Green("✓")}
		switch {
		case seen[clean]:
			e.mark, e.note = u.Yellow("!"), "listed twice, so the second one does nothing"
			dupes++
		case err != nil || !st.IsDir():
			e.mark, e.note = u.Yellow("!"), "does not exist"
			dead++
		}
		seen[clean] = true
		e.src, e.line = a.pathSource(p)
		rows = append(rows, e)
		if n := len(a.E.Tilde(p)); n > dirW {
			dirW = n
		}
	}
	srcW := u.Width() - 2 - 3 - 2 - 2
	if dirW > srcW-14 {
		dirW = srcW - 14
	}
	srcW -= dirW
	u.Say("  " + u.Faint(fmt.Sprintf("%3s   %-*s  %s", "#", dirW, "FOLDER", "ADDED BY")))
	for i, e := range rows {
		keys := []session.Action{a.copyKey("y", "copy", e.dir, a.E.Tilde(e.dir))}
		if host.Exists(e.dir) {
			keys = append([]session.Action{a.revealKey(e.dir)}, keys...)
		}
		if e.src != "" && !strings.HasPrefix(e.src, "/etc/") {
			keys = append(keys, a.editKey(e.src, e.line))
		}
		src := u.Dim(ui.Fit(a.E.Tilde(e.src), srcW))
		if e.src == "" {
			src = u.Faint("macOS or the shell")
		}
		dir := ui.Fit(a.E.Tilde(e.dir), dirW)
		dir += strings.Repeat(" ", max(0, dirW-ui.Visible(dir)))
		u.Say(fmt.Sprintf("  %s%s %s %s  %s", a.row(keys...), u.Dim(fmt.Sprintf("%2d", i+1)), e.mark, dir, src))
		if e.note != "" {
			u.Say("        " + u.Yellow(e.note))
		}
	}
	if dead > 0 {
		u.Blank()
		u.Note("A folder that does not exist only slows each search a little. It is safe to leave.")
		u.Hint("To remove one you added, take it out of the file named beside it. One from /etc/paths.d was put there by an installer.")
	}
	u.Sect("Tools hidden by an earlier folder")
	shadows := a.shadows()
	if len(shadows) == 0 {
		u.Ok("Nothing is hidden")
	}
	type group struct {
		tool, winner string
		hidden       []string
	}
	var groups []*group
	byTool := map[string]*group{}
	for _, sh := range shadows {
		g, ok := byTool[sh.tool]
		if !ok {
			g = &group{tool: sh.tool, winner: sh.winner}
			byTool[sh.tool] = g
			groups = append(groups, g)
		}
		g.hidden = append(g.hidden, a.E.Tilde(filepath.Dir(sh.hidden)))
	}
	toolW := 4
	for _, g := range groups {
		if len(g.tool) > toolW {
			toolW = len(g.tool)
		}
	}
	for i, g := range groups {
		if i == 12 {
			u.Hint(fmt.Sprintf("and %d more", len(groups)-12))
			break
		}
		pad := strings.Repeat(" ", toolW+2)
		u.Say("  " + a.row(a.copyKey("y", "copy path", g.winner, "the path")) + u.Bold(fmt.Sprintf("%-*s", toolW, g.tool)) + "  " + u.Dim("runs   ") + a.E.Tilde(g.winner))
		u.Say("  " + pad + u.Dim("hides  "+strings.Join(g.hidden, ", ")))
	}
	if len(groups) > 0 {
		u.Blank()
		u.Hint("The first folder on the list wins. That is usually what you want. If not, move the folder you prefer earlier in your startup file.")
	}
	u.Blank()
	if dead+dupes > 0 {
		return ExitIssues
	}
	return ExitOK
}

// pathSource finds which startup file names a folder, and on which line, so an entry can actually be found and fixed.
// macOS's own lists in /etc/paths and /etc/paths.d count too.
func (a *App) pathSource(dir string) (string, int) {
	short := strings.Replace(dir, a.E.Home, "$HOME", 1)
	tilde := a.E.Tilde(dir)
	files := a.E.RCFiles()
	if a.E.Mac() {
		files = append(files, "/etc/paths")
		extra, _ := filepath.Glob("/etc/paths.d/*")
		files = append(files, extra...)
	}
	for _, rc := range files {
		b, err := os.ReadFile(rc)
		if err != nil {
			continue
		}
		for n, line := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), "#") {
				continue
			}
			for _, needle := range []string{dir, short, tilde} {
				if strings.Contains(line, needle) {
					return rc, n + 1
				}
			}
		}
	}
	return "", 0
}

type shadow struct{ tool, winner, hidden string }

// notableTools are the commands where running the wrong copy causes real confusion. Comparing all of them would mostly list harmless system duplicates.
var notableTools = []string{"python", "python3", "pip", "pip3", "node", "npm", "npx", "ruby", "gem", "java", "javac", "go", "cargo", "rustc", "git", "make", "gcc", "clang", "php", "perl", "docker", "kubectl", "terraform", "brew", "code"}

func (a *App) shadows() []shadow {
	first := map[string]string{}
	var out []shadow
	for _, p := range a.E.Entries {
		for _, t := range notableTools {
			full := filepath.Join(p, t)
			st, err := os.Stat(full)
			if err != nil || st.IsDir() || st.Mode()&0o111 == 0 {
				continue
			}
			w, ok := first[t]
			if !ok {
				first[t] = full
				continue
			}
			ra, _ := filepath.EvalSymlinks(w)
			rb, _ := filepath.EvalSymlinks(full)
			if ra != rb {
				out = append(out, shadow{t, w, full})
			}
		}
	}
	return out
}

func cmdConfig(a *App, args []string) int {
	fs := a.flags("config", "[set name NAME | set mascot on|off | set animations on|off]")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	u := a.U
	c := a.Store.LoadConfig()
	onOff := func(on bool) string {
		if on {
			return "on"
		}
		return "off"
	}
	if fs.NArg() == 0 {
		u.Hdr("Settings")
		name := c.Nickname()
		if name == "" {
			name = u.Dim("not set")
		}
		u.Row("Your name", a.row(goTo("⏎", "change", "Settings", "config", "set", "name"))+name)
		u.Row("Kit", a.row(goTo("⏎", "turn "+onOff(!c.MascotOn()), "Settings", "config", "set", "mascot", onOff(!c.MascotOn())))+onOff(c.MascotOn()))
		u.Row("Animations", a.row(goTo("⏎", "turn "+onOff(!c.MotionOn()), "Settings", "config", "set", "animations", onOff(!c.MotionOn())))+onOff(c.MotionOn())+u.Dim("  Kit's wag and the health dot's pulse"))
		u.Row("Files", a.E.Tilde(a.Store.ConfigDir))
		u.Row("History", a.E.Tilde(a.Store.Dir))
		u.Blank()
		return ExitOK
	}
	if fs.Arg(0) != "set" || fs.NArg() < 2 {
		fs.Usage()
		return ExitUsage
	}
	switch key := fs.Arg(1); key {
	case "name":
		name := strings.TrimSpace(strings.Join(fs.Args()[2:], " "))
		if fs.NArg() == 2 {
			name = strings.TrimSpace(u.Text("What should I call you? " + u.Dim("(Enter for no name) ")))
		}
		if len(name) > 24 {
			name = name[:24]
		}
		c.Name = &name
		if name == "" {
			u.Ok("No name. Catalyst just says hello.")
		} else {
			u.Ok("Hello, " + name + ".")
		}
	case "mascot", "animations":
		if fs.NArg() != 3 || (fs.Arg(2) != "on" && fs.Arg(2) != "off") {
			fs.Usage()
			return ExitUsage
		}
		on := fs.Arg(2) == "on"
		if key == "mascot" {
			c.Mascot = &on
			u.Ok("Kit is " + fs.Arg(2) + ".")
		} else {
			c.Motion = &on
			u.Ok("Animations are " + fs.Arg(2) + ". This takes effect the next time Catalyst opens.")
		}
	default:
		fs.Usage()
		return ExitUsage
	}
	if err := a.Store.SaveConfig(c); err != nil {
		u.Stop(err.Error())
		return ExitFailed
	}
	a.outcome.Changed = true
	return ExitOK
}
