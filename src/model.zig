//! The model: mock's own Zig types for the APIs a mock serves.
//!
//! A model is plain data, structs, slices and pointers with no hidden state. A test builds one
//! with struct literals, at comptime or at run time; a tool that reads OpenAPI or another
//! description maps it onto these types on its own side. A model is checked when it is loaded,
//! and everything the checks refuse is named in the load report.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Number = value.Number;

/// Everything one mock serves.
pub const Model = struct {
    services: []const Service,
    /// The in-process identity provider, if the model has one.
    identity: ?Identity = null,
};

/// One API, served on a listener of its own.
pub const Service = struct {
    /// Unique within the model: the key for the service's port, its record entries and swaps.
    name: []const u8,
    /// The JWT `aud` this service accepts. Null means `name`.
    audience: ?[]const u8 = null,
    security_schemes: []const SecurityScheme = &.{},
    /// The requirements of every operation whose own `security` is null. Empty means none.
    security: []const Requirement = &.{},
    operations: []const Operation,
};

pub const Operation = struct {
    /// Unique within the service.
    id: []const u8,
    method: std.http.Method,
    /// A path template, such as "/pets/{petId}".
    path: []const u8,
    parameters: []const Parameter = &.{},
    request_body: ?RequestBody = null,
    responses: []const Response,
    /// Null takes the service's requirements; empty means none.
    security: ?[]const Requirement = null,
};

pub const Parameter = struct {
    name: []const u8,
    in: enum { path, query, header, cookie },
    /// A path parameter is always required, whatever this says.
    required: bool = false,
    style: Style = .default,
    /// Null means the style's default.
    explode: ?bool = null,
    schema: *const Schema,
};

/// How a parameter's value is written, by the OpenAPI style names.
pub const Style = enum {
    /// The default style of the parameter's location.
    default,
    matrix,
    label,
    simple,
    form,
    space_delimited,
    pipe_delimited,
    deep_object,
};

pub const RequestBody = struct {
    required: bool = false,
    content: []const MediaContent,
};

pub const Response = struct {
    status: Status,
    headers: []const Header = &.{},
    content: []const MediaContent = &.{},
};

/// Which statuses a declared response stands for.
pub const Status = union(enum) {
    /// One status code: `.{ .code = 200 }`.
    code: u16,
    /// Every code with this first digit: `.{ .range = 4 }` is `4XX`.
    range: u8,
    /// Every status no other response of the operation declares.
    default,
};

/// A response header the operation declares.
pub const Header = struct {
    name: []const u8,
    schema: *const Schema,
};

pub const MediaContent = struct {
    /// Such as "application/json".
    media_type: []const u8,
    schema: ?*const Schema = null,
    examples: []const Example = &.{},
};

pub const Example = struct { name: []const u8, value: Value };

/// A JSON Schema, in the subset mock implements.
///
/// Schemas refer to each other by pointer, so a recursive schema is a pointer cycle.
pub const Schema = struct {
    types: TypeSet = .any,
    enum_values: ?[]const Value = null,
    const_value: ?Value = null,

    minimum: ?Number = null,
    maximum: ?Number = null,
    exclusive_minimum: ?Number = null,
    exclusive_maximum: ?Number = null,
    multiple_of: ?Number = null,

    min_length: ?u32 = null,
    max_length: ?u32 = null,
    format: ?[]const u8 = null,
    /// Has a field so that an adapter can map it; a schema that sets it is refused when the model
    /// is loaded, because mock has no regular-expression engine yet.
    pattern: ?[]const u8 = null,

    items: ?*const Schema = null,
    min_items: ?u32 = null,
    max_items: ?u32 = null,
    unique_items: bool = false,

    properties: []const Property = &.{},
    required: []const []const u8 = &.{},
    additional_properties: Additional = .allowed,

    all_of: []const *const Schema = &.{},
    any_of: []const *const Schema = &.{},
    one_of: []const *const Schema = &.{},

    read_only: bool = false,
    write_only: bool = false,
    default: ?Value = null,
    examples: []const Value = &.{},

    /// The name of every keyword the source schema had that has no field above.
    ///
    /// Pure annotations are accepted: `title`, `description`, `$comment`, `deprecated`,
    /// `externalDocs`, the OpenAPI `discriminator` (it does not change how `oneOf` validates), and
    /// any name starting `x-`. Every other name is refused when the model is loaded, so that a
    /// keyword such as `not` is never served as if it were absent.
    other_keywords: []const []const u8 = &.{},
};

/// The JSON Schema `type` names.
pub const JsonType = enum { null, boolean, integer, number, string, array, object };

