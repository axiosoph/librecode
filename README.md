# librecode

A libre governance layer for AI-assisted work: every agent walk is bounded by a
contract, checked by deterministic gates, and recorded in a durable,
tamper-evident ledger.

## What it is

librecode is a Common Lisp (SBCL) toolkit for running AI-agent work as governed
**campaigns**, not open-ended chat sessions. A **walker** — the LLM-driven
process actually doing the work — never operates on a bare instruction; it
executes against a boundary refined out of a human's intent until it's
precise enough for a machine to check.

Three pieces work together:

| Piece | Where | What it is |
|---|---|---|
| Reference model | `src/model/` | The pure state machine of governed work — DAG, node phases, deposits, event log — with four crown-jewel invariants as executable predicates. |
| Metaharness | `src/meta/` | Campaign orchestration: DAG scheduling, crash-safe journal, native [Nickel](https://nickel-lang.org) gates, multi-child supervision with condition/restart recovery. |
| Runner | `src/runner/` | The reference supervisable walker — an event-sourced LLM agent harness proving out the supervision contract (freeze/handshake, cooperative shutdown, resume). |

Today it's driven from a Lisp REPL (`just repl`), not yet a polished CLI — see
[Status](#status).

## How a campaign runs

1. A human states intent, often underspecified; an agent presses on the gaps
   until it's a sufficient **IBC** (Initial Boundary Condition) — a plain
   document naming the goal, what's already known, what's delegated to the
   walker's own judgment, and what must halt and ask rather than be guessed
   at. The human keeps final say over every detail and scope — the agent
   sharpens, it doesn't decide.
2. An architect maps that campaign-level IBC into a plan — a DAG of nodes,
   each needing its own IBC drawn from that living plan, which acts as a
   kind of meta-IBC for the nodes under it.
3. The metaharness schedules the DAG and dispatches each node to an isolated
   worktree.
4. A walker executes its node and lands a **deposit** — its unit of finished
   work.
5. A **gate** — any deterministic check, whether a Nickel contract or a
   script the harness runs as a hook — verifies the deposit before it's
   accepted. A contract is one specific, load-bearing kind of gate, not a
   synonym for the concept. The walker never supplies the terms of its own
   checking.
6. Every step — findings, decisions, and their why — is written to a durable,
   append-only ledger, so any reviewer can reconstruct what happened without
   trusting a summary.
7. The human is surfaced only where a **delegation table** actually requires
   it (see [The human seam](#the-human-seam)) — everything else resolves
   without a human in the loop.

## Why this discipline

This isn't a complaint about current models, it's structural: an LLM is a
stochastic walk, not a mind, and open-loop generation drifts by default —
handed a vague task, it doesn't ask what you meant, it fills the gap with a
plausible-sounding assumption instead of surfacing it, and it can't be
trusted to grade its own work either. No amount of scale removes this; only
external structure closes the loop. So librecode pushes precision to both
ends: a contract states requirements before work starts, and a gate — never
the agent that did the work — checks the result after.

That's not just risk management. Working with an LLM changes what's
*tractable*, not just what's fast: research and code both move quickly
enough that problems previously out of reach on a realistic timeline become
worth attempting. But that speedup only holds if direction stays coherent —
the bottleneck isn't the model's capability, it's ours. A precisely scoped
boundary is what turns "should this stop and ask a human" from a guess into
a derivable decision, which is what lets the system move at LLM speed on
everything it can, while still reliably stopping for the one thing no model
has: the human's actual vision for what's being built. See
[docs/design.md](docs/design.md) for the full formal treatment.

## The human seam

Escalation runs through a council of specialized **seats** — architect,
**composer** (the conductor scheduling and dispatching the walk),
lead-maintainer, auditor — each owning a slice of the decision space. A
**delegation table** routes every decision-type to its owning seat and the
assent it requires (a single seat, a subset, the full council, or the
human), so only the decisions that genuinely need a human ever reach one.
Three seam classes dominate that traffic:

- **Novelty-bounding** — greenfield work, closed by writing a sufficient IBC.
- **Divergence-alert** — real-time deviation from a mapped plan, surfaced
  immediately rather than held until review.
- **Coherence-judgment** — the human's quality call at close, which
  overrides any agent's self-assessment.

See [docs/design.md](docs/design.md) for the full delegation table.

## Why more than one model

Prompt variation can't fix what a model systematically cannot see: errors stay
correlated through the model itself. Only genuinely *different* models break
that floor — which is why librecode is heterogeneous-first, composing disparate
models (and deterministic checks, and the human) rather than deepening a bond
with any single vendor. No incumbent can build this: composing competitors is
structurally against their interests. Freedom here isn't ideology bolted on —
it is the enabling condition of the math. See [MANIFESTO.md](MANIFESTO.md) and
[docs/foundations.md](docs/foundations.md) for the full argument.

## Status

Pre-1.0 and molten — still being reshaped freely, no API stability promised
yet. The proof-of-concept is reached: a real supervised subprocess walker with
working tools, a native gate producing a gated artifact, mid-run kill/resume,
and a runnable end-to-end demo against a local model. The current push is a
usable MVP — librecode governing real day-to-day campaigns, including its own
development.

## Quickstart (developers)

Inside the Nix shell (`shell.nix` provides SBCL and dependencies):

```
just build       # compile all systems
just test        # FiveAM + check-it suite
just repl        # interactive REPL with everything loaded
just repl-drive  # REPL loaded to charter and drive a real campaign
just demo        # end-to-end campaign demo against local Ollama
```

`just repl-drive` is the native (non-TUI) way to charter and drive one real
campaign end to end from the REPL — build a DAG, dispatch it against a real
provider, and watch deposits, gates, and the journal as they land. It's a
library, not a script: see `demo/repl-drive.lisp`'s header for the full
interactive session recipe.

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
