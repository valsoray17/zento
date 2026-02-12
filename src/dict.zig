const std = @import("std");
const h = @import("handler.zig");
const stardict = @import("stardict.zig");

/// Module-level dictionary — loaded once at startup, immutable after init
var dictionary: ?stardict.Dictionary = null;

pub fn init(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) !void {
    dictionary = try stardict.Dictionary.load(allocator, dir, name);
}

pub fn wordCount() usize {
    const d = dictionary orelse return 0;
    return d.entries.len;
}

/// Return candidates for a dictionary query (the word/prefix to search).
/// Caller is responsible for mode detection and prefix stripping.
pub fn suggest(allocator: std.mem.Allocator, query: []const u8) std.mem.Allocator.Error![]h.Candidate {
    const d = dictionary orelse return allocator.alloc(h.Candidate, 0);
    if (query.len == 0) return allocator.alloc(h.Candidate, 0);

    const matches = stardict.findByPrefix(d.entries, query);
    if (matches.len == 0) return allocator.alloc(h.Candidate, 0);

    const max_results: usize = 10;
    const count = @min(matches.len, max_results);
    var candidates = try allocator.alloc(h.Candidate, count);

    for (matches[0..count], 0..) |entry, i| {
        const is_exact = std.mem.eql(u8, entry.word, query);

        // Load definition only for exact match
        var sublabel: ?[]const u8 = null;
        if (is_exact) {
            const def_buf = try allocator.alloc(u8, entry.size);
            sublabel = stardict.readDefinition(d.dict_file, entry, def_buf) catch null;
        }

        candidates[i] = .{
            .label = entry.word,
            .sublabel = sublabel,
            .kind = .preview,
            .score = if (is_exact) 1.0 else @as(f32, @floatFromInt(query.len)) / @as(f32, @floatFromInt(entry.word.len)),
        };
    }

    return candidates;
}
