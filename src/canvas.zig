const std = @import("std");
const res = @import("lenore-resources");
const types = @import("types.zig");

const DrawCommand = res.DrawCommand;
const ImageHandle = res.ImageHandle;
const Index = res.DrawIndex;
const PremultipliedColor = res.PremultipliedColor;
const Rect = res.Rect;
const UvRect = types.UvRect;
const Vertex = res.Vertex2D;

// The draw-list builder: widget code appends indexed geometry in painter's
// order and the result is a vertex array, an index array and a list of draws
// over them.
//
// It owns no memory. Every array is a slice the caller supplies, which is what
// lets the engine hand it a mapped frame ring and a test hand it a stack array,
// with the same code between them and no allocator anywhere.
//
// **The vertex and index destinations are written and never read back.** They
// are expected to be memory the device reads directly, which is not memory to
// run a read-modify-write across, and nothing here does: the merge and the
// rollback below re-read only the command list. That is also why there is no
// accessor returning the vertices — handing out a readable view of that memory
// is how the rule would eventually be broken by someone who never read it.
// A caller that needs to inspect the geometry already owns the array it passed
// to `init`.

// Per-vertex finiteness is checked while a build carries safety and not at all
// in the build that ships, which is the same split `lenore-platform`'s event
// queue makes for its batch guard.
//
// The values are not untrusted input: they come from a tessellator in this
// module, working from a rectangle already validated where it entered. A
// permanent scan would be one pass over the largest per-frame array, every
// frame, re-deriving a guarantee the producer made. What it is worth is
// catching a new tessellator's arithmetic the first time it runs, which is a
// development concern and is priced accordingly.
const check_geometry = std.debug.runtime_safety;

pub const InitError = error{
    // Every array has to be able to hold something. A zero-length one is a
    // caller that has not decided its budget yet, and it would otherwise fail
    // later as a capacity error that names the wrong cause.
    EmptyStorage,

    // An index is 32 bits and so is `first_index`, so storage past that range
    // could produce a draw that cannot be expressed.
    StorageTooLarge,
};

pub const Error = error{
    InvalidGeometry,

    // A zero or unregistered handle. Separate from `InvalidGeometry` so the
    // failure names what was wrong rather than what it was passed to.
    InvalidImage,

    VertexCapacityExceeded,
    IndexCapacityExceeded,
    CommandCapacityExceeded,
    ClipCapacityExceeded,
};

// A point to roll back to, so that a widget drawing several primitives either
// appears whole or does not appear.
//
// It carries the previous command's index count as well as the counts, because
// an append may have merged into that command rather than adding one, and
// rewinding the command count alone would leave the merge behind.
pub const Checkpoint = struct {
    vertex_count: usize,
    index_count: usize,
    command_count: usize,
    previous_index_count: u32,
};

