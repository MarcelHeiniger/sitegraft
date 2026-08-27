# tests/unit/test_domain_remap_guard_consistency.bats — MINOR-1 (issue #73,
# third review round). There are actually FIVE enforcement points for "this
# domain remap is unusable", not the four graft_domain_remap_unusable_reason
# (lib/graft.sh) documents as its own reason for existing: manifest_validate
# (lib/manifest.sh:190-200-ish) carries a SEPARATE, hand-duplicated copy.
# Architecturally forced, not an oversight — bin/sitegraft does not load
# lib/graft.sh for the `plan` phase (only lib/manifest.sh + lib/plan.sh, see
# bin/sitegraft's own `require_lib` list under the `plan` case), so
# manifest_validate cannot call the shared graft.sh predicate even if it
# wanted to.
#
# The two definitions differ on exactly ONE point, deliberately: an empty
# `from` is unusable to manifest_validate (issue #73's own acceptance
# criterion: "a search_replace.from that is empty... must make plan refuse
# to freeze") but usable to graft_domain_remap_unusable_reason (every
# runtime caller already treats it as the legitimate "no domain configured"
# no-op before ever consulting that function). Documented in both
# functions' own header comments — not a design flaw.
#
# What WOULD be a flaw, silently: a sixth form added to only one of the two
# tomorrow. `plan` would then freeze a manifest `graft` refuses to run —
# a cheap rejection at plan time quietly becoming an abandoned run after
# backup. This file loads BOTH lib/manifest.sh and lib/graft.sh together
# (something no single phase in bin/sitegraft ever does) specifically to
# assert the two guards still agree on every form they share.
setup() {
  load '../../lib/core.sh'
  load '../../lib/manifest.sh'
  load '../../lib/graft.sh'
}

# _guards_agree <from> <to> — echoes "agree" iff manifest_validate and
# graft_domain_remap_unusable_reason reach the SAME usable/unusable verdict
# for this pair; otherwise echoes a diagnostic naming which one disagreed.
_guards_agree() {
  local from="$1" to="$2"
  local manifest manifest_bad graft_bad
  manifest=$(jq -n --arg f "$from" --arg t "$to" '{options:{search_replace:{from:$f,to:$t}}}')
  if manifest_validate "$manifest" >/dev/null 2>&1; then manifest_bad=false; else manifest_bad=true; fi
  if [ -n "$(graft_domain_remap_unusable_reason "$from" "$to")" ]; then graft_bad=true; else graft_bad=false; fi
  if [ "$manifest_bad" = "$graft_bad" ]; then
    echo "agree"
  else
    echo "DISAGREE (manifest_validate bad=${manifest_bad}, graft_domain_remap_unusable_reason bad=${graft_bad})"
  fi
}

@test "manifest_validate and graft_domain_remap_unusable_reason agree: from == 'unknown' is unusable" {
  run _guards_agree "unknown" "https://b.example.com"
  [ "$output" = "agree" ]
}

@test "manifest_validate and graft_domain_remap_unusable_reason agree: to == 'unknown' is unusable" {
  run _guards_agree "https://a.example.com" "unknown"
  [ "$output" = "agree" ]
}

@test "manifest_validate and graft_domain_remap_unusable_reason agree: to == '' is unusable (BLOCKER-1's own shape — from real, to broken)" {
  run _guards_agree "https://a.example.com" ""
  [ "$output" = "agree" ]
}

@test "manifest_validate and graft_domain_remap_unusable_reason agree: from == to is unusable" {
  run _guards_agree "https://same.example.com" "https://same.example.com"
  [ "$output" = "agree" ]
}

@test "manifest_validate and graft_domain_remap_unusable_reason agree: a real, distinct pair is usable" {
  run _guards_agree "https://a.example.com" "https://b.example.com"
  [ "$output" = "agree" ]
}

@test "the ONE deliberate divergence, pinned so it can never grow silently: from == '' — manifest_validate refuses to freeze it, graft's runtime guard treats it as the no-op case" {
  local manifest
  manifest=$(jq -n '{options:{search_replace:{from:"",to:"https://b.example.com"}}}')
  run manifest_validate "$manifest"
  [ "$status" -ne 0 ]
  run graft_domain_remap_unusable_reason "" "https://b.example.com"
  [ -z "$output" ]
}
