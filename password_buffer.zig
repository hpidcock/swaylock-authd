//! password_buffer.zig – Secure mlocked password buffer management.
//! Extracted from password.zig to break the comm↔password circular
//! dependency. Both comm.zig and password.zig import this module.

const std = @import("std");
const types = @import("types.zig");
const log = @import("log.zig");

extern fn mlock(addr: ?*const anyopaque, len: usize) c_int;
extern fn munlock(addr: ?*const anyopaque, len: usize) c_int;

var mlock_supported: bool = true;

fn slogErrno(
    verbosity: log.LogImportance,
    src: std.builtin.SourceLocation,
    comptime fmt: []const u8,
) void {
    log.slog(verbosity, src, fmt ++ ": errno {d}", .{std.c._errno().*});
}

/// Expects addr to be page-aligned.
fn passwordBufferLock(addr: [*]u8, size: usize) bool {
    var retries: i32 = 5;
    while (mlock(@ptrCast(addr), size) != 0 and retries > 0) {
        const err = std.c._errno().*;
        if (err == @intFromEnum(std.posix.E.AGAIN)) {
            retries -= 1;
            if (retries == 0) {
                log.slog(
                    log.LogImportance.err,
                    @src(),
                    "mlock() supported but failed too often.",
                    .{},
                );
                return false;
            }
        } else if (err == @intFromEnum(std.posix.E.PERM)) {
            slogErrno(
                log.LogImportance.err,
                @src(),
                "Unable to mlock() password memory: Unsupported!",
            );
            mlock_supported = false;
            return true;
        } else {
            slogErrno(
                log.LogImportance.err,
                @src(),
                "Unable to mlock() password memory.",
            );
            return false;
        }
    }
    return true;
}

/// Expects addr to be page-aligned.
fn passwordBufferUnlock(addr: [*]u8, size: usize) bool {
    if (mlock_supported) {
        if (munlock(@ptrCast(addr), size) != 0) {
            slogErrno(
                log.LogImportance.err,
                @src(),
                "Unable to munlock() password memory.",
            );
            return false;
        }
    }
    return true;
}

/// Allocates a page-aligned, mlocked buffer of the given size.
/// Returns a pointer to the buffer on success, or null on failure.
pub fn passwordBufferCreate(size: usize) ?[*]u8 {
    const slice = std.heap.c_allocator.alignedAlloc(
        u8,
        @as(u29, @intCast(std.heap.page_size_min)),
        size,
    ) catch |err| {
        log.slog(
            log.LogImportance.err,
            @src(),
            "failed to alloc password buffer: {s}",
            .{@errorName(err)},
        );
        return null;
    };
    if (!passwordBufferLock(slice.ptr, size)) {
        std.heap.c_allocator.free(slice);
        return null;
    }
    return slice.ptr;
}

/// Clears and frees a buffer previously created by passwordBufferCreate.
pub fn passwordBufferDestroy(buffer: ?[*]u8, size: usize) void {
    clearBuffer(buffer, size);
    _ = passwordBufferUnlock(buffer.?, size);
    std.heap.c_allocator.free(buffer.?[0..size]);
}

/// Clears a buffer using volatile writes so the compiler cannot
/// optimise the zeroing away.
pub fn clearBuffer(buf: ?[*]u8, size: usize) void {
    const vbuf: [*]volatile u8 = @ptrCast(buf.?);
    for (0..size) |i|
        vbuf[i] = 0;
}

/// Clears the password buffer and resets the length to zero.
pub fn clearPasswordBuffer(pw: *types.SwaylockPassword) void {
    clearBuffer(pw.buffer, pw.buffer_len);
    pw.len = 0;
}
