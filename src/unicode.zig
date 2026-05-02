//! UTF-8 utility functions replacing unicode.c from the C codebase.

const std = @import("std");

/// Returns the byte length of the last UTF-8 character in the
/// null-terminated string, or 0 if the string is empty.
/// Does not validate correct UTF-8 encoding.
pub fn utf8LastSize(str: [*:0]const u8) i32 {
    const s = std.mem.sliceTo(str, 0);
    if (s.len == 0) return 0;
    var i: usize = s.len;
    var len: i32 = 0;
    while (i > 0) {
        i -= 1;
        len += 1;
        if ((s[i] & 0xc0) != 0x80) return len;
    }
    return 0;
}

/// Returns the number of bytes needed to encode a codepoint
/// as UTF-8.
pub fn utf8Chsize(ch: u32) usize {
    if (ch > 0x10FFFF) return 4;
    return std.unicode.utf8CodepointSequenceLength(
        @intCast(ch),
    ) catch 4;
}

/// Encodes a codepoint as UTF-8 into str, returning the byte
/// length written. Falls back to manual encoding for surrogates
/// and out-of-range values.
pub fn utf8Encode(str: []u8, ch: u32) usize {
    if (ch <= 0x10FFFF) {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(
            @intCast(ch),
            &buf,
        ) catch return encodeManual(str, ch);
        @memcpy(str[0..n], buf[0..n]);
        return n;
    }
    return encodeManual(str, ch);
}

// Manual UTF-8 encoder without validation. Handles surrogates
// and out-of-range codepoints matching the original C behaviour.
fn encodeManual(str: []u8, ch_in: u32) usize {
    var ch = ch_in;
    var first: u8 = undefined;
    var len: usize = undefined;
    if (ch < 0x80) {
        first = 0;
        len = 1;
    } else if (ch < 0x800) {
        first = 0xc0;
        len = 2;
    } else if (ch < 0x10000) {
        first = 0xe0;
        len = 3;
    } else {
        first = 0xf0;
        len = 4;
    }
    var i: usize = len - 1;
    while (i > 0) : (i -= 1) {
        str[i] = @as(u8, @truncate(ch & 0x3f)) | 0x80;
        ch >>= 6;
    }
    str[0] = @as(u8, @truncate(ch)) | first;
    return len;
}

test "utf8LastSize: empty string" {
    const s: [*:0]const u8 = "";
    try std.testing.expectEqual(@as(i32, 0), utf8LastSize(s));
}

test "utf8LastSize: single ASCII byte" {
    const s: [*:0]const u8 = "a";
    try std.testing.expectEqual(@as(i32, 1), utf8LastSize(s));
}

test "utf8LastSize: 2-byte codepoint" {
    // U+00E9 = é, encoded as 0xC3 0xA9
    const s: [*:0]const u8 = "\xc3\xa9";
    try std.testing.expectEqual(@as(i32, 2), utf8LastSize(s));
}

test "utf8LastSize: 3-byte codepoint" {
    // U+4E2D = 中, encoded as 0xE4 0xB8 0xAD
    const s: [*:0]const u8 = "\xe4\xb8\xad";
    try std.testing.expectEqual(@as(i32, 3), utf8LastSize(s));
}

test "utf8LastSize: 4-byte codepoint" {
    // U+1F600 = 😀, encoded as 0xF0 0x9F 0x98 0x80
    const s: [*:0]const u8 = "\xf0\x9f\x98\x80";
    try std.testing.expectEqual(@as(i32, 4), utf8LastSize(s));
}

test "utf8LastSize: ASCII then multi-byte last" {
    // "a" followed by U+00E9 é — last char is 2 bytes
    const s: [*:0]const u8 = "a\xc3\xa9";
    try std.testing.expectEqual(@as(i32, 2), utf8LastSize(s));
}

test "utf8LastSize: multi-byte then ASCII last" {
    // U+00E9 é followed by "z" — last char is 1 byte
    const s: [*:0]const u8 = "\xc3\xa9z";
    try std.testing.expectEqual(@as(i32, 1), utf8LastSize(s));
}

test "utf8Chsize: ASCII range" {
    try std.testing.expectEqual(@as(usize, 1), utf8Chsize(0x00));
    try std.testing.expectEqual(@as(usize, 1), utf8Chsize(0x7F));
}

test "utf8Chsize: 2-byte range" {
    try std.testing.expectEqual(@as(usize, 2), utf8Chsize(0x80));
    try std.testing.expectEqual(@as(usize, 2), utf8Chsize(0x7FF));
}

test "utf8Chsize: 3-byte range" {
    try std.testing.expectEqual(@as(usize, 3), utf8Chsize(0x800));
    try std.testing.expectEqual(@as(usize, 3), utf8Chsize(0xFFFF));
}

test "utf8Chsize: 4-byte range" {
    try std.testing.expectEqual(@as(usize, 4), utf8Chsize(0x10000));
    try std.testing.expectEqual(@as(usize, 4), utf8Chsize(0x10FFFF));
}

test "utf8Chsize: beyond Unicode range falls back to 4" {
    try std.testing.expectEqual(@as(usize, 4), utf8Chsize(0x110000));
    try std.testing.expectEqual(
        @as(usize, 4),
        utf8Chsize(0xFFFFFFFF),
    );
}

test "utf8Encode: ASCII codepoint" {
    var buf: [4]u8 = undefined;
    const n = utf8Encode(&buf, 'A');
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 'A'), buf[0]);
}

test "utf8Encode: 2-byte codepoint" {
    var buf: [4]u8 = undefined;
    // U+00E9 = é
    const n = utf8Encode(&buf, 0xE9);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xC3, 0xA9 },
        buf[0..2],
    );
}

test "utf8Encode: 3-byte codepoint" {
    var buf: [4]u8 = undefined;
    // U+4E2D = 中
    const n = utf8Encode(&buf, 0x4E2D);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xE4, 0xB8, 0xAD },
        buf[0..3],
    );
}

test "utf8Encode: 4-byte codepoint" {
    var buf: [4]u8 = undefined;
    // U+1F600 = 😀
    const n = utf8Encode(&buf, 0x1F600);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xF0, 0x9F, 0x98, 0x80 },
        buf[0..4],
    );
}

test "utf8Encode: size matches utf8Chsize" {
    const codepoints = [_]u32{ 0, 0x7F, 0x80, 0x7FF, 0x800, 0xFFFF, 0x10000, 0x10FFFF };
    for (codepoints) |cp| {
        var buf: [4]u8 = undefined;
        const encoded = utf8Encode(&buf, cp);
        try std.testing.expectEqual(utf8Chsize(cp), encoded);
    }
}
