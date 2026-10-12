# mock: design

Status: **accepted**; the first slice is being built to it, in stages. The README states the
scope; this document says how the first slice is built and what comes after it. Where this
document and the README disagree, that is a defect in one of them. Where the code shows the design
is wrong, the design is corrected first, in the same change.

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
    name: []const u8,                 // unique, or the load fails; keys ports, records, swaps
    audience: ?[]const u8 = null,     // JWT `aud` this service accepts; defaults to `name`
    security_schemes: []const SecurityScheme = &.{},
    security: []const Requirement = &.{},   // default for operations; empty = none
    operations: []const Operation,
};

pub const Operation = struct {
    id: []const u8,                   // unique within the service (used twice, both are refused)
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
`other_keywords`. mock accepts the names that are pure annotations, which change nothing mock does,
and refuses the rest. The annotations are:

- `title`, `description`, `$comment`, `deprecated`, `externalDocs`, `x-` extensions (the prefix
  compared with case, as OpenAPI's field names are), OpenAPI 3.0's `example` and `xml`, and the
  OpenAPI `discriminator`, which does not change `oneOf` validation. An adapter should map 3.0's
  `example` into `examples`, where it is validated and served; listed here instead, its value
  never reaches mock, so it is neither checked nor served;
- the identifiers and containers `$schema`, `$id`, `$anchor`, `$dynamicAnchor`,
  `$recursiveAnchor`, `$vocabulary`, `$defs` and `definitions`. They name a schema, a dialect or a
  place to keep schemas, and they matter only to the adapter: a reference reaches its target as a
  pointer, so a schema kept under `$defs` is checked where a pointer reaches it;
- `contentMediaType`, `contentEncoding` and `contentSchema`, which JSON Schema 2020-12 makes
  annotations.

The references `$ref`, `$dynamicRef` and `$recursiveRef` stay refused. An adapter resolves a
reference into a `*const Schema`; one left in `other_keywords` means the adapter did not resolve it,
and ignoring it would validate against nothing. `nullable` stays refused too: an adapter maps it
into `types` (4.4), and one left unmapped, if ignored, would refuse a valid null.

Without this field an adapter would drop `not` or `if` silently and mock would answer as if the
keyword were absent, which is exactly the wrong answer the bar forbids.

Schemas reference each other by `*const Schema`, so a recursive schema is a pointer cycle. mock
copies the graph once, keeping cycles, when it loads the model.

Security and identity types:

```zig
pub const SecurityScheme = struct {
    name: []const u8,                 // unique within the service (used twice, a refusal)
    kind: union(enum) {
        api_key: struct { in: enum { header, query, cookie }, name: []const u8 },
        http_basic,
        http_bearer: struct { format: enum { any, jwt, opaque_token } = .any },
        oauth2: struct { scopes: []const []const u8 = &.{} },   // any flow; see 5.1
        openid_connect,                                       // checked as bearer; see 5.1
        other: []const u8,            // e.g. "mutualTLS", "http digest": refused where required (below)
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
checked against the subset, every example and `default` validated against its schema, and the
route table built. The result is an immutable compiled model. Loading produces a **load report**:
one line for every refusal, and one for each unsupported scheme that no operation needs (below),
each naming where and what. Where is the service, the operation, and a JSON pointer (RFC 6901) from
the model's root through the model types' field names and slice indices, such as
`/services/0/operations/2/parameters/0/schema/items`; a schema reached by more than one path is
named by the first in field order, since the check goes depth first through each schema's children
in the order of `Schema`'s fields. What is the keyword, parameter style, media type, scheme or
`alg`.

What happens to a refusal is set by `Options.on_unsupported`:

- `.refuse_model` (the default): any refusal fails the load. Right for a test, which wants to know
  at once.
- `.refuse_operation`: the operations that need a refused feature answer 501 with a problem
  document naming the refusal; the rest are served. Right for a tool that mocks whatever API a user
  imports and shows the report.

An example or `default` that does not validate against its own schema is a refusal like any other:
mock will not hand a client data the description says is impossible.

**Names.** A name used twice, or one that names nothing, is a fault in the model:

- A service name used twice fails the load under either setting, because a service is addressed by
  name: its port, its record entries and a swap all find it that way.
- An operation id used twice refuses both operations, because the record and fault rules name an
  operation by its id, so neither could be told from the other.
- A security scheme name used twice is a refusal, and so is a requirement naming a scheme the
  service does not declare. Under `.refuse_operation` each refuses the operations whose
  requirements name it; under `.refuse_model` each fails the load even when no operation needs it.

**Unsupported schemes.** A scheme of a kind mock does not implement (`kind = .other`) is not a
fault in the model, so it is refused only where an operation's requirements name it: its own, or
its service's when its own `security` is null. Under `.refuse_model` that fails the load; under
`.refuse_operation` it refuses those operations. A declared one that no operation's requirements
name still gets a line, so the reader of an imported API sees what mock would not check, but that
line refuses nothing and fails no load under either setting: no request is checked against the
scheme, so it cannot make an answer wrong. The line says so twice over: its reason is
`.unsupported_scheme_kind_unused`, and its printed form ends `named by no requirement, refuses
nothing`.

**Identity clients.** A client whose `alg` names no key the provider holds fails the load under
either setting, like a service name used twice: clients are the test's own configuration, not part
of an API it imports, so there is nothing to serve around one that is wrong. Its line names no
service and no operation; its pointer is `/identity/clients/<i>/alg`, and it comes after every
service's lines. A client whose `alg` is null takes the provider's first key and is not checked
here.

**The report is bounded.** It keeps at most 1 MiB of memory, each line's text and its record (3,
bounds); past that, lines are counted, not listed. The count is in `Diagnostics.unlisted`, and the
printed report ends with it, with the bound. The bound changes what is listed, never the load's
outcome.

**Swapping.** `swapModel(new)` compiles the new model first. If it is refused, the old model keeps
serving and the call returns the error with its report. If it compiles, one pointer is replaced
under a lock. A request already in progress finishes on the model it started with (each request
holds a reference; the last release frees the old model), and every request that starts afterwards
sees the new one. A swap may change anything except the set of service names, because services own
listeners and ports; a swap that adds or removes a service is refused (`error.ServiceSetChanged`).
The identity provider keeps its keys and its token store across a swap. So that tokens issued
before a swap stay valid after it (valid, not authorized: what a token may do follows the new
model's requirements), a swap may not add or remove the identity provider or change its
issuer, its keys, or any service's audience (`error.IdentityChanged`); users, clients and API keys
come from the new model. A client whose `alg` names no key the provider holds is refused at load,
in a swap as at the start.

## 3. The server core

### Listeners

Each service gets one listener. By default it binds `127.0.0.1` on port 0, so the OS picks a free
port and tests can run in parallel; `mock.port("pets")` and `mock.baseUrl("pets")` say where it is.
A test may name a port or another address in `Options`. The identity provider has a listener of its
own when its token endpoint is enabled (5.5).

Sockets come from `std.Io.net`: `IpAddress.listen` (`lib/std/Io/net.zig:246`, options at `:224`)
and `Server.accept` (`:1442`).

### HTTP/1.1 framing is mock's own

mock parses requests and writes responses itself. `std.http.Server` was the first candidate, but
four of its behaviours do not fit a mock that must never answer wrongly or hang:

- `readerExpectNone` gives an empty body reader to every method whose `requestHasBody()` is false,
  even when the request has a `Content-Length` (`lib/std/http/Server.zig:591-596`), and the
  keep-alive path then treats the unread body as the next request (`:618-640`, `:636`). A POST
  with neither `Content-Length` nor `Transfer-Encoding` gets the raw stream as its body
  (`lib/std/http.zig:457-459`), so reading it waits for the client to close.
- `Content-Length` is parsed with `std.fmt.parseInt` (`lib/std/http/Server.zig:154`), which accepts
  a leading `+` and ignores `_` (`lib/std/fmt.zig:329`, `:442`).
- When it means to keep the connection alive, `respond` drains an unread request body before it
  writes the status line (`:348-350`, `:618-633`), so a 413 for an oversized upload is sent only
  after the whole upload has been read.
- Starting to read a body invalidates the strings in the parsed head (`:594`).

mock's parser, bounded by the limits in this section:

- Strict request-line and header grammar (RFC 9112 §§3, 5); a malformed head is 400 and the
  connection is closed. An unrecognized method is 501 (RFC 9110 §9.1). The method of a model's
  operation is still `std.http.Method` (`lib/std/http.zig:23`), a closed set of nine; a `CONNECT`
  operation is refused at load, since mock does not tunnel.
- The head is copied into memory the connection owns before anything else reads it.
- Body framing follows RFC 9112 §6.3 and ignores the method: `Transfer-Encoding: chunked`, else
  `Content-Length`, else no body. `Content-Length` is decimal digits only. Both headers at once, a
  repeated `Content-Length` or any transfer coding other than `chunked` is refused (400, or 501 for
  an unknown coding, RFC 9112 §6.1) and the connection is closed.
- The chunked decoder is mock's own, strict to RFC 9112 §7.1. `std.http.ChunkParser` was
  considered and is not used: it takes any ASCII letter as a size digit
  (`lib/std/http/ChunkParser.zig:55-57`, so `G` reads as 16), treats any other byte as the start of
  an extension (`:65-68`), and skips extension bytes without checking them (`:79-85`). In mock's
  decoder a chunk size is one or more hex digits, and the body is refused with 413 as soon as the
  running total would pass the body limit, before any arithmetic can overflow. A chunk extension
  must match the `chunk-ext` grammar (§7.1.1) and is then ignored. The trailer section (§7.1.2) is
  parsed with the header grammar and discarded, never merged into the headers. Chunk-size lines,
  extensions and trailers count against the request-head limit, so leading zeros or long
  extensions cannot make framing unbounded; past it the answer is 431, as for the head. Malformed
  framing is 400. In every case the connection is closed.
- `Expect: 100-continue` is answered with 100 only after the head has passed the Host check,
  routing, authentication and the size limit. If any of those fails, the final response is sent
  instead. Every scheme in the first slice reads its credential from the head (5.2), so this order
  never waits on the body. The token endpoint is the exception, because a client may authenticate
  in its form body (5.5): there, 100 follows the Host check, routing, the media type and the size
  limit, and the client is authenticated after the bounded form is read.
- Whenever mock answers without reading the whole body, it sends `Connection: close` and closes. A
  connection is kept alive only after its request body has been read to its end.

Responses are written by mock too: a status line, then each header as one `name: value` line
ending in CRLF, never folded, then the body. `Content-Length` is sent on every response except 1xx,
204 and 304 (RFC 9110 §8.6); a 205 carries `Content-Length: 0` (RFC 9110 §15.3.6). A HEAD response
carries the headers the GET response would have, including its `Content-Length`, and no body.
Header names must be tokens, and values must match the `field-value` grammar of RFC 9110 §5.5:
visible characters and obs-text, with spaces and tabs only between them, and no CR, LF, NUL or
other control character. A declared response header, example or fault that breaks this is refused
when it is loaded or added. A generated header value is checked by the same rule before it is sent;
one that fails is a 500, like any value that fails its final check (4.2). `Content-Length`,
`Transfer-Encoding`, `Connection` and `Content-Encoding` are reserved to mock, which does not encode
bodies: a model that declares any of them as a response header is refused at load.

### The Host check, against DNS rebinding

A web page can make the victim's browser resolve an attacker's host name to 127.0.0.1 and then
talk to a loopback server under that name. Every listener therefore checks the request's authority
before anything else:

- Accepted by default: `127.0.0.1:<port>`, `localhost:<port>` and `[::1]:<port>`, with the
  listener's own port. The authority is parsed before it is compared, not compared as text: an IPv6
  literal as a 16-byte address, so `[0:0:0:0:0:0:0:1]` is `[::1]`; an IPv4 literal only in RFC 3986
  §3.2.2 dotted-decimal form, so `2130706433` and `0x7f.0.0.1` are names, which are not allowed; a
  name without regard to case, so `LOCALHOST` matches and `localhost.` does not; and the port as a
  decimal number, so `04711` is port 4711. A missing port means 80. A port above 65535 is invalid
  syntax. `Options.allowed_hosts` adds names; `.any` turns the check off and must be written out.
- A missing Host header, more than one, or one with invalid syntax is answered 400, as RFC 9112
  §3.2 requires for HTTP/1.1. mock applies the same rule to HTTP/1.0, since the check cannot run
  without Host.
- A well-formed authority that is not allowed is answered **421 Misdirected Request** (RFC 9110
  §15.5.20: the server will not produce an authoritative response for that target) with a problem
  document, and recorded.
- An absolute-form target (`GET http://127.0.0.1:4711/pets HTTP/1.1`) is accepted, as RFC 9112
  §3.2.2 requires, and **its** authority is the one checked; the Host header is then ignored, as
  that section says. Asterisk-form (`OPTIONS *`) is refused with 400; authority-form belongs to
  CONNECT, which mock does not serve.
- mock sends no CORS headers unless a test configures allowed origins, so a page on another origin
  cannot read mock's responses. (WebSocket, later, checks `Origin` for the same reason;
  RFC 6455 §10.2.)

### Threading on `std.Io`

mock takes the caller's `std.Io` and uses it for every socket, lock, sleep and task. It needs an
implementation that can run tasks **concurrently**, because the accept loop must make progress
while the test's own client is blocked on a response:

- `start` launches one accept task per listener and one sweeper task with `Io.concurrent`
  (`lib/std/Io.zig:2365`). If the `Io` cannot, `start` fails with `error.ConcurrencyUnavailable`
  (`:2352`) and nothing is left running.
- Each accepted connection is served by a task in one `Io.Group` (`:1218`, `concurrent` at
  `:1261`), one request at a time per connection, with HTTP/1.1 keep-alive.
- **Spawning can fail at any time, not only at start**: `Group.concurrent` returns
  `ConcurrencyUnavailable` whenever the `Io` is out of capacity (a small `concurrent_limit` on
  `Io.Threaded`, for one). The accept task then answers that connection itself with a fixed 503
  problem document and `Connection: close`, records it as refused, closes it, and goes back to
  accepting. An `accept` error is recorded and retried after a short cancelable sleep. The accept
  loop ends only when it is cancelled.
- `Io.Threaded` (`lib/std/Io/Threaded.zig:1607`) supports this on all three systems; its listen
  and accept have POSIX and Windows paths (`:1916`, `:1924`). The io_uring implementation in 0.16
  does not implement listening (`lib/std/Io/Uring.zig:774`), so `start` fails there.
- Shared state (the compiled-model pointer, the record, the token store, the fault rules, the table
  of live connections) is guarded by `Io.Mutex` (`lib/std/Io.zig:1587`). mock never awaits a task
  while holding a lock that task may need.
- **The allocator passed to `init` must be thread-safe**, because connection tasks allocate
  concurrently. `std.heap.smp_allocator` (`lib/std/heap.zig:353`) and `std.testing.allocator` (a
  `DebugAllocator`, thread-safe unless the build is single-threaded,
  `lib/std/heap/debug_allocator.zig:127`) are; a plain `FixedBufferAllocator` is not
  (`lib/std/heap/FixedBufferAllocator.zig:62-71`). mock does not serialize the caller's
  allocator.

**Cancellation is cooperative.** Cancelling a task makes its next cancelable `Io` call return
`error.Canceled` (`lib/std/Io.zig:1181-1188`); it does not interrupt computation. So request
validation and response generation run under work budgets (the bounds table) and check for
cancellation between steps, and no loop in mock is unbounded.

### Idle and stuck connections

A `std.Io.net.Stream` read takes no deadline (the only receive with a timeout is the datagram
`receiveTimeout`, `lib/std/Io/net.zig:1164`). So a sweeper task wakes once a second on the
monotonic clock and shuts down (`Stream.shutdown`, `:1252`) any connection that is past one of two
deadlines:

- **idle**: waiting for a request head or body, with no byte received for `limits.idle_timeout`;
- **write**: writing a response for longer than `limits.write_timeout`, which is what frees a task
  blocked on a client that never reads.

Time spent producing a response, including a `delay` fault, counts against neither.

The live-connection table holds each connection's socket. A connection task removes its own entry
under the table's lock before it closes its socket, and the sweeper and `stop` shut down only
sockets still in the table, under the same lock. A handle is therefore never shut down after it was
closed and possibly reused by the OS.

### Start and stop

- `start` binds every listener or none: a failure part-way closes the ones already bound and returns
  the error.
- `stop`, in order: cancels and awaits each accept task (`accept` can return `error.Canceled`,
  `lib/std/Io/net.zig:1442`; `Future.cancel`, `lib/std/Io.zig:1191`), so no new connection task is
  spawned; cancels and awaits the sweeper; shuts down every socket in the live-connection table;
  then cancels and awaits the connection group (`Group.cancel`, `lib/std/Io.zig:1298`). Shutting
  the sockets down is what bounds `stop`: a task blocked writing to a client that never reads fails
  its write instead of holding `stop` forever. Section 8 plants exactly that client.
- `start`, `stop`, `swapModel` and `deinit` take one lifecycle lock, because `Future.cancel` and
  `Group.cancel` are not thread-safe (`lib/std/Io.zig:1191`, `:1298`): a second `stop` on another
  thread waits for the first, then returns. No task of the mock takes that lock, so `stop` can
  await tasks while holding it. The lock is not recursive (`Io.Mutex.lock`, `lib/std/Io.zig:1602`),
  so each public call takes it once and does its work through internal functions that expect it
  held (the one exception, `swapModel`'s compiling, is below). `deinit` runs the stop steps that
  way, never by calling `stop`.
- `stop` and `deinit` return nothing and must finish, so no step of theirs may return early on
  `error.Canceled`. Shutting a socket down is itself cancelable (`ShutdownError`,
  `lib/std/Io/net.zig:982-988`), and so is taking a lock. Each therefore runs its whole body with
  the calling task's cancel protection set to `.blocked` (`swapCancelProtection`,
  `lib/std/Io.zig:1342`) and restores the previous state on return. Under `.blocked`, no cancelation
  point in the calling task returns `error.Canceled` (`CancelProtection`, `:1322`). Cancelling the
  mock's own tasks is unaffected, because protection belongs to the task that calls `stop`. A
  cancelled task's own result can still be `error.Canceled`, because `Future.cancel` returns the
  task's result (`:1191`). `stop` expects that result from the accept tasks and the sweeper and
  consumes it. It never treats it as unreachable, and it goes on to shut the sockets down and
  cancel the connection group.
- `start` and `swapModel` take the lock with `lock` (`:1602`), which can return `error.Canceled`
  while another call holds the lock. Each then returns `error.Canceled`, a member of `StartError`
  and `SwapError`, with nothing changed. A cancelled `start` has bound nothing, because `start`
  takes the lock before it binds. `swapModel` compiles its candidate BEFORE it takes the lock.
  Compiling touches only the private candidate and the caller's model, so it is the one piece of
  public-call work done without the lock held. A cancelled `swapModel` therefore frees the model it
  compiled, and the old model keeps serving. The lock is released only by a call that took it.
- `deinit` is the last call on a mock. The caller must own the mock exclusively by then, with no
  other thread inside or waiting on any of its methods, because `deinit` frees the lock with
  everything else.
- `stop` is idempotent, and `deinit` stops a running mock first. A stopped mock keeps its record
  until `deinit`, and no task of a mock outlives its `stop`.

### Bounds

Every limit has a default, can be set in `Options.limits`, and fails visibly.

| Bound | Default | When it is reached |
|---|---|---|
| Open connections per listener | 64 | The connection is accepted, answered 503 with a problem document and `Connection: close`, and recorded as refused. |
| Request head | 16 KiB | 431 (RFC 6585 §5), then close. |
| Request body | 1 MiB | 413, decided from `Content-Length` before any body is read, or as soon as a chunked body passes the limit; then close. |
| JSON nesting depth in a request | 64 | 413, with the error response 4.4 chooses, `Options.validation_errors` included. The record keeps the reason `request-too-complex` whichever body is sent, so the refusal stays distinct from a schema failure. |
| Validation work per request | 1,000,000 steps | As above. |
| Idle connection / blocked write | 30 s / 30 s | Shut down by the sweeper, and recorded. |
| Record entries | 10,000 | Later requests are still answered and **counted**, but not stored. Every query except `stats()` then returns `error.RecordOverflow` until `clear()`. A truncated record cannot be read by accident. |
| Body bytes kept per record entry | 64 KiB | The prefix is kept, with the full length and `body_truncated = true`. |
| Errors listed in a validation problem | 32 | The list ends and the document says `"truncated": true`. |
| Tokens held (issued, with their metadata) | 10,000 tokens / 4 MiB in all | `issue` returns `error.TokenStoreFull`; the token endpoint answers 503. Revocation applies only to held tokens, so the revoked set is bounded by the same limit. |
| Size of a token, issued or presented | 8 KiB | `issue` returns `error.TokenTooLarge` and the token endpoint answers 500; a presented token is refused with reason `too_large`. |
| Fault rules / one fault's body | 256 / 1 MiB | `faults.add` returns `error.TooManyRules` or `error.FaultTooLarge`. |
| Generation: depth / nodes / one string / one response / work | 8 / 10,000 / 4 KiB / 1 MiB / 1,000,000 steps | See 4.3. A schema whose minimum (`minItems`, `minLength`, required recursion) cannot fit is refused at load; one that overruns at run time gets 500. Nothing is clamped below what the schema requires. |
| Compiled model | 64 MiB | The load is refused. |
| Load report memory: each line's text and its record | 1 MiB | The lines are listed in the order the checks meet them until the next would pass the bound; it and every line after it are counted, not listed. `Diagnostics.unlisted` holds the count, and the printed report ends with it. The load's outcome is the one it would have without the bound. This also caps what a long chain of refused schemas, each with a longer pointer, can make the report hold. |

### The seed

`Options.seed` (default 0) makes generated data repeatable. Each generated response draws from a
fresh `std.Random.Xoshiro256` (`lib/std/Random.zig:24`), seeded with `std.hash.Wyhash.hash(seed, x)`
(`lib/std/hash/wyhash.zig:178`), where `x` is the operation id, the method, the target and the body,
each preceded by its length so that no two different requests give the same input. A HEAD request
uses GET as its method here, so its headers match the GET response's. The same request gets the
same generated response whatever order concurrent requests arrive in. mock names `Xoshiro256`
directly rather than `std.Random.DefaultPrng`, which is only an alias (`lib/std/Random.zig:13`) that
a later Zig may point elsewhere.

The promise covers generated data only: the same mock version, model, seed and request produce the
same generated bytes. Output may change between mock versions.

### Keys

Keys are **not** derived from the seed. Each mock makes fresh keys from `Io.randomSecure`
(`lib/std/Io.zig:2485`) and the `generateDeterministic` constructors that take a seed
(`lib/std/crypto/ecdsa.zig:318`, `lib/std/crypto/25519/ed25519.zig:319`). It does not use the
`KeyPair.generate` functions, because they draw from `Io.random` (`ecdsa.zig:329`,
`ed25519.zig:339`), which falls back to a seed made from the process id, the time and an address
when secure entropy is unavailable (`lib/std/Io/Threaded.zig:16958`, `:16967`). `randomSecure` can
fail with `error.EntropyUnavailable` or `error.Canceled` (`lib/std/Io.zig:2472`), and `init` returns
either as it came, so a cancelled `init` is not reported as missing entropy.

### The record

Every request, and every credential the identity provider issues, is recorded:

- **Requests**: sequence number, time, service, method, target, headers, body (bounded), the
  operation it matched (or why none did), the authentication outcome (scheme, subject, scopes, or
  the refusal reason), the response status, any fault applied, duration, and a state: `pending`,
  `answered`, `completed`, `dropped` or `failed`.
- **Tokens**: kind (JWT or opaque), client or user, subject, scopes, issue and expiry times, `jti`,
  and the defect it was issued with, if any.

Every string in the record is the record's own copy, model-derived names included, so a swap or a
caller freeing its model cannot leave the record pointing at freed memory.

The token store is not the record. It copies every string it keeps, as the record does, and
`clear()` does not touch it.

**Ordering guarantee.** An entry is published as `pending` as soon as its request head is accepted,
before any byte of any response, 100 Continue included; a pending entry has no status yet. It
becomes `answered`, with its status, before the first byte of the final response is written, and
`completed`, `dropped` or `failed`, with its duration, after. A connection refused before a head is
accepted (a malformed or oversized head, the connection bound, a failed spawn) gets an entry too,
published as `answered` with its status, its reason and whatever of the head was read, before its
response is written. So a test that has received any byte of a final response finds the entry with
its status, and a test that has received a 100 finds the entry, `pending` or in any later state,
since the server may move on before the test looks. Two things end the promise,
both visibly: past the record bound, entries are counted, not stored, and queries return
`error.RecordOverflow` (Bounds); and `clear()` removes every entry, in-flight ones included, after
which an update to a removed entry is discarded.

Queries (`requests`, `tokens`, `count`, each with a filter) copy their results into the caller's
allocator, so nothing a test holds can be freed under it by a later `clear`. `stats()` returns the
numbers stored and overflowed, and never fails.

### Fault injection

A fault rule matches requests (by service, operation id, or any) and applies to the next `times`
matches, or to every match until removed:

- `status`: answer with this status, body and headers instead of the normal response;
- `declared`: answer with one of the operation's declared responses (by status, and example name)
  instead of the default choice;
- `delay`: wait, then answer normally. The wait is a cancelable `Io.sleep` (`lib/std/Io.zig:2397`),
  so `stop` is never held up by it;
- `drop`: close the connection before any response, or part-way through the body.

A rule is checked when it is added: its status is 200 to 599, a 204, 205 or 304 rule has no body,
its body is within its bound (Bounds), and its headers follow the field-value grammar with no
reserved names (the response writer, above). Every applied
fault is in the request's record entry. The identity provider's token endpoint is an operation like
any other, so forcing it to answer `invalid_grant` is a `status` fault; no separate hook system is
needed.

## 4. The HTTP mock

Each request goes through the same stages, in this order, and the first that fails answers:
framing and the Host check (3), routing (4.1), authentication (5), request validation (4.4), then
the response (4.2). Authentication comes before validation, as in most servers, so a request with
no credentials gets 401 whatever its body.

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
   (RFC 9110 §9.3.2), and `Allow` then lists HEAD too.

### 4.2 Answering

On a request that passed every stage the mock picks the response:

1. A matching fault rule, if any (3, fault injection).
2. Otherwise the response the client asked for with a `Prefer` header (below), if it asked.
3. Otherwise the success response: the lowest declared 2xx status; else a `2XX` range, answered as
   200; else `default`, answered as 200. An operation with none of these is refused at load.
4. Status and content must agree, or the model is refused at load. A status mock answers with is
   200 to 599: an informational status is never a final answer, so a declared `1XX` response or a
   1xx fault status is refused at load or at `faults.add`. A 204, 205 or 304 response declares no
   content. A response with no content (those three, or no declared media type) is sent without a
   body and needs no negotiation. Otherwise the media type is the first declared one the
   `Accept` header allows (`*/*` and `type/*` honoured, `q=0` excluded); none allowed is 406.
5. The body: the example `Prefer` named, if any; else the first named example; else the schema's
   `examples`, then `default`; else a value generated from the schema (4.3). Declared response
   headers are produced the same way.

**Choosing a response with `Prefer`.** A client such as a person on an API page, or curl in a
script, can ask for a response other than success, without code. It does so with the `Prefer`
request header (RFC 7240), using the names Prism uses. mock parses the header as RFC 7240 §2 does:
preferences separated by commas, each a token with an optional value, and parameters after `;`
ignored. It acts on two preferences:
- `code=<status>` picks the operation's declared response for that status, the way 4.4 picks one:
  the exact code, else its range (`4XX`), else `default`. The status must be three digits from 200
  to 599.
- `example=<name>` picks that named example from the chosen response's media type. Without
  `code`, that is the success response.

Every other preference, such as `return=minimal`, `respond-async` or `wait`, is ignored, as RFC
7240 §2 requires. If a preference appears twice, only the first counts (RFC 7240 §2).

What `Prefer` never does:
- **It never skips a stage.** The Host check, routing, authentication and validation run first, so
  `Prefer: code=200` cannot get a request past a missing token or an invalid body.
- **It never escapes the send-time validation or `Accept` negotiation.**
- **It never overrides a fault rule.** A test's fault comes first.

An honoured preference is echoed in `Preference-Applied` (RFC 7240 §3), for example
`Preference-Applied: code=404`, and the record entry notes it. A `code` or `example` that names
nothing the operation declares, or a `code` value that is not a status from 200 to 599, is refused.
The answer is 400 with mock's own problem document, of type `preference-unsatisfiable`, which lists
the declared statuses and example names. It is never the operation's declared 400, because the
mistake is in the request to the mock, not in the request to the API. A `code` or `example` mock
cannot satisfy therefore never silently turns into a success.

That refusal is a deliberate deviation from RFC 7240, which requires a server that cannot comply
with a preference to ignore it and carry on (§2). A mock's `code` and `example` are test controls,
not hints: a test that asks for a 404 and is answered 200 because of a typo would pass for the
wrong reason. The other preferences are ignored as the RFC requires.

Because `Prefer` can change the response, every response this stage sends carries a `Vary` field
that lists `Prefer`, whether or not the request had a `Prefer` header (RFC 7240 §2 requires that),
so that a cache never answers an ordinary request with a response a preference chose. The
`preference-unsatisfiable` refusal carries it too. The field also lists `Accept` whenever step 4
negotiated, whichever way it came out: when it chose a media type the `Accept` header allowed, and
when it answered 406 because none was allowed (RFC 9110 §12.5.5). A response with no content skips
negotiation, so its field lists `Prefer` without `Accept`. If the operation declares a `Vary`
response header, mock produces its value as for any declared header, then adds its own members to
that one field where they are missing, keeping the declared ones; a declared `*` already covers
them and is left alone. The value checked against the declared header's schema is the merged one,
which is the value sent, both at load for examples and defaults and at send time (below). So a
declaration that cannot hold mock's members, such as a `const` of `Origin`, is refused at load
when its example or default shows it, and is otherwise answered 500 at send time.

**Every value sent is validated against its schema first**, whatever its source: example,
`default`, or generated, body or header. Examples and defaults are also validated when the model is
loaded, so a bad one is a load refusal; the check at send time is the boundary that holds even if
the generator is wrong. A value that fails there is not sent: the mock answers 500 with a problem
document naming the schema location. Wrong data is never served as if it were right.

### 4.3 Generating from a schema

Deterministic from the seed (3, the seed), within the generation bounds (3, bounds).

- **Objects**: required properties are always produced, and optional ones too, down to the depth
  bound. Additional properties are never produced. A required property that `properties` does not
  declare is generated from `additionalProperties` when that is a schema, and refused at load
  otherwise.
- **Arrays**: between `minItems` and `min(maxItems, minItems + 2)` items.
- **Strings** respect `minLength` and `maxLength`. **Numbers** respect the bounds and an integer
  `multipleOf`. `enum` and `const` pick from the set.
- **Composition**: `oneOf` and `anyOf` try branches in seed order until a value validates; `allOf` is
  generated only when every branch is an object schema, by merging `properties` and `required`.
- **Direction**: a `writeOnly` property is never produced in a response, and is not required there;
  a `readOnly` property is not required in a request. mock applies this, the OpenAPI 3.0 rule, as
  its own rule: OpenAPI 3.1 leaves it to tools, and it is the only reading under which a required
  `readOnly` property can be served at all.

Formats generated: `date-time`, `date` and `time` (RFC 3339), `uuid` (version 4 layout, RFC 9562),
`email` (at `example.com`, RFC 2606), `uri`, `hostname`, `ipv4`, `ipv6`, and the numeric formats
`int32`, `int64`, `float` and `double` as range limits. A string schema with any other format and no
example is refused at load: mock cannot know what a valid value looks like.

Refused at load: required properties that recurse with no way to stop within the depth bound;
`uniqueItems` over too few possible values; a minimum that exceeds a generation bound.

### 4.4 Validating a request

Path, query, header and cookie parameters, then `Content-Type`, then the body.

**Error responses.** By default a request this stage refuses is answered with the operation's own
declared response for the refusal's status (400, 413 for a request too complex to check, 415, or
422, below), found the way the OpenAPI Responses Object orders them: the exact code, else its
`4XX` range, else `default`. Its body comes from its example or is generated from its schema, so
that a client's error decoder sees the shape the API promises. When the operation declares none
of the three, the answer is an `application/problem+json` document (RFC 9457) with a
`type` tag URI (RFC 4151) such as `tag:spirefy.io,2026:mock/request-invalid`, a `title`, the
`status`, the `operation`, and an `errors` extension member listing each problem: where (`in` and a
JSON pointer), which keyword, and a message. The problem list is in the record either way.
`Options.validation_errors = .problem_document` always sends mock's own document, which is easier to
read in a script.

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
| Annotations | `readOnly` (accepted and ignored in a request body, never required there), `writeOnly` (never in a response), `default`, `examples` |

