//! Loading a model: the checks that decide which of its operations can be served, and the load
//! report that names every refusal.
//!
//! The checks here are the ones the model types state: a service name, an operation id within
//! its service and a security scheme name within its service are each used once; every scheme a
//! requirement names is declared; no declared scheme is of a kind mock does not implement; and no
//! schema sets `pattern` or carries a keyword other than the annotations `Schema.other_keywords`
//! lists.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");

pub const Options = struct {
    /// What a refusal does to the load.
    ///
    /// - `.refuse_model`: any refusal fails the load with `error.ModelRefused`.
    /// - `.refuse_operation`: the load succeeds, and each operation that needs something refused
    ///   is marked refused in `Compiled.refused`; the rest are served. A refusal that needs no
    ///   operation, such as a scheme no requirement names, refuses nothing. A service name used
    ///   twice still fails the load, because the name is how the service is addressed and no
    ///   operation of either service could be told apart from the other's.
    on_unsupported: enum { refuse_model, refuse_operation } = .refuse_model,
};

/// One line of the load report.
pub const Refusal = struct {
    service: []const u8,
    /// Null when the refused item is in the service rather than in one operation: a scheme it
    /// declares, or the requirements it gives operations whose own `security` is null.
    operation: ?[]const u8,
    /// A JSON pointer (RFC 6901) from the model's root to the refused item, through the model
    /// types' field names and slice indices, such as
    /// "/services/0/operations/2/parameters/0/schema/items". A schema reached by more than one path
    /// is named by the first path the check took.
    pointer: []const u8,
    reason: Reason,
    /// What was refused: the keyword, the scheme a requirement names, the scheme kind, or the name
    /// used twice.
    name: []const u8,

    pub const Reason = enum {
        duplicate_service_name,
        duplicate_operation_id,
        duplicate_scheme_name,
        unknown_scheme,
        unsupported_scheme_kind,
        unsupported_keyword,
    };

    /// Writes the refusal as one line with no line break, such as
    /// `service "pets", operation "getPet", /services/0/operations/0/parameters/0/schema:
    /// unsupported keyword "not"`. Names are written as JSON strings, so a name holding a quote
    /// or a line break still gives one line.
    ///
    /// Errors: `error.WriteFailed` when `w` fails.
    pub fn format(r: Refusal, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("service {f}", .{std.json.fmt(r.service, .{})});
        if (r.operation) |id| try w.print(", operation {f}", .{std.json.fmt(id, .{})});
        const what = switch (r.reason) {
            .duplicate_service_name => "service name used twice",
            .duplicate_operation_id => "operation id used twice",
            .duplicate_scheme_name => "security scheme name used twice",
            .unknown_scheme => "no security scheme named",
            .unsupported_scheme_kind => "unsupported security scheme kind",
            .unsupported_keyword => "unsupported keyword",
        };
        try w.print(", {s}: {s} {f}", .{ r.pointer, what, std.json.fmt(r.name, .{}) });
    }
};

/// Carries the load report out of `compile`, which a Zig error cannot.
pub const Diagnostics = struct {
    /// Every refusal of the last load given this `Diagnostics`, in the order the checks met them:
    /// each service in turn, and in a service its name, its schemes, its requirements, then each
    /// operation. Empty after a load that refused nothing, and after `error.OutOfMemory`.
    report: []const Refusal = &.{},
    arena: std.heap.ArenaAllocator.State = .init,

    /// Frees the report and leaves `d` empty and reusable. `gpa` is the allocator given to the
    /// load that filled it.
    pub fn deinit(d: *Diagnostics, gpa: Allocator) void {
        d.arena.promote(gpa).deinit();
        d.* = .{};
    }
};

/// What a load decided. It holds no pointer into the model it was made from.
pub const Compiled = struct {
    /// `refused[s][o]` is true when operation `o` of service `s` needs something the load refused.
    /// Only a load under `.refuse_operation` returns any set.
    refused: []const []const bool,

    pub fn deinit(c: *Compiled, gpa: Allocator) void {
        for (c.refused) |row| gpa.free(row);
        gpa.free(c.refused);
        c.* = undefined;
    }
};

pub const Error = error{
    /// The model has a refusal that `options.on_unsupported` does not let it be served with.
    /// `diag`, if given, holds the report.
    ModelRefused,
    OutOfMemory,
};

