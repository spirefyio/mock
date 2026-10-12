//! Loading a model: the checks that decide which of its operations can be served, and the load
//! report that names every refusal.
//!
//! The checks here are the ones the model types state: a service name, an operation id within
//! its service and a security scheme name within its service are each used once; every scheme a
//! requirement names is declared; no scheme an operation's requirements name is of a kind mock
//! does not implement; no schema sets `pattern` or carries a keyword other than the annotations
//! `Schema.other_keywords` lists; and every identity client's `alg` names a key the provider holds.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const Refusal = @import("report.zig").Refusal;
const Diagnostics = @import("report.zig").Diagnostics;
const default_report_max = @import("report.zig").default_report_max;

pub const Options = struct {
    /// What a refusal does to the load.
    ///
    /// - `.refuse_model`: any refusal fails the load with `error.ModelRefused`.
    /// - `.refuse_operation`: the load succeeds, and each operation that needs something refused
    ///   is marked refused in `Compiled.refused`; the rest are served. A refusal that no
    ///   operation needs, such as a scheme name used twice that no requirement names, refuses
    ///   nothing. Two refusals still fail the load. A service name used twice, because the name
    ///   is how the service is addressed and no operation of either service could be told apart
    ///   from the other's. And an identity client with no key to sign with: one whose `alg` names
    ///   no key the provider holds, or a JWT client with a null `alg` on a provider with no keys,
    ///   because clients are the test's own configuration, not part of an API it imports.
    ///
    /// Under either setting, a line of reason `.unsupported_scheme_kind_unused` refuses nothing
    /// and fails no load.
    on_unsupported: enum { refuse_model, refuse_operation } = .refuse_model,
    /// The bounds the load holds to.
    limits: Limits = .{},
};

