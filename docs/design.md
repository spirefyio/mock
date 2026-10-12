# mock: design

Status: **proposal**, for review before any code is written. The README states the scope; this
document says how the first slice is built and what comes after it. Where this document and the
README disagree, that is a defect in one of them.

Standard-library citations are `lib/std/<path>:<line>` in the Zig 0.16.0 release, read when this
document was written.

## 1. Goals, non-goals and the test-double bar

### Goals

- A Zig library that serves a working mock of an API **in memory, inside the test process**: the
  HTTP server, later the SOAP server and the brokers, and an identity provider that issues
  credentials. No containers, no outside services, nothing to install.
- Mocks are **built at run time from a model**, mock's own Zig types (section 2). A running mock
  can be handed a new model and serves it from the next request on.
- **Model-neutral.** mock depends only on Zig's standard library. A tool that reads OpenAPI,
  AsyncAPI or WSDL maps its model onto mock's types on its own side. Spirefy does this from its
  unified API model through an adapter that lives in Spirefy, not here.
- **Credentials that work end to end**, good and deliberately bad, starting with the simple
  schemes (section 5) and growing as conformance tests need more (section 6).
- **Observable.** A test can query everything the mock received and issued, and inject faults.
- Linux, macOS and Windows.

### Non-goals

- A production server, broker or identity provider. Nothing mock signs is to be trusted outside a
  test.
- A load-testing tool.
- Every behaviour of every broker, or every keyword of every schema language.

### The test-double bar

A test double is useful only while it is **never wrong in a way the test cannot see**. mock holds
that bar with three rules:

1. **A stated subset.** mock implements a written list of features (sections 4 and 5). Anything
   outside it is **refused with an error that names what was refused**, never approximated. A
   model that uses an unsupported schema keyword is refused when it is loaded, not served with the
   keyword ignored.
2. **Bounded, never lossy.** Every queue, store and buffer has a limit. Reaching it produces an
   error the test can see: an HTTP status that says so, or an error from the query API. Nothing is
   dropped silently.
3. **Checked by independent software.** A behaviour counts as working only once software we did
   not write agrees with it (section 8). A test written by the same people who wrote the code
   shares their reading of the spec, so it cannot catch a misreading.

## 2. The model types

The model is plain Zig data: structs, slices and pointers, with no hidden state. A caller builds
it with struct literals (at comptime or at run time), and an adapter builds it from a parsed
description. mock copies everything it needs when it loads a model, so the caller may free its
model as soon as the load returns.

### Types

```zig
pub const Model = struct {
    services: []const Service,
    identity: ?Identity = null,       // the in-process identity provider, if any
};

pub const Service = struct {
    name: []const u8,                 // unique; the key for ports, records and swaps
    audience: ?[]const u8 = null,     // JWT `aud` this service accepts; defaults to `name`
    security_schemes: []const SecurityScheme = &.{},
    security: []const Requirement = &.{},   // default for operations; empty = none
    operations: []const Operation,
};

pub const Operation = struct {
    id: []const u8,                   // unique within the service
    method: std.http.Method,          // lib/std/http.zig:23
    path: []const u8,                 // template: "/pets/{petId}"
    parameters: []const Parameter = &.{},
    request_body: ?RequestBody = null,
    responses: []const Response,
    security: ?[]const Requirement = null,  // null = the service's; empty = none
};

pub const Parameter = struct {
    name: []const u8,
    in: enum { path, query, header, cookie },
    required: bool = false,           // a path parameter is always required
    style: Style = .default,          // `.default` = the location's default style
    explode: ?bool = null,
    schema: *const Schema,
};

pub const RequestBody = struct {
    required: bool = false,
    content: []const MediaContent,
};

pub const Response = struct {
    status: Status,                   // .{ .code = 200 }, .{ .range = 4 } for 4XX, or .default
    headers: []const Header = &.{},
    content: []const MediaContent = &.{},
};

pub const MediaContent = struct {
    media_type: []const u8,           // "application/json"
    schema: ?*const Schema = null,
    examples: []const Example = &.{},
};

pub const Example = struct { name: []const u8, value: Value };
```

`Value` is mock's own JSON-shaped value: null, bool, number (kept as its source text, so large
integers and exact decimals survive), string, array, or object with ordered members.

`Schema` covers the JSON Schema keywords listed in section 4.4, with **one escape hatch that keeps
the subset honest**:

```zig
pub const Schema = struct {
    types: TypeSet = .any,            // null, boolean, integer, number, string, array, object
    enum_values: ?[]const Value = null,
    const_value: ?Value = null,
    // numbers
    minimum: ?Number = null, maximum: ?Number = null,
    exclusive_minimum: ?Number = null, exclusive_maximum: ?Number = null,
    multiple_of: ?Number = null,
    // strings
    min_length: ?u32 = null, max_length: ?u32 = null,
    format: ?[]const u8 = null,
    pattern: ?[]const u8 = null,      // has a field so adapters map it; refused in slice 1
    // arrays
    items: ?*const Schema = null, min_items: ?u32 = null, max_items: ?u32 = null,
    unique_items: bool = false,
    // objects
    properties: []const Property = &.{},
    required: []const []const u8 = &.{},
    additional_properties: Additional = .allowed,   // .allowed, .forbidden, or .{ .schema = s }
    // composition
    all_of: []const *const Schema = &.{},
    any_of: []const *const Schema = &.{},
    one_of: []const *const Schema = &.{},
    // annotations that change behaviour
    read_only: bool = false, write_only: bool = false,
    default: ?Value = null,
    examples: []const Value = &.{},
    // every keyword the source had that has no field above
    other_keywords: []const []const u8 = &.{},
};
```

An adapter maps the keywords mock has fields for and puts the name of **every other keyword** into
`other_keywords`. mock knows which of those are pure annotations (`title`, `description`,
`$comment`, `deprecated`, `externalDocs`, `x-` extensions, and the OpenAPI `discriminator`, which
does not change `oneOf` validation) and refuses the rest. Without this field an adapter would drop
`not` or `if` silently and mock would answer as if the keyword were absent, which is exactly the
wrong answer the bar forbids.

Schemas reference each other by `*const Schema`, so a recursive schema is a pointer cycle. mock
copies the graph once, keeping cycles, when it loads the model.

