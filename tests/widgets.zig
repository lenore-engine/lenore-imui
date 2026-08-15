const std = @import("std");
const imui = @import("lenore-imui");
const res = @import("lenore-resources");

const testing = std.testing;

const Canvas = imui.Canvas;
const DrawCommand = res.DrawCommand;
const Index = res.DrawIndex;
const ImageHandle = res.ImageHandle;
const Interaction = imui.Interaction;
const Rect = res.Rect;
const SliderRange = imui.SliderRange;
const Vertex = res.Vertex2D;

const image: ImageHandle = @enumFromInt(1);
const root: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 1000 };
const box: Rect = .{ .x = 10, .y = 10, .width = 100, .height = 20 };

fn colour(value: f32) res.PremultipliedColor {
    const channel: f16 = @floatCast(value);
    return .{ .rgba = .{ channel, channel, channel, 1 } };
}

const normal = colour(0.1);
const hovered = colour(0.2);
const held = colour(0.3);
const disabled = colour(0.4);
const border_colour = colour(0.5);
const focus_colour = colour(0.6);

const flat: imui.ButtonStyle = .{
    .normal_fill = normal,
    .hovered_fill = hovered,
    .held_fill = held,
    .disabled_fill = disabled,
    .border = border_colour,
    .radius = 6,
};

const bordered: imui.ButtonStyle = blk: {
    var style = flat;
    style.border_width = 2;
    style.focused_border = focus_colour;
    break :blk style;
};

const Fixture = struct {
    vertices: [512]Vertex = undefined,
    indices: [1024]Index = undefined,
    commands: [32]DrawCommand = undefined,
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

    // Whichever colour a vertex carries, as a single channel. Every style
    // above is a grey, so one channel identifies it.
    fn firstColour(self: *const Fixture) f32 {
        return @floatCast(self.vertices[0].colour.rgba[0]);
    }
};

fn hoveredState() Interaction {
    return .{ .hovered = true };
}

fn heldState() Interaction {
    return .{ .hovered = true, .capture = .primary };
}

test "a button wears the fill its state calls for, and held beats hovered" {
    var fixture: Fixture = .{};

    var canvas = try fixture.started();
    try imui.drawButton(&canvas, box, flat, .{}, true, image);
    try testing.expectApproxEqAbs(0.1, fixture.firstColour(), 1e-3);

    canvas = try fixture.started();
    try imui.drawButton(&canvas, box, flat, hoveredState(), true, image);
    try testing.expectApproxEqAbs(0.2, fixture.firstColour(), 1e-3);

    // A pointer held on a widget is on it by definition, so both flags are set
    // and the held fill is the one that shows.
    canvas = try fixture.started();
    try imui.drawButton(&canvas, box, flat, heldState(), true, image);
    try testing.expectApproxEqAbs(0.3, fixture.firstColour(), 1e-3);

    canvas = try fixture.started();
    try imui.drawButton(&canvas, box, flat, heldState(), false, image);
    try testing.expectApproxEqAbs(0.4, fixture.firstColour(), 1e-3);
}

test "a capture by another button does not press a widget down" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    var state = hoveredState();
    state.capture = .middle;
    try imui.drawButton(&canvas, box, flat, state, true, image);
    try testing.expectApproxEqAbs(0.2, fixture.firstColour(), 1e-3);
}

test "a borderless button is one shape and a bordered one is two" {
    var fixture: Fixture = .{};

    var canvas = try fixture.started();
    try imui.drawButton(&canvas, box, flat, .{}, true, image);
    const plain = canvas.vertexCount();

    canvas = try fixture.started();
    try imui.drawButton(&canvas, box, bordered, .{}, true, image);
    try testing.expectEqual(plain * 2, canvas.vertexCount());
}

test "the border is drawn under the fill, and focus replaces its colour" {
    var fixture: Fixture = .{};

    var canvas = try fixture.started();
    try imui.drawButton(&canvas, box, bordered, .{}, true, image);
    // The border goes down first, so the first vertex carries it.
    try testing.expectApproxEqAbs(0.5, fixture.firstColour(), 1e-3);

    canvas = try fixture.started();
    try imui.drawButton(&canvas, box, bordered, .{ .focused = true }, true, image);
    try testing.expectApproxEqAbs(0.6, fixture.firstColour(), 1e-3);

    // With no focused colour set, focus shows nothing rather than nothing
    // being drawn.
    var without = bordered;
    without.focused_border = null;
    canvas = try fixture.started();
    try imui.drawButton(&canvas, box, without, .{ .focused = true }, true, image);
    try testing.expectApproxEqAbs(0.5, fixture.firstColour(), 1e-3);
}

