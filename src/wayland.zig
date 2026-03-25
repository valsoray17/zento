const std = @import("std");

const wl = @import("wayland").client.wl;
const zwlr = @import("wayland").client.zwlr;

const calc = @import("calc.zig");
const convert = @import("convert.zig");
const dict = @import("dict.zig");
const fuzzy = @import("fuzzy.zig");
const handler = @import("handler.zig");
const systemd = @import("systemd.zig");
const apps = @import("apps.zig");

const gfx = @cImport({
    @cInclude("pixman-1/pixman.h");
    @cInclude("fcft/fcft.h");
});
const xkb = @cImport(@cInclude("xkbcommon/xkbcommon.h"));

// Application state — passed as context pointer to every Wayland listener.
// All compositor-side objects we own live here so listeners can reach them.
//
// Go analogy: a struct holding all the net.Conn, channels, and shared state
// for a long-running client — passed around instead of using globals.
const WIDTH: u32 = 600;
const HEIGHT: u32 = 400;
const PAD_H: i32 = 20; // horizontal padding: left margin for text, right margin for sublabels
const ROW_PAD: i32 = 8; // vertical padding above and below text within each row

// Modes
const Mode = struct {
    prefix: []const u8,
    handlers: []const *const handler.Handler,
};

const default_mode = Mode{
    .prefix = "> ",
    .handlers = &.{ &calc.handler, &convert.handler, &systemd.handler, &apps.handler },
};

const dict_mode = Mode{
    .prefix = "[dict] ",
    // potentially can merge multiple dictionaries in the future
    .handlers = &.{&dict.handler},
};

// Input state
// Text input buffer — accumulates keypresses as UTF-8 bytes.
// cursor_byte is a byte offset into input_buf (not a codepoint index).
// A 4-byte emoji at the start means cursor_byte=4, not cursor_byte=1.
const InputState = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    selected: usize = 0,
};

const TaggedCandidate = struct {
    candidate: handler.Candidate,
    handler: *const handler.Handler,
};

const OutputEntry = struct { output: *wl.Output, scale: u32 };

const App = struct {
    // Globals: one per interface the compositor advertises in the registry.
    // We bind each one during the first roundtrip.
    // Optional because we don't have them until the registry listener fires.
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,

    // Our objects, created after globals are bound.
    layer_surface: ?*zwlr.LayerSurfaceV1 = null,
    seat: ?*wl.Seat = null,
    keyboard: ?*wl.Keyboard = null,

    // Output scale tracking — see OutputEntry above App.
    // Defaults to 1 until wl_surface.enter fires and tells us the real output.
    outputs: [8]?OutputEntry = [_]?OutputEntry{null} ** 8,
    scale: u32 = 1,

    // xkbcommon state — populated when compositor sends the keymap event.
    // context: global xkb context (needed to create keymaps)
    // keymap:  the keyboard layout received from the compositor
    // state:   tracks current modifier state (shift/ctrl/alt/capslock...)
    xkb_context: ?*xkb.xkb_context = null,
    xkb_keymap: ?*xkb.xkb_keymap = null,
    xkb_state: ?*xkb.xkb_state = null,

    // Drawing resources — set in run() after creation, used by redraw().
    // Listeners only receive *App, so we store these here rather than
    // passing them through every call path.
    surface: ?*wl.Surface = null,
    surface_image: ?*gfx.pixman_image_t = null,
    wl_buffer: ?*wl.Buffer = null,
    font: ?*gfx.struct_fcft_font = null,

    // Set to true when compositor sends its first configure event.
    // We must not attach a buffer before that — protocol violation.
    configured: bool = false,
    running: bool = true,

    input: InputState = .{},

    // These are the things required for the actual app logic
    arena: ?*std.heap.ArenaAllocator = null,
    mode: *const Mode = &default_mode,
    static_candidates: []TaggedCandidate = &.{},
    candidates: []TaggedCandidate = &.{},
    expanded: ?[]const u8 = null,
};

