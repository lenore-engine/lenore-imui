const std = @import("std");
const imui = @import("lenore-imui");

const testing = std.testing;

const LogicalRect = imui.LogicalRect;
const LogicalSize = imui.LogicalSize;
const Node = imui.LayoutNode;
const NodeIndex = imui.NodeIndex;
const Tree = imui.LayoutTree;
const Workspace = imui.Workspace;

const root_rect: LogicalRect = .{ .x = 0, .y = 0, .width = 100, .height = 60 };

const Fixture = struct {
    parents: [16]NodeIndex = undefined,
    order: [16]NodeIndex = undefined,
    measured: [16]LogicalSize = undefined,
    scratch: [16]LogicalRect = undefined,
    results: [16]LogicalRect = undefined,

    fn workspace(self: *Fixture) Workspace {
        return .{
            .parents = &self.parents,
            .order = &self.order,
            .measured = &self.measured,
            .rects = &self.scratch,
        };
    }

    fn solve(self: *Fixture, nodes: []const Node, children: []const NodeIndex, rect: LogicalRect) !void {
        return imui.solveLayout(.{ .nodes = nodes, .children = children }, rect, self.workspace(), &self.results);
    }
};

fn fixed(width: f32, height: f32) Node {
    return .{ .width = .{ .fixed = width }, .height = .{ .fixed = height } };
}

fn expectRect(expected: LogicalRect, actual: LogicalRect) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, 1e-4);
    try testing.expectApproxEqAbs(expected.y, actual.y, 1e-4);
    try testing.expectApproxEqAbs(expected.width, actual.width, 1e-4);
    try testing.expectApproxEqAbs(expected.height, actual.height, 1e-4);
}

test "the storage a solve runs over has to cover the tree" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{.{}};

    try testing.expectError(error.EmptyTree, fixture.solve(&.{}, &.{}, root_rect));

    var short: Workspace = fixture.workspace();
    short.measured = fixture.measured[0..0];
    try testing.expectError(
        error.WorkspaceTooSmall,
        imui.solveLayout(.{ .nodes = &nodes, .children = &.{} }, root_rect, short, &fixture.results),
    );
    try testing.expectError(
        error.ResultsTooSmall,
        imui.solveLayout(.{ .nodes = &nodes, .children = &.{} }, root_rect, fixture.workspace(), fixture.results[0..0]),
    );
}

test "a root rectangle that is not well formed is refused" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{.{}};
    try testing.expectError(error.InvalidRootRect, fixture.solve(
        &nodes,
        &.{},
        .{ .x = 0, .y = 0, .width = std.math.nan(f32), .height = 10 },
    ));
}

test "a node carrying a value that is not finite and non-negative is refused" {
    const nan = std.math.nan(f32);
    var fixture: Fixture = .{};

    try testing.expectError(error.InvalidNodeData, fixture.solve(&.{fixed(nan, 10)}, &.{}, root_rect));
    try testing.expectError(error.InvalidNodeData, fixture.solve(&.{fixed(-1, 10)}, &.{}, root_rect));
    try testing.expectError(error.InvalidNodeData, fixture.solve(
        &.{.{ .padding = .{ .left = -1 } }},
        &.{},
        root_rect,
    ));
    try testing.expectError(error.InvalidNodeData, fixture.solve(&.{.{ .gap = nan }}, &.{}, root_rect));
    try testing.expectError(error.InvalidNodeData, fixture.solve(&.{.{ .flex_grow = -1 }}, &.{}, root_rect));

    // A minimum above its maximum has no size that satisfies it.
    try testing.expectError(error.InvalidNodeData, fixture.solve(
        &.{.{ .constraints = .{ .min_width = 20, .max_width = 10 } }},
        &.{},
        root_rect,
    ));
}

test "the child ranges have to tile the edge array exactly once" {
    var fixture: Fixture = .{};

    // A range that runs off the end.
    try testing.expectError(error.MalformedChildRange, fixture.solve(
        &.{ .{ .child_start = 0, .child_count = 3 }, .{}, .{} },
        &.{ 1, 2 },
        root_rect,
    ));
    // An edge belonging to no node's range.
    try testing.expectError(error.MalformedChildRange, fixture.solve(
        &.{ .{ .child_start = 0, .child_count = 1 }, .{}, .{} },
        &.{ 1, 2 },
        root_rect,
    ));
    // A child index past the node array.
    try testing.expectError(error.InvalidChildIndex, fixture.solve(
        &.{ .{ .child_start = 0, .child_count = 1 }, .{} },
        &.{7},
        root_rect,
    ));
}

