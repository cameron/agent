// Command agent.template renders one templated agent instruction file.
//
// The `agent` launcher calls it for every AGENTS.md.tmpl and
// AGENTS.md.d/*.md.tmpl file it finds on AGENTSPATH. The rendered text becomes
// part of the prompt prefix, so the template surface is deliberately closed:
// a template reads AGENT_-prefixed parameters and a fixed set of launcher
// facts, and nothing else.
package main

import (
	"fmt"
	"io"
	"os"
	"strings"
)

const usage = "usage: agent.template [-fact NAME=VALUE]... FILE"

type options struct {
	path  string
	facts map[string]string
}

func main() {
	opts, err := parseArgs(os.Args[1:])
	if err != nil {
		fmt.Fprintf(os.Stderr, "agent.template: %v\n%s\n", err, usage)
		os.Exit(2)
	}
	if err := run(opts, os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "agent.template: %v\n", err)
		os.Exit(1)
	}
}

// parseArgs reads repeated -fact flags followed by exactly one file operand.
// It does not use the flag package: repeated flags need a collecting value,
// and the argument grammar is small enough to read directly.
func parseArgs(args []string) (options, error) {
	opts := options{facts: map[string]string{}}
	rest := args

flags:
	for len(rest) > 0 {
		arg := rest[0]
		assignment := ""
		switch {
		case arg == "-fact" || arg == "--fact":
			if len(rest) < 2 {
				return options{}, fmt.Errorf("%s requires NAME=VALUE", arg)
			}
			assignment = rest[1]
			rest = rest[2:]
		case strings.HasPrefix(arg, "-fact="), strings.HasPrefix(arg, "--fact="):
			_, assignment, _ = strings.Cut(arg, "=")
			rest = rest[1:]
		case arg == "--":
			rest = rest[1:]
			break flags
		case strings.HasPrefix(arg, "-") && arg != "-":
			return options{}, fmt.Errorf("unknown option %q", arg)
		default:
			break flags
		}

		name, value, found := strings.Cut(assignment, "=")
		if !found || name == "" {
			return options{}, fmt.Errorf("malformed fact %q, want NAME=VALUE", assignment)
		}
		if !isKnownFact(name) {
			return options{}, fmt.Errorf("unknown fact %q", name)
		}
		opts.facts[name] = value
	}

	if len(rest) != 1 {
		return options{}, fmt.Errorf("want exactly one file operand, got %d", len(rest))
	}
	opts.path = rest[0]
	return opts, nil
}

func run(opts options, out io.Writer) error {
	source, err := os.ReadFile(opts.path)
	if err != nil {
		return err
	}

	rendered, err := render(string(source), opts.facts, os.Getenv)
	if err != nil {
		return fmt.Errorf("%s: %w", opts.path, err)
	}

	_, err = io.WriteString(out, rendered)
	return err
}