pub const Canvas = struct {
    storage: res.DrawListStorage,

    vertex_count: usize = 0,
    index_count: usize = 0,
    command_count: usize = 0,
    clip_count: usize = 0,

    pub fn init(storage: res.DrawListStorage) InitError!Canvas {
        if (storage.vertices.len == 0 or storage.indices.len == 0 or
            storage.commands.len == 0 or storage.clips.len == 0)
            return error.EmptyStorage;
        if (storage.vertices.len > std.math.maxInt(u32) or
            storage.indices.len > std.math.maxInt(u32) or
            storage.commands.len > std.math.maxInt(u32))
            return error.StorageTooLarge;

        return .{ .storage = storage };
    }

    // Starts a frame's list without touching the storage. The root clip is the
    // ancestor of every other, so it is validated here: `Rect.intersection` is
    // built from `@min` and `@max`, which return the operand that is not NaN, so
    // a non-finite root would silently become whatever it was intersected with
    // rather than announcing itself.
    pub fn begin(self: *Canvas, root_clip: Rect) Error!void {
        if (!root_clip.isValid()) return error.InvalidGeometry;
        self.vertex_count = 0;
        self.index_count = 0;
        self.command_count = 0;
        self.storage.clips[0] = root_clip;
        self.clip_count = 1;
    }

    // What the consumer needs to record the frame: how much of each array was
    // written, and the draws over it.
    pub fn vertexCount(self: *const Canvas) usize {
        return self.vertex_count;
    }

    pub fn indexCount(self: *const Canvas) usize {
        return self.index_count;
    }

    pub fn commands(self: *const Canvas) []const DrawCommand {
        return self.storage.commands[0..self.command_count];
    }

    pub fn currentClip(self: *const Canvas) Rect {
        std.debug.assert(self.clip_count > 0);
        return self.storage.clips[self.clip_count - 1];
    }

    // Nesting is intersection only, so a child can never draw outside its
    // parent however it was placed.
    pub fn pushClip(self: *Canvas, clip: Rect) Error!void {
        if (!clip.isValid()) return error.InvalidGeometry;
        if (self.clip_count == self.storage.clips.len) return error.ClipCapacityExceeded;
        self.storage.clips[self.clip_count] = Rect.intersection(self.currentClip(), clip);
        self.clip_count += 1;
    }

    // Popping the root is a programmer error rather than a runtime condition:
    // the stack is balanced by the code that pushes, not by input.
    pub fn popClip(self: *Canvas) void {
        std.debug.assert(self.clip_count > 1);
        self.clip_count -= 1;
    }

    pub fn checkpoint(self: *const Canvas) Checkpoint {
        return .{
            .vertex_count = self.vertex_count,
            .index_count = self.index_count,
            .command_count = self.command_count,
            .previous_index_count = if (self.command_count == 0)
                0
            else
                self.storage.commands[self.command_count - 1].index_count,
        };
    }

    pub fn restore(self: *Canvas, mark: Checkpoint) void {
        std.debug.assert(mark.vertex_count <= self.vertex_count);
        std.debug.assert(mark.index_count <= self.index_count);
        std.debug.assert(mark.command_count <= self.command_count);

        self.vertex_count = mark.vertex_count;
        self.index_count = mark.index_count;
        self.command_count = mark.command_count;
        // Undoes a merge into the command that was last at the mark. Without
        // this the command survives with a range covering geometry that has
        // been rolled back.
        if (mark.command_count > 0)
            self.storage.commands[mark.command_count - 1].index_count = mark.previous_index_count;
    }

    // An axis-aligned rectangle, which is most of what a UI draws.
    //
    // The rectangle enters from outside this module, so it is validated here.
    // An empty one is not an error: a layout that resolved to zero width is a
    // widget with nothing to show, not a fault.
    pub fn addQuad(
        self: *Canvas,
        rect: Rect,
        uv: UvRect,
        colour: PremultipliedColor,
        image: ImageHandle,
    ) Error!void {
        if (!rect.isValid()) return error.InvalidGeometry;
        if (rect.isEmpty()) return;

        const right = rect.x + rect.width;
        const bottom = rect.y + rect.height;
        const corners = [4]Vertex{
            .{ .position = .{ rect.x, rect.y }, .uv = .{ uv.u0, uv.v0 }, .colour = colour },
            .{ .position = .{ right, rect.y }, .uv = .{ uv.u1, uv.v0 }, .colour = colour },
            .{ .position = .{ right, bottom }, .uv = .{ uv.u1, uv.v1 }, .colour = colour },
            .{ .position = .{ rect.x, bottom }, .uv = .{ uv.u0, uv.v1 }, .colour = colour },
        };
        // Two triangles over the corners in the order above, sharing the
        // diagonal from the top left to the bottom right. Which way that winds
        // is not stated here and is not relied on: a draw list is not culled,
        // because it is built in one orientation and has no back to face away.
        const order = [6]Index{ 0, 1, 2, 2, 3, 0 };
        return self.addIndexed(&corners, &order, image);
    }

    // The one funnel every drawing path reaches the arrays through.
    //
    // `incoming_indices` address `incoming_vertices` from zero and are rebased
    // here, so a tessellator writes its geometry without knowing what is
    // already in the canvas.
    //
    // Nothing is written until every check has passed, which is what makes a
    // failure leave the canvas exactly as it was. A widget that fails part way
    // through several of these still needs `restore`, because the earlier ones
    // succeeded.
    pub fn addIndexed(
        self: *Canvas,
        incoming_vertices: []const Vertex,
        incoming_indices: []const Index,
        image: ImageHandle,
    ) Error!void {
        if (!image.isValid()) return error.InvalidImage;
        if (incoming_vertices.len == 0 and incoming_indices.len == 0) return;
        if (incoming_vertices.len == 0 or incoming_indices.len == 0)
            return error.InvalidGeometry;

        // Against the incoming count, which is one tessellator's output and
        // small, rather than against the accumulated array.
        for (incoming_indices) |index| {
            if (index >= incoming_vertices.len) return error.InvalidGeometry;
        }
        if (check_geometry) {
            for (incoming_vertices) |vertex| {
                for (vertex.position ++ vertex.uv) |value| {
                    std.debug.assert(std.math.isFinite(value));
                }
            }
        }

        // A clip that has collapsed discards the geometry rather than
        // recording a draw the scissor would reject.
        const clip = self.currentClip();
        if (clip.isEmpty()) return;

        if (incoming_vertices.len > self.storage.vertices.len - self.vertex_count)
            return error.VertexCapacityExceeded;
        if (incoming_indices.len > self.storage.indices.len - self.index_count)
            return error.IndexCapacityExceeded;

        // Merging keeps a run of quads sharing an image and a clip as one draw,
        // which is what makes a panel of a hundred rectangles cost one.
        const merges = self.command_count > 0 and
            continues(
                self.storage.commands[self.command_count - 1],
                image,
                clip,
                @intCast(self.index_count),
            );
        if (!merges and self.command_count == self.storage.commands.len)
            return error.CommandCapacityExceeded;

        @memcpy(self.storage.vertices[self.vertex_count..][0..incoming_vertices.len], incoming_vertices);
        for (
            incoming_indices,
            self.storage.indices[self.index_count..][0..incoming_indices.len],
        ) |source, *destination| {
            // Cannot exceed the index width: the vertex count is bounded by
            // the storage, which `init` refused if it was past this range, and
            // every source is below `incoming.len`.
            destination.* = @intCast(self.vertex_count + source);
        }

        if (merges) {
            self.storage.commands[self.command_count - 1].index_count += @intCast(incoming_indices.len);
        } else {
            self.storage.commands[self.command_count] = .{
                .image = image,
                .clip = clip,
                .first_index = @intCast(self.index_count),
                .index_count = @intCast(incoming_indices.len),
            };
            self.command_count += 1;
        }
        self.vertex_count += incoming_vertices.len;
        self.index_count += incoming_indices.len;
    }
};

// Whether a draw can absorb the geometry about to be written. Everything a
// draw fixes has to match, and the indices have to be the ones that follow it:
// a command's range is contiguous by construction, and extending one across a
// gap would draw whatever fell in between.
fn continues(
    command: DrawCommand,
    image: ImageHandle,
    clip: Rect,
    next_index: u32,
) bool {
    return command.image == image and
        std.meta.eql(command.clip, clip) and
        command.first_index + command.index_count == next_index;
}
