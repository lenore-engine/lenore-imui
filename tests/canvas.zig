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
const other_image: ImageHandle = @enumFromInt(2);
const root: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 1000 };

// The canvas holds slices, so a fixture is four arrays the test owns. Reading
// the geometry back means reading them, not asking the canvas for a view of
// memory it promises never to read.
const Fixture = struct {
    vertices: [64]Vertex = undefined,
    indices: [96]Index = undefined,
    commands: [8]DrawCommand = undefined,
    clips: [4]Rect = undefined,

    fn canvas(self: *Fixture) !Canvas {
        return Canvas.init(.{
            .vertices = &self.vertices,
            .indices = &self.indices,
            .commands = &self.commands,
            .clips = &self.clips,
        });
    }

    fn started(self: *Fixture) !Canvas {
        var result = try self.canvas();
        try result.begin(root);
        return result;
    }
};

fn unitQuad(x: f32) Rect {
    return .{ .x = x, .y = 0, .width = 10, .height = 10 };
}

test "storage with an empty array is refused where the budget was set" {
    var vertices: [4]Vertex = undefined;
    var indices: [6]Index = undefined;
    var commands: [1]DrawCommand = undefined;
    var clips: [1]Rect = undefined;

    try testing.expectError(error.EmptyStorage, Canvas.init(.{
        .vertices = &vertices,
        .indices = &indices,
        .commands = &commands,
        .clips = clips[0..0],
    }));
}

test "a non-finite root clip is refused rather than silently absorbed" {
    var fixture: Fixture = .{};
    var canvas = try fixture.canvas();
    try testing.expectError(error.InvalidGeometry, canvas.begin(.{
        .x = 0,
        .y = 0,
        .width = std.math.nan(f32),
        .height = 10,
    }));
}

test "a quad is four vertices, six indices and one draw" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    try canvas.addQuad(unitQuad(0), .{}, white, image);

    try testing.expectEqual(4, canvas.vertexCount());
    try testing.expectEqual(6, canvas.indexCount());
    try testing.expectEqual(1, canvas.commands().len);

    const written = fixture.vertices[0..canvas.vertexCount()];
    try testing.expectEqual([2]f32{ 0, 0 }, written[0].position);
    try testing.expectEqual([2]f32{ 10, 0 }, written[1].position);
    try testing.expectEqual([2]f32{ 10, 10 }, written[2].position);
    try testing.expectEqual([2]f32{ 0, 10 }, written[3].position);
    try testing.expectEqual([2]f32{ 0, 0 }, written[0].uv);
    try testing.expectEqual([2]f32{ 1, 1 }, written[2].uv);

    const draw = canvas.commands()[0];
    try testing.expectEqual(image, draw.image);
    try testing.expectEqual(0, draw.first_index);
    try testing.expectEqual(6, draw.index_count);
}

test "quads sharing an image and a clip become one draw" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    try canvas.addQuad(unitQuad(0), .{}, white, image);
    try canvas.addQuad(unitQuad(20), .{}, white, image);
    try canvas.addQuad(unitQuad(40), .{}, white, image);

    try testing.expectEqual(12, canvas.vertexCount());
    try testing.expectEqual(1, canvas.commands().len);
    try testing.expectEqual(18, canvas.commands()[0].index_count);

    // The second quad's indices address the whole list, not its own vertices.
    try testing.expectEqual(4, fixture.indices[6]);
}

test "a different image breaks the run, a different clip breaks it too" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();

    try canvas.addQuad(unitQuad(0), .{}, white, image);
    try canvas.addQuad(unitQuad(20), .{}, white, other_image);
    try testing.expectEqual(2, canvas.commands().len);

    try canvas.pushClip(.{ .x = 0, .y = 0, .width = 5, .height = 5 });
    try canvas.addQuad(unitQuad(40), .{}, white, other_image);
    canvas.popClip();
    try testing.expectEqual(3, canvas.commands().len);

    // Back at the root clip, and the last draw is under the narrower one, so
    // this cannot merge into it either.
    try canvas.addQuad(unitQuad(60), .{}, white, other_image);
    try testing.expectEqual(4, canvas.commands().len);
}

test "an empty rectangle is nothing to draw, not a fault" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    try canvas.addQuad(.{ .x = 0, .y = 0, .width = 0, .height = 10 }, .{}, white, image);

    try testing.expectEqual(0, canvas.vertexCount());
    try testing.expectEqual(0, canvas.commands().len);
}

test "geometry under a collapsed clip is discarded" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();

    try canvas.pushClip(.{ .x = 2000, .y = 2000, .width = 10, .height = 10 });
    try testing.expect(canvas.currentClip().isEmpty());
    try canvas.addQuad(unitQuad(0), .{}, white, image);
    canvas.popClip();

    try testing.expectEqual(0, canvas.vertexCount());
    try testing.expectEqual(0, canvas.commands().len);
}

test "a child clip can only narrow its parent" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();

    try canvas.pushClip(.{ .x = 10, .y = 10, .width = 100, .height = 100 });
    // Asking for more than the parent allows yields the parent's bound.
    try canvas.pushClip(.{ .x = 0, .y = 0, .width = 1000, .height = 1000 });

    const clip = canvas.currentClip();
    try testing.expectEqual(10, clip.x);
    try testing.expectEqual(100, clip.width);
}

