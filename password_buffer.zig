//! password_buffer.zig – Secure mlocked password buffer management.
//! Extracted from password.zig to break the comm↔password circular
//! dependency. Both comm.zig and password.zig import this module.

const std = @import("std");
const types = @import("types.zig");
const log = @import("log.zig");

/// Allocates a page-aligned, mlocked buffer of the given size.
/// Returns a pointer to the buffer on success, or null on failure.
pub fn create(size: usize) ?[]u8 {
    const flags: std.posix.MAP = .{
        .TYPE = .PRIVATE,
        .ANONYMOUS = true,
        .LOCKED = true,
    };
    const slice = std.posix.mmap(
        null,
        size,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        flags,
        0,
        0,
    ) catch |err| {
        log.slog(
            log.LogImportance.err,
            @src(),
            "failed to alloc password buffer: {s}",
            .{@errorName(err)},
        );
        return null;
    };
    return slice;
}

/// Clears and frees a buffer previously created by passwordBufferCreate.
pub fn destroy(buffer: []u8) void {
    zero(buffer);
    const aligned: []align(std.heap.page_size_min) u8 = @as([*]align(std.heap.page_size_min) u8, @ptrCast(
        @alignCast(buffer),
    ))[0..buffer.len];
    std.posix.munmap(aligned);
}

/// Clears a buffer using volatile writes so the compiler cannot
/// optimise the zeroing away.
pub fn zero(buf: ?[]u8) void {
    const vbuf: [*]volatile u8 = @ptrCast(buf.?.ptr);
    for (0..buf.?.len) |i|
        vbuf[i] = 0;
}

/// Clears the password buffer and resets the length to zero.
pub fn clear(pw: *types.SwaylockPassword) void {
    zero(pw.buffer);
    pw.len = 0;
}
