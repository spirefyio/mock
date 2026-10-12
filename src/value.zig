//! mock's own JSON value, and parsing JSON text into it.
//!
//! A model holds values (examples, `default`, `enum`), and a model is built with struct literals,
//! at comptime as well as at run time. `std.json.Value` keeps arrays and objects in an `ArrayList`
//! and a `StringArrayHashMap`, which are built with an allocator, so mock has its own value made
//! of plain slices, with every number kept as its source text. Parsing refuses a repeated member
//! name and bounds the nesting depth; `std.json.Scanner` does the tokenizing.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A JSON value (RFC 8259).
pub const Value = union(enum) {
    null,
    bool: bool,
    number: Number,
    /// The string's content, escapes resolved, as UTF-8.
    string: []const u8,
    array: []const Value,
    /// The members in the order they were written.
    object: []const Member,
};

/// A JSON number kept as its source text, such as `12345678901234567890` or `1.10`, so that large
/// integers and exact decimals survive.
pub const Number = struct { text: []const u8 };

/// One member of a JSON object.
pub const Member = struct { name: []const u8, value: Value };

pub const ParseOptions = struct {
    /// The deepest nesting of arrays and objects accepted. `[]` and `{}` are depth 1, `[[]]` is
    /// depth 2, and a document that is a single number, string or literal is depth 0.
    max_depth: u16 = 64,
};

pub const ParseError = error{
    /// The text is not JSON (RFC 8259), or is not valid UTF-8.
    SyntaxError,
    /// The text ends inside a value, or holds no value at all.
    UnexpectedEndOfInput,
    /// An object names the same member twice, after escapes are resolved.
    DuplicateMember,
    /// Arrays and objects nest deeper than `ParseOptions.max_depth`.
    TooDeep,
    OutOfMemory,
};

/// Parses `source`, one complete JSON text, into a `Value`.
///
/// The result owns every byte it holds and does not point into `source`. Free it with `deinit`.
///
/// The text must be valid UTF-8, an escaped surrogate half must be one of a pair, and nothing but
/// whitespace may follow the value; `std.json.Scanner` enforces all three. A leading byte order mark is refused as a syntax error: RFC 8259 §8.1 lets a parser
/// either ignore it or refuse it, and the scanner refuses it.
///
/// Errors:
/// - `error.SyntaxError` when the text is not JSON or not valid UTF-8;
/// - `error.UnexpectedEndOfInput` when it ends before its value does, or is empty;
/// - `error.DuplicateMember` when an object repeats a member name;
/// - `error.TooDeep` when arrays and objects nest deeper than `options.max_depth`;
/// - `error.OutOfMemory`.
///
/// Errors come in the order the text meets them, except that a repeated name is found when its
/// object closes, so a syntax error later in that object is returned first.
pub fn parse(gpa: Allocator, source: []const u8, options: ParseOptions) ParseError!std.json.Parsed(Value) {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    return .{ .arena = arena, .value = try parseLeaky(arena.allocator(), gpa, source, options) };
}

/// An array or object that has begun and not yet ended.
const Open = struct {
    kind: enum { array, object },
    /// Where this container's items or members begin in the shared list.
    start: usize,
    /// For an object: the name of the member whose value comes next, once it has been read.
    name: ?[]const u8 = null,
};

