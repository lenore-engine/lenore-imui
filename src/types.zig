const std = @import("std");
const res = @import("lenore-resources");

// The geometry and colour this module owns: the space a caller lays out in, the
// encoding a theme is written in, and the framebuffer position both are
// resolved against.
//
// What crosses to whoever draws the list is not here. The vertex, the draw
// command, the clip rectangle and the image handle are `lenore-resources`
// declarations, so that this module and the renderer share a vocabulary without
// either naming the other. This file holds what turns an author's values into
// that vocabulary, and what the module needs on its own side of it.

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

// An extent in the space a caller lays out in, with no position.
//
// Separate from `LogicalRect` because measurement and placement are separate
// passes over a layout tree: what a widget wants is a size, and where it goes
// is decided a pass later by whoever owns the space.
pub const LogicalSize = struct {
    width: f32,
    height: f32,

    pub const zero: LogicalSize = .{ .width = 0, .height = 0 };

    pub fn isValid(self: LogicalSize) bool {
        return std.math.isFinite(self.width) and std.math.isFinite(self.height) and
            self.width >= 0 and self.height >= 0;
    }
};

// A rectangle in the resolution-independent space a caller lays out in. It
// reaches the draw list only through the conversion below.
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
    pub fn toFramebufferFilled(self: LogicalRect, scale: ScaleFactor) ConversionError!res.Rect {
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

// A position in framebuffer pixels, which is the space a pointer arrives in and
// the space a region is tested in.
//
// There is no logical counterpart, because nothing lays a position out. A
// rectangle is authored in logical space and converted; a position comes from
// the window already in pixels and is only ever compared against the result.
pub const Point = struct {
    x: f32,
    y: f32,

    // Half-open on both axes: the left and top edges belong to the rectangle
    // and the right and bottom do not. Two rectangles sharing an edge therefore
    // share no position, so a pointer on the seam between adjacent widgets is
    // inside exactly one of them.
    //
    // This is the one geometry predicate in the module that takes no error
    // path, and the arithmetic is why. Both comparisons are false when either
    // operand is NaN, and a negative extent puts the upper bound below the
    // lower one, so a rectangle or a position that is not finite contains
    // nothing rather than everything. A validity check here would change no
    // answer.
    pub fn isInside(self: Point, rect: res.Rect) bool {
        return self.x >= rect.x and self.y >= rect.y and
            self.x < rect.x + rect.width and self.y < rect.y + rect.height;
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
// Kept apart from the premultiplied form rather than converted in place, so
// that an unconverted colour cannot be written into a vertex. The two are
// different quantities and the type system is where that is cheapest to say.
//
// Both are sRGB encoded, and that is the overlay's contract rather than an
// omission. What the draw list carries is what the display shows: the pass
// composites onto an image the tone operator has already encoded, and blending
// a glyph's coverage against display values is what puts a half-covered edge
// half way up the scale a reader sees.
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

    // Into the encoding a vertex carries: the same channels, scaled by alpha.
    //
    // Every channel passes through a clamp, and `std.math.clamp` is
    // `@max(lower, @min(upper, value))` where `@min` and `@max` return the
    // operand that is not NaN. A non-finite input therefore leaves here as a
    // bound rather than as itself, which is what lets the draw list carry no
    // per-vertex colour check.
    pub fn premultiplied(self: SrgbColor) res.PremultipliedColor {
        const alpha = std.math.clamp(self.a, 0, 1);
        return .{ .rgba = .{
            @floatCast(std.math.clamp(self.r, 0, 1) * alpha),
            @floatCast(std.math.clamp(self.g, 0, 1) * alpha),
            @floatCast(std.math.clamp(self.b, 0, 1) * alpha),
            @floatCast(alpha),
        } };
    }
};
