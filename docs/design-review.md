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
- Fixed in `4fafcd5`, the commit that adds this record.

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
- Fixed in `67e152b`, the commit that adds this record.

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
- Fixed in `5afe804`, the commit that adds this record. That fix delta had its own pass, pass 4.

Pass 2's items: F4, F8, F14-F16, F19, F23, F25-F27, F31, F32 and F34-F40 closed. F5, F7 and F33
closed in part; what remained is F42, F41 and F44 below.

| # | Sev. | Finding (short) | Disposition and evidence | Change |
|---|---|---|---|---|
| F41 | HIGH | `deinit` takes the lifecycle lock and then calls `stop`, which takes it again | CONFIRMED-BY-READING: `Io.Mutex.lock` (`lib/std/Io.zig:1602`) waits on a held mutex and keeps no owner, so the second take never returns | Each public call takes the lock once; `deinit` runs the stop steps through internal functions; exclusive ownership at `deinit` stated; a plant (3, 8) |
| F42 | MED | "A test that has received only a 100 finds it `pending`" promises a state the server may have left | CONFIRMED-BY-READING: the server may read the body and answer before the test looks | The entry exists after a 100, `pending` or later (3) |
| F43 | LOW | The status for framing overhead past the head limit | PARTIAL: section 3 charged framing overhead to the request-head limit, which the Bounds table answers with 431, but "Any other breach is 400" in the same section gave that breach a second answer. *Corrected after pass 4 (F47): this said no status was stated, which was wrong.* | 431 past the limit, 413 for the body, 400 for malformed framing (3) |
| F44 | LOW | Open question 2 restated the pass-1 rule without `default` | CONFIRMED-BY-READING | It now points at 4.4 (10) |

Recommendations R25-R29 (the strict chunked decoder; 100 at the token endpoint before client
authentication; outcomes decided together with "malformed" narrowed; one lifecycle lock; the store's
kind check kept as armor behind shape dispatch): the pass agreed with all five, R25 and R28 subject
to F43 and F41.

