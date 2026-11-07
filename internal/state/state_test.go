package state

import (
	"testing"
	"time"
)

func TestOnePerDay(t *testing.T) {
	s := New(t.TempDir(), nil)
	d := time.Date(2026, 3, 1, 9, 0, 0, 0, time.Local)
	s.Record(Health{Date: d, Score: 50})
	s.Record(Health{Date: d.Add(time.Hour), Score: 80})
	if h := s.History(); len(h) != 1 || h[0].Score != 80 {
		t.Fatalf("%+v", h)
	}
	if _, _, ok := Trend(s.History()); ok {
		t.Fatal("one day has no trend")
	}
	s.Record(Health{Date: d.Add(48 * time.Hour), Score: 90})
	change, since, ok := Trend(s.History())
	if !ok || change != 10 || !since.Equal(d.Add(time.Hour)) {
		t.Fatal(change, since, ok)
	}
}

func TestKeepsNinetyDays(t *testing.T) {
	s := New(t.TempDir(), nil)
	d := time.Date(2026, 1, 1, 9, 0, 0, 0, time.Local)
	for i := 0; i < 120; i++ {
		s.Record(Health{Date: d.AddDate(0, 0, i), Score: i})
	}
	h := s.History()
	if len(h) != 90 || h[89].Score != 119 {
		t.Fatal(len(h))
	}
}

func TestConfigDefaultsToKitOn(t *testing.T) {
	s := New(t.TempDir(), nil)
	if !s.LoadConfig().MascotOn() {
		t.Fatal("on by default")
	}
	off := false
	if err := s.SaveConfig(Config{Mascot: &off}); err != nil {
		t.Fatal(err)
	}
	if s.LoadConfig().MascotOn() {
		t.Fatal("should be off")
	}
}

func TestXDGFolders(t *testing.T) {
	s := New("/home/alex", func(k string) string {
		if k == "XDG_STATE_HOME" {
			return "/x/state"
		}
		return ""
	})
	if s.Dir != "/x/state/catalyst" || s.ConfigDir != "/home/alex/.config/catalyst" {
		t.Fatalf("%+v", s)
	}
}
