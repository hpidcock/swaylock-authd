//! allocator.zig – Process-wide allocator singletons.
//!
//! Provides three allocators for use across all Zig source:
//!   general()    – fixed-buffer in release, DebugAllocator in debug
//!   render()     – arena allocator, reset each frame
//!   c_ffi        – always c_allocator for C FFI boundaries
//!
//! Call init() once at process start and deinit() on clean exit.

const std = @import("std");
const builtin = @import("builtin");

const is_debug = builtin.mode == .Debug;

// ── General ───────────────────────────────────────────────────────

var da: std.heap.DebugAllocator(.{}) = .{};

/// 256 KiB static backing buffer for the fixed-buffer allocator.
var gen_buf: [256 * 1024]u8 = undefined;
var gen_fba: std.heap.FixedBufferAllocator = undefined;

// ── Render arena ──────────────────────────────────────────────────

/// In debug: a fresh DebugAllocator backs the arena each frame so
/// that resetRender() can deinit and check for leaks between frames.
/// In release: a plain ArenaAllocator backed by PageAllocator.
var render_da: std.heap.DebugAllocator(.{}) = .{};
var render_arena: std.heap.ArenaAllocator = undefined;

// ── Lifecycle ─────────────────────────────────────────────────────

/// Initialise all allocator singletons.
/// Must be called once before general() or render() are used.
pub fn init() void {
    gen_fba = .init(&gen_buf);
    if (is_debug) {
        render_da = .{};
        render_arena = .init(render_da.allocator());
    } else {
        render_arena = .init(std.heap.page_allocator);
    }
}

/// Release arena memory and check for leaks in debug builds.
pub fn deinit() void {
    render_arena.deinit();
    if (is_debug) {
        _ = render_da.deinit();
        _ = da.deinit();
    }
}

// ── Public allocators ─────────────────────────────────────────────

/// General-purpose allocator for non-render, non-FFI allocations.
/// Release: fixed-buffer over a 256 KiB static buffer.
/// Debug: DebugAllocator for leak and use-after-free detection.
pub fn general() std.mem.Allocator {
    return if (is_debug) da.allocator() else gen_fba.allocator();
}

/// Arena allocator for render-frame allocations.
/// Reset between frames by calling resetRender().
pub fn render() std.mem.Allocator {
    return render_arena.allocator();
}

/// Reset the render arena between frames.
/// Release: retains backing pages for reuse.
/// Debug: deinits the arena and its DebugAllocator to catch leaks,
/// then reinitialises both for the next frame.
pub fn resetRender() void {
    if (is_debug) {
        render_arena.deinit();
        _ = render_da.deinit();
        render_da = .{};
        render_arena = .init(render_da.allocator());
    } else {
        _ = render_arena.reset(.retain_capacity);
    }
}

/// Always use the C allocator for C FFI calls.
pub const c_ffi: std.mem.Allocator = std.heap.c_allocator;
