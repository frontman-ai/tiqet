const std = @import("std");

const Command = @This();

// One statically reserved execution context. Never copy it: allocators and handles
// borrow its backing storage. The mutex serializes reuse; State locks other processes.
io: std.Io = undefined,
storage: Storage = undefined,
mutex: std.Io.Mutex = .init,
state: ?State = null,
command_storage: [8 * 1024 * 1024]u8 = undefined,
command_allocator: std.heap.FixedBufferAllocator = undefined,
json_storage: [json_scratch_bytes_max]u8 = undefined,
json_allocator: std.heap.FixedBufferAllocator = undefined,
output: [git_output_bytes_max + 1]u8 = undefined,
line: [event_record_bytes_max]u8 = undefined,
encoded: [event_record_bytes_max]u8 = undefined,
chunk: [4096]u8 = undefined,
compare: [4096]u8 = undefined,
projection: Replay = .{},
order: [task_count_max]Id = undefined,

const Event = @import("event.zig");
const Replay = @import("replay.zig");
const Storage = @import("storage.zig");
const State = Storage.State;
const Creation = Event.Creation;
const Id = Event.Id;
const Task = Replay.Task;
pub const description_bytes_max = Event.description_bytes_max;
const event_record_bytes_max = Event.record_bytes_max;
const json_scratch_bytes_max = Event.json_scratch_bytes_max;
const task_count_max = Replay.task_count_max;
const event_count_max = Replay.event_count_max;
const git_output_bytes_max = Storage.git_output_bytes_max;

pub const InitializeOptions = struct {
    process: std.process.Init,
    cwd: std.process.Child.Cwd = .inherit,
};
pub const ListOptions = InitializeOptions;
pub const SyncOptions = InitializeOptions;
pub const CreateOptions = struct {
    process: std.process.Init,
    cwd: std.process.Child.Cwd = .inherit,
    title: []const u8,
    creator: []const u8 = "local",
    description: ?[]const u8 = null,
};
pub const DoneOptions = struct {
    process: std.process.Init,
    cwd: std.process.Child.Cwd = .inherit,
    task_id: []const u8,
};

pub const ShowOptions = DoneOptions;

pub fn run_create(options: *const CreateOptions, output: *std.Io.Writer) !void {
    const creation = Creation{
        .title = Event.validate_text(options.title, 160) catch return error.InvalidTaskTitle,
        .creator = Event.validate_text(options.creator, 64) catch return error.InvalidCreator,
        .description = try Event.validate_description(options.description),
    };
    try command.begin(options.process.io, options.process.environ_map, options.cwd);
    defer command.end();
    try command.create(&creation, output);
}

pub fn run_done(options: *const DoneOptions) !void {
    const id = Event.parse_id(options.task_id) catch return error.InvalidTaskId;
    try command.begin(options.process.io, options.process.environ_map, options.cwd);
    defer command.end();
    try command.done(id);
}

pub fn run_show(options: *const ShowOptions, output: *std.Io.Writer) !void {
    const id = Event.parse_id(options.task_id) catch return error.InvalidTaskId;
    try command.begin(options.process.io, options.process.environ_map, options.cwd);
    defer command.end();
    try command.show(id, output);
}

pub fn run_list(options: *const ListOptions, output: *std.Io.Writer) !void {
    try command.begin(options.process.io, options.process.environ_map, options.cwd);
    defer command.end();
    try command.list(output);
}

pub fn run_sync(options: *const SyncOptions) !void {
    try command.begin(options.process.io, options.process.environ_map, options.cwd);
    defer command.end();
    try command.sync();
}

pub fn run_initialize(options: *const InitializeOptions) !void {
    try command.begin(options.process.io, options.process.environ_map, options.cwd);
    defer command.end();
    try command.storage.initialize(&command.state);
}

