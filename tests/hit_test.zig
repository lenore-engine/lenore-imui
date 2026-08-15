const std = @import("std");
const imui = @import("lenore-imui");
const res = @import("lenore-resources");

const testing = std.testing;

const Id = imui.Id;
const Point = imui.Point;
const Region = imui.Region;
const hitTest = imui.hitTest;

const nowhere: res.Rect = .{ .x = -1000, .y = -1000, .width = 4000, .height = 4000 };

fn id(value: u64) Id {
    return @enumFromInt(value);
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

test "adjacent regions share no position" {
    const regions = [_]Region{
        region(1, .{ .x = 0, .y = 0, .width = 10, .height = 10 }),
        region(2, .{ .x = 10, .y = 0, .width = 10, .height = 10 }),
    };
    // The seam belongs to the region that starts there, and to it alone.
    try testing.expectEqual(id(1), hitTest(&regions, .{ .x = 9.999, .y = 5 }));
    try testing.expectEqual(id(2), hitTest(&regions, .{ .x = 10, .y = 5 }));
}
