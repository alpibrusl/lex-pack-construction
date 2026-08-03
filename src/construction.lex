# construction.lex — milestone payments gated on evidence (construction pack, #126).
#
# Subcontractor coordination with money attached: the platform's
# pay-against-proven-outcome thesis applied to the industry that invented the
# retention dispute. A CONTRACT names client, contractor, a retention
# percentage and a MILESTONE schedule; each milestone declares the EVIDENCE
# KINDS it requires (photo, inspection, load-test — domain data, not code).
# Evidence lands as hash-chained trail events per contract; RELEASE pays only
# when every required kind is on the chain AND the chain re-verifies — no
# evidence, no euros, and a refusal NAMES what is missing.
#
# A milestone release is DOUBLY gated (#126). The evidence gate decides whether
# the outcome is proven (every required kind on the chain, chain re-verifies).
# The x402 gate decides whether the payment is AUTHORIZED: a contract carries a
# BUDGET TOKEN (a lex-guard Policy — total cap + per-milestone cap), and each
# release runs through gate.spend, which records a spend intent on the trail,
# checks it against the budget's rolling caps, and either executes an x402
# payment (deterministic mock settlement — the tx hash a facilitator would
# return) or DENIES it. An over-budget release is denied and recorded, never
# silently paid — the pay-against-proven-outcome thesis now also enforces
# pay-within-authorized-budget. A contract with no budget token (both caps 0)
# authorizes freely, so existing contracts are unchanged.
#
# On approval the money still lands as before: the retention slice held back,
# the net an L1 chargeback on the settlement trail (client -> contractor,
# aggregates in /usage), now stamped with the x402 tx reference. Equipment
# handoffs reuse the custody chain; crane/site windows reuse the lex-tms slot
# inventory. Exceptions escalate through the existing dispute routes.
#
# AIA-03: enforced human oversight. A release at or above the contract's
# review_above_cents needs an explicit human approval (bound to this
# amount+contractor) via gate.spend_reviewed, or it is held — an in-budget
# release can no longer auto-settle with no human. A held release answers
# HTTP 202 (requires_human_approval, resubmit with a matching approval); a
# release the budget itself refuses (over cap, no approval involved) answers
# HTTP 402 as before — the denial is on the trail either way, unpaid.
#
#   POST /construction/contracts             — {contract_ref, client_agent, contractor_agent, retention_pct, budget_total_eur?, budget_per_milestone_eur?, review_above_eur?, milestones:[{ref,title,amount_eur,required_evidence:[..]}]}
#   POST /construction/evidence              — {contract_ref, milestone_ref, kind, hash, by}
#   POST /construction/milestones/release    — {contract_ref, milestone_ref, approval?:{approver,ref,amount_eur}}: pay iff evidence proves AND the budget authorizes AND (below review threshold OR a matching approval is present)
#   GET  /construction/contracts/:ref/statement — milestones, evidence, paid/held, budget, chain_intact
#
# Domain pack over the lex-soft core. Zero core changes.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.float" as float

import "std.time" as time

import "std.sql" as sql

import "std.crypto" as crypto

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/log" as tlog

import "lex-soft/src/settlement" as settlement

import "lex-soft/src/evidence" as evidence

import "lex-money/src/decimal" as mdec

import "lex-money/src/money" as money

import "lex-money/src/rounding" as mround

import "lex-guard/src/gate" as gate

import "lex-guard/src/models" as gmodels

import "lex-soft/src/positions" as pos

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# The amount as the caller WROTE it (string passes through; number rendered once).
fn jdec(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => str.trim(s),
    Some(JFloat(v)) => float.to_str(v),
    Some(JInt(n)) => int.to_str(n),
    _ => "",
  }
}

fn jnum(j :: jv.Json, key :: Str, dflt :: Float) -> Float {
  match jv.get_field(j, key) {
    Some(JFloat(v)) => v,
    Some(JInt(n)) => int.to_float(n),
    Some(JStr(s)) => match jv.parse(s) {
      Ok(JFloat(v)) => v,
      Ok(JInt(n)) => int.to_float(n),
      _ => dflt,
    },
    _ => dflt,
  }
}

fn jlist(j :: jv.Json, key :: Str) -> List[jv.Json] {
  match jv.get_field(j, key) {
    Some(JList(xs)) => xs,
    _ => [],
  }
}

