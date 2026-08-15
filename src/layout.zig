const std = @import("std");
const types = @import("types.zig");

const LogicalRect = types.LogicalRect;
const LogicalSize = types.LogicalSize;

// A flat layout solver: one rooted tree in, one rectangle per node out.
//
// The tree is arrays rather than pointers. Nodes are one contiguous array and
// the edges are a second, so a parent names its children by a range into the
// edge array. That is what makes the two passes below straight walks over
// memory in order, and it is why the solver needs no allocator and no
// recursion: the traversal order is computed once into a workspace array and
// then read forwards and backwards.
//
// Measurement runs bottom-up and placement top-down, which is the one order
// that works. A parent cannot size itself until its children have reported
// what they want, and a child cannot be placed until its parent knows where it
// is. Neither pass revisits a node.
//
// Everything the caller hands in is validated before any of it is used, and
// the results are copied out only once the whole solve has succeeded. A tree
// that fails to solve therefore leaves the previous frame's rectangles intact,
// which matters because the alternative is a frame drawn from half-updated
// geometry.

pub const NodeIndex = u32;

// How a node arranges its children.
pub const Arrangement = enum {
    // Along the horizontal axis, one after another.
    row,
    // Along the vertical axis.
    column,
    // All in the same place, each aligned within the parent independently.
    overlay,
};

// What a node asks for along one axis, before its constraints are applied.
pub const Dimension = union(enum) {
    // As large as the content needs: the greater of what the children measured
    // to and what the node declared as its own intrinsic size.
    intrinsic,
    // Exactly this, whatever the content came to.
    fixed: f32,
};

pub const Padding = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
};

// Bounds applied after a dimension is resolved. A null maximum is no maximum,
// which is not the same as a very large one: it also means no clamp to apply.
pub const Constraints = struct {
    min_width: f32 = 0,
    min_height: f32 = 0,
    max_width: ?f32 = null,
    max_height: ?f32 = null,
};

// Where the children sit along the axis they are laid out on.
pub const MainAlignment = enum { start, center, end, space_between };

// Where each child sits across it. `stretch` is the one that changes a size
// rather than a position, and it reaches only a child that asked for an
// intrinsic size on that axis: a child that named a fixed size named it.
pub const CrossAlignment = enum { start, center, end, stretch };

pub const Node = struct {
    // A range into the tree's edge array. A leaf is a count of zero and the
    // start is then not read.
    child_start: u32 = 0,
    child_count: u32 = 0,

    arrangement: Arrangement = .overlay,
    width: Dimension = .intrinsic,
    height: Dimension = .intrinsic,

    // What the node is worth on its own, before its children. A label's text
    // extent arrives here.
    intrinsic_size: LogicalSize = .zero,

    constraints: Constraints = .{},
    padding: Padding = .{},

    // Between adjacent children on the main axis. It has no effect under
    // `overlay`, where the children are not adjacent to anything.
    gap: f32 = 0,

    // The share of the leftover main-axis space this node takes, in proportion
    // to its siblings' values. A node with a fixed main-axis dimension takes
    // none of it however this is set: it asked for an exact size.
    flex_grow: f32 = 0,

    main_alignment: MainAlignment = .start,
    cross_alignment: CrossAlignment = .start,
};

pub const Tree = struct {
    nodes: []const Node,
    children: []const NodeIndex,
};

// Scratch for one solve, all of it the caller's and none of it meaningful
// afterwards. Every array needs at least as many elements as the tree has
// nodes.
pub const Workspace = struct {
    parents: []NodeIndex,
    order: []NodeIndex,
    measured: []LogicalSize,
    rects: []LogicalRect,
};

pub const Error = error{
    EmptyTree,

    // A node is addressed by a `u32`, and the sentinel below takes one value
    // out of that range.
    TooManyNodes,

    WorkspaceTooSmall,
    ResultsTooSmall,
    InvalidRootRect,

    // A size, a padding, a gap or a growth factor that is not finite and
    // non-negative, or a minimum above its maximum.
    InvalidNodeData,

    // The child ranges do not tile the edge array exactly once.
    MalformedChildRange,

    InvalidChildIndex,

    // Two nodes claim the same child.
    DuplicateParent,

    // No node is without a parent, or more than one is. Either way what was
    // given is not a rooted tree.
    NotOneRoot,

    // Nodes that no walk from the root reaches. With one parent apiece and
    // exactly one root, an unreachable node is in a cycle.
    CycleDetected,

    // A sum or a product left the finite range. The inputs are all finite by
    // validation, so this is the arithmetic and not the data: it cannot be
    // moved to the boundary the way the checks above are.
    ArithmeticOverflow,
};

