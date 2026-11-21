package checks

import (
	"os"
	"strings"
	"testing"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
)

func TestLocalProxy(t *testing.T) {
	cases := map[string]string{
		"http://127.0.0.1:8080":         "127.0.0.1:8080",
		"localhost:3128":                "localhost:3128",
		"socks5h://localhost":           "localhost:1080",
		"http://user:pw@[::1]:9000/":    "[::1]:9000",
		"http://proxy.example.com:8080": "",
		"http://10.0.0.5:3128":          "",
		"":                              "",
	}
	for in, want := range cases {
		got, ok := LocalProxy(in)
		if ok != (want != "") || got != want {
			t.Errorf("%q: %q %v", in, got, ok)
		}
	}
}

func TestNetworkEnv(t *testing.T) {
	e, _ := env(t, "linux", nil, nil)
	defer func(f func(string) bool) { dialLocal = f }(dialLocal)
	dialed := []string{}
	dialLocal = func(a string) bool { dialed = append(dialed, a); return a == "127.0.0.1:9999" }

	e.Vars = map[string]string{}
	if r := one(t, networkEnv(e)); r.State != d.Skipped {
		t.Fatalf("%+v", r)
	}
	ca := e.Path("corp.pem")
	write(t, ca, "-----BEGIN CERTIFICATE-----\n", 0o644)
	os.MkdirAll(e.Path("certs"), 0o755)
	e.Vars = map[string]string{"NODE_EXTRA_CA_CERTS": ca, "SSL_CERT_DIR": e.Path("certs"), "HTTPS_PROXY": "http://127.0.0.1:9999", "http_proxy": "http://proxy.example.com:8080"}
	if r := one(t, networkEnv(e)); r.State != d.Passed {
		t.Fatalf("%+v", r)
	}
	if len(dialed) != 1 {
		t.Fatalf("a remote proxy must never be contacted: %v", dialed)
	}
	e.Vars = map[string]string{"REQUESTS_CA_BUNDLE": e.Path("gone.pem"), "HTTPS_PROXY": "localhost:8888", "HTTP_PROXY": "localhost:8888", "GIT_SSL_CAINFO": e.Path("certs")}
	rs := networkEnv(e)
	if len(rs) != 3 {
		t.Fatalf("one per problem, the same proxy once: %+v", rs)
	}
	for _, r := range rs {
		if r.Severity != d.Warning || strings.Contains(r.Title, e.Home) {
			t.Errorf("%+v", r)
		}
	}
}

func TestWhereSet(t *testing.T) {
	e, _ := env(t, "linux", nil, nil)
	write(t, e.Path(".bashrc"), "# export NODE_EXTRA_CA_CERTS=/old.pem\nalias x=y\nexport NODE_EXTRA_CA_CERTS=/etc/ssl/missing.pem\n", 0o644)
	write(t, e.Path(".config", "fish", "config.fish"), "set -gx PIP_CERT /x.pem\n", 0o644)
	if got := WhereSet(e, "NODE_EXTRA_CA_CERTS"); got != "It is set in ~/.bashrc, line 3." {
		t.Errorf("got %q", got)
	}
	if got := WhereSet(e, "PIP_CERT"); got != "It is set in ~/.config/fish/config.fish, line 1." {
		t.Errorf("got %q", got)
	}
	if got := WhereSet(e, "SSL_CERT_FILE"); !strings.Contains(got, "/etc/environment") {
		t.Errorf("got %q", got)
	}
}
