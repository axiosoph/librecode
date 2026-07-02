# librecode — Foundations

The first-principles account of what librecode's metaharness *is* and what "stable"
*means* for it. This is the design bedrock the code must map onto (see **Completeness
discipline**); it argues, it does not persuade (that is `MANIFESTO.md`) and it does not
describe the as-built system (that is the rest of `docs/`). Claims are cited to the
literature inline (see **References**).

**Epistemic scope.** Every *mechanism* composed here is independently grounded in the
empirical or theoretical literature, cited in place. What is novel and unverified is their
*system-level synthesis* (see **The novelty boundary**); building librecode is how that
synthesis gets tested. One claim — the dynamic half of the stability metric (§8) — is not
yet machine-checkable, and is marked as such.

---

## Positioning

Agent harnesses (opencode and kin) handle progress in **focused microcosms of concern**:
one session, short horizon, a bounded task. What none of them expose is a **supervision
contract**: hooks that let a parent freeze a walk mid-turn, offer it a chosen restart, and
resume it in place — transparently, without killing and restarting from scratch. librecode's
**runner** is the reference implementation of that contract, grown out of porting opencode's
primitives; it exists to prove the contract out, not to duplicate a harness that already
exists (see "The null hypothesis," below, and `AGENTS.md`).

What is missing — in the field at large — is a formalization of **coherent progress on
long-horizon, large-goal work**, which is inherently **multi-project and multi-commons**:
a commons holds many projects, and a person or team may steward more than one at once. We
take the **commons** as the model with the least *a priori* structural bias and derive the
layer from the *mechanics* that make a commons work. librecode's **metaharness** is the
first attempt to formalize that layer; unlike the runner, its stability has no external
spec and is argued here.

The commons here is **literal, not a metaphor**: a network of independent sessions — run by
different people, on different harnesses, across different projects — cross-coordinating on
shared long-horizon goals through one governing layer that none of them owns. That is why the
layer sits *above* any single harness rather than inside one. A coordination feature built into
one agent tool governs only that tool's users, and a project of any size has stakeholders who
will never standardize on one tool (editors, harnesses, and workflows are heterogeneous and
unenforceable). Abstracting the layer above the harness is what lets disparate human operators —
and their disparate machine walkers — work under one non-conflicting goal-structure. The
metaharness is not a bigger harness; it is the layer that survives stakeholders refusing to agree
on a harness. (This is the capture argument of §2 at a second axis: a layer inside one harness is
captured by that harness, exactly as one inside a vendor is captured by that vendor.)

---

## The null hypothesis — why not a forge and a bot?

The sharpest objection to building any of this: git forges (Forgejo, and its proprietary
cousins) already give a community an append-only history, required CI gates, and
machine-enforced human sign-off (branch protection, required reviewers, CODEOWNERS) —
Ostrom's principles, largely reified, for free. Why not a webhook daemon and a set of
contracts on top of one, instead of a bespoke metaharness?

Because a forge's coordination unit is the **artifact**, not the **walk**. It samples the
world at push/PR/comment granularity and human cadence, and it does so *deliberately*: its
contributors have always been humans, whose reasoning is opaque and unsupervisable
mid-thought, so the only thing a forge can honestly govern is what they hand it when
they're done. Push a bespoke bot hard enough to cover librecode's requirements and every
patch it needs converges on a component librecode already has under a different name:
forge state is mutable (reviews get dismissed, comments edited), so tamper-evidence
requires mirroring it into an append-only journal — the journal. CI executes code the
agent itself authored, so the checker's parameters have to be pinned outside the agent's
control — gate-parameterization. And a forge is blind between pushes, so the whole
recovery ladder (freeze, offer a restart, resume in place) collapses to one primitive,
reject-and-redispatch, discarding everything a doomed walk could have told a supervisor
watching it in real time.

Agent walks are the first contributors whose trajectories are **observable** end to end —
every token, every tool call — and that observability is new. A forge's
artifact-granularity boundary is correct for humans and is simply the wrong boundary for a
walker that can be watched. The metaharness exists to exploit that difference: **forges
govern what's merged; the metaharness supervises what's producing it.** Positioning's
"above any harness" claim has a dual here — the metaharness sits **before any forge**, not
in competition with one. A forge remains the right home for the durable, merged record and
for optional outbound visibility into a campaign's state (a non-adopter should be able to
watch progress without installing anything); it is not a substitute for walk-level
governance, and nothing here treats it as one.

One design decision survives this stress test unpatched: the gate-checker's
external-binary property (`design.md §4`) — the contract lives outside the harness process
and is invoked the same way everywhere — is exactly what lets the identical check run
inside the harness, in CI, and at a commit hook without librecode itself needing to be
present on the forge side — the one piece of the architecture already built for a world
with a forge in it.

