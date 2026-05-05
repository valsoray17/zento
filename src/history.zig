const std = @import("std");

var frequency: std.StringHashMap(u32) = undefined;
var usage: std.StringHashMap(u32) = undefined;

const frequency_filename = "frequency";
const usage_filename = "usage";

pub fn load() void {
    frequency = std.StringHashMap(u32).init(std.heap.page_allocator);
    usage = std.StringHashMap(u32).init(std.heap.page_allocator);

    const home = std.posix.getenv("HOME") orelse return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zento_path = std.fmt.bufPrint(&path_buf, "{s}/.local/share/zento", .{home}) catch return;

    var zento_dir = std.fs.openDirAbsolute(zento_path, .{}) catch return;
    defer zento_dir.close();

    loadFile(&frequency, zento_dir, frequency_filename);
    loadFile(&usage, zento_dir, usage_filename);
}

pub fn save() void {
    const home = std.posix.getenv("HOME") orelse return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zento_path = std.fmt.bufPrint(&path_buf, "{s}/.local/share/zento", .{home}) catch return;

    std.fs.makeDirAbsolute(zento_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return,
    };
    var zento_dir = std.fs.openDirAbsolute(zento_path, .{}) catch return;
    defer zento_dir.close();

    saveFile(frequency, zento_dir, frequency_filename);
    saveFile(usage, zento_dir, usage_filename);
}

fn saveFile(map: std.StringHashMap(u32), dir: std.fs.Dir, filename: []const u8) void {
    const file = dir.createFile(filename, .{}) catch return;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;   

    var it = map.iterator();
    while (it.next()) |entry| {
        w.print("{s}={d}\n", .{ entry.key_ptr.*, entry.value_ptr.* }) catch return;
    }
    w.flush() catch return;
}

test "loadFile and saveFile roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    frequency = std.StringHashMap(u32).init(std.heap.page_allocator);
    usage = std.StringHashMap(u32).init(std.heap.page_allocator);

    record("apps", "org.mozilla.firefox.desktop");
    record("apps", "org.mozilla.firefox.desktop");
    record("systemd", "Suspend");

    saveFile(frequency, tmp.dir, frequency_filename);
    saveFile(usage, tmp.dir, usage_filename);

    frequency.clearAndFree();
    usage.clearAndFree();
    frequency = std.StringHashMap(u32).init(std.heap.page_allocator);
    usage = std.StringHashMap(u32).init(std.heap.page_allocator);

    loadFile(&frequency, tmp.dir, frequency_filename);
    loadFile(&usage, tmp.dir, usage_filename);

    try std.testing.expectEqual(@as(u32, 2), getFrequency("apps:org.mozilla.firefox.desktop"));
    try std.testing.expectEqual(@as(u32, 1), getFrequency("apps:systemd:Suspend"));
    try std.testing.expectEqual(@as(u32, 0), getFrequency("apps:nonexistent"));
}

pub fn getFrequency(key: []const u8) u32 {
    return frequency.get(key) orelse 0;
}

pub fn record(handler_name: []const u8, candidate_id: ?[]const u8) void {
    // increment usage
    const usage_entry = usage.getOrPut(handler_name) catch return;
    if (!usage_entry.found_existing) {
        const key_owned = std.heap.page_allocator.dupe(u8, handler_name) catch return;
        usage_entry.key_ptr.* = key_owned;
        usage_entry.value_ptr.* = 0;
    }
    usage_entry.value_ptr.* += 1;

    // increment frequency if candidate has a stable id
    if (candidate_id) |id| {
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ handler_name, id }) catch return;
        const freq_entry = frequency.getOrPut(key) catch return;
        if (!freq_entry.found_existing) {
            const key_owned = std.heap.page_allocator.dupe(u8, key) catch return;
            freq_entry.key_ptr.* = key_owned;
            freq_entry.value_ptr.* = 0;
        }
        freq_entry.value_ptr.* += 1;
    }
}
fn loadFile(map: *std.StringHashMap(u32), dir: std.fs.Dir, filename: []const u8) void {
    const contents = dir.readFileAlloc(std.heap.page_allocator, filename, 64 * 1024) catch return;
    defer std.heap.page_allocator.free(contents);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.splitScalar(u8, line, '=');
        const key = parts.next() orelse continue;
        const counter_str = parts.next() orelse continue;
        const count = std.fmt.parseInt(u32, counter_str, 10) catch continue;
        const key_owned = std.heap.page_allocator.dupe(u8, key) catch continue;
        map.put(key_owned, count) catch return;
    }
}
