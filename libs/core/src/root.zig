const std = @import("std");
const Command = @import("command.zig");

pub const package_name = "tiqet-core";
// Proposed alpha version. Keep both package manifests and the E2E contract in sync.
pub const version = "0.1.0-alpha.1";
pub const version_line = "tiqet " ++ version ++ "\n";
pub const description_bytes_max = Command.description_bytes_max;

pub const InitializeOptions = Command.InitializeOptions;
pub const CreateOptions = Command.CreateOptions;
pub const DoneOptions = Command.DoneOptions;
pub const ShowOptions = Command.ShowOptions;
pub const ListOptions = Command.ListOptions;
pub const SyncOptions = Command.SyncOptions;

pub const initialize = Command.run_initialize;
pub const create = Command.run_create;
pub const done = Command.run_done;
pub const show = Command.run_show;
pub const list = Command.run_list;
pub const sync = Command.run_sync;

test {
    std.testing.refAllDecls(Command);
}
