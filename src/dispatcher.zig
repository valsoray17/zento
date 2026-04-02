const std = @import("std");

const handler = @import("handler.zig");
const calc = @import("calc.zig");
const convert = @import("convert.zig");
const dict = @import("dict.zig");
const systemd = @import("systemd.zig");
const apps = @import("apps.zig");

const fuzzy = @import("fuzzy.zig");

pub const TaggedCandidate = struct {
    candidate: handler.Candidate,
    handler: *const handler.Handler,
};

// Modes
const Mode = struct {
    prefix: []const u8,
    handlers: []const *const handler.Handler,
};

pub const default_mode = Mode{
    .prefix = "> ",
    .handlers = &.{ &calc.handler, &convert.handler, &systemd.handler, &apps.handler },
};

pub const dict_mode = Mode{
    .prefix = "[dict] ",
    // potentially can merge multiple dictionaries in the future
    .handlers = &.{&dict.handler},
};

pub const DispatcherState = struct {
    arena: *std.heap.ArenaAllocator,
    mode: *const Mode = &default_mode,
    static_candidates: []TaggedCandidate = &.{},
    candidates: []TaggedCandidate = &.{},
    selected: usize = 0,
};

// TODO consider moving run and loadMode to the dispatcher state struct as methods
// Collect candidates from all handlers for the current input.
// Resets the arena first — previous candidates are invalidated.
// Called after every input change (insert, backspace, delete).
pub fn run(state: *DispatcherState, input: []const u8) void {
    const arena = state.arena;
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
        state.candidates = &.{};
        return;
    };
    for (top, 0..) |r, i| out[i] = r.tagged;
    state.candidates = out;

    if (state.candidates.len == 0) {
        state.selected = 0;
    } else if (state.selected >= state.candidates.len) {
        state.selected = state.candidates.len - 1;
    }
}

pub fn loadMode(state: *DispatcherState, mode: *const Mode) void {
    std.heap.page_allocator.free(state.static_candidates);
    state.mode = mode;

    var candidates: std.ArrayListUnmanaged(TaggedCandidate) = .empty;
    for (state.mode.handlers) |h| {
        switch (h.source) {
            .load => |f| for (f(std.heap.page_allocator) catch continue) |cand|
                candidates.append(std.heap.page_allocator, .{ .candidate = cand, .handler = h }) catch continue,
            .suggest => {},
        }
    }

    state.static_candidates = candidates.toOwnedSlice(std.heap.page_allocator) catch &.{};
}