fn begin(
    self: *Command,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    cwd: std.process.Child.Cwd,
) !void {
    try self.mutex.lock(io);
    std.debug.assert(self.state == null);
    self.io = io;
    self.command_allocator = std.heap.FixedBufferAllocator.init(&self.command_storage);
    self.json_allocator = std.heap.FixedBufferAllocator.init(&self.json_storage);
    self.storage = .{
        .io = io,
        .environment = environment,
        .cwd = cwd,
        .line = self.line[0..Storage.text_scratch_bytes_max],
        .encoded = self.encoded[0..Storage.text_scratch_bytes_max],
        .output = &self.output,
        .chunk = &self.chunk,
        .compare = &self.compare,
        .json_allocator = &self.json_allocator,
    };
    self.projection = .{};
    errdefer self.end();
    const allocator = self.command_allocator.allocator();
    try self.projection.tasks.ensureTotalCapacity(allocator, task_count_max);
    try self.projection.events.ensureTotalCapacity(allocator, event_count_max);
}

fn end(self: *Command) void {
    const io = self.io;
    if (self.state) |*opened| opened.close(io);
    self.state = null;
    self.projection = .{};
    self.command_allocator.reset();
    self.json_allocator.reset();
    self.storage = undefined;
    self.io = undefined;
    self.mutex.unlock(io);
}

fn load(self: *Command) !void {
    try self.storage.open(&self.state);
    try self.replay_history();
}

fn create(self: *Command, creation: *const Creation, output: *std.Io.Writer) !void {
    try self.load();
    const event = Event{
        .id = Event.random_id(self.io),
        .task_id = Event.random_id(self.io),
        .created_at = try Event.format_timestamp(std.Io.Clock.real.now(self.io).toSeconds()),
        .payload = .{ .created = creation.* },
    };
    try self.append(&event);
    output.print("{s}\n", .{event.task_id}) catch return error.EventPersistedOutputFailed;
}

fn done(self: *Command, id: Id) !void {
    try self.load();
    const task = self.projection.tasks.get(id) orelse return error.TaskNotFound;
    if (task.creation == null) return error.TaskNotFound;
    if (task.completed) return;
    const event = Event{
        .id = Event.random_id(self.io),
        .task_id = id,
        .created_at = try Event.format_timestamp(std.Io.Clock.real.now(self.io).toSeconds()),
        .payload = .completed,
    };
    try self.append(&event);
}

fn show(self: *Command, id: Id, output: *std.Io.Writer) !void {
    try self.load();
    const task = self.projection.tasks.get(id) orelse return error.TaskNotFound;
    const creation = task.creation orelse return error.TaskNotFound;
    const creation_id = task.creation_event_id orelse return error.TaskNotFound;
    // ponytail: second linear scan avoids retained descriptions; add an index only after measured read latency requires it.
    const file = (try self.storage.open_log(&self.state.?)) orelse return error.InvalidEventLog;
    defer file.close(self.io);
    var reader = file.reader(self.io, &self.line);
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.InvalidEventLog,
            else => return err,
        };
        const event = try self.parse_event(line);
        if (!std.mem.eql(u8, &event.id, &creation_id)) continue;
        if (!std.mem.eql(u8, &event.task_id, &id)) return error.InvalidEventLog;
        const description = switch (event.payload) {
            .created => |details| details.description,
            .completed => return error.InvalidEventLog,
        };
        try output.print("ID: {s}\nTitle: {s}\nStatus: {s}\nCreator: {s}\n", .{
            id, creation.title, if (task.completed) "completed" else "open", creation.creator,
        });
        if (description) |body| {
            try output.writeAll("\nDescription:\n");
            try output.writeAll(body);
        }
        return;
    }
}

fn list(self: *Command, output: *std.Io.Writer) !void {
    try self.load();
    const ids = self.order[0..self.projection.tasks.count()];
    @memcpy(ids, self.projection.tasks.keys());
    std.mem.sort(Id, ids, {}, struct {
        fn less(_: void, a: Id, b: Id) bool {
            return std.mem.lessThan(u8, &a, &b);
        }
    }.less);
    for (ids) |id| {
        const task = self.projection.tasks.getPtr(id).?;
        if (task.completed) continue;
        if (task.creation) |*creation| {
            try output.print("{s} open {s} {s}\n", .{
                id, creation.creator, creation.title,
            });
        }
    }
}

