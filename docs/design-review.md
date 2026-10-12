# mock: design review record

Every adversarial review pass over [design.md](design.md) is recorded here: the commits it
reviewed, the reviewing model as its log names it, its verdict, and what was done with each
finding. A finding is a claim to be checked, not a verdict: each one is checked against the
reviewed commit and the Zig 0.16.0 standard library before it is accepted, and is marked

- **CONFIRMED-BY-READING**: the citation and the reasoning hold when read;
- **PARTIAL**: the mechanism is real, but the severity or the scope is not;
- **REFUTED**: with the evidence that refutes it.

The review is of a design, so nothing here is confirmed by measurement: no code exists yet.

## Pass 1

- Reviewed: `08379e4` (the first draft), read-only.
- Model: `gpt-6.1-sol`, reasoning effort `max`.
- Verdict: **REWORK** — "correct the HTTP wrapper, ownership and resource contracts, credential
  validity rules, and mutation-test gaps before implementation."
- Fixed in the commit that follows this record.

| # | Sev. | Finding (short) | Disposition and evidence | Change |
|---|---|---|---|---|
| F1 | HIGH | `std.http.Server` body framing is wrong for mock: GET/DELETE bodies are left unread and become the next request; an unframed POST reads to EOF | CONFIRMED-BY-READING: `http/Server.zig:591-596` returns an empty reader when `requestHasBody()` is false; `:636` marks the connection ready without discarding; `http.zig:457-459` returns the raw stream | mock owns HTTP/1.1 framing (3) |
| F2 | MED | `Content-Length` accepts `+10` and `1_0` | CONFIRMED-BY-READING: `http/Server.zig:154` uses `parseInt`; `fmt.zig:329` accepts `+`, `:442` skips `_` | Own parser, digits only (3) |
| F3 | HIGH | A 413 is sent only after the oversized body is drained | CONFIRMED-BY-READING: `respond` calls `discardBody` (`http/Server.zig:350`), which reads the whole body (`:618-633`) | Answer early, `Connection: close` (3) |
| F4 | HIGH | Head strings are invalidated when the body is read; records must own their strings | CONFIRMED-BY-READING: `http/Server.zig:594`; the draft said nothing about record ownership | Head copied first; record owns every string (3) |
| F5 | MED | 100 Continue precedes the record entry; the entry's duration cannot exist before the response | CONFIRMED-BY-READING: `http/Server.zig:577-581`; the draft listed duration in an entry published before the response | `pending` / `answered` / final states; `clear` semantics (3) |
| F6 | HIGH | Spawning a connection task can fail after a successful start | CONFIRMED-BY-READING: `Group.concurrent` returns `ConcurrentError` (`Io.zig:1261`) | Spawn failure answered 503 and recorded; accept loop never exits on it (3) |
| F7 | HIGH | Sweeper lifecycle and socket ownership unspecified | CONFIRMED-BY-READING: the draft named the sweeper but not its cancellation or handle ownership | Stop order; live-connection table (3) |
| F8 | HIGH | Generation unbounded (`minItems` of a billion, exponential optional recursion) | CONFIRMED-BY-READING: the draft's formula used `minItems` with no ceiling | Generation bounds; refusal at load; no clamping (3, 4.3) |
| F9 | HIGH | `allOf` naming itself hangs validation; deep instances; cancellation is cooperative | CONFIRMED-BY-READING: `Io.zig:1181-1188`; the draft refused only required-recursion in generation | Cycle refusal; depth and work budgets (3, 4.4) |
| F10 | HIGH | No allocator thread-safety contract | CONFIRMED-BY-READING: `heap/FixedBufferAllocator.zig:62-71` updates `end_index` unsynchronized | Contract stated (3, 9) |
| F11 | HIGH | A `default` was never validated | CONFIRMED-BY-READING: the draft validated examples at load and generated values at send | Every sent value validated; defaults at load (2, 4.2) |
| F12 | MED | mock's problem document can violate a declared error schema | PARTIAL: the mechanism is real; which shape is the default is the maintainer's call | Default now the declared shape, with an option; open question 2 reworded (4.4, 10) |
| F13 | MED | `required` conflicts with "no additional properties" and with `readOnly`/`writeOnly` | CONFIRMED-BY-READING | Directional rule and undeclared-required rule stated (4.3) |
| F14 | MED | No bodyless branch; std writes `Content-Length` on 204 | CONFIRMED-BY-READING: `respondUnflushed` writes `content-length` when no transfer encoding is set (`http/Server.zig:364-369`); RFC 9110 §8.6 forbids it on 204 | Bodyless responses; success-response selection; own writer (3, 4.2) |
| F15 | HIGH | A header value with CRLF trips std's assertion or splits the response | CONFIRMED-BY-READING: `http/Server.zig:338-345` asserts only under runtime safety | Header checks at load and at `faults.add`; reserved names (3) |
| F16 | MED | Swapping identity configuration breaks "old tokens stay valid" | CONFIRMED-BY-READING | Issuer, keys, audiences and provider presence frozen across a swap (2) |
| F17 | HIGH | Opaque lookup alone grants expired, revoked or stored-JWT tokens | CONFIRMED-BY-READING | Opaque validity contract; shape decides the kind (5.2) |
| F18 | MED | Basic split on "exactly one colon" refuses valid passwords | CONFIRMED-BY-READING: RFC 7617 §2 | Split at the first colon (5.2) |
| F19 | MED | Error codes on absent credentials; malformed credentials; API-key challenge | CONFIRMED-BY-READING: RFC 6750 §3.1; RFC 9110 §15.5.2 | Four outcome classes; `ApiKey` challenge (5.1) |
| F20 | MED | `application/at+jwt` refused; required claims incomplete; RS256 required by RFC 9068 | CONFIRMED-BY-READING: RFC 9068 §§2.1, 2.2, 4 | Both spellings; full claim set; conformance gap labelled (5.2, 5.3) |
| F21 | MED | `b64: false` without `crit` passes | PARTIAL: such a token is verified over the normally encoded payload, so no unsigned content is accepted; refusing `b64` costs nothing | `b64` refused whatever its value (5.3) |
| F22 | MED | `KeyPair.generate` uses `Io.random`, which falls back to weak seeding | CONFIRMED-BY-READING: `ecdsa.zig:329`, `ed25519.zig:339`, `Io/Threaded.zig:16958`, `:16967` | `randomSecure` plus `generateDeterministic`; `EntropyUnavailable` fails `init` (3) |
| F23 | MED | Invalid Host should be 400; absolute-form must be accepted and its authority checked; CONNECT | CONFIRMED-BY-READING: RFC 9112 §3.2, §3.2.2 | Rules rewritten; CONNECT refused at load (3) |
| F24 | MED | `Allow` must list HEAD; HEAD must generate as GET | CONFIRMED-BY-READING | Both stated (3, 4.1); plant expectation corrected (8) |
| F25 | MED | `client_secret_basic` form-encoding, repeated and empty parameters, `Pragma`, TLS | CONFIRMED-BY-READING: RFC 6749 §§2.3.1, 3.1, 3.2, 5.1 | All stated; plain HTTP labelled a test-only deviation (5.5) |
| F26 | MED | Defects need applicability, refusal classes and leeway-aware times | CONFIRMED-BY-READING | Defect table rewritten (5.4) |
| F27 | MED | step does not check `typ` or `kid` with a fixed key; openssl `dgst -mac` computes, it does not verify | PARTIAL: what step checks is its own behaviour, not yet run here; the draft's claim was over-broad either way | Expectations listed and pinned on first run; MAC compared in the script; defective tokens also sent to mock with curl (8) |
| F28 | MED | The `oneOf` plant never reaches the final check | CONFIRMED-BY-READING: the generator validates candidates itself | Send-boundary test (8) |
| F29 | MED | "Large response" does not prove the writer is blocked | CONFIRMED-BY-READING | Synchronized blocked-writer test (8) |
| F30 | HIGH | curl is not a schema oracle; equality by source text would pass `[1, 1.0]` under `uniqueItems` | CONFIRMED-BY-READING | JSON-Schema-Test-Suite added; value equality stated (4.4, 8) |

Recommendations the pass disagreed with: R1 (always mock's problem document; see F12), R2 (absolute
form; see F23) and R12, on `typ` spelling only (see F20). It agreed with the other fifteen.

BALLAST it named, and what was done:

- Generated request examples: no caller. The phrase was removed (4.3).
- `unauthorized_client` with nothing in the model to trigger it: now produced only by a fault (5.5).
- Hashing fixed-length HMAC tags before comparing: removed; tags are compared directly (5.1).
- A new DER writer: std has one (`crypto/codecs/asn1/der.zig:9`, `:19`); the staging row now builds on
  it (6).
- Custom auth schemes and a `Prefer` header: these are open questions, not design; unchanged.

Found by the author while the pass ran, and fixed in the same commit: authentication now comes before
request validation (4); the JWK Set never carries HS256 secrets (5.6); the seed hash takes
length-prefixed fields (3).

The same commit fills **Borrowing candidates** (7) from the library survey, which the next pass
reviews with the fixes.
