package host

import (
	"strings"
	"testing"
	"time"
)

// Recorded from a MacBook Pro, with its serial number taken out.
const ioregBattery = `
      "AppleRawCurrentCapacity" = 3989
      "NominalChargeCapacity" = 4305
      "FullyCharged" = Yes
      "DesignCycleCount9C" = 1000
      "AdapterDetails" = {"IsWireless"=No,"AdapterID"=0,"AdapterVoltage"=20000,"Watts"=63,"UsbHvcIndex"=3}
      "InstantAmperage" = 0
      "Temperature" = 3073
      "DesignCapacity" = 5103
      "Voltage" = 12574
      "Amperage" = 18446744073709550616
      "CycleCount" = 532
      "AppleRawMaxCapacity" = 4172
      "BatteryData" = {"CellVoltage"=(4192,4191,4191),"Qstart"=0}
`

func TestBatteryDetailsFromIoreg(t *testing.T) {
	c := ParseCells(ioregBattery)
	if c.DesignMAh != 5103 || c.FullMAh != 4172 || c.RatedCycle != 1000 || c.AdapterW != 63 || !c.FullyFull {
		t.Fatalf("%+v", c)
	}
	if len(c.CellVolts) != 3 || c.CellVolts[0] != 4.192 {
		t.Fatalf("cells %v", c.CellVolts)
	}
	// InstantAmperage is 0, so Amperage counts: a huge unsigned number is a current going out, 1 A here.
	if c.Watts > -12 || c.Watts < -13 {
		t.Fatalf("watts %.2f, want about -12.6", c.Watts)
	}
}

func TestUptimeFromBoottime(t *testing.T) {
	now := time.Unix(1791883967+3*86400, 0)
	d, ok := ParseBoottime("{ sec = 1791883967, usec = 208811 } Tue Oct 13 15:02:47 2026", now)
	if !ok || d != 72*time.Hour {
		t.Fatal(d, ok)
	}
}

func TestMemoryPressureOnLinux(t *testing.T) {
	for in, want := range map[string]string{
		"some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00": "normal",
		"some avg10=12.50 avg60=3.00":                                     "warning",
		"some avg10=44.10 avg60=30.00":                                    "critical",
	} {
		if got, ok := ParsePSI(in); !ok || got != want {
			t.Errorf("%q: %q", in, got)
		}
	}
}

func TestThermal(t *testing.T) {
	if got := ParseTherm("Note: No thermal warning level has been recorded\nNote: No performance warning level has been recorded"); got != "normal" {
		t.Fatal(got)
	}
	if got := ParseTherm("CPU_Scheduler_Limit \t= 100\nCPU_Available_CPUs \t= 8\nCPU_Speed_Limit \t= 70"); !strings.Contains(got, "70%") {
		t.Fatal(got)
	}
}

func TestBusiestCountsHelpersWithTheirApp(t *testing.T) {
	ps := `  1.0 204800 Slack
  5.0 102400 Slack Helper (Renderer)
 30.0  10240 node
  0.1 512000 Xcode`
	top := ParsePS(ps, 2, false)
	if len(top) != 2 || top[0].Name != "node" || top[1].Name != "Slack" || top[1].CPU != 6 {
		t.Fatalf("%+v", top)
	}
	mem := ParsePS(ps, 1, true)
	if mem[0].Name != "Xcode" {
		t.Fatalf("%+v", mem)
	}
}

func TestWiFiFromSystemProfiler(t *testing.T) {
	js := `{"SPAirPortDataType":[{"spairport_airport_interfaces":[{"_name":"en0","spairport_current_network_information":{"_name":"<redacted>","spairport_network_channel":"52 (5GHz, 80MHz)","spairport_network_phymode":"802.11ac","spairport_network_rate":390,"spairport_signal_noise":"-64 dBm / -90 dBm"}},{"_name":"awdl0","spairport_current_network_information":{"spairport_network_type":"spairport_network_type_station"}}]}]}`
	w, ok := ParseAirport(js)
	if !ok || w.Name != "" || w.Signal != -64 || w.Noise != -90 || w.RateMb != 390 || !strings.HasPrefix(w.Channel, "52") {
		t.Fatalf("%+v %v", w, ok)
	}
}

func TestNameserversAndProxy(t *testing.T) {
	got := ParseNameservers("resolver #1\n  nameserver[0] : 10.0.0.5\n  nameserver[1] : 10.0.0.5\nresolver #2\n  nameserver[0] : 192.168.1.20\n")
	if strings.Join(got, ",") != "10.0.0.5,192.168.1.20" {
		t.Fatal(got)
	}
	if got := ParseNameservers("# comment\nnameserver 10.0.0.5\n"); len(got) != 1 {
		t.Fatal(got)
	}
	if p := ParseProxy("<dictionary> {\n  HTTPEnable : 0\n  HTTPSEnable : 1\n  HTTPSPort : 8080\n  HTTPSProxy : proxy.example.com\n}"); p != "proxy.example.com:8080" {
		t.Fatal(p)
	}
	if p := ParseProxy("<dictionary> {\n  HTTPEnable : 0\n}"); p != "" {
		t.Fatal(p)
	}
}

func TestSmartctlReadsLifetimeFigures(t *testing.T) {
	js := `{"model_name":"APPLE SSD AP0256Q","smart_status":{"passed":true},"temperature":{"current":31},"power_on_time":{"hours":4410},
"nvme_smart_health_information_log":{"percentage_used":3,"data_units_written":60000000,"data_units_read":80000000,"available_spare":100,"available_spare_threshold":99,"unsafe_shutdowns":12,"power_cycles":300,"media_errors":0}}`
	d := Drive{}
	if !ParseSmartctl(js, &d) {
		t.Fatal("no readings")
	}
	if d.BytesRead != 80000000*512000 || d.Spare != 100 || d.SpareLimit != 99 || d.Unsafe != 12 || d.PowerCycles != 300 || d.WearPercent != 3 {
		t.Fatalf("%+v", d)
	}
}
