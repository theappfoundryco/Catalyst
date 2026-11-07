// Command sprites prints Kit's pixels as JSON, so the README art is drawn from the same grids as the terminal.
package main

import (
	"encoding/json"
	"os"

	"github.com/theappfoundryco/catalyst/internal/kit"
)

func main() {
	pal := map[string]string{}
	for k, v := range kit.Palette {
		pal[string(k)] = v
	}
	json.NewEncoder(os.Stdout).Encode(map[string]any{"palette": pal, "moods": kit.Sprites})
}