// One value of `NodeIndex` reserved to mean "no parent yet", which is what
// takes one node off the addressable range.
const no_parent = std.math.maxInt(NodeIndex);

const Axis = enum { horizontal, vertical };

// Solves the tree into `results`, one rectangle per node, in node order.
//
// The root fills `root_rect` exactly. Everything below keeps fractional
// logical coordinates: rounding to pixels is the conversion in `types.zig` and
// happens once, at the edge, so that a chain of nested rectangles does not
// accumulate four roundings.
//
// Linear in the nodes and the edges together. Each node is validated once,
// walked once to find the traversal order, measured once and placed once.
pub fn solve(
    tree: Tree,
    root_rect: LogicalRect,
    workspace: Workspace,
    results: []LogicalRect,
) Error!void {
    const count = tree.nodes.len;
    if (count == 0) return error.EmptyTree;
    if (count > no_parent) return error.TooManyNodes;
    if (workspace.parents.len < count or workspace.order.len < count or
        workspace.measured.len < count or workspace.rects.len < count)
        return error.WorkspaceTooSmall;
    if (results.len < count) return error.ResultsTooSmall;
    if (!root_rect.isValid()) return error.InvalidRootRect;

    const parents = workspace.parents[0..count];
    const order = workspace.order[0..count];
    const measured = workspace.measured[0..count];
    const rects = workspace.rects[0..count];

    const root_index = try link(tree, parents);
    try walk(tree, order, parents, root_index);

    // Backwards over the traversal order, which puts every child before its
    // parent. That is what makes one pass enough.
    var remaining = count;
    while (remaining > 0) {
        remaining -= 1;
        const index = order[remaining];
        measured[index] = try measure(tree, measured, index);
    }

    rects[root_index] = root_rect;
    for (order) |index| try arrange(tree, measured, rects, index);

    @memcpy(results[0..count], rects);
}

// Validates every node, works out which node is the root, and marks in
// `parents` which nodes are somebody's child.
//
// The array carries two meanings in turn: here it is only "claimed or not",
// and `walk` overwrites it with the parent itself. One array rather than two
// because the first meaning is dead the moment the second is written.
fn link(tree: Tree, parents: []NodeIndex) Error!NodeIndex {
    @memset(parents, no_parent);

    var edges_seen: usize = 0;
    for (tree.nodes) |node| {
        try validate(node);

        const start: usize = node.child_start;
        const child_count: usize = node.child_count;
        if (start > tree.children.len or child_count > tree.children.len - start)
            return error.MalformedChildRange;
        if (child_count > tree.children.len - edges_seen)
            return error.MalformedChildRange;
        edges_seen += child_count;

        for (tree.children[start..][0..child_count]) |child| {
            if (child >= tree.nodes.len) return error.InvalidChildIndex;
            if (parents[child] != no_parent) return error.DuplicateParent;
            // Claimed. The value is replaced by the real parent in `walk`, and
            // anything other than the sentinel serves until then.
            parents[child] = 0;
        }
    }
    // Every edge belongs to exactly one node's range, so the ranges tile the
    // array. Without this a node could name a range that another node also
    // names while the totals still balanced.
    if (edges_seen != tree.children.len) return error.MalformedChildRange;

    var root: ?NodeIndex = null;
    for (parents, 0..) |parent, index| {
        if (parent != no_parent) continue;
        if (root != null) return error.NotOneRoot;
        root = @intCast(index);
    }
    return root orelse error.NotOneRoot;
}

