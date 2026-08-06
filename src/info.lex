# info.lex — the construction agent-domain manifest (pack.PackInfo).
#
# The DomainPack counterpart of this pack's REST pos.PackManifest (see
# construction.lex's manifest()): how a console should PRESENT the
# construction-ops persona — label, tagline, starter prompts. Served by the
# host under /platform/packs's agent_packs field.

import "lex-soft/src/pack" as pack

fn info() -> pack.PackInfo {
  { name: "construction", title: "Construction", tagline: "Milestone payments released only against evidence that is present and re-verifies.", personas: [{ kind: "construction-ops", title: "Construction ops", tagline: "Sets up contracts, records evidence, and releases milestone payments under the budget and review gates.", suggested_prompts: ["Create a contract between client-acme and contractor-buildco with a 10% retention and one milestone M1 for 5000 EUR requiring a photo and an inspection.", "Record photo evidence for milestone M1 on contract C-100.", "Release milestone M1 on contract C-100.", "What is the statement for contract C-100?"] }] }
}

