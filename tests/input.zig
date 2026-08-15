const std = @import("std");
const imui = @import("lenore-imui");
const res = @import("lenore-resources");

const testing = std.testing;

const Context = imui.InputContext;
const Interaction = imui.Interaction;
const LookupSlot = imui.LookupSlot;
const Point = imui.Point;
const Region = imui.Region;
const Token = imui.Token;

const everywhere: res.Rect = .{ .x = -1000, .y = -1000, .width = 4000, .height = 4000 };

fn id(value: u64) imui.Id {
    return @enumFromInt(value);
}

fn at(x: f32, y: f32) Point {
    return .{ .x = x, .y = y };
}

fn press(x: f32, y: f32) imui.Event {
    return .{ .pointer_button = .{ .position = at(x, y), .button = .primary, .action = .press } };
}

fn release(x: f32, y: f32) imui.Event {
    return .{ .pointer_button = .{ .position = at(x, y), .button = .primary, .action = .release } };
}

fn key(which: imui.Key, action: imui.KeyAction, shift: bool) imui.Event {
    return .{ .key = .{ .key = which, .action = action, .shift = shift } };
}

const Fixture = struct {
    regions: [8]Region = undefined,
    interactions: [8]Interaction = undefined,
    // Deliberately uninitialised: emptying the table is `initBuffers`'s job.
    lookup: [16]LookupSlot = undefined,

    fn context(self: *Fixture) !Context {
        return Context.initBuffers(&self.regions, &self.interactions, &self.lookup);
    }
};

// A region ten by ten with its top-left at (x, 0), clipped by nothing.
fn box(value: u64, x: f32) Region {
    return .{
        .id = id(value),
        .rect = .{ .x = x, .y = 0, .width = 10, .height = 10 },
        .clip = everywhere,
    };
}

fn focusable(value: u64, x: f32) Region {
    var result = box(value, x);
    result.focusable = true;
    return result;
}

// Registers the regions given, routes the events given, and closes the frame.
fn frame(context: *Context, regions: []const Region, events: []const imui.Event) ![]Token {
    const storage = struct {
        var tokens: [8]Token = undefined;
    };
    try context.beginFrame();
    for (regions, 0..) |region, index| storage.tokens[index] = try context.addRegion(region);
    try context.beginRouting();
    for (events) |event| _ = try context.routeEvent(event);
    try context.finishRouting();
    return storage.tokens[0..regions.len];
}

test "the storage a context is built over has to cover what it will hold" {
    var regions: [4]Region = undefined;
    var interactions: [4]Interaction = undefined;
    var lookup: [8]LookupSlot = undefined;

    try testing.expectError(error.EmptyStorage, Context.initBuffers(regions[0..0], &interactions, &lookup));
    try testing.expectError(
        error.StorageTooSmall,
        Context.initBuffers(&regions, interactions[0..3], &lookup),
    );
    // Linear probing wants half the table free, so the requirement is twice
    // the region capacity and not merely as much.
    try testing.expectError(
        error.StorageTooSmall,
        Context.initBuffers(&regions, &interactions, lookup[0..7]),
    );
    _ = try Context.initBuffers(&regions, &interactions, &lookup);
}

test "each phase refuses what belongs to another" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    try testing.expectError(error.InvalidPhase, context.addRegion(box(1, 0)));
    try testing.expectError(error.InvalidPhase, context.routeEvent(.{ .pointer_move = at(5, 5) }));
    try testing.expectError(error.InvalidPhase, context.beginRouting());

    try context.beginFrame();
    // Dropping the regions with routing under way would route the rest of the
    // frame against nothing.
    try testing.expectError(error.InvalidPhase, context.beginFrame());
    const token = try context.addRegion(box(1, 0));
    try testing.expectError(error.InvalidPhase, context.interaction(token));

    try context.beginRouting();
    try testing.expectError(error.InvalidPhase, context.addRegion(box(2, 20)));
    try testing.expectError(error.InvalidPhase, context.beginFrame());

    try context.finishRouting();
    try testing.expectError(error.InvalidPhase, context.routeEvent(.{ .pointer_move = at(5, 5) }));
    _ = try context.interaction(token);
}