// Fills `order` with the nodes parent-first, and `parents` with the real
// parent of each.
//
// The array being filled is also the queue being read, which is what removes
// the explicit stack. Each node is appended exactly once because each has at
// most one parent, so the cursor is bounded by the node count and the walk
// cannot loop.
fn walk(tree: Tree, order: []NodeIndex, parents: []NodeIndex, root_index: NodeIndex) Error!void {
    order[0] = root_index;
    var filled: usize = 1;
    var cursor: usize = 0;
    while (cursor < filled) : (cursor += 1) {
        const parent_index = order[cursor];
        const node = tree.nodes[parent_index];
        const start: usize = node.child_start;
        for (tree.children[start..][0..node.child_count]) |child| {
            parents[child] = parent_index;
            order[filled] = child;
            filled += 1;
        }
    }
    // A node the walk never reached has a parent that the walk never reached
    // either, all the way round.
    if (filled != order.len) return error.CycleDetected;
}

fn validate(node: Node) Error!void {
    if (!validDimension(node.width) or !validDimension(node.height) or
        !nonNegative(node.intrinsic_size.width) or
        !nonNegative(node.intrinsic_size.height) or
        !nonNegative(node.constraints.min_width) or
        !nonNegative(node.constraints.min_height) or
        !optionalNonNegative(node.constraints.max_width) or
        !optionalNonNegative(node.constraints.max_height) or
        !nonNegative(node.padding.left) or !nonNegative(node.padding.top) or
        !nonNegative(node.padding.right) or !nonNegative(node.padding.bottom) or
        !nonNegative(node.gap) or !nonNegative(node.flex_grow))
        return error.InvalidNodeData;

    // A minimum above its maximum has no size that satisfies it, and the
    // clamp would silently answer with the maximum.
    if (node.constraints.max_width) |limit|
        if (node.constraints.min_width > limit) return error.InvalidNodeData;
    if (node.constraints.max_height) |limit|
        if (node.constraints.min_height > limit) return error.InvalidNodeData;
}

fn validDimension(value: Dimension) bool {
    return switch (value) {
        .intrinsic => true,
        .fixed => |size| nonNegative(size),
    };
}

fn nonNegative(value: f32) bool {
    return std.math.isFinite(value) and value >= 0;
}

fn optionalNonNegative(value: ?f32) bool {
    return if (value) |number| nonNegative(number) else true;
}

// What one node comes to, given what its children came to.
fn measure(tree: Tree, measured: []const LogicalSize, index: NodeIndex) Error!LogicalSize {
    const node = tree.nodes[index];
    const start: usize = node.child_start;
    const children = tree.children[start..][0..node.child_count];

    var content: LogicalSize = .zero;
    switch (node.arrangement) {
        .row => for (children, 0..) |child, offset| {
            if (offset != 0) content.width = try add(content.width, node.gap);
            content.width = try add(content.width, measured[child].width);
            content.height = @max(content.height, measured[child].height);
        },
        .column => for (children, 0..) |child, offset| {
            if (offset != 0) content.height = try add(content.height, node.gap);
            content.height = try add(content.height, measured[child].height);
            content.width = @max(content.width, measured[child].width);
        },
        .overlay => for (children) |child| {
            content.width = @max(content.width, measured[child].width);
            content.height = @max(content.height, measured[child].height);
        },
    }

    content.width = try add(content.width, try add(node.padding.left, node.padding.right));
    content.height = try add(content.height, try add(node.padding.top, node.padding.bottom));

    // A node is at least as large as its own declared extent, so a label with
    // no children still measures to its text.
    const natural: LogicalSize = .{
        .width = @max(content.width, node.intrinsic_size.width),
        .height = @max(content.height, node.intrinsic_size.height),
    };
    return .{
        .width = constrain(resolve(node.width, natural.width), node.constraints.min_width, node.constraints.max_width),
        .height = constrain(resolve(node.height, natural.height), node.constraints.min_height, node.constraints.max_height),
    };
}

fn resolve(dimension: Dimension, intrinsic: f32) f32 {
    return switch (dimension) {
        .intrinsic => intrinsic,
        .fixed => |fixed| fixed,
    };
}

fn constrain(value: f32, minimum: f32, maximum: ?f32) f32 {
    const raised = @max(value, minimum);
    return if (maximum) |limit| @min(raised, limit) else raised;
}