/// Checks `m` and decides which of its operations can be served.
///
/// Nothing returned points into `m`, so the caller may free it as soon as this returns. When
/// `diag` is given, any report it held is freed and it receives this load's report, on success
/// as on `error.ModelRefused`; free it with `diag.deinit(gpa)`.
///
/// Errors:
/// - `error.ModelRefused` when there is any refusal under `.refuse_model`, or a service name used
///   twice under either setting;
/// - `error.OutOfMemory`, after which `diag` holds an empty report.
pub fn compile(gpa: Allocator, m: *const model.Model, options: Options, diag: ?*Diagnostics) Error!Compiled {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    var checked = check(gpa, arena.allocator(), m) catch |err| {
        arena.deinit();
        if (diag) |d| d.deinit(gpa);
        return err;
    };
    if (diag) |d| {
        d.deinit(gpa);
        d.* = .{ .report = checked.report, .arena = arena.state };
    } else arena.deinit();

    if (checked.report.len != 0 and (options.on_unsupported == .refuse_model or checked.model_wide)) {
        checked.compiled.deinit(gpa);
        return error.ModelRefused;
    }
    return checked.compiled;
}

const Checked = struct {
    compiled: Compiled,
    report: []const Refusal,
    /// Some refusal concerns the whole model, so no setting lets it load.
    model_wide: bool,
};

fn check(gpa: Allocator, arena: Allocator, m: *const model.Model) Allocator.Error!Checked {
    const refused = try gpa.alloc([]bool, m.services.len);
    var rows: usize = 0;
    errdefer {
        for (refused[0..rows]) |row| gpa.free(row);
        gpa.free(refused);
    }
    for (refused, m.services) |*row, service| {
        row.* = try gpa.alloc(bool, service.operations.len);
        @memset(row.*, false);
        rows += 1;
    }

    var checker: Checker = .{ .gpa = gpa, .arena = arena };
    defer checker.deinit();
    try checker.checkModel(m, refused);
    return .{
        .compiled = .{ .refused = refused },
        .report = checker.report.items,
        .model_wide = checker.model_wide,
    };
}

/// Where in the model a check is: a service, or one of its operations.
const Site = struct {
    service: *const model.Service,
    s: usize,
    operation: ?*const model.Operation = null,
    o: usize = 0,
};

/// Where a schema graph hangs off an operation.
const Root = union(enum) {
    parameter: usize,
    request_content: usize,
    response_header: struct { usize, usize },
    response_content: struct { usize, usize },
};

/// How the walk reached a schema from the one before it, or from its root.
const Edge = union(enum) {
    root: Root,
    items,
    property: usize,
    additional,
    all_of: usize,
    any_of: usize,
    one_of: usize,
};

const Step = struct {
    /// The index in `Checker.trail` of the schema this one was reached from; null at a root.
    parent: ?usize,
    edge: Edge,
};

const Pending = struct {
    schema: *const model.Schema,
    /// This schema's index in `Checker.trail`.
    step: usize,
};