None of this is an argument that every mechanism here is individually exotic — most
aren't; a CI script and forge configuration cheaply reproduce most of what's cited above.
That was never where the bet lives. Only the five elements in "The novelty boundary" below
require the synthesis; the honest claim is that governing all of them coherently, over an
observable walk, is what a forge cannot do — not that any single mechanism needs a bespoke
system to exist.

---

## The argument

### Axiom — two stochastic walkers, with two asymmetries
A **machine** (LLM) is a stochastic walker **bounded** to a model `θ` (its weights, from
training + fine-tuning + safeguards): it samples only within `θ`'s reachable region, and
is **abundant** in throughput. A **human** is a stochastic walker on a **different
substrate whose bound cannot be written down** — not provably unbounded, but not
characterized by any known `θ`. The human–machine correlation is **graded and
error-class-dependent**, not absent (§3 models the channels); the human is **scarce** in
throughput (attention is the limiting resource). Two
asymmetries are load-bearing and distinct: the human is a *different, un-formalizable
substrate* (drives the decorrelation role, §3) and is *scarce* (drives the economy of
§6–7). The claim is difference and independence, not superiority or unbounded reach; that
the human is the better *judge* of coherence is argued in §6, not assumed here.

### 1 · Why disparate models — the decorrelation floor
Separate what is provable from what is not. For the *average* of real-valued members under
squared error, the ensemble's error equals the mean member error minus a non-negative
**diversity** term (Krogh & Vedelsby 1995), and falls only as the inter-member error
**covariance** falls (Ueda & Nakano 1996); identical members contribute zero diversity.
That much is an identity — but it signs the *averaged ensemble against its own mean member*,
and the quantity it reduces is **variance**, not **bias** (likewise the random-forest floor,
Breiman 2001, where decorrelation cuts variance down to the residual inter-tree correlation).

librecode's claim rests one level deeper, on `θ` itself. A model's systematic errors —
training gaps, learned biases, the outputs its tuning refuses — are properties of `θ`,
invariant across how it is prompted: two promptings of one `θ` have errors correlated
*through* `θ`, a floor no reprompting crosses. Disparate `θ` have *different* floors, so
where one is blind another may see. This is the decorrelation the architecture is built on,
and it is why members must differ at the **weight level** — not in prompt or persona. The
ensemble identities earn their keep for exactly one thing — diversity is the *only* source
of gain, so identical members buy nothing (Wood, Mu, Reid & Brown 2023 carry this across
loss functions) — and we lean on them for no more: the composition is not an average but
role-differentiated production under gates and a human (§3, §7). By *how much* disparate `θ`
beat the best single model is therefore not a theorem but the empirical claim this project
exists to test — expected on principle (the `θ`-floor is real and its blind spots differ),
and measured rather than asserted.

The picture this licenses is a **union of reach**, `⋃_θ`: the combined region disparate
models cover, made coherent by the governance layer — more than any single `θ` commands
alone. (A model's own conditioning envelope `⋃_c` — in-context learning, chain-of-thought,
retrieval, tools — widens *its* reach but leaves *its* `θ`-level blind spots intact, which
is exactly why covering those needs a different `θ`, not more prompting.) That the composed
whole exceeds the sum of its parts is the thesis; §3 gives the honest reason it is
bounded — shared `θ`-priors — and where the human enters.

### 2 · Why the composing layer must be *libre* — capture-resistance
One might expect freedom to be what makes the disparate-model union reachable. It is not:
composing disparate `θ` requires only a *neutral composer*, and neutral composers already
exist as proprietary products (model routers/aggregators). The composition of §1 does not,
by itself, require freedom.

What freedom secures is different and decisive. A neutral composer that is closed becomes
the next lock-in: it captures the coordination layer everyone comes to depend on, and shared
reliance on one such layer is itself a correlated-failure and welfare risk (Kleinberg &
Raghavan 2021; Bommasani et al. 2021). The layer that *governs* disparate production (§4–5)
into coherent, verifiable output, and that holds the community and its people (§4), must
itself be **un-capturable**. A libre license is *necessary* for that but not sufficient —
open-source-yet-captured is a familiar outcome (single-steward lock-in, open-core). What
secures it is the license **plus** governance no one can quietly enclose: the collective
right to fork, re-steward, and revise the rules (§5). Freedom is the enabling condition of a
**trustable, capture-resistant governance layer**, not of the composition mathematics. (Our
scope rule — proprietary models allowed as arms-length members — is consistent only under
this reading.)

Capture-resistance also has to survive the metaharness's own implementation choice, not
just its license. A kernel implemented in a language with few practitioners narrows the
credible steward pool for that kernel specifically — a real cost, not a hypothetical one.
What keeps the argument intact is that capture-resistance rests on the **model and
protocol** being reimplementable and the correctness argument being **legible to
non-Lispers** (`src/model/` is deliberately dependency-free, CLOS-free, and stated as a
specification other implementations can be conformance-tested against, not as an appeal to
trust the Lisp), while the surrounding ecosystem's contribution surface is the opencode
plugin seam (roadmap G), not the kernel itself. The commons does not need many people
extending the kernel; it needs the kernel's semantics to be public and checkable by people
who never touch it.

