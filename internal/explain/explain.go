// Package explain matches an error message against the ones Catalyst knows, and says what causes it, which check
// confirms it on this machine and what fixes it. It is a table, read offline: an unknown message is said to be unknown,
// never guessed at.
package explain

import (
	"regexp"
	"strings"
)

// Match is one known error found in the text.
type Match struct {
	ID     string   `json:"id"`
	Title  string   `json:"title"`
	Cause  string   `json:"cause"`
	Checks []string `json:"checks,omitempty"` // doctor checks that confirm it: catalyst doctor --only ID
	Run    string   `json:"run,omitempty"`    // a Catalyst command that shows more
	Fix    string   `json:"fix"`
}

type sig struct {
	id     string
	find   *regexp.Regexp
	title  string
	cause  string
	checks []string
	run    string
	fix    string
	unless string // another entry that, when it matched, already explains this text better
}

// $1 in title, run and fix is the first thing the pattern caught, such as a port or a command's name.
var sigs = []sig{
	{"watchers", re(`ENOSPC: System limit for number of file watchers reached|inotify watch limit reached|inotify_add_watch.*No space left`),
		"Linux ran out of file watchers",
		"Editors, bundlers and test runners watch every file in a project, and the system's limit (often 8192) is used up. The disk is not full, whatever the message says.",
		[]string{"machine.watchers"}, "", "Raise the limit. The check shows how many are in use, and the exact command for this system.", ""},
	{"disk", re(`(?i:no space left on device|disk quota exceeded|not enough (?:free )?(?:disk )?space)|\bENOSPC\b`),
		"A disk is full",
		"Either this machine's disk, or a virtual machine's own disk, such as Docker Desktop's or Podman's, which fills up with its own limit while the Mac has room.",
		[]string{"machine.disk", "machine.docker"}, "catalyst space", "Free space safely with catalyst sweep (build folders) and catalyst clean (caches). For Docker's own disk: docker system prune.", "watchers"},
	{"port", re(`(?:EADDRINUSE|(?i:address already in use))|[Pp]ort \d{2,5} is (?:already )?in use`),
		"Something is already listening on that port",
		"Another program, often an earlier run of the same server that did not stop, holds the port.",
		nil, "catalyst ports", "Stop whatever holds it from Ports, or start yours on another port.", ""},
	{"files", re(`\bEMFILE\b|[Tt]oo many open files`),
		"The open file limit is too low",
		"Each shell has a limit on how many files a program may open at once. Bundlers and test runners can need thousands.",
		[]string{"shell.files"}, "", "Raise the limit. The check shows it, and how to raise it for new shells.", ""},
	{"pip", re(`externally-managed-environment`),
		"pip will not install into the system's Python",
		"Your system's Python belongs to its package manager (PEP 668), so pip refuses to change it.",
		[]string{"tools.pip"}, "", "Use a virtual environment for a project: python3 -m venv .venv, then . .venv/bin/activate. For a command-line tool, use pipx install NAME.", ""},
	{"docker-denied", re(`permission denied while trying to connect to the [Dd]ocker (?:API|daemon socket)`),
		"Docker is running, but this user may not use it",
		"On Linux, Docker's socket belongs to root and the docker group.",
		[]string{"machine.docker"}, "", "Join the docker group, or use rootless Docker. The check shows the command for this system, and what the group means for security.", ""},
	{"docker-down", re(`Cannot connect to the Docker daemon|failed to connect to the docker API|Is the docker daemon running`),
		"Docker is not running",
		"The docker command works, but there is no engine for it to talk to: Docker Desktop is closed, Colima or the service is stopped, or the context points at one that is gone.",
		[]string{"machine.docker"}, "", "Start Docker Desktop, or your runtime (colima start, or sudo systemctl start docker). The check says which applies here.", ""},
	{"dyld", re(`dyld(?:\[\d+\])?: Library not loaded: ?'?(\S+?)'?\s`),
		"A program needs a library that is gone",
		"It was built against a library that has since been upgraded or removed, often by brew upgrade or brew uninstall.",
		[]string{"tools.broken"}, "", "Reinstall the program that failed, with the tool that installed it, such as brew reinstall NAME. The check finds every command this affects.", ""},
	{"interpreter", re(`bad interpreter: (\S+?):? (?i:no such file)`),
		"A script's interpreter is gone",
		"The script starts with #! naming $1, which no longer exists, usually after Python or Ruby was upgraded or a version manager removed a version.",
		[]string{"tools.broken"}, "", "Reinstall the tool with the one that installed it (pipx reinstall NAME, pip install --force-reinstall NAME, gem pristine NAME).", ""},
	{"cpu-mac", re(`Bad CPU type in executable`),
		"An Intel program on an Apple silicon Mac, without Rosetta",
		"The program is built only for Intel, and Rosetta, which translates it, is not installed.",
		[]string{"tools.broken"}, "", "Install the Apple silicon version if there is one. Otherwise install Rosetta: softwareupdate --install-rosetta", ""},
	{"cpu-linux", re(`[Ee]xec format error|cannot execute binary file`),
		"A program built for another kind of processor",
		"It was built for a different CPU (arm64 against x86_64), or it is not a program for this system at all.",
		[]string{"tools.broken"}, "", "Install the build for this machine. The check names every command like this on your PATH.", ""},
	{"glibc", re(`GLIBC_(\d+\.\d+)'? not found`),
		"A program needs a newer glibc than this system has",
		"It was built on a newer Linux, and needs glibc $1 or later. The system's glibc cannot be upgraded on its own.",
		nil, "catalyst status", "Install the version built for this distribution, or a static or musl build.", ""},
	{"clock", re(`certificate (?:is not yet valid|has expired)|x509: certificate has expired or is not yet valid`),
		"A certificate looks expired, which is often the clock",
		"When this machine's clock is wrong, valid certificates look expired or not yet valid. If the clock is right, the site's certificate really did expire.",
		[]string{"machine.clock"}, "", "If the check finds the clock off, turn on automatic time. Otherwise the certificate really expired, and the site has to renew it.", ""},
	{"tls", re(`CERTIFICATE_VERIFY_FAILED|unable to get local issuer certificate|self[- ]signed certificate in certificate chain|SELF_SIGNED_CERT_IN_CHAIN|UNABLE_TO_GET_ISSUER_CERT_LOCALLY|SSL certificate problem`),
		"A tool does not trust the certificate it was shown",
		"Either the tool has no certificates to check with (python.org's Python on a Mac, until its Install Certificates step runs), a setting points at a certificate file that is gone, or a company proxy or VPN re-signs traffic with its own certificate.",
		[]string{"tools.tls", "tools.network"}, "", "The checks find a missing certificate store or a setting that points nowhere. Behind a company proxy, point NODE_EXTRA_CA_CERTS, REQUESTS_CA_BUNDLE or git's http.sslCAInfo at your company's certificate.", ""},
	{"publickey", re(`Permission denied \(publickey`),
		"The SSH server refused every key offered",
		"ssh offered no key, or none that the account on that server knows.",
		[]string{"keys.sshhosts", "keys.ssh"}, "", "Check what is offered: ssh-add -l. Add your .pub to the account (GitHub: Settings, SSH keys), or clone over HTTPS instead.", ""},
	{"hostkey", re(`Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED`),
		"The server's key does not match the one in known_hosts",
		"Either the server changed its key (GitHub did in 2023), or something is in the way. ssh stops rather than guess.",
		[]string{"keys.sshhosts"}, "", "If the host announced a new key, remove the old one with ssh-keygen -R HOST and connect again. If it did not, find out why before you do.", ""},
	{"identity", re(`Please tell me who you are|Author identity unknown|unable to auto-detect email address`),
		"git does not know your name and email",
		"Every commit records an author, and git has none set.",
		[]string{"tools.git"}, "", "git config --global user.name \"Your Name\", then git config --global user.email you@example.com", ""},
	{"gpg", re(`gpg failed to sign the data|error: Load key "[^"]*": (?:No such file|invalid format)`),
		"git cannot sign your commit",
		"Commit signing is on, and the key or the program it uses is missing or locked.",
		[]string{"tools.gitsetup"}, "", "The check says which part is missing. To stop signing for now: git config --global commit.gpgsign false", ""},
	{"owner", re(`detected dubious ownership in repository at '([^']+)'`),
		"git will not work in a folder owned by another user",
		"The repository belongs to a different user, often root after a sudo git clone, and git refuses it to stay safe.",
		nil, "", "Give it back to yourself: sudo chown -R $USER \"$1\". Or, if you trust it as it is: git config --global --add safe.directory \"$1\"", ""},
	{"java", re(`JAVA_HOME is (?:set to an invalid directory|not set|not defined correctly)|No Java runtime present|Unable to locate a Java Runtime`),
		"No Java where the build looks for it",
		"Gradle, Maven and Android tools find Java through JAVA_HOME, and it is unset or points at a removed JDK.",
		[]string{"tools.java"}, "", "Point JAVA_HOME at an installed JDK. The check lists the ones here and the line to set.", ""},
	{"xcode", re(`xcrun: error: invalid active developer path|xcode-select: note: no developer tools were found|xcrun: error: unable to find utility`),
		"Apple's Command Line Tools are missing or broken",
		"git, make and compilers on a Mac come from them, and a macOS update often removes them.",
		[]string{"tools.build"}, "", "Reinstall them: xcode-select --install", ""},
	{"npm-eacces", re(`npm (?:ERR!|error) code EACCES|EACCES: permission denied, (?:mkdir|access|open|rename|symlink) '[^']*node_modules`),
		"npm cannot write to its global folder",
		"The folder npm installs global packages into belongs to root, often after one sudo npm install -g.",
		[]string{"tools.node"}, "", "Do not use sudo. Use a version manager such as nvm or fnm, whose global folder is yours.", ""},
	{"module", re(`ModuleNotFoundError: No module named '([\w.]+)'|ImportError: No module named '?([\w.]+)`),
		"Python cannot find the module $1",
		"It is installed for a different Python than the one running, or the project's virtual environment is not active.",
		[]string{"tools.python"}, "catalyst why python3", "Install it with the same Python that runs the script: python3 -m pip install $1 (inside the project's .venv if it has one).", ""},
	{"heap", re(`JavaScript heap out of memory|Reached heap limit`),
		"Node ran out of the memory it allows itself",
		"Node caps its own heap, and a large build or test run goes over it. It is rarely this machine's memory.",
		[]string{"machine.memory"}, "", "Give it more for this run: NODE_OPTIONS=--max-old-space-size=4096, then the command again.", ""},
	{"dns", re(`Could not resolve host|getaddrinfo (?:ENOTFOUND|EAI_AGAIN)|Temporary failure in name resolution|nodename nor servname provided`),
		"A name could not be looked up",
		"DNS is not answering, the connection is down, or a proxy or VPN setting sends lookups somewhere that is gone.",
		[]string{"tools.network"}, "catalyst net", "catalyst net tests DNS and the connection, and the check looks for a proxy setting that points nowhere.", ""},
	{"engine", re(`The engine "node" is incompatible|EBADENGINE|Unsupported engine`),
		"This project asks for a different Node",
		"Its package.json (engines) or .nvmrc pins a Node version, and the one running is not it.",
		nil, "catalyst project", "Switch to the version it pins with your version manager, such as nvm use or fnm use.", ""},
	{"notfound", re(`(?:zsh|bash|sh|ksh|dash)(?::(?: line)? \d+)?: (?:command not found: ([\w.+-]+)|([\w.+-]+): (?:command )?not found)|fish: Unknown command:? '?([\w.+-]+)`),
		"No command called $1",
		"Nothing on the PATH a new terminal gets is called $1. It is not installed, its folder is not on PATH, or its setup line is in another shell's startup file.",
		[]string{"shell.othershell", "shell.path"}, "catalyst why $1", "Install it, or, if it is installed, the check names the startup lines your shell is missing.", ""},
}

func re(s string) *regexp.Regexp { return regexp.MustCompile(s) }

// Max is how many matches are said at most. An error log can hold many messages, and the first are usually the cause.
const Max = 3

// Find returns the known errors in text, in the order of the table, each at most once.
func Find(text string) []Match {
	var out []Match
	found := map[string]bool{}
	for _, s := range sigs {
		m := s.find.FindStringSubmatch(text)
		if m == nil || found[s.unless] {
			continue
		}
		found[s.id] = true
		caught := ""
		for _, g := range m[1:] {
			if g != "" {
				caught = g
				break
			}
		}
		fill := func(x string) string {
			if caught == "" {
				x = strings.ReplaceAll(x, " $1", "")
				return strings.ReplaceAll(x, "$1", "it")
			}
			return strings.ReplaceAll(x, "$1", caught)
		}
		out = append(out, Match{ID: s.id, Title: fill(s.title), Cause: fill(s.cause), Checks: s.checks, Run: fill(s.run), Fix: fill(s.fix)})
		if len(out) == Max {
			break
		}
	}
	return out
}

// Checks is every doctor check the table points at, so a test can make sure each one exists.
func Checks() []string {
	var out []string
	for _, s := range sigs {
		out = append(out, s.checks...)
	}
	return out
}
