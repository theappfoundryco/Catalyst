// Command catalyst is the doctor for your dev environment.
package main

import (
	"os"

	"github.com/theappfoundryco/catalyst/internal/cli"
	_ "github.com/theappfoundryco/catalyst/internal/doctor/checks"
)

func main() { os.Exit(cli.Main(os.Args[1:])) }
