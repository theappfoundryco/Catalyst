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
	"os/signal"
	"strings"
	"sync/atomic"
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

// Foreground is true while a program has the terminal to itself through Attached. A Ctrl-C then belongs to that program,
// so the session must not take it as its own signal to leave.
var Foreground atomic.Bool

// Attached runs a program on this terminal, in the foreground, so it can ask its own questions. It exists for the few
// steps a person must answer themselves: sudo asking for a password (macOS reads it, Catalyst never sees it), or an
// installer asking to go ahead. Nothing else uses it. stdout is captured when capture is true, and shown otherwise.
// There is no time limit: the person is in charge, and Ctrl-C reaches the program, not Catalyst.
func Attached(capture bool, name string, args ...string) (stdout string, code int) {
	cmd := exec.Command(name, args...)
	cmd.Stdin, cmd.Stderr = os.Stdin, os.Stderr
	var out bytes.Buffer
	if capture {
		cmd.Stdout = &out
	} else {
		cmd.Stdout = os.Stdout
	}
	quiet := make(chan os.Signal, 1) // while anything listens, Go does not let a Ctrl-C end Catalyst
	signal.Notify(quiet, os.Interrupt)
	defer signal.Stop(quiet)
	Foreground.Store(true)
	defer Foreground.Store(false)
	err := cmd.Run()
	var ee *exec.ExitError
	switch {
	case err == nil:
		return out.String(), 0
	case errors.As(err, &ee):
		return out.String(), ee.ExitCode()
	case errors.Is(err, exec.ErrNotFound), errors.Is(err, os.ErrNotExist):
		return "", 127
	}
	return out.String(), -1
}

// Input runs a program with text on its stdin, such as pbcopy with what to copy. Same rules as Run otherwise.
func Input(timeout time.Duration, input, name string, args ...string) Result {
	if timeout <= 0 {
		timeout = Default
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin = strings.NewReader(input)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.WaitDelay = 2 * time.Second
	err := cmd.Run()
	r := Result{Stdout: out.String(), Stderr: errb.String()}
	var ee *exec.ExitError
	switch {
	case err == nil:
	case errors.Is(err, exec.ErrNotFound), errors.Is(err, os.ErrNotExist):
		r.NotFound, r.Code = true, 127
	case errors.As(err, &ee):
		r.Code = ee.ExitCode()
	default:
		r.Code = -1
	}
	return r
}
