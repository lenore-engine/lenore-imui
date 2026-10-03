const std = @import("std");
const hit_test = @import("hit_test.zig");
const id_stack = @import("id_stack.zig");
const types = @import("types.zig");

const Id = id_stack.Id;
const Point = types.Point;
const Region = hit_test.Region;

// Pointer and keyboard routing over the regions one frame registered.
//
// A frame runs in three phases and the order is the whole design. Every region
// is registered first, then events are routed against the complete set, and
// only then are the results read. Routing an event against a half-built frame
// would answer from whichever widgets happened to be registered already, and
// routing against the previous frame's regions would answer from geometry that
// has since moved. Neither is a hazard the caller can be asked to avoid, so the
// phase is a state the context carries and every entry point checks.
//
// Nothing is retained across a frame except what an interaction is *about*:
// which widget holds the pointer, which has the keyboard, and where the pointer
// last was. Those are properties of the user's ongoing gesture rather than of a
// frame, and they are matched back to the new frame's regions by identity.
//
// Storage is the caller's, as everywhere else in this module.

pub const PointerButton = enum { primary, secondary, middle };
pub const ButtonAction = enum { press, release };
pub const KeyAction = enum { press, repeat, release };

// The keys a UI acts on, and no others.
//
// Characters are not among them, and that is what the `text` event is for: what
// a keystroke produces depends on a layout, a modifier state and a compose
// sequence that none of this module can see. What is here is the navigation and
// editing whose meaning is the same on every layout.
pub const Key = enum {
    tab,
    enter,
    space,
    escape,
    left,
    right,
    up,
    down,
    backspace,
    delete,
    home,
    end,
};

pub const PointerButtonEvent = struct {
    position: Point,
    button: PointerButton,
    action: ButtonAction,
    shift: bool = false,
};

// A motion or editing key, with the modifiers that decide what it means.
//
// The modifiers are here and not read off some frame-wide state because they
// belong to the keystroke: a selection extended by one word is shift and
// control on the arrow that extended it, and where in the frame that arrow fell
// is what says which characters it covered.
pub const EditKey = struct {
    key: Key,
    shift: bool = false,
    control: bool = false,
};

// One thing the user did to the focused region, in the order it happened.
//
// Order is the whole reason this is a queue rather than a set of counters.
// Typing, a backspace and more typing inside one frame are three operations
// whose result depends on their sequence, and a frame is long enough to hold
// all three whenever one stalls.
pub const Edit = union(enum) {
    // Committed text, pointing into the context's own buffer. Valid until the
    // next `beginFrame`.
    insert: []const u8,
    key: EditKey,
};

// Which keys reach the queue, as against which the module answers itself.
//
// Tab moves the focus, escape drops it, and enter and space actuate: those are
// this module's own and a field sees their result rather than the keystroke.
// Up and down are absent because a field on one line has nowhere to take them,
// and `Interaction.adjust` is where a widget that reads them as a value looks.
fn isEditKey(key: Key) bool {
    return switch (key) {
        .left, .right, .home, .end, .backspace, .delete => true,
        .tab, .enter, .space, .escape, .up, .down => false,
    };
}

pub const KeyEvent = struct {
    key: Key,
    action: KeyAction,
    shift: bool = false,

    // Word-wise motion and select-all, which are what a text field reads it
    // for. Separate from `shift` rather than folded into it because the two
    // combine: control with shift extends a selection by a word.
    control: bool = false,
};

// What the host routes in, in framebuffer pixels.
//
// Every pointer transition carries its own position rather than relying on a
// move having arrived first. A press and the motion that led to it can reach
// the host in either order, and a button that acts on a stale position acts on
// the wrong widget.
pub const Event = union(enum) {
    pointer_move: Point,
    pointer_button: PointerButtonEvent,
    key: KeyEvent,

    // Committed text, in UTF-8, for whatever holds the keyboard.
    //
    // Borrowed for the call. `routeEvent` copies what it takes into the
    // context's own buffer, so the memory behind this may be reused the moment
    // it returns.
    //
    // Committed, so a composition still being edited is not among them. There
    // is no member for one because no backend driving this module produces
    // one, and a word for something nothing can say is a word that would be
    // wrong by the time something did.
    text: []const u8,

    // How far the wheel turned, in framebuffer pixels: positive y travels
    // further down the content and positive x further right, which are the
    // draw list's own axes.
    //
    // Pixels and not lines. A wheel reports lines, and turning a line into a
    // distance needs a line height, which needs a face; this module has no
    // font and the conversion belongs to whoever does.
    scroll: Point,

    // The window gained or lost focus. Losing it ends any gesture in progress,
    // because the release that would have ended it will be delivered to
    // somebody else.
    focus: bool,

    // The host is abandoning the gesture: a drag left the window, a modal
    // opened, the frame budget was overrun. Distinct from losing focus because
    // the window is still the one receiving events.
    cancel,
};

