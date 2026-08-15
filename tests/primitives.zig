const std = @import("std");
const imui = @import("lenore-imui");
const res = @import("lenore-resources");

const testing = std.testing;

const Canvas = imui.Canvas;
const DrawCommand = res.DrawCommand;
const Index = res.DrawIndex;
const ImageHandle = res.ImageHandle;
const Rect = res.Rect;
const Vertex = res.Vertex2D;

const white: res.PremultipliedColor = .white;
const image: ImageHandle = @enumFromInt(1);
const root: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 1000 };

const Fixture = struct {
    // Two fans over, so that a merge has room to be observed.
    vertices: [64]Vertex = undefined,
    indices: [128]Index = undefined,
    commands: [8]DrawCommand = undefined,
    clips: [4]Rect = undefined,

    fn started(self: *Fixture) !Canvas {
        var result = try Canvas.init(.{
            .vertices = &self.vertices,
            .indices = &self.indices,
            .commands = &self.commands,
            .clips = &self.clips,
        });
        try result.begin(root);
        return result;
    }

    fn written(self: *const Fixture, canvas: *const Canvas) []const Vertex {
        return self.vertices[0..canvas.vertexCount()];
    }
};

// The fan is one middle vertex and both ends of each of four quarter arcs.
const fan_vertices = 4 * (4 + 1) + 1;
const fan_indices = (fan_vertices - 1) * 3;

const panel: Rect = .{ .x = 20, .y = 30, .width = 200, .height = 100 };
const radius: f32 = 12;

fn approx(a: f32, b: f32) bool {
    return @abs(a - b) <= 1e-3;
}

test "a rounded rectangle is one submission of a known size" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    try imui.addRoundedRect(&canvas, panel, radius, .{}, white, image);

    try testing.expectEqual(fan_vertices, canvas.vertexCount());
    try testing.expectEqual(fan_indices, canvas.indexCount());
    try testing.expectEqual(1, canvas.commands().len);
}

// The property the prototype's tessellation does not have. It samples four
// points per corner over the open interval, leaving the last 22.5 degrees of
// every quarter arc unsampled, so the shape is cut across each corner by a
// chord and never touches the middle of any edge. Sampling both ends is what
// makes the four straight edges the chords between corners.
test "the shape reaches every edge of the rectangle it was given" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    try imui.addRoundedRect(&canvas, panel, radius, .{}, white, image);

    var touches_left = false;
    var touches_right = false;
    var touches_top = false;
    var touches_bottom = false;
    for (fixture.written(&canvas)) |vertex| {
        if (approx(vertex.position[0], panel.x)) touches_left = true;
        if (approx(vertex.position[0], panel.x + panel.width)) touches_right = true;
        if (approx(vertex.position[1], panel.y)) touches_top = true;
        if (approx(vertex.position[1], panel.y + panel.height)) touches_bottom = true;
    }
    try testing.expect(touches_left);
    try testing.expect(touches_right);
    try testing.expect(touches_top);
    try testing.expect(touches_bottom);
}

test "the four tangent points where an edge meets its corners are all present" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    try imui.addRoundedRect(&canvas, panel, radius, .{}, white, image);

    const right = panel.x + panel.width;
    const bottom = panel.y + panel.height;
    const tangents = [_][2]f32{
        .{ panel.x + radius, panel.y }, // where the top edge leaves the top-left
        .{ right - radius, panel.y }, // where it meets the top-right
        .{ right, panel.y + radius }, // where the right edge leaves it
        .{ right, bottom - radius },
        .{ right - radius, bottom },
        .{ panel.x + radius, bottom },
        .{ panel.x, bottom - radius },
        .{ panel.x, panel.y + radius },
    };

    for (tangents) |wanted| {
        var found = false;
        for (fixture.written(&canvas)) |vertex| {
            if (approx(vertex.position[0], wanted[0]) and approx(vertex.position[1], wanted[1]))
                found = true;
        }
        try testing.expect(found);
    }
}

