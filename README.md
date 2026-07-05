# librecode

A libre governance layer for AI-assisted work: every agent walk is bounded by a
contract, checked by deterministic gates, and recorded in a durable,
tamper-evident ledger.

## The premise

Hand anyone a non-trivial assignment — homework, a lab experiment, a consulting
engagement — and the expectation is universal: do the work, *and keep a legible
record of it*. Show your steps. Keep the lab notebook. File the report. No
serious discipline, from grade school to professional practice, accepts "trust
me, it's done" as a deliverable.

Should we expect less from our AI helpers?

We can't introspect a model directly, so librecode enforces the same discipline
externally that we'd expect from any capable colleague:

- **A contract** states the work requirements — machine-checkable, filled as the
  work progresses, never graded by the one who did the work.
- **Deterministic gates** check every deposit of work against its contract. An
  agent supplies work; it never supplies the terms of its own checking.
- **A durable ledger** keeps the pertinent record, zettelkasten-style — findings,
  decisions, and their why — append-only and replayable, so progress is
  tamper-evident and any reviewer can reconstruct what happened from the record
  alone.

## Why more than one model

Prompt variation can't fix what a model systematically cannot see: errors stay
correlated through the model itself. Only genuinely *different* models break
that floor — which is why librecode is heterogeneous-first, composing disparate
models (and deterministic checks, and the human) rather than deepening a bond
with any single vendor. No incumbent can build this: composing competitors is
structurally against their interests. Freedom here isn't ideology bolted on —
it is the enabling condition of the math. See [MANIFESTO.md](MANIFESTO.md) and
[docs/foundations.md](docs/foundations.md) for the full argument.

## What's in the box

| Piece | Where | What it is |
|---|---|---|
| Reference model | `src/model/` | The pure state machine of governed work — DAG, node phases, deposits, event log — with four crown-jewel invariants as executable predicates. |
| Metaharness | `src/meta/` | Campaign orchestration: DAG scheduling, crash-safe journal, native [Nickel](https://nickel-lang.org) gates, multi-child supervision with condition/restart recovery. |
| Runner | `src/runner/` | The reference supervisable walker — an event-sourced LLM agent harness proving out the supervision contract (freeze/handshake, cooperative shutdown, resume). |

A campaign flows: a human-authored boundary contract goes in → the DAG
dispatches walkers → walkers land deposits → gates check them → the ledger
records everything → the human is surfaced exactly where judgment is needed →
a merged, auditable branch comes out.

## Status

Pre-1.0 and molten. The proof-of-concept is reached: a real supervised
subprocess walker with working tools, a native gate producing a gated artifact,
mid-run kill/resume, and a runnable end-to-end demo against a local model. The
current push is a usable MVP — librecode governing real day-to-day campaigns,
including its own development.

## Quickstart (developers)

Inside the Nix shell (`shell.nix` provides SBCL and dependencies):

```
just build   # compile all systems
just test    # FiveAM + check-it suite
just repl    # interactive REPL with everything loaded
just demo    # end-to-end campaign demo against local Ollama
```

## Documentation

- [MANIFESTO.md](MANIFESTO.md) — why libre, why now
- [docs/foundations.md](docs/foundations.md) — first principles: the decorrelation
  theorem, the null hypothesis, what "stable" means
- [docs/design.md](docs/design.md) — the campaign lifecycle, council protocol,
  human seam
- [docs/model.md](docs/model.md) — the reference state machine and its invariants
- [docs/roadmap.md](docs/roadmap.md) — workstreams and sequencing

## License

Not yet declared (pre-release).
