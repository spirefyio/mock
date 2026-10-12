//! Loading a model: the checks that decide which of its operations can be served, and the load
//! report that names every refusal.
//!
//! The checks here are the ones the model types state: a service name, an operation id within
//! its service and a security scheme name within its service are each used once; every scheme a
//! requirement names is declared; no scheme an operation's requirements name is of a kind mock
//! does not implement; and no schema sets `pattern` or carries a keyword other than the
//! annotations `Schema.other_keywords` lists.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");

/// The most text the load report lists: the bytes of the service names, operation ids, pointers
/// and names its lines hold (design section 3, Bounds). Past it, lines are counted in
/// `Diagnostics.unlisted` instead. A default that `Options.limits` is to take over when it exists.
const default_report_text_max: usize = 1 << 20;

pub const Options = struct {
    /// What a refusal does to the load.
    ///
    /// - `.refuse_model`: any refusal fails the load with `error.ModelRefused`.
    /// - `.refuse_operation`: the load succeeds, and each operation that needs something refused
    ///   is marked refused in `Compiled.refused`; the rest are served. A refusal that no
    ///   operation needs, such as a scheme name used twice that no requirement names, refuses
    ///   nothing. A service name used twice still fails the load, because the name is how the
    ///   service is addressed and no operation of either service could be told apart from the
    ///   other's.
    ///
    /// Under either setting, a line of reason `.unsupported_scheme_kind_unused` refuses nothing
    /// and fails no load.
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
        /// A declared scheme of kind `other` that some operation's requirements name.
        unsupported_scheme_kind,
        /// A declared scheme of kind `other` that no operation's requirements name. The one
        /// reason that refuses nothing: no request is checked against the scheme, so the line
        /// fails no load under either `Options.on_unsupported` and marks no operation.
        unsupported_scheme_kind_unused,
        unsupported_keyword,
    };

    /// Writes the refusal as one line with no line break, such as
    /// `service "pets", operation "getPet", /services/0/operations/0/parameters/0/schema:
    /// unsupported keyword "not"`. Names are written as JSON strings, so a name holding a quote
    /// or a line break still gives one line. A line that refuses nothing ends
    /// `named by no requirement, refuses nothing`.
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
            .unsupported_scheme_kind, .unsupported_scheme_kind_unused => "unsupported security scheme kind",
            .unsupported_keyword => "unsupported keyword",
        };
        try w.print(", {s}: {s} {f}", .{ r.pointer, what, std.json.fmt(r.name, .{}) });
        if (r.reason == .unsupported_scheme_kind_unused) try w.writeAll(", named by no requirement, refuses nothing");
    }
};

/// Carries the load report out of `compile`, which a Zig error cannot.
pub const Diagnostics = struct {
    /// The lines of the last load given this `Diagnostics`, in the order the checks met them:
    /// each service in turn, and in a service its name, its schemes, its requirements, then each
    /// operation. Listed until the next line's text (its service name, operation id, pointer and
    /// name) would take the report past 1 MiB; that line and every one after it are counted in
    /// `unlisted` instead. Empty after a load with nothing to report, and after
    /// `error.OutOfMemory`.
    report: []const Refusal = &.{},
    /// The lines past the bound: counted, not listed. The load's outcome is the same as if they
    /// had been listed.
    unlisted: usize = 0,
    arena: std.heap.ArenaAllocator.State = .init,

    /// Frees the report and leaves `d` empty and reusable. `gpa` is the allocator given to the
    /// load that filled it.
    pub fn deinit(d: *Diagnostics, gpa: Allocator) void {
        d.arena.promote(gpa).deinit();
        d.* = .{};
    }

    /// Writes each line of the report, each ending in a line break, then, when lines are past
    /// the bound, a last line with their count, such as
    /// `2 more not listed: the report keeps at most 1048576 bytes of text`.
    ///
    /// Errors: `error.WriteFailed` when `w` fails.
    pub fn format(d: Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (d.report) |line| try w.print("{f}\n", .{line});
        if (d.unlisted != 0) {
            try w.print("{d} more not listed: the report keeps at most {d} bytes of text\n", .{ d.unlisted, default_report_text_max });
        }
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
///   twice under either setting. A line of reason `.unsupported_scheme_kind_unused` is not a
///   refusal here. Lines past the report's bound count exactly as listed ones do;
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
        d.* = .{ .report = checked.report, .unlisted = checked.unlisted, .arena = arena.state };
    } else arena.deinit();

    if (checked.model_wide or (checked.refusals != 0 and options.on_unsupported == .refuse_model)) {
        checked.compiled.deinit(gpa);
        return error.ModelRefused;
    }
    return checked.compiled;
}

