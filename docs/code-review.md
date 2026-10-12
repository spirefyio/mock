# mock: code review record

Every adversarial review pass over mock's code is recorded here: the commits it reviewed, the
reviewing model as its log names it, its verdict, and what was done with each finding. The design's
own review is in [design-review.md](design-review.md).

A finding is a claim to be checked, not a verdict. Each one is checked against the reviewed commit
before it is accepted, and is marked

- **CONFIRMED-BY-MEASUREMENT**: a test, a witness or a mutant printed it;
- **CONFIRMED-BY-READING**: the citation and the reasoning hold when read, and no witness was built;
- **PARTIAL**: the mechanism is real, but the severity or the scope is not;
- **REFUTED**: with the evidence that refutes it.

Every fix is new code, so it gets its own pass. The loop for a stage ends when a pass asks for no
change to the code.

## Stage 1: foundation

Stage 1 builds the package files, `Value` (mock's own JSON value), the model types of design
section 2, and the load checks whose rules are in that section, with the load report.

### Pass 1

- Reviewed: `9d72def..5661ad5` (`ce6fa8a`, `b9535d4`, `5661ad5`), read-only. The prompt named the
  base with a typo; the reviewer found the right commit from the history.
- Model: `gpt-6.1-sol`, reasoning effort `max`. A security lens and a test-quality lens ran beside it.
- Verdict: **REWORK**.
- Fixed in `76c58aa` and `46ba864`.

| # | Sev. | Finding (short) | Disposition and evidence | Change |
|---|---|---|---|---|
| S1 | MED | `compile` never reads `Model.identity`, though section 2 refuses a client whose `alg` names no key the provider holds | CONFIRMED-BY-READING: the design's sentence, and no read of `identity` in `compile` | Such a client fails the load under either setting; so does a JWT client with a null `alg` on a provider with no keys |
| S2 | LOW | A schema shared by two fields takes the later field's location, though the comment says field order | CONFIRMED-BY-MEASUREMENT by the reviewer; `push` marked a schema visited when pushed | Marked when popped, so the first path in field order names it; the design says so |
| S3 | MED | Model names were keyed in std's string hash maps, whose seed is fixed, so colliding names make the load quadratic | CONFIRMED-BY-MEASUREMENT: 40,000 colliding operation ids took 48 s in Debug against 23 ms | Names are sorted, compared with their neighbours, and found by binary search |
| S4 | MED | Refusal counts are `usize` and can wrap on a 32-bit target, and the load decision read a count | CONFIRMED-BY-READING; practically unreachable, and cheap to guard | The decision reads a boolean; `unlisted` is a saturating `u64` |
| M1-a | LOW | The report's bound counted only text; growing it in an arena kept dead buffers | CONFIRMED-BY-MEASUREMENT: 1 MiB of text kept 11.5 MiB live | The bound counts each line's record and its text; the report is two exact allocations |
| M1-b | LOW | A name that is not valid UTF-8 printed as an array of numbers, though the comment said a JSON string | CONFIRMED-BY-READING | Each invalid byte is written as U+FFFD; the report keeps the bytes |
| M1-c | LOW | A test fixture pinned acceptance of a composition cycle, which section 4.4 refuses | CONFIRMED-BY-READING | The cycle goes through `properties` |
| M1-d | LOW | The report's bound could not be set by any caller, and the printed footer named the constant | CONFIRMED-BY-READING | `Diagnostics.report_max` carries the bound in use |
| M1-e | LOW | Each operation walks a shared schema again, which is quadratic in the description's size | CONFIRMED-BY-READING | Deferred to stage 2, which builds the schema checks |
| M1-f | LOW | `parse` keeps about 35 times its input in memory | Measured by the lens; not yet checked here. It goes to stage 4 with the finding | Deferred to stage 4, which reads request bodies and sets their bound |
| G1-G8 | — | Eight behaviours no test pinned: `any_of`; an `additional_properties` schema; operation ids and scheme names per service; an undeclared scheme in a service's requirements; no `Diagnostics`; three printed wordings; the report after `OutOfMemory` | CONFIRMED-BY-MEASUREMENT: for each, a mutant stayed green | A test for each, seen to fail on its mutant |

Every fix was planted: the code was broken on purpose, in its own build cache, and the new test was
seen to fail before the code was restored.

### Pass 2

- Reviewed: `5661ad5..46ba864` (`76c58aa`, `46ba864`), read-only. `46ba864` adds one rule beyond
  pass 1's findings: a JWT client with a null `alg`, on a provider with no keys, has nothing to sign
  with and fails the load.
- Model: `gpt-6.1-sol`, reasoning effort `max`. The first run was stopped by the provider's content
  filter before it wrote a report; the prompt was reworded and the pass run again.
- Verdict: **REWORK**: every finding of pass 1 closed, and two new ones in the fix.
- Fixed in `3cc91c4`, which also adds `Options.limits`, so a caller can set the report's bound (a note of the pass).

| # | Sev. | Finding (short) | Disposition and evidence | Change |
|---|---|---|---|---|
| S5 | — | The scheme collector keeps every use, where the hash set it replaced kept one entry per name: a model built from one shared requirement slice makes operations × requirements entries | CONFIRMED-BY-MEASUREMENT: `collectSchemes` appended each use; with it restored, the load below runs out of its 1 MiB | The declarations are sorted first, and each name a requirement uses marks its declaration, found by binary search; a test loads 2,000 operations sharing 2,000 requirements within 1 MiB |
| S6 | — | A schema waiting to be expanded is queued again by every parent, each time with a trail record: schemas sharing one properties slice queue on the order of its length squared | CONFIRMED-BY-MEASUREMENT: `push` skipped only schemas already expanded; with it restored, the load below runs out of its 4 MiB | A depth-first walk over frames enters each schema once and advances one child at a time; a test loads 2,000 schemas sharing one 2,000-entry properties slice within 4 MiB |

### Pass 3

- Reviewed: `46ba864..3cc91c4`, read-only.
- Model: `gpt-6.1-sol`, reasoning effort `max`.
- Verdict: **ACCEPT WITH CHANGES**: S5, S6 and `Options.limits` closed, no new finding, and four
  comments to correct.
- The comments are corrected in the commit before this record. That change is to comments only,
  so it closes the loop for stage 1 without another pass.

| # | Comment | Change |
|---|---|---|
| 1 | The scratch name lists: "the last three are reused for each service", though one of the three is the model's | Names `schemes` and `ids` as the two refilled for each service |
| 2 | The two-paths test said the walk pushes `one_of` first, which the frame walk no longer does | Says the walk reaches the shared schema through `items` first |
| 3 | The fixed-budget helper said a load whose memory is not bounded by the model's size fails, which one fixture cannot show | Says the budget holds for that fixture, and that the general bound rests on the code's invariants |
| 4 | A test said each growing array leaves old copies behind, though the last allocation grows in place | Says only an array that is not the last allocation is copied |
