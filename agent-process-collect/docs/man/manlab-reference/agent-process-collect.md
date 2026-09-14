# collect process records for agent audits

## SYNOPSIS

`agent-process-collect status`

`agent-process-collect report [--days N]`

`agent-process-collect sessions [--since TIME] [--until TIME] [--json]`

`agent-process-collect lastcomm [--days N] [-- LASTCOMM-OPTION ...]`

`agent-process-collect sa [--days N] [-- SA-OPTION ...]`

`agent-process-collect execs [--days N] [-- AUSEARCH-OPTION ...]`

## DESCRIPTION

`agent-process-collect` operates the root-only process records that Bench keeps
for later agent-behavior analysis. The collector does not make tool-use or
behavior recommendations.

The Audit dispatcher writes a compact SQLite index while it receives events.
The index contains one row for each agent launch and daily counters for
executable basenames. Normal session and report queries read this index. They
do not copy or replay the retained Audit logs.

BSD process accounting records every completed process on the host. These
records include the command name, PID and parent PID, user, start and elapsed
time, CPU, memory, I/O, and exit flags. The Linux Audit system records
`execve` and `execveat` arguments for process trees started by the standard
`agent` command.

The accounting data is local to one kernel. An SSH client is visible as a
local process, but a command that it starts on another host is not part of the
local process tree.

## COMMANDS

`status`

: Show the accounting and Audit service state, loaded collection rules, lost
  event count, index heartbeat, current file sizes, archive age, and retained
  degraded launches. Status 1 means that collection is not healthy.

`report`

: Write a safe Markdown summary for the selected number of days. It includes
  collection health, launch and exec counts, harness counts, and executable
  basenames. Exec counts use compact UTC-day counters. It does not include argv
  values. The compact index query has a 60-second default timeout. A timeout
  writes a clear report error and returns status 1.

`sessions`

: List standard agent launches. `--json` writes one JSON object per line.
  `--since` and `--until` accept ISO 8601 values. Times without an offset are
  UTC. This command reads only the compact launch index.

`lastcomm`

: Run `lastcomm --pid` over the selected managed accounting records. The
  default is all retained records. `--days` selects from 1 through the
  configured retention period.

`sa`

: Run `sa -i` over the selected managed accounting records. This command does
  not change `savacct` or `usracct`.

`execs`

: Run `ausearch` over each selected Audit record with the `agent_exec` key.
  Results start without first making a combined temporary copy.

Input-file and Audit-key options are not accepted. This prevents a native view
from silently using a file outside the managed record set.

## SESSION RECORDS

Each JSON line from `sessions --json` has these fields:

`schema_version`

: The record schema. The current value is 1.

`host`, `boot_id`, `started_at`, `root_pid`

: The host and boot identity, UTC launch time, and root process ID of the
  labeled tree.

`uid`, `gid`, `original_auid`, `audit_auid`

: The real user and group IDs, the inherited Audit login ID, and the Audit
  login ID after the labeling attempt.

`label_status`

: `labeled` when argv capture was enabled or `degraded` when labeling failed.

`cwd`, `harness`, `launcher_argv`

: The launch directory, selected harness, and complete argument vector. The
  last two values are null if no matching Audit exec record was available.

## FILES

Current process accounting records are in
`/var/log/agent-process-collect/pacct/current`. Current Audit records are in
`/var/log/agent-process-collect/audit/current`. Each directory has an
`archive` directory. All directories are mode 0700 and all data files are mode
0600 with root ownership.

The compact index is
`/var/log/agent-process-collect/index/process.sqlite3`. Auditd updates it
through the `agent_process_index` dispatcher plugin. Before the plugin starts
for the first time, `agent-process-index-bootstrap.service` builds the index
from retained raw records. Raw records remain the source for detailed
investigations and for index recovery.

Files rotate each day and remain uncompressed so that the native accounting
tools can read them. The default retention period is 30 complete UTC days plus
the current files. Rotation also removes expired rows from the compact index.

## SECURITY

Audit records contain complete command argument vectors. An argument can
contain a password, token, prompt, or other sensitive value. Only root can read
the records or run the report commands.

The reserved Audit login ID labels agent descendants. It does not change the
real or effective process user. A label failure produces a warning and the
agent continues with BSD process accounting only.

## EXIT STATUS

Status 0 means success. Status 1 means unhealthy collection or an operational
failure. Status 2 means that command options were not valid.

## SEE ALSO

`agent(lab-reference)`, `accton(8)`, `lastcomm(1)`, `sa(8)`, `auditctl(8)`,
`ausearch(8)`
