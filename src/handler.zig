const std = @import("std");

pub const ResultKind = enum {
    calc, // Calculator: show value, no action needed
    cmd, // systemd exec on Enter
    app, // launch app
    dict, // Dictionary: show definition
};

pub const LoadFn = *const fn (std.mem.Allocator) std.mem.Allocator.Error![]Candidate;
pub const SuggestFn = *const fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error![]Candidate;

pub const Source = union(enum){
    load: LoadFn, // called once at mode switch, results are cached by dispatcher
    suggest: SuggestFn, // called every keystroke, handler pre-filters internally
};

pub const ExecuteFn = *const fn (key: []const u8) anyerror!void;
pub const ExpandFn = *const fn (std.mem.Allocator, key: []const u8) anyerror![]const u8;

pub const OnEnter = union(enum) {
    close,
    run: ExecuteFn,
    show: ExpandFn,
};

pub const Candidate = struct {
    label: []const u8,            // "suspend" or "= 8"
    sublabel: ?[]const u8 = null, // "Suspend the system" or null
    key: ?[]const u8 = null,
    id: ?[]const u8 = null,       // stable id for history tracking; null = don't track
};

/// Handler interface — each plugin implements suggest and optionally execute
pub const Handler = struct {
    name: []const u8,
    kind: ResultKind,
    on_enter: OnEnter,
    source: Source,
};
