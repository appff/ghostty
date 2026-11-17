//! Desktop peer bootstrap state. Screen cells use the native VT formatter;
//! state which VT repainting cannot preserve (saved cursors, pending wrap,
//! keyboard stacks, saved modes) is restored explicitly before raw output.
//! Capture and restore callers hold the terminal's renderer mutex.
const PeerTerminalSnapshot = @This();
const std = @import("std");
const terminal = @import("../terminal/main.zig");
const Terminal = terminal.Terminal;
const Screen = terminal.Screen;
const TerminalFlags = @FieldType(Terminal, "flags");

version: u8 = 1,
columns: u16,
rows: u16,
active: terminal.ScreenSet.Key,
modes: @FieldType(Terminal, "modes"),
region: Terminal.ScrollingRegion,
colors: Terminal.Colors,
previous_char: ?u21,
status_display: @FieldType(Terminal, "status_display"),
cursor: Terminal.Cursor,
mouse_event: @FieldType(TerminalFlags, "mouse_event"),
mouse_format: @FieldType(TerminalFlags, "mouse_format"),
mouse_shift_capture: @FieldType(TerminalFlags, "mouse_shift_capture"),
modify_other_keys_2: bool,
tabstops: []const u16,
primary: ScreenState,
alternate: ?ScreenState,

const ScreenState = struct {
    vt: []const u8,
    x: u16,
    y: u16,
    pending_wrap: bool,
    cursor_style: Screen.CursorStyle,
    saved_cursor: ?Screen.SavedCursor,
    charset: Screen.CharsetState,
    protected_mode: @FieldType(Screen, "protected_mode"),
    keyboard: @FieldType(Screen, "kitty_keyboard"),

    fn capture(alloc: std.mem.Allocator, screen: *const Screen) !ScreenState {
        const buffer = try alloc.alloc(u8, 4 * 1024 * 1024);
        defer alloc.free(buffer);
        var writer: std.Io.Writer = .fixed(buffer);
        var formatter: terminal.formatter.ScreenFormatter = .init(screen, .{
            .emit = .vt,
            .trim = false,
            .unwrap = false,
        });
        formatter.content = .{ .selection = terminal.Selection.init(
            screen.pages.getTopLeft(.active),
            screen.pages.getBottomRight(.active).?,
            false,
        ) };
        // Restore the active pen and hyperlink after writing the cells. The
        // geometry/modes are assigned later so margins cannot distort replay.
        formatter.extra = .all;
        try formatter.format(&writer);
        return .{
            .vt = try alloc.dupe(u8, writer.buffered()),
            .x = screen.cursor.x,
            .y = screen.cursor.y,
            .pending_wrap = screen.cursor.pending_wrap,
            .cursor_style = screen.cursor.cursor_style,
            .saved_cursor = screen.saved_cursor,
            .charset = screen.charset,
            .protected_mode = screen.protected_mode,
            .keyboard = screen.kitty_keyboard,
        };
    }

    fn valid(self: ScreenState, columns: u16, rows: u16) bool {
        if (self.x >= columns or self.y >= rows or self.vt.len > 4 * 1024 * 1024) return false;
        if (self.saved_cursor) |cursor| {
            if (cursor.x >= columns or cursor.y >= rows) return false;
        }
        return true;
    }

    fn restore(self: ScreenState, t: *Terminal, key: terminal.ScreenSet.Key) !void {
        _ = try t.switchScreen(key);
        // Formatter replay always starts with default addressing and charsets.
        t.modes = .{};
        t.scrolling_region = .{ .top = 0, .bottom = t.rows - 1, .left = 0, .right = t.cols - 1 };
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(self.vt);
        if (stream.handler.semantic_failure or stream.parser.state != .ground or stream.utf8decoder.state != 0)
            return error.InvalidSnapshot;
        const screen = t.screens.active;
        screen.cursorAbsolute(self.x, self.y);
        screen.cursor.pending_wrap = self.pending_wrap;
        screen.cursor.cursor_style = self.cursor_style;
        screen.saved_cursor = self.saved_cursor;
        screen.charset = self.charset;
        screen.protected_mode = self.protected_mode;
        screen.kitty_keyboard = self.keyboard;
    }
};

