//! render.zig – Zig port of render.c.
//! Draws the swaylock lock indicator surfaces using Cairo.

const std = @import("std");
const math = std.math;
const opts = @import("render_options");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("wayland-client.h");
    @cInclude("cairo.h");
    @cInclude("background-image.h");
    if (opts.have_debug_overlay) @cDefine("HAVE_DEBUG_OVERLAY", "1");
    @cInclude("swaylock.h");
    @cInclude("log.h");
    if (opts.have_qrencode) @cInclude("qrencode.h");
});

const pi: f64 = math.pi;
/// Angular range of the typing indicator arc.
const type_indicator_range: f64 = pi / 3.0;
/// ARGB colour for authd error messages.
const error_text_color: u32 = 0xFF4444FF;

/// Cast any integer to f64 for Cairo coordinate arguments.
inline fn fd(x: anytype) f64 {
    return @floatFromInt(x);
}

fn set_color_for_state(
    cairo: ?*c.cairo_t,
    state: *c.swaylock_state,
    colorset: *c.swaylock_colorset,
) void {
    if (state.input_state == c.INPUT_STATE_CLEAR) {
        c.cairo_set_source_u32(cairo, colorset.cleared);
    } else if (state.auth_state == c.AUTH_STATE_VALIDATING) {
        c.cairo_set_source_u32(cairo, colorset.verifying);
    } else if (state.auth_state == c.AUTH_STATE_INVALID) {
        c.cairo_set_source_u32(cairo, colorset.wrong);
    } else if (state.xkb.caps_lock and
        state.args.show_caps_lock_indicator)
    {
        c.cairo_set_source_u32(cairo, colorset.caps_lock);
    } else if (state.xkb.caps_lock and
        !state.args.show_caps_lock_indicator and
        state.args.show_caps_lock_text)
    {
        const saved = state.args.colors.text.input;
        state.args.colors.text.input =
            state.args.colors.text.caps_lock;
        c.cairo_set_source_u32(cairo, colorset.input);
        state.args.colors.text.input = saved;
    } else {
        c.cairo_set_source_u32(cairo, colorset.input);
    }
}

fn surface_frame_handle_done(
    data: ?*anyopaque,
    callback: ?*c.wl_callback,
    time: u32,
) callconv(std.builtin.CallingConvention.c) void {
    _ = time;
    const surface: *c.swaylock_surface =
        @ptrCast(@alignCast(data));
    c.wl_callback_destroy(callback);
    surface.frame = null;
    render(surface);
}

const surface_frame_listener: c.wl_callback_listener = .{
    .done = surface_frame_handle_done,
};

fn render_debug_overlay(surface: *c.swaylock_surface) void {
    // The entire body is only analysed when the overlay feature is
    // enabled; Zig does not type-check unreachable comptime branches,
    // so the overlay-only fields on swaylock_surface are safe here.
    if (comptime opts.have_debug_overlay) {
        const state: *c.swaylock_state = @ptrCast(surface.state);
        if (surface.width == 0 or surface.height == 0) return;

        var count: c_int = 0;
        const lines = c.swaylock_log_get_overlay(&count);
        if (count == 0) return;

        const font_size: f64 = fd(surface.scale) * 12.0;
        c.cairo_select_font_face(
            state.test_cairo,
            state.args.font,
            c.CAIRO_FONT_SLANT_NORMAL,
            c.CAIRO_FONT_WEIGHT_NORMAL,
        );
        c.cairo_set_font_size(state.test_cairo, font_size);
        var fe: c.cairo_font_extents_t = undefined;
        c.cairo_font_extents(state.test_cairo, &fe);

        const pad: f64 = fd(surface.scale) * 4.0;
        const line_h: i32 = @intFromFloat(@ceil(fe.height + pad));
        const buf_w: i32 = @intCast(surface.width * @as(u32, @intCast(surface.scale)));
        const buf_h: i32 = @intCast(surface.height * @as(u32, @intCast(surface.scale)));

        const buf_ptr = c.get_next_buffer(
            state.shm,
            @as([*c]c.pool_buffer, @ptrCast(&surface.overlay_buffers)),
            @intCast(buf_w),
            @intCast(buf_h),
        );
        if (buf_ptr == null) return;
        const buf: *c.pool_buffer = @ptrCast(buf_ptr);

        const max_lines: i32 =
            if (line_h > 0) @divTrunc(buf_h, line_h) else 0;
        if (max_lines <= 0) return;
        const show: i32 = @min(count, max_lines);
        const start: i32 = count - show;

        const cr = buf.cairo;
        c.cairo_identity_matrix(cr);
        c.cairo_set_antialias(cr, c.CAIRO_ANTIALIAS_BEST);

        c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
        c.cairo_paint(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

        const text_h: i32 = show * line_h;
        const text_top: i32 = buf_h - text_h;
        c.cairo_set_source_rgba(cr, 0, 0, 0, 0.75);
        c.cairo_rectangle(cr, 0, fd(text_top), fd(buf_w), fd(text_h));
        c.cairo_fill(cr);

        c.cairo_select_font_face(
            cr,
            state.args.font,
            c.CAIRO_FONT_SLANT_NORMAL,
            c.CAIRO_FONT_WEIGHT_NORMAL,
        );
        c.cairo_set_font_size(cr, font_size);
        c.cairo_font_extents(cr, &fe);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 1);

        var y: f64 = fd(text_top) + fe.ascent + pad;
        var i: i32 = start;
        while (i < count) : (i += 1) {
            c.cairo_move_to(cr, pad, y);
            c.cairo_show_text(cr, @ptrCast(&lines[@intCast(i)]));
            y += fd(line_h);
        }

        c.wl_subsurface_set_position(surface.overlay_sub, 0, 0);
        c.wl_surface_set_buffer_scale(surface.overlay, surface.scale);
        c.wl_surface_attach(surface.overlay, buf.buffer, 0, 0);
        c.wl_surface_damage_buffer(
            surface.overlay,
            0,
            0,
            math.maxInt(i32),
            math.maxInt(i32),
        );
        c.wl_surface_commit(surface.overlay);
    }
}