fn row_str(row :: sql.Row, k :: Str) -> Str {
  match sql.get_str(row, k) {
    Some(v) => v,
    None => "",
  }
}

fn row_float(row :: sql.Row, k :: Str) -> Float {
  match sql.get_float(row, k) {
    Some(v) => v,
    None => 0.0,
  }
}

fn row_int(row :: sql.Row, k :: Str) -> Int {
  match sql.get_int(row, k) {
    Some(v) => v,
    None => 0,
  }
}

# Portable DDL (SQLite + Postgres): TEXT / DOUBLE PRECISION / BIGINT only.
# NOT `REAL`: lex's Postgres driver binds PFloat params as Rust f64 (float8),
# which tokio-postgres refuses to serialize against a `REAL` (float4) column
# ("error serializing parameter N") — every INSERT/UPDATE touching that column
# fails client-side before it ever reaches Postgres. Same class of gotcha as
# `INTEGER` vs `BIGINT` for Int params; see reference_lex_postgres memory.
# The retention_pct/amount_eur/paid_eur/retention_eur ALTER COLUMN TYPE lines
# below widen already-deployed tables (created with the old `REAL` columns) in
# place: a no-op on SQLite (unsupported syntax, error discarded like the ADD
# COLUMN migrations above) and a no-op on Postgres once already widened.
fn ensure_tables(db :: Db) -> [sql] Unit {
  let __a := sql.exec(db, "ALTER TABLE construction_milestones ADD COLUMN amount_dec TEXT NOT NULL DEFAULT ''", [])
  let __bt := sql.exec(db, "ALTER TABLE construction_contracts ADD COLUMN budget_total_cents BIGINT NOT NULL DEFAULT 0", [])
  let __bp := sql.exec(db, "ALTER TABLE construction_contracts ADD COLUMN budget_per_ms_cents BIGINT NOT NULL DEFAULT 0", [])
  let __rv := sql.exec(db, "ALTER TABLE construction_contracts ADD COLUMN review_above_cents BIGINT NOT NULL DEFAULT 0", [])
  let __mx := sql.exec(db, "ALTER TABLE construction_milestones ADD COLUMN x402_tx TEXT NOT NULL DEFAULT ''", [])
  let __c := sql.exec(db, "CREATE TABLE IF NOT EXISTS construction_contracts (contract_ref TEXT PRIMARY KEY, client_agent TEXT NOT NULL, contractor_agent TEXT NOT NULL, retention_pct DOUBLE PRECISION NOT NULL DEFAULT 0, budget_total_cents BIGINT NOT NULL DEFAULT 0, budget_per_ms_cents BIGINT NOT NULL DEFAULT 0, created_ms BIGINT NOT NULL)", [])
  let __m := sql.exec(db, "CREATE TABLE IF NOT EXISTS construction_milestones (contract_ref TEXT NOT NULL, ref TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', amount_eur DOUBLE PRECISION NOT NULL, amount_dec TEXT NOT NULL DEFAULT '', required_kinds TEXT NOT NULL DEFAULT '', paid BIGINT NOT NULL DEFAULT 0, paid_eur DOUBLE PRECISION NOT NULL DEFAULT 0, retention_eur DOUBLE PRECISION NOT NULL DEFAULT 0, chargeback TEXT NOT NULL DEFAULT '', x402_tx TEXT NOT NULL DEFAULT '', PRIMARY KEY (contract_ref, ref))", [])
  let __rt := sql.exec(db, "ALTER TABLE construction_contracts ALTER COLUMN retention_pct TYPE DOUBLE PRECISION", [])
  let __ae := sql.exec(db, "ALTER TABLE construction_milestones ALTER COLUMN amount_eur TYPE DOUBLE PRECISION", [])
  let __pe := sql.exec(db, "ALTER TABLE construction_milestones ALTER COLUMN paid_eur TYPE DOUBLE PRECISION", [])
  let __re := sql.exec(db, "ALTER TABLE construction_milestones ALTER COLUMN retention_eur TYPE DOUBLE PRECISION", [])
  ()
}

type Contract = { client :: Str, contractor :: Str, retention_pct :: Float, budget_total_cents :: Int, budget_per_ms_cents :: Int, review_above_cents :: Int }

