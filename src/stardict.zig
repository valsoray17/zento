const std = @import("std");

// ============================================================================
// StarDict .ifo Parser
// ============================================================================

// .ifo file format:
//   Line 1: "StarDict's dict ifo file" (magic header)
//   Line 2+: key=value pairs
//
// Example:
//   StarDict's dict ifo file
//   version=3.0.0
//   wordcount=12345
//   bookname=Webster's 1913
//
// Go equivalent: bufio.Scanner + strings.SplitN

pub const IfoInfo = struct {
    bookname: ?[]const u8 = null,
    wordcount: ?usize = null,
    version: ?[]const u8 = null,
};

pub fn parseIfo(data: []const u8) ?IfoInfo {
    var lines = std.mem.splitScalar(u8, data, '\n');

    // First line must be magic header
    const first_line = lines.next() orelse return null;
    if (!std.mem.startsWith(u8, first_line, "StarDict's dict ifo file")) {
        return null;
    }

    var info = IfoInfo{};

    // Parse remaining key=value lines
    while (lines.next()) |line| {
        // Trim whitespace (space, tab) and \r for Windows CRLF line endings
        const trimmed = std.mem.trim(u8, line, " \t\r");
        // Skip empty lines
        if (trimmed.len == 0) continue;

        // Find '=' separator
        const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = trimmed[0..eq_pos];
        const value = trimmed[eq_pos + 1 ..];

        if (std.mem.eql(u8, key, "bookname")) {
            info.bookname = value;
        } else if (std.mem.eql(u8, key, "version")) {
            info.version = value;
        } else if (std.mem.eql(u8, key, "wordcount")) {
            info.wordcount = std.fmt.parseInt(usize, value, 10) catch null;
        }
    }

    return info;
}

test "parseIfo - valid dictionary" {
    const data =
        \\StarDict's dict ifo file
        \\version=3.0.0
        \\wordcount=123
        \\bookname=Test Dictionary
    ;

    const info = parseIfo(data) orelse return error.TestFailed;

    try std.testing.expectEqualStrings("Test Dictionary", info.bookname.?);
    try std.testing.expectEqual(@as(?usize, 123), info.wordcount);
    try std.testing.expectEqualStrings("3.0.0", info.version.?);
}

test "parseIfo - invalid magic header" {
    const data = "Not a stardict file\nversion=3.0.0\n";
    const info = parseIfo(data);
    try std.testing.expect(info == null);
}

test "parseIfo - empty file" {
    const info = parseIfo("");
    try std.testing.expect(info == null);
}

test "parseIfo - handles CRLF line endings" {
    const data = "StarDict's dict ifo file\r\nversion=2.4.2\r\nbookname=CRLF Test\r\n";
    const info = parseIfo(data) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("CRLF Test", info.bookname.?);
}

// ============================================================================
// StarDict .idx Parser
// ============================================================================

// .idx file format (binary, repeating entries):
//   word: null-terminated UTF-8 string
//   offset: 4 bytes, big-endian (position in .dict file)
//   size: 4 bytes, big-endian (definition length in bytes)
//
// Example entry for "hello" at offset 100, size 32:
//   68 65 6c 6c 6f 00   "hello\0"
//   00 00 00 64         offset = 100 (0x64)
//   00 00 00 20         size = 32 (0x20)
//
// Go equivalent: binary.BigEndian.Uint32()

pub const IdxEntry = struct {
    word: []const u8, // Points into the original idx data (no allocation)
    offset: u32,
    size: u32,
};

// Iterator for parsing .idx entries one at a time
// Go equivalent: bufio.Scanner with custom split function
pub const IdxParser = struct {
    data: []const u8,
    pos: usize = 0,

    // Parse next entry from the index
    // Returns null when no more entries
    pub fn next(self: *IdxParser) ?IdxEntry {
        if (self.pos >= self.data.len) return null;

        // Find null terminator for word
        const word_end = std.mem.indexOfScalarPos(u8, self.data, self.pos, 0) orelse return null;
        const word = self.data[self.pos..word_end];

        // Need 8 more bytes for offset (4) + size (4)
        const nums_start = word_end + 1;
        if (nums_start + 8 > self.data.len) return null;

        // Read big-endian u32 values
        // Zig slice syntax: data[start..][0..4] means "4 bytes starting at start"
        // std.mem.readInt is like Go's binary.BigEndian.Uint32()
        const offset = std.mem.readInt(u32, self.data[nums_start..][0..4], .big);
        const size = std.mem.readInt(u32, self.data[nums_start + 4 ..][0..4], .big);

        // Advance position for next call
        self.pos = nums_start + 8;

        return IdxEntry{
            .word = word,
            .offset = offset,
            .size = size,
        };
    }
};

