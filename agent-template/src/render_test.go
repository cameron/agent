package main

import (
	"strings"
	"testing"
)

func env(pairs map[string]string) func(string) string {
	return func(name string) string { return pairs[name] }
}

func TestParamUsesEnvironmentValue(t *testing.T) {
	got, err := render(
		`density {{param "AGENT_SPEECH_INFO_DENSITY" "100"}}%`,
		nil,
		env(map[string]string{"AGENT_SPEECH_INFO_DENSITY": "25"}),
	)
	if err != nil {
		t.Fatalf("render returned %v", err)
	}
	if want := "density 25%"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestParamFallsBackWhenUnsetOrEmpty(t *testing.T) {
	source := `density {{param "AGENT_SPEECH_INFO_DENSITY" "100"}}%`

	for name, environment := range map[string]map[string]string{
		"unset": {},
		"empty": {"AGENT_SPEECH_INFO_DENSITY": ""},
	} {
		got, err := render(source, nil, env(environment))
		if err != nil {
			t.Fatalf("%s: render returned %v", name, err)
		}
		if want := "density 100%"; got != want {
			t.Fatalf("%s: got %q, want %q", name, got, want)
		}
	}
}

func TestParamRejectsUnprefixedName(t *testing.T) {
	_, err := render(
		`{{param "HOME" ""}}`,
		nil,
		env(map[string]string{"HOME": "/home/secret"}),
	)
	if err == nil {
		t.Fatal("render accepted an unprefixed parameter name")
	}
	if !strings.Contains(err.Error(), "AGENT_[A-Z0-9_]+") {
		t.Fatalf("error does not name the required form: %v", err)
	}
	if strings.Contains(err.Error(), "/home/secret") {
		t.Fatalf("error leaked the environment value: %v", err)
	}
}

func TestParamRejectsLowercaseAndBareAgentPrefix(t *testing.T) {
	for _, name := range []string{"agent_speech", "AGENT_", "AGENTSPATH", ""} {
		if _, err := render(`{{param "`+name+`" "x"}}`, nil, env(nil)); err == nil {
			t.Fatalf("render accepted parameter name %q", name)
		}
	}
}

func TestFactPrefersLauncherValue(t *testing.T) {
	got, err := render(
		`{{fact "harness"}} on {{fact "worktree_branch"}}`,
		map[string]string{"harness": "claude", "worktree_branch": "agent/abc"},
		env(nil),
	)
	if err != nil {
		t.Fatalf("render returned %v", err)
	}
	if want := "claude on agent/abc"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestUnsuppliedFactRendersEmpty(t *testing.T) {
	got, err := render(`[{{fact "worktree"}}]`, nil, env(nil))
	if err != nil {
		t.Fatalf("render returned %v", err)
	}
	if want := "[]"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestUnknownFactIsAnError(t *testing.T) {
	_, err := render(`{{fact "harnes"}}`, nil, env(nil))
	if err == nil {
		t.Fatal("render accepted an unknown fact")
	}
	if !strings.Contains(err.Error(), "harness") {
		t.Fatalf("error does not list the known facts: %v", err)
	}
}

func TestLocalFactsAnswerHostAndUser(t *testing.T) {
	got, err := render(`{{fact "host"}}`, nil, env(nil))
	if err != nil {
		t.Fatalf("render returned %v", err)
	}
	if got == "" {
		t.Fatal("host fact rendered empty")
	}
}

func TestConditionalOnParameter(t *testing.T) {
	source := `{{if eq (param "AGENT_SPEECH_INFO_DENSITY" "100") "100"}}default{{else}}adjusted{{end}}`

	got, err := render(source, nil, env(nil))
	if err != nil {
		t.Fatalf("render returned %v", err)
	}
	if want := "default"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}

	got, err = render(source, nil, env(map[string]string{"AGENT_SPEECH_INFO_DENSITY": "30"}))
	if err != nil {
		t.Fatalf("render returned %v", err)
	}
	if want := "adjusted"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestPlainTextPassesThroughUnchanged(t *testing.T) {
	source := "You are a sudoer.\n\nNever grep source in a test.\n"

	got, err := render(source, nil, env(nil))
	if err != nil {
		t.Fatalf("render returned %v", err)
	}
	if got != source {
		t.Fatalf("got %q, want %q", got, source)
	}
}

func TestNoDataIsReachableThroughDot(t *testing.T) {
	if _, err := render(`{{.}}`, map[string]string{"harness": "claude"}, env(nil)); err != nil {
		t.Fatalf("render returned %v", err)
	}
	// A field access on the empty dot must fail rather than expose anything.
	if _, err := render(`{{.harness}}`, map[string]string{"harness": "claude"}, env(nil)); err == nil {
		t.Fatal("render resolved a field on the empty data value")
	}
}

func TestUndefinedFunctionIsAParseError(t *testing.T) {
	if _, err := render(`{{env "PATH"}}`, nil, env(nil)); err == nil {
		t.Fatal("render accepted an undefined function")
	}
}

func TestUnterminatedActionIsAParseError(t *testing.T) {
	if _, err := render(`density {{param "AGENT_X" "1"`, nil, env(nil)); err == nil {
		t.Fatal("render accepted an unterminated action")
	}
}
