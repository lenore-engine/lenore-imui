const std = @import("std");
const imui = @import("lenore-imui");

const testing = std.testing;

const Rect = imui.Rect;
const LogicalRect = imui.LogicalRect;
const ScaleFactor = imui.ScaleFactor;
const SrgbColor = imui.SrgbColor;
const LinearPremultipliedColor = imui.LinearPremultipliedColor;
const Vertex = imui.Vertex;

// f16 carries an eleven-bit significand, so a value near 1 is exact to about
// 5e-4. Everything compared here is a colour channel in [0, 1].
const f16_tolerance = 1e-3;

fn linear(colour: LinearPremultipliedColor, channel: usize) f32 {
    return @floatCast(colour.rgba[channel]);
}

test "the vertex layout is the one the shader declares" {
    // Reading the layout is what analyses the comptime block inside `Vertex`.
    // Without a consumer that resolves the struct, those asserts never run.
    try testing.expectEqual(24, @sizeOf(Vertex));
    try testing.expectEqual(0, @offsetOf(Vertex, "position"));
    try testing.expectEqual(8, @offsetOf(Vertex, "uv"));
    try testing.expectEqual(16, @offsetOf(Vertex, "colour"));
}

test "the sRGB decode meets the specification at both ends and at its knee" {
    // Khronos Data Format Specification v1.3, 13.3.1. The endpoints are fixed
    // points of the function, and the knee is where the two branches meet:
    // 0.04045 / 12.92 is 0.0031308, which is the threshold section 13.3.2 uses
    // for the inverse.
    const black = LinearPremultipliedColor.fromSrgb(.{ .r = 0, .g = 0, .b = 0 });
    try testing.expectEqual(0, linear(black, 0));

    const white = LinearPremultipliedColor.fromSrgb(.{ .r = 1, .g = 1, .b = 1 });
    try testing.expectApproxEqAbs(1, linear(white, 0), f16_tolerance);

    const knee = LinearPremultipliedColor.fromSrgb(.{ .r = 0.04045, .g = 0, .b = 0 });
    try testing.expectApproxEqAbs(0.0031308, linear(knee, 0), 1e-5);

    const half = LinearPremultipliedColor.fromSrgb(.{ .r = 0.5, .g = 0, .b = 0 });
    try testing.expectApproxEqAbs(0.21404114, linear(half, 0), f16_tolerance);
}

test "the decode is monotonic across the branch boundary" {
    var previous: f32 = -1;
    var step: u16 = 0;
    while (step <= 255) : (step += 1) {
        const encoded = @as(f32, @floatFromInt(step)) / 255.0;
        const value = linear(LinearPremultipliedColor.fromSrgb(.{
            .r = encoded,
            .g = 0,
            .b = 0,
        }), 0);
        try testing.expect(value > previous);
        previous = value;
    }
}

test "alpha multiplies the colour channels and is carried alongside" {
    const opaque_half = LinearPremultipliedColor.fromSrgb(.{ .r = 0.5, .g = 0.5, .b = 0.5 });
    const washed = LinearPremultipliedColor.fromSrgb(
        (SrgbColor{ .r = 0.5, .g = 0.5, .b = 0.5 }).withAlpha(0.5),
    );

    try testing.expectApproxEqAbs(1, linear(opaque_half, 3), f16_tolerance);
    try testing.expectApproxEqAbs(0.5, linear(washed, 3), f16_tolerance);
    // Premultiplied: half the coverage is half the emitted colour.
    try testing.expectApproxEqAbs(
        linear(opaque_half, 0) * 0.5,
        linear(washed, 0),
        f16_tolerance,
    );
}

test "a non-finite channel leaves the conversion as a bound, never as itself" {
    // This is what lets the draw list carry no per-vertex colour check, so it
    // is pinned here rather than left to `std.math.clamp` staying as it is.
    const nan = std.math.nan(f32);
    const poisoned = LinearPremultipliedColor.fromSrgb(.{ .r = nan, .g = -1, .b = 2, .a = nan });

    for (poisoned.rgba) |channel| {
        try testing.expect(std.math.isFinite(@as(f32, @floatCast(channel))));
    }
    // A NaN clamps to the upper bound, so the alpha is opaque and the red
    // channel is full rather than zero.
    try testing.expectApproxEqAbs(1, linear(poisoned, 3), f16_tolerance);
    try testing.expectApproxEqAbs(1, linear(poisoned, 0), f16_tolerance);
    try testing.expectEqual(0, linear(poisoned, 1));
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

test "intersection nests and disjoint rectangles come back empty" {
    const parent: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const child: Rect = .{ .x = 50, .y = 50, .width = 100, .height = 100 };
    const nested = Rect.intersection(parent, child);
    try testing.expectEqual(50, nested.x);
    try testing.expectEqual(50, nested.width);
    try testing.expect(!nested.isEmpty());

    const elsewhere: Rect = .{ .x = 200, .y = 200, .width = 10, .height = 10 };
    const disjoint = Rect.intersection(parent, elsewhere);
    try testing.expect(disjoint.isEmpty());
    // An empty result never carries a negative extent, which a scissor would
    // have to reject rather than interpret.
    try testing.expect(disjoint.width >= 0 and disjoint.height >= 0);
}