pub fn run() !void {
    var app = App{};

    // fcft_init: sets up fontconfig, freetype, logging.
    // Must be called before any other fcft function.
    // Args: colorize log output, use syslog, log level.
    if (!gfx.fcft_init(gfx.FCFT_LOG_COLORIZE_AUTO, false, gfx.FCFT_LOG_CLASS_WARNING)) {
        return error.FcftInitFailed;
    }
    defer gfx.fcft_fini();

    // --- Phase 1: connect and discover globals ---
    //
    // Unix domain socket: $XDG_RUNTIME_DIR/wayland-0 (e.g. /run/user/1000/wayland-0)
    // Same connect/send/recv API as TCP, but kernel-only — no network stack.
    // Binary wire format: [object_id: u32][opcode+size: u32][args...]
    //
    // compositor = server, we = client. Full-duplex:
    //   us → compositor : requests  (create surface, attach buffer, commit...)
    //   compositor → us : events    (configure, key press, close...)
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    // wl_registry: compositor's directory of available interfaces.
    // Requesting it sends our first bytes down the socket.
    const registry = try display.getRegistry();

    // Store fn pointer + &app locally. No I/O yet.
    // Callback fires during roundtrip when registry events arrive.
    registry.setListener(*App, registryListener, &app);

    // roundtrip():
    //   1. Flush pending requests (getRegistry) to socket
    //   2. Send wl_display.sync marker: "tell me when you've handled everything so far"
    //   3. Read socket in a loop, dispatch events → listeners
    //   4. Return when sync fires — all prior events guaranteed delivered
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const compositor = app.compositor orelse return error.NoCompositor;
    const shm = app.shm orelse return error.NoShm;
    const layer_shell = app.layer_shell orelse return error.NoLayerShell;

    // --- Phase 2: create the overlay surface ---
    //
    // wl_surface: a raw canvas with no role or position yet.
    //   Think of it as an empty framebuffer — no size, no location, invisible.
    //
    // zwlr_layer_surface: assigns a role to the surface — "you are an overlay".
    //   This is a wlroots extension supported by Mutter, KWin, sway, etc.
    //   Layer shell gives us positioning without xdg-shell's app-window semantics.
    //
    // Wayland surfaces are double-buffered:
    //   draw into buffer → commit → compositor atomically swaps it in
    //   No tearing: the swap happens at vblank.
    const surface = try compositor.createSurface();
    app.surface = surface;
    // Register surface listener now so wl_surface.enter arrives during the
    // configure roundtrip and app.scale is set before we create the buffer.
    surface.setListener(*App, surfaceListener, &app);

    // getLayerSurface args:
    //   surface  — the raw wl_surface to promote
    //   null     — output (null = compositor picks primary monitor)
    //   .overlay — layer: background < bottom < top < overlay
    //   "launcher" — namespace: lets compositor identify our window type
    const layer_surface = try layer_shell.getLayerSurface(surface, null, .overlay, "launcher");
    app.layer_surface = layer_surface;

    // No anchor = compositor centers us on screen.
    // Anchoring edges (top/bottom/left/right) would make us a panel bar.
    layer_surface.setSize(WIDTH, HEIGHT);
    layer_surface.setAnchor(.{});

    // .on_demand: compositor gives us focus when visible, user can still use
    // compositor shortcuts. .exclusive is for lock screens only — causes bugs
    // in sway/Hyprland and gives users no escape if the app hangs.
    layer_surface.setKeyboardInteractivity(.on_demand);

    // Register configure/closed listener before committing.
    layer_surface.setListener(*App, layerSurfaceListener, &app);

    // Committing with no buffer sends the surface to the compositor.
    // This triggers the configure handshake:
    //   us: surface.commit()
    //   compositor: "here are your final dimensions, serial=N — acknowledge before drawing"
    //   us: layer_surface.ackConfigure(N)   ← done in layerSurfaceListener
    surface.commit();

    // Second roundtrip: wait for configure event.
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    if (!app.configured) return error.NotConfigured;

    // --- Phase 3: load font ---
    //
    // fcft_from_name: resolves font name via fontconfig, loads it via freetype.
    // Takes an array of font names — fcft tries each in order, falling back to
    // the next if a glyph is missing (useful for emoji fallback fonts).
    //
    // The attributes string passes options to fontconfig, e.g. "size=14:weight=bold".
    // null = use defaults.
    // [*c]const u8 = C-style pointer to const char (what fcft_from_name expects).
    // @ptrCast: reinterpret &font_names as the [*c][*c]const u8 the C API wants.
    var font_buf: [64]u8 = undefined;
    const font_name_z = std.fmt.bufPrintZ(&font_buf, "monospace:size={d}", .{14 * app.scale}) 
        catch return error.FontNameTooLong;
    var font_names = [_][*c]const u8{font_name_z.ptr};
    const font = gfx.fcft_from_name(font_names.len, @ptrCast(&font_names), null) orelse {
        return error.FontLoadFailed;
    };
    defer gfx.fcft_destroy(font);
    app.font = font;

    // --- Phase 4: shared memory buffer ---
    //
    // wl_shm is Wayland's software rendering path — no GPU required.
    //
    // The trick: both us and the compositor mmap the same file descriptor.
    // We write pixels → compositor reads them. Zero copies across the socket —
    // only the fd number travels over the wire, not the pixel data itself.
    //
    // memfd_create: anonymous RAM-backed file (Linux-specific).
    //   Better than shm_open: no name, no /dev/shm file to clean up on crash.
    //   w
    //   Lives in RAM, behaves like a regular file (ftruncate, mmap, etc).
    const physical_w: u32 = WIDTH * app.scale;
    const physical_h: u32 = HEIGHT * app.scale;
    const stride: u32 = physical_w * 4; // 4 bytes per pixel: [A][R][G][B]
    const size: usize = stride * physical_h;

    const fd = try std.posix.memfd_create("zento-shm", 0);
    defer std.posix.close(fd);

    // Set the file size — starts at 0 bytes by default
    try std.posix.ftruncate(fd, @intCast(size));

    // Map into our address space: we get a []u8 slice over WIDTH*HEIGHT*4 bytes.
    // SHARED: writes are visible to other mmaps of the same fd (i.e. the compositor).
    const data = try std.posix.mmap(
        null,
        size,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer std.posix.munmap(data);

    // Tell the compositor about the fd — it will mmap it on its side.
    // pool represents the entire shared memory region.
    const pool = try shm.createPool(fd, @intCast(size));
    defer pool.destroy();

    // Carve a wl_buffer out of the pool.
    // offset=0: buffer starts at the beginning of the pool.
    // argb8888: 4 bytes per pixel, [A][R][G][B] in memory order.
    const buffer = try pool.createBuffer(0, @intCast(physical_w), @intCast(physical_h), @intCast(stride), .argb8888);
    defer buffer.destroy();
    app.wl_buffer = buffer;

    // --- Phase 4: draw and commit ---
    //
    // Wrap our mmap'd pixel buffer as a pixman image — just a view, no copy.
    // All drawing operations (fill, text) go through this image.
    const surface_image = gfx.pixman_image_create_bits(
        gfx.PIXMAN_a8r8g8b8,
        @intCast(physical_w),
        @intCast(physical_h),
        @ptrCast(@alignCast(data.ptr)),
        @intCast(stride),
    ) orelse return error.PixmanImageFailed;
    defer _ = gfx.pixman_image_unref(surface_image);
    app.surface_image = surface_image;

    // --- Phase 5: event loop ---
    //
    // dispatch() blocks until the compositor sends something (key press, close, etc),
    // then processes all pending events and calls registered listeners.
    //
    //   socket readable → dispatch() → listeners fire → (render) → repeat
    //
    // xkb_context: global object needed for all xkb operations.
    // Created once, lives for the duration of the session.
    app.xkb_context = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
        return error.XkbContextFailed;
    defer xkb.xkb_context_unref(app.xkb_context);
    defer if (app.xkb_state) |s| xkb.xkb_state_unref(s);
    defer if (app.xkb_keymap) |k| xkb.xkb_keymap_unref(k);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    app.arena = &arena;

    loadMode(&app, &default_mode);
    runDispatcher(&app);
    redraw(&app);

    std.debug.print("Window open. Press Escape to close.\n", .{});
    while (app.running) {
        if (display.dispatch() != .SUCCESS) break;
    }
}

fn loadMode(app: *App, mode: *const Mode) void {
    std.heap.page_allocator.free(app.static_candidates);
    app.mode = mode;

    var candidates: std.ArrayListUnmanaged(TaggedCandidate) = .empty;
    for (app.mode.handlers) |h| {
        switch (h.source) {
            .load => |f| for (f(std.heap.page_allocator) catch continue) |cand|
                candidates.append(std.heap.page_allocator, .{ .candidate = cand, .handler = h }) catch continue,
            .suggest => {},
        }
    }

    app.static_candidates = candidates.toOwnedSlice(std.heap.page_allocator) catch &.{};
}

// Collect candidates from all handlers for the current input.
// Resets the arena first — previous candidates are invalidated.
// Called after every input change (insert, backspace, delete).
fn runDispatcher(app: *App) void {
    const arena = app.arena orelse return;
    // frees all allocations locally but keeps the backing memory pages mapped
    _ = arena.reset(.retain_capacity);
    const alloc = arena.allocator();

    const input = app.input.buf[0..app.input.len];

    // Collect candidates
    var all: std.ArrayListUnmanaged(TaggedCandidate) = .empty;
    // static hadlers
    all.appendSlice(alloc, app.static_candidates) catch {};
    // dynamic handlers
    for (app.mode.handlers) |h| {
        if (input.len == 0) break;
        switch (h.source) {
            .suggest => |f| for (f(alloc, input) catch continue) |cand|
                all.append(alloc, .{ .candidate = cand, .handler = h }) catch continue,
            .load => {},
        }
    }

    // Score
    const Ranked = struct { tagged: TaggedCandidate, score: f32 };
    var ranked: std.ArrayListUnmanaged(Ranked) = .empty;
    for (all.items) |tc| {
        const s: f32 = if (tc.handler.kind == .calc) 1.0 else fuzzy.score(input, tc.candidate.label);
        if (s > 0) ranked.append(alloc, .{ .tagged = tc, .score = s }) catch continue;
    }

    // Sort — .calc first, then by score
    // Explicit kind priority is needed because fuzzy scores can exceed 1.0.
    std.mem.sort(Ranked, ranked.items, {}, struct {
        fn gt(_: void, a: Ranked, b: Ranked) bool {
            const a_calc = a.tagged.handler.kind == .calc;
            const b_calc = b.tagged.handler.kind == .calc;
            if (a_calc != b_calc) return a_calc;
            return a.score > b.score;
        }
    }.gt);

    // Strip scores - store ordered TaggedCandidate only
    // TODO: derive max rows from window height / row_h instead of hardcoding 8
    const top = ranked.items[0..@min(ranked.items.len, 8)];
    const out = alloc.alloc(TaggedCandidate, top.len) catch {
        app.candidates = &.{};
        return;
    };
    for (top, 0..) |r, i| out[i] = r.tagged;
    app.candidates = out;

    if (app.candidates.len == 0) {
        app.input.selected = 0;
    } else if (app.input.selected >= app.candidates.len) {
        app.input.selected = app.candidates.len - 1;
    }
}

// Redraw the window: clear + layout + commit to compositor.
// Called after every keystroke or selection change.
fn redraw(app: *App) void {
    // TODO scale changes at runtime should also recreate buffer
    const surface = app.surface orelse return;
    const image = app.surface_image orelse return;
    const buffer = app.wl_buffer orelse return;
    const font = app.font orelse return;

    // TODO move scaled dimensions (w, h, pad, row) into App so they are
    // computed once on scale
    const scale: i32 = @intCast(app.scale);
    const w: i32 = @as(i32, @intCast(WIDTH)) * scale;
    const h: i32 = @as(i32, @intCast(HEIGHT)) * scale;
    const pad_h: i32 = PAD_H * scale;
    const row_pad: i32 = ROW_PAD * scale;

    // Layout metrics derived from font at runtime.
    // row_h is the same for the input row and every candidate row.
    // baseline is the pen_y offset within any row.
    const font_height: i32 = font.*.height;
    const row_h: i32 = font_height + row_pad * 2;
    const baseline: i32 = row_pad + font.*.ascent;
    const sep_y: i32 = row_h; // separator sits right below the input row

    // Colors
    const col_bg = gfx.pixman_color_t{ .red = 0x1818, .green = 0x1818, .blue = 0x2828, .alpha = 0xffff };
    const col_hl = gfx.pixman_color_t{ .red = 0x2828, .green = 0x2828, .blue = 0x5050, .alpha = 0xffff };
    const col_sep = gfx.pixman_color_t{ .red = 0x4040, .green = 0x4040, .blue = 0x5555, .alpha = 0xffff };
    const col_white = gfx.pixman_color_t{ .red = 0xffff, .green = 0xffff, .blue = 0xffff, .alpha = 0xffff };
    const col_prefix = gfx.pixman_color_t{ .red = 0x6666, .green = 0x6666, .blue = 0x8888, .alpha = 0xffff };
    const col_sub = gfx.pixman_color_t{ .red = 0x7777, .green = 0x7777, .blue = 0x9999, .alpha = 0xffff };

    // --- Background ---
    drawRect(image, 0, 0, @intCast(w), @intCast(h), col_bg);

    // --- Input row ---
    // "> " prefix in muted color, then the typed text in white.
    const prefix = app.mode.prefix;
    renderText(image, font, prefix, pad_h, baseline, col_prefix);
    const prefix_w = measureText(font, prefix);
    renderText(image, font, app.input.buf[0..app.input.len], pad_h + prefix_w, baseline, col_white);

    // --- Separator ---
    drawRect(image, 0, sep_y, @intCast(w), 1, col_sep);

    if (app.expanded) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var row: usize = 0;
        while (lines.next()) |line| {
            const row_y = sep_y + 1 + @as(i32, @intCast(row)) * row_h;
            if (row_y + row_h > @as(i32, h)) break;
            renderText(image, font, line, pad_h, row_y + baseline, col_white);
            row += 1;
        }
    } else {
        for (app.candidates, 0..) |tc, i| {
            const row_y: i32 = sep_y + 1 + @as(i32, @intCast(i)) * row_h;
            const pen_y: i32 = row_y + baseline;

            // Highlight the selected row with a full-width rectangle.
            if (i == app.input.selected) {
                drawRect(image, 0, row_y, @intCast(w), row_h, col_hl);
            }

            // Label — left-aligned with horizontal padding.
            renderText(image, font, tc.candidate.label, pad_h, pen_y, col_white);

            // Sublabel - inline after label, dimmer color
            if (tc.candidate.sublabel) |sub| {
                const label_w = measureText(font, tc.candidate.label);
                renderText(image, font, sub, pad_h + label_w + 8, pen_y, col_sub);
            }

            // Kind tag - right aligned
            const kind_str: []const u8 = switch (tc.handler.kind) {
                .calc => "calc",
                .cmd => "command",
                .app => "application",
                .dict => "dictionary",
            };
            const kind_w = measureText(font, kind_str);
            renderText(image, font, kind_str, @as(i32, @intCast(w)) - pad_h - kind_w, pen_y, col_sub);
        }
    }

    surface.setBufferScale(scale);
    surface.attach(buffer, 0, 0);
    surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    surface.commit();
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

// Compositor response to our surface.commit().
// We must ackConfigure() before attaching any buffer — it's a protocol handshake.
// The serial ties our ack to this specific configure event (compositor may send many).
fn layerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, app: *App) void {
    switch (event) {
        .configure => |ev| {
            // Acknowledge: "I saw configure serial N, I will comply"
            layer_surface.ackConfigure(ev.serial);
            app.configured = true;
        },
        .closed => {
            // Compositor told us to go away (e.g. compositor shutting down)
            app.running = false;
        },
    }
}

