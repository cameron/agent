# list source repositories and their short descriptions

## SYNOPSIS

`lab.repo [--check] [QUERY...]`

## DESCRIPTION

`lab.repo` lists every direct Git checkout below `/srv/src`. This is the fast
repository-discovery path for agents that start at the source root instead of
inside one project.

The output is tab-separated with `REPOSITORY` and `DESCRIPTION` columns. When
query text is present, it filters the repository name and description without
case sensitivity. Each whitespace-separated query word must appear somewhere
in the name or description, so `kindle alexandrias archive` finds the
repository `kindle-alexandrias-archive`. When no repository matches, the
listing holds only the header and standard error carries
`lab.repo: no repository matched: QUERY`.

The command uses the first available description from this order:

1. The first line of a tracked `.repo-description` file.
2. The first literal `description = "...";` assignment in `flake.nix`.
3. The packaged legacy catalog.

A new repository without a flake description must add this file:

```text
.repo-description
```

The first line is its short plain-language description. Keep it useful to a
person or agent that does not yet know the repository name. The file is normal
repository content and changes through the usual integration gate. Do not add
a legacy-catalog entry for a new repository.

Every invocation audits coverage. A missing description is shown as
`[description needed]` and reported on standard error. `--check` also exits with
status 1 when any description is missing. This makes the normal discovery path
the upkeep process instead of waiting for a separate periodic job.

## ENVIRONMENT

`LAB_REPO_ROOT`

: Override `/srv/src`, primarily for tests.

`LAB_REPO_CATALOG`

: Override the packaged legacy catalog, primarily for tests.

## EXIT STATUS

Status 0 means the catalog was listed. With `--check`, status 1 means at least
one repository needs a description. Status 2 means the command line is invalid.

## SEE ALSO

`agent(lab-reference)`, `src-mirror(lab-reference)`
