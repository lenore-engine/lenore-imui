const std = @import("std");
const imui = @import("lenore-imui");
const res = @import("lenore-resources");

const testing = std.testing;

const Id = imui.Id;
const Point = imui.Point;
const Region = imui.Region;
const hitTest = imui.hitTest;
const hitTestScrollable = imui.hitTestScrollable;

const nowhere: res.Rect = .{ .x = -1000, .y = -1000, .width = 4000, .height = 4000 };

fn id(value: u64) Id {
    return @fromBackingInt(@intCast(value));
}

fn region(value: u64, rect: res.Rect) Region {
    return .{ .id = id(value), .rect = rect, .clip = nowhere };
}

test "nothing is hit over no regions" {
    try testing.expectEqual(null, hitTest(&.{}, .{ .x = 0, .y = 0 }));
}

test "a position inside one region names it" {
    const regions = [_]Region{region(7, .{ .x = 10, .y = 10, .width = 20, .height = 20 })};
    try testing.expectEqual(id(7), hitTest(&regions, .{ .x = 15, .y = 15 }));
    try testing.expectEqual(null, hitTest(&regions, .{ .x = 5, .y = 15 }));
}

test "the region registered last is the one on top" {
    const rect: res.Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const regions = [_]Region{ region(1, rect), region(2, rect) };
    try testing.expectEqual(id(2), hitTest(&regions, .{ .x = 5, .y = 5 }));
}

test "a disabled region lets the one beneath it answer" {
    const rect: res.Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    var regions = [_]Region{ region(1, rect), region(2, rect) };
    regions[1].enabled = false;
    try testing.expectEqual(id(1), hitTest(&regions, .{ .x = 5, .y = 5 }));
}

test "the clip bounds the hit and not only the drawing" {
    var only = region(3, .{ .x = 0, .y = 0, .width = 100, .height = 100 });
    only.clip = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const regions = [_]Region{only};

    try testing.expectEqual(id(3), hitTest(&regions, .{ .x = 5, .y = 5 }));
    // Inside the layout rectangle, outside what the frame showed of it.
    try testing.expectEqual(null, hitTest(&regions, .{ .x = 50, .y = 50 }));
}

test "a region without an identity is never the answer" {
    // Its rectangle contains the position, so only the identity keeps it out.
    // Without that the caller would receive a non-null `.invalid`.
    const regions = [_]Region{region(0, .{ .x = 0, .y = 0, .width = 10, .height = 10 })};
    try testing.expectEqual(null, hitTest(&regions, .{ .x = 5, .y = 5 }));
}

test "ill-formed geometry is hit by nothing rather than by everything" {
    const nan = std.math.nan(f32);
    const regions = [_]Region{
        region(1, .{ .x = nan, .y = 0, .width = 10, .height = 10 }),
        region(2, .{ .x = 0, .y = 0, .width = nan, .height = 10 }),
        region(3, .{ .x = 0, .y = 0, .width = -10, .height = -10 }),
    };
    try testing.expectEqual(null, hitTest(&regions, .{ .x = 5, .y = 5 }));

    // And a position that is not finite falls on no well-formed region either.
    const sound = [_]Region{region(4, .{ .x = 0, .y = 0, .width = 10, .height = 10 })};
    try testing.expectEqual(null, hitTest(&sound, .{ .x = nan, .y = 5 }));
}

// The case the flag exists for. A widget that does not scroll sits over one
// that does, the pointer is on the widget, and the wheel belongs to the region
// beneath it. Nothing in the pointer's own answer changes.
test "the wheel reaches past a region that does not scroll" {
    const rect: res.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    var regions = [_]Region{
        region(1, rect),
        region(2, .{ .x = 10, .y = 10, .width = 20, .height = 20 }),
    };
    regions[0].scrollable = true;

    const inside: Point = .{ .x = 15, .y = 15 };
    try testing.expectEqual(id(2), hitTest(&regions, inside));
    try testing.expectEqual(id(1), hitTestScrollable(&regions, inside));
}

// Painter's order is the whole of the nesting rule, so an inner list needs no
// notion of a parent to win over the one it sits in.
test "the innermost scrolling region is the one that answers" {
    var regions = [_]Region{
        region(1, .{ .x = 0, .y = 0, .width = 100, .height = 100 }),
        region(2, .{ .x = 10, .y = 10, .width = 40, .height = 40 }),
    };
    regions[0].scrollable = true;
    regions[1].scrollable = true;

    try testing.expectEqual(id(2), hitTestScrollable(&regions, .{ .x = 20, .y = 20 }));
    // Outside the inner one, still inside the outer.
    try testing.expectEqual(id(1), hitTestScrollable(&regions, .{ .x = 70, .y = 70 }));
}

test "a frame with nothing to scroll answers nothing" {
    const regions = [_]Region{region(1, .{ .x = 0, .y = 0, .width = 10, .height = 10 })};
    // The position is on a region, which is what makes this the interesting
    // answer: a host reads it to decide whether the wheel was the UI's.
    try testing.expectEqual(id(1), hitTest(&regions, .{ .x = 5, .y = 5 }));
    try testing.expectEqual(null, hitTestScrollable(&regions, .{ .x = 5, .y = 5 }));
}

test "a disabled region does not scroll either" {
    const rect: res.Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    var regions = [_]Region{ region(1, rect), region(2, rect) };
    regions[0].scrollable = true;
    regions[1].scrollable = true;
    regions[1].enabled = false;

    try testing.expectEqual(id(1), hitTestScrollable(&regions, .{ .x = 5, .y = 5 }));
}

test "adjacent regions share no position" {
    const regions = [_]Region{
        region(1, .{ .x = 0, .y = 0, .width = 10, .height = 10 }),
        region(2, .{ .x = 10, .y = 0, .width = 10, .height = 10 }),
    };
    // The seam belongs to the region that starts there, and to it alone.
    try testing.expectEqual(id(1), hitTest(&regions, .{ .x = 9.999, .y = 5 }));
    try testing.expectEqual(id(2), hitTest(&regions, .{ .x = 10, .y = 5 }));
}
