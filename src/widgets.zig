const std = @import("std");
const res = @import("lenore-resources");
const canvas_mod = @import("canvas.zig");
const input = @import("input.zig");
const primitives = @import("primitives.zig");
const text = @import("text.zig");
const types = @import("types.zig");

const Canvas = canvas_mod.Canvas;
const FontMetrics = res.FontMetrics;
const GlyphRun = res.GlyphRun;
const ImageHandle = res.ImageHandle;
const Interaction = input.Interaction;
const Point = types.Point;
const PremultipliedColor = res.PremultipliedColor;
const Rect = res.Rect;

// The widgets, as drawing over a routed result plus the arithmetic that turns
// one into a value.
//
// Nothing here holds state or an identity. A widget is a function of the
// rectangle it was given, the style it was given and what the frame's input
// did to the region registered under it, which is what lets the same function
// serve a widget drawn once and a widget drawn in a list of two hundred.
//
// Style is premultiplied colour rather than the authoring form, because a
// theme is written once and drawn every frame: converting at the draw would
// put a transfer function on the per-frame path for a value that never
// changes. Whoever builds a theme calls `SrgbColor.premultiplied` there.
//
// Text is here as a label, and a label is a placement and nothing else. A
// widget takes no allocator and no font, so what it draws is a run somebody
// else shaped and a width somebody else measured; what it adds is the baseline
// a rectangle and an alignment come to.
//
// Every compound widget takes a checkpoint and rolls back on failure, so one
// that runs out of vertices half way through leaves nothing behind rather than
// a border with no fill inside it.

pub const ButtonStyle = struct {
    normal_fill: PremultipliedColor,
    hovered_fill: PremultipliedColor,
    held_fill: PremultipliedColor,
    disabled_fill: PremultipliedColor,
    border: PremultipliedColor,

    // Drawn in place of `border` while the region holds the keyboard. It is
    // only visible where there is a border to draw: a style with no border
    // width shows focus by nothing, which is a theme's decision to make.
    focused_border: ?PremultipliedColor = null,

    border_width: f32 = 0,
    radius: f32 = 0,
};

pub const SplitterStyle = struct {
    normal_fill: PremultipliedColor,
    hovered_fill: PremultipliedColor,
    held_fill: PremultipliedColor,
};

pub const CheckboxStyle = struct {
    box: ButtonStyle,
    mark: PremultipliedColor,
    mark_inset: f32,
    mark_radius: f32 = 0,
};

pub const SliderStyle = struct {
    track: PremultipliedColor,
    disabled_track: PremultipliedColor,
    knob: ButtonStyle,
    track_thickness: f32,
    knob_width: f32,
};

// The range a slider's value lives in.
//
// A step of zero is a continuous slider and also turns the arrow keys off:
// there is no amount for an arrow to move by that the range itself defines.
pub const SliderRange = struct {
    min: f32,
    max: f32,
    step: f32 = 0,
};

// What a label draws: the glyphs, what they measure, and where they are read
// from.
//
// One value rather than four parameters, because none of them means anything
// without the others. The atlas belongs in here for the reason a placement
// does: a glyph is resolved against one atlas, and the same run drawn from
// another is a run of different letters.
pub const Label = struct {
    run: GlyphRun,

    // The face's, at the size the run was shaped at. A face is a face at one
    // size, so there is nothing to scale these by.
    metrics: FontMetrics,

    // What the pen moves over the whole run.
    //
    // It arrives as data because this module measures nothing: whoever shaped
    // the run summed the advances on the way, and a second sum here would be
    // one formula kept true on both sides of a module boundary. It is the same
    // number a layout was given as the label's intrinsic width, so a caller
    // that placed the rectangle is already holding it.
    advance: f32,

    atlas: ImageHandle,

    // How tall a rectangle has to be to hold this line, which is what a layout
    // node sized from a caption asks for. The width is `advance` and needs no
    // method to say so.
    //
    // The line's own box and not `FontMetrics.lineHeight`: the gap is leading
    // between two lines and a single one does not carry it. That is the same
    // box `labelBaseline` places the pen in, so a node sized by this and a
    // baseline placed by that agree about where the line sits. Sizing by
    // `lineHeight` instead would leave the caption sitting high in its
    // rectangle by half the gap, for a reason nobody could point at.
    //
    // `descent` is measured upward from the baseline and is negative for every
    // ordinary face, which is why this is a subtraction.
    pub fn height(self: Label) f32 {
        return self.metrics.ascent - self.metrics.descent;
    }
};