### 3 · The human/machine division — and the correlated-bias floor
As a different substrate, the human's failures are not correlated through any `θ`'s
*architecture or tuning conventions*: the human is the natural check on the machine floor,
the reach into genuine novelty (work outside `⋃_θ`), and — argued in §6, not assumed — the
better judge of coherence and meaning. (The correlation that *does* bind the substrates is
modeled below, not assumed away.) So the **human
operates ON the basin** (the basin of attraction — the region of outcomes a walk settles
into: sets it, moves it, overrides, judges), and the **machine walks WITHIN it**. Precisely:
- **No perfect judge.** The human errs too — the justification for measurement (§6).
- **Judgment splits:** deterministic gates judge the *mechanical*, humans the *meaningful*
  — together, the **Verification Dual**.
- **The IBC (Initial Boundary Condition) is the transducer.** Human intent is often
  underspecified, and the machine's failure mode is *acting on insufficient information* →
  drift. The IBC converts underspecified intent into a *sufficient boundary* a raw agent
  executes without drift.
- **The second floor — why oversight cannot be model-on-model.** Disparate `θ` share
  training corpora, architectures, and tuning conventions, so their errors are *positively
  correlated*: they can confidently **agree and be jointly wrong**. This floor is not
  hypothetical and it is *widening*: measuring error overlap across 39 models on identical
  tasks, Goel et al. (2025) find that mistakes grow **more** similar as capability rises,
  and that a model judging others favors models similar to itself (also Panickssery et al.
  2024) — a direct result *against* model-on-model oversight; failures also transfer across
  vendors (Zou et al. 2023). Note the regime those results measure: models answering the
  **same** task and grading **the same** answers — homogeneous voting. librecode's response
  is to *not* verify that way. It composes disparate `θ` in **differentiated roles**, under
  **substrate-independent deterministic gates** and a **human**, because a shared blind spot
  survives both reprompting *and* role assignment (if reviewer and author share the bias,
  the review misses it). So more models cannot break the residual floor — the only genuinely
  different substrate is the human. And the human basin's independence is **graded, not
  binary** — two channels bind the substrates directly, beyond the human-side effects
  (automation bias from reading the machine's answer before judging; shared steward priors):
  `θ` is distilled *from human output*, so documented human misconceptions and cognitive
  biases are in `θ` by construction (LLMs reproduce them; Binz & Schulz 2023), and
  preference-tuning optimizes `θ` *against human judgment specifically*, teaching models to
  exploit its weaknesses (sycophancy; Sharma et al. 2023) — so on confident, fluent,
  plausible-but-wrong output, machine error and human approval are not independent draws.
  What survives, and what the human's authority actually stands on, are the error classes
  `θ` cannot reach: contact with the world, stakes and accountability, taste, long-horizon
  memory. The design consequences: treat human agreement with machine output as a
  *partially correlated* signal, not ground truth simpliciter (§6); **judge before being
  shown the machine's answer** where it matters; and govern **plural** with *deliberately
  unlike* stewards (suggestive support in the diversity-beats-ability literature — Hong &
  Page 2004, though its formal core is contested). Novel or high-stakes work stays in the
  human loop even on ensemble agreement. This deliberately spends the scarcest resource —
  human attention — where it is decisive, which is the cost the economy of §6–7 manages and
  the determinization ratchet shrinks as work moves from novel to routine.

### 4 · The coordination mechanics — why a deterministic bounding layer
Coordination on a shared resource, under many uncoordinated walkers, degrades it — and the
resource is genuinely **rivalrous**, which is what lets common-pool-resource theory apply:
the scarce, subtractive good is the stewards' **attention and review capacity** (spent here,
gone there) and the **robustness of the commons and its people** (capture and exclusion
deplete it); the artifact's **coherence** is the derived good these protect, drained by
drift. Two depletion modes, not one. Where the walkers are *rational human contributors*,
the failure is **strategic**: each optimizing locally has no incentive to preserve the
shared good — the free-rider result underlying the tragedy of the commons (Hardin 1968 as
the game-theoretic null; Ostrom's program below shows its *inevitability* claim false).
Where the walker is a *machine*, the failure is **not** strategic — an LLM gains nothing
from incoherence — but **entropic**: open-loop generation drifts by default, depleting the
same resource with no intent to. The layer must bound both.

The fix is mode-matched, and its grounding splits with it. For the **strategic** mode it is
mechanism design: change the payoff so cooperation is stable (the logic of graduated
reciprocity; Axelrod 1984) — make defection **detectable**, **costly and bounded**
(a graduated response that cannot propagate), and
**individually irrational** (contribution proportional to benefit), and make the game
**decomposable**. For the **entropic** mode the same machinery acts not as incentive but as
**closed-loop control** — detection, bounded correction, rollback — standing on engineering
merits rather than game theory (the strategic-mode citations ground the human half only, and
are not claimed for the machine half). Both realized as a deterministic bounding layer whose state is an **append-only,
immutable, replayable statespace** — an established coordination-friendly substrate (Helland
2015) — which is also the **context substrate** (context is *reconstructed, not recalled*).
Proof is **monotonic** (a passed gate never silently un-passes; a proven result is never
lost); the **plan is regressable** — reset-to-checkpoint (a standard rollback-recovery
discipline; Elnozahy et al. 2002) or cut-clean-and-decorrelate. The recovery ladder
(retry→rework→skip→escalate) is the condition/restart shape from the Lisp tradition: signal,
offer restarts, resume without unwinding (Pitman 2001) — decorrelation as *recovery*, not
only detection.

### 5 · The layer = the coordination mechanisms, reified
The bounding layer reifies the §4 mechanisms as **machine-enforced state**, composed with
the disparate-`θ` production of §1–3: *governance ⊕ decorrelated production*; neither alone
is the layer. That these mechanisms durably stabilize a real commons is an empirical result:
Ostrom's (1990) eight design principles for long-enduring common-pool-resource institutions,
empirically supported across a 91-study meta-analysis (Cox et al. 2010 — which also proposes
refining three of the principles) and extended to polycentric, nested governance (Ostrom
2010). We cite this as *validation of the mechanism*; the argument is the mechanism (§4), not
the name. (What is built versus designed is tracked in `AGENTS.md` and the roadmap, not here.)

| Coordination mechanism (§4) | Reified as | Ostrom instance |
|---|---|---|
| Detectable boundaries | IBC + `file_surface`; authority gate | clear boundaries |
| Costly, bounded defection | recovery ladder | graduated sanctions |
| Detection | gates + auditor + maintainer + hooks | monitoring |
| Decomposition | goal-nesting; alignment-to-parent | nested/polycentric |
| Rules fit the game | DAG (directed-acyclic work graph) amendment; stewards revise the IBC | collective-choice |
| Contain escalation | delegation table; decorrelated review | conflict-resolution |
| Cost ∝ benefit | ceremony ∝ task; gate strength ∝ drift-risk | congruence |
| Un-capturable | freedom; runner stands alone; no lock-in (§2) | right to organize |

**Scope is plural.** The governed unit is a **commons** (stewards + its many projects); the
metaharness may govern more than one at once, under **plural-human** governance.
Single-project or single-human operation is a special case, never an assumption. That
Ostrom's principles — validated for *human* commons — transfer to a commons whose
contributors are stochastic model-walkers is itself a hypothesis under test, not an
established result (see **The novelty boundary**).

**The commons is concrete — it is the council.** Its governance mechanism (design §2) is a
delegation table over an arbitrary set of seats — machine reviewers *and* human stakeholders
alike — where each decision-type names the assent it requires. "No progress on X until Alice and
Bob both sign off" is not a special case; it is a delegation edge with required-assent
`{alice, bob}` — a hard, human-gated dependency in the work graph, enforced like any deterministic
gate rather than tracked out-of-band. Disparate isolated sessions (each stakeholder on their own
harness) become a **single coherent view** into ongoing work through the shared append-only
statespace (§4). Machine and human contributors meet the same **governance substrate**, though
for different reasons: disparate `θ` are composed to *exploit* their difference (§1);
heterogeneous human stakeholders, because their difference cannot be *eliminated* — you cannot
make real contributors homogeneous. One layer governs both.

This coordination — managing the dependencies among many contributors' activities (Malone &
Crowston 1994) — is not overhead incidental to the work; in large efforts it is frequently the
dominant cost and the deciding factor. Coordination load grows super-linearly with contributors
(Brooks 1975), a system's structure tracks its organization's communication structure (Conway
1968), and shared cognition across a team measurably predicts its performance (DeChurch &
Mesmer-Magnus 2010). Sustained, coherent alignment on long-horizon goals is often what separates
large groups that succeed from those that fail — which is precisely the resource (the artifact's
coherence and the commons' robustness, §4) this layer exists to maintain.

### 6 · The living coherence loop — measurement without an oracle
No perfect judge (§3) means the layer cannot be static: the resource's health must be
**measured** and attention **adapted** where it degrades. A dense deterministic telemetry
bed (iterations-to-gate, rework/escalation/gate-fail rates, decorrelation rounds — sliced by
basin/content-type/project/time) is anchored by the sparse but authoritative **human quality
signal**, which overrides agent self-metrics; models are least calibrated exactly
off-distribution, growing *more* confident as they get *worse* under shift (Ovadia et al.
2019), and a calibrated model must hallucinate on rarely-seen facts as a matter of
information theory (Kalai & Vempala 2024).

- **Divergence-from-plan alerts the human in real time** — a seam beyond novelty.
- **The convergence caveat (from §3, load-bearing):** slow convergence signals novelty, but
  *correlated* hallucination produces **fast, confident agreement**, which a naive
  convergence metric misreads as *health* in exactly the novel regime we target (the Goel et
  al. 2025 finding). So the novelty trigger must include a signal **independent of
  convergence** (cross-*substrate* disagreement, or a human spot-check), and
  confident-fast-agreement on novel work routes **to the human**, never away.

### 7 · The composition medium — the human seam
Human and machine compose through a **message-first medium that surfaces exactly the genuine
seams and nothing else** (throughput is scarce): novelty-bounding, divergence-alert,
coherence-judgment. The composition is **heterogeneous + externally verified** — and the
answer-aggregation literature cuts both ways, so we cite both: mixed-model aggregation can
improve output (Mixture-of-Agents, Wang et al. 2024), yet aggregating samples of the single
*best* model has been shown to beat the mixed ensemble where member-quality gaps dominate the
diversity gain (Li et al. 2025), naive multi-agent debate does not reliably beat cheaper
baselines (Smit et al. 2024), and models cannot self-correct without an external signal
(Huang et al. 2024). librecode's composition is **role-differentiated production under
external checks**, not answer aggregation — so neither MoA result attaches to it directly,
and the regime where disparate-`θ` composition pays (verification and review, vs. raw
generation quality) is exactly what the early cross-model probe must measure (roadmap) —
which is why the *verification* is deterministic gates and a human, not agents grading
themselves. Aggregation supplies candidates; the external checks decide. Agents are primed to know their arsenal and owe *generative*
reports (trade-offs, decisions-and-why, goal-fit, suggestions that spark), which makes the
human's catch of a correlated hallucination cheap. Concrete transport and UI are design, not
principle.

### 8 · "Stable" — the metric
The metaharness is **stable** when, for any agent composition:
- **(static)** the bounding-layer invariants hold — **tamper-evident monotonic progress**,
  bounded+recoverable divergence, seams surfaced never crossed silently, decorrelated
  composition; **and**
- **(dynamic)** the measured coherence health is good and self-correcting — a living commons
  that detects and repairs its own degradation.

The static half is specifiable now. The dynamic half is **not yet checkable** — there is no
threshold — and is deferred to a machine-checked spec grounded against the running
metaharness (roadmap A). Until then "stable" is only half-checkable, and the missing half is
the distinctively living-commons claim.

Read *decorrelated composition* at the `θ` level (§1): it means composing disparate models,
or the gates and the human — not lens-variation on a single `θ`, which sits below §1's floor
and does not count. Which mechanisms are built versus designed is tracked in the roadmap and
`AGENTS.md`, not here; this document defines the target, not the current state.

**"Tamper-evident", precisely — the threat model.** Two properties travel here and only one
is machine-checkable. *Ledger integrity* — the record "gate G passed deposit D at position P"
is authentic, append-only, and gate-parameterized (the agent never sets the terms of its own
checking) — **is** the static invariant, and it is checkable. *Work validity* — that G passing
means the work is actually done — is **not** machine-checkable in general, because the agent
authors the *subjects* of the evaluators (the code, and often the tests): weakening the
checked subject forges "progress" through an honest gate. That vector is not hypothetical —
this project's own shutdown regression rode it (the test was removed and the gate stayed
green). The countermeasures are the review layer (pass is necessary, never sufficient) and
contracts on the *evaluator surface itself* (e.g., a test deleted or weakened without a
linked decision fails the gate). The stability metric claims the first property; it never
claims the second.