test "the two curves are concentric, so the inner radius is the outer one less the border" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    try imui.drawButton(&canvas, box, bordered, .{}, true, image);

    // The outer shape has radius six about (16, 16), so the inner one must
    // have radius four about the same point: an inner radius left at six
    // would bulge into the border and put its centre at (18, 18).
    const all = fixture.written(&canvas);
    const inner = all[all.len / 2 ..];
    var found = false;
    for (inner) |vertex| {
        if (@abs(vertex.position[0] - (box.x + 2)) <= 1e-3 and
            @abs(vertex.position[1] - (box.y + 2 + 4)) <= 1e-3) found = true;
    }
    try testing.expect(found);
}

test "the inner rectangle sits inside the border on every side" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    try imui.drawButton(&canvas, box, bordered, .{}, true, image);

    const all = fixture.written(&canvas);
    const inner = all[all.len / 2 ..];
    for (inner) |vertex| {
        try testing.expect(vertex.position[0] >= box.x + 2 - 1e-3);
        try testing.expect(vertex.position[1] >= box.y + 2 - 1e-3);
        try testing.expect(vertex.position[0] <= box.x + box.width - 2 + 1e-3);
        try testing.expect(vertex.position[1] <= box.y + box.height - 2 + 1e-3);
    }
}

test "a border past half the shorter side stops rather than inverting" {
    var fixture: Fixture = .{};

    var canvas = try fixture.started();
    try imui.drawButton(&canvas, box, bordered, .{}, true, image);
    const both = canvas.vertexCount();

    canvas = try fixture.started();
    var thick = bordered;
    thick.border_width = 1000;
    try imui.drawButton(&canvas, box, thick, .{}, true, image);

    // Clamped to ten, which is half the height, so the two edges meet and the
    // inner rectangle is empty. An empty rectangle draws nothing rather than
    // one with a negative extent, so the button is the border alone.
    try testing.expectEqual(both / 2, canvas.vertexCount());
    for (fixture.written(&canvas)) |vertex| {
        try testing.expect(vertex.position[1] >= box.y - 1e-3);
        try testing.expect(vertex.position[1] <= box.y + box.height + 1e-3);
    }
}

test "a border that is not finite is refused before anything is drawn" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();
    var broken = bordered;
    broken.border_width = std.math.nan(f32);
    try testing.expectError(error.InvalidGeometry, imui.drawButton(&canvas, box, broken, .{}, true, image));
    try testing.expectEqual(0, canvas.vertexCount());
}

test "a compound widget that runs out of room leaves nothing behind" {
    var fixture: Fixture = .{};
    var canvas = try Canvas.init(.{
        // Room for the border's fan and not for the fill's, which is what
        // makes the second of the two draws the one that fails.
        .vertices = fixture.vertices[0..25],
        .indices = &fixture.indices,
        .commands = &fixture.commands,
        .clips = &fixture.clips,
    });
    try canvas.begin(root);

    try testing.expectError(
        error.VertexCapacityExceeded,
        imui.drawButton(&canvas, box, bordered, .{}, true, image),
    );
    // The rollback is what stops a border being drawn with no fill inside it.
    try testing.expectEqual(0, canvas.vertexCount());
    try testing.expectEqual(0, canvas.commands().len);
}

test "a splitter is one quad and takes its fill from the gesture" {
    var fixture: Fixture = .{};
    const style: imui.SplitterStyle = .{
        .normal_fill = normal,
        .hovered_fill = hovered,
        .held_fill = held,
    };

    var canvas = try fixture.started();
    try imui.drawSplitter(&canvas, box, style, .{}, image);
    try testing.expectEqual(4, canvas.vertexCount());
    try testing.expectApproxEqAbs(0.1, fixture.firstColour(), 1e-3);

    canvas = try fixture.started();
    try imui.drawSplitter(&canvas, box, style, heldState(), image);
    try testing.expectApproxEqAbs(0.3, fixture.firstColour(), 1e-3);
}

test "an unchecked box draws its background and nothing more" {
    var fixture: Fixture = .{};
    const style: imui.CheckboxStyle = .{ .box = flat, .mark = colour(0.9), .mark_inset = 4 };

    var canvas = try fixture.started();
    try imui.drawCheckbox(&canvas, box, style, .{}, false, true, image);
    const empty = canvas.vertexCount();

    canvas = try fixture.started();
    try imui.drawCheckbox(&canvas, box, style, .{}, true, true, image);
    try testing.expect(canvas.vertexCount() > empty);
}

