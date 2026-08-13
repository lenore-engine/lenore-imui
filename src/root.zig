// Immediate-mode UI: per-frame region registration, event routing, drawing.
//
// It names no sibling module and no graphics API. The one thing it shares with
// whatever draws its output is the declarations in `types.zig`, which the
// renderer reads; nothing here reads anything of the renderer's.

const types = @import("types.zig");

pub const ConversionError = types.ConversionError;
pub const ImageHandle = types.ImageHandle;
pub const LinearPremultipliedColor = types.LinearPremultipliedColor;
pub const LogicalRect = types.LogicalRect;
pub const Rect = types.Rect;
pub const ScaleFactor = types.ScaleFactor;
pub const SrgbColor = types.SrgbColor;
pub const UvRect = types.UvRect;
pub const Vertex = types.Vertex;
