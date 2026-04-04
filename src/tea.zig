/// Core Program and Model interface — the Elm architecture for terminals.
const std = @import("std");
const msg_mod = @import("msg.zig");
const cmd_mod = @import("cmd.zig");
const terminal = @import("terminal.zig");
const input_mod = @import("input.zig");
const renderer_mod = @import("renderer.zig");

pub const Msg = msg_mod.Msg;
pub const Cmd = cmd_mod.Cmd;

// ---------------------------------------------------------------------------
// Model interface (vtable-based dynamic dispatch)
// ---------------------------------------------------------------------------

pub const Model = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Called once at startup. Return an initial Cmd or null.
        init: *const fn (ctx: *anyopaque) ?Cmd,
        /// Called for every Msg. Mutates internal state in-place. Return a Cmd or null.
        update: *const fn (ctx: *anyopaque, m: Msg) ?Cmd,
        /// Render the current state as a UTF-8 string written to `writer`.
        view: *const fn (ctx: *anyopaque, writer: std.io.AnyWriter) anyerror!void,
    };

    pub fn init(self: Model) ?Cmd {
        return self.vtable.init(self.ptr);
    }

    pub fn update(self: Model, m: Msg) ?Cmd {
        return self.vtable.update(self.ptr, m);
    }

    pub fn view(self: Model, writer: std.io.AnyWriter) !void {
        return self.vtable.view(self.ptr, writer);
    }
};

/// Convenience: create a Model interface from any pointer whose type
/// implements `init`, `update`, and `view` with the right signatures.
///
/// Expected signatures on T:
///   pub fn init(self: *T) ?tea.Cmd
///   pub fn update(self: *T, m: tea.Msg) ?tea.Cmd
///   pub fn view(self: *T, writer: std.io.AnyWriter) anyerror!void
pub fn model(ptr: anytype) Model {
    const T = @TypeOf(ptr.*);
    const gen = struct {
        fn initFn(ctx: *anyopaque) ?Cmd {
            const self: *T = @ptrCast(@alignCast(ctx));
            return self.init();
        }
        fn updateFn(ctx: *anyopaque, m: Msg) ?Cmd {
            const self: *T = @ptrCast(@alignCast(ctx));
            return self.update(m);
        }
        fn viewFn(ctx: *anyopaque, writer: std.io.AnyWriter) anyerror!void {
            const self: *T = @ptrCast(@alignCast(ctx));
            return self.view(writer);
        }
    };
    return .{
        .ptr = ptr,
        .vtable = &.{
            .init = gen.initFn,
            .update = gen.updateFn,
            .view = gen.viewFn,
        },
    };
}

// ---------------------------------------------------------------------------
// Message queue
// ---------------------------------------------------------------------------

const MsgQueue = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    items: std.ArrayList(Msg) = .empty,
    closed: bool = false,

    fn deinit(self: *MsgQueue, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    fn push(self: *MsgQueue, m: Msg, allocator: std.mem.Allocator) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(allocator, m);
        self.cond.signal();
    }

    /// Block until a message is available, then return it.
    fn pop(self: *MsgQueue) ?Msg {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.items.items.len == 0) {
            if (self.closed) return null;
            self.cond.wait(&self.mutex);
        }
        return self.items.orderedRemove(0);
    }

    fn close(self: *MsgQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.cond.broadcast();
    }
};

// ---------------------------------------------------------------------------
// Program
// ---------------------------------------------------------------------------

pub const Program = struct {
    m: Model,
    allocator: std.mem.Allocator,
    queue: MsgQueue,
    renderer: renderer_mod.Renderer,
    running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, m: Model) Program {
        return .{
            .m = m,
            .allocator = allocator,
            .queue = .{},
            .renderer = renderer_mod.Renderer.init(allocator),
            .running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn deinit(self: *Program) void {
        self.queue.deinit(self.allocator);
        self.renderer.deinit();
    }

    /// Run the event loop. Blocks until the model returns a quit/interrupt Cmd.
    pub fn run(self: *Program) !void {
        // Initialise raw terminal mode
        const term = try terminal.TerminalState.init();
        defer term.deinit();

        // Render initial view
        try self.renderView();

        // Dispatch initial Cmd from model.init()
        if (self.m.init()) |initial_cmd| {
            try self.execCmd(initial_cmd, self.allocator);
        }

        // Start input reader thread (detached — exits when process does)
        const input_thread = try std.Thread.spawn(.{}, inputLoop, .{self});
        input_thread.detach();

        // Main event loop
        while (true) {
            const m = self.queue.pop() orelse break;

            switch (m) {
                .quit, .interrupt => break,
                else => {},
            }

            const maybe_cmd = self.m.update(m);
            try self.renderView();

            if (maybe_cmd) |c| {
                try self.execCmd(c, self.allocator);
            }
        }

        self.running.store(false, .release);
        self.queue.close();
        self.renderer.clear();
    }

    // ---- Private helpers ----

    fn renderView(self: *Program) !void {
        var view_buf: [65536]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&view_buf);
        try self.m.view(fbs.writer().any());
        self.renderer.render(fbs.getWritten());
    }

    fn execCmd(self: *Program, c: Cmd, allocator: std.mem.Allocator) !void {
        if (c) |fn_ptr| {
            const result = fn_ptr();
            try self.queue.push(result, allocator);
        }
    }
};

// ---------------------------------------------------------------------------
// Input reader (runs in its own thread)
// ---------------------------------------------------------------------------

fn inputLoop(prog: *Program) void {
    const stdin = std.fs.File.stdin();
    var buf: [256]u8 = undefined;
    var msgs: std.ArrayList(Msg) = .empty;
    defer msgs.deinit(prog.allocator);

    while (prog.running.load(.acquire)) {
        // Poll with 100 ms timeout so the thread can notice `running = false`
        if (!input_mod.pollStdin(100)) continue;

        const n = stdin.read(&buf) catch return;
        if (n == 0) continue;

        msgs.clearRetainingCapacity();
        input_mod.parseAll(buf[0..n], &msgs, prog.allocator) catch continue;

        for (msgs.items) |m| {
            prog.queue.push(m, prog.allocator) catch return;
        }
    }
}