test "the mark sits inside the box by its inset" {
    var fixture: Fixture = .{};
    const style: imui.CheckboxStyle = .{ .box = flat, .mark = colour(0.9), .mark_inset = 4 };

    var canvas = try fixture.started();
    try imui.drawCheckbox(&canvas, box, style, .{}, true, true, image);

    for (fixture.written(&canvas)) |vertex| {
        if (@as(f32, @floatCast(vertex.colour.rgba[0])) < 0.8) continue;
        try testing.expect(vertex.position[0] >= box.x + 4 - 1e-3);
        try testing.expect(vertex.position[0] <= box.x + box.width - 4 + 1e-3);
    }
}

test "a slider draws its track and its knob" {
    var fixture: Fixture = .{};
    const style: imui.SliderStyle = .{
        .track = colour(0.7),
        .disabled_track = colour(0.8),
        .knob = flat,
        .track_thickness = 4,
        .knob_width = 12,
    };

    var canvas = try fixture.started();
    try imui.drawSlider(&canvas, box, style, .{}, 0, true, image);

    // The knob is flush with the left edge at zero and with the right at one.
    var leftmost: f32 = 1e9;
    for (fixture.written(&canvas)) |vertex| {
        if (@as(f32, @floatCast(vertex.colour.rgba[0])) > 0.6) continue;
        leftmost = @min(leftmost, vertex.position[0]);
    }
    try testing.expectApproxEqAbs(box.x, leftmost, 1e-3);

    canvas = try fixture.started();
    try imui.drawSlider(&canvas, box, style, .{}, 1, true, image);
    var rightmost: f32 = -1e9;
    for (fixture.written(&canvas)) |vertex| {
        if (@as(f32, @floatCast(vertex.colour.rgba[0])) > 0.6) continue;
        rightmost = @max(rightmost, vertex.position[0]);
    }
    try testing.expectApproxEqAbs(box.x + box.width, rightmost, 1e-3);
}

// The arithmetic below takes no canvas and no context, which is the reason it
// lives beside the drawing rather than in the façade above it.

const unit: SliderRange = .{ .min = 0, .max = 100 };

fn dragTo(x: f32) Interaction {
    return .{ .capture = .primary, .pointer = .{ .x = x, .y = 15 } };
}

test "a range with no interior is refused" {
    const state: Interaction = .{};
    try testing.expectError(error.InvalidRange, imui.sliderValue(0, box, 10, .{ .min = 1, .max = 1 }, state, true));
    try testing.expectError(error.InvalidRange, imui.sliderValue(0, box, 10, .{ .min = 2, .max = 1 }, state, true));
    try testing.expectError(error.InvalidRange, imui.sliderValue(
        0,
        box,
        10,
        .{ .min = 0, .max = std.math.nan(f32) },
        state,
        true,
    ));
    try testing.expectError(error.InvalidRange, imui.sliderValue(
        0,
        box,
        10,
        .{ .min = 0, .max = 1, .step = -1 },
        state,
        true,
    ));
    // And a value that is not finite, which would otherwise come back out of
    // the clamp as one of the bounds without anybody having asked.
    try testing.expectError(error.InvalidRange, imui.sliderValue(std.math.nan(f32), box, 10, unit, state, true));
}

test "a drag puts the value where the knob's middle is" {
    // The knob is twelve wide over a hundred, so the travel is eighty-eight
    // and the pointer is measured from six in.
    const left = try imui.sliderValue(50, box, 12, unit, dragTo(box.x + 6), true);
    try testing.expectApproxEqAbs(0, left, 1e-3);

    const right = try imui.sliderValue(50, box, 12, unit, dragTo(box.x + 6 + 88), true);
    try testing.expectApproxEqAbs(100, right, 1e-3);

    const middle = try imui.sliderValue(50, box, 12, unit, dragTo(box.x + 6 + 44), true);
    try testing.expectApproxEqAbs(50, middle, 1e-3);
}

test "a drag past either end is clamped rather than extrapolated" {
    try testing.expectApproxEqAbs(0, try imui.sliderValue(50, box, 12, unit, dragTo(-500), true), 1e-3);
    try testing.expectApproxEqAbs(100, try imui.sliderValue(50, box, 12, unit, dragTo(500), true), 1e-3);
}

