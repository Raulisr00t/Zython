//! Isolated-heap-per-worker threads + message passing -- the actual
//! multithreading differentiator this project was built around (see the
//! plan doc for why this design over a GIL or CPython's real no-GIL
//! fine-grained locking).
//!
//! Each worker is a real OS thread with its own arena: no shared mutable
//! object graph, so there's nothing to lock on ordinary Values. The only
//! genuinely shared mutable state anywhere in the VM is stdout (see
//! vm.zig's out_mutex) and each worker's own Mailbox queue (guarded by its
//! own Io.Mutex/Io.Condition below) -- nothing else needs synchronization
//! because nothing else is shared.

const std = @import("std");
const Io = std.Io;
const bytecode = @import("bytecode.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Message = value_mod.Message;
const vm_mod = @import("vm.zig");

pub const Mailbox = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    queue: std.ArrayList(Message) = .empty,

    pub fn send(self: *Mailbox, io: Io, msg: Message) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.queue.append(std.heap.smp_allocator, msg);
        self.cond.signal(io);
    }

    /// Blocks until a message is available.
    pub fn recv(self: *Mailbox, io: Io) !Message {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        while (self.queue.items.len == 0) {
            try self.cond.wait(io, &self.mutex);
        }
        return self.queue.orderedRemove(0);
    }
};

pub const Worker = struct {
    id: usize,
    thread: std.Thread,
    mailbox: *Mailbox,
    result_message: ?Message = null,
    err_diag: ?[]const u8 = null,
};

var next_worker_id = std.atomic.Value(usize).init(1); // 0 is reserved for the main/module worker

/// Everything a spawned OS thread needs to bootstrap its own isolated VM.
/// Allocated via smp_allocator (independent of any single worker's arena)
/// and freed by threadMain once it's done reading from it.
const SpawnArgs = struct {
    worker: *Worker,
    code: *const bytecode.CodeObject,
    call_args: []Message,
    out: *Io.Writer,
    out_mutex: *Io.Mutex,
    io: Io,
    verbose: bool,
};

fn threadMain(spawn_args: *SpawnArgs) void {
    defer std.heap.smp_allocator.destroy(spawn_args);
    const worker = spawn_args.worker;

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var vm = vm_mod.VM.init(alloc, spawn_args.out, spawn_args.out_mutex, spawn_args.io, worker.mailbox) catch |err| {
        worker.err_diag = @errorName(err);
        std.heap.smp_allocator.free(spawn_args.call_args);
        return;
    };
    vm.worker_id = worker.id;
    vm.verbose = spawn_args.verbose;

    const call_values = alloc.alloc(Value, spawn_args.call_args.len) catch |err| {
        worker.err_diag = @errorName(err);
        std.heap.smp_allocator.free(spawn_args.call_args);
        return;
    };
    for (spawn_args.call_args, 0..) |m, i| {
        call_values[i] = value_mod.messageToValue(alloc, m) catch |err| {
            worker.err_diag = @errorName(err);
            std.heap.smp_allocator.free(spawn_args.call_args);
            return;
        };
    }
    std.heap.smp_allocator.free(spawn_args.call_args);

    var func = bytecode.PyFunction{ .code = spawn_args.code };
    const result = vm.callFunctionPublic(&func, call_values) catch |err| {
        worker.err_diag = @errorName(err);
        return;
    };
    worker.result_message = value_mod.valueToMessage(result) catch null;
}

pub const SpawnError = error{ NotSendableArg, NotAFunction };

/// Starts a new OS thread running `func(args...)` against a brand new,
/// fully isolated VM (its own arena, its own globals, its own mailbox).
/// `args` are deep-copied (see value_mod.valueToMessage) before the thread
/// starts, so the new worker never touches the spawning worker's arena.
pub fn spawn(
    func: *bytecode.PyFunction,
    args: []const Value,
    out: *Io.Writer,
    out_mutex: *Io.Mutex,
    io: Io,
    verbose: bool,
) !*Worker {
    const call_args = try std.heap.smp_allocator.alloc(Message, args.len);
    errdefer std.heap.smp_allocator.free(call_args);
    for (args, 0..) |a, i| {
        call_args[i] = value_mod.valueToMessage(a) catch return SpawnError.NotSendableArg;
    }

    const worker = try std.heap.smp_allocator.create(Worker);
    errdefer std.heap.smp_allocator.destroy(worker);
    const mailbox = try std.heap.smp_allocator.create(Mailbox);
    mailbox.* = .{};
    worker.* = .{ .id = next_worker_id.fetchAdd(1, .monotonic), .mailbox = mailbox, .thread = undefined };

    const spawn_args = try std.heap.smp_allocator.create(SpawnArgs);
    spawn_args.* = .{
        .worker = worker,
        .code = func.code,
        .call_args = call_args,
        .out = out,
        .out_mutex = out_mutex,
        .io = io,
        .verbose = verbose,
    };

    worker.thread = try std.Thread.spawn(.{}, threadMain, .{spawn_args});
    return worker;
}

pub const JoinError = error{WorkerFailed};

/// Blocks until the worker's thread finishes, then returns its return
/// value copied into `allocator` (typically the joining worker's arena).
pub fn join(allocator: std.mem.Allocator, worker: *Worker) !Value {
    worker.thread.join();
    if (worker.err_diag != null) return JoinError.WorkerFailed;
    const msg = worker.result_message orelse return .{ .none = {} };
    return value_mod.messageToValue(allocator, msg);
}
