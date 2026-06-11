const std = @import("std");

const handler = @import("handler.zig");
const calc = @import("calc.zig");
const convert = @import("convert.zig");
const dict = @import("dict.zig");
const systemd = @import("systemd.zig");
const apps = @import("apps.zig");

const fuzzy = @import("fuzzy.zig");
const history = @import("history.zig");

pub const TaggedCandidate = struct {
    candidate: handler.Candidate,
    handler: handler.Handler,
};

// Modes
const Mode = struct {
    prefix: []const u8,
    handlers: []const handler.Handler,
};

pub const Modes = struct {
    default: Mode,
    dict: Mode,
};

pub const ModeId = enum { default, dict };

fn make(gpa: std.mem.Allocator, value: anytype) !handler.Handler {
    const ptr = try gpa.create(@TypeOf(value));
    ptr.* = value;
    return ptr.handler();
}

fn build(gpa: std.mem.Allocator, home: ?[]const u8, data_dirs: ?[]const u8) !*const Modes {
    const calc_h = try make(gpa, calc.Calc{});
    const convert_h = try make(gpa, convert.Convert{});
    const systemd_h = try make(gpa, systemd.Systemd{});
    const apps_h = try make(gpa, apps.Apps.init(home, data_dirs));
    const dict_h = try make(gpa, dict.Dict.init(home));

    const modes = try gpa.create(Modes);
    modes.* = .{
        .default = .{
            .prefix = "> ",
            .handlers = try gpa.dupe(handler.Handler, &.{ calc_h, convert_h, systemd_h, apps_h }),
        },
        .dict = .{
            .prefix = "[dict] ",
            // potentially can merge multiple dictionaries in the future
            .handlers = try gpa.dupe(handler.Handler, &.{dict_h}),
        },
    };
    return modes;
}

pub const DispatcherState = struct {
    suggest_arena: *std.heap.ArenaAllocator,

    // Both point into stable (arena) storage, so they survive this struct being
    // copied into app.dispatch. `modes` is the whole set (needed to switch),
    // `mode` is the current one.
    modes: *const Modes,
    mode: *const Mode = undefined,
    static_candidates: []TaggedCandidate = &.{},
    candidates: []TaggedCandidate = &.{},

    // Build the modes, construct the state, and load the default mode.
    // Safe to return by value: every field points at external/stable storage.
    pub fn init(
        gpa: std.mem.Allocator,
        suggest_arena: *std.heap.ArenaAllocator,
        io: std.Io,
        home: ?[]const u8,
        data_dirs: ?[]const u8,
    ) !DispatcherState {
        var state = DispatcherState{
            .suggest_arena = suggest_arena,
            .modes = try build(gpa, home, data_dirs),
        };
        loadMode(&state, io, .default);
        return state;
    }

    pub fn deinit(self: *DispatcherState) void {
        self.suggest_arena.deinit();
    }
};

// TODO consider moving run and loadMode to the dispatcher state struct as methods
// Collect candidates from all handlers for the current input.
// Resets the arena first — previous candidates are invalidated.
// Called after every input change (insert, backspace, delete).
pub fn run(state: *DispatcherState, io: std.Io, input: []const u8) void {
    const arena = state.suggest_arena;
    // frees all allocations locally but keeps the backing memory pages mapped
    _ = arena.reset(.retain_capacity);
    const alloc = arena.allocator();

    // Collect candidates
    var all: std.ArrayListUnmanaged(TaggedCandidate) = .empty;
    // static hadlers
    all.appendSlice(alloc, state.static_candidates) catch {};
    // dynamic handlers
    for (state.mode.handlers) |h| {
        if (input.len == 0) break;
        switch (h.source) {
            .suggest => |f| for (f(h.ptr, io, alloc, input) catch continue) |cand|
                all.append(alloc, .{ .candidate = cand, .handler = h }) catch continue,
            .load => {},
        }
    }

    // Score
    const Ranked = struct { tagged: TaggedCandidate, score: f32 };
    var ranked: std.ArrayListUnmanaged(Ranked) = .empty;
    for (all.items) |tc| {
        var s: f32 = if (tc.handler.kind == .calc) 1.0 else fuzzy.score(input, tc.candidate.label);
        for (tc.candidate.aliases) |alias| s = @max(s, fuzzy.score(input, alias));
        if (tc.candidate.id) |id| {
            var key_buf: [256]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ tc.handler.name, id }) catch continue;
            const freq = history.getFrequency(key);
            s += std.math.log2(@as(f32, @floatFromInt(freq + 1)));
        }
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
    const top = ranked.items;
    const out = alloc.alloc(TaggedCandidate, top.len) catch {
        state.candidates = &.{};
        return;
    };
    for (top, 0..) |r, i| out[i] = r.tagged;
    state.candidates = out;
}

pub fn loadMode(state: *DispatcherState, io: std.Io, id: ModeId) void {
    std.heap.page_allocator.free(state.static_candidates);
    state.mode = switch (id) {
        .default => &state.modes.default,
        .dict => &state.modes.dict,
    };

    var candidates: std.ArrayListUnmanaged(TaggedCandidate) = .empty;
    for (state.mode.handlers) |h| {
        switch (h.source) {
            .load => |f| {
                const loaded = f(h.ptr, io) catch continue;
                for (loaded) |cand|
                    candidates.append(std.heap.page_allocator, .{ .candidate = cand, .handler = h }) catch continue;
            },
            .suggest => {},
        }
    }

    state.static_candidates = candidates.toOwnedSlice(std.heap.page_allocator) catch &.{};
}