---

## The novelty boundary
Every mechanism above is grounded (References). What is novel and, to our search, without
prior art is the **system-level synthesis**: composing disparate `θ` under a deterministic,
machine-enforced governance layer that reifies commons mechanisms as append-only state and
*measures its own coherence health, adapting scaffolding inversely to certainty*. Five
elements are specifically unverified — contributions, not citations:
1. **The determinization ratchet** (below): that *hunting new gates* grows the deterministic
   surface and recedes the uncertain frontier as the commons matures. The static half —
   defer-uncertain-to-human — has prior art; the ratcheting dynamic, to our search, does not.
2. **The dynamic-stability metric** (§8): the living-commons half, which we concede is not
   yet checkable — the single largest unverified claim.
3. **Transfer of Ostrom's principles** from human institutions to a human+machine commons.
4. **The magnitude of §1's benefit** for long-horizon software specifically — that disparate
   `θ` beat the best single model, and by how much. The direction is well-motivated by the
   `θ`-floor; the magnitude is what measurement must settle — and settle *early*, because our
   own §3 evidence says the diversity term shrinks as frontier models converge (Goel et al.
   2025) and the aggregation literature shows regimes where mixing loses to the best single
   model (Li et al. 2025). The bet is live in the verification/review regime we actually
   compose in; an early cross-model probe is scheduled rather than deferred (roadmap). This is
   a race against time as much as a measurement: model-internal long-horizon coherence is
   improving on its own trajectory, so the orchestration delta this project bets on is being
   squeezed from both ends — shrinking diversity and a shrinking need for external
   coordination — and the measurement has to outrun that squeeze, not merely happen eventually.
