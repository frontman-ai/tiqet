const std = @import("std");
const Event = @import("event.zig");
const Storage = @This();

// Borrowed for one command. Buffers must be distinct and outlive this context.
// Fixed-size pointers enforce the scratch capacities without owning backing storage.
io: std.Io,
environment: *const std.process.Environ.Map,
cwd: std.process.Child.Cwd,
line: *[text_scratch_bytes_max]u8,
encoded: *[text_scratch_bytes_max]u8,
output: *[git_output_bytes_max + 1]u8,
chunk: *[4096]u8,
compare: *[4096]u8,
json_allocator: *std.heap.FixedBufferAllocator,

const project_dir = ".tiqet";
pub const project_config_path = project_dir ++ "/project.json";
pub const events_path = project_dir ++ "/events/local.jsonl";
const attributes_path = project_dir ++ "/events/.gitattributes";
const state_branch = "__tiqet_state__";
const state_ref = "refs/heads/" ++ state_branch;
const gitignore_entries = ".tiqet/log/\n.tiqet/events/\n";
const Id = Event.Id;
const Timestamp = Event.Timestamp;
pub const text_scratch_bytes_max = 2048;
const gitignore_bytes_max = text_scratch_bytes_max;
pub const project_config_bytes_max = 512;
const history_bytes_max: u64 = 128 * 1024 * 1024;
pub const git_output_bytes_max = 64512;

const ProjectConfig = struct { id: Id, created_at: Timestamp };

const WireProject = struct {
    projectId: []const u8,
    stateBranch: []const u8,
    createdAt: []const u8,
};

pub const State = struct {
    dir: std.Io.Dir,
    lock: std.Io.File,
    config: ProjectConfig,
    path: [std.fs.max_path_bytes]u8,
    path_len: u16,

    pub fn close(state: *State, io: std.Io) void {
        state.lock.close(io);
        state.dir.close(io);
    }
};

pub fn open(self: *Storage, target: *?State) !void {
    std.debug.assert(target.* == null);
    target.* = @as(State, undefined);
    // Partial handles close here; the caller owns cleanup only after successful opening.
    errdefer target.* = null;
    const state = &target.*.?;
    const io = self.io;
    const source = try self.root_dir();
    defer source.close(io);
    state.config = try self.read_project(source);
    state.path_len = @intCast((try state_path(
        &state.config,
        self.environment.get("HOME"),
        &state.path,
    )).len);
    state.dir = try std.Io.Dir.openDirAbsolute(io, state.path[0..state.path_len], .{
        .follow_symlinks = false,
    });
    errdefer state.dir.close(io);
    const source_cwd: std.process.Child.Cwd = .{ .dir = source };
    const state_cwd: std.process.Child.Cwd = .{ .dir = state.dir };
    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var state_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_common = try self.canonical_git_dir(
        source_cwd,
        "--git-common-dir",
        &source_buffer,
    );
    const state_common = try self.canonical_git_dir(
        state_cwd,
        "--git-common-dir",
        &state_buffer,
    );
    if (!std.mem.eql(u8, source_common, state_common)) return error.GitStateIdentityInvalid;
    const expected = source_buffer[0..try state.dir.realPath(io, &source_buffer)];
    const actual = try self.canonical_git_dir(state_cwd, "--show-toplevel", &state_buffer);
    if (!std.mem.eql(u8, expected, actual)) return error.GitStateIdentityInvalid;
    state.lock = try self.state_lock(state.dir);
    errdefer state.lock.close(io);
    try self.validate(state, "HEAD");
    const disk = try self.read_project(state.dir);
    if (!std.meta.eql(disk, state.config)) return error.GitStateIdentityInvalid;
}