const Checker = struct {
    gpa: Allocator,
    /// Holds the report: every `Refusal` and every string in one.
    arena: Allocator,
    report: std.ArrayList(Refusal) = .empty,
    model_wide: bool = false,

    // Scratch for the schema walk, reused for each operation.
    visited: std.AutoHashMapUnmanaged(*const model.Schema, void) = .empty,
    stack: std.ArrayList(Pending) = .empty,
    trail: std.ArrayList(Step) = .empty,
    chain: std.ArrayList(usize) = .empty,

    fn deinit(c: *Checker) void {
        c.visited.deinit(c.gpa);
        c.stack.deinit(c.gpa);
        c.trail.deinit(c.gpa);
        c.chain.deinit(c.gpa);
    }

    fn checkModel(c: *Checker, m: *const model.Model, refused: []const []bool) Allocator.Error!void {
        var names: std.StringHashMapUnmanaged(void) = .empty;
        defer names.deinit(c.gpa);
        for (m.services, refused, 0..) |*service, service_refused, s| {
            const at: Site = .{ .service = service, .s = s };
            if ((try names.getOrPut(c.gpa, service.name)).found_existing) {
                c.model_wide = true;
                try c.refuse(at, "/name", .{}, .duplicate_service_name, service.name);
            }
            try c.checkService(at, service_refused);
        }
    }

    fn checkService(c: *Checker, at: Site, refused: []bool) Allocator.Error!void {
        const service = at.service;

        // For each declared scheme name, whether an operation whose requirements name it is
        // refused: true when the name is declared twice, since a requirement naming it is
        // ambiguous, or when a scheme of that name is of a kind mock does not implement.
        var schemes: std.StringHashMapUnmanaged(bool) = .empty;
        defer schemes.deinit(c.gpa);
        for (service.security_schemes, 0..) |scheme, i| {
            const entry = try schemes.getOrPut(c.gpa, scheme.name);
            if (entry.found_existing) {
                entry.value_ptr.* = true;
                try c.refuse(at, "/security_schemes/{d}/name", .{i}, .duplicate_scheme_name, scheme.name);
            } else entry.value_ptr.* = false;
            switch (scheme.kind) {
                .other => |kind| {
                    entry.value_ptr.* = true;
                    try c.refuse(at, "/security_schemes/{d}/kind/other", .{i}, .unsupported_scheme_kind, kind);
                },
                .api_key, .http_basic, .http_bearer, .oauth2, .openid_connect => {},
            }
        }

        const defaults_refused = try c.checkRequirements(at, &schemes, service.security);

        // Each id's first operation, so that a repeat can refuse it as well.
        var ids: std.StringHashMapUnmanaged(usize) = .empty;
        defer ids.deinit(c.gpa);
        for (service.operations, 0..) |*operation, o| {
            const op_at: Site = .{ .service = service, .s = at.s, .operation = operation, .o = o };
            const first = try ids.getOrPut(c.gpa, operation.id);
            if (first.found_existing) {
                // The record and fault rules name an operation by its id, so neither of the two
                // could be told apart from the other.
                refused[first.value_ptr.*] = true;
                refused[o] = true;
                try c.refuse(op_at, "/id", .{}, .duplicate_operation_id, operation.id);
            } else first.value_ptr.* = o;

            const requirements_refused = if (operation.security) |own|
                try c.checkRequirements(op_at, &schemes, own)
            else
                defaults_refused;
            if (requirements_refused) refused[o] = true;
            if (try c.checkSchemas(op_at)) refused[o] = true;
        }
    }

    /// Returns whether any requirement names a scheme that is not declared or is refused.
    fn checkRequirements(
        c: *Checker,
        at: Site,
        schemes: *const std.StringHashMapUnmanaged(bool),
        requirements: []const model.Requirement,
    ) Allocator.Error!bool {
        var refused = false;
        for (requirements, 0..) |requirement, k| {
            for (requirement, 0..) |use, u| {
                if (schemes.get(use.scheme)) |scheme_refused| {
                    if (scheme_refused) refused = true;
                } else {
                    refused = true;
                    try c.refuse(at, "/security/{d}/{d}/scheme", .{ k, u }, .unknown_scheme, use.scheme);
                }
            }
        }
        return refused;
    }

    /// Walks every schema graph that hangs off the operation, each schema once, and returns
    /// whether any schema was refused. The walk keeps its own stack, so a long chain of schemas
    /// cannot overflow the call stack, and its visited set makes a pointer cycle end.
    fn checkSchemas(c: *Checker, at: Site) Allocator.Error!bool {
        c.visited.clearRetainingCapacity();
        c.trail.clearRetainingCapacity();
        const operation = at.operation.?;
        var refused = false;
        for (operation.parameters, 0..) |parameter, i| {
            if (try c.walk(at, parameter.schema, .{ .parameter = i })) refused = true;
        }
        if (operation.request_body) |body| {
            for (body.content, 0..) |content, i| {
                const schema = content.schema orelse continue;
                if (try c.walk(at, schema, .{ .request_content = i })) refused = true;
            }
        }
        for (operation.responses, 0..) |response, r| {
            for (response.headers, 0..) |header, h| {
                if (try c.walk(at, header.schema, .{ .response_header = .{ r, h } })) refused = true;
            }
            for (response.content, 0..) |content, i| {
                const schema = content.schema orelse continue;
                if (try c.walk(at, schema, .{ .response_content = .{ r, i } })) refused = true;
            }
        }
        return refused;
    }

    fn walk(c: *Checker, at: Site, root: *const model.Schema, from: Root) Allocator.Error!bool {
        std.debug.assert(c.stack.items.len == 0);
        try c.push(root, .{ .parent = null, .edge = .{ .root = from } });
        var refused = false;
        while (c.stack.pop()) |pending| {
            if (try c.checkSchema(at, pending)) refused = true;
            // Children are pushed last first, so that they are checked in field order.
            const schema = pending.schema;
            var i = schema.one_of.len;
            while (i > 0) : (i -= 1) try c.push(schema.one_of[i - 1], .{ .parent = pending.step, .edge = .{ .one_of = i - 1 } });
            i = schema.any_of.len;
            while (i > 0) : (i -= 1) try c.push(schema.any_of[i - 1], .{ .parent = pending.step, .edge = .{ .any_of = i - 1 } });
            i = schema.all_of.len;
            while (i > 0) : (i -= 1) try c.push(schema.all_of[i - 1], .{ .parent = pending.step, .edge = .{ .all_of = i - 1 } });
            switch (schema.additional_properties) {
                .schema => |additional| try c.push(additional, .{ .parent = pending.step, .edge = .additional }),
                .allowed, .forbidden => {},
            }
            i = schema.properties.len;
            while (i > 0) : (i -= 1) try c.push(schema.properties[i - 1].schema, .{ .parent = pending.step, .edge = .{ .property = i - 1 } });
            if (schema.items) |items| try c.push(items, .{ .parent = pending.step, .edge = .items });
        }
        return refused;
    }

    fn push(c: *Checker, schema: *const model.Schema, step: Step) Allocator.Error!void {
        if ((try c.visited.getOrPut(c.gpa, schema)).found_existing) return;
        try c.trail.append(c.gpa, step);
        try c.stack.append(c.gpa, .{ .schema = schema, .step = c.trail.items.len - 1 });
    }

    /// Returns whether the schema itself, not counting its children, was refused.
    fn checkSchema(c: *Checker, at: Site, pending: Pending) Allocator.Error!bool {
        // Built on the first refusal, then shared by the others in this schema.
        var pointer: ?[]const u8 = null;
        if (pending.schema.pattern != null) {
            pointer = try c.schemaPointer(at, pending.step);
            try c.add(at, pointer.?, .unsupported_keyword, "pattern");
        }
        for (pending.schema.other_keywords) |keyword| {
            if (isAnnotation(keyword)) continue;
            if (pointer == null) pointer = try c.schemaPointer(at, pending.step);
            try c.add(at, pointer.?, .unsupported_keyword, keyword);
        }
        return pointer != null;
    }

    fn schemaPointer(c: *Checker, at: Site, step: usize) Allocator.Error![]const u8 {
        c.chain.clearRetainingCapacity();
        var next: ?usize = step;
        while (next) |index| {
            try c.chain.append(c.gpa, index);
            next = c.trail.items[index].parent;
        }
        var out: std.ArrayList(u8) = .empty;
        try out.print(c.arena, "/services/{d}/operations/{d}", .{ at.s, at.o });
        var k = c.chain.items.len;
        while (k > 0) {
            k -= 1;
            switch (c.trail.items[c.chain.items[k]].edge) {
                .root => |root| switch (root) {
                    .parameter => |i| try out.print(c.arena, "/parameters/{d}/schema", .{i}),
                    .request_content => |i| try out.print(c.arena, "/request_body/content/{d}/schema", .{i}),
                    .response_header => |rh| try out.print(c.arena, "/responses/{d}/headers/{d}/schema", rh),
                    .response_content => |rc| try out.print(c.arena, "/responses/{d}/content/{d}/schema", rc),
                },
                .items => try out.appendSlice(c.arena, "/items"),
                .property => |i| try out.print(c.arena, "/properties/{d}/schema", .{i}),
                .additional => try out.appendSlice(c.arena, "/additional_properties/schema"),
                .all_of => |i| try out.print(c.arena, "/all_of/{d}", .{i}),
                .any_of => |i| try out.print(c.arena, "/any_of/{d}", .{i}),
                .one_of => |i| try out.print(c.arena, "/one_of/{d}", .{i}),
            }
        }
        return out.items;
    }

    /// Adds a refusal at `at` plus `suffix`.
    fn refuse(
        c: *Checker,
        at: Site,
        comptime suffix: []const u8,
        args: anytype,
        reason: Refusal.Reason,
        name: []const u8,
    ) Allocator.Error!void {
        const pointer = if (at.operation == null)
            try std.fmt.allocPrint(c.arena, "/services/{d}" ++ suffix, .{at.s} ++ args)
        else
            try std.fmt.allocPrint(c.arena, "/services/{d}/operations/{d}" ++ suffix, .{ at.s, at.o } ++ args);
        try c.add(at, pointer, reason, name);
    }

    /// Adds a refusal. `pointer` is already in the arena; every other string is copied there,
    /// because the caller may free the model once the load returns.
    fn add(c: *Checker, at: Site, pointer: []const u8, reason: Refusal.Reason, name: []const u8) Allocator.Error!void {
        try c.report.append(c.arena, .{
            .service = try c.arena.dupe(u8, at.service.name),
            .operation = if (at.operation) |operation| try c.arena.dupe(u8, operation.id) else null,
            .pointer = pointer,
            .reason = reason,
            .name = try c.arena.dupe(u8, name),
        });
    }
};

