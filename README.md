# agent

`agent` runs Codex, Claude, or Pi with shared instructions and a common way to
inspect their sessions. This is a reference snapshot from a personal NixOS lab,
published as material to read and adapt. The lab integration is still visible.

Three ideas drive the implementation:

- **Manual pages as skills.** Keep tool instructions in installed manual pages.
  Put a short catalog in the prompt; read a full page when the task needs it.
- **Prompt composition and roles.** Collect instructions from system, user,
  repository, and working-directory scopes through `AGENTSPATH`. Append selected
  roles with `--role`. Render `.md.tmpl` files through `agent.template`.
- **Shared transcript readers.** Parse each harness's native logs with one Python
  implementation. Reuse it for an audit index, live tails, session selection,
  and automatic titles.

The transcript index stores selected normalized events and metadata. It is a
partial audit view: assistant prose and full tool results stay in the native
logs. `tail` reads those logs directly. Sessions resume in their original
harness; this does not convert a Codex session into a Claude or Pi session.

## Where to read

| Source | What it shows |
|---|---|
| [bin/agent](bin/agent) | Instruction collection, roles, templates, and native harness arguments. Start at `collect_agent_instructions`. |
| [agent-template/src](agent-template/src) | A small Go template renderer with explicit parameters and facts. |
| [agent-transcripts/agent_transcripts.py](agent-transcripts/agent_transcripts.py) | Native transcript readers, normalized audit events, SQLite indexing, and reports. |
| [agent-transcripts/agent_sessions.py](agent-transcripts/agent_sessions.py) | Resume selection and live title watching, using the same readers. |
| [docs/man/manlab-reference/agent.md](docs/man/manlab-reference/agent.md) | The launcher interface and its operating assumptions. |
| [spec](spec) | Behavior checks with synthetic sessions and stubbed harnesses. |

Other included tools are `agent usage` for subscription limits,
`agent-process-collect` for Linux process audits, and `lab.repo` for repository
discovery. The process collector has its own NixOS module. The tmux editor
integration is in `share/emacs/agent-compose.el`.

## Try instruction composition

From this checkout, with Bash and the usual Unix command-line tools:

```sh
AGENTSPATH="$PWD/examples/instructions" ./bin/agent --print-instructions
AGENTSPATH="$PWD/examples/instructions" ./bin/agent --role reviewer --print-instructions
```

These commands print the prompt without starting a harness. The example uses
plain Markdown, so it does not need the template renderer or a Nix build.

The normal search path is `/etc/agent:~/.agent:$gitroot:.`. Each directory
contributes `AGENTS.md`, then its `AGENTS.md.d` files in lexical order. Role
files load only when selected. Duplicate scopes are read once.

The manual catalog is supplied by the host. In the lab, Bench's
`nix/modules/agent-manpages-common.nix` runs `apropos` for `lab-reference` and
`lab-guide` and writes `/etc/agent/AGENTS.md.d/50-man-pages.md`. The launcher
reads that file through the same composition path. It does not scan manual
sections itself. [The example catalog](examples/instructions/AGENTS.md.d/20-manuals.md)
shows the shape of that input; the full lab catalog is outside this repository.

## Transcripts

The transcript commands can run from source with Python 3. They do not start a
harness or load prompt instructions:

```sh
./bin/agent transcripts index
./bin/agent transcripts recent --limit 10
./bin/agent transcripts tail -n 4 codex:SESSION-ID
./bin/agent transcripts report man
./bin/agent resume --list
```

`index` reads the local harness session directories and writes a local SQLite
database. Use `--db PATH` before the subcommand and `index --session-dir DIR`
to select a separate database and source directory. See the
[transcript manual](agent-transcripts/docs/man/manlab-reference/agent-transcripts.md).

## Lab dependencies and defaults

The Nix flake retains private SSH inputs for `md2man` (manual-page builds),
`content2title` (automatic titles), and `rm4agent` (file cleanup). Building the
complete flake outside the lab requires replacing those inputs with accessible
implementations. Their URLs in `flake.nix` and `flake.lock` describe this wiring;
they do not provide public download locations. Harnesses are installed and
authenticated separately.

The launcher also carries lab policy. In Git checkouts it appends instructions
for feature branches and `git.deploy`, the lab's merge-queue command. That
instruction block needs adaptation for another publication process.

Live sessions default to full command access without approval prompts. Codex
and Claude also trust selected projects under `/srv/src`; set
`AGENT_CODEX_AUTO_TRUST_ROOT=` and `AGENT_CLAUDE_AUTO_TRUST_ROOT=` to disable
that automatic trust setup. Read the launcher manual before starting a harness
with these defaults.

`zfs.space` and `tmux.space` provide the lab's workspace lifecycle. The launcher
inherits its working directory and filesystem; ordinary directories work too.
Optional tmux helpers, Matrix integration, and process labeling use tools or
services supplied by the host. `lab.repo` defaults to `/srv/src`; set
`LAB_REPO_ROOT` for another source directory. `AGENT_MAIL_DOMAIN` sets the
session's Git author email domain; the reference default is
`agents.example.invalid`.

## Development

With the lab's Nix inputs available:

- `make build` builds the launcher package and its bundled helpers.
- `make check` evaluates the flake and builds its checks, including the Go and
  Python tests, native sandbox specs, and Linux process-collection microVM test.
- `make test` runs the same checks as the repository's merge gate.

Check outputs stay rooted under `${XDG_STATE_HOME:-~/.local/state}/agent/checks`.
The source is provided under the [MIT license](LICENSE).
