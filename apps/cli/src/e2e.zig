const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 2 and arguments.len != 3) return error.MissingCliPath;
    if (arguments.len == 3 and !std.mem.eql(u8, arguments[2], "--scale")) return error.UnexpectedArgument;

    var cli_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cli_path_length = try std.Io.Dir.cwd().realPathFile(
        init.io,
        arguments[1],
        &cli_path_buffer,
    );
    const cli_path = cli_path_buffer[0..cli_path_length];

    var random_bytes: [12]u8 = undefined;
    init.io.random(&random_bytes);
    var repository_name: [std.base64.url_safe.Encoder.calcSize(random_bytes.len)]u8 = undefined;
    _ = std.base64.url_safe.Encoder.encode(&repository_name, &random_bytes);

    const cache = try std.Io.Dir.cwd().createDirPathOpen(init.io, ".zig-cache/e2e", .{});
    defer cache.close(init.io);
    const repository = try cache.createDirPathOpen(init.io, &repository_name, .{});
    defer cache.deleteTree(init.io, &repository_name) catch {};
    defer repository.close(init.io);

    var home_name_buffer: [64]u8 = undefined;
    var home_name_writer = std.Io.Writer.fixed(&home_name_buffer);
    try home_name_writer.print("{s}-home", .{repository_name});
    const home_name = home_name_writer.buffered();
    const home = try cache.createDirPathOpen(init.io, home_name, .{});
    defer cache.deleteTree(init.io, home_name) catch {};
    defer home.close(init.io);

    var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home_length = try home.realPath(init.io, &home_buffer);
    var environment = std.process.Environ.Map.init(init.gpa);
    defer environment.deinit();
    try environment.put("GIT_CONFIG_NOSYSTEM", "1");
    try environment.put("HOME", home_buffer[0..home_length]);
    if (arguments.len == 3) {
        try scale_e2e(init, &environment, repository, cli_path);
        return;
    }

    try usage_e2e(init, &environment, repository, cli_path);
    try expect(init, &environment, repository, &.{ cli_path, "--version" }, 0, "tiqet 0.1.0-alpha.1\n");
    try expect(init, &environment, repository, &.{
        "git",
        "init",
        "--initial-branch=main",
        ".",
    }, 0, null);
    try expect(init, &environment, repository, &.{
        "git",    "-c",            "user.name=T", "-c",   "user.email=t@t",
        "commit", "--allow-empty", "-m",          "code",
    }, 0, null);

    const head_before = try run(
        init,
        &environment,
        repository,
        &.{ "git", "rev-parse", "HEAD" },
        0,
    );
    defer init.gpa.free(head_before.stdout);
    defer init.gpa.free(head_before.stderr);

    try expect(init, &environment, repository, &.{ cli_path, "init" }, 0, "");
    const head_after = try run(
        init,
        &environment,
        repository,
        &.{ "git", "rev-parse", "HEAD" },
        0,
    );
    defer init.gpa.free(head_after.stdout);
    defer init.gpa.free(head_after.stderr);
    if (std.mem.eql(u8, head_before.stdout, head_after.stdout)) return error.InitDidNotCommit;
    try expect(
        init,
        &environment,
        repository,
        &.{ "git", "status", "--short", "--untracked-files=all" },
        0,
        "",
    );
    try expect(
        init,
        &environment,
        repository,
        &.{ "git", "for-each-ref", "refs/heads/tiqet-state", "--format=%(refname)" },
        0,
        "",
    );

    try expect(
        init,
        &environment,
        repository,
        &.{ "git", "show", "--format=", "--name-only", "HEAD" },
        0,
        ".gitignore\n.tiqet/project.json\n",
    );

    var gitignore_buffer: [128]u8 = undefined;
    const gitignore = try repository.readFile(init.io, ".gitignore", &gitignore_buffer);
    try expectContains(gitignore, ".tiqet/log/\n");
    try expectContains(gitignore, ".tiqet/events/\n");

    var project_buffer: [512]u8 = undefined;
    const project_json = try repository.readFile(init.io, ".tiqet/project.json", &project_buffer);
    const project_id = try jsonString(project_json, "projectId");
    try expectHex32(project_id);
    var state_worktree_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var state_worktree_writer = std.Io.Writer.fixed(&state_worktree_buffer);
    try state_worktree_writer.print("{s}/.tiqet/worktrees/{s}", .{ home_buffer[0..home_length], project_id });
    const state_worktree = state_worktree_writer.buffered();

    const state_head_before = try run(
        init,
        &environment,
        repository,
        &.{ "git", "-C", state_worktree, "rev-parse", "HEAD" },
        0,
    );
    defer init.gpa.free(state_head_before.stdout);
    defer init.gpa.free(state_head_before.stderr);
    const worktrees_before = try run(
        init,
        &environment,
        repository,
        &.{ "git", "worktree", "list", "--porcelain" },
        0,
    );
    defer init.gpa.free(worktrees_before.stdout);
    defer init.gpa.free(worktrees_before.stderr);

    try expect(init, &environment, repository, &.{ cli_path, "init" }, 0, "");
    var project_buffer_after: [512]u8 = undefined;
    const project_json_after = try repository.readFile(
        init.io,
        ".tiqet/project.json",
        &project_buffer_after,
    );
    if (!std.mem.eql(u8, project_json, project_json_after)) return error.InitChangedProjectConfig;
    const source_head_after_second = try run(
        init,
        &environment,
        repository,
        &.{ "git", "rev-parse", "HEAD" },
        0,
    );
    defer init.gpa.free(source_head_after_second.stdout);
    defer init.gpa.free(source_head_after_second.stderr);
    if (!std.mem.eql(u8, head_after.stdout, source_head_after_second.stdout)) return error.InitChangedSourceHead;
    const state_head_after = try run(
        init,
        &environment,
        repository,
        &.{ "git", "-C", state_worktree, "rev-parse", "HEAD" },
        0,
    );
    defer init.gpa.free(state_head_after.stdout);
    defer init.gpa.free(state_head_after.stderr);
    if (!std.mem.eql(u8, state_head_before.stdout, state_head_after.stdout)) return error.InitChangedStateHead;
    const worktrees_after = try run(
        init,
        &environment,
        repository,
        &.{ "git", "worktree", "list", "--porcelain" },
        0,
    );
    defer init.gpa.free(worktrees_after.stdout);
    defer init.gpa.free(worktrees_after.stderr);
    if (!std.mem.eql(u8, worktrees_before.stdout, worktrees_after.stdout)) return error.InitChangedWorktrees;

    try expect(
        init,
        &environment,
        repository,
        &.{ "git", "-C", state_worktree, "rev-parse", "--symbolic-full-name", "HEAD" },
        0,
        "refs/heads/__tiqet_state__\n",
    );
    try expect(
        init,
        &environment,
        repository,
        &.{ "git", "-C", state_worktree, "ls-tree", "--name-only", "HEAD" },
        0,
        ".tiqet\n",
    );
    try expect(
        init,
        &environment,
        repository,
        &.{ "git", "-C", state_worktree, "ls-tree", "-r", "--name-only", "HEAD" },
        0,
        ".tiqet/events/.gitattributes\n.tiqet/project.json\n",
    );
    try expect(
        init,
        &environment,
        repository,
        &.{ "git", "-C", state_worktree, "status", "--short", "--untracked-files=all" },
        0,
        "",
    );
    var media_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var media_dir_writer = std.Io.Writer.fixed(&media_dir_buffer);
    try media_dir_writer.print("{s}/.tiqet/media", .{state_worktree});
    try expect(init, &environment, repository, &.{ "test", "-d", media_dir_writer.buffered() }, 0, "");
    try expectString(project_json, "stateBranch", "__tiqet_state__");
    try expectRfc3339ish(try jsonString(project_json, "createdAt"));

    const create_result = try run(init, &environment, repository, &.{ cli_path, "create", "write tests" }, 0);
    defer init.gpa.free(create_result.stdout);
    defer init.gpa.free(create_result.stderr);
    const task_id = std.mem.trimEnd(u8, create_result.stdout, "\n");
    try expectHex32(task_id);
    var expected_list_buffer: [80]u8 = undefined;
    var expected_list_writer = std.Io.Writer.fixed(&expected_list_buffer);
    try expected_list_writer.print("{s} open local write tests\n", .{task_id});
    try expect(init, &environment, repository, &.{ cli_path, "list" }, 0, expected_list_writer.buffered());
    try expect(
        init,
        &environment,
        repository,
        &.{ "git", "-C", state_worktree, "ls-files", ".tiqet/events/*.jsonl" },
        0,
        "",
    );
    try expect(
        init,
        &environment,
        repository,
        &.{ "git", "-C", state_worktree, "status", "--short", "--untracked-files=all" },
        0,
        "?? .tiqet/events/local.jsonl\n",
    );
    var linked_name_buffer: [64]u8 = undefined;
    var linked_name_writer = std.Io.Writer.fixed(&linked_name_buffer);
    try linked_name_writer.print("{s}-linked", .{repository_name});
    const linked_name = linked_name_writer.buffered();
    var linked_relative_buffer: [80]u8 = undefined;
    var linked_relative_writer = std.Io.Writer.fixed(&linked_relative_buffer);
    try linked_relative_writer.print("../{s}", .{linked_name});
    try expect(init, &environment, repository, &.{ "git", "worktree", "add", linked_relative_writer.buffered() }, 0, null);
    defer cache.deleteTree(init.io, linked_name) catch {};
    const linked = try cache.openDir(init.io, linked_name, .{ .access_sub_paths = true });
    defer linked.close(init.io);
    try expect(init, &environment, linked, &.{ cli_path, "list" }, 0, expected_list_writer.buffered());
    try expect_show(init, &environment, linked, cli_path, task_id, "write tests", "local", "open", null);
    const worktrees_after_linked_list = try run(
        init,
        &environment,
        repository,
        &.{ "git", "worktree", "list", "--porcelain" },
        0,
    );
    defer init.gpa.free(worktrees_after_linked_list.stdout);
    defer init.gpa.free(worktrees_after_linked_list.stderr);
    if (countOccurrences(worktrees_after_linked_list.stdout, state_worktree) != 1) return error.LinkedWorktreeCreatedSecondState;

    try expect(init, &environment, repository, &.{ cli_path, "done", task_id }, 0, "");
    try expect(init, &environment, repository, &.{ cli_path, "list" }, 0, "");
    const event_log = try working_events(init, &environment, state_worktree);
    defer init.gpa.free(event_log.stdout);
    defer init.gpa.free(event_log.stderr);
    try expectContains(event_log.stdout, "\"type\":\"task-created\"");
    try expectContains(event_log.stdout, "\"creator\":\"local\"");
    try expectContains(event_log.stdout, "\"type\":\"task-completed\"");

    try repository.writeFile(init.io, .{ .sub_path = ".git/info/exclude", .data = "*.jsonl\n" });
    try expect(init, &environment, repository, &.{
        "git", "-C", state_worktree, "status", "--porcelain=v1",
    }, 0, "");
    try sync_e2e(init, &environment, repository, cli_path, state_worktree);

    try commit_scope_e2e(init, &environment, repository, cli_path);
    try model_e2e(init, &environment, repository, cli_path);
}

