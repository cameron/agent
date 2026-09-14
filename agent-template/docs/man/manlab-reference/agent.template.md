# render a templated agent instruction file

Use this page to write an `AGENTS.md.tmpl` file, to find the name of a
parameter or a fact, or to find out why a template failed to render.

## Synopsis

```
agent.template [-fact NAME=VALUE]... FILE
```

## Description

`agent` renders every instruction file whose name ends in `.md.tmpl` through
this command before it adds the text to the prompt prefix. Read
`man lab-reference agent` for how instruction files are found and ordered.

The command reads `FILE`, renders it, and writes the result to standard output.
It changes nothing else. Run it directly to develop a template.

A template is Go `text/template` syntax with two functions and no data. The
usual actions are available: `{{if}}`, `{{else}}`, `{{end}}`, `{{range}}`,
`{{with}}`, `{{eq}}`, `{{printf}}`, and the `{{-` and `-}}` whitespace trims. A
file with no actions renders unchanged, so plain Markdown is a valid template.

A parse or render error is fatal. `agent` stops with status 2 and prints the
message rather than starting a harness with a damaged prompt.

## Parameters

`{{param "AGENT_NAME" "DEFAULT"}}` reads an environment variable.

The name must match `AGENT_[A-Z0-9_]+`. Any other name is an error. This is a
boundary, not a naming convention: an instruction file in any repository is
rendered into a prompt that leaves the host, so it must not be able to name an
arbitrary variable and carry a credential out with it.

An unset variable and an empty variable both give `DEFAULT`. A default is
required, so every template renders.

The command does not check the value. A parameter that expects a number renders
whatever the environment holds. Use `agent --print-instructions` to see the
result.

### AGENT_SPEECH_INFO_DENSITY

The information density of the agent's replies, as a percentage of its default,
from 1 to 100. The default is 40. Lower it further for a narrow channel such as
a phone, or raise it when you want the full explanation. The system instruction
file at `/etc/agent/AGENTS.md.tmpl` reads it.

```sh
AGENT_SPEECH_INFO_DENSITY=80 agent claude
```

## Facts

`{{fact "NAME"}}` reads one value that the launcher knows and a file cannot
state. The set is closed. An unknown name is an error, so a typo fails instead
of rendering silence into a prompt.

- `gitroot`: Nearest Git work-tree root, or empty outside a work tree.
- `harness`: `codex`, `claude`, or `pi`.
- `host`: Host name.
- `launch_dir`: Directory the agent started in.
- `parent_branch`: Branch that started the current agent worktree.
- `roles`: Selected roles, separated by spaces.
- `user`: User name.
- `worktree`: Worktree root created for the current agent, or empty.
- `worktree_branch`: Branch created for the current agent, or empty.

A fact the launcher does not supply renders as the empty string. Test for it:

```
{{if fact "worktree"}}You are in {{fact "worktree"}}.{{end}}
```

## Examples

Render the system instruction file at a low density:

```sh
AGENT_SPEECH_INFO_DENSITY=20 agent.template /etc/agent/AGENTS.md.tmpl
```

Supply a fact that only the launcher normally provides:

```sh
agent.template -fact harness=claude ./AGENTS.md.tmpl
```

## Exit status

- `0`: The file rendered.
- `1`: The file is unreadable, or the template failed to parse or render.
- `2`: The command line is wrong.

## See also

`man lab-reference agent`
