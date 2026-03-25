const std = @import("std");
const h = @import("handler.zig");
const stardict = @import("stardict.zig");

var state = struct {
    loaded: bool = false,
    dictionary: ?stardict.Dictionary = null,
}{};

pub const handler = h.Handler {
    .name = "dict",
    .kind = .dict,
    .on_enter = .{ .show = expandEntry },
    .source = .{ .suggest = suggest },
};

pub fn lookup(alloc: std.mem.Allocator, word: []const u8) ![]const u8 {
    const d = state.dictionary orelse return error.NotLoaded;
    // findByPrefix matches case-insensitively; an exact hit is one where the
    // stored word has the same length as the query (prefix match already
    // guarantees the same characters).
    const matches = stardict.findByPrefix(d.entries, word);
    for (matches) |entry| {
        if (entry.word.len == word.len) {
            const buf = try alloc.alloc(u8, entry.size);
            return stardict.readDefinition(d.dict_file, entry, buf);
        }
    }
    return error.NotFound;
}

fn expandEntry(alloc: std.mem.Allocator, key: []const u8) anyerror![]const u8 {
    return lookup(alloc, key);
}

/// Return candidates for a dictionary query (the word/prefix to search).
/// Lazy-loads the dictionary on first call. Returns empty slice on load failure.
/// Caller is responsible for mode detection and prefix stripping.
pub fn suggest(allocator: std.mem.Allocator, query: []const u8) std.mem.Allocator.Error![]h.Candidate {
    if (!state.loaded) {
        // Mark loaded first — prevents infinite retry if the file is missing.
        state.loaded = true;
        // TODO: scan ~/.stardict/dic/ for all subdirectories (like sdcv does) instead
        // of hardcoding a single dictionary name. Also check /usr/share/stardict/dic/.
        // Support ZENTO_DICT_DIR env var as an override.
        const home = std.posix.getenv("HOME") orelse "/tmp";
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = std.fmt.bufPrint(&buf,
            "{s}/.stardict/dic/stardict-dictd-web1913-2.4.2", .{home}) catch return &.{};
        var timer = std.time.Timer.start() catch null;
        // page_allocator, not the caller's arena — dictionary is session-level
        // data that must outlive arena resets between keystrokes.
        state.dictionary = stardict.Dictionary.load(std.heap.page_allocator, dir, "dictd_www.dict.org_web1913") catch null;
        const ms = if (timer) |*t| @as(f64, @floatFromInt(t.read())) / std.time.ns_per_ms else 0;
        if (state.dictionary) |d| {
            std.log.info("dictionary: {} words in {d:.1}ms", .{ d.entries.len, ms });
        } else {
            std.log.warn("dictionary not loaded (file missing?)", .{});
        }
    }
    const d = state.dictionary orelse return &.{};
    if (query.len == 0) return &.{};

    const matches = stardict.findByPrefix(d.entries, query);
    if (matches.len == 0) return &.{};

    const max_results: usize = 10;
    const count = @min(matches.len, max_results);
    var candidates = try allocator.alloc(h.Candidate, count);

    for (matches[0..count], 0..) |entry, i| {
        candidates[i] = .{
            .label = entry.word,
            .key = entry.word,
        };
    }

    return candidates;
}
