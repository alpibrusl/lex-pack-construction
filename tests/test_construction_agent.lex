# tests/test_construction_agent.lex — pure-logic coverage for
# src/construction_agent.lex.
#
# The tools themselves are HTTP-calling closures (verified live against a
# running deployment, matching lex-pack-energy's test convention), but the
# ModelSchema each tool declares is real, non-trivial logic worth unit
# testing directly: it's what the LLM's tool-call arguments get validated
# against before create_contract/release_milestone ever reach construction.lex's
# routes, and a schema/route mismatch here would surface as silent 400s at
# runtime instead of a compile-time or test-time failure.
#
# lex test discards run_all's return value and only checks whether the call
# raises a runtime error -- see lex-ag-ui's README for the full writeup.
# This file forces a real runtime error when count_failures(...) > 0 so
# lex test/lex ci are real gates here.

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-llm/src/tool" as t

import "../src/construction_agent" as agent

fn pass() -> Result[Unit, Str] {
  Ok(())
}

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    pass()
  } else {
    Err(label)
  }
}

fn find_tool(name :: Str) -> Option[t.Tool] {
  t.find_by_name(agent.make_construction_tools("http://127.0.0.1:8100"), name)
}

fn schema_of(name :: Str) -> Option[sch.ModelSchema] {
  match find_tool(name) {
    None => None,
    Some(tool) => Some(tool.params),
  }
}

fn test_four_tools_defined() -> Result[Unit, Str] {
  assert_true(list.len(agent.make_construction_tools("http://127.0.0.1:8100")) == 4, "construction has exactly 4 REST routes today, so exactly 4 tools should be defined")
}

# ---- create_contract schema, mirrored against construction.lex's documented body ----
fn sample_contract() -> jv.Json {
  JObj([("contract_ref", JStr("C-100")), ("client_agent", JStr("client-acme")), ("contractor_agent", JStr("contractor-buildco")), ("retention_pct", JFloat(10.0)), ("budget_total_eur", JFloat(20000.0)), ("milestones", JList([JObj([("ref", JStr("M1")), ("title", JStr("Foundation")), ("amount_eur", JFloat(5000.0)), ("required_evidence", JList([JStr("photo"), JStr("inspection")]))])]))])
}

fn test_create_contract_schema_accepts_documented_shape() -> Result[Unit, Str] {
  match schema_of("create_contract") {
    None => Err("create_contract tool must be defined"),
    Some(schema) => match sch.validate(schema, sample_contract()) {
      Err(_) => Err("create_contract's schema must accept construction.lex's documented POST /construction/contracts body"),
      Ok(_) => pass(),
    },
  }
}

fn test_create_contract_schema_rejects_missing_milestones() -> Result[Unit, Str] {
  let bad := JObj([("contract_ref", JStr("C-100")), ("client_agent", JStr("client-acme")), ("contractor_agent", JStr("contractor-buildco")), ("retention_pct", JFloat(10.0))])
  match schema_of("create_contract") {
    None => Err("create_contract tool must be defined"),
    Some(schema) => match sch.validate(schema, bad) {
      Err(_) => pass(),
      Ok(_) => Err("create_contract's schema must require the milestones array, not silently accept its absence"),
    },
  }
}

# ---- submit_evidence schema ----
fn test_submit_evidence_schema_accepts_documented_shape() -> Result[Unit, Str] {
  let sample := JObj([("contract_ref", JStr("C-100")), ("milestone_ref", JStr("M1")), ("kind", JStr("photo")), ("hash", JStr("deadbeef")), ("by", JStr("inspector-1"))])
  match schema_of("submit_evidence") {
    None => Err("submit_evidence tool must be defined"),
    Some(schema) => match sch.validate(schema, sample) {
      Err(_) => Err("submit_evidence's schema must accept construction.lex's documented POST /construction/evidence body"),
      Ok(_) => pass(),
    },
  }
}

# ---- release_milestone schema (approval is optional) ----
fn test_release_milestone_schema_accepts_without_approval() -> Result[Unit, Str] {
  let sample := JObj([("contract_ref", JStr("C-100")), ("milestone_ref", JStr("M1"))])
  match schema_of("release_milestone") {
    None => Err("release_milestone tool must be defined"),
    Some(schema) => match sch.validate(schema, sample) {
      Err(_) => Err("release_milestone's approval field must be optional -- most releases carry no approval"),
      Ok(_) => pass(),
    },
  }
}

fn test_release_milestone_schema_accepts_with_approval() -> Result[Unit, Str] {
  let sample := JObj([("contract_ref", JStr("C-100")), ("milestone_ref", JStr("M1")), ("approval", JObj([("approver", JStr("cfo-1")), ("ref", JStr("appr-1")), ("amount_eur", JFloat(4500.0))]))])
  match schema_of("release_milestone") {
    None => Err("release_milestone tool must be defined"),
    Some(schema) => match sch.validate(schema, sample) {
      Err(_) => Err("release_milestone's schema must accept a matching approval object"),
      Ok(_) => pass(),
    },
  }
}

# ---- get_statement schema ----
fn test_get_statement_schema_requires_contract_ref() -> Result[Unit, Str] {
  match schema_of("get_statement") {
    None => Err("get_statement tool must be defined"),
    Some(schema) => match sch.validate(schema, JObj([])) {
      Err(_) => pass(),
      Ok(_) => Err("get_statement's schema must require contract_ref"),
    },
  }
}

fn suite_pure() -> List[Result[Unit, Str]] {
  [test_four_tools_defined(), test_create_contract_schema_accepts_documented_shape(), test_create_contract_schema_rejects_missing_milestones(), test_submit_evidence_schema_accepts_documented_shape(), test_release_milestone_schema_accepts_without_approval(), test_release_milestone_schema_accepts_with_approval(), test_get_statement_schema_requires_contract_ref()]
}

fn count_failures(results :: List[Result[Unit, Str]]) -> Int {
  list.fold(results, 0, fn (acc :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

fn run_all() -> Int {
  let failures := count_failures(suite_pure())
  let _crash_if_failed := if failures > 0 {
    1 / 0
  } else {
    0
  }
  failures
}

