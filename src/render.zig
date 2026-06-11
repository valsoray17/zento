const std = @import("std");
pub const gfx = @cImport({
    @cInclude("pixman-1/pixman.h");
    @cInclude("fcft/fcft.h");
});

const dispatcher = @import("dispatcher.zig");

const PAD_H: i32 = 16; // horizontal padding: left margin for text, right margin for sublabels
pub const ROW_PAD: i32 = 6; // vertical padding above and below text within each row
pub const ICON_SIZE: i32 = 24; // display size
pub const ICON_MARGIN: i32 = 4; // gap between footer separator and icon
pub const BORDER: i32 = 1;
pub const CORNER_RADIUS: i32 = 8;

const icon_raw = @embedFile("assets/zento-icon.raw");
const ICON_RAW_SIZE: i32 = 96; // pixel size of the embedded raw file

pub const DrawContext = struct {
    surface_image: *gfx.pixman_image_t,
    font: *gfx.struct_fcft_font,
    font_large: *gfx.struct_fcft_font,

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
    scroll_offset: usize,
    expanded_scroll: usize,
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

// Draw rounded corners by rasterizing arcs pixel-by-pixel.
// Pixels outside the outer radius get col_bg (erased), pixels between
// outer and inner radius get col_border (the arc), inner pixels get col_bg.
fn drawCorners(image: *gfx.pixman_image_t, w: i32, h: i32, r: i32, bw: i32, col_bg: gfx.pixman_color_t, col_border: gfx.pixman_color_t) void {
    const col_clear = gfx.pixman_color_t{ .red = 0, .green = 0, .blue = 0, .alpha = 0 };
    const outer_sq = r * r;
    const inner_sq = (r - bw) * (r - bw);
    var dy: i32 = 0;
    while (dy < r) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < r) : (dx += 1) {
            const adx = r - dx;
            const ady = r - dy;
            const dist_sq = adx * adx + ady * ady;
            const color = if (dist_sq > outer_sq) col_clear else if (dist_sq > inner_sq) col_border else col_bg;
            drawRect(image, dx, dy, 1, 1, color); // top-left
            drawRect(image, w - 1 - dx, dy, 1, 1, color); // top-right
            drawRect(image, dx, h - 1 - dy, 1, 1, color); // bottom-left
            drawRect(image, w - 1 - dx, h - 1 - dy, 1, 1, color); // bottom-right
        }
    }
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

