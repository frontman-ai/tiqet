const std = @import("std");
const Event = @import("event.zig");
const Replay = @This();
const Id = Event.Id;

// The caller reserves table capacity and owns all retained allocations.
tasks: std.AutoArrayHashMapUnmanaged(Id, Task) = .empty,
events: std.AutoArrayHashMapUnmanaged(Id, [32]u8) = .empty,
records: u32 = 0,

pub const task_count_max = 4096;
pub const event_count_max = 16384;
pub const record_count_max = 32768;

const TaskDetails = struct { title: []const u8, creator: []const u8 };
pub const Task = struct {
    creation: ?TaskDetails = null,
    creation_event_id: ?Id = null,
    completed: bool = false,
};

pub fn clear(replay: *Replay) void {
    // Retain table capacity. String allocations remain owned by the caller.
    replay.tasks.clearRetainingCapacity();
    replay.events.clearRetainingCapacity();
    replay.records = 0;
}

pub fn apply(
    replay: *Replay,
    event: *const Event,
    digest: [32]u8,
    allocator: std.mem.Allocator,
) !void {
    if (replay.records == record_count_max) return error.EventCapacityExceeded;
    replay.records += 1;
    if (replay.events.get(event.id)) |previous| {
        if (!std.mem.eql(u8, &previous, &digest)) return error.ConflictingEventId;
        return;
    }
    if (replay.events.count() == event_count_max) return error.EventCapacityExceeded;
    if (!replay.tasks.contains(event.task_id)) {
        if (replay.tasks.count() == task_count_max) return error.TaskCapacityExceeded;
        replay.tasks.putAssumeCapacity(event.task_id, .{});
    }
    const task = replay.tasks.getPtr(event.task_id).?;
    switch (event.payload) {
        .created => |creation| {
            if (task.creation != null) return error.ConflictingTaskCreation;
            task.creation = .{
                .title = try allocator.dupe(u8, creation.title),
                .creator = try allocator.dupe(u8, creation.creator),
            };
            task.creation_event_id = event.id;
        },
        .completed => task.completed = true,
    }
    replay.events.putAssumeCapacity(event.id, digest);
}

test "replay is idempotent, order independent, and rejects conflicts and capacity overflow" {
    var storage: [64 * 1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    var replay = Replay{};
    try replay.tasks.ensureTotalCapacity(allocator.allocator(), 4);
    try replay.events.ensureTotalCapacity(allocator.allocator(), 4);
    const created = Event{
        .id = ("1" ** 32).*,
        .task_id = ("2" ** 32).*,
        .created_at = "2000-01-01T00:00:00Z".*,
        .payload = .{ .created = .{ .title = "task", .creator = "local" } },
    };
    const completed = Event{
        .id = ("3" ** 32).*,
        .task_id = created.task_id,
        .created_at = created.created_at,
        .payload = .completed,
    };
    try replay.apply(&completed, try event_digest(&completed), allocator.allocator());
    try replay.apply(&created, try event_digest(&created), allocator.allocator());
    const allocated = allocator.end_index;
    try replay.apply(&created, try event_digest(&created), allocator.allocator());
    try std.testing.expectEqual(allocated, allocator.end_index);
    try std.testing.expectEqual(@as(u32, 1), replay.tasks.count());
    try std.testing.expect(replay.tasks.get(created.task_id).?.completed);
    var conflict = created;
    conflict.payload.created.title = "changed";
    try std.testing.expectError(
        error.ConflictingEventId,
        replay.apply(&conflict, try event_digest(&conflict), allocator.allocator()),
    );
    conflict.id = ("4" ** 32).*;
    try std.testing.expectError(
        error.ConflictingTaskCreation,
        replay.apply(&conflict, try event_digest(&conflict), allocator.allocator()),
    );
    replay.records = record_count_max;
    try std.testing.expectError(
        error.EventCapacityExceeded,
        replay.apply(&created, try event_digest(&created), allocator.allocator()),
    );
}

test "creation description replay preserves identity" {
    var memory: [64 * 1024]u8 = undefined;
    var pool = std.heap.FixedBufferAllocator.init(&memory);
    const allocator = pool.allocator();
    var replay: Replay = .{};
    try replay.tasks.ensureTotalCapacity(allocator, 4);
    try replay.events.ensureTotalCapacity(allocator, 4);
    var event = test_creation("hello");
    var completed = event;
    completed.id = ("3" ** 32).*;
    completed.payload = .completed;
    try replay.apply(&completed, try event_digest(&completed), allocator);
    try replay.apply(&event, try event_digest(&event), allocator);
    const allocated = pool.end_index;
    try replay.apply(&event, try event_digest(&event), allocator);
    try std.testing.expectEqual(allocated, pool.end_index);
    const task = replay.tasks.get(event.task_id).?;
    try std.testing.expect(task.completed);
    try std.testing.expectEqual(event.id, task.creation_event_id.?);
    const json = "{ \"version\":1,\"id\":\"11111111111111111111111111111111\"," ++
        "\"type\":\"task-created\",\"taskId\":\"22222222222222222222222222222222\"," ++
        "\"title\":\"task\",\"creator\":\"local\",\"description\":\"\\u0068ello\"," ++
        "\"createdAt\":\"2000-01-01T00:00:00Z\"}";
    const equivalent = try Event.parse(allocator, json);
    try replay.apply(&equivalent, try event_digest(&equivalent), allocator);
    event.payload.created.description = "different";
    try std.testing.expectError(
        error.ConflictingEventId,
        replay.apply(&event, try event_digest(&event), allocator),
    );
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

fn event_digest(event: *const Event) ![32]u8 {
    var buffer: [1024]u8 = undefined;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(try event.encode(&buffer), &digest, .{});
    return digest;
}
