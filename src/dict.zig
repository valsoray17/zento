const std = @import("std");
const h = @import("handler.zig");
const stardict = @import("stardict.zig");

pub const Dict = struct {
    home: ?[]const u8,
    loaded: bool = false,
    dictionary: ?stardict.Dictionary = null,

    pub fn init(home: ?[]const u8) Dict {
        return .{ .home = home };
    }

    pub fn lookup(self: *Dict, io: std.Io, alloc: std.mem.Allocator, word: []const u8) ![]const u8 {
        const d = self.dictionary orelse return error.NotLoaded;
        // findByPrefix matches case-insensitively; an exact hit is one where the
        // stored word has the same length as the query (prefix match already
        // guarantees the same characters).
        const matches = stardict.findByPrefix(d.entries, word);
        for (matches) |entry| {
            if (entry.word.len == word.len) {
                const buf = try alloc.alloc(u8, entry.size);
                return stardict.readDefinition(io, d.dict_file, entry, buf);
            }
        }
        return error.NotFound;
    }

    pub fn expand(self: *Dict, io: std.Io, alloc: std.mem.Allocator, key: []const u8) anyerror![]const u8 {
        const raw = try self.lookup(io, alloc, key);
        const stripped = try stripEtymology(alloc, raw);
        return collapseNewlines(alloc, stripped);
    }

    /// Return candidates for a dictionary query (the word/prefix to search).
    /// Lazy-loads the dictionary on first call. Returns empty slice on load failure.
    /// Caller is responsible for mode detection and prefix stripping.
    pub fn suggest(self: *Dict, io: std.Io, allocator: std.mem.Allocator, query: []const u8) std.mem.Allocator.Error![]h.Candidate {
        if (!self.loaded) {
            // Mark loaded first — prevents infinite retry if the file is missing.
            self.loaded = true;
            // TODO: scan ~/.stardict/dic/ for all subdirectories (like sdcv does) instead
            // of hardcoding a single dictionary name. Also check /usr/share/stardict/dic/.
            // Support ZENTO_DICT_DIR env var as an override.
            const home = self.home orelse "/tmp";
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const dir = std.fmt.bufPrint(&buf, "{s}/.stardict/dic/stardict-dictd-web1913-2.4.2", .{home}) catch return &.{};
            const start = std.Io.Clock.awake.now(io);
            // page_allocator, not the caller's arena — dictionary is session-level
            // data that must outlive arena resets between keystrokes.
            self.dictionary = stardict.Dictionary.load(io, std.heap.page_allocator, dir, "dictd_www.dict.org_web1913") catch null;
            const ms = start.untilNow(io, .awake).toMilliseconds();
            if (self.dictionary) |d| {
                std.log.info("dictionary: {} words in {}ms", .{ d.entries.len, ms });
            } else {
                std.log.warn("dictionary not loaded (file missing?)", .{});
            }
        }
        const d = self.dictionary orelse return &.{};
        if (query.len == 0) return &.{};

        const matches = stardict.findByPrefix(d.entries, query);
        if (matches.len == 0) return &.{};

        const count = @min(matches.len, 30);
        var candidates = try allocator.alloc(h.Candidate, count);

        for (matches[0..count], 0..) |entry, i| {
            candidates[i] = .{
                .label = entry.word,
                .key = entry.word,
            };
        }

        return candidates;
    }

    pub fn handler(self: *Dict) h.Handler {
        return .{
            .ptr = self,
            .name = "dict",
            .kind = .dict,
            .on_enter = .{ .show = h.expandFn(Dict) },
            .source = .{ .suggest = h.suggestFn(Dict) },
        };
    }
};

// Find and remove all etymology blocks in a Webster 1913 definition.
// Etymology is the only [...] block that spans multiple lines — grammar info
// like [imp. & p.p. Fared] always fits on one line. A word with multiple
// parts of speech (noun, verb, adj) may have one etymology block each.
fn stripEtymology(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    // Collect spans to remove. 16 etymology blocks per entry is far more than enough.
    var spans: [16]struct { start: usize, end: usize } = undefined;
    var span_count: usize = 0;

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '[') continue;
        const block_start = i;
        var depth: usize = 1;
        var has_newline = false;
        var j: usize = i + 1;
        while (j < text.len) : (j += 1) {
            switch (text[j]) {
                '[' => depth += 1,
                '\n' => has_newline = true,
                ']' => {
                    depth -= 1;
                    if (depth == 0) {
                        if (has_newline and span_count < spans.len) {
                            spans[span_count] = .{ .start = block_start, .end = j + 1 };
                            span_count += 1;
                        }
                        i = j;
                        break;
                    }
                },
                else => {},
            }
        }
    }

    if (span_count == 0) return alloc.dupe(u8, text);

    // Compute how many bytes survive after removing all spans.
    var keep_size: usize = text.len;
    for (spans[0..span_count]) |span| keep_size -= span.end - span.start;

    // Build result by copying everything except the removed spans.
    const result = try alloc.alloc(u8, keep_size);
    var pos: usize = 0;
    var text_pos: usize = 0;
    for (spans[0..span_count]) |span| {
        const chunk = text[text_pos..span.start];
        @memcpy(result[pos..][0..chunk.len], chunk);
        pos += chunk.len;
        text_pos = span.end;
    }
    @memcpy(result[pos..], text[text_pos..]);
    return result;
}

// Collapse runs of multiple newlines down to a single newline to reduce
// wasted vertical space in the expanded view.
fn collapseNewlines(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    var keep: usize = 0;
    var prev_nl = false;
    for (text) |c| {
        if (c == '\n') {
            if (!prev_nl) keep += 1;
            prev_nl = true;
        } else {
            keep += 1;
            prev_nl = false;
        }
    }

    const result = try alloc.alloc(u8, keep);
    var pos: usize = 0;
    prev_nl = false;
    for (text) |c| {
        if (c == '\n') {
            if (!prev_nl) {
                result[pos] = c;
                pos += 1;
            }
            prev_nl = true;
        } else {
            result[pos] = c;
            pos += 1;
            prev_nl = false;
        }
    }
    return result;
}