// Places one node's children inside the rectangle that node has already been
// given.
fn arrange(
    tree: Tree,
    measured: []const LogicalSize,
    rects: []LogicalRect,
    parent_index: NodeIndex,
) Error!void {
    const node = tree.nodes[parent_index];
    if (node.child_count == 0) return;

    const parent = rects[parent_index];
    const horizontal_padding = try add(node.padding.left, node.padding.right);
    const vertical_padding = try add(node.padding.top, node.padding.bottom);
    // Padding that exceeds the rectangle leaves nothing rather than a negative
    // extent, which is the same rule clipping uses.
    const inner: LogicalRect = .{
        .x = try add(parent.x, node.padding.left),
        .y = try add(parent.y, node.padding.top),
        .width = @max(parent.width - horizontal_padding, 0),
        .height = @max(parent.height - vertical_padding, 0),
    };
    if (!inner.isValid()) return error.ArithmeticOverflow;

    switch (node.arrangement) {
        .row => try arrangeLinear(tree, measured, rects, node, inner, .horizontal),
        .column => try arrangeLinear(tree, measured, rects, node, inner, .vertical),
        .overlay => try arrangeOverlay(tree, measured, rects, node, inner),
    }
}

fn arrangeLinear(
    tree: Tree,
    measured: []const LogicalSize,
    rects: []LogicalRect,
    node: Node,
    inner: LogicalRect,
    axis: Axis,
) Error!void {
    const start: usize = node.child_start;
    const child_count: usize = node.child_count;
    const children = tree.children[start..][0..child_count];
    const available_main = axisExtent(inner, axis);
    const available_cross = axisExtent(inner, other(axis));

    // What the children asked for, and how much growth they are willing to
    // take between them.
    var basis_total: f32 = 0;
    var grow_total: f32 = 0;
    for (children) |child| {
        basis_total = try add(basis_total, axisOf(measured[child], axis));
        grow_total = try add(grow_total, growOf(tree.nodes[child], axis));
    }
    // A single child has no gaps around it. Written as a branch rather than
    // left to the subtraction, which is on a `usize`.
    const gap_total = if (child_count > 1)
        try multiply(node.gap, @floatFromInt(child_count - 1))
    else
        0;
    basis_total = try add(basis_total, gap_total);
    const free = @max(available_main - basis_total, 0);

    // What the children actually come to once growth has been shared out and
    // each child's own constraints have clamped its share. That can land short
    // of the space available, and what is left over is what alignment moves.
    var occupied: f32 = gap_total;
    for (children) |child|
        occupied = try add(occupied, try mainExtent(tree.nodes[child], measured[child], axis, free, grow_total));
    const slack = @max(available_main - occupied, 0);

    var between: f32 = 0;
    var position = axisOrigin(inner, axis);
    switch (node.main_alignment) {
        .start => {},
        .center => position = try add(position, slack * 0.5),
        .end => position = try add(position, slack),
        .space_between => if (child_count > 1) {
            between = slack / @as(f32, @floatFromInt(child_count - 1));
        },
    }

    for (children, 0..) |child, offset| {
        const child_node = tree.nodes[child];
        const main_size = try mainExtent(child_node, measured[child], axis, free, grow_total);

        // Stretch is the only alignment that resizes, and it reaches only a
        // child that left the cross axis intrinsic.
        const stretches = node.cross_alignment == .stretch and
            isIntrinsic(dimensionOf(child_node, other(axis)));
        const cross_size = if (stretches)
            constrainAxis(available_cross, child_node.constraints, other(axis))
        else
            axisOf(measured[child], other(axis));

        const cross_free = @max(available_cross - cross_size, 0);
        const cross_offset: f32 = switch (node.cross_alignment) {
            .start, .stretch => 0,
            .center => cross_free * 0.5,
            .end => cross_free,
        };

        rects[child] = compose(
            axis,
            position,
            try add(axisOrigin(inner, other(axis)), cross_offset),
            main_size,
            cross_size,
        );
        if (!rects[child].isValid()) return error.ArithmeticOverflow;

        position = try add(position, main_size);
        if (offset + 1 != child_count) {
            position = try add(position, node.gap);
            position = try add(position, between);
        }
    }
}