test "every perimeter vertex sits on the arc of one corner" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    try imui.addRoundedRect(&canvas, panel, radius, .{}, white, image);

    const centres = [4][2]f32{
        .{ panel.x + radius, panel.y + radius },
        .{ panel.x + panel.width - radius, panel.y + radius },
        .{ panel.x + panel.width - radius, panel.y + panel.height - radius },
        .{ panel.x + radius, panel.y + panel.height - radius },
    };

    // The first vertex is the middle of the fan and sits on no arc.
    for (fixture.written(&canvas)[1..]) |vertex| {
        var on_an_arc = false;
        for (centres) |centre| {
            const dx = vertex.position[0] - centre[0];
            const dy = vertex.position[1] - centre[1];
            if (approx(@sqrt(dx * dx + dy * dy), radius)) on_an_arc = true;
        }
        try testing.expect(on_an_arc);
    }
}

test "no vertex leaves the rectangle" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    try imui.addRoundedRect(&canvas, panel, radius, .{}, white, image);

    for (fixture.written(&canvas)) |vertex| {
        try testing.expect(vertex.position[0] >= panel.x - 1e-3);
        try testing.expect(vertex.position[1] >= panel.y - 1e-3);
        try testing.expect(vertex.position[0] <= panel.x + panel.width + 1e-3);
        try testing.expect(vertex.position[1] <= panel.y + panel.height + 1e-3);
    }
}

test "a radius past half the shorter side is clamped rather than refused" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    const squat: Rect = .{ .x = 0, .y = 0, .width = 200, .height = 20 };
    try imui.addRoundedRect(&canvas, squat, 1000, .{}, white, image);

    try testing.expectEqual(fan_vertices, canvas.vertexCount());
    for (fixture.written(&canvas)) |vertex| {
        try testing.expect(vertex.position[1] >= squat.y - 1e-3);
        try testing.expect(vertex.position[1] <= squat.y + squat.height + 1e-3);
    }
    // Clamped to ten, so the top-left arc reaches the middle of the short side.
    var reaches_middle = false;
    for (fixture.written(&canvas)) |vertex| {
        if (approx(vertex.position[0], squat.x) and approx(vertex.position[1], 10))
            reaches_middle = true;
    }
    try testing.expect(reaches_middle);
}

test "a radius under half a pixel takes the quad path instead of the fan" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    try imui.addRoundedRect(&canvas, panel, 0.49, .{}, white, image);

    try testing.expectEqual(4, canvas.vertexCount());
    try testing.expectEqual(6, canvas.indexCount());
}

test "a zero radius is a quad" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    try imui.addRoundedRect(&canvas, panel, 0, .{}, white, image);

    try testing.expectEqual(4, canvas.vertexCount());
}

test "the rectangle and the radius are both refused where they enter" {
    const nan = std.math.nan(f32);
    var fixture: Fixture = .{};
    var canvas = try fixture.started();

    // Neither the fan nor `addIndexed` re-checks the rectangle, and the empty
    // test cannot: `isEmpty` is a `<=` comparison, so a NaN extent reports
    // itself as non-empty and would reach the vertices.
    try testing.expectError(error.InvalidGeometry, imui.addRoundedRect(
        &canvas,
        .{ .x = 0, .y = 0, .width = nan, .height = 10 },
        4,
        .{},
        white,
        image,
    ));
    try testing.expectError(error.InvalidGeometry, imui.addRoundedRect(
        &canvas,
        .{ .x = nan, .y = 0, .width = 10, .height = 10 },
        4,
        .{},
        white,
        image,
    ));
    try testing.expectError(error.InvalidGeometry, imui.addRoundedRect(&canvas, panel, nan, .{}, white, image));
    try testing.expectError(error.InvalidGeometry, imui.addRoundedRect(&canvas, panel, -1, .{}, white, image));

    try testing.expectEqual(0, canvas.vertexCount());
}