test "a region is refused where its identity or its geometry is ill-formed" {
    const nan = std.math.nan(f32);
    var fixture: Fixture = .{};
    var context = try fixture.context();
    try context.beginFrame();

    var without_id = box(1, 0);
    without_id.id = .invalid;
    try testing.expectError(error.InvalidRegion, context.addRegion(without_id));

    var bad_rect = box(1, 0);
    bad_rect.rect.width = nan;
    try testing.expectError(error.InvalidRegion, context.addRegion(bad_rect));

    var bad_clip = box(1, 0);
    bad_clip.clip.height = -1;
    try testing.expectError(error.InvalidRegion, context.addRegion(bad_clip));
}

test "one identity registered twice in a frame is refused" {
    var fixture: Fixture = .{};
    var context = try fixture.context();
    try context.beginFrame();

    _ = try context.addRegion(box(1, 0));
    try testing.expectError(error.DuplicateId, context.addRegion(box(1, 20)));
    // And the same identity in the next frame is fine, which is the whole
    // point of an immediate-mode identity.
    try context.beginRouting();
    try context.finishRouting();
    try context.beginFrame();
    _ = try context.addRegion(box(1, 0));
}

test "registration stops at the region capacity" {
    var fixture: Fixture = .{};
    var context = try fixture.context();
    try context.beginFrame();

    for (0..8) |index| _ = try context.addRegion(box(index + 1, @floatFromInt(index * 20)));
    try testing.expectError(error.RegionCapacityExceeded, context.addRegion(box(99, 400)));
}

test "a token does not survive the frame it was issued in" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    const first = (try frame(&context, &.{box(1, 0)}, &.{}))[0];
    _ = try context.interaction(first);

    _ = try frame(&context, &.{box(1, 0)}, &.{});
    try testing.expectError(error.StaleToken, context.interaction(first));
}

test "the pointer hovers the region it is over and no other" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    const tokens = try frame(&context, &.{ box(1, 0), box(2, 20) }, &.{
        .{ .pointer_move = at(5, 5) },
    });

    const first = try context.interaction(tokens[0]);
    const second = try context.interaction(tokens[1]);
    try testing.expect(first.hovered);
    try testing.expect(!second.hovered);
    try testing.expectEqual(at(5, 5), first.pointer.?);
}

test "the region registered last is the one hovered where they overlap" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    const tokens = try frame(&context, &.{ box(1, 0), box(2, 0) }, &.{
        .{ .pointer_move = at(5, 5) },
    });

    try testing.expect(!(try context.interaction(tokens[0])).hovered);
    try testing.expect((try context.interaction(tokens[1])).hovered);
}

test "a press and a release on one region actuate it" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    const tokens = try frame(&context, &.{box(1, 0)}, &.{ press(5, 5), release(5, 5) });
    const result = try context.interaction(tokens[0]);

    try testing.expectEqual(.primary, result.capture_began.?);
    try testing.expectEqual(.primary, result.capture_ended.?);
    try testing.expect(result.pressed);
    // The capture ended within the frame, so nothing is held at the end of it.
    try testing.expectEqual(null, result.capture);
}

test "a press dragged off the region and released does not actuate it" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    const tokens = try frame(&context, &.{ box(1, 0), box(2, 20) }, &.{
        press(5, 5),
        .{ .pointer_move = at(25, 5) },
        release(25, 5),
    });

    const dragged_from = try context.interaction(tokens[0]);
    try testing.expectEqual(.primary, dragged_from.capture_ended.?);
    try testing.expect(!dragged_from.pressed);
    // And the region it was released over gets nothing: the gesture belonged
    // to the one that took the press.
    const released_over = try context.interaction(tokens[1]);
    try testing.expectEqual(null, released_over.capture_ended);
    try testing.expect(!released_over.pressed);
}

