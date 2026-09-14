# run an agent

## SYNOPSIS

`agent [--no-update] [--role NAME]... [codex|claude|pi] [arguments]`

`agent [--role NAME]... -- [native arguments]`

`agent [--no-update] [--role NAME]... [codex|claude|pi] --print-instructions`

`agent resume [ID|HARNESS:ID]`

`agent resume [--all] [--list] [--limit N]`

`agent usage [--diagnose]`

`agent transcripts [arguments]`

`agent send [DRAFT-FILE]`

`agent --here --harnesh-turn [--session HARNESS:NATIVE-ID]`

## DESCRIPTION

A thin harness wrapper to standardize behavior across claude, codex, pi, etc.

Use `--` after wrapper options to select the harness through `AGENT_BIN`
and pass the remaining arguments as native harness arguments. For example,
`AGENT_BIN=codex agent --role kanban-author -- resume ID` resumes Codex
directly; it does not invoke the cross-harness `agent resume` picker.
`AGENT_MODEL` still supplies the model default. Roles select instructions
independently of the harness and model.

The workspace belongs to `tmux.space(lab-reference)` and
`zfs.space(lab-reference)`. Agents inherit the filesystem from their shell;
the harness does not manage ZFS datasets or mount namespaces.

`agent` sets `SHELL` to the Bash executable that runs the wrapper. This applies
to all harness and helper invocations, even when the account login shell is
fish.

`agent` runs every invocation in place: it creates no worktree, no branch,
and no checkout of its own. `tmux.space` starts sessions inside durable
filesystem spaces. Several agents in one space share its checkouts. The
retired `--here` and `--no-worktree` flags are still accepted and do
nothing.

When it starts inside a Git checkout, `agent` exports `GIT_AUTHOR_NAME` and
`GIT_AUTHOR_EMAIL` for the session. The author is
`HARNESS SLUG <HARNESS.SLUG@agents.example.invalid>`, for example
`codex 20260822-160305-2411`. The slug names the session artifacts, so a
reader can trace any commit to the session that produced it, for example
with `vfind SLUG`. The committer identity remains the configured Git user.
Set `AGENT_MAIL_DOMAIN` to use your own author email domain.

The injected agent instructions separate development from deployment. Before
changing tracked files, development leaves `main` and uses an ordinary,
descriptively named feature branch. Focused commits and feature-branch pushes
can continue throughout the work cycle. A branch push provides backup or
collaboration; it does not request deployment.

After all requested work in the current cycle is complete, focused tests pass,
and the result is ready for `main` and its production path, run the deployment
command once:

```text
git.deploy -m 'MESSAGE'
```

`git.deploy` stages and commits all remaining nonignored changes with
`MESSAGE` as the commit subject, submits the original branch and remote
`main` to the speculative merge queue, runs `make test` on the assigned merge,
and pushes the exact tested commit to `main`. Do not deploy intermediate units
or deploy only to save work. See
`git.deploy(lab-reference)`.

A failed test stops the command and returns to the feature branch. Correct the
failure there and retry only when the complete cycle is ready again. The
harness exit status does not start, permit, or prevent a deployment: work
pushed earlier stays published even if the harness later fails, and unpushed
work remains in the checkout. Spaces persist until explicitly destroyed.

In particular, `agent` builds an AGENTS.md prompt prefix from files found on
`AGENTSPATH`. The default path is:

```text
/etc/agent:~/.agent:$gitroot:.
```



In each directory, `agent` reads `AGENTS.md` first, followed by the files in
`AGENTS.md.d` (lexical order).

Read errors are suppressed, so you can temporarily disable a file by removing its read
permission with chmod.

The literal `$gitroot` value in AGENTSPATH expands to the nearest Git work-tree root. The
entry is skipped when the current directory is not in a Git work tree.
Duplicate directory scopes are read one time. Thus, the Git-root instructions
are not read two times when the current directory is the Git root.

An instruction file whose name ends in `.md.tmpl` is a template. `agent` renders
it with `agent.template` before it adds the text to the prompt prefix. Use
`AGENTS.md.tmpl`, `AGENTS.md.d/NN-name.md.tmpl`, or
`AGENTS.md.d/role-NAME.md.tmpl`. A file that ends in `.md` is never rendered.