5. **The human-attention economy.** The ratchet (below) accounts for what determinization
   *saves*; nothing here yet totals what governance *spends* — IBC authoring, promotion
   ratification, escalation judgment, close-time quality scalars, decorrelated
   audit-sampling. There is plausibly a team size or work cadence below which the metaharness
   is attention-*negative* relative to unmediated review, and no threshold is derived. This is
   a debt the roadmap must retire (a priced assumption or a measurement), not a footnote to
   defer indefinitely.

Each mechanism is grounded; the synthesis is the hypothesis this project exists to verify.

## Congruence inverted on certainty — the determinization ratchet
Scaffolding is deployed inversely to certainty (a dynamic form of "cost ∝ benefit", §5).
Where certainty is lowest — novel, near the reach boundary, high divergence — deploy the
maximum: full decorrelation and every applicable check. Where a boundary can be made
machine-decidable, convert it, along a gradient of instruments: from **sharpened prose** (a
more specific, less ambiguous procedure) to a **contract** (that procedure's declarative
target — a typed record that must be filled and checked) enforced by a **gate**. Routing
uncertain cases to heavier scrutiny and to the human is itself established (selective
prediction and learning-to-defer; El-Yaniv & Wiener 2010; Mozannar & Sontag 2020); what is
ours is the *ratchet* — that a meta-review hunts *new* determinizations, so the machine-checked
surface grows and the uncertain frontier recedes as the commons matures. That surface has a
ceiling: some coherence properties are undecidable in principle (Rice), so the frontier
recedes toward a floor, not to zero. Where certainty is high, ceremony collapses. And the
ratchet is the system's *economy*, not only its rigor: every check moved into a
machine-decidable contract is one no longer paid for with a scarce council seat or a human
minute, so determinization buys **throughput** — it relocates verification from the expensive
tier to the near-free one, run on every deposit. That economy has a failure mode the loop must
instrument against, because every friction signal is blind to it: a **false-accepting**
contract (wrongly specified, passing what it should fail) *reduces* fill-failures and rework —
reading as improved health on every friction metric — while the ratchet's own economy removes
the human review that would catch it, and the two ratchet signals can never fire (nothing
fails to fill; nothing recurs un-contracted). This is §6's convergence caveat applied to the
gate layer itself, and it compounds. The counter-instruments are non-optional: **periodic
decorrelated audit-sampling of gate-passed deposits**, and **close-time attribution** from the
human quality scalar back to the contracts that passed the judged work (design §6).

