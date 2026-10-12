# mock: design review record

Every adversarial review pass over [design.md](design.md) is recorded here: the commits it
reviewed, the reviewing model as its log names it, its verdict, and what was done with each
finding. A finding is a claim to be checked, not a verdict: each one is checked against the
reviewed commit and the Zig 0.16.0 standard library before it is accepted, and is marked

- **CONFIRMED-BY-READING**: the citation and the reasoning hold when read;
- **PARTIAL**: the mechanism is real, but the severity or the scope is not;
- **REFUTED**: with the evidence that refutes it.

No pass has been recorded yet.