// wl_seat: represents a group of input devices (keyboard + pointer + touch).
// The capabilities event tells us which are present on this seat.
fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, app: *App) void {
    switch (event) {
        .capabilities => |ev| {
            // Capability is a packed struct bitfield: .keyboard, .pointer, .touch
            if (ev.capabilities.keyboard) {
                const keyboard = seat.getKeyboard() catch return;
                app.keyboard = keyboard;
                keyboard.setListener(*App, keyboardListener, app);
            }
        },
        .name => {},
    }
}

// wl_keyboard: raw key events from the compositor.
// At this stage we just print the raw Linux keycode.
// xkbcommon (piece 2) will translate these to actual characters.
fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, app: *App) void {
    switch (event) {
        .keymap => |ev| {
            // Compositor sends the keymap once on focus, describing the keyboard layout.
            // It arrives as a file descriptor containing an XKB text-format string.
            // We mmap it to read the string, then hand it to xkbcommon.
            if (ev.format != .xkb_v1) return;
            defer std.posix.close(ev.fd);

            const map_str = std.posix.mmap(
                null,
                ev.size,
                std.posix.PROT.READ,
                .{ .TYPE = .PRIVATE },
                ev.fd,
                0,
            ) catch return;
            defer std.posix.munmap(map_str);

            const keymap = xkb.xkb_keymap_new_from_string(
                app.xkb_context,
                map_str.ptr,
                xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
                xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
            ) orelse return;

            const state = xkb.xkb_state_new(keymap) orelse {
                xkb.xkb_keymap_unref(keymap);
                return;
            };

            // Replace any previous keymap/state (compositor can resend on layout change)
            if (app.xkb_state) |old| xkb.xkb_state_unref(old);
            if (app.xkb_keymap) |old| xkb.xkb_keymap_unref(old);
            app.xkb_keymap = keymap;
            app.xkb_state = state;
        },
        .key => |ev| handleKey(app, ev.key, ev.state),
        .modifiers => |ev| {
            // Keep xkb state in sync with Shift/Ctrl/Alt/CapsLock changes.
            // Without this, xkb_state_key_get_utf32 would ignore modifiers —
            // 'a' would never become 'A' when Shift is held.
            if (app.xkb_state) |state| {
                _ = xkb.xkb_state_update_mask(
                    state,
                    ev.mods_depressed, // physically held modifier keys
                    ev.mods_latched, // temporarily active (e.g. one-shot shift)
                    ev.mods_locked, // toggled (CapsLock)
                    0,
                    0,
                    ev.group, // keyboard layout group (for multi-layout setups)
                );
            }
        },
        .enter => {},
        .leave => {
            app.running = false;
        },
        .repeat_info => {},
    }
}

