package sweep

import (
	"os"
	"path/filepath"
	"testing"
)

// Every newer rule, offered with its marker and git's word, and left alone without its marker.
func TestNewerRulesNeedTheirMarker(t *testing.T) {
	cases := []struct{ marker, dir, restore string }{
		{"Package.swift", ".build", "swift build"},
		{"mix.exs", "_build", "mix compile"},
		{"mix.exs", "deps", "mix deps.get"},
		{"stack.yaml", ".stack-work", "stack build"},
		{"my-lib.cabal", "dist-newstyle", "cabal build"},
		{"angular.json", ".angular", "rebuilds itself"},
		{"elm.json", "elm-stuff", "elm make"},
		{"nuxt.config.ts", ".output", "nuxt build"},
		{"docusaurus.config.js", ".docusaurus", "rebuilds itself"},
		{"CMakeLists.txt", "cmake-build-debug", "build again in CLion"},
		{"App.csproj", "bin", "dotnet build"},
		{"App.fsproj", "obj", "dotnet build"},
		{"composer.json", "vendor", "composer install"},
	}
	for _, c := range cases {
		f := newFixture(t)
		f.file("p/app/"+c.marker, "x")
		f.file("p/app/.gitignore", c.dir+"/\n")
		f.file("p/app/"+c.dir+"/out/a.bin", "x")
		f.git("p/app", "init", "-q")
		f.git("p/app", "add", ".")
		f.git("p/app", "commit", "-qm", "first")
		f.old("p/app")
		r := f.scan("p")
		if !has(r, "app/"+c.dir) || r.Items[0].Restore != c.restore {
			t.Errorf("%s with %s: %+v", c.dir, c.marker, r.Items)
		}

		g := newFixture(t)
		g.file("p/app/README.md", "x")
		g.file("p/app/.gitignore", c.dir+"/\n")
		g.file("p/app/"+c.dir+"/out/a.bin", "x")
		g.git("p/app", "init", "-q")
		g.git("p/app", "add", ".")
		g.git("p/app", "commit", "-qm", "first")
		g.old("p/app")
		if has(g.scan("p"), "app/"+c.dir) {
			t.Errorf("%s without %s was offered", c.dir, c.marker)
		}
	}
}

func TestGlobMarkersMatchOnlyBesideTheFolder(t *testing.T) {
	dir := t.TempDir()
	if _, ok := ruleFor(dir, "obj"); ok {
		t.Fatal("no project file")
	}
	os.MkdirAll(filepath.Join(dir, "src"), 0o755)
	os.WriteFile(filepath.Join(dir, "src", "Deep.csproj"), []byte("x"), 0o644)
	if _, ok := ruleFor(dir, "obj"); ok {
		t.Fatal("a project file deeper down is not beside the folder")
	}
	os.WriteFile(filepath.Join(dir, "App.csproj"), []byte("x"), 0o644)
	if r, ok := ruleFor(dir, "obj"); !ok || r.Title != ".NET build output" {
		t.Fatal("beside the folder")
	}
}