Security and identity types:

```zig
pub const SecurityScheme = struct {
    name: []const u8,
    kind: union(enum) {
        api_key: struct { in: enum { header, query, cookie }, name: []const u8 },
        http_basic,
        http_bearer: struct { format: enum { any, jwt, opaque_token } = .any },
        oauth2: struct { scopes: []const []const u8 = &.{} },   // any flow; see 5.1
        openid_connect,                                       // checked as bearer; see 5.1
        other: []const u8,            // e.g. "mutualTLS", "http digest": refused at load
    },
};

pub const Requirement = []const SchemeUse;   // all of these together
pub const SchemeUse = struct { scheme: []const u8, scopes: []const []const u8 = &.{} };

pub const Identity = struct {
    issuer: []const u8 = "mock",
    keys: []const KeySpec = &.{.{ .alg = .ES256 }},   // made fresh for each mock
    users: []const TestUser = &.{},
    clients: []const Client = &.{},
    api_keys: []const ApiKey = &.{},
    token_ttl_s: u32 = 300,
};

pub const TestUser = struct {
    username: []const u8, password: []const u8,
    subject: ?[]const u8 = null,      // defaults to username
    scopes: []const []const u8 = &.{},
};

pub const Client = struct {
    id: []const u8, secret: []const u8,
    scopes: []const []const u8 = &.{},       // what it may ask for
    token: enum { jwt, opaque_token } = .jwt,
    alg: ?Alg = null,                        // which key signs its JWTs; first key if null
    defect: ?Defect = null,                  // section 5.4: every token it gets is bad this way
};

pub const ApiKey = struct { value: []const u8, subject: []const u8, scopes: []const []const u8 = &.{} };
```

Requirements follow OpenAPI's meaning: an operation's list of requirements is satisfied when **any
one** requirement is; a requirement is satisfied when **all** its schemes are. An empty
requirement in the list makes authentication optional.

### Building a model in code

```zig
const pet: mock.Schema = .{
    .types = .object,
    .properties = &.{
        .{ .name = "id", .schema = &.{ .types = .integer, .format = "int64" } },
        .{ .name = "name", .schema = &.{ .types = .string, .min_length = 1 } },
    },
    .required = &.{ "id", "name" },
};

const model: mock.Model = .{ .services = &.{.{
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
```

### Loading, the load report and swapping

Loading a model compiles it: every name is resolved, every path template parsed, every schema
checked against the subset, every example validated against its schema, and the route table built.
The result is an immutable compiled model. Loading produces a **load report**: one line for every
refusal, each naming where (service, operation, JSON pointer into the schema) and what (keyword,
parameter style, media type, scheme).

What happens to a refusal is set by `Options.on_unsupported`:

- `.refuse_model` (the default): any refusal fails the load. Right for a test, which wants to know
  at once.
- `.refuse_operation`: the operations that need a refused feature answer 501 with a problem
  document naming the refusal; the rest are served. Right for a tool that mocks whatever API a user
  imports and shows the report.

An example that does not validate against its own schema is a refusal like any other: mock will not
hand a client data the description says is impossible.

**Swapping.** `swapModel(new)` compiles the new model first. If it is refused, the old model keeps
serving and the call returns the error with its report. If it compiles, one pointer is replaced
under a lock. A request already in progress finishes on the model it started with (each request
holds a reference; the last release frees the old model), and every request that starts afterwards
sees the new one. A swap may change anything except the set of service names, because services own
listeners and ports; a swap that adds or removes a service is refused (`error.ServiceSetChanged`).
The identity provider keeps its keys and its token store across a swap, so tokens issued before it
stay valid; users, clients and API keys come from the new model.

## 3. The server core

### Listeners

Each service gets one listener. By default it binds `127.0.0.1` on port 0, so the OS picks a free
port and tests can run in parallel; `mock.port("pets")` and `mock.baseUrl("pets")` say where it is.
A test may name a port or another address in `Options`. The identity provider has a listener of its
own when its token endpoint is enabled (5.5).

Built on `std.Io.net`: `IpAddress.listen` (`lib/std/Io/net.zig:246`, options at `:224`) and
`Server.accept` (`:1442`). HTTP parsing is `std.http.Server` (`lib/std/http/Server.zig`):
`receiveHead` (`:46`) parses the request head into the reader's buffer, and returns
`HttpHeadersOversize` when the head does not fit (`:25`), which gives the head-size bound for free;
`iterateHeaders` (`:237`), `readerExpectNone` and `readerExpectContinue` (`:591`, `:577`) and
`respond` (`:323`) do the rest.

`std.http.Method` is a closed enum of the nine RFC 9110 and RFC 5789 methods (`lib/std/http.zig:23`)
and `receiveHead` rejects any other method as an invalid head, so mock serves exactly those nine.
A model cannot name another method, because `Operation.method` has that type.

### The Host check, against DNS rebinding

A web page can make the victim's browser resolve an attacker's host name to 127.0.0.1 and then
talk to a loopback server under that name. Every listener therefore checks the Host header before
anything else:

- Accepted by default: `127.0.0.1:<port>`, `localhost:<port>` and `[::1]:<port>`, with the
  listener's own port. `Options.allowed_hosts` adds names; `.any` turns the check off and must be
  written out.
- A missing Host header, or more than one, is answered 400, as RFC 9112 §3.2 requires for
  HTTP/1.1. mock applies the same rule to HTTP/1.0, since the check cannot run without Host.
- Any other Host is answered **421 Misdirected Request** (RFC 9110 §15.5.20: the server will not
  produce an authoritative response for that target) with a problem document, and recorded.
- Only origin-form request targets (`/path?query`, RFC 9112 §3.2.1) are accepted. An absolute-form
  target (`GET http://host/ HTTP/1.1`) is answered 400, because RFC 9112 §3.2.2 tells a server to
  take the authority from such a target and ignore Host, which would sidestep the check.
- mock sends no CORS headers unless a test configures allowed origins, so a page on another origin
  cannot read mock's responses. (WebSocket, later, checks `Origin` for the same reason;
  RFC 6455 §10.2.)

### Threading on `std.Io`

mock takes the caller's `std.Io` and uses it for every socket, lock, sleep and task. It needs an
implementation that can run tasks **concurrently**, because the accept loop must make progress while
the test's own client is blocked on a response:

