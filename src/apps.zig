const std = @import("std");
const h = @import("handler.zig");

const AppEntry = struct {
    name: []const u8,
    exec: []const u8,
};

fn scanAllPaths(allocator: std.mem.Allocator, list: *std.ArrayList(AppEntry)) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    // user's home
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const user_path = std.fmt.bufPrint(&buf, "{s}/.local/share/applications", .{home}) catch return;
    scanDir(allocator, user_path, list);

    // xdg data dirs
    const xdg_data_dirs = std.posix.getenv("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var it = std.mem.splitScalar(u8, xdg_data_dirs, ':');
    while (it.next()) |dir| {
        const path = std.fmt.bufPrint(&buf, "{s}/applications", .{dir});
        scanDir(allocator, path, list);
    }
}

fn scanDir(allocator: std.mem.Allocator, dir_path: []const u8, list: *std.ArrayList(AppEntry)) void {
    _ = allocator;
    _ = dir_path;
    _ = list;
}

pub const handler = h.Handler {
    .name = "apps",
    .kind = .app,
    .source = .{ .load = load },
    .on_enter = .{ .run = execute },
};

pub fn load(_: std.mem.Allocator) std.mem.Allocator.Error![]h.Candidate {
    return &.{};
}

fn execute(_: []const u8) anyerror!void{
}