**Equality is by value**, as JSON Schema defines it, wherever `enum`, `const` and `uniqueItems`
compare instances: `1` and `1.0` are equal, and two objects with the same members in a different
order are equal. Numbers keep their source text (2) and are compared exactly, not through `f64`.

**Schema cycles.** A cycle that reaches the same schema without moving into a child of the instance
(`allOf` naming itself, directly or through `anyOf` or `oneOf`) is refused at load, since validating
it would never end. Cycles through `properties`, `items` or `additionalProperties` are fine: each
step consumes one level of the instance, and the instance depth is bounded.

**What the first slice refuses**, at load, by name: `pattern` and `patternProperties` (std has no
regular-expression engine; this is the first follow-up), `not`, `if`/`then`/`else`,
`dependentRequired`, `dependentSchemas`, `prefixItems`, `contains`, `propertyNames`,
`unevaluatedProperties`, `unevaluatedItems`, `$dynamicRef`, a `$ref` or `$recursiveRef` an adapter
left unresolved (2), and a non-integer `multipleOf`.

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

    // every variant provides:
    //   fn check(self, ctx: *const Context, req: *const RequestView) Outcome
    //   fn challenge(self, outcome: Outcome) []const u8   // a WWW-Authenticate challenge
};

pub const Outcome = union(enum) {
    absent,                        // this scheme's credential is not in the request
    malformed: []const u8,         // the request's authentication syntax is broken (see below)
    granted: Principal,            // subject, client id, scopes, token jti
    refused: Refusal,              // readable but invalid: a reason enum plus detail
};
```

A comptime check fails the build if a variant lacks either function. Adding a scheme is adding a
variant; nothing else changes. A tagged union rather than a run-time interface, because every scheme
lives in this library: there is no second implementer outside it to design for. Letting users plug
in their own scheme is a future addition (section 6).

`oauth2` and `openIdConnect` schemes in a model are **checked as bearer tokens with scopes**. For a
resource server the flow that produced a token does not matter, only whether the token is valid and
carries the scopes. So an operation protected by an authorization-code scheme is fully enforced in
the first slice; only *issuing* through that flow comes later (6), and a test can mint the token
directly meanwhile. This is the trap mock exists to avoid: a mock that accepts any
`Authorization: Bearer <anything>` passes a client that sends garbage.

**Evaluation.** Every scheme the operation's requirements name is checked once. A requirement is
satisfied when every scheme it names is granted with every scope it lists, and the operation is
allowed when any requirement is satisfied. Otherwise the answer is decided from all the outcomes
together, so every mix of credentials has one, a requirement met only in part included. The first
rule that holds decides:

1. 400 with `error="invalid_request"` (RFC 6750 §3.1) if any credential is malformed. Malformed
   means the request's authentication syntax is broken: a header repeated, the same credential in
   two places (the header and the query, say), a Basic value that is not base64 or has no colon, a
   Bearer value that is not `b64token` syntax (RFC 6750 §2.1). A Bearer value with the right syntax
   that does not decode or parse as a JWT is **not** malformed: it is a refused token (5.3), since
   RFC 6750 §3.1 gives `invalid_token` to a token that is "malformed, or invalid for other reasons".
2. 401 with `error="invalid_token"` and an `error_description` naming the reason (RFC 6750 §3) if
   any credential was refused.
3. 403 with `error="insufficient_scope"` (RFC 6750 §3.1) if some requirement has every scheme
   granted and lacks only scopes.
4. 401 with each scheme's challenge and **no** error code otherwise: every requirement lacks at
   least one credential. That includes a requirement for two API keys called with one valid key.
   RFC 6750 §3.1 asks for no error code when authentication information is absent.

Every 401 carries at least one challenge (RFC 9110 §15.5.2), one for each scheme the requirements
name: `Basic realm="mock"` (RFC 7617 §2), `Bearer realm="mock"` (RFC 6750 §3). Parameter values are
quoted strings with `"` and `\` escaped (RFC 9110 §11.2), and an `error_description` keeps to the
characters RFC 6750 §3 allows. API keys have no registered scheme, so mock sends
`ApiKey realm="mock", in="header", name="X-API-Key"` (with the scheme's own location and name). It
is mock's own, well-formed challenge syntax that clients may ignore, not an interoperable scheme.
The body is a problem document naming
the reason. A production server would say less; a test double that hides the reason only slows the
person debugging.

Comparisons of secrets: variable-length secrets (API keys, passwords, client secrets) are hashed with
SHA-256 and the digests compared with `std.crypto.timing_safe.eql`
(`lib/std/crypto/timing_safe.zig:12`); fixed-length HMAC tags are compared directly with it, after
their length is checked. On a loopback test double this defends nothing in particular, but it costs
nothing and keeps the code safe to copy.

### 5.2 The first set

- **API keys** in a header, a query parameter or a cookie, matched against `Identity.api_keys`.
- **HTTP Basic** (RFC 7617) against `Identity.users`. The credentials must be valid base64
  (`lib/std/base64.zig:37`). They are split at the **first** colon: a user-id cannot contain one, a
  password can (RFC 7617 §2). Control characters are refused; the bytes are taken as UTF-8
  (RFC 7617 §2.1).
- **Bearer** (RFC 6750 §2.1, the header form only), opaque or JWT. The shape decides which: three
  base64url parts joined by dots is a JWT and is only ever verified as one (5.3), never looked up; an
  opaque token is 32 random bytes in base64url, which has no dots. An opaque token is valid when it
  is in the token store **as an opaque token**, is not expired and is not revoked.
- **JWTs**, issued and verified, with:

  | `alg` | Primitive | std |
  |---|---|---|
  | `HS256` | HMAC-SHA-256, 256-bit secret (RFC 7518 §3.2) | `std.crypto.auth.hmac.sha2.HmacSha256`, `lib/std/crypto/hmac.zig:11` |
  | `ES256` | ECDSA P-256 with SHA-256; the signature is the 64-byte `R‖S`, not DER (RFC 7518 §3.4) | `std.crypto.sign.ecdsa.EcdsaP256Sha256`, `lib/std/crypto/ecdsa.zig:15`; `Signature.fromBytes` takes exactly the 64 raw bytes (`:126`), `verify` at `:102`, `KeyPair.generateDeterministic` at `:318`, `sign` at `:347` |
  | `EdDSA` (RFC 8037 §3.1), or `Ed25519` (RFC 9864) | Ed25519 | `std.crypto.sign.Ed25519`, `lib/std/crypto/25519/ed25519.zig:17`; `Signature.verify` at `:275`, `KeyPair.generateDeterministic` at `:319`, `sign` at `:375` |

  Base64url without padding is `std.base64.url_safe_no_pad` (`lib/std/base64.zig:74`). Its decoder
  rejects `=` and any character outside the alphabet, and rejects non-zero trailing bits
  (`:230`, `:279`), so a token has one encoding only. JSON is parsed into mock's own `Value`, which
  refuses duplicate member names and keeps numbers as text; `std.json`'s `Scanner` does the
  tokenizing (`lib/std/json.zig:69`).

  For Ed25519 mock uses `Signature.verify` (`ed25519.zig:275`), which std documents as the
  cofactored check (`:270`); RFC 8032 §5.1.7 permits it as well as the strict one (`verifyStrict`,
  `:292`). The Wycheproof run (section 8) records which way each edge case falls. Each key carries
  exactly one `alg` name. An Ed25519 key is configured as `Ed25519`, the RFC 9864 name that
  deprecates `EdDSA`, which is the default. It can also be configured as `EdDSA`, for clients whose
  libraries know only the older name. The two names use the same primitive, but they are not
  interchangeable on a token: the protected header, `alg` included, is part of the JWS signing
  input (RFC 7515 §5.1), so a token issued under one name has a different signature from the same
  token under the other, and renaming its `alg` breaks the signature. A key verifies only tokens
  whose `alg` is its own name (5.3, step 4).

  RFC 9068 requires RS256 of conforming authorization and resource servers. Until RSA signing lands
  (6), mock's JWT access tokens follow RFC 9068's format but not that requirement.

- **An OAuth 2.0 client-credentials token endpoint** (5.5). Separable: it can be deferred without
  touching the rest.

### 5.3 Verifying a JWT

Verification follows RFC 7515 §5.2 and RFC 7519 §7.2, tightened by the JWT best current practice,
RFC 8725. Each step refuses with its own reason, which goes into the 401 and the record.

1. **Shape.** Exactly three base64url parts (compact JWS). Five parts (JWE) are refused. At most
   `limits.max_token_bytes`.
2. **Header.** A JSON object. **Duplicate member names are refused** (RFC 7515 §4 allows a parser to
   keep the last one instead; refusing is the safer of the two). The same holds for the claims
   (RFC 7519 §4).
3. **`alg: none` is refused**, always, whatever the key (RFC 8725 §2.1 and §3.1; RFC 7518 §3.6).
4. **The key picks the algorithm, never the header.** The key is found by `kid`; with no `kid`,
   only a provider with a single key may verify. That key has exactly one `alg`, and the header's
   `alg` must equal it (RFC 8725 §3.1: each key is used with exactly one algorithm). This is what
   defeats alg/key-type confusion, where an attacker signs `HS256` using an ES256 public key's bytes
   as the HMAC secret. Unknown `kid`: refused.
5. **`crit` is refused if present**, and so is a `b64` member whatever its value. RFC 7515 §4.1.11
   requires refusing a token whose `crit` lists an extension the recipient does not understand, and
   mock understands none. Refusing `b64` (RFC 7797) outright is mock's own policy, narrower than
   RFC 7797, which permits it under `crit`: it leaves no reading in which a payload is signed
   unencoded. Presence is what is tested: a member whose value is `null` counts as present.
6. **`jku`, `x5u`, `jwk` and `x5c` are never used** to find or fetch a key (RFC 8725 §3.10). Keys
   come only from the provider.
7. **`typ`** must be `at+jwt` or `application/at+jwt`, compared without regard to case (RFC 9068 §4;
   explicit typing, RFC 8725 §3.11), so that another kind of JWT, such as a future ID token, cannot
   be replayed as an access token (RFC 8725 §3.12).
8. **Signature.** HS256: recompute the HMAC and compare with `timing_safe.eql`. ES256: the signature
   must decode to exactly 64 bytes; a DER signature is refused, not converted. Ed25519, under
   either name: 64 bytes, `Signature.verify`.
9. **Claims** (RFC 7519 §4.1, RFC 9068 §2.2): `iss`, `exp`, `aud`, `sub`, `client_id`, `iat` and
   `jti` must be present, with the right types: strings, and `aud` a string or an array of strings.
   `iss` equals the provider's issuer exactly; `aud` contains the service's audience exactly
   (RFC 8725 §3.9); `exp` is in the future and `nbf`, if present, is not, both by the identity
   clock (5.7). `exp`, `nbf` and `iat` must be JSON numbers (RFC 7519 §2 NumericDate); strings are
   refused. Clock leeway defaults to zero and can be set.
10. **Revocation.** A `jti` in the revoked set is refused.
11. **Scopes** from the space-separated `scope` claim (RFC 9068 §2.2.3) are checked against the
    requirement.

Issued JWTs carry `typ: at+jwt`, `kid`, and the RFC 9068 §2.2 claims: `iss`, `exp`, `aud`, `sub`,
`client_id`, `iat`, `jti`, and `scope` when there are scopes.

### 5.4 Bad credentials on purpose

`idp.issue(.{ .client = "svc", .scopes = ..., .defect = .expired })` mints a token in code. The same
path with `defect` set produces a token wrong in exactly one way. The verifier's refusal names the
class in the last column; two defects share `signature_invalid`, because a verifier cannot tell a
flipped bit from a key it does not hold.

| Defect | Applies to | What is wrong | Refused as |
|---|---|---|---|
| `expired` | JWT, opaque | `exp` 60 s further in the past than the configured leeway | `expired` |
| `not_yet_valid` | JWT | `nbf` 60 s further in the future than the leeway | `not_yet_valid` |
| `wrong_issuer` | JWT | `iss` is not the provider's | `wrong_issuer` |
| `wrong_audience` | JWT | `aud` is a value no service accepts | `wrong_audience` |
| `bad_signature` | JWT | one bit of the signature flipped | `signature_invalid` |
| `untrusted_key` | JWT | signed by a key the provider does not hold, under a `kid` it does | `signature_invalid` |
| `missing_scope` | JWT, opaque | one requested scope left out; needs at least one requested scope | `insufficient_scope` (403), on an operation whose requirement demands the left-out scope |
| `revoked` | JWT, opaque | issued, then its `jti` revoked | `revoked` |
| `alg_none` | JWT | unsigned, `alg: none` | `alg_none` |
| `wrong_typ` | JWT | `typ: JWT` instead of `at+jwt` | `wrong_typ` |
| `unknown_kid` | JWT | `kid` names no key | `unknown_kid` |

Asking for a defect that does not apply (an opaque `alg_none`, a `missing_scope` with no scope) is an
error, not a good token. A `missing_scope` token is wrong only where the left-out scope is required;
on any other operation it is a good token, so a test presents it where that scope is demanded.
A client configured with a `defect` gets tokens with that defect from the
token endpoint, so a system that fetches its own token can be tested against a bad one. Defective
tokens are recorded with their defect. They serve two kinds of test: a server under test that must
refuse them (it verifies with the provider's keys, 5.6), and mock's own verifier, which must refuse
every one of them with the class above (section 8).

### 5.5 The client-credentials token endpoint

RFC 6749 §4.4, on the provider's own listener at `/token`:

- `POST`, `application/x-www-form-urlencoded`, `grant_type=client_credentials`, optional `scope`.
  A parameter sent twice is `invalid_request`, an empty one counts as absent, and unknown ones are
  ignored (RFC 6749 §3.1, §3.2).
- Client authentication by HTTP Basic (`client_secret_basic`) or in the form body
  (`client_secret_post`), RFC 6749 §2.3.1. For Basic, the user-id and password are each
  form-urlencoded before base64, so mock splits first and form-decodes each part after: client
  `a:b` with secret `x+y` arrives as the Basic credentials of `a%3Ab:x%2By`. Both methods at once is
  `invalid_request`. Since the credentials may be in the body, `Expect: 100-continue` is answered
  here before the client is authenticated (3).
- Success (§5.1): `access_token`, `token_type: "Bearer"`, `expires_in`, `scope`, with
  `Cache-Control: no-store` and `Pragma: no-cache`. The requested scopes must be a subset of the
  client's; none requested means all of them.
- Errors (§5.2) as an OAuth error object: `invalid_request`, `invalid_client` (401, with a challenge
  when Basic was used), `unsupported_grant_type`, `invalid_scope`. Any other error, such as
  `unauthorized_client` or `invalid_grant`, is produced with a fault rule.
- RFC 6749 requires TLS on the token endpoint. The first slice serves it over plain HTTP on
  loopback, a deliberate test-only deviation until the TLS server lands (6).

It is a module of its own on top of the issuer, and it is in the first slice: a client under test
fetches its token the way it would in production. `idp.issue` also mints tokens in code.

### 5.6 What the provider exposes

- `idp.jwks(allocator)`: the **public** keys as a JWK Set (RFC 7517; OKP keys as in RFC 8037 §2),
  for a server under test or an outside verifier. HS256 secrets are never in it. Serving it over HTTP
  comes with OpenID Connect discovery (6).
- `idp.hmacSecret(kid)`: an HS256 key is a shared secret, so a server under test that verifies HS256
  needs it, and gets it only by asking for it in code.
- `idp.revoke(jti)` (an unknown `jti` is `error.UnknownToken`), `idp.tokenUrl()`.
- `idp.clock`: the identity clock (5.7).

### 5.7 The identity clock

Every time the identity provider reads comes from one clock:
- `iat`, `nbf` and `exp` when it issues a token;
- `expires_in` at the token endpoint;
- the `exp` and `nbf` checks when it verifies a JWT;
- expiry of an opaque token;
- the issue and expiry times in the record's token entries.

A test can move that clock, so it can make a token expire without waiting for it.

- `Options.clock` is `.real` by default: the system's real-time clock plus an offset that starts at
  zero. `.{ .manual = t }` instead freezes the clock at `t` seconds since the Unix epoch, and it
  then moves only when the test moves it. A frozen clock makes every `iat`, `nbf` and `exp` exact,
  so a test can assert those values exactly. It does not make whole tokens repeatable: each token's
  `jti` is unique to it (RFC 7519 §4.1.7) and each mock makes fresh keys (3, keys), so a test
  compares claims, not token bytes.
- `idp.clock.advance(seconds)` adds to the offset (`.real`) or to the frozen time (`.manual`). The
  number may be negative, so a test can step back to check `not_yet_valid`. `idp.clock.set(t)`
  makes the clock read `t` at that instant, keeping its mode: a `.manual` clock stays at `t`, and a
  `.real` clock takes the offset that makes it read `t` then and goes on ticking from there.
  `idp.clock.now()` reads it.
- A move that would leave the clock before the epoch, or after 253402300799 (the last second of
  year 9999), is refused with `error.ClockOutOfRange`, and the clock is unchanged. That bound keeps
  every `exp` mock writes inside the range of a JSON number that clients read exactly.
- A `.real` clock can still leave the range after a move, because real time runs on: one `set` to
  the last second reads past it a second later. The system clock can be out of range by itself
  too. So every read is checked against the same bound. Out of range, `now()` returns
  `error.ClockOutOfRange`, and so does `idp.issue`. A request that needs the time, at the token
  endpoint or to check a token, is answered 500 with mock's problem document of type
  `clock-out-of-range`, and the record notes it. The check is arithmetic on the one reading, so it
  never blocks, and no token is issued or accepted on a time outside the range.
- `init` refuses a `.manual` start outside that range with the same error.
- The mode is fixed at `init`, and the clock's state is one atomic word: the offset or the frozen
  time. So a test thread may move the clock while requests are being served. Each request reads it
  once, when it issues or verifies a token, and uses that reading throughout.
- The clock is kept across a swap, like the provider's keys.

Only identity times follow it. Socket timeouts, the idle and blocked-write sweeper, fault delays,
request durations and the request entries' times stay on real time. Moving the identity clock can
therefore never stall or speed up the server itself.

## 6. Staging

Each item lands **when a conformance test needs it**, not before. Each needs:

| Item | Needs |
|---|---|
| `pattern`, `patternProperties` | A regular-expression engine for the ECMA-262 dialect JSON Schema uses. std has none, and the survey found no ECMAScript-compatible engine in Zig (Borrowing candidates). Also generation of strings that match. |
| RS256, PS256 | RSA key generation and signing. std verifies only: `lib/std/crypto/Certificate.zig:945` has `rsa.PKCS1v1_5Signature.verify` (`:1125`) and `PSSSignature.verify` (`:962`), no signing and no key generation. Generating keys means prime generation on top of `lib/std/crypto/ff.zig`. |
| Authorization code with PKCE (RFC 7636), refresh tokens (RFC 6749 §6), device code (RFC 8628), introspection (RFC 7662), revocation (RFC 7009) | Headless approval: an authorization request is approved as the test user the test picks. Client registration with redirect URIs. Mostly HTTP and the existing issuer. |
| OpenID Connect: discovery, JWKS over HTTP, ID tokens, userinfo | The above, plus `nonce` and ID-token claims. |
| TLS server; HTTPS listeners | A TLS 1.3 server. std has a client only (`lib/std/crypto/tls.zig:39`). |
| Mutual TLS (RFC 8705) | The TLS server, plus a small X.509 issuer to make client certificates. std's `lib/std/crypto/Certificate.zig` parses (`:422`) and verifies (`:551`) but does not build certificates. std does encode DER (`std.crypto.codecs.asn1.der`, `lib/std/crypto/codecs/asn1/der.zig:19`), so the issuer is a certificate builder on top of it. |
| SASL for the brokers: PLAIN (RFC 4616), SCRAM-SHA-256 (RFC 7677) and SCRAM-SHA-512 (RFC 5802 mechanism), OAUTHBEARER (RFC 7628) | The broker it runs in. SCRAM uses std's PBKDF2 (`lib/std/crypto/pbkdf2.zig`) and HMAC; OAUTHBEARER reuses the bearer verifier. |
| SAML 2.0 SSO and WS-Security for SOAP | An XML parser (std has none), exclusive XML canonicalization (W3C xml-exc-c14n), XML-DSig, RSA signing (above) and the X.509 issuer (above). In memory, good enough for an API client or service to work against; not an enterprise IdP. |
| Custom auth schemes | A run-time interface beside the scheme union, so a user can plug in code for a scheme OpenAPI cannot describe, such as a signed request (the whole request signed with a shared secret, the signature in a header). Such schemes reach mock today as API-key headers, which the first set already checks. A future addition, made when a user needs it. |
| Protocols, in order | HTTP; then WebSocket (RFC 6455, on mock's own HTTP framing; the handshake needs only std's SHA-1 and base64, and mock adds the Host and Origin checks and bounded frames); MQTT 3.1.1, then 5.0; AMQP 0-9-1; Kafka; SOAP 1.1 and 1.2 (the XML parser above); later GraphQL and gRPC (gRPC needs HTTP/2, which std does not serve). |

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

mock takes no code from its maintainers' closed-source projects. Code that is not borrowed under
the policy above is written fresh in this repository.

### Borrowing candidates

A survey of open-source Zig code, read on 2026-10-11 and 2026-10-12. **These are leads, not
verdicts.** Licenses come from the GitHub API and the head of each LICENSE file. "Zig 0.16" means
the project declares it in `build.zig.zon` or CI; nothing was built. Test counts are counts of
`test` declarations. Conformance claims are each project's own and were not reproduced.

**The real check happens at borrow time.** Before anything is copied, at a pinned commit:

- Read the terms that apply to each file we take: the root `LICENSE`, any license or `NOTICE` in
  the module or directory that holds it, the file's own header, and the terms of any third-party
  code or test vectors inside it. Repository metadata does not settle this.
- Where the terms offer a choice (`Apache-2.0 OR ISC`), record the license we take it under.
- Fulfil every condition those terms set, attribution conditions in a module's `NOTICE` included,
  and ship the license texts they require.
- Record the URL, the commit, the files and the license in our `NOTICE`; carry the file's own
  notice into its header with a line on what changed; and carry an Apache-2.0 source's `NOTICE`
  text into ours, as above.

Borrowed code then meets section 8 like our own. The stars, contributor counts and test counts in
the tables are context for choosing where to look, not reasons to borrow.

Two facts shape every row:

- Zig 0.17.0 was released on 2026-10-01 and many upstream main branches have moved to it. mock
  targets 0.16, so code from a 0.17-only source must be ported back. Some projects keep a 0.16
  branch; it is named where they do.
- zaxified/zig-libs (MIT, 246 modules, minimum Zig 0.16.0) appears in many rows. It says it is
  written by AI with no third-party review or audit, and the NOTICE files of its `jwt`, `regex`,
  `webauthn` and `openapi` modules carry attribution conditions. Code from it is something to adapt
  under our own oracles, never evidence that anything is correct.

**First slice**

| Upstream | License | What we would adapt | Why | Caveat |
|---|---|---|---|---|
| karlseguin/http.zig, branch `zig-0.16.0` | MIT | Reference only: connection handling and limits | mock writes its own framing (3); this is a mature design to compare its connection handling and limits against | 50 contributors; we do not plan to copy it |
| zaxified/zig-libs `jwt` | MIT | JWS encoding and verification structure, RFC vectors | Its encoder takes `alg` from the key and never emits `alg: none`, as 5.3 requires; 158 tests | AI-written, unaudited; its vectors file carries a NOTICE condition; no JWK Set writer was seen in its root file |
| ChristianPresley/zig-sdk, `src/mcp/auth/authorization_server.zig` | Apache-2.0 | The token endpoint's request parsing and error responses (5.5) | The only licensed Zig 0.16 authorization server found; 2,091 lines, 20 tests | Coupled to an MCP SDK; one contributor |
| C2SP/wycheproof | Apache-2.0 | Test vectors (section 8) | Independent negative cases for ECDSA P-256, Ed25519 and HMAC | Vectors, not code |
| h0rv/jsonschema.zig | MIT | Schema validation (4.4) | Claims JSON Schema 2020-12 with the full JSON-Schema-Test-Suite passing; the suite itself is an oracle we should run too | Claim not reproduced |

The signature primitives are std's (5.2), so nothing is borrowed for them.

**Later stages**

| Stage | Upstream | License | What we would adapt | Caveat |
|---|---|---|---|---|
| RSA signing and key generation | zaxified/zig-libs `rsa` | MIT | PKCS#1 v1.5 and PSS signing, key generation, a self-signed certificate | AI-written; known-answer tests from OpenSSL; 4096-bit cap |
| | ianic/tls.zig `src/rsa`, branch `zig-0.16.x` | MIT | CRT signing | |
| | NerdMeNot/parley `provider/rsa.zig` | Apache-2.0 OR ISC | RSA provider | See parley below |
| TLS server, mTLS | NerdMeNot/parley | Apache-2.0 OR ISC | TLS 1.2 and 1.3 server with client certificates | Claims BoGo, Wycheproof and interop; 239 tests; one contributor, no stars, a single push (2026-05-25) |
| | ianic/tls.zig, branch `zig-0.16.x` | MIT | TLS 1.3 server with a `client_auth` option | TLS 1.3 only; tlsfuzzer scripts; 11 contributors |
| | mattrobenolt/ztls | Apache-2.0 | Sans-I/O TLS 1.3 client and server with client certificates | Pre-alpha; about 1,000 tests |
| X.509 issuance | (ours, on std) | | A certificate builder on `std.crypto.codecs.asn1.der` (`lib/std/crypto/codecs/asn1/der.zig:19`) and `Oid` | The survey found no complete builder; the fragments below help |
| | kacy/yoq `src/tls/x509_gen.zig`, `csr.zig` | MIT | An ECDSA P-256 CA and a leaf it signs | Fragment |
| | techsaint/zig_iroh `acme/x509.zig` | Apache-2.0 | A DER writer and CSR, ECDSA | Fragment |
| XML | ianprime0509/zig-xml | 0BSD | Parser | Seven contributors, a W3C xmlconf runner, fuzzing; no DTD support |
| | zaxified/zig-libs `xml` | MIT | Namespace-aware parser that refuses DOCTYPE, never expands entities, and has limits | AI-written |
| Exclusive C14N, XML-DSig | zaxified/zig-libs `xmldsig` | MIT | Canonicalization and verification | Verifies only; the survey found no signing or XPath, so we expect to write them |
| SAML | (ours) | | An identity provider | The survey found no Zig SAML IdP; zig-libs `saml` is service-provider side only |
| SCRAM | securemessage/xmppd `lib/sasl/scram.zig` | BSD-2-Clause | Server and client, channel binding, SASLprep with NFC tables | SHA-1 and SHA-256 only; Zig 0.15.2+ per its README |
| | meszmate/smtp.zig `src/auth/scram.zig` | MIT | SHA-256 with RFC 7677 vectors | |
| | mattrobenolt/kafka-zig `src/scram` | Apache-2.0 | SHA-256 and SHA-512 | Client only; Zig 0.15.2 |
| WebSocket | karlseguin/websocket.zig, branch `zig-0.16.0` | MIT | Framing and limits | Has an Autobahn directory |
| | zaxified/zig-libs `websocket` | MIT | Framing | AI-written; claims Autobahn |
| MQTT broker | zaxified/zig-libs `mqtt` | MIT | 3.1.1 and 5.0, QoS 0 to 2, sessions, shared subscriptions | AI-written; 205 tests; claims Mosquitto and Paho as oracles |
| | electricalgorithm/protomq | MIT | Trie-based wildcard routing | Zig 0.15.2 |
| Kafka | mattrobenolt/kafka-zig | Apache-2.0 | `src/testing/mock_broker.zig`, an in-process mock broker (ApiVersions, Metadata, Produce, SaslHandshake, SaslAuthenticate, SCRAM-SHA-512 server side); the codecs in `src/wire` | The closest thing to mock in Zig, for one protocol |
| | kay-kewl/samsa | MIT | The approach: protocol structs generated from Kafka's JSON message schemas | Worth copying as a method |
| AMQP 0-9-1 | malcolmstill/zig-amqp | BSD-3-Clause | The frame codec | Zig 0.13; the survey found no Zig broker, so the broker is ours |
| `pattern` | zoptia0regex | Apache-2.0 | A linear-time regular-expression engine | RE2-class, not ECMAScript-compatible; the survey found no ECMAScript-compatible engine in Zig, so the dialect gap must be closed or refused by name |
| HTTP/2, gRPC | zaxified/zig-libs `grpc`, `http`; Arwalk/zig-protobuf (tag `zig-0.16.0`, claims the protobuf conformance suite); hendriknielaender/http2.zig; zoxy-io/hpack; c4milo/colibri (h2spec 144 of 146) | MIT, MIT, MIT, MIT, Apache-2.0 | Held until gRPC is scheduled | |
| GraphQL | none | | | The survey found no licensed Zig 0.16 validator or executor |
| Deterministic tests | zaxified/zig-libs `simio` | MIT | A deterministic `std.Io` with virtual time, for testing timeouts and the sweeper | AI-written |

**Not usable**

- AGPL or GPL, so never copied: onyx-server `x509_selfsign`, ArmorTLS, NefixEstrada's zig-rsa and
  zig-scram, balehu86/mqtt-zig, wolfSSL, mockery.
- No license, so never read for implementation: ibd1279/oauth2 (its test server is the closest
  feature match to mock's identity provider), chy3xyz/zgraphql, GrayHatter/mqtt, kabelweb, thinDB,
  bunny-zig, klog.
- MPL-2.0, held for the maintainer's decision: nektro/zig-xml, tardy-org/zzz,
  hyperpolymath/proven-servers.

## 8. How it is checked

Unit tests prove the code does what its authors meant. They cannot prove the authors read the spec
right, so behaviour is also checked against software we did not write. The checks are shell scripts
and Zig tests only: no Python anywhere in the build, the tests or the tooling.

### The oracles

- **curl**, a transport and an independent HTTP client. It sends the requests and the scripts
  compare statuses, headers and bodies with what the design says: routing and 405, the Host check
  (`curl -H 'Host: evil.example'` must get 421), framing refusals, Basic and API keys, and every
  defective token (5.4) presented to a protected operation, which must get 401 or 403 with the
  matching reason. It also presents tokens mock never issued and so holds nothing about, made by the
  script itself: a hand-encoded `alg: none` token, a token step signs with a key mock does not
  hold, and a good token with one character changed. curl decides nothing about schemas; it only
  carries what mock answered.
- **JSON-Schema-Test-Suite** (MIT), as a Zig test: every case for a keyword mock supports must give
  the suite's answer, through the same validator the server uses. Cases for refused keywords, and
  for refused forms of a supported one (a non-integer `multipleOf`), must be refused at load and are
  counted as such, not as passes. This is the independent check of the validator, including
  value equality
  (`uniqueItems` with `1` and `1.0`, objects in a different member order).
- **step** (`step crypto jwt verify --key <public JWK> --iss <issuer> --aud <audience>`), for the
  ES256 and EdDSA tokens the mock issues, each verified with its own key's public JWK file (one key
  per file, not the set). For step, the script configures a second Ed25519 key under the `EdDSA`
  name, which step knows, and has mock issue and sign tokens with that key; an `Ed25519` token is
  never relabelled, since that would break its signature (5.2). Tokens from a key under the default
  `Ed25519` name are checked by openssl, which verifies the signature over the signing input
  whatever the header says, and by mock's own test, which checks their header against RFC 9864.
  Whether step accepts the newer name has not been checked. HS256 tokens are not
  given to step, since no public key verifies them;
  openssl checks those. Opaque tokens are not JWTs and go to neither. A good token must verify.
  Of the defective ones, step is expected to reject
  `expired`, `not_yet_valid`, `wrong_issuer`, `wrong_audience`, `bad_signature`, `untrusted_key` and
  `alg_none`, and to accept `missing_scope`, `revoked`, `wrong_typ` and `unknown_kid`: it knows
  nothing of scopes or revocation, does not check `typ`, and with a key given directly does not look
  at `kid`. These expectations are confirmed on the script's first run and written into it; a change
  in step's behaviour then fails the check instead of passing silently. A token whose payload or
  signature the script changes by one character must fail.
- **openssl**, a second signature check over the token's signing input: for HS256 the script
  computes the MAC with `openssl dgst -sha256 -mac HMAC -macopt hexkey:<key>` and compares it with
  the token's signature; for Ed25519, under either name, it runs `openssl pkeyutl -verify -rawin`
  with `-pubin` and the public key as PEM, over the signing input's exact bytes. Both must agree
  with mock on good and tampered tokens.
- **Published vectors**, as Zig tests at the JWS layer:
  - RFC 7515 Appendix A.1 (HS256) and A.3 (ES256) must verify; A.5, an unsecured JWS, must be
    refused under mock's `alg: none` rule;
  - RFC 8037 Appendix A.4 (Ed25519): Ed25519 signatures are deterministic, so mock must produce the
    published signature byte for byte, and verify it;
  - RFC 7520 §4.4 (HS256). RFC 7518 defines the algorithms but publishes no JWS signature examples.
  - Wycheproof (Apache-2.0): the P-256 ECDSA vectors in IEEE P1363 form, which is exactly JWS's
    `R‖S`; the Ed25519 vectors; the HMAC-SHA-256 vectors. Every `valid` case must verify and every
    `invalid` case must be refused. Cases Wycheproof marks `acceptable` are pinned to the result
    std's cofactored Ed25519 check gives, which is mock's policy (5.2), so a change in any of them
    fails the test.

The scripts drive a small example program (`examples/serve.zig`) that builds a fixture model,
starts a mock, prints its ports, writes the public JWK Set, each public key as its own JWK file and
as PEM, the HS256 secret and a token of every kind to an output directory, and stops when its
standard input closes.
A missing tool fails the check with its name; it is never skipped silently.

### Plants

A plant is a defect injected on purpose to show that a check can fail. Each check below names the
plant it must turn red; a check never seen red is not trusted. Each plant changes one thing in an
otherwise valid fixture, and is asserted at the public boundary (an HTTP response, or the verifier's
entry point), not inside a helper, except where a row says why it cannot be.

| Plant | Must be caught by |
|---|---|
| Verification accepts a wrong signature (the comparison is skipped) | The `bad_signature` and `untrusted_key` unit tests; Wycheproof `invalid` cases; the curl script presenting those tokens. |
| `alg: none` accepted | RFC 7515 A.5; the `alg_none` unit test and curl case. |
| The header's `alg` chooses the verification (an HS256 token keyed with the ES256 public key's bytes is accepted) | An alg-confusion unit test that builds exactly that token. |
| `crit` or `b64` ignored | Tokens carrying `crit: ["x"]`, and `b64: false` without `crit`, must be refused. |
| `exp` or `aud` not checked by the verifier | The `expired` and `wrong_audience` unit tests and curl cases. (step checks only the issuer side, so it cannot catch this plant.) |
| Shape dispatch removed, so a JWT-shaped bearer credential is looked up in the token store | An `alg_none` JWT placed in the token store as an opaque token, presented through the bearer entry point, must be refused. |
| The opaque check ignores expiry or revocation | An expired and a revoked opaque token, presented through the bearer entry point, must be refused. |
| The token store's kind check removed | A unit test at the store's lookup with a JWT-kind entry. This is the one plant asserted below the public boundary: while shape dispatch holds, no HTTP request reaches the kind check. The check stays as armor, with that argument written beside it in the code. |
| A partly met requirement granted, or left without an answer | An operation requiring two API keys, called with one valid key: 401 with both challenges and no error code. |
| A JWT that does not parse is answered 400 | A Bearer value of three base64url parts whose header is not JSON must get 401 `invalid_token`. |
| A chunk size accepts a letter outside hex | A chunked request whose size line is `G` must get 400 and a closed connection. |
| 100 Continue at the token endpoint waits for authentication | curl with `client_secret_post`, `Expect: 100-continue` and an expect timeout longer than the test's time limit must get its token within that limit. |
| A declared `default` error shape ignored | An invalid body sent to an operation that declares only 200 and `default` must get the `default` shape. |
| Routing ignores the method | `curl -X DELETE` on a GET-only path must get 405 with `Allow: GET, HEAD`; the router unit test. |
| The most-literal rule reversed | `/pets/mine` must reach its own operation, not `/pets/{petId}`. |
| The Host check disabled | `curl -H 'Host: evil.example'` must get 421; an absolute-form target naming `evil.example` must get 421 too. |
| A GET's `Content-Length` body is not consumed | A GET with a body followed on the same connection by a second request: the second must be answered as itself, not parsed from the first one's body. |
| The record drops entries past its bound silently | Fill the record to its bound plus one: the query must return `error.RecordOverflow`, not the first N entries. |
| The connection bound not enforced | Hold the bound's number of connections open, each confirmed accepted by its `pending` record entry; one more must get 503. |
| `stop` waits on a client that never reads | On a deterministic test `Io` whose write blocks by construction, a client that never reads and a hook that signals the response write is blocked; only then is `stop` called, and it must return within the test's time limit. The same test on a real socket, with a body several times the two sockets' buffer sizes as the system reports them (and `limits` raised to allow it), is a smoke test only: it cannot prove the write had blocked. |
| `deinit` takes the lifecycle lock again through `stop` | A started mock passed to `deinit` without a `stop` first must return within the test's time limit. The limit is enforced by a watchdog outside the call, never by the blocked call itself. |
| A cancelled lock acquisition treated as taken | A `stop` holds the lifecycle lock, blocked on a test hook, and a `swapModel` waiting for the lock is cancelled. The `swapModel` must return `error.Canceled`, and the old model must still serve. A second lifecycle call made meanwhile must stay blocked until the `stop` returns, which shows the lock was never released by the cancelled call. The hook is released independently of the cancelled call. |
| Cleanup that stops at a cancellation | Cancel the task that calls `stop` on a running mock with open connections, both while it waits for the lock and while it shuts sockets down. `stop` must still return with every socket in the live-connection table shut down and every task awaited. The plant removes the cancel protection, and the test then sees a socket left open or a task left running. |
| The verifier reads the real clock instead of the identity clock | Issue a one-hour token, `idp.clock.advance(3601)`, and present it: it must be refused as `expired`. The plant makes the verifier read the real clock, and the test then sees 200. A `.manual` clock frozen at `t` must issue a token whose `iat` is exactly `t`. |
| A clock move leaves the range | On a `.manual` clock, so that nothing else moves it, `advance` past year 9999, or `set(-1)`, must return `error.ClockOutOfRange` and leave `now()` unchanged. The plant removes the move's range check, and the move then succeeds. |
| A `.real` clock read past the bound is used | On a test `Io` whose real-time clock the test steps, `set` the identity clock to the last second of year 9999 and step real time by two seconds: a request to the token endpoint must get 500 of type `clock-out-of-range`, and `idp.issue` must return `error.ClockOutOfRange`. The plant removes the read check, and the test then sees 200 and a token whose `iat` is past the bound. |
| `Prefer` ignored | `curl -H 'Prefer: code=404'` on an operation that declares a 404 must get that response, with `Preference-Applied: code=404`. The plant ignores the header, and the test then sees 200. |
| `Prefer` read too loosely | `Prefer: return=minimal` alone must change nothing. `Prefer: code=418` on an operation with no `4XX` or `default` must get 400 of type `preference-unsatisfiable`, not a success and not the operation's declared 400. |
| `Prefer` applied before authentication | `Prefer: code=200` without credentials on a secured operation must still get 401. The plant sends the preferred response as soon as `Prefer` is read, before authentication runs, and the test then sees 200. |
| `Vary: Prefer` missing | A request with no `Prefer` header must get a response whose `Vary` lists `Prefer`. On an operation that declares a `Vary: Origin` response header, the response must carry one `Vary` field listing `Origin` and `Prefer`. A request whose `Accept` allows none of the declared media types must get 406 with `Vary` listing `Accept`. The plant drops mock's members, and a cache keyed without `Prefer` would then serve a preferred 404 to an ordinary request. |
| A declared `Vary` validated before mock's members are added | An operation that declares a `Vary` response header whose schema is a `const` of `Origin`, with the example `Origin`, must be refused at load. The plant validates the value before the merge, and the model then loads and sends `Origin, Prefer`, which its own schema forbids. |
| A value is sent without the final validation | A unit test that hands the send boundary a value its schema forbids must get 500. The plant removes that check; the test then sees a 200. |
| Equality by source text (`[1, 1.0]` passes `uniqueItems`) | The JSON-Schema-Test-Suite `uniqueItems` cases. |

### What each oracle cannot see

- **curl** sees one client's view of the wire. It cannot see the record, ordering under concurrency,
  or bounds that need many connections; those are Zig tests, written by us.
- **JSON-Schema-Test-Suite** checks the validator, not the generator, the parameter decoding, or
  the OpenAPI-specific rules (`readOnly`, `writeOnly`, the directional `required` rule in 4.3).
- **step** verifies signature, `iss`, `aud`, `exp` and `nbf` of the ES256 and EdDSA tokens mock
  **issues**. It does not test mock's **verifier** or HS256 tokens, and it cannot see scopes,
  revocation, `typ` or `kid`.
- **openssl** checks signatures only, not claims or the JOSE header.
- **RFC vectors** are few and mostly well-formed; only A.5 is a negative case.
- **Wycheproof** tests the signature primitives and our encoding of them (`R‖S`, base64url). It cannot
  see JWT header or claim logic.
- **Our unit tests** share our reading of the specs. They are the only check for the record, faults,
  bounds, framing edge cases and auth evaluation until a broker or identity-provider oracle covers
  them.

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
  http/wire.zig          request parsing, body framing, response writing (3)
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
tests/vectors/           RFC, Wycheproof and JSON-Schema-Test-Suite vectors, credited
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
    defer diag.deinit(std.testing.allocator);
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
    /// `gpa` must be thread-safe (3, threading).
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
    validation_errors: enum { declared_or_problem, problem_document } = .declared_or_problem,
    clock_leeway_s: u32 = 0,
    clock: union(enum) { real, manual: i64 } = .real,  // the identity clock (5.7)
    limits: Limits = .{},
};
```

`Diagnostics` carries the load report, because a Zig error carries no payload.

## 10. Decisions by the maintainer

The design's open questions, as the maintainer answered them on 2026-10-12:

1. **The client-credentials token endpoint ships in the first slice** (5.5).
2. **A request refused by validation is answered with the API's own declared error shape by
   default**, and with mock's problem document only when the operation declares none (4.4). A mock
   that answers in the API's shape lets that shape be tested, and fixed where it is wrong.
   `.problem_document` remains an option. Refusals from other stages keep their own rules: a failed
   credential is a 401 with a challenge and mock's problem document (5.1), and a `Prefer` the mock
   cannot satisfy is a 400 with mock's problem document (4.2).
3. **Custom auth schemes are left out for now** and recorded as a future addition (6).
4. **There is a settable test clock**, so a test never waits for a token to expire (5.7).
5. **A swap that adds or removes a service is refused** (2).
6. **`Ed25519` is the default name** for Ed25519 keys, with `EdDSA` as an option (5.2).
7. **A client may choose a response with `Prefer`** (4.2).

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
- **Wycheproof** (Apache-2.0) supplies the signature test vectors, and **JSON-Schema-Test-Suite**
  (MIT) the schema vectors.
- **In Zig**, the library survey (Borrowing candidates) found no general mock library. The nearest
  is mattrobenolt/kafka-zig's in-process mock Kafka broker, for its own tests.

Design review records are in [design-review.md](design-review.md).
