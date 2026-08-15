const std = @import("std");
const imui = @import("lenore-imui");
const res = @import("lenore-resources");

const testing = std.testing;

const Canvas = imui.Canvas;
const DrawCommand = res.DrawCommand;
const Index = res.DrawIndex;
const ImageHandle = res.ImageHandle;
const Interaction = imui.Interaction;
const LookupSlot = imui.LookupSlot;
const Rect = res.Rect;
const Region = imui.Region;
const Vertex = res.Vertex2D;
const WidgetContext = imui.WidgetContext;

const image: ImageHandle = @enumFromInt(1);
const root: Rect = .{ .x = 0, .y = 0, .width = 200, .height = 100 };
const box: Rect = .{ .x = 10, .y = 10, .width = 60, .height = 20 };

fn colour(value: f32) res.PremultipliedColor {
    const channel: f16 = @floatCast(value);
    return .{ .rgba = .{ channel, channel, channel, 1 } };
}

const flat: imui.ButtonStyle = .{
    .normal_fill = colour(0.1),
    .hovered_fill = colour(0.2),
    .held_fill = colour(0.3),
    .disabled_fill = colour(0.4),
    .border = colour(0.5),
};

const slider_style: imui.SliderStyle = .{
    .track = colour(0.7),
    .disabled_track = colour(0.8),
    .knob = flat,
    .track_thickness = 4,
    .knob_width = 12,
};

fn at(x: f32, y: f32) imui.Point {
    return .{ .x = x, .y = y };
}

fn press(x: f32, y: f32) imui.Event {
    return .{ .pointer_button = .{ .position = at(x, y), .button = .primary, .action = .press } };
}

fn release(x: f32, y: f32) imui.Event {
    return .{ .pointer_button = .{ .position = at(x, y), .button = .primary, .action = .release } };
}

const Fixture = struct {
    regions: [8]Region = undefined,
    interactions: [8]Interaction = undefined,
    lookup: [16]LookupSlot = undefined,
    scopes: [8]imui.Id = undefined,

    vertices: [512]Vertex = undefined,
    indices: [1024]Index = undefined,
    commands: [32]DrawCommand = undefined,
    clips: [8]Rect = undefined,

    input_context: imui.InputContext = undefined,
    canvas: Canvas = undefined,

    fn context(self: *Fixture) !WidgetContext {
        self.input_context = try imui.InputContext.initBuffers(
            &self.regions,
            &self.interactions,
            &self.lookup,
        );
        self.canvas = try Canvas.init(.{
            .vertices = &self.vertices,
            .indices = &self.indices,
            .commands = &self.commands,
            .clips = &self.clips,
        });
        return WidgetContext.init(&self.input_context, &self.canvas, &self.scopes, 0x1234, image);
    }
};

// Registers one button, routes the events, and returns what the button
// reported on the drawing pass.
fn buttonFrame(context: *WidgetContext, events: []const imui.Event, enabled: bool) !bool {
    try context.beginFrame(root);
    try context.register(.{ .string = "ok" }, box, .{ .enabled = enabled, .focusable = true });
    try context.beginRouting();
    for (events) |event| _ = try context.routeEvent(event);
    try context.finishRouting();
    return context.button(.{ .string = "ok" }, box, flat, enabled);
}

test "a context needs an image to sample and room for its scopes" {
    var fixture: Fixture = .{};
    fixture.input_context = try imui.InputContext.initBuffers(
        &fixture.regions,
        &fixture.interactions,
        &fixture.lookup,
    );
    fixture.canvas = try Canvas.init(.{
        .vertices = &fixture.vertices,
        .indices = &fixture.indices,
        .commands = &fixture.commands,
        .clips = &fixture.clips,
    });

    try testing.expectError(error.InvalidImage, WidgetContext.init(
        &fixture.input_context,
        &fixture.canvas,
        &fixture.scopes,
        0,
        @enumFromInt(0),
    ));
    try testing.expectError(error.EmptyStorage, WidgetContext.init(
        &fixture.input_context,
        &fixture.canvas,
        fixture.scopes[0..0],
        0,
        image,
    ));
}