/// The bounds of design section 3, Bounds, that a load holds to, each with the default the design
/// gives it.
pub const Limits = struct {
    /// Load report memory, in bytes: each listed line's record and the bytes of its service name,
    /// operation id, pointer and name (the Bounds row "Load report memory"). Past it, lines are
    /// counted in `Diagnostics.unlisted` instead of listed, and the load's outcome is the same.
    load_report: usize = default_report_max,
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
/// - `error.ModelRefused` when there is any refusal under `.refuse_model`, or, under either
///   setting, a service name used twice or a client with no key to sign with. A line of reason
///   `.unsupported_scheme_kind_unused` is not a refusal here. Lines past the report's bound count
///   exactly as listed ones do;
/// - `error.OutOfMemory`, after which `diag` holds an empty report.
pub fn compile(gpa: Allocator, m: *const model.Model, options: Options, diag: ?*Diagnostics) Error!Compiled {
    // Freed first, so that whatever this load returns, no earlier report is left in `diag`.
    if (diag) |d| d.deinit(gpa);
    var checked = try check(gpa, m, options.limits.load_report);
    if (diag) |d| {
        d.* = .{ .report = checked.report, .unlisted = checked.unlisted, .report_max = options.limits.load_report, .text = checked.text };
    } else {
        gpa.free(checked.report);
        gpa.free(checked.text);
    }

    if (checked.model_wide or (checked.refused_any and options.on_unsupported == .refuse_model)) {
        checked.compiled.deinit(gpa);
        return error.ModelRefused;
    }
    return checked.compiled;
}

const Checked = struct {
    compiled: Compiled,
    report: []const Refusal,
    text: []const u8,
    unlisted: u64,
    /// Some line, listed or not, refuses something: one of any reason but
    /// `.unsupported_scheme_kind_unused`. The decision reads this flag, never `report.len` and
    /// never a count, so that neither the bound on the report nor a count that wraps can change
    /// it.
    refused_any: bool,
    /// Some refusal concerns the whole model, so no setting lets it load.
    model_wide: bool,
};

fn check(gpa: Allocator, m: *const model.Model, report_max: usize) Allocator.Error!Checked {
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

    var checker: Checker = .{ .gpa = gpa, .report_max = report_max };
    defer checker.deinit();
    try checker.checkModel(m, refused);
    const text = try gpa.dupe(u8, checker.text.items);
    errdefer gpa.free(text);
    return .{
        .compiled = .{ .refused = refused },
        .report = try checker.takeReport(text),
        .text = text,
        .unlisted = checker.unlisted,
        .refused_any = checker.refused_any,
        .model_wide = checker.model_wide,
    };
}

/// Where in the model a check is: the model itself, a service, or one of its operations.
const Site = struct {
    service: ?*const model.Service = null,
    s: usize = 0,
    operation: ?*const model.Operation = null,
    o: usize = 0,
};

/// Where a schema graph hangs off an operation.
const Root = union(enum) {
    parameter: usize,
    request_content: usize,
    response_header: struct { response: usize, header: usize },
    response_content: struct { response: usize, content: usize },
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

/// A schema on the walk's path, from its root to the schema the walk is in.
const Frame = struct {
    schema: *const model.Schema,
    /// This schema's index in `Checker.trail`.
    step: usize,
    /// The index, in field order, of the next child to visit; see `childAt`.
    next: usize = 0,
};

const Child = struct {
    schema: *const model.Schema,
    edge: Edge,
};

/// The `n`th child of `schema` in field order, or null past the last: `items`, each of
/// `properties`, a schema in `additional_properties`, then each of `all_of`, `any_of` and
/// `one_of`.
fn childAt(schema: *const model.Schema, n: usize) ?Child {
    var k = n;
    if (schema.items) |items| {
        if (k == 0) return .{ .schema = items, .edge = .items };
        k -= 1;
    }
    if (k < schema.properties.len) return .{ .schema = schema.properties[k].schema, .edge = .{ .property = k } };
    k -= schema.properties.len;
    switch (schema.additional_properties) {
        .schema => |additional| {
            if (k == 0) return .{ .schema = additional, .edge = .additional };
            k -= 1;
        },
        .allowed, .forbidden => {},
    }
    if (k < schema.all_of.len) return .{ .schema = schema.all_of[k], .edge = .{ .all_of = k } };
    k -= schema.all_of.len;
    if (k < schema.any_of.len) return .{ .schema = schema.any_of[k], .edge = .{ .any_of = k } };
    k -= schema.any_of.len;
    if (k < schema.one_of.len) return .{ .schema = schema.one_of[k], .edge = .{ .one_of = k } };
    return null;
}

/// A listed line while the report is built. Its strings are spans of `Checker.text`, which moves
/// as it grows.
const Line = struct {
    service: ?Span,
    operation: ?Span,
    pointer: Span,
    reason: Refusal.Reason,
    name: Span,
};

const Span = struct {
    start: usize,
    len: usize,

    fn of(span: Span, text: []const u8) []const u8 {
        return text[span.start..][0..span.len];
    }
};

/// A name from the model, and the index of the service, scheme or operation that holds it.
///
/// Names are checked by sorting these, never through a hash map: std's string hash maps hash with
/// the fixed seed 0 (`std.hash_map.hashString`), so a model could hold names chosen to collide.
/// 40,000 operation ids sharing one hash took 48 s to load in a Debug build, against 23 ms for
/// ids that do not collide. Sorting costs O(n log n) comparisons whatever the names are.
const Name = struct {
    name: []const u8,
    index: usize,
    /// Set on the first entry of a declared scheme's name: whether a requirement naming it is
    /// refused.
    refused: bool = false,
    /// Set on the first entry of a declared scheme's name: whether some operation's requirements
    /// name it.
    used: bool = false,
};

/// Fills `names` with the `field` of each of `items`, sorted by name and then by index, so that
/// the first entry of each name is its first use.
fn sortNames(gpa: Allocator, names: *std.ArrayList(Name), items: anytype, comptime field: []const u8) Allocator.Error!void {
    names.clearRetainingCapacity();
    try names.ensureTotalCapacity(gpa, items.len);
    for (items, 0..) |item, i| names.appendAssumeCapacity(.{ .name = @field(item, field), .index = i });
    std.mem.sort(Name, names.items, {}, nameLessThan);
}

fn nameLessThan(_: void, a: Name, b: Name) bool {
    return switch (std.mem.order(u8, a.name, b.name)) {
        .lt => true,
        .gt => false,
        .eq => a.index < b.index,
    };
}

/// The first entry of `name` in `sorted`, which `sortNames` filled, or null.
fn findName(sorted: []Name, name: []const u8) ?*Name {
    const k = std.sort.lowerBound(Name, sorted, name, orderName);
    if (k == sorted.len or !std.mem.eql(u8, sorted[k].name, name)) return null;
    return &sorted[k];
}

fn orderName(name: []const u8, entry: Name) std.math.Order {
    return std.mem.order(u8, name, entry.name);
}

/// Sets `used` on the first entry, in `sorted`, of each declared scheme `requirements` name.
fn markUsed(sorted: []Name, requirements: []const model.Requirement) void {
    for (requirements) |requirement| {
        for (requirement) |use| {
            if (findName(sorted, use.scheme)) |entry| entry.used = true;
        }
    }
}

const Checker = struct {
    gpa: Allocator,
    /// The most memory the report may take: `Diagnostics.report_max`.
    report_max: usize,
    /// The listed lines and their text. `check` copies them out into allocations of exactly their
    /// size, so that what grew here while the report was built leaves nothing in the report.
    lines: std.ArrayList(Line) = .empty,
    text: std.ArrayList(u8) = .empty,
    /// The memory the listed lines will take in the report, never more than `report_max`.
    listed_bytes: usize = 0,
    /// Lines left out of `report` for the bound. Once one is, every later one is too, so the
    /// listed lines are always the first ones. 64 bits and saturating, because a `usize` can
    /// wrap: a shared schema is checked again for each operation that reaches it, so a 32-bit
    /// target can meet more lines than it can count.
    unlisted: u64 = 0,
    refused_any: bool = false,
    model_wide: bool = false,

    // Names sorted for lookup; see `Name`. `schemes` and `ids` are refilled for each service.
    service_names: std.ArrayList(Name) = .empty,
    schemes: std.ArrayList(Name) = .empty,
    ids: std.ArrayList(Name) = .empty,

    // Scratch for the schema walk, reused for each operation.
    visited: std.AutoHashMapUnmanaged(*const model.Schema, void) = .empty,
    /// The path from the root to the schema the walk is in.
    stack: std.ArrayList(Frame) = .empty,
    /// How the walk first reached each schema it entered, one record each.
    trail: std.ArrayList(Step) = .empty,
    chain: std.ArrayList(usize) = .empty,
    /// A line's pointer while it is built, copied into `text` only if the line is listed.
    pointer: std.ArrayList(u8) = .empty,

    fn deinit(c: *Checker) void {
        c.lines.deinit(c.gpa);
        c.text.deinit(c.gpa);
        c.service_names.deinit(c.gpa);
        c.schemes.deinit(c.gpa);
        c.ids.deinit(c.gpa);
        c.visited.deinit(c.gpa);
        c.stack.deinit(c.gpa);
        c.trail.deinit(c.gpa);
        c.chain.deinit(c.gpa);
        c.pointer.deinit(c.gpa);
    }

    /// The listed lines as refusals whose strings point into `text`, a copy of `c.text`.
    fn takeReport(c: *Checker, text: []const u8) Allocator.Error![]const Refusal {
        const report = try c.gpa.alloc(Refusal, c.lines.items.len);
        for (report, c.lines.items) |*r, line| r.* = .{
            .service = if (line.service) |span| span.of(text) else null,
            .operation = if (line.operation) |span| span.of(text) else null,
            .pointer = line.pointer.of(text),
            .reason = line.reason,
            .name = line.name.of(text),
        };
        return report;
    }

    fn checkModel(c: *Checker, m: *const model.Model, refused: []const []bool) Allocator.Error!void {
        try sortNames(c.gpa, &c.service_names, m.services, "name");
        for (m.services, refused, 0..) |*service, service_refused, s| {
            const at: Site = .{ .service = service, .s = s };
            if (findName(c.service_names.items, service.name).?.index != s) {
                c.model_wide = true;
                try c.refuse(at, "/name", .{}, .duplicate_service_name, service.name);
            }
            try c.checkService(at, service_refused);
        }
        if (m.identity) |identity| try c.checkIdentity(identity);
    }

    /// A client's `alg` must name a key the provider holds. A null `alg` names none: it takes the
    /// provider's first key (design section 2), so a JWT client with a null `alg` needs the
    /// provider to hold some key. An opaque-token client with a null `alg` signs nothing and needs
    /// none; one whose `alg` is set is held to it all the same, as the design states it.
    fn checkIdentity(c: *Checker, identity: model.Identity) Allocator.Error!void {
        var held: std.EnumSet(model.Alg) = .initEmpty();
        for (identity.keys) |key| held.insert(key.alg);
        for (identity.clients, 0..) |client, i| {
            if (client.alg) |alg| {
                if (held.contains(alg)) continue;
                c.model_wide = true;
                try c.refuse(.{}, "/identity/clients/{d}/alg", .{i}, .no_key_for_alg, @tagName(alg));
            } else if (client.token == .jwt and identity.keys.len == 0) {
                c.model_wide = true;
                try c.refuse(.{}, "/identity/clients/{d}/alg", .{i}, .no_signing_key, client.id);
            }
        }
    }

    fn checkService(c: *Checker, at: Site, refused: []bool) Allocator.Error!void {
        const service = at.service.?;

        try sortNames(c.gpa, &c.schemes, service.security_schemes, "name");
        const schemes = c.schemes.items;

        // Marks each declared name that some operation's requirements use: its own, or the
        // service's when its own `security` is null. A scheme of a kind mock does not implement is
        // refused only where one of these names it. Marked in place, so that the memory this
        // takes is the declarations', however many requirements name them: operations can share
        // one requirement slice, so a small model can hold a great many uses.
        var inherits = false;
        for (service.operations) |operation| {
            if (operation.security) |own| markUsed(schemes, own) else inherits = true;
        }
        if (inherits) markUsed(schemes, service.security);

        // On the first entry of each declared scheme name, whether an operation whose
        // requirements name it is refused: true when the name is declared twice, since a
        // requirement naming it is ambiguous, or when a scheme of that name is of a kind mock does
        // not implement.
        var first: usize = 0;
        while (first < schemes.len) {
            var end = first + 1;
            while (end < schemes.len and std.mem.eql(u8, schemes[end].name, schemes[first].name)) end += 1;
            schemes[first].refused = end - first > 1;
            for (schemes[first..end]) |entry| {
                if (service.security_schemes[entry.index].kind == .other) schemes[first].refused = true;
            }
            first = end;
        }
        for (service.security_schemes, 0..) |scheme, i| {
            const first_entry = findName(schemes, scheme.name).?;
            if (first_entry.index != i) {
                try c.refuse(at, "/security_schemes/{d}/name", .{i}, .duplicate_scheme_name, scheme.name);
            }
            switch (scheme.kind) {
                .other => |kind| {
                    const reason: Refusal.Reason = if (first_entry.used) .unsupported_scheme_kind else .unsupported_scheme_kind_unused;
                    try c.refuse(at, "/security_schemes/{d}/kind/other", .{i}, reason, kind);
                },
                .api_key, .http_basic, .http_bearer, .oauth2, .openid_connect => {},
            }
        }

        const defaults_refused = try c.checkRequirements(at, service.security);

        try sortNames(c.gpa, &c.ids, service.operations, "id");
        for (service.operations, 0..) |*operation, o| {
            const op_at: Site = .{ .service = service, .s = at.s, .operation = operation, .o = o };
            const first_use = findName(c.ids.items, operation.id).?.index;
            if (first_use != o) {
                // The record and fault rules name an operation by its id, so neither of the two
                // could be told apart from the other.
                refused[first_use] = true;
                refused[o] = true;
                try c.refuse(op_at, "/id", .{}, .duplicate_operation_id, operation.id);
            }

            const requirements_refused = if (operation.security) |own|
                try c.checkRequirements(op_at, own)
            else
                defaults_refused;
            if (requirements_refused) refused[o] = true;
            if (try c.checkSchemas(op_at)) refused[o] = true;
        }
    }

    /// Returns whether any requirement names a scheme that is not declared or is refused.
    fn checkRequirements(c: *Checker, at: Site, requirements: []const model.Requirement) Allocator.Error!bool {
        var refused = false;
        for (requirements, 0..) |requirement, k| {
            for (requirement, 0..) |use, u| {
                if (findName(c.schemes.items, use.scheme)) |scheme| {
                    if (scheme.refused) refused = true;
                } else {
                    refused = true;
                    try c.refuse(at, "/security/{d}/{d}/scheme", .{ k, u }, .unknown_scheme, use.scheme);
                }
            }
        }
        return refused;
    }

    /// Walks every schema graph that hangs off the operation, each schema once, and returns
    /// whether any schema was refused.
    ///
    /// The walk is depth first, over a stack of its own so that a long chain of schemas cannot
    /// overflow the call stack. It enters a schema, marks it visited and checks it the first time
    /// it reaches it, then takes its children one at a time in field order. So a schema is named
    /// by the first path to it in field order, a pointer cycle ends, and the walk keeps one record
    /// for each schema it enters and one frame for each schema on its path. Neither depends on
    /// the edges, which the schemas do not bound: schemas can share one child slice.
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
                if (try c.walk(at, header.schema, .{ .response_header = .{ .response = r, .header = h } })) refused = true;
            }
            for (response.content, 0..) |content, i| {
                const schema = content.schema orelse continue;
                if (try c.walk(at, schema, .{ .response_content = .{ .response = r, .content = i } })) refused = true;
            }
        }
        return refused;
    }

    fn walk(c: *Checker, at: Site, root: *const model.Schema, from: Root) Allocator.Error!bool {
        std.debug.assert(c.stack.items.len == 0);
        var refused = try c.enter(at, root, .{ .parent = null, .edge = .{ .root = from } });
        while (c.stack.items.len > 0) {
            const top = &c.stack.items[c.stack.items.len - 1];
            const child = childAt(top.schema, top.next) orelse {
                _ = c.stack.pop();
                continue;
            };
            top.next += 1;
            // Read before entering the child, which can move the stack and `top` with it.
            const parent = top.step;
            if (try c.enter(at, child.schema, .{ .parent = parent, .edge = child.edge })) refused = true;
        }
        return refused;
    }

    /// Enters `schema` unless the walk has entered it before: records how it was reached, checks
    /// it and puts it on the path. Returns whether it was refused.
    fn enter(c: *Checker, at: Site, schema: *const model.Schema, step: Step) Allocator.Error!bool {
        if ((try c.visited.getOrPut(c.gpa, schema)).found_existing) return false;
        try c.trail.append(c.gpa, step);
        const frame: Frame = .{ .schema = schema, .step = c.trail.items.len - 1 };
        try c.stack.append(c.gpa, frame);
        return c.checkSchema(at, frame);
    }

    /// Returns whether the schema itself, not counting its children, was refused, whether or not
    /// its lines were listed.
    fn checkSchema(c: *Checker, at: Site, frame: Frame) Allocator.Error!bool {
        // Whether `c.pointer` holds this schema's pointer: built for its first listed line, then
        // shared by the others.
        var built = false;
        var refused = false;
        if (frame.schema.pattern != null) {
            refused = true;
            try c.refuseKeyword(at, frame.step, &built, "pattern");
        }
        for (frame.schema.other_keywords) |keyword| {
            if (isAnnotation(keyword)) continue;
            refused = true;
            try c.refuseKeyword(at, frame.step, &built, keyword);
        }
        return refused;
    }

    fn refuseKeyword(c: *Checker, at: Site, step: usize, built: *bool, keyword: []const u8) Allocator.Error!void {
        // Past the bound the pointer is not built at all, so a long chain of refused schemas
        // costs no more than counting.
        if (!c.admit(.unsupported_keyword)) return;
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
                    .response_header => |rh| try out.print(c.gpa, "/responses/{d}/headers/{d}/schema", .{ rh.response, rh.header }),
                    .response_content => |rc| try out.print(c.gpa, "/responses/{d}/content/{d}/schema", .{ rc.response, rc.content }),
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
        if (!c.admit(reason)) return;
        c.pointer.clearRetainingCapacity();
        if (at.service == null)
            try c.pointer.print(c.gpa, suffix, args)
        else if (at.operation == null)
            try c.pointer.print(c.gpa, "/services/{d}" ++ suffix, .{at.s} ++ args)
        else
            try c.pointer.print(c.gpa, "/services/{d}/operations/{d}" ++ suffix, .{ at.s, at.o } ++ args);
        try c.list(at, reason, name);
    }

    /// Notes a line, and returns whether it may still be listed: false once a line has been left
    /// out for the bound.
    fn admit(c: *Checker, reason: Refusal.Reason) bool {
        if (reason != .unsupported_scheme_kind_unused) c.refused_any = true;
        if (c.unlisted == 0) return true;
        c.unlisted +|= 1;
        return false;
    }

    /// Lists a line that `admit` let through, with its pointer in `c.pointer`, or leaves it out
    /// when its record and text would take the report past `report_max`. Every string is copied,
    /// because the caller may free the model once the load returns.
    fn list(c: *Checker, at: Site, reason: Refusal.Reason, name: []const u8) Allocator.Error!void {
        const service: []const u8 = if (at.service) |s| s.name else "";
        const operation: []const u8 = if (at.operation) |o| o.id else "";
        // Saturating, so that strings that alias one another cannot wrap the sum.
        const bytes = @sizeOf(Refusal) +| service.len +| operation.len +| c.pointer.items.len +| name.len;
        if (bytes > c.report_max - c.listed_bytes) {
            c.unlisted +|= 1;
            return;
        }
        try c.lines.ensureUnusedCapacity(c.gpa, 1);
        try c.text.ensureUnusedCapacity(c.gpa, bytes - @sizeOf(Refusal));
        c.lines.appendAssumeCapacity(.{
            .service = if (at.service != null) c.appendText(service) else null,
            .operation = if (at.operation != null) c.appendText(operation) else null,
            .pointer = c.appendText(c.pointer.items),
            .reason = reason,
            .name = c.appendText(name),
        });
        c.listed_bytes += bytes;
    }

    fn appendText(c: *Checker, bytes: []const u8) Span {
        const start = c.text.items.len;
        c.text.appendSliceAssumeCapacity(bytes);
        return .{ .start = start, .len = bytes.len };
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

test "compile: the walk reaches a schema through every kind of child" {
    // Each child is reached through one edge only, so a walk that skipped an edge would miss
    // its line.
    const schema: model.Schema = .{
        .items = &.{ .other_keywords = &.{"prefixItems"} },
        .properties = &.{.{ .name = "p", .schema = &.{ .other_keywords = &.{"propertyNames"} } }},
        .additional_properties = .{ .schema = &.{ .other_keywords = &.{"contains"} } },
        .all_of = &.{&.{ .other_keywords = &.{"if"} }},
        .any_of = &.{&.{ .other_keywords = &.{"then"} }},
        .one_of = &.{&.{ .other_keywords = &.{"else"} }},
    };
    const m: model.Model = .{ .services = &.{.{ .name = "s", .operations = &.{op("o", ok(&schema))} }} };
    var loaded: Loaded = .init(&m, .{ .on_unsupported = .refuse_operation });
    defer loaded.deinit();
    const root = "/services/0/operations/0/responses/0/content/0/schema";
    try loaded.expectRefusals(&.{
        .{ .service = "s", .operation = "o", .pointer = root ++ "/items", .reason = .unsupported_keyword, .name = "prefixItems" },
        .{ .service = "s", .operation = "o", .pointer = root ++ "/properties/0/schema", .reason = .unsupported_keyword, .name = "propertyNames" },
        .{ .service = "s", .operation = "o", .pointer = root ++ "/additional_properties/schema", .reason = .unsupported_keyword, .name = "contains" },
        .{ .service = "s", .operation = "o", .pointer = root ++ "/all_of/0", .reason = .unsupported_keyword, .name = "if" },
        .{ .service = "s", .operation = "o", .pointer = root ++ "/any_of/0", .reason = .unsupported_keyword, .name = "then" },
        .{ .service = "s", .operation = "o", .pointer = root ++ "/one_of/0", .reason = .unsupported_keyword, .name = "else" },
    });
    try loaded.expectRefused(&.{&.{true}});
}

test "compile: a schema reached by two paths is named by the first in field order" {
    const by_properties: model.Schema = .{ .properties = &.{
        .{ .name = "a", .schema = &refused_not },
        .{ .name = "b", .schema = &refused_not },
    } };
    // `items` comes before `one_of` among `Schema`'s fields, so the walk reaches the shared
    // schema through `items` first.
    const by_items: model.Schema = .{ .items = &refused_not, .one_of = &.{&refused_not} };
    const m: model.Model = .{ .services = &.{.{ .name = "s", .operations = &.{
        op("properties", ok(&by_properties)),
        op("items", ok(&by_items)),
    } }} };
    var loaded: Loaded = .init(&m, .{ .on_unsupported = .refuse_operation });
    defer loaded.deinit();
    try loaded.expectRefusals(&.{
        .{ .service = "s", .operation = "properties", .pointer = "/services/0/operations/0/responses/0/content/0/schema/properties/0/schema", .reason = .unsupported_keyword, .name = "not" },
        .{ .service = "s", .operation = "items", .pointer = "/services/0/operations/1/responses/0/content/0/schema/items", .reason = .unsupported_keyword, .name = "not" },
    });
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

test "compile: the load decision is made from whether anything was refused, not from a count" {
    // 256 refusals: a count of eight bits or fewer wraps to zero here and lets the load through.
    // A 32-bit count can wrap the same way, from a model that is large but not absurd, since a
    // shared schema is checked again for each operation that reaches it.
    const nots: model.Schema = .{ .other_keywords = &([_][]const u8{"not"} ** 256) };
    const m: model.Model = .{ .services = &.{.{ .name = "s", .operations = &.{op("o", ok(&nots))} }} };
    var loaded: Loaded = .init(&m, .{});
    defer loaded.deinit();
    try loaded.expectModelRefused();
    try testing.expectEqual(256, loaded.diag.report.len);
}

const self_items: model.Schema = .{ .items = &self_items, .other_keywords = &.{"not"} };
// Cycles through `properties`, `additionalProperties` and `items` only, which the design allows:
// each step consumes one level of the instance. A composition naming itself is a cycle the
// design refuses, so no fixture pins it as accepted.
const tree: model.Schema = .{
    .items = &tree,
    .properties = &.{.{ .name = "child", .schema = &tree }},
    .additional_properties = .{ .schema = &tree },
    .one_of = &.{ &plain, &refused_not },
    .other_keywords = &.{"if"},
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
        .{ .service = "s", .operation = "tree", .pointer = "/services/0/operations/1/responses/0/content/0/schema", .reason = .unsupported_keyword, .name = "if" },
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
                &.{ .{ .scheme = "key" }, .{ .scheme = "absent" } },
            } },
            .{ .id = "none", .method = .GET, .path = "/n", .responses = ok(&plain), .security = &.{} },
            .{ .id = "declared", .method = .GET, .path = "/d", .responses = ok(&plain), .security = &.{&.{.{ .scheme = "key" }}} },
        },
    }} };
    // "nope" sorts after the one declared name and "absent" before it, so a lookup that took the
    // nearest declared name for the one asked would miss either.
    var loaded: Loaded = .init(&m, .{ .on_unsupported = .refuse_operation });
    defer loaded.deinit();
    try loaded.expectRefusals(&.{
        .{ .service = "s", .operation = null, .pointer = "/services/0/security/0/0/scheme", .reason = .unknown_scheme, .name = "nope" },
        .{ .service = "s", .operation = "own", .pointer = "/services/0/operations/1/security/1/1/scheme", .reason = .unknown_scheme, .name = "absent" },
    });
    try loaded.expectRefused(&.{&.{ true, true, false, false }});
}

