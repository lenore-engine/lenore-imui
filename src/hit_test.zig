const res = @import("lenore-resources");
const id_stack = @import("id_stack.zig");
const types = @import("types.zig");

const Id = id_stack.Id;
const Point = types.Point;
const Rect = res.Rect;

// Which widget a position falls on, over the regions one frame registered.
//
// Draw order is the answer's order. A region registered later is drawn over one
// registered earlier, so the last match is the topmost, and that is the whole
// of the resolution rule. It is why the scan runs backwards and why it stops at
// the first hit.
//
// The scan is linear and that is the shape the problem has. A frame registers
// regions in the hundreds and asks about one position, so any spatial index
// would be built once per frame to be queried once. Nothing here allocates or
// retains anything: the regions are the caller's array and no state crosses a
// frame boundary.

// One interactive rectangle and the clip in force where it was drawn.
//
// `rect` is deliberately not pre-intersected with `clip`. The two answer
// different questions. `rect` is where the widget was laid out, which is what a
// later query about its position or its size wants; `clip` is how much of it
// the frame actually showed. Intersecting them at registration would leave only
// the second, and a widget scrolled half out of its parent would report a
// layout rectangle it never had.
pub const Region = struct {
    id: Id,
    rect: Rect,
    clip: Rect,
    enabled: bool = true,

    // Whether the keyboard can reach this region. It is separate from
    // `enabled` because most of what a frame registers is reachable by the
    // pointer and by nothing else: a panel background takes a click to stop it
    // falling through, and putting it in the tab order would be a defect.
    focusable: bool = false,

    pub fn contains(self: Region, point: Point) bool {
        // A region without an identity cannot be hit. That is what keeps the
        // non-null arm of `hitTest` a live widget: without it a caller matching
        // on the result would take "no widget" for a widget.
        //
        // Geometry needs no check of its own. `Point.isInside` is false for a
        // non-finite operand and for a negative extent, so an ill-formed region
        // is simply never hit.
        if (!self.enabled or !self.id.isValid()) return false;
        return point.isInside(self.rect) and point.isInside(self.clip);
    }
};

// The topmost enabled region containing `point`, or null when none does.
pub fn hitTest(regions: []const Region, point: Point) ?Id {
    var index = regions.len;
    while (index > 0) {
        index -= 1;
        if (regions[index].contains(point)) return regions[index].id;
    }
    return null;
}
