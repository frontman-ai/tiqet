# Tiqet

Tiqet is a local-first task ledger for coding agents. It shares tasks between linked Git worktrees on one machine while your agent harness handles workers and review.

Current alpha: `0.1.0-alpha.1` for Linux x86_64.

## Requirements

- Linux x86_64 on a local filesystem
- Git 2.42+
- A trusted, non-bare Git repository
- Zig 0.16.0 only when building from source

## Install

No prerelease has been published yet. To build from source:

```sh
(cd apps/cli && zig build -Doptimize=ReleaseSafe)
install -Dm755 apps/cli/zig-out/bin/tiqet "$HOME/.local/bin/tiqet"
tiqet --version
```

After a prerelease is published, download and verify it with:

```sh
gh release download v0.1.0-alpha.1 --repo frontman-ai/tiqet
grep 'tiqet-0.1.0-alpha.1-linux-x86_64.tar.gz' SHA256SUMS | sha256sum --check
tar -xzf tiqet-0.1.0-alpha.1-linux-x86_64.tar.gz
```

## Use

`tiqet init` creates and commits `.tiqet/project.json` and updates `.gitignore`. Run it only after reviewing your working tree.

```sh
tiqet init

id=$(tiqet create --creator coordinator "Check the login flow" \
  --description "Reproduce the failure, fix it, and run the relevant tests.")

tiqet list
tiqet show "$id"
tiqet done "$id"
```

Use `--description-file PATH` for longer task briefs, or `--description-file -` to read one from stdin.

Linked worktrees automatically use the same ledger when they share the same `HOME`:

```sh
git worktree add -b worker ../project-worker
(cd ../project-worker && tiqet show "$id")
```

Local commands do not contact a remote. `tiqet sync` explicitly checkpoints and exchanges task state through `origin`.

## Agent coordination skill

The portable skill is included at [`skills/tiqet-workflow/SKILL.md`](skills/tiqet-workflow/SKILL.md). With Pi:

```sh
pi --skill /absolute/path/to/skills/tiqet-workflow/SKILL.md
```

The coordinator creates task briefs, gives workers explicit task IDs, reviews their changes, and marks accepted tasks done. Tiqet stores tasks; it does not launch agents.

## Limits

This alpha supports one repository and its linked worktrees on one machine. It does not support independent-clone collaboration, assignment, notes, subtasks, reopening, editing, MCP, or a TUI.

Task state lives outside the source checkout, so cloning the repository is not a task backup. Back up the Tiqet state directory before upgrades or recovery work.

## Development

```sh
just test
just fmt
```

Create a local archive and checksum with:

```sh
just --justfile apps/cli/justfile package /absolute/output/path preview
```

A release archive additionally requires a clean checkout and an approved root `LICENSE` file.