pub fn encode(alloc: std.mem.Allocator, t: *const Terminal) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();
    var tabstops: std.ArrayList(u16) = .empty;
    for (0..t.cols) |column| {
        if (t.tabstops.get(column)) try tabstops.append(scratch, @intCast(column));
    }
    const value: PeerTerminalSnapshot = .{
        .columns = t.cols,
        .rows = t.rows,
        .active = t.screens.active_key,
        .modes = t.modes,
        .region = t.scrolling_region,
        .colors = t.colors,
        .previous_char = t.previous_char,
        .status_display = t.status_display,
        .cursor = t.cursor,
        .mouse_event = t.flags.mouse_event,
        .mouse_format = t.flags.mouse_format,
        .mouse_shift_capture = t.flags.mouse_shift_capture,
        .modify_other_keys_2 = t.flags.modify_other_keys_2,
        .tabstops = tabstops.items,
        .primary = try .capture(scratch, t.screens.get(.primary).?),
        .alternate = if (t.screens.get(.alternate)) |screen| try .capture(scratch, screen) else null,
    };
    const buffer = try alloc.alloc(u8, 4 * 1024 * 1024);
    defer alloc.free(buffer);
    var writer: std.Io.Writer = .fixed(buffer);
    try std.json.Stringify.value(value, .{}, &writer);
    return alloc.dupe(u8, writer.buffered());
}

pub fn decode(alloc: std.mem.Allocator, data: []const u8) !std.json.Parsed(PeerTerminalSnapshot) {
    if (data.len > 4 * 1024 * 1024) return error.InvalidSnapshot;
    var parsed = try std.json.parseFromSlice(PeerTerminalSnapshot, alloc, data, .{});
    errdefer parsed.deinit();
    const v = parsed.value;
    if (v.version != 1 or v.columns < 2 or v.columns > 1000 or v.rows < 2 or v.rows > 1000 or
        v.region.top > v.region.bottom or v.region.bottom >= v.rows or
        v.region.left > v.region.right or v.region.right >= v.columns or
        v.tabstops.len > v.columns or !v.primary.valid(v.columns, v.rows)) return error.InvalidSnapshot;
    if (v.alternate) |screen| {
        if (!screen.valid(v.columns, v.rows)) return error.InvalidSnapshot;
    } else if (v.active == .alternate) return error.InvalidSnapshot;
    for (v.tabstops) |column| {
        if (column >= v.columns) return error.InvalidSnapshot;
    }
    if (v.previous_char) |char| {
        if (!std.unicode.utf8ValidCodepoint(char)) return error.InvalidSnapshot;
    }
    return parsed;
}

pub fn restore(self: PeerTerminalSnapshot, t: *Terminal) !void {
    if (t.cols != self.columns or t.rows != self.rows) return error.WrongGeometry;
    t.fullReset();
    try self.primary.restore(t, .primary);
    if (self.alternate) |screen| try screen.restore(t, .alternate);
    t.screens.switchTo(self.active);
    t.modes = self.modes;
    t.scrolling_region = self.region;
    t.colors = self.colors;
    t.cursor = self.cursor;
    t.previous_char = self.previous_char;
    t.status_display = self.status_display;
    t.flags.mouse_event = self.mouse_event;
    t.flags.mouse_format = self.mouse_format;
    t.flags.mouse_shift_capture = self.mouse_shift_capture;
    t.flags.modify_other_keys_2 = self.modify_other_keys_2;
    for (0..t.cols) |column| {
        if (t.tabstops.get(column)) t.tabstops.unset(column);
    }
    for (self.tabstops) |column| t.tabstops.set(column);
    t.flags.dirty = .{ .clear = true, .palette = true, .reverse_colors = true };
}

