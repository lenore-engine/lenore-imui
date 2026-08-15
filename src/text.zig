const std = @import("std");
const res = @import("lenore-resources");
const canvas_mod = @import("canvas.zig");
const types = @import("types.zig");

const Canvas = canvas_mod.Canvas;
const GlyphRun = res.GlyphRun;
const ImageHandle = res.ImageHandle;
const Point = types.Point;
const PremultipliedColor = res.PremultipliedColor;
const Rect = res.Rect;
const UvRect = types.UvRect;

// Drawing text that has already been shaped and placed.
//
// Nothing here measures anything, and nothing here names a shaper. What arrives
// is a run in the `lenore-resources` vocabulary: which glyphs, how far each one
// moves the pen, and which part of an atlas fills each one. Turning a string
// into that is a font library's work, and it is a dependency this module does
// not have.
//
// The atlas is an image handle like any other, so a run of glyphs merges into
// the same draw as the run before it. What it cannot merge with is the solid
// fill around it, which samples a different image.
//
// Placing a run inside a rectangle is not here. That reads a face's metrics and
// belongs to the label widget, which is where the rest of the arithmetic that
// turns a rectangle into a drawing lives.

// Adds a run of glyphs along the baseline at `pen`.
//
// **The pen is a baseline, not a corner.** A shaped position is measured upward
// from the baseline, which is the opposite of the draw list's own orientation,
// and this is the one place the two meet: every subtraction below is that flip.
// Handing in a top-left corner instead would need the face's ascent, which is a
// property of the font and not of the run.
//
// The run's own numbers are not re-validated. They come from a shaper and an
// atlas inside this project rather than from application code, and the values
// that did enter from outside are checked here: the pen, once, and each glyph's
// rectangle inside `addQuad`. The pen is what every position below is built
// from, which is why a non-finite one is refused before any of them exists.
//
// Rolls back on failure, so a run that runs out of vertices half way through
// leaves nothing behind rather than the first half of a word.
pub fn addGlyphs(
    canvas: *Canvas,
    run: GlyphRun,
    pen: Point,
    colour: PremultipliedColor,
    atlas: ImageHandle,
) canvas_mod.Error!void {
    if (!run.isValid()) return error.InvalidGeometry;
    if (!std.math.isFinite(pen.x) or !std.math.isFinite(pen.y))
        return error.InvalidGeometry;

    const mark = canvas.checkpoint();
    errdefer canvas.restore(mark);

    var x = pen.x;
    var y = pen.y;
    for (run.glyphs, 0..) |glyph, index| {
        // Every glyph is drawn at a whole pixel. The coverage in the atlas was
        // rasterised against the pixel grid, so at a fractional position a
        // filter reads between two texels of a shape that has no information
        // there and the glyph loses its edges for nothing.
        //
        // What keeps that from moving the glyph is that the run carries several
        // rasterisations of it, one per fraction of a pixel, and `subpixelSplit`
        // answers with the whole pixel and the rasterisation together. The pen
        // itself stays fractional, so nothing accumulates.
        //
        // A run of one bucket gets the nearest whole pixel and the only
        // rasterisation there is, which is the same arithmetic and no branch.
        const origin = res.subpixelSplit(x + glyph.x_offset, run.buckets);
        const placement = run.placement(index, origin.bucket);

        // A glyph with no ink still moves the pen, which is what a space is.
        // Skipping it here rather than in `addQuad` also keeps a run of spaces
        // from reaching the image check with nothing to draw.
        if (!placement.isBlank()) {
            const left = origin.base + placement.left;
            // Nothing splits the vertical axis: a baseline is one position for
            // the whole run rather than one per glyph, so a face is rasterised
            // at the grid it will be drawn on and the rounding here moves
            // every glyph of a line by the same amount or none.
            const top = @round(y - glyph.y_offset - placement.top);
            try canvas.addQuad(
                Rect{
                    .x = left,
                    .y = top,
                    .width = placement.width,
                    .height = placement.height,
                },
                UvRect{
                    .u0 = placement.u_min,
                    .v0 = placement.v_min,
                    .u1 = placement.u_max,
                    .v1 = placement.v_max,
                },
                colour,
                atlas,
            );
        }
        x += glyph.x_advance;
        y -= glyph.y_advance;
    }
}