test "IdxParser - single entry" {
    // Build binary data: "hi\0" + offset(100) + size(32)
    // [_]u8{...} infers array length, 'h', 'i' are individual bytes
    const data = [_]u8{
        'h', 'i', 0, // word with null terminator
        0, 0, 0, 100, // offset = 100 (big-endian)
        0, 0, 0, 32, // size = 32 (big-endian)
    };

    // &data coerces fixed array to slice []const u8
    var parser = IdxParser{ .data = &data };
    const entry = parser.next() orelse return error.TestFailed;

    try std.testing.expectEqualStrings("hi", entry.word);
    try std.testing.expectEqual(@as(u32, 100), entry.offset);
    try std.testing.expectEqual(@as(u32, 32), entry.size);

    // No more entries
    try std.testing.expect(parser.next() == null);
}

test "IdxParser - multiple entries" {
    const data = [_]u8{
        // Entry 1: "apple" at offset 0, size 10
        'a', 'p', 'p', 'l', 'e', 0,
        0, 0, 0, 0, // offset = 0
        0, 0, 0, 10, // size = 10
        // Entry 2: "banana" at offset 10, size 15
        'b', 'a', 'n', 'a', 'n', 'a', 0,
        0, 0, 0, 10, // offset = 10
        0, 0, 0, 15, // size = 15
    };

    var parser = IdxParser{ .data = &data };

    const first = parser.next() orelse return error.TestFailed;
    try std.testing.expectEqualStrings("apple", first.word);
    try std.testing.expectEqual(@as(u32, 0), first.offset);
    try std.testing.expectEqual(@as(u32, 10), first.size);

    const second = parser.next() orelse return error.TestFailed;
    try std.testing.expectEqualStrings("banana", second.word);
    try std.testing.expectEqual(@as(u32, 10), second.offset);
    try std.testing.expectEqual(@as(u32, 15), second.size);

    try std.testing.expect(parser.next() == null);
}

test "IdxParser - empty data" {
    var parser = IdxParser{ .data = "" };
    try std.testing.expect(parser.next() == null);
}

test "IdxParser - truncated entry (missing size bytes)" {
    // Only 5 bytes after null terminator, needs 8
    const data = [_]u8{
        't', 'e', 's', 't', 0, // word
        0, 0, 0, 100, // only 4 bytes (offset), missing size
    };
    var parser = IdxParser{ .data = &data };
    try std.testing.expect(parser.next() == null);
}

// ============================================================================
// Index Loading and Lookup
// ============================================================================

// Parse all .idx entries into an allocated slice
// wordcount comes from .ifo file - if it's wrong, dictionary is corrupted
// Caller owns the returned memory and must free with allocator.free()
//
// Go equivalent: make([]IdxEntry, wordcount)
pub fn parseAllEntries(allocator: std.mem.Allocator, idx_data: []const u8, wordcount: usize) ![]IdxEntry {
    const entries = try allocator.alloc(IdxEntry, wordcount);
    errdefer allocator.free(entries);

    var parser = IdxParser{ .data = idx_data };
    var i: usize = 0;
    while (parser.next()) |entry| {
        if (i >= wordcount) return error.WordcountMismatch;
        entries[i] = entry;
        i += 1;
    }

    // Verify we got exactly wordcount entries
    if (i != wordcount) return error.WordcountMismatch;

    return entries;
}

test "parseAllEntries - parses with wordcount" {
    const idx_data = [_]u8{
        'a', 'p', 'e', 0, 0, 0, 0, 0, 0, 0, 0, 10,
        'a', 'p', 'p', 'l', 'e', 0, 0, 0, 0, 10, 0, 0, 0, 20,
    };

    const entries = try parseAllEntries(std.testing.allocator, &idx_data, 2);
    defer std.testing.allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("ape", entries[0].word);
    try std.testing.expectEqualStrings("apple", entries[1].word);
}