fn usage_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    cli_path: []const u8,
) !void {
    // No Git repository exists yet. Open stdin must not delay help or usage errors.
    for ([_][]const u8{ "--help", "--version" }) |flag| {
        const result = try run_stdin(init, environment, repository, &.{ cli_path, flag }, null, 0);
        defer init.gpa.free(result.stdout);
        defer init.gpa.free(result.stderr);
        try std.testing.expectEqualStrings("", result.stderr);
        if (std.mem.eql(u8, flag, "--help")) {
            for ([_][]const u8{
                "Usage: tiqet", "init",               "create",                  "list",           "show ID",      "done ID",
                "sync",         "--description TEXT", "--description-file PATH", "--creator NAME", "32-character", "https://github.com/frontman-ai/tiqet#readme",
            }) |text| try expectContains(result.stdout, text);
        } else try std.testing.expectEqualStrings("tiqet 0.1.0-alpha.1\n", result.stdout);
    }
    const invalid = [_][]const []const u8{
        &.{cli_path},                                                          &.{ cli_path, "unknown" },                                             &.{ cli_path, "--help", "extra" },
        &.{ cli_path, "--version", "extra" },                                  &.{ cli_path, "init", "extra" },                                       &.{ cli_path, "list", "extra" },
        &.{ cli_path, "show" },                                                &.{ cli_path, "show", "id", "extra" },                                 &.{ cli_path, "done" },
        &.{ cli_path, "done", "id", "extra" },                                 &.{ cli_path, "sync", "extra" },                                       &.{ cli_path, "create" },
        &.{ cli_path, "create", "title", "--description-file", "-", "extra" }, &.{ cli_path, "create", "title", "--creator", "a", "--creator", "b" },
    };
    for (invalid, 0..) |args, index| {
        const result = try run_stdin(init, environment, repository, args, null, 1);
        defer init.gpa.free(result.stdout);
        defer init.gpa.free(result.stderr);
        try std.testing.expectEqualStrings("", result.stdout);
        const message = if (index == 0) "missing command" else if (index == 1)
            "unknown command"
        else
            "invalid arguments: check argument counts and create options";
        var buffer: [256]u8 = undefined;
        try std.testing.expectEqualStrings(
            try std.fmt.bufPrint(&buffer, "tiqet: {s}. Run tiqet --help.\n", .{message}),
            result.stderr,
        );
    }
    try expect(init, environment, repository, &.{ "test", "!", "-e", ".tiqet" }, 0, "");
    try expect(init, environment, repository, &.{ "test", "!", "-e", ".git" }, 0, "");
}

fn commit_scope_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    parent: std.Io.Dir,
    cli_path: []const u8,
) !void {
    // Real indices with staged and unstaged versions must survive every scoped commit.
    for ([_][]const u8{ "existing", "unborn" }) |name| {
        const repository = try parent.createDirPathOpen(init.io, name, .{});
        defer repository.close(init.io);
        try expect(init, environment, repository, &.{ "git", "init", "-q" }, 0, "");
        if (std.mem.eql(u8, name, "existing")) {
            try repository.writeFile(init.io, .{ .sub_path = ".gitignore", .data = "*.o\n" });
            try repository.writeFile(init.io, .{ .sub_path = "unrelated", .data = "original\n" });
            try expect(init, environment, repository, &.{ "git", "add", "." }, 0, "");
            try expect(init, environment, repository, &.{
                "git", "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-qm", "base",
            }, 0, "");
            try dirty_gitignore_e2e(init, environment, repository, cli_path, true);
        } else {
            try dirty_gitignore_e2e(init, environment, repository, cli_path, false);
        }
        try repository.writeFile(init.io, .{ .sub_path = "unrelated", .data = "staged\n" });
        try expect(init, environment, repository, &.{ "git", "add", "unrelated" }, 0, "");
        try repository.writeFile(init.io, .{ .sub_path = "unrelated", .data = "unstaged\n" });
        const index = try run(init, environment, repository, &.{
            "git", "ls-files", "--stage", "--", "unrelated",
        }, 0);
        defer init.gpa.free(index.stdout);
        defer init.gpa.free(index.stderr);
        const subdir = try repository.createDirPathOpen(init.io, "src", .{});
        defer subdir.close(init.io);
        try expect(init, environment, subdir, &.{ cli_path, "init" }, 0, "");
        try expect(init, environment, repository, &.{
            "git", "ls-files", "--stage", "--", "unrelated",
        }, 0, index.stdout);
        try expect(init, environment, repository, &.{
            "git", "show", "--format=", "--name-only", "HEAD",
        }, 0, ".gitignore\n.tiqet/project.json\n");
        try expect(init, environment, repository, &.{
            "git", "show", "--format=%s", "--no-patch", "HEAD",
        }, 0, "Initialize Tiqet\n");
        var buffer: [64]u8 = undefined;
        try std.testing.expectEqualStrings(
            "unstaged\n",
            try repository.readFile(init.io, "unrelated", &buffer),
        );
        try event_commit_scope_e2e(init, environment, repository, cli_path);
    }
}

