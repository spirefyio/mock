//! The load report: its lines, how they print, and the `Diagnostics` that carries them out of a
//! load.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The most memory the load report holds: each listed line's record and the bytes of the service
/// name, operation id, pointer and name it holds (design section 3, Bounds). Past it, lines are
/// counted in `Diagnostics.unlisted` instead. A default that `Options.limits` is to take over when
/// it exists.
pub const default_report_max: usize = 1 << 20;

/// One line of the load report.
pub const Refusal = struct {
    /// Null when the refused item is in no service: an identity client.
    service: ?[]const u8,
    /// Null when the refused item is not in one operation: a scheme a service declares, the
    /// requirements it gives operations whose own `security` is null, or an identity client.
    operation: ?[]const u8,
    /// A JSON pointer (RFC 6901) from the model's root to the refused item, through the model
    /// types' field names and slice indices, such as
    /// "/services/0/operations/2/parameters/0/schema/items". A schema reached by more than one path
    /// is named by the first in field order: the check goes depth first, through each schema's
    /// children in the order of `Schema`'s fields.
    pointer: []const u8,
    reason: Reason,
    /// What was refused: the keyword, the scheme a requirement names, the scheme kind, the name
    /// used twice, the `alg` a client names, or the id of a JWT client with no key to sign with.
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
        /// An identity client whose `alg` names no key the provider holds.
        no_key_for_alg,
        /// A JWT client whose `alg` is null, on an identity provider that holds no key.
        no_signing_key,
    };

    /// Writes the refusal as one line with no line break, such as
    /// `service "pets", operation "getPet", /services/0/operations/0/parameters/0/schema:
    /// unsupported keyword "not"`. A line in no service starts at its pointer. Names are written
    /// as JSON strings, with each byte that is not part of a valid UTF-8 sequence written as
    /// U+FFFD, so a name holding a quote, a line break or invalid UTF-8 still gives one line of
    /// valid UTF-8; the report itself keeps the name's bytes as they were. A line that refuses
    /// nothing ends `named by no requirement, refuses nothing`.
    ///
    /// Errors: `error.WriteFailed` when `w` fails.
    pub fn format(r: Refusal, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (r.service) |service| {
            try w.writeAll("service ");
            try writeName(w, service);
            if (r.operation) |id| {
                try w.writeAll(", operation ");
                try writeName(w, id);
            }
            try w.writeAll(", ");
        }
        const what = switch (r.reason) {
            .duplicate_service_name => "service name used twice",
            .duplicate_operation_id => "operation id used twice",
            .duplicate_scheme_name => "security scheme name used twice",
            .unknown_scheme => "no security scheme named",
            .unsupported_scheme_kind, .unsupported_scheme_kind_unused => "unsupported security scheme kind",
            .unsupported_keyword => "unsupported keyword",
            .no_key_for_alg => "no key of the identity provider has alg",
            .no_signing_key => "no key of the identity provider can sign for client",
        };
        try w.print("{s}: {s} ", .{ r.pointer, what });
        try writeName(w, r.name);
        if (r.reason == .unsupported_scheme_kind_unused) try w.writeAll(", named by no requirement, refuses nothing");
    }
};

/// Writes `name` as a JSON string, each byte that is not part of a valid UTF-8 sequence as
/// U+FFFD. `std.json.fmt` would write such a name as an array of numbers.
fn writeName(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    // The start of the valid sequences not yet written.
    var start: usize = 0;
    var i: usize = 0;
    while (i < name.len) {
        const len: usize = std.unicode.utf8ByteSequenceLength(name[i]) catch 0;
        if (len != 0 and len <= name.len - i and std.unicode.utf8ValidateSlice(name[i..][0..len])) {
            i += len;
            continue;
        }
        try std.json.Stringify.encodeJsonStringChars(name[start..i], .{}, w);
        try w.writeAll("\u{FFFD}");
        i += 1;
        start = i;
    }
    try std.json.Stringify.encodeJsonStringChars(name[start..], .{}, w);
    try w.writeByte('"');
}