pub fn validate(self: *Storage, state: *const State, ref: []const u8) !void {
    const branch = try self.git(.{ .dir = state.dir }, &.{ "git", "symbolic-ref", "HEAD" });
    if (!std.mem.eql(u8, branch, state_ref ++ "\n")) {
        return error.GitStateBranchInvalid;
    }
    const tree = try self.git(.{ .dir = state.dir }, &.{
        "git", "ls-tree", "--format=%(objectmode) %(objecttype) %(path)", ref,
    });
    if (!std.mem.eql(u8, tree, "040000 tree .tiqet\n")) return error.GitStateTreeInvalid;
    const entry = try self.git(.{ .dir = state.dir }, &.{
        "git", "ls-tree", "--format=%(objectmode) %(objecttype)",
        ref,   "--",      project_config_path,
    });
    if (!std.mem.eql(u8, entry, "100644 blob\n")) return error.GitStateIdentityInvalid;
    var spec_buffer: [128]u8 = undefined;
    const spec = try std.fmt.bufPrint(&spec_buffer, "{s}:" ++ project_config_path, .{ref});
    self.json_allocator.reset();
    const config = try parse_project(self.json_allocator.allocator(), try self.git(
        .{ .dir = state.dir },
        &.{ "git", "show", spec },
    ));
    if (!std.meta.eql(config, state.config)) return error.GitStateIdentityInvalid;
}

pub fn initialize(self: *Storage, target: *?State) !void {
    const source = try self.root_dir();
    defer source.close(self.io);
    const root_cwd: std.process.Child.Cwd = .{ .dir = source };
    const existing: ?ProjectConfig = self.read_project(source) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing != null) {
        // A valid config alone is not a completed initialization. Never return false success.
        try self.open(target);
        return;
    }
    const status = try self.git(root_cwd, &.{
        "git", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--", ".gitignore",
    });
    if (status.len != 0) return error.GitignoreDirty;
    const config = ProjectConfig{
        .id = Event.random_id(self.io),
        .created_at = try Event.format_timestamp(std.Io.Clock.real.now(self.io).toSeconds()),
    };
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try state_path(&config, self.environment.get("HOME"), &path_buffer);
    try source.createDirPath(self.io, project_dir);
    try self.write_project(source, &config);
    try self.update_gitignore(source);
    try self.commit_files(
        root_cwd,
        &.{ project_config_path, ".gitignore" },
        "Initialize Tiqet",
    );
    try std.Io.Dir.cwd().createDirPath(self.io, std.fs.path.dirname(path).?);
    _ = try self.git(root_cwd, &.{
        "git", "worktree", "add", "--orphan", "-b", state_branch, path,
    });
    const state_dir = try std.Io.Dir.openDirAbsolute(
        self.io,
        path,
        .{ .follow_symlinks = false },
    );
    defer state_dir.close(self.io);
    try state_dir.createDirPath(self.io, project_dir ++ "/events");
    try state_dir.createDirPath(self.io, project_dir ++ "/media");
    try self.write_project(state_dir, &config);
    try state_dir.writeFile(self.io, .{
        .sub_path = attributes_path,
        .data = "*.jsonl merge=union\n",
        .flags = .{ .resolve_beneath = true },
    });
    const state_cwd: std.process.Child.Cwd = .{ .dir = state_dir };
    try self.commit_files(
        state_cwd,
        &.{ project_config_path, attributes_path },
        "Initialize Tiqet state",
    );
}

pub fn checkpoint(self: *Storage, state: *const State) !void {
    const status = try self.git(.{ .dir = state.dir }, &.{
        "git", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored",
    });
    if (status.len == 0) return;
    var entries = std.mem.splitScalar(u8, status, 0);
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        if (entry.len < 4 or !std.mem.eql(u8, entry[3..], events_path)) {
            return error.GitStateDirty;
        }
        for ([_][]const u8{ " M", "M ", "MM", "A ", "AM", "??", "!!" }) |allowed| {
            if (std.mem.eql(u8, entry[0..2], allowed)) break;
        } else return error.GitStateDirty;
    }
    try self.commit_files(
        .{ .dir = state.dir },
        &.{events_path},
        "Checkpoint task events",
    );
}

