const std = @import("std");

// Hierarchical widget identity, derived per frame and stored nowhere.
//
// An immediate-mode widget is a call rather than an object, so it has nothing
// to be identified by except where it sits in the call structure. A local key
// is combined with the enclosing scope's identity, which makes two buttons both
// labelled "Delete" distinct as long as their scopes are, and keeps each stable
// from frame to frame as long as the structure is.
//
// The stack holds identities and never the strings they came from. A key is
// hashed where it is passed and its bytes are not retained, so a caller may
// build a label in a scratch buffer and let it go on the next line.
//
// Storage is the caller's, as it is for `Canvas`: the depth a UI needs is a
// property of the widget code, and the module that owns the frame is what
// decides it.

// A widget's identity, and the only thing derived here that leaves.
//
// Zero is reserved, so storage that was zero-initialised names no widget rather
// than the first one. `derive` cannot produce it.
pub const Id = enum(u64) {
    invalid = 0,
    _,

    pub fn isValid(self: Id) bool {
        return self != .invalid;
    }
};

// What distinguishes a widget from its siblings.
//
// A string key is the label the widget already carries, so the ordinary case
// costs the caller nothing. An integer key is for where a string cannot serve:
// a row of a list, whose visible text is data and where two rows may well
// spell the same.
pub const Key = union(enum) {
    integer: u64,
    string: []const u8,
};

pub const Error = error{
    // A stack has to be able to hold its root, so an empty slice cannot become
    // one.
    EmptyStorage,

    ScopeCapacityExceeded,
};

pub const Stack = struct {
    storage: []Id,
    depth: usize,

    // `seed` namespaces one surface of UI against another, so that two panels
    // built from the same widget code do not derive the same identities. It is
    // hashed rather than stored, which is what lets zero be a seed: the root is
    // a derived identity like every other and so is never the reserved value.
    pub fn init(storage: []Id, seed: u64) Error!Stack {
        if (storage.len == 0) return error.EmptyStorage;
        storage[0] = derive(seed, .{ .integer = 0 });
        return .{ .storage = storage, .depth = 1 };
    }

    // Drops every scope a frame opened. The root keeps the identity `init`
    // derived, so identities are stable across frames and not merely within
    // one.
    pub fn reset(self: *Stack) void {
        self.depth = 1;
    }

    // Whether every scope opened this frame has been closed. It is what lets a
    // frame name an unbalanced widget where the frame ends, rather than letting
    // the imbalance surface as a wrong identity somewhere later.
    pub fn isAtRoot(self: *const Stack) bool {
        return self.depth == 1;
    }

    // The enclosing scope's identity, which every key is derived against.
    pub fn current(self: *const Stack) Id {
        // Depth is one at construction, rises only in `push`, and falls only in
        // `pop`, which refuses the root. It cannot reach zero.
        std.debug.assert(self.depth > 0);
        return self.storage[self.depth - 1];
    }

    // The identity a widget would have here, without opening a scope. This is
    // what a leaf uses: it needs an identity and has no children to namespace.
    pub fn id(self: *const Stack, key: Key) Id {
        return derive(@intFromEnum(self.current()), key);
    }

    // Opens a scope, which becomes the parent of everything derived until it is
    // closed.
    pub fn push(self: *Stack, key: Key) Error!void {
        if (self.depth == self.storage.len) return error.ScopeCapacityExceeded;
        self.storage[self.depth] = self.id(key);
        self.depth += 1;
    }

    // Closing more scopes than were opened is a programmer error rather than a
    // runtime condition, for the reason `Canvas.popClip` gives: the stack is
    // balanced by the code that pushes, not by input.
    pub fn pop(self: *Stack) void {
        std.debug.assert(self.depth > 1);
        self.depth -= 1;
    }
};

// One identity from its parent and a local key.
//
// Seeding the hash with the parent is what chains a scope to its ancestors: the
// result depends on the whole path down to it and not only on the last key.
//
// The leading tag byte keeps the two arms of `Key` disjoint. It is needed for
// exactly one case, and only that one: a string of eight bytes, which is what
// `std.mem.asBytes` produces for an integer, so untagged it would be the same
// input as the integer those bytes spell. Any other length is already separated
// by its length.
//
// `std.hash.Wyhash`, seeded and fed in two calls rather than through the
// one-shot `hash`, because the parent is the seed and the key is the input.
// Identities live for one run of one build and are never persisted, so nothing
// depends on the digest surviving a change of hash or a change of endianness.
fn derive(parent: u64, key: Key) Id {
    var hasher = std.hash.Wyhash.init(parent);
    switch (key) {
        .integer => |value| {
            hasher.update(&[_]u8{0});
            hasher.update(std.mem.asBytes(&value));
        },
        .string => |bytes| {
            hasher.update(&[_]u8{1});
            hasher.update(bytes);
        },
    }
    const value = hasher.final();
    // Zero is the reserved "no widget", so the one digest that would collide
    // with it is moved aside. That makes 1 twice as likely as any other value,
    // which over a 64-bit space is not a rate anything above here can observe.
    return @enumFromInt(if (value == 0) 1 else value);
}