/// The keywords `Schema.other_keywords` may carry: pure annotations, which change nothing mock
/// does. An extension is any name starting `x-`, compared with case, as OpenAPI's field names are.
fn isAnnotation(keyword: []const u8) bool {
    if (std.mem.startsWith(u8, keyword, "x-")) return true;
    const annotations = [_][]const u8{ "title", "description", "$comment", "deprecated", "externalDocs", "discriminator" };
    for (annotations) |annotation| {
        if (std.mem.eql(u8, keyword, annotation)) return true;
    }
    return false;
}

const testing = std.testing;

/// Loads `m` and returns its report and decision; the caller frees both.
const Loaded = struct {
    diag: Diagnostics,
    compiled: ?Compiled,
    err: ?Error,

    fn init(m: *const model.Model, options: Options) Loaded {
        var loaded: Loaded = .{ .diag = .{}, .compiled = null, .err = null };
        loaded.compiled = compile(testing.allocator, m, options, &loaded.diag) catch |err| blk: {
            loaded.err = err;
            break :blk null;
        };
        return loaded;
    }

    fn deinit(l: *Loaded) void {
        if (l.compiled) |*c| c.deinit(testing.allocator);
        l.diag.deinit(testing.allocator);
    }

    fn expectModelRefused(l: Loaded) !void {
        try testing.expectEqual(@as(?Error, error.ModelRefused), l.err);
    }

    fn expectRefusals(l: Loaded, expected: []const Refusal) !void {
        try testing.expectEqualDeep(expected, l.diag.report);
    }

    fn expectRefused(l: Loaded, expected: []const []const bool) !void {
        if (l.err) |err| return err;
        try testing.expectEqualDeep(expected, l.compiled.?.refused);
    }
};