test "a tree with no single root is refused however it fails to be one" {
    var fixture: Fixture = .{};

    // Two nodes and no edges: two roots.
    try testing.expectError(error.NotOneRoot, fixture.solve(&.{ .{}, .{} }, &.{}, root_rect));
    // One child claimed twice.
    try testing.expectError(error.DuplicateParent, fixture.solve(
        &.{
            .{ .child_start = 0, .child_count = 1 },
            .{ .child_start = 1, .child_count = 1 },
            .{},
        },
        &.{ 2, 2 },
        root_rect,
    ));
    // Every node has a parent, so somewhere there is a cycle and no root.
    try testing.expectError(error.NotOneRoot, fixture.solve(
        &.{
            .{ .child_start = 0, .child_count = 1 },
            .{ .child_start = 1, .child_count = 1 },
        },
        &.{ 1, 0 },
        root_rect,
    ));
}

test "a component the root cannot reach is a cycle" {
    var fixture: Fixture = .{};
    // Node 0 is the root with child 1. Nodes 2 and 3 point at each other, so
    // both have parents and neither is reachable.
    try testing.expectError(error.CycleDetected, fixture.solve(
        &.{
            .{ .child_start = 0, .child_count = 1 },
            .{},
            .{ .child_start = 1, .child_count = 1 },
            .{ .child_start = 2, .child_count = 1 },
        },
        &.{ 1, 3, 2 },
        root_rect,
    ));
}

test "a lone node is given the rectangle it was solved into" {
    var fixture: Fixture = .{};
    try fixture.solve(&.{.{}}, &.{}, root_rect);
    try expectRect(root_rect, fixture.results[0]);
}

test "a row places its children one after another with the gap between them" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{
        .{ .arrangement = .row, .child_start = 0, .child_count = 3, .gap = 4 },
        fixed(10, 20),
        fixed(30, 10),
        fixed(10, 10),
    };
    try fixture.solve(&nodes, &.{ 1, 2, 3 }, root_rect);

    try expectRect(.{ .x = 0, .y = 0, .width = 10, .height = 20 }, fixture.results[1]);
    try expectRect(.{ .x = 14, .y = 0, .width = 30, .height = 10 }, fixture.results[2]);
    try expectRect(.{ .x = 48, .y = 0, .width = 10, .height = 10 }, fixture.results[3]);
}

test "a column runs down the other axis" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{
        .{ .arrangement = .column, .child_start = 0, .child_count = 2, .gap = 5 },
        fixed(10, 20),
        fixed(10, 10),
    };
    try fixture.solve(&nodes, &.{ 1, 2 }, root_rect);

    try expectRect(.{ .x = 0, .y = 0, .width = 10, .height = 20 }, fixture.results[1]);
    try expectRect(.{ .x = 0, .y = 25, .width = 10, .height = 10 }, fixture.results[2]);
}

test "a single child has no gap around it" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{
        .{ .arrangement = .row, .child_start = 0, .child_count = 1, .gap = 1000 },
        fixed(10, 10),
    };
    try fixture.solve(&nodes, &.{1}, root_rect);
    try expectRect(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, fixture.results[1]);
}

test "padding moves the children in and takes the space off what they get" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{
        .{
            .arrangement = .row,
            .child_start = 0,
            .child_count = 1,
            .padding = .{ .left = 5, .top = 7, .right = 5, .bottom = 3 },
        },
        .{ .flex_grow = 1, .cross_alignment = .start },
    };
    // The child grows into what is left after the padding.
    var stretched = nodes;
    stretched[0].cross_alignment = .stretch;
    try fixture.solve(&stretched, &.{1}, root_rect);

    try expectRect(.{ .x = 5, .y = 7, .width = 90, .height = 50 }, fixture.results[1]);
}

test "padding beyond the rectangle leaves nothing rather than a negative extent" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{
        .{
            .arrangement = .row,
            .child_start = 0,
            .child_count = 1,
            .padding = .{ .left = 500, .right = 500 },
        },
        .{ .flex_grow = 1 },
    };
    try fixture.solve(&nodes, &.{1}, root_rect);

    try testing.expectEqual(0, fixture.results[1].width);
    try testing.expect(fixture.results[1].width >= 0);
}

