package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestParseArgsCollectsFacts(t *testing.T) {
	opts, err := parseArgs([]string{
		"-fact", "harness=claude",
		"--fact=worktree_branch=agent/abc",
		"-fact", "roles=",
		"/etc/agent/AGENTS.md.tmpl",
	})
	if err != nil {
		t.Fatalf("parseArgs returned %v", err)
	}
	if opts.path != "/etc/agent/AGENTS.md.tmpl" {
		t.Fatalf("path = %q", opts.path)
	}
	want := map[string]string{
		"harness":         "claude",
		"worktree_branch": "agent/abc",
		"roles":           "",
	}
	if !reflect.DeepEqual(opts.facts, want) {
		t.Fatalf("facts = %#v, want %#v", opts.facts, want)
	}
}

func TestParseArgsKeepsValuesContainingEquals(t *testing.T) {
	opts, err := parseArgs([]string{"-fact", "gitroot=/srv/a=b", "x.md.tmpl"})
	if err != nil {
		t.Fatalf("parseArgs returned %v", err)
	}
	if got := opts.facts["gitroot"]; got != "/srv/a=b" {
		t.Fatalf("gitroot = %q", got)
	}
}

func TestParseArgsRejectsBadInput(t *testing.T) {
	cases := map[string][]string{
		"no operand":      {"-fact", "harness=claude"},
		"two operands":    {"a.md.tmpl", "b.md.tmpl"},
		"unknown option":  {"-verbose", "a.md.tmpl"},
		"unknown fact":    {"-fact", "hostname=forge", "a.md.tmpl"},
		"malformed fact":  {"-fact", "harness", "a.md.tmpl"},
		"empty fact name": {"-fact", "=claude", "a.md.tmpl"},
		"dangling -fact":  {"-fact"},
		"no arguments":    {},
	}

	for name, args := range cases {
		if _, err := parseArgs(args); err == nil {
			t.Fatalf("%s: parseArgs accepted %v", name, args)
		}
	}
}

func TestParseArgsStopsFlagsAtDoubleDash(t *testing.T) {
	opts, err := parseArgs([]string{"--", "-weird-name.md.tmpl"})
	if err != nil {
		t.Fatalf("parseArgs returned %v", err)
	}
	if opts.path != "-weird-name.md.tmpl" {
		t.Fatalf("path = %q", opts.path)
	}
}

func TestRunRendersFileToWriter(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "AGENTS.md.tmpl")
	source := `density {{param "AGENT_SPEECH_INFO_DENSITY" "100"}}% under {{fact "harness"}}`
	if err := os.WriteFile(path, []byte(source), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENT_SPEECH_INFO_DENSITY", "40")

	var out strings.Builder
	opts := options{path: path, facts: map[string]string{"harness": "codex"}}
	if err := run(opts, &out); err != nil {
		t.Fatalf("run returned %v", err)
	}
	if want := "density 40% under codex"; out.String() != want {
		t.Fatalf("got %q, want %q", out.String(), want)
	}
}

func TestRunNamesTheFileInARenderError(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "broken.md.tmpl")
	if err := os.WriteFile(path, []byte(`{{fact "nope"}}`), 0o644); err != nil {
		t.Fatal(err)
	}

	err := run(options{path: path}, &strings.Builder{})
	if err == nil {
		t.Fatal("run accepted a broken template")
	}
	if !strings.Contains(err.Error(), path) {
		t.Fatalf("error does not name the file: %v", err)
	}
}

func TestRunReportsAMissingFile(t *testing.T) {
	err := run(options{path: filepath.Join(t.TempDir(), "absent")}, &strings.Builder{})
	if !os.IsNotExist(err) {
		t.Fatalf("run returned %v, want a not-exist error", err)
	}
}