fn contract_for(db :: Db, ref :: Str) -> [sql] Option[Contract] {
  match sql.query(db, "SELECT client_agent, contractor_agent, retention_pct, budget_total_cents, budget_per_ms_cents, review_above_cents FROM construction_contracts WHERE contract_ref = ?", [PStr(ref)]) {
    Err(_) => None,
    Ok(rows) => match list.head(rows) {
      None => None,
      Some(row) => Some({ client: row_str(row, "client_agent"), contractor: row_str(row, "contractor_agent"), retention_pct: row_float(row, "retention_pct"), budget_total_cents: row_int(row, "budget_total_cents"), budget_per_ms_cents: row_int(row, "budget_per_ms_cents"), review_above_cents: row_int(row, "review_above_cents") }),
    },
  }
}

# The contract's budget token as a lex-guard Policy. cap 0 = no cap (guard's
# convention), so a contract created without a budget authorizes every release.
# The token scopes spending to the contractor as the sole merchant and the
# construction.milestone category — a release cannot be diverted elsewhere.
# A euro amount (as the caller wrote it) in exact cents — the unit the guard
# budget caps and spend intents work in. 0 (the default) means "no budget cap".
fn eur_to_cents(dec_str :: Str) -> Int {
  match money.parse(dec_str, Eur, HalfUp(())) {
    Some(m) => m.amount,
    None => 0,
  }
}

fn budget_policy(ct :: Contract, contract_ref :: Str) -> gmodels.Policy {
  { token_id: contract_ref, agent_id: ct.client, currency: "EUR", cap_total: ct.budget_total_cents, cap_per_day: 0, cap_per_transaction: ct.budget_per_ms_cents, merchants_allow: [ct.contractor], categories_allow: ["construction.milestone"], max_tx_per_hour: 0, expires_at: 0, require_memo: false, policy_version: 1 }
}

# The x402 settlement executor gate.spend runs on approval. This is the mock:
# a deterministic base58 tx hash — the reference a facilitator would return
# after settling — stable per distinct spend so it is replayable. It is a
# construction-LOCAL executor rather than lex-x402/x402_mock_exec on purpose:
# lex-x402's Solana `network.Family` type and lex-money's `currency.Currency`
# both export a nullary/unary `Unknown`, and lex resolves constructors globally,
# so the two libraries cannot coexist in one program (lex-x402#10). This
# module needs lex-money for the retention math, so it supplies its own executor
# — the x402 AUTHORIZATION (budget token, intent → caps → outcome on the trail)
# is entirely in lex-guard's `gate`, which is money-compatible; only the on-chain
# Solana rail lives in lex-x402, and the fleet settles off-chain.
fn mock_x402_exec(intent :: gmodels.SpendIntent) -> [net] Result[Str, Str] {
  Ok(crypto.base58_encode(bytes.from_str(crypto.sha256_str(str.join(["x402:", int.to_str(intent.amount), ":", intent.merchant, ":", intent.memo], "")))))
}

# Optional human approval from a release request. AIA-03: for releases at or
# above the contract's review threshold, gate.spend_reviewed refuses to execute
# without one, bound to the intent's amount (cents) + merchant so a stale or
# generic approval cannot unlock a different or larger release. In production
# `ref` should be a signed human-gateway decision id.
fn parse_approval(j :: jv.Json, merchant :: Str) -> Option[gmodels.HumanApproval] {
  match jv.get_field(j, "approval") {
    Some(aj) => match aj {
      JObj(_) => Some(({ approver: jstr(aj, "approver"), decision: "approve", amount: eur_to_cents(jdec(aj, "amount_eur")), merchant: merchant, ref: jstr(aj, "ref") } :: gmodels.HumanApproval)),
      _ => None,
    },
    None => None,
  }
}

# The tip of a contract's construction.* event chain (contract, evidence,
# releases) — the custody chain_tip precedent, keyed by contract_ref.
fn chain_tip(db :: Db, contract_ref :: Str) -> [sql] Option[Str] {
  let pat := str.concat("%\"contract_ref\":", str.concat(jv.stringify(JStr(contract_ref)), "%"))
  match sql.query(db, "SELECT id FROM events WHERE kind LIKE 'construction.%' AND payload_json LIKE ? ORDER BY ts_ms DESC LIMIT 1", [PStr(pat)]) {
    Err(_) => None,
    Ok(rows) => match list.head(rows) {
      None => None,
      Some(row) => Some(row_str(row, "id")),
    },
  }
}

