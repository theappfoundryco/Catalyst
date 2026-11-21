package checks

import (
	"bufio"
	"os"
	"sort"
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "keys.sshhosts", Group: d.GroupKeys, Name: "Checking SSH to GitHub, GitLab and Bitbucket", Run: sshGitHosts})
}

// gitHosts are the hosting services whose SSH failures people quote most.
var gitHosts = map[string]string{"github.com": "GitHub", "gitlab.com": "GitLab", "bitbucket.org": "Bitbucket", "ssh.dev.azure.com": "Azure DevOps", "codeberg.org": "Codeberg"}

// GitHub replaced its RSA host key in March 2023, after the old one was exposed. A known_hosts that still holds it
// fails every connection with "Host key verification failed", and the warning ssh prints looks like an attack.
const githubOldRSA = "SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8"

// "Permission denied (publickey)" and "Host key verification failed" are quoted in thousands of issues, and both can be
// seen coming without connecting anywhere: ssh -G says which keys would be offered, ssh-add -l what the agent holds,
// and ssh-keygen -F what known_hosts says. Only hosts this person has set up for SSH are judged. A known_hosts line on
// its own is left alone: one ssh -T long ago leaves it, and someone who clones over HTTPS should hear nothing.
func sshGitHosts(e *host.Env) []d.Result {
	ssh, err := e.Look("ssh")
	if err != nil {
		return []d.Result{d.Skip("ssh is not installed")}
	}
	keygen, _ := e.Look("ssh-keygen")
	known := e.Path(".ssh", "known_hosts")
	inKnown := func(h string) bool {
		return keygen != "" && host.Exists(known) && e.Run.Run(0, keygen, "-F", h, "-f", known).OK()
	}
	targets := sshConfigAliases(e.Path(".ssh", "config"))
	configured := map[string]bool{}
	for a := range targets {
		configured[a] = true
	}
	for h := range gitHosts {
		if _, ok := targets[h]; !ok && inKnown(h) {
			targets[h] = h
		}
	}
	if len(targets) == 0 {
		return []d.Result{d.Skip("You do not use SSH with GitHub, GitLab or Bitbucket here")}
	}
	agentKeys := -1 // -1: no agent to ask
	if add, err := e.Look("ssh-add"); err == nil {
		r := e.Run.Run(0, add, "-l")
		switch {
		case r.Code == 0:
			agentKeys = len(strings.Split(strings.TrimSpace(r.Stdout), "\n"))
		case r.Code == 1:
			agentKeys = 0
		}
	}
	aliases := make([]string, 0, len(targets))
	for a := range targets {
		aliases = append(aliases, a)
	}
	sort.Strings(aliases)
	var out []d.Result
	var judged []string
	for _, alias := range aliases {
		service := gitHosts[targets[alias]]
		cfg := sshSettings(e.Out(ssh, "-G", alias))
		files, have := cfg["identityfile"], []string{}
		for _, f := range files {
			if p := sshFile(e, f); host.Exists(p) || host.Exists(p+".pub") {
				have = append(have, f)
			}
		}
		agent := strings.ToLower(first(cfg["identityagent"]))
		ownAgent := agent != "" && agent != "ssh_auth_sock" && agent != "none" // such as 1Password's: it holds the keys, and cannot be asked here
		only := strings.EqualFold(first(cfg["identitiesonly"]), "yes")
		if len(have) == 0 && agentKeys <= 0 && !configured[alias] && !ownAgent {
			continue // no key anywhere and nothing in ~/.ssh/config: this person does not use SSH here
		}
		judged = append(judged, alias)
		switch {
		case ownAgent:
		case only && len(have) == 0:
			out = append(out, d.Warn("SSH to "+alias+" will be refused: the key it is set to use is gone").
				With("~/.ssh/config tells ssh to offer only "+strings.Join(files, ", ")+" to "+service+", and no such file exists. Point IdentityFile at a key you have, or make one: ssh-keygen -t ed25519"))
		case len(have) == 0 && agentKeys <= 0:
			out = append(out, d.Warn("SSH to "+alias+" will be refused: there is no key to offer").
				With("~/.ssh/config sets up "+alias+" for "+service+", but ~/.ssh holds no key ssh would try, and no agent holds one. Make one and add its .pub to your "+service+" account:\nssh-keygen -t ed25519"))
		}
		if targets[alias] == "github.com" && keygen != "" && host.Exists(known) {
			if s, _ := e.Out(keygen, "-l", "-F", "github.com", "-f", known); strings.Contains(s, githubOldRSA) {
				out = append(out, d.Warn("known_hosts still has GitHub's old RSA key, which GitHub replaced in 2023").
					With("So ssh to GitHub stops with \"Host key verification failed\". Remove the old entry, and ssh asks about the new key next time:\nssh-keygen -R github.com"))
			}
		}
	}
	if len(out) == 0 && len(judged) == 0 {
		return []d.Result{d.Skip("You do not use SSH with GitHub, GitLab or Bitbucket here")}
	}
	if len(out) == 0 {
		return []d.Result{d.Pass("SSH to " + strings.Join(judged, ", ") + " has a key to offer")}
	}
	return out
}

// sshConfigAliases finds the Host names in ~/.ssh/config that lead to a git host, by name or through HostName, mapped
// to that host. Include and Match are left to ssh -G, which reads them when each alias is asked about.
func sshConfigAliases(path string) map[string]string {
	out := map[string]string{}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()
	var hosts []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(strings.ReplaceAll(sc.Text(), "=", " "))
		if len(fields) < 2 || strings.HasPrefix(fields[0], "#") {
			continue
		}
		switch strings.ToLower(fields[0]) {
		case "host":
			hosts = nil
			for _, h := range fields[1:] {
				if !strings.ContainsAny(h, "*?!") {
					hosts = append(hosts, h)
					if _, git := gitHosts[strings.ToLower(h)]; git {
						out[h] = strings.ToLower(h)
					}
				}
			}
		case "match":
			hosts = nil
		case "hostname":
			if _, git := gitHosts[strings.ToLower(fields[1])]; git {
				for _, h := range hosts {
					out[h] = strings.ToLower(fields[1])
				}
			}
		}
	}
	return out
}

// sshSettings reads ssh -G output: one lowercase key and its value per line, keys repeated for lists.
func sshSettings(text string, _ bool) map[string][]string {
	out := map[string][]string{}
	for _, l := range strings.Split(text, "\n") {
		if k, v, ok := strings.Cut(strings.TrimSpace(l), " "); ok {
			out[k] = append(out[k], v)
		}
	}
	return out
}

// sshFile is an IdentityFile as ssh reads it: ~ is the home folder.
func sshFile(e *host.Env, f string) string {
	if strings.HasPrefix(f, "~/") {
		return e.Path(f[2:])
	}
	return f
}

func first(xs []string) string {
	if len(xs) == 0 {
		return ""
	}
	return xs[0]
}