pub const LabelStyle = struct {
    // Where the line sits along the axis it is set on.
    //
    // Deliberately not `MainAlignment`, whose fourth case would mean justified
    // text here. Justification moves the advances, which belongs to whoever
    // shaped the run, and a case this file cannot answer is worse in an enum
    // than absent from one.
    pub const Horizontal = enum { start, center, end };

    // Where it sits across that axis. There is no `baseline` case: a caller
    // that already has a baseline calls `addGlyphs` with it and reads no
    // metrics at all.
    pub const Vertical = enum { top, middle, bottom };

    normal_text: PremultipliedColor,
    disabled_text: PremultipliedColor,

    horizontal: Horizontal = .start,
    vertical: Vertical = .middle,
};

pub const Error = canvas_mod.Error || error{
    // A range with no interior, or one built from values that are not finite.
    // It comes from application code and is checked once, here.
    InvalidRange,
};

// Which fill a button-shaped thing wears.
//
// Held beats hovered because a pointer held down on a widget is on it by
// definition, and the two would otherwise both be true for the whole gesture.
fn buttonFill(style: ButtonStyle, state: Interaction, enabled: bool) PremultipliedColor {
    if (!enabled) return style.disabled_fill;
    if (state.capture == .primary) return style.held_fill;
    if (state.hovered) return style.hovered_fill;
    return style.normal_fill;
}

// A button background: the rectangle, and a border drawn as a larger rounded
// rectangle with the fill laid over it.
//
// Two rectangles rather than four sides, because a border of even width around
// a rounded rectangle is exactly that shape inset by the width, and four
// quads would have to mitre their corners.
pub fn drawButton(
    canvas: *Canvas,
    rect: Rect,
    style: ButtonStyle,
    state: Interaction,
    enabled: bool,
    image: ImageHandle,
) Error!void {
    if (!std.math.isFinite(style.border_width) or style.border_width < 0)
        return error.InvalidGeometry;

    const fill = buttonFill(style, state, enabled);
    if (style.border_width == 0)
        return primitives.addRoundedRect(canvas, rect, style.radius, .{}, fill, image);

    const mark = canvas.checkpoint();
    errdefer canvas.restore(mark);

    const border = if (state.focused)
        style.focused_border orelse style.border
    else
        style.border;
    try primitives.addRoundedRect(canvas, rect, style.radius, .{}, border, image);

    // A border thicker than half the shorter side would invert the inner
    // rectangle, so it stops where the two edges meet.
    const width = @min(style.border_width, @min(rect.width, rect.height) * 0.5);
    const inner: Rect = .{
        .x = rect.x + width,
        .y = rect.y + width,
        .width = @max(rect.width - width * 2, 0),
        .height = @max(rect.height - width * 2, 0),
    };
    // The inner radius is the outer one less the border, so the two curves
    // stay concentric rather than the inner one bulging into the border.
    try primitives.addRoundedRect(canvas, inner, @max(style.radius - width, 0), .{}, fill, image);
}

// A drag handle between two panes. One quad: it has no border and no focus,
// because it is grabbed rather than activated.
pub fn drawSplitter(
    canvas: *Canvas,
    rect: Rect,
    style: SplitterStyle,
    state: Interaction,
    image: ImageHandle,
) Error!void {
    const fill = if (state.capture == .primary)
        style.held_fill
    else if (state.hovered)
        style.hovered_fill
    else
        style.normal_fill;
    return canvas.addQuad(rect, .{}, fill, image);
}

