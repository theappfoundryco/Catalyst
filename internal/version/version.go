// Package version holds the release number, set at build time.
package version

// Version is replaced by the release build (-ldflags -X). A plain go build says "dev".
var Version = "0.1.0-dev"

// Repo is the GitHub repository releases come from.
const Repo = "theappfoundryco/catalyst"
