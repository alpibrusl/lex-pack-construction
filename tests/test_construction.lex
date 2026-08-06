# tests/test_construction.lex — pure-logic coverage for src/construction.lex.
#
# eur_to_cents/split_kinds/missing_kinds are the pure, non-trivial functions
# here (euro-to-minor-unit conversion, and diffing required evidence against
# what's on the chain); the effectful routes (contracts, evidence, release,
# gate.spend) need a live DB + budget token to exercise meaningfully — that's
# covered by lex-ev-fleet's own integration testing of the mounted deployment.
#
# lex test discards run_all's return value and only checks whether the call
# raises a runtime error -- see lex-ag-ui's README for the full writeup. This
# file forces a real runtime error when count_failures(...) > 0 so lex
# test/lex ci are real gates here.

import "std.list" as list

import "lex-soft/src/positions" as pos

import "../src/construction" as construction

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

# ---- eur_to_cents -----------------------------------------------------------
fn test_eur_to_cents_basic() -> Result[Unit, Str] {
  assert_true(construction.eur_to_cents("10.00") == 1000, "a decimal euro amount must convert to exact minor-unit cents")
}

fn test_eur_to_cents_unparseable_is_zero() -> Result[Unit, Str] {
  assert_true(construction.eur_to_cents("not-a-number") == 0, "an unparseable amount must fall back to zero rather than guessing")
}

# ---- split_kinds --------------------------------------------------------------
fn test_split_kinds_drops_blank_entries() -> Result[Unit, Str] {
  let got := construction.split_kinds("photo,,inspection")
  assert_true(list.len(got) == 2, "an empty entry between commas must be dropped, not kept as a blank kind")
}

# ---- missing_kinds --------------------------------------------------------------
fn test_missing_kinds_none_missing() -> Result[Unit, Str] {
  assert_true(list.is_empty(construction.missing_kinds(["photo"], [("photo", "ev-1")])), "when every required kind has an evidence event, nothing is missing")
}

fn test_missing_kinds_reports_what_is_missing() -> Result[Unit, Str] {
  let got := construction.missing_kinds(["photo", "inspection"], [("photo", "ev-1")])
  assert_true(got == ["inspection"], "an evidence kind with no recorded event must be named as missing")
}

# ---- manifest() -------------------------------------------------------------
fn test_manifest_is_valid() -> Result[Unit, Str] {
  let m := construction.manifest()
  assert_true(list.is_empty(pos.validate(m)), "construction's own manifest must satisfy the shared position/pattern validator")
}

fn test_manifest_route_prefix() -> Result[Unit, Str] {
  assert_true(construction.manifest().route_prefix == "/construction", "manifest route_prefix must match the mounted routes")
}

fn test_manifest_settles() -> Result[Unit, Str] {
  assert_true(construction.manifest().settles, "a milestone release moves money, so the manifest must declare settles: true")
}

fn suite_pure() -> List[Result[Unit, Str]] {
  [test_eur_to_cents_basic(), test_eur_to_cents_unparseable_is_zero(), test_split_kinds_drops_blank_entries(), test_missing_kinds_none_missing(), test_missing_kinds_reports_what_is_missing(), test_manifest_is_valid(), test_manifest_route_prefix(), test_manifest_settles()]
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

