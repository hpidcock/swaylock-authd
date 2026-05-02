//! Test root – importing a module here causes the Zig test
//! runner to discover and execute all test blocks within it.

comptime {
    _ = @import("unicode.zig");
    _ = @import("log.zig");
    _ = @import("background-image.zig");
    _ = @import("comm.zig");
    _ = @import("cairo.zig");
    _ = @import("loop.zig");
}