// Handle a single key press event.
// Extracted from keyboardListener so the outer switch stays a clean event dispatcher.
fn handleKey(app: *App, key: u32, state: wl.Keyboard.KeyState) void {
    if (state != .pressed) return;

    // Escape: raw keycode check, no xkb needed
    if (key == 1) {
        if (app.expanded != null) {
            // we are in expanded mode
            std.heap.page_allocator.free(app.expanded.?);
            app.expanded = null;
            redraw(app);
        } else if (app.mode == &default_mode) {
            // in default mode, close the app
            app.running = false;
        } else {
            // we are one level into another mode
            loadMode(app, &default_mode);
            app.input = .{};
            runDispatcher(app);
            redraw(app);
        }
        return;
    }

    // xkbcommon uses X11 keycodes = Linux evdev keycode + 8
    const xkb_key = key + 8;
    const xkb_state = app.xkb_state orelse return;
    const sym = xkb.xkb_state_key_get_one_sym(xkb_state, xkb_key);

    switch (sym) {
        xkb.XKB_KEY_BackSpace => {
            // Remove the codepoint immediately before the cursor.
            // UTF-8 continuation bytes are 0x80–0xBF (top bits: 10xxxxxx).
            // Walking backwards past them lands on the sequence's lead byte.
            if (app.input.cursor > 0) {
                var start = app.input.cursor - 1;
                while (start > 0 and app.input.buf[start] & 0xC0 == 0x80) : (start -= 1) {}
                const removed = app.input.cursor - start;
                std.mem.copyForwards(u8, app.input.buf[start .. app.input.len - removed], app.input.buf[app.input.cursor..app.input.len]);
                app.input.len -= removed;
                app.input.cursor = start;
                runDispatcher(app);
                redraw(app);
            }
        },
        xkb.XKB_KEY_Delete => {
            // Remove the codepoint at the cursor (forward delete).
            if (app.input.cursor < app.input.len) {
                const seq_len = std.unicode.utf8ByteSequenceLength(app.input.buf[app.input.cursor]) catch 1;
                const end = @min(app.input.cursor + seq_len, app.input.len);
                const removed = end - app.input.cursor;
                std.mem.copyForwards(u8, app.input.buf[app.input.cursor .. app.input.len - removed], app.input.buf[end..app.input.len]);
                app.input.len -= removed;
                runDispatcher(app);
                redraw(app);
            }
        },
        xkb.XKB_KEY_Left => {
            // Move cursor one codepoint left (skip back past continuation bytes).
            if (app.input.cursor > 0) {
                var pos = app.input.cursor - 1;
                while (pos > 0 and app.input.buf[pos] & 0xC0 == 0x80) : (pos -= 1) {}
                app.input.cursor = pos;
            }
        },
        xkb.XKB_KEY_Right => {
            // Move cursor one codepoint right.
            if (app.input.cursor < app.input.len) {
                const seq_len = std.unicode.utf8ByteSequenceLength(app.input.buf[app.input.cursor]) catch 1;
                app.input.cursor = @min(app.input.cursor + seq_len, app.input.len);
            }
        },
        xkb.XKB_KEY_Up => {
            if (app.input.selected > 0) {
                app.input.selected -= 1;
                redraw(app);
            }
        },
        xkb.XKB_KEY_Down => {
            if (app.candidates.len > 0 and app.input.selected < app.candidates.len - 1) {
                app.input.selected += 1;
                redraw(app);
            }
        },
        xkb.XKB_KEY_Return => {
            if (app.candidates.len == 0) return;
            const tc = app.candidates[app.input.selected];
            switch (tc.handler.on_enter) {
                .close => app.running = false,
                .run => |exec| {
                    exec(tc.candidate.key orelse return) catch |err|
                        std.debug.print("error: {}\n", .{err});
                    app.running = false;
                },
                .show => |expand| {
                    const text = expand(std.heap.page_allocator, tc.candidate.key orelse return) catch return;
                    if (app.expanded) |old| std.heap.page_allocator.free(old);
                    app.expanded = text;
                    redraw(app);
                },
            }
        },
        else => {
            // Printable character: get UTF-8 bytes and insert at cursor.
            // xkb_state_key_get_utf8 behaves like snprintf: writes up to `size`
            // bytes (including null), returns the count without null (like snprintf).
            // Returns 0 for keys that produce no character (F-keys, modifiers, etc.)
            var char_buf: [8]u8 = undefined;
            const n_signed = xkb.xkb_state_key_get_utf8(xkb_state, xkb_key, &char_buf, char_buf.len);
            if (n_signed <= 0) return;
            const n: usize = @intCast(n_signed);

            // TODO make it configurable. For now check Ctrl+Q as "close window" 
            if (char_buf[0] == 0x11) {
                app.running = false;
                return;
            }

            // Skip control characters: Ctrl+key produces C0 codes (< 0x20), DEL = 0x7F
            if (char_buf[0] < 0x20 or char_buf[0] == 0x7F) return;

            // Guard against buffer overflow
            if (app.input.len + n > app.input.buf.len) return;

            // Shift bytes from cursor rightward to make room, then copy in new bytes.
            // copyBackwards: overlapping regions, destination is to the right of source.
            std.mem.copyBackwards(u8, app.input.buf[app.input.cursor + n .. app.input.len + n], app.input.buf[app.input.cursor..app.input.len]);
            @memcpy(app.input.buf[app.input.cursor .. app.input.cursor + n], char_buf[0..n]);
            app.input.len += n;
            app.input.cursor += n;

            // TODO improve this. This is a dictionary mode
            if (app.mode == &default_mode and
                std.mem.eql(u8, app.input.buf[0..app.input.len], "dw "))
            {
                loadMode(app, &dict_mode);
                // TODO should we handle this in loadMode too?
                app.input = .{};
            }

            runDispatcher(app);
            redraw(app);
        },
    }
}