fn sync(self: *Command) !void {
    try self.load();
    try self.storage.checkpoint(&self.state.?);
    try self.storage.integrate_remote(&self.state.?);
    try self.storage.validate(&self.state.?, "HEAD");
    try self.replay_history();
    try self.storage.push(&self.state.?);
}

fn replay_history(self: *Command) !void {
    self.projection.clear();
    const file = (try self.storage.open_log(&self.state.?)) orelse return;
    defer file.close(self.io);
    var reader = file.reader(self.io, &self.line);
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                if (reader.interface.buffered().len != 0) return error.InvalidEventLog;
                break;
            },
            else => return err,
        };
        const event = try self.parse_event(line);
        _ = try self.preview(&event);
    }
}

fn preview(self: *Command, event: *const Event) ![]const u8 {
    const bytes = try event.encode(&self.encoded);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    try self.projection.apply(event, digest, self.command_allocator.allocator());
    return bytes;
}

fn append(self: *Command, event: *const Event) !void {
    // Preview all reducer checks, then persist the same bytes without re-encoding.
    const bytes = try self.preview(event);
    try self.storage.append(&self.state.?, bytes);
}

fn parse_event(self: *Command, bytes: []const u8) !Event {
    self.json_allocator.reset();
    return Event.parse(self.json_allocator.allocator(), bytes);
}

var command: Command = .{};

const test_environment = std.process.Environ.Map.init(std.testing.allocator);

test "preallocated tables reject capacity overflow without losing existing tasks" {
    try command.begin(std.testing.io, &test_environment, .inherit);
    defer command.end();
    const allocator = command.command_allocator.allocator();
    var event = Event{
        .id = undefined,
        .task_id = undefined,
        .created_at = "2000-01-01T00:00:00Z".*,
        .payload = .{ .created = .{ .title = "t" ** 160, .creator = "c" ** 64 } },
    };
    for (0..task_count_max) |index| {
        _ = try std.fmt.bufPrint(&event.id, "{x:0>32}", .{index});
        event.task_id = event.id;
        try command.projection.apply(&event, try event_digest(&event), allocator);
    }
    _ = try std.fmt.bufPrint(&event.id, "{x:0>32}", .{task_count_max});
    event.task_id = event.id;
    try std.testing.expectError(
        error.TaskCapacityExceeded,
        command.projection.apply(&event, try event_digest(&event), allocator),
    );
    try std.testing.expectEqual(task_count_max, command.projection.tasks.count());
    event.task_id = ("0" ** 32).*;
    event.payload = .completed;
    for (task_count_max..event_count_max) |index| {
        _ = try std.fmt.bufPrint(&event.id, "{x:0>32}", .{index});
        try command.projection.apply(&event, try event_digest(&event), allocator);
    }
    _ = try std.fmt.bufPrint(&event.id, "{x:0>32}", .{event_count_max});
    try std.testing.expectError(
        error.EventCapacityExceeded,
        command.projection.apply(&event, try event_digest(&event), allocator),
    );
    try std.testing.expectEqual(event_count_max, command.projection.events.count());
    try std.testing.expect(command.projection.tasks.get(event.task_id).?.completed);
    // A second maximum-text projection fits without resetting command-owned allocations.
    command.projection.clear();
    event.payload = .{ .created = .{ .title = "t" ** 160, .creator = "c" ** 64 } };
    for (0..task_count_max) |index| {
        _ = try std.fmt.bufPrint(&event.id, "{x:0>32}", .{index});
        event.task_id = event.id;
        try command.projection.apply(&event, try event_digest(&event), allocator);
    }
    try std.testing.expectEqual(task_count_max, command.projection.tasks.count());
}

