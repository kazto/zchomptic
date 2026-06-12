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
        view: *const fn (ctx: *anyopaque, writer: *std.Io.Writer) anyerror!void,
    };

    pub fn init(self: Model) ?Cmd {
        return self.vtable.init(self.ptr);
    }

    pub fn update(self: Model, m: Msg) ?Cmd {
        return self.vtable.update(self.ptr, m);
    }

    pub fn view(self: Model, writer: *std.Io.Writer) !void {
        return self.vtable.view(self.ptr, writer);
    }
};

/// Convenience: create a Model interface from any pointer whose type
/// implements `init`, `update`, and `view` with the right signatures.
///
/// Expected signatures on T:
///   pub fn init(self: *T) ?tea.Cmd
///   pub fn update(self: *T, m: tea.Msg) ?tea.Cmd
///   pub fn view(self: *T, writer: *std.Io.Writer) anyerror!void
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
        fn viewFn(ctx: *anyopaque, writer: *std.Io.Writer) anyerror!void {
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
    locked: std.atomic.Value(bool) = .init(false),
    items: std.ArrayList(Msg) = .empty,
    closed: bool = false,

    fn lock(self: *MsgQueue) void {
        while (self.locked.swap(true, .acquire)) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *MsgQueue) void {
        self.locked.store(false, .release);
    }

    fn deinit(self: *MsgQueue, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    fn push(self: *MsgQueue, m: Msg, allocator: std.mem.Allocator) !void {
        self.lock();
        defer self.unlock();
        try self.items.append(allocator, m);
    }

    /// Block until a message is available, then return it.
    fn pop(self: *MsgQueue) ?Msg {
        while (true) {
            self.lock();
            if (self.items.items.len > 0) {
                const msg = self.items.orderedRemove(0);
                self.unlock();
                return msg;
            }
            if (self.closed) {
                self.unlock();
                return null;
            }
            self.unlock();
            std.Thread.yield() catch {};
        }
    }

    fn close(self: *MsgQueue) void {
        self.lock();
        defer self.unlock();
        self.closed = true;
    }
};

// ---------------------------------------------------------------------------
// Program
// ---------------------------------------------------------------------------

pub const Program = struct {
    m: Model,
    allocator: std.mem.Allocator,
    io: std.Io,
    queue: MsgQueue,
    renderer: renderer_mod.Renderer,
    running: std.atomic.Value(bool),
    view_buf: std.Io.Writer.Allocating,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, m: Model) Program {
        return .{
            .m = m,
            .allocator = allocator,
            .io = io,
            .queue = .{},
            .renderer = renderer_mod.Renderer.init(io, allocator),
            .running = std.atomic.Value(bool).init(true),
            .view_buf = .init(allocator),
        };
    }

    pub fn deinit(self: *Program) void {
        self.queue.deinit(self.allocator);
        self.renderer.deinit();
        self.view_buf.deinit();
    }

    /// Run the event loop. Blocks until the model returns a quit/interrupt Cmd.
    pub fn run(self: *Program) !void {
        // Initialise raw terminal mode
        const term = try terminal.TerminalState.init(self.io);
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
        self.view_buf.writer.end = 0;
        try self.m.view(&self.view_buf.writer);
        self.renderer.render(self.view_buf.writer.buffered());
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
    var buf: [256]u8 = undefined;
    var msgs: std.ArrayList(Msg) = .empty;
    defer msgs.deinit(prog.allocator);

    while (prog.running.load(.acquire)) {
        // Poll with 100 ms timeout so the thread can notice `running = false`
        if (!input_mod.pollStdin(100)) continue;

        const n = input_mod.readStdin(&buf);
        if (n == 0) continue;

        msgs.clearRetainingCapacity();
        input_mod.parseAll(buf[0..n], &msgs, prog.allocator) catch continue;

        for (msgs.items) |m| {
            prog.queue.push(m, prog.allocator) catch return;
        }
    }
}