A template reads two things: `{{param "AGENT_NAME" "DEFAULT"}}` for an
`AGENT_`-prefixed environment variable, and `{{fact "NAME"}}` for a value that
this launcher supplies, such as the selected harness or the current worktree.
Read `man lab-reference agent.template` for the complete surface.

One instruction file exists as Markdown or as a template, not both. `AGENTS.md`
and `AGENTS.md.tmpl` in the same directory is an error.

A template that fails to render stops the launcher with status 2. A harness
does not start with a damaged prompt prefix. An unreadable template stays
silently disabled, as an unreadable Markdown file does.

The system instruction file `/etc/agent/AGENTS.md.tmpl` reads
`AGENT_SPEECH_INFO_DENSITY`, the percentage of the agent's default reply
information density. The default is 40. Lower it further for a narrow channel,
or raise it when you want the full explanation:

```sh
AGENT_SPEECH_INFO_DENSITY=80 agent claude
```

Files named `AGENTS.md.d/role-NAME.md` are opt-in role instructions. They do
not load during normal instruction collection. Use `--role NAME` before the
harness selector to append a role after all normal instructions:

```sh
agent --role mobile codex
```

Role files can exist in each `AGENTSPATH` scope. A selected role loads from
general to specific scope. Specify `--role` more than one time to compose
roles in command-line order. An invalid or unknown role is an error.

Use `--print-instructions` to print the concatenated instructions without
starting an agent.

`--harnesh-turn` is the non-interactive integration protocol for Harnesh. It
reads one prompt from standard input and writes one JSON response with
`harness`, `session_id`, `kind`, `answer`, and `command` fields. On a new
session, `AGENT_BIN` selects Codex, Claude, or Pi. The returned session ID is
opaque to Harnesh and includes the selected harness. Pass that complete value
to `--session` for later turns. A resumed session keeps its original harness,
even if the default `AGENT_BIN` has changed.

The protocol translates its common request to each harness's native
non-interactive and session-resume interface. Codex and Claude use their native
structured-output validation. Pi uses its JSON event stream and durable Pi
session. Pi model and provider selection remains normal `agent` configuration;
for example, a local Ollama-backed model continues to come from Pi's
`models.json` and `AGENT_PI_FLAGS`.

By default, every harness runs without permission prompts. Codex uses the
`danger-full-access` sandbox and the `never` approval policy. Claude uses
`--dangerously-skip-permissions`. Pi has no approval or sandbox layer; its
built-in tools run directly. Use these defaults only in a trusted environment.
Explicit Codex sandbox or approval arguments replace the Codex defaults. An
explicit Claude `--permission-mode` replaces the Claude default. Pi tool
restrictions, such as `--no-tools`, pass through `AGENT_PI_FLAGS`.

When `agent` starts Codex in a directory at or below `/srv/src`, it writes an
exact trusted-project entry to the user Codex configuration before it starts
the session. In a Git checkout, it trusts the checkout root. Otherwise, it
trusts the selected working directory. Codex project trust does not apply
recursively from a parent path. This behavior also applies when `-C` or `--cd`
selects the working directory. Setting `AGENT_CODEX_AUTO_TRUST_ROOT` to an
empty value disables the behavior.

When `agent` starts interactively in tmux and `tmux.agent-pane-center` is on
the PATH, it asks that helper to center the pane at about half the window
width between inert spacer panes; the spacers yield to any other pane and
return when the agent is alone again. Disable it globally with
`tmux.agent-pane-center off`, or for one invocation with
`TMUX_AGENT_PANE_CENTER=0`. See tmux.agent-pane-center(lab-reference).

When `agent` starts in tmux, the window and session can keep a generic name
until the first eligible user message reaches the Codex, Claude, or Pi
transcript. The watcher then calls `content2title` immediately. One model result
names the window and the session. The session form is a short slug. An explicit
repository scope adds the short repository prefix; a cross-repository session
does not infer one. Harness metadata, local-command wrappers, tool results, and
sidechain messages do not qualify as user prompts. A manual rename prevents an
automatic rename at that scope.

The watcher binds a resumed session to its native session ID. New Claude
sessions also receive an ID before launch. For Codex, the watcher can read the
session ID from the native process writer lock. Without an exact ID, only a
transcript created after the watcher starts is eligible, and only when one
live watcher matches the harness and working directory. A transcript that
already existed is never assigned to a new launch. If ownership is ambiguous,
the watcher does not rename the window or reuse a saved sidecar.

