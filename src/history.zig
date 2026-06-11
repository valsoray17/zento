const std = @import("std");

var frequency: std.StringHashMap(u32) = undefined;
var usage: std.StringHashMap(u32) = undefined;

const frequency_filename = "frequency";
const usage_filename = "usage";

fn getCachePath(buf: []u8, home: ?[]const u8, cache_home: ?[]const u8) ?[]u8 {
    if (cache_home) |ch| {
        return std.fmt.bufPrint(buf, "{s}/zento", .{ch}) catch null;
    }
    const h = home orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.cache/zento", .{h}) catch null;
}

pub fn load(io: std.Io, home: ?[]const u8, cache_home: ?[]const u8) void {
    frequency = std.StringHashMap(u32).init(std.heap.page_allocator);
    usage = std.StringHashMap(u32).init(std.heap.page_allocator);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zento_path = getCachePath(&path_buf, home, cache_home) orelse return;

    var zento_dir = std.Io.Dir.openDirAbsolute(io, zento_path, .{}) catch return;
    defer zento_dir.close(io);

    loadFile(io, &frequency, zento_dir, frequency_filename);
    loadFile(io, &usage, zento_dir, usage_filename);
}

pub fn save(io: std.Io, home: ?[]const u8, cache_home: ?[]const u8) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zento_path = getCachePath(&path_buf, home, cache_home) orelse return;

    std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, zento_path) catch return;

    var zento_dir = std.Io.Dir.openDirAbsolute(io, zento_path, .{}) catch return;
    defer zento_dir.close(io);

    saveFile(io, frequency, zento_dir, frequency_filename);
    saveFile(io, usage, zento_dir, usage_filename);
}

fn saveFile(io: std.Io, map: std.StringHashMap(u32), dir: std.Io.Dir, filename: []const u8) void {
    const file = std.Io.Dir.createFile(dir, io, filename, .{}) catch return;
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
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

fn loadFile(io: std.Io, map: *std.StringHashMap(u32), dir: std.Io.Dir, filename: []const u8) void {
    var file_buf: [64 * 1024]u8 = undefined;
    const contents = std.Io.Dir.readFile(dir, io, filename, &file_buf) catch return;
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
