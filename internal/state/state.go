// Package state keeps Catalyst's small local files: settings, health history and the journal of everything it changed.
// All of it stays on this machine, under the standard XDG folders.
package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// Store is rooted at a home folder, so tests can use a temporary one.
type Store struct {
	Dir       string // ~/.local/state/catalyst
	ConfigDir string // ~/.config/catalyst
}

// New picks the folders from the XDG variables, or their usual defaults.
func New(home string, getenv func(string) string) *Store {
	st := filepath.Join(home, ".local", "state")
	cf := filepath.Join(home, ".config")
	if getenv != nil {
		if v := getenv("XDG_STATE_HOME"); v != "" {
			st = v
		}
		if v := getenv("XDG_CONFIG_HOME"); v != "" {
			cf = v
		}
	}
	return &Store{Dir: filepath.Join(st, "catalyst"), ConfigDir: filepath.Join(cf, "catalyst")}
}

// Config is what `catalyst config` changes.
type Config struct {
	Mascot    *bool    `json:"mascot,omitempty"`
	Motion    *bool    `json:"animations,omitempty"`
	Name      *string  `json:"name,omitempty"`             // what to call the person; set but empty means they chose not to say
	NoHelpers []string `json:"declined_helpers,omitempty"` // helper tools the person said no to, so setup stops offering them
	SetupDone bool     `json:"setup_done,omitempty"`
}

// MascotOn says whether Kit may appear. On unless turned off.
func (c Config) MascotOn() bool { return c.Mascot == nil || *c.Mascot }

// MotionOn says whether things on screen may move: Kit's wag and the health dot's pulse. On unless turned off.
func (c Config) MotionOn() bool { return c.Motion == nil || *c.Motion }

// Nickname is what to call the person, or "".
func (c Config) Nickname() string {
	if c.Name == nil {
		return ""
	}
	return *c.Name
}

// Declined says whether the person said no to a helper tool.
func (c Config) Declined(tool string) bool {
	for _, t := range c.NoHelpers {
		if t == tool {
			return true
		}
	}
	return false
}

// LoadConfig reads the settings. A missing or damaged file means defaults: settings must never stop a diagnosis.
func (s *Store) LoadConfig() Config {
	var c Config
	if b, err := os.ReadFile(filepath.Join(s.ConfigDir, "config.json")); err == nil {
		_ = json.Unmarshal(b, &c)
	}
	return c
}

// SaveConfig writes the settings.
func (s *Store) SaveConfig(c Config) error {
	if err := os.MkdirAll(s.ConfigDir, 0o755); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(c, "", "  ")
	return writeAtomic(filepath.Join(s.ConfigDir, "config.json"), append(b, '\n'))
}

func writeAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Health is one day's doctor result.
type Health struct {
	Date     time.Time `json:"date"`
	Score    int       `json:"score"`
	Issues   int       `json:"issues"`
	Critical int       `json:"critical"`
}

const keepDays = 90

// History returns saved results, oldest first.
func (s *Store) History() []Health {
	var h []Health
	if b, err := os.ReadFile(filepath.Join(s.Dir, "health.json")); err == nil {
		_ = json.Unmarshal(b, &h)
	}
	return h
}

// Record saves a result, one per calendar day so re-running after a fix does not flood the trend.
func (s *Store) Record(r Health) error {
	if err := os.MkdirAll(s.Dir, 0o755); err != nil {
		return err
	}
	h := s.History()
	if n := len(h); n > 0 && sameDay(h[n-1].Date, r.Date) {
		h[n-1] = r
	} else {
		h = append(h, r)
	}
	if len(h) > keepDays {
		h = h[len(h)-keepDays:]
	}
	b, _ := json.Marshal(h)
	return writeAtomic(filepath.Join(s.Dir, "health.json"), b)
}

func sameDay(a, b time.Time) bool {
	ay, am, ad := a.Local().Date()
	by, bm, bd := b.Local().Date()
	return ay == by && am == bm && ad == bd
}

// Trend compares the newest result with the one from the last different day. ok is false with only one day saved.
func Trend(h []Health) (change int, since time.Time, ok bool) {
	if len(h) < 2 {
		return 0, time.Time{}, false
	}
	return h[len(h)-1].Score - h[len(h)-2].Score, h[len(h)-2].Date, true
}

// Sweep is the size last found to reclaim.
type Sweep struct {
	Date  time.Time `json:"date"`
	Bytes int64     `json:"bytes"`
	Count int       `json:"count"`
}

// LastSweep reads it.
func (s *Store) LastSweep() (Sweep, bool) {
	var v Sweep
	b, err := os.ReadFile(filepath.Join(s.Dir, "sweep.json"))
	if err != nil || json.Unmarshal(b, &v) != nil {
		return v, false
	}
	return v, true
}

// SaveSweep writes it.
func (s *Store) SaveSweep(v Sweep) error {
	if err := os.MkdirAll(s.Dir, 0o755); err != nil {
		return err
	}
	b, _ := json.Marshal(v)
	return writeAtomic(filepath.Join(s.Dir, "sweep.json"), b)
}