fn op(id: []const u8, responses: []const model.Response) model.Operation {
    return .{ .id = id, .method = .GET, .path = "/x", .responses = responses };
}

/// A 200 response with `schema`. Comptime, so that the slice it returns is static.
fn ok(comptime schema: *const model.Schema) []const model.Response {
    return &.{.{ .status = .{ .code = 200 }, .content = &.{.{ .media_type = "application/json", .schema = schema }} }};
}

const plain: model.Schema = .{ .types = .string };
const refused_not: model.Schema = .{ .other_keywords = &.{"not"} };

test "compile: the design's example model loads with nothing refused" {
    const pet: model.Schema = .{
        .types = .object,
        .properties = &.{
            .{ .name = "id", .schema = &.{ .types = .integer, .format = "int64" } },
            .{ .name = "name", .schema = &.{ .types = .string, .min_length = 1 } },
        },
        .required = &.{ "id", "name" },
    };
    const m: model.Model = .{ .services = &.{.{
        .name = "pets",
        .operations = &.{.{
            .id = "getPet",
            .method = .GET,
            .path = "/pets/{petId}",
            .parameters = &.{.{ .name = "petId", .in = .path, .schema = &.{ .types = .integer } }},
            .responses = &.{.{
                .status = .{ .code = 200 },
                .content = &.{.{ .media_type = "application/json", .schema = &pet }},
            }},
        }},
    }} };
    var loaded: Loaded = .init(&m, .{});
    defer loaded.deinit();
    try loaded.expectRefusals(&.{});
    try loaded.expectRefused(&.{&.{false}});
}

test "compile: a keyword outside the annotations is refused, by name and place" {
    const body: model.Schema = .{
        .types = .object,
        .properties = &.{
            .{ .name = "a", .schema = &plain },
            .{ .name = "b", .schema = &.{ .items = &.{ .all_of = &.{ &plain, &refused_not } } } },
        },
    };
    const m: model.Model = .{ .services = &.{.{ .name = "pets", .operations = &.{.{
        .id = "createPet",
        .method = .POST,
        .path = "/pets",
        .request_body = .{ .content = &.{
            .{ .media_type = "text/plain" },
            .{ .media_type = "application/json", .schema = &body },
        } },
        .responses = &.{.{ .status = .{ .code = 201 } }},
    }} }} };
    var loaded: Loaded = .init(&m, .{});
    defer loaded.deinit();
    try loaded.expectModelRefused();
    try loaded.expectRefusals(&.{.{
        .service = "pets",
        .operation = "createPet",
        .pointer = "/services/0/operations/0/request_body/content/1/schema/properties/1/schema/items/all_of/1",
        .reason = .unsupported_keyword,
        .name = "not",
    }});
}