fn dirty_gitignore_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    cli_path: []const u8,
    tracked: bool,
) !void {
    // Reject shared-file edits before creating project files; preserve HEAD, index, and bytes.
    for ([_]bool{ false, true }) |stage| {
        try repository.writeFile(init.io, .{ .sub_path = ".gitignore", .data = "staged-user-edit\n" });
        if (stage) try expect(init, environment, repository, &.{ "git", "add", ".gitignore" }, 0, "");
        try repository.writeFile(init.io, .{ .sub_path = ".gitignore", .data = "unstaged-user-edit\n" });
        const index = try run(init, environment, repository, &.{ "git", "ls-files", "--stage" }, 0);
        defer init.gpa.free(index.stdout);
        defer init.gpa.free(index.stderr);
        const refs = try run(init, environment, repository, &.{ "git", "show-ref", "--head" }, if (tracked) 0 else 1);
        defer init.gpa.free(refs.stdout);
        defer init.gpa.free(refs.stderr);
        const result = try run(init, environment, repository, &.{ cli_path, "init" }, 1);
        defer init.gpa.free(result.stdout);
        defer init.gpa.free(result.stderr);
        try expectContains(result.stderr, "GitignoreDirty");
        try expect(init, environment, repository, &.{ "test", "!", "-e", ".tiqet" }, 0, "");
        try expect(init, environment, repository, &.{ "git", "ls-files", "--stage" }, 0, index.stdout);
        try expect(init, environment, repository, &.{ "git", "show-ref", "--head" }, if (tracked) 0 else 1, refs.stdout);
        var buffer: [64]u8 = undefined;
        try std.testing.expectEqualStrings(
            "unstaged-user-edit\n",
            try repository.readFile(init.io, ".gitignore", &buffer),
        );
        if (tracked) {
            try expect(init, environment, repository, &.{
                "git", "restore", "--source=HEAD", "--staged", "--worktree", "--", ".gitignore",
            }, 0, "");
        } else {
            if (stage) try expect(init, environment, repository, &.{
                "git", "rm", "--cached", "-f", "--", ".gitignore",
            }, 0, null);
            try repository.deleteFile(init.io, ".gitignore");
        }
    }
}

fn event_commit_scope_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    cli_path: []const u8,
) !void {
    var config_buffer: [512]u8 = undefined;
    const config = try repository.readFile(init.io, ".tiqet/project.json", &config_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/.tiqet/worktrees/{s}", .{
        environment.get("HOME").?, try jsonString(config, "projectId"),
    });
    const state = try std.Io.Dir.openDirAbsolute(init.io, path, .{});
    defer state.close(init.io);
    try state.writeFile(init.io, .{ .sub_path = "unrelated", .data = "staged\n" });
    try expect(init, environment, state, &.{ "git", "add", "unrelated" }, 0, "");
    try state.writeFile(init.io, .{ .sub_path = "unrelated", .data = "unstaged\n" });
    const index = try run(init, environment, state, &.{
        "git", "ls-files", "--stage", "--", "unrelated",
    }, 0);
    defer init.gpa.free(index.stdout);
    defer init.gpa.free(index.stderr);
    var task_id: [32]u8 = undefined;
    for (0..2) |i| {
        const args: []const []const u8 = if (i == 0)
            &.{ cli_path, "create", "scoped task" }
        else
            &.{ cli_path, "done", &task_id };
        const result = try run(init, environment, repository, args, 0);
        defer init.gpa.free(result.stdout);
        defer init.gpa.free(result.stderr);
        if (i == 0) {
            const id = std.mem.trimEnd(u8, result.stdout, "\n");
            try expectHex32(id);
            @memcpy(&task_id, id);
        }
        try expect(init, environment, state, &.{
            "git", "ls-files", "--stage", "--", "unrelated",
        }, 0, index.stdout);
        try expect(init, environment, state, &.{
            "git", "show", "--format=", "--name-only", "HEAD",
        }, 0, ".tiqet/events/.gitattributes\n.tiqet/project.json\n");
        const message = try run(init, environment, state, &.{
            "git", "show", "--format=%s", "--no-patch", "HEAD",
        }, 0);
        defer init.gpa.free(message.stdout);
        defer init.gpa.free(message.stderr);
        try std.testing.expectEqualStrings("Initialize Tiqet state", std.mem.trimEnd(u8, message.stdout, "\n"));
        var buffer: [64]u8 = undefined;
        try std.testing.expectEqualStrings(
            "unstaged\n",
            try state.readFile(init.io, "unrelated", &buffer),
        );
    }
}

fn sync_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    cli_path: []const u8,
    state_worktree: []const u8,
) !void {
    // Real remotes exercise first publish, rebase, and failure without touching source state.
    try expect(init, environment, repository, &.{ cli_path, "sync", "extra" }, 1, "");
    try expect(init, environment, repository, &.{ cli_path, "sync" }, 1, "");
    var remote_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const remote = try std.fmt.bufPrint(&remote_buffer, "{s}/remote.git", .{
        environment.get("HOME").?,
    });
    try expect(init, environment, repository, &.{ "git", "init", "--bare", remote }, 0, null);
    try expect(init, environment, repository, &.{ "git", "remote", "add", "origin", remote }, 0, "");
    try repository.writeFile(init.io, .{ .sub_path = "source.txt", .data = "uncommitted code\n" });
    try expect(init, environment, repository, &.{ "git", "add", "source.txt" }, 0, "");
    const source_head = try run(init, environment, repository, &.{ "git", "rev-parse", "HEAD" }, 0);
    defer init.gpa.free(source_head.stdout);
    defer init.gpa.free(source_head.stderr);
    try expect(init, environment, repository, &.{ cli_path, "sync" }, 0, "");
    const published = try run(init, environment, repository, &.{
        "git", "--git-dir", remote, "rev-parse", "refs/heads/__tiqet_state__",
    }, 0);
    defer init.gpa.free(published.stdout);
    defer init.gpa.free(published.stderr);
    const events = try run(init, environment, repository, &.{
        "git", "-C", state_worktree, "show", "HEAD:.tiqet/events/local.jsonl",
    }, 0);
    defer init.gpa.free(events.stdout);
    defer init.gpa.free(events.stderr);
    try expect(init, environment, repository, &.{
        "git", "--git-dir", remote, "show", "__tiqet_state__:.tiqet/events/local.jsonl",
    }, 0, events.stdout);
    try repository.writeFile(init.io, .{ .sub_path = ".git/info/exclude", .data = "" });
    try expect(init, environment, repository, &.{ cli_path, "sync" }, 0, "");
    try expect(init, environment, repository, &.{
        "git", "--git-dir", remote, "rev-parse", "refs/heads/__tiqet_state__",
    }, 0, published.stdout);

    try sync_checkpoint_e2e(init, environment, repository, cli_path, state_worktree, remote);
    try sync_lock_e2e(init, environment, repository, cli_path, state_worktree);
    try sync_rebase_e2e(init, environment, repository, cli_path, state_worktree, remote);
    try sync_push_failure_e2e(init, environment, repository, cli_path, state_worktree, remote);
    try sync_conflict_e2e(init, environment, repository, cli_path, state_worktree);
    try expect(init, environment, repository, &.{
        "git", "remote", "set-url", "origin", "/nonexistent-tiqet-remote",
    }, 0, "");
    const local_head = try run(init, environment, repository, &.{
        "git", "-C", state_worktree, "rev-parse", "HEAD",
    }, 0);
    defer init.gpa.free(local_head.stdout);
    defer init.gpa.free(local_head.stderr);
    try expect(init, environment, repository, &.{ cli_path, "sync" }, 1, "");
    try expect(init, environment, repository, &.{
        "git", "-C", state_worktree, "rev-parse", "HEAD",
    }, 0, local_head.stdout);
    try expect(init, environment, repository, &.{ "git", "rev-parse", "HEAD" }, 0, source_head.stdout);
    try expect(init, environment, repository, &.{ "git", "status", "--short" }, 0, "A  source.txt\n");
    try expect(init, environment, repository, &.{
        "git", "--git-dir", remote, "for-each-ref", "--format=%(refname)",
    }, 0, "refs/heads/__tiqet_state__\n");
}

fn sync_checkpoint_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    cli_path: []const u8,
    state_worktree: []const u8,
    remote: []const u8,
) !void {
    const state_dir = try std.Io.Dir.openDirAbsolute(init.io, state_worktree, .{});
    defer state_dir.close(init.io);
    try state_dir.writeFile(init.io, .{ .sub_path = "unrelated.txt", .data = "keep me\n" });
    try expect(init, environment, repository, &.{ cli_path, "sync" }, 1, "");
    try expect(init, environment, repository, &.{
        "git", "-C", state_worktree, "add", "unrelated.txt",
    }, 0, "");
    try expect(init, environment, repository, &.{ cli_path, "sync" }, 1, "");
    try expect(init, environment, repository, &.{
        "git", "-C", state_worktree, "reset", "--", "unrelated.txt",
    }, 0, null);
    try state_dir.deleteFile(init.io, "unrelated.txt");
    const events = try run(init, environment, repository, &.{
        "git", "-C", state_worktree, "show", "HEAD:.tiqet/events/local.jsonl",
    }, 0);
    defer init.gpa.free(events.stdout);
    defer init.gpa.free(events.stderr);
    // A pending event is checkpointed even when it has not been committed by create/done.
    const pending_event = "{\"version\":1,\"id\":\"11111111111111111111111111111111\"," ++
        "\"type\":\"task-created\",\"taskId\":\"22222222222222222222222222222222\"," ++
        "\"title\":\"pending\",\"creator\":\"local\",\"createdAt\":\"2000-01-01T00:00:00Z\"}\n";
    var log_buffer: [4096]u8 = undefined;
    const pending_log = try std.fmt.bufPrint(&log_buffer, "{s}{s}", .{ events.stdout, pending_event });
    try state_dir.writeFile(init.io, .{
        .sub_path = ".tiqet/events/local.jsonl",
        .data = pending_log,
    });
    try expect(init, environment, repository, &.{ cli_path, "sync" }, 0, "");
    try expect(init, environment, repository, &.{
        "git", "--git-dir", remote, "show", "__tiqet_state__:.tiqet/events/local.jsonl",
    }, 0, pending_log);
}