**A caveat the ratchet does not resolve.** Its economy pays out precisely where certainty
is already high — recurring, machine-decidable work — and is by design inert on the
frontier it exists to protect: the genuinely novel work this project claims to matter most
for gets none of the ratchet's throughput gain, only its ceremony. There the system's
honest floor is close to unmediated human review plus the cost of authoring and ratifying
the boundary around it (the human-attention economy, above) — a cost the roadmap must
measure, not assume away.

The engine that drives the ratchet is the self-governing instruction layer, next.

## The self-governing instruction layer
The metaharness owns its own **prose procedures** and **contracts** as versioned, committable
artifacts, and governs them the way it governs work — the self-similarity pattern turned on
the harness itself.

Two artifacts in a control loop. A **prose procedure** is the actionable means — *do X, then
Y* — direct and low-risk, the thing an agent can act on. A **contract** is the declarative
*target*: a typed record with a slot per step (*what was done for X, for Y*) whose filled
instance must type-check and meet its invariants, or fail unambiguously — no judgment. The
prose aims to fill the contract; the filled instance *is* the audit trail, since the record
and the check are one object. That is why sharpening prose serves auditability and not only
correctness (§4: the history is the deliverable). The contract is the stable setpoint, edited
rarely; the prose is the adaptive means, refined often.