test "a parent with an intrinsic size measures to its content" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{
        // The root fills the rectangle it was given whatever it measured to,
        // so the measurement is read from the child's parent instead.
        .{ .arrangement = .row, .child_start = 0, .child_count = 1 },
        .{
            .arrangement = .row,
            .child_start = 1,
            .child_count = 2,
            .gap = 6,
            .padding = .{ .left = 2, .right = 3, .top = 1, .bottom = 1 },
        },
        fixed(10, 20),
        fixed(30, 8),
    };
    try fixture.solve(&nodes, &.{ 1, 2, 3 }, root_rect);

    // 2 + 10 + 6 + 30 + 3 across, and 1 + 20 + 1 down.
    try expectRect(.{ .x = 0, .y = 0, .width = 51, .height = 22 }, fixture.results[1]);
}

test "a node is at least as large as its own declared extent" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{
        .{ .arrangement = .row, .child_start = 0, .child_count = 1 },
        .{ .intrinsic_size = .{ .width = 40, .height = 12 } },
    };
    try fixture.solve(&nodes, &.{1}, root_rect);
    try expectRect(.{ .x = 0, .y = 0, .width = 40, .height = 12 }, fixture.results[1]);
}

test "constraints raise and cap what a node measured to" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{
        .{ .arrangement = .row, .child_start = 0, .child_count = 2, .gap = 0 },
        .{ .intrinsic_size = .{ .width = 5, .height = 5 }, .constraints = .{ .min_width = 20 } },
        .{ .intrinsic_size = .{ .width = 90, .height = 5 }, .constraints = .{ .max_width = 30 } },
    };
    try fixture.solve(&nodes, &.{ 1, 2 }, root_rect);

    try testing.expectEqual(20, fixture.results[1].width);
    try testing.expectEqual(30, fixture.results[2].width);
}

test "growth is shared in proportion and a fixed child takes none of it" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{
        .{ .arrangement = .row, .child_start = 0, .child_count = 3 },
        .{ .flex_grow = 1 },
        .{ .flex_grow = 3 },
        // Fixed on the main axis, so its growth factor is not consulted.
        .{ .width = .{ .fixed = 20 }, .flex_grow = 100 },
    };
    try fixture.solve(&nodes, &.{ 1, 2, 3 }, root_rect);

    // 80 free after the fixed child, split one to three.
    try testing.expectEqual(20, fixture.results[1].width);
    try testing.expectEqual(60, fixture.results[2].width);
    try testing.expectEqual(20, fixture.results[3].width);
    try testing.expectEqual(80, fixture.results[3].x);
}

test "a child's own maximum caps its share and the rest becomes alignment slack" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{
        .{ .arrangement = .row, .child_start = 0, .child_count = 2, .main_alignment = .end },
        .{ .flex_grow = 1, .constraints = .{ .max_width = 10 } },
        .{ .flex_grow = 1, .constraints = .{ .max_width = 10 } },
    };
    try fixture.solve(&nodes, &.{ 1, 2 }, root_rect);

    // Twenty of a hundred taken, and the eighty left over moves them right
    // rather than being handed back to the children.
    try testing.expectEqual(10, fixture.results[1].width);
    try testing.expectEqual(80, fixture.results[1].x);
    try testing.expectEqual(90, fixture.results[2].x);
}

test "main alignment moves the children within what is left over" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{
        .{ .arrangement = .row, .child_start = 0, .child_count = 2 },
        fixed(20, 10),
        fixed(20, 10),
    };

    var start = nodes;
    try fixture.solve(&start, &.{ 1, 2 }, root_rect);
    try testing.expectEqual(0, fixture.results[1].x);

    var centred = nodes;
    centred[0].main_alignment = .center;
    try fixture.solve(&centred, &.{ 1, 2 }, root_rect);
    try testing.expectEqual(30, fixture.results[1].x);
    try testing.expectEqual(50, fixture.results[2].x);

    var ended = nodes;
    ended[0].main_alignment = .end;
    try fixture.solve(&ended, &.{ 1, 2 }, root_rect);
    try testing.expectEqual(60, fixture.results[1].x);

    var spread = nodes;
    spread[0].main_alignment = .space_between;
    try fixture.solve(&spread, &.{ 1, 2 }, root_rect);
    try testing.expectEqual(0, fixture.results[1].x);
    try testing.expectEqual(80, fixture.results[2].x);
}

