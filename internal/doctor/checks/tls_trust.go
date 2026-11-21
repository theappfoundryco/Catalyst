package checks

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "tools.tls", Group: d.GroupTools, Name: "Checking which certificates your tools trust", Run: tlsTrust})
}

// pythonOrg is where the python.org installer puts each version. A variable, so tests can point it elsewhere.
var pythonOrg = "/Library/Frameworks/Python.framework/Versions"

// "CERTIFICATE_VERIFY_FAILED" and "unable to get local issuer certificate" are among the most quoted errors on GitHub,
// and the setting behind them is rarely where people look. tools.network covers the variables. This covers what a
// tool's own config points at, and python.org's Python on a Mac, which ships with no certificates at all until its
// Install Certificates step has run. Only files on this machine are read: nothing is connected to.
func tlsTrust(e *host.Env) []d.Result {
	var out []d.Result
	looked := 0
	if e.Mac() {
		r, n := pythonOrgCerts(e)
		out, looked = append(out, r...), looked+n
	}
	if git, ok := e.SafeTool("git"); ok {
		looked++
		for _, k := range []string{"http.sslCAInfo", "http.sslCAPath"} {
			v, _ := e.Out(git, "config", "--global", "--get", k)
			if p := expandHome(e, strings.TrimSpace(v)); p != "" && !host.Exists(p) {
				out = append(out, d.Warn("git's "+k+" points at "+e.Tilde(p)+", which does not exist").
					With("So every git clone and fetch over HTTPS fails with a certificate error. Point it at the right file, or remove it:\ngit config --global --unset "+k))
			}
		}
	}
	if kv, ok := iniValues(e.Path(".npmrc")); ok {
		looked++
		if p := expandHome(e, kv["cafile"]); p != "" && !host.Exists(p) {
			out = append(out, d.Warn("npm's cafile points at "+e.Tilde(p)+", which does not exist").
				With("So npm install fails with a certificate error. Fix or remove the cafile line in ~/.npmrc."))
		}
		if strings.EqualFold(kv["strict-ssl"], "false") {
			out = append(out, d.Note("npm does not check certificates (strict-ssl=false in ~/.npmrc)").
				With("Often left behind by a proxy workaround. Anyone between you and the registry could change what you install. Remove the line once it is no longer needed."))
		}
	}
	for _, conf := range []string{e.Path(".config", "pip", "pip.conf"), e.Path(".pip", "pip.conf"), e.Path("Library", "Application Support", "pip", "pip.conf")} {
		kv, ok := iniValues(conf)
		if !ok {
			continue
		}
		looked++
		if p := expandHome(e, kv["cert"]); p != "" && !host.Exists(p) {
			out = append(out, d.Warn("pip's cert setting points at "+e.Tilde(p)+", which does not exist").
				With("So pip install fails with a certificate error. Fix or remove the cert line in "+e.Tilde(conf)+"."))
		}
	}
	if len(out) > 0 {
		return out
	}
	if looked == 0 {
		return []d.Result{d.Skip("No tool here has its own certificate settings")}
	}
	return []d.Result{d.Pass("Your tools' certificate settings point at real files")}
}

// pythonOrgCerts finds python.org versions whose certificate file was never put in place. The one python3 runs is a
// warning, since every HTTPS request from it fails. Other versions are only a note.
func pythonOrgCerts(e *host.Env) (out []d.Result, looked int) {
	versions, _ := os.ReadDir(pythonOrg)
	active := ""
	if p, err := e.Look("python3"); err == nil {
		if real, err := filepath.EvalSymlinks(p); err == nil && strings.HasPrefix(real, pythonOrg+"/") {
			active = strings.SplitN(strings.TrimPrefix(real, pythonOrg+"/"), "/", 2)[0]
		}
	}
	for _, v := range versions {
		dir := filepath.Join(pythonOrg, v.Name())
		if v.Name() == "Current" || !host.Exists(filepath.Join(dir, "bin", "python3")) {
			continue
		}
		looked++
		if _, err := os.Stat(filepath.Join(dir, "etc", "openssl", "cert.pem")); err == nil {
			continue // Install Certificates links certifi's file here, and a link to nothing fails Stat too
		}
		fix := `open "/Applications/Python ` + v.Name() + `/Install Certificates.command"`
		if v.Name() == active {
			out = append(out, d.Warn("Python "+v.Name()+" from python.org has no certificates, so HTTPS from Python fails").
				With("Its requests fail with CERTIFICATE_VERIFY_FAILED. The installer leaves one step for you. Run it:\n"+fix))
		} else {
			out = append(out, d.Note("Python "+v.Name()+" from python.org has no certificates yet").
				With("HTTPS from it will fail until you run:\n"+fix))
		}
	}
	return out, looked
}

// iniValues reads key = value lines from a simple config file, such as ~/.npmrc or pip.conf. Sections are ignored, since
// the keys looked for here are only ever global ones.
func iniValues(path string) (map[string]string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return nil, false
	}
	defer f.Close()
	kv := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || line[0] == '#' || line[0] == ';' || line[0] == '[' {
			continue
		}
		if k, v, ok := strings.Cut(line, "="); ok {
			kv[strings.ToLower(strings.TrimSpace(k))] = strings.Trim(strings.TrimSpace(v), `"'`)
		}
	}
	return kv, true
}

// expandHome turns ~ and $HOME into the home folder, the way the tools themselves read their settings.
func expandHome(e *host.Env, p string) string {
	switch {
	case p == "":
		return ""
	case strings.HasPrefix(p, "~/"):
		return e.Path(p[2:])
	case strings.HasPrefix(p, "$HOME/"):
		return e.Path(p[6:])
	case strings.HasPrefix(p, "${HOME}/"):
		return e.Path(p[8:])
	}
	return p
}
