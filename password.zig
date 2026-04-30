//! password.zig – Zig port of password.c and password-buffer.c.
//! Manages the locked password buffer and keyboard input handling.

const std = @import("std");
const types = @import("types.zig");

// Only stdlib needed locally — xkb constants come from types.c.
const c = @cImport({
    @cDefine("_POSIX_C_SOURCE", "200809L");
    @cDefine("_DEFAULT_SOURCE", "1");
    @cInclude("stdlib.h");
});

const wl = types.c;

const log_err: i32 = @intFromEnum(types.LogImportance.err);
const log_debug: i32 = @intFromEnum(types.LogImportance.debug);

const log = @import("log.zig");
const loop = @import("loop.zig");
const comm = @import("comm.zig");
const password_buffer = @import("password_buffer.zig");
const unicode_mod = @import("unicode.zig");

extern fn damage_state(state: *types.SwaylockState) void;

fn backspace(pw: *types.SwaylockPassword) bool {
    if (pw.len != 0) {
        const last: i32 = unicode_mod.utf8LastSize(
            @ptrCast(pw.buffer),
        );
        pw.len -= @intCast(last);
        pw.buffer.?[@intCast(pw.len)] = 0;
        return true;
    }
    return false;
}

fn appendCh(pw: *types.SwaylockPassword, codepoint: u32) void {
    const utf8_size: usize = unicode_mod.utf8Chsize(codepoint);
    const len: usize = @intCast(pw.len);
    if (len + utf8_size + 1 >= pw.buffer_len)
        return;
    _ = unicode_mod.utf8Encode(
        @ptrCast(&pw.buffer.?[len]),
        codepoint,
    );
    pw.buffer.?[len + utf8_size] = 0;
    pw.len += @intCast(utf8_size);
}

// ── timer callbacks ──────────────────────────────────────────────────

fn setInputIdle(data: ?*anyopaque) callconv(.c) void {
    const state: *types.SwaylockState = @ptrCast(@alignCast(data));
    state.input_idle_timer = null;
    state.input_state = types.InputState.idle;
    damage_state(state);
}

fn setAuthIdle(data: ?*anyopaque) callconv(.c) void {
    const state: *types.SwaylockState = @ptrCast(@alignCast(data));
    state.auth_idle_timer = null;
    state.auth_state = types.AuthState.idle;
    damage_state(state);
}

fn scheduleInputIdle(state: *types.SwaylockState) void {
    if (state.input_idle_timer != null)
        _ = loop.loopRemoveTimer(
            state.eventloop.?,
            state.input_idle_timer.?,
        );
    state.input_idle_timer = loop.loopAddTimer(
        state.eventloop.?,
        1500,
        setInputIdle,
        state,
    );
}

fn cancelInputIdle(state: *types.SwaylockState) void {
    if (state.input_idle_timer != null) {
        _ = loop.loopRemoveTimer(
            state.eventloop.?,
            state.input_idle_timer.?,
        );
        state.input_idle_timer = null;
    }
}

pub fn scheduleAuthIdle(state: *types.SwaylockState) void {
    if (state.auth_idle_timer != null)
        _ = loop.loopRemoveTimer(
            state.eventloop.?,
            state.auth_idle_timer.?,
        );
    state.auth_idle_timer = loop.loopAddTimer(
        state.eventloop.?,
        3000,
        setAuthIdle,
        state,
    );
}

fn clearPassword(data: ?*anyopaque) callconv(.c) void {
    const state: *types.SwaylockState = @ptrCast(@alignCast(data));
    state.clear_password_timer = null;
    state.input_state = types.InputState.clear;
    scheduleInputIdle(state);
    password_buffer.clearPasswordBuffer(&state.password);
    damage_state(state);
}

fn schedulePasswordClear(state: *types.SwaylockState) void {
    if (state.clear_password_timer != null)
        _ = loop.loopRemoveTimer(
            state.eventloop.?,
            state.clear_password_timer.?,
        );
    state.clear_password_timer = loop.loopAddTimer(
        state.eventloop.?,
        10000,
        clearPassword,
        state,
    );
}

fn cancelPasswordClear(state: *types.SwaylockState) void {
    if (state.clear_password_timer != null) {
        _ = loop.loopRemoveTimer(
            state.eventloop.?,
            state.clear_password_timer.?,
        );
        state.clear_password_timer = null;
    }
}

// ── submit / highlight ───────────────────────────────────────────────

fn submitPassword(state: *types.SwaylockState) void {
    if (state.args.ignore_empty and state.password.len == 0) {
        log.slog(
            log_debug,
            @src(),
            "submit_password: skipped (ignore_empty)",
            .{},
        );
        return;
    }
    if (state.auth_state == types.AuthState.validating) {
        log.slog(
            log_debug,
            @src(),
            "submit_password: skipped (already validating)",
            .{},
        );
        return;
    }
    log.slog(
        log_debug,
        @src(),
        "submit_password: sending (len={d}) auth=idle -> validating",
        .{state.password.len},
    );
    state.input_state = types.InputState.idle;
    state.auth_state = types.AuthState.validating;
    cancelPasswordClear(state);
    cancelInputIdle(state);
    if (!comm.writeCommPassword(&state.password)) {
        log.slog(
            log_debug,
            @src(),
            "submit_password: write failed auth=validating -> invalid",
            .{},
        );
        state.auth_state = types.AuthState.invalid;
        scheduleAuthIdle(state);
    }
    damage_state(state);
}