fn sync_lock_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    cli_path: []const u8,
    state_worktree: []const u8,
) !void {
    const result = try run(init, environment, repository, &.{
        "git", "-C", state_worktree, "rev-parse", "--absolute-git-dir",
    }, 0);
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    const git_dir = try std.Io.Dir.openDirAbsolute(init.io, std.mem.trimEnd(u8, result.stdout, "\n"), .{});
    defer git_dir.close(init.io);
    {
        const lock = try git_dir.createFile(init.io, "tiqet-sync.lock", .{
            .truncate = false,
            .lock = .exclusive,
        });
        defer lock.close(init.io);
        try expect(init, environment, repository, &.{ cli_path, "sync" }, 1, "");
    }
    try git_dir.createDir(init.io, "rebase-merge", .default_dir);
    try expect(init, environment, repository, &.{ cli_path, "sync" }, 1, "");
    try git_dir.deleteDir(init.io, "rebase-merge");
    try expect(init, environment, repository, &.{ cli_path, "sync" }, 0, "");
}

fn sync_push_failure_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    cli_path: []const u8,
    state_worktree: []const u8,
    remote: []const u8,
) !void {
    try expect(init, environment, repository, &.{ cli_path, "create", "survive rejected push" }, 0, null);
    const pending = try working_events(init, environment, state_worktree);
    defer init.gpa.free(pending.stdout);
    defer init.gpa.free(pending.stderr);
    try expect(init, environment, repository, &.{
        "git", "--git-dir", remote, "config", "receive.hideRefs", "refs/heads/__tiqet_state__",
    }, 0, "");
    try expect(init, environment, repository, &.{ cli_path, "sync" }, 1, "");
    try expect(init, environment, repository, &.{
        "git", "-C", state_worktree, "show", "HEAD:.tiqet/events/local.jsonl",
    }, 0, pending.stdout);
    try expect(init, environment, repository, &.{
        "git", "--git-dir", remote, "config", "--unset", "receive.hideRefs",
    }, 0, "");
    try expect(init, environment, repository, &.{ cli_path, "sync" }, 0, "");
}

fn sync_conflict_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    cli_path: []const u8,
    state_worktree: []const u8,
) !void {
    var peer_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const peer_path = try std.fmt.bufPrint(&peer_buffer, "{s}/peer", .{environment.get("HOME").?});
    const peer = try std.Io.Dir.openDirAbsolute(init.io, peer_path, .{});
    defer peer.close(init.io);
    try expect(init, environment, peer, &.{ "git", "pull", "--ff-only" }, 0, null);
    try peer.writeFile(init.io, .{ .sub_path = ".tiqet/remote.txt", .data = "remote conflict\n" });
    try expect(init, environment, peer, &.{
        "git", "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-am", "remote conflict",
    }, 0, null);
    try expect(init, environment, peer, &.{ "git", "push", "origin", "HEAD" }, 0, null);
    const state_dir = try std.Io.Dir.openDirAbsolute(init.io, state_worktree, .{});
    defer state_dir.close(init.io);
    try state_dir.writeFile(init.io, .{ .sub_path = ".tiqet/remote.txt", .data = "local conflict\n" });
    try expect(init, environment, state_dir, &.{
        "git", "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-am", "local conflict",
    }, 0, null);
    const head = try run(init, environment, state_dir, &.{ "git", "rev-parse", "HEAD" }, 0);
    defer init.gpa.free(head.stdout);
    defer init.gpa.free(head.stderr);
    try expect(init, environment, repository, &.{ cli_path, "sync" }, 1, "");
    try expect(init, environment, state_dir, &.{ "git", "rev-parse", "HEAD" }, 0, head.stdout);
    try expect(init, environment, state_dir, &.{ "git", "status", "--porcelain" }, 0, "");
}

fn sync_rebase_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    cli_path: []const u8,
    state_worktree: []const u8,
    remote: []const u8,
) !void {
    var peer_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const peer_path = try std.fmt.bufPrint(&peer_buffer, "{s}/peer", .{environment.get("HOME").?});
    try expect(init, environment, repository, &.{
        "git", "clone", "--branch", "__tiqet_state__", remote, peer_path,
    }, 0, null);
    const peer = try std.Io.Dir.openDirAbsolute(init.io, peer_path, .{});
    defer peer.close(init.io);
    try peer.writeFile(init.io, .{ .sub_path = ".tiqet/remote.txt", .data = "remote state\n" });
    try expect(init, environment, peer, &.{ "git", "add", ".tiqet/remote.txt" }, 0, "");
    try expect(init, environment, peer, &.{
        "git", "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "remote state",
    }, 0, null);
    try expect(init, environment, peer, &.{ "git", "push", "origin", "HEAD" }, 0, null);
    try expect(init, environment, repository, &.{ cli_path, "create", "local after remote" }, 0, null);
    const events = try working_events(init, environment, state_worktree);
    defer init.gpa.free(events.stdout);
    defer init.gpa.free(events.stderr);
    try expect(init, environment, repository, &.{ cli_path, "sync" }, 0, "");
    try expect(init, environment, repository, &.{
        "git", "--git-dir", remote, "show", "__tiqet_state__:.tiqet/events/local.jsonl",
    }, 0, events.stdout);
    try expect(init, environment, repository, &.{
        "git", "-C", state_worktree, "show", "HEAD:.tiqet/remote.txt",
    }, 0, "remote state\n");
}

fn model_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    parent: std.Io.Dir,
    cli_path: []const u8,
) !void {
    const repository = try parent.createDirPathOpen(init.io, "model", .{});
    defer repository.close(init.io);
    try expect(init, environment, repository, &.{ "git", "init", "-q" }, 0, "");
    try expect(init, environment, repository, &.{ cli_path, "init" }, 0, "");
    var config_buffer: [512]u8 = undefined;
    const config = try repository.readFile(init.io, ".tiqet/project.json", &config_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/.tiqet/worktrees/{s}", .{
        environment.get("HOME").?, try jsonString(config, "projectId"),
    });
    const state = try std.Io.Dir.openDirAbsolute(init.io, path, .{});
    defer state.close(init.io);
    try identity_e2e(init, environment, repository, state, cli_path);
    try journal_e2e(init, environment, repository, state, path, cli_path);
    try show_e2e(init, environment, repository, cli_path);
    try show_history_e2e(init, environment, repository, state, cli_path);
    try description_e2e(init, environment, repository, state, path, cli_path);
}

