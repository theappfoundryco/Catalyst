package ui

import (
	"bufio"
	"fmt"
	"strings"
	"sync"
	"time"
)

var frames = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

// Spinner holds one live line. Set changes its dim trailing text, Stop clears it. On a pipe it prints nothing.
type Spinner struct {
	u     *UI
	doing string
	mu    sync.Mutex
	last  string
	t0    time.Time
	done  chan struct{}
	gone  chan struct{}
}

// Spin starts a spinner.
func (u *UI) Spin(doing string) *Spinner {
	s := &Spinner{u: u, doing: doing, t0: time.Now(), done: make(chan struct{}), gone: make(chan struct{})}
	if !u.TTY {
		close(s.gone)
		return s
	}
	go func() {
		defer close(s.gone)
		tick := time.NewTicker(100 * time.Millisecond)
		defer tick.Stop()
		for i := 0; ; i++ {
			s.draw(i)
			select {
			case <-s.done:
				fmt.Fprint(u.Out, "\r\033[K")
				return
			case <-tick.C:
			}
		}
	}()
	return s
}

// line builds the row so it fits one terminal line: longer than that, each frame would wrap and stack.
func (s *Spinner) line(frame int, cols int) string {
	s.mu.Lock()
	last := s.last
	doing := s.doing
	s.mu.Unlock()
	secs := fmt.Sprintf("(%ds)", int(time.Since(s.t0).Seconds()))
	doing = Fit(doing, cols-len(secs)-8)
	room := cols - Visible(doing) - len(secs) - 8
	tail := secs
	if room > 12 && last != "" {
		tail += " " + Fit(last, room)
	}
	return fmt.Sprintf("  %s %s %s", s.u.Cyan(frames[frame%len(frames)]), doing, s.u.Dim(tail))
}

func (s *Spinner) draw(frame int) { fmt.Fprint(s.u.Out, "\r"+s.line(frame, s.u.Width())+"\033[K") }

// Set changes the main text.
func (s *Spinner) Set(doing string) {
	s.mu.Lock()
	s.doing = doing
	s.mu.Unlock()
}

// Detail changes the dim trailing text.
func (s *Spinner) Detail(last string) {
	s.mu.Lock()
	s.last = last
	s.mu.Unlock()
}

// Stop clears the line, and returns how long the spinner ran.
func (s *Spinner) Stop() time.Duration {
	select {
	case <-s.done:
	default:
		close(s.done)
	}
	<-s.gone
	return time.Since(s.t0)
}

// Took is a dim elapsed note, empty under a second.
func (u *UI) Took(d time.Duration) string {
	if d < time.Second {
		return ""
	}
	return " " + u.Dim(fmt.Sprintf("(%ds)", int(d.Seconds())))
}

// Step runs fn with a spinner, then prints one tick. On failure it shows what the work said, and nothing before that.
func (u *UI) Step(doing, did string, fn func(s *Spinner) (string, error)) error {
	if !u.TTY {
		fmt.Fprintf(u.Out, "  %s...\n", doing)
	}
	s := u.Spin(doing)
	output, err := fn(s)
	took := s.Stop()
	if err == nil {
		u.Ok(did + u.Took(took))
		return nil
	}
	u.Stop(doing + " did not work: " + err.Error())
	if tail := lastLines(output, 12); tail != "" {
		for _, l := range strings.Split(tail, "\n") {
			u.Hint(l)
		}
	}
	return err
}

func lastLines(s string, n int) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

// Ask asks a yes or no question where Enter means no. Never yes without a person or --yes.
func (u *UI) Ask(q string) bool {
	if u.Yes {
		return true
	}
	if !u.InTTY {
		return false
	}
	switch strings.ToLower(u.prompt(q + " [y/N] ")) {
	case "y", "yes":
		return true
	}
	return false
}

// AskYes asks about something most people want, where Enter means yes. It is still never yes without a person.
func (u *UI) AskYes(q string) bool {
	if u.Yes {
		return true
	}
	if !u.InTTY {
		return false
	}
	switch strings.ToLower(u.prompt(q + " [Y/n] ")) {
	case "n", "no":
		return false
	}
	return true
}

func (u *UI) prompt(q string) string {
	fmt.Fprint(u.Out, "  "+q)
	r := bufio.NewReader(u.In)
	line, _ := r.ReadString('\n')
	return strings.TrimSpace(line)
}
