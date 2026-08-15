const std = @import("std");
const imui = @import("lenore-imui");
const res = @import("lenore-resources");

const testing = std.testing;

const Canvas = imui.Canvas;
const DrawCommand = res.DrawCommand;
const GlyphPlacement = res.GlyphPlacement;
const GlyphRun = res.GlyphRun;
const Index = res.DrawIndex;
const ImageHandle = res.ImageHandle;
const Point = imui.Point;
const Rect = res.Rect;
const ShapedGlyph = res.ShapedGlyph;
const Vertex = res.Vertex2D;

const white: res.PremultipliedColor = .white;
const atlas: ImageHandle = @enumFromInt(1);
const root: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 1000 };

const Fixture = struct {
    vertices: [64]Vertex = undefined,
    indices: [96]Index = undefined,
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

// A letter of a monospaced face at sixteen pixels, in whole numbers so that
// every expected position below is exact: one texel of bearing, thirteen texels
// of it above the baseline, and a whole em of advance.
const bearing_left: f32 = 1;
const bearing_top: f32 = 13;
const ink_width: f32 = 16;
const ink_height: f32 = 17;
const em: f32 = 16;

const letter: GlyphPlacement = .{
    .left = bearing_left,
    .top = bearing_top,
    .width = ink_width,
    .height = ink_height,
    .u_min = 0.25,
    .v_min = 0.5,
    .u_max = 0.375,
    .v_max = 0.625,
};

fn glyph(index: u32, advance: f32) ShapedGlyph {
    return .{
        .index = index,
        .cluster = 0,
        .x_advance = advance,
        .y_advance = 0,
        .x_offset = 0,
        .y_offset = 0,
    };
}

test "the pen is a baseline and the glyph is placed above it" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();

    const glyphs = [_]ShapedGlyph{glyph(1, em)};
    const placements = [_]GlyphPlacement{letter};
    const pen: Point = .{ .x = 100, .y = 200 };
    try imui.addGlyphs(&canvas, .{ .glyphs = &glyphs, .placements = &placements, .buckets = .whole }, pen, white, atlas);

    const vertices = fixture.written(&canvas);
    try testing.expectEqual(4, vertices.len);

    // The flip: `top` is measured up from the baseline and Y increases
    // downward, so the ink starts above the pen and ends four texels below it.
    try testing.expectEqual(@as(f32, 101), vertices[0].position[0]);
    try testing.expectEqual(@as(f32, 187), vertices[0].position[1]);
    try testing.expectEqual(@as(f32, 117), vertices[2].position[0]);
    try testing.expectEqual(@as(f32, 204), vertices[2].position[1]);

    // The atlas is sampled the same way round: the glyph's first row is at
    // `v_min`, which belongs to the corner above the baseline.
    try testing.expectEqual([2]f32{ letter.u_min, letter.v_min }, vertices[0].uv);
    try testing.expectEqual([2]f32{ letter.u_max, letter.v_max }, vertices[2].uv);
}

test "a run of glyphs advances the pen and costs one draw" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();

    const glyphs = [_]ShapedGlyph{ glyph(1, em), glyph(2, em), glyph(3, em) };
    const placements = [_]GlyphPlacement{ letter, letter, letter };
    try imui.addGlyphs(
        &canvas,
        .{ .glyphs = &glyphs, .placements = &placements, .buckets = .whole },
        .{ .x = 0, .y = 100 },
        white,
        atlas,
    );

    const vertices = fixture.written(&canvas);
    try testing.expectEqual(12, vertices.len);
    for (0..3) |step| {
        const expected = em * @as(f32, @floatFromInt(step)) + bearing_left;
        try testing.expectEqual(expected, vertices[step * 4].position[0]);
    }

    // Every glyph samples one image under one clip, so the whole run is a
    // single command however many letters it holds.
    try testing.expectEqual(1, canvas.commands().len);
    try testing.expectEqual(18, canvas.commands()[0].index_count);
}

test "a glyph with no ink moves the pen and draws nothing" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();

    const glyphs = [_]ShapedGlyph{ glyph(1, em), glyph(2, em), glyph(3, em) };
    const placements = [_]GlyphPlacement{ letter, .blank, letter };
    try imui.addGlyphs(
        &canvas,
        .{ .glyphs = &glyphs, .placements = &placements, .buckets = .whole },
        .{ .x = 0, .y = 100 },
        white,
        atlas,
    );

    // Two letters with a space between them: eight vertices, and the second
    // letter two ems along rather than one.
    const vertices = fixture.written(&canvas);
    try testing.expectEqual(8, vertices.len);
    try testing.expectEqual(2 * em + bearing_left, vertices[4].position[0]);
}

test "a glyph lands on the pixel grid without the pen being snapped to it" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();

    // Half-pixel advances, which is what an ordinary face at an ordinary size
    // produces. Were each position snapped and then advanced from, the third
    // glyph would be a whole pixel out.
    const advance: f32 = 16.5;
    const glyphs = [_]ShapedGlyph{ glyph(1, advance), glyph(2, advance), glyph(3, advance) };
    const placements = [_]GlyphPlacement{ letter, letter, letter };
    try imui.addGlyphs(
        &canvas,
        .{ .glyphs = &glyphs, .placements = &placements, .buckets = .whole },
        .{ .x = 100.4, .y = 200.7 },
        white,
        atlas,
    );

    const vertices = fixture.written(&canvas);
    // Unrounded the pen reads 101.4, 117.9 and 134.4.
    try testing.expectEqual(@as(f32, 101), vertices[0].position[0]);
    try testing.expectEqual(@as(f32, 118), vertices[4].position[0]);
    try testing.expectEqual(@as(f32, 134), vertices[8].position[0]);

    // Every corner is a whole number on both axes, which is what makes the
    // atlas read back the texels it was written with.
    for (vertices) |vertex| {
        try testing.expectEqual(@round(vertex.position[0]), vertex.position[0]);
        try testing.expectEqual(@round(vertex.position[1]), vertex.position[1]);
    }
}