pub fn drawCheckbox(
    canvas: *Canvas,
    rect: Rect,
    style: CheckboxStyle,
    state: Interaction,
    checked: bool,
    enabled: bool,
    image: ImageHandle,
) Error!void {
    if (!std.math.isFinite(style.mark_inset) or style.mark_inset < 0 or
        !std.math.isFinite(style.mark_radius) or style.mark_radius < 0)
        return error.InvalidGeometry;

    const mark = canvas.checkpoint();
    errdefer canvas.restore(mark);

    try drawButton(canvas, rect, style.box, state, enabled, image);
    if (!checked) return;

    const inset = @min(style.mark_inset, @min(rect.width, rect.height) * 0.5);
    try primitives.addRoundedRect(canvas, .{
        .x = rect.x + inset,
        .y = rect.y + inset,
        .width = @max(rect.width - inset * 2, 0),
        .height = @max(rect.height - inset * 2, 0),
    }, style.mark_radius, .{}, style.mark, image);
}

// A line of text inside a rectangle.
//
// A label registers no region and takes no interaction: it is not a target,
// and text that answers a click is a button with a caption drawn over it. What
// it does share with the widgets that are targets is `enabled`, so a disabled
// control's caption greys with the control.
//
// One run is one line. Two lines are two calls with the second rectangle moved
// down by `FontMetrics.lineHeight`, which is the distance the face itself gives
// between baselines.
//
// **Nothing is clipped.** A run wider than its rectangle draws past it, which
// is the honest picture of a label that does not fit. A clip is a draw command
// of its own and breaks the merge with everything around it, so whether to pay
// for one is the caller's decision to make with `Canvas.pushClip`.
//
// No checkpoint here, unlike the compound widgets: this draws one thing, and
// the run rolls itself back.
pub fn drawLabel(
    canvas: *Canvas,
    rect: Rect,
    style: LabelStyle,
    label: Label,
    enabled: bool,
) Error!void {
    if (!rect.isValid()) return error.InvalidGeometry;
    // A rectangle that has collapsed draws nothing, which is the rule
    // `addQuad` already applies to one. Otherwise the caption is the only thing
    // left on the screen of a layout that resolved to no size, sitting where
    // the widget it names is not.
    if (rect.isEmpty()) return;

    return text.addGlyphs(
        canvas,
        label.run,
        labelBaseline(rect, style, label),
        if (enabled) style.normal_text else style.disabled_text,
        label.atlas,
    );
}

// Where the pen goes for a label of this style in this rectangle.
//
// Shared with `drawLabel` so the baseline drawn on is the baseline a caller
// reads, and public for the reason `sliderValue` is here: it is numbers in and
// a number out, which is where a wrong sign on `descent` is cheap to catch. It
// is also what an underline or a caret wants, both of which are positions
// rather than glyphs.
//
// The label's own numbers are not checked. They come from a face and a shaper
// inside this project, and a pen that came out non-finite from them is refused
// by `addGlyphs` whatever produced it.
pub fn labelBaseline(rect: Rect, style: LabelStyle, label: Label) Point {
    const x = switch (style.horizontal) {
        .start => rect.x,
        .center => rect.x + (rect.width - label.advance) * 0.5,
        .end => rect.x + rect.width - label.advance,
    };

    // The line's own box rather than `lineHeight`: the gap is leading between
    // two lines, and half of it above a single one would sit that line low in
    // its rectangle for a reason nobody could point at. `descent` is measured
    // upward from the baseline and is negative for every ordinary face, so the
    // height of the box is a subtraction and the bottom edge lifts the baseline
    // by an addition.
    const line = label.metrics.ascent - label.metrics.descent;
    const y = switch (style.vertical) {
        .top => rect.y + label.metrics.ascent,
        .middle => rect.y + (rect.height - line) * 0.5 + label.metrics.ascent,
        .bottom => rect.y + rect.height + label.metrics.descent,
    };

    return .{ .x = x, .y = y };
}