test "each pass refuses what belongs to another" {
    var fixture: Fixture = .{};
    var context = try fixture.context();
    const key: imui.IdKey = .{ .string = "ok" };

    try testing.expectError(error.InvalidPhase, context.register(key, box, .{}));
    try testing.expectError(error.InvalidPhase, context.routeEvent(press(20, 20)));
    try testing.expectError(error.InvalidPhase, context.interaction(key));
    try testing.expectError(error.InvalidPhase, context.drawList());

    try context.beginFrame(root);
    try testing.expectError(error.InvalidPhase, context.beginFrame(root));
    try testing.expectError(error.InvalidPhase, context.routeEvent(press(20, 20)));
    try testing.expectError(error.InvalidPhase, context.interaction(key));
    try context.register(key, box, .{});

    try context.beginRouting();
    try testing.expectError(error.InvalidPhase, context.register(key, box, .{}));
    try testing.expectError(error.InvalidPhase, context.pushId(key));
    try testing.expectError(error.InvalidPhase, context.interaction(key));

    try context.finishRouting();
    try testing.expectError(error.InvalidPhase, context.routeEvent(press(20, 20)));
    _ = try context.interaction(key);
    _ = try context.drawList();
}

test "a scope left open at the end of the registering pass is refused" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    try context.beginFrame(root);
    try context.pushId(.{ .string = "panel" });
    try context.register(.{ .string = "ok" }, box, .{});
    try testing.expectError(error.UnbalancedScopes, context.beginRouting());

    // Popped, and the pass closes.
    context.popId();
    try context.beginRouting();
}

test "a click on a button is reported on the frame it was completed" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    try testing.expect(!try buttonFrame(&context, &.{press(20, 20)}, true));
    try testing.expect(try buttonFrame(&context, &.{release(20, 20)}, true));
    try testing.expect(!try buttonFrame(&context, &.{}, true));
}

test "a press dragged off the button before release does not actuate it" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    _ = try buttonFrame(&context, &.{press(20, 20)}, true);
    try testing.expect(!try buttonFrame(&context, &.{
        .{ .pointer_move = at(150, 80) },
        release(150, 80),
    }, true));
}

test "the keyboard actuates a button that holds focus" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    _ = try buttonFrame(&context, &.{.{ .key = .{ .key = .tab, .action = .press } }}, true);
    try testing.expect(try buttonFrame(&context, &.{
        .{ .key = .{ .key = .enter, .action = .press } },
    }, true));
}

test "a disabled button is not actuated however it is clicked" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    _ = try buttonFrame(&context, &.{press(20, 20)}, false);
    try testing.expect(!try buttonFrame(&context, &.{release(20, 20)}, false));
}

test "one key under two scopes names two widgets" {
    var fixture: Fixture = .{};
    var context = try fixture.context();
    const key: imui.IdKey = .{ .string = "ok" };
    const second: Rect = .{ .x = 100, .y = 10, .width = 60, .height = 20 };

    try context.beginFrame(root);
    try context.pushId(.{ .string = "left" });
    try context.register(key, box, .{});
    context.popId();
    try context.pushId(.{ .string = "right" });
    try context.register(key, second, .{});
    context.popId();

    try context.beginRouting();
    _ = try context.routeEvent(press(120, 20));
    _ = try context.routeEvent(release(120, 20));
    try context.finishRouting();

    // The click landed on the right one, so only that scope reports it.
    try context.pushId(.{ .string = "left" });
    try testing.expect(!try context.button(key, box, flat, true));
    context.popId();
    try context.pushId(.{ .string = "right" });
    try testing.expect(try context.button(key, second, flat, true));
    context.popId();
}

// The one protection there is against the two passes walking differently.
// Nothing can check that they matched without keeping the tree, so what a
// mismatch has to produce is a refusal rather than somebody else's result.
test "reading under a scope the frame did not register is refused" {
    var fixture: Fixture = .{};
    var context = try fixture.context();
    const key: imui.IdKey = .{ .string = "ok" };

    try context.beginFrame(root);
    try context.pushId(.{ .string = "panel" });
    try context.register(key, box, .{});
    context.popId();
    try context.beginRouting();
    try context.finishRouting();

    try testing.expectError(error.UnknownId, context.interaction(key));
    try context.pushId(.{ .string = "other" });
    try testing.expectError(error.UnknownId, context.interaction(key));
    context.popId();

    // And the scope that registered it finds it.
    try context.pushId(.{ .string = "panel" });
    _ = try context.interaction(key);
    context.popId();
}