test "letting go is still part of the drag" {
    var state = dragTo(box.x + 6 + 88);
    state.capture = null;
    state.capture_ended = .primary;
    try testing.expectApproxEqAbs(100, try imui.sliderValue(0, box, 12, unit, state, true), 1e-3);

    // A capture by another button is not a drag of the slider.
    var other = dragTo(box.x + 6 + 88);
    other.capture = .secondary;
    try testing.expectApproxEqAbs(0, try imui.sliderValue(0, box, 12, unit, other, true), 1e-3);
}

test "a knob as wide as the track has nowhere to travel" {
    const value = try imui.sliderValue(50, box, box.width, unit, dragTo(box.x + 90), true);
    try testing.expectApproxEqAbs(0, value, 1e-3);
}

test "the arrows move by one step and a continuous slider ignores them" {
    const stepped: SliderRange = .{ .min = 0, .max = 100, .step = 5 };
    const nudged: Interaction = .{ .adjust = 3 };
    try testing.expectApproxEqAbs(65, try imui.sliderValue(50, box, 12, stepped, nudged, true), 1e-3);

    const down: Interaction = .{ .adjust = -2 };
    try testing.expectApproxEqAbs(40, try imui.sliderValue(50, box, 12, stepped, down, true), 1e-3);

    // No step, so there is no distance an arrow could mean.
    try testing.expectApproxEqAbs(50, try imui.sliderValue(50, box, 12, unit, nudged, true), 1e-3);
}

test "the pointer and the keyboard are quantised together and not in turn" {
    const stepped: SliderRange = .{ .min = 0, .max = 100, .step = 10 };
    var both = dragTo(box.x + 6 + 44);
    both.adjust = 1;
    // The drag lands on 50 and the arrow adds 10, and the pair is snapped
    // once. Snapping the drag first would give the same answer here and a
    // different one wherever the drag lands off the grid.
    try testing.expectApproxEqAbs(60, try imui.sliderValue(0, box, 12, stepped, both, true), 1e-3);
}

test "a disabled slider keeps its value and still reports it on the grid" {
    const stepped: SliderRange = .{ .min = 0, .max = 100, .step = 10 };
    const dragging = dragTo(box.x + 90);
    try testing.expectApproxEqAbs(50, try imui.sliderValue(50, box, 12, stepped, dragging, false), 1e-3);
    try testing.expectApproxEqAbs(50, try imui.sliderValue(47, box, 12, stepped, .{}, false), 1e-3);
}

// The property the prototype's comment claimed and its arithmetic did not.
// With min 0, max 10 and step 3 it answered 9 for a value of 10, so `max` was
// not reachable; with step 4 it answered 10, which is not on the grid, and 8
// for 9.9, so the top of the range jumped. Neither is a rule that can be
// stated.
test "a step makes the reachable values exactly the grid inside the range" {
    const threes: SliderRange = .{ .min = 0, .max = 10, .step = 3 };
    const state: Interaction = .{};

    try testing.expectApproxEqAbs(9, try imui.sliderValue(10, box, 12, threes, state, true), 1e-4);
    try testing.expectApproxEqAbs(9, try imui.sliderValue(9.9, box, 12, threes, state, true), 1e-4);
    try testing.expectApproxEqAbs(9, try imui.sliderValue(8.9, box, 12, threes, state, true), 1e-4);
    try testing.expectApproxEqAbs(6, try imui.sliderValue(7.4, box, 12, threes, state, true), 1e-4);
    try testing.expectApproxEqAbs(0, try imui.sliderValue(-5, box, 12, threes, state, true), 1e-4);

    const fours: SliderRange = .{ .min = 0, .max = 10, .step = 4 };
    // Off the grid at the top, so the last reachable value is eight and there
    // is no jump to ten.
    try testing.expectApproxEqAbs(8, try imui.sliderValue(10, box, 12, fours, state, true), 1e-4);
    try testing.expectApproxEqAbs(8, try imui.sliderValue(9.9, box, 12, fours, state, true), 1e-4);

    // On the grid at the top, so it is reachable like any other grid point.
    const fives: SliderRange = .{ .min = 0, .max = 10, .step = 5 };
    try testing.expectApproxEqAbs(10, try imui.sliderValue(10, box, 12, fives, state, true), 1e-4);
}

