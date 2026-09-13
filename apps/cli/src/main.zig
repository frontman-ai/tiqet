const std = @import("std");
const cli = @import("tiqet_cli");

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);

    cli.execute(&init, arguments[1..], &stdout_writer.interface) catch |err| switch (err) {
        error.MissingCommand,
        error.UnexpectedArgument,
        error.UnknownCommand,
        => {
            var stderr_buffer: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
            const message = switch (err) {
                error.MissingCommand => "missing command",
                error.UnknownCommand => "unknown command",
                else => "invalid arguments: check argument counts and create options",
            };
            try stderr_writer.interface.print("tiqet: {s}. Run tiqet --help.\n", .{message});
            try stderr_writer.interface.flush();
            std.process.exit(1);
        },
        else => return err,
    };
    try stdout_writer.interface.flush();
}
