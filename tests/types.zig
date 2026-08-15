const std = @import("std");
const imui = @import("lenore-imui");
const res = @import("lenore-resources");

const testing = std.testing;

const LogicalRect = imui.LogicalRect;
const Point = imui.Point;
const ScaleFactor = imui.ScaleFactor;
const SrgbColor = imui.SrgbColor;

// f16 carries an eleven-bit significand, so a value near 1 is exact to about
// 5e-4. Everything compared here is a colour channel in [0, 1].
const f16_tolerance = 1e-3;

fn channelOf(colour: res.PremultipliedColor, channel: usize) f32 {
    return @floatCast(colour.rgba[channel]);
}

fn opaqueGrey(value: f32) res.PremultipliedColor {
    return (SrgbColor{ .r = value, .g = value, .b = value }).premultiplied();
}

test "a channel reaches the vertex as it was authored" {
    // The draw list is composited onto a picture already encoded for display,
    // so an authored channel is the value the display shows and nothing here
    // converts it. A transfer function applied on this path would put a glyph's
    // half-covered edge well above half the scale a reader sees.
    try testing.expectEqual(0, channelOf(opaqueGrey(0), 0));
    try testing.expectApproxEqAbs(1, channelOf(opaqueGrey(1), 0), f16_tolerance);
    try testing.expectApproxEqAbs(0.5, channelOf(opaqueGrey(0.5), 0), f16_tolerance);
    try testing.expectApproxEqAbs(0.04045, channelOf(opaqueGrey(0.04045), 0), f16_tolerance);
}

test "alpha multiplies the colour channels and is carried alongside" {
    const full = opaqueGrey(0.5);
    const washed = (SrgbColor{ .r = 0.5, .g = 0.5, .b = 0.5 }).withAlpha(0.5).premultiplied();

    try testing.expectApproxEqAbs(1, channelOf(full, 3), f16_tolerance);
    try testing.expectApproxEqAbs(0.5, channelOf(washed, 3), f16_tolerance);
    // Premultiplied: half the coverage is half the emitted colour.
    try testing.expectApproxEqAbs(channelOf(full, 0) * 0.5, channelOf(washed, 0), f16_tolerance);
}

test "a non-finite channel leaves the conversion as a bound, never as itself" {
    // This is what lets the draw list carry no per-vertex colour check, so it
    // is pinned here rather than left to `std.math.clamp` staying as it is.
    const nan = std.math.nan(f32);
    const poisoned = (SrgbColor{ .r = nan, .g = -1, .b = 2, .a = nan }).premultiplied();

    for (poisoned.rgba) |channel| {
        try testing.expect(std.math.isFinite(@as(f32, @floatCast(channel))));
    }
    // A NaN clamps to the upper bound, so the alpha is opaque and the red
    // channel is full rather than zero.
    try testing.expectApproxEqAbs(1, channelOf(poisoned, 3), f16_tolerance);
    try testing.expectApproxEqAbs(1, channelOf(poisoned, 0), f16_tolerance);
    try testing.expectEqual(0, channelOf(poisoned, 1));
}

test "hex authoring accepts both lengths and an optional hash" {
    const six = SrgbColor.fromHex("3366ff");
    const hashed = SrgbColor.fromHex("#3366ff");
    const eight = SrgbColor.fromHex("3366ff80");

    try testing.expectEqual(six.r, hashed.r);
    try testing.expectEqual(six.g, hashed.g);
    try testing.expectEqual(1, six.a);
    try testing.expectApproxEqAbs(@as(f32, 0x33) / 255.0, six.r, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0x66) / 255.0, six.g, 1e-6);
    try testing.expectApproxEqAbs(1, six.b, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0x80) / 255.0, eight.a, 1e-6);
}

test "a scale factor is rejected unless it is finite and positive" {
    try testing.expectError(error.InvalidScaleFactor, ScaleFactor.init(0, 1));
    try testing.expectError(error.InvalidScaleFactor, ScaleFactor.init(1, -1));
    try testing.expectError(error.InvalidScaleFactor, ScaleFactor.init(std.math.nan(f32), 1));
    try testing.expectError(error.InvalidScaleFactor, ScaleFactor.init(1, std.math.inf(f32)));

    const valid = try ScaleFactor.init(1.5, 1.5);
    try testing.expectEqual(1.5, valid.x);
}