fn identity_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    state: std.Io.Dir,
    cli_path: []const u8,
) !void {
    try expect(init, environment, state, &.{ "git", "checkout", "-qb", "wrong" }, 0, "");
    for ([_][]const u8{ "list", "sync" }) |command| {
        try expect(init, environment, repository, &.{ cli_path, command }, 1, "");
    }
    try expect(init, environment, repository, &.{ cli_path, "create", "wrong branch" }, 1, "");
    try expect_show_error(init, environment, repository, cli_path, "0" ** 32, "GitStateBranchInvalid");
    try expect(init, environment, state, &.{ "test", "!", "-e", ".tiqet/events/local.jsonl" }, 0, "");
    try expect(init, environment, state, &.{ "git", "checkout", "-q", "__tiqet_state__" }, 0, "");
    try expect(init, environment, repository, &.{ cli_path, "done", "0" ** 32 }, 1, "");
    // A different repository with the same project bytes must not share this state directory.
    const other = try repository.createDirPathOpen(init.io, "other", .{});
    defer other.close(init.io);
    try expect(init, environment, other, &.{ "git", "init", "-q" }, 0, "");
    try other.createDirPath(init.io, ".tiqet");
    var buffer: [512]u8 = undefined;
    try other.writeFile(init.io, .{
        .sub_path = ".tiqet/project.json",
        .data = try repository.readFile(init.io, ".tiqet/project.json", &buffer),
    });
    try expect(init, environment, other, &.{ cli_path, "create", "foreign project" }, 1, "");
    try expect_show_error(init, environment, other, cli_path, "0" ** 32, "GitStateIdentityInvalid");
    try expect(init, environment, state, &.{ "test", "!", "-e", ".tiqet/events/local.jsonl" }, 0, "");
    // Every command uses the same metadata lock, not only sync.
    const result = try run(init, environment, state, &.{ "git", "rev-parse", "--absolute-git-dir" }, 0);
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    const git_dir = try std.Io.Dir.openDirAbsolute(init.io, std.mem.trimEnd(u8, result.stdout, "\n"), .{});
    defer git_dir.close(init.io);
    const lock = try git_dir.createFile(init.io, "tiqet-sync.lock", .{ .truncate = false, .lock = .exclusive });
    defer lock.close(init.io);
    try expect(init, environment, repository, &.{ cli_path, "create", "locked" }, 1, "");
    try expect_show_error(init, environment, repository, cli_path, "0" ** 32, "WouldBlock");
    try expect(init, environment, repository, &.{ cli_path, "done", "0" ** 32 }, 1, "");
    try expect(init, environment, repository, &.{ cli_path, "list" }, 1, "");
}

fn journal_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    state: std.Io.Dir,
    path: []const u8,
    cli_path: []const u8,
) !void {
    // Mutation durability no longer depends on Git hooks or a successful checkpoint.
    try repository.writeFile(init.io, .{ .sub_path = ".git/hooks/pre-commit", .data = "#!/bin/sh\nexit 1\n" });
    try expect(init, environment, repository, &.{ "chmod", "+x", ".git/hooks/pre-commit" }, 0, "");
    const created = try run(init, environment, repository, &.{ cli_path, "create", "say \"hi\" \\ ok" }, 0);
    defer init.gpa.free(created.stdout);
    defer init.gpa.free(created.stderr);
    try expect(init, environment, repository, &.{ cli_path, "done", std.mem.trimEnd(u8, created.stdout, "\n") }, 0, "");
    const before = try working_events(init, environment, path);
    defer init.gpa.free(before.stdout);
    defer init.gpa.free(before.stderr);
    try expect(init, environment, repository, &.{ cli_path, "done", std.mem.trimEnd(u8, created.stdout, "\n") }, 0, "");
    const after = try working_events(init, environment, path);
    defer init.gpa.free(after.stdout);
    defer init.gpa.free(after.stderr);
    try std.testing.expectEqualStrings(before.stdout, after.stdout);
    try expect(init, environment, repository, &.{ cli_path, "sync" }, 1, "");
    try expect(init, environment, repository, &.{ cli_path, "list" }, 0, "");
    try repository.deleteFile(init.io, ".git/hooks/pre-commit");
    for (0..30) |_| try expect(init, environment, repository, &.{ cli_path, "create", "task" }, 0, null);
    const listed = try run(init, environment, repository, &.{ cli_path, "list" }, 0);
    defer init.gpa.free(listed.stdout);
    defer init.gpa.free(listed.stderr);
    try std.testing.expectEqual(@as(u8, 30), countOccurrences(listed.stdout, " open local task\n"));
    var lines = std.mem.tokenizeScalar(u8, listed.stdout, '\n');
    var previous: []const u8 = "";
    while (lines.next()) |line| {
        try std.testing.expect(std.mem.lessThan(u8, previous, line[0..32]));
        previous = line[0..32];
    }
    const events = try working_events(init, environment, path);
    defer init.gpa.free(events.stdout);
    defer init.gpa.free(events.stderr);
    try std.testing.expect(events.stdout.len > 4096);
    try replay_failures_e2e(init, environment, repository, state, cli_path, events.stdout);
}

fn replay_failures_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    state: std.Io.Dir,
    cli_path: []const u8,
    events: []const u8,
) !void {
    const log = ".tiqet/events/local.jsonl";
    // An incomplete tail must fail before another append; a retry cannot hide corruption.
    try state.writeFile(init.io, .{ .sub_path = log, .data = events[0 .. events.len - 1] });
    try expect(init, environment, repository, &.{ cli_path, "list" }, 1, "");
    try expect(init, environment, repository, &.{ cli_path, "create", "corrupt tail" }, 1, "");
    try expect_show_error(init, environment, repository, cli_path, "0" ** 32, "InvalidEventLog");
    var buffer: [16384]u8 = undefined;
    try std.testing.expectEqualStrings(events[0 .. events.len - 1], try state.readFile(init.io, log, &buffer));
    try state.writeFile(init.io, .{ .sub_path = log, .data = events });
    // A missing remote still leaves a valid local checkpoint. Rewrites cannot replace it.
    try expect(init, environment, repository, &.{ cli_path, "sync" }, 1, "");
    try expect(init, environment, state, &.{ "git", "show", "HEAD:.tiqet/events/local.jsonl" }, 0, events);
    try state.writeFile(init.io, .{ .sub_path = log, .data = "" });
    try expect(init, environment, repository, &.{ cli_path, "sync" }, 1, "");
    try expect(init, environment, repository, &.{ cli_path, "create", "rewritten" }, 1, "");
    try expect_show_error(init, environment, repository, cli_path, "0" ** 32, "EventHistoryRewritten");
    try expect(init, environment, state, &.{ "git", "show", "HEAD:.tiqet/events/local.jsonl" }, 0, events);
    try state.writeFile(init.io, .{ .sub_path = log, .data = events });
}

fn scale_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    cli_path: []const u8,
) !void {
    try expect(init, environment, repository, &.{ "git", "init", "-q" }, 0, "");
    try expect(init, environment, repository, &.{ cli_path, "init" }, 0, "");
    var config_buffer: [512]u8 = undefined;
    const config = try repository.readFile(init.io, ".tiqet/project.json", &config_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/.tiqet/worktrees/{s}", .{
        environment.get("HOME").?, try jsonString(config, "projectId"),
    });
    const state = try std.Io.Dir.openDirAbsolute(init.io, path, .{});
    defer state.close(init.io);
    const body = try init.gpa.alloc(u8, 32 * 1024);
    defer init.gpa.free(body);
    @memset(body, 'x');
    @memcpy(body[0..11], "## Details\n");
    for ([_]u32{ 1000, 4000 }) |count| {
        for ([_]u32{ 0, 1024, 16 * 1024, 32 * 1024 }) |length| {
            try write_scale_history(init, environment, state, count, if (length == 0) null else body[0..length]);
            var times: [3][3]i64 = undefined;
            for (0..3) |sample| {
                var started = std.Io.Clock.awake.now(init.io).toMilliseconds();
                const listed = try run(init, environment, repository, &.{ cli_path, "list" }, 0);
                times[0][sample] = std.Io.Clock.awake.now(init.io).toMilliseconds() - started;
                defer init.gpa.free(listed.stdout);
                defer init.gpa.free(listed.stderr);
                try std.testing.expectEqual(count, std.mem.count(u8, listed.stdout, " open local task\n"));
                started = std.Io.Clock.awake.now(init.io).toMilliseconds();
                const created = try run(init, environment, repository, &.{
                    cli_path, "create", "benchmark append", "--description", body[0..1024],
                }, 0);
                times[1][sample] = std.Io.Clock.awake.now(init.io).toMilliseconds() - started;
                defer init.gpa.free(created.stdout);
                defer init.gpa.free(created.stderr);
                const id = std.mem.trimEnd(u8, created.stdout, "\n");
                try expectHex32(id);
                started = std.Io.Clock.awake.now(init.io).toMilliseconds();
                try expect(init, environment, repository, &.{ cli_path, "done", id }, 0, "");
                times[2][sample] = std.Io.Clock.awake.now(init.io).toMilliseconds() - started;
            }
            for (&times) |*samples| std.mem.sort(i64, samples, {}, std.sort.asc(i64));
            std.debug.print("scale-cli tasks={d} description={d} list_ms={d} create_ms={d} done_ms={d}\n", .{
                count, length, times[0][1], times[1][1], times[2][1],
            });
        }
    }
}

