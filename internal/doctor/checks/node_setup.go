package checks

import (
	"os"
	"strings"
	"syscall"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "tools.node", Group: d.GroupTools, Name: "Checking Node", Run: nodeSetup})
}

func nodeSetup(e *host.Env) []d.Result {
	npm, err := e.Look("npm")
	if err != nil {
		return []d.Result{d.Skip("Node is not installed")}
	}
	var out []d.Result
	nvm := e.NvmDir != "" || host.Exists(e.Path(".nvm"))
	if nvm && (strings.HasPrefix(npm, "/opt/homebrew/") || strings.HasPrefix(npm, "/usr/local/") || strings.HasPrefix(npm, "/usr/bin/")) {
		out = append(out, d.Warn("npm resolves to "+npm+" but nvm is installed").With("Your nvm versions are being ignored. Remove the other Node, or make sure nvm loads last."))
	}
	if root, ok := e.Out(npm, "root", "-g"); ok && root != "" {
		if st, err := os.Stat(root); err == nil {
			if sys, ok := st.Sys().(*syscall.Stat_t); ok && sys.Uid == 0 && os.Getuid() != 0 {
				out = append(out, d.Warn("npm's global folder belongs to root").With("Global installs will fail or tempt you into sudo. A version manager like nvm or fnm avoids this."))
			}
		}
	}
	if len(out) == 0 {
		return []d.Result{d.Pass("Node and npm are set up cleanly")}
	}
	return out
}
