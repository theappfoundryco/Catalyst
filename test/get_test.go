// Package test checks get.sh against a local server, so install problems are found without publishing a release.
package test

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func archive(t *testing.T, script string) []byte {
	t.Helper()
	var b bytes.Buffer
	gz := gzip.NewWriter(&b)
	w := tar.NewWriter(gz)
	w.WriteHeader(&tar.Header{Name: "catalyst", Mode: 0o755, Size: int64(len(script)), Typeflag: tar.TypeReg})
	w.Write([]byte(script))
	w.Close()
	gz.Close()
	return b.Bytes()
}

func serve(t *testing.T, data []byte, sums string) *httptest.Server {
	t.Helper()
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "SHA256SUMS"):
			fmt.Fprint(w, sums)
		case strings.HasSuffix(r.URL.Path, ".tar.gz"):
			w.Write(data)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

func run(t *testing.T, base, dir string) (string, error) {
	t.Helper()
	root, _ := filepath.Abs("..")
	cmd := exec.Command("sh", filepath.Join(root, "get.sh"))
	cmd.Env = []string{"HOME=" + filepath.Dir(dir), "PATH=" + dir + ":" + os.Getenv("PATH"), "CATALYST_BASE=" + base, "CATALYST_DIR=" + dir, "NO_COLOR=1"}
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func name() string {
	arch := runtime.GOARCH
	return fmt.Sprintf("catalyst_%s_%s.tar.gz", runtime.GOOS, arch)
}

func TestInstallsAndChecks(t *testing.T) {
	data := archive(t, "#!/bin/sh\necho catalyst 9.9.9\n")
	sum := fmt.Sprintf("%x  %s\n", sha256.Sum256(data), name())
	s := serve(t, data, sum)
	dir := filepath.Join(t.TempDir(), "bin")
	out, err := run(t, s.URL, dir)
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if !strings.Contains(out, "catalyst 9.9.9") || !strings.Contains(out, "Ready.") {
		t.Fatal(out)
	}
	st, err := os.Stat(filepath.Join(dir, "catalyst"))
	if err != nil || st.Mode().Perm() != 0o755 {
		t.Fatal(err, st)
	}
	if _, err := os.Stat(filepath.Join(dir, "catalyst.new")); err == nil {
		t.Fatal("left a temporary file behind")
	}
}

func TestRefusesABadChecksum(t *testing.T) {
	data := archive(t, "#!/bin/sh\necho hacked\n")
	s := serve(t, data, strings.Repeat("0", 64)+"  "+name()+"\n")
	dir := filepath.Join(t.TempDir(), "bin")
	out, err := run(t, s.URL, dir)
	if err == nil || !strings.Contains(out, "does not match") {
		t.Fatalf("%v\n%s", err, out)
	}
	if _, err := os.Stat(filepath.Join(dir, "catalyst")); err == nil {
		t.Fatal("installed it anyway")
	}
}

func TestRefusesAMissingChecksum(t *testing.T) {
	data := archive(t, "#!/bin/sh\n")
	s := serve(t, data, "abc  some_other_file.tar.gz\n")
	out, err := run(t, s.URL, filepath.Join(t.TempDir(), "bin"))
	if err == nil || !strings.Contains(out, "no checksum") {
		t.Fatalf("%v\n%s", err, out)
	}
}

func TestADownloadFailureIsPlain(t *testing.T) {
	s := httptest.NewServer(http.NotFoundHandler())
	defer s.Close()
	out, err := run(t, s.URL, filepath.Join(t.TempDir(), "bin"))
	if err == nil || !strings.Contains(out, "Could not download") {
		t.Fatalf("%v\n%s", err, out)
	}
}
