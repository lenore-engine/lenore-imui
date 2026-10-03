const std = @import("std");
const res = @import("lenore-resources");
const canvas_mod = @import("canvas.zig");
const input = @import("input.zig");
const primitives = @import("primitives.zig");
const text = @import("text.zig");
const types = @import("types.zig");

const Canvas = canvas_mod.Canvas;
const Edit = input.Edit;
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

    // A text field's state does not describe its buffer: a length past the
    // buffer, a caret past the length, or a caret in the middle of a character.
    //
    // Checked because the state is the caller's and every slice below is taken
    // with it. In a build with the safety checks off a caret past the length is
    // a read out of bounds rather than a panic, and one inside a character
    // cuts a UTF-8 sequence in half.
    InvalidTextState,
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

// Where a scrolling region sits after this frame's wheel.
//
// The clamp is the whole of it, and it is here rather than in the region that
// draws because it is arithmetic: an offset, a distance, and the two sizes that
// say how far there is to go.
//
// Zero is the top and the offset grows downward, which is the sense the `scroll`
// event carries. Content no larger than the view scrolls nowhere rather than
// scrolling backwards.
pub fn scrollOffset(current: f32, delta: f32, content: f32, viewport: f32) Error!f32 {
    if (!std.math.isFinite(current) or !std.math.isFinite(delta) or
        !std.math.isFinite(content) or !std.math.isFinite(viewport) or
        content < 0 or viewport < 0)
        return error.InvalidRange;

    return std.math.clamp(current + delta, 0, @max(content - viewport, 0));
}

// A text field's own state, which is everything about it that outlives a frame.
//
// The bytes are not here. They are the caller's buffer, as everywhere else in
// this module, and `len` says how much of it the field is using. Two callers
// editing the same buffer through two of these is a caller's mistake and not
// one this can detect.
pub const TextFieldState = struct {
    // How many bytes of the buffer hold text.
    len: usize = 0,

    // The caret, as a byte offset into the first `len` bytes. It sits between
    // characters, never inside one.
    caret: usize = 0,

    // Where the selection began. Equal to `caret` when there is no selection,
    // which is why there is no separate flag: a selection is the interval
    // between the two and an empty interval is no selection.
    //
    // It is the anchor and not the lower bound, so a selection dragged
    // backwards keeps the end the user started from.
    anchor: usize = 0,

    // How far the line is scrolled to the left, in pixels, so that the caret
    // stays inside a field narrower than its text.
    scroll: f32 = 0,

    // The lower and upper bounds of the selection, in that order.
    pub fn selection(self: TextFieldState) struct { usize, usize } {
        return .{ @min(self.caret, self.anchor), @max(self.caret, self.anchor) };
    }

    pub fn hasSelection(self: TextFieldState) bool {
        return self.caret != self.anchor;
    }
};

// Applies one frame's editing to the caller's buffer, and reports whether the
// text changed.
//
// Changed means the bytes changed. A caret that moved and a selection that grew
// are not changes to the text, and a caller that saves on every change should
// not save because an arrow key was pressed.
//
// Here rather than with the widget façade for the reason `sliderValue` is: it
// is the one part of a text field that is arithmetic rather than plumbing, and
// it takes no canvas, no context and no device.
//
// The operations are applied in the order they arrived, which is the whole
// reason the queue is a queue. Typing, a backspace and more typing inside one
// frame give a different answer in a different order.
pub fn applyEdits(
    buffer: []u8,
    state: *TextFieldState,
    edits: []const Edit,
    enabled: bool,
) Error!bool {
    try validateState(buffer, state.*);
    if (!enabled) return false;

    var changed = false;
    for (edits) |edit| switch (edit) {
        .insert => |bytes| changed = insert(buffer, state, bytes) or changed,
        .key => |stroke| switch (stroke.key) {
            .left => moveCaret(buffer[0..state.len], state, .backward, stroke),
            .right => moveCaret(buffer[0..state.len], state, .forward, stroke),
            .home => placeCaret(state, 0, stroke.shift),
            .end => placeCaret(state, state.len, stroke.shift),
            .backspace => changed = deleteAdjacent(buffer, state, .backward, stroke) or changed,
            .delete => changed = deleteAdjacent(buffer, state, .forward, stroke) or changed,
            // `input.isEditKey` admits six keys and the six are above. The
            // others never reach the queue, and a field that received one
            // would have nothing to do with it either way.
            .tab, .enter, .space, .escape, .up, .down => {},
        },
    };
    return changed;
}