fn write_scale_history(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    state: std.Io.Dir,
    count: u32,
    description: ?[]const u8,
) !void {
    const path = ".tiqet/events/local.jsonl";
    const file = try state.createFile(init.io, path, .{ .truncate = true });
    defer file.close(init.io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    for (0..count) |index| {
        var id: [32]u8 = undefined;
        _ = try std.fmt.bufPrint(&id, "{x:0>32}", .{index});
        try std.json.Stringify.value(.{
            .version = @as(u8, 1),
            .id = &id,
            .type = "task-created",
            .taskId = &id,
            .title = "task",
            .creator = "local",
            .description = description,
            .createdAt = "2000-01-01T00:00:00Z",
        }, .{ .emit_null_optional_fields = false }, &writer.interface);
        try writer.interface.writeByte('\n');
    }
    try writer.interface.flush();
    try file.sync(init.io);
    try expect(init, environment, state, &.{ "git", "add", "--", path }, 0, "");
    try expect(init, environment, state, &.{
        "git", "-c", "user.name=T", "-c", "user.email=t@t", "commit", "--only", "-qm", "scale fixture", "--", path,
    }, 0, "");
}

fn show_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    cli_path: []const u8,
) !void {
    const body = "## Problem\r\n\tSay \"hello\" \\ 世界 🌍\nTrailing spaces  ";
    const created = try run(init, environment, repository, &.{
        cli_path, "create", "show task", "--creator", "agent", "--description", body,
    }, 0);
    defer init.gpa.free(created.stdout);
    defer init.gpa.free(created.stderr);
    const id = std.mem.trimEnd(u8, created.stdout, "\n");
    try expectHex32(id);
    for ([_][]const u8{ "open", "completed" }) |status| {
        var buffer: [512]u8 = undefined;
        const expected = try std.fmt.bufPrint(&buffer, "ID: {s}\nTitle: show task\nStatus: {s}\nCreator: agent\n\nDescription:\n{s}", .{ id, status, body });
        try expect(init, environment, repository, &.{ cli_path, "show", id }, 0, expected);
        // Without a remote, sync checkpoints locally before returning its existing error.
        try expect(init, environment, repository, &.{ cli_path, "sync" }, 1, "");
        try expect(init, environment, repository, &.{ cli_path, "show", id }, 0, expected);
        const piped = try run_stdin(init, environment, repository, &.{ cli_path, "show", id }, null, 0);
        defer init.gpa.free(piped.stdout);
        defer init.gpa.free(piped.stderr);
        try std.testing.expectEqualStrings(expected, piped.stdout);
        try expect(init, environment, repository, &.{ cli_path, "done", id }, 0, "");
    }
    try expect(init, environment, repository, &.{ cli_path, "show" }, 1, "");
    try expect(init, environment, repository, &.{ cli_path, "show", id, "extra" }, 1, "");
    for ([_][]const u8{ "", "a", "A" ** 32, "g" ** 32, "a" ** 31, "a" ** 33, "--help" }) |invalid| {
        try expect_show_error(init, environment, repository, cli_path, invalid, "InvalidTaskId");
    }
    try expect_show_error(init, environment, repository, cli_path, "f" ** 32, "TaskNotFound");
    for ([_]?[]const u8{ null, "", " \t\r\n  " }) |body_text| {
        const result = try run(init, environment, repository, if (body_text) |text|
            &.{ cli_path, "create", "plain", "--description", text }
        else
            &.{ cli_path, "create", "plain" }, 0);
        defer init.gpa.free(result.stdout);
        defer init.gpa.free(result.stderr);
        try expect_show(init, environment, repository, cli_path, std.mem.trimEnd(u8, result.stdout, "\n"), "plain", "local", "open", if (body_text != null and body_text.?.len != 0) body_text else null);
    }
}

fn expect_show(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    cli_path: []const u8,
    id: []const u8,
    title: []const u8,
    creator: []const u8,
    status: []const u8,
    description: ?[]const u8,
) !void {
    const expected = try std.fmt.allocPrint(init.gpa, "ID: {s}\nTitle: {s}\nStatus: {s}\nCreator: {s}\n{s}{s}", .{ id, title, status, creator, if (description != null) "\nDescription:\n" else "", description orelse "" });
    defer init.gpa.free(expected);
    try expect(init, environment, repository, &.{ cli_path, "show", id }, 0, expected);
}

fn expect_show_error(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    cli_path: []const u8,
    id: []const u8,
    message: []const u8,
) !void {
    const result = try run(init, environment, repository, &.{ cli_path, "show", id }, 1);
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    try std.testing.expectEqualStrings("", result.stdout);
    try expectContains(result.stderr, message);
}

fn show_history_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    state: std.Io.Dir,
    cli_path: []const u8,
) !void {
    const log = ".tiqet/events/local.jsonl";
    const before = try state.readFileAlloc(init.io, log, init.gpa, .limited(1024 * 1024));
    defer init.gpa.free(before);
    const completed = "{\"version\":1,\"id\":\"" ++ "a" ** 32 ++
        "\",\"type\":\"task-completed\",\"taskId\":\"" ++ "b" ** 32 ++
        "\",\"createdAt\":\"2000-01-01T00:00:00Z\"}\n";
    const creation = "{\"version\":1,\"id\":\"" ++ "c" ** 32 ++
        "\",\"type\":\"task-created\",\"taskId\":\"" ++ "b" ** 32 ++
        "\",\"title\":\"legacy\",\"creator\":\"agent\",\"createdAt\":\"2000-01-01T00:00:00Z\"";
    for ([_][]const u8{ "", ",\"description\":null", ",\"description\":\"\"" }) |field| {
        const bytes = try std.fmt.allocPrint(init.gpa, "{s}{s}{s}{s}}}\n{s}{s}}}\n", .{ before, completed, creation, field, creation, field });
        defer init.gpa.free(bytes);
        try state.writeFile(init.io, .{ .sub_path = log, .data = bytes });
        try expect_show(init, environment, repository, cli_path, "b" ** 32, "legacy", "agent", "completed", null);
        try show_readonly_e2e(init, environment, repository, state, cli_path, "b" ** 32);
    }
    const only = try std.fmt.allocPrint(init.gpa, "{s}{s}", .{ before, completed });
    defer init.gpa.free(only);
    try state.writeFile(init.io, .{ .sub_path = log, .data = only });
    try expect_show_error(init, environment, repository, cli_path, "b" ** 32, "TaskNotFound");
    for ([_][]const u8{ "{}\n", completed }) |tail| {
        const bytes = try std.fmt.allocPrint(init.gpa, "{s}{s}}}\n{s}", .{ before, creation, tail });
        defer init.gpa.free(bytes);
        // Reusing the creation ID for a completion creates a conflict after the target.
        const conflicting = try init.gpa.dupe(u8, bytes);
        defer init.gpa.free(conflicting);
        if (tail.len > 3) {
            const start = before.len + creation.len + 2;
            const id_start = start + (std.mem.indexOf(u8, conflicting[start..], "\"id\":\"") orelse
                return error.MissingJsonField) + 6;
            @memset(conflicting[id_start..][0..32], 'c');
        }
        try state.writeFile(init.io, .{ .sub_path = log, .data = conflicting });
        try expect_show_error(init, environment, repository, cli_path, "b" ** 32, if (tail.len > 3) "ConflictingEventId" else "InvalidEventLog");
    }
    try state.writeFile(init.io, .{ .sub_path = log, .data = before });
}

fn show_readonly_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    state: std.Io.Dir,
    cli_path: []const u8,
    id: []const u8,
) !void {
    // Snapshot both worktrees around successful and failed reads, including pending bytes.
    const log = ".tiqet/events/local.jsonl";
    const bytes = try state.readFileAlloc(init.io, log, init.gpa, .limited(1024 * 1024));
    defer init.gpa.free(bytes);
    for ([_]std.Io.Dir{ repository, state }) |dir| {
        for ([_][]const []const u8{
            &.{ "git", "rev-parse", "HEAD" },
            &.{ "git", "status", "--porcelain=v1", "--untracked-files=all" },
        }) |args| {
            const before = try run(init, environment, dir, args, 0);
            defer init.gpa.free(before.stdout);
            defer init.gpa.free(before.stderr);
            try expect(init, environment, repository, &.{ cli_path, "show", id }, 0, null);
            try expect_show_error(init, environment, repository, cli_path, "f" ** 32, "TaskNotFound");
            try expect(init, environment, dir, args, 0, before.stdout);
        }
    }
    const after = try state.readFileAlloc(init.io, log, init.gpa, .limited(1024 * 1024));
    defer init.gpa.free(after);
    try std.testing.expectEqualStrings(bytes, after);
}