test "a region takes the clip the registering pass was under" {
    var fixture: Fixture = .{};
    var context = try fixture.context();
    const key: imui.IdKey = .{ .string = "ok" };
    // Half the button's width, so a click on the right half falls outside.
    const half: Rect = .{ .x = 10, .y = 10, .width = 30, .height = 20 };

    try context.beginFrame(root);
    try context.pushClip(half);
    try context.register(key, box, .{});
    context.popClip();
    try context.beginRouting();
    _ = try context.routeEvent(press(60, 20));
    _ = try context.routeEvent(release(60, 20));
    try context.finishRouting();

    // Inside the button and outside its clip, so it was never hit.
    try testing.expect(!try context.button(key, box, flat, true));

    // And the same click on the clipped half does actuate it.
    try context.beginFrame(root);
    try context.pushClip(half);
    try context.register(key, box, .{});
    context.popClip();
    try context.beginRouting();
    _ = try context.routeEvent(press(20, 20));
    _ = try context.routeEvent(release(20, 20));
    try context.finishRouting();
    try testing.expect(try context.button(key, box, flat, true));
}

test "an explicit clip overrides the one the canvas is under" {
    var fixture: Fixture = .{};
    var context = try fixture.context();
    const key: imui.IdKey = .{ .string = "ok" };
    const half: Rect = .{ .x = 10, .y = 10, .width = 30, .height = 20 };

    try context.beginFrame(root);
    try context.pushClip(half);
    try context.register(key, box, .{ .clip = root });
    context.popClip();
    try context.beginRouting();
    _ = try context.routeEvent(press(60, 20));
    _ = try context.routeEvent(release(60, 20));
    try context.finishRouting();

    try testing.expect(try context.button(key, box, flat, true));
}

test "the registering pass leaves no geometry behind" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    try context.beginFrame(root);
    try context.pushClip(.{ .x = 10, .y = 10, .width = 30, .height = 20 });
    try context.register(.{ .string = "ok" }, box, .{});
    context.popClip();
    try context.beginRouting();
    try context.finishRouting();

    // The pass pushed a clip and registered a region and drew nothing, so the
    // drawing pass starts from the root exactly as registration did.
    try testing.expectEqual(0, fixture.canvas.vertexCount());
    try testing.expectEqual(0, fixture.canvas.commands().len);
    try testing.expectEqual(root, fixture.canvas.currentClip());
}

test "a checkbox toggles and shows the value the frame ends with" {
    var fixture: Fixture = .{};
    var context = try fixture.context();
    const key: imui.IdKey = .{ .string = "box" };
    const style: imui.CheckboxStyle = .{ .box = flat, .mark = colour(0.9), .mark_inset = 4 };

    var value = false;
    try context.beginFrame(root);
    try context.register(key, box, .{});
    try context.beginRouting();
    _ = try context.routeEvent(press(20, 20));
    _ = try context.routeEvent(release(20, 20));
    try context.finishRouting();

    const before = fixture.canvas.vertexCount();
    try testing.expect(try context.checkbox(key, box, &value, style, true));
    try testing.expect(value);
    // The tick is drawn on the same frame the click landed, so the checkbox
    // is more than its background.
    try testing.expect(fixture.canvas.vertexCount() > before + 4);

    // A frame with no click leaves it alone.
    try context.beginFrame(root);
    try context.register(key, box, .{});
    try context.beginRouting();
    try context.finishRouting();
    try testing.expect(!try context.checkbox(key, box, &value, style, true));
    try testing.expect(value);
}

test "a slider follows a drag and reports that it moved" {
    var fixture: Fixture = .{};
    var context = try fixture.context();
    const key: imui.IdKey = .{ .string = "gain" };
    const track: Rect = .{ .x = 10, .y = 10, .width = 112, .height = 20 };
    const range: imui.SliderRange = .{ .min = 0, .max = 100 };

    var value: f32 = 0;
    try context.beginFrame(root);
    try context.register(key, track, .{});
    try context.beginRouting();
    // The knob is twelve wide, so the travel is a hundred and the middle of
    // the knob at the far end is at x = 10 + 6 + 100.
    _ = try context.routeEvent(press(16, 20));
    _ = try context.routeEvent(.{ .pointer_move = at(116, 20) });
    try context.finishRouting();

    try testing.expect(try context.slider(key, track, &value, range, slider_style, true));
    try testing.expectApproxEqAbs(100, value, 1e-3);

    // A frame that does nothing to it reports no change.
    try context.beginFrame(root);
    try context.register(key, track, .{});
    try context.beginRouting();
    try context.finishRouting();
    try testing.expect(!try context.slider(key, track, &value, range, slider_style, true));
    try testing.expectApproxEqAbs(100, value, 1e-3);
}