// Refuses a state that does not describe this buffer, before anything slices
// with it.
fn validateState(buffer: []const u8, state: TextFieldState) Error!void {
    if (state.len > buffer.len) return error.InvalidTextState;
    if (state.caret > state.len or state.anchor > state.len) return error.InvalidTextState;
    if (!std.math.isFinite(state.scroll)) return error.InvalidTextState;

    // On a character boundary, which is what every slice below assumes. A
    // continuation byte is 0b10xxxxxx and no character starts with one.
    //
    // Against the text and not the whole buffer, so that a caret at the end
    // reads no byte at all. The buffer past `len` holds whatever it held
    // before, and a caret was refused by whatever that byte happened to be.
    const text_bytes = buffer[0..state.len];
    if (isContinuation(text_bytes, state.caret) or isContinuation(text_bytes, state.anchor))
        return error.InvalidTextState;
}

fn isContinuation(buffer: []const u8, offset: usize) bool {
    return offset < buffer.len and buffer[offset] & 0xC0 == 0x80;
}

const Direction = enum { backward, forward };

// Replaces the selection with `bytes`, or inserts them at the caret when there
// is none.
//
// A chunk that does not fit is dropped whole rather than in part. A field with
// a full buffer stops accepting text, which is what a bounded field does; the
// alternative of taking the bytes that fit would cut a UTF-8 sequence in half.
fn insert(buffer: []u8, state: *TextFieldState, bytes: []const u8) bool {
    const start, const end = state.selection();
    const remaining = state.len - (end - start);
    if (bytes.len > buffer.len - remaining) return false;
    if (bytes.len == 0 and start == end) return false;

    // The tail moves first, because the gap it moves into is the one the
    // insertion is about to fill.
    const tail = state.len - end;
    @memmove(buffer[start + bytes.len ..][0..tail], buffer[end..][0..tail]);
    @memcpy(buffer[start..][0..bytes.len], bytes);

    state.len = remaining + bytes.len;
    state.caret = start + bytes.len;
    state.anchor = state.caret;
    return true;
}

// Backspace and delete: the selection if there is one, otherwise the character
// or word to one side of the caret.
fn deleteAdjacent(
    buffer: []u8,
    state: *TextFieldState,
    direction: Direction,
    stroke: input.EditKey,
) bool {
    const text_bytes = buffer[0..state.len];
    var start, var end = state.selection();
    if (start == end) {
        // Nothing to either side of an empty selection at the edge, and
        // reporting a change for a keystroke that removed nothing would make a
        // caller save a file that did not move.
        if (direction == .backward) {
            start = step(text_bytes, start, .backward, stroke.control);
        } else {
            end = step(text_bytes, end, .forward, stroke.control);
        }
        if (start == end) return false;
    }

    const tail = state.len - end;
    @memmove(buffer[start..][0..tail], buffer[end..][0..tail]);
    state.len -= end - start;
    state.caret = start;
    state.anchor = start;
    return true;
}

// Left and right, with shift extending the selection and control moving by a
// word.
//
// Without shift, a motion over a selection collapses it to the edge it moved
// towards rather than moving from the caret. That is what makes right-arrow
// after selecting a word land at the end of the word instead of one character
// into it.
fn moveCaret(
    text_bytes: []const u8,
    state: *TextFieldState,
    direction: Direction,
    stroke: input.EditKey,
) void {
    if (!stroke.shift and state.hasSelection() and !stroke.control) {
        const start, const end = state.selection();
        placeCaret(state, if (direction == .backward) start else end, false);
        return;
    }
    placeCaret(state, step(text_bytes, state.caret, direction, stroke.control), stroke.shift);
}

// Moves the caret, and either drags the anchor with it or leaves it where a
// selection can grow from.
fn placeCaret(state: *TextFieldState, offset: usize, extend: bool) void {
    state.caret = offset;
    if (!extend) state.anchor = offset;
}

