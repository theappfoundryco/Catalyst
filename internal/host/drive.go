package host

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"
)

// Drive is the health of the disk the system runs from.
type Drive struct {
	Model        string `json:"model,omitempty"`
	Device       string `json:"device,omitempty"`
	Status       string `json:"status,omitempty"`
	OK           bool   `json:"ok"`
	HasSmart     bool   `json:"has_smart"`
	WearPercent  int    `json:"wear_percent"`
	TemperatureC int    `json:"temperature_c,omitempty"`
	PowerOnHours int    `json:"power_on_hours,omitempty"`
	BytesWritten int64  `json:"bytes_written,omitempty"`
	BytesRead    int64  `json:"bytes_read,omitempty"`
	Spare        int    `json:"available_spare_percent,omitempty"`
	SpareLimit   int    `json:"spare_threshold_percent,omitempty"`
	Unsafe       int64  `json:"unsafe_shutdowns,omitempty"`
	PowerCycles  int64  `json:"power_cycles,omitempty"`
	MediaErrors  int64  `json:"media_errors"`
	NoTool       bool   `json:"-"` // smartctl is not installed
	Note         string `json:"note,omitempty"`
}

func plistValue(text, key string) string {
	re := regexp.MustCompile(`<key>` + regexp.QuoteMeta(key) + `</key>\s*<string>([^<]*)</string>`)
	if m := re.FindStringSubmatch(text); m != nil {
		return m[1]
	}
	return ""
}

// physicalStore finds the real disk behind "/". On APFS "/" sits on a synthesized disk, and only the store underneath answers SMART.
var physicalStore = regexp.MustCompile(`<key>APFSPhysicalStores</key>\s*<array>\s*<dict>\s*<key>APFSPhysicalStore</key>\s*<string>(disk\d+)`)

// ParseDiskutil reads diskutil info -plist.
func ParseDiskutil(text string) Drive {
	d := Drive{WearPercent: -1, Model: strings.TrimSpace(plistValue(text, "MediaName")), Status: plistValue(text, "SMARTStatus")}
	d.OK = d.Status == "Verified"
	if m := physicalStore.FindStringSubmatch(text); m != nil {
		d.Device = "/dev/" + m[1]
	} else if p := plistValue(text, "ParentWholeDisk"); p != "" {
		d.Device = "/dev/" + p
	}
	return d
}

// DriveHealth reads the system drive. SMART detail needs smartctl, and root on Linux. Neither is required: without them
// this says what is missing and how to get it.
func (e *Env) DriveHealth() Drive {
	d := Drive{WearPercent: -1}
	if e.Mac() {
		if s, ok := e.Out("diskutil", "info", "-plist", "/"); ok {
			d = ParseDiskutil(s)
		}
	} else if s, ok := e.Out("lsblk", "-dno", "NAME,MODEL,TYPE"); ok {
		for _, l := range strings.Split(s, "\n") {
			f := strings.Fields(l)
			if len(f) >= 2 && f[len(f)-1] == "disk" && !strings.HasPrefix(f[0], "loop") {
				d.Device = "/dev/" + f[0]
				d.Model = strings.Join(f[1:len(f)-1], " ")
				break
			}
		}
	}
	if d.Device == "" {
		d.Note = "Could not tell which drive this system runs from."
		return d
	}
	if _, err := e.Look("smartctl"); err != nil {
		if e.Mac() {
			d.Note = "For wear and temperature: brew install smartmontools"
		} else {
			d.Note = "For wear and temperature: install smartmontools"
		}
		d.NoTool = true
		return d
	}
	r := e.Run.Run(15*time.Second, "smartctl", "-j", "-a", d.Device)
	if r.Stdout == "" || !ParseSmartctl(r.Stdout, &d) {
		d.Note = "Reading wear and temperature needs root: sudo smartctl -a " + d.Device
	}
	return d
}

// ParseSmartctl reads smartctl -j -a. It returns false when the output holds no readings, which is what no permission looks like.
func ParseSmartctl(text string, d *Drive) bool {
	var s struct {
		Model  string `json:"model_name"`
		Status *struct {
			Passed bool `json:"passed"`
		} `json:"smart_status"`
		Temp struct {
			Current int `json:"current"`
		} `json:"temperature"`
		Hours struct {
			Hours int `json:"hours"`
		} `json:"power_on_time"`
		NVMe *struct {
			Used        int   `json:"percentage_used"`
			Written     int64 `json:"data_units_written"`
			Read        int64 `json:"data_units_read"`
			Spare       int   `json:"available_spare"`
			SpareLimit  int   `json:"available_spare_threshold"`
			Unsafe      int64 `json:"unsafe_shutdowns"`
			Cycles      int64 `json:"power_cycles"`
			MediaErrors int64 `json:"media_errors"`
		} `json:"nvme_smart_health_information_log"`
	}
	if json.Unmarshal([]byte(text), &s) != nil || s.Status == nil {
		return false
	}
	if s.Model != "" {
		d.Model = s.Model
	}
	d.HasSmart = true
	d.OK = s.Status.Passed
	d.Status = fmt.Sprintf("%s", map[bool]string{true: "Passed", false: "Failed"}[s.Status.Passed])
	d.TemperatureC = s.Temp.Current
	d.PowerOnHours = s.Hours.Hours
	if s.NVMe != nil {
		d.WearPercent = s.NVMe.Used
		d.BytesWritten = s.NVMe.Written * 512000 // NVMe counts in units of 1000 sectors
		d.BytesRead = s.NVMe.Read * 512000
		d.Spare, d.SpareLimit = s.NVMe.Spare, s.NVMe.SpareLimit
		d.Unsafe, d.PowerCycles = s.NVMe.Unsafe, s.NVMe.Cycles
		d.MediaErrors = s.NVMe.MediaErrors
	}
	return true
}

var gatewayMac = regexp.MustCompile(`gateway:\s*(\S+)`)
var gatewayLinux = regexp.MustCompile(`default via (\S+)`)

// Gateway is the router's address, or "" when there is no route out.
func (e *Env) Gateway() string {
	if e.Mac() {
		s, _ := e.Out("route", "-n", "get", "default")
		if m := gatewayMac.FindStringSubmatch(s); m != nil {
			return m[1]
		}
		return ""
	}
	s, _ := e.Out("ip", "route", "show", "default")
	if m := gatewayLinux.FindStringSubmatch(s); m != nil {
		return m[1]
	}
	return ""
}