test "compile: annotations are accepted, and every other keyword is refused" {
    const schema: model.Schema = .{
        .pattern = "^a",
        .other_keywords = &.{
            "title",      "description", "$comment",   "deprecated", "externalDocs", "discriminator",
            "x-internal", "x-",          "X-Internal", "if",         "$ref",         "patternProperties",
        },
    };
    const m: model.Model = .{ .services = &.{.{ .name = "s", .operations = &.{op("o", ok(&schema))} }} };
    var loaded: Loaded = .init(&m, .{});
    defer loaded.deinit();
    const expected = [_][]const u8{ "pattern", "X-Internal", "if", "$ref", "patternProperties" };
    try testing.expectEqual(expected.len, loaded.diag.report.len);
    for (expected, loaded.diag.report) |name, r| {
        try testing.expectEqualStrings(name, r.name);
        try testing.expectEqual(.unsupported_keyword, r.reason);
        try testing.expectEqualStrings("/services/0/operations/0/responses/0/content/0/schema", r.pointer);
    }
}

test "compile: on_unsupported decides between failing the load and refusing what needs it" {
    const m: model.Model = .{ .services = &.{.{ .name = "s", .operations = &.{
        op("bad", ok(&refused_not)),
        op("good", ok(&plain)),
    } }} };
    const line: Refusal = .{
        .service = "s",
        .operation = "bad",
        .pointer = "/services/0/operations/0/responses/0/content/0/schema",
        .reason = .unsupported_keyword,
        .name = "not",
    };

    var whole: Loaded = .init(&m, .{ .on_unsupported = .refuse_model });
    defer whole.deinit();
    try whole.expectModelRefused();
    try whole.expectRefusals(&.{line});

    var per_op: Loaded = .init(&m, .{ .on_unsupported = .refuse_operation });
    defer per_op.deinit();
    try per_op.expectRefused(&.{&.{ true, false }});
    try per_op.expectRefusals(&.{line});
}

const self_items: model.Schema = .{ .items = &self_items, .other_keywords = &.{"not"} };
const tree: model.Schema = .{
    .properties = &.{.{ .name = "child", .schema = &tree }},
    .additional_properties = .{ .schema = &tree },
    .one_of = &.{ &tree, &refused_not },
};

test "compile: a schema cycle is walked once, and each schema refused once" {
    const m: model.Model = .{ .services = &.{.{ .name = "s", .operations = &.{
        op("loop", ok(&self_items)),
        op("tree", ok(&tree)),
    } }} };
    var loaded: Loaded = .init(&m, .{ .on_unsupported = .refuse_operation });
    defer loaded.deinit();
    try loaded.expectRefusals(&.{
        .{ .service = "s", .operation = "loop", .pointer = "/services/0/operations/0/responses/0/content/0/schema", .reason = .unsupported_keyword, .name = "not" },
        .{ .service = "s", .operation = "tree", .pointer = "/services/0/operations/1/responses/0/content/0/schema/one_of/1", .reason = .unsupported_keyword, .name = "not" },
    });
    try loaded.expectRefused(&.{&.{ true, true }});
}

test "compile: a schema shared by two operations is refused in each" {
    const m: model.Model = .{ .services = &.{.{ .name = "s", .operations = &.{
        .{ .id = "a", .method = .GET, .path = "/a", .parameters = &.{
            .{ .name = "q", .in = .query, .schema = &plain },
            .{ .name = "h", .in = .header, .schema = &refused_not },
        }, .responses = &.{.{ .status = .default }} },
        op("b", &.{.{ .status = .{ .range = 2 }, .headers = &.{.{ .name = "X-A", .schema = &refused_not }} }}),
        op("c", ok(&plain)),
    } }} };
    var loaded: Loaded = .init(&m, .{ .on_unsupported = .refuse_operation });
    defer loaded.deinit();
    try loaded.expectRefusals(&.{
        .{ .service = "s", .operation = "a", .pointer = "/services/0/operations/0/parameters/1/schema", .reason = .unsupported_keyword, .name = "not" },
        .{ .service = "s", .operation = "b", .pointer = "/services/0/operations/1/responses/0/headers/0/schema", .reason = .unsupported_keyword, .name = "not" },
    });
    try loaded.expectRefused(&.{&.{ true, true, false }});
}