test "cross alignment moves a child across, and stretch resizes it instead" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{
        .{ .arrangement = .row, .child_start = 0, .child_count = 1 },
        fixed(20, 10),
    };

    var centred = nodes;
    centred[0].cross_alignment = .center;
    try fixture.solve(&centred, &.{1}, root_rect);
    try testing.expectEqual(25, fixture.results[1].y);
    try testing.expectEqual(10, fixture.results[1].height);

    var ended = nodes;
    ended[0].cross_alignment = .end;
    try fixture.solve(&ended, &.{1}, root_rect);
    try testing.expectEqual(50, fixture.results[1].y);

    // A fixed cross dimension is what the child asked for, so stretch leaves
    // it alone rather than overriding it.
    var stretched = nodes;
    stretched[0].cross_alignment = .stretch;
    try fixture.solve(&stretched, &.{1}, root_rect);
    try testing.expectEqual(10, fixture.results[1].height);

    // Intrinsic on that axis, and stretch reaches it.
    var open = nodes;
    open[0].cross_alignment = .stretch;
    open[1] = .{ .width = .{ .fixed = 20 } };
    try fixture.solve(&open, &.{1}, root_rect);
    try testing.expectEqual(60, fixture.results[1].height);
}

test "stretch respects the maximum the child set for itself" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{
        .{ .arrangement = .row, .child_start = 0, .child_count = 1, .cross_alignment = .stretch },
        .{ .width = .{ .fixed = 20 }, .constraints = .{ .max_height = 25 } },
    };
    try fixture.solve(&nodes, &.{1}, root_rect);
    try testing.expectEqual(25, fixture.results[1].height);
}

test "overlay puts every child in the same place and aligns each on its own" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{
        .{
            .arrangement = .overlay,
            .child_start = 0,
            .child_count = 2,
            .main_alignment = .center,
            .cross_alignment = .end,
        },
        fixed(20, 10),
        fixed(40, 20),
    };
    try fixture.solve(&nodes, &.{ 1, 2 }, root_rect);

    // Main is the horizontal axis for an overlay and cross is the vertical.
    try expectRect(.{ .x = 40, .y = 50, .width = 20, .height = 10 }, fixture.results[1]);
    try expectRect(.{ .x = 30, .y = 40, .width = 40, .height = 20 }, fixture.results[2]);
}

test "an overlay measures to the largest of its children" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{
        .{ .arrangement = .row, .child_start = 0, .child_count = 1 },
        .{ .arrangement = .overlay, .child_start = 1, .child_count = 2 },
        fixed(20, 30),
        fixed(40, 10),
    };
    try fixture.solve(&nodes, &.{ 1, 2, 3 }, root_rect);
    try expectRect(.{ .x = 0, .y = 0, .width = 40, .height = 30 }, fixture.results[1]);
}

test "a tree three levels deep places every node once" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{
        .{ .arrangement = .column, .child_start = 0, .child_count = 2 },
        .{ .height = .{ .fixed = 10 }, .flex_grow = 0 },
        .{ .arrangement = .row, .child_start = 2, .child_count = 2, .flex_grow = 1, .cross_alignment = .stretch },
        fixed(30, 5),
        .{ .flex_grow = 1 },
    };
    try fixture.solve(&nodes, &.{ 1, 2, 3, 4 }, root_rect);

    // The first child takes its fixed height and grows not at all; the row
    // takes the whole 50 that is left, because it is the only one whose main
    // axis is open to growth.
    try expectRect(.{ .x = 0, .y = 0, .width = 0, .height = 10 }, fixture.results[1]);
    // Its width is what it measured to and not the column's, because the
    // column aligns across at `start` rather than stretching.
    try expectRect(.{ .x = 0, .y = 10, .width = 30, .height = 50 }, fixture.results[2]);

    // Inside the row: the fixed child keeps its own height against the row's
    // stretch, and the flexible one has nothing left to grow into across but
    // takes the row's full height.
    try expectRect(.{ .x = 0, .y = 10, .width = 30, .height = 5 }, fixture.results[3]);
    try expectRect(.{ .x = 30, .y = 10, .width = 0, .height = 50 }, fixture.results[4]);
}

