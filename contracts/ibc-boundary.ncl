# Structured dispatch-boundary grant contract.
#
# Gates the record that will replace campaign-node's bare-string `ibc` slot
# (src/meta/campaign.lisp:24) at dispatch time: the machine-checkable
# authorization a walker runs under, named "boundary" (not "deposit",
# "contract", or "verdict" — those describe src/model's landed-work gating,
# a different concept; docs/model.md:55-63). The rework-diagnostic — a
# genuinely different concept, previously complected into the same slot —
# is decomplected into its own field below rather than folded back into
# the boundary grant.
#
# Usage:
#   nickel export <boundary>.yaml --apply-contract contracts/ibc-boundary.ncl
#
# All four fields are REQUIRED (no `optional` qualifier, no default) — a
# grant with any field omitted fails this record contract's built-in
# missing-field check, so `nickel export` alone is the gate; no extra
# presence logic is needed (mirrors the sibling predicate repo's
# worker_ibc.ncl `Worker` record: presence is intrinsic to a typed record
# contract, not something to hand-roll on top of one).
{
  # MUST the walker be authorized to commit within its declared file_surface?
  may_commit
    | doc "whether this dispatch grants commit authorization"
    | Bool,

  # The paths/globs this dispatch may touch — the walker's authorized surface.
  file_surface
    | doc "paths/globs this dispatch is authorized to modify"
    | Array String,

  # Reserved halt predicates this dispatch must freeze against rather than
  # improvise past (S3 "reserved" — the human's calls, not the walker's).
  halt_conditions
    | doc "conditions under which this dispatch MUST halt and report, not improvise"
    | Array String,

  # The base dispatch instructions fed to the harness as the initial prompt.
  prompt
    | doc "the base instructions the harness reads at dispatch"
    | String,
}