// What one region got out of the frame.
//
// The pointer fields name the button rather than answering only for the primary
// one. A viewport drag on the middle button and a click on the primary are the
// same mechanism, and a widget that wants the primary asks for it.
pub const Interaction = struct {
    hovered: bool = false,
    focused: bool = false,

    // The button whose press is being held on this region, for as long as it
    // is held.
    capture: ?PointerButton = null,

    // The button that took the capture, on the frame it was taken.
    capture_began: ?PointerButton = null,

    // The button that gave it up, on the frame it was released.
    capture_ended: ?PointerButton = null,

    // The region was actuated: a primary capture was released while the
    // pointer was still on it, or the keyboard activated it while focused.
    // This is what a button acts on, and the reason it is not simply
    // `capture_ended == .primary` is that a press dragged off the widget and
    // released elsewhere must not count.
    pressed: bool = false,

    // Shift as it stood when the capture began, held for the whole gesture
    // rather than sampled at the release. A drag that starts constrained stays
    // constrained even if the key is let go mid-drag.
    shift: bool = false,

    // Accumulated arrow-key movement, saturating rather than wrapping: a key
    // held down for an hour reports a very large adjustment and never a
    // negative one.
    adjust: i32 = 0,

    // What the wheel turned over this region, summed over the frame, in the
    // units and the sense the `scroll` event carries.
    //
    // A distance and not a position. A frame may route several wheel events
    // and what the region wants is how far they moved it in total.
    scroll: Point = .{ .x = 0, .y = 0 },

    // Where the pointer was for whichever of the above happened. Absent when
    // the region was reached by the keyboard alone.
    pointer: ?Point = null,
};

// A frame-local handle to a registered region.
//
// The epoch is what makes it frame-local rather than merely index-shaped. The
// arrays are reused every frame, so an index kept across `beginFrame` would
// address a live region belonging to a different widget, and read plausible
// results from it forever.
pub const Token = struct {
    index: u32,
    epoch: u32,
};

pub const Error = error{
    EmptyStorage,

    // The interaction array must cover every region, and the lookup table must
    // be at least twice as large. See `initBuffers` for why twice.
    StorageTooSmall,

    // A region is addressed by a `u32` index in a `Token`.
    StorageTooLarge,

    // Registering or routing out of order. A programmer error in the frame
    // loop, reported rather than asserted because the frame loop is above this
    // module and its mistakes should not be undefined behaviour in a build
    // with the checks off.
    InvalidPhase,

    InvalidRegion,

    // Two regions registered under one identity in one frame. Either the id
    // stack was not pushed where it should have been, or a loop is registering
    // its rows under a constant key.
    DuplicateId,

    RegionCapacityExceeded,

    // A pointer position that is not finite. Refused so that it cannot become
    // a hit against nothing and a hover that never clears.
    InvalidPointerPosition,

    // A scroll distance that is not finite. Refused before it reaches the
    // accumulator, which a region reads as a distance and cannot recover once
    // a NaN has been added into it.
    InvalidScrollDelta,

    // Text that is not UTF-8, refused where it enters. Past here the bytes are
    // handed to a shaper and to a caller's own buffer, and neither should have
    // to carry the case.
    InvalidText,

    // One frame delivered more text than the buffer `initBuffers` was given.
    // Caller-sized like the regions, and exceeded for the same kind of reason.
    TextCapacityExceeded,

    // The same for the edit queue, which is sized in operations where the
    // buffer beside it is sized in bytes.
    EditCapacityExceeded,

    StaleToken,

    // An identity that this frame did not register. It is what a caller sees
    // when the pass that reads results walked a different set of scopes from
    // the pass that registered them, which is a mistake worth a name of its
    // own rather than an empty interaction.
    UnknownId,
};

