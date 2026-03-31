const std = @import("std");
const h = @import("handler.zig");

const AppEntry = struct {
    name: []const u8,
    exec: []const u8,
};

const NAME     = "Name=";
const EXEC     = "Exec=";
const TYPE     = "Type=";
const TERMINAL = "Terminal=";
const NO_DISPLAY = "NoDisplay=";

fn scanAllPaths(alloc: std.mem.Allocator) []AppEntry {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var list = std.ArrayListUnmanaged(AppEntry){};
    defer list.deinit(alloc);

    // user's home
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const user_path = std.fmt.bufPrint(&buf, "{s}/.local/share/applications", .{home}) catch return &.{};
    scanDir(alloc, user_path, &list);

    // xdg data dirs
    const xdg_data_dirs = std.posix.getenv("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var it = std.mem.splitScalar(u8, xdg_data_dirs, ':');
    while (it.next()) |dir| {
        const path = std.fmt.bufPrint(&buf, "{s}/applications", .{dir}) catch continue;
        scanDir(alloc, path, &list);
    }
    return list.toOwnedSlice(alloc) catch &.{};
}

fn scanDir(alloc: std.mem.Allocator, dir_path: []const u8, list: *std.ArrayListUnmanaged(AppEntry)) void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    const buf = alloc.alloc(u8, 64*1024) catch return; 
    defer alloc.free(buf);
    
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".desktop")) continue;

        if (parseDesktopFile(alloc, dir, entry.name, buf)) |app| {
            list.append(alloc, app) catch {};
        }
    }
}

fn parseDesktopFile(alloc: std.mem.Allocator, dir: std.fs.Dir, file_name: []const u8, buf: []u8) ?AppEntry {
    const contents = dir.readFile(file_name, buf) catch return null;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var name: ?[]const u8 = null;
    var exec: ?[]const u8 = null;
    var is_app = false;
    var terminal = false;
    var no_display = false;

    var in_desktop = false;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.eql(u8, line, "[Desktop Entry]")) {
            in_desktop = true;
            continue;
        }
        if (!in_desktop) continue;

        // we are in desktop section
        
        // now leaving the desktop section
        if (std.mem.startsWith(u8, line, "[")) break;

        if (std.mem.startsWith(u8, line, NAME))       name       = line[NAME.len..];
        if (std.mem.startsWith(u8, line, EXEC))       exec       = line[EXEC.len..]; // TODO strip the params like %u etc.
        if (std.mem.startsWith(u8, line, TYPE))       is_app     = std.mem.eql(u8, line[TYPE.len..], "Application");
        if (std.mem.startsWith(u8, line, TERMINAL))   terminal   = std.mem.eql(u8, line[TERMINAL.len..], "true");
        if (std.mem.startsWith(u8, line, NO_DISPLAY)) no_display = std.mem.eql(u8, line[NO_DISPLAY.len..], "true");
    }

    // validate
    const n = name orelse return null;
    const e = exec orelse return null;
    if (!is_app or terminal or no_display) return null;

    // strip the params like %u etc.
    var exec_stripped: [1024]u8 = undefined;
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < e.len) {
        const byte = e[i];
        // we want to skip any %x symbols, except '%%'
        if (byte == '%' and i < e.len - 1){
            if (e[i+1] == '%') {
                exec_stripped[out_len] = '%';
                out_len += 1;
            }
            i += 2;
            continue;
        }
        exec_stripped[out_len] = byte;
        out_len += 1;
        i += 1;
    }
    
    const name_owned = alloc.dupe(u8, n) catch return null;
    const exec_owned = alloc.dupe(u8, exec_stripped[0..out_len]) catch return null;

    return .{ .name = name_owned, .exec = exec_owned };
}

pub const handler = h.Handler {
    .name = "apps",
    .kind = .app,
    .source = .{ .load = load },
    .on_enter = .{ .run = execute },
};

var state = struct {
    loaded: bool = false,
    entries: []AppEntry = &.{},
}{};

pub fn load(alloc: std.mem.Allocator) std.mem.Allocator.Error![]h.Candidate {
    if (!state.loaded) {
        var timer = std.time.Timer.start() catch null;
        // these should outlive the alloc passed here (which is arena allocator)
        state.entries = scanAllPaths(std.heap.page_allocator);
        state.loaded = true;
        const ms = if (timer) |*t| @as(f64, @floatFromInt(t.read())) / std.time.ns_per_ms else 0;
        std.log.info("apps: {} entries in {d:.1}ms", .{ state.entries.len, ms });
    }
    var candidates = try alloc.alloc(h.Candidate, state.entries.len);
    for (state.entries, 0..) |entry, i| {
       candidates[i] = .{
          .label = entry.name,
          .key = entry.exec,
       };
    }
    return candidates;
}

fn execute(key: []const u8) anyerror!void {
    var argv_buf: [32][]const u8 = undefined;
    var argc: usize = 0;

    var it = std.mem.splitScalar(u8, key, ' ');
    while (it.next()) |arg| {
        if (argc >= argv_buf.len) break;
        argv_buf[argc] = arg;
        argc += 1;
    }

    var child = std.process.Child.init(argv_buf[0..argc], std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.cwd = std.posix.getenv("HOME");
    try child.spawn();
}
