# librecode

*A libre coordination layer for composing disparate language models into verifiable work.*

## The problem

A language model's systematic errors are properties of the model, not the prompt. Gaps
in its training, its learned biases, the shapes its tuning refuses to produce: reprompting
averages out noise but reaches none of these. Running more copies of one model compounds
its blind spots; it does not correct them. Only a model trained differently has different
blind spots. Error-correction across models is therefore real, and it requires models that
genuinely differ.

The effect has a ceiling. Models from different vendors still share corpora, architectures,
and tuning conventions, so they can agree confidently and be jointly wrong — most
dangerously on new problems, where there is no prior art to anchor them, and the overlap
grows as the models get stronger. Cross-model agreement is a signal, not a proof.
Deterministic checks and human judgment carry the rest of the load; on novel work, the
human carries most of it.

## Why the useful version does not exist

No model vendor will build the layer that composes its competitors, because that layer's
value is precisely *not* depending on any one of them. A neutral aggregator can, and closed
ones already do. But a closed coordination layer is the next enclosure: it captures the
dependency everyone accumulates by using it. The version worth trusting cannot be owned.

## Why a layer, not a feature

The obvious objection: build this coordination into an agent tool directly, as a feature. But
a real project of any size has stakeholders who will never standardize on one tool — different
editors, different harnesses, different workflows — and you cannot make them. A feature inside
one tool governs only that tool's users. The commons spans the stakeholders regardless of what
each runs locally, so the coordinating layer has to sit *above* any single tool. That is what
lets many people, on whatever they each prefer, work as one group whose long-horizon goals do
not silently diverge — and sustained alignment of that kind, across many contributors over a
long horizon, is often what decides whether a large effort succeeds at all. It is not a tooling
detail; it is the thing being built.

## What librecode is

A coordination layer built as a commons — literally: a network of independent sessions, run
by different people using different tools, cross-coordinating on shared long-horizon goals
through one governing layer that none of them owns. It composes disparate models under
deterministic gates that separate progress from regression without ambiguity; keeps every
result in an append-only record so nothing proven is silently lost — and so every session sees
one coherent view of the whole, including the hard blockers ("no progress here until these
people sign off") that hold a large group together; recovers a line of work that goes wrong
instead of letting it propagate; and keeps the human at the two points machines cannot reach —
the genuinely novel, and the judgment of what is actually good.

The composition may *use* proprietary models. It must not *depend* on any of them, and the
governing layer itself must stay un-capturable. That is the entire freedom argument here:
not a slogan, but the one property that keeps a coordination commons from being enclosed by
whoever operates it.

## Who it is for

The people who already recognize enclosure when they see it, and who built the commons the
rest of software runs on — in the open, procedurally, often to a higher standard than the
firms they compete with. The layer for working with these models should be built the same
way, by the same people, for the same reasons.

## Where it stands

Early, and honest about it. The runner and the cross-process supervision core work; the
governance and the measured-coherence loop are argued and partly built. The full argument,
including the places where it is motivated rather than proven, is in
[foundations](docs/foundations.md). If the reasoning holds, help build it. If it does not,
attacking it is the fastest way to find out.