test "replay owns text after input and parser scratch are overwritten" {
    try command.begin(std.testing.io, &test_environment, .inherit);
    defer command.end();
    const json = "{\"version\":1,\"id\":\"11111111111111111111111111111111\"," ++
        "\"type\":\"task-created\",\"taskId\":\"22222222222222222222222222222222\"," ++
        "\"title\":\"say \\\"hi\\\"\",\"creator\":\"local\"," ++
        "\"createdAt\":\"2000-01-01T00:00:00Z\"}";
    @memcpy(command.line[0..json.len], json);
    const event = try command.parse_event(command.line[0..json.len]);
    _ = try command.preview(&event);
    // Escaped title bytes use parser scratch; unescaped creator bytes can borrow the input.
    @memset(&command.json_storage, 0xa5);
    @memset(&command.line, 0xa5);
    @memset(&command.encoded, 0xa5);
    const creation = command.projection.tasks.get(event.task_id).?.creation.?;
    try std.testing.expectEqualStrings("say \"hi\"", creation.title);
    try std.testing.expectEqualStrings("local", creation.creator);
    try std.testing.expect(command.command_allocator.ownsSlice(@constCast(creation.title)));
    try std.testing.expect(command.command_allocator.ownsSlice(@constCast(creation.creator)));
}

test "command memory is reclaimed after success and allocation failure" {
    // Exercise begin/end repeatedly in one process, rather than launching fresh CLI processes.
    for (0..3) |_| {
        try test_command_memory(false);
        try std.testing.expectEqual(@as(usize, 0), command.command_allocator.end_index);
        try std.testing.expectEqual(@as(u32, 0), command.projection.tasks.count());
        try std.testing.expectError(error.OutOfMemory, test_command_memory(true));
        try std.testing.expectEqual(@as(usize, 0), command.command_allocator.end_index);
        try std.testing.expectEqual(@as(u32, 0), command.projection.events.count());
    }
}

test "creation descriptions use bounded borrowed storage" {
    try command.begin(std.testing.io, &test_environment, .inherit);
    defer command.end();
    const body = try std.testing.allocator.alloc(u8, description_bytes_max);
    defer std.testing.allocator.free(body);
    @memset(body, '\n');
    var source = test_creation(body);
    for (0..2) |index| {
        _ = try std.fmt.bufPrint(&source.id, "{x:0>32}", .{index});
        source.task_id = source.id;
        const decoded = try test_decode_event(&source);
        _ = try command.preview(&decoded);
        @memset(&command.line, 0xa5);
        @memset(&command.json_storage, 0xa5);
    }
    for (command.projection.tasks.keys(), command.projection.tasks.values()) |id, task| {
        try std.testing.expectEqualStrings("task", task.creation.?.title);
        try std.testing.expectEqualStrings("local", task.creation.?.creator);
        try std.testing.expectEqual(id, task.creation_event_id.?);
    }
    try std.testing.expect(@sizeOf(Task) <= 320);
    try std.testing.expect(@sizeOf(Event) <= 512);
    try std.testing.expect(@sizeOf(Command) <= 16 * 1024 * 1024);
}