test "peer snapshot preserves raw continuation across screens and saved state" {
    const alloc = std.testing.allocator;
    var host = try Terminal.init(std.testing.io, alloc, .{ .cols = 12, .rows = 5 });
    defer host.deinit(alloc);
    var input = host.vtStream();
    defer input.deinit();
    input.nextSlice("primary\x1b[31m\x1b7\x1b[?1049h\x1b[2;4r\x1b[?6h\x1b[>3u\x1b[>7u\x1b[?1003h\x1b[?1006h123456789012");
    const encoded = try PeerTerminalSnapshot.encode(alloc, &host);
    defer alloc.free(encoded);
    var decoded = try PeerTerminalSnapshot.decode(alloc, encoded);
    defer decoded.deinit();
    var guest = try Terminal.init(std.testing.io, alloc, .{ .cols = 12, .rows = 5 });
    defer guest.deinit(alloc);
    try decoded.value.restore(&guest);
    var output = guest.vtStream();
    defer output.deinit();
    for ([_][]const u8{ "X\x1b[<u", "\x1b[?1049l", "\x1b8Y\tZ", "\x1b[?47hQ", "\x1b[?47lR" }) |bytes| {
        input.nextSlice(bytes);
        output.nextSlice(bytes);
        const expected = try PeerTerminalSnapshot.encode(alloc, &host);
        defer alloc.free(expected);
        const actual = try PeerTerminalSnapshot.encode(alloc, &guest);
        defer alloc.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "peer history hydration preserves live state and scrolled viewport" {
    const alloc = std.testing.allocator;
    var guest = try Terminal.init(std.testing.io, alloc, .{ .cols = 12, .rows = 5 });
    defer guest.deinit(alloc);
    var stream = guest.vtStream();
    defer stream.deinit();
    stream.nextSlice("recent\r\n1\r\n2\r\n3\r\n4\r\nlive\x1b[32m");
    const pages = &guest.screens.active.pages;
    pages.scroll(.top);
    const viewport = pages.getTopLeft(.viewport);
    const current = pages.getTopLeft(.active);
    const cursor = guest.screens.active.cursor;
    const before = try PeerTerminalSnapshot.encode(alloc, &guest);
    defer alloc.free(before);
    var history = try Terminal.init(std.testing.io, alloc, .{ .cols = 12, .rows = 3 });
    defer history.deinit(alloc);
    var history_stream = history.vtStream();
    defer history_stream.deinit();
    history_stream.nextSlice("old-1\r\nold-2\r\nold-3");
    try std.testing.expect(try pages.prependClonedRows(&history.screens.active.pages, 3));
    try std.testing.expect(std.meta.eql(viewport, pages.getTopLeft(.viewport)));
    try std.testing.expect(std.meta.eql(current, pages.getTopLeft(.active)));
    try std.testing.expect(std.meta.eql(cursor, guest.screens.active.cursor));
    const after = try PeerTerminalSnapshot.encode(alloc, &guest);
    defer alloc.free(after);
    try std.testing.expectEqualStrings(before, after);
    const text = try guest.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "old-1\nold-2\nold-3\nrecent"));
}

test "peer history budget rejection rolls back partially staged pages" {
    const alloc = std.testing.allocator;
    var guest = try Terminal.init(std.testing.io, alloc, .{ .cols = 80, .rows = 24 });
    defer guest.deinit(alloc);
    var history = try Terminal.init(std.testing.io, alloc, .{ .cols = 80, .rows = 1000 });
    defer history.deinit(alloc);
    const pages = &guest.screens.active.pages;
    const source = &history.screens.active.pages;
    const before_size = pages.page_size;
    const before_rows = pages.total_rows;
    pages.explicit_max_size = before_size + source.pages.first.?.page().memory.len;
    pages.min_max_size = pages.explicit_max_size;
    try std.testing.expect(!(try pages.prependClonedRows(source, 1000)));
    try std.testing.expectEqual(before_size, pages.page_size);
    try std.testing.expectEqual(before_rows, pages.total_rows);
    try std.testing.expectEqual(@as(u64, 0), pages.row_space_revision);
}