test "a step grid is measured from the minimum and not from zero" {
    const offset: SliderRange = .{ .min = 1, .max = 10, .step = 3 };
    const state: Interaction = .{};
    // The grid is 1, 4, 7, 10.
    try testing.expectApproxEqAbs(4, try imui.sliderValue(4.4, box, 12, offset, state, true), 1e-4);
    try testing.expectApproxEqAbs(10, try imui.sliderValue(10, box, 12, offset, state, true), 1e-4);
}

test "the fraction a slider is drawn at is the value's place in the range" {
    try testing.expectApproxEqAbs(0, imui.sliderFraction(0, unit), 1e-4);
    try testing.expectApproxEqAbs(0.25, imui.sliderFraction(25, unit), 1e-4);
    try testing.expectApproxEqAbs(1, imui.sliderFraction(100, unit), 1e-4);
    // Outside the range it is still a fraction that can be drawn.
    try testing.expectApproxEqAbs(1, imui.sliderFraction(500, unit), 1e-4);
    try testing.expectApproxEqAbs(0, imui.sliderFraction(-500, unit), 1e-4);
}

// A label's face and its run, in whole numbers so that every position below is
// exact. The line gap is deliberately larger than the box it sits in, so a
// baseline computed from `lineHeight` rather than from the ink box is off by a
// distance no rounding could produce.
const ascent: f32 = 16;
const descent: f32 = -4;
const line_gap: f32 = 100;
const glyph_advance: f32 = 10;
const glyph_top: f32 = 12;

const face: res.FontMetrics = .{ .ascent = ascent, .descent = descent, .line_gap = line_gap };

const inked: res.GlyphPlacement = .{
    .left = 0,
    .top = glyph_top,
    .width = 8,
    .height = 14,
    .u_min = 0,
    .v_min = 0,
    .u_max = 0.125,
    .v_max = 0.125,
};

const run_glyphs = [_]res.ShapedGlyph{
    .{ .index = 1, .cluster = 0, .x_advance = glyph_advance, .y_advance = 0, .x_offset = 0, .y_offset = 0 },
    .{ .index = 2, .cluster = 1, .x_advance = glyph_advance, .y_advance = 0, .x_offset = 0, .y_offset = 0 },
    .{ .index = 3, .cluster = 2, .x_advance = glyph_advance, .y_advance = 0, .x_offset = 0, .y_offset = 0 },
};
const run_placements = [_]res.GlyphPlacement{ inked, inked, inked };

const caption: imui.Label = .{
    .run = .{ .glyphs = &run_glyphs, .placements = &run_placements, .buckets = .whole },
    .metrics = face,
    .advance = glyph_advance * run_glyphs.len,
    .atlas = image,
};

const plain_label: imui.LabelStyle = .{ .normal_text = normal, .disabled_text = disabled };

// Wide enough for the run three times over and tall enough for the line twice,
// so every alignment lands somewhere different.
const plate: Rect = .{ .x = 100, .y = 200, .width = 90, .height = 40 };

test "a label sits where its alignment puts it along the line" {
    var style = plain_label;

    style.horizontal = .start;
    try testing.expectApproxEqAbs(100, imui.labelBaseline(plate, style, caption).x, 1e-4);

    // Half the leftover space on each side: ninety wide against thirty of run.
    style.horizontal = .center;
    try testing.expectApproxEqAbs(130, imui.labelBaseline(plate, style, caption).x, 1e-4);

    style.horizontal = .end;
    try testing.expectApproxEqAbs(160, imui.labelBaseline(plate, style, caption).x, 1e-4);
}

test "a label sits where its alignment puts it across the line" {
    var style = plain_label;

    // The top edge plus the ascent, so the tallest letter starts at the edge.
    style.vertical = .top;
    try testing.expectApproxEqAbs(216, imui.labelBaseline(plate, style, caption).y, 1e-4);

    // The ink box is twenty tall in a rectangle of forty, so it starts ten
    // below the top edge and the baseline is sixteen below that.
    style.vertical = .middle;
    try testing.expectApproxEqAbs(226, imui.labelBaseline(plate, style, caption).y, 1e-4);

    // The bottom edge less the descent, which is negative and so lifts the
    // baseline by four rather than dropping it.
    style.vertical = .bottom;
    try testing.expectApproxEqAbs(236, imui.labelBaseline(plate, style, caption).y, 1e-4);
}