// Returns the byte length of the longest prefix of `text` that fits within
// max_w, or null if the full text fits. Caller subtracts ellipsis width from
// max_w before calling so this function has no knowledge of ellipsis.
fn truncateText(font: *gfx.struct_fcft_font, text: []const u8, max_w: i32) ?usize {
    var w: i32 = 0;
    var fit_byte: usize = 0;
    var iter = std.unicode.Utf8View.init(text) catch return null;
    var it = iter.iterator();
    while (it.nextCodepoint()) |cp| {
        const glyph = gfx.fcft_rasterize_char_utf32(font, cp, gfx.FCFT_SUBPIXEL_DEFAULT) orelse continue;
        w += glyph.*.advance.x;
        if (w > max_w) return fit_byte;
        fit_byte = it.i;
    }
    return null;
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

fn cardHeight(ctx: DrawContext) i32 {
    const row_pad: i32 = ROW_PAD * ctx.scale;
    // Always reserves two lines: large result + normal sublabel.
    // Space is reserved even when sublabel is absent for visual consistency.
    return ctx.font_large.*.height + ctx.font.*.height + row_pad * 4 + 4;
}

// Render a result card for instant handlers (calc, convert).
// Fixed height always — reserves space for result + sublabel line.
// Layout: [input] => [result]  right-aligned in large font.
//                   [sublabel] right-aligned in normal font below result.
fn drawCard(ctx: DrawContext, input: []const u8, tc: dispatcher.TaggedCandidate, y: i32) void {
    const pad_h: i32 = PAD_H * ctx.scale;
    const card_h: i32 = cardHeight(ctx);

    const col_hl = gfx.pixman_color_t{ .red = 0x2828, .green = 0x2828, .blue = 0x5050, .alpha = 0xffff };
    const col_white = gfx.pixman_color_t{ .red = 0xffff, .green = 0xffff, .blue = 0xffff, .alpha = 0xffff };
    const col_prefix = gfx.pixman_color_t{ .red = 0x6666, .green = 0x6666, .blue = 0x8888, .alpha = 0xffff };
    const col_sep = gfx.pixman_color_t{ .red = 0x4040, .green = 0x4040, .blue = 0x5555, .alpha = 0xffff };
    const col_sub = gfx.pixman_color_t{ .red = 0x7777, .green = 0x7777, .blue = 0x9999, .alpha = 0xffff };

    drawRect(ctx.surface_image, 0, y, ctx.width, card_h, col_hl);

    // Left: input + arrow, normal font centered in card height
    const input_baseline = y + @divTrunc(card_h - ctx.font.*.height, 2) + ctx.font.*.ascent;
    const input_w = measureText(ctx.font, input);
    renderText(ctx.surface_image, ctx.font, input, pad_h, input_baseline, col_prefix);
    renderText(ctx.surface_image, ctx.font, "=>", pad_h + input_w + 8, input_baseline, col_sep);

    // Right: result + optional sublabel, centered as a block
    const result_w = measureText(ctx.font_large, tc.candidate.label);
    const result_x = ctx.width - pad_h - result_w;
    if (tc.candidate.sublabel) |sub| {
        // Two-line block: center (large + gap + normal) together
        const block_h = ctx.font_large.*.height + 4 + ctx.font.*.height;
        const block_top = y + @divTrunc(card_h - block_h, 2);
        const result_baseline = block_top + ctx.font_large.*.ascent;
        const sub_baseline = block_top + ctx.font_large.*.height + 4 + ctx.font.*.ascent;
        renderText(ctx.surface_image, ctx.font_large, tc.candidate.label, result_x, result_baseline, col_white);
        const sub_w = measureText(ctx.font, sub);
        renderText(ctx.surface_image, ctx.font, sub, ctx.width - pad_h - sub_w, sub_baseline, col_sub);
    } else {
        // Single line: center large font in card height
        const result_baseline = y + @divTrunc(card_h - ctx.font_large.*.height, 2) + ctx.font_large.*.ascent;
        renderText(ctx.surface_image, ctx.font_large, tc.candidate.label, result_x, result_baseline, col_white);
    }
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
    //const col_border = gfx.pixman_color_t{ .red = 0x4a4a, .green = 0x4a4a, .blue = 0x6a6a, .alpha = 0xffff };
    const col_border = gfx.pixman_color_t{ .red = 0xb4b4, .green = 0xbebe, .blue = 0xfefe, .alpha = 0xffff };
    const col_white = gfx.pixman_color_t{ .red = 0xffff, .green = 0xffff, .blue = 0xffff, .alpha = 0xffff };
    const col_prefix = gfx.pixman_color_t{ .red = 0x6666, .green = 0x6666, .blue = 0x8888, .alpha = 0xffff };
    const col_sub = gfx.pixman_color_t{ .red = 0x7777, .green = 0x7777, .blue = 0x9999, .alpha = 0xffff };

    // --- Background ---
    drawRect(ctx.surface_image, 0, 0, @intCast(ctx.width), @intCast(ctx.height), col_bg);

    // --- Border ---
    const border: i32 = BORDER * ctx.scale;
    drawRect(ctx.surface_image, 0, 0, ctx.width, border, col_border); // top
    drawRect(ctx.surface_image, 0, ctx.height - border, ctx.width, border, col_border); // bottom
    drawRect(ctx.surface_image, 0, 0, border, ctx.height, col_border); // left
    drawRect(ctx.surface_image, ctx.width - border, 0, border, ctx.height, col_border); // right
    drawCorners(ctx.surface_image, ctx.width, ctx.height, CORNER_RADIUS * ctx.scale, border, col_bg, col_border);

    const icon_size: i32 = ICON_SIZE * ctx.scale;
    const icon_margin: i32 = ICON_MARGIN * ctx.scale;
    const footer_h: i32 = icon_size + icon_margin * 2;
    const footer_sep_y: i32 = ctx.height - footer_h - border;

    // --- Input row ---
    // "> " prefix in muted color, then the typed text in white.
    renderText(ctx.surface_image, ctx.font, state.prefix, pad_h, baseline, col_prefix);
    const prefix_w = measureText(ctx.font, state.prefix);
    renderText(ctx.surface_image, ctx.font, state.input, pad_h + prefix_w, baseline, col_white);

    // --- Separator ---
    drawRect(ctx.surface_image, border, sep_y, ctx.width - border * 2, 1, col_sep);

    // --- Footer separator ---
    drawRect(ctx.surface_image, border, footer_sep_y, ctx.width - border * 2, 1, col_sep);

    if (state.expanded) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var line_idx: usize = 0;
        var row: usize = 0;
        while (lines.next()) |line| : (line_idx += 1) {
            if (line_idx < state.expanded_scroll) continue;
            const row_y = sep_y + 1 + @as(i32, @intCast(row)) * row_h;
            if (row_y + row_h > footer_sep_y) break;
            renderText(ctx.surface_image, ctx.font, line, pad_h, row_y + baseline, col_white);
            row += 1;
        }
    } else {
        var content_y: i32 = sep_y + 1;
        const visible = state.candidates[state.scroll_offset..];
        for (visible, state.scroll_offset..) |tc, i| {
            if (content_y >= footer_sep_y) break;

            if (tc.handler.kind == .calc) {
                drawCard(ctx, state.input, tc, content_y);
                content_y += cardHeight(ctx);
                continue;
            }

            const row_y = content_y;
            const pen_y: i32 = row_y + baseline;
            if (row_y + row_h > footer_sep_y) break;

            // Highlight the selected row, inset by border so it doesn't overlap it.
            if (i == state.selected) {
                drawRect(ctx.surface_image, border, row_y, ctx.width - border * 2, row_h, col_hl);
            }

            // Label — left-aligned with horizontal padding.
            renderText(ctx.surface_image, ctx.font, tc.candidate.label, pad_h, pen_y, col_white);

            // Kind tag - right aligned
            const kind_str: []const u8 = switch (tc.handler.kind) {
                .calc => "[calc]",
                .cmd => "[cmd]",
                .app => "[app]",
                .dict => "[dict]",
            };
            const kind_w = measureText(ctx.font, kind_str);
            const kind_x: i32 = @as(i32, @intCast(ctx.width)) - pad_h - kind_w;
            renderText(ctx.surface_image, ctx.font, kind_str, kind_x, pen_y, col_sub);

            // Sublabel - inline after label, truncated with ellipsis if it would overlap kind tag
            if (tc.candidate.sublabel) |sub| {
                const label_w = measureText(ctx.font, tc.candidate.label);
                const sub_x = pad_h + label_w + 16;
                const ellipsis_w = measureText(ctx.font, "…");
                const sub_max_w = kind_x - sub_x - pad_h - ellipsis_w;
                if (truncateText(ctx.font, sub, sub_max_w)) |len| {
                    renderText(ctx.surface_image, ctx.font, sub[0..len], sub_x, pen_y, col_sub);
                    const truncated_w = measureText(ctx.font, sub[0..len]);
                    renderText(ctx.surface_image, ctx.font, "…", sub_x + truncated_w, pen_y, col_sub);
                } else {
                    renderText(ctx.surface_image, ctx.font, sub, sub_x, pen_y, col_sub);
                }
            }

            content_y += row_h;
        }
    }

    // --- Footer icon (right-aligned, vertically centered in footer strip) ---
    const icon_img = gfx.pixman_image_create_bits(
        gfx.PIXMAN_a8r8g8b8,
        ICON_RAW_SIZE,
        ICON_RAW_SIZE,
        @ptrCast(@alignCast(@constCast(icon_raw.ptr))),
        ICON_RAW_SIZE * 4,
    ) orelse return;
    defer _ = gfx.pixman_image_unref(icon_img);

    // Scale down from raw size to display size (96 → 24, factor 4x)
    const scale_factor: f64 = @as(f64, @floatFromInt(ICON_RAW_SIZE)) / @as(f64, @floatFromInt(icon_size));
    const s: i32 = @intFromFloat(scale_factor * 65536.0);
    var transform = gfx.pixman_transform_t{ .matrix = .{
        .{ s, 0, 0 },
        .{ 0, s, 0 },
        .{ 0, 0, 65536 },
    } };
    _ = gfx.pixman_image_set_transform(icon_img, &transform);
    _ = gfx.pixman_image_set_filter(icon_img, gfx.PIXMAN_FILTER_BILINEAR, null, 0);

    const icon_x: i32 = ctx.width - icon_size - icon_margin;
    const icon_y: i32 = footer_sep_y + icon_margin;

    var alpha_color = gfx.pixman_color_t{ .red = 0, .green = 0, .blue = 0, .alpha = 0xdfff };
    const alpha_mask = gfx.pixman_image_create_solid_fill(&alpha_color) orelse return;
    defer _ = gfx.pixman_image_unref(alpha_mask);

    gfx.pixman_image_composite32(
        gfx.PIXMAN_OP_OVER,
        icon_img,
        alpha_mask,
        ctx.surface_image,
        0,
        0,
        0,
        0,
        icon_x,
        icon_y,
        icon_size,
        icon_size,
    );
}