The contract's deepest purpose is **reconstructability**. Because the empty contract is the
plan, filling it is the doing, and the partial fill is the exact resumption state,
plan/execution/record collapse into one artifact — leaving no gap between them for context to
leak out of. A reader with *no* prior context — a later session, a different agent, the human
months on — can open the contract and see what was attempted, what is done, and where it
stopped; with the immutable ledger (§4) alongside, that reader rebuilds whatever else it needs.
This is the system's load-bearing purpose: never to reach the most corrosive failure of agentic
work — where too much was done too fast, the context that explains it is gone, and good state
can no longer be told from bad (the trajectory has gone *unfalsifiable*). The context-free
reader is the **primary** consumer, because context loss — compaction, a new session, a new
agent — is the normal case, not the exception; every artifact is built to suffice for someone
holding nothing but the artifact. It also makes review tractable: the reviewer reads the
contract's reasoning against its co-located evidence rather than reconstructing the work from a
diff, and *thin* fill relative to what a step demanded is a heat map for where scrutiny should
go. Two guards keep it honest — slots must demand **evidence** (a re-runnable evaluator, a
`file:line`, a checkable object), not bare prose a capable agent can fill convincingly without
having done the thing; and they must capture the **why**, not only the *what*, since the
repercussions that surface late live in intent, not in the diff.

The metaharness has a vantage no single walk has — it sees the *same* procedure across many
sessions — and reads two signals from it:
- **Repeated failure to fill a contract** ⇒ the prose is too coarse; refine the prose.
- **A recurring, un-contracted area** ⇒ a pattern stable enough to reify; author a contract.

The first sharpens the means toward a fixed target; the second raises a new target where
behavior has stabilized. Neither reaches novel work — *recurrence itself* is the signal that a
procedure is stable enough to bind, so binding it never constrains the genuinely new
(congruence-∝-certainty).

The artifacts layer by scope: a **default basin ships** with the harness and is refined **per
commons, per project, per operator** (a project's formatter, its issue tracker, its house
procedure). A refinement that proves itself *across sessions* is **promoted upward** toward
the default base. The layering is asymmetric where it must be: prose is freely refinable — it
is guidance, bounded by the contracts — while an **immutable core of contracts cannot be
modified at any scope**: the system's own invariants, the §8 static floor. Scoped contracts
*add* requirements within that floor and cannot relax it, exactly as a nested goal must stay
inside its parent — a move that loosened the core would be a defeater. Editing the core, or
promoting a refinement into the shipped default, is a **privileged, human-ratified** act: the
harness may propose its own constitution but not self-author it (the recurring pattern's
dual-trigger, cost scaled by blast radius — a per-operator tweak is local and cheap; a change
to what ships for everyone is constitutional).

