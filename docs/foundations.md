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
one session, short horizon, a bounded task. librecode's **runner** reimplements that.

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

## The argument

### Axiom — two stochastic walkers, with two asymmetries
A **machine** (LLM) is a stochastic walker **bounded** to a model `θ` (its weights, from
training + fine-tuning + safeguards): it samples only within `θ`'s reachable region, and
is **abundant** in throughput. A **human** is a stochastic walker on a **different
substrate whose bound cannot be written down** — not provably unbounded, but not
characterized by any known `θ`, and correlated with the machines only weakly and
indirectly — and is **scarce** in throughput (attention is the limiting resource). Two
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

### 3 · The human/machine division — and the correlated-bias floor
As a different substrate, the human's failures are not correlated *through* any `θ`: it is
the natural check on the machine floor, the reach into genuine novelty (work outside `⋃_θ`),
and — argued in §6, not assumed — the better judge of coherence and meaning. So the **human
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
  different substrate is the human. And the human basin is itself imperfectly independent: a
  reviewer who reads the machine's output before judging inherits its framing (automation
  bias), and stewards from one community share priors — the same correlation argument, run
  honestly against ourselves. The mitigations are structural, not magical: **judge before
  being shown the machine's answer** where it matters, and govern **plural** with
  *deliberately unlike* stewards (diverse problem-solvers can outperform more-able
  homogeneous ones — Hong & Page 2004). Novel or high-stakes work stays in the human loop
  even on ensemble agreement. This deliberately spends the scarcest resource — human
  attention — where it is decisive, which is the cost the economy of §6–7 manages and the
  determinization ratchet shrinks as work moves from novel to routine.

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

The fix is mechanism design: change the payoff so cooperation is stable (the logic of
graduated reciprocity; Axelrod 1984) — make defection **detectable**, **costly and bounded**
(a graduated response that cannot propagate), and
**individually irrational** (contribution proportional to benefit), and make the game
**decomposable**. Realized as a deterministic bounding layer whose state is an **append-only,
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
coherence-judgment. The composition is **heterogeneous + externally verified**: aggregating
*different* models measurably improves output (Mixture-of-Agents, Wang et al. 2024), while
naive multi-agent debate does not reliably beat cheaper baselines (Smit et al. 2024) and
models cannot self-correct without an external signal (Huang et al. 2024) — which is why the
*verification* is deterministic gates and a human, not agents grading themselves. Aggregation
supplies candidates; the external checks decide. Agents are primed to know their arsenal and owe *generative*
reports (trade-offs, decisions-and-why, goal-fit, suggestions that spark), which makes the
human's catch of a correlated hallucination cheap. Concrete transport and UI are design, not
principle.

### 8 · "Stable" — the metric
The metaharness is **stable** when, for any agent composition:
- **(static)** the bounding-layer invariants hold — monotonic unforgeable progress,
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

---

## The novelty boundary
Every mechanism above is grounded (References). What is novel and, to our search, without
prior art is the **system-level synthesis**: composing disparate `θ` under a deterministic,
machine-enforced governance layer that reifies commons mechanisms as append-only state and
*measures its own coherence health, adapting scaffolding inversely to certainty*. Four
elements are specifically unverified — contributions, not citations:
1. **The determinization ratchet** (below): that *hunting new gates* grows the deterministic
   surface and recedes the uncertain frontier as the commons matures. The static half —
   defer-uncertain-to-human — has prior art; the ratcheting dynamic, to our search, does not.
2. **The dynamic-stability metric** (§8): the living-commons half, which we concede is not
   yet checkable — the single largest unverified claim.
3. **Transfer of Ostrom's principles** from human institutions to a human+machine commons.
4. **The magnitude of §1's benefit** for long-horizon software specifically — that disparate
   `θ` beat the best single model, and by how much. The direction is well-motivated by the
   `θ`-floor; the magnitude is what measurement must settle.

Each mechanism is grounded; the synthesis is the hypothesis this project exists to verify.

## Congruence inverted on certainty — the determinization ratchet
Scaffolding is deployed inversely to certainty (a dynamic form of "cost ∝ benefit", §5).
Where certainty is lowest — novel, near the reach boundary, high divergence — deploy the
maximum: full decorrelation, every applicable check, and a meta-review that hunts for a new
deterministic gate that converts the uncertainty into a permanent check. Routing uncertain
cases to heavier scrutiny and to the human is itself established (selective prediction and
learning-to-defer; El-Yaniv & Wiener 2010; Mozannar & Sontag 2020); what is ours is the
*ratchet* — that the meta-review hunts *new* gates, so the deterministic surface grows and
the uncertain frontier recedes as the commons matures. That surface has a ceiling: some
coherence properties are undecidable in principle (Rice), so the frontier recedes toward a
floor, not to zero. Where certainty is high, ceremony collapses.

## The recurring pattern (self-similarity)
Wherever a boundary is inherently undecidable deterministically, the system uses one shape —
a deterministic flag + a non-deterministic judgment + human ratification (an instance of the
Verification Dual) — never pure-determinism (brittle) nor pure-judgment (ungovernable). It
recurs at the convening trigger, the rule-promotion trigger, and the accept/rework/escalate
ladder.

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