fn description_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    state: std.Io.Dir,
    state_path: []const u8,
    cli_path: []const u8,
) !void {
    const markdown = "## Problem\r\n\tSay \"hello\" \\ 世界 🌍\n";
    var description_ids: [3][32]u8 = undefined;
    const inputs = try repository.createDirPathOpen(init.io, "inputs", .{});
    defer inputs.close(init.io);
    try inputs.writeFile(init.io, .{ .sub_path = "body.md", .data = markdown });
    for (0..3) |index| {
        const result = switch (index) {
            0 => try run(init, environment, repository, &.{
                cli_path, "create", "description", "--description", markdown,
            }, 0),
            1 => try run(init, environment, inputs, &.{
                cli_path, "create", "--description-file", "body.md", "description", "--creator", "agent",
            }, 0),
            else => try run_stdin(init, environment, repository, &.{
                cli_path, "create", "description", "--description-file", "-",
            }, markdown, 0),
        };
        defer init.gpa.free(result.stdout);
        defer init.gpa.free(result.stderr);
        const id = std.mem.trimEnd(u8, result.stdout, "\n");
        try expectHex32(id);
        @memcpy(&description_ids[index], id);
        try expect_description(init, state, id, markdown);
        try expect_show(init, environment, repository, cli_path, id, "description", if (index == 1) "agent" else "local", "open", markdown);
        try expect(init, environment, repository, &.{ cli_path, "done", id }, 0, "");
    }
    for (description_ids, 0..) |id, index| {
        try expect_show(init, environment, repository, cli_path, &id, "description", if (index == 1) "agent" else "local", "completed", markdown);
    }
    // Leaving the input pipe open proves these commands do not attempt to read stdin.
    const no_input = try run_stdin(init, environment, repository, &.{
        cli_path, "create", "--", "--description",
    }, null, 0);
    defer init.gpa.free(no_input.stdout);
    defer init.gpa.free(no_input.stderr);
    try expect_description(init, state, std.mem.trimEnd(u8, no_input.stdout, "\n"), null);
    try expect_show(init, environment, repository, cli_path, std.mem.trimEnd(u8, no_input.stdout, "\n"), "--description", "local", "open", null);
    const conflict = try run_stdin(init, environment, repository, &.{
        cli_path, "create", "conflict", "--description", "text", "--description-file", "-",
    }, null, 1);
    defer init.gpa.free(conflict.stdout);
    defer init.gpa.free(conflict.stderr);
    try std.testing.expectEqualStrings("", conflict.stdout);
    for ([_][]const u8{ "--description", "--description-file" }) |flag| {
        try inputs.writeFile(init.io, .{ .sub_path = "empty.md", .data = "" });
        const empty = try run(init, environment, inputs, &.{
            cli_path, "create", "empty", flag, if (std.mem.eql(u8, flag, "--description")) "" else "empty.md",
        }, 0);
        defer init.gpa.free(empty.stdout);
        defer init.gpa.free(empty.stderr);
        try expect_description(init, state, std.mem.trimEnd(u8, empty.stdout, "\n"), null);
        try expect_show(init, environment, repository, cli_path, std.mem.trimEnd(u8, empty.stdout, "\n"), "empty", "local", "open", null);
    }
    const empty_stdin = try run_stdin(init, environment, repository, &.{
        cli_path, "create", "empty stdin", "--description-file", "-",
    }, "", 0);
    defer init.gpa.free(empty_stdin.stdout);
    defer init.gpa.free(empty_stdin.stderr);
    try expect_description(init, state, std.mem.trimEnd(u8, empty_stdin.stdout, "\n"), null);
    try expect_show(init, environment, repository, cli_path, std.mem.trimEnd(u8, empty_stdin.stdout, "\n"), "empty stdin", "local", "open", null);
    try description_boundaries_e2e(init, environment, repository, state, cli_path);
    // Pending descriptions use the ordinary checkpoint and remote path, not a blob store.
    var remote_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const remote = try std.fmt.bufPrint(&remote_buffer, "{s}/descriptions.git", .{environment.get("HOME").?});
    try expect(init, environment, repository, &.{ "git", "init", "--bare", remote }, 0, null);
    try expect(init, environment, repository, &.{ "git", "remote", "add", "origin", remote }, 0, "");
    try expect(init, environment, repository, &.{ cli_path, "sync" }, 0, "");
    for (description_ids, 0..) |id, index| {
        try expect_show(init, environment, repository, cli_path, &id, "description", if (index == 1) "agent" else "local", "completed", markdown);
    }
    try expect_show(init, environment, repository, cli_path, std.mem.trimEnd(u8, empty_stdin.stdout, "\n"), "empty stdin", "local", "open", null);
    const log = try working_events(init, environment, state_path);
    defer init.gpa.free(log.stdout);
    defer init.gpa.free(log.stderr);
    try expect(init, environment, repository, &.{
        "git", "--git-dir", remote, "show", "__tiqet_state__:.tiqet/events/local.jsonl",
    }, 0, log.stdout);
    try expect(init, environment, state, &.{ "git", "ls-tree", "-r", "--name-only", "HEAD" }, 0, ".tiqet/events/.gitattributes\n.tiqet/events/local.jsonl\n.tiqet/project.json\n");
    // Large committed records keep the existing prefix and partial-tail protections.
    const file = try state.createFile(init.io, ".tiqet/events/local.jsonl", .{
        .read = true,
        .truncate = false,
    });
    defer file.close(init.io);
    try file.writePositionalAll(init.io, "{}", log.stdout.len);
    const tail = try run(init, environment, repository, &.{ cli_path, "create", "bad tail" }, 1);
    defer init.gpa.free(tail.stdout);
    defer init.gpa.free(tail.stderr);
    try expectContains(tail.stderr, "InvalidEventLog");
    try expect_show_error(init, environment, repository, cli_path, std.mem.trimEnd(u8, no_input.stdout, "\n"), "InvalidEventLog");
    try std.testing.expectEqual(log.stdout.len + 2, (try file.stat(init.io)).size);
    try file.setLength(init.io, log.stdout.len);
    try file.writePositionalAll(init.io, "!", 0);
    const rewritten = try run(init, environment, repository, &.{ cli_path, "sync" }, 1);
    defer init.gpa.free(rewritten.stdout);
    defer init.gpa.free(rewritten.stderr);
    try expectContains(rewritten.stderr, "EventHistoryRewritten");
    try expect_show_error(init, environment, repository, cli_path, std.mem.trimEnd(u8, no_input.stdout, "\n"), "EventHistoryRewritten");
    try file.writePositionalAll(init.io, log.stdout[0..1], 0);
    try expect(init, environment, repository, &.{ cli_path, "sync" }, 0, "");
    try expect(init, environment, state, &.{ "git", "show", "HEAD:.tiqet/events/local.jsonl" }, 0, log.stdout);
}