/// The result goes in `arena`; `gpa` holds only scratch memory, freed before return.
/// An explicit stack, not recursion, so that no setting of `max_depth` can exhaust the call stack.
fn parseLeaky(arena: Allocator, gpa: Allocator, source: []const u8, options: ParseOptions) ParseError!Value {
    var scanner: std.json.Scanner = .initCompleteInput(gpa, source);
    defer scanner.deinit();

    var open: std.ArrayList(Open) = .empty;
    defer open.deinit(gpa);
    // The items of every open array, outermost first; each `Open.start` says where its own begin.
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(gpa);
    // The members of every open object, the same way.
    var members: std.ArrayList(Member) = .empty;
    defer members.deinit(gpa);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);

    while (true) {
        const token = try nextToken(&scanner, arena, source.len);
        const value: Value = switch (token) {
            .array_begin, .object_begin => {
                if (open.items.len >= options.max_depth) return error.TooDeep;
                try open.append(gpa, if (token == .array_begin)
                    .{ .kind = .array, .start = items.items.len }
                else
                    .{ .kind = .object, .start = members.items.len });
                continue;
            },
            .array_end => value: {
                const array = open.pop().?;
                const slice = try arena.dupe(Value, items.items[array.start..]);
                items.shrinkRetainingCapacity(array.start);
                break :value .{ .array = slice };
            },
            .object_end => value: {
                const object = open.pop().?;
                try refuseDuplicateNames(gpa, &names, members.items[object.start..]);
                const slice = try arena.dupe(Member, members.items[object.start..]);
                members.shrinkRetainingCapacity(object.start);
                break :value .{ .object = slice };
            },
            .true => .{ .bool = true },
            .false => .{ .bool = false },
            .null => .null,
            .allocated_number => |text| .{ .number = .{ .text = text } },
            .allocated_string => |text| value: {
                if (open.items.len != 0) {
                    const top = &open.items[open.items.len - 1];
                    // The scanner checks the grammar, so a string in an object with no name
                    // waiting is a member name.
                    if (top.kind == .object and top.name == null) {
                        top.name = text;
                        continue;
                    }
                }
                break :value .{ .string = text };
            },
            // With `.alloc_always` the scanner returns only the tokens above (`std.json.Token`
            // documents it), and `.end_of_document` only after a complete value, which returns
            // below before asking for another token.
            else => unreachable,
        };

        if (open.items.len == 0) {
            // The scanner refuses anything after the value but whitespace.
            const end = try nextToken(&scanner, arena, source.len);
            std.debug.assert(end == .end_of_document);
            return value;
        }
        const top = &open.items[open.items.len - 1];
        switch (top.kind) {
            .array => try items.append(gpa, value),
            .object => {
                try members.append(gpa, .{ .name = top.name.?, .value = value });
                top.name = null;
            },
        }
    }
}

fn nextToken(scanner: *std.json.Scanner, arena: Allocator, source_len: usize) ParseError!std.json.Token {
    // A string's content, escapes resolved, is never longer than its source text, and a number's
    // is its source text, so no value can exceed the input's length.
    return scanner.nextAllocMax(arena, .alloc_always, source_len) catch |err| switch (err) {
        error.ValueTooLong => unreachable,
        else => |e| e,
    };
}

/// The names come from whoever sent the JSON. std's string hash maps hash with the fixed seed 0
/// (`std.hash_map.hashString`), so a sender could choose names that collide; sorting a copy of the
/// names keeps the check at O(n log n) comparisons whatever the names are.
fn refuseDuplicateNames(
    gpa: Allocator,
    names: *std.ArrayList([]const u8),
    members: []const Member,
) error{ DuplicateMember, OutOfMemory }!void {
    if (members.len < 2) return;
    names.clearRetainingCapacity();
    try names.ensureTotalCapacity(gpa, members.len);
    for (members) |member| names.appendAssumeCapacity(member.name);
    std.mem.sort([]const u8, names.items, {}, nameLessThan);
    for (names.items[0 .. names.items.len - 1], names.items[1..]) |a, b| {
        if (std.mem.eql(u8, a, b)) return error.DuplicateMember;
    }
}

fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const testing = std.testing;

fn expectParsed(expected: Value, source: []const u8) !void {
    const parsed = try parse(testing.allocator, source, .{});
    defer parsed.deinit();
    try testing.expectEqualDeep(expected, parsed.value);
}

test "parse: numbers keep their source text" {
    // Through i64 or f64, 12345678901234567890 overflows or rounds, 1.10 becomes 1.1, -0 becomes 0
    // and 1E400 becomes inf.
    for ([_][]const u8{ "12345678901234567890", "1.10", "-0", "1E400", "0.1e-7", "-12.500" }) |text| {
        try expectParsed(.{ .number = .{ .text = text } }, text);
    }
    try expectParsed(.{ .array = &.{
        .{ .number = .{ .text = "12345678901234567890" } },
        .{ .number = .{ .text = "1.10" } },
    } }, "[12345678901234567890, 1.10]");
}

test "parse: every kind of value, with members in source order" {
    try expectParsed(.{ .object = &.{
        .{ .name = "z", .value = .null },
        .{ .name = "a", .value = .{ .array = &.{ .{ .bool = true }, .{ .bool = false }, .{ .array = &.{} } } } },
        .{ .name = "m", .value = .{ .object = &.{} } },
        .{ .name = "s", .value = .{ .string = "a\nb\u{e9}\u{1F600}" } },
    } },
        \\ {"z": null, "a": [true, false, []], "m": {}, "s": "a\nb\u00e9\ud83d\ude00"}
    );
    try expectParsed(.{ .string = "top" }, "\"top\"");
}

