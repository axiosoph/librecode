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
is **abundant** in throughput. A **human** is a stochastic walker **unbounded** by any
known `θ`, but **scarce** in throughput (attention is the limiting resource). Both
asymmetries are load-bearing: unbounded reach drives §3, scarce throughput drives §6–7.

### 1 · Why disparate models — the decorrelation floor
Ensemble error-correction rests on a decomposition identity, not an intuition. For
squared error, an ensemble's error equals the average member error minus a non-negative
**diversity** (ambiguity) term (Krogh & Vedelsby 1995); equivalently, it falls only as the
inter-member error **covariance** falls (Ueda & Nakano 1996). Identical members contribute
zero diversity and no gain. A model's systematic errors — gaps in training, learned biases,
the outputs its tuning refuses — are properties of `θ`, invariant across how it is
prompted; two promptings of one `θ` therefore have errors correlated *through* `θ`, a floor
no reprompting crosses. Disparate `θ` have different biases that partially cancel. This is
the operating principle of random forests, where decorrelation reduces variance down to a
floor set by the residual correlation between trees (Breiman 2001).

Two honest bounds. First, a single model's reach is not one prompt but its whole
conditioning envelope `⋃_c` (in-context learning, chain-of-thought, retrieval, tools), so
disparate models buy less than a naive single-prompt comparison suggests; the claim is that
they buy something *material* on the model-bias term, which is empirical for a given domain,
not entailed — and cross-model error correlation appears to *grow* with capability (Goel et
al. 2025), so the margin is not guaranteed to widen. Second, "reachable region" means a
high-probability set, not literal support; the union of regions `⋃_θ` (across all available
models) is a useful informal model, not set algebra.

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
itself be **un-capturable** — which is what libre licensing provides. Freedom is the
enabling condition of a **trustable, capture-resistant governance layer**, not of the
composition mathematics. (Our scope rule — proprietary models allowed as arms-length members
— is consistent only under this reading.)

### 3 · The human/machine division — and the correlated-bias floor
Being unbounded, the human reaches outside any model's region (genuine novelty), is a
different-substrate check, and is the best judge of coherence and meaning. So the **human
operates ON the basin** (the basin of attraction — the region of outcomes a walk settles
into: sets it, moves it, overrides, judges), and the **machine walks WITHIN it**. Precisely:
- **No perfect judge.** The human errs too — the justification for measurement (§6).
- **Judgment splits:** deterministic gates judge the *mechanical*, humans the *meaningful*
  — together, the **Verification Dual**.
- **The IBC (Initial Boundary Condition) is the transducer.** Human intent is often
  underspecified, and the machine's failure mode is *acting on insufficient information* →
  drift. The IBC converts underspecified intent into a *sufficient boundary* a raw agent
  executes without drift.
- **The second, higher floor.** Disparate `θ` share training corpora, architectures, and
  tuning conventions, so their errors are *positively correlated*: they can confidently
  **agree and be jointly wrong**, and this shared error grows with capability (Goel et al.
  2025). Failures transfer across vendors (Zou et al. 2023), and a model judging others
  favors its own kind (Panickssery et al. 2024). Disparate models therefore do **not fully**
  break the floor; the only genuinely different substrate is the human — and a *single*
  human is itself one correlated basin, so governance is **plural-human** (multiple stewards
  are the human-side decorrelation), and novel or high-stakes work stays in the human loop
  even on ensemble agreement. This directly constrains §6.