test "parseAllEntries - wordcount mismatch" {
    const idx_data = [_]u8{
        'h', 'i', 0, 0, 0, 0, 0, 0, 0, 0, 10,
    };

    // Claim 5 words but only have 1
    const result = parseAllEntries(std.testing.allocator, &idx_data, 5);
    try std.testing.expectError(error.WordcountMismatch, result);
}

// Case-insensitive order matching how dictd tools sort the .idx file.
// Compares like std.mem.order but folds bytes to lowercase first.
// The length tie-break is preserved: "War" < "Wart" because after matching
// 3 equal bytes, the shorter slice wins.
fn orderCI(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |ac, bc| {
        switch (std.math.order(std.ascii.toLower(ac), std.ascii.toLower(bc))) {
            .eq => {},
            .lt => return .lt,
            .gt => return .gt,
        }
    }
    return std.math.order(a.len, b.len);
}

fn startsWithCI(str: []const u8, prefix: []const u8) bool {
    if (str.len < prefix.len) return false;
    for (str[0..prefix.len], prefix) |sc, pc| {
        if (std.ascii.toLower(sc) != std.ascii.toLower(pc)) return false;
    }
    return true;
}

// Find entries matching a prefix (for autocomplete)
// Returns a slice of the entries array - no allocation needed
//
// The .idx file is sorted case-insensitively by dictd, so both the binary
// search and the scan-forward use case-insensitive comparison.  This lets
// typing "wart" find the entry "Wart" without any query normalisation.
//
// Go equivalent: sort.Search + linear scan
pub fn findByPrefix(entries: []const IdxEntry, prefix: []const u8) []const IdxEntry {
    if (entries.len == 0 or prefix.len == 0) return entries[0..0];

    // Binary search: find first entry >= prefix (case-insensitive)
    var left: usize = 0;
    var right: usize = entries.len;

    while (left < right) {
        const mid = left + (right - left) / 2;
        const word = entries[mid].word;

        // Slice word down to prefix length for comparison so that the length
        // tie-break inside orderCI correctly ranks "War" < "Wart".
        const cmp_len = @min(word.len, prefix.len);
        const cmp = orderCI(word[0..cmp_len], prefix);

        if (cmp == .lt) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }

    // left is now the first entry >= prefix
    const start = left;

    // Scan forward while prefix matches (case-insensitive)
    var end = start;
    while (end < entries.len) {
        if (!startsWithCI(entries[end].word, prefix)) break;
        end += 1;
    }

    return entries[start..end];
}

test "findByPrefix - finds matching entries" {
    // Sorted entries: ant, ape, apple, apply, banana
    const entries = [_]IdxEntry{
        .{ .word = "ant", .offset = 0, .size = 10 },
        .{ .word = "ape", .offset = 10, .size = 10 },
        .{ .word = "apple", .offset = 20, .size = 10 },
        .{ .word = "apply", .offset = 30, .size = 10 },
        .{ .word = "banana", .offset = 40, .size = 10 },
    };

    const results = findByPrefix(&entries, "ap");
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("ape", results[0].word);
    try std.testing.expectEqualStrings("apple", results[1].word);
    try std.testing.expectEqualStrings("apply", results[2].word);
}

test "findByPrefix - exact match" {
    const entries = [_]IdxEntry{
        .{ .word = "apple", .offset = 0, .size = 10 },
        .{ .word = "banana", .offset = 10, .size = 10 },
    };

    const results = findByPrefix(&entries, "apple");
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("apple", results[0].word);
}

