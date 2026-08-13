const std = @import("std");

// The geometry and colour the draw list is written in, and the whole of what
// the module that draws it has to agree with. Nothing here names a graphics
// API: the renderer reads these declarations, and that direction is what keeps
// the dependency from existing in the other one.
//
// Coordinates are framebuffer pixels, origin at the top left, Y increasing
// downward. That is the raster's own orientation and the one a scissor
// rectangle is expressed in, so a clip travels to the device without a flip. A
// resolution-independent coordinate is a `LogicalRect` and reaches this space
// only through an explicit `ScaleFactor`.

pub const ConversionError = error{
    InvalidLogicalRect,
    InvalidScaleFactor,

    // The product of two finite values is not finite. Reachable from a large
    // rectangle and a large scale, and it has to be an error rather than a
    // clamp: there is no framebuffer rectangle that means what the caller asked
    // for.
    ConversionOverflow,
};

// Per-axis logical-to-framebuffer scale.
//
// There is deliberately no process-global DPI. Every conversion carries the
// metrics snapshot it was made against, so a window that has moved between two
// outputs cannot convert against the scale of the one it left.
pub const ScaleFactor = struct {
    x: f32,
    y: f32,

    pub const identity: ScaleFactor = .{ .x = 1, .y = 1 };

    pub fn init(x: f32, y: f32) ConversionError!ScaleFactor {
        const factor: ScaleFactor = .{ .x = x, .y = y };
        try factor.validate();
        return factor;
    }

    // A scale enters from the window, which is outside this module, so it is
    // checked here and by nothing downstream. Zero is refused along with the
    // negatives: it collapses every rectangle to nothing, which reads as a
    // missing UI rather than as a bad scale.
    pub fn validate(self: ScaleFactor) ConversionError!void {
        if (!std.math.isFinite(self.x) or !std.math.isFinite(self.y) or
            self.x <= 0 or self.y <= 0) return error.InvalidScaleFactor;
    }
};

// A rectangle in framebuffer pixels.
//
// Validity is established where a rectangle enters from outside and is not
// re-checked afterwards. That matters more here than the predicate suggests:
// `isEmpty` is a `<=` comparison, so a NaN extent reports itself as non-empty,
// and `intersection` is built from `@min` and `@max`, which return the operand
// that is not NaN. A NaN therefore does not propagate and does not announce
// itself either. It is stopped at the boundary or not at all.
pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub const zero: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

    pub fn isValid(self: Rect) bool {
        return std.math.isFinite(self.x) and std.math.isFinite(self.y) and
            std.math.isFinite(self.width) and std.math.isFinite(self.height) and
            self.width >= 0 and self.height >= 0;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.width <= 0 or self.height <= 0;
    }

    // Clipping is intersection only, so a child can never draw outside its
    // parent. A disjoint pair yields an empty rectangle at the near corner
    // rather than a negative extent.
    pub fn intersection(a: Rect, b: Rect) Rect {
        const left = @max(a.x, b.x);
        const top = @max(a.y, b.y);
        const right = @min(a.x + a.width, b.x + b.width);
        const bottom = @min(a.y + a.height, b.y + b.height);
        return .{
            .x = left,
            .y = top,
            .width = @max(right - left, 0),
            .height = @max(bottom - top, 0),
        };
    }
};

// A rectangle in the resolution-independent space a caller lays out in.
pub const LogicalRect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn isValid(self: LogicalRect) bool {
        return std.math.isFinite(self.x) and std.math.isFinite(self.y) and
            std.math.isFinite(self.width) and std.math.isFinite(self.height) and
            self.width >= 0 and self.height >= 0;
    }

    // Minima round down and maxima round up, so the result covers at least the
    // area that was asked for. Under a fractional scale the alternative loses
    // an edge pixel of a filled rectangle, and a row of panels converted that
    // way shows the background through the seams between them.
    //
    // This is the conversion for something being filled. A stroke or a text
    // origin wants its own rule and does not have one yet.
    pub fn toFramebufferFilled(self: LogicalRect, scale: ScaleFactor) ConversionError!Rect {
        if (!self.isValid()) return error.InvalidLogicalRect;
        try scale.validate();

        const left = @floor(self.x * scale.x);
        const top = @floor(self.y * scale.y);
        const right = @ceil((self.x + self.width) * scale.x);
        const bottom = @ceil((self.y + self.height) * scale.y);
        if (!std.math.isFinite(left) or !std.math.isFinite(top) or
            !std.math.isFinite(right) or !std.math.isFinite(bottom))
            return error.ConversionOverflow;

        return .{
            .x = left,
            .y = top,
            .width = right - left,
            .height = bottom - top,
        };
    }
};

// The sub-image a quad samples, as normalised coordinates. The default is the
// whole image, which is what a solid fill against the white image wants.
pub const UvRect = struct {
    u0: f32 = 0,
    v0: f32 = 0,
    u1: f32 = 1,
    v1: f32 = 1,
};