test "a disabled slider does not move" {
    var fixture: Fixture = .{};
    var context = try fixture.context();
    const key: imui.IdKey = .{ .string = "gain" };
    const track: Rect = .{ .x = 10, .y = 10, .width = 112, .height = 20 };
    const range: imui.SliderRange = .{ .min = 0, .max = 100 };

    var value: f32 = 25;
    try context.beginFrame(root);
    try context.register(key, track, .{ .enabled = false });
    try context.beginRouting();
    _ = try context.routeEvent(press(116, 20));
    try context.finishRouting();

    try testing.expect(!try context.slider(key, track, &value, range, slider_style, false));
    try testing.expectApproxEqAbs(25, value, 1e-3);
}

test "a splitter hands back the gesture that is dragging it" {
    var fixture: Fixture = .{};
    var context = try fixture.context();
    const key: imui.IdKey = .{ .string = "split" };
    const style: imui.SplitterStyle = .{
        .normal_fill = colour(0.1),
        .hovered_fill = colour(0.2),
        .held_fill = colour(0.3),
    };

    try context.beginFrame(root);
    try context.register(key, box, .{});
    try context.beginRouting();
    _ = try context.routeEvent(press(20, 20));
    _ = try context.routeEvent(.{ .pointer_move = at(45, 25) });
    try context.finishRouting();

    const state = try context.splitter(key, box, style);
    try testing.expectEqual(.primary, state.capture.?);
    try testing.expectEqual(at(45, 25), state.pointer.?);
}

test "a frame draws through the same canvas the caller can reach" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    try context.beginFrame(root);
    try context.register(.{ .string = "ok" }, box, .{});
    try context.beginRouting();
    try context.finishRouting();
    _ = try context.button(.{ .string = "ok" }, box, flat, true);

    const list = try context.drawList();
    try testing.expectEqual(&fixture.canvas, list);
    try testing.expect(list.vertexCount() > 0);
}

test "a clip left open at the end of the registering pass is refused" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    try context.beginFrame(root);
    try context.pushClip(.{ .x = 10, .y = 10, .width = 30, .height = 20 });
    try context.register(.{ .string = "ok" }, box, .{});
    // Every region after the one that opened it would take a clip its caller
    // did not mean, which is the mistake an open scope is.
    try testing.expectError(error.UnbalancedScopes, context.beginRouting());

    context.popClip();
    try context.beginRouting();
}

// The two `enabled` flags are the caller's to keep in step, and this is what
// happens when it does not: the region was live so the click routed to it, and
// the widget drawn as disabled refuses to act on the result.
test "a widget registered live and drawn disabled does not actuate" {
    var fixture: Fixture = .{};
    var context = try fixture.context();
    const key: imui.IdKey = .{ .string = "ok" };

    try context.beginFrame(root);
    try context.register(key, box, .{ .enabled = true });
    try context.beginRouting();
    _ = try context.routeEvent(press(20, 20));
    _ = try context.routeEvent(release(20, 20));
    try context.finishRouting();

    try testing.expect(!try context.button(key, box, flat, false));
}

test "a slider's knob is drawn where the drag put it, on the same frame" {
    var fixture: Fixture = .{};
    var context = try fixture.context();
    const key: imui.IdKey = .{ .string = "gain" };
    const track: Rect = .{ .x = 10, .y = 10, .width = 112, .height = 20 };
    const range: imui.SliderRange = .{ .min = 0, .max = 100 };

    var value: f32 = 0;
    try context.beginFrame(root);
    try context.register(key, track, .{});
    try context.beginRouting();
    _ = try context.routeEvent(press(16, 20));
    _ = try context.routeEvent(.{ .pointer_move = at(116, 20) });
    try context.finishRouting();
    _ = try context.slider(key, track, &value, range, slider_style, true);

    // The knob is the only part drawn in the button style, so the darker
    // vertices are its own. Drawing from the value the frame began with would
    // leave it at the left edge while the value reads a hundred.
    var rightmost: f32 = -1e9;
    for (fixture.vertices[0..fixture.canvas.vertexCount()]) |vertex| {
        if (@as(f32, @floatCast(vertex.colour.rgba[0])) > 0.6) continue;
        rightmost = @max(rightmost, vertex.position[0]);
    }
    try testing.expectApproxEqAbs(track.x + track.width, rightmost, 1e-3);
}