# Evidence events recorded for one milestone: (kind, event_id) pairs.
fn evidence_for(db :: Db, contract_ref :: Str, milestone_ref :: Str) -> [sql] List[(Str, Str)] {
  let pc := str.concat("%\"contract_ref\":", str.concat(jv.stringify(JStr(contract_ref)), "%"))
  let pm := str.concat("%\"milestone_ref\":", str.concat(jv.stringify(JStr(milestone_ref)), "%"))
  match sql.query(db, "SELECT id, payload_json FROM events WHERE kind='construction.evidence' AND payload_json LIKE ? AND payload_json LIKE ? ORDER BY ts_ms ASC", [PStr(pc), PStr(pm)]) {
    Err(_) => [],
    Ok(rows) => list.map(rows, fn (row :: sql.Row) -> (Str, Str) {
      let kind := match jv.parse(row_str(row, "payload_json")) {
        Err(_) => "",
        Ok(p) => jstr(p, "kind"),
      }
      (kind, row_str(row, "id"))
    }),
  }
}

fn split_kinds(s :: Str) -> List[Str] {
  list.filter(str.split(s, ","), fn (k :: Str) -> Bool {
    not str.is_empty(str.trim(k))
  })
}

fn missing_kinds(required :: List[Str], have :: List[(Str, Str)]) -> List[Str] {
  list.filter(required, fn (need :: Str) -> Bool {
    list.is_empty(list.filter(have, fn (h :: (Str, Str)) -> Bool {
      match h {
        (kind, _) => str.cmp(str.trim(kind), str.trim(need)) == 0,
      }
    }))
  })
}