fn description_boundaries_e2e(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    state: std.Io.Dir,
    cli_path: []const u8,
) !void {
    const body = try init.gpa.alloc(u8, 256 * 1024 + 1);
    defer init.gpa.free(body);
    @memset(body, 'x');
    body[0] = '\n';
    for (0..2) |index| {
        const accepted = body[0 .. body.len - 1];
        try repository.writeFile(init.io, .{ .sub_path = "large.md", .data = accepted });
        const result = if (index == 0)
            try run(init, environment, repository, &.{ cli_path, "create", "large", "--description-file", "large.md" }, 0)
        else
            try run_stdin(init, environment, repository, &.{ cli_path, "create", "large", "--description-file", "-" }, accepted, 0);
        defer init.gpa.free(result.stdout);
        defer init.gpa.free(result.stderr);
        try expect_description(init, state, std.mem.trimEnd(u8, result.stdout, "\n"), accepted);
        try expect_show(init, environment, repository, cli_path, std.mem.trimEnd(u8, result.stdout, "\n"), "large", "local", "open", accepted);
    }
    const inline_result = try run(init, environment, repository, &.{
        cli_path, "create", "large inline", "--description", body[0 .. 16 * 1024],
    }, 0);
    defer init.gpa.free(inline_result.stdout);
    defer init.gpa.free(inline_result.stderr);
    try expect_description(
        init,
        state,
        std.mem.trimEnd(u8, inline_result.stdout, "\n"),
        body[0 .. 16 * 1024],
    );
    const listed = try run(init, environment, repository, &.{ cli_path, "list" }, 0);
    defer init.gpa.free(listed.stdout);
    defer init.gpa.free(listed.stderr);
    try std.testing.expect(listed.stdout.len < 4096);
    try repository.writeFile(init.io, .{ .sub_path = "large.md", .data = body });
    try repository.writeFile(init.io, .{ .sub_path = "invalid.md", .data = "\xff" });
    const log_path = ".tiqet/events/local.jsonl";
    const before = try state.readFileAlloc(init.io, log_path, init.gpa, .limited(2 * 1024 * 1024));
    defer init.gpa.free(before);
    const refs = try run(init, environment, repository, &.{ "git", "show-ref", "--head" }, 0);
    defer init.gpa.free(refs.stdout);
    defer init.gpa.free(refs.stderr);
    const source_index = try run(init, environment, repository, &.{ "git", "ls-files", "--stage" }, 0);
    defer init.gpa.free(source_index.stdout);
    defer init.gpa.free(source_index.stderr);
    const state_index = try run(init, environment, state, &.{ "git", "ls-files", "--stage" }, 0);
    defer init.gpa.free(state_index.stdout);
    defer init.gpa.free(state_index.stderr);
    const invalid = [_][]const []const u8{
        &.{ cli_path, "create", "bad", "--description" },
        &.{ cli_path, "create", "bad", "--description-file" },
        &.{ cli_path, "create", "bad", "--unknown", "x" },
        &.{ cli_path, "create", "bad", "extra" },
        &.{ cli_path, "create", "bad", "--description", "x", "--description", "x" },
        &.{ cli_path, "create", "bad", "--description-file", "missing", "--description-file", "missing" },
        &.{ cli_path, "create", "bad", "--creator", "a", "--creator", "b" },
        &.{ cli_path, "create", "bad", "--description-file", "missing.md" },
        &.{ cli_path, "create", "bad", "--description-file", "." },
        &.{ cli_path, "create", "bad", "--description-file", "invalid.md" },
        &.{ cli_path, "create", "bad", "--description-file", "large.md" },
        &.{ cli_path, "create", "bad", "--description", "\x1b" },
    };
    for (invalid) |arguments| try expect(init, environment, repository, arguments, 1, "");
    const oversized = try run_stdin(init, environment, repository, &.{
        cli_path, "create", "bad", "--description-file", "-",
    }, body, 1);
    defer init.gpa.free(oversized.stdout);
    defer init.gpa.free(oversized.stderr);
    try expectContains(oversized.stderr, "DescriptionTooLong");
    const after = try state.readFileAlloc(init.io, log_path, init.gpa, .limited(2 * 1024 * 1024));
    defer init.gpa.free(after);
    try std.testing.expectEqualStrings(before, after);
    try expect(init, environment, repository, &.{ "git", "show-ref", "--head" }, 0, refs.stdout);
    try expect(init, environment, repository, &.{ "git", "ls-files", "--stage" }, 0, source_index.stdout);
    try expect(init, environment, state, &.{ "git", "ls-files", "--stage" }, 0, state_index.stdout);
}

fn expect_description(init: std.process.Init, state: std.Io.Dir, id: []const u8, expected: ?[]const u8) !void {
    const bytes = try state.readFileAlloc(init.io, ".tiqet/events/local.jsonl", init.gpa, .limited(2 * 1024 * 1024));
    defer init.gpa.free(bytes);
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    var count: u32 = 0;
    while (lines.next()) |line| {
        const json = try std.json.parseFromSlice(std.json.Value, init.gpa, line, .{});
        defer json.deinit();
        const fields = json.value.object;
        if (!std.mem.eql(u8, fields.get("taskId").?.string, id)) continue;
        if (!std.mem.eql(u8, fields.get("type").?.string, "task-created")) continue;
        count += 1;
        if (expected) |description| {
            try std.testing.expectEqualStrings(description, fields.get("description").?.string);
        } else try std.testing.expect(fields.get("description") == null);
    }
    try std.testing.expectEqual(@as(u32, 1), count);
}

fn run_stdin(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    arguments: []const []const u8,
    input: ?[]const u8,
    exit_code: u8,
) !std.process.RunResult {
    var child = try std.process.spawn(init.io, .{
        .argv = arguments,
        .cwd = .{ .dir = repository },
        .environ_map = environment,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(init.io);
    if (input) |bytes| {
        try child.stdin.?.writeStreamingAll(init.io, bytes);
        child.stdin.?.close(init.io);
        child.stdin = null;
    }
    var buffers: std.Io.File.MultiReader.Buffer(2) = undefined;
    var readers: std.Io.File.MultiReader = undefined;
    readers.init(init.gpa, init.io, buffers.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer readers.deinit();
    const deadline = (std.Io.Timeout{ .duration = .{
        .raw = .fromSeconds(10),
        .clock = .awake,
    } }).toDeadline(init.io);
    while (readers.fill(4096, deadline)) |_| {
        if (readers.reader(0).buffered().len > 4096 or readers.reader(1).buffered().len > 64512) {
            return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try readers.checkAnyError();
    const term = try child.wait(init.io);
    const stdout = try readers.toOwnedSlice(0);
    errdefer init.gpa.free(stdout);
    const stderr = try readers.toOwnedSlice(1);
    errdefer init.gpa.free(stderr);
    if (term != .exited or term.exited != exit_code) {
        std.debug.print("stdin command failed: {s}\n", .{stderr});
        return error.UnexpectedExitCode;
    }
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

fn working_events(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    path: []const u8,
) !std.process.RunResult {
    const dir = try std.Io.Dir.openDirAbsolute(init.io, path, .{});
    defer dir.close(init.io);
    return run(init, environment, dir, &.{ "cat", ".tiqet/events/local.jsonl" }, 0);
}

fn countOccurrences(haystack: []const u8, needle: []const u8) u8 {
    var count: u8 = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        count += 1;
        rest = rest[index + needle.len ..];
    }
    return count;
}

fn jsonString(json: []const u8, field: []const u8) ![]const u8 {
    var needle_buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&needle_buffer);
    try writer.print("\"{s}\": \"", .{field});
    const needle = writer.buffered();
    const start = std.mem.indexOf(u8, json, needle) orelse return error.MissingJsonField;
    const value_start = start + needle.len;
    const value_end = std.mem.indexOfScalarPos(
        u8,
        json,
        value_start,
        '"',
    ) orelse return error.InvalidJson;
    return json[value_start..value_end];
}

fn expectHex32(value: []const u8) !void {
    if (value.len != 32) return error.UnexpectedHex;
    for (value) |byte| {
        const digit = byte >= '0' and byte <= '9';
        const lower = byte >= 'a' and byte <= 'f';
        if (!digit and !lower) return error.UnexpectedHex;
    }
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) return error.MissingExpectedText;
}

fn expectString(json: []const u8, field: []const u8, expected: []const u8) !void {
    const actual = try jsonString(json, field);
    if (!std.mem.eql(u8, actual, expected)) return error.UnexpectedJsonString;
}

fn expectRfc3339ish(value: []const u8) !void {
    if (value.len != 20) return error.UnexpectedTimestamp;
    if (value[4] != '-' or value[7] != '-' or value[10] != 'T') return error.UnexpectedTimestamp;
    if (value[13] != ':' or value[16] != ':' or value[19] != 'Z') return error.UnexpectedTimestamp;
}

fn expect(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    arguments: []const []const u8,
    exit_code: u8,
    expected_stdout: ?[]const u8,
) !void {
    const result = try run(init, environment, repository, arguments, exit_code);
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    if (expected_stdout) |expected| {
        if (!std.mem.eql(u8, expected, result.stdout)) return error.UnexpectedStdout;
    }
}

fn run(
    init: std.process.Init,
    environment: *const std.process.Environ.Map,
    repository: std.Io.Dir,
    arguments: []const []const u8,
    exit_code: u8,
) !std.process.RunResult {
    const result = try std.process.run(init.gpa, init.io, .{
        .argv = arguments,
        .cwd = .{ .dir = repository },
        .environ_map = environment,
        .stderr_limit = .limited(4096),
        .stdout_limit = .limited(1024 * 1024),
    });
    const actual_exit_code = switch (result.term) {
        .exited => |code| code,
        else => {
            init.gpa.free(result.stdout);
            init.gpa.free(result.stderr);
            return error.UnexpectedTermination;
        },
    };
    if (actual_exit_code != exit_code) {
        std.debug.print("command failed: {s}\n", .{result.stderr});
        init.gpa.free(result.stdout);
        init.gpa.free(result.stderr);
        return error.UnexpectedExitCode;
    }
    return result;
}
