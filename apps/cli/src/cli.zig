const std = @import("std");
const assert = std.debug.assert;
const tiqet_core = @import("tiqet_core");

pub const usage =
    \\Usage: tiqet <command>
    \\
    \\  --help                         Show this help without accessing project state
    \\  --version                      Show the build version
    \\  init                           Initialize state and commit source configuration
    \\  create [--creator NAME] [--description TEXT | --description-file PATH] [--] TITLE
    \\                                 Create a task; print its full ID
    \\  list                           List open tasks, sorted by ID
    \\  show ID                        Show an open or completed task and its description
    \\  done ID                        Complete a task (no reopen command)
    \\  sync                           Commit pending events, fetch/rebase/push via origin
    \\
    \\IDs are full lowercase 32-character hexadecimal strings, not prefixes.
    \\Create accepts one title and one description source. Options can surround the title.
    \\--description-file - reads stdin until EOF; other paths are relative to the caller.
    \\No description option means no stdin read. Use -- before a dash-prefixed title.
    \\Descriptions are UTF-8, at most 262144 bytes. Creator defaults to local.
    \\Local task commands need no sync.
    \\Documentation: https://github.com/frontman-ai/tiqet#readme
    \\
;

// Keep input separate from core replay scratch and alive until create returns.
var description_buffer: [tiqet_core.description_bytes_max + 1]u8 = undefined;
var create_mutex: std.Io.Mutex = .init;

pub fn execute(
    init: *const std.process.Init,
    arguments: []const []const u8,
    output: *std.Io.Writer,
) !void {
    assert(@intFromPtr(init) != 0);
    assert(@intFromPtr(output) != 0);
    if (arguments.len == 0) return error.MissingCommand;

    if (std.mem.eql(u8, arguments[0], "--help")) {
        if (arguments.len != 1) return error.UnexpectedArgument;
        return output.writeAll(usage);
    }
    if (std.mem.eql(u8, arguments[0], "--version")) {
        if (arguments.len != 1) return error.UnexpectedArgument;
        return output.writeAll(tiqet_core.version_line);
    }
    if (std.mem.eql(u8, arguments[0], "init")) {
        if (arguments.len != 1) return error.UnexpectedArgument;
        const options = tiqet_core.InitializeOptions{ .process = init.* };
        return tiqet_core.initialize(&options);
    }
    if (std.mem.eql(u8, arguments[0], "create")) {
        const parsed = try parse_create(arguments);
        try create_mutex.lock(init.io);
        defer create_mutex.unlock(init.io);
        const options = tiqet_core.CreateOptions{
            .process = init.*,
            .title = parsed.title,
            .creator = parsed.creator,
            .description = try load_description(init.io, parsed.description),
        };
        return tiqet_core.create(&options, output);
    }
    if (std.mem.eql(u8, arguments[0], "done")) {
        if (arguments.len != 2) return error.UnexpectedArgument;
        const options = tiqet_core.DoneOptions{ .process = init.*, .task_id = arguments[1] };
        return tiqet_core.done(&options);
    }
    if (std.mem.eql(u8, arguments[0], "show")) {
        if (arguments.len != 2) return error.UnexpectedArgument;
        const options = tiqet_core.ShowOptions{ .process = init.*, .task_id = arguments[1] };
        return tiqet_core.show(&options, output);
    }
    if (std.mem.eql(u8, arguments[0], "list")) {
        if (arguments.len != 1) return error.UnexpectedArgument;
        const options = tiqet_core.ListOptions{ .process = init.* };
        return tiqet_core.list(&options, output);
    }
    if (std.mem.eql(u8, arguments[0], "sync")) {
        if (arguments.len != 1) return error.UnexpectedArgument;
        const options = tiqet_core.SyncOptions{ .process = init.* };
        return tiqet_core.sync(&options);
    }
    return error.UnknownCommand;
}

const DescriptionSource = union(enum) { text: []const u8, file: []const u8 };
const ParsedCreate = struct {
    title: []const u8,
    creator: []const u8,
    description: ?DescriptionSource,
};

fn parse_create(arguments: []const []const u8) !ParsedCreate {
    var title: ?[]const u8 = null;
    var creator: ?[]const u8 = null;
    var description: ?DescriptionSource = null;
    var positional = false;
    var index: u32 = 1;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (!positional and std.mem.eql(u8, argument, "--")) {
            positional = true;
            continue;
        }
        if (!positional and std.mem.startsWith(u8, argument, "-")) {
            index += 1;
            if (index == arguments.len) return error.UnexpectedArgument;
            const value = arguments[index];
            if (std.mem.eql(u8, argument, "--creator")) {
                if (creator != null) return error.UnexpectedArgument;
                creator = value;
            } else if (std.mem.eql(u8, argument, "--description")) {
                if (description != null) return error.UnexpectedArgument;
                description = .{ .text = value };
            } else if (std.mem.eql(u8, argument, "--description-file")) {
                if (description != null) return error.UnexpectedArgument;
                description = .{ .file = value };
            } else return error.UnexpectedArgument;
        } else {
            if (title != null) return error.UnexpectedArgument;
            title = argument;
        }
    }
    return .{
        .title = title orelse return error.UnexpectedArgument,
        .creator = creator orelse "local",
        .description = description,
    };
}

fn load_description(io: std.Io, source: ?DescriptionSource) !?[]const u8 {
    return switch (source orelse return null) {
        .text => |text| text,
        .file => |path| file: {
            if (std.mem.eql(u8, path, "-")) break :file try read_description(io, .stdin());
            const dir = std.Io.Dir.cwd();
            // Reject special files before open, then check the opened file as well.
            if ((try dir.statFile(io, path, .{ .follow_symlinks = true })).kind != .file) {
                return error.InvalidDescriptionFile;
            }
            const input = try dir.openFile(io, path, .{
                .allow_directory = false,
                .follow_symlinks = true,
                .allow_ctty = false,
            });
            defer input.close(io);
            if ((try input.stat(io)).kind != .file) return error.InvalidDescriptionFile;
            break :file try read_description(io, input);
        },
    };
}

fn read_description(io: std.Io, file: std.Io.File) ![]const u8 {
    var len: u32 = 0;
    while (len < description_buffer.len) {
        const count = file.readStreaming(io, &.{description_buffer[len..]}) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (count == 0) break;
        len += @intCast(count);
        if (len > tiqet_core.description_bytes_max) return error.DescriptionTooLong;
    }
    return description_buffer[0..len];
}