- `start` launches one accept task per listener with `Io.concurrent` (`lib/std/Io.zig:2365`).
  If the `Io` cannot run tasks concurrently, `start` fails with `error.ConcurrencyUnavailable`
  (`:2352`) instead of deadlocking later.
- Each accepted connection is served by a task in one `Io.Group` (`:1218`, `concurrent` at
  `:1261`), one request at a time per connection, with HTTP/1.1 keep-alive.
- `Io.Threaded` (`lib/std/Io/Threaded.zig:1607`) supports this on all three systems; its listen
  and accept have POSIX and Windows paths (`:1916`, `:1924`). The io_uring implementation in 0.16
  does not implement listening (`lib/std/Io/Uring.zig:774`), so `start` fails there.
- Shared state (the compiled-model pointer, the record, the token store, the fault rules) is
  guarded by `Io.Mutex` (`lib/std/Io.zig:1587`), taken with `lockUncancelable` so that stopping
  cannot leave a structure half-updated.

**Idle and stuck connections.** A `std.Io.net.Stream` read takes no deadline (the only receive
with a timeout is the datagram `receiveTimeout`, `lib/std/Io/net.zig:1164`). So one sweeper task
per mock wakes periodically, and shuts down (`Stream.shutdown`, `:1252`) any connection that has
been idle longer than `limits.idle_timeout`. Shutting the socket down is also what unblocks a write
to a client that never reads.

### Start and stop

- `start` binds every listener or none: a failure part-way closes the ones already bound and returns
  the error.
- `stop` stops accepting, cancels the accept tasks (`accept` can return `error.Canceled`,
  `lib/std/Io/net.zig:1442`), shuts down every live connection, then cancels and awaits the
  connection group (`Group.cancel`, `lib/std/Io.zig:1298`). Shutting the sockets down first is what
  bounds `stop`: a task blocked writing to a client that never reads fails its write instead of
  holding `stop` forever. A test plants exactly that client (section 8).
- `stop` is idempotent; `deinit` calls it. A stopped mock keeps its record until `deinit`.

### Bounds

Every limit has a default, can be set in `Options.limits`, and fails visibly.

| Bound | Default | When it is reached |
|---|---|---|
| Open connections per listener | 64 | The connection is accepted, answered 503 with a problem document and `Connection: close`, and recorded as refused. |
| Request head | 16 KiB | 431 (RFC 6585 §5). The limit is the size of the reader buffer handed to `std.http.Server.init`. |
| Request body | 1 MiB | 413, decided from `Content-Length` before the body is read, or as soon as a chunked body passes the limit. |
| Idle connection | 30 s | Shut down by the sweeper, and recorded. |
| Record entries | 10,000 | Later requests are still answered and **counted**, but not stored. Every record query then returns `error.RecordOverflow` until `clear()`. A truncated record cannot be read by accident. |
| Body bytes kept per record entry | 64 KiB | The prefix is kept, with the full length and `body_truncated = true`. |
| Errors listed in a validation problem | 32 | The list ends and the document says `"truncated": true`. |
| Tokens held (issued, with their metadata) | 10,000 | `issue` returns `error.TokenStoreFull`; the token endpoint answers 503. |
| Size of a presented token | 8 KiB | Refused with reason `too_large`. |
| Fault rules | 256 | `faults.add` returns `error.TooManyRules`. |
| Generation depth / generated array length | 8 / 3 | See 4.3. |

### The seed

`Options.seed` (default 0) makes generated data repeatable. Each generated response draws from a
fresh `std.Random.Xoshiro256` (`lib/std/Random.zig:24`), seeded with
`std.hash.Wyhash.hash(seed, operation id ‖ method ‖ target ‖ body)` (`lib/std/hash/wyhash.zig:178`).
So the same request gets the same generated response whatever order concurrent requests arrive
in. mock names `Xoshiro256` directly rather than `std.Random.DefaultPrng`, which is only an alias
(`lib/std/Random.zig:13`) that a later Zig may point elsewhere.

The promise is: the same mock version, model, seed and request produce the same bytes. Output may
change between mock versions.

Keys are **not** derived from the seed. They are made fresh for each mock from the `Io`'s
cryptographic random source (`lib/std/Io.zig:2468`), as the README promises.

### The record

Every request, and every credential the identity provider issues, is recorded:

- **Requests**: sequence number, time, service, method, target, headers, body (bounded), the
  operation it matched (or why none did), the authentication outcome (scheme, subject, scopes, or
  the refusal reason), the response status, any fault applied, and duration.
- **Tokens**: kind (JWT or opaque), client or user, subject, scopes, issue and expiry times, `jti`,
  and the defect it was issued with, if any.

**Ordering guarantee:** a request's entry is in the record **before the first byte of its response
is written**. A test that has received a response can therefore always find its entry; there is no
window in which the client has an answer the record does not show.

Queries (`requests`, `tokens`, `count`, each with a filter) copy their results into the caller's
allocator, so nothing a test holds can be freed under it by a later `clear`.

### Fault injection

A fault rule matches requests (by service, operation id, or any) and applies to the next `times`
matches, or to every match until removed:

- `status`: answer with this status, body and headers instead of the normal response;
- `declared`: answer with one of the operation's declared responses (by status, and example name)
  instead of the default choice;
- `delay`: wait, then answer normally. The wait is a cancelable `Io.sleep` (`lib/std/Io.zig:2397`),
  so `stop` is never held up by it;
- `drop`: close the connection before any response, or part-way through the body.

Every applied fault is in the request's record entry. The identity provider's token endpoint is an
operation like any other, so forcing it to answer `invalid_grant` is a `status` fault; no separate
hook system is needed.

## 4. The HTTP mock

### 4.1 Routing

1. The path is split on `/` and each segment is percent-decoded; a decoded `/` stays inside its
   segment. No other normalization: `/pets/` is not `/pets`, and dot segments are not removed.
2. A template segment matches a literal segment exactly, and a `{name}` segment matches any
   non-empty segment.
3. When more than one template matches, **the most literal wins**: compare the templates segment by
   segment, and at the first position where one has a literal and the other a parameter, the
   literal wins. This is the OpenAPI rule ("concrete paths match before templated ones") made total.
   Two templates that differ only in parameter names are refused at load.
