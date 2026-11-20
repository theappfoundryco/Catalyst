package checks

import (
	"net"
	"net/url"
	"os"
	"strings"
	"time"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "tools.network", Group: d.GroupTools, Name: "Checking proxy and certificate settings", Run: networkEnv})
}

// caVars are the variables that point a tool at extra certificates, and the tools that read each.
var caVars = []struct{ name, who string }{
	{"NODE_EXTRA_CA_CERTS", "node and npm"}, {"SSL_CERT_FILE", "curl, git, Python and Ruby"}, {"SSL_CERT_DIR", "OpenSSL"},
	{"REQUESTS_CA_BUNDLE", "pip and Python's requests"}, {"CURL_CA_BUNDLE", "curl"}, {"GIT_SSL_CAINFO", "git"},
	{"PIP_CERT", "pip"}, {"AWS_CA_BUNDLE", "the AWS CLI"}, {"NPM_CONFIG_CAFILE", "npm"}, {"npm_config_cafile", "npm"},
}

var proxyVars = []string{"HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"}

// dialLocal is how a local proxy is tried. It only ever connects to this machine, and sends nothing.
var dialLocal = func(addr string) bool {
	c, err := net.DialTimeout("tcp", addr, 400*time.Millisecond)
	if err != nil {
		return false
	}
	c.Close()
	return true
}

// A certificate variable left behind by an old job or VPN, or a proxy that only ran while a tool was open, breaks every
// install with an error about TLS or the network, never about the variable. Only what is certain is reported: a path
// that does not exist, and a proxy on this machine with nothing listening. A remote proxy is never contacted.
func networkEnv(e *host.Env) []d.Result {
	var out []d.Result
	set := 0
	for _, v := range caVars {
		p := e.Var(v.name)
		if p == "" {
			continue
		}
		set++
		st, err := os.Stat(p)
		switch {
		case err != nil:
			out = append(out, d.Warn(v.name+" points at "+e.Tilde(p)+", which does not exist").
				With("So "+v.who+" fail with certificate errors. Remove the line that sets it, or point it at the right file. See where: catalyst path"))
		case v.name == "SSL_CERT_DIR" && !st.IsDir():
			out = append(out, d.Warn("SSL_CERT_DIR points at a file, not a folder").With("OpenSSL expects a folder of certificates here."))
		case v.name != "SSL_CERT_DIR" && st.IsDir():
			out = append(out, d.Warn(v.name+" points at a folder, not a certificate file").With(v.who+" expect one file of certificates here."))
		}
	}
	seen := map[string]bool{}
	for _, name := range proxyVars {
		raw := e.Var(name)
		if raw == "" {
			continue
		}
		set++
		addr, ok := LocalProxy(raw)
		if !ok || seen[addr] {
			continue
		}
		seen[addr] = true
		if !dialLocal(addr) {
			out = append(out, d.Warn(name+" sends traffic to "+addr+" on this machine, where nothing is listening").
				With("Downloads and installs will fail to connect. Start the proxy, or remove the line that sets "+name+"."))
		}
	}
	if len(out) > 0 {
		return out
	}
	if set == 0 {
		return []d.Result{d.Skip("No proxy or certificate variables are set")}
	}
	return []d.Result{d.Pass("Proxy and certificate settings point at real places")}
}

// LocalProxy returns host:port when a proxy setting points at this machine. Remote proxies return false, because
// trying one would be a network call nobody asked for.
func LocalProxy(raw string) (string, bool) {
	if !strings.Contains(raw, "://") {
		raw = "http://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" {
		return "", false
	}
	h := u.Hostname()
	if h != "localhost" && h != "127.0.0.1" && h != "::1" {
		return "", false
	}
	port := u.Port()
	if port == "" {
		port = map[string]string{"https": "443", "socks5": "1080", "socks5h": "1080", "socks": "1080"}[u.Scheme]
		if port == "" {
			port = "80"
		}
	}
	return net.JoinHostPort(h, port), true
}
