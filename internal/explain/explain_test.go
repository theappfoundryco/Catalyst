package explain

import (
	"strings"
	"testing"
)

// Each known error, in the words the tools print it, with names and paths invented.
var samples = map[string]string{
	"watchers":      "Error: ENOSPC: System limit for number of file watchers reached, watch '/home/alex/app/src'",
	"disk":          "write /var/lib/docker/tmp/GetImageBlob123: no space left on device",
	"port":          "Error: listen EADDRINUSE: address already in use :::3000",
	"files":         "Error: EMFILE: too many open files, open '/home/alex/app/node_modules/x/index.js'",
	"pip":           "error: externally-managed-environment\n\n× This environment is externally managed",
	"docker-denied": "permission denied while trying to connect to the docker API at unix:///var/run/docker.sock",
	"docker-down":   "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?",
	"dyld":          "dyld[1234]: Library not loaded: /opt/homebrew/opt/icu4c/lib/libicuuc.73.dylib\n  Referenced from: /opt/homebrew/bin/node",
	"interpreter":   "zsh: /home/alex/.local/bin/http: bad interpreter: /home/alex/.pyenv/versions/3.11.4/bin/python3.11: no such file or directory",
	"cpu-mac":       "zsh: bad CPU type in executable: ./tool\nBad CPU type in executable",
	"cpu-linux":     "bash: ./tool: cannot execute binary file: Exec format error",
	"glibc":         "./tool: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found (required by ./tool)",
	"clock":         "x509: certificate has expired or is not yet valid: current time 2001-01-01T00:00:00Z is before 2026-01-01",
	"tls":           "ssl.SSLCertVerificationError: [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to get local issuer certificate (_ssl.c:1006)",
	"publickey":     "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.",
	"hostkey":       "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed.",
	"identity":      "Author identity unknown\n\n*** Please tell me who you are.",
	"gpg":           "error: gpg failed to sign the data\nfatal: failed to write commit object",
	"owner":         "fatal: detected dubious ownership in repository at '/srv/app'",
	"java":          "ERROR: JAVA_HOME is set to an invalid directory: /Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home",
	"xcode":         "xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools), missing xcrun at: /Library/Developer/CommandLineTools/usr/bin/xcrun",
	"npm-eacces":    "npm error code EACCES\nnpm error syscall mkdir\nnpm error path /usr/local/lib/node_modules/typescript",
	"module":        "Traceback (most recent call last):\n  File \"app.py\", line 1\nModuleNotFoundError: No module named 'requests'",
	"heap":          "FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory",
	"dns":           "fatal: unable to access 'https://github.com/example/app.git/': Could not resolve host: github.com",
	"engine":        "error app@1.0.0: The engine \"node\" is incompatible with this module. Expected version \">=20\". Got \"18.19.0\"",
	"notfound":      "zsh: command not found: nvm",
}

func TestEveryEntryKnowsItsOwnSample(t *testing.T) {
	for _, s := range sigs {
		text, ok := samples[s.id]
		if !ok {
			t.Errorf("%s has no sample", s.id)
			continue
		}
		got := Find(text)
		if len(got) == 0 || got[0].ID != s.id {
			t.Errorf("%s: got %+v", s.id, got)
		}
		for _, m := range got {
			if strings.Contains(m.Title+m.Cause+m.Fix+m.Run, "$1") {
				t.Errorf("%s: an unfilled $1 in %+v", s.id, m)
			}
		}
	}
}

func TestWhatWasCaughtIsUsed(t *testing.T) {
	for text, want := range map[string]string{
		"zsh: command not found: nvm":                 "catalyst why nvm",
		"bash: brew: command not found":               "catalyst why brew",
		"sh: 1: tsc: not found":                       "catalyst why tsc",
		"bash: line 3: poetry: command not found":     "catalyst why poetry",
		"fish: Unknown command: pyenv":                "catalyst why pyenv",
		"ModuleNotFoundError: No module named 'yaml'": "pip install yaml",
	} {
		got := Find(text)
		if len(got) == 0 || !strings.Contains(got[0].Run+" "+got[0].Fix, want) {
			t.Errorf("%q: %+v", text, got)
		}
	}
}

func TestNoGuessing(t *testing.T) {
	for _, text := range []string{"", "everything worked", "Segmentation fault (core dumped)", "TypeError: x is not a function"} {
		if got := Find(text); len(got) != 0 {
			t.Errorf("%q: %+v", text, got)
		}
	}
	if got := Find(samples["watchers"]); len(got) != 1 {
		t.Errorf("a watcher limit is not also a full disk: %+v", got)
	}
	long := strings.Repeat(samples["disk"]+"\n"+samples["port"]+"\n"+samples["tls"]+"\n"+samples["dns"]+"\n", 3)
	if got := Find(long); len(got) != Max {
		t.Errorf("at most %d: %d", Max, len(got))
	}
}
