//! Build script for swaylock. Compiles all C sources via the system
//! C compiler (cc) using addSystemCommand, with pkg-config supplying
//! system include paths. This avoids Zig 0.16's aro C-frontend bugs
//! that manifest in --listen=- server mode.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const have_pam = b.option(
        bool,
        "pam",
        "Use PAM for authentication (default: true)",
    ) orelse true;
    const have_gdk_pixbuf = b.option(
        bool,
        "gdk-pixbuf",
        "Enable gdk-pixbuf image loading (default: true)",
    ) orelse true;
    const have_qrencode = b.option(
        bool,
        "qrencode",
        "Enable QR code support (default: false)",
    ) orelse false;
    const debug_overlay = b.option(
        bool,
        "debug-overlay",
        "Render debug log overlay (default: false)",
    ) orelse false;
    const debug_unlock_on_crash = b.option(
        bool,
        "debug-unlock-on-crash",
        "Unlock on crash - dev only (default: false)",
    ) orelse false;

    const sysconfdir = b.option(
        []const u8,
        "sysconfdir",
        "System config directory",
    ) orelse b.graph.environ_map.get("SYSCONFDIR") orelse "/etc";

    const wl_proto_dir = b.option(
        []const u8,
        "wl-proto-dir",
        "wayland-protocols pkgdatadir",
    ) orelse b.graph.environ_map.get("WL_PROTOCOLS_PKGDATADIR")
        orelse "/usr/share/wayland-protocols";

    // Generate ext-session-lock-v1 protocol glue via wayland-scanner.
    const ext_lock_xml = b.fmt(
        "{s}/staging/ext-session-lock/ext-session-lock-v1.xml",
        .{wl_proto_dir},
    );

    const gen_proto_c = b.addSystemCommand(
        &.{ "wayland-scanner", "private-code" },
    );
    gen_proto_c.addArg(ext_lock_xml);
    const proto_c = gen_proto_c.addOutputFileArg(
        "ext-session-lock-v1-protocol.c",
    );

    const gen_proto_h = b.addSystemCommand(
        &.{ "wayland-scanner", "client-header" },
    );
    gen_proto_h.addArg(ext_lock_xml);
    const proto_h = gen_proto_h.addOutputFileArg(
        "ext-session-lock-v1-client-protocol.h",
    );
    const proto_h_dir = proto_h.dirname();

    // Query pkg-config for system include paths at configure time.
    // The list of packages varies with enabled features.
    var pc_args: std.ArrayList([]const u8) = .empty;
    pc_args.appendSlice(
        b.allocator,
        &.{ "pkg-config", "--cflags-only-I" },
    ) catch @panic("OOM");
    pc_args.appendSlice(
        b.allocator,
        &.{ "wayland-client", "cairo", "xkbcommon" },
    ) catch @panic("OOM");
    if (have_gdk_pixbuf)
        pc_args.append(b.allocator, "gdk-pixbuf-2.0") catch @panic("OOM");
    if (have_pam) {
        pc_args.append(b.allocator, "pam") catch @panic("OOM");
        pc_args.append(b.allocator, "libcjson") catch @panic("OOM");
    }
    if (have_qrencode)
        pc_args.append(b.allocator, "libqrencode") catch @panic("OOM");

    const pc_raw = b.run(
        pc_args.toOwnedSlice(b.allocator) catch @panic("OOM"),
    );

    // Parse whitespace-separated -I flags from pkg-config output.
    var sys_includes: std.ArrayList([]const u8) = .empty;
    var pc_tok = std.mem.tokenizeAny(u8, pc_raw, " \t\n\r");
    while (pc_tok.next()) |flag| {
        const f = std.mem.trim(u8, flag, " \t\n\r");
        if (f.len > 0)
            sys_includes.append(b.allocator, f) catch @panic("OOM");
    }

    // Full C flags: system includes first, then compile flags and
    // feature defines. include/config.h provides #ifndef-guarded
    // defaults; the -D flags here take precedence.
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, sys_includes.items) catch @panic("OOM");
    flags.appendSlice(b.allocator, &.{
        "-std=c11",
        "-D_POSIX_C_SOURCE=200809L",
        "-Wall",
        "-Wextra",
        "-Wno-unused-parameter",
        "-Wno-unused-result",
    }) catch @panic("OOM");
    flags.append(
        b.allocator,
        b.fmt("-DSYSCONFDIR=\"{s}\"", .{sysconfdir}),
    ) catch @panic("OOM");
    flags.append(
        b.allocator,
        "-DSWAYLOCK_VERSION=\"1.8.5\"",
    ) catch @panic("OOM");
    flags.append(
        b.allocator,
        if (have_gdk_pixbuf) "-DHAVE_GDK_PIXBUF=1" else "-DHAVE_GDK_PIXBUF=0",
    ) catch @panic("OOM");
    flags.append(
        b.allocator,
        if (have_qrencode) "-DHAVE_QRENCODE=1" else "-DHAVE_QRENCODE=0",
    ) catch @panic("OOM");
    flags.append(
        b.allocator,
        if (debug_overlay)
            "-DHAVE_DEBUG_OVERLAY=1"
        else
            "-DHAVE_DEBUG_OVERLAY=0",
    ) catch @panic("OOM");
    flags.append(
        b.allocator,
        if (debug_unlock_on_crash)
            "-DHAVE_DEBUG_UNLOCK_ON_CRASH=1"
        else
            "-DHAVE_DEBUG_UNLOCK_ON_CRASH=0",
    ) catch @panic("OOM");
    const c_flags = flags.toOwnedSlice(b.allocator) catch @panic("OOM");

    // Protocol glue only needs basic flags, no feature defines.
    var proto_flags_list: std.ArrayList([]const u8) = .empty;
    proto_flags_list.appendSlice(
        b.allocator, sys_includes.items,
    ) catch @panic("OOM");
    proto_flags_list.appendSlice(b.allocator,
        &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L" },
    ) catch @panic("OOM");
    const proto_flags =
        proto_flags_list.toOwnedSlice(b.allocator) catch @panic("OOM");

    // Ctx compiles a single C file via the system cc, bypassing Zig's
    // aro C frontend entirely. addPrefixedDirectoryArg resolves
    // LazyPaths at make time, so the generated protocol header becomes
    // a proper build-graph dependency.
    const Ctx = struct {
        b: *std.Build,
        proto_h_dir: std.Build.LazyPath,

        fn cobj(
            ctx: @This(),
            src: std.Build.LazyPath,
            name: []const u8,
            file_flags: []const []const u8,
        ) std.Build.LazyPath {
            const cmd = ctx.b.addSystemCommand(&.{ "cc", "-c" });
            // Local include dirs must come first so that #include "cairo.h"
            // and similar quoted includes resolve to our headers in include/,
            // not to same-named headers inside the system Cairo package.
            cmd.addPrefixedDirectoryArg("-I", ctx.b.path("include"));
            cmd.addPrefixedDirectoryArg("-I", ctx.proto_h_dir);
            for (file_flags) |flag| cmd.addArg(flag);
            cmd.addFileArg(src);
            cmd.addArg("-o");
            return cmd.addOutputFileArg(
                ctx.b.fmt("{s}.o", .{name}),
            );
        }
    };

    const ctx: Ctx = .{
        .b = b,
        .proto_h_dir = proto_h_dir,
    };

    // exe_mod carries library links; objects are added as LazyPaths
    // from the cc compilation steps above.
    const exe_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const c_sources = [_][]const u8{
        "background-image.c",
        "cairo.c",
        "comm.c",
        "log.c",
        "loop.c",
        "main.c",
        "password.c",
        "password-buffer.c",
        "pool-buffer.c",
        "seat.c",
        "unicode.c",
    };
    for (c_sources) |src| {
        exe_mod.addObjectFile(
            ctx.cobj(b.path(src), std.fs.path.stem(src), c_flags),
        );
    }

    // Compile render.zig as a Zig object; it replaces render.c.
    const render_options = b.addOptions();
    render_options.addOption(bool, "have_qrencode", have_qrencode);
    render_options.addOption(
        bool, "have_debug_overlay", debug_overlay);

    const render_mod = b.createModule(.{
        .root_source_file = b.path("render.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    render_mod.addImport(
        "render_options", render_options.createModule());
    render_mod.addIncludePath(b.path("include"));
    render_mod.addIncludePath(proto_h_dir);
    for (sys_includes.items) |flag| {
        const fi = std.mem.trim(u8, flag, " \t\n\r");
        if (std.mem.startsWith(u8, fi, "-I")) {
            const path = fi[2..];
            render_mod.addSystemIncludePath(
                .{ .cwd_relative = path });
            // Also add the parent so that e.g. <cairo/cairo.h>
            // resolves when pkg-config gives .../include/cairo.
            if (std.fs.path.dirname(path)) |parent| {
                render_mod.addSystemIncludePath(
                    .{ .cwd_relative = parent });
            }
        }
    }
    const render_obj = b.addObject(.{
        .name = "render",
        .root_module = render_mod,
    });
    exe_mod.addObjectFile(render_obj.getEmittedBin());

    exe_mod.addObjectFile(
        ctx.cobj(
            proto_c,
            "ext-session-lock-v1-protocol",
            proto_flags,
        ),
    );

    if (have_pam) {
        exe_mod.addObjectFile(
            ctx.cobj(b.path("pam.c"), "pam", c_flags),
        );
        exe_mod.linkSystemLibrary("pam", .{});
        exe_mod.linkSystemLibrary("libcjson", .{});
        if (have_qrencode)
            exe_mod.linkSystemLibrary("libqrencode", .{});
    } else {
        exe_mod.addObjectFile(
            ctx.cobj(b.path("shadow.c"), "shadow", c_flags),
        );
        // libcrypt is not a pkg-config package; link directly.
        exe_mod.linkSystemLibrary("crypt", .{ .use_pkg_config = .no });
    }

    exe_mod.linkSystemLibrary("wayland-client", .{});
    exe_mod.linkSystemLibrary("xkbcommon", .{});
    exe_mod.linkSystemLibrary("cairo", .{});
    if (have_gdk_pixbuf)
        exe_mod.linkSystemLibrary("gdk-pixbuf-2.0", .{});
    // libm and librt are glibc components that still need explicit
    // link flags in some configurations.
    exe_mod.linkSystemLibrary("m", .{ .use_pkg_config = .no });
    exe_mod.linkSystemLibrary("rt", .{ .use_pkg_config = .no });

    const exe = b.addExecutable(.{
        .name = "swaylock",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
}
