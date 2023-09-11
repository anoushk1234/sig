const std = @import("std");
const entry = @import("entry.zig");
const Level = @import("level.zig").Level;
const logfmt = @import("logfmt.zig");
const Entry = entry.Entry;
const testing = std.testing;
const Mutex = std.Thread.Mutex;
const AtomicBool = std.atomic.Atomic(bool);
const Channel = @import("../sync/channel.zig").Channel;

const INITIAL_ENTRIES_CHANNEL_SIZE: usize = 1024;

pub const Logger = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    default_level: Level,
    exit_sig: AtomicBool,
    handle: ?std.Thread,
    channel: *Channel(*Entry),
    sink: Sink,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, default_level: Level, maybe_sink: ?Sink) *Self {
        var self = allocator.create(Self) catch @panic("could not allocator.create Logger");
        var arena = std.heap.ArenaAllocator.init(allocator);

        var sink = blk: {
            if (maybe_sink) |sink| {
                break :blk sink;
            } else {
                var sink = StdErrSink{};
                break :blk sink.sink();
            }
        };

        self.* = .{
            .allocator = allocator,
            .arena = arena,
            .default_level = default_level,
            .exit_sig = AtomicBool.init(false),
            .handle = null,
            .channel = Channel(*Entry).init(allocator, INITIAL_ENTRIES_CHANNEL_SIZE),
            .sink = sink,
        };
        return self;
    }

    pub fn spawn(self: *Self) void {
        self.handle = std.Thread.spawn(.{}, Logger.run, .{self}) catch @panic("could not spawn Logger");
    }

    pub fn deinit(self: *Self) void {
        self.channel.close();
        if (self.handle) |handle| {
            self.exit_sig.store(true, .SeqCst);
            handle.join();
        }
        self.channel.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn run(self: *Self) void {
        while (!self.exit_sig.load(.SeqCst)) {
            std.time.sleep(std.time.ns_per_ms * 5);

            var entries = self.channel.drain() orelse {
                // channel is closed
                return;
            };
            defer self.channel.allocator.free(entries);

            self.sink.consumeEntries(entries);

            // deinit entries
            for (entries) |e| {
                e.deinit();
            }
        }
    }

    pub fn field(self: *Self, name: []const u8, value: anytype) *Entry {
        return Entry.init(self.arena.allocator(), self.channel).field(name, value);
    }

    pub fn info(self: *Self, comptime msg: []const u8) void {
        Entry.init(self.arena.allocator(), self.channel).infof(msg, .{});
    }

    pub fn debug(self: *Self, comptime msg: []const u8) void {
        Entry.init(self.arena.allocator(), self.channel).debugf(msg, .{});
    }

    pub fn warn(self: *Self, comptime msg: []const u8) void {
        Entry.init(self.arena.allocator(), self.channel).warn(msg, .{});
    }

    pub fn err(self: *Self, comptime msg: []const u8) void {
        Entry.init(self.arena.allocator(), self.channel).err(msg, .{});
    }

    pub fn infof(self: *Self, comptime fmt: []const u8, args: anytype) void {
        Entry.init(self.arena.allocator(), self.channel).infof(fmt, args);
    }

    pub fn debugf(self: *Self, comptime fmt: []const u8, args: anytype) void {
        Entry.init(self.arena.allocator(), self.channel).debugf(fmt, args);
    }

    pub fn warnf(self: *Self, comptime fmt: []const u8, args: anytype) void {
        Entry.init(self.arena.allocator(), self.channel).warnf(fmt, args);
    }

    pub fn errf(self: *Self, comptime fmt: []const u8, args: anytype) void {
        Entry.init(self.arena.allocator(), self.channel).errf(fmt, args);
    }
};

const Sink = struct {
    ptr: *anyopaque,
    impl: *const Impl,

    const Self = @This();

    const Impl = struct {
        consumeEntries: *const fn (ctx: *anyopaque, entries: []*Entry) void,
    };

    pub fn consumeEntries(self: *Self, entries: []*Entry) void {
        self.impl.consumeEntries(self.ptr, entries);
    }
};

pub const StdErrSink = struct {
    const Self = @This();

    pub fn consumeEntries(_: *anyopaque, entries: []*Entry) void {
        var std_err_writer = std.io.getStdErr().writer();
        var std_err_mux = std.debug.getStderrMutex();
        std_err_mux.lock();
        defer std_err_mux.unlock();

        for (entries) |e| {
            logfmt.formatter(e, std_err_writer) catch unreachable;
        }
    }

    pub fn sink(self: *Self) Sink {
        return Sink{
            .ptr = self,
            .impl = &.{
                .consumeEntries = consumeEntries,
            },
        };
    }
};

pub const DoNothingSink = struct {
    const Self = @This();

    pub fn consumeEntries(_: *anyopaque, entries: []*Entry) void {
        _ = entries;
    }

    pub fn sink(self: *Self) Sink {
        return Sink{
            .ptr = self,
            .impl = &.{
                .consumeEntries = consumeEntries,
            },
        };
    }
};

test "trace.logger: works" {
    var logger = Logger.init(testing.allocator, .info, null);
    logger.spawn();
    defer logger.deinit();

    logger.field("elapsed", 4245).debugf("request with id {s} succeeded", .{"abcd1234"});

    logger.field("kind", .some_enum_kind).infof("operation was done", .{});
    logger.field("authorized", false).warnf("api call received at {d} not authorized", .{10004});
    logger.field("error", "IOError").errf("api call received at {d} broke the system!", .{10005});

    std.time.sleep(std.time.ns_per_ms * 100);

    logger.field("elapsed", 4245).debug("request with id succeeded");
    logger.field("kind", .some_enum_kind).info("operation was done");
    logger.field("authorized", false).warn("api call received at not authorized");
    logger.field("error", "IOError").err("api call received broke the system!");

    const s: []const u8 = "t12312";
    logger
        .field("tmp1", 123)
        .field("tmp2", 456)
        .field("tmp2", s)
        .info("new push message");

    std.time.sleep(std.time.ns_per_ms * 100);

    std.debug.print("--- \n", .{});
    var sink = DoNothingSink{};
    var logger_null = Logger.init(testing.allocator, .info, sink.sink());
    logger_null.spawn();
    defer logger_null.deinit();

    logger_null.field("elapsed", 4245).debug("request with id succeeded");
    std.time.sleep(std.time.ns_per_ms * 100);
}
