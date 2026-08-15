const std = @import("std");
const res = @import("lenore-resources");
const canvas_mod = @import("canvas.zig");
const types = @import("types.zig");

const Canvas = canvas_mod.Canvas;
const Index = res.DrawIndex;
const PremultipliedColor = res.PremultipliedColor;
const Rect = res.Rect;
const UvRect = types.UvRect;
const Vertex = res.Vertex2D;

// Tessellation of the shapes a UI draws that a quad cannot express.
//
// Everything here reaches the arrays through `Canvas.addIndexed`, so a
// primitive is one submission that either lands whole or does not land: a
// tessellator never has to unwind its own partial write. Geometry is built in
// fixed stack arrays sized at compile time, which is what keeps a primitive
// allocation-free without an arena to hand it.

// Segments per quarter arc. A quarter arc of `n` segments departs from the true
// circle by at most `r * (1 - cos(pi / 4n))`, which at four segments is
// `0.0192 * r`: under half a pixel for any radius up to 26, and under a fifth of
// a pixel at the 4 to 12 pixels a panel or a button is actually drawn with.
//
// Fixed rather than derived from the radius. The vertex count is then a
// property of the shape and not of the resolution it is drawn at, so a frame
// costs the same on two displays, and the arrays below stay comptime-sized. A
// consumer that wants a 50-pixel radius changes this number.
const corner_segments = 4;

// Both ends of each quarter arc are sampled, which is what makes the four
// straight edges the chords between one corner's last vertex and the next
// corner's first. Dropping the far endpoint leaves 22.5 degrees of every corner
// unsampled and cuts the shape across it.
const corner_samples = corner_segments + 1;
const perimeter_count = corner_samples * 4;

// The unit circle sampled once, at compile time, in the order the perimeter is
// walked: the corners run top-left, top-right, bottom-right, bottom-left, and
// each spans a quarter turn from where the previous edge met it.
//
// Coordinates are the framebuffer's, so Y increases downward and the walk runs
// clockwise on screen. Nothing here depends on that: a draw list is not culled,
// having been built in one orientation with no back to face away.
const unit_offsets: [perimeter_count][2]f32 = blk: {
    const quarter = std.math.pi * 0.5;
    var result: [perimeter_count][2]f32 = undefined;
    for (0..4) |corner| {
        // The top-left corner opens at pi, where the left edge meets it, and
        // each later corner is a quarter turn further round.
        const start = std.math.pi + quarter * @as(f64, @floatFromInt(corner));
        for (0..corner_samples) |step| {
            const angle = start + quarter *
                @as(f64, @floatFromInt(step)) / @as(f64, corner_segments);
            result[corner * corner_samples + step] = .{
                @floatCast(@cos(angle)), @floatCast(@sin(angle)),
            };
        }
    }
    break :blk result;
};

// Below this the arc lies inside a single pixel, so the fan would spend 21
// vertices to draw the corners of a quad.
const min_visible_radius = 0.5;

// A filled rectangle with rounded corners, as one indexed submission.
//
// The rectangle and the radius both enter from application code, so both are
// validated here and nothing downstream re-checks them. That is what makes the
// division by the extents below safe: an empty rectangle has already returned
// and a non-finite one has already been refused, so the width and the height
// are finite and above zero by the time they are a denominator.
//
// The radius is clamped to half the shorter side rather than refused when it
// exceeds it. A layout that shrinks a panel below twice its corner radius has
// produced a smaller panel, not a fault, and the shape that answers is the one
// whose corners have run together.
pub fn addRoundedRect(
    canvas: *Canvas,
    rect: Rect,
    corner_radius: f32,
    uv: UvRect,
    colour: PremultipliedColor,
    image: res.ImageHandle,
) canvas_mod.Error!void {
    if (!rect.isValid()) return error.InvalidGeometry;
    if (!std.math.isFinite(corner_radius) or corner_radius < 0) return error.InvalidGeometry;
    if (rect.isEmpty()) return;

    const radius = @min(corner_radius, @min(rect.width, rect.height) * 0.5);
    if (radius < min_visible_radius) return canvas.addQuad(rect, uv, colour, image);

    const centres = [4][2]f32{
        .{ rect.x + radius, rect.y + radius },
        .{ rect.x + rect.width - radius, rect.y + radius },
        .{ rect.x + rect.width - radius, rect.y + rect.height - radius },
        .{ rect.x + radius, rect.y + rect.height - radius },
    };

    // A fan around the middle. It is the cheapest tessellation of a convex
    // shape and the shape is convex for every radius this accepts.
    var vertices: [perimeter_count + 1]Vertex = undefined;
    var indices: [perimeter_count * 3]Index = undefined;

    vertices[0] = .{
        .position = .{ rect.x + rect.width * 0.5, rect.y + rect.height * 0.5 },
        .uv = .{ (uv.u0 + uv.u1) * 0.5, (uv.v0 + uv.v1) * 0.5 },
        .colour = colour,
    };
    for (unit_offsets, 0..) |offset, step| {
        const centre = centres[step / corner_samples];
        const x = centre[0] + offset[0] * radius;
        const y = centre[1] + offset[1] * radius;
        vertices[step + 1] = .{
            .position = .{ x, y },
            .uv = .{
                uv.u0 + (x - rect.x) / rect.width * (uv.u1 - uv.u0),
                uv.v0 + (y - rect.y) / rect.height * (uv.v1 - uv.v0),
            },
            .colour = colour,
        };
        // Every triangle takes the middle and one edge of the perimeter, the
        // last wrapping to the first so the ring closes.
        indices[step * 3 + 0] = 0;
        indices[step * 3 + 1] = @intCast(step + 1);
        indices[step * 3 + 2] = @intCast((step + 1) % perimeter_count + 1);
    }

    // At the largest radius the shape accepts, two corners meet on the shorter
    // side and the edge between them is a chord of zero length. The triangle
    // over it has no area and rasterises nothing, which costs four such
    // triangles on a capsule and is cheaper than a branch that would find them.
    return canvas.addIndexed(&vertices, &indices, image);
}
