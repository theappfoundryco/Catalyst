package checks

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/run"
)

func TestTLSPythonOrgWithoutCertificates(t *testing.T) {
	root := t.TempDir()
	old := pythonOrg
	pythonOrg = root
	defer func() { pythonOrg = old }()
	for _, v := range []string{"3.12", "3.11"} {
		write(t, filepath.Join(root, v, "bin", "python3"), "", 0o755)
	}
	os.MkdirAll(filepath.Join(root, "3.11", "etc", "openssl"), 0o755)
	write(t, filepath.Join(root, "3.11", "etc", "openssl", "cert.pem"), "certs\n", 0o644)
	e, _ := env(t, "darwin", map[string]string{"python3": filepath.Join(root, "3.12", "bin", "python3")}, nil)
	r := one(t, tlsTrust(e))
	if r.Severity != d.Warning || !strings.Contains(r.Title, "Python 3.12") || !strings.Contains(r.Hint, `open "/Applications/Python 3.12/Install Certificates.command"`) {
		t.Fatalf("%+v", r)
	}
	write(t, filepath.Join(root, "3.12", "etc", "openssl", "cert.pem"), "certs\n", 0o644)
	if r := one(t, tlsTrust(e)); r.State != d.Passed {
		t.Fatalf("%+v", r)
	}
}

func TestTLSToolSettingsThatPointNowhere(t *testing.T) {
	e, _ := env(t, "linux", map[string]string{"git": "/usr/bin/git"}, map[string]run.Result{
		"/usr/bin/git config --global --get http.sslCAInfo": {Stdout: "~/certs/corp.pem\n"},
		"/usr/bin/git config --global --get http.sslCAPath": {Code: 1},
	})
	write(t, e.Path(".npmrc"), "registry=https://registry.example.com/\ncafile=/etc/ssl/gone.pem\nstrict-ssl=false\n", 0o644)
	write(t, e.Path(".config", "pip", "pip.conf"), "[global]\ncert = $HOME/certs/corp.pem\n", 0o644)
	var got []string
	for _, r := range tlsTrust(e) {
		got = append(got, string(r.Severity)+" "+r.Title)
	}
	want := []string{
		"warning git's http.sslCAInfo points at ~/certs/corp.pem, which does not exist",
		"warning npm's cafile points at /etc/ssl/gone.pem, which does not exist",
		"info npm does not check certificates (strict-ssl=false in ~/.npmrc)",
		"warning pip's cert setting points at ~/certs/corp.pem, which does not exist",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("%s", strings.Join(got, "\n"))
	}
	write(t, e.Path("certs", "corp.pem"), "certs\n", 0o644)
	write(t, e.Path(".npmrc"), "cafile=~/certs/corp.pem\n", 0o644)
	if r := one(t, tlsTrust(e)); r.State != d.Passed {
		t.Fatalf("%+v", r)
	}
}
