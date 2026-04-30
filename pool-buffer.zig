//! pool-buffer.zig – Zig port of pool-buffer.c.
//! Manages pairs of Wayland shared-memory buffers backed by
//! Cairo image surfaces.

const std = @import("std");

const c = @cImport({
    @cDefine("_POSIX_C_SOURCE", "200809L");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("sys/mman.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("wayland-client.h");
    @cInclude("cairo.h");
    @cInclude("pool-buffer.h");
});

/// Returns the address of the thread-local errno variable (Linux/glibc).
extern fn __errno_location() *c_int;

/// Opens an anonymous POSIX shared-memory object by trying
/// time-stamped names until one does not already exist.
/// Returns a file descriptor on success, or -1 on failure.
fn anonymous_shm_open() c_int {
    var retries: c_int = 100;
    while (retries > 0) : (retries -= 1) {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        const pid = c.getpid();
        // Truncate tv_nsec to u32 without panicking on a
        // signed-to-unsigned conversion.
        const nsec: u32 = @truncate(
            @as(u64, @bitCast(@as(i64, ts.tv_nsec))),
        );
        var name: [50]u8 = undefined;
        // bufPrintZ guarantees null-termination for shm_open.
        _ = std.fmt.bufPrintZ(
            &name,
            "/swaylock-{x}-{x}",
            .{ @as(u32, @intCast(pid)), nsec },
        ) catch continue;
        // shm_open guarantees that O_CLOEXEC is set.
        const fd = c.shm_open(
            @as([*c]const u8, @ptrCast(&name)),
            c.O_RDWR | c.O_CREAT | c.O_EXCL,
            @as(c.mode_t, 0o600),
        );
        if (fd >= 0) {
            _ = c.shm_unlink(@as([*c]const u8, @ptrCast(&name)));
            return fd;
        }
        if (__errno_location().* != c.EEXIST) break;
    }
    return -1;
}

fn buffer_release(
    data: ?*anyopaque,
    wl_buf: ?*c.wl_buffer,
) callconv(.c) void {
    _ = wl_buf;
    const buffer: *c.pool_buffer = @ptrCast(@alignCast(data.?));
    buffer.busy = false;
}

const buffer_listener: c.wl_buffer_listener = .{
    .release = buffer_release,
};

/// Creates a Wayland shared-memory buffer of the given dimensions
/// and pixel format, populating buf in place.
/// Returns buf on success, or null on failure.
pub export fn create_buffer(
    shm: ?*c.wl_shm,
    buf: *c.pool_buffer,
    width: i32,
    height: i32,
    format: u32,
) ?*c.pool_buffer {
    const stride: u32 = @as(u32, @intCast(width)) * 4;
    const size: usize = @as(usize, stride) * @as(usize, @intCast(height));
    var data: ?*anyopaque = null;
    if (size > 0) {
        const fd = anonymous_shm_open();
        if (fd == -1) return null;
        if (c.ftruncate(fd, @as(i64, @intCast(size))) < 0) {
            _ = c.close(fd);
            return null;
        }
        data = c.mmap(
            null,
            size,
            c.PROT_READ | c.PROT_WRITE,
            c.MAP_SHARED,
            fd,
            0,
        );
        const pool = c.wl_shm_create_pool(
            shm,
            fd,
            @as(i32, @intCast(size)),
        );
        buf.buffer = c.wl_shm_pool_create_buffer(
            pool,
            0,
            width,
            height,
            @as(i32, @intCast(stride)),
            format,
        );
        _ = c.wl_buffer_add_listener(
            buf.buffer,
            &buffer_listener,
            @ptrCast(buf),
        );
        c.wl_shm_pool_destroy(pool);
        _ = c.close(fd);
    }
    buf.size = size;
    buf.width = @as(u32, @intCast(width));
    buf.height = @as(u32, @intCast(height));
    buf.data = data;
    buf.surface = c.cairo_image_surface_create_for_data(
        @as([*c]u8, @ptrCast(data)),
        c.CAIRO_FORMAT_ARGB32,
        width,
        height,
        @as(c_int, @intCast(stride)),
    );
    buf.cairo = c.cairo_create(buf.surface);
    return buf;
}

/// Releases all resources held by buffer and zeroes the struct.
pub export fn destroy_buffer(buffer: *c.pool_buffer) void {
    if (buffer.buffer != null)
        c.wl_buffer_destroy(buffer.buffer);
    if (buffer.cairo != null)
        c.cairo_destroy(buffer.cairo);
    if (buffer.surface != null)
        c.cairo_surface_destroy(buffer.surface);
    if (buffer.data != null)
        _ = c.munmap(buffer.data, buffer.size);
    buffer.* = std.mem.zeroes(c.pool_buffer);
}

/// Returns a pointer to a non-busy buffer from pool[0..2],
/// allocating or reallocating it if its dimensions have changed.
/// Returns null if all buffers are busy or allocation fails.
pub export fn get_next_buffer(
    shm: ?*c.wl_shm,
    pool: [*]c.pool_buffer,
    width: u32,
    height: u32,
) ?*c.pool_buffer {
    var buffer: ?*c.pool_buffer = null;
    for (0..2) |i| {
        if (pool[i].busy) continue;
        buffer = &pool[i];
    }
    const buf = buffer orelse return null;
    if (buf.width != width or buf.height != height)
        destroy_buffer(buf);
    if (buf.buffer == null) {
        if (create_buffer(
            shm,
            buf,
            @as(i32, @intCast(width)),
            @as(i32, @intCast(height)),
            c.WL_SHM_FORMAT_ARGB8888,
        ) == null) return null;
    }
    buf.busy = true;
    return buf;
}
