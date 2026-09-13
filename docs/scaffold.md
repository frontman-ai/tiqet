# Tiqet Monorepo Scaffold

## Objective

Create a structure-only polyglot monorepo foundation. The initial repository
contains one independently consumable Zig core library and one Zig application
that will later expose CLI, TUI, and MCP modes.

## Tech Stack

- Latest Zig master nightly for current packages.
- just 1.57.0 for language-neutral task delegation.

## Commands

- `mise install`: install all repository development tools.
- `just build`: delegate builds to every current workspace.
- `just test`: delegate tests to every current workspace.
- `just fmt`: delegate formatting to every current workspace.

## Project Structure

```text
apps/cli/       Zig application; future CLI, TUI, and MCP entry point
libs/core/      Independently consumable Zig library
docs/           Project specifications and decisions
justfile        Root task delegation only
mise.toml       Pinned repository development tools
```

Each workspace owns its build configuration and `justfile`. Root recipes must
not contain language-specific build logic.

## Code Style

Use `zig fmt` and direct, minimal Zig modules.

```zig
const std = @import("std");

pub const name = "tiqet";

test "exports project name" {
    try std.testing.expectEqualStrings("tiqet", name);
}
```

## Testing Strategy

- Keep unit tests beside Zig source.
- `libs/core` tests its public module through `zig build test`.
- `apps/cli` tests its root module through `zig build test`.
- Root `just test` must execute both workspace test recipes.

## Boundaries

- Always: keep workspaces independently buildable and root recipes delegated.
- Ask first: add dependencies, workspaces, package managers, or root tooling.
- Never: add task, event, storage, synchronization, CLI, TUI, or MCP behavior as
  part of this scaffold.

## Success Criteria

- `just build`, `just test`, and `just fmt` succeed from repository root.
- `mise install` provides the latest Zig master nightly and just 1.57.0.
- `cd libs/core && just build` succeeds independently.
- `apps/cli` consumes `libs/core` through an explicit local Zig package
  dependency.
- No Tiqet product behavior is implemented.

## Implementation Plan

1. Add buildable and testable `libs/core` package.
2. Add buildable and testable `apps/cli` package with local core dependency.
3. Add workspace and root `justfile` delegation.
4. Run all root recipes and inspect repository diff.

## Open Questions

None for initial scaffold.