fn step(text_bytes: []const u8, offset: usize, direction: Direction, by_word: bool) usize {
    return switch (direction) {
        .backward => if (by_word) wordLeft(text_bytes, offset) else charLeft(text_bytes, offset),
        .forward => if (by_word) wordRight(text_bytes, offset) else charRight(text_bytes, offset),
    };
}

// The four below are total on any byte slice and never leave it, so a buffer
// holding something that is not UTF-8 moves the caret oddly rather than out of
// bounds. That matters with the safety checks off, where a slice past the end
// is a read of whatever is there.

fn charLeft(text_bytes: []const u8, offset: usize) usize {
    var index = @min(offset, text_bytes.len);
    while (index > 0) {
        index -= 1;
        if (text_bytes[index] & 0xC0 != 0x80) break;
    }
    return index;
}

fn charRight(text_bytes: []const u8, offset: usize) usize {
    if (offset >= text_bytes.len) return text_bytes.len;
    var index = offset + 1;
    while (index < text_bytes.len and text_bytes[index] & 0xC0 == 0x80) index += 1;
    return index;
}

// A word is a run of anything that is not ASCII whitespace, and moving over one
// takes the whitespace beside it as well.
//
// Every byte of a character outside ASCII has its high bit set, so none of them
// is whitespace and a word runs straight through them. That is also what keeps
// these two on character boundaries without testing for one: a stop happens
// only where a whitespace byte meets a word byte, and an ASCII whitespace byte
// is a whole character.
//
// It is a separator rule and not a script-aware one. Word breaking in the sense
// of Unicode Standard Annex #29 needs the character properties, which is a
// table this module does not carry.
fn wordLeft(text_bytes: []const u8, offset: usize) usize {
    var index = @min(offset, text_bytes.len);
    while (index > 0 and std.ascii.isWhitespace(text_bytes[index - 1])) index -= 1;
    while (index > 0 and !std.ascii.isWhitespace(text_bytes[index - 1])) index -= 1;
    return index;
}

fn wordRight(text_bytes: []const u8, offset: usize) usize {
    var index = @min(offset, text_bytes.len);
    while (index < text_bytes.len and !std.ascii.isWhitespace(text_bytes[index])) index += 1;
    while (index < text_bytes.len and std.ascii.isWhitespace(text_bytes[index])) index += 1;
    return index;
}

// How far the pen has moved by the byte at `offset` in the text the run was
// shaped from.
//
// This measures, where the rest of the file does not, and the reason the rule
// bends here is that the number depends on the caret. A shaper can sum a run
// once and hand the total over as `Label.advance`; it cannot sum it up to a
// position it does not know.
//
// `cluster` is the byte the glyph came from, so a character that shaped into
// several glyphs is passed over as one and a caret can never land inside it.
//
// Left to right, which is the direction the pen moves in a run this module can
// draw. A run that reordered its glyphs would need its own answer, and nothing
// in this project reorders one yet.
pub fn advanceTo(run: GlyphRun, offset: usize) f32 {
    var pen: f32 = 0;
    for (run.glyphs) |glyph| {
        if (glyph.cluster >= offset) break;
        pen += glyph.x_advance;
    }
    return pen;
}

// Where the line has to sit for the caret to be inside the field.
//
// Called with the caret's own offset rather than with a direction, so that it
// answers the same whether the caret arrived by a keystroke, by a click or by
// the text under it changing length.
//
// A line that fits is never scrolled, and no line is ever scrolled past its
// end: both fall out of the clamp, which is why there is one and not a branch
// for each case.
pub fn caretScroll(current: f32, caret: f32, viewport: f32, content: f32) f32 {
    const travel = @max(content - viewport, 0);
    var next = std.math.clamp(current, 0, travel);
    if (caret < next) next = caret;
    if (caret > next + viewport) next = caret - viewport;
    return std.math.clamp(next, 0, travel);
}

// Where a field's line lives: its rectangle less the padding at both ends.
//
// Shared by the drawing and by whoever turns a pointer position into a caret,
// so that the caret a click puts down is under the pointer. Two copies of this
// arithmetic is one formula kept true in two places, and the one that drifts
// is the one nothing draws.
//
// The padding stops where the two sides would cross, the way a border width
// does, so an absurd padding empties the line rather than inverting it.
pub fn textFieldLine(rect: Rect, style: TextFieldStyle) Rect {
    const inset = @min(style.padding, rect.width * 0.5);
    return .{
        .x = rect.x + inset,
        .y = rect.y,
        .width = @max(rect.width - inset * 2, 0),
        .height = rect.height,
    };
}

