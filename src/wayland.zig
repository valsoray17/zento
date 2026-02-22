const std = @import("std");
const wl = @import("wayland").client.wl;
const zwlr = @import("wayland").client.zwlr;
const c = @cImport(@cInclude("pixman-1/pixman.h"));

// Application state — passed as context pointer to every Wayland listener.
// All compositor-side objects we own live here so listeners can reach them.
//
// Go analogy: a struct holding all the net.Conn, channels, and shared state
// for a long-running client — passed around instead of using globals.
const WIDTH: u32 = 600;
const HEIGHT: u32 = 400;

const App = struct {
    // Globals: one per interface the compositor advertises in the registry.
    // We bind each one during the first roundtrip.
    // Optional because we don't have them until the registry listener fires.
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,

    // Our objects, created after globals are bound.
    layer_surface: ?*zwlr.LayerSurfaceV1 = null,

    // Set to true when compositor sends its first configure event.
    // We must not attach a buffer before that — protocol violation.
    configured: bool = false,
    running: bool = true,
};

pub fn run() !void {
    var app = App{};

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

    // TODO: switch back to .exclusive when keyboard handling is implemented (step 4).
    // .none for now so Ctrl+C from the terminal still works during development.
    layer_surface.setKeyboardInteractivity(.none);

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

    // --- Phase 3: shared memory buffer ---
    //
    // wl_shm is Wayland's software rendering path — no GPU required.
    //
    // The trick: both us and the compositor mmap the same file descriptor.
    // We write pixels → compositor reads them. Zero copies across the socket —
    // only the fd number travels over the wire, not the pixel data itself.
    //
    // memfd_create: anonymous RAM-backed file (Linux-specific).
    //   Better than shm_open: no name, no /dev/shm file to clean up on crash.
    //   Lives in RAM, behaves like a regular file (ftruncate, mmap, etc).
    const stride: u32 = WIDTH * 4; // 4 bytes per pixel: [A][R][G][B]
    const size: usize = stride * HEIGHT;

    const fd = try std.posix.memfd_create("launcher-shm", 0);
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
    const buffer = try pool.createBuffer(0, @intCast(WIDTH), @intCast(HEIGHT), @intCast(stride), .argb8888);
    defer buffer.destroy();

    // --- Phase 4: draw and commit ---
    //
    // pixman wraps our raw pixel data as a pixman_image_t — just a view,
    // no copy. We fill it with a solid color, then it's ready to send.
    fillSolid(data, @intCast(WIDTH), @intCast(HEIGHT), @intCast(stride));

    // Attach buffer: "this is the pixel data for this surface"
    surface.attach(buffer, 0, 0);

    // damage tells the compositor which region changed and needs repainting.
    // maxInt = "the whole surface changed" — required or compositor may skip it.
    surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));

    // commit: compositor atomically swaps our buffer in at next vblank. Window appears.
    surface.commit();

    // --- Phase 5: event loop ---
    //
    // dispatch() blocks until the compositor sends something (key press, close, etc),
    // then processes all pending events and calls registered listeners.
    //
    //   socket readable → dispatch() → listeners fire → (render) → repeat
    //
    // For now the loop body is empty — we just keep the window alive.
    // Keyboard handling comes in the next step.
    std.debug.print("Window open.\n", .{});
    while (app.running) {
        if (display.dispatch() != .SUCCESS) break;
    }
}

// Fill the entire pixel buffer with a solid dark color.
//
// pixman_image_create_bits: wraps raw memory as a pixman image — no copy,
// pixman just holds a pointer to our mmap'd buffer.
//
// pixman colors are 16-bit per channel (0x0000–0xffff), not 8-bit.
// 0x1818 ≈ 9% brightness — dark background.
fn fillSolid(data: []u8, width: i32, height: i32, stride: i32) void {
    const image = c.pixman_image_create_bits(
        c.PIXMAN_a8r8g8b8,
        width,
        height,
        @ptrCast(@alignCast(data.ptr)),
        stride,
    ) orelse return;
    defer _ = c.pixman_image_unref(image);

    var color = c.pixman_color_t{
        .red = 0x1818,
        .green = 0x1818,
        .blue = 0x2828,
        .alpha = 0xffff,
    };
    var rect = c.pixman_rectangle16_t{
        .x = 0,
        .y = 0,
        .width = @intCast(width),
        .height = @intCast(height),
    };

    // OP_SRC: copy source directly, ignoring destination (plain overwrite).
    // OP_OVER would alpha-blend over whatever was there before.
    _ = c.pixman_image_fill_rectangles(c.PIXMAN_OP_SRC, image, &color, 1, &rect);
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
            }
        },
        .global_remove => {},
    }
}