/// Carries the load report out of `compile`, which a Zig error cannot.
pub const Diagnostics = struct {
    /// The lines of the last load given this `Diagnostics`, in the order the checks met them:
    /// each service in turn, and in a service its name, its schemes, its requirements, then each
    /// operation; then the identity provider's clients. Listed while the memory they take stays
    /// within `report_max`: each line's record, and the bytes of its service name, operation id,
    /// pointer and name. The first line that would take it past and every one after it are
    /// counted in `unlisted` instead. Empty after a load with nothing to report, and after
    /// `error.OutOfMemory`.
    report: []const Refusal = &.{},
    /// The lines past the bound: counted, not listed. The load's outcome is the same as if they
    /// had been listed.
    unlisted: u64 = 0,
    /// The bound `report` was built with, in bytes.
    report_max: usize = default_report_max,
    /// The bytes the strings in `report` point into.
    text: []const u8 = &.{},

    /// Frees the report and leaves `d` empty and reusable. `gpa` is the allocator given to the
    /// load that filled it.
    pub fn deinit(d: *Diagnostics, gpa: Allocator) void {
        gpa.free(d.report);
        gpa.free(d.text);
        d.* = .{};
    }

    /// Writes each line of the report, each ending in a line break, then, when lines are past
    /// the bound, a last line with their count and the bound, such as
    /// `2 more not listed: the report keeps at most 1048576 bytes`.
    ///
    /// Errors: `error.WriteFailed` when `w` fails.
    pub fn format(d: Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (d.report) |line| try w.print("{f}\n", .{line});
        if (d.unlisted != 0) {
            try w.print("{d} more not listed: the report keeps at most {d} bytes\n", .{ d.unlisted, d.report_max });
        }
    }
};

const testing = std.testing;

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
    // Each reason's own words: a line printed with another reason's would send its reader to the
    // wrong fault.
    try testing.expectFmt(
        \\service "s", operation "o", /services/0/operations/0/security/0/0/scheme: no security scheme named "key"
    , "{f}", .{Refusal{ .service = "s", .operation = "o", .pointer = "/services/0/operations/0/security/0/0/scheme", .reason = .unknown_scheme, .name = "key" }});
    try testing.expectFmt(
        \\service "s", /services/0/security_schemes/1/name: security scheme name used twice "auth"
    , "{f}", .{Refusal{ .service = "s", .operation = null, .pointer = "/services/0/security_schemes/1/name", .reason = .duplicate_scheme_name, .name = "auth" }});
    try testing.expectFmt(
        \\service "pets", /services/1/name: service name used twice "pets"
    , "{f}", .{Refusal{ .service = "pets", .operation = null, .pointer = "/services/1/name", .reason = .duplicate_service_name, .name = "pets" }});
    // A line in no service starts at its pointer.
    try testing.expectFmt(
        \\/identity/clients/2/alg: no key of the identity provider has alg "HS256"
    , "{f}", .{Refusal{ .service = null, .operation = null, .pointer = "/identity/clients/2/alg", .reason = .no_key_for_alg, .name = "HS256" }});
    try testing.expectFmt(
        \\/identity/clients/1/alg: no key of the identity provider can sign for client "a\"b"
    , "{f}", .{Refusal{ .service = null, .operation = null, .pointer = "/identity/clients/1/alg", .reason = .no_signing_key, .name = "a\"b" }});
    // Invalid UTF-8 is printed as U+FFFD inside the string, never as an array of bytes; valid
    // multi-byte sequences are kept. Each byte outside a valid sequence is one U+FFFD: a lead
    // byte with no continuation, and each byte of an encoded surrogate.
    try testing.expectFmt("service \"s\u{FFFD}\", operation \"\u{FFFD}\u{FFFD}\", /services/0/operations/0/id: operation id used twice \"\u{FFFD}\u{FFFD}\u{FFFD}é\"", "{f}", .{Refusal{ .service = "s\xff", .operation = "\xc3\xe9", .pointer = "/services/0/operations/0/id", .reason = .duplicate_operation_id, .name = "\xed\xa0\x80é" }});
}

test "Diagnostics.format: one line each, then the count of lines past the bound" {
    const line: Refusal = .{ .service = "s", .operation = "o", .pointer = "/services/0/operations/0/id", .reason = .duplicate_operation_id, .name = "o" };
    // Without the last line a reader would take the listed lines for the whole report. The bound
    // printed is the one the report was built with.
    try testing.expectFmt(
        \\service "s", operation "o", /services/0/operations/0/id: operation id used twice "o"
        \\service "s", operation "o", /services/0/operations/0/id: operation id used twice "o"
        \\3 more not listed: the report keeps at most 4096 bytes
        \\
    , "{f}", .{Diagnostics{ .report = &.{ line, line }, .unlisted = 3, .report_max = 4096 }});
    // And with nothing past the bound, no count line.
    try testing.expectFmt(
        \\service "s", operation "o", /services/0/operations/0/id: operation id used twice "o"
        \\
    , "{f}", .{Diagnostics{ .report = &.{line} }});
    try testing.expectFmt("", "{f}", .{Diagnostics{}});
}