test "an empty rectangle draws nothing and is not an error" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    try imui.addRoundedRect(&canvas, .{ .x = 5, .y = 5, .width = 0, .height = 20 }, 4, .{}, white, image);

    try testing.expectEqual(0, canvas.vertexCount());
    try testing.expectEqual(0, canvas.commands().len);
}

test "the geometry is mapped into the sub-image it was given" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    const sub: imui.UvRect = .{ .u0 = 0.25, .v0 = 0.5, .u1 = 0.75, .v1 = 1 };
    try imui.addRoundedRect(&canvas, panel, radius, sub, white, image);

    for (fixture.written(&canvas)) |vertex| {
        try testing.expect(vertex.uv[0] >= sub.u0 - 1e-4 and vertex.uv[0] <= sub.u1 + 1e-4);
        try testing.expect(vertex.uv[1] >= sub.v0 - 1e-4 and vertex.uv[1] <= sub.v1 + 1e-4);
    }
    // The middle of the shape is the middle of the sub-image.
    try testing.expect(approx(fixture.written(&canvas)[0].uv[0], 0.5));
    try testing.expect(approx(fixture.written(&canvas)[0].uv[1], 0.75));
}

test "a rounded rectangle merges with a neighbour sharing its image and clip" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    try imui.addRoundedRect(&canvas, panel, radius, .{}, white, image);
    try imui.addRoundedRect(&canvas, .{ .x = 300, .y = 30, .width = 100, .height = 100 }, radius, .{}, white, image);

    try testing.expectEqual(1, canvas.commands().len);
    try testing.expectEqual(fan_indices * 2, canvas.commands()[0].index_count);
}

// Positions alone do not say the shape is covered. The two tests below read the
// indices, which is where an unclosed ring or a triangle pointed at the wrong
// vertex shows up: a fan can carry every vertex in the right place and still
// leave a wedge of the shape untouched.
test "every perimeter vertex is used by exactly two triangles" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    try imui.addRoundedRect(&canvas, panel, radius, .{}, white, image);

    var uses = [_]u32{0} ** fan_vertices;
    var at: usize = 0;
    while (at < canvas.indexCount()) : (at += 3) {
        try testing.expectEqual(0, fixture.indices[at]);
        uses[fixture.indices[at + 1]] += 1;
        uses[fixture.indices[at + 2]] += 1;
    }

    // The middle is the first slot of every triangle and never an edge of one.
    try testing.expectEqual(0, uses[0]);
    for (uses[1..]) |count| {
        try testing.expectEqual(2, count);
    }
}

test "the triangles cover the area a rounded rectangle has" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    try imui.addRoundedRect(&canvas, panel, radius, .{}, white, image);

    var area: f64 = 0;
    var at: usize = 0;
    while (at < canvas.indexCount()) : (at += 3) {
        const a = fixture.vertices[fixture.indices[at]].position;
        const b = fixture.vertices[fixture.indices[at + 1]].position;
        const c = fixture.vertices[fixture.indices[at + 2]].position;
        area += 0.5 * @as(f64, (b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1]));
    }

    // The corners are inscribed polygons rather than arcs, so the figure is a
    // quarter-square less a fan of `n` isosceles triangles of half-angle
    // pi / 2n: each corner loses r^2 * (1 - (n / 2) * sin(pi / 2n)).
    const segments = 4.0;
    const lost = 1.0 - (segments / 2.0) * @sin(std.math.pi / (2.0 * segments));
    const expected = @as(f64, panel.width) * panel.height -
        4.0 * @as(f64, radius) * radius * lost;
    try testing.expectApproxEqRel(expected, @abs(area), 1e-5);

    // And it is an inscribed approximation of the true shape, so it is short of
    // the analytic area by that same amount and never over it.
    const exact = @as(f64, panel.width) * panel.height -
        (4.0 - std.math.pi) * @as(f64, radius) * radius;
    try testing.expect(@abs(area) < exact);
    try testing.expect(@abs(area) > exact * 0.99);
}