pub fn integrate_remote(self: *Storage, state: *const State) !void {
    _ = try self.git(.{ .dir = state.dir }, &.{ "git", "remote", "get-url", "origin" });
    const remote = try self.git(.{ .dir = state.dir }, &.{
        "git", "ls-remote", "--heads", "origin", state_ref,
    });
    if (remote.len == 0) return;
    _ = try self.git(.{ .dir = state.dir }, &.{
        "git",       "fetch",  "--no-tags", "--no-recurse-submodules",
        "--refmap=", "origin", state_ref,
    });
    try self.validate(state, "FETCH_HEAD");
    _ = self.git(.{ .dir = state.dir }, &.{
        "git",
        "-c",
        "user.name=Tiqet",
        "-c",
        "user.email=tiqet@localhost",
        "rebase",
        "--no-autostash",
        "--no-update-refs",
        "FETCH_HEAD",
    }) catch |err| {
        _ = self.git(
            .{ .dir = state.dir },
            &.{ "git", "rebase", "--abort" },
        ) catch return err;
        return err;
    };
}

fn state_lock(self: *Storage, state_dir: std.Io.Dir) !std.Io.File {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try self.canonical_git_dir(
        .{ .dir = state_dir },
        "--absolute-git-dir",
        &buffer,
    );
    const io = self.io;
    const dir = try std.Io.Dir.openDirAbsolute(io, path, .{});
    defer dir.close(io);
    const lock = try dir.createFile(io, "tiqet-sync.lock", .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .resolve_beneath = true,
    });
    errdefer lock.close(io);
    const operations = [_][]const u8{
        "rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD",
    };
    for (operations) |name| {
        dir.access(io, name, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        return error.GitStateOperationInProgress;
    }
    return lock;
}

fn commit_files(
    self: *Storage,
    cwd: std.process.Child.Cwd,
    comptime paths: []const []const u8,
    message: []const u8,
) !void {
    _ = try self.git(cwd, &[_][]const u8{ "git", "add", "--force", "--" } ++ paths);
    _ = try self.git(cwd, &[_][]const u8{
        "git",    "-c",     "user.name=Tiqet", "-c",    "user.email=tiqet@localhost",
        "commit", "--only", "-m",              message, "--",
    } ++ paths);
}