test "compile: a requirement naming an undeclared scheme refuses the operations that take it" {
    const m: model.Model = .{ .services = &.{.{
        .name = "s",
        .security_schemes = &.{.{ .name = "key", .kind = .{ .api_key = .{ .in = .header, .name = "X-Key" } } }},
        .security = &.{&.{.{ .scheme = "nope" }}},
        .operations = &.{
            op("inherits", ok(&plain)),
            .{ .id = "own", .method = .GET, .path = "/o", .responses = ok(&plain), .security = &.{
                &.{.{ .scheme = "key" }},
                &.{ .{ .scheme = "key" }, .{ .scheme = "missing" } },
            } },
            .{ .id = "none", .method = .GET, .path = "/n", .responses = ok(&plain), .security = &.{} },
            .{ .id = "declared", .method = .GET, .path = "/d", .responses = ok(&plain), .security = &.{&.{.{ .scheme = "key" }}} },
        },
    }} };
    var loaded: Loaded = .init(&m, .{ .on_unsupported = .refuse_operation });
    defer loaded.deinit();
    try loaded.expectRefusals(&.{
        .{ .service = "s", .operation = null, .pointer = "/services/0/security/0/0/scheme", .reason = .unknown_scheme, .name = "nope" },
        .{ .service = "s", .operation = "own", .pointer = "/services/0/operations/1/security/1/1/scheme", .reason = .unknown_scheme, .name = "missing" },
    });
    try loaded.expectRefused(&.{&.{ true, true, false, false }});
}

test "compile: a scheme of a kind mock does not implement refuses every operation that names it" {
    const m: model.Model = .{
        .services = &.{.{
            .name = "s",
            .security_schemes = &.{
                .{ .name = "key", .kind = .{ .api_key = .{ .in = .query, .name = "k" } } },
                .{ .name = "mtls", .kind = .{ .other = "mutualTLS" } },
            },
            .operations = &.{
                .{ .id = "only", .method = .GET, .path = "/a", .responses = ok(&plain), .security = &.{&.{.{ .scheme = "mtls" }}} },
                .{ .id = "key", .method = .GET, .path = "/b", .responses = ok(&plain), .security = &.{&.{.{ .scheme = "key" }}} },
                // Either requirement would do, but a request carrying the second could not be checked.
                .{ .id = "either", .method = .GET, .path = "/c", .responses = ok(&plain), .security = &.{
                    &.{.{ .scheme = "key" }},
                    &.{.{ .scheme = "mtls" }},
                } },
            },
        }},
    };
    const line: Refusal = .{ .service = "s", .operation = null, .pointer = "/services/0/security_schemes/1/kind/other", .reason = .unsupported_scheme_kind, .name = "mutualTLS" };

    var per_op: Loaded = .init(&m, .{ .on_unsupported = .refuse_operation });
    defer per_op.deinit();
    try per_op.expectRefusals(&.{line});
    try per_op.expectRefused(&.{&.{ true, false, true }});

    // Declared and named by no requirement: still reported, and it fails a `.refuse_model` load,
    // but under `.refuse_operation` it refuses nothing.
    const unused: model.Model = .{ .services = &.{.{
        .name = "s",
        .security_schemes = m.services[0].security_schemes,
        .operations = &.{op("o", ok(&plain))},
    }} };
    var whole: Loaded = .init(&unused, .{});
    defer whole.deinit();
    try whole.expectModelRefused();
    try whole.expectRefusals(&.{line});
    var spared: Loaded = .init(&unused, .{ .on_unsupported = .refuse_operation });
    defer spared.deinit();
    try spared.expectRefused(&.{&.{false}});
}

test "compile: a name used twice" {
    // Operation ids: both operations sharing the id are refused, the third is served.
    const ids: model.Model = .{ .services = &.{.{ .name = "s", .operations = &.{
        op("get", ok(&plain)), op("list", ok(&plain)), op("get", ok(&plain)),
    } }} };
    var by_id: Loaded = .init(&ids, .{ .on_unsupported = .refuse_operation });
    defer by_id.deinit();
    try by_id.expectRefusals(&.{.{ .service = "s", .operation = "get", .pointer = "/services/0/operations/2/id", .reason = .duplicate_operation_id, .name = "get" }});
    try by_id.expectRefused(&.{&.{ true, false, true }});

    // Scheme names: a requirement naming the repeated name is ambiguous.
    const schemes: model.Model = .{ .services = &.{.{
        .name = "s",
        .security_schemes = &.{
            .{ .name = "auth", .kind = .http_basic },
            .{ .name = "auth", .kind = .{ .http_bearer = .{} } },
            .{ .name = "key", .kind = .{ .api_key = .{ .in = .cookie, .name = "k" } } },
        },
        .security = &.{&.{.{ .scheme = "auth" }}},
        .operations = &.{
            op("inherits", ok(&plain)),
            .{ .id = "key", .method = .GET, .path = "/k", .responses = ok(&plain), .security = &.{&.{.{ .scheme = "key" }}} },
        },
    }} };
    var by_scheme: Loaded = .init(&schemes, .{ .on_unsupported = .refuse_operation });
    defer by_scheme.deinit();
    try by_scheme.expectRefusals(&.{.{ .service = "s", .operation = null, .pointer = "/services/0/security_schemes/1/name", .reason = .duplicate_scheme_name, .name = "auth" }});
    try by_scheme.expectRefused(&.{&.{ true, false }});

    // Service names: no setting lets the model load.
    const services: model.Model = .{ .services = &.{
        .{ .name = "pets", .operations = &.{op("a", ok(&plain))} },
        .{ .name = "pets", .operations = &.{op("b", ok(&plain))} },
    } };
    for ([_]Options{ .{ .on_unsupported = .refuse_model }, .{ .on_unsupported = .refuse_operation } }) |options| {
        var by_service: Loaded = .init(&services, options);
        defer by_service.deinit();
        try by_service.expectModelRefused();
        try by_service.expectRefusals(&.{.{ .service = "pets", .operation = null, .pointer = "/services/1/name", .reason = .duplicate_service_name, .name = "pets" }});
    }
}