BALLAST it named, and what was done: three survey rows still claimed absence universally ("exists
anywhere", "No Zig SAML IdP exists", "No licensed Zig 0.16 validator or executor exists"); each now
says what the survey found (7). The real-socket blocked-writer run, survey counts, custom schemes and
`Prefer` were judged correctly labelled; unchanged.

## Pass 4

- **Reviewed:** the fix delta `67e152b..5afe804` (pass 3's fixes), read-only, with pass 3's
  findings and their dispositions. This pass also checked the whole document once for
  contradictions between sections.
- **Model:** `gpt-6.1-sol`, reasoning effort `max`.
- **Verdict:** **ACCEPT WITH CHANGES**. The design still had to:
  - resolve lifecycle cancellation;
  - remove the contradiction about the body of a too-complex request;
  - correct the F43 disposition.
- **Fixed in:** `6e7b01d`, the commit that adds this record, which gets its own pass.

Pass 3's items:
- F42, F43 and F44 are closed, as are the three survey wording items.
- F41 is closed in part. No path takes the lock twice, but a cancelled acquisition was left
  undefined (F45).

| # | Sev. | Finding (short) | Disposition and evidence | Change |
|---|---|---|---|---|
| F45 | MED | Taking the lifecycle lock can be cancelled, and the design said nothing about it | CONFIRMED-BY-READING: `Io.Mutex.lock` returns `Cancelable!void` (`lib/std/Io.zig:1602`), while `stop` and `deinit` return `void`. `lockUncancelable` exists at `:1623`. | `stop` and `deinit` take the lock uncancelably. `start` and `swapModel` return `error.Canceled` with nothing changed. A plant covers it (3, 8). |
| F46 | LOW | The Bounds table promised a `request-too-complex` problem document, but 4.4 answers with the operation's declared 413 first | CONFIRMED-BY-READING: the Bounds row and 4.4's error-response rule gave two bodies for one refusal. | The Bounds row now defers to 4.4, and the record keeps the reason either way (3). |
| F47 | LOW | Pass 3's F43 disposition said no status was stated | CONFIRMED-BY-READING: at `67e152b` the Bounds table answered the head limit with 431, and section 3's "Any other breach is 400" contradicted it. | The F43 row is corrected where it stands (this file). |

**BALLAST:** the pass named nothing new. It found the added `deinit` plant to be armor, provided
the time limit is enforced outside the blocked call. Section 8 now says so.

## Pass 5

- **Reviewed:** the fix delta `5afe804..6e7b01d` (pass 4's fixes), read-only, with pass 4's
  findings and their dispositions.
- **Model:** `gpt-6.1-sol`, reasoning effort `max`.
- **Verdict:** **ACCEPT WITH CHANGES**. The design still had to:
  - complete cancellation handling;
  - settle when the swap candidate is compiled;
  - keep every case of 4.4's response choice.
- **Fixed in:** `4baee22`, the commit that adds this record, which gets its own pass.

Pass 4's items:
- F47 is closed.
- F45 is closed in part. Taking the lock was specified, but a cancellation already pending could
  still cut cleanup short.
- F46 is closed in part. The Bounds row summarised only part of 4.4's rule.

| # | Sev. | Finding (short) | Disposition and evidence | Change |
|---|---|---|---|---|
| F45 (rest) | MED | Taking the lock uncancelably still leaves a pending cancellation able to stop cleanup at a cancelable step | CONFIRMED-BY-READING: `ShutdownError` includes `Cancelable` (`lib/std/Io/net.zig:982-988`), and the threaded shutdown checks for cancellation (`lib/std/Io/Threaded.zig:13235` onward). `CancelProtection` and `swapCancelProtection` (`lib/std/Io.zig:1322`, `:1342`) block it for a region. | `stop` and `deinit` run with cancel protection `.blocked`. A plant cancels a `stop` during cleanup (3, 8). |
| F46 (rest) | LOW | The Bounds row named two of 4.4's choices and left out `4XX`, `default` and `.problem_document` | CONFIRMED-BY-READING | The row now defers to 4.4 entirely (3). |
| F48 | LOW | "Frees the model it compiled" put compiling before the lock, while the bullet above said all work is done with the lock held | CONFIRMED-BY-READING: the two sentences disagree, and section 2 ("compiles the new model first") did not say where the lock is taken | `swapModel` compiles before taking the lock, and the held-lock rule names that exception (3). |

**BALLAST:** the pass named nothing new. It judged the watchdog requirement useful armor.

## Pass 6

- **Reviewed:** the fix delta `6e7b01d..4baee22` (pass 5's fixes), read-only, with pass 5's
  findings and their dispositions.
- **Model:** `gpt-6.1-sol`, reasoning effort `max`.
- **Verdict:** **ACCEPT WITH CHANGES**. The previous findings are closed. The pass asked for one
  correction, to a blanket guarantee about cancelled task results.
- **Fixed in:** `1b6ae19`, the commit that adds this record, which gets its own pass.

Pass 5's items: the rest of F45, the rest of F46, and F48 are all closed.

| # | Sev. | Finding (short) | Disposition and evidence | Change |
|---|---|---|---|---|
| F49 | LOW | "Under `.blocked`, no `Io` call returns `error.Canceled`" is too broad: a cancelled child task's result can still be `error.Canceled` | CONFIRMED-BY-READING: `Future.cancel` returns the task's `Result` (`lib/std/Io.zig:1191-1195`), and protection covers only the calling task's cancelation points | The sentence names the calling task's cancelation points. `stop` consumes the expected `error.Canceled` from its accept tasks and the sweeper, then goes on with the shutdown (3). |

**BALLAST:** the pass named nothing new.

## Pass 7

- Reviewed: the fix delta `4baee22..1b6ae19` (pass 6's fix), read-only.
- Model: `gpt-6.1-sol`, reasoning effort `max`.
- Verdict: **ACCEPT**. F49 is closed, `stop`'s step order is unchanged, and no new defect was found.
- **The review loop is closed:** this pass asked for no change. This record is the only commit after
  it, and it changes no design text.
  *Reopened after pass 7: the maintainer's decisions on the open questions (`777a3eb`) changed the
  design after this record, so the loop ran again from pass 8.*

## Pass 8

- **Reviewed:** the delta `7ff1697..777a3eb`, the maintainer's decisions written into the design,
  read-only. The prompt carried four recommendations (R30–R33) for the pass to agree or disagree
  with.
- **Model:** `gpt-6.1-sol`, reasoning effort `max`.
- **Verdict:** **ACCEPT WITH CHANGES**. The clock and signing contracts needed correcting, strict
  `Prefer` handling needed to be marked as a deviation, `Vary` was missing, and one plant could not
  turn red.
- **Fixed in:** `a5a33fe`, the commit that adds this record, which gets its own pass.

RFC 7240 §2 was read for F52 and F53: a server that "does not recognize or is unable to comply
with particular preference tokens … MUST ignore those tokens and continue processing instead of
signaling an error", and "a Vary header field MUST be included in the response listing the Prefer
header field regardless of whether the client actually used Prefer in the request".

| # | Sev. | Finding (short) | Disposition and evidence | Change |
|---|---|---|---|---|
| F50 | MED | `set(t)` on a `.real` clock cannot make `now()` return `t` "from then on", and a `.real` clock set near the upper bound leaves the range a second later with nothing to stop it | CONFIRMED-BY-READING: 5.7 defines `.real` as the real-time clock plus an offset, so it keeps ticking after a `set`; the range was checked only on a move | `set` makes the clock read `t` at that instant: `.manual` stays there, `.real` takes the matching offset and ticks on. Every read is checked against the bound; out of range, `now()` and `idp.issue` return `error.ClockOutOfRange` and a request that needs the time gets 500 `clock-out-of-range` (5.7). A plant on a test `Io` steps real time past the bound (8). |
| F51 | MED | "The two names sign the same bytes" is false: the protected header, `alg` included, is part of the signing input, so a relabelled token fails verification, and the step check that relied on relabelling cannot work | CONFIRMED-BY-READING: RFC 7515 §5.1 makes the JWS signing input the encoded protected header, a period and the encoded payload. The false sentence was written in this design at `777a3eb`. | Retracted at both sites. 5.2 says the two names share a primitive but not a signature, and a key verifies only its own name. The step check uses a second key configured as `EdDSA`, whose tokens mock issues and signs; `Ed25519` tokens go to openssl, which checks the signature over the signing input whatever the header says, and to mock's own header test (8). |
| F52 | LOW | Refusing an unsatisfiable `code` or `example` with 400 departs from RFC 7240 §2, which requires ignoring a preference the server cannot comply with; the design said the RFC "allows" ignoring | CONFIRMED-BY-READING: the quoted §2 text above | "allows" becomes "requires". A paragraph marks the 400 as a deliberate deviation and gives the reason: a test asking for a 404 that gets a 200 through a typo would pass for the wrong reason (4.2). |
| F53 | MED | Responses that `Prefer` can change carry no `Vary`, so a cache could answer an ordinary request with a response a preference chose | CONFIRMED-BY-READING: the quoted §2 text above | Every response 4.2 sends, the `preference-unsatisfiable` refusal included, carries one `Vary` field listing `Prefer`, and `Accept` when the media type was negotiated (RFC 9110 §12.5.5). A declared `Vary` keeps its members; a declared `*` is left alone (4.2). A plant drops mock's members (8). |
| F54 | LOW | A frozen clock makes timestamps exact, not whole tokens: `jti` and the keys differ each time | CONFIRMED-BY-READING: 5.3 requires `jti`, unique per token (RFC 7519 §4.1.7), and section 3, Keys, makes fresh keys for every mock | The promise is narrowed to `iat`, `nbf` and `exp`; a test compares claims, not token bytes (5.7). |
| F55 | LOW | Two summaries overstate their rules: "an ignored preference never silently turns into a success" contradicts ignoring `return=minimal` on a successful request, and section 10's "a refused request" stretches the validation-stage rule to authentication and `Prefer` refusals | CONFIRMED-BY-READING: 4.2 ignores every preference but `code` and `example`; 4.4's declared-shape rule covers only "a request this stage refuses" | 4.2 now says a `code` or `example` mock cannot satisfy never turns into a success. Section 10 item 2 says "refused by validation" and names the rules for the other two refusals. |

**Recommendations.** R30, the identity clock moving apart from the server's own time: AGREE. R31,
an unsatisfiable `code` or `example` refused with mock's problem document: AGREE, with F52's label.
R32, acting only on `code` and `example`: AGREE. R33, a manual mode beside the offset clock: AGREE,
with F54's narrower promise.

**BALLAST:** of the five new plants, four were judged armor. "`Prefer` applied before
authentication" was ballast as written: choosing a response early can still leave the 401 intact,
so the plant might never turn the test red. It now sends the preferred response before
authentication runs. The range plant now uses a `.manual` clock, so that real time cannot move
`now()` under the "unchanged" assertion.

## Pass 9

- **Reviewed:** the fix delta `777a3eb..a5a33fe` (pass 8's fixes), read-only, with pass 8's
  findings and their dispositions.
- **Model:** `gpt-6.1-sol`, reasoning effort `max`.
- **Verdict:** **ACCEPT WITH CHANGES**. The merged `Vary` value had to be validated, the 406 had
  to list `Accept`, and the record had to name its fix commits correctly.
- **Fixed in:** the commit that adds this record, which gets its own pass.

Pass 8's items:
- F50, F51, F52, F54 and F55 are closed, and so are both plant notes.
- F53 is closed in part: see F56 and F57.
- The pass confirmed that `openssl pkeyutl -verify -rawin` checks an Ed25519 signature over the
  signing-input bytes without reading the JOSE `alg`. It noted that the invocation needs `-pubin`
  as well as the key, input and signature arguments, and section 8 now names it.

| # | Sev. | Finding (short) | Disposition and evidence | Change |
|---|---|---|---|---|
| F56 | MED | Adding mock's members to a declared `Vary` can send a value its own schema forbids (a `const` of `Origin` becomes `Origin, Prefer`), and the sentence exempting the added members contradicted "every value sent is validated against its schema first" | CONFIRMED-BY-READING: both sentences stood in 4.2 at `a5a33fe`, and a schema constrains the whole header value | The exemption is withdrawn. The merged value, which is the value sent, is the one validated, at load for examples and defaults and at send time; a declaration that cannot hold mock's members is refused at load when its example or default shows it, and otherwise answered 500 (4.2). A plant validates before the merge (8). |
| F57 | LOW | The `Accept` condition named only a successful choice of media type, so the 406, which also depends on `Accept`, need not list it | CONFIRMED-BY-READING: 4.2 step 4 answers 406 when no declared type is allowed, and the condition read "chosen by negotiation" | `Accept` is listed whenever step 4 negotiated, whichever way it came out, the 406 included; a response with no content skips negotiation and lists `Prefer` only (4.2). The `Vary` plant gains a 406 case (8). |
| F58 | LOW | Pass 8's "Fixed in: the commit that follows this record" is wrong: the record and its fixes are in the same commit, `a5a33fe` | CONFIRMED-BY-READING, and the class is wider than the finding: `git show --stat` shows that every fix commit from `4fafcd5` to `a5a33fe` adds its pass's record together with its fixes, so passes 1 to 6 and 8 all said the same wrong thing | Each of those seven records now names its commit and says it is the commit that adds the record. |

**BALLAST:** the pass judged all four new or rewritten plants armor. It noted that the range plant's
narrative was wrong while the read check stays in place, since `now()` would then return the error
rather than the out-of-range time; the plant now says the move succeeds.

## Pass 10

- **Reviewed:** the fix delta `a5a33fe..f3b5f2b` (pass 9's fixes), read-only, with pass 9's
  findings and their dispositions.
- **Model:** `gpt-6.1-sol`, reasoning effort `max`.
- **Verdict:** **ACCEPT**. F56, F57 and F58 are closed, and so are the two notes. The pass checked
  each of the seven named fix commits with `git show` and found that each adds its own pass
  record. It judged both new plant cases armor and found no new defect.
- **The review loop is closed:** this pass asked for no change. This record is the only commit after
  it, and it changes no design text.
