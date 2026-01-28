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

// ============================================================================
// Tests
// ============================================================================
// Run with: zig test src/stardict.zig

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