const Phase = enum { idle, registering, routing, routed };

// One entry of the open-addressed identity index.
//
// `epoch` is what makes the table free of a per-frame clear: a slot belongs to
// the current frame only if its epoch matches, so bumping the epoch empties the
// whole table in one increment.
pub const LookupSlot = struct {
    id: Id = .invalid,
    region_index: u32 = 0,
    epoch: u32 = 0,
};

// The gesture in progress, which is the only pointer state that outlives a
// frame.
//
// One optional rather than an identity, a button, a modifier and a flag kept in
// step by hand. Those four can disagree, and where they did the prototype read
// the button with an `orelse unreachable` that a build with the checks off
// would not have caught.
const Capture = struct {
    id: Id,
    button: PointerButton,
    shift: bool,
};

pub const Context = struct {
    regions: []Region,
    interactions: []Interaction,
    lookup: []LookupSlot,

    // What one frame did to the focused region, in order, and the bytes the
    // insertions among them point into. Both may be empty, which is what a UI
    // with no text target needs and costs it nothing.
    edits: []Edit,
    edit_count: usize = 0,
    text_buffer: []u8,
    text_len: usize = 0,

    // Which region the queue above is for.
    //
    // Focus moves inside a frame: a click or a tab is an event like any other
    // and what follows it belongs to whatever it focused. Without this the
    // frame's editing would be handed whole to whichever widget held the
    // keyboard when the frame ended.
    edit_owner: ?Id = null,

    region_count: usize = 0,
    epoch: u32 = 0,
    phase: Phase = .idle,

    pointer: ?Point = null,
    hot: ?Id = null,
    capture: ?Capture = null,
    focused: ?Id = null,
    window_focused: bool = true,

    // Every array is the caller's and is held for the context's lifetime.
    //
    // The lookup table is required to be twice the region capacity, which is
    // the load factor linear probing wants. At a load factor of one the last
    // insertions of a frame walk half the table; at one half the expected walk
    // is under three slots. It also makes exhaustion impossible: a free slot
    // exists whenever a region does, which is what lets `findInsertionSlot`
    // carry no failure path.
    // The two editing arrays are the ones with no size requirement, because
    // there is a UI that wants neither: nothing is queued until something is
    // focusable and reads it, and an empty slice refuses the first operation
    // that arrives, which is the truth about a UI with no field in it.
    //
    // Sized independently, because they measure different things. The queue is
    // in operations and the buffer is in bytes, and a frame that inserts one
    // character six times fills one of them six times faster than the other.
    pub fn initBuffers(
        regions: []Region,
        interactions: []Interaction,
        lookup: []LookupSlot,
        edits: []Edit,
        text_buffer: []u8,
    ) Error!Context {
        if (regions.len == 0) return error.EmptyStorage;
        if (interactions.len < regions.len or lookup.len < regions.len * 2)
            return error.StorageTooSmall;
        if (regions.len > std.math.maxInt(u32)) return error.StorageTooLarge;

        // The epochs are the table's only notion of a slot being free, and the
        // first frame runs at epoch one. Storage handed over uninitialised
        // would carry slots that read as belonging to that frame, so the table
        // is emptied here rather than by asking the caller to have done it.
        for (lookup) |*slot| slot.* = .{};

        return .{
            .regions = regions,
            .interactions = interactions,
            .lookup = lookup,
            .edits = edits,
            .text_buffer = text_buffer,
        };
    }

    // Opens registration. Refused from inside a frame, because dropping the
    // regions while events are being routed against them would route the rest
    // of the frame against nothing.
    pub fn beginFrame(self: *Context) Error!void {
        if (self.phase == .registering or self.phase == .routing)
            return error.InvalidPhase;

        self.region_count = 0;
        self.hot = null;
        // The editing is a frame's, like the regions it was routed against.
        // What a widget does with it, it did on the frame it arrived.
        self.edit_count = 0;
        self.text_len = 0;
        self.edit_owner = null;
        self.epoch +%= 1;
        if (self.epoch == 0) {
            // Wrapped, so slots left over from the epoch that is about to be
            // reused would read as belonging to this frame. This is the one
            // pass over the table there is, once every four billion frames.
            for (self.lookup) |*slot| slot.epoch = 0;
            self.epoch = 1;
        }
        self.phase = .registering;
    }

    // Drops the frame being built, without settling anything it holds.
    //
    // For a caller that failed part-way through one: registration that ran out
    // of room, or an event that could not be routed. The phase such a caller
    // stops in is not one `beginFrame` accepts, so without a way back the next
    // frame is refused for a reason unrelated to what actually went wrong.
    //
    // The phase is all this touches, because it is all that is wrong. The
    // regions, the epoch and the hot region are `beginFrame`'s to clear and it
    // clears them whatever this leaves behind.
    //
    // The gesture is kept, and deliberately. The pointer is still held down,
    // and a capture is matched back to whatever the next frame registers by
    // identity. Ending it here would turn one failed frame into a button the
    // user never released.
    pub fn abandonFrame(self: *Context) void {
        self.phase = .idle;
    }

    // Registers one region in painter's order and returns the handle its result
    // is read back through.
    //
    // The geometry is validated here because this is where it enters from
    // application code. `hitTest` needs no check of its own, and an ill-formed
    // rectangle would otherwise make a widget quietly unreachable rather than
    // saying so.
    pub fn addRegion(self: *Context, region: Region) Error!Token {
        if (self.phase != .registering) return error.InvalidPhase;
        if (!region.id.isValid() or !region.rect.isValid() or !region.clip.isValid())
            return error.InvalidRegion;
        if (self.region_count == self.regions.len) return error.RegionCapacityExceeded;

        const slot_index = try self.findInsertionSlot(region.id);
        const index: u32 = @intCast(self.region_count);
        self.lookup[slot_index] = .{ .id = region.id, .region_index = index, .epoch = self.epoch };
        self.regions[index] = region;
        self.interactions[index] = .{};
        self.region_count += 1;
        return .{ .index = index, .epoch = self.epoch };
    }

    // Closes registration and opens routing.
    //
    // A gesture is matched back to the new frame's regions here, once, rather
    // than on every event. A widget that has gone away or been disabled while
    // holding the pointer has its capture dropped before any event can observe
    // it, and the same for the keyboard.
    pub fn beginRouting(self: *Context) Error!void {
        if (self.phase != .registering) return error.InvalidPhase;

        if (self.capture) |held| {
            const index = self.find(held.id);
            if (index == null or !self.regions[index.?].enabled) self.capture = null;
        }
        if (self.focused) |focused_id| {
            const index = self.find(focused_id);
            if (index == null or !canFocus(self.regions[index.?])) self.focused = null;
        }

        self.updateHot();
        self.phase = .routing;
    }

    // Routes one event and reports whether the UI took it. A host suppresses
    // the camera or the game's own binding when this is true, which is why a
    // move over any region counts: a cursor on a panel is not a cursor
    // steering a camera.
    pub fn routeEvent(self: *Context, event: Event) Error!bool {
        if (self.phase != .routing) return error.InvalidPhase;

        return switch (event) {
            .pointer_move => |position| blk: {
                try self.setPointer(position);
                break :blk self.hot != null or self.capture != null;
            },
            .pointer_button => |button_event| try self.routeButton(button_event),
            .key => |key_event| try self.routeKey(key_event),
            .text => |bytes| try self.routeText(bytes),
            .scroll => |delta| try self.routeScroll(delta),
            .focus => |focused| blk: {
                self.window_focused = focused;
                if (!focused) self.endGesture();
                break :blk false;
            },
            .cancel => blk: {
                const consumed = self.capture != null;
                self.endGesture();
                break :blk consumed;
            },
        };
    }

    // Closes routing and settles the results that describe a state rather than
    // an event: what is hovered, what is held, what has the keyboard. Those are
    // written once from the state at the end of the frame, because an earlier
    // event may have moved the pointer off the widget that a later one is
    // about.
    pub fn finishRouting(self: *Context) Error!void {
        if (self.phase != .routing) return error.InvalidPhase;

        self.updateHot();
        if (self.hot) |hot_id| {
            if (self.find(hot_id)) |index| {
                self.interactions[index].hovered = true;
                self.interactions[index].pointer = self.pointer;
            }
        }
        if (self.capture) |held| {
            if (self.find(held.id)) |index| {
                self.interactions[index].capture = held.button;
                self.interactions[index].shift = held.shift;
                self.interactions[index].pointer = self.pointer;
            }
        }
        if (self.focused) |focused_id| {
            if (self.find(focused_id)) |index| self.interactions[index].focused = true;
        }
        self.phase = .routed;
    }

    // What the region registered under `token` got out of the frame.
    pub fn interaction(self: *const Context, token: Token) Error!Interaction {
        if (self.phase != .routed) return error.InvalidPhase;
        if (token.epoch != self.epoch or token.index >= self.region_count)
            return error.StaleToken;
        return self.interactions[token.index];
    }

    // What this frame did to the region named by `region_id`, in order, and an
    // empty slice for every other region.
    //
    // Read in the drawing pass, because that is when a widget exists to act on
    // it. The entries live in the caller's arrays and are valid until the next
    // `beginFrame`.
    //
    // Asked for by identity and not answered for whatever holds the keyboard,
    // so that a widget cannot be handed editing the frame routed to somebody
    // else. That is not hypothetical: focus moves inside a frame.
    pub fn editsForId(self: *const Context, region_id: Id) Error![]const Edit {
        if (self.phase != .routed) return error.InvalidPhase;
        if (self.edit_owner != region_id) return &.{};
        return self.edits[0..self.edit_count];
    }

    // The same, by identity rather than by handle.
    //
    // A caller that registers its regions through a façade does not hold the
    // handles, and rebuilding the identity from the scope it is already in
    // costs one hash lookup. A caller that has the handle should use the one
    // above: it is an array index.
    pub fn interactionForId(self: *const Context, region_id: Id) Error!Interaction {
        if (self.phase != .routed) return error.InvalidPhase;
        const index = self.find(region_id) orelse return error.UnknownId;
        return self.interactions[index];
    }

    // Ends whatever gesture is in progress and clears the results already
    // written this frame. It is the response to the host saying the frame's
    // input is not to be acted on, so leaving half of it in place would be
    // acting on it.
    //
    // The pointer position goes too: after a cancel there is no position the
    // module can claim to know.
    pub fn endGesture(self: *Context) void {
        self.pointer = null;
        self.hot = null;
        self.capture = null;
        self.focused = null;
        // The editing goes with the rest. It was routed to a widget that is
        // about to lose the keyboard, and leaving it would insert a character
        // the cancel says not to act on.
        self.edit_count = 0;
        self.text_len = 0;
        self.edit_owner = null;
        for (self.interactions[0..self.region_count]) |*state| state.* = .{};
    }

    fn routeButton(self: *Context, event: PointerButtonEvent) Error!bool {
        try self.setPointer(event.position);

        return switch (event.action) {
            .press => blk: {
                // One gesture at a time. A second button pressed during a drag
                // is consumed and otherwise ignored, rather than stealing the
                // capture from the drag in progress.
                if (self.capture != null) break :blk true;

                const target = self.hot orelse {
                    // A press on nothing drops the keyboard focus, the way
                    // clicking the background of a dialog does.
                    if (event.button == .primary) self.focused = null;
                    break :blk false;
                };
                const index = self.find(target) orelse break :blk false;

                self.capture = .{ .id = target, .button = event.button, .shift = event.shift };
                if (event.button == .primary)
                    self.focused = if (canFocus(self.regions[index])) target else null;

                self.interactions[index].capture_began = event.button;
                self.interactions[index].shift = event.shift;
                self.interactions[index].pointer = self.pointer;
                break :blk true;
            },
            .release => blk: {
                const held = self.capture orelse break :blk false;
                // A release of a button other than the one being held belongs
                // to whoever was interested in it, and the gesture continues.
                if (held.button != event.button) break :blk false;

                if (self.find(held.id)) |index| {
                    self.interactions[index].capture_ended = event.button;
                    self.interactions[index].shift = held.shift;
                    // Actuated only if the pointer is still on the widget the
                    // press took. Dragging off and letting go is how a click is
                    // taken back.
                    if (event.button == .primary and self.hot == held.id)
                        self.interactions[index].pressed = true;
                    self.interactions[index].pointer = self.pointer;
                }
                self.capture = null;
                break :blk true;
            },
        };
    }

    // Queues committed text for whatever holds the keyboard.
    //
    // A chunk is taken whole or not at all. That is what keeps the buffer on a
    // character boundary: taking the part of a chunk that fits would leave a
    // UTF-8 sequence cut in half, which every reader downstream would then have
    // to handle.
    fn routeText(self: *Context, bytes: []const u8) Error!bool {
        // Text with nothing to type into is not the UI's. A host that binds a
        // character to something of its own keeps that binding until a field
        // has the keyboard.
        if (self.editTarget() == null) return false;

        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidText;

        // Written as the room left rather than as a sum, which cannot overflow.
        // `text_len` never passes `text_buffer.len`, so the subtraction is
        // sound for the same reason the copy below is in range.
        if (bytes.len > self.text_buffer.len - self.text_len)
            return error.TextCapacityExceeded;
        // Reserved before the bytes are copied, so a queue that is full leaves
        // the buffer as it was rather than holding text no entry names.
        const slot = try self.reserveEdit();

        const written = self.text_buffer[self.text_len..][0..bytes.len];
        @memcpy(written, bytes);
        self.text_len += bytes.len;
        slot.* = .{ .insert = written };
        return true;
    }

    // Queues one motion or editing key for whatever holds the keyboard.
    fn routeEditKey(self: *Context, event: KeyEvent) Error!bool {
        if (self.editTarget() == null) return false;
        // The release is not an operation. The press and every repeat under it
        // are, which is what makes a held arrow travel.
        if (event.action == .release) return true;

        const slot = try self.reserveEdit();
        slot.* = .{ .key = .{
            .key = event.key,
            .shift = event.shift,
            .control = event.control,
        } };
        return true;
    }

    // The region an edit belongs to, or nothing when the keyboard is not on a
    // region that can take one.
    //
    // Clearing the queue on a change of owner is here rather than at each
    // caller: focus moves inside a frame, and what was queued before the move
    // belongs to a widget that will not be asked for it. Dropping it is the
    // only answer that does not hand one widget's typing to another.
    fn editTarget(self: *Context) ?Id {
        if (!self.window_focused) return null;
        const index = self.focusedIndex() orelse return null;
        const owner = self.regions[index].id;
        if (self.edit_owner != owner) {
            self.edit_count = 0;
            self.text_len = 0;
            self.edit_owner = owner;
        }
        return owner;
    }

    fn reserveEdit(self: *Context) Error!*Edit {
        if (self.edit_count == self.edits.len) return error.EditCapacityExceeded;
        const slot = &self.edits[self.edit_count];
        self.edit_count += 1;
        return slot;
    }

    // Adds a wheel turn to the innermost scrolling region under the pointer.
    //
    // Not to the hot region. The pointer resolves to the topmost widget it is
    // over, which for a wheel is usually the wrong one: a slider inside a list
    // is what the pointer is on and the list is what the wheel is for.
    fn routeScroll(self: *Context, delta: Point) Error!bool {
        if (!std.math.isFinite(delta.x) or !std.math.isFinite(delta.y))
            return error.InvalidScrollDelta;
        if (!self.window_focused) return false;

        // One gesture at a time, as for a second button pressed during a drag.
        // The wheel is the UI's for as long as the UI holds the pointer, and
        // it moves nothing while a drag is in progress.
        if (self.capture != null) return true;

        const point = self.pointer orelse return false;
        const target = hit_test.hitTestScrollable(self.regions[0..self.region_count], point) orelse
            return false;
        if (self.find(target)) |index| {
            self.interactions[index].scroll.x += delta.x;
            self.interactions[index].scroll.y += delta.y;
        }
        return true;
    }

    // A position that is not finite is refused and changes nothing.
    //
    // The gesture is deliberately left alone. Ending it would let one bad
    // event from the window drop a drag the user is in the middle of, and the
    // last good position is a better answer than no position at all.
    fn setPointer(self: *Context, position: Point) Error!void {
        if (!std.math.isFinite(position.x) or !std.math.isFinite(position.y))
            return error.InvalidPointerPosition;
        self.pointer = position;
        self.updateHot();
    }

    fn routeKey(self: *Context, event: KeyEvent) Error!bool {
        if (!self.window_focused) return false;

        // Queued first and in every case, whatever else the key also does
        // here. Left and right are both: a field reads them off the queue in
        // the order they arrived, and a slider reads their sum off `adjust`.
        // The two answer different questions about the same keystroke.
        const queued = if (isEditKey(event.key)) try self.routeEditKey(event) else false;

        return switch (event.key) {
            .tab => blk: {
                if (event.action == .release) break :blk self.focused != null;
                break :blk self.moveFocus(event.shift);
            },
            .escape => blk: {
                const consumed = self.focused != null;
                if (event.action == .press) self.focused = null;
                break :blk consumed;
            },
            .enter, .space => blk: {
                const index = self.focusedIndex() orelse break :blk false;
                if (event.action == .press) self.interactions[index].pressed = true;
                break :blk true;
            },
            .left, .right, .up, .down => blk: {
                const index = self.focusedIndex() orelse break :blk false;
                if (event.action != .release) {
                    // Up and right increase. Down and left decrease, including
                    // for a vertical control: the axis a widget reads is its
                    // own business and both arrows reach it.
                    const delta: i32 = switch (event.key) {
                        .right, .up => 1,
                        .left, .down => -1,
                        else => unreachable, // The switch above admits four keys.
                    };
                    self.interactions[index].adjust +|= delta;
                }
                break :blk true;
            },
            // Consumed whenever something holds the keyboard, whether or not
            // that widget edits text. A host that acted on a backspace because
            // the focused widget happened to ignore it would be acting on a
            // keystroke the UI took.
            .backspace, .delete, .home, .end => queued,
        };
    }

    // The next focusable region in registration order, wrapping once.
    //
    // Registration order is painter's order, so the tab order is the order the
    // widgets were built in. That is the order the code reads in, which is the
    // only one this module can know: a spatial order would need a notion of
    // reading direction that belongs to whoever writes the layout.
    fn moveFocus(self: *Context, backwards: bool) bool {
        if (self.region_count == 0) return false;

        const current = if (self.focused) |id| self.find(id) else null;
        // Walking from the region after the current one, or from either end
        // when nothing is focused, so that the first tab into a frame lands on
        // the first focusable widget.
        const from = current orelse if (backwards) 0 else self.region_count - 1;
        for (1..self.region_count + 1) |step| {
            const index = if (backwards)
                (from + self.region_count - step) % self.region_count
            else
                (from + step) % self.region_count;
            if (canFocus(self.regions[index])) {
                self.focused = self.regions[index].id;
                return true;
            }
        }

        self.focused = null;
        return false;
    }

    fn focusedIndex(self: *const Context) ?usize {
        const id = self.focused orelse return null;
        const index = self.find(id) orelse return null;
        return if (canFocus(self.regions[index])) index else null;
    }

    fn updateHot(self: *Context) void {
        // A window that does not have focus has no cursor over it as far as
        // this module is concerned, whatever the last position was.
        if (!self.window_focused) {
            self.hot = null;
            return;
        }
        const point = self.pointer orelse {
            self.hot = null;
            return;
        };
        self.hot = hit_test.hitTest(self.regions[0..self.region_count], point);
    }

    // The slot a new identity takes, or `DuplicateId` if the frame already used
    // it.
    //
    // The walk cannot fall through. `initBuffers` requires the table to be at
    // least twice the region capacity and `addRegion` refuses past that
    // capacity, so at most half the slots carry the current epoch and a free
    // one is always reached.
    fn findInsertionSlot(self: *Context, id: Id) Error!usize {
        const start = slotFor(id, self.lookup.len);
        for (0..self.lookup.len) |offset| {
            const index = (start + offset) % self.lookup.len;
            if (self.lookup[index].epoch != self.epoch) return index;
            if (self.lookup[index].id == id) return error.DuplicateId;
        }
        unreachable;
    }

    fn find(self: *const Context, id: Id) ?usize {
        const start = slotFor(id, self.lookup.len);
        for (0..self.lookup.len) |offset| {
            const index = (start + offset) % self.lookup.len;
            // A slot from an earlier frame ends the probe. Insertion took the
            // first such slot from the same starting point, so everything
            // between here and there belongs to this frame and the identity
            // would already have been found.
            if (self.lookup[index].epoch != self.epoch) return null;
            if (self.lookup[index].id == id) return self.lookup[index].region_index;
        }
        return null;
    }
};

fn canFocus(region: Region) bool {
    return region.enabled and region.focusable;
}

// An identity is a Wyhash digest already, so it is not hashed a second time.
// The modulo keeps the low bits, which is where a digest is as well mixed as
// anywhere.
fn slotFor(id: Id, len: usize) usize {
    return @as(usize, @truncate(@backingInt(id))) % len;
}
