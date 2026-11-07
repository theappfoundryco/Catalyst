package checks

import (
	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "tools.java", Group: d.GroupTools, Name: "Checking Java", Run: javaSetup})
}

func javaSetup(e *host.Env) []d.Result {
	if e.JavaHome != "" && !host.Exists(e.JavaHome) {
		return []d.Result{d.Warn("JAVA_HOME points at a folder that is gone (" + e.JavaHome + ")").With("Gradle, Maven and Android tools will fail until it is fixed.")}
	}
	_, javac := e.Look("javac")
	jdk := javac == nil
	if e.Mac() {
		jdk = e.Run.Run(0, "/usr/libexec/java_home").OK()
	}
	if !jdk {
		return []d.Result{d.Skip("No Java here")}
	}
	if e.JavaHome == "" {
		return []d.Result{d.Note("A JDK is installed but JAVA_HOME is not set").With("Some build tools will not find it.")}
	}
	return []d.Result{d.Pass("JAVA_HOME points at a real JDK")}
}
