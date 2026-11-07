package space

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/run"
)

// Trimmed from a real Mac, with the volume names changed. The second container is an external disk.
const apfsList = `
+-- Container disk3 11111111-0000-0000-0000-000000000000
    |   +-> Volume disk3s1 A
    |   |   APFS Volume Disk (Role):   disk3s1 (Data)
    |   |   Capacity Consumed:         139389263872 B (139.4 GB)
    |   +-> Volume disk3s3 B
    |   |   APFS Volume Disk (Role):   disk3s3 (System)
    |   |   Capacity Consumed:         11258822656 B (11.3 GB)
    |   +-> Volume disk3s4 C
    |   |   APFS Volume Disk (Role):   disk3s4 (Preboot)
    |   |   Capacity Consumed:         7422033920 B (7.4 GB)
    |   +-> Volume disk3s5 D
    |   |   APFS Volume Disk (Role):   disk3s5 (Recovery)
    |   |   Capacity Consumed:         1048952832 B (1.0 GB)
    |   +-> Volume disk3s6 E
    |   |   APFS Volume Disk (Role):   disk3s6 (VM)
    |   |   Capacity Consumed:         7516213248 B (7.5 GB)
+-- Container disk5 22222222-0000-0000-0000-000000000000
    |   +-> Volume disk5s2 F
    |   |   APFS Volume Disk (Role):   disk5s2 (System)
    |   |   Capacity Consumed:         99999999999 B (100 GB)
`

func TestParseAPFSCountsOnlyThisMacsOwnVolumes(t *testing.T) {
	s := ParseAPFS(apfsList, "/dev/disk3s1")
	if s.Sealed != 11258822656 || s.Boot != 7422033920 || s.Recovery != 1048952832 || s.Swap != 7516213248 {
		t.Fatalf("%+v", s)
	}
	if s.Total() != 27246022656 {
		t.Fatal(s.Total())
	}
}

func TestMeasureFindsLandmarksAndCountsHardLinksOnce(t *testing.T) {
	home := t.TempDir()
	write := func(rel string, n int) string {
		p := filepath.Join(home, rel)
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, make([]byte, n), 0o644)
		return p
	}
	write(".cache/huggingface/hub/model.bin", 3<<20)
	a := write("Projects/a/blob", 2<<20)
	os.Link(a, filepath.Join(home, "Projects/a/same-blob"))
	write("Downloads/x", 1<<20)
	write(".cache/pip/wheel", 2<<20)
	e := host.ForTest(home, "linux", &run.Fake{})
	r := Measure(Options{Env: e, Floor: 2 << 20})
	// ~/.cache holds 5 MB, 3 of them the models: it shows only the other 2, so nothing is counted twice.
	if len(r.Landmarks) != 2 || r.Landmarks[0].Name != "Hugging Face models" || r.Landmarks[0].How == "" {
		t.Fatalf("%+v", r.Landmarks)
	}
	if c := r.Landmarks[1]; c.Name != "Tool caches" || c.Bytes >= 3<<20 {
		t.Fatalf("%+v", c)
	}
	var projects int64
	for _, h := range r.Home {
		if h.Name == "Projects" {
			projects = h.Bytes
		}
	}
	if projects < 2<<20 || projects >= 4<<20 {
		t.Fatalf("Projects measured %d: a hard link was counted twice, or the file not at all", projects)
	}
}

func TestUnreadableFoldersAreCountedNotGuessed(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root reads everything")
	}
	home := t.TempDir()
	locked := filepath.Join(home, "Private", "inner")
	os.MkdirAll(locked, 0o755)
	os.Chmod(filepath.Dir(locked), 0o000)
	defer os.Chmod(filepath.Dir(locked), 0o755)
	r := Measure(Options{Env: host.ForTest(home, "linux", &run.Fake{})})
	if r.Unreadable != 1 {
		t.Fatal(r.Unreadable)
	}
}
