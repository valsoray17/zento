const std = @import("std");

/// Returns a score in (0, 1] if input is a subsequence of label, 0 otherwise.
/// Higher score = tighter match (consecutive character runs score better).
pub fn score(input: []const u8, label: []const u8) f32 {
    if (input.len == 0) return 1.0;
    var i: usize = 0;
    var consecutive: f32 = 0;
    var total: f32 = 0;
    for (label) |c| {
        if (std.ascii.toLower(c) == std.ascii.toLower(input[i])) {
            consecutive += 1;
            total += consecutive;
            i += 1;
            if (i == input.len) return total / @as(f32, @floatFromInt(label.len));
        } else {
            consecutive = 0;
        }
    }
    return 0;
}