test "scale: bounded replay memory with thousands of descriptions" {
    const report = try std.testing.environ.contains(std.testing.allocator, "TIQET_SCALE_REPORT");
    const body = try std.testing.allocator.alloc(u8, 32 * 1024);
    defer std.testing.allocator.free(body);
    @memset(body, 'x');
    @memcpy(body[0..11], "## Details\n");
    for ([_]u32{ 1000, 4000 }) |count| {
        for ([_]u32{ 0, 1024, 16 * 1024, 32 * 1024 }) |length| {
            try command.begin(std.testing.io, &test_environment, .inherit);
            defer command.end();
            const started = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
            var event = test_creation(if (length == 0) null else body[0..length]);
            var bytes: u64 = 0;
            var parser_peak: usize = 0;
            for (0..count) |index| {
                _ = try std.fmt.bufPrint(&event.id, "{x:0>32}", .{index});
                event.task_id = event.id;
                bytes += (try encode_test_event(&event)).len;
                const decoded = try test_decode_event(&event);
                parser_peak = @max(parser_peak, command.json_allocator.end_index);
                _ = try command.preview(&decoded);
            }
            try Storage.check_history_capacity(bytes, 0);
            try std.testing.expectEqual(count, command.projection.tasks.count());
            const elapsed = std.Io.Clock.awake.now(std.testing.io).toMilliseconds() - started;
            if (report) std.debug.print(
                "scale tasks={d} description={d} history={d} ms={d} command={d} parser={d}\n",
                .{
                    count,
                    length,
                    bytes,
                    elapsed,
                    command.command_allocator.end_index,
                    parser_peak,
                },
            );
        }
    }
    if (report) std.debug.print(
        "layout task={d} event={d} command_backing={d} parser_budget={d}\n",
        .{ @sizeOf(Task), @sizeOf(Event), @sizeOf(Command), json_scratch_bytes_max },
    );
}

test "command cleanup releases storage after partial open and replay failures" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const source = try temporary.dir.createDirPathOpen(io, "source", .{});
    defer source.close(io);
    var home: [std.fs.max_path_bytes]u8 = undefined;
    const home_path = home[0..try temporary.dir.realPath(io, &home)];
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", home_path);
    try environment.put("GIT_CONFIG_NOSYSTEM", "1");
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try setup_command_repository(&environment, source, &path_buffer);
    const storage = try std.Io.Dir.openDirAbsolute(io, path, .{});
    defer storage.close(io);
    var config_buffer: [Storage.project_config_bytes_max]u8 = undefined;
    const config = try storage.readFile(io, Storage.project_config_path, &config_buffer);
    // Config failure occurs after acquiring the metadata lock. Replay failure occurs
    // after storage opens. Both must leave the singleton reusable in this process.
    for ([_]bool{ true, false }) |invalid_config| {
        const corrupted_path = if (invalid_config)
            Storage.project_config_path
        else
            Storage.events_path;
        try storage.writeFile(io, .{ .sub_path = corrupted_path, .data = "{}\n" });
        const expected: anyerror = if (invalid_config)
            error.InvalidProjectConfig
        else
            error.InvalidEventLog;
        try std.testing.expectError(expected, test_load_command(&environment, source));
        try std.testing.expect(command.state == null);
        try std.testing.expectEqual(@as(usize, 0), command.command_allocator.end_index);
        try std.testing.expectEqual(@as(usize, 0), command.json_allocator.end_index);
        try std.testing.expectEqual(@as(u32, 0), command.projection.tasks.count());
        if (invalid_config) {
            try storage.writeFile(io, .{ .sub_path = Storage.project_config_path, .data = config });
        } else try storage.deleteFile(io, Storage.events_path);
        // Reacquiring the exclusive lock proves the failed execution released it.
        try test_load_command(&environment, source);
        try std.testing.expect(command.state == null);
    }
}