4. The method is matched after the path. **A path that matches with no operation for the method is
   405** with an `Allow` header listing the methods it has (RFC 9110 §15.5.6); no matching path is
   404. HEAD on a path that declares GET but not HEAD is answered as GET without a body
   (RFC 9110 §9.3.2).

### 4.2 Answering

On a valid request the mock picks the response:

1. A matching fault rule, if any (3, fault injection).
2. Otherwise the lowest declared 2xx status, or `default` when there is no 2xx.
3. The media type: the first declared one the `Accept` header allows (`*/*` and `type/*` honoured,
   `q=0` excluded); none allowed is 406.
4. The body: the first named example; else the schema's `examples`, then `default`; else a value
   generated from the schema (4.3). Declared response headers are produced the same way.

Every generated value is **validated against its schema before it is sent**. A value that fails, for
example a `oneOf` the generator could not satisfy, is not sent: the mock answers 500 with a
problem document naming the schema location. Wrong data is never served as if it were right.

### 4.3 Generating from a schema

Deterministic from the seed (3, the seed). Required properties are always produced and optional
ones are produced too, down to the depth bound; additional properties are never produced. Arrays get
between `minItems` and `min(maxItems, minItems + 3)` items. Strings respect `minLength` and
`maxLength`. Numbers respect the bounds and integer `multipleOf`. `enum` and `const` pick from the
set. `oneOf` and `anyOf` try branches in seed order until a value validates; `allOf` is generated
only when every branch is an object schema, by merging properties and `required`. `readOnly`
properties appear in responses and never in generated request examples; `writeOnly` properties never
appear in responses.

Formats generated: `date-time`, `date` and `time` (RFC 3339), `uuid` (version 4 layout, RFC 9562),
`email` (at `example.com`, RFC 2606), `uri`, `hostname`, `ipv4`, `ipv6`, and the numeric formats
`int32`, `int64`, `float` and `double` as range limits. A string schema with any other format and no
example is refused at load: mock cannot know what a valid value looks like.

A schema whose required properties recurse with no way to stop within the depth bound is refused at
load, and so is `uniqueItems` over too few possible values.

### 4.4 Validating a request

mock validates the request against the operation before anything else touches it: path, query,
header and cookie parameters, then `Content-Type`, then the body.

**Error responses.** Errors are `application/problem+json` (RFC 9457), with a `type` tag URI
(RFC 4151) such as `tag:spirefy.io,2026:mock/request-invalid`, a `title`, the `status`, the
`operation`, and an `errors` extension member listing each problem: where (`in` and a JSON pointer),
which keyword, and a message.

**Status: 400 for a request that cannot be read, 422 for content that can be read but breaks its
schema.** A missing required parameter, a parameter that does not parse as its type, a missing
required body or a body that does not parse as its media type is 400 (RFC 9110 §15.5.1). A body that
parses but fails its schema is 422 Unprocessable Content (RFC 9110 §15.5.21: the content type is
understood and the syntax is correct, but the instructions cannot be processed). A `Content-Type`
the operation does not declare is 415.

Scalar's mock server answers every validation failure, parameters included, with 422 and the
content type `application/problem+json` (its body is `{error, violations}`, without the RFC 9457
members). mock agrees with it on body schema failures and differs on parameters: a parameter is not
content, so RFC 9110 gives it no claim to 422, and a test that checks for 400 on a malformed
parameter is checking what most real servers do.

mock answers with its own problem document even when the operation declares its own 400 or 422
schema, because only mock's document can say what was wrong. Whether to answer with the API's
declared error shape instead is an open question (section 10).

**What the first slice validates.** The JSON Schema 2020-12 keywords below, plus OpenAPI's
`readOnly` and `writeOnly` semantics:

| Kind | Validated |
|---|---|
| Any | `type` (one type or a list, which is how `nullable` arrives), `enum`, `const` |
| Number, integer | `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf` (an integer `multipleOf` only) |
| String | `minLength`, `maxLength` (counted in Unicode code points), `format` as an annotation only, which is the 2020-12 default |
| Array | `items` (one schema), `minItems`, `maxItems`, `uniqueItems` |
| Object | `properties`, `required`, `additionalProperties` (true, false or a schema) |
| Composition | `allOf`, `anyOf`, `oneOf` |
| Annotations | `readOnly` (forbidden in a request body), `writeOnly` (never in a response), `default`, `examples` |

**What the first slice refuses**, at load, by name: `pattern` and `patternProperties` (std has no
regular-expression engine; this is the first follow-up), `not`, `if`/`then`/`else`,
`dependentRequired`, `dependentSchemas`, `prefixItems`, `contains`, `propertyNames`,
`unevaluatedProperties`, `unevaluatedItems`, `$dynamicRef`, and a non-integer `multipleOf`.

**Parameters.** Path `simple`; query `form` with `explode` true or false, for primitives and arrays;
header `simple`; cookie `form`. Objects in parameters (`deepObject`, exploded objects) and the
`matrix`, `label`, `spaceDelimited` and `pipeDelimited` styles are refused. Unknown query parameters
are allowed, as OpenAPI allows them.

**Media types.** `application/json` and any `+json` type, `text/plain`,
`application/x-www-form-urlencoded` (an object of primitive properties), and
`application/octet-stream` (bytes, checked for size only). XML and `multipart/*` are refused for
now; XML arrives with SOAP.

## 5. The auth seam and the first auth set

### 5.1 The seam

Each scheme is a variant of one tagged union, and each variant implements the same two functions:

```zig
pub const Scheme = union(enum) {
    api_key: ApiKeyScheme,
    basic: BasicScheme,
    bearer: BearerScheme,          // opaque tokens and JWTs
    // later: oauth2 flows beyond client credentials, mtls, ...

    // every variant provides:
    //   fn check(self, ctx: *const Context, req: *const RequestView) Outcome
    //   fn challenge(self, outcome: Outcome) ?[]const u8   // WWW-Authenticate value
};

pub const Outcome = union(enum) {
    absent,                        // this scheme's credential is not in the request
    granted: Principal,            // subject, client id, scopes, token jti
    refused: Refusal,              // present but bad: a reason enum plus detail
};
```