pub const TextFieldStyle = struct {
    box: ButtonStyle,
    normal_text: PremultipliedColor,
    disabled_text: PremultipliedColor,

    // Behind the selected characters, drawn under them.
    selection: PremultipliedColor,
    caret: PremultipliedColor,
    caret_width: f32 = 1,

    // Between the border and the text, at both ends. It is also what the caret
    // has to sit inside at either extreme, which is why a field with none has
    // its caret on the border.
    padding: f32 = 0,
};

// A single line of editable text.
//
// The line is set from the left and centred across the field. There is no
// alignment to choose: a field whose text is centred moves under the caret as
// it is typed into, which is why no interface has one.
//
// **The caret does not blink.** Blinking is a redraw twice a second for as long
// as a field holds focus, which is a frame this engine would otherwise not
// draw, and it buys nothing a steady caret does not already say.
//
// The text is clipped to the field, unlike a label. That is what the scroll
// offset is for, and a field whose text ran past its own border would make the
// offset pointless.
pub fn drawTextField(
    canvas: *Canvas,
    rect: Rect,
    style: TextFieldStyle,
    state: TextFieldState,
    label: Label,
    interaction: Interaction,
    enabled: bool,
    image: ImageHandle,
) Error!void {
    if (!rect.isValid()) return error.InvalidGeometry;
    if (!std.math.isFinite(style.padding) or style.padding < 0 or
        !std.math.isFinite(style.caret_width) or style.caret_width < 0 or
        !std.math.isFinite(state.scroll))
        return error.InvalidGeometry;

    const mark = canvas.checkpoint();
    errdefer canvas.restore(mark);

    try drawButton(canvas, rect, style.box, interaction, enabled, image);

    const inner = textFieldLine(rect, style);
    if (inner.isEmpty()) return;

    try canvas.pushClip(inner);
    defer canvas.popClip();

    const line: LabelStyle = .{
        .normal_text = style.normal_text,
        .disabled_text = style.disabled_text,
        .horizontal = .start,
    };
    var pen = labelBaseline(inner, line, label);
    pen.x -= state.scroll;

    const start, const end = state.selection();
    if (start != end) {
        const from = pen.x + advanceTo(label.run, start);
        const to = pen.x + advanceTo(label.run, end);
        // The line's own box, which is the box `labelBaseline` placed the pen
        // in, so the highlight covers the characters rather than the leading
        // around them.
        try canvas.addQuad(.{
            .x = from,
            .y = pen.y - label.metrics.ascent,
            .width = to - from,
            .height = label.height(),
        }, .{}, style.selection, image);
    }

    try text.addGlyphs(
        canvas,
        label.run,
        pen,
        if (enabled) style.normal_text else style.disabled_text,
        label.atlas,
    );

    // Drawn only where the field holds the keyboard: a caret in a field that
    // is not focused says the typing would land there, and it would not.
    if (!enabled or !interaction.focused or style.caret_width == 0) return;
    try canvas.addQuad(.{
        .x = pen.x + advanceTo(label.run, state.caret),
        .y = pen.y - label.metrics.ascent,
        .width = style.caret_width,
        .height = label.height(),
    }, .{}, style.caret, image);
}

// The byte offset a position along the line falls on, for turning a click into
// a caret.
//
// The inverse of `advanceTo`, and `x` is measured from the same origin: the pen
// the run was drawn from, so a caller scrolled along the line adds its offset
// back before asking.
//
// Half way through a character is where the answer changes, which is what puts
// the caret on the side of the character the user aimed at rather than always
// before it.
//
// A character that shaped into several glyphs is entered at its own start, and
// a position inside it answers with that start. There is no byte between the
// glyphs of one cluster for the answer to be, which is the same reason a caret
// cannot be moved into one.
pub fn offsetAt(run: GlyphRun, text_len: usize, x: f32) usize {
    var pen: f32 = 0;
    for (run.glyphs) |glyph| {
        if (x < pen + glyph.x_advance * 0.5) return @min(glyph.cluster, text_len);
        pen += glyph.x_advance;
    }
    return text_len;
}
