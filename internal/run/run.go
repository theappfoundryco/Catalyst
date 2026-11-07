// Package run starts other programs. It is the only place Catalyst does so, and it holds the rules that kept
// the old app from hanging: arguments are never passed through a shell, stdin is closed so a hidden prompt fails
// instead of waiting, every call has a time limit, and output is parsed in a fixed locale.
package run

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

// Default is the time limit when a caller passes zero.
const Default = 10 * time.Second

// Result is what came back from a program.
type Result struct {
	Stdout, Stderr string
	Code           int
	NotFound       bool
	TimedOut       bool
}

// OK reports a clean exit. Success is always decided by the exit code, never by scraping text.
func (r Result) OK() bool { return r.Code == 0 && !r.NotFound && !r.TimedOut }

// Text is stdout with the surrounding whitespace removed.
func (r Result) Text() string { return strings.TrimSpace(r.Stdout) }

// Runner is swapped for a Fake in tests, so a Linux contributor can test macOS parsing and the other way round.
type Runner interface {
	Run(timeout time.Duration, name string, args ...string) Result
}

// Real runs actual programs.
type Real struct{}

// Run starts name with args and waits for it, up to the time limit.
func (Real) Run(timeout time.Duration, name string, args ...string) Result {
	if timeout <= 0 {
		timeout = Default
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), "LC_ALL=C", "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0")
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	// Its own session, with no controlling terminal. An interactive shell started in a background group freezes when it
	// touches the terminal (SIGTTOU), and without a terminal nothing can stop to ask for a password either.
	// It also means a time limit stops everything it started. A child that keeps our pipe open (a git fsmonitor daemon,
	// system_profiler) can otherwise make reading to the end wait forever: WaitDelay ends that.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 2 * time.Second
	err := cmd.Run()
	r := Result{Stdout: out.String(), Stderr: errb.String()}
	if err == nil {
		return r
	}
	var ee *exec.ExitError
	switch {
	case errors.Is(err, exec.ErrNotFound), errors.Is(err, os.ErrNotExist):
		r.NotFound, r.Code = true, 127
	case ctx.Err() != nil:
		r.TimedOut, r.Code = true, -1
	case errors.Is(err, exec.ErrWaitDelay):
		// The program itself finished; something it started just kept the pipe open.
	case errors.As(err, &ee):
		r.Code = ee.ExitCode()
	default:
		r.Code = -1
		r.Stderr = err.Error()
	}
	return r
}

// Fake answers from a table, keyed by the whole command line. Anything not listed reads as "not installed".
type Fake struct {
	Calls   []string
	Replies map[string]Result
}

// Run looks the command line up in Replies.
func (f *Fake) Run(_ time.Duration, name string, args ...string) Result {
	line := strings.TrimSpace(fmt.Sprintf("%s %s", name, strings.Join(args, " ")))
	f.Calls = append(f.Calls, line)
	if r, ok := f.Replies[line]; ok {
		return r
	}
	return Result{NotFound: true, Code: 127}
}