# Milestone release route: the chargeback (settlement.record_chargeback_dec)
# already moved money before the following `UPDATE construction_milestones SET
# paid = 1 ...` — if that write fails, the local `paid` flag didn't stick (so a
# retry would double-pay), so it must surface as an error, not a silent 201,
# even though the payment itself can't be rolled back automatically.
fn mount(r :: router.Router, db :: Db) -> [sql] router.Router {
  let __t := ensure_tables(db)
  let with_contracts := router.route_effectful(r, "POST", "/construction/contracts", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let ref := jstr(j, "contract_ref")
        let client := jstr(j, "client_agent")
        let contractor := jstr(j, "contractor_agent")
        let milestones := jlist(j, "milestones")
        if str.is_empty(ref) or str.is_empty(client) or str.is_empty(contractor) or list.is_empty(milestones) {
          resp.bad_request("{\"error\":\"contract_ref, client_agent, contractor_agent and a non-empty milestones list are required\"}")
        } else {
          let retention := jnum(j, "retention_pct", 0.0)
          let budget_total := eur_to_cents(jdec(j, "budget_total_eur"))
          let budget_per_ms := eur_to_cents(jdec(j, "budget_per_milestone_eur"))
          let review_above := eur_to_cents(jdec(j, "review_above_eur"))
          let now := time.now_ms()
          match sql.exec(db, "INSERT INTO construction_contracts (contract_ref, client_agent, contractor_agent, retention_pct, budget_total_cents, budget_per_ms_cents, review_above_cents, created_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (contract_ref) DO UPDATE SET client_agent = ?, contractor_agent = ?, retention_pct = ?, budget_total_cents = ?, budget_per_ms_cents = ?, review_above_cents = ?", [PStr(ref), PStr(client), PStr(contractor), PFloat(retention), PInt(budget_total), PInt(budget_per_ms), PInt(review_above), PInt(now), PStr(client), PStr(contractor), PFloat(retention), PInt(budget_total), PInt(budget_per_ms), PInt(review_above)]) {
            Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
            Ok(_) => {
              let ms_result := list.fold(milestones, Ok(()), fn (acc :: Result[Unit, Str], m :: jv.Json) -> [sql] Result[Unit, Str] {
                match acc {
                  Err(msg) => Err(msg),
                  Ok(_) => {
                    let mref := jstr(m, "ref")
                    if str.is_empty(mref) {
                      Ok(())
                    } else {
                      let kinds := str.join(list.map(jlist(m, "required_evidence"), fn (k :: jv.Json) -> Str {
                        match k {
                          JStr(s) => str.trim(s),
                          _ => "",
                        }
                      }), ",")
                      let amount_dec := match money.parse(jdec(m, "amount_eur"), Eur, HalfUp(())) {
                        Some(am) => money.format(am),
                        None => "",
                      }
                      match sql.exec(db, "INSERT INTO construction_milestones (contract_ref, ref, title, amount_eur, amount_dec, required_kinds) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (contract_ref, ref) DO UPDATE SET title = ?, amount_eur = ?, amount_dec = ?, required_kinds = ?", [PStr(ref), PStr(mref), PStr(jstr(m, "title")), PFloat(jnum(m, "amount_eur", 0.0)), PStr(amount_dec), PStr(kinds), PStr(jstr(m, "title")), PFloat(jnum(m, "amount_eur", 0.0)), PStr(amount_dec), PStr(kinds)]) {
                        Err(e) => Err(e.message),
                        Ok(_) => Ok(()),
                      }
                    }
                  },
                }
              })
              match ms_result {
                Err(msg) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(msg)), "}"))),
                Ok(_) => {
                  let log := settlement.trail_on(db)
                  let payload := jv.stringify(JObj([("contract_ref", JStr(ref)), ("agent", JStr(client)), ("client_agent", JStr(client)), ("contractor_agent", JStr(contractor)), ("retention_pct", JFloat(retention)), ("milestones", JInt(list.len(milestones)))]))
                  let __e := tlog.append(log, "construction.contract", chain_tip(db, ref), payload)
                  resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("contract_ref", JStr(ref)), ("milestones", JInt(list.len(milestones)))])))
                },
              }
            },
          }
        }
      },
    }
  })
  let with_evidence := router.route_effectful(with_contracts, "POST", "/construction/evidence", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let ref := jstr(j, "contract_ref")
        let mref := jstr(j, "milestone_ref")
        let kind := jstr(j, "kind")
        let hash := jstr(j, "hash")
        if str.is_empty(ref) or str.is_empty(mref) or str.is_empty(kind) or str.is_empty(hash) {
          resp.bad_request("{\"error\":\"contract_ref, milestone_ref, kind and hash are required\"}")
        } else {
          match contract_for(db, ref) {
            None => resp.json_status(404, "{\"error\":\"unknown contract\"}"),
            Some(ct) => {
              let log := settlement.trail_on(db)
              match evidence.record(log, "construction.evidence", ct.contractor, chain_tip(db, ref), [("contract_ref", JStr(ref)), ("milestone_ref", JStr(mref)), ("kind", JStr(kind)), ("hash", JStr(hash)), ("by", JStr(jstr(j, "by"))), ("agent", JStr(ct.contractor))]) {
                Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
                Ok(ev) => resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("event_id", JStr(ev.id)), ("kind", JStr(kind))]))),
              }
            },
          }
        }
      },
    }
  })
  let with_release := router.route_effectful(with_evidence, "POST", "/construction/milestones/release", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let ref := jstr(j, "contract_ref")
        let mref := jstr(j, "milestone_ref")
        match contract_for(db, ref) {
          None => resp.json_status(404, "{\"error\":\"unknown contract\"}"),
          Some(ct) => {
            let rows := match sql.query(db, "SELECT amount_eur, amount_dec, required_kinds, paid FROM construction_milestones WHERE contract_ref = ? AND ref = ?", [PStr(ref), PStr(mref)]) {
              Err(_) => [],
              Ok(rs) => rs,
            }
            match list.head(rows) {
              None => resp.json_status(404, "{\"error\":\"unknown milestone\"}"),
              Some(row) => {
                if row_int(row, "paid") == 1 {
                  resp.json_status(409, "{\"error\":\"milestone already released\"}")
                } else {
                  let required := split_kinds(row_str(row, "required_kinds"))
                  let have := evidence_for(db, ref, mref)
                  let missing := missing_kinds(required, have)
                  let log := settlement.trail_on(db)
                  let intact := match chain_tip(db, ref) {
                    None => false,
                    Some(tip) => settlement.verify(log, tip),
                  }
                  if not list.is_empty(missing) {
                    resp.json_status(409, jv.stringify(JObj([("error", JStr("evidence incomplete: milestone not payable")), ("missing_evidence", JList(list.map(missing, fn (m :: Str) -> jv.Json {
                      JStr(m)
                    })))])))
                  } else {
                    if not intact {
                      resp.json_status(409, "{\"error\":\"evidence chain failed verification: milestone not payable\"}")
                    } else {
                      let amount_src := if str.is_empty(row_str(row, "amount_dec")) {
                        float.to_str(row_float(row, "amount_eur"))
                      } else {
                        row_str(row, "amount_dec")
                      }
                      let amount_m := match money.parse(amount_src, Eur, HalfUp(())) {
                        Some(am) => am,
                        None => money.zero(Eur),
                      }
                      let pct_dec := match mdec.parse(float.to_str(ct.retention_pct)) {
                        Some(p) => p,
                        None => mdec.zero(),
                      }
                      let retention_m := money.scale(amount_m, mdec.mul(pct_dec, mdec.decimal(1, -2)), HalfUp(()))
                      let payable_m := match money.sub(amount_m, retention_m) {
                        Ok(pm) => pm,
                        Err(_) => amount_m,
                      }
                      let retention := int.to_float(retention_m.amount) / 100.0
                      let payable := int.to_float(payable_m.amount) / 100.0
                      let payable_dec := money.format(payable_m)
                      let retention_dec := money.format(retention_m)
                      let pay_ref := str.join([ref, "|", mref], "")
                      let policy := budget_policy(ct, ref)
                      let intent := { merchant: ct.contractor, amount: payable_m.amount, currency: "EUR", category: "construction.milestone", memo: pay_ref }
                      let approval := parse_approval(j, ct.contractor)
                      match gate.spend_reviewed(policy, log, mock_x402_exec, intent, ct.review_above_cents, approval) {
                        Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
                        Ok(outcome) => if not outcome.approved {
                          if str.starts_with(outcome.denial_reason, "human approval") {
                            resp.json_status(202, jv.stringify(JObj([("ok", JBool(false)), ("requires_human_approval", JBool(true)), ("reason", JStr(outcome.denial_reason)), ("amount_dec", JStr(payable_dec)), ("merchant", JStr(ct.contractor)), ("hint", JStr("resubmit with approval:{approver,ref,amount_eur} matching this amount"))])))
                          } else {
                            resp.json_status(402, jv.stringify(JObj([("error", JStr("payment not authorized by the contract budget token")), ("denied", JBool(true)), ("reason", JStr(outcome.denial_reason)), ("amount_dec", JStr(payable_dec))])))
                          }
                        } else {
                          match settlement.record_chargeback_dec(log, ct.client, ct.contractor, payable_dec, "EUR", pay_ref) {
                            Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
                            Ok(cb_id) => {
                              match sql.exec(db, "UPDATE construction_milestones SET paid = 1, paid_eur = ?, retention_eur = ?, chargeback = ?, x402_tx = ? WHERE contract_ref = ? AND ref = ?", [PFloat(payable), PFloat(retention), PStr(cb_id), PStr(outcome.executor_ref), PStr(ref), PStr(mref)]) {
                                Err(e) => resp.json_status(500, jv.stringify(JObj([("error", JStr(str.concat("chargeback ", str.concat(cb_id, str.concat(" settled but milestone record update failed — reconcile manually: ", e.message)))))]))),
                                Ok(_) => {
                                  let ev_ids := list.map(have, fn (h :: (Str, Str)) -> jv.Json {
                                    match h {
                                      (_, id) => JStr(id),
                                    }
                                  })
                                  let payload := jv.stringify(JObj([("contract_ref", JStr(ref)), ("milestone_ref", JStr(mref)), ("agent", JStr(ct.contractor)), ("from_agent", JStr(ct.client)), ("to_agent", JStr(ct.contractor)), ("amount_eur", JFloat(payable)), ("amount_dec", JStr(payable_dec)), ("retention_eur", JFloat(retention)), ("retention_dec", JStr(retention_dec)), ("evidence", JList(ev_ids)), ("chargeback", JStr(cb_id)), ("x402_tx", JStr(outcome.executor_ref))]))
                                  let __e := tlog.append(log, "construction.milestone.released", chain_tip(db, ref), payload)
                                  resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("paid_eur", JFloat(payable)), ("paid_dec", JStr(payable_dec)), ("retention_held_eur", JFloat(retention)), ("retention_dec", JStr(retention_dec)), ("chargeback", JStr(cb_id)), ("x402_tx", JStr(outcome.executor_ref)), ("evidence_events", JInt(list.len(have)))])))
                                },
                              }
                            },
                          }
                        },
                      }
                    }
                  }
                }
              },
            }
          },
        }
      },
    }
  })
  router.route_effectful(with_release, "GET", "/construction/contracts/:ref/statement", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let ref := match ctx.path_param(c, "ref") {
      Some(s) => s,
      None => "",
    }
    match contract_for(db, ref) {
      None => resp.json_status(404, "{\"error\":\"unknown contract\"}"),
      Some(ct) => {
        let rows := match sql.query(db, "SELECT ref, title, amount_eur, required_kinds, paid, paid_eur, retention_eur, chargeback FROM construction_milestones WHERE contract_ref = ? ORDER BY ref", [PStr(ref)]) {
          Err(_) => [],
          Ok(rs) => rs,
        }
        let items := list.map(rows, fn (row :: sql.Row) -> [sql] jv.Json {
          let mref := row_str(row, "ref")
          let have := evidence_for(db, ref, mref)
          let required := split_kinds(row_str(row, "required_kinds"))
          JObj([("ref", JStr(mref)), ("title", JStr(row_str(row, "title"))), ("amount_eur", JFloat(row_float(row, "amount_eur"))), ("required_evidence", JList(list.map(required, fn (k :: Str) -> jv.Json {
            JStr(k)
          }))), ("evidence", JList(list.map(have, fn (h :: (Str, Str)) -> jv.Json {
            match h {
              (kind, id) => JObj([("kind", JStr(kind)), ("event_id", JStr(id))]),
            }
          }))), ("missing_evidence", JList(list.map(missing_kinds(required, have), fn (k :: Str) -> jv.Json {
            JStr(k)
          }))), ("paid", JBool(row_int(row, "paid") == 1)), ("paid_eur", JFloat(row_float(row, "paid_eur"))), ("retention_held_eur", JFloat(row_float(row, "retention_eur"))), ("chargeback", JStr(row_str(row, "chargeback")))])
        })
        let paid_total := list.fold(rows, 0.0, fn (acc :: Float, row :: sql.Row) -> Float {
          acc + row_float(row, "paid_eur")
        })
        let retention_total := list.fold(rows, 0.0, fn (acc :: Float, row :: sql.Row) -> Float {
          acc + row_float(row, "retention_eur")
        })
        let log := settlement.trail_on(db)
        let intact := match chain_tip(db, ref) {
          None => true,
          Some(tip) => settlement.verify(log, tip),
        }
        resp.json(jv.stringify(JObj([("contract_ref", JStr(ref)), ("client_agent", JStr(ct.client)), ("contractor_agent", JStr(ct.contractor)), ("retention_pct", JFloat(ct.retention_pct)), ("milestones", JList(items)), ("paid_total_eur", JFloat(paid_total)), ("retention_held_eur", JFloat(retention_total)), ("chain_intact", JBool(intact))])))
      },
    }
  })
}