// Colour as a theme authors it: straight alpha, sRGB encoded.
//
// Kept apart from the linear premultiplied form rather than converted in place,
// so that an unconverted colour cannot be written into a vertex. The two are
// different quantities and the type system is where that is cheapest to say.
pub const SrgbColor = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1,

    pub fn fromBytes(r: u8, g: u8, b: u8, a: u8) SrgbColor {
        const scale = 1.0 / 255.0;
        return .{
            .r = @as(f32, @floatFromInt(r)) * scale,
            .g = @as(f32, @floatFromInt(g)) * scale,
            .b = @as(f32, @floatFromInt(b)) * scale,
            .a = @as(f32, @floatFromInt(a)) * scale,
        };
    }

    // Comptime hex authoring, so a palette reads as the design source it came
    // from and stays diffable against it. `rrggbb` or `rrggbbaa`, with an
    // optional leading `#`. A malformed literal is a compile error: there is no
    // runtime path through here and therefore no runtime failure mode. A theme
    // read from a file carries floats and never reaches this.
    pub fn fromHex(comptime literal: []const u8) SrgbColor {
        const bytes = comptime hexBytes(literal);
        return fromBytes(bytes[0], bytes[1], bytes[2], bytes[3]);
    }

    // Parsing is split from construction because the whole result has to be a
    // comptime value, and `fromBytes` is an ordinary runtime function.
    fn hexBytes(comptime literal: []const u8) [4]u8 {
        comptime {
            const digits = if (literal.len > 0 and literal[0] == '#') literal[1..] else literal;
            if (digits.len != 6 and digits.len != 8)
                @compileError("hex colour must be rrggbb or rrggbbaa: '" ++ literal ++ "'");

            var bytes: [4]u8 = .{ 0, 0, 0, 255 };
            for (0..digits.len / 2) |index| {
                const high: u8 = nibble(literal, digits[index * 2]);
                const low: u8 = nibble(literal, digits[index * 2 + 1]);
                bytes[index] = (high << 4) | low;
            }
            return bytes;
        }
    }

    fn nibble(comptime literal: []const u8, comptime character: u8) u4 {
        return switch (character) {
            '0'...'9' => character - '0',
            'a'...'f' => character - 'a' + 10,
            'A'...'F' => character - 'A' + 10,
            else => @compileError("hex colour has a non-hex digit: '" ++ literal ++ "'"),
        };
    }

    // Replaces alpha rather than scaling it. A palette role is authored opaque,
    // and a translucent wash is defined by the coverage the caller wants rather
    // than by whatever the role happened to carry.
    pub fn withAlpha(self: SrgbColor, alpha: f32) SrgbColor {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = alpha };
    }
};

// Colour as the vertex carries it: linear, premultiplied by alpha.
//
// Premultiplied because it is the only encoding under which compositing is
// associative. A glyph over a translucent fill over a panel over the scene
// reduces to the same result whatever order the pairs are taken in, and the
// place straight alpha breaks that is exactly where a UI spends its time.
//
// f16 rather than a linear `unorm8`, and the reason is arithmetic rather than
// caution. One `unorm8` step is 1/255. The sRGB decode below divides its toe by
// 12.92, so sRGB code 1 decodes to a linear 1/255/12.92; one linear `unorm8`
// step therefore spans 12.92 sRGB code values near black, and a dark panel
// bands at every one of them. An f16 significand is eleven bits, which puts its
// spacing there orders of magnitude below what the encoding can express.
pub const LinearPremultipliedColor = extern struct {
    rgba: [4]f16,

    pub const transparent: LinearPremultipliedColor = .{ .rgba = .{ 0, 0, 0, 0 } };

    // Every channel passes through a clamp, and `std.math.clamp` is
    // `@max(lower, @min(upper, value))` where `@min` and `@max` return the
    // operand that is not NaN. A non-finite input therefore leaves here as a
    // bound rather than as itself, which is what lets the draw list carry no
    // per-vertex colour check.
    pub fn fromSrgb(colour: SrgbColor) LinearPremultipliedColor {
        const alpha = std.math.clamp(colour.a, 0, 1);
        return .{ .rgba = .{
            @floatCast(srgbToLinear(colour.r) * alpha),
            @floatCast(srgbToLinear(colour.g) * alpha),
            @floatCast(srgbToLinear(colour.b) * alpha),
            @floatCast(alpha),
        } };
    }

    pub const white: LinearPremultipliedColor = .{ .rgba = .{ 1, 1, 1, 1 } };
};

// Khronos Data Format Specification v1.3, section 13.3.1 "sRGB EOTF": below the
// threshold the encoding is divided by 12.92, above it the offset encoding is
// raised to 2.4.
fn srgbToLinear(channel: f32) f32 {
    const value = std.math.clamp(channel, 0, 1);
    return if (value <= 0.04045)
        value / 12.92
    else
        std.math.pow(f32, (value + 0.055) / 1.055, 2.4);
}

// A sampled image, resolved only by whoever registered it.
//
// The width is the resource pool's on the other side: an index and a generation
// packed into one word, with zero reserved. A zero-initialised draw command
// therefore names nothing live rather than aliasing the first slot.
pub const ImageHandle = enum(u64) {
    invalid = 0,
    _,

    pub fn isValid(self: ImageHandle) bool {
        return self != .invalid;
    }
};

// One indexed vertex, in the layout the vertex stage declares.
//
// Position and UV stay f32 so that neither depends on the framebuffer extent
// nor on the size of the image being sampled. Narrowing them would save eight
// bytes a vertex, which on a dense frame is a fraction of one frame's colour
// traffic and does not pay for a decode in the vertex stage.
pub const Vertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    colour: LinearPremultipliedColor,

    // Inside the struct rather than at file scope, so it is analysed when
    // something resolves this layout, which is every consumer that matters. The
    // shader declares its attributes at these offsets.
    comptime {
        std.debug.assert(@sizeOf(Vertex) == 24);
        std.debug.assert(@offsetOf(Vertex, "position") == 0);
        std.debug.assert(@offsetOf(Vertex, "uv") == 8);
        std.debug.assert(@offsetOf(Vertex, "colour") == 16);
    }
};