test "arithmetic that leaves the finite range is reported" {
    var fixture: Fixture = .{};
    const huge = std.math.floatMax(f32);
    const nodes = [_]Node{
        .{ .arrangement = .row, .child_start = 0, .child_count = 2 },
        fixed(huge, 1),
        fixed(huge, 1),
    };
    try testing.expectError(error.ArithmeticOverflow, fixture.solve(&nodes, &.{ 1, 2 }, root_rect));
}

test "a solve that fails leaves the results of the last one that did not" {
    var fixture: Fixture = .{};
    const good = [_]Node{
        .{ .arrangement = .row, .child_start = 0, .child_count = 2 },
        fixed(20, 10),
        fixed(20, 10),
    };
    try fixture.solve(&good, &.{ 1, 2 }, root_rect);
    const kept = fixture.results[1];

    const huge = std.math.floatMax(f32);
    var broken = good;
    broken[1] = fixed(huge, 1);
    broken[2] = fixed(huge, 1);
    try testing.expectError(error.ArithmeticOverflow, fixture.solve(&broken, &.{ 1, 2 }, root_rect));

    // A frame that failed to lay out draws the geometry it had, not half of a
    // new one.
    try expectRect(kept, fixture.results[1]);
}

// The gap enters the arithmetic in two places that no test above reaches: it
// is taken off the space available to growth, and off the space alignment has
// to move within. A child's own position is stepped by `gap` directly, so an
// error in the total is invisible to a row that neither grows nor aligns.
test "the gap is taken off the space that growth is shared out of" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{
        .{ .arrangement = .row, .child_start = 0, .child_count = 3, .gap = 10 },
        .{ .flex_grow = 1 },
        .{ .flex_grow = 1 },
        .{ .flex_grow = 1 },
    };
    try fixture.solve(&nodes, &.{ 1, 2, 3 }, root_rect);

    // Two gaps of ten out of a hundred leaves eighty to split three ways.
    const share = 80.0 / 3.0;
    try testing.expectApproxEqAbs(share, fixture.results[1].width, 1e-4);
    try testing.expectApproxEqAbs(share + 10, fixture.results[2].x, 1e-4);
    try testing.expectApproxEqAbs(2 * share + 20, fixture.results[3].x, 1e-4);
}

test "the gap is taken off the space alignment moves within" {
    var fixture: Fixture = .{};
    const nodes = [_]Node{
        .{
            .arrangement = .row,
            .child_start = 0,
            .child_count = 2,
            .gap = 10,
            .main_alignment = .end,
        },
        fixed(20, 10),
        fixed(20, 10),
    };
    try fixture.solve(&nodes, &.{ 1, 2 }, root_rect);

    // Forty of content and one gap of ten leaves fifty, so the pair ends
    // flush against the right edge.
    try testing.expectEqual(50, fixture.results[1].x);
    try testing.expectEqual(80, fixture.results[2].x);
    try testing.expectEqual(100, fixture.results[2].x + fixture.results[2].width);
}

// The failure above happens during measurement, before a single rectangle is
// written. This one fails during placement, with part of the tree already
// placed in the scratch array, which is the case the copy-out exists for.
test "a failure part way through placement still leaves the results alone" {
    var fixture: Fixture = .{};
    const huge = std.math.floatMax(f32);
    const wide: LogicalRect = .{ .x = huge, .y = 0, .width = 0, .height = 10 };

    const good = [_]Node{
        .{ .arrangement = .row, .child_start = 0, .child_count = 2 },
        fixed(1, 1),
        fixed(1, 1),
    };
    try fixture.solve(&good, &.{ 1, 2 }, root_rect);
    const kept_first = fixture.results[1];
    const kept_second = fixture.results[2];

    // Each child is finite and so is its rectangle, so the first is written
    // before the running position leaves the range on the way to the second.
    const overflowing = [_]Node{
        .{ .arrangement = .row, .child_start = 0, .child_count = 2 },
        fixed(huge, 1),
        fixed(1, 1),
    };
    try testing.expectError(error.ArithmeticOverflow, fixture.solve(&overflowing, &.{ 1, 2 }, wide));

    try expectRect(kept_first, fixture.results[1]);
    try expectRect(kept_second, fixture.results[2]);
}