fn updateHighlight(state: *types.SwaylockState) void {
    // Advance a random amount between 1/4 and 3/4 of a full turn.
    state.highlight_start =
        (state.highlight_start +
            @as(u32, @intCast(@rem(c.rand(), 1024))) + 512) % 2048;
}

// ── key handler ──────────────────────────────────────────────────────

pub fn swaylockHandleKey(
    state: *types.SwaylockState,
    keysym: wl.xkb_keysym_t,
    codepoint: u32,
) void {
    // In broker or auth-mode selection, Up/Down navigate the list
    // and Enter confirms. Tab presses the optional button.
    if (state.authd_active) {
        if (state.authd_stage == types.AuthdStage.broker or
            state.authd_stage == types.AuthdStage.auth_mode)
        {
            const is_broker =
                state.authd_stage == types.AuthdStage.broker;
            if (keysym == wl.XKB_KEY_Up) {
                if (is_broker) {
                    if (state.authd_sel_broker > 0)
                        state.authd_sel_broker -= 1;
                } else {
                    if (state.authd_sel_auth_mode > 0)
                        state.authd_sel_auth_mode -= 1;
                }
                damage_state(state);
                return;
            } else if (keysym == wl.XKB_KEY_Down) {
                if (is_broker) {
                    if (state.authd_sel_broker <
                        state.authd_num_brokers - 1)
                        state.authd_sel_broker += 1;
                } else {
                    if (state.authd_sel_auth_mode <
                        state.authd_num_auth_modes - 1)
                        state.authd_sel_auth_mode += 1;
                }
                damage_state(state);
                return;
            } else if (keysym == wl.XKB_KEY_Return or
                keysym == wl.XKB_KEY_KP_Enter)
            {
                if (is_broker) {
                    const sel = state.authd_sel_broker;
                    if (sel >= 0 and sel < state.authd_num_brokers) {
                        const id =
                            state.authd_brokers.?[@intCast(sel)].id;
                        if (id != null)
                            _ = comm.commMainWrite(
                                types.CommMsg.broker_sel,
                                id,
                                std.mem.len(id.?) + 1,
                            );
                    }
                } else {
                    const sel = state.authd_sel_auth_mode;
                    if (sel >= 0 and
                        sel < state.authd_num_auth_modes)
                    {
                        const id =
                            state.authd_auth_modes.?[
                                @intCast(sel)
                            ].id;
                        if (id != null)
                            _ = comm.commMainWrite(
                                types.CommMsg.auth_mode_sel,
                                id,
                                std.mem.len(id.?) + 1,
                            );
                    }
                }
                return;
            } else if (keysym == wl.XKB_KEY_Escape) {
                _ = comm.commMainWrite(types.CommMsg.cancel, null, 0);
                return;
            }
        }
        if (state.authd_stage == types.AuthdStage.challenge) {
            if (keysym == wl.XKB_KEY_Tab and
                state.authd_layout.button != null)
            {
                _ = comm.commMainWrite(types.CommMsg.button, null, 0);
                damage_state(state);
                return;
            }
        }
    }

    if (keysym == wl.XKB_KEY_KP_Enter or keysym == wl.XKB_KEY_Return) {
        submitPassword(state);
    } else if (keysym == wl.XKB_KEY_Delete or
        keysym == wl.XKB_KEY_BackSpace)
    {
        if (state.xkb.control) {
            password_buffer.clearPasswordBuffer(&state.password);
            state.input_state = types.InputState.clear;
            cancelPasswordClear(state);
        } else if (backspace(&state.password) and
            state.password.len != 0)
        {
            state.input_state = types.InputState.backspace;
            schedulePasswordClear(state);
            updateHighlight(state);
        } else {
            state.input_state = types.InputState.clear;
            cancelPasswordClear(state);
        }
        scheduleInputIdle(state);
        damage_state(state);
    } else if (keysym == wl.XKB_KEY_Escape) {
        password_buffer.clearPasswordBuffer(&state.password);
        state.input_state = types.InputState.clear;
        cancelPasswordClear(state);
        scheduleInputIdle(state);
        damage_state(state);
    } else if (keysym == wl.XKB_KEY_Caps_Lock or
        keysym == wl.XKB_KEY_Shift_L or
        keysym == wl.XKB_KEY_Shift_R or
        keysym == wl.XKB_KEY_Control_L or
        keysym == wl.XKB_KEY_Control_R or
        keysym == wl.XKB_KEY_Meta_L or
        keysym == wl.XKB_KEY_Meta_R or
        keysym == wl.XKB_KEY_Alt_L or
        keysym == wl.XKB_KEY_Alt_R or
        keysym == wl.XKB_KEY_Super_L or
        keysym == wl.XKB_KEY_Super_R)
    {
        state.input_state = types.InputState.neutral;
        schedulePasswordClear(state);
        scheduleInputIdle(state);
        damage_state(state);
    } else if ((keysym == wl.XKB_KEY_m or
        keysym == wl.XKB_KEY_d or
        keysym == wl.XKB_KEY_j) and state.xkb.control)
    {
        submitPassword(state);
    } else if ((keysym == wl.XKB_KEY_c or
        keysym == wl.XKB_KEY_u) and state.xkb.control)
    {
        password_buffer.clearPasswordBuffer(&state.password);
        state.input_state = types.InputState.clear;
        cancelPasswordClear(state);
        scheduleInputIdle(state);
        damage_state(state);
    } else {
        if (codepoint != 0) {
            appendCh(&state.password, codepoint);
            state.input_state = types.InputState.letter;
            schedulePasswordClear(state);
            scheduleInputIdle(state);
            updateHighlight(state);
            damage_state(state);
        }
    }
}