A comptime check fails the build if a variant lacks either function. Adding a scheme is adding a
variant; nothing else changes. A tagged union rather than a run-time interface, because every scheme
lives in this library: there is no second implementer outside it to design for. Whether users
should be able to plug in their own scheme is an open question (section 10).

`oauth2` and `openIdConnect` schemes in a model are **checked as bearer tokens with scopes**. For a
resource server the flow that produced a token does not matter, only whether the token is valid and
carries the scopes. So an operation protected by an authorization-code scheme is fully enforced in
the first slice; only *issuing* through that flow comes later (6), and a test can mint the token
directly meanwhile. This is the trap mock exists to avoid: a mock that accepts any
`Authorization: Bearer <anything>` passes a client that sends garbage.

**Evaluation.** For each requirement in order, check each scheme it names. The operation is allowed
if one requirement has every scheme granted with every scope it lists. Otherwise:

- 401 if no credential was presented, or one was refused, with each scheme's `WWW-Authenticate`
  challenge (RFC 7617 §2 for Basic, RFC 6750 §3 for Bearer, with `error="invalid_token"` and an
  `error_description` naming the reason);
- 403 with `error="insufficient_scope"` (RFC 6750 §3.1) if a credential was valid but lacked a scope.

The body is a problem document naming the reason (expired, wrong audience, ...). A production server
would say less; a test double that hides the reason only slows the person debugging.

Secret comparisons (API keys, passwords, client secrets, HMAC tags) go through one helper that
compares fixed-length SHA-256 digests with `std.crypto.timing_safe.eql`
(`lib/std/crypto/timing_safe.zig:12`). On a loopback test double this defends nothing in particular,
but it costs nothing and keeps the code safe to copy.

### 5.2 The first set

- **API keys** in a header, a query parameter or a cookie, matched against `Identity.api_keys`.
- **HTTP Basic** (RFC 7617) against `Identity.users`. The credentials must be valid base64
  (`lib/std/base64.zig:37`) holding exactly one `:`.
- **Bearer** (RFC 6750 §2.1, the header form only), opaque or JWT. An opaque token is 32 random
  bytes, base64url, looked up in the token store. A JWT is verified as in 5.3.
- **JWTs**, issued and verified, with:

  | `alg` | Primitive | std |
  |---|---|---|
  | `HS256` | HMAC-SHA-256, 256-bit secret (RFC 7518 §3.2) | `std.crypto.auth.hmac.sha2.HmacSha256`, `lib/std/crypto/hmac.zig:11` |
  | `ES256` | ECDSA P-256 with SHA-256; the signature is the 64-byte `R‖S`, not DER (RFC 7518 §3.4) | `std.crypto.sign.ecdsa.EcdsaP256Sha256`, `lib/std/crypto/ecdsa.zig:15`; `Signature.fromBytes` takes exactly the 64 raw bytes (`:126`), `verify` at `:102`, `KeyPair.generate` at `:326`, `sign` at `:347` |
  | `EdDSA` (RFC 8037 §3.1), or `Ed25519` (RFC 9864) | Ed25519 | `std.crypto.sign.Ed25519`, `lib/std/crypto/25519/ed25519.zig:17`; `Signature.verify` at `:275`, `KeyPair.generate` at `:336`, `sign` at `:375` |

  Base64url without padding is `std.base64.url_safe_no_pad` (`lib/std/base64.zig:74`). Its decoder
  rejects `=` and any character outside the alphabet, and rejects non-zero trailing bits
  (`:230`, `:279`), so a token has one encoding only. JSON is `std.json` (`lib/std/json.zig:83`,
  `:94`).

  For Ed25519 mock uses `Signature.verify` (`ed25519.zig:275`), which std documents as the
  cofactored check (`:270`); that is the equation RFC 8032 §5.1.7 states. Wycheproof (section 8)
  settles any case where the cofactored and the strict check (`verifyStrict`, `:292`) disagree. Each key carries exactly one `alg` name; an Ed25519 key is
  configured as `EdDSA` (the default, which most libraries still expect) or as `Ed25519` (the
  RFC 9864 name, which deprecates `EdDSA`).

- **An OAuth 2.0 client-credentials token endpoint** (5.5). Separable: it can be deferred without
  touching the rest.

### 5.3 Verifying a JWT

Verification follows RFC 7515 §5.2 and RFC 7519 §7.2, tightened by the JWT best current practice,
RFC 8725. Each step refuses with its own reason, which goes into the 401 and the record.

1. **Shape.** Exactly three base64url parts (compact JWS). Five parts (JWE) are refused. At most
   `limits.max_token_bytes`.
2. **Header.** Valid JSON object. **Duplicate member names are refused** (RFC 7515 §4 allows a parser
   to keep the last one instead; refusing is the safer of the two). The same holds for the claims
   (RFC 7519 §4). `std.json` refuses duplicates by default (`lib/std/json/static.zig:22`,
   `lib/std/json/dynamic.zig:150`).
3. **`alg: none` is refused**, always, whatever the key (RFC 8725 §2.1 and §3.1; RFC 7518 §3.6).
4. **The key picks the algorithm, never the header.** The key is found by `kid`; with no `kid`,
   only a provider with a single key may verify. That key has exactly one `alg`, and the header's
   `alg` must equal it (RFC 8725 §3.1: each key is used with exactly one algorithm). This is what
   defeats alg/key-type confusion, where an attacker signs `HS256` using an ES256 public key's bytes
   as the HMAC secret. Unknown `kid`: refused.
5. **`crit` is refused if present.** RFC 7515 §4.1.11 requires refusing a token whose `crit` lists an
   extension the recipient does not understand, and mock understands none. This also refuses
   `b64: false` (RFC 7797), which is only valid under `crit`.
6. **`jku`, `x5u`, `jwk` and `x5c` are never used** to find or fetch a key (RFC 8725 §3.10). Keys
   come only from the provider.
7. **`typ`** must be `at+jwt` for an access token (RFC 9068 §4; explicit typing, RFC 8725 §3.11), so
   that another kind of JWT, such as a future ID token, cannot be replayed as an access token
   (RFC 8725 §3.12).
8. **Signature.** HS256: recompute the HMAC and compare with `timing_safe.eql`. ES256: the signature
   must decode to exactly 64 bytes; a DER signature is refused, not converted. EdDSA: 64 bytes,
   `Signature.verify`.