test "a held region keeps the capture while the pointer leaves it" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    _ = try frame(&context, &.{ box(1, 0), box(2, 20) }, &.{press(5, 5)});
    const tokens = try frame(&context, &.{ box(1, 0), box(2, 20) }, &.{
        .{ .pointer_move = at(25, 5) },
    });

    const held = try context.interaction(tokens[0]);
    try testing.expectEqual(.primary, held.capture.?);
    try testing.expect(!held.hovered);
    // Hover follows the pointer even while somebody else holds it.
    try testing.expect((try context.interaction(tokens[1])).hovered);
}

test "a capture is dropped when its region goes away or is disabled" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    _ = try frame(&context, &.{box(1, 0)}, &.{press(5, 5)});
    // Registered no more.
    const gone = try frame(&context, &.{box(2, 20)}, &.{});
    try testing.expectEqual(null, (try context.interaction(gone[0])).capture);

    _ = try frame(&context, &.{box(1, 0)}, &.{press(5, 5)});
    var disabled = box(1, 0);
    disabled.enabled = false;
    const tokens = try frame(&context, &.{disabled}, &.{});
    try testing.expectEqual(null, (try context.interaction(tokens[0])).capture);
}

test "one gesture at a time" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    try context.beginFrame();
    const first = try context.addRegion(box(1, 0));
    const second = try context.addRegion(box(2, 20));
    try context.beginRouting();

    try testing.expect(try context.routeEvent(press(5, 5)));
    // A second button during the drag is taken and otherwise ignored.
    try testing.expect(try context.routeEvent(.{ .pointer_button = .{
        .position = at(25, 5),
        .button = .secondary,
        .action = .press,
    } }));
    try context.finishRouting();

    try testing.expectEqual(.primary, (try context.interaction(first)).capture.?);
    try testing.expectEqual(null, (try context.interaction(second)).capture_began);
}

test "releasing a button other than the one held leaves the gesture alone" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    try context.beginFrame();
    const token = try context.addRegion(box(1, 0));
    try context.beginRouting();

    _ = try context.routeEvent(press(5, 5));
    try testing.expect(!try context.routeEvent(.{ .pointer_button = .{
        .position = at(5, 5),
        .button = .middle,
        .action = .release,
    } }));
    try context.finishRouting();

    try testing.expectEqual(.primary, (try context.interaction(token)).capture.?);
}

test "a non-primary gesture captures without actuating" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    const middle_press: imui.Event = .{ .pointer_button = .{
        .position = at(5, 5),
        .button = .middle,
        .action = .press,
    } };
    const middle_release: imui.Event = .{ .pointer_button = .{
        .position = at(5, 5),
        .button = .middle,
        .action = .release,
    } };
    const tokens = try frame(&context, &.{box(1, 0)}, &.{ middle_press, middle_release });
    const result = try context.interaction(tokens[0]);

    try testing.expectEqual(.middle, result.capture_began.?);
    try testing.expectEqual(.middle, result.capture_ended.?);
    try testing.expect(!result.pressed);
}

test "shift is held from the press through to the release" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    const shifted: imui.Event = .{ .pointer_button = .{
        .position = at(5, 5),
        .button = .primary,
        .action = .press,
        .shift = true,
    } };
    // Released without the modifier, which must not undo the constraint the
    // gesture began under.
    const tokens = try frame(&context, &.{box(1, 0)}, &.{ shifted, release(5, 5) });
    try testing.expect((try context.interaction(tokens[0])).shift);
}

test "a primary press moves the keyboard to what it landed on" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    const tokens = try frame(
        &context,
        &.{ focusable(1, 0), box(2, 20) },
        &.{ press(5, 5), release(5, 5) },
    );
    try testing.expect((try context.interaction(tokens[0])).focused);

    // Onto a region that cannot take the keyboard, which clears it rather than
    // leaving it behind on the last one.
    const after = try frame(
        &context,
        &.{ focusable(1, 0), box(2, 20) },
        &.{ press(25, 5), release(25, 5) },
    );
    try testing.expect(!(try context.interaction(after[0])).focused);
    try testing.expect(!(try context.interaction(after[1])).focused);
}