pub fn read_project(self: *Storage, dir: std.Io.Dir) !ProjectConfig {
    const io = self.io;
    const file = try dir.openFile(io, project_config_path, .{
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(io);
    const count = try file.readPositionalAll(
        io,
        self.line[0 .. project_config_bytes_max + 1],
        0,
    );
    if (count > project_config_bytes_max) return error.InvalidProjectConfig;
    self.json_allocator.reset();
    return parse_project(self.json_allocator.allocator(), self.line[0..count]);
}

fn write_project(self: *Storage, dir: std.Io.Dir, config: *const ProjectConfig) !void {
    const io = self.io;
    var writer = std.Io.Writer.fixed(self.encoded[0..project_config_bytes_max]);
    try std.json.Stringify.value(WireProject{
        .projectId = &config.id,
        .stateBranch = state_branch,
        .createdAt = &config.created_at,
    }, .{ .whitespace = .indent_2 }, &writer);
    try writer.writeByte('\n');
    const file = try dir.createFile(io, project_config_path, .{
        .exclusive = true,
        .resolve_beneath = true,
    });
    defer file.close(io);
    try file.writePositionalAll(io, writer.buffered(), 0);
    try file.sync(io);
}

fn update_gitignore(self: *Storage, source: std.Io.Dir) !void {
    const io = self.io;
    const bytes = source.readFile(
        io,
        ".gitignore",
        self.line[0..gitignore_bytes_max],
    ) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    if (std.mem.indexOf(u8, bytes, gitignore_entries) != null) return;
    var writer = std.Io.Writer.fixed(self.encoded[0..gitignore_bytes_max]);
    try writer.writeAll(bytes);
    if (bytes.len != 0 and bytes[bytes.len - 1] != '\n') try writer.writeByte('\n');
    try writer.writeAll(gitignore_entries);
    try source.writeFile(io, .{
        .sub_path = ".gitignore",
        .data = writer.buffered(),
        .flags = .{ .resolve_beneath = true },
    });
}

fn root_dir(self: *Storage) !std.Io.Dir {
    const path = try git_path(try self.git(self.cwd, &.{
        "git", "rev-parse", "--show-toplevel",
    }));
    return std.Io.Dir.openDirAbsolute(self.io, path, .{});
}

fn canonical_git_dir(
    self: *Storage,
    cwd: std.process.Child.Cwd,
    argument: []const u8,
    buffer: []u8,
) ![]const u8 {
    const path = try git_path(try self.git(cwd, &.{
        "git", "rev-parse", "--path-format=absolute", argument,
    }));
    const dir = try std.Io.Dir.openDirAbsolute(self.io, path, .{});
    defer dir.close(self.io);
    return buffer[0..try dir.realPath(self.io, buffer)];
}

pub fn git(self: *Storage, cwd: std.process.Child.Cwd, arguments: []const []const u8) ![]const u8 {
    return self.git_read(cwd, arguments, null);
}

// Compare a committed blob with the working prefix, or capture bounded metadata.
// Short pipe reads are not EOF. Both paths consume the complete output.
fn git_read(
    self: *Storage,
    cwd: std.process.Child.Cwd,
    arguments: []const []const u8,
    prefix: ?std.Io.File,
) ![]const u8 {
    const io = self.io;
    var child = try std.process.spawn(io, .{
        .argv = arguments,
        .cwd = cwd,
        .environ_map = self.environment,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    errdefer child.kill(io);
    var total: u64 = 0;
    while (true) {
        const count = child.stdout.?.readStreaming(io, &.{self.chunk}) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (count == 0) break;
        if (prefix) |file| {
            try check_history_capacity(total, count);
            const read = try file.readPositionalAll(io, self.compare[0..count], total);
            if (read != count) return error.EventHistoryRewritten;
            if (!std.mem.eql(u8, self.chunk[0..count], self.compare[0..count])) {
                return error.EventHistoryRewritten;
            }
        } else {
            if (total + count > git_output_bytes_max) return error.GitOutputTooLong;
            @memcpy(self.output[@intCast(total)..][0..count], self.chunk[0..count]);
        }
        total += count;
    }
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.GitCommandFailed;
    return if (prefix != null) "" else self.output[0..@intCast(total)];
}

// On success, the caller owns the file handle and must close it after replay.
pub fn open_log(self: *Storage, state: *const State) !?std.Io.File {
    const file = state.dir.openFile(self.io, events_path, .{
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            const entry = try self.git(.{ .dir = state.dir }, &.{
                "git", "ls-tree", "HEAD", "--", events_path,
            });
            if (entry.len != 0) return error.EventHistoryRewritten;
            return null;
        },
        else => return err,
    };
    errdefer file.close(self.io);
    const stat = try file.stat(self.io);
    if (stat.kind != .file) return error.InvalidEventLog;
    try check_history_capacity(stat.size, 0);
    const entry = try self.git(.{ .dir = state.dir }, &.{
        "git", "ls-tree", "--format=%(objectmode) %(objecttype)", "HEAD", "--", events_path,
    });
    if (entry.len != 0) {
        if (!std.mem.eql(u8, entry, "100644 blob\n")) return error.InvalidEventLog;
        _ = try self.git_read(
            .{ .dir = state.dir },
            &.{ "git", "show", "HEAD:" ++ events_path },
            file,
        );
    }
    return file;
}

pub fn append(self: *Storage, state: *const State, bytes: []const u8) !void {
    const io = self.io;
    const file = try state.dir.createFile(io, events_path, .{
        .read = true,
        .truncate = false,
        .resolve_beneath = true,
    });
    defer file.close(io);
    const size = (try file.stat(io)).size;
    try check_history_capacity(size, bytes.len);
    file.writePositionalAll(io, bytes, size) catch |err| {
        file.setLength(io, size) catch return error.EventDurabilityUnknown;
        file.sync(io) catch return error.EventDurabilityUnknown;
        return err;
    };
    // A sync failure has an indeterminate durability outcome; do not report a clean retry.
    file.sync(io) catch return error.EventDurabilityUnknown;
    // The first append also creates a directory entry; syncing only the file is insufficient.
    const directory = state.dir.openFile(io, project_dir ++ "/events", .{
        .allow_directory = true,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch return error.EventDurabilityUnknown;
    defer directory.close(io);
    directory.sync(io) catch return error.EventDurabilityUnknown;
}

pub fn push(self: *Storage, state: *const State) !void {
    _ = try self.git(.{ .dir = state.dir }, &.{
        "git",
        "-c",
        "remote.origin.mirror=false",
        "push",
        "--no-follow-tags",
        "--recurse-submodules=no",
        "--set-upstream",
        "origin",
        state_ref ++ ":" ++ state_ref,
    });
}

fn parse_project(allocator: std.mem.Allocator, bytes: []const u8) !ProjectConfig {
    if (bytes.len > project_config_bytes_max) return error.InvalidProjectConfig;
    const wire = std.json.parseFromSliceLeaky(WireProject, allocator, bytes, .{
        .allocate = .alloc_if_needed,
        .max_value_len = project_config_bytes_max,
        .ignore_unknown_fields = false,
    }) catch return error.InvalidProjectConfig;
    if (!std.mem.eql(u8, wire.stateBranch, state_branch)) return error.InvalidProjectConfig;
    return .{
        .id = Event.parse_id(wire.projectId) catch return error.InvalidProjectConfig,
        .created_at = Event.parse_timestamp(wire.createdAt) catch return error.InvalidProjectConfig,
    };
}

pub fn check_history_capacity(size: u64, additional: u64) !void {
    if (size > history_bytes_max) return error.EventCapacityExceeded;
    if (additional > history_bytes_max - size) return error.EventCapacityExceeded;
}

fn git_path(bytes: []const u8) ![]const u8 {
    if (bytes.len < 2 or bytes[0] != '/' or bytes[bytes.len - 1] != '\n') {
        return error.InvalidGitPath;
    }
    return bytes[0 .. bytes.len - 1];
}

pub fn state_path(config: *const ProjectConfig, home: ?[]const u8, buffer: []u8) ![]u8 {
    const root = home orelse return error.HomeMissing;
    if (root.len == 0 or root[0] != '/') return error.InvalidHome;
    return std.fmt.bufPrint(buffer, "{s}/.tiqet/worktrees/{s}", .{ root, config.id });
}

test "project configuration codec preserves identity and rejects invalid input" {
    var memory: [2048]u8 = undefined;
    var pool = std.heap.FixedBufferAllocator.init(&memory);
    const config = try parse_project(
        pool.allocator(),
        "{\"stateBranch\":\"__tiqet_state__\"," ++
            "\"projectId\":\"11111111111111111111111111111111\"," ++
            "\"createdAt\":\"2000-01-01T00:00:00Z\"}",
    );
    try std.testing.expectEqualStrings("1" ** 32, &config.id);
    try std.testing.expectError(error.InvalidProjectConfig, parse_project(pool.allocator(), "{}"));
}

test "history byte bounds reject overflow" {
    try check_history_capacity(history_bytes_max, 0);
    try check_history_capacity(history_bytes_max - 1, 1);
    try std.testing.expectError(
        error.EventCapacityExceeded,
        check_history_capacity(history_bytes_max, 1),
    );
    try std.testing.expectError(
        error.EventCapacityExceeded,
        check_history_capacity(std.math.maxInt(u64), 1),
    );
}