The Python watcher shares transcript readers with `agent transcripts`. It reads
identity only from the small transcript header. Once it binds a transcript,
it watches only that file. It tracks append positions by byte size, keeps an
incomplete final record for the next read, and reads only new complete records
while it waits for the first eligible user message. Saved titles for a known
session can be reused before the next transcript write.

Durable interactive sessions also show the native session ID in each
harness's existing chrome, so it can be copied without consuming another
terminal row. Codex adds `thread-id` to its footer. An unset footer keeps the
complete Codex default (`model-with-reasoning`, `context-remaining`, and
`current-dir`) before the ID. A configured footer keeps its ordered items and
adds the ID only when absent; an explicitly disabled or empty footer becomes
ID-only for sessions launched through `agent`. User and project configuration,
`AGENT_CODEX_FLAGS`, and command-line `-c`/`--config` values retain their normal
precedence for every other key.

Claude uses its prompt-box session name. A new session gets a launcher-assigned
UUID; an exact UUID supplied through `--session-id` or `-r`/`--resume` uses that
UUID. A caller name is rendered as `NAME · UUID`. Claude selectors whose
result is not known before launch are deliberately left alone: a bare resume
picker, a non-UUID resume search, every `--from-pr` form, `--continue`,
`--fork-session`, or conflicting identity selectors. The launcher never shows
a search term or parent ID as though it identified the running session.

Pi loads a small extension for persistent interactive sessions and composes
the ID into the existing session-name footer field as `NAME · ID`. Reloading or
resuming an already composed session writes no new metadata. A fork replaces
only a suffix equal to the verified parent session ID, so an unrelated
UUID-looking user label is preserved. A later native rename is an explicit
display override until the next session lifecycle start.

The display behavior excludes non-interactive print/JSON/RPC commands, Pi
`--no-session`, and the unknown-ID Claude selectors above because those runs
do not expose a deterministic durable ID at launch.

By default, `agent` specifies the `codex` provider and `gpt-5.6-luna` model to
`content2title`. The provider runs an ephemeral authenticated Codex request,
ignores user and project instructions, uses a read-only sandbox, and disables
reasoning. The complete attempt has a 30-second budget and receives no more
than the first 800 characters. `AGENT_TITLE_PROVIDER` and `AGENT_TITLE_MODEL`
change the specification. Selecting `pi` without a model retains
`content2title`'s local title-model default. `CONTENT2TITLE_TIMEOUT_SECONDS`
changes the budget.

If the model is unavailable, times out, or returns invalid output,
`content2title` derives one deterministic title from the request. This is the
final result; the watcher does not make a later refinement call. A successful
model or fallback title is saved in the transcript sidecar. A resumed session
reapplies that sidecar without a model call.

The CLI also writes the generated title as one UTF-8 line in
`<session-file>.title`. For example, the title for `rollout.jsonl` is in
`rollout.jsonl.title`. This sidecar is common agent metadata. It does not depend
on the Codex, Claude, or Pi session JSON format. Consumers must ignore a
missing or invalid sidecar. `agent transcripts annotate` writes the same
sidecar for sessions the watcher never titled, plus a one-sentence
`<session-file>.desc` sidecar; `agent resume` shows both. See
agent-transcripts(lab-reference).

When the tmux session has a `TMUX_WORKSPACE` directory, the same watcher also
registers the interactive agent in
`$TMUX_WORKSPACE/.tmux.workspace-resume.json`. The record includes the harness,
durable session ID, session file, working directory, window title, and window
order. A normal pane exit removes the record. Loss of the complete tmux session
keeps it for the next `tmux.workspace-start`, which resumes saved agents by
default.

## USAGE

`agent usage` prints the current subscription-limit utilization as one compact
line for tmux status bars and similar consumers:

```text
fable: 6% (3d6h) claude: 5% (4h12m) codex: 17% (2d)
```

Each value is the highest percentage among the applicable current windows.
The parenthesized duration is the time left until that window resets. Durations
use minutes below one hour, hours and minutes below one day, and days and hours
after that.
For Claude, the unscoped session and weekly-all windows become `claude`, while
a model-scoped weekly window uses its lowercase display name, such as
`fable`. Codex uses the highest unexpired primary or secondary window from the
newest local telemetry whose limit ID is exactly `codex`; separate model limits
are not included. The reset duration belongs to the same window as the shown
percentage. Percentages are rounded to whole numbers.