### 4 · The coordination mechanics — why a deterministic bounding layer
Uncoordinated stochastic walkers on a shared resource is a **defection-dominant
equilibrium**: each, optimizing locally, has no incentive to preserve the shared good, so it
is depleted — the free-rider result underlying the tragedy of the commons (Hardin 1968, as
the game-theoretic null; Ostrom's program below shows the *inevitability* claim is false).
The shared resource is **dual**: the **coherence of the artifact** (drift depletes it) and
the **robustness of the commons and its people** (capture/exclusion deplete it).

The fix is mechanism design: change the payoff so cooperation is stable — make defection
**detectable**, **costly and bounded** (a graduated response that cannot propagate), and
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
validated across a 91-study meta-analysis (Cox et al. 2010) and extended to polycentric,
nested governance (Ostrom 2010). We cite this as *validation of the mechanism*; the argument
is the mechanism (§4), not the name.

| Coordination mechanism (§4) | Reified as | Ostrom instance | Status |
|---|---|---|---|
| Detectable boundaries | IBC + `file_surface`; authority gate | clear boundaries | built |
| Costly, bounded defection | recovery ladder | graduated sanctions | built |
| Detection | gates + auditor + maintainer + hooks | monitoring | built/partial |
| Decomposition | goal-nesting; alignment-to-parent | nested/polycentric | built |
| Rules fit the game | DAG (directed-acyclic work graph) amendment; stewards revise the IBC | collective-choice | partial |
| Contain escalation | delegation table; decorrelated review | conflict-resolution | partial |
| Cost ∝ benefit | ceremony ∝ task; gate strength ∝ drift-risk | congruence | partial |
| Un-capturable | freedom; runner stands alone; no lock-in (§2) | right to organize | stance |

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
statespace (§4). The same composition shape recurs at two scales: decorrelated machine `θ` (§1)
and heterogeneous human stakeholders — both composed under one governance layer. The metaharness
is heterogeneity-tolerant *by necessity*, because homogeneity across real contributors cannot be
enforced.

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
*different* models under external checks measurably improves output (Mixture-of-Agents, Wang
et al. 2024), whereas naive multi-agent debate does not reliably beat cheaper baselines
(Smit et al. 2024) and models cannot self-correct without an external signal (Huang et al.
2024) — which is precisely why librecode verifies with deterministic gates and a human, not
with agents grading themselves. Agents are primed to know their arsenal and owe *generative*
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

---

## The novelty boundary
Every mechanism above is grounded (References). What is novel and, to our search, without
prior art is the **system-level synthesis**: composing disparate `θ` under a deterministic,
machine-enforced governance layer that reifies commons mechanisms as append-only state and
*measures its own coherence health, adapting scaffolding inversely to certainty*. Four
elements are specifically unverified — contributions, not citations:
1. **The determinization ratchet** (below): that hunting for new deterministic gates makes
   the uncertain frontier monotonically recede as the commons matures.
2. **The dynamic-stability metric** (§8): the living-commons half, which we concede is not
   yet checkable — the single largest unverified claim.
3. **Transfer of Ostrom's principles** from human institutions to a human+machine commons.
4. **The magnitude of §1's benefit** for long-horizon software specifically (the sign is an
   identity; the magnitude is empirical, and Goel et al. 2025 suggests it is under pressure).

Each mechanism is grounded; the synthesis is the hypothesis this project exists to verify.

## Congruence inverted on certainty — the determinization ratchet
Scaffolding is deployed inversely to certainty (a dynamic form of "cost ∝ benefit", §5).
Where certainty is lowest — novel, near the reach boundary, high divergence — deploy the
maximum: full decorrelation, every applicable check, and a meta-review that hunts for a new
deterministic gate that converts the uncertainty into a permanent check. The intended effect
is compounding: the deterministic surface grows, the uncertain frontier recedes. Where
certainty is high, ceremony collapses.

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
- Goel, Prabhakar, Bardes, et al. (2025). Great Models Think Alike and this Undermines AI Oversight. *ICML 2025* (arXiv:2502.04313).
- Bommasani, Hudson, Adeli, et al. (2021). On the Opportunities and Risks of Foundation Models. arXiv:2108.07258 (§ Homogenization).
- Kleinberg & Raghavan (2021). Algorithmic monoculture and social welfare. *PNAS* 118(22).
- Zou, Wang, Kolter & Fredrikson (2023). Universal and Transferable Adversarial Attacks on Aligned Language Models. arXiv:2307.15043.
- Panickssery, Bowman & Feng (2024). LLM Evaluators Recognize and Favor Their Own Generations. *NeurIPS 2024*.
- Wang, Mao, Guo, et al. (2024). Mixture-of-Agents Enhances Large Language Model Capabilities. arXiv:2406.04692.
- Smit, Grinsztajn, Bou-Ammar, et al. (2024). Should We Be Going MAD? A Look at Multi-Agent Debate Strategies for LLMs. *ICML 2024* (arXiv:2311.17371).
- Huang, Chen, Mishra, et al. (2024). Large Language Models Cannot Self-Correct Reasoning Yet. *ICLR 2024* (arXiv:2310.01798).
- Ostrom (1990). *Governing the Commons*. Cambridge University Press.
- Cox, Arnold & Villamayor-Tomás (2010). A Review of Design Principles for Community-Based Natural Resource Management. *Ecology and Society* 15(4):38.
- Ostrom (2010). Beyond Markets and States: Polycentric Governance of Complex Economic Systems. *American Economic Review* 100(3).
- Malone & Crowston (1994). The Interdisciplinary Study of Coordination. *ACM Computing Surveys* 26(1).
- Brooks (1975). *The Mythical Man-Month*. Addison-Wesley.
- Conway (1968). How Do Committees Invent? *Datamation* 14(4).
- DeChurch & Mesmer-Magnus (2010). The Cognitive Underpinnings of Effective Teamwork: A Meta-Analysis. *Journal of Applied Psychology* 95(1).
- Hardin (1968). The Tragedy of the Commons. *Science* 162(3859).
- Kalai & Vempala (2024). Calibrated Language Models Must Hallucinate. *STOC 2024* (arXiv:2311.14648).
- Ovadia, Fertig, Ren, et al. (2019). Can You Trust Your Model's Uncertainty? *NeurIPS 2019*.
- Helland (2015). Immutability Changes Everything. *CIDR 2015* / *ACM Queue* 13(9).
- Pitman (2001). Condition Handling in the Lisp Language Family.
- Elnozahy, Alvisi, Wang & Johnson (2002). A Survey of Rollback-Recovery Protocols in Message-Passing Systems. *ACM Computing Surveys* 34(3).
