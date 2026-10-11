package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

var noise = regexp.MustCompile(`^($|which: no \S+ in \(|Resolving dependencies\.\.\.$|Downloading packages\.\.\.$|Got dependencies!$|\d+ packages? ha(s|ve) newer versions|Try .flutter pub outdated.|[ !] +\S+ .*\((\S+ available|overridden)\)$)`)

// Held so a compile error that a failed load repeats prints once, under its
// suite.
const holdFor = 2 * time.Second

type event struct {
	Type string `json:"type"`
	Time int    `json:"time"`

	Count   int   `json:"count"`
	Success *bool `json:"success"`

	Test *struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	} `json:"test"`

	TestID     int    `json:"testID"`
	Result     string `json:"result"`
	Skipped    bool   `json:"skipped"`
	Hidden     bool   `json:"hidden"`
	Error      string `json:"error"`
	StackTrace string `json:"stackTrace"`
	Message    string `json:"message"`
}

type test struct {
	name    string
	suite   bool
	started int
	log     strings.Builder
}

type stray struct {
	text string
	at   time.Time
}

type report struct {
	mu    sync.Mutex
	out   io.Writer
	live  bool
	width func() int
	began time.Time

	running              bool
	suites, loaded       int
	passed, failed, skip int
	tests                map[int]*test
	held                 []stray
	failures             []string
	success              *bool
}

func newReport(out io.Writer, live bool, width func() int) *report {
	return &report{out: out, live: live, width: width, began: time.Now(), tests: map[int]*test{}}
}

func (r *report) line(s string) {
	r.mu.Lock()
	defer r.mu.Unlock()

	var e event
	if !strings.HasPrefix(s, "{") || json.Unmarshal([]byte(s), &e) != nil || e.Type == "" {
		switch {
		case noise.MatchString(s):
		case r.running:
			r.held = append(r.held, stray{s, time.Now()})
		default:
			r.print(s)
		}
		return
	}

	switch e.Type {
	case "start":
		r.running = true
	case "allSuites":
		r.suites = e.Count
	case "testStart":
		t := &test{name: e.Test.Name, started: e.Time}
		if path, ok := strings.CutPrefix(t.name, "loading "); ok {
			t.name, t.suite = filepath.Base(path), true
		}
		r.tests[e.Test.ID] = t
	case "print":
		if t := r.tests[e.TestID]; t != nil {
			t.log.WriteString(e.Message + "\n")
		}
	case "error":
		if t := r.tests[e.TestID]; t != nil {
			t.log.WriteString(e.Error + "\n" + e.StackTrace)
			if t.suite {
				r.drop(e.Error)
			}
		}
	case "testDone":
		r.done(e)
	case "done":
		r.success = e.Success
	}
	r.release(false)
	r.status()
}

func (r *report) drop(reported string) {
	kept := r.held[:0]
	for _, h := range r.held {
		if !strings.Contains(reported, strings.TrimSpace(h.text)) {
			kept = append(kept, h)
		}
	}
	r.held = kept
}

func (r *report) release(all bool) {
	n := 0
	for n < len(r.held) && (all || time.Since(r.held[n].at) >= holdFor) {
		r.print(r.held[n].text)
		n++
	}
	r.held = r.held[n:]
}

func (r *report) done(e event) {
	t := r.tests[e.TestID]
	if t == nil {
		return
	}
	delete(r.tests, e.TestID)
	if t.suite {
		r.loaded++
	}

	if e.Result == "success" {
		switch {
		case t.suite:
			r.print(fmt.Sprintf("compiled %s (%d/%d) in %.1fs", t.name, r.loaded, r.suites, float64(e.Time-t.started)/1000))
		case e.Hidden:
		case e.Skipped:
			r.skip++
		default:
			r.passed++
		}
		return
	}

	r.failed++
	r.failures = append(r.failures, t.name)
	r.print(r.paint("31", "FAIL "+t.name))
	if log := strings.TrimRight(t.log.String(), "\n"); log != "" {
		r.print("    " + strings.ReplaceAll(log, "\n", "\n    "))
	}
}

func (r *report) paint(code, s string) string {
	if !r.live {
		return s
	}
	return "\x1b[" + code + "m" + s + "\x1b[0m"
}

func (r *report) print(s string) {
	if r.live {
		fmt.Fprint(r.out, "\r\x1b[K")
	}
	fmt.Fprintln(r.out, s)
}

func (r *report) status() {
	if !r.live {
		return
	}
	var state string
	switch {
	case !r.running:
		state = "resolving packages, running build hooks"
	case r.suites == 0:
		state = "compiling"
	case r.loaded < r.suites:
		state = fmt.Sprintf("compiled %d/%d", r.loaded, r.suites)
	default:
		state = "running"
	}
	elapsed := time.Since(r.began).Truncate(time.Second)
	line := fmt.Sprintf("%s  %s  %s", elapsed, r.counts(false), state)
	if w := r.width(); w > 0 && len(line) >= w {
		line = line[:w-1]
	} else {
		line = fmt.Sprintf("%s  %s  %s", elapsed, r.counts(true), state)
	}
	fmt.Fprint(r.out, "\r\x1b[K"+line)
}

func (r *report) counts(color bool) string {
	paint := func(code, s string) string {
		if color {
			return r.paint(code, s)
		}
		return s
	}
	s := paint("32", fmt.Sprintf("%d passed", r.passed))
	if r.failed > 0 {
		s += "  " + paint("31", fmt.Sprintf("%d failed", r.failed))
	}
	if r.skip > 0 {
		s += "  " + paint("33", fmt.Sprintf("%d skipped", r.skip))
	}
	return s
}

func (r *report) tick() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.release(false)
	r.status()
}

func (r *report) finish() bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.release(true)
	if r.live {
		fmt.Fprint(r.out, "\r\x1b[K")
	}
	if len(r.failures) > 0 {
		fmt.Fprintln(r.out, "\nfailed:")
		for _, name := range r.failures {
			fmt.Fprintln(r.out, "  "+name)
		}
	}
	fmt.Fprintf(r.out, "\n%s in %s\n", r.counts(r.live), time.Since(r.began).Round(100*time.Millisecond))
	if r.success == nil {
		fmt.Fprintln(r.out, "flutter test ended without a result")
		return false
	}
	return r.failed == 0 && *r.success
}

func main() {
	info, err := os.Stdout.Stat()
	live := err == nil && info.Mode()&os.ModeCharDevice != 0 && os.Getenv("TERM") != "dumb"
	r := newReport(os.Stdout, live, func() int { return width(os.Stdout) })

	go func() {
		for range time.Tick(time.Second) {
			r.tick()
		}
	}()

	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 64<<10), 16<<20)
	for scanner.Scan() {
		r.line(scanner.Text())
	}
	if err := scanner.Err(); err != nil {
		fmt.Fprintln(os.Stderr, "testfmt:", err)
		os.Exit(2)
	}
	if !r.finish() {
		os.Exit(1)
	}
}