Claude utilization comes from Claude Code's own `/usage` command and its
`cachedUsageUtilization` snapshot in `${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json`.
The helper does not read credentials or make direct HTTP requests. Claude Code
owns login refresh and token rotation. The command runs in print mode with
zero model turns, no tools, no hooks, no MCP servers, and no saved session.
This path is verified with Claude Code 2.1.263.

One lock protects all usage readers. A native refresh has a 30-second timeout.
Fresh native snapshots are reused, including model-scoped limits such as Fable.
Normalized labels, percentages, and reset timestamps are cached atomically in
`${XDG_CACHE_HOME:-$HOME/.cache}/agent/usage-claude.json` for 15 minutes.
Failed refreshes back off from 15 minutes to at most one hour. Repeated reads
do not extend that delay or start duplicate Claude processes. A valid empty
response clears prior limits. An account change clears the prior account's cache.

On failure, valid cached percentages remain visible. When their periods end,
known Claude labels show `unavailable` until a successful refresh. They do not
disappear or show an old percentage as current. `agent usage --diagnose` reports
the native source, cache labels, last error, and retry time without starting
Claude or reading credentials.

Codex utilization comes from recent JSONL files below
`${CODEX_HOME:-$HOME/.codex}` and is read on every invocation. The scan is
limited to files modified in the last eight days and bounded by both file count
and bytes per file. An incomplete live JSONL line is ignored without hiding an
older complete rate-limit event.

Providers with no recorded data are omitted independently. The command succeeds
when it can print at least one value or a known unavailable label. Otherwise it
reports that no session-limit usage is available. `AGENT_USAGE_CACHE_SECONDS`
changes the Claude cache lifetime; `0` refreshes on each invocation but still
respects failure backoff. `AGENT_CLAUDE_BIN` selects the native Claude executable.

## TRANSCRIPTS

`agent transcripts` exposes the bundled Python transcript index and readers.
Use `agent transcripts --help` or `man lab-reference agent-transcripts` for
indexing, live tails, session annotations, and audit reports. These commands
run before prompt collection, process labeling, and terminal setup.

`agent-transcripts` remains a compatibility command. `AGENT_TRANSCRIPTS_BIN`
overrides the transcript command used by both `agent transcripts` and
`agent resume`.

## RESUME

`agent resume` reopens a recorded session of any harness. It refreshes the
agent-transcripts(lab-reference) index, lists the recent sessions of the
current repository — newest first, each with its time, harness, title, and
one-sentence description — and opens the chosen one in `fzf`. The chosen
session restarts through this launcher, retaining any selected `--role` values,
with its own harness, in its own
working directory: `codex resume ID`, `claude --resume ID`, or
`pi --session ID`.

With a native ID, `agent resume ID` skips the picker, searches the complete
index across repositories, restores the recorded working directory, and uses
the recorded harness. `agent resume HARNESS:ID` restricts lookup to `codex`,
`claude`, or `pi`; use it if the same opaque ID exists under more than one
harness. Missing and ambiguous IDs fail without starting a harness. Direct-ID
lookup collapses duplicate transcript copies for the same harness and native
session, and ignores non-resumable child-agent transcripts. It cannot be
combined with the picker options.

`--all` widens the list to every repository. `--limit N` caps the list
(default 30). `--list` prints the table and exits; the same happens when
`fzf` or a terminal is absent. The titles and descriptions come from the
sidecar files that the window titler and `agent transcripts annotate`
maintain; run `annotate` to fill the gaps for sessions that never got a
title. `AGENT_TRANSCRIPTS_BIN` overrides the indexer executable.

Use `pi` to select the Pi harness. Arguments after the selector pass to Pi
without translation, except that `-m NAME` expands to `--model NAME`:

```sh
agent pi -m qwen3.6-27b
```

For `-m`, `agent` resolves an unqualified name against the local provider.
An exact model ID wins. Otherwise, one partial match is accepted and multiple
matches produce an error with the candidate list. Thus, `-m qwen3.6-27b`
selects the local model without requiring the `local/` provider prefix.
Provider-qualified values pass through unchanged. The long form remains
identical to Pi:

