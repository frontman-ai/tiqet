---
name: tiqet-workflow
description: Use Tiqet as a shared local task ledger for multi-step implementation, long-running work, and subagent delegation. Coordinators create briefs, dispatch explicit IDs through an available harness, review results, and complete accepted tickets. Load when resuming assigned Tiqet work.
---

# Tiqet workflow

Tiqet stores flat tickets with immutable descriptions and open/completed status.
The harness runs workers and carries messages. This skill does not install a launcher.
Use Tiqet for actionable work, not a competing Markdown task list.
`creator` records attribution, not ownership.
Do not invent notes, subtasks, claims, assignments, dependencies, or extra statuses.

## Load in Pi

From the extracted Tiqet package directory, start a fresh Pi session:

```sh
pi --skill "$PWD/skills/tiqet-workflow"
```

Invoke `/skill:tiqet-workflow` in that session.
Check that startup lists `tiqet-workflow` and the command loads this skill from the expected path.
The explicit path needs no global installation or MCP server.
Pi 0.85.1 supports this method. Other harnesses require their own documented discovery and launch tools.
Pi authentication is separate from Tiqet installation.
A copied skill file alone does not prove fresh-session discovery or successful delegation.

## Check the environment

Read the project's agent instructions and affected package documentation.
Preserve existing source changes and ticket history.

```sh
SOURCE_ROOT=$(git rev-parse --show-toplevel)
TIQET=${TIQET:-$(command -v tiqet-dev || command -v tiqet)}
if [ -z "$TIQET" ]; then
    printf '%s\n' 'Tiqet is missing. Supply a stable installed binary.' >&2
    exit 1
fi
"$TIQET" --version
"$TIQET" --help
```

If neither binary exists, stop ticket operations and report the missing prerequisite.
Preserve a coordinator-supplied `TIQET` path instead of selecting another binary from PATH.
Use a stable installed binary, not a build output that another process can replace.
All workers must use the same compatible version and absolute binary path.
Do not rebuild or replace the shared binary while workers use it.
This protocol requires `create --description-file`, `show`, `list`, and `done`.
If the CLI lacks these capabilities, request a compatible version before creating tickets.
For older development binaries without help, inspect `show` on an existing ID.
Empty output alone does not prove command support.

If `.tiqet/project.json` is absent, ask before initialization unless the user already authorized it.
`init` writes source files and creates Git commits.
Do not initialize a second project in a worker directory.

```sh
"$TIQET" list
"$TIQET" show <full-task-id>
```

Replace the example ID with a relevant ID from `list`.
Read existing descriptions before decomposition to avoid duplicates.
Leave unrelated tickets alone.
Never synchronize, edit event files, or perform destructive cleanup automatically.
Local ticket operations do not need network access or `sync`.

## Coordinator: create executable briefs

For a trivial edit, work directly unless the user requests a ticket.
For substantive work, create one ticket per concrete, reviewable outcome within the authorized request.
Ask about missing scope or product decisions, not each routine ticket operation.
Discover verification commands from the actual project. Do not guess them.

Replace the example content before use:

```sh
"$TIQET" create --creator coordinator "Implement the agreed behavior" --description-file - <<'TICKET'
## Goal
State the requested outcome and why it matters.

## Context
Name relevant behavior, repository-relative paths, and decisions.
Do not assume access to the parent conversation.

## Scope
Name writable paths, allowed changes, and exclusions.

## Acceptance criteria
State observable conditions, including important edge cases.

## Verification
Give exact commands, working directories, and expected results.

## Delivery
Return the ticket ID, source path/branch, changed files, checks, and blockers.
Leave the ticket open for coordinator review. Do not launch more workers.
TICKET
```

Capture the printed ID, then read it with `show`.
IDs are full lowercase 32-character hexadecimal strings. Prefixes do not work.
Never put secrets in tickets.
Descriptions are immutable. If requirements change materially, pause the affected worker and resolve scope with the user.
Do not silently complete superseded work.

## Coordinator: assign and dispatch