test "the clip stack reports exhaustion rather than overrunning its array" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    // Four slots, one of which the root holds.
    try canvas.pushClip(root);
    try canvas.pushClip(root);
    try canvas.pushClip(root);
    try testing.expectError(error.ClipCapacityExceeded, canvas.pushClip(root));
}

test "an index outside the incoming vertices is refused" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();

    const vertices = [3]Vertex{
        .{ .position = .{ 0, 0 }, .uv = .{ 0, 0 }, .colour = white },
        .{ .position = .{ 1, 0 }, .uv = .{ 1, 0 }, .colour = white },
        .{ .position = .{ 0, 1 }, .uv = .{ 0, 1 }, .colour = white },
    };
    try testing.expectError(
        error.InvalidGeometry,
        canvas.addIndexed(&vertices, &.{ 0, 1, 3 }, image),
    );
    try testing.expectEqual(0, canvas.vertexCount());
}

test "a zero image handle is refused and names itself" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    try testing.expectError(
        error.InvalidImage,
        canvas.addQuad(unitQuad(0), .{}, white, .invalid),
    );
}

test "a refused append leaves the canvas exactly as it was" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();

    // Sixteen quads fill the vertex array of sixty-four exactly.
    for (0..16) |step| try canvas.addQuad(unitQuad(@floatFromInt(step * 20)), .{}, white, image);
    const before = canvas.checkpoint();

    try testing.expectError(
        error.VertexCapacityExceeded,
        canvas.addQuad(unitQuad(400), .{}, white, image),
    );
    try testing.expectEqual(before.vertex_count, canvas.vertexCount());
    try testing.expectEqual(before.index_count, canvas.indexCount());
    try testing.expectEqual(before.command_count, canvas.commands().len);
}

test "a rollback undoes a merge, not only the commands after it" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();

    try canvas.addQuad(unitQuad(0), .{}, white, image);
    const mark = canvas.checkpoint();
    // Merges into the draw above rather than adding one, so rewinding the
    // command count alone would leave its range covering rolled-back geometry.
    try canvas.addQuad(unitQuad(20), .{}, white, image);
    try testing.expectEqual(1, canvas.commands().len);
    try testing.expectEqual(12, canvas.commands()[0].index_count);

    canvas.restore(mark);
    try testing.expectEqual(4, canvas.vertexCount());
    try testing.expectEqual(6, canvas.indexCount());
    try testing.expectEqual(1, canvas.commands().len);
    try testing.expectEqual(6, canvas.commands()[0].index_count);
}

test "a rollback to an empty canvas removes the draw entirely" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();

    const mark = canvas.checkpoint();
    try canvas.addQuad(unitQuad(0), .{}, white, image);
    canvas.restore(mark);

    try testing.expectEqual(0, canvas.vertexCount());
    try testing.expectEqual(0, canvas.commands().len);
}

// Past where a narrow index would have stopped, and nothing happens.
//
// 65 536 is the ceiling a sixteen-bit index had, and until 2026-08-15 crossing
// it cut the list into segments: the draw after the boundary carried a base its
// indices were relative to, and it could not merge with the draw before. Both
// are gone, and this is what says so — one draw across the boundary, with the
// indices past it addressing the vertex array directly.
//
// The only test here that needs real capacity, because the boundary is a real
// number of vertices. The canvas still allocates nothing: the arrays are the
// caller's, as in every other fixture.
test "a list runs past the old index ceiling as one draw" {
    const allocator = testing.allocator;
    const past = 65536;

    const vertices = try allocator.alloc(Vertex, past + 8);
    defer allocator.free(vertices);
    const indices = try allocator.alloc(Index, 64);
    defer allocator.free(indices);
    var commands: [8]DrawCommand = undefined;
    var clips: [4]Rect = undefined;

    var canvas = try Canvas.init(.{
        .vertices = vertices,
        .indices = indices,
        .commands = &commands,
        .clips = &clips,
    });
    try canvas.begin(root);

    const filler = try allocator.alloc(Vertex, past);
    defer allocator.free(filler);
    @memset(filler, .{ .position = .{ 0, 0 }, .uv = .{ 0, 0 }, .colour = white });

    try canvas.addIndexed(filler, &.{ 0, 1, 2 }, image);
    try testing.expectEqual(1, canvas.commands().len);

    // The quad's vertices sit past the old ceiling, and it still merges: what
    // used to break the run was the segment boundary and nothing else.
    try canvas.addQuad(unitQuad(0), .{}, white, image);
    try testing.expectEqual(1, canvas.commands().len);
    try testing.expectEqual(9, canvas.commands()[0].index_count);

    // Absolute, not rebased: the quad's first corner is vertex 65 536, which is
    // the value a sixteen-bit index could not hold at all.
    try testing.expectEqual(past, indices[3]);
    try testing.expectEqual(past + 2, indices[5]);
    try testing.expect(past > std.math.maxInt(u16));
}