```sh
agent pi --model qwen3.6-27b
```

Prefix a benchmark configuration key with `@` to resolve its explicitly
cataloged Pi model:

```sh
agent pi -m @q365d
```

`agent` calls `local-ai-bench --pi-model CONFIGURATION`, then resolves the
returned model against the local provider. The configuration must have a
cataloged Pi model mapping and that model must be present in Pi's model list.

For this selector, `agent` passes the concatenated instructions to Pi with
`--append-system-prompt`. It also passes `--no-context-files`, which makes
`AGENTSPATH` the authoritative source of project instructions. Pass
`--offline` explicitly when required.

## COMPOSE PANE

With `AGENT_COMPOSE` set, an interactive launch in a tmux window that holds no
other pane also opens a sidecar column on the right: the editor on the
session's `.agent-compose-send` scratch file in the top half, and a plain
shell below it. Read the agent's
output in the agent pane; take notes and compose replies in the editor;
deliver a reply with `agent send`; use the shell for quick checks beside the
conversation. The focus stays on the agent pane at launch.

`AGENT_COMPOSE` values: `0`, `false`, or empty disable the feature. `1` or
`true` enable it with `$EDITOR` (falling back to `vi`). Any other value is
itself the editor command line, so `AGENT_COMPOSE='emacsclient -t'` works
while `$EDITOR` stays something else.

Spacer panes from `tmux.agent-pane-center(lab-reference)` do not count as
company. The split lands before pane centering runs, so centering yields to
the editor pane by its own rules and still marks the agent pane. Closing the
editor pane and relaunching `agent` in the again-lone window reopens the
same draft.

The editor process starts only after the shell split has established the final
sidecar layout. In a detached session that still has tmux's default placeholder
size, it also waits for a client or an explicit window resize. A terminal
editor therefore receives the useful pane size when it starts.

The draft is `.agent-compose-send` in the tmux session's working directory,
so it stays with the workspace and survives editor restarts. Both sidecar
panes also start in that directory, even when the agent was launched from a
different directory. The editor runs through `isolate-exec`, and the shell
joins through its space entry hook, so both see
the same private source trees as the agent. The global Git ignore excludes
the scratch file.

`agent send [DRAFT-FILE]` delivers the draft to the agent pane. The payload
is the text below the last marker line, where a marker is a line of three or
more dashes. A draft without a marker is sent whole. Text above the last
marker never leaves the file — keep notes there, or start a fresh reply by
adding a new marker under the previous one. A payload of only blank lines is
refused.

Without `DRAFT-FILE`, `send` reads the draft path from the `@agent_compose_draft`
option of the invoking pane; the launch stores it, with the agent pane id in
`@agent_compose_target`, on both sidecar panes, so `agent send` also works
from the shell. A pane without a stored target falls back to the unique pane
in the window marked `@agent_center_role agent`.
Delivery loads the payload into a uniquely named tmux buffer, pastes it into
the agent pane (bracketed paste keeps embedded newlines from submitting
early), waits `AGENT_COMPOSE_SETTLE_SECONDS`, and submits once with an
unmodified `Enter`.
Delivery is fire-and-forget; if pastes ever race harness startup, the
hardening path is a capture-pane composer check before the submit.

The Emacs integration binds `M-Enter` only in agent compose drafts, so the
binding takes priority over Markdown mode without changing other Markdown
buffers. On success it clears and saves the draft buffer. The package ships
the Emacs side at `share/agent/emacs/agent-compose.el` (on NixOS:
`/run/current-system/sw/share/agent/emacs/agent-compose.el`), so the function
always matches the installed `agent send`. Your configuration only loads it:

```elisp
(let ((agent-compose "/run/current-system/sw/share/agent/emacs/agent-compose.el"))
  (when (file-exists-p agent-compose)
    (load agent-compose)))
```

vim:

```vim
function! AgentSend() abort
  write
  let out = system('agent send ' .. shellescape(expand('%:p')))
  if v:shell_error
    echomsg out
  else
    silent %delete _
    write
    normal! gg
  endif
endfunction
nnoremap <C-CR> :call AgentSend()<CR>
```

Tmux reports `M-Enter` to a terminal editor as the standard Meta prefix plus
Enter. It does not require extended-key reporting to applications.

## ENVIRONMENT

