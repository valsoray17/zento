const std = @import("std");

const wl = @import("wayland").client.wl;
const zwlr = @import("wayland").client.zwlr;

const render = @import("render.zig");
const gfx = render.gfx; // reuse rener's cImport
const dispatcher = @import("dispatcher.zig");

const xkb = @cImport(@cInclude("xkbcommon/xkbcommon.h"));

const WIDTH = 600;
const HEIGHT = 400;

// Input state
// Text input buffer — accumulates keypresses as UTF-8 bytes.
// cursor is a byte offset into input_buf (not a codepoint index).
// A 4-byte emoji at the start means cursor_byte=4, not cursor_byte=1.
const InputState = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
};

const OutputEntry = struct { output: *wl.Output, scale: i32 };

// Application state — passed as context pointer to every Wayland listener.
// All compositor-side objects we own live here so listeners can reach them.
//
// Go analogy: a struct holding all the net.Conn, channels, and shared state
// for a long-running client — passed around instead of using globals.
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
    wl_buffer: ?*wl.Buffer = null,

    // Set to true when compositor sends its first configure event.
    // We must not attach a buffer before that — protocol violation.
    configured: bool = false,
    running: bool = true,

    input: InputState = .{},

    dispatch: ?dispatcher.DispatcherState = null,

    scale: i32 = 1,
    font: ?*gfx.struct_fcft_font = null,
    surface_image: ?*gfx.pixman_image_t = null,
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
    const physical_w: i32 = WIDTH * app.scale;
    const physical_h: i32 = HEIGHT * app.scale;
    const stride: i32 = physical_w * 4; // 4 bytes per pixel: [A][R][G][B]
    const size: usize = @intCast(stride * physical_h);

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

    app.dispatch = dispatcher.DispatcherState{ .arena = &arena };
    dispatcher.loadMode(&app.dispatch.?, &dispatcher.default_mode);
    dispatcher.run(&app.dispatch.?, app.input.buf[0..app.input.len]);
    redraw(&app);

    std.debug.print("Window open. Press Escape to close.\n", .{});
    while (app.running) {
        if (display.dispatch() != .SUCCESS) break;
    }
}

fn redraw(app: *App) void {
    const ctx = render.DrawContext{
        .surface_image = app.surface_image orelse return,
        .font = app.font orelse return,
        .scale = app.scale,
        .width = @as(i32, @intCast(WIDTH)) * app.scale,
        .height = @as(i32, @intCast(HEIGHT)) * app.scale,
    };

    const d = &(app.dispatch orelse return);
    render.redraw(ctx, render.RenderState{
        .prefix = d.mode.prefix,
        .input = app.input.buf[0..app.input.len],
        .expanded = app.expanded,
        .candidates = d.candidates,
        .selected = d.selected,
    });

    const surface = app.surface orelse return;
    const buffer = app.wl_buffer orelse return;
    // TODO again: why is this cast? Can we use the same int type expected?
    surface.setBufferScale(app.scale);
    surface.attach(buffer, 0, 0);
    surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    surface.commit();
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

    const d = &(app.dispatch orelse return);

    // Escape: raw keycode check, no xkb needed
    if (key == 1) {
        if (app.expanded != null) {
            // we are in expanded mode
            std.heap.page_allocator.free(app.expanded.?);
            app.expanded = null;
            redraw(app);
        } else if (d.mode == &dispatcher.default_mode) {
            // in default mode, close the app
            app.running = false;
        } else {
            // we are one level into another mode
            dispatcher.loadMode(d, &dispatcher.default_mode);
            app.input = .{};
            dispatcher.run(d, app.input.buf[0..app.input.len]);
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
                dispatcher.run(d, app.input.buf[0..app.input.len]);
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
                dispatcher.run(d, app.input.buf[0..app.input.len]);
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
            if (d.selected > 0) {
                d.selected -= 1;
                redraw(app);
            }
        },
        xkb.XKB_KEY_Down => {
            // TODO way too many of .?. things. Is there another option for this?
            if (d.candidates.len > 0 and d.selected < d.candidates.len - 1) {
                d.selected += 1;
                redraw(app);
            }
        },
        xkb.XKB_KEY_Return => {
            if (d.candidates.len == 0) return;
            const tc = d.candidates[d.selected];
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
            if (d.mode == &dispatcher.default_mode and
                std.mem.eql(u8, app.input.buf[0..app.input.len], "dw "))
            {
                dispatcher.loadMode(d, &dispatcher.dict_mode);
                // TODO should we handle this in loadMode too?
                app.input = .{};
            }

            dispatcher.run(d, app.input.buf[0..app.input.len]);
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
                        entry.scale = ev.factor;
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
