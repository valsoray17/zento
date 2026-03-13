const std = @import("std");
const h = @import("handler.zig");
const stardict = @import("stardict.zig");

var state = struct {
    loaded: bool = false,
    dictionary: ?stardict.Dictionary = null,
}{};

/// Return candidates for a dictionary query (the word/prefix to search).
/// Lazy-loads the dictionary on first call. Returns empty slice on load failure.
/// Caller is responsible for mode detection and prefix stripping.
pub fn suggest(allocator: std.mem.Allocator, query: []const u8) std.mem.Allocator.Error![]h.Candidate {
    if (!state.loaded) {
        // Mark loaded first — prevents infinite retry if the file is missing.
        state.loaded = true;
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
            .kind = .preview,
        };
    }

    return candidates;
}
