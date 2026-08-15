const std = @import("std");
const imui = @import("lenore-imui");

const testing = std.testing;

const Id = imui.Id;
const IdStack = imui.IdStack;

fn stack(storage: []Id, seed: u64) !IdStack {
    return IdStack.init(storage, seed);
}

test "a stack needs room for its root" {
    var empty: [0]Id = .{};
    try testing.expectError(error.EmptyStorage, IdStack.init(&empty, 1));
}

test "the root is a live identity even from a zero seed" {
    var storage: [4]Id = undefined;
    const ids = try stack(&storage, 0);
    try testing.expect(ids.current().isValid());
}

test "seeds namespace one surface against another" {
    var first_storage: [4]Id = undefined;
    var second_storage: [4]Id = undefined;
    const first = try stack(&first_storage, 1);
    const second = try stack(&second_storage, 2);
    try testing.expect(first.current() != second.current());
}

test "the same key in the same scope derives the same identity" {
    var storage: [4]Id = undefined;
    var ids = try stack(&storage, 7);
    try testing.expectEqual(ids.id(.{ .string = "ok" }), ids.id(.{ .string = "ok" }));
    try testing.expect(ids.id(.{ .string = "ok" }) != ids.id(.{ .string = "cancel" }));
}

test "an eight-byte string and the integer it spells are disjoint" {
    var storage: [4]Id = undefined;
    var ids = try stack(&storage, 7);

    // The collision the tag byte in `derive` exists to stop, and the only one
    // it is needed for. A key of any other length is separated by its length
    // alone; a key of exactly eight bytes presents the hasher with the same
    // bytes `std.mem.asBytes` produces for one integer, so without a tag the
    // two are one input.
    const spelling = "rowindex";
    const spelled = std.mem.bytesToValue(u64, spelling);
    try testing.expect(ids.id(.{ .integer = spelled }) != ids.id(.{ .string = spelling }));
}

test "a scope namespaces the keys derived inside it" {
    var storage: [4]Id = undefined;
    var ids = try stack(&storage, 7);

    const outside = ids.id(.{ .string = "delete" });
    try ids.push(.{ .string = "left panel" });
    const inside = ids.id(.{ .string = "delete" });
    ids.pop();

    try testing.expect(outside != inside);
    try testing.expectEqual(outside, ids.id(.{ .string = "delete" }));
}

test "two scopes with the same key under different parents stay distinct" {
    var storage: [4]Id = undefined;
    var ids = try stack(&storage, 7);

    try ids.push(.{ .string = "left" });
    try ids.push(.{ .string = "row" });
    const under_left = ids.id(.{ .integer = 0 });
    ids.pop();
    ids.pop();

    try ids.push(.{ .string = "right" });
    try ids.push(.{ .string = "row" });
    const under_right = ids.id(.{ .integer = 0 });
    ids.pop();
    ids.pop();

    try testing.expect(under_left != under_right);
}

test "a frame ends at the root and identities survive the reset" {
    var storage: [4]Id = undefined;
    var ids = try stack(&storage, 7);
    const before = ids.id(.{ .string = "title" });

    try ids.push(.{ .integer = 3 });
    try testing.expect(!ids.isAtRoot());
    ids.reset();

    try testing.expect(ids.isAtRoot());
    try testing.expectEqual(before, ids.id(.{ .string = "title" }));
}

test "the stack refuses a scope past its storage" {
    var storage: [2]Id = undefined;
    var ids = try stack(&storage, 7);
    try ids.push(.{ .integer = 0 });
    try testing.expectError(error.ScopeCapacityExceeded, ids.push(.{ .integer = 1 }));
    // The refused push left the scope that was open untouched.
    try testing.expect(!ids.isAtRoot());
}