- `AGENTSPATH`: Colon-separated instruction directories.

- `AGENT_BIN`: Default agent. Supported values are `codex`, `claude`, and `pi`.
- `AGENT_MODEL`: Default native model ID for the selected harness, passed as
  `--model`. Unset or empty leaves the harness configuration in control.
  Explicit model options in the command line or `AGENT_CODEX_FLAGS`,
  `AGENT_CLAUDE_FLAGS`, or `AGENT_PI_FLAGS` take precedence. Codex `-c model=...`
  also takes precedence. This applies to new and resumed sessions. For Pi,
  use its native model ID; local partial-name lookup remains an explicit `-m`
  feature.

- `AGENT_HARNESS`: Harness that this invocation resolved to. `agent` exports it
  for the harness and everything it runs. `AGENT_BIN` selects a default;
  `AGENT_HARNESS` reports the answer.

- `AGENT_COMPOSE`: Compose pane switch and, beyond `1`/`true`, its editor
  command line. See COMPOSE PANE.

- `AGENT_COMPOSE_SETTLE_SECONDS`: Delay between the paste and the submitting
  `Enter` in `agent send`. The default is 0.25.

- `AGENT_USAGE_CACHE_SECONDS`: Lifetime in seconds of normalized Claude usage
  data and the initial failure backoff. The default is 900; `0` refreshes on
  each invocation while retaining failure backoff (at least 60 seconds).
- `AGENT_CLAUDE_BIN`: Native Claude Code executable used for `/usage`.
  Defaults to `claude` from PATH.

- `AGENT_TITLE_PROVIDER`: Provider specified to `content2title` for automatic
  titles. The default is `codex`; `pi` selects the local provider.

- `AGENT_TITLE_MODEL`: Model specified to `content2title`. With the default
  `codex` provider, the default is `gpt-5.6-luna`. With another provider, an
  unset value leaves model selection to `content2title`.

- `AGENT_SPEECH_INFO_DENSITY`: Information density of the agent's replies, as a
  percentage of its default, from 1 to 100. The default is 40. The system
  instruction template reads it.

- `AGENT_TEMPLATE_BIN`: Command that renders `.md.tmpl` instruction files. The
  default is `agent.template`. Set it to test a local build.

- `AGENT_WORKTREE_MODE`, `AGENT_WORKTREE`, `AGENT_WORKTREE_BRANCH`,
  `AGENT_PARENT_WORKTREE`, `AGENT_PARENT_BRANCH`, `AGENT_PARENT_UPSTREAM`,
  `AGENT_PARENT_PUSH`: Retired managed-worktree variables. The launcher
  ignores them and clears any that arrive from an old environment.

- `AGENT_CODEX_FLAGS`: Additional Codex arguments. Explicit sandbox and
  approval arguments override the launcher defaults. For durable interactive
  sessions, an effective `tui.status_line` is preserved but always includes
  `thread-id`.

- `AGENT_CODEX_SANDBOX`: Default Codex sandbox for interactive sessions,
  resumed sessions, and non-interactive runs. The default is
  `danger-full-access`. `AGENT_EXEC_SANDBOX` remains a compatibility alias.

- `AGENT_CODEX_APPROVAL`: Default Codex approval policy for interactive
  sessions, resumed sessions, and non-interactive runs. The default is
  `never`.

- `AGENT_CODEX_AUTO_TRUST_ROOT`: Directory below which `agent` automatically
  trusts Codex project roots. The default is `/srv/src`. Set it to an empty
  value to disable this behavior.

- `AGENT_CLAUDE_FLAGS`: Additional Claude arguments. An explicit
  `--permission-mode` or `--dangerously-skip-permissions` value replaces the
  launcher's Claude permission default. A launch-time `--name` is composed with
  a deterministically known native UUID.

- `AGENT_PI_FLAGS`: Additional Pi arguments for the `pi` selector. Pi has no
  separate approval policy; use tool flags here when a run must be restricted.
  Persistent interactive launches load the packaged session-ID name extension;
  `--no-session` and non-interactive modes do not.

- `AGENT_PI_CONFIG_RESOLVER`: Command used to map an `@CONFIGURATION` value to
  a Pi model identifier. The default is `local-ai-bench`.

- `AGENT_PI_PROVIDER`: Provider used to resolve unqualified `-m` values.
  The default is `local`.
