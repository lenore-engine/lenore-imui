const std = @import("std");
const res = @import("lenore-resources");
const canvas_mod = @import("canvas.zig");
const id_stack = @import("id_stack.zig");
const input = @import("input.zig");
const widgets = @import("widgets.zig");

const Canvas = canvas_mod.Canvas;
const Id = id_stack.Id;
const ImageHandle = res.ImageHandle;
const Interaction = input.Interaction;
const Rect = res.Rect;

pub const Key = id_stack.Key;

// The three parts of the module driven as one: identities, routing, drawing.
//
// A frame here runs in three passes and the caller walks the same widget tree
// in each. First every widget registers its rectangle, then the frame's events
// are routed against the complete set, then every widget reads its result and
// draws. The middle pass is why there are three rather than one: a click has
// to be resolved against the whole painter order, and half of it is not an
// order.
//
// What ties the passes together is the identity stack. A widget is named by
// where it sits in the scopes its caller pushed, so the registering pass and
// the drawing pass find the same widget by walking the same scopes in the same
// order. Nothing checks that they matched, because nothing can without keeping
// the tree the module exists to avoid keeping. What happens instead is that a
// pass that walked differently asks for an identity the frame never
// registered, and gets `UnknownId` rather than somebody else's result.
//
// The clip stack is scoped the same way and for the same reason: a region's
// clip is read off the canvas at registration, so the two passes have to push
// the same clips as well as the same identities.

pub const RegionOptions = struct {
    enabled: bool = true,
    focusable: bool = false,

    // Whether the wheel reaches this region. Separate from `focusable` because
    // most of a frame is neither, and a widget is commonly one without the
    // other.
    scrollable: bool = false,

    // Null takes the clip the canvas is under, which is the usual case. An
    // explicit one is for a widget whose interactive area is not the area it
    // draws in.
    clip: ?Rect = null,
};

pub const Error = input.Error || canvas_mod.Error || id_stack.Error ||
    widgets.Error || error{
    // A scope was pushed and not popped by the time the pass that opened
    // it ended. Caught at the pass boundary because past it the identities
    // are wrong rather than missing, and wrong identities are what this
    // module is built to make impossible.
    UnbalancedScopes,
};

// The façade's own pass, which is not the input context's: it also drives the
// canvas and the identity stack, and it is the check that fires first.
const Pass = enum { idle, registering, routing, drawing };