test "a frame abandoned part-way does not refuse the next one" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    // The shape a caller fails in: a scope opened, a region registered under
    // it, and then something goes wrong before the pass is closed.
    try context.beginFrame(root);
    try context.pushId(.{ .string = "panel" });
    try context.pushClip(box);
    try context.register(.{ .string = "ok" }, box, .{});
    try testing.expectError(error.InvalidPhase, context.beginFrame(root));

    context.abandonFrame();

    // A whole frame, from a context that was left mid-registration with both
    // stacks open. The button answering at all says the pass was reopened; the
    // click landing on it says the identity was derived at the root, because
    // the scope the abandoned frame left open would have named another widget.
    try testing.expect(try buttonFrame(&context, &.{
        press(box.x + 1, box.y + 1),
        release(box.x + 1, box.y + 1),
    }, true));
}

test "abandoning a frame keeps the gesture the pointer is still making" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    try context.beginFrame(root);
    try context.register(.{ .string = "ok" }, box, .{});
    try context.beginRouting();
    _ = try context.routeEvent(press(box.x + 1, box.y + 1));
    try context.finishRouting();
    try testing.expectEqual(
        imui.PointerButton.primary,
        (try context.interaction(.{ .string = "ok" })).capture,
    );

    // The button is still held down while the frame that would have observed
    // the release is dropped. A capture belongs to the pointer rather than to
    // a frame, so the release still actuates the widget that took it, and a
    // widget that had lost its capture would report nothing.
    try context.beginFrame(root);
    try context.register(.{ .string = "ok" }, box, .{});
    context.abandonFrame();

    try testing.expect(try buttonFrame(&context, &.{
        release(box.x + 1, box.y + 1),
    }, true));
}

// A caption of two glyphs against a face whose numbers are whole, so the
// baseline the façade draws on is one the test can name.
const label_ink: res.GlyphPlacement = .{
    .left = 0,
    .top = 12,
    .width = 8,
    .height = 14,
    .u_min = 0,
    .v_min = 0,
    .u_max = 0.125,
    .v_max = 0.125,
};

const label_glyphs = [_]res.ShapedGlyph{
    .{ .index = 1, .cluster = 0, .x_advance = 10, .y_advance = 0, .x_offset = 0, .y_offset = 0 },
    .{ .index = 2, .cluster = 1, .x_advance = 10, .y_advance = 0, .x_offset = 0, .y_offset = 0 },
};
const label_placements = [_]res.GlyphPlacement{ label_ink, label_ink };

const atlas: ImageHandle = @enumFromInt(2);

const caption: imui.Label = .{
    .run = .{ .glyphs = &label_glyphs, .placements = &label_placements, .buckets = .whole },
    .metrics = .{ .ascent = 16, .descent = -4, .line_gap = 6 },
    .advance = 20,
    .atlas = atlas,
};

const caption_style: imui.LabelStyle = .{
    .normal_text = colour(0.9),
    .disabled_text = colour(0.4),
};

test "a label is drawn without a key and only while the frame is drawing" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    try context.beginFrame(root);
    // Not while the regions are being registered: geometry emitted there would
    // belong to a frame nothing has been routed against.
    try testing.expectError(
        error.InvalidPhase,
        context.label(box, caption_style, caption, true),
    );
    try context.beginRouting();
    try context.finishRouting();

    try context.label(box, caption_style, caption, true);

    // Both glyphs, sampled from the atlas the caption named rather than from
    // the white image the context holds for its fills.
    try testing.expectEqual(8, fixture.canvas.vertexCount());
    try testing.expectEqual(1, fixture.canvas.commands().len);
    try testing.expectEqual(atlas, fixture.canvas.commands()[0].image);
}

test "a caption and the widget under it are one call each" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    try context.beginFrame(root);
    try context.register(.{ .string = "ok" }, box, .{});
    try context.beginRouting();
    try context.finishRouting();

    _ = try context.button(.{ .string = "ok" }, box, flat, true);
    const background = fixture.canvas.commands().len;
    try context.label(box, caption_style, caption, true);

    // The caption samples a different image, so it cannot merge into the draw
    // the button just made. That is the cost of text over a fill and it is
    // worth seeing in a test rather than discovering in a frame capture.
    try testing.expectEqual(background + 1, fixture.canvas.commands().len);
}