// Called once per global the compositor advertises.
// We pick the three interfaces we need and bind them.
//
// registry.bind(): "I want to use this interface at this version"
//   → sends a bind request down the socket
//   → returns a typed proxy object we can call methods on
//
// global.interface is [*:0]const u8 (null-terminated C string).
// std.mem.span() converts it to a []const u8 slice by scanning for the null byte.
fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, app: *App) void {
    switch (event) {
        .global => |g| {
            const iface = std.mem.span(g.interface);
            if (std.mem.eql(u8, iface, "wl_compositor")) {
                app.compositor = registry.bind(g.name, wl.Compositor, 4) catch return;
            } else if (std.mem.eql(u8, iface, "wl_shm")) {
                app.shm = registry.bind(g.name, wl.Shm, 1) catch return;
            } else if (std.mem.eql(u8, iface, "zwlr_layer_shell_v1")) {
                app.layer_shell = registry.bind(g.name, zwlr.LayerShellV1, 4) catch return;
            } else if (std.mem.eql(u8, iface, "wl_seat")) {
                // wl_seat represents all input devices (keyboard, pointer, touch).
                // capabilities event fires immediately telling us what's available.
                app.seat = registry.bind(g.name, wl.Seat, 7) catch return;
                app.seat.?.setListener(*App, seatListener, app);
            } else if (std.mem.eql(u8, iface, "wl_output")) {
                // version 2 is required for the .scale event
                const out = registry.bind(g.name, wl.Output, 2) catch return;
                for (&app.outputs) |*slot| {
                    if (slot.* == null) {
                        slot.* = .{ .output = out, .scale = 1 };
                        out.setListener(*App, outputListener, app);
                        break;
                    }
                }
            }
        },
        .global_remove => {},
    }
}

// Fires once per output after binding (and again if the monitor changes)
// We find the matching slot in app.outputs and update its scale
fn outputListener(output: *wl.Output, event: wl.Output.Event, app: *App) void {
    switch (event) {
        .scale => |ev| {
            for (&app.outputs) |*slot| {
                if (slot.*) |*entry| {
                    if (entry.output == output) {
                        entry.scale = @intCast(ev.factor);
                        break;
                    }
                }
            }
        },
        else => {},
    }
}

// Fires when our surface enters or leaves an output.
// On enter we look up the output's scale and store it in app.scale.
fn surfaceListener(_: *wl.Surface, event: wl.Surface.Event, app: *App) void {
    switch (event) {
        .enter => |ev| {
            for (app.outputs) |slot| {
                if (slot) |entry| {
                    if (entry.output == ev.output) {
                        app.scale = entry.scale;
                        break;
                    }
                }
            }
        },
        else => {},
    }
}