pub const Context = struct {
    input_context: *input.Context,
    canvas: *Canvas,
    ids: id_stack.Stack,

    // The image every solid fill samples: one white texel, so that a coloured
    // quad and a textured one are the same draw and merge into one command.
    image: ImageHandle,

    // How many clips the façade itself has pushed and not popped. Counted
    // here rather than asked of the canvas because these are the ones the two
    // passes have to agree on; what a caller pushes on the canvas directly
    // while drawing is its own business.
    clip_depth: u32 = 0,

    pass: Pass = .idle,

    // Everything is borrowed and nothing is allocated. `scope_storage` fixes
    // the deepest the identity stack can go for the context's lifetime.
    pub fn init(
        input_context: *input.Context,
        canvas: *Canvas,
        scope_storage: []Id,
        root_seed: u64,
        image: ImageHandle,
    ) Error!Context {
        if (!image.isValid()) return error.InvalidImage;
        return .{
            .input_context = input_context,
            .canvas = canvas,
            .ids = try id_stack.Stack.init(scope_storage, root_seed),
            .image = image,
        };
    }

    // Opens the registering pass. Refused from inside a frame for the same
    // reason the input context refuses it: the regions being registered are
    // what the rest of the frame is about.
    pub fn beginFrame(self: *Context, root_clip: Rect) Error!void {
        if (self.pass == .registering or self.pass == .routing) return error.InvalidPhase;

        try self.input_context.beginFrame();
        try self.canvas.begin(root_clip);
        self.ids.reset();
        self.clip_depth = 0;
        self.pass = .registering;
    }

    // Drops the frame being built, for a caller that failed part-way through
    // it. What that buys is in `input.Context.abandonFrame`.
    //
    // Like that one, this resets the pass and nothing else. The identity stack,
    // the clip depth and the canvas are all begun again by `beginFrame`, and
    // neither stack may be asked to be balanced here: a caller that failed is
    // exactly the caller likely to have left a scope open, and refusing to
    // recover from a failure because of that failure is the trap this exists to
    // remove rather than one to reproduce.
    pub fn abandonFrame(self: *Context) void {
        self.input_context.abandonFrame();
        self.pass = .idle;
    }

    // Opens a scope. Valid in both passes that walk the tree, and it has to be
    // called identically in both.
    pub fn pushId(self: *Context, key: Key) Error!void {
        if (self.pass != .registering and self.pass != .drawing) return error.InvalidPhase;
        return self.ids.push(key);
    }

    pub fn popId(self: *Context) void {
        self.ids.pop();
    }

    // The clip is scoped like the identity and for the same reason: the
    // registering pass reads it off the canvas to give the region its clip,
    // and the drawing pass has to be under the same one for the geometry to
    // land where the region was.
    pub fn pushClip(self: *Context, clip: Rect) Error!void {
        if (self.pass != .registering and self.pass != .drawing) return error.InvalidPhase;
        try self.canvas.pushClip(clip);
        self.clip_depth += 1;
    }

    pub fn popClip(self: *Context) void {
        self.canvas.popClip();
        self.clip_depth -= 1;
    }

    // Registers one widget's interactive area, in painter's order.
    pub fn register(self: *Context, key: Key, rect: Rect, options: RegionOptions) Error!void {
        if (self.pass != .registering) return error.InvalidPhase;
        _ = try self.input_context.addRegion(.{
            .id = self.ids.id(key),
            .rect = rect,
            .clip = options.clip orelse self.canvas.currentClip(),
            .enabled = options.enabled,
            .focusable = options.focusable,
            .scrollable = options.scrollable,
        });
    }

    pub fn beginRouting(self: *Context) Error!void {
        if (self.pass != .registering) return error.InvalidPhase;
        // Both stacks, because both name where a widget is: a clip left open
        // gave every region after it the wrong one, which is the same class of
        // mistake as a scope left open and deserves the same answer.
        if (!self.ids.isAtRoot() or self.clip_depth != 0) return error.UnbalancedScopes;

        try self.input_context.beginRouting();
        self.pass = .routing;
    }

    pub fn routeEvent(self: *Context, event: input.Event) Error!bool {
        if (self.pass != .routing) return error.InvalidPhase;
        return self.input_context.routeEvent(event);
    }

    // Closes routing and opens the drawing pass.
    //
    // Neither stack is reset and the canvas is not begun again, because both
    // are already where the drawing pass needs them: `beginRouting` refused a
    // pass that left either stack open, the routing pass can push neither, and
    // registration emits no geometry because the canvas is only reachable
    // while drawing. Resetting here would be a second answer to a question
    // that already has one.
    pub fn finishRouting(self: *Context) Error!void {
        if (self.pass != .routing) return error.InvalidPhase;

        try self.input_context.finishRouting();
        self.pass = .drawing;
    }

    // What the widget named by `key` in the current scope got out of the frame.
    pub fn interaction(self: *const Context, key: Key) Error!Interaction {
        if (self.pass != .drawing) return error.InvalidPhase;
        return self.input_context.interactionForId(self.ids.id(key));
    }

    // The canvas, for a caller drawing something this module has no widget for.
    pub fn drawList(self: *Context) Error!*Canvas {
        if (self.pass != .drawing) return error.InvalidPhase;
        return self.canvas;
    }

    // A line of text in a rectangle.
    //
    // The one widget here that takes no key, because it registers no region and
    // resolves nothing: a label is not a target, and text that answers a click
    // is a button with a caption drawn over it. What it still needs the façade
    // for is the pass, which is the check that says the geometry lands in the
    // frame the regions were routed against.
    //
    // It reads none of the context's image either. A run addresses the atlas it
    // was resolved against, so that handle travels with the glyphs rather than
    // with the widget drawing them.
    pub fn label(
        self: *Context,
        rect: Rect,
        style: widgets.LabelStyle,
        content: widgets.Label,
        enabled: bool,
    ) Error!void {
        if (self.pass != .drawing) return error.InvalidPhase;
        return widgets.drawLabel(self.canvas, rect, style, content, enabled);
    }

    // The widgets below draw and resolve in one call. Registration is a
    // separate call in the earlier pass and cannot be folded in: the result
    // being returned here is only knowable once every region of the frame has
    // been routed against.
    //
    // `enabled` has to match what the same widget was registered with. The
    // registered flag governs whether input reaches the region at all, and
    // this one governs how it is drawn and whether its value moves; a caller
    // that disagrees with itself gets a widget that looks live and is not.

    // True on the frame the button was actuated, by a click completed on it or
    // by the keyboard while it held focus.
    pub fn button(
        self: *Context,
        key: Key,
        rect: Rect,
        style: widgets.ButtonStyle,
        enabled: bool,
    ) Error!bool {
        const state = try self.interaction(key);
        try widgets.drawButton(self.canvas, rect, style, state, enabled, self.image);
        return enabled and state.pressed;
    }

    // The whole interaction, because what a splitter is for is the pointer
    // position during a drag and no single flag carries that.
    pub fn splitter(
        self: *Context,
        key: Key,
        rect: Rect,
        style: widgets.SplitterStyle,
    ) Error!Interaction {
        const state = try self.interaction(key);
        try widgets.drawSplitter(self.canvas, rect, style, state, self.image);
        return state;
    }

    // Toggles `value` and reports whether this frame was the one that did.
    pub fn checkbox(
        self: *Context,
        key: Key,
        rect: Rect,
        value: *bool,
        style: widgets.CheckboxStyle,
        enabled: bool,
    ) Error!bool {
        const state = try self.interaction(key);
        const changed = enabled and state.pressed;
        // Drawn from the value the frame ends with, not the one it began with,
        // so the tick appears on the same frame the click landed rather than
        // the one after it.
        if (changed) value.* = !value.*;
        try widgets.drawCheckbox(self.canvas, rect, style, state, value.*, enabled, self.image);
        return changed;
    }

    // Moves `offset` by whatever the frame's wheel did to a scrolling region,
    // and reports whether it moved.
    //
    // Arithmetic and a lookup, with no drawing of its own: what a scrolling
    // region looks like is a panel, a clip and rows placed `offset` higher,
    // all of which the caller already has. Registering the region with
    // `scrollable` is what makes the wheel reach it at all.
    pub fn scroll(
        self: *Context,
        key: Key,
        content: f32,
        viewport: f32,
        offset: *f32,
    ) Error!bool {
        const state = try self.interaction(key);
        const next = try widgets.scrollOffset(offset.*, state.scroll.y, content, viewport);
        const moved = next != offset.*;
        offset.* = next;
        return moved;
    }

    // Applies this frame's editing to a text field, and reports whether the
    // text changed.
    //
    // **Separate from the drawing below, and called before it.** What is drawn
    // is a run somebody shaped from the buffer, and the buffer is what this
    // changes; folding the two into one call would draw the text as it stood
    // before the keystroke and leave the typing one frame behind. A caller
    // acts on the answer by shaping again, and then draws.
    //
    // `shaped` is the run as it was last drawn, which is what a click is
    // resolved against: the user aimed at what was on the screen.
    //
    // The style is here for its padding, which is where the line starts and so
    // what a pointer position is measured from. Passing the same style to both
    // calls is what keeps the caret a click puts down under the pointer.
    pub fn editText(
        self: *Context,
        key: Key,
        rect: Rect,
        style: widgets.TextFieldStyle,
        buffer: []u8,
        state: *widgets.TextFieldState,
        shaped: widgets.Label,
        enabled: bool,
    ) Error!bool {
        const interacted = try self.interaction(key);
        const changed = try widgets.applyEdits(buffer, state, try self.editsFor(key), enabled);
        if (enabled) placeCaretFromPointer(rect, style, state, shaped, interacted);
        return changed;
    }

    // Draws a text field over the state `editText` left behind.
    //
    // The scroll is settled here and not there, because it is the only part
    // that depends on the run: a caller that shaped again between the two
    // calls has the current one by now, and the caret is kept in view against
    // the line that is about to be drawn rather than the one before it.
    pub fn textField(
        self: *Context,
        key: Key,
        rect: Rect,
        style: widgets.TextFieldStyle,
        state: *widgets.TextFieldState,
        shaped: widgets.Label,
        enabled: bool,
    ) Error!void {
        const interacted = try self.interaction(key);
        state.scroll = widgets.caretScroll(
            state.scroll,
            widgets.advanceTo(shaped.run, state.caret),
            widgets.textFieldLine(rect, style).width,
            shaped.advance,
        );
        return widgets.drawTextField(
            self.canvas,
            rect,
            style,
            state.*,
            shaped,
            interacted,
            enabled,
            self.image,
        );
    }

    fn editsFor(self: *const Context, key: Key) Error![]const input.Edit {
        if (self.pass != .drawing) return error.InvalidPhase;
        return self.input_context.editsForId(self.ids.id(key));
    }

    // Moves `value` by whatever the frame's input did to the slider, and
    // reports whether it moved.
    pub fn slider(
        self: *Context,
        key: Key,
        rect: Rect,
        value: *f32,
        range: widgets.SliderRange,
        style: widgets.SliderStyle,
        enabled: bool,
    ) Error!bool {
        const state = try self.interaction(key);
        const next = try widgets.sliderValue(
            value.*,
            rect,
            style.knob_width,
            range,
            state,
            enabled,
        );
        try widgets.drawSlider(
            self.canvas,
            rect,
            style,
            state,
            widgets.sliderFraction(next, range),
            enabled,
            self.image,
        );
        const changed = next != value.*;
        value.* = next;
        return changed;
    }
};

// A click puts the caret where it landed, and a drag from it selects.
//
// The anchor moves only on the frame the press was taken, so every frame after
// it moves the caret alone. That is the whole of what makes dragging select,
// and it is why the press and the hold are told apart here rather than being
// one case.
fn placeCaretFromPointer(
    rect: Rect,
    style: widgets.TextFieldStyle,
    state: *widgets.TextFieldState,
    shaped: widgets.Label,
    interacted: Interaction,
) void {
    if (interacted.capture != .primary and interacted.capture_began != .primary) return;
    const pointer = interacted.pointer orelse return;

    // Measured from the pen the run is drawn from, which is where the line
    // starts less however far the field is scrolled along it.
    const line = widgets.textFieldLine(rect, style);
    const along = pointer.x - line.x + state.scroll;

    const offset = widgets.offsetAt(shaped.run, state.len, along);
    state.caret = offset;
    if (interacted.capture_began == .primary) state.anchor = offset;
}