test "compile: an undeclared scheme in the service's requirements fails the load though no operation takes them" {
    const m: model.Model = .{ .services = &.{.{
        .name = "s",
        .security = &.{&.{.{ .scheme = "nope" }}},
        .operations = &.{
            .{ .id = "open", .method = .GET, .path = "/o", .responses = ok(&plain), .security = &.{} },
        },
    }} };
    const line: Refusal = .{ .service = "s", .operation = null, .pointer = "/services/0/security/0/0/scheme", .reason = .unknown_scheme, .name = "nope" };

    var whole: Loaded = .init(&m, .{});
    defer whole.deinit();
    try whole.expectModelRefused();
    try whole.expectRefusals(&.{line});

    var per_op: Loaded = .init(&m, .{ .on_unsupported = .refuse_operation });
    defer per_op.deinit();
    try per_op.expectRefusals(&.{line});
    try per_op.expectRefused(&.{&.{false}});
}

test "compile: operation ids and scheme names are each a service's own" {
    // The same id in two services, at different indices: all are served.
    const ids: model.Model = .{ .services = &.{
        .{ .name = "a", .operations = &.{op("get", ok(&plain))} },
        .{ .name = "b", .operations = &.{ op("list", ok(&plain)), op("get", ok(&plain)) } },
    } };
    var by_id: Loaded = .init(&ids, .{});
    defer by_id.deinit();
    try by_id.expectRefusals(&.{});
    try by_id.expectRefused(&.{ &.{false}, &.{ false, false } });

    // A scheme declared only by service a, named by service b: undeclared in b.
    const schemes: model.Model = .{ .services = &.{
        .{
            .name = "a",
            .security_schemes = &.{.{ .name = "key", .kind = .{ .api_key = .{ .in = .header, .name = "X-Key" } } }},
            .operations = &.{op("x", ok(&plain))},
        },
        .{ .name = "b", .operations = &.{
            .{ .id = "y", .method = .GET, .path = "/y", .responses = ok(&plain), .security = &.{&.{.{ .scheme = "key" }}} },
        } },
    } };
    const line: Refusal = .{ .service = "b", .operation = "y", .pointer = "/services/1/operations/0/security/0/0/scheme", .reason = .unknown_scheme, .name = "key" };
    var whole: Loaded = .init(&schemes, .{});
    defer whole.deinit();
    try whole.expectModelRefused();
    try whole.expectRefusals(&.{line});
    var per_op: Loaded = .init(&schemes, .{ .on_unsupported = .refuse_operation });
    defer per_op.deinit();
    try per_op.expectRefused(&.{ &.{false}, &.{true} });
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
    // Operation ids: every operation sharing the id is refused, and each repeat is reported where
    // it is; the operation between them is served.
    const ids: model.Model = .{ .services = &.{.{ .name = "s", .operations = &.{
        op("get", ok(&plain)), op("list", ok(&plain)), op("get", ok(&plain)), op("get", ok(&plain)),
    } }} };
    var by_id: Loaded = .init(&ids, .{ .on_unsupported = .refuse_operation });
    defer by_id.deinit();
    try by_id.expectRefusals(&.{
        .{ .service = "s", .operation = "get", .pointer = "/services/0/operations/2/id", .reason = .duplicate_operation_id, .name = "get" },
        .{ .service = "s", .operation = "get", .pointer = "/services/0/operations/3/id", .reason = .duplicate_operation_id, .name = "get" },
    });
    try by_id.expectRefused(&.{&.{ true, false, true, true }});

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

test "compile: a client whose alg names no key the provider holds fails the load under either setting" {
    const refusing: model.Model = .{
        .services = &.{.{ .name = "s", .operations = &.{op("bad", ok(&refused_not))} }},
        .identity = .{
            .keys = &.{ .{ .alg = .ES256 }, .{ .alg = .Ed25519 } },
            .clients = &.{
                // A null alg takes the first key.
                .{ .id = "first", .secret = "x" },
                .{ .id = "es", .secret = "x", .alg = .ES256 },
                .{ .id = "hs", .secret = "x", .alg = .HS256 },
                // The older name of an Ed25519 key is another alg: a token signed under one
                // name does not verify under the other.
                .{ .id = "eddsa", .secret = "x", .alg = .EdDSA },
            },
        },
    };
    for ([_]Options{ .{ .on_unsupported = .refuse_model }, .{ .on_unsupported = .refuse_operation } }) |options| {
        var loaded: Loaded = .init(&refusing, options);
        defer loaded.deinit();
        try loaded.expectModelRefused();
        // After every service's lines.
        try loaded.expectRefusals(&.{
            .{ .service = "s", .operation = "bad", .pointer = "/services/0/operations/0/responses/0/content/0/schema", .reason = .unsupported_keyword, .name = "not" },
            .{ .service = null, .operation = null, .pointer = "/identity/clients/2/alg", .reason = .no_key_for_alg, .name = "HS256" },
            .{ .service = null, .operation = null, .pointer = "/identity/clients/3/alg", .reason = .no_key_for_alg, .name = "EdDSA" },
        });
    }

    const held: model.Model = .{
        .services = &.{.{ .name = "s", .operations = &.{op("o", ok(&plain))} }},
        .identity = .{
            .keys = &.{ .{ .alg = .HS256 }, .{ .alg = .EdDSA } },
            .clients = &.{ .{ .id = "first", .secret = "x" }, .{ .id = "eddsa", .secret = "x", .alg = .EdDSA } },
        },
    };
    var loaded: Loaded = .init(&held, .{});
    defer loaded.deinit();
    try loaded.expectRefusals(&.{});
    try loaded.expectRefused(&.{&.{false}});
}

test "compile: a JWT client with a null alg on a provider with no keys fails the load under either setting" {
    // A null alg takes the first key, and there is none: the client could get no token.
    const m: model.Model = .{
        .services = &.{.{ .name = "s", .operations = &.{op("o", ok(&plain))} }},
        .identity = .{ .keys = &.{}, .clients = &.{.{ .id = "jwt", .secret = "x" }} },
    };
    for ([_]Options{ .{ .on_unsupported = .refuse_model }, .{ .on_unsupported = .refuse_operation } }) |options| {
        var loaded: Loaded = .init(&m, options);
        defer loaded.deinit();
        try loaded.expectModelRefused();
        try loaded.expectRefusals(&.{.{ .service = null, .operation = null, .pointer = "/identity/clients/0/alg", .reason = .no_signing_key, .name = "jwt" }});
    }
}

test "compile: an opaque-token client with a null alg needs no key" {
    const m: model.Model = .{
        .services = &.{.{ .name = "s", .operations = &.{op("o", ok(&plain))} }},
        .identity = .{ .keys = &.{}, .clients = &.{.{ .id = "opaque", .secret = "x", .token = .opaque_token }} },
    };
    var loaded: Loaded = .init(&m, .{});
    defer loaded.deinit();
    try loaded.expectRefusals(&.{});
    try loaded.expectRefused(&.{&.{false}});
}

test "compile: an opaque-token client whose alg no key has fails the load under either setting" {
    // It signs nothing, but its alg is held to the provider's keys all the same.
    const m: model.Model = .{
        .services = &.{.{ .name = "s", .operations = &.{op("o", ok(&plain))} }},
        .identity = .{ .keys = &.{}, .clients = &.{.{ .id = "opaque", .secret = "x", .token = .opaque_token, .alg = .HS256 }} },
    };
    for ([_]Options{ .{ .on_unsupported = .refuse_model }, .{ .on_unsupported = .refuse_operation } }) |options| {
        var loaded: Loaded = .init(&m, options);
        defer loaded.deinit();
        try loaded.expectModelRefused();
        try loaded.expectRefusals(&.{.{ .service = null, .operation = null, .pointer = "/identity/clients/0/alg", .reason = .no_key_for_alg, .name = "HS256" }});
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
    try testing.expectEqualStrings("pets", diag.report[0].service.?);
    try testing.expectEqualStrings("getPet", diag.report[0].operation.?);
    try testing.expectEqualStrings("not", diag.report[0].name);

    const clean: model.Model = .{ .services = &.{.{ .name = "s", .operations = &.{op("o", ok(&plain))} }} };
    var compiled = try compile(gpa, &clean, .{}, &diag);
    compiled.deinit(gpa);
    try testing.expectEqual(0, diag.report.len);
}

test "compile: after error.OutOfMemory, a Diagnostics that held a report holds an empty one" {
    const m: model.Model = .{ .services = &.{.{ .name = "s", .operations = &.{op("o", ok(&refused_not))} }} };
    // Each allocation of the load in turn fails, until a load succeeds in allocating at all.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var diag: Diagnostics = .{};
        defer diag.deinit(testing.allocator);
        try testing.expectError(error.ModelRefused, compile(testing.allocator, &m, .{}, &diag));
        try testing.expectEqual(1, diag.report.len);

        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        _ = compile(failing.allocator(), &m, .{}, &diag) catch |err| switch (err) {
            error.ModelRefused => break,
            error.OutOfMemory => {
                try testing.expectEqual(0, diag.report.len);
                try testing.expectEqual(0, diag.unlisted);
                continue;
            },
        };
        return error.TestUnexpectedResult;
    }
    try testing.expect(fail_index > 1);
}

test "compile: with no Diagnostics, nothing is kept and nothing leaks" {
    const m: model.Model = .{ .services = &.{.{
        .name = "s",
        .security_schemes = &.{.{ .name = "mtls", .kind = .{ .other = "mutualTLS" } }},
        .operations = &.{ op("bad", ok(&refused_not)), op("good", ok(&plain)) },
    }} };
    try testing.expectError(error.ModelRefused, compile(testing.allocator, &m, .{}, null));
    var compiled = try compile(testing.allocator, &m, .{ .on_unsupported = .refuse_operation }, null);
    defer compiled.deinit(testing.allocator);
    try testing.expectEqualDeep(@as([]const []const bool, &.{&.{ true, false }}), compiled.refused);
}

test "compile: the report lists lines until the next would pass its bound, and counts the rest" {
    const gpa = testing.allocator;
    // A line's memory here is its record, "s", the operation id, the pointer and the keyword.
    const line_bytes = @sizeOf(Refusal) + 1 + 1 + "/services/0/operations/0/responses/0/content/0/schema".len;
    // One byte longer than the keyword that, with a second line refusing "not", fills the
    // report exactly.
    const big = try gpa.alloc(u8, default_report_max - 2 * line_bytes - "not".len + 1);
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

/// Counts the bytes allocated through it and not yet freed.
const LiveBytes = struct {
    child: Allocator,
    bytes: usize = 0,

    fn allocator(l: *LiveBytes) Allocator {
        return .{ .ptr = l, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const l: *LiveBytes = @ptrCast(@alignCast(ctx));
        const memory = l.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        l.bytes += len;
        return memory;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const l: *LiveBytes = @ptrCast(@alignCast(ctx));
        if (!l.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        l.bytes = l.bytes - memory.len + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const l: *LiveBytes = @ptrCast(@alignCast(ctx));
        const moved = l.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        l.bytes = l.bytes - memory.len + new_len;
        return moved;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const l: *LiveBytes = @ptrCast(@alignCast(ctx));
        l.child.rawFree(memory, alignment, ret_addr);
        l.bytes -= memory.len;
    }
};

test "compile: the report's memory, records and text, stays within its bound, and nothing else is kept" {
    // 20,000 lines of short text: within the bound counting text alone, more than twice past it
    // counting each line's record as well.
    const keywords = try testing.allocator.alloc([]const u8, 20_000);
    defer testing.allocator.free(keywords);
    @memset(keywords, "not");
    const schema: model.Schema = .{ .other_keywords = keywords };
    const content = [_]model.MediaContent{.{ .media_type = "application/json", .schema = &schema }};
    const responses = [_]model.Response{.{ .status = .{ .code = 200 }, .content = &content }};
    const operations = [_]model.Operation{op("o", &responses)};
    const services = [_]model.Service{.{ .name = "s", .operations = &operations }};
    const m: model.Model = .{ .services = &services };

    var live: LiveBytes = .{ .child = testing.allocator };
    var diag: Diagnostics = .{};
    defer diag.deinit(live.allocator());
    try testing.expectError(error.ModelRefused, compile(live.allocator(), &m, .{}, &diag));

    const line_bytes = @sizeOf(Refusal) + "s".len + "o".len + "/services/0/operations/0/responses/0/content/0/schema".len + "not".len;
    try testing.expectEqual(diag.report_max / line_bytes, diag.report.len);
    try testing.expectEqual(keywords.len - diag.report.len, diag.unlisted);
    // Once the load returns, all it holds is the report: no buffer left behind by its growth.
    try testing.expectEqual(diag.report.len * line_bytes, live.bytes);
    try testing.expect(live.bytes <= diag.report_max);
}

test "compile: the bound on the report never changes the load's outcome" {
    const gpa = testing.allocator;
    // A line that refuses nothing and fills the report exactly: its record, "s", no operation,
    // the pointer and the kind.
    const kind = try gpa.alloc(u8, default_report_max - @sizeOf(Refusal) - 1 - "/services/0/security_schemes/0/kind/other".len);
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

fn compileWithoutReport(gpa: Allocator, m: *const model.Model, options: Options) !void {
    var compiled = compile(gpa, m, options, null) catch |err| switch (err) {
        error.ModelRefused => return,
        error.OutOfMemory => |e| return e,
    };
    compiled.deinit(gpa);
}

test "compile: no leak or double free when any allocation fails" {
    const m: model.Model = .{
        .services = &.{
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
        },
    };
    // Apart, because a refused client refuses the whole model, and the sweep above must also
    // reach a load that succeeds.
    const identity: model.Model = .{
        .services = &.{.{ .name = "s", .operations = &.{op("o", ok(&plain))} }},
        .identity = .{ .clients = &.{ .{ .id = "c", .secret = "x", .alg = .HS256 }, .{ .id = "d", .secret = "x", .alg = .EdDSA } } },
    };
    inline for (.{ compileWithReport, compileWithoutReport }) |load| {
        try testing.checkAllAllocationFailures(testing.allocator, load, .{ &m, Options{ .on_unsupported = .refuse_operation } });
        try testing.checkAllAllocationFailures(testing.allocator, load, .{ &m, Options{ .on_unsupported = .refuse_model } });
        try testing.checkAllAllocationFailures(testing.allocator, load, .{ &identity, Options{} });
    }
}

/// The result of `loadWithin`, held in its buffer.
const Within = struct {
    compiled: Compiled,
    diag: Diagnostics,
};

/// Loads `m` with every allocation, the result's included, taken from `buffer`, so that a load
/// that takes more than the buffer fails with `error.OutOfMemory` instead of passing. A test sizes
/// the buffer with room for its fixture under this code and far below what the earlier code took;
/// that shows the load stays within the budget for that fixture, not a bound for every model,
/// which rests on the code's own invariants. Logs how long the load took and where it left the buffer's end, at `.info`: the
/// test runner shows that only when `std.testing.log_level` is raised, because any test output
/// on stderr makes `zig build test` print its command as failed though every test passed.
fn loadWithin(buffer: []u8, m: *const model.Model, options: Options, what: []const u8) !Within {
    var fba: std.heap.FixedBufferAllocator = .init(buffer);
    var diag: Diagnostics = .{};
    const start = std.Io.Timestamp.now(testing.io, .awake).nanoseconds;
    const compiled = try compile(fba.allocator(), m, options, &diag);
    const took = std.Io.Timestamp.now(testing.io, .awake).nanoseconds - start;
    std.log.info("{s}: loaded in {d} ms, ending {d} bytes into a buffer of {d}\n", .{ what, @divTrunc(took, std.time.ns_per_ms), fba.end_index, buffer.len });
    return .{ .compiled = compiled, .diag = diag };
}

test "compile: requirements many operations share take memory for the schemes declared, not for each use" {
    const gpa = testing.allocator;
    // 2,000 operations share one slice of 2,000 requirements, each naming "auth": 4,000,000 uses
    // held in a few thousand values. Keeping a record of each use would take 64 MB.
    const uses = [_]model.SchemeUse{.{ .scheme = "auth" }};
    const requirements = try gpa.alloc(model.Requirement, 2_000);
    defer gpa.free(requirements);
    @memset(requirements, &uses);
    const ids = try gpa.alloc([4]u8, 2_000);
    defer gpa.free(ids);
    const operations = try gpa.alloc(model.Operation, ids.len);
    defer gpa.free(operations);
    for (operations, ids, 0..) |*operation, *id, i| {
        _ = std.fmt.bufPrint(id, "{d:0>4}", .{i}) catch unreachable;
        operation.* = op(id, ok(&plain));
        operation.security = requirements;
    }
    // "legacy" is of a kind mock does not implement and no requirement names it, so its line
    // refuses nothing. Marking it used would fail the load; leaving "auth" unmarked changes
    // nothing here, since "auth" is of a kind mock implements.
    const schemes = [_]model.SecurityScheme{
        .{ .name = "auth", .kind = .{ .http_bearer = .{} } },
        .{ .name = "legacy", .kind = .{ .other = "custom" } },
    };
    const services = [_]model.Service{.{ .name = "s", .security_schemes = &schemes, .operations = operations }};
    const m: model.Model = .{ .services = &services };

    // The load ends about 0.1 MiB into the buffer, measured.
    const buffer = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buffer);
    const loaded = try loadWithin(buffer, &m, .{}, "4,000,000 uses of one scheme");
    try testing.expectEqualDeep(&[_]Refusal{
        .{ .service = "s", .operation = null, .pointer = "/services/0/security_schemes/1/kind/other", .reason = .unsupported_scheme_kind_unused, .name = "custom" },
    }, loaded.diag.report);
    try testing.expectEqual(@as(u64, 0), loaded.diag.unlisted);
    try testing.expectEqual(1, loaded.compiled.refused.len);
    try testing.expectEqual(ids.len, loaded.compiled.refused[0].len);
    try testing.expect(std.mem.allEqual(bool, loaded.compiled.refused[0], false));
}

test "compile: schemas that share one child slice take memory for the schemas, not for the edges" {
    const gpa = testing.allocator;
    // 2,000 schemas share one slice of 2,000 properties, one naming each of them: 4,000,000 edges
    // held in a few thousand values. Queuing a schema at each edge that reaches it before the
    // walk enters it would keep about 2,000,000 records.
    const schemas = try gpa.alloc(model.Schema, 2_000);
    defer gpa.free(schemas);
    const properties = try gpa.alloc(model.Property, schemas.len);
    defer gpa.free(properties);
    const names = try gpa.alloc([4]u8, schemas.len);
    defer gpa.free(names);
    for (schemas, properties, names, 0..) |*schema, *property, *name, i| {
        _ = std.fmt.bufPrint(name, "{d:0>4}", .{i}) catch unreachable;
        property.* = .{ .name = name, .schema = schema };
        schema.* = .{ .properties = properties };
    }
    // Refused only in the last schema. From schema i, properties 0 to i lead to schemas already
    // entered, so the first path to it in field order runs through every other schema in turn.
    schemas[schemas.len - 1].other_keywords = &.{"not"};
    const content = [_]model.MediaContent{.{ .media_type = "application/json", .schema = &schemas[0] }};
    const responses = [_]model.Response{.{ .status = .{ .code = 200 }, .content = &content }};
    const operations = [_]model.Operation{op("o", &responses)};
    const services = [_]model.Service{.{ .name = "s", .operations = &operations }};
    const m: model.Model = .{ .services = &services };

    var pointer: std.ArrayList(u8) = .empty;
    defer pointer.deinit(gpa);
    try pointer.appendSlice(gpa, "/services/0/operations/0/responses/0/content/0/schema");
    for (1..schemas.len) |i| try pointer.print(gpa, "/properties/{d}/schema", .{i});

    // The load ends about 0.8 MiB into the buffer, measured: a fixed buffer's allocator frees
    // only its last allocation, so an array that grows when it is not the last one is copied and
    // leaves its old block behind.
    const buffer = try gpa.alloc(u8, 4 << 20);
    defer gpa.free(buffer);
    const loaded = try loadWithin(buffer, &m, .{ .on_unsupported = .refuse_operation }, "4,000,000 edges between 2,000 schemas");
    try testing.expectEqualDeep(&[_]Refusal{
        .{ .service = "s", .operation = "o", .pointer = pointer.items, .reason = .unsupported_keyword, .name = "not" },
    }, loaded.diag.report);
    try testing.expectEqualDeep(&[_][]const bool{&.{true}}, loaded.compiled.refused);
}

test "compile: Options.limits.load_report bounds the report, and the printed report names the bound" {
    const gpa = testing.allocator;
    const schema: model.Schema = .{ .other_keywords = &.{ "not", "if", "then" } };
    const content = [_]model.MediaContent{.{ .media_type = "application/json", .schema = &schema }};
    const responses = [_]model.Response{.{ .status = .{ .code = 200 }, .content = &content }};
    const operations = [_]model.Operation{op("o", &responses)};
    const services = [_]model.Service{.{ .name = "s", .operations = &operations }};
    const m: model.Model = .{ .services = &services };
    const where = "/services/0/operations/0/responses/0/content/0/schema";

    var whole: Loaded = .init(&m, .{});
    defer whole.deinit();
    try whole.expectModelRefused();
    try testing.expectEqual(3, whole.diag.report.len);
    try testing.expectEqual(default_report_max, whole.diag.report_max);

    // Room for the lines refusing "not" and "if", and not for "then".
    const bound = 2 * (@sizeOf(Refusal) + "s".len + "o".len + where.len) + "not".len + "if".len;
    var bounded: Loaded = .init(&m, .{ .limits = .{ .load_report = bound } });
    defer bounded.deinit();
    try bounded.expectModelRefused();
    try testing.expectEqual(bound, bounded.diag.report_max);
    try testing.expectEqual(@as(u64, 1), bounded.diag.unlisted);
    const printed = try std.fmt.allocPrint(gpa, "{f}", .{bounded.diag});
    defer gpa.free(printed);
    const expected = try std.fmt.allocPrint(gpa,
        \\service "s", operation "o", {s}: unsupported keyword "not"
        \\service "s", operation "o", {s}: unsupported keyword "if"
        \\1 more not listed: the report keeps at most {d} bytes
        \\
    , .{ where, where, bound });
    defer gpa.free(expected);
    try testing.expectEqualStrings(expected, printed);
}

test "compile: the report's bound defaults to the design's 1 MiB" {
    // The Bounds row "Load report memory" gives 1 MiB, so changing it here is changing the design.
    try testing.expectEqual(@as(usize, 1 << 20), default_report_max);
    try testing.expectEqual(default_report_max, (Limits{}).load_report);
    try testing.expectEqual(default_report_max, (Options{}).limits.load_report);
    try testing.expectEqual(default_report_max, (Diagnostics{}).report_max);
}