// The track and the knob, with `fraction` already normalised to [0, 1] by
// `sliderValue` below.
pub fn drawSlider(
    canvas: *Canvas,
    rect: Rect,
    style: SliderStyle,
    state: Interaction,
    fraction: f32,
    enabled: bool,
    image: ImageHandle,
) Error!void {
    if (!std.math.isFinite(fraction) or
        !std.math.isFinite(style.track_thickness) or style.track_thickness < 0 or
        !std.math.isFinite(style.knob_width) or style.knob_width < 0)
        return error.InvalidGeometry;

    const mark = canvas.checkpoint();
    errdefer canvas.restore(mark);

    // A fully rounded track: the radius is half the thickness, which
    // `addRoundedRect` clamps to exactly that anyway.
    const thickness = @min(style.track_thickness, rect.height);
    try primitives.addRoundedRect(canvas, .{
        .x = rect.x,
        .y = rect.y + (rect.height - thickness) * 0.5,
        .width = rect.width,
        .height = thickness,
    }, thickness * 0.5, .{}, if (enabled) style.track else style.disabled_track, image);

    const knob = knobRect(rect, style.knob_width, fraction);
    // The knob wears the slider's own interaction, so the whole control lights
    // up together rather than only the part the pointer is over.
    return drawButton(canvas, knob, style.knob, state, enabled, image);
}

// Where the knob sits for a given fraction. Shared with `sliderValue` so that
// the position drawn and the position read are the same arithmetic.
fn knobRect(rect: Rect, knob_width: f32, fraction: f32) Rect {
    const width = @min(knob_width, rect.width);
    const travel = @max(rect.width - width, 0);
    return .{
        .x = rect.x + std.math.clamp(fraction, 0, 1) * travel,
        .y = rect.y,
        .width = width,
        .height = rect.height,
    };
}

// What a slider's value becomes, given what the frame's input did to it.
//
// It is here rather than with the widget façade because it is the one piece of
// widget behaviour that is arithmetic rather than plumbing, and because this
// way it takes no canvas, no context and no device: every case below is a
// call with numbers in and a number out.
//
// The pointer and the keyboard are both applied, in that order, and the
// result is quantised once at the end. Quantising each in turn would let a
// drag land off the grid whenever an arrow arrived in the same frame.
pub fn sliderValue(
    current: f32,
    rect: Rect,
    knob_width: f32,
    range: SliderRange,
    state: Interaction,
    enabled: bool,
) Error!f32 {
    if (!std.math.isFinite(range.min) or !std.math.isFinite(range.max) or
        range.min >= range.max or
        !std.math.isFinite(range.step) or range.step < 0)
        return error.InvalidRange;
    if (!std.math.isFinite(current)) return error.InvalidRange;
    if (!rect.isValid() or !std.math.isFinite(knob_width) or knob_width < 0)
        return error.InvalidGeometry;

    if (!enabled) return quantize(current, range);

    var next = current;

    // The pointer drives the value while the primary button holds the slider,
    // including on the frame the release arrives: letting go is part of the
    // drag and the last position is the one the user chose.
    const dragging = state.capture == .primary or state.capture_ended == .primary;
    if (dragging) {
        if (state.pointer) |pointer| {
            // The knob's own width is taken off both ends, so that dragging to
            // either extreme puts the knob flush with the track rather than
            // half off it.
            const width = @min(knob_width, rect.width);
            const travel = rect.width - width;
            const fraction = if (travel > 0)
                std.math.clamp((pointer.x - rect.x - width * 0.5) / travel, 0, 1)
            else
                0;
            next = range.min + fraction * (range.max - range.min);
        }
    }

    // The arrows move by one step each. A continuous slider has a step of
    // zero, so this is what makes the keyboard move it by nothing: the
    // distance an arrow means is the one the range defines, and it defines
    // none.
    next += @as(f32, @floatFromInt(state.adjust)) * range.step;

    return quantize(next, range);
}

// The fraction of the range a value sits at, for drawing.
pub fn sliderFraction(value: f32, range: SliderRange) f32 {
    return std.math.clamp((value - range.min) / (range.max - range.min), 0, 1);
}

// Clamps to the range, and to the step grid when there is one.
//
// With a step the reachable values are exactly `min`, `min + step`, and so on
// up to the last one at or below `max`. `max` itself is reachable only when it
// lies on that grid, which is the price of the grid being regular: rounding to
// `max` from above would put one reachable value off the grid and make the top
// of the range jump.
fn quantize(value: f32, range: SliderRange) f32 {
    const clamped = std.math.clamp(value, range.min, range.max);
    if (range.step <= 0) return clamped;

    const highest = @floor((range.max - range.min) / range.step);
    const steps = @min(@round((clamped - range.min) / range.step), highest);
    return range.min + steps * range.step;
}