test "a press on nothing clears the keyboard" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    _ = try frame(&context, &.{focusable(1, 0)}, &.{ press(5, 5), release(5, 5) });
    const tokens = try frame(&context, &.{focusable(1, 0)}, &.{ press(500, 500), release(500, 500) });
    try testing.expect(!(try context.interaction(tokens[0])).focused);
}

test "tab walks the focusable regions in registration order and wraps" {
    var fixture: Fixture = .{};
    var context = try fixture.context();
    const regions = [_]Region{ focusable(1, 0), box(2, 20), focusable(3, 40) };

    // The first tab into a frame lands on the first focusable region, and the
    // one between them is skipped rather than taking a stop of its own.
    var tokens = try frame(&context, &regions, &.{key(.tab, .press, false)});
    try testing.expect((try context.interaction(tokens[0])).focused);

    tokens = try frame(&context, &regions, &.{key(.tab, .press, false)});
    try testing.expect((try context.interaction(tokens[2])).focused);

    // And round again.
    tokens = try frame(&context, &regions, &.{key(.tab, .press, false)});
    try testing.expect((try context.interaction(tokens[0])).focused);

    // Backwards from the first is the last.
    tokens = try frame(&context, &regions, &.{key(.tab, .press, true)});
    try testing.expect((try context.interaction(tokens[2])).focused);
}

test "tab over a frame with nothing focusable takes nothing" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    try context.beginFrame();
    const token = try context.addRegion(box(1, 0));
    try context.beginRouting();
    try testing.expect(!try context.routeEvent(key(.tab, .press, false)));
    try context.finishRouting();

    try testing.expect(!(try context.interaction(token)).focused);
}

test "escape gives the keyboard up and says it did" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    _ = try frame(&context, &.{focusable(1, 0)}, &.{key(.tab, .press, false)});

    try context.beginFrame();
    const token = try context.addRegion(focusable(1, 0));
    try context.beginRouting();
    try testing.expect(try context.routeEvent(key(.escape, .press, false)));
    // Nothing focused, so the next one is not the UI's to take.
    try testing.expect(!try context.routeEvent(key(.escape, .press, false)));
    try context.finishRouting();

    try testing.expect(!(try context.interaction(token)).focused);
}

test "the keyboard actuates what it holds" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    _ = try frame(&context, &.{focusable(1, 0)}, &.{key(.tab, .press, false)});
    const tokens = try frame(&context, &.{focusable(1, 0)}, &.{key(.enter, .press, false)});
    try testing.expect((try context.interaction(tokens[0])).pressed);

    const spaced = try frame(&context, &.{focusable(1, 0)}, &.{key(.space, .press, false)});
    try testing.expect((try context.interaction(spaced[0])).pressed);
}

test "the arrows accumulate a signed adjustment over presses and repeats" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    _ = try frame(&context, &.{focusable(1, 0)}, &.{key(.tab, .press, false)});
    const tokens = try frame(&context, &.{focusable(1, 0)}, &.{
        key(.right, .press, false),
        key(.right, .repeat, false),
        key(.up, .repeat, false),
        key(.left, .press, false),
        // A release contributes nothing and is still the UI's event.
        key(.left, .release, false),
        key(.down, .press, false),
    });

    try testing.expectEqual(1, (try context.interaction(tokens[0])).adjust);
}

test "losing the window ends the gesture and takes the keyboard with it" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    _ = try frame(&context, &.{focusable(1, 0)}, &.{ key(.tab, .press, false), press(5, 5) });
    const tokens = try frame(&context, &.{focusable(1, 0)}, &.{.{ .focus = false }});
    const result = try context.interaction(tokens[0]);

    try testing.expectEqual(null, result.capture);
    try testing.expect(!result.focused);
    try testing.expect(!result.hovered);
}

test "a cancel takes back what the frame had already recorded" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    try context.beginFrame();
    const token = try context.addRegion(box(1, 0));
    try context.beginRouting();
    _ = try context.routeEvent(press(5, 5));
    try testing.expect(try context.routeEvent(.cancel));
    try context.finishRouting();

    const result = try context.interaction(token);
    try testing.expectEqual(null, result.capture);
    try testing.expectEqual(null, result.capture_began);
    try testing.expect(!result.hovered);
}

