const std = @import("std");
const Event = @This();

id: Id,
task_id: Id,
created_at: Timestamp,
payload: union(enum) { created: Creation, completed: void },

pub const Id = [32]u8;
pub const Timestamp = [20]u8;
pub const description_bytes_max: u32 = 256 * 1024;
pub const record_bytes_max: u32 = 6 * description_bytes_max + 2048;
pub const json_scratch_bytes_max = 2 * record_bytes_max + 64 * 1024;

pub const Creation = struct {
    title: []const u8,
    creator: []const u8,
    description: ?[]const u8 = null,
};

const WireEvent = struct {
    version: u8,
    id: []const u8,
    type: enum { @"task-created", @"task-completed" },
    taskId: []const u8,
    title: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    description: ?[]const u8 = null,
    createdAt: []const u8,
};

// The destination must not overlap the event's borrowed text.
pub fn encode(event: *const Event, buffer: []u8) ![]const u8 {
    const creation: ?*const Creation = switch (event.payload) {
        .created => |*value| value,
        .completed => null,
    };
    const wire = WireEvent{
        .version = 1,
        .id = &event.id,
        .type = if (creation != null) .@"task-created" else .@"task-completed",
        .taskId = &event.task_id,
        .title = if (creation) |value| value.title else null,
        .creator = if (creation) |value| value.creator else null,
        .description = if (creation) |value| value.description else null,
        .createdAt = &event.created_at,
    };
    var writer = std.Io.Writer.fixed(buffer);
    try std.json.Stringify.value(wire, .{ .emit_null_optional_fields = false }, &writer);
    try writer.writeByte('\n');
    return writer.buffered();
}

// Decoded text borrows bytes or allocator storage. The caller controls both lifetimes.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Event {
    if (bytes.len > record_bytes_max) return error.InvalidEventLog;
    const wire = std.json.parseFromSliceLeaky(WireEvent, allocator, bytes, .{
        .allocate = .alloc_if_needed,
        .max_value_len = record_bytes_max,
        .ignore_unknown_fields = false,
    }) catch return error.InvalidEventLog;
    if (wire.version != 1) return error.InvalidEventVersion;
    return .{
        .id = try parse_id(wire.id),
        .task_id = try parse_id(wire.taskId),
        .created_at = try parse_timestamp(wire.createdAt),
        .payload = switch (wire.type) {
            .@"task-created" => .{ .created = .{
                .title = try validate_text(wire.title orelse return error.InvalidEventLog, 160),
                .creator = try validate_text(
                    wire.creator orelse return error.InvalidEventLog,
                    64,
                ),
                .description = try validate_description(wire.description),
            } },
            .@"task-completed" => completed: {
                if (wire.title != null or wire.creator != null or wire.description != null) {
                    return error.InvalidEventLog;
                }
                break :completed .completed;
            },
        },
    };
}

pub fn validate_text(bytes: []const u8, capacity: u16) ![]const u8 {
    if (bytes.len == 0 or bytes.len > capacity) return error.InvalidText;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidText;
    for (bytes) |byte| if (byte < 32 or byte == 127) return error.InvalidText;
    return bytes;
}

pub fn validate_description(value: ?[]const u8) !?[]const u8 {
    const bytes = value orelse return null;
    if (bytes.len > description_bytes_max) return error.DescriptionTooLong;
    if (bytes.len == 0) return null;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidDescription;
    for (bytes) |byte| {
        if (byte == '\t' or byte == '\n' or byte == '\r') continue;
        if (byte < 32 or byte == 127) return error.InvalidDescription;
    }
    return bytes;
}

pub fn parse_id(bytes: []const u8) !Id {
    if (bytes.len != 32) return error.InvalidId;
    for (bytes) |byte| {
        if (!(byte >= '0' and byte <= '9') and !(byte >= 'a' and byte <= 'f')) {
            return error.InvalidId;
        }
    }
    return bytes[0..32].*;
}

pub fn parse_timestamp(bytes: []const u8) !Timestamp {
    if (bytes.len != 20) return error.InvalidTimestamp;
    for (bytes, 0..) |byte, index| {
        const expected: ?u8 = switch (index) {
            4, 7 => '-',
            10 => 'T',
            13, 16 => ':',
            19 => 'Z',
            else => null,
        };
        if (expected) |value| {
            if (byte != value) return error.InvalidTimestamp;
        } else if (!std.ascii.isDigit(byte)) return error.InvalidTimestamp;
    }
    const year = try std.fmt.parseInt(u16, bytes[0..4], 10);
    const month = try std.fmt.parseInt(u8, bytes[5..7], 10);
    const day = try std.fmt.parseInt(u8, bytes[8..10], 10);
    if (year < 1970 or month < 1 or month > 12) return error.InvalidTimestamp;
    const days: u8 = switch (month) {
        4, 6, 9, 11 => 30,
        2 => if (std.time.epoch.isLeapYear(year)) 29 else 28,
        else => 31,
    };
    if (day < 1 or day > days) return error.InvalidTimestamp;
    if (try std.fmt.parseInt(u8, bytes[11..13], 10) >= 24) return error.InvalidTimestamp;
    if (try std.fmt.parseInt(u8, bytes[14..16], 10) >= 60) return error.InvalidTimestamp;
    if (try std.fmt.parseInt(u8, bytes[17..19], 10) >= 60) return error.InvalidTimestamp;
    return bytes[0..20].*;
}

