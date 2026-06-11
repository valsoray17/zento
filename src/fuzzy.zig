const std = @import("std");

/// Returns a score > 0 if input is a subsequence of label, 0 otherwise.
/// Higher score = tighter match.
/// Scoring:
///   - Consecutive character runs are rewarded quadratically (run of N scores N*(N+1)/2)
///   - Match starting at a word boundary (start of string, or after space/dash/underscore/dot)
///     gets a 2x bonus
pub fn score(input: []const u8, label: []const u8) f32 {
    // TODO why in fuzzel 'gogo' input shows both Google Chrome and Problem Reporting?
    if (input.len == 0) return 1.0;
    var i: usize = 0; // position in input
    var consecutive: f32 = 0;
    var total: f32 = 0;
    var first_match_pos: ?usize = null;

    for (label, 0..) |c, pos| {
        if (std.ascii.toLower(c) == std.ascii.toLower(input[i])) {
            consecutive += 1;
            total += consecutive;
            if (first_match_pos == null) first_match_pos = pos;
            i += 1;
            if (i == input.len) {
                // Apply word boundary bonus
                const boundary = if (first_match_pos.? == 0) true else isSeparator(label[first_match_pos.? - 1]);
                return if (boundary) total * 2.0 else total;
            }
        } else {
            consecutive = 0;
        }
    }
    return 0;
}

fn isSeparator(c: u8) bool {
    return c == ' ' or c == '-' or c == '_' or c == '.';
}