/// The types a schema allows: one, as in `.types = .string`, several, as in
/// `.types = .of(&.{ .string, .null })`, or `.any`.
pub const TypeSet = struct {
    set: std.EnumSet(JsonType),

    pub const any: TypeSet = .{ .set = .initFull() };
    pub const @"null": TypeSet = .of(&.{.null});
    pub const boolean: TypeSet = .of(&.{.boolean});
    pub const integer: TypeSet = .of(&.{.integer});
    pub const number: TypeSet = .of(&.{.number});
    pub const string: TypeSet = .of(&.{.string});
    pub const array: TypeSet = .of(&.{.array});
    pub const object: TypeSet = .of(&.{.object});

    pub fn of(types: []const JsonType) TypeSet {
        return .{ .set = .initMany(types) };
    }
};

pub const Property = struct {
    name: []const u8,
    schema: *const Schema,
};

/// `additionalProperties`: true, false, or a schema.
pub const Additional = union(enum) {
    allowed,
    forbidden,
    schema: *const Schema,
};

pub const SecurityScheme = struct {
    name: []const u8,
    kind: union(enum) {
        api_key: struct { in: enum { header, query, cookie }, name: []const u8 },
        http_basic,
        http_bearer: struct { format: enum { any, jwt, opaque_token } = .any },
        /// Checked as a bearer token with scopes, whatever the flow.
        oauth2: struct { scopes: []const []const u8 = &.{} },
        /// Checked as a bearer token.
        openid_connect,
        /// A scheme mock does not implement, by its source name, such as "mutualTLS" or
        /// "http digest". A model that declares one is refused when it is loaded.
        other: []const u8,
    },
};

/// Satisfied when every scheme it names is. An operation's list of requirements is satisfied
/// when any one of them is, so an empty requirement in the list makes authentication optional.
pub const Requirement = []const SchemeUse;

pub const SchemeUse = struct {
    /// The `SecurityScheme.name` of a scheme the service declares.
    scheme: []const u8,
    scopes: []const []const u8 = &.{},
};

/// The identity provider: its signing keys and the principals it knows.
pub const Identity = struct {
    issuer: []const u8 = "mock",
    /// Keys are made fresh for each mock, never derived from the model.
    keys: []const KeySpec = &.{.{ .alg = .ES256 }},
    users: []const TestUser = &.{},
    clients: []const Client = &.{},
    api_keys: []const ApiKey = &.{},
    token_ttl_s: u32 = 300,
};

/// A signing key the provider makes, by the one JWS algorithm it is used with.
pub const KeySpec = struct { alg: Alg };

/// The JWS `alg` names mock signs and verifies with. An Ed25519 key is named `Ed25519`, the
/// RFC 9864 name, or `EdDSA` for clients that know only the older one; a token signed under one
/// name does not verify under the other.
pub const Alg = enum { HS256, ES256, Ed25519, EdDSA };

pub const TestUser = struct {
    username: []const u8,
    password: []const u8,
    /// Null means `username`.
    subject: ?[]const u8 = null,
    scopes: []const []const u8 = &.{},
};

pub const Client = struct {
    id: []const u8,
    secret: []const u8,
    /// The scopes the client may ask for.
    scopes: []const []const u8 = &.{},
    token: enum { jwt, opaque_token } = .jwt,
    /// Which key signs its JWTs; null means the provider's first key.
    alg: ?Alg = null,
    /// When set, every token the client gets is wrong in this one way.
    defect: ?Defect = null,
};

/// The one way a deliberately bad token is wrong.
pub const Defect = enum {
    expired,
    not_yet_valid,
    wrong_issuer,
    wrong_audience,
    bad_signature,
    untrusted_key,
    missing_scope,
    revoked,
    alg_none,
    wrong_typ,
    unknown_kid,
};

pub const ApiKey = struct {
    value: []const u8,
    subject: []const u8,
    scopes: []const []const u8 = &.{},
};

test "TypeSet: each named set holds exactly its own type" {
    // Catches a name bound to the wrong type, such as `integer` holding `number`.
    inline for (comptime std.enums.values(JsonType)) |t| {
        const one: TypeSet = @field(TypeSet, @tagName(t));
        try std.testing.expect(one.set.eql(.initOne(t)));
    }
    const unconstrained: Schema = .{};
    try std.testing.expect(unconstrained.types.set.eql(.initFull()));

    const nullable_string: Schema = .{ .types = .of(&.{ .string, .null }) };
    try std.testing.expectEqual(2, nullable_string.types.set.count());
    try std.testing.expect(nullable_string.types.set.contains(.string));
    try std.testing.expect(nullable_string.types.set.contains(.null));
}
