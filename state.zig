//! state.zig – global state helpers.

const types = @import("types.zig");
const render = @import("render.zig");

/// Marks every surface dirty and re-renders it.
pub fn damageState(st: *types.State) void {
    for (st.surfaces.items) |surface| {
        surface.dirty = true;
        render.render(surface);
    }
}