test "parse: a repeated member name is refused" {
    const refused = [_][]const u8{
        \\{"a": 1, "a": 2}
        ,
        // The same name once escapes are resolved.
        \\{"a": 1, "\u0061": 2}
        ,
        \\{"b": 0, "a": 1, "c": 2, "a": 3}
        ,
        \\[{"x": {"k": 1, "k": 1}}]
        ,
    };
    for (refused) |source| {
        try testing.expectError(error.DuplicateMember, parse(testing.allocator, source, .{}));
    }
    // One name per object: the same name in two objects, or at two depths, is not a repeat.
    try expectParsed(.{ .array = &.{
        .{ .object = &.{.{ .name = "a", .value = .{ .number = .{ .text = "1" } } }} },
        .{ .object = &.{.{ .name = "a", .value = .{ .object = &.{.{ .name = "a", .value = .null }} } }} },
    } },
        \\[{"a": 1}, {"a": {"a": null}}]
    );
}

test "parse: nesting is bounded by max_depth" {
    var buf: [2 * 65]u8 = undefined;
    @memset(buf[0..65], '[');
    @memset(buf[65..], ']');
    const at_limit = buf[1 .. buf.len - 1]; // 64 deep
    const parsed = try parse(testing.allocator, at_limit, .{});
    parsed.deinit();
    try testing.expectError(error.TooDeep, parse(testing.allocator, &buf, .{}));

    // Objects count as arrays do.
    try testing.expectError(error.TooDeep, parse(testing.allocator,
        \\{"a": [{"b": []}]}
    , .{ .max_depth = 3 }));
    const three = try parse(testing.allocator,
        \\{"a": [{"b": 1}]}
    , .{ .max_depth = 3 });
    three.deinit();

    // Depth 0 allows a lone scalar only.
    const scalar = try parse(testing.allocator, "7", .{ .max_depth = 0 });
    scalar.deinit();
    try testing.expectError(error.TooDeep, parse(testing.allocator, "[]", .{ .max_depth = 0 }));
}

test "parse: the deepest nesting a u16 max_depth allows parses without exhausting the stack" {
    // A recursive parser would need tens of thousands of frames here.
    const depth = std.math.maxInt(u16);
    const source = try testing.allocator.alloc(u8, 2 * depth);
    defer testing.allocator.free(source);
    @memset(source[0..depth], '[');
    @memset(source[depth..], ']');
    const parsed = try parse(testing.allocator, source, .{ .max_depth = depth });
    defer parsed.deinit();
    var reached: usize = 0;
    var v = parsed.value;
    while (v == .array) : (reached += 1) {
        if (v.array.len == 0) {
            reached += 1;
            break;
        }
        v = v.array[0];
    }
    try testing.expectEqual(depth, reached);
}

test "parse: text that is not one JSON value is refused" {
    const syntax = [_][]const u8{
        "[1,]",
        "{\"a\" 1}",
        "1 2",
        "[1] x",
        "\xef\xbb\xbf[]", // a byte order mark
        "\"\xff\"", // not UTF-8
        "\"\\ud800\"", // half a surrogate pair
        "\"\\udc00\\ud800\"", // the halves in the wrong order
        "{\"a\": 1, \"a\": 2,]", // a repeated name, but the syntax error comes first
        "01",
        "{a: 1}",
    };
    for (syntax) |source| {
        try testing.expectError(error.SyntaxError, parse(testing.allocator, source, .{}));
    }
    for ([_][]const u8{ "", "  ", "[1", "{\"a\":", "\"abc" }) |source| {
        try testing.expectError(error.UnexpectedEndOfInput, parse(testing.allocator, source, .{}));
    }
}

test "parse: the result does not point into the source" {
    const source = try testing.allocator.dupe(u8,
        \\{"plain": "text", "n": 12}
    );
    const parsed = parse(testing.allocator, source, .{}) catch |err| {
        testing.allocator.free(source);
        return err;
    };
    defer parsed.deinit();
    // A result that borrowed from the source would now read differently.
    @memset(source, 'x');
    testing.allocator.free(source);
    try testing.expectEqualDeep(Value{ .object = &.{
        .{ .name = "plain", .value = .{ .string = "text" } },
        .{ .name = "n", .value = .{ .number = .{ .text = "12" } } },
    } }, parsed.value);
}

fn parseAndFree(gpa: Allocator, source: []const u8) !void {
    const parsed = try parse(gpa, source, .{});
    parsed.deinit();
}

test "parse: no leak or double free when any allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, parseAndFree, .{
        \\{"a": [1, "two\n", {"b": [true, null]}], "c": {"d": "e"}, "f": 1.10}
    });
    // A duplicate found after allocations have been made.
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            parseAndFree(gpa,
                \\{"a": [1, {"x": "y"}], "b": 2, "a": 3}
            ) catch |err| switch (err) {
                error.DuplicateMember => return,
                else => return err,
            };
            return error.TestUnexpectedResult;
        }
    }.run, .{});
}