test "a pointer position that is not finite is refused and changes nothing" {
    const nan = std.math.nan(f32);
    var fixture: Fixture = .{};
    var context = try fixture.context();

    try context.beginFrame();
    const token = try context.addRegion(box(1, 0));
    try context.beginRouting();

    _ = try context.routeEvent(press(5, 5));
    try testing.expectError(
        error.InvalidPointerPosition,
        context.routeEvent(.{ .pointer_move = at(nan, 5) }),
    );
    try context.finishRouting();

    // The gesture is untouched: one bad event from the window does not drop a
    // drag the user is in the middle of.
    const result = try context.interaction(token);
    try testing.expectEqual(.primary, result.capture.?);
    try testing.expectEqual(at(5, 5), result.pointer.?);
}

test "an event over the UI is reported taken and one over nothing is not" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    try context.beginFrame();
    _ = try context.addRegion(box(1, 0));
    try context.beginRouting();

    try testing.expect(try context.routeEvent(.{ .pointer_move = at(5, 5) }));
    try testing.expect(!try context.routeEvent(.{ .pointer_move = at(500, 500) }));
    try testing.expect(!try context.routeEvent(press(500, 500)));
    try context.finishRouting();
}

test "the identity index survives the epoch wrapping" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    // One frame under the old epoch, so the table carries slots that the
    // wrapped counter would otherwise read as belonging to the new one.
    _ = try frame(&context, &.{ box(1, 0), box(2, 20) }, &.{});
    context.epoch = std.math.maxInt(u32);

    const tokens = try frame(&context, &.{ box(1, 0), box(2, 20) }, &.{
        .{ .pointer_move = at(25, 5) },
    });
    try testing.expectEqual(1, context.epoch);
    try testing.expect(!(try context.interaction(tokens[0])).hovered);
    try testing.expect((try context.interaction(tokens[1])).hovered);
}

test "every identity of a full frame is found again" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    var regions: [8]Region = undefined;
    for (&regions, 0..) |*region, index|
        region.* = box(index + 1, @floatFromInt(index * 20));

    // The pointer is on the last one, which is only reported if the index
    // resolved every identity ahead of it as well.
    const tokens = try frame(&context, &regions, &.{.{ .pointer_move = at(145, 5) }});
    for (tokens, 0..) |token, index| {
        const result = try context.interaction(token);
        try testing.expectEqual(index == 7, result.hovered);
    }
}

test "the identity index is emptied where the context is built" {
    var fixture: Fixture = .{};
    // Storage that reads as a full table belonging to the first frame. Left
    // as it is, every lookup of that frame walks the whole table and finds
    // neither the identity it wants nor a free slot to put one in.
    for (&fixture.lookup) |*slot| slot.* = .{ .id = .invalid, .region_index = 0, .epoch = 1 };

    var context = try fixture.context();
    const tokens = try frame(&context, &.{ box(1, 0), box(2, 20) }, &.{
        .{ .pointer_move = at(5, 5) },
    });
    try testing.expect((try context.interaction(tokens[0])).hovered);
}

test "a window without focus has nothing hovered even as the pointer moves over it" {
    var fixture: Fixture = .{};
    var context = try fixture.context();

    try context.beginFrame();
    const token = try context.addRegion(box(1, 0));
    try context.beginRouting();

    // A compositor delivers motion to a window that does not have focus, and a
    // widget lighting up under a pointer the user is not directing at it reads
    // as the window having taken focus back.
    _ = try context.routeEvent(.{ .focus = false });
    try testing.expect(!try context.routeEvent(.{ .pointer_move = at(5, 5) }));
    try context.finishRouting();
    try testing.expect(!(try context.interaction(token)).hovered);

    // And it comes back with the focus, from the position already known.
    try context.beginFrame();
    const back = try context.addRegion(box(1, 0));
    try context.beginRouting();
    _ = try context.routeEvent(.{ .focus = true });
    _ = try context.routeEvent(.{ .pointer_move = at(5, 5) });
    try context.finishRouting();
    try testing.expect((try context.interaction(back)).hovered);
}