test "a filled conversion covers at least what was asked for" {
    const scale = try ScaleFactor.init(1.5, 1.5);
    const logical: LogicalRect = .{ .x = 1, .y = 1, .width = 3, .height = 3 };
    const converted = try logical.toFramebufferFilled(scale);

    // 1 * 1.5 is 1.5 and 4 * 1.5 is 6, so the exact span is [1.5, 6] and the
    // conservative one is [1, 6].
    try testing.expectEqual(1, converted.x);
    try testing.expectEqual(1, converted.y);
    try testing.expectEqual(5, converted.width);
    try testing.expectEqual(5, converted.height);
    try testing.expect(converted.x <= logical.x * scale.x);
    try testing.expect(converted.x + converted.width >=
        (logical.x + logical.width) * scale.x);
}

test "adjacent logical rectangles leave no seam after conversion" {
    // The property the conservative rounding exists for: a row of panels that
    // touch in logical space must still touch in pixels, or the background
    // shows through between them.
    const scale = try ScaleFactor.init(1.25, 1.25);
    var edge: f32 = 0;
    while (edge < 40) : (edge += 1) {
        const left = try (LogicalRect{ .x = edge, .y = 0, .width = 1, .height = 1 })
            .toFramebufferFilled(scale);
        const right = try (LogicalRect{ .x = edge + 1, .y = 0, .width = 1, .height = 1 })
            .toFramebufferFilled(scale);
        try testing.expect(left.x + left.width >= right.x);
    }
}

test "a conversion refuses an invalid rectangle rather than clamping it" {
    const scale: ScaleFactor = .identity;
    try testing.expectError(
        error.InvalidLogicalRect,
        (LogicalRect{ .x = 0, .y = 0, .width = -1, .height = 1 }).toFramebufferFilled(scale),
    );
    try testing.expectError(
        error.InvalidLogicalRect,
        (LogicalRect{ .x = std.math.nan(f32), .y = 0, .width = 1, .height = 1 })
            .toFramebufferFilled(scale),
    );
}

test "a conversion that leaves the finite range is an error, not a saturation" {
    const scale = try ScaleFactor.init(std.math.floatMax(f32), 1);
    const wide: LogicalRect = .{ .x = 0, .y = 0, .width = std.math.floatMax(f32), .height = 1 };
    try testing.expectError(error.ConversionOverflow, wide.toFramebufferFilled(scale));
}

test "containment takes the near edges and not the far ones" {
    const rect: res.Rect = .{ .x = 10, .y = 20, .width = 30, .height = 40 };

    try testing.expect((Point{ .x = 10, .y = 20 }).isInside(rect));
    try testing.expect((Point{ .x = 39.999, .y = 59.999 }).isInside(rect));
    try testing.expect(!(Point{ .x = 40, .y = 40 }).isInside(rect));
    try testing.expect(!(Point{ .x = 20, .y = 60 }).isInside(rect));
    try testing.expect(!(Point{ .x = 9.999, .y = 40 }).isInside(rect));
}

// The property `Point.isInside` claims in place of a validity check, and the
// reason `Region.contains` checks no geometry. Every comparison it is built
// from is false for a NaN operand, and a negative extent puts the upper bound
// below the lower one.
test "containment is false rather than true where the geometry is ill-formed" {
    const nan = std.math.nan(f32);
    const sound: res.Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };

    try testing.expect(!(Point{ .x = nan, .y = 5 }).isInside(sound));
    try testing.expect(!(Point{ .x = 5, .y = nan }).isInside(sound));
    try testing.expect(!(Point{ .x = 5, .y = 5 }).isInside(.{ .x = nan, .y = 0, .width = 10, .height = 10 }));
    try testing.expect(!(Point{ .x = 5, .y = 5 }).isInside(.{ .x = 0, .y = 0, .width = nan, .height = 10 }));
    try testing.expect(!(Point{ .x = 5, .y = 5 }).isInside(.{ .x = 0, .y = 0, .width = -10, .height = -10 }));
}

test "an empty rectangle contains nothing, including its own corner" {
    const empty: res.Rect = .{ .x = 10, .y = 10, .width = 0, .height = 0 };
    try testing.expect(!(Point{ .x = 10, .y = 10 }).isInside(empty));
}
