const std = @import("std");
pub const gfx = @cImport({
    @cInclude("pixman-1/pixman.h");
    @cInclude("fcft/fcft.h");
});

const dispatcher = @import("dispatcher.zig");

const PAD_H: i32 = 20; // horizontal padding: left margin for text, right margin for sublabels
const ROW_PAD: i32 = 8; // vertical padding above and below text within each row


pub const DrawContext = struct {
    surface_image: *gfx.pixman_image_t,
    font: *gfx.struct_fcft_font,

    scale: i32 = 1,
    width: i32,
    height: i32,
};

pub const RenderState = struct {
    prefix: []const u8,
    input: []const u8,
    expanded: ?[]const u8,
    candidates: []dispatcher.TaggedCandidate,
    selected: usize,
};

// Draw a filled rectangle at (x, y) with given width, height and color.
// Used for the separator line (h=1) and candidate highlight (h=row_h).
fn drawRect(image: *gfx.pixman_image_t, x: i32, y: i32, w: i32, h: i32, color: gfx.pixman_color_t) void {
    var c = color;
    var rect = gfx.pixman_rectangle16_t{
        .x = @intCast(x),
        .y = @intCast(y),
        .width = @intCast(w),
        .height = @intCast(h),
    };
    _ = gfx.pixman_image_fill_rectangles(gfx.PIXMAN_OP_SRC, image, &c, 1, &rect);
}

// Render a UTF-8 string onto a pixman surface image.
//
// pen_x/pen_y: starting position. pen_y is the baseline —
//   glyphs sit above it (ascent) and hang below it (descent).
//
// Rendering pipeline per glyph:
//   1. fcft rasterizes the codepoint → pixman_image_t (the glyph bitmap)
//   2. For normal glyphs: composite glyph as a mask over a solid color
//      (PIXMAN_OP_OVER blends glyph alpha with the destination)
//   3. Advance pen_x by glyph->advance.x for the next character
fn renderText(
    dst: *gfx.pixman_image_t,
    font: *gfx.struct_fcft_font,
    text: []const u8,
    pen_x: i32,
    pen_y: i32,
    color: gfx.pixman_color_t,
) void {
    // Solid fill image for the text color — used as the source in compositing.
    // pixman_image_create_solid_fill: a virtual infinite image of one color.
    var mutable_color = color;
    const src = gfx.pixman_image_create_solid_fill(&mutable_color) orelse return;
    defer _ = gfx.pixman_image_unref(src);

    var x = pen_x;

    // Iterate the UTF-8 string codepoint by codepoint.
    // std.unicode.Utf8View handles multi-byte sequences correctly.
    var iter = std.unicode.Utf8View.init(text) catch return;
    var it = iter.iterator();
    while (it.nextCodepoint()) |cp| {
        // Rasterize one character. fcft caches rasterized glyphs internally
        // so repeated calls for the same codepoint are fast.
        const glyph = gfx.fcft_rasterize_char_utf32(font, cp, gfx.FCFT_SUBPIXEL_DEFAULT) orelse continue;

        // glyph->x/y: offset from pen point to top-left of the glyph bitmap.
        // y is measured upward from baseline, so we subtract it.
        const dst_x = x + glyph.*.x;
        const dst_y = pen_y - glyph.*.y;

        if (glyph.*.is_color_glyph) {
            // Emoji: glyph->pix is already full ARGB — use as source directly.
            gfx.pixman_image_composite32(gfx.PIXMAN_OP_OVER, glyph.*.pix, null, dst, 0, 0, 0, 0, dst_x, dst_y, glyph.*.width, glyph.*.height);
        } else {
            // Normal glyph: pix is a grayscale mask — composite solid color through it.
            gfx.pixman_image_composite32(gfx.PIXMAN_OP_OVER, src, glyph.*.pix, dst, 0, 0, 0, 0, dst_x, dst_y, glyph.*.width, glyph.*.height);
        }

        x += glyph.*.advance.x;
    }
}

// Measure the pixel width of a UTF-8 string by summing glyph advances.
// Used to right-align sublabels: pen_x = WIDTH - PAD_H - measureText(font, text)
fn measureText(font: *gfx.struct_fcft_font, text: []const u8) i32 {
    var width: i32 = 0;
    var iter = std.unicode.Utf8View.init(text) catch return 0;
    var it = iter.iterator();
    while (it.nextCodepoint()) |cp| {
        const glyph = gfx.fcft_rasterize_char_utf32(font, cp, gfx.FCFT_SUBPIXEL_DEFAULT) orelse continue;
        width += glyph.*.advance.x;
    }
    return width;
}