test "compile: the report outlives the model, and the next load replaces it" {
    const gpa = testing.allocator;
    const service_name = try gpa.dupe(u8, "pets");
    defer gpa.free(service_name);
    const op_id = try gpa.dupe(u8, "getPet");
    defer gpa.free(op_id);
    const keyword = try gpa.dupe(u8, "not");
    defer gpa.free(keyword);

    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    {
        const keywords = [_][]const u8{keyword};
        const schema: model.Schema = .{ .other_keywords = &keywords };
        const content = [_]model.MediaContent{.{ .media_type = "application/json", .schema = &schema }};
        const responses = [_]model.Response{.{ .status = .{ .code = 200 }, .content = &content }};
        const operations = [_]model.Operation{op(op_id, &responses)};
        const services = [_]model.Service{.{ .name = service_name, .operations = &operations }};
        const m: model.Model = .{ .services = &services };
        try testing.expectError(error.ModelRefused, compile(gpa, &m, .{}, &diag));
    }
    // A report that borrowed the model's strings would now read differently.
    @memset(service_name, 'x');
    @memset(op_id, 'x');
    @memset(keyword, 'x');
    try testing.expectEqual(1, diag.report.len);
    try testing.expectEqualStrings("pets", diag.report[0].service);
    try testing.expectEqualStrings("getPet", diag.report[0].operation.?);
    try testing.expectEqualStrings("not", diag.report[0].name);

    const clean: model.Model = .{ .services = &.{.{ .name = "s", .operations = &.{op("o", ok(&plain))} }} };
    var compiled = try compile(gpa, &clean, .{}, &diag);
    compiled.deinit(gpa);
    try testing.expectEqual(0, diag.report.len);
}

test "Refusal.format: one line, with names written as JSON strings" {
    try testing.expectFmt(
        \\service "pets", operation "getPet", /services/0/operations/0/parameters/0/schema: unsupported keyword "not"
    , "{f}", .{Refusal{
        .service = "pets",
        .operation = "getPet",
        .pointer = "/services/0/operations/0/parameters/0/schema",
        .reason = .unsupported_keyword,
        .name = "not",
    }});
    try testing.expectFmt(
        \\service "a\"b", /services/0/security_schemes/1/kind/other: unsupported security scheme kind "mutual\nTLS"
    , "{f}", .{Refusal{
        .service = "a\"b",
        .operation = null,
        .pointer = "/services/0/security_schemes/1/kind/other",
        .reason = .unsupported_scheme_kind,
        .name = "mutual\nTLS",
    }});
}

fn compileWithReport(gpa: Allocator, m: *const model.Model, options: Options) !void {
    var diag: Diagnostics = .{};
    defer diag.deinit(gpa);
    var compiled = compile(gpa, m, options, &diag) catch |err| switch (err) {
        error.ModelRefused => return,
        error.OutOfMemory => |e| return e,
    };
    compiled.deinit(gpa);
}

test "compile: no leak or double free when any allocation fails" {
    const m: model.Model = .{ .services = &.{
        .{
            .name = "s",
            .security_schemes = &.{.{ .name = "mtls", .kind = .{ .other = "mutualTLS" } }},
            .security = &.{&.{.{ .scheme = "nope" }}},
            .operations = &.{ op("a", ok(&tree)), op("b", ok(&plain)), op("a", ok(&self_items)) },
        },
        .{ .name = "t", .operations = &.{op("c", ok(&refused_not))} },
    } };
    try testing.checkAllAllocationFailures(testing.allocator, compileWithReport, .{ &m, Options{ .on_unsupported = .refuse_operation } });
    try testing.checkAllAllocationFailures(testing.allocator, compileWithReport, .{ &m, Options{ .on_unsupported = .refuse_model } });
}
