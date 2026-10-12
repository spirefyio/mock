# mock: design review record

Every adversarial review pass over [design.md](design.md) is recorded here: the commits it
reviewed, the reviewing model as its log names it, its verdict, and what was done with each
finding. A finding is a claim to be checked, not a verdict: each one is checked against the
reviewed commit and the Zig 0.16.0 standard library before it is accepted, and is marked

- **CONFIRMED-BY-READING**: the citation and the reasoning hold when read;
- **PARTIAL**: the mechanism is real, but the severity or the scope is not;
- **REFUTED**: with the evidence that refutes it.

The review is of a design, so nothing here is confirmed by measurement: no code exists yet. A
disposition says the finding holds; the Change column says what the design now says. Neither claims
a chain is closed until a later pass reads the change.

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

## Pass 2

- Reviewed: the fix delta `08379e4..4fafcd5` (pass 1's fixes and the new Borrowing candidates),
  read-only, with pass 1's findings and their dispositions.
- Model: `gpt-6.1-sol`, reasoning effort `max`.
- Verdict: **REWORK** — "malformed chunk acceptance, body-authentication ordering, incomplete error
  contracts, and remaining ownership/resource/lifecycle gaps still prevent the promised defensive
  guarantees."
- Fixed in the commit that follows this record.

Pass 1's findings: F1-F3, F6, F9-F11, F13, F16-F18, F20-F22, F24, F28-F30 closed. The residue the
pass named in the others, each confirmed by reading the design at `4fafcd5`:

| # | Residue | Change |
|---|---|---|
| F4 | The token store's strings had no ownership rule | The token store copies every string it keeps; `clear()` does not touch it (3) |
| F5 | "At least its status" was false after a 100; no word on overflow, `clear` or refusals before a head | Guarantee restated: `pending` has no status; pre-head refusals get an entry; overflow and `clear` named (3) |
| F7 | `Future.cancel` and `Group.cancel` are not thread-safe, and nothing serialized `stop` | One lifecycle lock over `start`, `stop`, `swapModel` and `deinit`; no task takes it (3) |
| F8 | Issued token size, token-store bytes, fault bodies and generation work unbounded | Bounds rows for each (3) |
| F12 | `default` ignored | See F33 |
| F14 | 205 and 1xx | See F34 |
| F15 | Field-value grammar, serialization, generated header values, `Content-Encoding` | All stated; `Content-Encoding` reserved (3) |
| F16 | Validity is not authorization | Said so at the swap rule (2) |
| F19 | Aggregation and malformed | See F35, F36 |
| F23 | Equivalent IPv6 spellings and ports | The authority is parsed and compared as address, name and number (3) |
| F25 | Body authentication against the 100 rule | See F32 |
| F26 | `missing_scope` is wrong only where the scope is required | Stated in the defect table and below it (5.4) |
| F27 | No negative tokens mock never issued | curl presents script-made tokens (8); see F37 |

New findings:

| # | Sev. | Finding (short) | Disposition and evidence | Change |
|---|---|---|---|---|
| F31 | HIGH | `std.http.ChunkParser` accepts malformed chunk framing | CONFIRMED-BY-READING: `lib/std/http/ChunkParser.zig:55-57` takes `A`-`Z` and `a`-`z` as digits, `:65-68` turns any other byte into an extension, `:79-85` skips extension bytes unchecked | mock's own strict decoder; ChunkParser named and refused (3); a plant (8) |
| F32 | HIGH | 100 Continue waits on authentication, but `client_secret_post` sends credentials in the body | CONFIRMED-BY-READING: the 100 rule in 3 against 5.5 | Token endpoint exception (3, 5.5); a plant (8) |
| F33 | MED | `default` ignored when choosing the error response | CONFIRMED-BY-READING: OpenAPI's Responses Object lets `default` cover undeclared codes | Exact code, then range, then `default`, for every status that stage answers (4.4); a plant (8) |
| F34 | MED | 205 with content and 1xx as a final answer | CONFIRMED-BY-READING: RFC 9110 §15.3.6 | Status/content matrix; 1xx refused; 205 sends `Content-Length: 0` (3, 4.2, faults) |
| F35 | MED | Two API keys required, one sent: no rule answered | CONFIRMED-BY-READING: none of the four conditions held | Outcomes decided together; rule 4 names the case; a plant (5.1, 8) |
| F36 | MED | An unparseable JWT fit both 400 and 401 | CONFIRMED-BY-READING: RFC 6750 §3.1 gives `invalid_token` to a malformed token | Malformed narrowed to the request's authentication syntax (5.1); a plant (8) |
| F37 | MED | step cannot verify HS256 with a public JWK; the fixture wrote a set | CONFIRMED-BY-READING for the HS256 half: 5.6 keeps HS256 secrets out of the JWK Set. How step's `--key` treats a set was not checked here; one key per file is right either way | step for ES256 and EdDSA only, one JWK file per key; HS256 to openssl; opaque tokens to neither (8) |
| F38 | MED | The borrow-time procedure did not establish each file's effective terms | PARTIAL: the gap in the procedure is real; nothing has been borrowed, so no condition has been missed | Procedure rewritten: per-file terms, the chosen license for OR terms, module conditions, license texts (7) |
| F39 | LOW | The http.zig row said `std.http.Server` is enough, against 3 | CONFIRMED-BY-READING | Row reworded (7) |
| F40 | LOW | `Canceled` reported as `EntropyUnavailable` | CONFIRMED-BY-READING: `lib/std/Io.zig:2472` puts `Cancelable` in `RandomSecureError` | Both errors returned as they came (3) |

Recommendations R19-R24: the pass agreed with all six, with qualifications that F31, F33, F35 and
F36 carry. It noted that refusing `b64` outright is mock's policy, narrower than RFC 7797; 5.3 now
says so.

BALLAST it named, and what was done:

- The stored-JWT plant could not catch removal of the store's kind check while shape dispatch
  stands. Split into three rows: shape dispatch, the opaque expiry and revocation check, and the
  kind check, which is the one plant asserted below the public boundary, with the reason (8).
- Recording Wycheproof `acceptable` results has no failing expectation: they are now pinned to
  mock's policy (8).
- The real-socket blocked-writer run cannot prove the write had blocked: the deterministic `Io` run
  is the check, and the real-socket run is labelled a smoke test (8).
- Survey counts are not borrowing gates, and "exists nowhere" claimed too much: both reworded (7).
- "Every case for a keyword" overstated restricted forms such as a non-integer `multipleOf`: such
  cases are counted as refusals (8).
- Custom auth schemes and `Prefer`: open questions, unchanged.

From CHECKED CLEAN: std's drain before responding is conditional on keeping the connection alive
(`lib/std/http/Server.zig:348-350`); section 3 now says so.

## Pass 3

- Reviewed: the fix delta `4fafcd5..67e152b` (pass 2's fixes), read-only, with pass 2's findings
  and their dispositions.
- Model: `gpt-6.1-sol`, reasoning effort `max`.
- Verdict: **REWORK** — "the stated lifecycle contract can deadlock during cleanup, and the
  record-state and error-response guarantees still need correction."
- Fixed in the commit that follows this record. **That fix delta has not had its own pass:** three
  passes was the cap set for this design, so a fourth pass over it is owed before the design is
  accepted.

Pass 2's items: F4, F8, F14-F16, F19, F23, F25-F27, F31, F32 and F34-F40 closed. F5, F7 and F33
closed in part; what remained is F42, F41 and F44 below.

| # | Sev. | Finding (short) | Disposition and evidence | Change |
|---|---|---|---|---|
| F41 | HIGH | `deinit` takes the lifecycle lock and then calls `stop`, which takes it again | CONFIRMED-BY-READING: `Io.Mutex.lock` (`lib/std/Io.zig:1602`) waits on a held mutex and keeps no owner, so the second take never returns | Each public call takes the lock once; `deinit` runs the stop steps through internal functions; exclusive ownership at `deinit` stated; a plant (3, 8) |
| F42 | MED | "A test that has received only a 100 finds it `pending`" promises a state the server may have left | CONFIRMED-BY-READING: the server may read the body and answer before the test looks | The entry exists after a 100, `pending` or later (3) |
| F43 | LOW | The status for framing overhead past the head limit | PARTIAL: "any other breach is 400" excluded that case rather than giving it a second answer, but no status was stated for it | 431 past the limit, 413 for the body, 400 for malformed framing (3) |
| F44 | LOW | Open question 2 restated the pass-1 rule without `default` | CONFIRMED-BY-READING | It now points at 4.4 (10) |

Recommendations R25-R29 (the strict chunked decoder; 100 at the token endpoint before client
authentication; outcomes decided together with "malformed" narrowed; one lifecycle lock; the store's
kind check kept as armor behind shape dispatch): the pass agreed with all five, R25 and R28 subject
to F43 and F41.

BALLAST it named, and what was done: three survey rows still claimed absence universally ("exists
anywhere", "No Zig SAML IdP exists", "No licensed Zig 0.16 validator or executor exists"); each now
says what the survey found (7). The real-socket blocked-writer run, survey counts, custom schemes and
`Prefer` were judged correctly labelled; unchanged.
