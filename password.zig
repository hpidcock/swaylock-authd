//! password.zig – Zig port of password.c and password-buffer.c.
//! Manages the locked password buffer and keyboard input handling.

const std = @import("std");

const c = @cImport({
    @cDefine("_POSIX_C_SOURCE", "200809L");
    @cDefine("_DEFAULT_SOURCE", "1");
    @cInclude("errno.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("unistd.h");
    @cInclude("sys/mman.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("comm.h");
    @cInclude("log.h");
    @cInclude("loop.h");
    @cInclude("seat.h");
    @cInclude("swaylock.h");
    @cInclude("unicode.h");
});

// ── logging helpers ──────────────────────────────────────────────────

fn slog(
    verbosity: anytype,
    src: std.builtin.SourceLocation,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    c._swaylock_log(
        @as(c.enum_log_importance, @intCast(verbosity)),
        "[%s:%d] %s",
        c._swaylock_strip_path(src.file.ptr),
        @as(c_int, @intCast(src.line)),
        msg.ptr,
    );
}

fn slogErrno(
    verbosity: anytype,
    src: std.builtin.SourceLocation,
    comptime fmt: []const u8,
) void {
    const err = c.__errno_location().*;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrintZ(
        &buf,
        fmt ++ ": {s}",
        .{std.mem.sliceTo(c.strerror(err), 0)},
    ) catch return;
    c._swaylock_log(
        @as(c.enum_log_importance, @intCast(verbosity)),
        "[%s:%d] %s",
        c._swaylock_strip_path(src.file.ptr),
        @as(c_int, @intCast(src.line)),
        msg.ptr,
    );
}

// ── password-buffer ──────────────────────────────────────────────────

var mlock_supported: bool = true;
var cached_page_size: c_long = 0;

fn getPageSize() c_long {
    if (cached_page_size == 0)
        cached_page_size = c.sysconf(c._SC_PAGESIZE);
    return cached_page_size;
}

/// Expects addr to be page-aligned.
fn passwordBufferLock(addr: [*]u8, size: usize) bool {
    var retries: c_int = 5;
    while (c.mlock(@ptrCast(addr), size) != 0 and retries > 0) {
        const err = c.__errno_location().*;
        if (err == c.EAGAIN) {
            retries -= 1;
            if (retries == 0) {
                slog(
                    c.LOG_ERROR,
                    @src(),
                    "mlock() supported but failed too often.",
                    .{},
                );
                return false;
            }
        } else if (err == c.EPERM) {
            slogErrno(
                c.LOG_ERROR,
                @src(),
                "Unable to mlock() password memory: Unsupported!",
            );
            mlock_supported = false;
            return true;
        } else {
            slogErrno(
                c.LOG_ERROR,
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
        if (c.munlock(@ptrCast(addr), size) != 0) {
            slogErrno(
                c.LOG_ERROR,
                @src(),
                "Unable to munlock() password memory.",
            );
            return false;
        }
    }
    return true;
}

export fn password_buffer_create(size: usize) [*c]u8 {
    var buffer: ?*anyopaque = null;
    const result = c.posix_memalign(
        &buffer,
        @intCast(getPageSize()),
        size,
    );
    if (result != 0) {
        // posix_memalign does not set errno per the man page.
        c.__errno_location().* = result;
        slogErrno(
            c.LOG_ERROR,
            @src(),
            "failed to alloc password buffer",
        );
        return null;
    }
    const buf: [*]u8 = @ptrCast(buffer.?);
    if (!passwordBufferLock(buf, size)) {
        c.free(buffer);
        return null;
    }
    return buf;
}

export fn password_buffer_destroy(buffer: [*c]u8, size: usize) void {
    clear_buffer(buffer, size);
    _ = passwordBufferUnlock(buffer, size);
    c.free(buffer);
}

// ── buffer helpers ───────────────────────────────────────────────────

/// Clears a buffer using volatile writes so the compiler cannot
/// optimise the zeroing away.
export fn clear_buffer(buf: [*c]u8, size: usize) void {
    const vbuf: [*]volatile u8 = @ptrCast(buf);
    for (0..size) |i|
        vbuf[i] = 0;
}

export fn clear_password_buffer(pw: *c.swaylock_password) void {
    clear_buffer(pw.buffer, pw.buffer_len);
    pw.len = 0;
}

fn backspace(pw: *c.swaylock_password) bool {
    if (pw.len != 0) {
        const last: usize = @intCast(c.utf8_last_size(pw.buffer));
        pw.len -= last;
        pw.buffer[pw.len] = 0;
        return true;
    }
    return false;
}

fn appendCh(pw: *c.swaylock_password, codepoint: u32) void {
    const utf8_size: usize = c.utf8_chsize(codepoint);
    if (pw.len + utf8_size + 1 >= pw.buffer_len)
        return;
    _ = c.utf8_encode(&pw.buffer[pw.len], codepoint);
    pw.buffer[pw.len + utf8_size] = 0;
    pw.len += utf8_size;
}

// ── timer callbacks ──────────────────────────────────────────────────

fn setInputIdle(data: ?*anyopaque) callconv(.c) void {
    const state: *c.swaylock_state = @ptrCast(@alignCast(data));
    state.input_idle_timer = null;
    state.input_state = c.INPUT_STATE_IDLE;
    c.damage_state(state);
}

fn setAuthIdle(data: ?*anyopaque) callconv(.c) void {
    const state: *c.swaylock_state = @ptrCast(@alignCast(data));
    state.auth_idle_timer = null;
    state.auth_state = c.AUTH_STATE_IDLE;
    c.damage_state(state);
}

fn scheduleInputIdle(state: *c.swaylock_state) void {
    if (state.input_idle_timer != null)
        _ = c.loop_remove_timer(state.eventloop, state.input_idle_timer);
    state.input_idle_timer = c.loop_add_timer(
        state.eventloop,
        1500,
        setInputIdle,
        state,
    );
}

fn cancelInputIdle(state: *c.swaylock_state) void {
    if (state.input_idle_timer != null) {
        _ = c.loop_remove_timer(state.eventloop, state.input_idle_timer);
        state.input_idle_timer = null;
    }
}

export fn schedule_auth_idle(state: *c.swaylock_state) void {
    if (state.auth_idle_timer != null)
        _ = c.loop_remove_timer(state.eventloop, state.auth_idle_timer);
    state.auth_idle_timer = c.loop_add_timer(
        state.eventloop,
        3000,
        setAuthIdle,
        state,
    );
}

fn clearPassword(data: ?*anyopaque) callconv(.c) void {
    const state: *c.swaylock_state = @ptrCast(@alignCast(data));
    state.clear_password_timer = null;
    state.input_state = c.INPUT_STATE_CLEAR;
    scheduleInputIdle(state);
    clear_password_buffer(&state.password);
    c.damage_state(state);
}

fn schedulePasswordClear(state: *c.swaylock_state) void {
    if (state.clear_password_timer != null)
        _ = c.loop_remove_timer(
            state.eventloop,
            state.clear_password_timer,
        );
    state.clear_password_timer = c.loop_add_timer(
        state.eventloop,
        10000,
        clearPassword,
        state,
    );
}

fn cancelPasswordClear(state: *c.swaylock_state) void {
    if (state.clear_password_timer != null) {
        _ = c.loop_remove_timer(
            state.eventloop,
            state.clear_password_timer,
        );
        state.clear_password_timer = null;
    }
}

// ── submit / highlight ───────────────────────────────────────────────

fn submitPassword(state: *c.swaylock_state) void {
    if (state.args.ignore_empty and state.password.len == 0) {
        slog(c.LOG_DEBUG, @src(), "submit_password: skipped (ignore_empty)", .{});
        return;
    }
    if (state.auth_state == c.AUTH_STATE_VALIDATING) {
        slog(c.LOG_DEBUG, @src(), "submit_password: skipped (already validating)", .{});
        return;
    }
    slog(c.LOG_DEBUG, @src(), "submit_password: sending (len={d}) auth=idle -> validating", .{state.password.len});
    state.input_state = c.INPUT_STATE_IDLE;
    state.auth_state = c.AUTH_STATE_VALIDATING;
    cancelPasswordClear(state);
    cancelInputIdle(state);
    if (!c.write_comm_password(&state.password)) {
        slog(c.LOG_DEBUG, @src(), "submit_password: write failed auth=validating -> invalid", .{});
        state.auth_state = c.AUTH_STATE_INVALID;
        schedule_auth_idle(state);
    }
    c.damage_state(state);
}

fn updateHighlight(state: *c.swaylock_state) void {
    // Advance a random amount between 1/4 and 3/4 of a full turn.
    state.highlight_start =
        (state.highlight_start +
            @as(u32, @intCast(@rem(c.rand(), 1024))) + 512) % 2048;
}

// ── key handler ──────────────────────────────────────────────────────

export fn swaylock_handle_key(
    state: *c.swaylock_state,
    keysym: c.xkb_keysym_t,
    codepoint: u32,
) void {
    // In broker or auth-mode selection, Up/Down navigate the list
    // and Enter confirms. Tab presses the optional button.
    if (state.authd_active) {
        if (state.authd_stage == c.AUTHD_STAGE_BROKER or
            state.authd_stage == c.AUTHD_STAGE_AUTH_MODE)
        {
            const is_broker =
                state.authd_stage == c.AUTHD_STAGE_BROKER;
            if (keysym == c.XKB_KEY_Up) {
                if (is_broker) {
                    if (state.authd_sel_broker > 0)
                        state.authd_sel_broker -= 1;
                } else {
                    if (state.authd_sel_auth_mode > 0)
                        state.authd_sel_auth_mode -= 1;
                }
                c.damage_state(state);
                return;
            } else if (keysym == c.XKB_KEY_Down) {
                if (is_broker) {
                    if (state.authd_sel_broker <
                        state.authd_num_brokers - 1)
                        state.authd_sel_broker += 1;
                } else {
                    if (state.authd_sel_auth_mode <
                        state.authd_num_auth_modes - 1)
                        state.authd_sel_auth_mode += 1;
                }
                c.damage_state(state);
                return;
            } else if (keysym == c.XKB_KEY_Return or
                keysym == c.XKB_KEY_KP_Enter)
            {
                if (is_broker) {
                    const sel = state.authd_sel_broker;
                    if (sel >= 0 and sel < state.authd_num_brokers) {
                        const id =
                            state.authd_brokers[@intCast(sel)].id;
                        if (id != null)
                            _ = c.comm_main_write(
                                c.COMM_MSG_BROKER_SEL,
                                id,
                                c.strlen(id) + 1,
                            );
                    }
                } else {
                    const sel = state.authd_sel_auth_mode;
                    if (sel >= 0 and
                        sel < state.authd_num_auth_modes)
                    {
                        const id =
                            state.authd_auth_modes[@intCast(sel)].id;
                        if (id != null)
                            _ = c.comm_main_write(
                                c.COMM_MSG_AUTH_MODE_SEL,
                                id,
                                c.strlen(id) + 1,
                            );
                    }
                }
                return;
            } else if (keysym == c.XKB_KEY_Escape) {
                _ = c.comm_main_write(c.COMM_MSG_CANCEL, null, 0);
                return;
            }
        }
        if (state.authd_stage == c.AUTHD_STAGE_CHALLENGE) {
            if (keysym == c.XKB_KEY_Tab and
                state.authd_layout.button != null)
            {
                _ = c.comm_main_write(c.COMM_MSG_BUTTON, null, 0);
                c.damage_state(state);
                return;
            }
        }
    }

    if (keysym == c.XKB_KEY_KP_Enter or keysym == c.XKB_KEY_Return) {
        submitPassword(state);
    } else if (keysym == c.XKB_KEY_Delete or
        keysym == c.XKB_KEY_BackSpace)
    {
        if (state.xkb.control) {
            clear_password_buffer(&state.password);
            state.input_state = c.INPUT_STATE_CLEAR;
            cancelPasswordClear(state);
        } else if (backspace(&state.password) and
            state.password.len != 0)
        {
            state.input_state = c.INPUT_STATE_BACKSPACE;
            schedulePasswordClear(state);
            updateHighlight(state);
        } else {
            state.input_state = c.INPUT_STATE_CLEAR;
            cancelPasswordClear(state);
        }
        scheduleInputIdle(state);
        c.damage_state(state);
    } else if (keysym == c.XKB_KEY_Escape) {
        clear_password_buffer(&state.password);
        state.input_state = c.INPUT_STATE_CLEAR;
        cancelPasswordClear(state);
        scheduleInputIdle(state);
        c.damage_state(state);
    } else if (keysym == c.XKB_KEY_Caps_Lock or
        keysym == c.XKB_KEY_Shift_L or
        keysym == c.XKB_KEY_Shift_R or
        keysym == c.XKB_KEY_Control_L or
        keysym == c.XKB_KEY_Control_R or
        keysym == c.XKB_KEY_Meta_L or
        keysym == c.XKB_KEY_Meta_R or
        keysym == c.XKB_KEY_Alt_L or
        keysym == c.XKB_KEY_Alt_R or
        keysym == c.XKB_KEY_Super_L or
        keysym == c.XKB_KEY_Super_R)
    {
        state.input_state = c.INPUT_STATE_NEUTRAL;
        schedulePasswordClear(state);
        scheduleInputIdle(state);
        c.damage_state(state);
    } else if ((keysym == c.XKB_KEY_m or
        keysym == c.XKB_KEY_d or
        keysym == c.XKB_KEY_j) and state.xkb.control)
    {
        submitPassword(state);
    } else if ((keysym == c.XKB_KEY_c or
        keysym == c.XKB_KEY_u) and state.xkb.control)
    {
        clear_password_buffer(&state.password);
        state.input_state = c.INPUT_STATE_CLEAR;
        cancelPasswordClear(state);
        scheduleInputIdle(state);
        c.damage_state(state);
    } else {
        if (codepoint != 0) {
            appendCh(&state.password, codepoint);
            state.input_state = c.INPUT_STATE_LETTER;
            schedulePasswordClear(state);
            scheduleInputIdle(state);
            updateHighlight(state);
            c.damage_state(state);
        }
    }
}