pub fn format_timestamp(seconds: i64) !Timestamp {
    if (seconds < 0 or seconds > 253402300799) return error.TimestampOutOfRange;
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    var result: Timestamp = undefined;
    _ = try std.fmt.bufPrint(&result, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
    return result;
}

pub fn random_id(io: std.Io) Id {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

test "typed codecs preserve wire fields, escapes, and validation" {
    var buffers = try TestBuffers.init();
    defer buffers.deinit();
    const json = "{\"version\":1,\"id\":\"11111111111111111111111111111111\"," ++
        "\"type\":\"task-created\",\"taskId\":\"22222222222222222222222222222222\"," ++
        "\"title\": \"say \\\"hi\\\" \\\\ ok\",\"creator\":\"local\"," ++
        "\"createdAt\":\"2000-02-29T00:00:00Z\"}";
    const event = try buffers.parse(json);
    try std.testing.expectEqualStrings("say \"hi\" \\ ok", event.payload.created.title);
    const decoded = try buffers.parse(try buffers.encode(&event));
    try std.testing.expectEqualStrings("say \"hi\" \\ ok", decoded.payload.created.title);
    try std.testing.expectError(error.InvalidEventLog, buffers.parse("{}"));
    try std.testing.expectError(error.InvalidEventLog, buffers.parse(json ++ "{}"));
    var malformed_buffer: [1024]u8 = undefined;
    for ([_][]const u8{ "task-created", "taskId", "createdAt" }) |field| {
        const start = std.mem.indexOf(u8, json, field).?;
        @memcpy(malformed_buffer[0..json.len], json);
        malformed_buffer[start] = '!';
        try std.testing.expectError(
            error.InvalidEventLog,
            buffers.parse(malformed_buffer[0..json.len]),
        );
    }
    try std.testing.expectError(error.InvalidText, validate_text("\xff", 160));
    try std.testing.expectError(error.InvalidText, validate_text("line\nbreak", 160));
    try std.testing.expectError(error.InvalidText, validate_text("", 160));
    _ = try validate_text("t" ** 160, 160);
    try std.testing.expectError(error.InvalidText, validate_text("t" ** 161, 160));
    _ = try validate_text("c" ** 64, 64);
    try std.testing.expectError(error.InvalidText, validate_text("c" ** 65, 64));
    try std.testing.expectError(error.InvalidId, parse_id("g" ** 32));
    try std.testing.expectError(error.InvalidTimestamp, parse_timestamp("2001-02-29T00:00:00Z"));
    try std.testing.expectError(error.InvalidTimestamp, parse_timestamp("2000-01-01T24:00:00Z"));
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", &(try format_timestamp(0)));
    try std.testing.expectEqualStrings(
        "9999-12-31T23:59:59Z",
        &(try format_timestamp(253402300799)),
    );
    try std.testing.expectError(error.TimestampOutOfRange, format_timestamp(-1));
}

test "creation description validation and JSON roundtrip" {
    var buffers = try TestBuffers.init();
    defer buffers.deinit();
    const markdown = "## Problem\r\n\tSay \"hello\" \\ 世界 🌍\n";
    const event = test_creation(markdown);
    const decoded = try buffers.decode(&event);
    try std.testing.expectEqualStrings(markdown, decoded.payload.created.description.?);
    try std.testing.expectEqual(@as(?[]const u8, null), try validate_description(null));
    try std.testing.expectEqual(@as(?[]const u8, null), try validate_description(""));
    try std.testing.expectEqualStrings(" \t\n", (try validate_description(" \t\n")).?);
    for ([_][]const u8{ "\xff", "\x00", "\x1b", "\x7f", "\x01" }) |invalid| {
        try std.testing.expectError(error.InvalidDescription, validate_description(invalid));
    }
    const prefix = "{\"version\":1,\"id\":\"11111111111111111111111111111111\"," ++
        "\"type\":\"task-created\",\"taskId\":\"22222222222222222222222222222222\"," ++
        "\"title\":\"task\",\"creator\":\"local\",\"createdAt\":\"2000-01-01T00:00:00Z\"";
    for ([_][]const u8{ "}", ",\"description\":null}", ",\"description\":\"\"}" }) |suffix| {
        const json = try std.fmt.bufPrint(buffers.line, "{s}{s}", .{ prefix, suffix });
        const absent = try buffers.parse(json);
        try std.testing.expect(absent.payload.created.description == null);
        const canonical = try buffers.encode(&absent);
        try std.testing.expectEqualStrings(prefix ++ "}\n", canonical);
    }
    try std.testing.expectError(
        error.InvalidEventLog,
        buffers.parse(prefix ++ ",\"description\":42}"),
    );
    try std.testing.expectError(error.InvalidEventLog, buffers.parse(
        prefix ++ ",\"description\":\"a\",\"description\":\"b\"}",
    ));
    for ([_][]const u8{ "", "unexpected" }) |description| {
        const json = try std.fmt.bufPrint(
            buffers.line,
            "{{\"version\":1,\"id\":\"11111111111111111111111111111111\"," ++
                "\"type\":\"task-completed\",\"taskId\":\"22222222222222222222222222222222\"," ++
                "\"createdAt\":\"2000-01-01T00:00:00Z\",\"description\":\"{s}\"}}",
            .{description},
        );
        try std.testing.expectError(error.InvalidEventLog, buffers.parse(json));
    }
}

test "creation description capacity boundaries" {
    var buffers = try TestBuffers.init();
    defer buffers.deinit();
    const report = try std.testing.environ.contains(std.testing.allocator, "TIQET_SCALE_REPORT");
    const body = try std.testing.allocator.alloc(u8, description_bytes_max + 1);
    defer std.testing.allocator.free(body);
    @memset(body, 'a');
    _ = try validate_description(body[0..description_bytes_max]);
    try std.testing.expectError(error.DescriptionTooLong, validate_description(body));
    // Two-byte UTF-8 characters must be counted as bytes, not code points.
    for (0..description_bytes_max / 2) |index| {
        body[index * 2] = 0xc3;
        body[index * 2 + 1] = 0xa9;
    }
    _ = try validate_description(body[0..description_bytes_max]);
    try std.testing.expectError(
        error.InvalidDescription,
        validate_description(body[0 .. description_bytes_max - 1]),
    );
    @memset(body, '\n');
    var event = test_creation(body[0..description_bytes_max]);
    event.payload.created.title = "t" ** 160;
    event.payload.created.creator = "c" ** 64;
    const decoded = try buffers.decode(&event);
    try std.testing.expectEqualStrings(
        body[0..description_bytes_max],
        decoded.payload.created.description.?,
    );
    // External JSON can use six bytes to encode one decoded byte, plus record whitespace.
    var writer = std.Io.Writer.fixed(buffers.line);
    try writer.writeAll("{\"version\":1,\"id\":\"11111111111111111111111111111111\"," ++
        "\"type\":\"task-created\",\"taskId\":\"22222222222222222222222222222222\"," ++
        "\"title\":\"task\",\"creator\":\"local\",\"description\":\"");
    for (0..description_bytes_max) |_| try writer.writeAll("\\u0061");
    try writer.writeAll("\",\"createdAt\":\"2000-01-01T00:00:00Z\"}");
    try writer.splatByteAll(' ', record_bytes_max - writer.buffered().len - 1);
    try writer.writeByte('\n');
    const escaped = try buffers.parse(writer.buffered());
    try std.testing.expectEqual(description_bytes_max, escaped.payload.created.description.?.len);
    for (escaped.payload.created.description.?) |byte| {
        try std.testing.expectEqual(@as(u8, 'a'), byte);
    }
    if (report) std.debug.print("description-boundary encoded={d} parser={d}\n", .{
        writer.buffered().len, buffers.json_allocator.end_index,
    });
    const oversized = try std.testing.allocator.alloc(u8, record_bytes_max + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.InvalidEventLog, buffers.parse(oversized));
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

// Test-only heap storage avoids putting multi-megabyte fixtures on the stack.
// Production codecs receive their allocator and destination from the caller.
const TestBuffers = struct {
    memory: []u8,
    line: []u8,
    encoded: []u8,
    json_allocator: std.heap.FixedBufferAllocator,

    fn init() !TestBuffers {
        const memory = try std.testing.allocator.alloc(
            u8,
            2 * record_bytes_max + json_scratch_bytes_max,
        );
        return .{
            .memory = memory,
            .line = memory[0..record_bytes_max],
            .encoded = memory[record_bytes_max .. 2 * record_bytes_max],
            .json_allocator = std.heap.FixedBufferAllocator.init(memory[2 * record_bytes_max ..]),
        };
    }

    fn deinit(self: *TestBuffers) void {
        std.testing.allocator.free(self.memory);
    }

    fn parse(self: *TestBuffers, bytes: []const u8) !Event {
        self.json_allocator.reset();
        return Event.parse(self.json_allocator.allocator(), bytes);
    }

    fn encode(self: *TestBuffers, value: *const Event) ![]const u8 {
        return value.encode(self.encoded);
    }

    fn decode(self: *TestBuffers, value: *const Event) !Event {
        const bytes = try self.encode(value);
        @memcpy(self.line[0..bytes.len], bytes);
        return self.parse(self.line[0..bytes.len]);
    }
};
