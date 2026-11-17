//! Bounded, demand-enabled PTY output retention for desktop peer recovery.
//! The owner holds the renderer mutex for every operation. Sequence numbers
//! count bytes modulo u64, exactly like Termio.processed_output_bytes.
const OutputReplay = @This();
const std = @import("std");

storage: []u8,
next: u64,
count: usize = 0,
write_index: usize = 0,

pub fn init(alloc: std.mem.Allocator, capacity: usize, next: u64) !OutputReplay {
    if (capacity == 0) return error.InvalidCapacity;
    return .{ .storage = try alloc.alloc(u8, capacity), .next = next };
}

pub fn deinit(self: *OutputReplay, alloc: std.mem.Allocator) void {
    alloc.free(self.storage);
    self.* = undefined;
}

pub fn append(self: *OutputReplay, bytes: []const u8) void {
    self.next +%= @intCast(bytes.len);
    const retained = bytes[bytes.len - @min(bytes.len, self.storage.len) ..];
    const first = @min(retained.len, self.storage.len - self.write_index);
    @memcpy(self.storage[self.write_index..][0..first], retained[0..first]);
    @memcpy(self.storage[0 .. retained.len - first], retained[first..]);
    self.write_index = (self.write_index + retained.len) % self.storage.len;
    self.count = @min(self.storage.len, self.count + retained.len);
}

/// Returns null for a gap or a future cursor. An empty slice is a valid idle
/// result. The caller supplies a small transfer buffer to bound copy cost.
pub fn read(self: *const OutputReplay, from: u64, buffer: []u8) ?[]const u8 {
    const distance = self.next -% from;
    if (distance > self.count) return null;
    const available: usize = @intCast(distance);
    const length = @min(available, buffer.len);
    const start = (self.write_index + self.storage.len - available) % self.storage.len;
    const first = @min(length, self.storage.len - start);
    @memcpy(buffer[0..first], self.storage[start..][0..first]);
    @memcpy(buffer[first..length], self.storage[0 .. length - first]);
    return buffer[0..length];
}

test "peer output replay retains exact suffix and rejects gaps" {
    var replay = try OutputReplay.init(std.testing.allocator, 8, 100);
    defer replay.deinit(std.testing.allocator);
    var buffer: [32]u8 = undefined;
    replay.append("abcdef");
    try std.testing.expectEqualStrings("abcdef", replay.read(100, &buffer).?);
    replay.append("ghijkl");
    try std.testing.expect(replay.read(100, &buffer) == null);
    try std.testing.expectEqualStrings("efghijkl", replay.read(104, &buffer).?);
    try std.testing.expectEqualStrings("", replay.read(112, &buffer).?);
    try std.testing.expect(replay.read(113, &buffer) == null);
    try std.testing.expectEqualStrings("efg", replay.read(104, buffer[0..3]).?);
}

test "peer output replay oversized writes and sequence wrap" {
    var replay = try OutputReplay.init(std.testing.allocator, 4, std.math.maxInt(u64) - 2);
    defer replay.deinit(std.testing.allocator);
    var buffer: [4]u8 = undefined;
    replay.append("0123456789");
    try std.testing.expectEqual(@as(u64, 7), replay.next);
    try std.testing.expectEqualStrings("6789", replay.read(3, &buffer).?);
    try std.testing.expect(replay.read(2, &buffer) == null);
    replay.append("xy");
    try std.testing.expectEqualStrings("89xy", replay.read(5, &buffer).?);
}
