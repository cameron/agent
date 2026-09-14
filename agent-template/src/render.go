package main

import (
	"fmt"
	"os"
	"os/user"
	"regexp"
	"sort"
	"strings"
	"text/template"
)

// knownFacts is the closed set of launcher facts a template may read. A fact
// the launcher does not supply renders as the empty string; a fact name that is
// not in this set is an error, so a typo fails loudly instead of rendering
// silence into a prompt.
//
// Facts marked local are computed here when the launcher does not pass them.
var knownFacts = map[string]bool{
	"gitroot":         true,
	"harness":         true,
	"host":            true, // local
	"launch_dir":      true,
	"parent_branch":   true,
	"roles":           true,
	"user":            true, // local
	"worktree":        true,
	"worktree_branch": true,
}

// paramName is the parameter surface a template may read from the environment.
// The AGENT_ prefix is a boundary, not a naming convention: an instruction file
// in any repository is rendered into a prompt that goes to a model provider, so
// it must not be able to name an arbitrary environment variable and carry a
// token out with it.
var paramName = regexp.MustCompile(`^AGENT_[A-Z0-9_]+$`)

func isKnownFact(name string) bool {
	return knownFacts[name]
}

// render executes source as a template. lookupEnv reads parameters, which the
// tests replace; facts come from the caller.
func render(source string, facts map[string]string, lookupEnv func(string) string) (string, error) {
	local := localFacts()

	funcs := template.FuncMap{
		"param": func(name string, fallback string) (string, error) {
			if !paramName.MatchString(name) {
				return "", fmt.Errorf(
					"parameter %q must match AGENT_[A-Z0-9_]+", name)
			}
			// An empty value means unset. A caller that exports
			// AGENT_X= wants the default, not an empty prompt.
			if value := lookupEnv(name); value != "" {
				return value, nil
			}
			return fallback, nil
		},
		"fact": func(name string) (string, error) {
			if !isKnownFact(name) {
				return "", fmt.Errorf("unknown fact %q, want one of %s",
					name, strings.Join(factNames(), ", "))
			}
			if value, ok := facts[name]; ok {
				return value, nil
			}
			return local[name], nil
		},
	}

	parsed, err := template.New("instructions").
		Funcs(funcs).
		Option("missingkey=error").
		Parse(source)
	if err != nil {
		return "", err
	}

	var out strings.Builder
	// No data is passed. Everything a template may read comes through the
	// two functions above, so `.` stays empty and cannot leak anything.
	if err := parsed.Execute(&out, nil); err != nil {
		return "", err
	}
	return out.String(), nil
}

func factNames() []string {
	names := make([]string, 0, len(knownFacts))
	for name := range knownFacts {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// localFacts fills in the facts the renderer can answer without the launcher.
// A failure is not an error: the fact renders empty, exactly as an unsupplied
// fact does.
func localFacts() map[string]string {
	facts := map[string]string{}
	if host, err := os.Hostname(); err == nil {
		facts["host"] = host
	}
	if current, err := user.Current(); err == nil {
		facts["user"] = current.Username
	}
	return facts
}