9. **Claims** (RFC 7519 §4.1): `iss` equals the provider's issuer; `aud` (a string or an array)
   contains the service's audience (RFC 8725 §3.9); `exp` is present and in the future; `nbf`, if
   present, is not in the future. `exp`, `nbf` and `iat` must be JSON numbers (RFC 7519 §2
   NumericDate); strings are refused. Clock leeway defaults to zero and can be set.
10. **Revocation.** A `jti` in the revoked set is refused.
11. **Scopes** from the space-separated `scope` claim (RFC 9068 §2.2.3) are checked against the
    requirement.

Issued JWTs carry `typ: at+jwt`, `kid`, and the RFC 9068 §2.2 claims: `iss`, `exp`, `aud`, `sub`,
`client_id`, `iat`, `jti`, and `scope` when there are scopes.

### 5.4 Bad credentials on purpose

`idp.issue(.{ .client = "svc", .scopes = ..., .defect = .expired })` mints a token in code. The
same path with `defect` set produces a token wrong in exactly one way:

| Defect | What is wrong |
|---|---|
| `expired` | `exp` in the past |
| `not_yet_valid` | `nbf` in the future |
| `wrong_issuer` | `iss` is not the provider's |
| `wrong_audience` | `aud` names no service |
| `bad_signature` | one bit of the signature flipped |
| `missing_scope` | `scope` lacks what was asked for |
| `revoked` | issued, then its `jti` revoked |
| `alg_none` | unsigned, `alg: none` |
| `wrong_typ` | `typ: JWT` instead of `at+jwt` |
| `unknown_kid` | `kid` names no key |
| `untrusted_key` | signed by a key the provider does not hold |