// What a layout node sized from a caption asks for, and the reason it is a
// method rather than a caller's subtraction: it has to be the same box
// `labelBaseline` centres the pen in, and the two are written apart.
test "a label's height is the box its own baseline is placed in" {
    // Twenty of ink box against the face's sixteen of ascent and four of
    // descent, and the descent is negative so the box is the difference.
    try testing.expectApproxEqAbs(20, caption.height(), 1e-4);

    // The gap is leading and no part of one line's box, which is the property
    // the baseline arithmetic already has: a face with a hundred of gap has the
    // same box as one with none.
    var gapless = caption;
    gapless.metrics.line_gap = 0;
    try testing.expectApproxEqAbs(caption.height(), gapless.height(), 1e-4);
    try testing.expect(caption.height() < caption.metrics.lineHeight());

    // The two agree by construction, which is the thing worth pinning: a
    // rectangle of exactly this height, aligned top or bottom, puts the
    // baseline in the same place, because neither has room to move it.
    var style = plain_label;
    const tight: Rect = .{ .x = plate.x, .y = plate.y, .width = plate.width, .height = caption.height() };
    style.vertical = .top;
    const from_top = imui.labelBaseline(tight, style, caption).y;
    style.vertical = .bottom;
    try testing.expectApproxEqAbs(from_top, imui.labelBaseline(tight, style, caption).y, 1e-4);
    style.vertical = .middle;
    try testing.expectApproxEqAbs(from_top, imui.labelBaseline(tight, style, caption).y, 1e-4);
}

test "the line gap is leading between lines and does not move a single one" {
    var style = plain_label;
    style.vertical = .middle;

    var gapless = caption;
    gapless.metrics.line_gap = 0;
    // A hundred of gap against none of it: centring on `lineHeight` would put
    // these fifty apart.
    try testing.expectApproxEqAbs(
        imui.labelBaseline(plate, style, gapless).y,
        imui.labelBaseline(plate, style, caption).y,
        1e-4,
    );
}

test "the glyphs are drawn on the baseline the alignment named" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();

    var style = plain_label;
    style.horizontal = .center;
    style.vertical = .middle;
    try imui.drawLabel(&canvas, plate, style, caption, true);

    const pen = imui.labelBaseline(plate, style, caption);
    const vertices = fixture.written(&canvas);
    try testing.expectEqual(12, vertices.len);
    // The corner of the first glyph: the pen, plus its bearing, flipped.
    try testing.expectApproxEqAbs(pen.x, vertices[0].position[0], 1e-4);
    try testing.expectApproxEqAbs(pen.y - glyph_top, vertices[0].position[1], 1e-4);
    // The last glyph starts two advances along, which is what says the run was
    // drawn from the pen rather than each glyph placed at it.
    try testing.expectApproxEqAbs(pen.x + 2 * glyph_advance, vertices[8].position[0], 1e-4);
}

test "a disabled label greys with the control it names" {
    var fixture: Fixture = .{};

    var canvas = try fixture.started();
    try imui.drawLabel(&canvas, plate, plain_label, caption, true);
    try testing.expectApproxEqAbs(0.1, fixture.firstColour(), 1e-3);

    canvas = try fixture.started();
    try imui.drawLabel(&canvas, plate, plain_label, caption, false);
    try testing.expectApproxEqAbs(0.4, fixture.firstColour(), 1e-3);
}

test "a label whose rectangle collapsed draws nothing, and one that is not finite is refused" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();

    const collapsed: Rect = .{ .x = plate.x, .y = plate.y, .width = 0, .height = plate.height };
    try imui.drawLabel(&canvas, collapsed, plain_label, caption, true);
    try testing.expectEqual(0, canvas.vertexCount());

    const nowhere: Rect = .{
        .x = std.math.nan(f32),
        .y = plate.y,
        .width = plate.width,
        .height = plate.height,
    };
    try testing.expectError(
        error.InvalidGeometry,
        imui.drawLabel(&canvas, nowhere, plain_label, caption, true),
    );
    try testing.expectEqual(0, canvas.vertexCount());
}

test "a run wider than its rectangle draws past it rather than being clipped" {
    var fixture: Fixture = .{};
    var canvas = try fixture.started();

    var style = plain_label;
    style.horizontal = .center;
    const narrow: Rect = .{ .x = plate.x, .y = plate.y, .width = 10, .height = plate.height };
    try imui.drawLabel(&canvas, narrow, style, caption, true);

    // Thirty of run centred in ten of rectangle starts ten to the left of it,
    // and every glyph is drawn: the widget pushes no clip of its own.
    const vertices = fixture.written(&canvas);
    try testing.expectEqual(12, vertices.len);
    try testing.expectApproxEqAbs(narrow.x - 10, vertices[0].position[0], 1e-4);
}