export fn render(surface: *c.swaylock_surface) void {
    const state: *c.swaylock_state = @ptrCast(surface.state);
    const bw: i32 =
        @as(i32, @intCast(surface.width)) * surface.scale;
    const bh: i32 =
        @as(i32, @intCast(surface.height)) * surface.scale;
    if (bw == 0 or bh == 0) return;
    if (!surface.dirty or surface.frame != null) return;

    var need_destroy = false;
    var buffer: c.pool_buffer = undefined;

    if (bw != surface.last_buffer_width or
        bh != surface.last_buffer_height)
    {
        need_destroy = true;
        if (c.create_buffer(
            state.shm,
            &buffer,
            bw,
            bh,
            c.WL_SHM_FORMAT_ARGB8888,
        ) == null) {
            c._swaylock_log(
                c.LOG_ERROR,
                "Failed to create new buffer for " ++
                    "frame background.",
            );
            return;
        }

        const cr = buffer.cairo;
        c.cairo_set_antialias(cr, c.CAIRO_ANTIALIAS_BEST);
        c.cairo_save(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
        c.cairo_set_source_u32(cr, state.args.colors.background);
        c.cairo_paint(cr);
        if (surface.image != null and
            state.args.mode != c.BACKGROUND_MODE_SOLID_COLOR)
        {
            c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
            c.render_background_image(
                cr,
                surface.image,
                state.args.mode,
                bw,
                bh,
            );
        }
        c.cairo_restore(cr);
        c.cairo_identity_matrix(cr);

        c.wl_surface_attach(surface.surface, buffer.buffer, 0, 0);
        c.wl_surface_damage_buffer(
            surface.surface,
            0,
            0,
            math.maxInt(i32),
            math.maxInt(i32),
        );

        surface.last_buffer_width = bw;
        surface.last_buffer_height = bh;
    }

    // Scale may change independently of the wl_buffer dimensions.
    c.wl_surface_set_buffer_scale(surface.surface, surface.scale);
    _ = render_frame(surface);
    if (comptime opts.have_debug_overlay) {
        render_debug_overlay(surface);
    }
    surface.dirty = false;
    surface.frame = c.wl_surface_frame(surface.surface);
    _ = c.wl_callback_add_listener(
        surface.frame,
        &surface_frame_listener,
        surface,
    );
    c.wl_surface_commit(surface.surface);

    if (need_destroy) c.destroy_buffer(&buffer);
}

fn configure_font_drawing(
    cairo: ?*c.cairo_t,
    state: *c.swaylock_state,
    subpixel: c.wl_output_subpixel,
    arc_radius: i32,
) void {
    const fo = c.cairo_font_options_create() orelse return;
    defer c.cairo_font_options_destroy(fo);
    c.cairo_font_options_set_hint_style(fo, c.CAIRO_HINT_STYLE_FULL);
    c.cairo_font_options_set_antialias(fo, c.CAIRO_ANTIALIAS_SUBPIXEL);
    c.cairo_font_options_set_subpixel_order(fo, c.to_cairo_subpixel_order(subpixel));
    c.cairo_set_font_options(cairo, fo);
    c.cairo_select_font_face(
        cairo,
        state.args.font,
        c.CAIRO_FONT_SLANT_NORMAL,
        c.CAIRO_FONT_WEIGHT_NORMAL,
    );
    if (state.args.font_size > 0) {
        c.cairo_set_font_size(cairo, fd(state.args.font_size));
    } else {
        c.cairo_set_font_size(cairo, fd(arc_radius) / 3.0);
    }
}

fn render_frame(surface: *c.swaylock_surface) bool {
    const state: *c.swaylock_state = @ptrCast(surface.state);
    const scale: i32 = surface.scale;
    const arc_radius: i32 =
        @as(i32, @intCast(state.args.radius)) * scale;
    const arc_thickness: i32 =
        @as(i32, @intCast(state.args.thickness)) * scale;
    const buffer_diameter: i32 =
        (arc_radius + arc_thickness) * 2;

    // Broker / auth-mode stage: draw a vertical selection list
    // and return early — no ring is rendered for these stages.
    if (state.authd_active and (state.authd_stage == c.AUTHD_STAGE_BROKER or
        state.authd_stage == c.AUTHD_STAGE_AUTH_MODE))
    {
        const is_broker =
            state.authd_stage == c.AUTHD_STAGE_BROKER;
        const count: i32 = if (is_broker)
            state.authd_num_brokers
        else
            state.authd_num_auth_modes;
        const sel: i32 = if (is_broker)
            state.authd_sel_broker
        else
            state.authd_sel_auth_mode;

        configure_font_drawing(
            state.test_cairo,
            state,
            surface.subpixel,
            arc_radius,
        );
        var fe: c.cairo_font_extents_t = undefined;
        c.cairo_font_extents(state.test_cairo, &fe);

        const max_vis: i32 = 8;
        const vis_count: i32 = @min(count, max_vis);
        var start: i32 = 0;
        if (count > max_vis and sel >= 0) {
            start = sel - @divTrunc(max_vis, 2);
            if (start < 0) {
                start = 0;
            } else if (start + max_vis > count) {
                start = count - max_vis;
            }
        }

        const box_padding: f64 = 4.0 * fd(scale);
        const item_height: f64 = fe.height * 1.5;
        var max_text_w: f64 = 0;

        var mi: i32 = start;
        while (mi < start + vis_count) : (mi += 1) {
            const name: [*c]const u8 = if (is_broker)
                state.authd_brokers[@intCast(mi)].name
            else
                state.authd_auth_modes[@intCast(mi)].label;
            var ext: c.cairo_text_extents_t = undefined;
            c.cairo_text_extents(
                state.test_cairo,
                if (name != null) name else "",
                &ext,
            );
            if (ext.width > max_text_w) max_text_w = ext.width;
        }

        var buf_w: i32 = @intFromFloat(max_text_w + 4.0 * box_padding);
        var buf_h: i32 = @intFromFloat(fd(vis_count) * item_height + 2.0 * box_padding);
        buf_w += scale - @mod(buf_w, scale);
        buf_h += scale - @mod(buf_h, scale);

        const subsurf_xpos: i32 =
            if (state.args.override_indicator_x_position)
                @as(i32, @intCast(state.args.indicator_x_position)) -
                    @divTrunc(buf_w, 2 * scale)
            else
                @divTrunc(@as(i32, @intCast(surface.width)), 2) -
                    @divTrunc(buf_w, 2 * scale);
        const subsurf_ypos: i32 =
            if (state.args.override_indicator_y_position)
                @as(i32, @intCast(state.args.indicator_y_position)) -
                    @divTrunc(buf_h, 2 * scale)
            else
                @divTrunc(@as(i32, @intCast(surface.height)), 2) -
                    @divTrunc(buf_h, 2 * scale);

        const buf_ptr = c.get_next_buffer(
            state.shm,
            @as([*c]c.pool_buffer, @ptrCast(&surface.indicator_buffers)),
            @intCast(buf_w),
            @intCast(buf_h),
        );
        if (buf_ptr == null) {
            c._swaylock_log(c.LOG_ERROR, "No buffer");
            return false;
        }
        const buf: *c.pool_buffer = @ptrCast(buf_ptr);

        const cr = buf.cairo;
        c.cairo_set_antialias(cr, c.CAIRO_ANTIALIAS_BEST);
        c.cairo_identity_matrix(cr);

        c.cairo_save(cr);
        c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
        c.cairo_paint(cr);
        c.cairo_restore(cr);

        configure_font_drawing(cr, state, surface.subpixel, arc_radius);

        var vi: i32 = 0;
        while (vi < vis_count) : (vi += 1) {
            const idx = start + vi;
            const name: [*c]const u8 = if (is_broker)
                state.authd_brokers[@intCast(idx)].name
            else
                state.authd_auth_modes[@intCast(idx)].label;
            const safe_name: [*c]const u8 =
                if (name != null) name else "";
            var ext: c.cairo_text_extents_t = undefined;
            c.cairo_text_extents(cr, safe_name, &ext);

            const iy: f64 =
                box_padding + fd(vi) * item_height;

            c.cairo_rectangle(cr, 0, iy, fd(buf_w), item_height);
            if (idx == sel) {
                c.cairo_set_source_u32(
                    cr,
                    state.args.colors.layout_background,
                );
            } else {
                c.cairo_set_source_u32(cr, state.args.colors.background);
            }
            c.cairo_fill(cr);

            const tx: f64 =
                (fd(buf_w) - ext.width) / 2.0 -
                ext.x_bearing;
            const ty: f64 = iy +
                (item_height + fe.height) / 2.0 -
                fe.descent;
            c.cairo_move_to(cr, tx, ty);
            if (idx == sel) {
                c.cairo_set_source_u32(cr, state.args.colors.layout_text);
            } else {
                c.cairo_set_source_u32(cr, state.args.colors.text.input);
            }
            c.cairo_show_text(cr, safe_name);
        }

        c.wl_subsurface_set_position(surface.subsurface, subsurf_xpos, subsurf_ypos);
        c.wl_surface_set_buffer_scale(surface.child, scale);
        c.wl_surface_attach(surface.child, buf.buffer, 0, 0);
        c.wl_surface_damage_buffer(
            surface.child,
            0,
            0,
            math.maxInt(i32),
            math.maxInt(i32),
        );
        c.wl_surface_commit(surface.child);
        return true;
    }

    // Compute the text to draw, if any; this determines the
    // size and position of the indicator surface.
    var attempts_buf: [5]u8 = std.mem.zeroes([5]u8);
    var text: [*c]const u8 = null;
    var layout_text: [*c]const u8 = null;

    const draw_indicator = state.args.show_indicator and
        (state.auth_state != c.AUTH_STATE_IDLE or
            state.input_state != c.INPUT_STATE_IDLE or
            state.args.indicator_idle_visible);

    if (draw_indicator) {
        if (state.input_state == c.INPUT_STATE_CLEAR) {
            text = "Cleared";
        } else if (state.auth_state == c.AUTH_STATE_VALIDATING) {
            text = "Verifying";
        } else if (state.auth_state == c.AUTH_STATE_INVALID) {
            text = "Wrong";
        } else {
            // Caps Lock has higher display priority.
            if (state.xkb.caps_lock and
                state.args.show_caps_lock_text)
            {
                text = "Caps Lock";
            } else if (state.args.show_failed_attempts and
                state.failed_attempts > 0)
            {
                if (state.failed_attempts > 999) {
                    text = "999+";
                } else {
                    _ = std.fmt.bufPrint(
                        attempts_buf[0..4],
                        "{d}",
                        .{state.failed_attempts},
                    ) catch {};
                    text = @as([*c]const u8, @ptrCast(&attempts_buf));
                }
            }

            if (state.xkb.keymap != null) {
                const num_layout =
                    c.xkb_keymap_num_layouts(state.xkb.keymap);
                if (!state.args.hide_keyboard_layout and
                    (state.args.show_keyboard_layout or
                        num_layout > 1))
                {
                    var curr: c.xkb_layout_index_t = 0;
                    while (curr < num_layout and
                        c.xkb_state_layout_index_is_active(
                            state.xkb.state,
                            curr,
                            c.XKB_STATE_LAYOUT_EFFECTIVE,
                        ) != 1)
                    {
                        curr += 1;
                    }
                    layout_text =
                        c.xkb_keymap_layout_get_name(state.xkb.keymap, curr);
                }
            }
        }
    }

    // QR code layout replaces the ring entirely.
    const is_qrcode = state.authd_active and
        state.authd_stage == c.AUTHD_STAGE_CHALLENGE and
        state.authd_layout.type != null and
        c.strcmp(state.authd_layout.type, "qrcode") == 0;

    // Store the QR code as an opaque pointer so the variable exists
    // regardless of opts.have_qrencode; accessed only inside comptime
    // blocks where the concrete type is known.
    var qrcode_opaque: ?*anyopaque = null;
    defer if (comptime opts.have_qrencode) {
        if (qrcode_opaque) |p| {
            const qr: *c.QRcode = @ptrCast(p);
            c.QRcode_free(qr);
        }
    };
    if (comptime opts.have_qrencode) {
        if (is_qrcode and
            state.authd_layout.qr_content != null)
        {
            const qr = c.QRcode_encodeString(
                state.authd_layout.qr_content,
                0,
                c.QR_ECLEVEL_L,
                c.QR_MODE_8,
                1,
            );
            if (qr != null) qrcode_opaque = @ptrCast(qr);
        }
    }

    // Compute required buffer dimensions.
    var buffer_width: i32 = buffer_diameter;
    var buffer_height: i32 = buffer_diameter;

    if (is_qrcode) {
        var have_qr_image = false;
        if (comptime opts.have_qrencode) {
            if (qrcode_opaque) |qr_opaque| {
                const qr: *c.QRcode = @ptrCast(qr_opaque);
                const qr_px = qr.width * 4 * scale;
                buffer_width = qr_px;
                buffer_height = qr_px;
                have_qr_image = true;
            }
        }
        // Reserve height for the human-readable fallback code.
        if (state.authd_layout.qr_code != null and
            state.authd_layout.qr_code[0] != 0)
        {
            c.cairo_set_antialias(state.test_cairo, c.CAIRO_ANTIALIAS_BEST);
            configure_font_drawing(
                state.test_cairo,
                state,
                surface.subpixel,
                arc_radius,
            );
            var ext: c.cairo_text_extents_t = undefined;
            var fe: c.cairo_font_extents_t = undefined;
            c.cairo_text_extents(state.test_cairo, state.authd_layout.qr_code, &ext);
            c.cairo_font_extents(state.test_cairo, &fe);
            const box_padding: f64 = 4.0 * fd(scale);
            buffer_height += @intFromFloat(fe.height + 2.0 * box_padding);
            if (!have_qr_image and
                buffer_width < @as(i32, @intFromFloat(ext.width + 2.0 * box_padding)))
            {
                buffer_width = @intFromFloat(ext.width + 2.0 * box_padding);
            }
        }
        // Suppress the keyboard layout badge alongside a QR code.
        layout_text = null;
    } else {
        if (text != null or layout_text != null) {
            c.cairo_set_antialias(state.test_cairo, c.CAIRO_ANTIALIAS_BEST);
            configure_font_drawing(
                state.test_cairo,
                state,
                surface.subpixel,
                arc_radius,
            );
            if (text != null) {
                var ext: c.cairo_text_extents_t = undefined;
                c.cairo_text_extents(state.test_cairo, text, &ext);
                if (buffer_width < @as(i32, @intFromFloat(ext.width))) {
                    buffer_width = @intFromFloat(ext.width);
                }
            }
            if (layout_text != null) {
                var ext: c.cairo_text_extents_t = undefined;
                var fe: c.cairo_font_extents_t = undefined;
                const box_padding: f64 =
                    4.0 * fd(surface.scale);
                c.cairo_text_extents(state.test_cairo, layout_text, &ext);
                c.cairo_font_extents(state.test_cairo, &fe);
                buffer_height += @intFromFloat(fe.height + 2.0 * box_padding);
                if (buffer_width < @as(i32, @intFromFloat(ext.width + 2.0 * box_padding))) {
                    buffer_width = @intFromFloat(ext.width + 2.0 * box_padding);
                }
            }
        }
    }

    // Extra buffer space for CHALLENGE-stage authd elements:
    // a label box above the ring, a button box and error below.
    var label_box_h: f64 = 0;
    var button_box_h: f64 = 0;
    var error_h: f64 = 0;
    if (state.authd_active and
        state.authd_stage == c.AUTHD_STAGE_CHALLENGE)
    {
        c.cairo_set_antialias(state.test_cairo, c.CAIRO_ANTIALIAS_BEST);
        configure_font_drawing(
            state.test_cairo,
            state,
            surface.subpixel,
            arc_radius,
        );
        var fe: c.cairo_font_extents_t = undefined;
        c.cairo_font_extents(state.test_cairo, &fe);
        const box_padding: f64 = 4.0 * fd(scale);

        if (!is_qrcode and
            state.authd_layout.label != null and
            state.authd_layout.label[0] != 0)
        {
            var ext: c.cairo_text_extents_t = undefined;
            c.cairo_text_extents(state.test_cairo, state.authd_layout.label, &ext);
            label_box_h = fe.height + 2.0 * box_padding;
            buffer_height += @intFromFloat(label_box_h);
            if (buffer_width < @as(i32, @intFromFloat(ext.width + 2.0 * box_padding))) {
                buffer_width = @intFromFloat(ext.width + 2.0 * box_padding);
            }
        }
        if (!is_qrcode and
            state.authd_layout.button != null and
            state.authd_layout.button[0] != 0)
        {
            var ext: c.cairo_text_extents_t = undefined;
            c.cairo_text_extents(state.test_cairo, state.authd_layout.button, &ext);
            button_box_h = fe.height + 2.0 * box_padding;
            buffer_height += @intFromFloat(button_box_h);
            if (buffer_width < @as(i32, @intFromFloat(ext.width + 2.0 * box_padding))) {
                buffer_width = @intFromFloat(ext.width + 2.0 * box_padding);
            }
        }
        if (state.authd_error != null and
            state.authd_error[0] != 0)
        {
            var ext: c.cairo_text_extents_t = undefined;
            c.cairo_text_extents(state.test_cairo, state.authd_error, &ext);
            error_h = fe.height + box_padding;
            buffer_height += @intFromFloat(error_h);
            if (buffer_width < @as(i32, @intFromFloat(ext.width))) {
                buffer_width = @intFromFloat(ext.width);
            }
        }
    }

    // Buffer dimensions must be multiples of scale per protocol.
    buffer_height += scale - @mod(buffer_height, scale);
    buffer_width += scale - @mod(buffer_width, scale);

    var subsurf_xpos: i32 = undefined;
    var subsurf_ypos: i32 = undefined;
    if (is_qrcode) {
        subsurf_xpos =
            if (state.args.override_indicator_x_position)
                @as(i32, @intCast(state.args.indicator_x_position)) -
                    @divTrunc(buffer_width, 2 * scale)
            else
                @divTrunc(@as(i32, @intCast(surface.width)), 2) -
                    @divTrunc(buffer_width, 2 * scale);
        subsurf_ypos =
            if (state.args.override_indicator_y_position)
                @as(i32, @intCast(state.args.indicator_y_position)) -
                    @divTrunc(buffer_height, 2 * scale)
            else
                @divTrunc(@as(i32, @intCast(surface.height)), 2) -
                    @divTrunc(buffer_height, 2 * scale);
    } else {
        subsurf_xpos =
            if (state.args.override_indicator_x_position)
                @as(i32, @intCast(state.args.indicator_x_position)) -
                    @divTrunc(buffer_width, 2 * scale) +
                    @divTrunc(2, scale)
            else
                @divTrunc(@as(i32, @intCast(surface.width)), 2) -
                    @divTrunc(buffer_width, 2 * scale) +
                    @divTrunc(2, scale);
        subsurf_ypos =
            if (state.args.override_indicator_y_position)
                @as(i32, @intCast(state.args.indicator_y_position)) -
                    @as(i32, @intCast(state.args.radius +
                        state.args.thickness))
            else
                @divTrunc(@as(i32, @intCast(surface.height)), 2) -
                    @as(i32, @intCast(state.args.radius +
                        state.args.thickness));
        // Shift up so the ring stays centred when a label
        // box occupies space above it in the buffer.
        subsurf_ypos -=
            @as(i32, @intFromFloat(label_box_h / fd(scale)));
    }

    const buf_ptr = c.get_next_buffer(
        state.shm,
        @as([*c]c.pool_buffer, @ptrCast(&surface.indicator_buffers)),
        @intCast(buffer_width),
        @intCast(buffer_height),
    );
    if (buf_ptr == null) {
        c._swaylock_log(c.LOG_ERROR, "No buffer");
        return false;
    }
    const buf: *c.pool_buffer = @ptrCast(buf_ptr);

    const cairo = buf.cairo;
    c.cairo_set_antialias(cairo, c.CAIRO_ANTIALIAS_BEST);
    c.cairo_identity_matrix(cairo);

    // Clear to fully transparent.
    c.cairo_save(cairo);
    c.cairo_set_source_rgba(cairo, 0, 0, 0, 0);
    c.cairo_set_operator(cairo, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_paint(cairo);
    c.cairo_restore(cairo);

    if (is_qrcode) {
        configure_font_drawing(cairo, state, surface.subpixel, arc_radius);
        var fe: c.cairo_font_extents_t = undefined;
        c.cairo_font_extents(cairo, &fe);
        const box_padding: f64 = 4.0 * fd(scale);

        var qr_y: f64 = 0;
        var drew_qr = false;

        if (comptime opts.have_qrencode) {
            if (qrcode_opaque) |qr_opaque| {
                const qr: *c.QRcode = @ptrCast(qr_opaque);
                const mod_size: c_int = 4 * scale;
                const qr_px: c_int = qr.width * mod_size;
                const qr_x: c_int =
                    @divTrunc(buffer_width - qr_px, 2);

                // White background behind QR modules.
                c.cairo_rectangle(
                    cairo,
                    fd(qr_x),
                    0,
                    fd(qr_px),
                    fd(qr_px),
                );
                c.cairo_set_source_rgb(cairo, 1, 1, 1);
                c.cairo_fill(cairo);

                // Collect all dark modules then fill in one pass.
                c.cairo_set_source_rgb(cairo, 0, 0, 0);
                var row: c_int = 0;
                while (row < qr.width) : (row += 1) {
                    var col: c_int = 0;
                    while (col < qr.width) : (col += 1) {
                        const px = qr.data[
                            @intCast(row * qr.width + col)
                        ];
                        if (px & 1 == 0) continue;
                        c.cairo_rectangle(
                            cairo,
                            fd(qr_x + col * mod_size),
                            fd(row * mod_size),
                            fd(mod_size),
                            fd(mod_size),
                        );
                    }
                }
                c.cairo_fill(cairo);

                qr_y = fd(qr_px);
                drew_qr = true;
            }
        }

        if (state.authd_layout.qr_code != null and
            state.authd_layout.qr_code[0] != 0)
        {
            var ext: c.cairo_text_extents_t = undefined;
            c.cairo_text_extents(cairo, state.authd_layout.qr_code, &ext);
            const tx: f64 =
                (fd(buffer_width) - ext.width) / 2.0 -
                ext.x_bearing;
            var ty: f64 = undefined;
            if (drew_qr) {
                ty = qr_y + (fe.height - fe.descent) +
                    box_padding;
                qr_y += fe.height + 2.0 * box_padding;
            } else {
                // No QR image: centre the fallback text.
                ty = (fd(buffer_height) - error_h) / 2.0 +
                    (fe.height / 2.0 - fe.descent);
                qr_y = fd(buffer_height) - error_h;
            }
            c.cairo_move_to(cairo, tx, ty);
            c.cairo_set_source_u32(cairo, state.args.colors.layout_text);
            c.cairo_show_text(cairo, state.authd_layout.qr_code);
        }

        // Error text below QR content.
        if (error_h > 0) {
            var ext: c.cairo_text_extents_t = undefined;
            c.cairo_text_extents(cairo, state.authd_error, &ext);
            const tx: f64 =
                (fd(buffer_width) - ext.width) / 2.0 -
                ext.x_bearing;
            const ty: f64 = qr_y +
                (fe.height - fe.descent) +
                box_padding / 2.0;
            c.cairo_move_to(cairo, tx, ty);
            c.cairo_set_source_u32(cairo, error_text_color);
            c.cairo_show_text(cairo, state.authd_error);
        }
    } else if (draw_indicator) {
        configure_font_drawing(cairo, state, surface.subpixel, arc_radius);

        // Label box above the ring (CHALLENGE stage only).
        if (label_box_h > 0) {
            var fe: c.cairo_font_extents_t = undefined;
            var ext: c.cairo_text_extents_t = undefined;
            c.cairo_font_extents(cairo, &fe);
            c.cairo_text_extents(cairo, state.authd_layout.label, &ext);
            const box_padding: f64 = 4.0 * fd(scale);
            const bx: f64 = fd(buffer_width) / 2.0 -
                ext.width / 2.0 - box_padding;
            c.cairo_rectangle(
                cairo,
                bx,
                0,
                ext.width + 2.0 * box_padding,
                fe.height + 2.0 * box_padding,
            );
            c.cairo_set_source_u32(
                cairo,
                state.args.colors.layout_background,
            );
            c.cairo_fill_preserve(cairo);
            c.cairo_set_source_u32(cairo, state.args.colors.layout_border);
            c.cairo_stroke(cairo);
            c.cairo_move_to(
                cairo,
                bx - ext.x_bearing + box_padding,
                (fe.height - fe.descent) + box_padding,
            );
            c.cairo_set_source_u32(cairo, state.args.colors.layout_text);
            c.cairo_show_text(cairo, state.authd_layout.label);
            c.cairo_new_sub_path(cairo);
        }

        // Ring centre Y shifts down by the label height so
        // the ring stays visually centred on screen.
        const ring_cy: i32 =
            @as(i32, @intFromFloat(label_box_h)) +
            @divTrunc(buffer_diameter, 2);
        const cx: f64 = fd(@divTrunc(buffer_width, 2));

        // Fill inner circle.
        c.cairo_set_line_width(cairo, 0);
        c.cairo_arc(
            cairo,
            cx,
            fd(ring_cy),
            fd(arc_radius) -
                fd(@divTrunc(arc_thickness, 2)),
            0,
            2.0 * pi,
        );
        set_color_for_state(cairo, state, &state.args.colors.inside);
        c.cairo_fill_preserve(cairo);
        c.cairo_stroke(cairo);

        // Draw ring.
        c.cairo_set_line_width(cairo, fd(arc_thickness));
        c.cairo_arc(
            cairo,
            cx,
            fd(ring_cy),
            fd(arc_radius),
            0,
            2.0 * pi,
        );
        set_color_for_state(cairo, state, &state.args.colors.ring);
        c.cairo_stroke(cairo);

        // Draw status message.
        configure_font_drawing(cairo, state, surface.subpixel, arc_radius);
        set_color_for_state(cairo, state, &state.args.colors.text);

        if (text != null) {
            var ext: c.cairo_text_extents_t = undefined;
            var fe: c.cairo_font_extents_t = undefined;
            c.cairo_text_extents(cairo, text, &ext);
            c.cairo_font_extents(cairo, &fe);
            const x: f64 = cx -
                (ext.width / 2.0 + ext.x_bearing);
            const y: f64 = fd(ring_cy) +
                (fe.height / 2.0 - fe.descent);
            c.cairo_move_to(cairo, x, y);
            c.cairo_show_text(cairo, text);
            c.cairo_close_path(cairo);
            c.cairo_new_sub_path(cairo);
        }

        // Typing indicator: highlight a random arc on keypress.
        if (state.input_state == c.INPUT_STATE_LETTER or
            state.input_state == c.INPUT_STATE_BACKSPACE)
        {
            const hs: f64 =
                fd(state.highlight_start) * (pi / 1024.0);
            c.cairo_arc(
                cairo,
                cx,
                fd(ring_cy),
                fd(arc_radius),
                hs,
                hs + type_indicator_range,
            );
            if (state.input_state == c.INPUT_STATE_LETTER) {
                if (state.xkb.caps_lock and
                    state.args.show_caps_lock_indicator)
                {
                    c.cairo_set_source_u32(cairo, state.args.colors
                        .caps_lock_key_highlight);
                } else {
                    c.cairo_set_source_u32(
                        cairo,
                        state.args.colors.key_highlight,
                    );
                }
            } else {
                if (state.xkb.caps_lock and
                    state.args.show_caps_lock_indicator)
                {
                    c.cairo_set_source_u32(cairo, state.args.colors
                        .caps_lock_bs_highlight);
                } else {
                    c.cairo_set_source_u32(
                        cairo,
                        state.args.colors.bs_highlight,
                    );
                }
            }
            c.cairo_stroke(cairo);

            // Draw borders for the highlighted segment.
            const inner_radius: f64 =
                fd(buffer_diameter) / 2.0 -
                fd(arc_thickness) * 1.5;
            const outer_radius: f64 =
                fd(buffer_diameter) / 2.0 -
                fd(arc_thickness) / 2.0;
            const hs_end: f64 = hs + type_indicator_range;

            c.cairo_set_line_width(cairo, 2.0 * fd(scale));
            c.cairo_set_source_u32(cairo, state.args.colors.separator);
            c.cairo_move_to(
                cairo,
                cx + math.cos(hs) * inner_radius,
                fd(ring_cy) + math.sin(hs) * inner_radius,
            );
            c.cairo_line_to(
                cairo,
                cx + math.cos(hs) * outer_radius,
                fd(ring_cy) + math.sin(hs) * outer_radius,
            );
            c.cairo_stroke(cairo);

            c.cairo_move_to(
                cairo,
                cx + math.cos(hs_end) * inner_radius,
                fd(ring_cy) + math.sin(hs_end) * inner_radius,
            );
            c.cairo_line_to(
                cairo,
                cx + math.cos(hs_end) * outer_radius,
                fd(ring_cy) + math.sin(hs_end) * outer_radius,
            );
            c.cairo_stroke(cairo);
        }

        // Draw inner and outer borders of the ring.
        set_color_for_state(cairo, state, &state.args.colors.line);
        c.cairo_set_line_width(cairo, 2.0 * fd(scale));
        c.cairo_arc(
            cairo,
            cx,
            fd(ring_cy),
            fd(arc_radius) -
                fd(@divTrunc(arc_thickness, 2)),
            0,
            2.0 * pi,
        );
        c.cairo_stroke(cairo);
        c.cairo_arc(
            cairo,
            cx,
            fd(ring_cy),
            fd(arc_radius) +
                fd(@divTrunc(arc_thickness, 2)),
            0,
            2.0 * pi,
        );
        c.cairo_stroke(cairo);

        // Display keyboard layout badge.
        if (layout_text != null) {
            var ext: c.cairo_text_extents_t = undefined;
            var fe: c.cairo_font_extents_t = undefined;
            const box_padding: f64 = 4.0 * fd(scale);
            c.cairo_text_extents(cairo, layout_text, &ext);
            c.cairo_font_extents(cairo, &fe);
            const lbx: f64 = cx -
                ext.width / 2.0 - box_padding;
            const lby: f64 = fd(@as(i32, @intFromFloat(label_box_h)) +
                buffer_diameter);

            c.cairo_rectangle(
                cairo,
                lbx,
                lby,
                ext.width + 2.0 * box_padding,
                fe.height + 2.0 * box_padding,
            );
            c.cairo_set_source_u32(
                cairo,
                state.args.colors.layout_background,
            );
            c.cairo_fill_preserve(cairo);
            c.cairo_set_source_u32(cairo, state.args.colors.layout_border);
            c.cairo_stroke(cairo);
            c.cairo_move_to(
                cairo,
                lbx - ext.x_bearing + box_padding,
                lby + (fe.height - fe.descent) +
                    box_padding,
            );
            c.cairo_set_source_u32(cairo, state.args.colors.layout_text);
            c.cairo_show_text(cairo, layout_text);
            c.cairo_new_sub_path(cairo);
        }

        // CHALLENGE: button and/or error text below ring.
        if (button_box_h > 0 or error_h > 0) {
            var fe: c.cairo_font_extents_t = undefined;
            c.cairo_font_extents(cairo, &fe);
            const box_padding: f64 = 4.0 * fd(scale);

            // Start below the ring and optional layout badge.
            var y: f64 = fd(@as(i32, @intFromFloat(label_box_h)) +
                buffer_diameter);
            if (layout_text != null) {
                y += fe.height + 2.0 * box_padding;
            }

            if (button_box_h > 0) {
                var ext: c.cairo_text_extents_t = undefined;
                c.cairo_text_extents(
                    cairo,
                    state.authd_layout.button,
                    &ext,
                );
                const bw: f64 =
                    ext.width + 2.0 * box_padding;
                const bh: f64 =
                    fe.height + 2.0 * box_padding;
                const bx: f64 =
                    (fd(buffer_width) - bw) / 2.0;
                const corner: f64 = bh / 4.0;

                // Rounded rectangle for the button.
                c.cairo_new_sub_path(cairo);
                c.cairo_arc(
                    cairo,
                    bx + bw - corner,
                    y + corner,
                    corner,
                    -pi / 2.0,
                    0,
                );
                c.cairo_arc(
                    cairo,
                    bx + bw - corner,
                    y + bh - corner,
                    corner,
                    0,
                    pi / 2.0,
                );
                c.cairo_arc(
                    cairo,
                    bx + corner,
                    y + bh - corner,
                    corner,
                    pi / 2.0,
                    pi,
                );
                c.cairo_arc(
                    cairo,
                    bx + corner,
                    y + corner,
                    corner,
                    pi,
                    3.0 * pi / 2.0,
                );
                c.cairo_close_path(cairo);

                c.cairo_set_source_u32(
                    cairo,
                    state.args.colors.layout_background,
                );
                c.cairo_fill_preserve(cairo);
                c.cairo_set_line_width(cairo, 2.0 * fd(scale));
                c.cairo_set_source_u32(
                    cairo,
                    state.args.colors.layout_border,
                );
                c.cairo_stroke(cairo);

                c.cairo_move_to(
                    cairo,
                    bx - ext.x_bearing + box_padding,
                    y + (fe.height - fe.descent) +
                        box_padding,
                );
                c.cairo_set_source_u32(cairo, state.args.colors.layout_text);
                c.cairo_show_text(cairo, state.authd_layout.button);
                c.cairo_new_sub_path(cairo);

                y += button_box_h;
            }

            if (error_h > 0) {
                var ext: c.cairo_text_extents_t = undefined;
                c.cairo_text_extents(cairo, state.authd_error, &ext);
                const tx: f64 =
                    (fd(buffer_width) - ext.width) / 2.0 -
                    ext.x_bearing;
                const ty: f64 = y +
                    (fe.height - fe.descent) +
                    box_padding / 2.0;
                c.cairo_move_to(cairo, tx, ty);
                c.cairo_set_source_u32(cairo, error_text_color);
                c.cairo_show_text(cairo, state.authd_error);
                c.cairo_new_sub_path(cairo);
            }
        }
    }

    // Send Wayland requests.
    c.wl_subsurface_set_position(surface.subsurface, subsurf_xpos, subsurf_ypos);
    c.wl_surface_set_buffer_scale(surface.child, surface.scale);
    c.wl_surface_attach(surface.child, buf.buffer, 0, 0);
    c.wl_surface_damage_buffer(
        surface.child,
        0,
        0,
        math.maxInt(i32),
        math.maxInt(i32),
    );
    c.wl_surface_commit(surface.child);

    return true;
}