test "findByPrefix - no match" {
    const entries = [_]IdxEntry{
        .{ .word = "apple", .offset = 0, .size = 10 },
        .{ .word = "banana", .offset = 10, .size = 10 },
    };

    const results = findByPrefix(&entries, "zebra");
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "findByPrefix - empty prefix returns empty" {
    const entries = [_]IdxEntry{
        .{ .word = "apple", .offset = 0, .size = 10 },
    };

    const results = findByPrefix(&entries, "");
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

// ============================================================================
// Definition Reading
// ============================================================================

pub const ReadError = error{
    BufferTooSmall,
    SeekFailed,
    ReadFailed,
    UnexpectedEof,
};

// Read a definition from .dict file given an index entry
// Seeks to offset and reads size bytes into caller-provided buffer
// Returns slice of buffer containing the definition
//
// Go equivalent: file.Seek + file.Read
pub fn readDefinition(file: std.fs.File, entry: IdxEntry, buf: []u8) ReadError![]const u8 {
    if (entry.size > buf.len) return error.BufferTooSmall;

    // Seek to definition offset
    file.seekTo(entry.offset) catch return error.SeekFailed;

    // Read definition into buffer
    const bytes_read = file.readAll(buf[0..entry.size]) catch return error.ReadFailed;
    if (bytes_read != entry.size) return error.UnexpectedEof;

    return buf[0..entry.size];
}

test "readDefinition - reads from file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write test data: "first def" at 0, "second def" at 20
    {
        const file = try tmp.dir.createFile("test.dict", .{});
        defer file.close();
        try file.writeAll("first def...........second def");
    }

    // Reopen for reading
    const file = try tmp.dir.openFile("test.dict", .{});
    defer file.close();

    const entry1 = IdxEntry{ .word = "a", .offset = 0, .size = 9 };
    const entry2 = IdxEntry{ .word = "b", .offset = 20, .size = 10 };

    var buf: [64]u8 = undefined;

    const def1 = try readDefinition(file, entry1, &buf);
    try std.testing.expectEqualStrings("first def", def1);

    const def2 = try readDefinition(file, entry2, &buf);
    try std.testing.expectEqualStrings("second def", def2);
}

test "readDefinition - buffer too small" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile("test.dict", .{});
        defer file.close();
        try file.writeAll("some definition text");
    }

    const file = try tmp.dir.openFile("test.dict", .{});
    defer file.close();

    const entry = IdxEntry{ .word = "a", .offset = 0, .size = 100 };
    var buf: [10]u8 = undefined; // Too small for size=100

    try std.testing.expectError(error.BufferTooSmall, readDefinition(file, entry, &buf));
}

// ============================================================================
// Dictionary (ties everything together)
// ============================================================================

pub const Dictionary = struct {
    entries: []IdxEntry,
    idx_data: []const u8, // entries point into this, must outlive entries
    dict_file: std.fs.File,
    allocator: std.mem.Allocator,

    // Load dictionary from a directory containing .ifo, .idx, .dict files
    // dict_name is the base name (e.g., "webster-1913" for webster-1913.ifo)
    pub fn load(allocator: std.mem.Allocator, dir_path: []const u8, dict_name: []const u8) !Dictionary {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;

        // Read and parse .ifo
        const ifo_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.ifo", .{ dir_path, dict_name });
        const ifo_data = try std.fs.cwd().readFileAlloc(allocator, ifo_path, 64 * 1024);
        defer allocator.free(ifo_data);

        const ifo = parseIfo(ifo_data) orelse return error.InvalidIfo;
        const wordcount = ifo.wordcount orelse return error.MissingWordcount;

        // Read and parse .idx
        const idx_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.idx", .{ dir_path, dict_name });
        const idx_data = try std.fs.cwd().readFileAlloc(allocator, idx_path, 100 * 1024 * 1024);
        errdefer allocator.free(idx_data);

        const entries = try parseAllEntries(allocator, idx_data, wordcount);
        errdefer allocator.free(entries);

        // Open .dict file (keep open for seeking)
        const dict_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.dict", .{ dir_path, dict_name });
        const dict_file = try std.fs.cwd().openFile(dict_path, .{});

        return Dictionary{
            .entries = entries,
            .idx_data = idx_data,
            .dict_file = dict_file,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Dictionary) void {
        self.dict_file.close();
        self.allocator.free(self.entries);
        self.allocator.free(self.idx_data);
    }

    // Look up a word and return its definition
    // Errors: WordNotFound, BufferTooSmall, SeekFailed, ReadFailed, UnexpectedEof
    pub fn lookup(self: Dictionary, word: []const u8, buf: []u8) ![]const u8 {
        const matches = findByPrefix(self.entries, word);
        if (matches.len == 0) return error.WordNotFound;

        // Return first exact match, or first prefix match
        for (matches) |entry| {
            if (std.mem.eql(u8, entry.word, word)) {
                return readDefinition(self.dict_file, entry, buf);
            }
        }
        return readDefinition(self.dict_file, matches[0], buf);
    }
};
