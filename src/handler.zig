const std = @import("std");

pub const ResultKind = enum {
    calc, // Calculator: show value, no action needed
    cmd, // systemd exec on Enter
    app, // launch app
    dict, // Dictionary: show definition
};

pub const LoadFn = *const fn (ptr: *anyopaque, std.Io) anyerror![]const Candidate;
pub const SuggestFn = *const fn (ptr: *anyopaque, std.Io, std.mem.Allocator, []const u8) std.mem.Allocator.Error![]Candidate;

pub const Source = union(enum) {
    load: LoadFn, // called once at mode switch, results are cached by dispatcher
    suggest: SuggestFn, // called every keystroke, handler pre-filters internally
};

pub const ExecuteFn = *const fn (ptr: *anyopaque, std.Io, key: []const u8) anyerror!void;
pub const ExpandFn = *const fn (ptr: *anyopaque, std.Io, std.mem.Allocator, key: []const u8) anyerror![]const u8;

pub const OnEnter = union(enum) {
    close,
    run: ExecuteFn,
    show: ExpandFn,
};

pub const Candidate = struct {
    label: []const u8, // "suspend" or "= 8"
    sublabel: ?[]const u8 = null, // "Suspend the system" or null
    aliases: []const []const u8 = &.{}, // can be "sleep" or app filename "pavucontrol"
    key: ?[]const u8 = null,
    id: ?[]const u8 = null, // stable id for history tracking; null = don't track
};

/// Handler interface — each plugin implements suggest and optionally execute
pub const Handler = struct {
    ptr: *anyopaque,
    name: []const u8,
    kind: ResultKind,
    on_enter: OnEnter,
    source: Source,
};

pub fn suggestFn(comptime T: type) SuggestFn {
    return struct {
        fn f(ptr: *anyopaque, io: std.Io, a: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]Candidate {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.suggest(io, a, input);
        }
    }.f;
}

pub fn loadFn(comptime T: type) LoadFn {
    return struct {
        fn f(ptr: *anyopaque, io: std.Io) anyerror![]const Candidate {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.load(io);
        }
    }.f;
}

pub fn executeFn(comptime T: type) ExecuteFn {
    return struct {
        fn f(ptr: *anyopaque, io: std.Io, key: []const u8) anyerror!void {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.execute(io, key);
        }
    }.f;
}

pub fn expandFn(comptime T: type) ExpandFn {
    return struct {
        fn f(ptr: *anyopaque, io: std.Io, a: std.mem.Allocator, key: []const u8) anyerror![]const u8 {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.expand(io, a, key);
        }
    }.f;
}