test "show writer failure releases storage and borrowed description scratch" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const source = try temporary.dir.createDirPathOpen(io, "source", .{});
    defer source.close(io);
    var home: [std.fs.max_path_bytes]u8 = undefined;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", home[0..try temporary.dir.realPath(io, &home)]);
    try environment.put("GIT_CONFIG_NOSYSTEM", "1");
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try setup_command_repository(&environment, source, &path_buffer);
    const storage = try std.Io.Dir.openDirAbsolute(io, path, .{});
    defer storage.close(io);
    const event = test_creation("## Details\r\n\tSay \"hello\" \\ 世界  ");
    try storage.writeFile(io, .{
        .sub_path = Storage.events_path,
        .data = try encode_test_event(&event),
    });
    var process: std.process.Init = undefined;
    process.io = io;
    process.environ_map = &environment;
    const options = ShowOptions{
        .process = process,
        .cwd = .{ .dir = source },
        .task_id = &event.task_id,
    };
    var buffer: [512]u8 = undefined;
    // Fail inside the description, after metadata has already been written.
    var small = std.Io.Writer.fixed(buffer[0..100]);
    try std.testing.expectError(error.WriteFailed, run_show(&options, &small));
    try std.testing.expect(command.state == null);
    try std.testing.expectEqual(@as(usize, 0), command.command_allocator.end_index);
    try std.testing.expectEqual(@as(usize, 0), command.json_allocator.end_index);
    try std.testing.expectEqual(@as(u32, 0), command.projection.tasks.count());
    @memset(&command.line, 0xa5);
    @memset(&command.json_storage, 0xa5);
    var output = std.Io.Writer.fixed(&buffer);
    try run_show(&options, &output);
    try std.testing.expectEqualStrings(
        "ID: " ++ "2" ** 32 ++ "\nTitle: task\nStatus: open\nCreator: local\n\nDescription:\n" ++
            "## Details\r\n\tSay \"hello\" \\ 世界  ",
        output.buffered(),
    );
    try std.testing.expect(command.state == null);
    try std.testing.expectEqual(@as(usize, 0), command.command_allocator.end_index);
}

test "command preview hashes the exact bytes returned for append" {
    try command.begin(std.testing.io, &test_environment, .inherit);
    defer command.end();
    const event = test_creation("## Details\nSay \"hello\" 🌍");
    const bytes = try command.preview(&event);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    try std.testing.expectEqual(digest, command.projection.events.get(event.id).?);
    try std.testing.expectEqual(@intFromPtr(&command.encoded), @intFromPtr(bytes.ptr));
    try std.testing.expectEqual(@as(u32, 1), command.projection.tasks.count());
    const decoded = try command.parse_event(bytes);
    try std.testing.expectEqualStrings(
        event.payload.created.description.?,
        decoded.payload.created.description.?,
    );
}

fn test_command_memory(exhaust: bool) !void {
    try command.begin(std.testing.io, &test_environment, .inherit);
    defer command.end();
    const allocator = command.command_allocator.allocator();
    if (exhaust) {
        const available = command.command_storage.len - command.command_allocator.end_index;
        _ = try allocator.alloc(u8, available);
    }
    const event = Event{
        .id = ("1" ** 32).*,
        .task_id = ("2" ** 32).*,
        .created_at = "2000-01-01T00:00:00Z".*,
        .payload = .{ .created = .{ .title = "task", .creator = "local" } },
    };
    try command.projection.apply(&event, try event_digest(&event), allocator);
}

fn test_creation(description: ?[]const u8) Event {
    return .{
        .id = ("1" ** 32).*,
        .task_id = ("2" ** 32).*,
        .created_at = "2000-01-01T00:00:00Z".*,
        .payload = .{ .created = .{
            .title = "task",
            .creator = "local",
            .description = description,
        } },
    };
}

fn test_decode_event(event: *const Event) !Event {
    const bytes = try encode_test_event(event);
    @memcpy(command.line[0..bytes.len], bytes);
    return command.parse_event(command.line[0..bytes.len]);
}

fn setup_command_repository(
    environment: *const std.process.Environ.Map,
    source: std.Io.Dir,
    buffer: []u8,
) ![]u8 {
    try command.begin(std.testing.io, environment, .{ .dir = source });
    defer command.end();
    _ = try command.storage.git(command.storage.cwd, &.{ "git", "init", "-q" });
    try command.storage.initialize(&command.state);
    const config = try command.storage.read_project(source);
    return Storage.state_path(&config, environment.get("HOME"), buffer);
}

fn test_load_command(environment: *const std.process.Environ.Map, source: std.Io.Dir) !void {
    try command.begin(std.testing.io, environment, .{ .dir = source });
    defer command.end();
    try command.load();
}

fn encode_test_event(event: *const Event) ![]const u8 {
    return event.encode(&command.encoded);
}

fn event_digest(event: *const Event) ![32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(try encode_test_event(event), &digest, .{});
    return digest;
}