# The domain vocabulary this pack speaks, in the engine's position words
# (lex-soft/src/positions). The shape is milestone_release: nothing about it is
# specific to building work, which is why the manifest names the pattern.
fn manifest() -> pos.PackManifest {
  { id: "construction", title: "Construction", tagline: "Milestones released only against evidence that is present and re-verifies.", pattern: "milestone_release", subject: "contract", subject_ref_field: "contract_ref", custody_ref_field: "", parties: [{ position: "originator", name: "client", title: "Client — commissions the work and funds the budget", field: "client_agent", required: true }, { position: "executor", name: "contractor", title: "Contractor — performs the milestones", field: "contractor_agent", required: true }, { position: "attestor", name: "inspector", title: "Inspector — submits the evidence a milestone requires", field: "by", required: false }, { position: "settler", name: "approver", title: "Approver — clears a release above the review threshold", field: "approver", required: false }], relationships: [{ from: "client", to: "contractor", role: "contracted", label: "the client commissions the milestones and funds the budget" }, { from: "contractor", to: "inspector", role: "attestation", label: "the contractor calls for the evidence a milestone requires" }, { from: "inspector", to: "client", role: "reporting", label: "evidence reaches the client who releases against it" }, { from: "approver", to: "contractor", role: "settlement", label: "releases above the review threshold are cleared before payment" }], event_kinds: ["construction.contract", "construction.evidence", "construction.milestone.released"], evidence_kinds: ["photo", "inspection", "load-test"], settles: true, route_prefix: "/construction" }
}