// Redraw the window: clear + layout + commit to compositor.
// Called after every keystroke or selection change.
pub fn redraw(ctx: DrawContext, state: RenderState) void {
    // TODO scale changes at runtime should also recreate buffer

    // TODO move scaled dimensions (width, height, pad, row) into App so they are
    // computed once on scale
    const pad_h: i32 = PAD_H * ctx.scale;
    const row_pad: i32 = ROW_PAD * ctx.scale;

    // Layout metrics derived from font at runtime.
    // row_h is the same for the input row and every candidate row.
    // baseline is the pen_y offset within any row.
    const font_height: i32 = ctx.font.*.height;
    const row_h: i32 = font_height + row_pad * 2;
    const baseline: i32 = row_pad + ctx.font.*.ascent;
    const sep_y: i32 = row_h; // separator sits right below the input row

    // Colors
    const col_bg = gfx.pixman_color_t{ .red = 0x1818, .green = 0x1818, .blue = 0x2828, .alpha = 0xffff };
    const col_hl = gfx.pixman_color_t{ .red = 0x2828, .green = 0x2828, .blue = 0x5050, .alpha = 0xffff };
    const col_sep = gfx.pixman_color_t{ .red = 0x4040, .green = 0x4040, .blue = 0x5555, .alpha = 0xffff };
    const col_white = gfx.pixman_color_t{ .red = 0xffff, .green = 0xffff, .blue = 0xffff, .alpha = 0xffff };
    const col_prefix = gfx.pixman_color_t{ .red = 0x6666, .green = 0x6666, .blue = 0x8888, .alpha = 0xffff };
    const col_sub = gfx.pixman_color_t{ .red = 0x7777, .green = 0x7777, .blue = 0x9999, .alpha = 0xffff };

    // --- Background ---
    drawRect(ctx.surface_image, 0, 0, @intCast(ctx.width), @intCast(ctx.height), col_bg);

    // --- Input row ---
    // "> " prefix in muted color, then the typed text in white.
    renderText(ctx.surface_image, ctx.font, state.prefix, pad_h, baseline, col_prefix);
    const prefix_w = measureText(ctx.font, state.prefix);
    renderText(ctx.surface_image, ctx.font, state.input, pad_h + prefix_w, baseline, col_white);

    // --- Separator ---
    drawRect(ctx.surface_image, 0, sep_y, @intCast(ctx.width), 1, col_sep);

    if (state.expanded) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var row: usize = 0;
        while (lines.next()) |line| {
            const row_y = sep_y + 1 + @as(i32, @intCast(row)) * row_h;
            if (row_y + row_h > ctx.height) break;
            renderText(ctx.surface_image, ctx.font, line, pad_h, row_y + baseline, col_white);
            row += 1;
        }
    } else {
        for (state.candidates, 0..) |tc, i| {
            const row_y: i32 = sep_y + 1 + @as(i32, @intCast(i)) * row_h;
            const pen_y: i32 = row_y + baseline;

            // Highlight the selected row with a full-width rectangle.
            if (i == state.selected) {
                drawRect(ctx.surface_image, 0, row_y, @intCast(ctx.width), row_h, col_hl);
            }

            // Label — left-aligned with horizontal padding.
            renderText(ctx.surface_image, ctx.font, tc.candidate.label, pad_h, pen_y, col_white);

            // Sublabel - inline after label, dimmer color
            if (tc.candidate.sublabel) |sub| {
                const label_w = measureText(ctx.font, tc.candidate.label);
                renderText(ctx.surface_image, ctx.font, sub, pad_h + label_w + 8, pen_y, col_sub);
            }

            // Kind tag - right aligned
            const kind_str: []const u8 = switch (tc.handler.kind) {
                .calc => "calc",
                .cmd => "command",
                .app => "application",
                .dict => "dictionary",
            };
            const kind_w = measureText(ctx.font, kind_str);
            renderText(ctx.surface_image, ctx.font, kind_str, @as(i32, @intCast(ctx.width)) - pad_h - kind_w, pen_y, col_sub);
        }
    }
}
