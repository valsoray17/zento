const std = @import("std");
const h = @import("handler.zig");

const AppEntry = struct {
    name: []const u8,
    comment: []const u8,
    exec: []const u8,
    desktop_id: []const u8, // e.g. "org.mozilla.firefox.desktop"
    generic_name: ?[]const u8,
};

const NAME = "Name=";
const EXEC = "Exec=";
const COMMENT = "Comment=";
const TYPE = "Type=";
const TERMINAL = "Terminal=";
const NO_DISPLAY = "NoDisplay=";
const GENERIC_NAME = "GenericName=";

fn scanAllPaths(home: []const u8, data_dirs: []const u8, alloc: std.mem.Allocator, io: std.Io) []AppEntry {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // TODO what is empty here?
    var list: std.ArrayList(AppEntry) = .empty;
    defer list.deinit(alloc);

    // user's home
    const user_path = std.fmt.bufPrint(&buf, "{s}/.local/share/applications", .{home}) catch return &.{};
    scanDir(alloc, io, user_path, &list);

    // xdg data dirs
    var it = std.mem.splitScalar(u8, data_dirs, ':');
    while (it.next()) |dir| {
        const path = std.fmt.bufPrint(&buf, "{s}/applications", .{dir}) catch continue;
        scanDir(alloc, io, path, &list);
    }
    return list.toOwnedSlice(alloc) catch &.{};
}

fn scanDir(alloc: std.mem.Allocator, io: std.Io, dir_path: []const u8, list: *std.ArrayListUnmanaged(AppEntry)) void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    const buf = alloc.alloc(u8, 64 * 1024) catch return;
    defer alloc.free(buf);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".desktop")) continue;

        if (parseDesktopFile(alloc, io, dir, entry.name, buf)) |app| {
            list.append(alloc, app) catch {};
        }
    }
}

fn parseDesktopFile(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, file_name: []const u8, buf: []u8) ?AppEntry {
    const desktop_id = alloc.dupe(u8, file_name) catch return null;
    const contents = dir.readFile(io, file_name, buf) catch return null;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var name: ?[]const u8 = null;
    var comment: ?[]const u8 = null;
    var exec: ?[]const u8 = null;
    var is_app = false;
    var terminal = false;
    var no_display = false;
    var generic_name: ?[]const u8 = null;

    var in_desktop = false;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.eql(u8, line, "[Desktop Entry]")) {
            in_desktop = true;
            continue;
        }
        if (!in_desktop) continue;

        // we are in desktop section

        // now leaving the desktop section
        if (std.mem.startsWith(u8, line, "[")) break;

        if (std.mem.startsWith(u8, line, NAME)) name = line[NAME.len..];
        if (std.mem.startsWith(u8, line, COMMENT)) comment = line[COMMENT.len..];
        if (std.mem.startsWith(u8, line, EXEC)) exec = line[EXEC.len..];
        if (std.mem.startsWith(u8, line, TYPE)) is_app = std.mem.eql(u8, line[TYPE.len..], "Application");
        if (std.mem.startsWith(u8, line, TERMINAL)) terminal = std.mem.eql(u8, line[TERMINAL.len..], "true");
        if (std.mem.startsWith(u8, line, NO_DISPLAY)) no_display = std.mem.eql(u8, line[NO_DISPLAY.len..], "true");
        if (std.mem.startsWith(u8, line, GENERIC_NAME)) generic_name = line[GENERIC_NAME.len..];
    }

    // validate
    const n = name orelse return null;
    const c = comment orelse "";
    const e = exec orelse return null;
    if (!is_app or terminal or no_display) return null;

    // strip the params like %u etc. from exec
    var exec_stripped: [1024]u8 = undefined;
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < e.len) {
        const byte = e[i];
        // we want to skip any %x symbols, except '%%'
        if (byte == '%' and i < e.len - 1) {
            if (e[i + 1] == '%') {
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
    const comment_owned = alloc.dupe(u8, c) catch return null;
    const exec_owned = alloc.dupe(u8, exec_stripped[0..out_len]) catch return null;
    const generic_name_owned = if (generic_name) |gn| alloc.dupe(u8, gn) catch null else null;

    return .{ .name = name_owned, .comment = comment_owned, .exec = exec_owned, .desktop_id = desktop_id, .generic_name = generic_name_owned };
}

// Handler implementation
pub const Apps = struct {
    home: ?[]const u8,
    data_dirs: ?[]const u8,
    candidates: []h.Candidate = &.{},

    pub fn init(home: ?[]const u8, data_dirs: ?[]const u8) Apps {
        return .{ .home = home, .data_dirs = data_dirs };
    }

    pub fn handler(self: *Apps) h.Handler {
        return .{
            .ptr = self,
            .name = "apps",
            .kind = .app,
            .source = .{ .load = h.loadFn(Apps) },
            .on_enter = .{ .run = h.executeFn(Apps) },
        };
    }

    pub fn load(self: *Apps, io: std.Io) anyerror![]const h.Candidate {
        // TODO should we do loaded state instead?
        if (self.candidates.len > 0) return self.candidates;

        const start = std.Io.Clock.awake.now(io);
        const entries = scanAllPaths(
            self.home orelse "/tmp",
            self.data_dirs orelse "/usr/local/share:/usr/share",
            std.heap.page_allocator,
            io,
        );
        defer std.heap.page_allocator.free(entries);
        const elapsed = start.untilNow(io, .awake);
        std.log.info("apps: {} entries in {d:.1}ms", .{ entries.len, elapsed.toNanoseconds() });

        var candidates = try std.heap.page_allocator.alloc(h.Candidate, entries.len);
        var count: usize = 0;
        for (entries) |entry| {
            candidates[count] = entryToCandidate(std.heap.page_allocator, entry) catch continue;
            count += 1;
        }
        self.candidates = try std.heap.page_allocator.realloc(candidates, count);

        return self.candidates;
    }

    pub fn execute(self: *Apps, io: std.Io, key: []const u8) anyerror!void {
        var argv_buf: [32][]const u8 = undefined;
        var argc: usize = 0;

        var it = std.mem.splitScalar(u8, key, ' ');
        while (it.next()) |arg| {
            if (argc >= argv_buf.len) break;
            argv_buf[argc] = arg;
            argc += 1;
        }

        _ = try std.process.spawn(io, .{
            .argv = argv_buf[0..argc],
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .cwd = if (self.home) |home| .{ .path = home } else .inherit,
        });
    }
};

fn entryToCandidate(alloc: std.mem.Allocator, entry: AppEntry) !h.Candidate {
    var buf: [2][]const u8 = undefined;
    // alias
    const first_token = std.mem.sliceTo(entry.exec, ' ');
    const alias = std.fs.path.basename(first_token);
    var len: usize = 0;
    buf[0] = alias;
    len += 1;
    if (entry.generic_name) |gn| {
        buf[1] = gn;
        len += 1;
    }
    const aliases = try alloc.dupe([]const u8, buf[0..len]);

    return .{
        .label = entry.name,
        .sublabel = entry.comment,
        .aliases = aliases,
        .key = entry.exec,
        .id = entry.desktop_id,
    };
}