This layer is the concrete form of the living loop's actuator (design §4) and the procedural
half of durable memory (git-backed how-to; roadmap C). The checking half is not hypothetical:
the tooling this project is built with already validates machine-written deposits against
exactly such typed contracts — and those contracts may carry *arbitrarily rigorous* computation
(a real graph algorithm proving a plan is a valid, conflict-free DAG, run purely as the gate),
safe precisely because the contract is **trusted, human-authored** code checking **untrusted,
machine-authored** data: the same human/machine line as the immutable core. That line extends to
the *terms* of checking — the agent supplies work and its record of it, never the parameters that
decide how it is verified: at every deterministic gate the phase to check and the contract to
apply are machine-derived from execution state (the DAG), overriding any value the agent declared
(advisory only, for self-description or a manual self-check). The checker composes
loosely rather than as a hard dependency — where it is absent the system **degrades** rather
than failing, and the degradation has exact semantics: deposits still land durably (work
capture keeps its liveness) but are quarantined *validation-pending*, and **the DAG phase does
not advance past a gate on a pending deposit** — degradation defers *proof advancement*, never
proof-then-retract. So "a violating deposit cannot enter **proven** history" holds
unconditionally in both modes; a failed discharge reverts the pending node to rework with
nothing proven ever lost (§4's monotonicity intact); and the degradation is *recorded, never
silent* (design). What the absent checker costs is ratchet advancement, not work capture —
the right trade. Contract shaping for partial validation is design (design §7).

## The recurring pattern (self-similarity)
Wherever a boundary is inherently undecidable deterministically, the system uses one shape —
a deterministic flag + a non-deterministic judgment + human ratification (an instance of the
Verification Dual) — never pure-determinism (brittle) nor pure-judgment (ungovernable). It
recurs at the convening trigger, the rule-promotion trigger (authoring a contract; promoting a
refinement into the shipped core), and the accept/rework/escalate ladder.

## Scope rule (freedom)
- **Out:** deep integration with, or dependence on, proprietary systems (unverifiable black
  boxes; coupling is capture).
- **In:** proprietary models as arms-length ensemble members (a cheap local libre model
  driving a proprietary text-only harness) — their disparate `θ` without deep coupling. The
  line is dependence and transparency, not refusing proprietary outputs.
- **The runner stands alone; the metaharness augments — never assumed, never coupled.** Its
  governance reaches the runner only through hooks the runner exposes (the runner runs as
  pure-opencode with nothing attached; the metaharness is an optional consumer). The
  augmentation seam, and how much opencode already affords, are **[design → docs/design.md;
  open prior-art → roadmap G].**

## Completeness discipline
The foundation is complete when the concept↔procedure mapping is orphan-free — no concept
here without a procedure implementing it, no procedure in code without a concept it serves —
verified by continued decorrelated agreement across genuinely different substrates (human ↔
machine; and, for review, ideally cross-model).

## What derives from here (not before)
1. Formalize the §8 static invariants into a machine-checked spec, and give the dynamic half
   a real threshold, grounded against the running metaharness.
2. Scrutinize the five primitives the procedures reduce to (GROUND a basin, ARM an agent,
   COMPOSE production, capture INTENT, TRACK state) against §1–§8; settle context-management
   as a facet of the append-only statespace (§4).
3. Derive the roadmap: PoC → stable metaharness (§8 enforced) → opencode-compatible runner.

---

## References
- Krogh & Vedelsby (1995). Neural Network Ensembles, Cross Validation, and Active Learning. *NIPS 7*.
- Ueda & Nakano (1996). Generalization error of ensemble estimators. *ICNN'96*.
- Breiman (2001). Random Forests. *Machine Learning* 45(1).
- Wood, Mu, Reid & Brown (2023). A Unified Theory of Diversity in Ensemble Learning. *JMLR* 24.
- Goel, Strüber, Auzina, et al. (2025). Great Models Think Alike and this Undermines AI Oversight. *ICML 2025* (arXiv:2502.04313).
- Bommasani, Hudson, Adeli, et al. (2021). On the Opportunities and Risks of Foundation Models. arXiv:2108.07258 (§ Homogenization).
- Kleinberg & Raghavan (2021). Algorithmic monoculture and social welfare. *PNAS* 118(22).
- Zou, Wang, Kolter & Fredrikson (2023). Universal and Transferable Adversarial Attacks on Aligned Language Models. arXiv:2307.15043.
- Panickssery, Bowman & Feng (2024). LLM Evaluators Recognize and Favor Their Own Generations. *NeurIPS 2024*.
- Wang, Wang, Athiwaratkun, et al. (2024). Mixture-of-Agents Enhances Large Language Model Capabilities. arXiv:2406.04692.
- Li, Xu, et al. (2025). Rethinking Mixture-of-Agents: Is Mixing Different Large Language Models Beneficial? arXiv:2502.00674.
- Binz & Schulz (2023). Using cognitive psychology to understand GPT-3. *PNAS* 120(6).
- Sharma, Tong, et al. (2023). Towards Understanding Sycophancy in Language Models. arXiv:2310.13548.
- Smit, Duckworth, Grinsztajn, et al. (2024). Should We Be Going MAD? A Look at Multi-Agent Debate Strategies for LLMs. *ICML 2024* (arXiv:2311.17371).
- Huang, Chen, Mishra, et al. (2024). Large Language Models Cannot Self-Correct Reasoning Yet. *ICLR 2024* (arXiv:2310.01798).
- Ostrom (1990). *Governing the Commons*. Cambridge University Press.
- Cox, Arnold & Villamayor-Tomás (2010). A Review of Design Principles for Community-Based Natural Resource Management. *Ecology and Society* 15(4):38.
- Ostrom (2010). Beyond Markets and States: Polycentric Governance of Complex Economic Systems. *American Economic Review* 100(3).
- Malone & Crowston (1994). The Interdisciplinary Study of Coordination. *ACM Computing Surveys* 26(1).
- Brooks (1975). *The Mythical Man-Month*. Addison-Wesley.
- Conway (1968). How Do Committees Invent? *Datamation*, April 1968.
- DeChurch & Mesmer-Magnus (2010). The Cognitive Underpinnings of Effective Teamwork: A Meta-Analysis. *Journal of Applied Psychology* 95(1).
- Hong & Page (2004). Groups of Diverse Problem Solvers Can Outperform Groups of High-Ability Problem Solvers. *PNAS* 101(46).
- Hardin (1968). The Tragedy of the Commons. *Science* 162(3859).
- Axelrod (1984). *The Evolution of Cooperation*. Basic Books.
- Kalai & Vempala (2024). Calibrated Language Models Must Hallucinate. *STOC 2024* (arXiv:2311.14648).
- Ovadia, Fertig, Ren, et al. (2019). Can You Trust Your Model's Uncertainty? *NeurIPS 2019*.
- El-Yaniv & Wiener (2010). On the Foundations of Noise-free Selective Classification. *JMLR* 11.
- Mozannar & Sontag (2020). Consistent Estimators for Learning to Defer to an Expert. *ICML 2020*.
- Helland (2015). Immutability Changes Everything. *CIDR 2015* / *ACM Queue* 13(9).
- Pitman (2001). Condition Handling in the Lisp Language Family.
- Elnozahy, Alvisi, Wang & Johnson (2002). A Survey of Rollback-Recovery Protocols in Message-Passing Systems. *ACM Computing Surveys* 34(3).