const Checked = struct {
    compiled: Compiled,
    report: []const Refusal,
    unlisted: usize,
    /// The lines, listed or not, that refuse something: all but those of reason
    /// `.unsupported_scheme_kind_unused`. The decision counts these, never `report.len`, so that
    /// the bound on the report cannot change it.
    refusals: usize,
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
        .unlisted = checker.unlisted,
        .refusals = checker.refusals,
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
    /// Holds the report: every listed `Refusal` and every string in one.
    arena: Allocator,
    report: std.ArrayList(Refusal) = .empty,
    /// The text of the listed lines, never more than `text_max`.
    text: usize = 0,
    text_max: usize = default_report_text_max,
    /// Lines left out of `report` for the bound. Once one is, every later one is too, so the
    /// listed lines are always the first ones.
    unlisted: usize = 0,
    /// Lines, listed or not, that refuse something.
    refusals: usize = 0,
    model_wide: bool = false,

    // Scratch for the schema walk, reused for each operation.
    visited: std.AutoHashMapUnmanaged(*const model.Schema, void) = .empty,
    stack: std.ArrayList(Pending) = .empty,
    trail: std.ArrayList(Step) = .empty,
    chain: std.ArrayList(usize) = .empty,
    /// A line's pointer while it is built, copied into the arena only if the line is listed.
    pointer: std.ArrayList(u8) = .empty,

    fn deinit(c: *Checker) void {
        c.visited.deinit(c.gpa);
        c.stack.deinit(c.gpa);
        c.trail.deinit(c.gpa);
        c.chain.deinit(c.gpa);
        c.pointer.deinit(c.gpa);
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

        // Every scheme name some operation's requirements use: its own, or the service's when
        // its own `security` is null. A scheme of a kind mock does not implement is refused only
        // where one of these names it.
        var used: std.StringHashMapUnmanaged(void) = .empty;
        defer used.deinit(c.gpa);
        var inherits = false;
        for (service.operations) |operation| {
            if (operation.security) |own| try c.collectSchemes(&used, own) else inherits = true;
        }
        if (inherits) try c.collectSchemes(&used, service.security);

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
                    const reason: Refusal.Reason = if (used.contains(scheme.name))
                        .unsupported_scheme_kind
                    else
                        .unsupported_scheme_kind_unused;
                    try c.refuse(at, "/security_schemes/{d}/kind/other", .{i}, reason, kind);
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

    fn collectSchemes(
        c: *Checker,
        used: *std.StringHashMapUnmanaged(void),
        requirements: []const model.Requirement,
    ) Allocator.Error!void {
        for (requirements) |requirement| {
            for (requirement) |use| try used.put(c.gpa, use.scheme, {});
        }
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

    /// Returns whether the schema itself, not counting its children, was refused, whether or not
    /// its lines were listed.
    fn checkSchema(c: *Checker, at: Site, pending: Pending) Allocator.Error!bool {
        // Whether `c.pointer` holds this schema's pointer: built for its first listed line, then
        // shared by the others.
        var built = false;
        var refused = false;
        if (pending.schema.pattern != null) {
            refused = true;
            try c.refuseKeyword(at, pending.step, &built, "pattern");
        }
        for (pending.schema.other_keywords) |keyword| {
            if (isAnnotation(keyword)) continue;
            refused = true;
            try c.refuseKeyword(at, pending.step, &built, keyword);
        }
        return refused;
    }

    fn refuseKeyword(c: *Checker, at: Site, step: usize, built: *bool, keyword: []const u8) Allocator.Error!void {
        // Past the bound the pointer is not built at all, so a long chain of refused schemas
        // costs no more than counting.
        if (!c.count(.unsupported_keyword)) return;
        if (!built.*) {
            try c.schemaPointer(at, step);
            built.* = true;
        }
        try c.list(at, .unsupported_keyword, keyword);
    }

    /// Writes the pointer of the schema at `step` of the trail into `c.pointer`.
    fn schemaPointer(c: *Checker, at: Site, step: usize) Allocator.Error!void {
        c.chain.clearRetainingCapacity();
        var next: ?usize = step;
        while (next) |index| {
            try c.chain.append(c.gpa, index);
            next = c.trail.items[index].parent;
        }
        const out = &c.pointer;
        out.clearRetainingCapacity();
        try out.print(c.gpa, "/services/{d}/operations/{d}", .{ at.s, at.o });
        var k = c.chain.items.len;
        while (k > 0) {
            k -= 1;
            switch (c.trail.items[c.chain.items[k]].edge) {
                .root => |root| switch (root) {
                    .parameter => |i| try out.print(c.gpa, "/parameters/{d}/schema", .{i}),
                    .request_content => |i| try out.print(c.gpa, "/request_body/content/{d}/schema", .{i}),
                    .response_header => |rh| try out.print(c.gpa, "/responses/{d}/headers/{d}/schema", rh),
                    .response_content => |rc| try out.print(c.gpa, "/responses/{d}/content/{d}/schema", rc),
                },
                .items => try out.appendSlice(c.gpa, "/items"),
                .property => |i| try out.print(c.gpa, "/properties/{d}/schema", .{i}),
                .additional => try out.appendSlice(c.gpa, "/additional_properties/schema"),
                .all_of => |i| try out.print(c.gpa, "/all_of/{d}", .{i}),
                .any_of => |i| try out.print(c.gpa, "/any_of/{d}", .{i}),
                .one_of => |i| try out.print(c.gpa, "/one_of/{d}", .{i}),
            }
        }
    }

    /// Adds a line at `at` plus `suffix`.
    fn refuse(
        c: *Checker,
        at: Site,
        comptime suffix: []const u8,
        args: anytype,
        reason: Refusal.Reason,
        name: []const u8,
    ) Allocator.Error!void {
        if (!c.count(reason)) return;
        c.pointer.clearRetainingCapacity();
        if (at.operation == null)
            try c.pointer.print(c.gpa, "/services/{d}" ++ suffix, .{at.s} ++ args)
        else
            try c.pointer.print(c.gpa, "/services/{d}/operations/{d}" ++ suffix, .{ at.s, at.o } ++ args);
        try c.list(at, reason, name);
    }

    /// Counts a line, and returns whether it may still be listed: false once a line has been
    /// left out for the bound.
    fn count(c: *Checker, reason: Refusal.Reason) bool {
        if (reason != .unsupported_scheme_kind_unused) c.refusals += 1;
        if (c.unlisted == 0) return true;
        c.unlisted += 1;
        return false;
    }

    /// Lists a line that `count` let through, with its pointer in `c.pointer`, or leaves it out
    /// when its text would take the report past `text_max`. Every string is copied into the
    /// arena, because the caller may free the model once the load returns.
    fn list(c: *Checker, at: Site, reason: Refusal.Reason, name: []const u8) Allocator.Error!void {
        const operation: ?[]const u8 = if (at.operation) |o| o.id else null;
        // Saturating, so that strings that alias one another cannot wrap the sum.
        const text = at.service.name.len +| (if (operation) |id| id.len else 0) +| c.pointer.items.len +| name.len;
        if (text > c.text_max - c.text) {
            c.unlisted += 1;
            return;
        }
        try c.report.append(c.arena, .{
            .service = try c.arena.dupe(u8, at.service.name),
            .operation = if (operation) |id| try c.arena.dupe(u8, id) else null,
            .pointer = try c.arena.dupe(u8, c.pointer.items),
            .reason = reason,
            .name = try c.arena.dupe(u8, name),
        });
        c.text += text;
    }
};

/// The keywords `Schema.other_keywords` may carry: pure annotations, which change nothing mock
/// does (design section 2). An extension is any name starting `x-`, compared with case, as
/// OpenAPI's field names are.
///
/// Not here, so refused: the references `$ref`, `$dynamicRef` and `$recursiveRef`, because an
/// adapter resolves a reference into a pointer and one left in `other_keywords` was not
/// resolved, so ignoring it would validate against nothing; and `nullable`, because an adapter
/// maps it into `types`, and one left unmapped, if ignored, would refuse a valid null.
fn isAnnotation(keyword: []const u8) bool {
    return std.mem.startsWith(u8, keyword, "x-") or annotations.has(keyword);
}

const annotations: std.StaticStringMap(void) = .initComptime(.{
    .{"title"},            .{"description"},     .{"$comment"},      .{"deprecated"},
    .{"externalDocs"},     .{"discriminator"},   .{"example"},       .{"xml"},
    // Identifiers and containers: a reference reaches its target as a pointer, so these matter
    // only to the adapter that resolved it.
    .{"$schema"},          .{"$id"},             .{"$anchor"},       .{"$dynamicAnchor"},
    .{"$recursiveAnchor"}, .{"$vocabulary"},     .{"$defs"},         .{"definitions"},
    // Annotations in JSON Schema 2020-12.
    .{"contentMediaType"}, .{"contentEncoding"}, .{"contentSchema"},
});

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
        // Checked first, so that a load that failed says so instead of returning its error.
        try testing.expectEqual(@as(?Error, null), l.err);
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
    // Each accepted name would show up as an extra line if it were refused; each refused name
    // would be missing from the lines if it were accepted. The references stay refused because
    // one left here was never resolved into a pointer, and `nullable` because one left unmapped
    // would refuse a valid null.
    const schema: model.Schema = .{
        .pattern = "^a",
        .other_keywords = &.{
            "title",            "description",     "$comment",      "deprecated",
            "externalDocs",     "discriminator",   "example",       "xml",
            "$schema",          "$id",             "$anchor",       "$dynamicAnchor",
            "$recursiveAnchor", "$vocabulary",     "$defs",         "definitions",
            "contentMediaType", "contentEncoding", "contentSchema", "x-internal",
            "x-",               "X-Internal",      "if",            "$ref",
            "$dynamicRef",      "$recursiveRef",   "nullable",      "patternProperties",
            "Example",          "$Defs",
        },
    };
    const m: model.Model = .{ .services = &.{.{ .name = "s", .operations = &.{op("o", ok(&schema))} }} };
    var loaded: Loaded = .init(&m, .{});
    defer loaded.deinit();
    const expected = [_][]const u8{ "pattern", "X-Internal", "if", "$ref", "$dynamicRef", "$recursiveRef", "nullable", "patternProperties", "Example", "$Defs" };
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

    var whole: Loaded = .init(&m, .{});
    defer whole.deinit();
    try whole.expectModelRefused();
    try whole.expectRefusals(&.{line});

    // Named only through the service's requirements, which an operation with a null `security`
    // takes: still refused where it is used.
    const inherited: model.Model = .{ .services = &.{.{
        .name = "s",
        .security_schemes = m.services[0].security_schemes,
        .security = &.{&.{.{ .scheme = "mtls" }}},
        .operations = &.{op("o", ok(&plain))},
    }} };
    var by_default: Loaded = .init(&inherited, .{});
    defer by_default.deinit();
    try by_default.expectModelRefused();
    try by_default.expectRefusals(&.{line});
}

test "compile: a scheme of a kind mock does not implement that no operation requires refuses nothing" {
    const schemes: []const model.SecurityScheme = &.{
        .{ .name = "key", .kind = .{ .api_key = .{ .in = .query, .name = "k" } } },
        .{ .name = "mtls", .kind = .{ .other = "mutualTLS" } },
    };
    const line: Refusal = .{ .service = "s", .operation = null, .pointer = "/services/0/security_schemes/1/kind/other", .reason = .unsupported_scheme_kind_unused, .name = "mutualTLS" };

    // Named by no requirement at all; and named only by the service's requirements, which no
    // operation takes because each has its own. Either way it is reported, and it neither fails
    // the load nor marks an operation, under either setting.
    const unnamed: model.Model = .{ .services = &.{.{
        .name = "s",
        .security_schemes = schemes,
        .operations = &.{op("o", ok(&plain))},
    }} };
    const overridden: model.Model = .{ .services = &.{.{
        .name = "s",
        .security_schemes = schemes,
        .security = &.{&.{.{ .scheme = "mtls" }}},
        .operations = &.{
            .{ .id = "o", .method = .GET, .path = "/o", .responses = ok(&plain), .security = &.{&.{.{ .scheme = "key" }}} },
            .{ .id = "open", .method = .GET, .path = "/p", .responses = ok(&plain), .security = &.{} },
        },
    }} };
    for ([_]Options{ .{ .on_unsupported = .refuse_model }, .{ .on_unsupported = .refuse_operation } }) |options| {
        var a: Loaded = .init(&unnamed, options);
        defer a.deinit();
        try a.expectRefusals(&.{line});
        try a.expectRefused(&.{&.{false}});

        var b: Loaded = .init(&overridden, options);
        defer b.deinit();
        try b.expectRefusals(&.{line});
        try b.expectRefused(&.{&.{ false, false }});
    }
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

    // Named by no requirement, a scheme name used twice is still a fault in the model: unlike an
    // unsupported kind no one requires, it fails a `.refuse_model` load.
    const unnamed: model.Model = .{ .services = &.{.{
        .name = "s",
        .security_schemes = schemes.services[0].security_schemes,
        .operations = &.{op("o", ok(&plain))},
    }} };
    var unnamed_whole: Loaded = .init(&unnamed, .{});
    defer unnamed_whole.deinit();
    try unnamed_whole.expectModelRefused();
    var unnamed_per_op: Loaded = .init(&unnamed, .{ .on_unsupported = .refuse_operation });
    defer unnamed_per_op.deinit();
    try unnamed_per_op.expectRefused(&.{&.{false}});

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
    // A line that refuses nothing says so; without the tail it would read as a refusal.
    try testing.expectFmt(
        \\service "s", /services/0/security_schemes/0/kind/other: unsupported security scheme kind "mutualTLS", named by no requirement, refuses nothing
    , "{f}", .{Refusal{
        .service = "s",
        .operation = null,
        .pointer = "/services/0/security_schemes/0/kind/other",
        .reason = .unsupported_scheme_kind_unused,
        .name = "mutualTLS",
    }});
}

test "Diagnostics.format: one line each, then the count of lines past the bound" {
    const line: Refusal = .{ .service = "s", .operation = "o", .pointer = "/services/0/operations/0/id", .reason = .duplicate_operation_id, .name = "o" };
    // Without the last line a reader would take the listed lines for the whole report.
    try testing.expectFmt(
        \\service "s", operation "o", /services/0/operations/0/id: operation id used twice "o"
        \\service "s", operation "o", /services/0/operations/0/id: operation id used twice "o"
        \\3 more not listed: the report keeps at most 1048576 bytes of text
        \\
    , "{f}", .{Diagnostics{ .report = &.{ line, line }, .unlisted = 3 }});
    // And with nothing past the bound, no count line.
    try testing.expectFmt(
        \\service "s", operation "o", /services/0/operations/0/id: operation id used twice "o"
        \\
    , "{f}", .{Diagnostics{ .report = &.{line} }});
    try testing.expectFmt("", "{f}", .{Diagnostics{}});
}

test "compile: the report lists lines until the next would pass its bound, and counts the rest" {
    const gpa = testing.allocator;
    // A line's text here is "s", the operation id, the pointer and the keyword.
    const line_text = 1 + 1 + "/services/0/operations/0/responses/0/content/0/schema".len;
    // One byte longer than the keyword that, with a second line refusing "not", fills the
    // report exactly.
    const big = try gpa.alloc(u8, default_report_text_max - 2 * line_text - "not".len + 1);
    defer gpa.free(big);
    @memset(big, 'k');

    var keywords = [_][]const u8{ big[0 .. big.len - 1], "not" };
    const first: model.Schema = .{ .other_keywords = &keywords };
    const second: model.Schema = .{ .other_keywords = &.{"if"} };
    const content = [_]model.MediaContent{
        .{ .media_type = "application/json", .schema = &first },
        .{ .media_type = "application/json", .schema = &second },
    };
    const responses_a = [_]model.Response{.{ .status = .{ .code = 200 }, .content = content[0..1] }};
    const responses_b = [_]model.Response{.{ .status = .{ .code = 200 }, .content = content[1..2] }};
    const operations = [_]model.Operation{ op("a", &responses_a), op("b", &responses_b) };
    const services = [_]model.Service{.{ .name = "s", .operations = &operations }};
    const m: model.Model = .{ .services = &services };

    // Exactly full: both of a's lines are listed, and b's is counted. Listing only lines that
    // leave room to spare would count "not" as well.
    {
        var loaded: Loaded = .init(&m, .{ .on_unsupported = .refuse_operation });
        defer loaded.deinit();
        try testing.expectEqual(2, loaded.diag.report.len);
        try testing.expectEqual(big.len - 1, loaded.diag.report[0].name.len);
        try testing.expectEqualStrings("not", loaded.diag.report[1].name);
        try testing.expectEqual(1, loaded.diag.unlisted);
        // b's line is not listed, and b is refused all the same.
        try loaded.expectRefused(&.{&.{ true, true }});
    }

    // One byte over: "not" no longer fits, and neither is b's line listed, though "if" is one
    // byte shorter than "not" and would fit; the listed lines are always the first ones.
    keywords[0] = big;
    {
        var loaded: Loaded = .init(&m, .{ .on_unsupported = .refuse_operation });
        defer loaded.deinit();
        try testing.expectEqual(1, loaded.diag.report.len);
        try testing.expectEqual(big.len, loaded.diag.report[0].name.len);
        try testing.expectEqual(2, loaded.diag.unlisted);
        try loaded.expectRefused(&.{&.{ true, true }});

        var whole: Loaded = .init(&m, .{});
        defer whole.deinit();
        try whole.expectModelRefused();
        try testing.expectEqual(2, whole.diag.unlisted);
    }

    // The lines past the bound, under allocation failure too.
    try testing.checkAllAllocationFailures(gpa, compileWithReport, .{ &m, Options{ .on_unsupported = .refuse_operation } });
}

test "compile: the bound on the report never changes the load's outcome" {
    const gpa = testing.allocator;
    // A line that refuses nothing and fills the report exactly: "s", no operation, the pointer
    // and the kind.
    const kind = try gpa.alloc(u8, default_report_text_max - 1 - "/services/0/security_schemes/0/kind/other".len);
    defer gpa.free(kind);
    @memset(kind, 'k');
    const schemes = [_]model.SecurityScheme{
        .{ .name = "huge", .kind = .{ .other = kind } },
        .{ .name = "small", .kind = .{ .other = "x" } },
    };

    // Past the bound, a refusal: it still fails a `.refuse_model` load, which a decision made
    // from the listed lines alone would let through, and still refuses its operation.
    const refusing = [_]model.Service{.{ .name = "s", .security_schemes = schemes[0..1], .operations = &.{op("o", ok(&refused_not))} }};
    const m: model.Model = .{ .services = &refusing };
    var whole: Loaded = .init(&m, .{});
    defer whole.deinit();
    try whole.expectModelRefused();
    try testing.expectEqual(1, whole.diag.report.len);
    try testing.expectEqual(.unsupported_scheme_kind_unused, whole.diag.report[0].reason);
    try testing.expectEqual(1, whole.diag.unlisted);
    var per_op: Loaded = .init(&m, .{ .on_unsupported = .refuse_operation });
    defer per_op.deinit();
    try per_op.expectRefused(&.{&.{true}});

    // Past the bound, only a line that refuses nothing: the load still succeeds, which a
    // decision that took every unlisted line for a refusal would fail.
    const quiet = [_]model.Service{.{ .name = "s", .security_schemes = &schemes, .operations = &.{op("o", ok(&plain))} }};
    const q: model.Model = .{ .services = &quiet };
    var spared: Loaded = .init(&q, .{});
    defer spared.deinit();
    try spared.expectRefused(&.{&.{false}});
    try testing.expectEqual(1, spared.diag.report.len);
    try testing.expectEqual(1, spared.diag.unlisted);
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
            .security_schemes = &.{
                .{ .name = "mtls", .kind = .{ .other = "mutualTLS" } },
                .{ .name = "digest", .kind = .{ .other = "http digest" } },
            },
            .security = &.{&.{.{ .scheme = "nope" }}},
            .operations = &.{
                op("a", ok(&tree)),
                op("b", ok(&plain)),
                op("a", ok(&self_items)),
                .{ .id = "m", .method = .GET, .path = "/m", .responses = ok(&plain), .security = &.{&.{.{ .scheme = "mtls" }}} },
            },
        },
        .{ .name = "t", .operations = &.{op("c", ok(&refused_not))} },
    } };
    try testing.checkAllAllocationFailures(testing.allocator, compileWithReport, .{ &m, Options{ .on_unsupported = .refuse_operation } });
    try testing.checkAllAllocationFailures(testing.allocator, compileWithReport, .{ &m, Options{ .on_unsupported = .refuse_model } });
}
