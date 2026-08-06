# construction_agent.lex — an LLM-driven agent persona that operates THIS
# pack's own REST service (construction.lex's /construction/* routes).
#
# Every tool here calls back into the same process's own mounted routes via
# `self_base_url` — the same loopback-HTTP pattern lex-soft-node's TMS agent
# already uses to call its own pack's /custody/handoffs route
# (lex-pack-logistics/src/tms.lex, record_handoff tool). Construction has no
# external backend to wrap (no telemetry/charging system) — its mount() IS
# the domain logic, so the agent's "backend" is itself.
#
# Tool schemas mirror construction.lex's documented request bodies field for
# field (see the comment block at the top of construction.lex), so most tool
# bodies can forward `args` verbatim via jv.stringify(args) — the same
# pass-through pattern lex-pack-logistics/src/shipper.lex's create_transport_order
# tool uses.

import "std.str" as str

import "std.http" as http

import "std.map" as map

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-schema/error" as e

import "lex-spec/capability" as cap

import "lex-llm/src/tool" as t

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-soft/src/runner" as runner

fn http_post_json(url :: Str, body :: Str, tenant :: Str) -> [net] jv.Json {
  let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(30000) }
  let req1 := http.with_header(req0, "Content-Type", "application/json")
  let req := if str.is_empty(tenant) {
    req1
  } else {
    http.with_header(req1, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(b) => match jv.parse(b) {
        Err(_) => JStr(b),
        Ok(j) => j,
      },
    },
  }
}

fn http_get_json(url :: Str, tenant :: Str) -> [net] jv.Json {
  let base := { method: "GET", url: url, headers: map.new(), body: None, timeout_ms: Some(30000) }
  let req := if str.is_empty(tenant) {
    base
  } else {
    http.with_header(base, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(body) => match jv.parse(body) {
        Err(_) => JStr(body),
        Ok(j) => j,
      },
    },
  }
}

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# ── Capability ────────────────────────────────────────────────────────────────
fn construction_capability() -> cap.Capability {
  cap.inbound("handle", "Operate a construction milestone-payment contract: create contracts, record evidence, release milestone payments, and report on contract status.", { title: "ConstructionOps", description: "Inbound message for the construction ops agent.", fields: [sch.required_str("text", [])] })
}

# ── Tools (self — this pack's own REST routes, no external backend) ──────────
fn milestone_schema() -> sch.ModelSchema {
  { title: "Milestone", description: "A milestone in a construction contract's payment schedule.", fields: [sch.required_str("ref", []), sch.required_str("title", []), sch.required_float("amount_eur", []), sch.required_array("required_evidence", KStr([]), [])] }
}

fn approval_schema() -> sch.ModelSchema {
  { title: "Approval", description: "Human approval bound to a specific release amount, required above the contract's review threshold.", fields: [sch.required_str("approver", []), sch.required_str("ref", []), sch.required_float("amount_eur", [])] }
}

fn make_construction_tools(self_base_url :: Str) -> List[t.Tool] {
  [t.define("create_contract", "Create (or update) a construction milestone-payment contract: names the client, contractor, a retention percentage, an optional budget cap (budget_total_eur/budget_per_milestone_eur) and human-review threshold (review_above_eur), plus the milestone schedule (each with the evidence kinds it requires before it can be released, e.g. photo, inspection, load-test).", { title: "CreateContract", description: "Contract creation.", fields: [sch.required_str("contract_ref", []), sch.required_str("client_agent", []), sch.required_str("contractor_agent", []), sch.required_float("retention_pct", []), sch.optional(sch.required_float("budget_total_eur", [])), sch.optional(sch.required_float("budget_per_milestone_eur", [])), sch.optional(sch.required_float("review_above_eur", [])), sch.required_array("milestones", KObject(milestone_schema()), [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.concat(self_base_url, "/construction/contracts"), jv.stringify(args), ""))
  }), t.define("submit_evidence", "Record one piece of evidence (e.g. a photo, inspection report, or load-test result) against a milestone, identified by its content hash. A milestone can only be released once every evidence kind its schedule requires has been submitted and the evidence chain re-verifies.", { title: "SubmitEvidence", description: "Evidence submission.", fields: [sch.required_str("contract_ref", []), sch.required_str("milestone_ref", []), sch.required_str("kind", []), sch.required_str("hash", []), sch.optional(sch.required_str("by", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.concat(self_base_url, "/construction/evidence"), jv.stringify(args), ""))
  }), t.define("release_milestone", "Release payment for a milestone. Pays only if every required evidence kind is on the chain AND the chain re-verifies AND the budget token authorizes the amount. A release at or above the contract's review_above_eur threshold needs a matching human approval (approver, ref, amount_eur matching the release exactly) or it is held (HTTP 202) for resubmission with that approval; an over-budget release is denied outright (HTTP 402).", { title: "ReleaseMilestone", description: "Milestone release, doubly gated on evidence + budget.", fields: [sch.required_str("contract_ref", []), sch.required_str("milestone_ref", []), sch.optional(sch.required_object("approval", approval_schema()))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.concat(self_base_url, "/construction/milestones/release"), jv.stringify(args), ""))
  }), t.define("get_statement", "Get a contract's full statement: every milestone with its evidence, missing evidence, paid/held status, retention held, and whether the evidence chain is intact.", { title: "GetStatement", description: "Contract statement lookup.", fields: [sch.required_str("contract_ref", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.join([self_base_url, "/construction/contracts/", jstr(args, "contract_ref"), "/statement"], ""), ""))
  })]
}

# ── System prompt ──────────────────────────────────────────────────────────────
fn construction_system_prompt(id :: Str) -> Str {
  str.join(["You are construction ops agent ", id, ". You operate milestone-payment contracts for subcontractor work: a contract names a client, a contractor, a retention percentage and a milestone schedule, and each milestone declares which evidence kinds it needs (e.g. photo, inspection, load-test) before it can be paid.", " To set up a contract, call create_contract with the milestone schedule. As evidence arrives, call submit_evidence for each piece (kind + content hash). To pay a milestone, call release_milestone -- it only pays once every required evidence kind is present and the chain re-verifies, and it also enforces the contract's budget cap and human-review threshold, so a release can come back HELD (needs a human approval) or DENIED (over budget); explain which, and what is missing, rather than retrying blindly.", " Use get_statement to check a contract's current state (evidence, paid/held milestones, retention) before answering questions about status.", " Be precise about euro amounts and always name the specific milestone_ref/contract_ref you acted on."], "")
}

# ── Agent factory (the persona builder the pack mounts) ────────────────────────
fn make_construction_def(db :: Db, id :: Str, base_url :: Str, self_base_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := construction_capability()
  let cfg := { id: id, kind: "construction-ops", system_prompt: construction_system_prompt(id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "self_url", url: self_base_url }], intent_roles: [], tools: make_construction_tools(self_base_url) }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(id, str.concat("Construction ops agent ", id), "0.1.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}