// Overlay places every child independently in the same rectangle, taking the
// horizontal axis as its main one and the vertical as its cross one.
//
// So `main_alignment` positions horizontally and `cross_alignment` positions
// vertically, and stretch reaches the height alone. Two independent axes would
// be a second pair of fields rather than a different reading of these two:
// changing what the existing pair means would change every layout already
// written against them.
fn arrangeOverlay(
    tree: Tree,
    measured: []const LogicalSize,
    rects: []LogicalRect,
    node: Node,
    inner: LogicalRect,
) Error!void {
    const start: usize = node.child_start;
    for (tree.children[start..][0..node.child_count]) |child| {
        const child_node = tree.nodes[child];
        const width = measured[child].width;
        const stretches = node.cross_alignment == .stretch and isIntrinsic(child_node.height);
        const height = if (stretches)
            constrainAxis(inner.height, child_node.constraints, .vertical)
        else
            measured[child].height;

        rects[child] = .{
            .x = try add(inner.x, mainOffset(inner.width, width, node.main_alignment)),
            .y = try add(inner.y, crossOffset(inner.height, height, node.cross_alignment)),
            .width = width,
            .height = height,
        };
        if (!rects[child].isValid()) return error.ArithmeticOverflow;
    }
}

// `space_between` distributes between neighbours, and an overlay child has
// none, so it sits where `start` would put it.
fn mainOffset(available: f32, size: f32, alignment: MainAlignment) f32 {
    const free = @max(available - size, 0);
    return switch (alignment) {
        .start, .space_between => 0,
        .center => free * 0.5,
        .end => free,
    };
}

fn crossOffset(available: f32, size: f32, alignment: CrossAlignment) f32 {
    const free = @max(available - size, 0);
    return switch (alignment) {
        .start, .stretch => 0,
        .center => free * 0.5,
        .end => free,
    };
}

// One child's main-axis extent: what it measured to, plus its share of what
// was left over, clamped by its own constraints.
fn mainExtent(node: Node, measured: LogicalSize, axis: Axis, free: f32, grow_total: f32) Error!f32 {
    const basis = axisOf(measured, axis);
    const grow = growOf(node, axis);
    if (grow == 0 or grow_total == 0) return basis;

    const share = free * (grow / grow_total);
    if (!std.math.isFinite(share)) return error.ArithmeticOverflow;
    return constrainAxis(try add(basis, share), node.constraints, axis);
}

// A fixed dimension takes no share of the leftover space whatever the growth
// factor says, because it named an exact size.
fn growOf(node: Node, axis: Axis) f32 {
    return if (isIntrinsic(dimensionOf(node, axis))) node.flex_grow else 0;
}

fn isIntrinsic(dimension: Dimension) bool {
    return dimension == .intrinsic;
}

fn dimensionOf(node: Node, axis: Axis) Dimension {
    return if (axis == .horizontal) node.width else node.height;
}

fn constrainAxis(value: f32, constraints: Constraints, axis: Axis) f32 {
    return if (axis == .horizontal)
        constrain(value, constraints.min_width, constraints.max_width)
    else
        constrain(value, constraints.min_height, constraints.max_height);
}

fn axisOf(size: LogicalSize, axis: Axis) f32 {
    return if (axis == .horizontal) size.width else size.height;
}

fn axisExtent(rect: LogicalRect, axis: Axis) f32 {
    return if (axis == .horizontal) rect.width else rect.height;
}

fn axisOrigin(rect: LogicalRect, axis: Axis) f32 {
    return if (axis == .horizontal) rect.x else rect.y;
}

fn other(axis: Axis) Axis {
    return if (axis == .horizontal) .vertical else .horizontal;
}

fn compose(axis: Axis, main: f32, cross: f32, main_size: f32, cross_size: f32) LogicalRect {
    return if (axis == .horizontal)
        .{ .x = main, .y = cross, .width = main_size, .height = cross_size }
    else
        .{ .x = cross, .y = main, .width = cross_size, .height = main_size };
}

// Every input is finite by validation, but a sum of finite values need not be.
// A layout that overflows is reported rather than allowed to place a child at
// infinity, where it would fail no later check and simply never be drawn.
fn add(a: f32, b: f32) Error!f32 {
    const result = a + b;
    if (!std.math.isFinite(result)) return error.ArithmeticOverflow;
    return result;
}

fn multiply(a: f32, b: f32) Error!f32 {
    const result = a * b;
    if (!std.math.isFinite(result)) return error.ArithmeticOverflow;
    return result;
}
