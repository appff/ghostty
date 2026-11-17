//! A frozen primary-screen history suffix, read in small newest-first batches.
//! Owns its pages independently of the live surface, so slow transfer never
//! holds the renderer mutex or follows the Host's viewport.
const PeerTerminalHistory = @This();
const std = @import("std");
const terminal = @import("../terminal/main.zig");

pages: terminal.PageList,
rows: usize,

pub fn capture(alloc: std.mem.Allocator, t: *const terminal.Terminal, maximum_rows: usize) !?*PeerTerminalHistory {
    const source = &t.screens.get(.primary).?.pages;
    const history_rows = source.total_rows - source.rows;
    // Bound native cell storage as well as rows before cloning. This preserves
    // up to 20k rows at ordinary widths without allocating a million-row log.
    const rows = @min(history_rows, maximum_rows, 20_000, 2 * 1024 * 1024 / @max(1, @as(usize, source.cols)));
    if (rows == 0) return null;
    const result = try alloc.create(PeerTerminalHistory);
    errdefer alloc.destroy(result);
    result.* = .{
        .pages = try source.clone(alloc, .{
            .top = .{ .screen = .{ .y = @intCast(history_rows - rows) } },
            .bot = .{ .screen = .{ .y = @intCast(history_rows - 1) } },
        }),
        .rows = rows,
    };
    return result;
}

pub fn destroy(self: *PeerTerminalHistory, alloc: std.mem.Allocator) void {
    self.pages.deinit();
    alloc.destroy(self);
}

pub const Batch = struct { bytes: []const u8, rows: usize };

pub fn read(self: *PeerTerminalHistory, offset: usize, buffer: []u8) !Batch {
    if (offset >= self.rows) return .{ .bytes = buffer[0..0], .rows = 0 };
    const bottom = self.rows - offset - 1;
    var count = @min(128, bottom + 1);
    while (true) {
        var formatter: terminal.formatter.PageListFormatter = .init(&self.pages, .{
            .emit = .vt,
            .trim = false,
            .unwrap = false,
        });
        formatter.top_left = self.pages.pin(.{ .screen = .{ .y = @intCast(bottom + 1 - count) } }).?;
        var end = self.pages.pin(.{ .screen = .{ .y = @intCast(bottom) } }).?;
        end.x = end.node.cols() - 1;
        formatter.bottom_right = end;
        var writer: std.Io.Writer = .fixed(buffer);
        formatter.format(&writer) catch |err| switch (err) {
            error.WriteFailed => {
                if (count == 1) return err;
                count = @max(1, count / 2);
                continue;
            },
            else => return err,
        };
        return .{ .bytes = writer.buffered(), .rows = count };
    }
}

test "peer frozen history is newest first and independent of later output" {
    const alloc = std.testing.allocator;
    var host = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 20, .rows = 5 });
    defer host.deinit(alloc);
    var stream = host.vtStream();
    defer stream.deinit();
    for (0..300) |index| {
        var buf: [32]u8 = undefined;
        stream.nextSlice(try std.fmt.bufPrint(&buf, "old-{d}\r\n", .{index}));
    }
    const history = (try PeerTerminalHistory.capture(alloc, &host, 200)).?;
    defer history.destroy(alloc);
    stream.nextSlice("NEW-LIVE-OUTPUT\r\n");
    var buf: [64 * 1024]u8 = undefined;
    const first = try history.read(0, &buf);
    try std.testing.expectEqual(@as(usize, 128), first.rows);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "NEW-LIVE-OUTPUT") == null);
    const second = try history.read(first.rows, &buf);
    try std.testing.expectEqual(@as(usize, 72), second.rows);
    const end = try history.read(first.rows + second.rows, &buf);
    try std.testing.expectEqual(@as(usize, 0), end.rows);
}