A client configured with a `defect` gets tokens with that defect from the token endpoint, so a
system that fetches its own token can be tested against a bad one. Defective tokens are recorded with
their defect. They serve two kinds of test: a server under test that must refuse them (it verifies
with the provider's keys, 5.6), and mock's own verifier, which must refuse every one of them with the
matching reason (section 8).

### 5.5 The client-credentials token endpoint

RFC 6749 §4.4, on the provider's own listener at `/token`:

- `POST`, `application/x-www-form-urlencoded`, `grant_type=client_credentials`, optional `scope`.
- Client authentication by HTTP Basic (`client_secret_basic`) or in the form body
  (`client_secret_post`), RFC 6749 §2.3.1. Both at once is `invalid_request`.
- Success (§5.1): `access_token`, `token_type: "Bearer"`, `expires_in`, `scope`, with
  `Cache-Control: no-store`. The requested scopes must be a subset of the client's; none requested
  means all of them.
- Errors (§5.2): `invalid_request`, `invalid_client` (401, with a challenge when Basic was used),
  `unsupported_grant_type`, `invalid_scope`, `unauthorized_client`.

It is a module of its own on top of the issuer. Deferring it removes that module and its listener;
`idp.issue` still mints tokens in code.

### 5.6 What the provider exposes

- `idp.jwks(allocator)`: the public keys as a JWK Set (RFC 7517; OKP keys as in RFC 8037 §2), for a
  server under test or an outside verifier. Serving it over HTTP comes with OpenID Connect discovery
  (6).
- `idp.hmacSecret(kid)`: an HS256 key is a shared secret, so a server under test that verifies HS256
  needs it.
- `idp.revoke(jti)`, `idp.tokenUrl()`.

## 6. Staging

Each item lands **when a conformance test needs it**, not before. Each needs:

| Item | Needs |
|---|---|
| `pattern`, `patternProperties` | A regular-expression engine for the ECMA-262 dialect JSON Schema uses; std has none. Also generation of strings that match. |
| RS256, PS256 | RSA key generation and signing. std verifies only: `lib/std/crypto/Certificate.zig:945` has `rsa.PKCS1v1_5Signature.verify` (`:1125`) and `PSSSignature.verify` (`:962`), no signing and no key generation. Generating keys means prime generation on top of `lib/std/crypto/ff.zig`. |
| Authorization code with PKCE (RFC 7636), refresh tokens (RFC 6749 §6), device code (RFC 8628), introspection (RFC 7662), revocation (RFC 7009) | Headless approval: an authorization request is approved as the test user the test picks. Client registration with redirect URIs. Mostly HTTP and the existing issuer. |
| OpenID Connect: discovery, JWKS over HTTP, ID tokens, userinfo | The above, plus `nonce` and ID-token claims. |
| TLS server; HTTPS listeners | A TLS 1.3 server. std has a client only (`lib/std/crypto/tls.zig:39`). |
| Mutual TLS (RFC 8705) | The TLS server, plus a small X.509 issuer to make client certificates. std's `lib/std/crypto/Certificate.zig` parses (`:422`) and verifies (`:551`) but does not build certificates; that needs a DER writer. |
| SASL for the brokers: PLAIN (RFC 4616), SCRAM-SHA-256 (RFC 7677) and SCRAM-SHA-512 (RFC 5802 mechanism), OAUTHBEARER (RFC 7628) | The broker it runs in. SCRAM uses std's PBKDF2 (`lib/std/crypto/pbkdf2.zig`) and HMAC; OAUTHBEARER reuses the bearer verifier. |
| SAML 2.0 SSO and WS-Security for SOAP | An XML parser (std has none), exclusive XML canonicalization (W3C xml-exc-c14n), XML-DSig, RSA signing (above) and the X.509 issuer (above). In memory, good enough for an API client or service to work against; not an enterprise IdP. |
| Protocols, in order | HTTP; then WebSocket (RFC 6455; std's `respondWebSocket` at `lib/std/http/Server.zig:531` writes the handshake, mock adds the Host and Origin checks and bounded frames); MQTT 3.1.1, then 5.0; AMQP 0-9-1; Kafka; SOAP 1.1 and 1.2 (the XML parser above); later GraphQL and gRPC (gRPC needs HTTP/2, which std does not serve). |

The README's "HTTP/1.1, plain or over TLS" depends on the TLS server row.

## 7. Borrowing policy

We write mock ourselves and own its code. Where another open-source project has solved a problem
well and its license allows it, we may copy or adapt its code, with credit.

**May be copied or adapted:** code under MIT, BSD-2-Clause, BSD-3-Clause, ISC, Zlib, 0BSD,
Apache-2.0, CC0-1.0 or the Unlicense.

- The file keeps the original copyright and license notice in its header, followed by a line saying
  what we changed.
- `NOTICE` lists every source: project, URL, the commit we took it from, and its license.
- When the source is Apache-2.0 and has a `NOTICE` file, its text is carried into ours (Apache-2.0
  §4(d)).

**Never copied:** GPL, LGPL, AGPL, SSPL or BUSL code, or code with no license. MPL-2.0 only with the
maintainer's explicit decision, case by case. Reading such code to understand an algorithm is fine;
copying or translating it line by line is not.

**Test vectors** (RFC examples, Wycheproof) are credited the same way: the file that holds them says
where they came from, and `NOTICE` lists them.

**Borrowed code meets the same bar as ours:** the same review, the same tests, the same planted
defects. A borrowed file is not trusted because it is popular.

Code that Spirefy's own maintainers wrote for other Spirefy projects may be moved in; its copyright
holder licenses it under Apache-2.0 as it is added, and it is reviewed like new code.

### Borrowing candidates

Pending the library survey.

## 8. How it is checked

Unit tests prove the code does what its authors meant. They cannot prove the authors read the spec
right, so every protocol behaviour is also checked against independent software. The checks are
shell scripts and Zig tests only: no Python anywhere in the build, the tests or the tooling.

### The oracles

- **curl**, for HTTP routing, validation statuses, the Host check, Basic and API keys. The scripts
  send requests with `curl --fail-with-body -w '%{http_code}'` and compare statuses, headers and
  problem documents. `curl -H 'Host: evil.example'` checks the rebinding guard.
- **step** (`step crypto jwt verify --key <jwk> --iss <issuer> --aud <audience>`), for tokens the
  mock issues: a good token must verify, and every defective one except `missing_scope` and
  `revoked` must fail. A token whose payload or signature the script changes by one character must
  fail.
- **openssl**, a second signature check: `openssl dgst -sha256 -mac HMAC` for HS256 and
  `openssl pkeyutl -verify -rawin` for Ed25519, over the token's signing input.
- **Published vectors**, as Zig tests:
  - RFC 7515 Appendix A.1 (HS256) and A.3 (ES256) must verify; A.5 (an unsecured JWS) must be
    refused;
  - RFC 8037 Appendix A.4 (Ed25519): Ed25519 signatures are deterministic, so mock must produce the
    published signature byte for byte, and verify it;
  - RFC 7520 §4.4 (HS256). RFC 7518 defines the algorithms but publishes no JWS signature examples.
  - Wycheproof (Apache-2.0): the P-256 ECDSA vectors in IEEE P1363 form, which is exactly JWS's
    `R‖S`; the Ed25519 vectors; the HMAC-SHA-256 vectors. Every `valid` case must verify and every
    `invalid` case must be refused.

The scripts drive a small example program (`examples/serve.zig`) that builds a fixture model,
starts a mock, prints its ports, writes the JWK Set and a token of every kind to an output
directory, and stops when its standard input closes. A missing tool fails the check with its name;
it is never skipped silently.

### Plants

A plant is a defect injected on purpose to show that a check can fail. Each check below names the
plant it must turn red; a check never seen red is not trusted.

| Plant | Must be caught by |
|---|---|
| Verification accepts a wrong signature (the comparison is skipped) | The `bad_signature` unit test; Wycheproof `invalid` cases; the tampered-token script. |
| `alg: none` accepted | RFC 7515 A.5; the `alg_none` unit test. |
| The header's `alg` chooses the verification (an HS256 token keyed with the ES256 public key's bytes is accepted) | An alg-confusion unit test that builds exactly that token. |
| `crit` ignored | A token with `crit: ["x"]` must be refused. |
| `exp` or `aud` not checked | The `expired` and `wrong_audience` unit tests; `step` for issued tokens. |
| Routing ignores the method | `curl -X DELETE` on a GET-only path must get 405 with `Allow: GET`; the router unit test. |
| The most-literal rule reversed | `/pets/mine` must reach its own operation, not `/pets/{petId}`. |
| The Host check disabled | `curl -H 'Host: evil.example'` must get 421. |
| The record drops entries past its bound silently | Fill the record to its bound plus one: the query must return `error.RecordOverflow`, not the first N entries. |
| The connection bound not enforced | Open bound + 1 connections: the last must get 503. |
| `stop` waits on a client that never reads | A test whose client sends a request for a large response and never reads; `stop` must return within the test's time limit. |
| A generated value is sent without the self-check | A schema the generator is known to fail (an unsatisfiable `oneOf`) must give 500, not a body. |

### What each oracle cannot see

- **curl** sees one client's view of the wire. It cannot see the record, ordering under concurrency,
  or bounds that need many connections; those are Zig tests, written by us.
- **step** verifies signature, `iss`, `aud`, `exp` and `nbf` of tokens mock **issues**. It does not
  test mock's **verifier**, and it cannot see scopes or revocation, which only mock knows.
- **openssl** checks signatures only, not claims or the JOSE header.
- **RFC vectors** are few and mostly well-formed; only A.5 is a negative case.
- **Wycheproof** tests the signature primitives and our encoding of them (`R‖S`, base64url). It cannot
  see JWT header or claim logic.
- **Our unit tests** share our reading of the specs. They are the only check for the record, faults,
  bounds and auth evaluation until a broker or identity-provider oracle covers them.

Later protocols bring their own oracles, as the README says: Mosquitto with Eclipse Paho for MQTT,
RabbitMQ and its clients for AMQP, Apache Kafka with librdkafka for Kafka, and established
relying-party tools for OpenID Connect and SAML. CI runs them; the library never depends on them.
The interop scripts run on Linux and macOS; Windows runs the Zig tests.

## 9. Package layout and API sketch

```
build.zig
build.zig.zon            .minimum_zig_version = "0.16.0", no dependencies
NOTICE
src/
  mock.zig               the public root
  model.zig              the types in section 2
  value.zig              Value, parsing and writing through std.json
  compile.zig            load: checks, the load report, the route table
  schema/validate.zig
  schema/generate.zig
  server/listener.zig    accept loop, connection tasks, Host check, bounds, sweeper
  server/record.zig
  server/faults.zig
  http/router.zig
  http/params.zig
  http/handler.zig       validation, response choice, problem documents
  auth/scheme.zig        the Scheme union, Outcome, requirement evaluation
  auth/api_key.zig
  auth/basic.zig
  auth/bearer.zig
  jose/jws.zig           compact JWS: parse, sign, verify
  jose/jwt.zig           claims, the steps in 5.3
  jose/jwk.zig           JWK Set export
  idp/provider.zig       keys, users, clients, token store, issue, defects
  idp/token_endpoint.zig the client-credentials endpoint (separable)
tests/vectors/           RFC and Wycheproof vectors, credited
examples/serve.zig       the fixture program the scripts drive
scripts/check/           http.sh, auth.sh, jwt.sh
```

Build steps: `zig build` (the `mock` module), `zig build test` (unit tests and vectors), and
`zig build check` (builds `examples/serve` and runs `scripts/check/*.sh`; needs curl, step and
openssl). A consumer adds the package to `build.zig.zon` and imports
`b.dependency("mock", .{}).module("mock")`.

### API sketch (a proposal, not a promise)

```zig
const std = @import("std");
const mock = @import("mock");

test "client sends a valid token" {
    const io = std.testing.io;
    var diag: mock.Diagnostics = .{};
    const m = try mock.Mock.init(std.testing.allocator, io, &model, .{ .seed = 7 }, &diag);
    defer m.deinit();
    try m.start();

    const token = try m.idp.?.issue(std.testing.allocator, .{ .client = "svc", .scopes = &.{"pets:read"} });
    defer std.testing.allocator.free(token);

    // ... drive the client under test at m.baseUrl("pets") with `token` ...

    const seen = try m.record.requests(std.testing.allocator, .{ .operation = "getPet" });
    defer mock.Record.free(std.testing.allocator, seen);
    try std.testing.expectEqual(@as(usize, 1), seen.len);
    try std.testing.expectEqualStrings("svc", seen[0].auth.granted.client_id);
}
```

```zig
pub const Mock = struct {
    pub fn init(gpa: Allocator, io: std.Io, model: *const Model, options: Options, diag: ?*Diagnostics) InitError!*Mock;
    pub fn deinit(m: *Mock) void;
    pub fn start(m: *Mock) StartError!void;
    pub fn stop(m: *Mock) void;
    pub fn port(m: *const Mock, service: []const u8) ?u16;
    pub fn baseUrl(m: *const Mock, service: []const u8) ?[]const u8;
    pub fn swapModel(m: *Mock, model: *const Model, diag: ?*Diagnostics) SwapError!void;
    record: *Record,
    faults: *Faults,
    idp: ?*Provider,
};

pub const Options = struct {
    address: []const u8 = "127.0.0.1",
    ports: []const struct { service: []const u8, port: u16 } = &.{},  // 0 = OS picks
    allowed_hosts: HostPolicy = .loopback,
    seed: u64 = 0,
    on_unsupported: enum { refuse_model, refuse_operation } = .refuse_model,
    clock_leeway_s: u32 = 0,
    limits: Limits = .{},
};
```

`Diagnostics` carries the load report, because a Zig error carries no payload.

## 10. Open questions for the maintainer

1. **Deferring the token endpoint.** Ship client credentials in the first slice (5.5) or defer it
   and mint tokens only in code?
2. **Declared error shapes.** Validation errors use mock's own problem document. Should mock answer
   with the operation's declared 400/422 response instead, when it has one?
3. **Custom schemes.** Should users be able to add their own auth scheme (for example a signed-request
   scheme), which would need a run-time interface beside the tagged union?
4. **A test clock.** Token times come from the real clock. Is a settable clock worth adding, so a test
   can make a token expire without waiting?
5. **Services in a swap.** A swap cannot add or remove a service. Is that acceptable for Spirefy's
   use, where a user may add a server while a mock is running?
6. **`EdDSA` or `Ed25519` by default** for Ed25519 keys (5.2).
7. **Choosing a response from the client.** Prism lets a client pick a response with a `Prefer`
   header. mock offers only the in-code `declared` fault. Is the header wanted?

## 11. Prior art

Read on 2026-10-12 (UTC) at the releases named.

- **MockServer** (Apache-2.0, release `mockserver-8.0.0`) has a mock OpenID Connect provider and a
  mock SAML identity provider, each with switches for bad credentials. The OpenID Connect provider
  has `issueExpiredToken`, `wrongIssuer` and `tamperedSignature`
  (<https://mock-server.com/mock_server/mock_openid_connect_provider.html>); the SAML provider has
  `expiredAssertion`, `wrongAudience` and `tamperedSignature`
  (<https://mock-server.com/mock_server/mocking_saml.html>). The switches apply to the whole
  provider. mock's defects (5.4) take the same idea per token and per client.
- **axa-group/oauth2-mock-server** (MIT, `v9.2.0`) emits `beforeTokenSigning` and `beforeResponse`
  events; its README forces `invalid_grant` by rewriting the token response in `beforeResponse`.
  mock does this with a fault rule on the token endpoint instead of a second hook system.
- **navikt/mock-oauth2-server** (MIT, `6.0.5`): a scriptable OAuth 2.0 and OpenID Connect server for
  JVM tests, with discovery, JWKS, several grants, and a login page that is off in library mode
  (`interactiveLogin`). Its headless approval is the model for mock's later authorization-code flow.
- **Stoplight Prism** (Apache-2.0, `v5.16.0`) is the warning. Its bearer, OAuth 2.0 and OpenID
  Connect handlers are one function that tests the `Authorization` header against `^Bearer\s.+$`
  (`packages/http/src/validator/validators/security/handlers/bearer.ts`); no token is verified and
  no scope is checked, so any bearer string passes. mock verifies (5.3).
- **Scalar's mock server** (MIT, `@scalar/mock-server` 0.17.4) validates parameters and JSON bodies
  and answers every failure with 422 and `application/problem+json`
  (`packages/mock-server/src/utils/validate-request.ts`). How mock differs is in 4.4.
- **Wycheproof** (Apache-2.0) supplies the signature test vectors.

Design review records are in [design-review.md](design-review.md).