Assign explicit IDs. Workers must not select arbitrary open tickets.
Keep the ID-to-worker-to-worktree mapping in session continuation context, not another task ledger.
Sequence dependent work. Dispatch in parallel only when writable scopes do not overlap.

Inspect the harness's documented launch, message, wait, and cleanup tools before dispatch.
If no launcher exists, report the limitation and offer sequential execution with the same tickets.
Do not pretend to delegate or improvise background agent processes.
Use Herdr only after an explicit user request, with `HERDR_ENV=1` and its skill loaded.

Use the project's approved source-isolation convention.
For linked Git worktrees, inspect the base and existing worktrees before creation.
Uncommitted changes do not appear in new worktrees. Do not commit or copy them without authorization.
Linked source worktrees share Tiqet state through the committed project configuration and the same host HOME.
An independent clone or a container HOME does not share this storage automatically.
Adapt build commands and container access to the project instead of copying another project's assumptions.

Give each worker this complete brief, with placeholders resolved:

```text
Role: worker, not coordinator.
Assigned ticket IDs: <explicit full IDs>
Source directory/branch: <absolute path and branch>
Stable Tiqet binary: <absolute path>
Tiqet HOME: <absolute ledger HOME, normally the shared host HOME>
Skill: <absolute path to this SKILL.md>
Writable scope: <paths and behavior>
Delivery target and Git permissions: <allowed actions and exclusions>

Read project/package instructions and this skill. Do not assume inherited context.
Run the supplied Tiqet binary from the source directory: show <each assigned ID>.
Use the supplied HOME for every Tiqet command. Do not change the harness authentication HOME.
Implement only the assigned scope. Run the ticket's verification commands.
Do not select other tickets, launch further workers, or call done.
Report progress, blockers, changed files, exact checks/results, and remaining work.
Leave every ticket open for coordinator review.
```

Supply a skill path that exists in the worker environment, or include the complete worker protocol.
Do not assume a new worktree contains an uncommitted skill.

## Worker protocol

1. Read each assigned ticket before edits. Compare it with the dispatched scope.
2. Read the current sources and callers before implementation.
3. Preserve other workers' files and all unrelated changes.
4. Report missing decisions and concrete follow-up work to the coordinator.
5. Implement and run the specified checks. Distinguish passed, failed, and unrun checks.
6. Return IDs, source path/branch, changed files, results, and blockers.
7. Leave tickets open. Do not dispatch more workers or complete other tickets.

## Coordinator: review, deliver, complete

Wait through the harness. Do not reassign until the prior worker stops or acknowledges the handoff.
Inspect actual diffs and verification evidence. A worker's completion message is not proof.
Request corrections where necessary. Check the combined result after integration.
Deliver to the agreed source location within the user's Git permissions.
A passed check does not authorize commits, merges, pushes, tags, or publication.
If delivery lacks permission, report the review result and leave the ticket open.

Only after acceptance and delivery, run:

```sh
"$TIQET" done <full-task-id>
"$TIQET" show <full-task-id>
```

Check for `Status: completed`. There is no reopen command.
Leave blocked, failed, and partial work open.
Stop only worker sessions you launched, after collecting results.
Do not delete worktrees or discard changes without authorization.

## Resume and errors

Before compaction or handoff, preserve IDs, worker handles, source paths, pending reviews, and blockers in session context.
On resume, read `list` and assigned descriptions with `show`.
Inspect existing sessions and source changes before dispatching replacements.
An open ticket does not identify an active worker or distinguish queued, failed, and blocked work.
If ownership is unknown, investigate or ask. `list` is not a claim queue.

On lock contention, wait for the known operation before retrying. Do not delete lock files or retry indefinitely.
On `EventDurabilityUnknown` or `EventPersistedOutputFailed`, inspect the ledger before retrying creation.
The event can already exist. Output transport failures can also hide a successful creation.
If the outcome remains uncertain, stop and report it instead of creating a duplicate.
Report storage failures. Do not improvise repair or edit raw history.
