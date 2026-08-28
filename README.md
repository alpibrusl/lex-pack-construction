# lex-pack-construction

Construction domain pack — milestone payments doubly gated on hash-chained evidence and an x402/lex-guard budget cap, with AI-Act-style human oversight above a review threshold.

Extracted from [`lex-ev-fleet`](https://github.com/alpibrusl/lex-ev-fleet) (see [issue #238](https://github.com/alpibrusl/lex-ev-fleet/issues/238)). No cross-pack dependency — reuses the evidence-gate pattern conceptually, not by importing any other pack.

## Routes

```
POST /construction/contracts             — {contract_ref, client_agent, contractor_agent, retention_pct, budget_total_eur?, budget_per_milestone_eur?, review_above_eur?, milestones:[{ref,title,amount_eur,required_evidence:[..]}]}
POST /construction/evidence              — {contract_ref, milestone_ref, kind, hash, by}
POST /construction/milestones/release    — {contract_ref, milestone_ref, approval?:{approver,ref,amount_eur}}: pay iff evidence proves AND the budget authorizes AND (below review threshold OR a matching approval is present)
GET  /construction/contracts/:ref/statement — milestones, evidence, paid/held, budget, chain_intact
```

## Usage

```lex
import "lex-pack-construction/construction" as construction

# in your router-wiring code:
let r := construction.mount(router.new(), db)
```

`construction.manifest()` returns the `pos.PackManifest` describing this pack's parties/pattern for the `lex-soft/src/positions` catalogue.

## Layering

Part of the lex-soft pack family: `lex-soft` (engine, primitives) → this pack (`mount()` for the HTTP routes, `manifest()` for the `lex-soft/src/positions` catalogue) → [`lex-soft-node`](https://github.com/alpibrusl/lex-soft-node) (mounts a configured set of packs into a running deployment).

## License


Copyright (c) 2026 lex-pack-construction contributors.

Licensed under the [EUPL-1.2](LICENSE) — the European Union Public Licence, as used across the `lex-*` ecosystem.