test "a run that does not fit leaves nothing behind" {
    var fixture: Fixture = .{};
    var canvas = try Canvas.init(.{
        // Room for one glyph and not two.
        .vertices = fixture.vertices[0..4],
        .indices = &fixture.indices,
        .commands = &fixture.commands,
        .clips = &fixture.clips,
    });
    try canvas.begin(root);

    const glyphs = [_]ShapedGlyph{ glyph(1, em), glyph(2, em) };
    const placements = [_]GlyphPlacement{ letter, letter };
    try testing.expectError(error.VertexCapacityExceeded, imui.addGlyphs(
        &canvas,
        .{ .glyphs = &glyphs, .placements = &placements, .buckets = .whole },
        .{ .x = 0, .y = 100 },
        white,
        atlas,
    ));

    // Half a word is worse than no word: the rollback takes the first glyph
    // back out with the one that failed.
    try testing.expectEqual(0, canvas.vertexCount());
    try testing.expectEqual(0, canvas.indexCount());
    try testing.expectEqual(0, canvas.commands().len);
}

test "a run whose halves disagree is refused rather than read past the end" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();

    const glyphs = [_]ShapedGlyph{ glyph(1, em), glyph(2, em) };
    const placements = [_]GlyphPlacement{letter};
    try testing.expectError(error.InvalidGeometry, imui.addGlyphs(
        &canvas,
        .{ .glyphs = &glyphs, .placements = &placements, .buckets = .whole },
        .{ .x = 0, .y = 100 },
        white,
        atlas,
    ));

    const nan = std.math.nan(f32);
    const pair = placements ++ placements;
    try testing.expectError(error.InvalidGeometry, imui.addGlyphs(
        &canvas,
        .{ .glyphs = &glyphs, .placements = &pair, .buckets = .whole },
        .{ .x = nan, .y = 100 },
        white,
        atlas,
    ));
    try testing.expectEqual(0, canvas.vertexCount());
}

// A glyph with no bearing, so a drawn position reads straight off the vertex,
// and a `u_min` that names which bucket it is. Four of them are one glyph's
// rasterisations, in bucket order.
fn bucketOf(index: u8) GlyphPlacement {
    return .{
        .left = 0,
        .top = bearing_top,
        .width = ink_width,
        .height = ink_height,
        .u_min = @as(f32, @floatFromInt(index)) / 8.0,
        .v_min = 0,
        .u_max = 1,
        .v_max = 1,
    };
}

const four_buckets = [_]GlyphPlacement{ bucketOf(0), bucketOf(1), bucketOf(2), bucketOf(3) };

// Advances of a quarter of a pixel, which is what four buckets resolve exactly.
// The pen reaches 0, 10.25, 20.5 and 30.75, and each of those is a whole pixel
// plus a bucket: base 0 at bucket 0, 10 at 1, 20 at 2, 30 at 3.
//
// Exact in f32, so nothing here is within a tolerance of the answer. Every
// value is a quarter, and a quarter is a binary fraction.
const quarter_advance: f32 = 10.25;

test "a fractional position picks the rasterisation made for that fraction" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();

    const glyphs = [_]ShapedGlyph{
        glyph(1, quarter_advance),
        glyph(1, quarter_advance),
        glyph(1, quarter_advance),
        glyph(1, quarter_advance),
    };
    const placements = four_buckets ++ four_buckets ++ four_buckets ++ four_buckets;
    try imui.addGlyphs(
        &canvas,
        .{ .glyphs = &glyphs, .placements = &placements, .buckets = .quarter },
        .{ .x = 0, .y = 100 },
        white,
        atlas,
    );

    const vertices = fixture.written(&canvas);
    try testing.expectEqual(16, vertices.len);

    const bases = [_]f32{ 0, 10, 20, 30 };
    for (bases, 0..) |base, index| {
        const corner = vertices[index * 4];
        try testing.expectEqual(base, corner.position[0]);
        // The bucket, read back off the placement that was chosen.
        try testing.expectEqual(bucketOf(@intCast(index)).u_min, corner.uv[0]);
        // And the two together are the position the shaper asked for, exactly:
        // a quarter of a pixel is a bucket, so nothing is lost.
        const drawn = base + @as(f32, @floatFromInt(index)) / 4.0;
        try testing.expectEqual(quarter_advance * @as(f32, @floatFromInt(index)), drawn);
    }
}

// The same run with one rasterisation, which is what the machinery above is
// measured against. Every position is rounded to a whole pixel, so the four
// pen positions a quarter apart become gaps of ten, eleven and ten: the run
// keeps its length and loses its rhythm.
test "one rasterisation quantises the gaps a fractional advance asks for" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();

    const glyphs = [_]ShapedGlyph{
        glyph(1, quarter_advance),
        glyph(1, quarter_advance),
        glyph(1, quarter_advance),
        glyph(1, quarter_advance),
    };
    const placements = [_]GlyphPlacement{ bucketOf(0), bucketOf(0), bucketOf(0), bucketOf(0) };
    try imui.addGlyphs(
        &canvas,
        .{ .glyphs = &glyphs, .placements = &placements, .buckets = .whole },
        .{ .x = 0, .y = 100 },
        white,
        atlas,
    );

    const vertices = fixture.written(&canvas);
    const drawn = [_]f32{ 0, 10, 21, 31 };
    for (drawn, 0..) |expected, index| {
        try testing.expectEqual(expected, vertices[index * 4].position[0]);
    }
}
