#!/usr/bin/env bash
# test_providers.sh — tests for the provider-alias feature (claude-providers).
# Hermetic: runs entirely inside a sandboxed $HOME via make_sandbox.
#
# As the feature lands, sections are added below. The first and most
# safety-critical section is the account-detection regression: provider
# dirs (~/.claude-prov-*) must be invisible to cma_detect_accounts so they
# never get merged into real-account auth or unify.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e   # lib.sh sets -e; the harness asserts on failures, so relax it.

# ---------------------------------------------------------------------------
# Section 1 — account-detection regression (the linchpin)
# ---------------------------------------------------------------------------

# Two real accounts and the shared dir.
make_account acct1
make_account acct2
mkdir -p "$SHARED_DIR"

# A provider-alias dir that looks account-like (has projects/ + .claude.json)
# — exactly the shape that would be wrongly detected without the exclusion.
mkdir -p "$HOME/${ACCOUNT_PREFIX}prov-deepseek/projects"
printf '{"name":"deepseek"}\n' > "$HOME/${ACCOUNT_PREFIX}prov-deepseek/.claude.json"
# A second provider dir to be sure the prefix match isn't accidental.
mkdir -p "$HOME/${ACCOUNT_PREFIX}prov-groq/projects"
printf '{"name":"groq"}\n' > "$HOME/${ACCOUNT_PREFIX}prov-groq/.claude.json"

detected="$(cma_detect_accounts)"

it "real accounts are still detected"
echo "$detected" | grep -q "${ACCOUNT_PREFIX}acct1$" ; assert_eq 0 $? "acct1 detected"
echo "$detected" | grep -q "${ACCOUNT_PREFIX}acct2$" ; assert_eq 0 $? "acct2 detected"

it "provider-alias dirs are excluded from detection"
echo "$detected" | grep -q "prov-deepseek" ; assert_eq 1 $? "prov-deepseek excluded"
echo "$detected" | grep -q "prov-groq" ;     assert_eq 1 $? "prov-groq excluded"

it "detection count is exactly the real accounts (no provider leakage)"
n="$(echo "$detected" | grep -c .)"
assert_eq "2" "$n" "exactly 2 detected accounts"

it "shared dir is never counted as an account"
echo "$detected" | grep -q -- "-shared" ; assert_eq 1 $? "shared excluded"

# ---------------------------------------------------------------------------
# Section 2 — providers_resolve.py against a deterministic fixture catalog
# (offline; proves transport detection, model selection, classification,
#  key-alias normalization, and unmapped handling without any network).
# ---------------------------------------------------------------------------
RESOLVE="$SCRIPTS_DIR/providers_resolve.py"
FIX="$HOME/fixture"
mkdir -p "$FIX"

cat > "$FIX/catalog.json" <<'JSON'
{
  "acme": {
    "env": ["ACME_API_KEY"],
    "api": "https://api.acme.com/anthropic",
    "npm": "@ai-sdk/anthropic",
    "models": {
      "big":   {"id":"acme-big","reasoning":true,"release_date":"2025-05-01","limit":{"context":200000},"cost":{"input":3,"output":15},"tool_call":true},
      "small": {"id":"acme-small","reasoning":false,"release_date":"2024-01-01","limit":{"context":32000},"cost":{"input":0.1,"output":0.4},"tool_call":true}
    }
  },
  "beta": {
    "env": ["BETA_API_KEY"],
    "api": "https://api.beta.ai/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "flagship": {"id":"beta-x","reasoning":false,"release_date":"2025-06-01","limit":{"context":128000},"cost":{"input":1,"output":5},"tool_call":true}
    }
  },
  "zai-coding-plan": {
    "env": ["ZAI_API_KEY"],
    "api": "https://api.z.ai/api/coding/paas/v4",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "glm-5.2": {"id":"glm-5.2","name":"GLM-5.2","reasoning":true,"tool_call":true,"release_date":"2026-06-13","limit":{"context":1000000},"cost":{"input":0,"output":0}},
      "glm-4.7": {"id":"glm-4.7","name":"GLM-4.7","reasoning":true,"tool_call":true,"release_date":"2025-12-22","limit":{"context":204800},"cost":{"input":0,"output":0}}
    }
  },
  "xiaomi": {
    "env": ["XIAOMI_API_KEY"],
    "api": "https://api.xiaomimimo.com/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "mimo-v2.5-pro-ultraspeed": {"id":"mimo-v2.5-pro-ultraspeed","name":"MiMo V2.5 Pro Ultraspeed","reasoning":true,"tool_call":true,"release_date":"2026-07-01","limit":{"context":1000000},"cost":{"input":0,"output":0}},
      "mimo-v2.5-pro":            {"id":"mimo-v2.5-pro","name":"MiMo V2.5 Pro","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":1000000},"cost":{"input":2,"output":8}},
      "mimo-v2-flash":            {"id":"mimo-v2-flash","name":"MiMo V2 Flash","reasoning":true,"tool_call":true,"release_date":"2026-05-01","limit":{"context":256000},"cost":{"input":0.1,"output":0.4}}
    }
  },
  "opencode": {
    "env": ["OPENCODE_API_KEY"],
    "api": "https://opencode.ai/zen/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "big-pickle": {"id":"big-pickle","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":200000},"cost":{"input":0,"output":0}},
      "deepseek-v4-flash-free": {"id":"deepseek-v4-flash-free","reasoning":true,"tool_call":true,"release_date":"2026-05-01","limit":{"context":200000},"cost":{"input":0,"output":0}},
      "nemotron-3-ultra-free": {"id":"nemotron-3-ultra-free","reasoning":true,"tool_call":true,"release_date":"2026-04-01","limit":{"context":1000000},"cost":{"input":0,"output":0}},
      "ling-2.6-flash-free": {"id":"ling-2.6-flash-free","reasoning":false,"tool_call":true,"release_date":"2026-03-01","limit":{"context":262100},"cost":{"input":0,"output":0}},
      "trinity-large-preview-free": {"id":"trinity-large-preview-free","reasoning":false,"tool_call":true,"release_date":"2026-02-01","limit":{"context":131072},"cost":{"input":0,"output":0}}
    }
  }
}
JSON

cat > "$FIX/key-aliases.json" <<'JSON'
{ "LEGACY_BETA_KEY": "beta", "XIAOMI_MIMO_API_KEY": "xiaomi", "ZEN_API_KEY": "opencode", "ApiKey_Opencode_Zen": "opencode" }
JSON

# A fixture overrides file mirroring the real shipped providers/overrides.json for
# xiaomi: pins native transport, the /anthropic base_url, and the live-served model
# ids — proving the override BEATS the resolver's catalog-derived defaults (router
# transport from the openai-compatible npm, the /v1 catalog api, and the stale
# ultraspeed model that auto-selection would otherwise pick as strongest).
cat > "$FIX/overrides.json" <<'JSON'
{
  "xiaomi": {
    "transport": "native",
    "base_url": "https://api.xiaomimimo.com/anthropic",
    "strong_model": "mimo-v2.5-pro",
    "fast_model": "mimo-v2-flash"
  },
  "opencode": {
    "strong_model": "big-pickle",
    "fast_model": "deepseek-v4-flash-free"
  }
}
JSON

# Read a field for a given key_var out of the resolver JSON output.
rfield() { # rfield JSON KEYVAR FIELD
  python3 -c 'import json,sys
recs=json.load(open(sys.argv[1]))
m={r["key_var"]:r for r in recs}
print(m[sys.argv[2]][sys.argv[3]])' "$1" "$2" "$3"
}

OUT="$HOME/resolved.json"
python3 "$RESOLVE" --models-dev "$FIX/catalog.json" \
  --key-aliases "$FIX/key-aliases.json" \
  --overrides "$FIX/overrides.json" \
  --keys "ACME_API_KEY,BETA_API_KEY,ZAI_API_KEY,LEGACY_BETA_KEY,XIAOMI_MIMO_API_KEY,ZEN_API_KEY,ApiKey_Opencode_Zen,GITHUB_TOKEN,FOO_API_KEY" > "$OUT"
rc=$?

it "resolver runs and emits valid JSON"
assert_eq 0 "$rc" "resolver exit 0"
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$OUT" 2>/dev/null
assert_eq 0 $? "output is valid JSON"

it "native transport detected from @ai-sdk/anthropic npm"
assert_eq "native" "$(rfield "$OUT" ACME_API_KEY transport)" "acme native"
assert_eq "resolved" "$(rfield "$OUT" ACME_API_KEY status)" "acme resolved"

it "strong model = reasoning/newest; fast model = lowest input cost"
assert_eq "acme-big" "$(rfield "$OUT" ACME_API_KEY strong_model)" "strong=reasoning model"
assert_eq "acme-small" "$(rfield "$OUT" ACME_API_KEY fast_model)" "fast=cheapest model"

it "openai-compatible npm => router transport"
assert_eq "router" "$(rfield "$OUT" BETA_API_KEY transport)" "beta router"
assert_eq "https://api.beta.ai/v1" "$(rfield "$OUT" BETA_API_KEY base_url)" "beta base_url from catalog"

it "key-aliases.json normalizes a differently-named key var"
assert_eq "beta" "$(rfield "$OUT" LEGACY_BETA_KEY provider_id)" "LEGACY_BETA_KEY -> beta"

it "zai-coding-plan resolves from env key match on ZAI_API_KEY"
assert_eq "zai-coding-plan" "$(rfield "$OUT" ZAI_API_KEY provider_id)" "zai-coding-plan provider_id"
assert_eq "resolved" "$(rfield "$OUT" ZAI_API_KEY status)" "zai-coding-plan resolved"

it "zai-coding-plan uses coding paas endpoint and router transport"
assert_eq "https://api.z.ai/api/coding/paas/v4" "$(rfield "$OUT" ZAI_API_KEY base_url)" "coding endpoint"
assert_eq "router" "$(rfield "$OUT" ZAI_API_KEY transport)" "zai-coding-plan router"

it "zai-coding-plan strong model = glm-5.2 (newest+reasoning), fast model = glm-4.7"
assert_eq "glm-5.2" "$(rfield "$OUT" ZAI_API_KEY strong_model)" "strong=glm-5.2"
assert_eq "glm-4.7" "$(rfield "$OUT" ZAI_API_KEY fast_model)" "fast=glm-4.7"

it "xiaomi resolves from the key-alias mapping on XIAOMI_MIMO_API_KEY"
assert_eq "xiaomi" "$(rfield "$OUT" XIAOMI_MIMO_API_KEY provider_id)" "xiaomi provider_id"
assert_eq "resolved" "$(rfield "$OUT" XIAOMI_MIMO_API_KEY status)" "xiaomi resolved"

it "xiaomi override forces native transport (beats openai-compatible npm)"
assert_eq "native" "$(rfield "$OUT" XIAOMI_MIMO_API_KEY transport)" "xiaomi native"

it "xiaomi override sets the /anthropic base_url (beats catalog /v1)"
assert_eq "https://api.xiaomimimo.com/anthropic" "$(rfield "$OUT" XIAOMI_MIMO_API_KEY base_url)" "xiaomi /anthropic base"

it "xiaomi strong=mimo-v2.5-pro, fast=mimo-v2-flash (override beats stale ultraspeed)"
assert_eq "mimo-v2.5-pro" "$(rfield "$OUT" XIAOMI_MIMO_API_KEY strong_model)" "strong=mimo-v2.5-pro"
assert_eq "mimo-v2-flash" "$(rfield "$OUT" XIAOMI_MIMO_API_KEY fast_model)" "fast=mimo-v2-flash"

it "the stale mimo-v2.5-pro-ultraspeed id is never selected"
cond=1; [[ "$(rfield "$OUT" XIAOMI_MIMO_API_KEY strong_model)" != "mimo-v2.5-pro-ultraspeed" ]] && cond=0; assert_eq 0 "$cond" "ultraspeed not strong"
cond=1; [[ "$(rfield "$OUT" XIAOMI_MIMO_API_KEY fast_model)" != "mimo-v2.5-pro-ultraspeed" ]] && cond=0; assert_eq 0 "$cond" "ultraspeed not fast"

it "xai override provides the base_url the null-api catalog lacks (v1.12.1 resolve-gap fix)"
# The real overrides.json must carry the xai base_url so xai stops resolving to
# 'unmapped' (catalog api:null -> "router provider missing base_url"). The
# override->base_url resolution mechanism itself is proven by the xiaomi test above;
# this guards the xai entry's presence + correctness in the shipped overrides.json.
assert_eq "https://api.x.ai/v1" "$(jq -r '.xai.base_url // "MISSING"' "$SCRIPTS_DIR/providers/overrides.json")" "overrides.json xai base_url present + correct"

it "opencode resolves from the key-alias mapping on ZEN_API_KEY"
assert_eq "opencode" "$(rfield "$OUT" ZEN_API_KEY provider_id)" "opencode provider_id"
assert_eq "resolved" "$(rfield "$OUT" ZEN_API_KEY status)" "opencode resolved"

it "ApiKey_Opencode_Zen also resolves to opencode via secondary key-alias"
assert_eq "opencode" "$(rfield "$OUT" ApiKey_Opencode_Zen provider_id)" "ApiKey_Opencode_Zen -> opencode"
assert_eq "resolved" "$(rfield "$OUT" ApiKey_Opencode_Zen status)" "ApiKey_Opencode_Zen resolved"

it "opencode uses router transport (openai-compatible npm)"
assert_eq "router" "$(rfield "$OUT" ZEN_API_KEY transport)" "opencode router"

it "opencode base_url from catalog (zen/v1 endpoint)"
assert_eq "https://opencode.ai/zen/v1" "$(rfield "$OUT" ZEN_API_KEY base_url)" "opencode zen/v1 base"

it "opencode override forces big-pickle as strong (beats nemotron-3-ultra-free auto-selection)"
assert_eq "big-pickle" "$(rfield "$OUT" ZEN_API_KEY strong_model)" "strong=big-pickle"
cond=1; [[ "$(rfield "$OUT" ZEN_API_KEY strong_model)" != "nemotron-3-ultra-free" ]] && cond=0; assert_eq 0 "$cond" "nemotron not strong"

it "opencode override forces deepseek-v4-flash-free as fast (beats trinity auto-selection)"
assert_eq "deepseek-v4-flash-free" "$(rfield "$OUT" ZEN_API_KEY fast_model)" "fast=deepseek-v4-flash-free"
cond=1; [[ "$(rfield "$OUT" ZEN_API_KEY fast_model)" != "trinity-large-preview-free" ]] && cond=0; assert_eq 0 "$cond" "trinity not fast"

# ---------------------------------------------------------------------------
# Section 2b — a strong_model pin must RE-DERIVE context_limit/max_output.
#
# Regression (found on the nvidia alias): select_models() computes the limits
# from the model IT auto-picks. overrides.json then replaced strong_model but
# left those limits untouched, so the generated .env advertised one model's
# window for a different model's traffic. Live case: nvidia pinned the 30B nano
# (256000/65536) yet kept z-ai/glm-5.2's 1000000/131072 -> the launch wrapper
# exported CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000, ~2x the model's real 65536.
# 9 of 13 pinned providers were emitting mismatched limits.
#
# Also covers the sibling bug in the same block: overrides.json documents
# context_limit / max_output fields (kimi-for-coding sets "context_limit":
# 262144) but the field loop never copied them, so they were silently ignored.
# ---------------------------------------------------------------------------
LFIX="$HOME/limfixture"
mkdir -p "$LFIX"

# auto-selection would pick "lc-newest" (reasoning + newest release_date) whose
# window is 1000000/131072; the override pins "lc-pinned" at 256000/65536.
cat > "$LFIX/catalog.json" <<'JSON'
{
  "limitcorp": {
    "env": ["LIMITCORP_API_KEY"],
    "api": "https://api.limitcorp.com/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "lc-newest": {"id":"lc-newest","reasoning":true,"tool_call":true,"release_date":"2026-06-13","limit":{"context":1000000,"output":131072},"cost":{"input":0,"output":0}},
      "lc-pinned": {"id":"lc-pinned","reasoning":true,"tool_call":true,"release_date":"2026-04-28","limit":{"context":256000,"output":65536},"cost":{"input":0,"output":0}}
    }
  },
  "opaquecorp": {
    "env": ["OPAQUECORP_API_KEY"],
    "api": "https://api.opaquecorp.com/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "oc-catalogued": {"id":"oc-catalogued","reasoning":true,"tool_call":true,"release_date":"2026-05-01","limit":{"context":900000,"output":99000},"cost":{"input":0,"output":0}}
    }
  },
  "statedcorp": {
    "env": ["STATEDCORP_API_KEY"],
    "api": "https://api.statedcorp.com/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "sc-auto": {"id":"sc-auto","reasoning":true,"tool_call":true,"release_date":"2026-05-01","limit":{"context":700000,"output":70000},"cost":{"input":0,"output":0}}
    }
  },
  "tinycorp": {
    "env": ["TINYCORP_API_KEY"],
    "api": "https://api.tinycorp.com/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "tc-widest": {"id":"tc-widest","reasoning":true,"tool_call":true,"release_date":"2026-05-01","limit":{"context":60000,"output":4096},"cost":{"input":0,"output":0}},
      "tc-narrow": {"id":"tc-narrow","reasoning":false,"tool_call":true,"release_date":"2026-01-01","limit":{"context":4000,"output":2048},"cost":{"input":0,"output":0}}
    }
  },
  "microcorp": {
    "env": ["MICROCORP_API_KEY"],
    "api": "https://api.microcorp.com/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "mc-only": {"id":"mc-only","reasoning":true,"tool_call":true,"release_date":"2026-05-01","limit":{"context":8000,"output":8000},"cost":{"input":0,"output":0}}
    }
  },
  "voidcorp": {
    "env": ["VOIDCORP_API_KEY"],
    "api": "https://api.voidcorp.com/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "vc-only": {"id":"vc-only","reasoning":true,"tool_call":true,"release_date":"2026-05-01","cost":{"input":0,"output":0}}
    }
  }
}
JSON

cat > "$LFIX/overrides.json" <<'JSON'
{
  "limitcorp":  { "strong_model": "lc-pinned" },
  "opaquecorp": { "strong_model": "oc-provider-only-model" },
  "statedcorp": { "strong_model": "sc-auto", "context_limit": 262144, "max_output": 8192 },
  "tinycorp":   { "strong_model": "tc-provider-only-model" }
}
JSON

LKEYS="LIMITCORP_API_KEY,OPAQUECORP_API_KEY,STATEDCORP_API_KEY,TINYCORP_API_KEY,MICROCORP_API_KEY,VOIDCORP_API_KEY"
LOUT="$HOME/resolved-limits.json"
python3 "$RESOLVE" --models-dev "$LFIX/catalog.json" \
  --overrides "$LFIX/overrides.json" \
  --keys "$LKEYS" > "$LOUT"

it "strong_model pin re-derives the limits from the PINNED model"
assert_eq "lc-pinned" "$(rfield "$LOUT" LIMITCORP_API_KEY strong_model)" "pin applied"
assert_eq "256000" "$(rfield "$LOUT" LIMITCORP_API_KEY context_limit)" "context from pinned model"
assert_eq "65536"  "$(rfield "$LOUT" LIMITCORP_API_KEY max_output)"    "max_output from pinned model"

it "the auto-picked model's limits do NOT leak through a strong_model pin"
cond=1; [[ "$(rfield "$LOUT" LIMITCORP_API_KEY context_limit)" != "1000000" ]] && cond=0
assert_eq 0 "$cond" "context is not lc-newest's 1000000"
cond=1; [[ "$(rfield "$LOUT" LIMITCORP_API_KEY max_output)" != "131072" ]] && cond=0
assert_eq 0 "$cond" "max_output is not lc-newest's 131072"

it "a pinned model the catalog does not know still gets a GUARD, not silence"
# Was: "leaves limits UNKNOWN, not stale" -- asserting None/None. That assertion
# encoded the last fail-open hole rather than a safe behaviour. Empty limits make
# the launch wrapper export NEITHER guard, and Claude Code's own no-cap default
# is 128000 output tokens against a window nobody measured -- the same failure
# the large-context fix closed, reached from the other end. Live case: inference
# pins glm-5.2, absent from its catalog, and shipped verified + launchable with
# CMA_PROVIDER_CONTEXT_LIMIT='' CMA_PROVIDER_MAX_OUTPUT=''.
# "Not stale" is still right -- opaquecorp must NOT inherit oc-catalogued's
# 900000/99000. The third option beats both: a conservative derived pair.
assert_eq "oc-provider-only-model" "$(rfield "$LOUT" OPAQUECORP_API_KEY strong_model)" "pin applied"
cond=1; [[ "$(rfield "$LOUT" OPAQUECORP_API_KEY context_limit)" != "None" ]] && cond=0
assert_eq 0 "$cond" "unknown pin still emits a context (no unguarded launch)"
cond=1; [[ "$(rfield "$LOUT" OPAQUECORP_API_KEY max_output)" != "None" ]] && cond=0
assert_eq 0 "$cond" "unknown pin still emits an output cap (no unguarded launch)"

it "the unknown-model fallback is bounded by the provider's OWN published window"
# opaquecorp publishes exactly one model at 900000, above the 128000
# conservative default -> the default wins (understating is the safe direction).
assert_eq "128000" "$(rfield "$LOUT" OPAQUECORP_API_KEY context_limit)" "min(default, published)"
assert_eq "8192"   "$(rfield "$LOUT" OPAQUECORP_API_KEY max_output)"    "output carved from it"

it "the unknown pin does NOT inherit the catalogued model's limits"
cond=1; [[ "$(rfield "$LOUT" OPAQUECORP_API_KEY context_limit)" != "900000" ]] && cond=0
assert_eq 0 "$cond" "context is not oc-catalogued's 900000"
cond=1; [[ "$(rfield "$LOUT" OPAQUECORP_API_KEY max_output)" != "99000" ]] && cond=0
assert_eq 0 "$cond" "max_output is not oc-catalogued's 99000"

it "explicit context_limit/max_output overrides are honored (were silently ignored)"
assert_eq "262144" "$(rfield "$LOUT" STATEDCORP_API_KEY context_limit)" "stated context wins"
assert_eq "8192"   "$(rfield "$LOUT" STATEDCORP_API_KEY max_output)"    "stated max_output wins"

# ---------------------------------------------------------------------------
# Section 2c — the resolver must NEVER emit an unguarded or self-contradictory
# limit pair. Two fail-open shapes, both live:
#
#   1. BOTH limits empty. `inference` shipped `verified` and launchable with
#      CMA_PROVIDER_CONTEXT_LIMIT='' CMA_PROVIDER_MAX_OUTPUT='' because its
#      pinned glm-5.2 is absent from its catalog. Empty exports NO guard, and
#      Claude Code's no-cap default is 128000 output tokens against an unknown
#      window -- the same 400 the large-context fix closed. `poe` (pins
#      claude-sonnet-4.6; the catalog id is anthropic/claude-sonnet-4.6) was the
#      same hole, latent behind a stale .env.
#   2. output >= context. The 8192 output floor was applied unconditionally, so
#      any window below it came out inverted -- 189 live models.dev rows
#      (mistral/open-mistral-7b at 8000/8000, evroc's 448-token rows). An output
#      cap at or above the whole window is the overstatement that 400s.
# ---------------------------------------------------------------------------
it "no resolved provider is launchable with an unguarded (empty) limit pair"
# Same C3 hazard as the two sweeps, milder form: this python carries no
# `2>/dev/null`, so a crash is at least visible — but the assertion is still
# `assert_eq ""`, and a crash still yields empty stdout and still scores as a
# PASS. The count of records actually examined is asserted for the same reason.
_unguarded="$(python3 -c '
import json,sys
recs=json.load(open(sys.argv[1]))
bad=[r["provider_id"] for r in recs
     if r["status"]=="resolved" and (r["context_limit"] is None or r["max_output"] is None)]
n=sum(1 for r in recs if r["status"]=="resolved")
print("resolved=%d unguarded=%s" % (n, ",".join(bad)))' "$LOUT")"
assert_eq "resolved=6 unguarded=" "$_unguarded" "resolved providers with a missing guard: '$_unguarded'"

it "every emitted pair satisfies output < context"
_inverted="$(python3 -c '
import json,sys
recs=json.load(open(sys.argv[1]))
bad=["%s(%s>=%s)"%(r["provider_id"],r["max_output"],r["context_limit"]) for r in recs
     if r["context_limit"] is not None and r["max_output"] is not None
     and r["max_output"] >= r["context_limit"]]
n=sum(1 for r in recs if r["context_limit"] is not None and r["max_output"] is not None)
print("pairs=%d inverted=%s" % (n, ",".join(bad)))' "$LOUT")"
assert_eq "pairs=6 inverted=" "$_inverted" "pairs violating output<context: '$_inverted'"

it "the fallback is capped by the provider's own ceiling when that is narrower"
# tinycorp pins an uncatalogued model and publishes nothing wider than 60000,
# so the 128000 default must NOT be assumed -- guessing above what the provider
# itself serves is the direction that kills the alias.
assert_eq "60000" "$(rfield "$LOUT" TINYCORP_API_KEY context_limit)" "provider ceiling binds"
assert_eq "8192"  "$(rfield "$LOUT" TINYCORP_API_KEY max_output)"    "cap fits inside it"

it "a wide-topped provider's fallback is bounded by its OWN 10th percentile"
# I3: the fallback used to be min(128000, the provider's LARGEST window), a
# ceiling that binds for 2 of 167 live providers (1.2%) -- openrouter's is
# 10,000,000, kilo's and poe's 2,000,000. So pinning an uncatalogued 32k model
# on openrouter emitted 128000, the wrapper exported a ~119808 input window,
# and Claude Code packed ~120k into a 32k endpoint: a 400 on the first request,
# in exactly the direction this module claims to avoid. The bound is now the
# provider's own 10th percentile over tool-call-capable models -- the same
# statistic that produced the 128000 default from the catalog as a whole --
# floored so "conservative" cannot degenerate into "unusable" (poe's raw p10 is
# 480 tokens).
_p10="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import providers_resolve as R
# One flagship, nine ordinary models: max says 2,000,000, the truth says 65536.
sibs = {"flagship": {"id": "flagship", "tool_call": True,
                     "limit": {"context": 2000000, "output": 16384}}}
for i in range(9):
    sibs["m%d" % i] = {"id": "m%d" % i, "tool_call": True,
                       "limit": {"context": 65536, "output": 8192}}
print(R.derive_limits({"id": "uncatalogued"}, sibs)[:2])
# The floor still keeps it usable when the percentile is absurdly small.
tiny = {"img": {"id": "img", "tool_call": True, "limit": {"context": 480, "output": 480}},
        "big": {"id": "big", "tool_call": True, "limit": {"context": 2000000, "output": 16384}}}
print(R.derive_limits({"id": "uncatalogued"}, tiny)[:2])' "$SCRIPTS_DIR")"
assert_eq "(65536, 8192)
(65536, 8192)" "$_p10" "fallback follows the provider's typical model, floored at a usable window"

it "limit.input below limit.context caps the emitted window (ATM-853 opencode compaction loop)"
# opencode/big-pickle publishes {context:200000, input:160000, output:32000}.
# The emitted context_limit drives CLAUDE_CODE_AUTO_COMPACT_WINDOW — the
# INPUT-side guard. Deriving it from limit.context alone put the client-side
# compact trigger (200000-32000=168000) ABOVE the server's real input cap
# (160000): the guard could never fire before the endpoint rejected the
# request, so every over-limit turn produced reject -> compact -> reject —
# the live "compresses on every prompt" loop. The window must respect
# limit.input when the catalog publishes one.
_inp="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import providers_resolve as R
bp = {"id": "big-pickle", "limit": {"context": 200000, "input": 160000, "output": 32000}}
ctx, out, _ = R.derive_limits(bp)
print((ctx, out))
# Control 1: input >= context is not a tighter cap — context wins unchanged.
loose = {"id": "loose", "limit": {"context": 100000, "input": 200000, "output": 8192}}
print(R.derive_limits(loose)[:2])
# Control 2: no input field at all — behaviour byte-identical to before.
plain = {"id": "plain", "limit": {"context": 100000, "output": 8192}}
print(R.derive_limits(plain)[:2])' "$SCRIPTS_DIR")"
assert_eq "(160000, 8192)
(100000, 8192)
(100000, 8192)" "$_inp" "context_limit = min(limit.context, limit.input) with the output carve re-applied against the REAL window; controls unchanged"

it "model_verify: an UNCATALOGUED live-proven model is not demoted for an UNKNOWN context (ATM-860)"
# helixagent's .gguf id is not in models.dev; enrich_from_catalog read the
# absent context as 0 and demoted a model the live completion probe had just
# PROVEN serving (verified=False, "Context window too small: 0 < 8000") —
# a §11.4.201 false refusal: UNKNOWN is not "too small". A KNOWN-small
# context must still demote (control).
_mv="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import model_verify as V
unk = [{"model_id": "local.gguf", "score": 55, "verified": True,
        "capabilities": {"context_window": 0, "output_tokens": 0}}]
V.enrich_from_catalog(unk, {})
print(unk[0]["verified"])
small = [{"model_id": "tiny", "score": 55, "verified": True,
          "capabilities": {"context_window": 0, "output_tokens": 0}}]
V.enrich_from_catalog(small, {"tiny": {"limit": {"context": 4000, "output": 2048}}})
print(small[0]["verified"])' "$SCRIPTS_DIR")"
assert_eq "True
False" "$_mv" "unknown context stays verified (live probe is ground truth); known-small still demotes"

it "a context narrower than the 8192 output floor does not invert the pair"
# microcorp's sole model is the impossible 8000/8000 shape: the output slot holds
# a context value, so it is discarded, and the 8192 floor would then exceed the
# entire 8000-token window.
assert_eq "8000" "$(rfield "$LOUT" MICROCORP_API_KEY context_limit)" "context kept"
assert_eq "4000" "$(rfield "$LOUT" MICROCORP_API_KEY max_output)"    "floor halved to fit"

it "a catalogued model with no limit block at all still yields a guard"
assert_eq "128000" "$(rfield "$LOUT" VOIDCORP_API_KEY context_limit)" "conservative default"
assert_eq "8192"   "$(rfield "$LOUT" VOIDCORP_API_KEY max_output)"    "carved from it"

it "a context_limit override re-carves the cap instead of keeping a stale one"
# kimi-for-coding states context_limit 262144 with no max_output. The cap on
# record was carved from the 128000 unknown-model fallback; keeping it would pin
# the alias to 8192 output when its own stated window affords 102144.
_kfix="$HOME/limfixture-kimi"; mkdir -p "$_kfix"
cat > "$_kfix/overrides.json" <<'JSON'
{ "opaquecorp": { "strong_model": "oc-provider-only-model", "context_limit": 262144 } }
JSON
python3 "$RESOLVE" --models-dev "$LFIX/catalog.json" \
  --overrides "$_kfix/overrides.json" --keys "OPAQUECORP_API_KEY" > "$_kfix/out.json"
assert_eq "262144" "$(rfield "$_kfix/out.json" OPAQUECORP_API_KEY context_limit)" "stated context"
assert_eq "102144" "$(rfield "$_kfix/out.json" OPAQUECORP_API_KEY max_output)" "re-carved, not stale 8192"

it "an operator max_output >= their own context_limit is corrected, not shipped"
# A human pin outranks the credit rule and the model ranking; it does not
# outrank input+output<=context, which is a property of the endpoint.
_bfix="$HOME/limfixture-bogus"; mkdir -p "$_bfix"
cat > "$_bfix/overrides.json" <<'JSON'
{ "statedcorp": { "strong_model": "sc-auto", "context_limit": 32000, "max_output": 64000 } }
JSON
python3 "$RESOLVE" --models-dev "$LFIX/catalog.json" \
  --overrides "$_bfix/overrides.json" --keys "STATEDCORP_API_KEY" > "$_bfix/out.json"
_bc="$(rfield "$_bfix/out.json" STATEDCORP_API_KEY context_limit)"
_bo="$(rfield "$_bfix/out.json" STATEDCORP_API_KEY max_output)"
cond=1; [ "$_bo" -lt "$_bc" ] && cond=0
assert_eq 0 "$cond" "override pair corrected to output($_bo) < context($_bc)"

it "a malformed operator override is rejected AND reported, never fail-open"
# I4: overrides.json is hand-edited, so its values are validated, not merely
# present-checked. `isinstance(True, int)` is True in Python, so
# `"context_limit": true` used to become the integer 1, carve to no cap at all,
# and make the launch wrapper export NEITHER guard -- fully unguarded, which is
# the exact hole this work exists to close. `-1`, `0` and `50000.5` reached the
# same place. Each bad shape must leave the derived pair standing and say why.
_ovfix="$HOME/limfixture-badoverrides"; mkdir -p "$_ovfix"
for _bad in 'true' '-1' '0' '50000.5' '"abc"' 'null' '[]'; do
  cat > "$_ovfix/overrides.json" <<JSON
{ "statedcorp": { "strong_model": "sc-auto", "context_limit": $_bad } }
JSON
  python3 "$RESOLVE" --models-dev "$LFIX/catalog.json" \
    --overrides "$_ovfix/overrides.json" --keys "STATEDCORP_API_KEY" > "$_ovfix/out.json" 2>"$_ovfix/err"
  _rc=$?
  assert_eq 0 "$_rc" "context_limit=$_bad does not crash the resolver"
  _c="$(rfield "$_ovfix/out.json" STATEDCORP_API_KEY context_limit)"
  _o="$(rfield "$_ovfix/out.json" STATEDCORP_API_KEY max_output)"
  _ok=1
  case "$_c" in ''|*[!0-9]*) _ok=0 ;; esac
  case "$_o" in ''|*[!0-9]*) _ok=0 ;; esac
  [ "$_ok" = 1 ] && [ "$_c" -gt 0 ] && [ "$_o" -gt 0 ] && [ "$_o" -lt "$_c" ] || _ok=0
  assert_eq 1 "$_ok" "context_limit=$_bad still yields a complete guard pair (got $_c/$_o)"
  # `null` is an absent value, not a typo; everything else must be called out.
  if [ "$_bad" != "null" ]; then
    _reason="$(python3 -c '
import json,sys
for r in json.load(open(sys.argv[1])):
    if r["key_var"]=="STATEDCORP_API_KEY": print(r["selection_reason"])' "$_ovfix/out.json")"
    case "$_reason" in *"ignored override context_limit"*) _sc=0 ;; *) _sc=1 ;; esac
    assert_eq 0 "$_sc" "context_limit=$_bad rejection is surfaced, not silent"
  fi
done

it "a digit-string override is honored instead of being silently dropped"
# "200000" is unambiguous and hand-written JSON produces it constantly; it used
# to be dropped with no diagnostic at all.
cat > "$_ovfix/overrides.json" <<'JSON'
{ "statedcorp": { "strong_model": "sc-auto", "context_limit": "200000" } }
JSON
python3 "$RESOLVE" --models-dev "$LFIX/catalog.json" \
  --overrides "$_ovfix/overrides.json" --keys "STATEDCORP_API_KEY" > "$_ovfix/out.json"
assert_eq "200000" "$(rfield "$_ovfix/out.json" STATEDCORP_API_KEY context_limit)" "digit string coerced"
assert_eq "40000"  "$(rfield "$_ovfix/out.json" STATEDCORP_API_KEY max_output)"    "cap re-carved from it"

it "an override too small to carve a cap from is refused, not shipped unguarded"
cat > "$_ovfix/overrides.json" <<'JSON'
{ "statedcorp": { "strong_model": "sc-auto", "context_limit": 1 } }
JSON
python3 "$RESOLVE" --models-dev "$LFIX/catalog.json" \
  --overrides "$_ovfix/overrides.json" --keys "STATEDCORP_API_KEY" > "$_ovfix/out.json"
_tc="$(rfield "$_ovfix/out.json" STATEDCORP_API_KEY context_limit)"
_to="$(rfield "$_ovfix/out.json" STATEDCORP_API_KEY max_output)"
_tok=0; [ -n "$_to" ] && [ "$_to" -gt 0 ] && [ "$_to" -lt "$_tc" ] && _tok=1
assert_eq 1 "$_tok" "refused context_limit=1; derived pair stands (got $_tc/$_to)"

it "a malformed catalog row degrades to 'no limits', it does not crash the sync"
# models.dev is REMOTE input. `model.get("limit") or {}` keeps a truthy list, so
# a row whose limit/cost is a JSON array used to abort `claude-providers sync`
# with an AttributeError traceback.
_malformed="$HOME/malformed-catalog.json"
cat > "$_malformed" <<'JSON'
{
  "brokencorp": {
    "env": ["BROKENCORP_API_KEY"],
    "api": "https://api.brokencorp.ai/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "listlimit": {"id":"listlimit","tool_call":true,"limit":[1,2],"cost":[3,4]},
      "listcost":  {"id":"listcost","tool_call":true,"limit":{"context":262144,"output":8192},"cost":["nope"],"release_date":["2026"]}
    }
  }
}
JSON
python3 "$RESOLVE" --models-dev "$_malformed" --keys "BROKENCORP_API_KEY" > "$HOME/malformed-out.json" 2>"$HOME/malformed-err"
assert_eq 0 $? "malformed catalog resolves without a traceback"
_mc="$(rfield "$HOME/malformed-out.json" BROKENCORP_API_KEY context_limit)"
_mo="$(rfield "$HOME/malformed-out.json" BROKENCORP_API_KEY max_output)"
_mok=0; [ -n "$_mc" ] && [ -n "$_mo" ] && [ "$_mo" -gt 0 ] && [ "$_mo" -lt "$_mc" ] && _mok=1
assert_eq 1 "$_mok" "malformed rows still yield a valid guard pair (got $_mc/$_mo)"

it "derive_limits emits a COMPLETE, valid guard pair for ANY input"
# Property sweep over the shapes models.dev actually contains, including the
# degenerate ones: absent limit block (the uncatalogued-pin case), context-only,
# output-only, the impossible output>=context, windows far below the 8192
# output floor, and the malformed types a remote catalog can hand us. A second
# loop (below) drives the CORROBORATION CORRECTION branch — which the main
# product loop cannot reach with corroboration=None — across viable and
# sub-viable corrected contexts, so the round-4 (1, None) fail-open is swept too.
#
# The invariant is STRICT, and deliberately so. It used to read
# `if ro is not None and ro >= rc`, which permitted a null output — while `outs`
# already contained 0, the exact input that produces one. The assertion
# therefore skipped its own most interesting case, and the block claimed "the
# launch wrapper always has a guard" while proving only half a pair: a context
# alone is NOT the guard, both env vars have to be exported. Now:
#   (i)   context is a positive int (not None, not bool, not float);
#   (ii)  max_output is a positive int, ALWAYS present;
#   (iii) max_output < context.
#
# C3: this block used to end its python with a blanket `2>/dev/null` and assert
# the output was EMPTY. Any crash — an import error, a typo, a renamed symbol —
# produced empty stdout and therefore read as a PASS; making the module
# unimportable left this test green. The case count was printed to stderr and
# thrown away, so nothing proved the sweep had run at all. Now stderr is left
# alone (a traceback is visible and fails the match) and the assertion carries
# the POSITIVE case count on stdout, so "nothing went wrong" and "nothing
# happened" can no longer produce the same result.
_prop="$(python3 -c '
import itertools, sys
sys.path.insert(0, sys.argv[1])
import providers_resolve as R
# 1 is the I5 case: a context too small to carve any output cap from. It used
# to yield the pair (1, None) — a context with no guard, the fail-open shape —
# and the sweep did not contain it.
ctxs = [None, 0, -1, 1, True, False, 50000.5, "200000", "abc", 448, 4000, 8000,
        8192, 16000, 60000, 125000, 128000, 200000, 262144, 1000000, 1048576]
outs = [None, 0, -1, True, False, 4096.5, "8192", 448, 2048, 4096, 8000, 8192,
        65536, 131072, 262144, 1000000]
sibsets = [{}, {"a": {"id": "a", "limit": {"context": 4000, "output": 2048}}},
           {"b": {"id": "b", "limit": {"context": 60000, "output": 4096}}},
           {"c": {"id": "c", "limit": {"context": 2000000, "output": 65536}}},
           {"d": {"id": "d"}},
           {"e": {"id": "e", "limit": [1, 2]}},
           {"f": {"id": "f", "limit": {"context": 32768, "output": 0}, "tool_call": True}}]
def posint(v):
    return isinstance(v, int) and not isinstance(v, bool) and v > 0
bad = []
for c, o, sibs in itertools.product(ctxs, outs, sibsets):
    lim = {}
    if c is not None: lim["context"] = c
    if o is not None: lim["output"] = o
    m = {"id": "m", "limit": lim} if lim else {"id": "m"}
    try:
        rc, ro, _ = R.derive_limits(m, sibs)
    except Exception as exc:
        bad.append("ctx=%r out=%r -> RAISED %s" % (c, o, type(exc).__name__)); continue
    if not posint(rc):
        bad.append("ctx=%r out=%r -> context %r not a positive int" % (c, o, rc)); continue
    if not posint(ro):
        bad.append("ctx=%r out=%r -> max_output %r not a positive int" % (c, o, ro)); continue
    if ro >= rc:
        bad.append("ctx=%r out=%r -> %s>=%s (inverted)" % (c, o, ro, rc))
# The product loop above passes corroboration=None, so it structurally CANNOT
# reach the correction branch (`ctx = corroborated`) — the exact latent path
# the round-4 fail-open lived on. This second loop forces a corroboration
# correction to every target below, INCLUDING the sub-viable ctx=1 that used to
# produce (1, None), and holds the SAME strict invariant. A small-but-viable
# target (e.g. 32768) must be CARVED, never inflated to the unknown floor.
corr_cases = 0
for target in [1, 2, 448, 4000, 8000, 8192, 16000, 32768, 65536, 128000, 262144]:
    corr_cases += 1
    accused_models = {
        "v/probe": {"id": "v/probe", "tool_call": True,
                    "limit": {"context": 1000000, "output": 16384}},
        "v/probe:free": {"id": "v/probe:free", "tool_call": True,
                         "limit": {"context": 1000000, "output": 262144}}}
    catalog = {"acc": {"models": accused_models}}
    for i in range(3):  # three independent same-vendor peers at `target`
        catalog["p%d" % i] = {"models": {"v/probe": {
            "id": "v/probe", "tool_call": True,
            "limit": {"context": target, "output": 4096}}}}
    corr = R.build_context_corroboration(catalog)
    rc, ro, note = R.derive_limits(accused_models["v/probe:free"],
                                   accused_models, corr, "acc")
    if "context corrected to" not in note:
        bad.append("target=%r -> correction branch NOT reached" % target); continue
    if not posint(rc):
        bad.append("target=%r -> context %r not a positive int" % (target, rc)); continue
    if not posint(ro):
        bad.append("target=%r -> max_output %r not a positive int" % (target, ro)); continue
    if ro >= rc:
        bad.append("target=%r -> %s>=%s (inverted)" % (target, ro, rc))
print("cases=%d violations=%s" % (len(ctxs)*len(outs)*len(sibsets) + corr_cases,
                                  " | ".join(bad[:6])))' "$SCRIPTS_DIR")"
assert_eq "cases=2363 violations=" "$_prop" "derive_limits invariant over all 2363 shapes (incl. correction branch): '$_prop'"

it "EVERY row of the real models.dev catalog satisfies the guard contract"
# The designed sweep above covers the shapes we thought of; this one covers the
# ones models.dev actually ships (5696 rows across 167 providers at the time of
# writing). Read-only, and SKIPped when no cache is on the host, so the suite
# stays hermetic -- it never writes outside the sandbox and never fetches.
# $HOME is the sandbox here, so the real cache is located via getent, not $HOME.
_sweep_cache="${CMA_MODELS_DEV_CACHE:-}"
if [ -z "$_sweep_cache" ]; then
  _sweep_home="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)"
  [ -n "$_sweep_home" ] && \
    _sweep_cache="$_sweep_home/.local/share/claude-multi-account/providers/models.dev.cache.json"
fi
if [ -r "$_sweep_cache" ]; then
  _sweep="$(python3 -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import providers_resolve as R
with open(sys.argv[2]) as fh:
    catalog = json.load(fh)
corr = R.build_context_corroboration(catalog)
def posint(v):
    return isinstance(v, int) and not isinstance(v, bool) and v > 0
bad, rows = [], 0
for pid, provider in catalog.items():
    models = (provider or {}).get("models")
    if not isinstance(models, dict):
        continue
    for mid, m in models.items():
        if not isinstance(m, dict):
            continue
        rows += 1
        try:
            c, o, _ = R.derive_limits(m, models, corr, pid)
        except Exception as exc:
            bad.append("%s/%s RAISED %s" % (pid, mid, type(exc).__name__)); continue
        if not posint(c): bad.append("%s/%s context=%r" % (pid, mid, c))
        elif not posint(o): bad.append("%s/%s max_output=%r" % (pid, mid, o))
        elif o >= c: bad.append("%s/%s %s>=%s" % (pid, mid, o, c))
# C3: the row count is asserted, not discarded to stderr, and stderr is no
# longer swallowed. A crash now yields a traceback and a non-matching stdout
# instead of an empty string that reads as success.
print("swept>=1000 %s violations=%s"
      % (rows >= 1000, " | ".join(bad[:6])))' "$SCRIPTS_DIR" "$_sweep_cache")"
  assert_eq "swept>=1000 True violations=" "$_sweep" "live-catalog contract: '$_sweep'"
else
  # A silent SKIP that scores as a PASS is how the only test covering
  # corroboration against real data disappears into the tally on CI or a fresh
  # clone. Make its absence audible AND scoreless — no assert_eq here, so it
  # cannot be counted as a passing test. Corroboration itself is no longer
  # UNCOVERED without the cache: the C1/C2/I1-I6 adjudication fixtures and the
  # property sweep's correction-branch loop above exercise it hermetically. What
  # is skipped here is only the every-live-row confirmation, which genuinely
  # needs the cache; scoring it as a pass would be the lie this branch warns of.
  printf '    \033[33m[SKIP]\033[0m live-catalog sweep: no models.dev cache at %s — every-row confirmation skipped (corroboration still covered hermetically above)\n' \
    "${_sweep_cache:-<unset>}" >&2
fi

it "an output slot of 0 is UNKNOWN, never a binding cap of zero"
# I5: models.dev carries "output": 0 on 166 live rows and "context": 0 on 104
# (stepfun, stepfun-ai). Read literally, a zero cap yielded max_output=None on
# 176 rows -- 18 with a context >= 32768, 11 of those tool-call capable -- and
# an empty cap is precisely the fail-open the module contracts against. The
# violation was masked only because lib.sh re-derives a cap when the resolver
# emits none: a "0 violations" claim that silently depended on a file this
# module does not own.
_zero="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import providers_resolve as R
out = []
for lim in ({"context": 262144, "output": 0}, {"context": 0, "output": 0},
            {"context": 0, "output": 65536}):
    out.append("%s->%s" % (sorted(lim.items()), R.derive_limits({"id": "z", "limit": lim}, {})[:2]))
print(" ".join(out))' "$SCRIPTS_DIR")"
assert_eq "[('context', 262144), ('output', 0)]->(262144, 102144) [('context', 0), ('output', 0)]->(128000, 8192) [('context', 0), ('output', 65536)]->(128000, 8192)" \
  "$_zero" "zero limits fall back to a real guard pair"

it "the out>=context shape resolves identically with or without a pre-detector"
# I2: the dedicated `output >= context` branch was provably dead -- disabling it
# changed the result on 0 of 5696 live rows -- because _carve_output's `cap` is
# strictly below `ctx` on every branch, so min(out, cap) == cap for any
# out >= ctx. The 1099 rows in that shape are fixed by the CARVE. This pins the
# property so the branch is never reinstated as a no-op that documentation then
# credits with real work.
_deadeq="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import providers_resolve as R
bad = []
for c in (448, 4000, 8000, 8192, 60000, 128000, 200000, 262144, 1000000):
    for o in (c, c + 1, c * 2, 1000000):
        with_out = R.derive_limits({"id": "m", "limit": {"context": c, "output": o}}, {})[:2]
        no_out = R.derive_limits({"id": "m", "limit": {"context": c}}, {})[:2]
        if with_out != no_out:
            bad.append("ctx=%d out=%d: %s != %s" % (c, o, with_out, no_out))
print(" | ".join(bad[:4]))' "$SCRIPTS_DIR")"
assert_eq "" "$_deadeq" "carve already subsumes out>=context: '$_deadeq'"

it "shipped overrides.json: nvidia strong slot holds the flagship, not the nano"
# The nvidia pins were inverted: the 30B-A3B nano sat in the strong slot while
# the 550B flagship sat in fast. Guard the corrected orientation at source --
# a hand-edited nvidia.env would be regenerated away by the next sync.
SHIPPED="$SCRIPTS_DIR/providers/overrides.json"
assert_eq "nvidia/nemotron-3-ultra-550b-a55b" \
  "$(jq -r '.nvidia.strong_model // "MISSING"' "$SHIPPED")" "nvidia strong = ultra-550b"
assert_eq "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning" \
  "$(jq -r '.nvidia.fast_model // "MISSING"' "$SHIPPED")" "nvidia fast = nano-omni-30b"

it "VCS token is skipped, unknown llm key is unmapped"
assert_eq "skipped" "$(rfield "$OUT" GITHUB_TOKEN status)" "GITHUB_TOKEN skipped"
assert_eq "vcs" "$(rfield "$OUT" GITHUB_TOKEN classification)" "GITHUB_TOKEN vcs"
assert_eq "unmapped" "$(rfield "$OUT" FOO_API_KEY status)" "FOO_API_KEY unmapped"

# ---------------------------------------------------------------------------
# Section 3 — claude-providers sync end-to-end (offline, fixture catalog)
# Proves: alias creation, env files, config-dir linking, dedupe (one alias per
# provider), idempotency, and that the existing claudeN alias machinery is
# untouched. Uses CLAUDE_BIN=/usr/bin/true and --offline so nothing launches
# or hits the network.
# ---------------------------------------------------------------------------
PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"

# Seed the models.dev cache (offline) with a controlled catalog. mistral is
# present so the real key-aliases.json mapping CODESTRAL_API_KEY->mistral
# collides with MISTRAL_API_KEY -> exercises dedupe.
PCACHE="$HOME/.local/share/claude-multi-account/providers/models.dev.cache.json"
mkdir -p "$(dirname "$PCACHE")"
cat > "$PCACHE" <<'JSON'
{
  "acme":   {"env":["ACME_API_KEY"],"api":"https://api.acme.com/anthropic","npm":"@ai-sdk/anthropic",
             "models":{"b":{"id":"acme-big","reasoning":true,"release_date":"2025-05-01","limit":{"context":200000},"cost":{"input":3,"output":15},"tool_call":true},
                       "s":{"id":"acme-small","reasoning":false,"release_date":"2024-01-01","limit":{"context":32000},"cost":{"input":0.1,"output":0.4},"tool_call":true}}},
  "beta":   {"env":["BETA_API_KEY"],"api":"https://api.beta.ai/v1","npm":"@ai-sdk/openai-compatible",
             "models":{"f":{"id":"beta-x","reasoning":false,"release_date":"2025-06-01","limit":{"context":128000},"cost":{"input":1,"output":5},"tool_call":true}}},
  "mistral":{"env":["MISTRAL_API_KEY"],"api":"https://api.mistral.ai/v1","npm":"@ai-sdk/openai-compatible",
             "models":{"m":{"id":"mistral-large","reasoning":false,"release_date":"2025-04-01","limit":{"context":128000},"cost":{"input":2,"output":6},"tool_call":true}}},
  "zai-coding-plan":{"env":["ZAI_API_KEY"],"api":"https://api.z.ai/api/coding/paas/v4","npm":"@ai-sdk/openai-compatible",
             "models":{"g5.2":{"id":"glm-5.2","reasoning":true,"tool_call":true,"release_date":"2026-06-13","limit":{"context":1000000},"cost":{"input":0,"output":0}},
                       "g4.7":{"id":"glm-4.7","reasoning":true,"tool_call":true,"release_date":"2025-12-22","limit":{"context":204800},"cost":{"input":0,"output":0}}}},
  "xiaomi":{"env":["XIAOMI_API_KEY"],"api":"https://api.xiaomimimo.com/v1","npm":"@ai-sdk/openai-compatible",
             "models":{"u":{"id":"mimo-v2.5-pro-ultraspeed","reasoning":true,"tool_call":true,"release_date":"2026-07-01","limit":{"context":1000000},"cost":{"input":0,"output":0}},
                       "p":{"id":"mimo-v2.5-pro","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":1000000},"cost":{"input":2,"output":8}},
                       "f":{"id":"mimo-v2-flash","reasoning":true,"tool_call":true,"release_date":"2026-05-01","limit":{"context":256000},"cost":{"input":0.1,"output":0.4}}}},
  "opencode":{"env":["OPENCODE_API_KEY"],"api":"https://opencode.ai/zen/v1","npm":"@ai-sdk/openai-compatible",
             "models":{"bp":{"id":"big-pickle","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":200000},"cost":{"input":0,"output":0}},
                       "df":{"id":"deepseek-v4-flash-free","reasoning":true,"tool_call":true,"release_date":"2026-05-01","limit":{"context":200000},"cost":{"input":0,"output":0}},
                       "nu":{"id":"nemotron-3-ultra-free","reasoning":true,"tool_call":true,"release_date":"2026-04-01","limit":{"context":1000000},"cost":{"input":0,"output":0}}}}
}
JSON

# Fake keys file (NAMES only matter; values are dummy and never executed by us).
KEYS="$HOME/api_keys.sh"
cat > "$KEYS" <<'SH'
export ACME_API_KEY="dummy-acme"
export BETA_API_KEY="dummy-beta"
export MISTRAL_API_KEY="dummy-mistral"
export CODESTRAL_API_KEY="dummy-codestral"
export ZAI_API_KEY="dummy-zai"
export XIAOMI_MIMO_API_KEY="dummy-xiaomi"
export ZEN_API_KEY="dummy-zen"
export ApiKey_Opencode_Zen="dummy-zen-2"
export GITHUB_TOKEN="dummy-gh"
SH

# A pre-existing real account alias must survive untouched.
cma_write_alias claude1 "$HOME/.claude-acct1"

bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >/dev/null 2>&1
sync_rc=$?

it "sync exits cleanly"
assert_eq 0 "$sync_rc" "sync rc"

it "cmd_sync heals a stale/outdated cma_run_provider wrapper (final-review I-2)"
# Simulate a pre-Phase-2 alias file whose wrapper lacks the activation-gate marker
# (_cma_force). cma_provider_write_alias only bootstraps when the file is ABSENT
# (to keep --refresh-aliases byte-idempotent), so the heal must come from cmd_sync's
# one-time cma_ensure_alias_file. Corrupt the wrapper, re-sync, assert it regenerated.
awk '/^cma_run_provider\(\) ?\{/{print "cma_run_provider() {"; print "  echo STALE-NO-GATE"; print "}"; s=1; next} s&&/^}/{s=0; next} !s{print}' "$ALIAS_FILE" > "$ALIAS_FILE.x" && mv "$ALIAS_FILE.x" "$ALIAS_FILE"
grep -q '_cma_force' "$ALIAS_FILE" && _pre=1 || _pre=0
assert_eq 0 "$_pre" "wrapper is stale before re-sync (no _cma_force)"
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >/dev/null 2>&1
grep -q '_cma_force' "$ALIAS_FILE"; assert_eq 0 $? "cmd_sync healed the stale wrapper (_cma_force restored)"
# (refresh-vs-refresh byte-idempotence is covered separately by the "--refresh-aliases
#  is idempotent" test; cmd_sync output need not equal refresh(cmd_sync output).)

it "present_key_vars dies clearly when CMA_KEYS_FILE is a directory (v1.12.1 5a)"
# -e (kept for FIFO/process-substitution keys files) also passes a DIRECTORY, which
# then yields a silent "0 key vars" (grep on a dir). A directory must die clearly.
_kd="$(mktemp -d "${TMPDIR:-/tmp}/cma-kd.XXXXXX")"
_kderr="$( bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$_kd" 2>&1 >/dev/null )"; _kdrc=$?
grep -qi 'is a directory' <<<"$_kderr"; assert_eq 0 $? "directory keys-file -> clear 'is a directory' die"
[[ "$_kdrc" -ne 0 ]]; assert_eq 0 $? "directory keys-file -> non-zero exit (not silent 0 key vars)"
rm -rf "$_kd"

it "cmd_sync_multi ALSO dies clearly on a directory keys-file (v1.12.1 5a, --multi path)"
# The --multi path resolves keys through the same subshell pattern, so it needs its
# own main-process guard too (final-review IMPORTANT: cmd_sync had it, cmd_sync_multi did not).
_kd2="$(mktemp -d "${TMPDIR:-/tmp}/cma-kd2.XXXXXX")"
_kd2err="$( bash "$PROVIDERS_SH" sync --multi --offline --keys-file "$_kd2" 2>&1 >/dev/null )"; _kd2rc=$?
grep -qi 'is a directory' <<<"$_kd2err"; assert_eq 0 $? "--multi directory keys-file -> clear die"
[[ "$_kd2rc" -ne 0 ]]; assert_eq 0 $? "--multi directory keys-file -> non-zero exit (not silent 0 key vars)"
rm -rf "$_kd2"

it "sync persists per-provider verification status (--no-verify -> unverified)"
# With --no-verify, vstatus defaults to 'unverified' for every resolved
# provider, and cmd_sync must record it in the status cache so the list family
# + activation gate have a source of truth.
assert_file "$(cma_status_cache)" "status cache written by sync"
assert_eq "unverified" "$(cma_status_read acme)"    "acme status persisted"
assert_eq "unverified" "$(cma_status_read mistral)" "mistral status persisted"
assert_eq "unverified" "$(cma_status_read opencode)" "opencode status persisted"
assert_file_not_contains "$(cma_status_cache)" "dummy-" "no dummy key values leaked into status cache"

PDIR="$HOME/.local/share/claude-multi-account/providers"
it "env files created for each resolved provider"
assert_file "$PDIR/acme.env" "acme env"
assert_file "$PDIR/beta.env" "beta env"
assert_file "$PDIR/mistral.env" "mistral env"

it "provider aliases written via cma_run_provider"
grep -q '^alias acme="cma_run_provider acme"' "$ALIAS_FILE" ; assert_eq 0 $? "acme alias"
grep -q '^alias beta="cma_run_provider beta"' "$ALIAS_FILE" ; assert_eq 0 $? "beta alias"

it "CODESTRAL_API_KEY + MISTRAL_API_KEY dedupe to ONE mistral alias"
c="$(grep -c 'cma_run_provider mistral"' "$ALIAS_FILE")"
assert_eq "1" "$c" "exactly one mistral alias"

it "native vs router transport recorded in env file"
grep -qE "^CMA_PROVIDER_TRANSPORT='?native'?" "$PDIR/acme.env" ; assert_eq 0 $? "acme native"
grep -qE "^CMA_PROVIDER_TRANSPORT='?router'?" "$PDIR/beta.env" ; assert_eq 0 $? "beta router"

it "zai-coding-plan env file created with coding endpoint and strong/fast overrides"
assert_file "$PDIR/zai-coding-plan.env" "zai-coding-plan env"
grep -qE "^CMA_PROVIDER_BASE_URL='?https://api.z.ai/api/coding/paas/v4'?" "$PDIR/zai-coding-plan.env" ; assert_eq 0 $? "coding endpoint"
grep -qE "^CMA_PROVIDER_MODEL='?glm-5.2'?" "$PDIR/zai-coding-plan.env" ; assert_eq 0 $? "strong model glm-5.2"
grep -qE "^CMA_PROVIDER_FAST_MODEL='?glm-4.7'?" "$PDIR/zai-coding-plan.env" ; assert_eq 0 $? "fast model glm-4.7"
grep -qE "^CMA_PROVIDER_TRANSPORT='?router'?" "$PDIR/zai-coding-plan.env" ; assert_eq 0 $? "zai-coding-plan router"

it "zai-coding-plan alias written via cma_run_provider"
grep -q '^alias zai-coding-plan="cma_run_provider zai-coding-plan"' "$ALIAS_FILE" ; assert_eq 0 $? "zai-coding-plan alias"

it "xiaomi env file created with router transport + /v1 base + pinned models"
# v1.19.0: xiaomi moved native(/anthropic) -> router(/v1). Its OpenAI-compatible
# endpoint is live-verified, so it routes through ccr like every other provider.
assert_file "$PDIR/xiaomi.env" "xiaomi env"
grep -qE "^CMA_PROVIDER_TRANSPORT='?router'?" "$PDIR/xiaomi.env" ; assert_eq 0 $? "xiaomi router transport"
grep -qE "^CMA_PROVIDER_BASE_URL='?https://api.xiaomimimo.com/v1'?" "$PDIR/xiaomi.env" ; assert_eq 0 $? "xiaomi /v1 base"
grep -qE "^CMA_PROVIDER_MODEL='?mimo-v2.5-pro'?" "$PDIR/xiaomi.env" ; assert_eq 0 $? "xiaomi strong model mimo-v2.5-pro"
grep -qE "^CMA_PROVIDER_FAST_MODEL='?mimo-v2.5'?" "$PDIR/xiaomi.env" ; assert_eq 0 $? "xiaomi fast model mimo-v2.5"
grep -qE "^CMA_PROVIDER_KEYVAR='?XIAOMI_MIMO_API_KEY'?" "$PDIR/xiaomi.env" ; assert_eq 0 $? "xiaomi keyvar pinned"

it "xiaomi alias written via cma_run_provider"
grep -q '^alias xiaomi="cma_run_provider xiaomi"' "$ALIAS_FILE" ; assert_eq 0 $? "xiaomi alias"

it "config dir created and shared items symlinked"
assert_dir "$HOME/.claude-prov-acme" "acme config dir"
assert_symlink_to "$HOME/.claude-prov-acme/plugins" "$SHARED_DIR/plugins" "plugins linked"

it "xiaomi config dir created and shared items symlinked"
assert_dir "$HOME/.claude-prov-xiaomi" "xiaomi config dir"
assert_symlink_to "$HOME/.claude-prov-xiaomi/plugins" "$SHARED_DIR/plugins" "xiaomi plugins linked"

it "xiaomi provider dir excluded from account detection"
det="$(cma_detect_accounts)"
echo "$det" | grep -q "prov-xiaomi" ; assert_eq 1 $? "prov-xiaomi excluded from detection"

it "opencode env file created with router transport + zen/v1 base + pinned models"
assert_file "$PDIR/opencode.env" "opencode env"
grep -qE "^CMA_PROVIDER_TRANSPORT='?router'?" "$PDIR/opencode.env" ; assert_eq 0 $? "opencode router transport"
grep -qE "^CMA_PROVIDER_BASE_URL='?https://opencode.ai/zen/v1'?" "$PDIR/opencode.env" ; assert_eq 0 $? "opencode zen/v1 base"
grep -qE "^CMA_PROVIDER_MODEL='?big-pickle'?" "$PDIR/opencode.env" ; assert_eq 0 $? "opencode strong model big-pickle"
grep -qE "^CMA_PROVIDER_FAST_MODEL='?deepseek-v4-flash-free'?" "$PDIR/opencode.env" ; assert_eq 0 $? "opencode fast model deepseek-v4-flash-free"
# The resolver picks the first key that maps to 'opencode' after alphabetical sort
# by present_key_vars: ApiKey_Opencode_Zen < ZEN_API_KEY, so it wins as keyvar.
grep -qE "^CMA_PROVIDER_KEYVAR='?ApiKey_Opencode_Zen'?" "$PDIR/opencode.env" ; assert_eq 0 $? "opencode keyvar ApiKey_Opencode_Zen"

it "opencode alias written via cma_run_provider"
# overrides.json pins "alias": "opencode-zen" on the opencode record (57ba5a2,
# 2026-07-24 — distinguishes the Zen endpoint from the newer Zen/Go provider),
# so the shell alias is opencode-zen while the provider id stays opencode.
grep -q '^alias opencode-zen="cma_run_provider opencode"' "$ALIAS_FILE" ; assert_eq 0 $? "opencode alias"

it "opencode config dir created and shared items symlinked"
assert_dir "$HOME/.claude-prov-opencode" "opencode config dir"
assert_symlink_to "$HOME/.claude-prov-opencode/plugins" "$SHARED_DIR/plugins" "opencode plugins linked"

it "opencode provider dir excluded from account detection"
det="$(cma_detect_accounts)"
echo "$det" | grep -q "prov-opencode" ; assert_eq 1 $? "prov-opencode excluded from detection"

it "the existing claudeN alias is untouched"
grep -q '^alias claude1=' "$ALIAS_FILE" ; assert_eq 0 $? "claude1 still present"

it "provider dirs remain excluded from account detection after sync"
det="$(cma_detect_accounts)"
echo "$det" | grep -q "prov-acme" ; assert_eq 1 $? "prov-acme excluded"

it "no secret values leaked into env files or alias file"
grep -rq "dummy-acme\|dummy-beta\|dummy-mistral\|dummy-xiaomi\|dummy-zen" "$PDIR" "$ALIAS_FILE" ; assert_eq 1 $? "no key values present"

it "sync is idempotent — second run does not duplicate aliases"
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >/dev/null 2>&1
c2="$(grep -c 'cma_run_provider acme"' "$ALIAS_FILE")"
assert_eq "1" "$c2" "still one acme alias after re-sync"
c2x="$(grep -c 'cma_run_provider xiaomi"' "$ALIAS_FILE")"
assert_eq "1" "$c2x" "still one xiaomi alias after re-sync"
c2z="$(grep -c 'cma_run_provider opencode"' "$ALIAS_FILE")"
assert_eq "1" "$c2z" "still one opencode alias after re-sync"

it "list family splits by status: list=verified, list-all=all, list-faulty=faulty"
# Section 3 synced with --no-verify, so every provider is 'unverified'.
# list (verified-only) hides them; list-all + list-faulty show them.
la_out="$(bash "$PROVIDERS_SH" list-all 2>/dev/null)"
echo "$la_out" | grep -q "acme"; assert_eq 0 $? "list-all shows unverified acme"
lf_out="$(bash "$PROVIDERS_SH" list-faulty 2>/dev/null)"
echo "$lf_out" | grep -q "acme"; assert_eq 0 $? "list-faulty shows unverified acme"
l_out="$(bash "$PROVIDERS_SH" list 2>/dev/null)"
echo "$l_out" | grep -q "acme" && _seen=1 || _seen=0
assert_eq 0 "$_seen" "list (verified-only) hides unverified acme"
# Mark acme verified -> now it appears under list and disappears from list-faulty.
cma_status_write acme verified acme-big ""
l_out2="$(bash "$PROVIDERS_SH" list 2>/dev/null)"
echo "$l_out2" | grep -q "acme"; assert_eq 0 $? "list shows acme once verified"
lf_out2="$(bash "$PROVIDERS_SH" list-faulty 2>/dev/null)"
echo "$lf_out2" | grep -q "acme" && _seen2=1 || _seen2=0
assert_eq 0 "$_seen2" "list-faulty hides acme once verified"
# Restore acme to unverified so later sections see the sync-time state.
cma_status_write acme unverified acme-big semantic

it "remove deletes alias + env, backs up config dir"
bash "$PROVIDERS_SH" remove beta >/dev/null 2>&1
cond=0; [[ -f "$PDIR/beta.env" ]] && cond=1; assert_eq 0 "$cond" "beta env gone"
grep -q 'cma_run_provider beta"' "$ALIAS_FILE" ; assert_eq 1 $? "beta alias gone"

# ---------------------------------------------------------------------------
# Section 4 — cross-shell wrapper smoke test (regression for the zsh
# `bad substitution` bug from ${!var} indirection). The alias file is sourced
# into the user's interactive shell, which is zsh on macOS — so the emitted
# cma_run_provider MUST work under zsh, not just bash. Guarded by zsh presence.
# ---------------------------------------------------------------------------
if command -v zsh >/dev/null 2>&1; then
  it "cma_run_provider runs under zsh (native transport) without bad substitution"
  # acme is the native-transport provider created in Section 3; its env file +
  # alias exist and $HOME/api_keys.sh defines ACME_API_KEY. Mark it verified so
  # the launch-time activation gate permits the launch and the zsh indirect
  # key-read (${!var}) path this test targets is actually exercised.
  cma_status_write acme verified acme-big ""
  # Provenance, zsh-side. bash's assert_fn_from cannot see into `zsh -c`, so the
  # snippet reports it itself: zsh's $functions_source[] (zsh/parameter, zsh>=5.4)
  # names the file that defined a function. Without this the block would only be
  # SAFE BY ACCIDENT — it would still pass if the source silently failed and a
  # /etc/zshenv or ~/.zshenv had already defined the host's cma_run_provider.
  z_out="$(CLAUDE_BIN=/usr/bin/true HOME="$HOME" zsh -c '
    emulate -L zsh
    source "'"$ALIAS_FILE"'" 2>&1
    zmodload zsh/parameter 2>/dev/null
    print -r -- "PROV=${functions_source[cma_run_provider]}"
    cma_run_provider acme </dev/null
    echo "RC=$?"' 2>&1)"
  z_prov="$(printf '%s\n' "$z_out" | sed -n 's/^PROV=//p')"
  assert_eq "$ALIAS_FILE" "$z_prov" "zsh provenance: cma_run_provider came from the sandbox alias file"
  echo "$z_out" | grep -qi 'bad substitution' ; assert_eq 1 $? "no zsh bad substitution"
  echo "$z_out" | grep -q 'RC=0' ; assert_eq 0 $? "wrapper exits 0 under zsh"
else
  it "zsh smoke test (skipped — zsh not installed)"
  _pass "zsh not present; bash path covered elsewhere"
fi

# ---------------------------------------------------------------------------
# Section 5 — cross-alias session visibility. Sessions created under any
# alias (claudeN or provider) must be visible from every other alias after
# sync-state runs. This proves the .claude.json merge includes provider dirs.
# ---------------------------------------------------------------------------
SYNC_SH="$SCRIPTS_DIR/claude-sync-state.sh"

# Create two accounts and one provider dir, each with a .claude.json that
# contains a unique session entry.
make_account xacct1
make_account xacct2
mkdir -p "$HOME/${ACCOUNT_PREFIX}prov-zen"
# Provider dir needs the same marker files as a real provider dir.
mkdir -p "$HOME/${ACCOUNT_PREFIX}prov-zen/projects"

# Each .claude.json has a unique project/session entry to prove merge.
cat > "$HOME/${ACCOUNT_PREFIX}xacct1/.claude.json" <<'JSON'
{"projects":{"/tmp/projectA":{"sessionId":"sess-a1","lastActive":"2026-06-20T10:00:00Z"}}}
JSON
cat > "$HOME/${ACCOUNT_PREFIX}xacct2/.claude.json" <<'JSON'
{"projects":{"/tmp/projectB":{"sessionId":"sess-b2","lastActive":"2026-06-20T11:00:00Z"}}}
JSON
cat > "$HOME/${ACCOUNT_PREFIX}prov-zen/.claude.json" <<'JSON'
{"projects":{"/tmp/projectC":{"sessionId":"sess-cz","lastActive":"2026-06-20T12:00:00Z"}}}
JSON

it "sync-state merge includes provider dirs"
# Run sync-state all to merge .claude.json across accounts + providers.
bash "$SYNC_SH" all 2>/dev/null
sync_rc=$?
assert_eq 0 "$sync_rc" "sync-state all exit 0"

it "session from account1 is visible in account2 after sync"
acct2_has_a1="$(python3 -c "import json; d=json.load(open('$HOME/${ACCOUNT_PREFIX}xacct2/.claude.json')); print('sess-a1' in str(d))" 2>/dev/null)"
assert_eq "True" "$acct2_has_a1" "acct2 sees sess-a1"

it "session from provider dir is visible in account1 after sync"
acct1_has_cz="$(python3 -c "import json; d=json.load(open('$HOME/${ACCOUNT_PREFIX}xacct1/.claude.json')); print('sess-cz' in str(d))" 2>/dev/null)"
assert_eq "True" "$acct1_has_cz" "acct1 sees sess-cz"

it "session from provider dir is visible in account2 after sync"
acct2_has_cz="$(python3 -c "import json; d=json.load(open('$HOME/${ACCOUNT_PREFIX}xacct2/.claude.json')); print('sess-cz' in str(d))" 2>/dev/null)"
assert_eq "True" "$acct2_has_cz" "acct2 sees sess-cz"

it "session from account1 is visible in provider dir after sync"
zen_has_a1="$(python3 -c "import json; d=json.load(open('$HOME/${ACCOUNT_PREFIX}prov-zen/.claude.json')); print('sess-a1' in str(d))" 2>/dev/null)"
assert_eq "True" "$zen_has_a1" "prov-zen sees sess-a1"

it "session from account2 is visible in provider dir after sync"
zen_has_b2="$(python3 -c "import json; d=json.load(open('$HOME/${ACCOUNT_PREFIX}prov-zen/.claude.json')); print('sess-b2' in str(d))" 2>/dev/null)"
assert_eq "True" "$zen_has_b2" "prov-zen sees sess-b2"

it "cma_run_provider wrapper has sync-state pull+push in alias file"
grep -q 'claude-sync-state.*pull' "$ALIAS_FILE" ; assert_eq 0 $? "pull present in wrapper"
grep -q 'claude-sync-state.*push' "$ALIAS_FILE" ; assert_eq 0 $? "push present in wrapper"

it "cma_run wrapper also has sync-state pull+push"
# Extract the FULL cma_run body (header → its column-0 closing brace) instead of a
# fixed `grep -A<N>` window: the body grows (provider-env isolation + auto session
# blocks), and a fixed window silently drops late markers like 'push' (which now
# sits ~30 lines in). Same robust pattern as test_claude.sh's _cma_run_body.
_run_body="$(awk '/^cma_run\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
grep -q 'claude-sync-state.*pull' <<<"$_run_body"; assert_eq 0 $? "cma_run pull"
grep -q 'claude-sync-state.*push' <<<"$_run_body"; assert_eq 0 $? "cma_run push"

it "cma_run has provider-env isolation (clears leaked ANTHROPIC_* before native launch)"
grep -q 'unset ANTHROPIC_BASE_URL' <<<"$_run_body"; assert_eq 0 $? "cma_run unsets ANTHROPIC_BASE_URL"

it "migration regenerating cma_run does NOT drop it (BRE empty-group \\(\\) bug regression)"
# Reproduce the exact failure: an OLD-format alias file with a cma_run lacking
# the 'unset ANTHROPIC_' marker, followed by cma_run_provider() and a claudeN
# alias. The buggy guard `grep '^cma_run\(\)'` matched cma_run_provider() too
# (empty capture group = matches "cma_run" prefix), so after stripping cma_run
# the re-append was skipped and the function vanished. With literal `()` it must
# strip-and-re-append cma_run, keep cma_run_provider, and preserve the alias.
_mig="$ALIAS_FILE.migtest"
cat > "$_mig" <<'OLDFMT'
export CLAUDE_BIN="/usr/bin/true"

cma_run() {
  "$CLAUDE_BIN" "$@"
}

cma_run_provider() {
  echo old
}

alias claude1="CLAUDE_CONFIG_DIR=$HOME/.claude-acct1 cma_run"
OLDFMT
( ALIAS_FILE="$_mig" cma_ensure_alias_file ) >/dev/null 2>&1
mig_run="$(grep -c '^cma_run()' "$_mig")"
mig_prov="$(grep -c '^cma_run_provider()' "$_mig")"
mig_alias="$(grep -c '^alias claude1=' "$_mig")"
# Scope to cma_run's own body: BOTH cma_run and cma_run_provider legitimately
# carry this unset (lib.sh:420 and :607), so a whole-file count is 2, not 1.
# This assertion is about cma_run specifically, so extract just its body.
mig_unset="$(awk '/^cma_run\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$_mig" | grep -c 'unset ANTHROPIC_BASE_URL')"
assert_eq 1 "$mig_run"   "cma_run re-appended after migration (not dropped)"
assert_eq 1 "$mig_prov"  "cma_run_provider preserved"
assert_eq 1 "$mig_alias" "claudeN alias preserved through migration"
assert_eq 1 "$mig_unset" "regenerated cma_run carries the env-isolation fix"
rm -f "$_mig"

# --- input-context token-limit guard (CLAUDE_CODE_AUTO_COMPACT_WINDOW) --------
# Fixes "400 exceeded model token limit: 262144 (requested: 311786)": the
# emitted cma_run_provider must export CLAUDE_CODE_AUTO_COMPACT_WINDOW from the
# provider's resolved CMA_PROVIDER_CONTEXT_LIMIT so Claude Code auto-compacts
# before overflowing a smaller provider's input window. The export is guarded so
# an unknown/empty limit is NOT exported, and sits BEFORE the transport branch
# so it applies to both native and router transports.
it "emitted cma_run_provider exports CLAUDE_CODE_AUTO_COMPACT_WINDOW from CMA_PROVIDER_CONTEXT_LIMIT (input token-limit guard)"
_acw_body="$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
# shellcheck disable=SC2016  # literal EMITTED code, not for expansion here
# NOTE: herestring (<<<), NOT `printf '%s\n' … | grep -q`. Under `set -o
# pipefail`, grep -q exits at the first match and closes the pipe; printf's
# remaining trailing write to the now-larger cma_run_provider body then takes
# SIGPIPE (rc 141), which pipefail surfaces as the pipeline exit -> a false
# FAIL (want=0 got=141) even though the match IS present. A herestring feeds
# the body via a temp file (no writer to kill), so grep's real rc is preserved.
# v1.24.0: the window is no longer CMA_PROVIDER_CONTEXT_LIMIT verbatim. It is
# co-derived with the output cap ($_cma_win = context - output, clamped) so the
# two guards cannot sum past the context — see the token-budget section at the
# end of this file for the behavioural assertions. The static check here is that
# the export still traces back to CMA_PROVIDER_CONTEXT_LIMIT.
grep -qF 'export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$_cma_win"' <<<"$_acw_body"
assert_eq 0 $? "auto-compact-window exported from the derived window"
# shellcheck disable=SC2016
grep -q 'CMA_PROVIDER_CONTEXT_LIMIT:-' <<<"$_acw_body"
assert_eq 0 $? "the derived window's input is CMA_PROVIDER_CONTEXT_LIMIT"
# shellcheck disable=SC2016
grep -qF '_cma_win="$_cma_octx"' <<<"$_acw_body"
assert_eq 0 $? "window seeded from the sanitized context limit"

it "cma_run_provider does NOT export the window when CMA_PROVIDER_CONTEXT_LIMIT is empty/unknown"
# Static-body check: the export line is conditional — immediately preceded by
# the [[ -n "${CMA_PROVIDER_CONTEXT_LIMIT:-}" ]] guard — so an empty/unknown
# limit never exports a bogus window.
# shellcheck disable=SC2016
grep -B45 'export CLAUDE_CODE_AUTO_COMPACT_WINDOW' <<<"$_acw_body" | grep -qF 'if [ -n "$_cma_octx" ]; then'
assert_eq 0 $? "export CLAUDE_CODE_AUTO_COMPACT_WINDOW is inside the known-context guard"

it "migration regenerates an outdated cma_run_provider that lacks the auto-compact cap guard"
# Mirror the cma_run migration regression above. The cma_run_provider migration
# guard (lib.sh) keys on the '_cma_compact_cap' marker — the local that caps the
# auto-compact window at <=200K — NOT on the bare 'CLAUDE_CODE_AUTO_COMPACT_WINDOW'
# export (which the guard does not check). Build an OLD-format alias file whose
# cma_run_provider carries ALL other current markers but is MISSING that guard.
# Rather than hand-write the body, take the CURRENT emitted body and delete the
# WHOLE token-guard region as ONE unit, between its begin/end sentinels.
# Deleting the block atomically (a) genuinely removes markers the guard keys on
# ('_cma_compact_cap' AND the v1.24.0 '_cma_in_guard'), so migration fires for
# the RIGHT reason, and (b) keeps the body valid bash (no orphan 'fi' — the bug a
# line-wise 'grep -v' strip of the export + its guard continuation introduced,
# which lost the 'if' but kept the 'fi'). Sentinel-delimited rather than
# 'first fi after the local', which silently under-deleted once the region grew
# a second 'if' and left '_cma_compact_cap' behind in the window block.
_mig2="$ALIAS_FILE.migtest2"
{
  printf 'export CLAUDE_BIN="/usr/bin/true"\n\n'
  awk '
    /cma-token-guards:begin/ { drop=1 }
    /cma-token-guards:end/   { drop=0; next }
    !drop
  ' <<<"$_acw_body"
  printf '\nalias kimi-for-coding="cma_run_provider kimi-for-coding"\n'
} > "$_mig2"
bash -n "$_mig2"; assert_eq 0 $? "old-format alias file parses (bash -n)"
grep -q '_cma_compact_cap' "$_mig2"; assert_eq 1 $? "old body lacks _cma_compact_cap guard marker (pre-migration)"
( ALIAS_FILE="$_mig2" cma_ensure_alias_file ) >/dev/null 2>&1
mig2_prov="$(grep -c '^cma_run_provider()' "$_mig2")"
mig2_alias="$(grep -c '^alias kimi-for-coding=' "$_mig2")"
mig2_cap="$(grep -c 'local _cma_compact_cap=' <<<"$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$_mig2")")"
assert_eq 1 "$mig2_prov"  "exactly one cma_run_provider() after migration"
assert_eq 1 "$mig2_alias" "kimi-for-coding alias preserved through migration"
assert_eq 1 "$mig2_cap"   "regenerated cma_run_provider restores the _cma_compact_cap guard"
rm -f "$_mig2"

it "migration regenerates an outdated cma_run_provider lacking the Kimi markers (v1.15.0)"
# The v1.15.0 features (family proxy discovery `_family_id` + Kimi OAuth
# launch-time token freshness 'kimi-code/credentials/...') MUST trigger the
# same self-heal migration — otherwise hosts upgrading from v1.14.0 keep a
# wrapper that can neither route kimi-* through kimi_proxy nor refresh the
# ~15-minute OAuth token (live-confirmed: stale wrapper => proxy never
# started => k3 400s every tool call; stale snapshot => 401 at launch).
_mig3="$ALIAS_FILE.migtest3"
cat > "$_mig3" <<'OLD'
export CLAUDE_BIN="/usr/bin/true"

cma_run_provider() {
  # claude-sync-state set -a +u claude-session apply-color _cma_compact_cap _cma_proxy_dir
  # command -v cma_log _cma_force >| "$tmp" unset ANTHROPIC_BASE_URL
  # ! git rev-parse --show-toplevel >/dev/null 2>&1
  # command -v "${CLAUDE_BIN:-}"
  :
}

alias kimi-for-coding="cma_run_provider kimi-for-coding"
OLD
bash -n "$_mig3"; assert_eq 0 $? "old-format alias file parses (bash -n)"
grep -q 'has-transform' "$_mig3"; assert_eq 1 $? "old body lacks proxy-discovery marker (pre-migration)"
grep -q 'kimi-code/credentials' "$_mig3"; assert_eq 1 $? "old body lacks OAuth freshness marker (pre-migration)"
( ALIAS_FILE="$_mig3" cma_ensure_alias_file ) >/dev/null 2>&1
mig3_body="$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$_mig3")"
mig3_alias="$(grep -c '^alias kimi-for-coding=' "$_mig3")"
# Use a here-string, not `printf | grep -q`: grep -q exits on first match and
# closes the pipe while printf is still writing the ~400-line body, so printf
# dies with SIGPIPE and the PIPELINE's status is 141 — not grep's 0. That made
# this assertion fail even though the marker was present (the sibling
# has-transform check passed only because its match happens late enough that
# printf finishes first). A here-string has no pipe and no SIGPIPE race.
# (Proxy discovery migrated to the Go cma-proxy 2026-07-22: `_family_id` shell
# discovery -> `cma-proxy --has-transform <id>`, which resolves the family key.)
grep -qF 'has-transform' <<<"$mig3_body"; assert_eq 0 $? "regenerated body carries cma-proxy discovery"
grep -qF 'kimi-code/credentials/kimi-code.json' <<<"$mig3_body"; assert_eq 0 $? "regenerated body carries OAuth token freshness"
assert_eq 1 "$mig3_alias" "kimi-for-coding alias preserved through migration"
rm -f "$_mig3"

# --- set -e/pipefail guard: a provider whose alias line is absent ------------
# claude-providers.sh runs `set -euo pipefail`. cmd_list/cmd_remove resolve the
# alias name via `grep ... | sed | head -1`; under pipefail a no-match grep
# (exit 1) aborted the subshell/function. A provider .env can legitimately have
# no alias line (manual edit, partial setup). These EXECUTE the real script.
it "claude-providers list-all does NOT abort on a provider with no alias line"
# Exercised via list-all (not list): ghost has no status entry -> 'pending', so
# verified-only `list` would filter it out BEFORE the alias-less grep runs.
# list-all shows every status, so ghost passes the filter and the alias-less
# grep|sed|head pipeline is actually exercised (the pipefail-abort regression).
mkdir -p "$PDIR"
cat > "$PDIR/ghost.env" <<'GHOST'
CMA_PROVIDER_ID='ghost'
CMA_PROVIDER_TRANSPORT='native'
CMA_PROVIDER_BASE_URL='https://ghost.example/anthropic'
CMA_PROVIDER_MODEL='ghost-model'
CMA_PROVIDER_FAST_MODEL='ghost-fast'
CMA_PROVIDER_KEYVAR='GHOST_API_KEY'
GHOST
list_out="$(bash "$PROVIDERS_SH" list-all 2>/dev/null)"; list_rc=$?
assert_eq 0 "$list_rc" "list-all exits 0 (no abort on the alias-less provider)"
grep -q 'ghost' <<<"$list_out"; assert_eq 0 $? "list-all still shows the alias-less provider"

it "claude-providers remove does NOT abort on a provider with no alias line"
bash "$PROVIDERS_SH" remove ghost >/dev/null 2>&1; rm_rc=$?
assert_eq 0 "$rm_rc" "remove exits 0 (no abort before deleting the env)"
still=0; [[ -f "$PDIR/ghost.env" ]] && still=1
assert_eq 0 "$still" "remove actually deleted the provider env file"

# --- 'null' normalization: a missing JSON field (jq -r -> "null") must never ---
# land in the env file as a bogus value. base/fast/context/max were normalized
# but model+transport were missed -> CMA_PROVIDER_MODEL='null' broke launches.
it "cma_provider_write_env: a 'null' model/transport/base is normalized to empty"
cma_provider_write_env "nulltest" "NT_KEY" "null" "null" "null" "null" "$SANDBOX_HOME/.cdir" "null" "null" >/dev/null 2>&1
_nf="$(cma_providers_dir)/nulltest.env"
grep -q "^CMA_PROVIDER_MODEL=''" "$_nf";     assert_eq 0 $? "null strong_model normalized to empty (not 'null')"
grep -q "^CMA_PROVIDER_TRANSPORT=''" "$_nf"; assert_eq 0 $? "null transport normalized to empty"
grep -q "^CMA_PROVIDER_BASE_URL=''" "$_nf";  assert_eq 0 $? "null base_url normalized to empty"
_hasnull=0; grep -qE "CMA_PROVIDER_(MODEL|TRANSPORT|BASE_URL|FAST_MODEL|CONTEXT_LIMIT|MAX_OUTPUT)='null'" "$_nf" && _hasnull=1
assert_eq 0 "$_hasnull" "no provider field contains the literal string 'null'"

# noclobber regression: cma_run_provider is a FUNCTION that runs in the user's
# interactive shell, which may have `set -o noclobber`. A bare `> "$tmp"` onto the
# just-created mktemp file fails there ("cannot overwrite existing file"), silently
# dropping the router-config update so EVERY router-transport provider breaks. The
# emitted function must use the force-clobber operator `>|`.
it "cma_run_provider router-config write is noclobber-safe (>| not bare >)"
_prov_body="$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
# shellcheck disable=SC2016  # literal $tmp intended: we grep the EMITTED code, not expand it
grep -q '>| "\$tmp"' <<<"$_prov_body"; assert_eq 0 $? "router jq write uses force-clobber >|"
_bare=0
# shellcheck disable=SC2016
grep -qE '> "\$tmp"' <<<"$_prov_body" && _bare=1
assert_eq 0 "$_bare" "no bare '> \$tmp' write remains in cma_run_provider"

it "noclobber proof: bare > is blocked on an existing mktemp file, >| succeeds"
_nc_t="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
_blocked=0; ( set -o noclobber; echo x > "$_nc_t" ) 2>/dev/null || _blocked=1
_forced=0;  ( set -o noclobber; echo y >| "$_nc_t" ) 2>/dev/null && _forced=1
assert_eq 1 "$_blocked" "bare '>' blocked by noclobber"
assert_eq 1 "$_forced"  "'>|' force-clobber works under noclobber"
rm -f "$_nc_t"

# ---------------------------------------------------------------------------
# Section 6 — verification status cache (single source of truth for the list
# family + the launch-time activation gate). Non-secret metadata only.
# ---------------------------------------------------------------------------
# Start from a clean cache: earlier sections (Section 3's `sync`) share this
# sandbox $HOME and already populated status.json, so reset for deterministic
# absolute-count assertions (§11.4.50).
rm -f "$(cma_status_cache)"

it "unknown provider id reads as 'pending'"
assert_eq "pending" "$(cma_status_read no_such_provider)" "unknown id -> pending"

it "cma_status_write persists a status readable by cma_status_read"
cma_status_write st_deepseek verified deepseek-chat ""
assert_eq "verified" "$(cma_status_read st_deepseek)" "wrote + read verified"
assert_jq "$(cma_status_cache)" '.st_deepseek.model' "deepseek-chat" "model persisted"
assert_jq "$(cma_status_cache)" '.st_deepseek.failing_layer' "" "verified has empty failing_layer"

it "cma_status_write upserts (overwrites same id, no duplicate record)"
cma_status_write st_deepseek unverified deepseek-chat semantic
assert_eq "unverified" "$(cma_status_read st_deepseek)" "upsert changed status"
assert_jq "$(cma_status_cache)" '.st_deepseek.failing_layer' "semantic" "failing_layer recorded"
assert_jq "$(cma_status_cache)" '. | length' "1" "still exactly one record (upsert, not append)"

it "cma_status_all lists every record as tab-separated rows"
cma_status_write st_groq failed llama-3 existence
assert_eq "2" "$(cma_status_all | wc -l | tr -d ' ')" "two records listed"
_all="$(cma_status_all)"
grep -qF "st_groq	failed	llama-3	" <<<"$_all"; assert_eq 0 $? "groq row present with fields"

it "no secret/key material is ever written into the status cache"
assert_file_not_contains "$(cma_status_cache)" "sk-" "no bearer-token prefix in cache"
assert_file_not_contains "$(cma_status_cache)" "Bearer" "no Authorization header in cache"

# Clean the status cache so later sections start fresh.
rm -f "$(cma_status_cache)"

# ---------------------------------------------------------------------------
# Section 7 — launch-time activation gate in cma_run_provider. Only a
# 'verified' alias brings up Claude Code; others refuse with an actionable
# message. --force overrides. Uses acme (native transport, from Section 3) +
# CLAUDE_BIN=/usr/bin/true so a permitted launch exits 0 without a real claude.
# ---------------------------------------------------------------------------

it "gate subshells load cma_run_provider from the sandbox alias file, not the host"
# BASH_ENV=~/.bashrc means the HOST's cma_run_provider is ALREADY defined in this
# shell. Every `( source "$ALIAS_FILE"; cma_run_provider … )` below would still
# "pass" if that source silently failed — it would just grade live host code.
# --source performs the same source in a throwaway subshell (mirroring those call
# sites) while landing the pass/fail in THIS shell's counters, so `summary` sees it.
assert_fn_from --source "$ALIAS_FILE" cma_run_provider "gate subshell wrapper provenance"

it "activation gate: unverified alias refuses to launch (rc 3, actionable message)"
cma_status_write acme unverified acme-big semantic
_g_out="$( ( source "$ALIAS_FILE"; cma_run_provider acme ) 2>&1 )"; _g_rc=$?
assert_eq 3 "$_g_rc" "unverified alias returns 3 (gate refused)"
grep -q 'not launching' <<<"$_g_out"; assert_eq 0 $? "gate prints 'not launching'"
grep -q 'claude-providers sync' <<<"$_g_out"; assert_eq 0 $? "gate suggests re-verify via sync"

it "activation gate: failed alias also refuses"
cma_status_write acme failed acme-big existence
( source "$ALIAS_FILE"; cma_run_provider acme ) >/dev/null 2>&1; assert_eq 3 $? "failed alias returns 3"

it "activation gate: pending (no cache entry) refuses"
rm -f "$(cma_status_cache)"
( source "$ALIAS_FILE"; cma_run_provider acme ) >/dev/null 2>&1; assert_eq 3 $? "pending alias returns 3"

it "activation gate: verified alias launches (CLAUDE_BIN=/usr/bin/true -> rc 0)"
cma_status_write acme verified acme-big ""
( source "$ALIAS_FILE"; cma_run_provider acme ) >/dev/null 2>&1; assert_eq 0 $? "verified alias launches"

it "activation gate: --force overrides a non-verified status (both arg positions)"
cma_status_write acme failed acme-big existence
( source "$ALIAS_FILE"; cma_run_provider acme --force ) >/dev/null 2>&1; assert_eq 0 $? "--force after id launches"
( source "$ALIAS_FILE"; cma_run_provider --force acme ) >/dev/null 2>&1; assert_eq 0 $? "--force before id launches"

it "activation gate is present in the emitted cma_run_provider body"
_gate_body="$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
# herestring (<<<), NOT `printf … | grep -q`: SIGPIPE-safe on the larger body
# (see the auto-compact-window assertions above for the pipefail/SIGPIPE detail).
grep -qF '_cma_force' <<<"$_gate_body"; assert_eq 0 $? "emitted body carries the --force/gate marker"

rm -f "$(cma_status_cache)"

# ---------------------------------------------------------------------------
# Section 8 — 'list --refresh-aliases --quiet': rebuild alias lines from the
# cached env files with NO network (the session hook's fast path). Requires the
# env file to persist CMA_PROVIDER_ALIAS (written by cma_provider_write_env).
# ---------------------------------------------------------------------------

it "env files persist CMA_PROVIDER_ALIAS (the no-network refresh source)"
assert_file_contains "$PDIR/acme.env" "CMA_PROVIDER_ALIAS='acme'" "acme env carries its alias name"

it "--refresh-aliases rebuilds a removed alias line from cache (no network)"
cma_remove_alias acme
grep -q '^alias acme="cma_run_provider acme"' "$ALIAS_FILE" && _pre=1 || _pre=0
assert_eq 0 "$_pre" "acme alias line removed (precondition)"
bash "$PROVIDERS_SH" list --refresh-aliases --quiet >/dev/null 2>&1
grep -q '^alias acme="cma_run_provider acme"' "$ALIAS_FILE"; assert_eq 0 $? "acme alias restored by refresh"

it "--refresh-aliases is idempotent"
# Byte-idempotent: a second refresh must yield an identical file. (Regression
# guard for the write_alias migration-churn bug — write_alias used to re-run the
# full cma_ensure_alias_file self-heal on every alias line, non-deterministically
# repositioning the cma_run_provider function relative to the alias lines, so this
# occasionally differed. Fixed by only bootstrapping the alias file when absent.)
_rb="$(cat "$ALIAS_FILE")"
bash "$PROVIDERS_SH" list --refresh-aliases --quiet >/dev/null 2>&1
assert_eq "$_rb" "$(cat "$ALIAS_FILE")" "second refresh yields an identical alias file"

it "--quiet suppresses the refresh log line (non-quiet emits it)"
_noisy="$(bash "$PROVIDERS_SH" list --refresh-aliases 2>&1 >/dev/null)"
grep -q refreshed <<<"$_noisy"; assert_eq 0 $? "non-quiet refresh logs 'refreshed'"
_quiet="$(bash "$PROVIDERS_SH" list --refresh-aliases --quiet 2>&1 >/dev/null)"
grep -q refreshed <<<"$_quiet" && _q=1 || _q=0
assert_eq 0 "$_q" "quiet refresh suppresses the log"

# ---------------------------------------------------------------------------
# Section 9 — install-time session-sync hook (cma_install_session_hook). The
# hook refreshes aliases from cache on every shell (no network) + kicks a
# detached full sync only when status.json is stale (TTL). Marker-bracketed,
# idempotent. status.json is absent here (Section 7 removed it), so no
# background sync spawns — deterministic.
# ---------------------------------------------------------------------------

it "cma_install_session_hook installs a marker-bracketed refresh block"
cma_install_session_hook
assert_eq "1" "$(grep -c 'cma-providers-session-refresh BEGIN' "$ALIAS_FILE")" "one BEGIN marker"
assert_eq "1" "$(grep -c 'cma-providers-session-refresh END' "$ALIAS_FILE")" "one END marker"
assert_file_contains "$ALIAS_FILE" "list --quiet --refresh-aliases" "hook uses the no-network refresh path"
assert_file_contains "$ALIAS_FILE" "CMA_PROVIDERS_SYNC_TTL" "hook honours the TTL knob"

it "cma_install_session_hook is idempotent (re-install replaces, no duplicate)"
cma_install_session_hook
assert_eq "1" "$(grep -c 'cma-providers-session-refresh BEGIN' "$ALIAS_FILE")" "still one BEGIN after re-install"
assert_eq "1" "$(grep -c 'cma_providers_session_refresh()' "$ALIAS_FILE")" "still one function definition"

it "sourcing the alias file fires the hook without error and with no network"
( source "$ALIAS_FILE" ) >/dev/null 2>&1
assert_eq 0 $? "sourcing (hook fires) succeeds offline"

# ---------------------------------------------------------------------------
# Section — semantic-code-visibility driver (claude-semantic-visibility.sh)
# Hermetic: a fake `go` on PATH "builds" a stub binary that echoes its argv,
# proving the driver caches + forwards flags without a real toolchain/network.
# ---------------------------------------------------------------------------
SEMDRV="$SCRIPTS_DIR/claude-semantic-visibility.sh"
_sem_bin="$HOME/.local-cache/semantic-code-visibility"
mkdir -p "$HOME/fakebin"
# Fake `go`: `go build -o <out> ./cmd/...` writes a stub that prints its args.
cat > "$HOME/fakebin/go" <<'FAKEGO'
#!/usr/bin/env bash
if [[ "$1" == build ]]; then
  out=""; while (($#)); do [[ "$1" == -o ]] && { out="$2"; shift 2; continue; }; shift; done
  printf '#!/usr/bin/env bash\nprintf "SCV-STUB %%s\\n" "$*"\nexit 0\n' > "$out"; chmod +x "$out"; exit 0
fi
exit 0
FAKEGO
chmod +x "$HOME/fakebin/go"

it "claude-semantic-visibility.sh builds (cached) + forwards flags to the binary"
rm -f "$_sem_bin"
out="$( PATH="$HOME/fakebin:$PATH" LLMSVERIFIER_DIR="$SCRIPTS_DIR/../submodules/LLMsVerifier" \
        LV_SEMANTIC_BIN="$_sem_bin" bash "$SEMDRV" --model m --sentinel Z 2>/dev/null )"
grep -q 'SCV-STUB' <<<"$out"; assert_eq 0 $? "driver execs the built binary"
grep -q -- '--sentinel Z' <<<"$out"; assert_eq 0 $? "driver forwards flags verbatim"
assert_file "$_sem_bin" "binary was cached under .local-cache"

it "claude-semantic-visibility.sh --help/-h ALWAYS works, even with no built binary (bug fix)"
# Regression guard: the OLD code did `exec "$BIN" -h` unconditionally, so with
# no cached binary (fresh checkout, no `go` toolchain yet) `exec` to a missing
# path kills the non-interactive script with exit 127 and empty stdout — the
# `||` fallback never runs because `exec` replaces the process on success and
# never returns to bash on failure either (it just fails the whole script).
out="$( LV_SEMANTIC_BIN=/nonexistent/path bash "$SEMDRV" --help 2>&1 )"; rc=$?
assert_eq 0 "$rc" "--help exits 0 with no built binary"
grep -qi 'usage' <<<"$out"; assert_eq 0 $? "--help prints a usage line with no built binary"
out="$( LV_SEMANTIC_BIN=/nonexistent/path bash "$SEMDRV" -h 2>&1 )"; rc=$?
assert_eq 0 "$rc" "-h exits 0 with no built binary"
grep -qi 'usage' <<<"$out"; assert_eq 0 $? "-h prints a usage line with no built binary"

# ---------------------------------------------------------------------------
# Section — providers-semantic.sh (layer 3 adapter). A stub driver stands in
# for the Go binary: it echoes a canned verdict JSON + exits with a chosen code,
# so the adapter's stdout/exit mapping is asserted with no go/network/keys.
# ---------------------------------------------------------------------------
SEMSH="$SCRIPTS_DIR/providers-semantic.sh"
_mk_stub_driver() {  # $1 = exit code, $2 = overall_pass json bool
  cat > "$HOME/fakebin/scv-stub" <<EOF
#!/usr/bin/env bash
printf '{"round1_sentinel":{"pass":$2,"observed":"ZETA-9-ORANGE-7f3a"},"round2_judge":{"pass":$2,"score":3,"skipped":false},"overall_pass":$2}\n'
exit $1
EOF
  chmod +x "$HOME/fakebin/scv-stub"
}

it "providers-semantic maps overall_pass=true -> 'verified' exit 0"
_mk_stub_driver 0 true
out="$( CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" CMA_PROBE_KEY=x CMA_JUDGE_KEY=y \
        bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
        --base-url https://api.deepseek.com 2>/dev/null )"; rc=$?
assert_eq "verified" "$out" "pass -> verified"
assert_eq 0 "$rc" "pass -> exit 0"

# The adapter SOURCES judge.env/template (which sets CMA_JUDGE_BASE_URL), so control
# the judge config via a CMA_JUDGE_ENV file, not an env var the template would clobber.
it "providers-semantic WARNs when judge endpoint == model-under-test endpoint (v1.12.1 1A independence guard)"
_mk_stub_driver 0 true
printf 'CMA_JUDGE_BASE_URL="https://api.deepseek.com"\nCMA_JUDGE_MODEL="deepseek-chat"\nCMA_JUDGE_KEYVAR="DEEPSEEK_API_KEY"\n' > "$HOME/judge-same.env"
err="$( CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" CMA_JUDGE_ENV="$HOME/judge-same.env" CMA_PROBE_KEY=x CMA_JUDGE_KEY=y \
        bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
        --base-url https://api.deepseek.com 2>&1 >/dev/null )"
grep -qi 'same-family judge is NOT independent' <<<"$err"; assert_eq 0 $? "same-endpoint judge -> independence WARNING on stderr"

it "providers-semantic does NOT warn when judge endpoint differs (independent judge)"
_mk_stub_driver 0 true
printf 'CMA_JUDGE_BASE_URL="https://api.groq.com/openai"\nCMA_JUDGE_MODEL="llama-3.1-8b-instant"\nCMA_JUDGE_KEYVAR="GROQ_API_KEY"\n' > "$HOME/judge-diff.env"
err2="$( CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" CMA_JUDGE_ENV="$HOME/judge-diff.env" CMA_PROBE_KEY=x CMA_JUDGE_KEY=y \
         bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
         --base-url https://api.deepseek.com 2>&1 >/dev/null )"
grep -qi 'same-family judge is NOT independent' <<<"$err2" && _w=1 || _w=0
assert_eq 0 "$_w" "different-endpoint judge -> NO independence warning"

it "providers-semantic maps Go exit 3 (transport/infra) -> 'skip', not 'unverified' (v1.12.1 I-1 no-downgrade)"
_mk_stub_driver 3 false
out3="$( CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" CMA_JUDGE_ENV="$HOME/judge-diff.env" CMA_PROBE_KEY=x CMA_JUDGE_KEY=y \
         bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
         --base-url https://api.deepseek.com 2>/dev/null )"; rc3=$?
assert_eq "skip" "$out3" "Go exit 3 (infra) -> skip (a transient judge/model error must not demote)"
assert_eq 2 "$rc3" "skip -> adapter exit 2"

it "providers-semantic maps overall_pass=false -> 'unverified' exit 1"
_mk_stub_driver 1 false
out="$( CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" CMA_PROBE_KEY=x CMA_JUDGE_KEY=y \
        bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
        --base-url https://api.deepseek.com 2>/dev/null )"; rc=$?
assert_eq "unverified" "$out" "fail -> unverified"
assert_eq 1 "$rc" "fail -> exit 1"

it "providers-semantic SKIPs (exit 2 -> 'skip') when the model key is absent — no downgrade"
# Use a key-var name no real provider would ever export (NOT DEEPSEEK_API_KEY —
# a host actually configured for this toolkit's own purpose, i.e. real provider
# keys exported in the operator's shell, would leak a real DEEPSEEK_API_KEY
# into this process's env and falsely defeat the "key absent" precondition).
unset CMA_TEST_NO_SUCH_KEY_VAR
out="$( CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" \
        bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var CMA_TEST_NO_SUCH_KEY_VAR \
        --base-url https://api.deepseek.com 2>/dev/null )"; rc=$?
assert_eq "skip" "$out" "no key -> skip"
assert_eq 2 "$rc" "skip -> exit 2"

it "providers-semantic reads fixture/rubric from providers/ (CONST-051 boundary), not the submodule"
# The rendered judge-prompt must contain rubric-derived criteria, proving the
# toolkit owns the judge input and the submodule binary only receives CLI args.
_mk_stub_driver 0 true
CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" CMA_PROBE_KEY=x CMA_JUDGE_KEY=y CMA_SEMANTIC_DEBUG=1 \
  bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
  --base-url https://api.deepseek.com >/dev/null 2>"$HOME/sem.err"
grep -q 'resolve_alias' "$HOME/sem.err" ; assert_eq 0 $? "judge-prompt carries rubric fixture-specific detail"

# providers-semantic.sh computes its own REPO_ROOT from BASH_SOURCE (it is not
# invoked through a symlink here, and there is no env override), so the driver
# it spawns writes evidence under the real repo's .local-cache — same place
# claude-semantic-visibility.sh's own driver test caches its stub binary from
# a *different* override; this one is not overridable, so we compute it the
# same way the script does and read the file back from there. .local-cache/
# is gitignored, so this never touches tracked state.
_sem_repo_root="$(cd "$SCRIPTS_DIR/.." && pwd)"
_sem_evidence="$_sem_repo_root/.local-cache/semantic-last.json"

it "providers-semantic writes the driver's JSON evidence to .local-cache/semantic-last.json (bug fix)"
# Regression guard: the OLD code redirected the driver's `--format json`
# stdout straight to /dev/null (only stderr was captured to semantic-last.err),
# so the round1_sentinel/round2_judge/overall_pass evidence Task 5's proof
# capture needs was silently discarded on every run.
rm -f "$_sem_evidence"
_mk_stub_driver 0 true
CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" CMA_PROBE_KEY=x CMA_JUDGE_KEY=y \
  bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
  --base-url https://api.deepseek.com >/dev/null 2>/dev/null
assert_file "$_sem_evidence" "semantic-last.json evidence file written"
grep -q 'overall_pass' "$_sem_evidence" 2>/dev/null; assert_eq 0 $? "evidence file carries the driver's overall_pass"
grep -q 'round1_sentinel' "$_sem_evidence" 2>/dev/null; assert_eq 0 $? "evidence file carries the driver's round1_sentinel"

it "providers-semantic normalizes a judge base URL ending in /v1 before passing --judge-base-url (bug fix)"
# Regression guard: the adapter normalizes the MODEL-under-test base (strips
# trailing /, /chat/completions, /anthropic, /v1) because the Go command
# appends /v1/chat/completions itself, but the OLD code skipped that same
# normalization for the JUDGE base — a judge.env ending in /v1 (a very natural
# way to write one) would double up to /v1/v1/chat/completions -> 404, which a
# live run hit exactly. Point CMA_JUDGE_ENV at a throwaway file so the real
# providers/judge.env.template (which has no /v1 suffix) can't mask the bug.
_judge_env_v1="$(mktemp "${TMPDIR:-/tmp}/cma-judge-env.XXXXXX")"
cat > "$_judge_env_v1" <<'EOF'
CMA_JUDGE_BASE_URL="https://api.example.com/v1"
CMA_JUDGE_MODEL="judge-model"
CMA_JUDGE_KEYVAR="CMA_TEST_NO_SUCH_JUDGE_KEYVAR"
CMA_JUDGE_THRESHOLD="2"
EOF
_argv_file="$HOME/scv-argv.txt"
rm -f "$_argv_file"
cat > "$HOME/fakebin/scv-argv-recorder" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$_argv_file"
echo '{"overall_pass":true}'
exit 0
EOF
chmod +x "$HOME/fakebin/scv-argv-recorder"
CMA_JUDGE_ENV="$_judge_env_v1" CMA_JUDGE_KEY=y CMA_PROBE_KEY=x \
  CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-argv-recorder" \
  bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
  --base-url https://api.deepseek.com >/dev/null 2>/dev/null
assert_file "$_argv_file" "argv-recorder stub wrote its received args"
_judge_base_val="$(awk '$0=="--judge-base-url"{getline; print; exit}' "$_argv_file" 2>/dev/null)"
assert_eq "https://api.example.com" "$_judge_base_val" "judge base url has /v1 stripped, no double /v1/v1"
rm -f "$_judge_env_v1"

# ---------------------------------------------------------------------------
# Section — cmd_sync layer-3 wiring. Stub existence -> 'verified' and semantic
# -> 'unverified' and assert the persisted status is unverified/semantic.
# ---------------------------------------------------------------------------
cat > "$HOME/fakebin/verify-ok" <<'EOF'
#!/usr/bin/env bash
echo verified
EOF
cat > "$HOME/fakebin/semantic-fail" <<'EOF'
#!/usr/bin/env bash
echo unverified
exit 1
EOF
chmod +x "$HOME/fakebin/verify-ok" "$HOME/fakebin/semantic-fail"

it "cmd_sync: existence=verified + semantic=unverified -> status unverified/semantic"
# (uses the Section-3 catalog + key-aliases already seeded above; a key must be
# set so cmd_sync attempts verification. --no-verify is NOT passed.)
CMA_PROVIDERS_VERIFY="$HOME/fakebin/verify-ok" \
CMA_PROVIDERS_SEMANTIC="$HOME/fakebin/semantic-fail" \
BETA_API_KEY=sk-test \
  bash "$PROVIDERS_SH" sync --keys-file <(echo 'export BETA_API_KEY=sk-test') >/dev/null 2>&1
assert_eq "unverified" "$(cma_status_read beta)" "semantic failure demotes to unverified"
assert_jq "$(cma_status_cache)" '.beta.failing_layer' "semantic" "failing layer = semantic"

it "cmd_sync: existence=verified + semantic=skip -> stays verified (honest SKIP, no downgrade)"
cat > "$HOME/fakebin/semantic-skip" <<'EOF'
#!/usr/bin/env bash
echo skip
exit 2
EOF
chmod +x "$HOME/fakebin/semantic-skip"
CMA_PROVIDERS_VERIFY="$HOME/fakebin/verify-ok" \
CMA_PROVIDERS_SEMANTIC="$HOME/fakebin/semantic-skip" \
BETA_API_KEY=sk-test \
  bash "$PROVIDERS_SH" sync --keys-file <(echo 'export BETA_API_KEY=sk-test') >/dev/null 2>&1
assert_eq "verified" "$(cma_status_read beta)" "semantic skip does not downgrade verified"

it "cmd_sync: existence=unverified (inconclusive) -> failing_layer=existence (NOT semantic), semantic never invoked"
# Regression guard for the Task-2 fix: the OLD buggy code labeled failing_layer
# "semantic" whenever verification did not end in "verified", even when the
# semantic (layer-3) probe was never reached because existence itself was the
# layer that failed. CMA_PROVIDERS_SEMANTIC below drops a marker file if it is
# ever invoked, so an accidental future call into layer-3 from the
# existence-inconclusive path is caught even if the failing_layer text happens
# to still read correctly.
cat > "$HOME/fakebin/verify-unverified" <<'EOF'
#!/usr/bin/env bash
echo unverified
EOF
chmod +x "$HOME/fakebin/verify-unverified"
rm -f "$HOME/sem-marker-fired"
cat > "$HOME/fakebin/semantic-marker" <<EOF
#!/usr/bin/env bash
touch "$HOME/sem-marker-fired"
echo verified
EOF
chmod +x "$HOME/fakebin/semantic-marker"

CMA_PROVIDERS_VERIFY="$HOME/fakebin/verify-unverified" \
CMA_PROVIDERS_SEMANTIC="$HOME/fakebin/semantic-marker" \
BETA_API_KEY=sk-test \
  bash "$PROVIDERS_SH" sync --keys-file <(echo 'export BETA_API_KEY=sk-test') >/dev/null 2>&1
assert_eq "unverified" "$(cma_status_read beta)" "existence-inconclusive -> status unverified"
assert_jq "$(cma_status_cache)" '.beta.failing_layer' "existence" "failing layer = existence, not semantic"
cond=0; [[ -f "$HOME/sem-marker-fired" ]] && cond=1
assert_eq 0 "$cond" "semantic layer not invoked when existence is inconclusive"

# ---------------------------------------------------------------------------
# Section — cmd_verify subcommand (Task 2 review Gap 1). Seeds one provider
# env file directly (no sync needed) and stubs the existence (layer-1) and
# semantic (layer-3) drivers via the same CMA_PROVIDERS_VERIFY /
# CMA_PROVIDERS_SEMANTIC overrides cmd_sync already uses above. --deep
# (layer-4, superpowers TUI) is covered separately in the
# verify_superpowers_tui.sh SKIP-behavior section below (Tier-A only — no
# real claude in the sandbox, so PASS/FAIL classification itself is deferred
# to Task 5's Tier-B live test).
# ---------------------------------------------------------------------------
cma_provider_write_env "gamma" "GAMMA_API_KEY" "router" "https://api.gamma.ai/v1" \
  "gamma-x" "" "$HOME/.claude-prov-gamma" "" "" "gamma"

cat > "$HOME/fakebin/verify-fail" <<'EOF'
#!/usr/bin/env bash
echo failed
EOF
cat > "$HOME/fakebin/semantic-ok" <<'EOF'
#!/usr/bin/env bash
echo verified
EOF
chmod +x "$HOME/fakebin/verify-fail" "$HOME/fakebin/semantic-ok"

it "cmd_verify: existence=verified + semantic=verified -> prints verified, persists verified with empty failing_layer"
out="$(CMA_PROVIDERS_VERIFY="$HOME/fakebin/verify-ok" CMA_PROVIDERS_SEMANTIC="$HOME/fakebin/semantic-ok" \
       bash "$PROVIDERS_SH" verify gamma 2>/dev/null)"
assert_eq "verified" "$out" "cmd_verify stdout: verified"
assert_eq "verified" "$(cma_status_read gamma)" "cmd_verify persists status verified"
assert_jq "$(cma_status_cache)" '.gamma.failing_layer' "" "cmd_verify verified -> failing_layer empty"

it "cmd_verify: existence probe returns failed -> prints failed, persists failed/existence"
out="$(CMA_PROVIDERS_VERIFY="$HOME/fakebin/verify-fail" CMA_PROVIDERS_SEMANTIC="$HOME/fakebin/semantic-ok" \
       bash "$PROVIDERS_SH" verify gamma 2>/dev/null)"
assert_eq "failed" "$out" "cmd_verify stdout: failed"
assert_eq "failed" "$(cma_status_read gamma)" "cmd_verify persists status failed"
assert_jq "$(cma_status_cache)" '.gamma.failing_layer' "existence" "cmd_verify failed -> failing_layer existence"

it "cmd_verify: existence=verified + semantic=unverified -> prints unverified, persists unverified/semantic"
out="$(CMA_PROVIDERS_VERIFY="$HOME/fakebin/verify-ok" CMA_PROVIDERS_SEMANTIC="$HOME/fakebin/semantic-fail" \
       bash "$PROVIDERS_SH" verify gamma 2>/dev/null)"
assert_eq "unverified" "$out" "cmd_verify stdout: unverified"
assert_eq "unverified" "$(cma_status_read gamma)" "cmd_verify persists status unverified"
assert_jq "$(cma_status_cache)" '.gamma.failing_layer' "semantic" "cmd_verify semantic-fail -> failing_layer semantic"

it "cmd_verify: unknown provider id dies with non-zero exit + message"
out="$(bash "$PROVIDERS_SH" verify no-such-provider-xyz 2>&1)"; rc=$?
assert_eq 1 "$rc" "cmd_verify unknown id exits 1"
grep -q "unknown provider" <<<"$out"; assert_eq 0 $? "cmd_verify unknown id emits a die message"

# ---------------------------------------------------------------------------
# Section — verify_superpowers_tui.sh SKIP behavior (Tier-A: no real claude).
# With CLAUDE_BIN=/usr/bin/true (the sandbox default) the layer-4 test MUST
# SKIP-with-reason and exit 0 — never a faked PASS, never a hard FAIL.
#
# All invocations below pin PROOF_DIR into the sandbox. verify_superpowers_tui.sh
# computes its default --out from its OWN on-disk location
# (${PROOF_DIR:-$TESTS_ROOT/tests/proof}/...), which resolves to the REAL
# scripts/tests/proof/ in the repo tree, not the sandboxed $HOME, unless
# PROOF_DIR is overridden. Without this, every Tier-A run leaves untracked
# providers-*-superpowers.txt files outside the sandbox (independent review
# Finding 3; reproduced — see providers-deepseek-superpowers.txt and
# providers-no_such_alias-superpowers.txt that were untracked in `git status`
# before this fix).
# ---------------------------------------------------------------------------
STUI="$SCRIPTS_DIR/verify_superpowers_tui.sh"
STUI_PROOF="$HOME/proof"

it "verify_superpowers_tui SCRUB list mirrors verify_claude_live.sh exactly (session-continuity vars included)"
_stui_scrub="$(grep -oE -- '-u [A-Z_]+' "$STUI" | awk '{print $2}' | sort -u)"
_live_scrub="$(grep -oE -- '-u [A-Z_]+' "$TESTS_DIR/verify_claude_live.sh" | awk '{print $2}' | sort -u)"
assert_eq "$_live_scrub" "$_stui_scrub" "SCRUB var set identical to verify_claude_live.sh (incl. CLAUDE_CODE_CHILD_SESSION/SESSION_ID govern resume safety)"

it "verify_superpowers_tui SKIPs (exit 0 + reason) when there is no real claude binary"
out="$( CLAUDE_BIN=/usr/bin/true PROOF_DIR="$STUI_PROOF" bash "$STUI" --alias deepseek --timeout 5 2>&1 )"; rc=$?
assert_eq 0 "$rc" "SKIP is a non-failure (exit 0)"
grep -q 'SKIP:' <<<"$out"; assert_eq 0 $? "prints an honest SKIP reason"
grep -qiv 'PASS' <<<"$out"; assert_eq 0 $? "never claims PASS when skipping"

# A stub whose basename matches claude* (unlike the previous `cat`/`true`) so
# the launch passes the "no real claude binary" precondition
# (verify_superpowers_tui.sh: [[ ... && "$(basename "$CB")" == claude* ]]) and
# genuinely reaches the alias-not-installed check further down. Review
# Finding 2: the old test used CLAUDE_BIN="$(command -v cat)", which SKIPped
# at the EARLIER "no real claude binary" precondition — the
# alias-not-installed branch had zero real coverage even though its
# `grep -q 'SKIP:'` assertion passed.
mkdir -p "$HOME/fakebin"
cat > "$HOME/fakebin/claude-stub" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$HOME/fakebin/claude-stub"

it "verify_superpowers_tui SKIPs when the named alias is not installed (genuinely reaches that branch)"
[[ -f "$ALIAS_FILE" ]]; assert_eq 0 $? "precondition: sandbox alias file exists (so the alias-file check doesn't SKIP first)"
[[ ! -f "$PDIR/no_such_alias.env" ]]; assert_eq 0 $? "precondition: no_such_alias has no provider env file"
out="$( CLAUDE_BIN="$HOME/fakebin/claude-stub" PROOF_DIR="$STUI_PROOF" bash "$STUI" --alias no_such_alias --timeout 5 2>&1 )"; rc=$?
assert_eq 0 "$rc" "unknown alias -> SKIP exit 0"
grep -q "SKIP: alias 'no_such_alias' not installed" <<<"$out"; assert_eq 0 $? "SKIP reason names the alias-not-installed branch specifically (not an earlier precondition)"

# ---------------------------------------------------------------------------
# Section — xAI existence via the generic chat probe (CORRECTED: xAI exposes
# an OpenAI-shaped API with alias ids like "latest"). No docs-scrape
# special-case may exist (Task 4, §11.4.124 — see
# .superpowers/sdd/task-4-recon.md: the generic probe path already covers xAI;
# no model-id-membership check exists anywhere to add alias tolerance to).
# ---------------------------------------------------------------------------

it "no xAI docs-scrape / hardcoded-model special-case is present in the sources"
! grep -rniE 'docs\.x\.ai|scrape|xai-models\.json' "$SCRIPTS_DIR"/*.sh "$SCRIPTS_DIR"/*.py 2>/dev/null
assert_eq 0 $? "xAI is handled by the generic probe path, not a scrape branch"

it "providers-verify treats xAI like any OpenAI-shaped provider (sentinel + tool call -> verified)"
# Fake the xAI chat endpoint on loopback: answer the VERIFY_OK sentinel probe
# and then the tool-calling probe with a tool_calls payload — exactly what the
# generic strategy-2 probes expect from any OpenAI-shaped provider.
python3 - "$HOME/xai.port" <<'PY' &
import http.server, socketserver, sys, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers()
        if '"tools"' in body:
            self.wfile.write(json.dumps({"choices":[{"message":{"tool_calls":[{"id":"c1","type":"function","function":{"name":"get_weather","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}).encode())
        else:
            self.wfile.write(json.dumps({"choices":[{"message":{"content":"VERIFY_OK"}}]}).encode())
    def log_message(self,*a): pass
with socketserver.TCPServer(("127.0.0.1",0),H) as s:
    open(sys.argv[1],"w").write(str(s.server_address[1]))
    s.handle_request(); s.handle_request()  # chat probe + tool probe
PY
# wait for the port file, then probe
for _ in $(seq 1 50); do [[ -s "$HOME/xai.port" ]] && break; sleep 0.05; done
port="$(cat "$HOME/xai.port" 2>/dev/null)"
XAI_API_KEY=sk-test out="$( XAI_API_KEY=sk-test bash "$SCRIPTS_DIR/providers-verify.sh" \
    --provider xai --model grok-4 --key-var XAI_API_KEY \
    --base-url "http://127.0.0.1:${port}/v1" 2>/dev/null )"
assert_eq "verified" "$out" "xAI chat+tools probes pass -> verified (no special-case)"

it "providers-verify names a context-overflow 400 as context-inadequate (existence layer), distinct from auth/billing"
# A backend so small the ~512-token sentinel probe itself overflows returns a 400
# whose body says the request exceeds the available context size. The verdict is
# `failed` either way (the alias cannot serve Claude Code as launched, and the
# live gate leaves it uncounted via status); what this pins is the DISTINCT,
# honest REASON — pointing the operator at the backend's context size rather than
# at funds or a missing model. Two 400s: probe 1 is retried once by
# retry_if_flappy, so both attempts must land on the same context-overflow body.
python3 - "$HOME/ctx.port" <<'PY' &
import http.server, socketserver, sys, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(n)
        self.send_response(400); self.send_header("Content-Type","application/json"); self.end_headers()
        self.wfile.write(json.dumps({"error":{"message":"request (67288 tokens) exceeds the available context size (3072 tokens), try increasing it"}}).encode())
    def log_message(self,*a): pass
with socketserver.TCPServer(("127.0.0.1",0),H) as s:
    open(sys.argv[1],"w").write(str(s.server_address[1]))
    s.handle_request(); s.handle_request()  # probe 1 + its one retry
PY
for _ in $(seq 1 50); do [[ -s "$HOME/ctx.port" ]] && break; sleep 0.05; done
ctxport="$(cat "$HOME/ctx.port" 2>/dev/null)"
ctx_out="$( TINY_API_KEY=sk-test bash "$SCRIPTS_DIR/providers-verify.sh" \
    --provider tiny --model tiny-model --key-var TINY_API_KEY \
    --base-url "http://127.0.0.1:${ctxport}/v1" 2>"$HOME/ctx.err" )"
assert_eq "failed" "$ctx_out" "a context-overflow 400 is still a failed verdict (the alias cannot serve Claude Code)"
grep -q 'context-inadequate' "$HOME/ctx.err"
assert_eq 0 $? "the reason distinctly names context-inadequate (not auth/billing/model-missing)"
grep -q 'relaunch the backing server with a larger context' "$HOME/ctx.err"
assert_eq 0 $? "and it points the operator at the backend size — the actual fix"
# Discrimination control: a plain auth 401 must NOT be misnamed context-inadequate.
python3 - "$HOME/auth.port" <<'PY' &
import http.server, socketserver, sys, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(n)
        self.send_response(401); self.send_header("Content-Type","application/json"); self.end_headers()
        self.wfile.write(json.dumps({"error":{"message":"invalid api key"}}).encode())
    def log_message(self,*a): pass
with socketserver.TCPServer(("127.0.0.1",0),H) as s:
    open(sys.argv[1],"w").write(str(s.server_address[1]))
    s.handle_request()  # 401 is deterministic, never retried
PY
for _ in $(seq 1 50); do [[ -s "$HOME/auth.port" ]] && break; sleep 0.05; done
authport="$(cat "$HOME/auth.port" 2>/dev/null)"
auth_out="$( TINY_API_KEY=sk-test bash "$SCRIPTS_DIR/providers-verify.sh" \
    --provider tiny --model tiny-model --key-var TINY_API_KEY \
    --base-url "http://127.0.0.1:${authport}/v1" 2>"$HOME/auth.err" )"
assert_eq "failed" "$auth_out" "a 401 is still failed"
grep -q 'context-inadequate' "$HOME/auth.err"
assert_eq 1 $? "a 401 is NOT misnamed context-inadequate (the distinct reason does not over-broaden)"

# NOTE: no `summary` here. There must be exactly ONE summary call, as the very
# last statement in the file — it is what converts TESTS_FAILED into the exit
# code run-all.sh tallies. A stray mid-file summary is a latent false-PASS
# hazard: if a future edit reorders sections so a mid-file summary becomes the
# last executed statement, its status would be reported instead of the real,
# cumulative one. (Sections 10-11 follow below; the real summary is at EOF.)

# ---------------------------------------------------------------------------
# Section 10 — HTTP probe URL normalization (providers-verify.sh)
# Native-transport providers (/anthropic base URL) must probe the Anthropic
# messages endpoint UNDER the kept /anthropic prefix (POST
# /anthropic/v1/messages — the shape real native endpoints like
# api.deepseek.com/anthropic actually serve), with Anthropic content-block
# responses. Loopback HTTP server test.
# ---------------------------------------------------------------------------

it "providers-verify keeps /anthropic and probes /anthropic/v1/messages for native-transport providers"
python3 - "$HOME/nat.port" <<'PY' &
import http.server, socketserver, sys, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        if self.path == "/anthropic/v1/messages":
            self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers()
            if '"tools"' in body:
                self.wfile.write(json.dumps({"content":[{"type":"tool_use","id":"t1","name":"get_weather","input":{"city":"Paris"}}]}).encode())
            else:
                self.wfile.write(json.dumps({"content":[{"type":"text","text":"VERIFY_OK"}]}).encode())
        else:
            self.send_response(404); self.end_headers()
    def log_message(self,*a): pass
with socketserver.TCPServer(("127.0.0.1",0),H) as s:
    open(sys.argv[1],"w").write(str(s.server_address[1]))
    s.handle_request(); s.handle_request()  # chat probe + tool probe
PY
for _ in $(seq 1 50); do [[ -s "$HOME/nat.port" ]] && break; sleep 0.05; done
natport="$(cat "$HOME/nat.port" 2>/dev/null)"
NATIVE_ANTHROPIC_API_KEY=sk-test out="$(
  NATIVE_ANTHROPIC_API_KEY=sk-test bash "$SCRIPTS_DIR/providers-verify.sh" \
    --provider native --model mimo-x --key-var NATIVE_ANTHROPIC_API_KEY \
    --base-url "http://127.0.0.1:${natport}/anthropic" 2>/dev/null )"
assert_eq "verified" "$out" "native /anthropic base -> verified (prefix kept, /anthropic/v1/messages probed)"

# ---------------------------------------------------------------------------
# Section 11 — cma_run_provider env isolation (emitted body check)
# ---------------------------------------------------------------------------

it "emitted cma_run_provider carries env-isolation unset for ANTHROPIC_*"
grep -qF 'unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL' "$ALIAS_FILE"
assert_eq 0 $? "full ANTHROPIC_* unset line present in alias file"

it "emitted cma_run_provider carries env-isolation unset for CLAUDE_CODE_*"
grep -qF 'unset CLAUDE_CODE_AUTO_COMPACT_WINDOW CLAUDE_CODE_MAX_OUTPUT_TOKENS' "$ALIAS_FILE"
assert_eq 0 $? "CLAUDE_CODE_* unset line present in alias file"

it "env-isolation markers appear in cma_run_provider body before activation gate"
# Scope BOTH line lookups to cma_run_provider's own body.
#
# This previously grepped the whole alias file and filtered out lines
# containing "grep", to skip lib.sh's own migration-marker checks. Those
# checks now use bash builtins (`[[ "$body" != *PAT* ]]`) instead of grep
# subprocesses, so that filter stopped excluding anything — and `head -1`
# then matched `local _cma_force=0` inside cma_run, comparing a line number
# from ONE function against a line number from ANOTHER. The ordering property
# itself never broke: within cma_run_provider the unset genuinely precedes the
# gate. Extracting the body first makes the comparison mean what it claims.
_ord_body="$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
_gate_line="$(grep -n '(( ! _cma_force ))' <<<"$_ord_body" | head -1 | cut -d: -f1)"
_unset_line="$(grep -n 'unset ANTHROPIC_BASE_URL' <<<"$_ord_body" | head -1 | cut -d: -f1)"
[[ -n "$_unset_line" && -n "$_gate_line" && "$_unset_line" -lt "$_gate_line" ]]
assert_eq 0 $? "env-isolation unset lines precede the activation gate"

it "migration check detects missing env-isolation marker"
_bare_body='cma_run_provider() { :; }'
grep -qF 'unset ANTHROPIC_BASE_URL' <<<"$_bare_body" && _has=1 || _has=0
assert_eq 0 "$_has" "bare body without env-isolation triggers missing check"

# ---------------------------------------------------------------------------
# Section 12 — multi-alias status persistence (direct status cache + gate test)
# ---------------------------------------------------------------------------

it "cma_status_write works for a multi-alias name (numeric suffix pattern)"
cma_status_write "acme2" "verified" "acme-big" ""
assert_eq "verified" "$(cma_status_read acme2)" "multi-alias acme2 reads as verified"
assert_jq "$(cma_status_cache)" '.acme2.model' "acme-big" "multi-alias carries model name"
assert_jq "$(cma_status_cache)" '.acme2.failing_layer' "" "verified has empty failing_layer"

it "cma_status_write for multi-alias with low score -> unverified (existence)"
cma_status_write "acme4" "unverified" "acme-tiny" "existence"
assert_eq "unverified" "$(cma_status_read acme4)" "low-score multi-alias -> unverified"
assert_jq "$(cma_status_cache)" '.acme4.failing_layer' "existence" "low-score -> existence"

it "multi-alias gate subshells also load the wrapper from the sandbox alias file"
# Re-asserted rather than inherited from Section 7: the alias file has been
# regenerated by the intervening syncs, so this is a different generation of the
# file feeding the two multi-alias gate subshells below.
assert_fn_from --source "$ALIAS_FILE" cma_run_provider "multi-alias gate subshell wrapper provenance"

it "multi-alias activation gate: verified alias launches (cma_run_provider rc 0)"
cma_status_write "acme2" "verified" "acme-big" ""
mkdir -p "$HOME/.claude-prov-acme2"
_pdir="$(cma_providers_dir)"; mkdir -p "$_pdir"
cat > "$_pdir/acme2.env" <<ENVEOF
CMA_PROVIDER_ID='acme2'
CMA_PROVIDER_KEYVAR='ACME_API_KEY'
CMA_PROVIDER_TRANSPORT='native'
CMA_PROVIDER_BASE_URL=''
CMA_PROVIDER_MODEL='acme-big'
CMA_PROVIDER_FAST_MODEL='acme-small'
CMA_PROVIDER_CONFIG_DIR='$HOME/.claude-prov-acme2'
ENVEOF
( ACME_API_KEY=sk-test CLAUDE_BIN=/usr/bin/true source "$ALIAS_FILE"; cma_run_provider acme2 ) >/dev/null 2>&1
assert_eq 0 $? "multi-alias verified acme2 launches (rc 0)"

it "multi-alias activation gate: unverified alias blocks (rc 3)"
# Create env file first (needed for cma_run_provider to find it)
cat > "$_pdir/acme4.env" <<ENVEOF
CMA_PROVIDER_ID='acme4'
CMA_PROVIDER_KEYVAR='ACME_API_KEY'
CMA_PROVIDER_TRANSPORT='native'
CMA_PROVIDER_BASE_URL=''
CMA_PROVIDER_MODEL='acme-tiny'
CMA_PROVIDER_FAST_MODEL='acme-small'
CMA_PROVIDER_CONFIG_DIR='$HOME/.claude-prov-acme4'
ENVEOF
mkdir -p "$HOME/.claude-prov-acme4"
cma_status_write "acme4" "unverified" "acme-tiny" "existence"
( CLAUDE_BIN=/usr/bin/true ACME_API_KEY=sk-test source "$ALIAS_FILE"; cma_run_provider acme4 ) >/dev/null 2>&1; _grc=$?
assert_eq 3 "$_grc" "unverified multi-alias acme4 blocked by gate (rc 3)"

# ---------------------------------------------------------------------------
# Section 13 — provider-removal & orphan lifecycle: cmd_remove must clear the
# status.json entry (previously it never did — .env/alias/config dir were
# removed but the stale record lingered forever, and a stale "verified" record
# is still trusted by the launch-time activation gate, which only checks
# status=="verified" and never checks whether the provider still resolves);
# cmd_sync must detect + demote any status.json/*.env record whose provider id
# no longer resolves against the current catalog+keys ("orphan") instead of
# leaving it forever; and the new `prune` subcommand reports (--dry-run) or
# actually removes orphans via the same cmd_remove path.
#
# Every id here is unique to this section and never present in the fixture
# catalog seeded above, so this section cannot collide with, or be polluted
# by, any earlier section's provider state.
# ---------------------------------------------------------------------------

it "cmd_remove clears the status.json entry for the removed provider"
cma_provider_write_env "removeme" "REMOVEME_KEY" "router" "https://api.removeme.example/v1" \
  "removeme-big" "removeme-fast" "$HOME/.claude-prov-removeme" "" "" "removeme"
cma_provider_write_alias "removeme" "removeme"
cma_status_write removeme verified removeme-big ""
assert_eq "verified" "$(cma_status_read removeme)" "precondition: removeme status verified before remove"
bash "$PROVIDERS_SH" remove removeme >/dev/null 2>&1
assert_eq "pending" "$(cma_status_read removeme)" "status reads back as pending (no stale record) after remove"
_rm_key_present=0
jq -e '.removeme' "$(cma_status_cache)" >/dev/null 2>&1 && _rm_key_present=1
assert_eq 0 "$_rm_key_present" "removeme key is actually absent from status.json, not just null"

it "cmd_remove leaves OTHER status.json entries untouched (no over-broad delete)"
cma_status_write removeme-sibling verified sibling-model ""
cma_provider_write_env "removeme2" "REMOVEME2_KEY" "router" "https://api.removeme2.example/v1" \
  "removeme2-big" "" "$HOME/.claude-prov-removeme2" "" "" "removeme2"
cma_status_write removeme2 verified removeme2-big ""
bash "$PROVIDERS_SH" remove removeme2 >/dev/null 2>&1
assert_eq "verified" "$(cma_status_read removeme-sibling)" "sibling status entry survives an unrelated remove"
assert_eq "pending" "$(cma_status_read removeme2)" "removeme2's own entry is gone"

it "sync demotes an orphaned status.json record instead of leaving it 'verified' forever"
# 'orphan-alpha' has no backing key anywhere in $KEYS and no catalog entry in
# $PCACHE — it can never be part of a resolved record, so any sync run must
# treat its lingering "verified" status as stale.
cma_status_write orphan-alpha verified orphan-alpha-model ""
assert_eq "verified" "$(cma_status_read orphan-alpha)" "precondition: orphan-alpha marked verified"
_orphan_warn="$(bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" 2>&1 >/dev/null)"
_orphan_status="$(cma_status_read orphan-alpha)"
cond=1; [[ "$_orphan_status" != "verified" ]] && cond=0
assert_eq 0 "$cond" "orphan-alpha no longer reports verified after sync (now: $_orphan_status)"
grep -qi 'orphan' <<<"$_orphan_warn"; assert_eq 0 $? "sync emits an orphan warning on stderr"
grep -q 'orphan-alpha' <<<"$_orphan_warn"; assert_eq 0 $? "warning names the specific orphaned id"

it "sync's orphan detection also covers a leftover *.env with no prior status.json entry"
cma_provider_write_env "orphan-beta" "ORPHAN_BETA_KEY" "router" "https://api.orphan-beta.example/v1" \
  "orphan-beta-model" "" "$HOME/.claude-prov-orphan-beta" "" "" "orphan-beta"
cma_provider_write_alias "orphan-beta" "orphan-beta"
assert_eq "pending" "$(cma_status_read orphan-beta)" "precondition: orphan-beta has no status entry yet (env-only orphan)"
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >/dev/null 2>&1
_orphan_beta_status="$(cma_status_read orphan-beta)"
cond=1; [[ "$_orphan_beta_status" != "verified" && "$_orphan_beta_status" != "pending" ]] && cond=0
assert_eq 0 "$cond" "env-only orphan gets an explicit demoted status, not silently left pending/verified (now: $_orphan_beta_status)"

it "sync never demotes a provider that still resolves (guard against orphan-detection over-matching)"
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >/dev/null 2>&1
_acme_status_after="$(cma_status_read acme)"
cond=1; [[ "$_acme_status_after" == "orphaned" ]] && cond=0
assert_eq 1 "$cond" "acme (still resolves every sync) is never marked orphaned"
assert_eq "unverified" "$_acme_status_after" "acme keeps its normal --no-verify status (not clobbered by orphan demotion)"


# ---------------------------------------------------------------------------
# Section 13b — the two DISTINCT orphan classes prune must tell apart:
#   * orphan-alpha (from above): a status.json record with NO backing .env —
#     STATUS-ONLY. Invisible to list/list-all/list-faulty and unreachable by
#     `remove` (which requires the env file), so it is unconditionally safe
#     dead weight; prune drops it even without any extra flag.
#   * orphan-beta (from above): a *.env-backed provider that no longer
#     resolves — UNRESOLVED. It has a live alias/config dir that might hold
#     real state and its non-resolution might just mean a key is temporarily
#     missing, so plain `prune` only ever REPORTS it; actually removing it
#     requires the explicit --unresolved flag.
#   * acme (from Section 3 onward): resolves on every sync/prune call in this
#     file (ACME_API_KEY is in $KEYS, "acme" is in the fixture catalog) — the
#     healthy provider that must never be flagged by either class.
# ---------------------------------------------------------------------------

it "prune --dry-run labels orphan-alpha status-only and orphan-beta unresolved, distinctly"
_dry_out="$(bash "$PROVIDERS_SH" prune --dry-run --offline --keys-file "$KEYS" 2>&1)"
grep -q 'orphan-alpha' <<<"$_dry_out"; assert_eq 0 $? "dry-run reports orphan-alpha"
grep -q 'orphan-beta' <<<"$_dry_out"; assert_eq 0 $? "dry-run reports orphan-beta"
_alpha_line="$(grep 'orphan-alpha' <<<"$_dry_out")"
_beta_line="$(grep 'orphan-beta' <<<"$_dry_out")"
grep -qi 'status-only' <<<"$_alpha_line"; assert_eq 0 $? "orphan-alpha (no .env) is labeled status-only"
grep -qi 'unresolved' <<<"$_beta_line"; assert_eq 0 $? "orphan-beta (has .env) is labeled unresolved"
grep -q 'would prune' <<<"$_alpha_line"; assert_eq 0 $? "status-only orphan is would-prune even without --unresolved"
grep -q 'would prune' <<<"$_beta_line"; assert_eq 1 $? "unresolved orphan is NOT would-prune without --unresolved"
grep -qi 'not pruned' <<<"$_beta_line"; assert_eq 0 $? "unresolved orphan is explicitly marked NOT pruned"
grep -q -- '--unresolved' <<<"$_beta_line"; assert_eq 0 $? "unresolved orphan's line tells the operator about --unresolved"

it "prune --dry-run never flags acme, a provider that still resolves"
echo "$_dry_out" | grep -qw 'acme'; assert_eq 1 $? "acme (still resolves) never appears in prune --dry-run output"

it "prune --dry-run: dry-run changes nothing for either class"
_before_alpha_status="$(cma_status_read orphan-alpha)"
_before_beta_env=0; [[ -f "$PDIR/orphan-beta.env" ]] && _before_beta_env=1
bash "$PROVIDERS_SH" prune --dry-run --offline --keys-file "$KEYS" >/dev/null 2>&1
assert_eq "$_before_alpha_status" "$(cma_status_read orphan-alpha)" "dry-run does not change orphan-alpha's status"
_after_beta_env=0; [[ -f "$PDIR/orphan-beta.env" ]] && _after_beta_env=1
assert_eq "$_before_beta_env" "$_after_beta_env" "dry-run does not remove orphan-beta's env file"
grep -q 'cma_run_provider orphan-beta"' "$ALIAS_FILE"; assert_eq 0 $? "dry-run does not remove orphan-beta's alias line"

it "prune --dry-run --unresolved previews pruning BOTH classes together"
_dry_both="$(bash "$PROVIDERS_SH" prune --dry-run --unresolved --offline --keys-file "$KEYS" 2>&1)"
grep 'orphan-alpha' <<<"$_dry_both" | grep -q 'would prune'; assert_eq 0 $? "status-only still would-prune under --unresolved"
grep 'orphan-beta' <<<"$_dry_both" | grep -q 'would prune'; assert_eq 0 $? "unresolved orphan also would-prune with --unresolved"
echo "$_dry_both" | grep -qw 'acme'; assert_eq 1 $? "acme still never appears, even with --unresolved"

it "plain prune removes the status-only orphan for real but leaves the unresolved orphan alone"
_real_out="$(bash "$PROVIDERS_SH" prune --offline --keys-file "$KEYS" 2>&1)"
assert_eq "pending" "$(cma_status_read orphan-alpha)" "orphan-alpha's status record is gone after a plain, real prune"
_beta_env_present=0; [[ -f "$PDIR/orphan-beta.env" ]] && _beta_env_present=1
assert_eq 1 "$_beta_env_present" "orphan-beta's env file SURVIVES a plain prune (needs --unresolved)"
grep -q 'cma_run_provider orphan-beta"' "$ALIAS_FILE"; assert_eq 0 $? "orphan-beta's alias line survives a plain prune"
grep -qi 'unresolved' <<<"$_real_out"; assert_eq 0 $? "plain prune's real-run output still calls out the untouched unresolved orphan"
grep -q -- '--unresolved' <<<"$_real_out"; assert_eq 0 $? "plain prune tells the operator how to remove it (--unresolved)"

it "prune --unresolved removes the unresolved orphan for real"
bash "$PROVIDERS_SH" prune --unresolved --offline --keys-file "$KEYS" >/dev/null 2>&1
_env_gone=1; [[ -f "$PDIR/orphan-beta.env" ]] && _env_gone=0
assert_eq 1 "$_env_gone" "orphan-beta's env file is removed after prune --unresolved"
grep -q 'cma_run_provider orphan-beta"' "$ALIAS_FILE" ; assert_eq 1 $? "orphan-beta's alias line is removed after prune --unresolved"
assert_eq "pending" "$(cma_status_read orphan-beta)" "orphan-beta's status record is also gone (cmd_remove clears it)"

it "prune never touches acme when actually removing orphans (healthy provider guard)"
_acme_status_before="$(cma_status_read acme)"
bash "$PROVIDERS_SH" prune --unresolved --offline --keys-file "$KEYS" >/dev/null 2>&1
assert_eq "$_acme_status_before" "$(cma_status_read acme)" "acme's status is untouched by a real prune run"
assert_file "$PDIR/acme.env" "acme env file still present after prune"
grep -q '^alias acme="cma_run_provider acme"' "$ALIAS_FILE"; assert_eq 0 $? "acme alias still present after prune"

it "prune is a no-op (with a clear message) once no orphans remain"
_clean_out="$(bash "$PROVIDERS_SH" prune --offline --keys-file "$KEYS" 2>&1)"
grep -qi 'no orphan' <<<"$_clean_out"; assert_eq 0 $? "prune reports there is nothing left to prune"


# ---------------------------------------------------------------------------
# Section N — token-budget invariants (regression for the v1.24.0 launch 400)
#
# Live failure this section pins down (openrouter, proof run):
#   "API Error: 400 This endpoint's maximum context length is 262144 tokens.
#    However, you requested about 265483 tokens (33796 of text input,
#    103687 of tool input, 128000 in the output)."
#
# Two independent defects produced it, and BOTH are asserted here:
#   A. providers_resolve.py copied limit.output out of the models.dev catalog
#      with no sanity check. That catalog carries context-sized numbers in the
#      output slot (1099 of 5696 rows have output >= context). openrouter's row
#      for nvidia/nemotron-3-super-120b-a12b:free is {context:1000000,
#      output:262144} — 262144 is the model's REAL context (kilo's row for the
#      same id says {context:262144, output:262144}, and so does the live 400).
#   B. lib.sh exported the input guard ONLY when context <= 200000, so the
#      large-context providers that most need a guard got none at all.
# ---------------------------------------------------------------------------

TGFIX="$HOME/tokenguard"
mkdir -p "$TGFIX"

# Fixture mirrors the three real shapes, with limits chosen so a regression is
# unambiguous rather than coincidentally passing.
cat > "$TGFIX/catalog.json" <<'JSON'
{
  "leaky": {
    "env": ["LEAKY_API_KEY"],
    "api": "https://api.leaky.ai/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "big":      {"id":"big","reasoning":true,"tool_call":true,"release_date":"2026-03-11","limit":{"context":1000000,"output":16384},"cost":{"input":0.21,"output":0.455}},
      "big:free": {"id":"big:free","reasoning":true,"tool_call":true,"release_date":"2026-03-11","limit":{"context":1000000,"output":262144},"cost":{"input":0,"output":0}}
    }
  },
  "twin": {
    "env": ["TWIN_API_KEY"],
    "api": "https://api.twin.ai/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "same": {"id":"same","reasoning":true,"tool_call":true,"release_date":"2026-03-11","limit":{"context":262144,"output":262144},"cost":{"input":0,"output":0}}
    }
  },
  "honest": {
    "env": ["HONEST_API_KEY"],
    "api": "https://api.honest.ai/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "wide": {"id":"wide","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":1048576,"output":131072},"cost":{"input":0,"output":0}}
    }
  },
  "peerone": {
    "env": ["PEERONE_API_KEY"],
    "api": "https://api.peerone.ai/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "big":       {"id":"big","tool_call":true,"limit":{"context":262144,"output":262144},"cost":{"input":0.2,"output":0.4}},
      "solid":     {"id":"solid","tool_call":true,"limit":{"context":1000000,"output":65536},"cost":{"input":0.2,"output":0.4}},
      "modest":    {"id":"modest","tool_call":true,"limit":{"context":262144,"output":32768},"cost":{"input":0.2,"output":0.4}}
    }
  },
  "peertwo": {
    "env": ["PEERTWO_API_KEY"],
    "api": "https://api.peertwo.ai/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "big":       {"id":"big","tool_call":true,"limit":{"context":262144,"output":16384},"cost":{"input":0.2,"output":0.4}},
      "solid":     {"id":"solid","tool_call":true,"limit":{"context":1000000,"output":65000},"cost":{"input":0.2,"output":0.4}},
      "modest":    {"id":"modest","tool_call":true,"limit":{"context":262144,"output":32768},"cost":{"input":0.2,"output":0.4}}
    }
  },
  "peerthree": {
    "env": ["PEERTHREE_API_KEY"],
    "api": "https://api.peerthree.ai/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "big":       {"id":"big","tool_call":true,"limit":{"context":262144,"output":32768},"cost":{"input":0.2,"output":0.4}},
      "solid":     {"id":"solid","tool_call":true,"limit":{"context":1000000,"output":65536},"cost":{"input":0.2,"output":0.4}},
      "modest":    {"id":"modest","tool_call":true,"limit":{"context":262144,"output":16384},"cost":{"input":0.2,"output":0.4}}
    }
  },
  "peerfour": {
    "env": ["PEERFOUR_API_KEY"],
    "api": "https://api.peerfour.ai/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "big":       {"id":"big","tool_call":true,"limit":{"context":100000,"output":16384},"cost":{"input":0.2,"output":0.4}},
      "solid":     {"id":"solid","tool_call":true,"limit":{"context":262144,"output":65536},"cost":{"input":0.2,"output":0.4}},
      "modest":    {"id":"modest","tool_call":true,"limit":{"context":32768,"output":16384},"cost":{"input":0.2,"output":0.4}}
    }
  },
  "falsepos": {
    "env": ["FALSEPOS_API_KEY"],
    "api": "https://api.falsepos.ai/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "solid":      {"id":"solid","tool_call":true,"limit":{"context":1000000,"output":16384},"cost":{"input":0.2,"output":0.4}},
      "solid:free": {"id":"solid:free","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":1000000,"output":65536},"cost":{"input":0,"output":0}}
    }
  },
  "crushed": {
    "env": ["CRUSHED_API_KEY"],
    "api": "https://api.crushed.ai/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "modest":      {"id":"modest","tool_call":true,"limit":{"context":262144,"output":16384},"cost":{"input":0.2,"output":0.4}},
      "modest:free": {"id":"modest:free","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":262144,"output":32768},"cost":{"input":0,"output":0}}
    }
  },
  "lonely": {
    "env": ["LONELY_API_KEY"],
    "api": "https://api.lonely.ai/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "orphan":      {"id":"orphan","tool_call":true,"limit":{"context":900000,"output":16384},"cost":{"input":0.2,"output":0.4}},
      "orphan:free": {"id":"orphan:free","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":900000,"output":65536},"cost":{"input":0,"output":0}}
    }
  }
}
JSON

TGOUT="$HOME/tokenguard.json"
python3 "$RESOLVE" --models-dev "$TGFIX/catalog.json" \
  --keys "LEAKY_API_KEY,TWIN_API_KEY,HONEST_API_KEY,FALSEPOS_API_KEY,CRUSHED_API_KEY,LONELY_API_KEY" > "$TGOUT"
assert_eq 0 $? "token-guard fixture resolves"

# Claude Code's measured per-request input floor (system prompt + tool schemas)
# from the live 400 above: 33796 + 103687.
TG_FLOOR=137483

it "a :free row contradicted by independent providers has its context corrected"
# leaky/big:free claims {1000000, 262144} while its own paid sibling gets only
# 16384 output, so something in the record is mislabelled. peerone and peertwo
# both publish `big` at 262144, so the CONTEXT is the fiction. This mirrors the
# live shape exactly: openrouter says 1000000 for
# nvidia/nemotron-3-super-120b-a12b while kilo, nvidia, cortecs and nebius all
# say 262144 — and the live 400 said "maximum context length is 262144 tokens".
# Without the fix this record emits context=1000000 / max_output=262144 — the
# exact pair that produced the 400.
assert_eq "262144" "$(rfield "$TGOUT" LEAKY_API_KEY context_limit)" "leaky context corrected to the real 262144"
_leaky_out="$(rfield "$TGOUT" LEAKY_API_KEY max_output)"
assert_eq "102144" "$_leaky_out" "leaky output carved out of the context, not copied from it"

# ---------------------------------------------------------------------------
# C1 regression — the same detector, firing on records that are RIGHT.
#
# Reading the offending output value as a context was a coin flip: on the live
# catalog it fires on 10 rows, shrinks 4, and 2 of those 4 were destroyed:
#
#   openrouter/nvidia/nemotron-3-ultra-550b-a55b:free {1000000, 65536}
#       -> ctx 65536, losing 934,464 tokens (93.4%). But nvidia's OWN record
#       for that model is {1000000, 65536} and vercel's is {1000000, 65000} —
#       65536 is a genuine output budget.
#   openrouter/google/gemma-4-26b-a4b-it:free {262144, 32768}
#       -> ctx 32768, losing 229,376 tokens (87.5%) AND collapsing the output
#       cap to the 8192 floor. But 32768 is the most published output for that
#       model (8 of 16 records) and 14 of 16 publish context=262144.
#
# An 8192 output cap on a coding model is its own dead alias, so "it errs
# small" does not make a wrong firing safe.
# ---------------------------------------------------------------------------
it "a :free row whose context IS corroborated keeps it (the ultra-550b shape)"
# falsepos/solid:free is {1000000, 65536} with a paid sibling at 16384 — the
# anomaly fires — but peerone and peertwo publish `solid` at 1000000 too.
assert_eq "1000000" "$(rfield "$TGOUT" FALSEPOS_API_KEY context_limit)" "context NOT collapsed to the output value 65536"
assert_eq "65536"   "$(rfield "$TGOUT" FALSEPOS_API_KEY max_output)"    "the genuine 65536 output budget survives, not the 8192 floor"

it "a corroborated :free row keeps a usable output cap (the gemma-4 shape)"
# crushed/modest:free is {262144, 32768} with a paid sibling at 16384. Peers
# publish `modest` at 262144, so 32768 is an output budget, not a context.
assert_eq "262144" "$(rfield "$TGOUT" CRUSHED_API_KEY context_limit)" "context NOT collapsed to 32768"
assert_eq "32768"  "$(rfield "$TGOUT" CRUSHED_API_KEY max_output)"    "output stays 32768, not floored to 8192"

it "with no independent corroboration the catalog context is kept, not guessed away"
# lonely/orphan exists nowhere else, so a single provider's self-inconsistency
# is all the evidence there is — and that evidence was measured to be right
# half the time. Keep the published context and say so rather than shrink on a
# coin flip.
assert_eq "900000" "$(rfield "$TGOUT" LONELY_API_KEY context_limit)" "uncorroborated context kept"
_lonely_reason="$(python3 -c '
import json,sys
for r in json.load(open(sys.argv[1])):
    if r["key_var"]=="LONELY_API_KEY": print(r["selection_reason"])' "$TGOUT")"
case "$_lonely_reason" in *"no corroboration"*) _lc=0 ;; *) _lc=1 ;; esac
assert_eq 0 "$_lc" "the absence of corroboration is stated, not silent: '$_lonely_reason'"

# ---------------------------------------------------------------------------
# Round-3 adjudicator tests. Everything below drives providers_resolve directly
# rather than through the fixture catalog, because the properties at stake are
# properties of the VOTE — who may vote, how many, and how the votes combine —
# and a fixture that has to round-trip the whole resolver cannot state them
# sharply enough to fail for the right reason.
#
# The prior fixtures could not catch these at all: peerone and peertwo were
# given IDENTICAL contexts for every model, so median, minimum and maximum were
# the same number and no aggregation bug could ever change an answer. Mutating
# the lower median to `vals[0]` (always take the minimum) left the suite at
# 380 passed / 0 failed. Live data is never homogeneous — median differed from
# minimum on 4 of the 5 lowerings the round-2 code performed.
# ---------------------------------------------------------------------------
_ADJ="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import providers_resolve as R

def cat(*rows):
    """rows: (provider_id, model_id, context, output) -> a catalog dict."""
    c = {}
    for pid, mid, ctx, out in rows:
        lim = {"context": ctx}
        if out is not None:
            lim["output"] = out
        c.setdefault(pid, {"models": {}})["models"][mid] = {
            "id": mid, "tool_call": True, "limit": lim}
    return c

def derive(catalog, pid, mid):
    corr = R.build_context_corroboration(catalog)
    models = catalog[pid]["models"]
    return R.derive_limits(models[mid], models, corr, pid)

# --- C1: the accused must not vote in its own trial ------------------------
# A provider publishing a genuine 1,000,000 free row, and exactly ONE obscure
# peer serving an 8192 truncation. Round 2 indexed the accused too, so
# {accused, peer} met a threshold of 2, and with two voters the lower median IS
# the minimum -- the single peer won outright and destroyed 99.2% of the window
# under a note claiming two independent providers had agreed.
c1 = cat(("provx", "nvidia/turbo", 1000000, 16384),
         ("provx", "nvidia/turbo:free", 1000000, 262144),
         ("provy", "turbo", 8192, 4096))
ctx, out, note = derive(c1, "provx", "nvidia/turbo:free")
print("C1_CTX=%s" % ctx)
print("C1_CORROBORATED=%s" % ("yes" if "context corrected" in note else "no"))

# Two peers is still not enough: with n=2 the lower median is the minimum, so
# one peer decides alone -- the same defect one step further out.
c1b = cat(("provx", "nvidia/turbo", 1000000, 16384),
          ("provx", "nvidia/turbo:free", 1000000, 262144),
          ("provy", "turbo", 8192, 4096), ("provz", "turbo", 1000000, 65536))
print("C1_TWOPEERS_CTX=%s" % derive(c1b, "provx", "nvidia/turbo:free")[0])

# Three INDEPENDENT peers, a majority of them low -> the correction is earned.
c1c = cat(("provx", "nvidia/turbo", 1000000, 16384),
          ("provx", "nvidia/turbo:free", 1000000, 262144),
          ("provy", "turbo", 262144, 4096), ("provz", "turbo", 262144, 65536),
          ("provw", "turbo", 1000000, 65536))
print("C1_THREEPEERS_CTX=%s" % derive(c1c, "provx", "nvidia/turbo:free")[0])

# The two cases above cannot, on their own, distinguish "the accused was
# excluded" from "the threshold was not met" -- both return None. These two can,
# and they pin the exclusion in BOTH directions.
#
# (a) The accused makes up the quorum. Two low peers is n=2 and no correction;
#     let the accused vote and n becomes 3, the lower median lands on the peers`
#     8192, and the accused is convicted by a quorum it joined itself.
c1d = cat(("provx", "nvidia/turbo", 1000000, 16384),
          ("provx", "nvidia/turbo:free", 1000000, 262144),
          ("provy", "turbo", 8192, 4096), ("provz", "turbo", 8192, 4096))
print("C1_SELFQUORUM_CTX=%s" % derive(c1d, "provx", "nvidia/turbo:free")[0])

# (b) The accused props up its own claim. Four independents split 2-2 and the
#     lower median is 262144, so the record is corrected -- but if the accused
#     votes, its own 1000000 becomes the fifth ballot, drags the median up to
#     1000000, and the record acquits itself. Exclusion has to cut both ways or
#     it is not a rule about evidence, it is a rule about outcomes.
c1e = cat(("provx", "nvidia/turbo", 1000000, 16384),
          ("provx", "nvidia/turbo:free", 1000000, 262144),
          ("pa", "turbo", 262144, 4096), ("pb", "turbo", 262144, 4096),
          ("pc", "turbo", 1000000, 4096), ("pd", "turbo", 1000000, 4096))
print("C1_SELFACQUIT_CTX=%s" % derive(c1e, "provx", "nvidia/turbo:free")[0])

# --- C2: the aggregate is the MEDIAN, distinguishable from min and max -----
# A deliberately heterogeneous pool: min 16000, lower median 80000, max 262144.
# All three are different numbers, so any of the three plausible aggregation
# rules produces a different answer and a mutation cannot hide.
het = R.build_context_corroboration(
    cat(("pa", "m", 16000, 4096), ("pb", "m", 32768, 4096),
        ("pc", "m", 80000, 4096), ("pd", "m", 131072, 4096),
        ("pe", "m", 262144, 4096)))
print("C2_MEDIAN=%s" % R._corroborated_context("m", het, None))
print("C2_MIN=%s C2_MAX=%s" % (16000, 262144))
# Even-sized pool: lower median must be the LOWER of the two middle values and
# must still differ from both extremes.
het4 = R.build_context_corroboration(
    cat(("pa", "m", 16000, 4096), ("pb", "m", 80000, 4096),
        ("pc", "m", 131072, 4096), ("pd", "m", 262144, 4096)))
print("C2_MEDIAN4=%s" % R._corroborated_context("m", het4, None))

# --- I1: output == context is NOT evidence about the context ---------------
# The commonest mislabel in the catalog is output copied FROM context (1099 of
# 5696 live rows), which _carve_output already fixes. Comparing that copy with
# a paid sibling`s genuine output cap makes the free row look bigger as
# arithmetic, not as evidence. Round 2 adjudicated these anyway and lowered
# three real windows, worst llama-3.2-3b-instruct:free 131072->80000 (39%),
# where the low votes were other hosts` truncations.
i1 = cat(("orx", "meta/lla", 131072, 16384),
         ("orx", "meta/lla:free", 131072, 131072),
         ("pa", "lla", 16000, 4096), ("pb", "lla", 32768, 4096),
         ("pc", "lla", 32768, 4096), ("pd", "lla", 80000, 4096))
print("I1_CTX=%s" % derive(i1, "orx", "meta/lla:free")[0])
# ...but the shape the mechanism WAS built for (output strictly below context)
# is still adjudicated, so this is a narrowing, not a disabling.
i1b = cat(("orx", "nv/sup", 1000000, 16384),
          ("orx", "nv/sup:free", 1000000, 262144),
          ("pa", "sup", 262144, 4096), ("pb", "sup", 262144, 4096),
          ("pc", "sup", 256000, 4096))
print("I1_STILL_ADJUDICATES=%s" % derive(i1b, "orx", "nv/sup:free")[0])

# --- I2: a value rejected as a cap cannot convict a context ----------------
# 262144.7 is reported by this module as "not a usable cap; treated as
# unknown", and then used, on that same rejected value, to cut 1,000,000 down
# to 32,768 -- 96.7% of the window.
i2 = {"px": {"models": {
        "x/y": {"id": "x/y", "limit": {"context": 1000000, "output": 16384}},
        "x/y:free": {"id": "x/y:free", "limit": {"context": 1000000, "output": 262144.7}}}},
      "pa": {"models": {"y": {"id": "y", "limit": {"context": 32768, "output": 4096}}}},
      "pb": {"models": {"y": {"id": "y", "limit": {"context": 32768, "output": 4096}}}},
      "pc": {"models": {"y": {"id": "y", "limit": {"context": 32768, "output": 4096}}}}}
print("I2_CTX=%s" % derive(i2, "px", "x/y:free")[0])

# --- I3: unrelated models that share a last segment are not one model ------
# Live: 392 normalized keys span >1 vendor prefix and 257 disagree on context.
i3 = cat(("alpha", "alpha/turbo", 1000000, 16384),
         ("alpha", "alpha/turbo:free", 1000000, 262144),
         ("beta", "beta/turbo", 8192, 4096), ("gamma", "gamma/turbo", 8192, 4096),
         ("delta", "delta/turbo", 8192, 4096))
print("I3_CTX=%s" % derive(i3, "alpha", "alpha/turbo:free")[0])
# The fold must not over-tighten either: a BARE id states no vendor and must
# still corroborate a vendored one (cortecs publishes `nemotron-...` where
# openrouter publishes `nvidia/nemotron-...`).
i3b = cat(("orx", "nvidia/nem", 1000000, 16384),
          ("orx", "nvidia/nem:free", 1000000, 262144),
          ("cortecs", "nem", 262144, 4096), ("kilo", "nvidia/nem", 262144, 4096),
          ("nv", "nem", 262144, 4096))
print("I3_BARE_STILL_VOTES=%s" % derive(i3b, "orx", "nvidia/nem:free")[0])

# --- I4: what corroboration CANNOT establish, pinned as behaviour ----------
# A genuinely throttled free tier is left at the paid value, because every peer
# record describes the PAID tier. This is a real blind spot, asserted here so
# it stays documented rather than quietly assumed solved.
i4 = cat(("px", "v/model", 1000000, 16384),
         ("px", "v/model:free", 1000000, 65536),
         ("pa", "model", 1000000, 4096), ("pb", "model", 1000000, 4096),
         ("pc", "model", 1000000, 4096))
print("I4_THROTTLED_FREE_NOT_CAUGHT=%s" % derive(i4, "px", "v/model:free")[0])

# --- I5: a context too small to carve any cap from is a hole, not a window --
print("I5_PAIR=%s" % (R.derive_limits({"id": "z", "limit": {"context": 1}}, {})[:2],))

# --- I6: a corroboration CORRECTION to a sub-viable context (round-4 fail-open) ---
# The raw-catalog viability guard (MIN_VIABLE_CONTEXT) re-validated ONLY the
# catalog context, but `ctx` is re-assigned afterward by the correction
# (`ctx = corroborated`). Three same-vendor peers all publishing context=1 drag
# the accused down to 1; the accused output (50000) exceeds its paid sibling
# (16384) so the anomaly fires and the correction branch is taken. Before the
# fix _carve_output returned None and derive_limits emitted (1, None) — a
# context with NO output cap, the precise fail-open the module exists to close.
def _pair_ok(c, o):
    return (isinstance(c, int) and not isinstance(c, bool) and c > 0
            and isinstance(o, int) and not isinstance(o, bool) and 0 < o < c)
i6 = cat(("acc", "acme/turbo-9000", 1000000, 16384),
         ("acc", "acme/turbo-9000:free", 1000000, 50000),
         ("p1", "acme/turbo-9000", 1, 1), ("p2", "acme/turbo-9000", 1, 1),
         ("p3", "acme/turbo-9000", 1, 1))
_c6, _o6, _n6 = derive(i6, "acc", "acme/turbo-9000:free")
print("I6_CAPLESS=%s" % ("yes" if _o6 is None else "no"))
print("I6_OK=%s" % ("yes" if _pair_ok(_c6, _o6) else "no"))
print("I6_CTX_RECOVERED=%s" % ("yes" if isinstance(_c6, int) and _c6 > 1 else "no"))
print("I6_VIA_CORRECTION=%s" % ("yes" if "context corrected to" in _n6 else "no"))
print("I6_VIA_FALLBACK=%s" % ("yes" if "fell back to the conservative estimate" in _n6 else "no"))
# ...and a correction to a SMALL-BUT-VIABLE context (peers agree on 32768) must
# still be carved AS 32768, never inflated up to the unknown floor — inflating
# it would re-introduce the opposite 400 (a window wider than the endpoint).
i6b = cat(("acc", "v/x", 1000000, 16384), ("acc", "v/x:free", 1000000, 262144),
          ("q1", "v/x", 32768, 4096), ("q2", "v/x", 32768, 4096),
          ("q3", "v/x", 32768, 4096))
_c6b, _o6b, _ = derive(i6b, "acc", "v/x:free")
print("I6_SMALLVIABLE=%s" % ((_c6b, _o6b),))
print("I6_SMALLVIABLE_OK=%s" % ("yes" if (_c6b == 32768 and _pair_ok(_c6b, _o6b)) else "no"))

# --- Q4: the usability floor must not overstate a provider`s own catalog ----
# `inference` is the provider cited as the motivating case: p10 4000, median
# 16000, yet the 65536 floor applied unclamped with 7 of its 9 tool-call rows
# below it -- a ~61440 input window against endpoints that may serve 4000.
narrow = {"m%d" % i: {"id": "m%d" % i, "tool_call": True,
                      "limit": {"context": c, "output": 1024}}
          for i, c in enumerate([4000, 4000, 8000, 16000, 16000, 32768, 131072])}
print("Q4_NARROW=%s" % R._conservative_unknown_context(narrow))
wide = {"m%d" % i: {"id": "m%d" % i, "tool_call": True,
                    "limit": {"context": c, "output": 1024}}
        for i, c in enumerate([8000, 32768, 200000, 200000, 262144])}
print("Q4_WIDE=%s" % R._conservative_unknown_context(wide))
# On a two-row pool the lower median IS the minimum, so the clamp must NOT
# apply -- otherwise one 480-token image endpoint alone decides the estimate
# and drags a provider that also serves a 2M flagship below usability.
pair = {"img": {"id": "img", "tool_call": True, "limit": {"context": 480, "output": 480}},
        "big": {"id": "big", "tool_call": True, "limit": {"context": 2000000, "output": 16384}}}
print("Q4_PAIR=%s" % R._conservative_unknown_context(pair))
' "$SCRIPTS_DIR")"
_adj() { printf '%s\n' "$_ADJ" | sed -n "s/^$1=//p"; }

it "C1: the accused provider does not vote in its own trial"
assert_eq "1000000" "$(_adj C1_CTX)" "one peer cannot sentence a 1M window to 8192"
assert_eq "no" "$(_adj C1_CORROBORATED)" "no correction is claimed when none was earned"
assert_eq "1000000" "$(_adj C1_TWOPEERS_CTX)" "two peers still leave one peer deciding alone — not enough"
assert_eq "262144" "$(_adj C1_THREEPEERS_CTX)" "three independents, a majority low, DO earn the correction"
assert_eq "1000000" "$(_adj C1_SELFQUORUM_CTX)" "the accused cannot make up the quorum that convicts it"
assert_eq "262144" "$(_adj C1_SELFACQUIT_CTX)" "nor cast the ballot that acquits it"

it "C2: the vote aggregates by lower median, not by minimum or maximum"
# This is the assertion the whole round-2 suite lacked. 80000 is neither the
# minimum (16000) nor the maximum (262144) of the pool, so mutating the
# aggregation in either direction changes this number.
assert_eq "80000" "$(_adj C2_MEDIAN)" "5-provider pool: lower median 80000, not min 16000 / max 262144"
assert_eq "80000" "$(_adj C2_MEDIAN4)" "4-provider pool: LOWER of the two middles, not min 16000 / max 262144"

it "I1: output==context is the output mislabel, not evidence against the context"
assert_eq "131072" "$(_adj I1_CTX)" "an out==ctx row is not adjudicated even with 4 low peers"
assert_eq "262144" "$(_adj I1_STILL_ADJUDICATES)" "out<ctx, the shape it was built for, still adjudicates"

it "I2: an output rejected as unusable cannot convict a context"
assert_eq "1000000" "$(_adj I2_CTX)" "output=262144.7 is not a cap and not a witness either"

it "I3: models sharing a last segment across vendors are not the same model"
assert_eq "1000000" "$(_adj I3_CTX)" "beta/gamma/delta turbo do not sentence alpha/turbo"
assert_eq "262144" "$(_adj I3_BARE_STILL_VOTES)" "a bare id still corroborates a vendored one"

it "I4: corroboration cannot detect a genuinely throttled free tier (known blind spot)"
assert_eq "1000000" "$(_adj I4_THROTTLED_FREE_NOT_CAUGHT)" "peers describe the PAID tier, so a real throttle is invisible here"

it "I5: a context too small to carve a cap from never yields a capless pair"
assert_eq "(128000, 8192)" "$(_adj I5_PAIR)" "context=1 falls back to the conservative pair, not (1, None)"

it "I6: a corroboration correction to a SUB-VIABLE context never yields a capless pair (round-4 fail-open)"
# FAILS before the fix (derive_limits returned (1, None)); passes after. The
# raw-catalog MIN_VIABLE_CONTEXT guard did not re-cover `ctx = corroborated`.
assert_eq "no"  "$(_adj I6_CAPLESS)"       "the resolved pair is NEVER (ctx, None)"
assert_eq "yes" "$(_adj I6_OK)"            "0 < max_output < context_limit, both positive ints"
assert_eq "yes" "$(_adj I6_CTX_RECOVERED)" "the sub-viable context (1) is recovered to a real window, not kept at 1"
assert_eq "yes" "$(_adj I6_VIA_CORRECTION)" "it genuinely went THROUGH the corroboration-correction branch"
assert_eq "yes" "$(_adj I6_VIA_FALLBACK)"  "and THROUGH the viability fallback, not some unrelated path"
assert_eq "yes" "$(_adj I6_SMALLVIABLE_OK)" "a small-but-viable correction (32768) is carved, NOT inflated to the floor"

it "Q4: the usability floor never overstates a provider's own distribution"
assert_eq "16000" "$(_adj Q4_NARROW)" "a narrow provider gets its median, not the 65536 floor"
assert_eq "65536" "$(_adj Q4_WIDE)" "a provider whose median clears the floor still gets 65536"
assert_eq "65536" "$(_adj Q4_PAIR)" "a 2-row pool has no median to speak of; the floor stands"

it "a context value never lands in the output slot"
for _kv in LEAKY_API_KEY TWIN_API_KEY HONEST_API_KEY; do
  _c="$(rfield "$TGOUT" "$_kv" context_limit)"
  _o="$(rfield "$TGOUT" "$_kv" max_output)"
  _lt=0; [ "$_o" -lt "$_c" ] && _lt=1
  assert_eq 1 "$_lt" "$_kv: max_output ($_o) < context_limit ($_c)"
  _ne=1; [ "$_o" = "$_c" ] && _ne=0
  assert_eq 1 "$_ne" "$_kv: max_output is not the context value verbatim"
done

it "derived input floor + output cap fits inside the real context window"
for _kv in LEAKY_API_KEY TWIN_API_KEY HONEST_API_KEY; do
  _c="$(rfield "$TGOUT" "$_kv" context_limit)"
  _o="$(rfield "$TGOUT" "$_kv" max_output)"
  _fits=0; [ $(( TG_FLOOR + _o )) -le "$_c" ] && _fits=1
  assert_eq 1 "$_fits" "$_kv: ${TG_FLOOR}+${_o} <= ${_c}"
done

it "the impossible context==output row is repaired rather than trusted"
assert_eq "262144" "$(rfield "$TGOUT" TWIN_API_KEY context_limit)" "twin keeps its (correct) context"
assert_eq "102144" "$(rfield "$TGOUT" TWIN_API_KEY max_output)" "twin's output no longer equals its context"

it "a credible large output budget is NOT collapsed (no over-correction)"
# The repair must be targeted: a genuine {context:1048576, output:131072} row
# keeps its wide window. An earlier draft that distrusted every output above
# the CLI ceiling shrank this to a 131072 window and crippled the alias.
assert_eq "1048576" "$(rfield "$TGOUT" HONEST_API_KEY context_limit)" "honest keeps its full 1M window"
assert_eq "128000" "$(rfield "$TGOUT" HONEST_API_KEY max_output)" "honest output clamped to the CLI ceiling only"

# --- the launch-time half: lib.sh's guards, extracted verbatim -------------
_GUARD_SRC="$(awk '/cma-token-guards:begin/{f=1;next} /cma-token-guards:end/{exit} f' "$SCRIPTS_DIR/lib.sh")"
it "the token-guard block is extractable from lib.sh"
_gs=0; [ -n "$_GUARD_SRC" ] && _gs=1
assert_eq 1 "$_gs" "guard source found between the sentinels"

# Runs the SHIPPED guard arithmetic and echoes "<window> <maxout>".
_guard() { # _guard CTX OUT
  CMA_PROVIDER_CONTEXT_LIMIT="$1"
  CMA_PROVIDER_MAX_OUTPUT="$2"
  unset CLAUDE_CODE_AUTO_COMPACT_WINDOW CLAUDE_CODE_MAX_OUTPUT_TOKENS
  eval "$_GUARD_SRC"
  printf '%s %s\n' "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" "${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-}"
}

it "an input guard is ALWAYS exported when the context is known (fail-open regression)"
# The old gate skipped the export whenever context > 200000, leaving exactly
# the big-window providers unguarded. Every one of these must now export.
for _ctx in 200001 262144 1000000 1048576; do
  read -r _w _o <<<"$(_guard "$_ctx" "")"
  _has=0; [ -n "$_w" ] && _has=1
  assert_eq 1 "$_has" "context=$_ctx exports an auto-compact window (got '$_w')"
done

it "an output cap is ALWAYS exported when the context is known"
# Leaving it unset is not neutral: Claude Code then reserves its own 128000
# default, which is what overflowed the 262144 window in the live failure.
for _pair in "262144 262144" "262144 " "1000000 262144"; do
  set -- $_pair
  read -r _w _o <<<"$(_guard "$1" "${2:-}")"
  _has=0; [ -n "$_o" ] && _has=1
  assert_eq 1 "$_has" "ctx=$1 out='${2:-}' exports an output cap (got '$_o')"
done

it "exported input window + output cap never exceed the context"
for _pair in "262144 102144" "262144 262144" "200000 32000" "1048576 131072" "131072 8192" "262144 "; do
  set -- $_pair
  read -r _w _o <<<"$(_guard "$1" "${2:-}")"
  _sum=$(( ${_w:-0} + ${_o:-0} ))
  _ok=0; [ "$_sum" -le "$1" ] && _ok=1
  assert_eq 1 "$_ok" "ctx=$1 out='${2:-}': window($_w)+cap($_o)=$_sum <= $1"
done

it "tool-schema budget is reserved: window + tools + output fit the context (openrouter3 live 400, 2026-07-26)"
# Compression-loop guard (2026-07-27): when the raw window (262144-102144-80000
# = 80000) is below CMA_MIN_COMPACT_WINDOW (default 120000), the output cap is
# reduced to make room — ensuring Claude Code's system prompt + tool schemas
# fit without triggering compaction on every request. The provider's own 400:
# "maximum context length is 262144 … requested about 371727 tokens (199347 of
# text input, 70236 of tool input, 102144 in the output)". With the OLD
# derivation the window was 262144-102144 = 160000, so the compact trigger
# (~window-13000 = 147000) let text grow until 147000+70236+102144 = 319380 >
# 262144 — rejected before compaction could ever fire, on the FIRST request.
# The trigger must reserve the tool payload:
# window = context - output - CMA_TOOL_TOKEN_BUDGET (default 80000, covering
# this host's measured 70236). If that leaves the window below 120000, reduce
# the output cap to reclaim the space.
read -r _w _o <<<"$(_guard 262144 102144)"
assert_eq "120000" "$_w" "openrouter3 shape: window raised from 80000 to 120000 by reducing output cap"
_sum=$(( _w + 80000 + _o )); _ok=0; [ "$_sum" -le 262144 ] && _ok=1
assert_eq 1 "$_ok" "window(120000)+tools(80000)+output($_o)=$_sum <= 262144"
# The budget is overridable per host (set in the calling shell; _guard evals
# the shipped block in the same shell).
CMA_TOOL_TOKEN_BUDGET=40000
read -r _w2 _o2 <<<"$(_guard 262144 102144)"
unset CMA_TOOL_TOKEN_BUDGET
assert_eq "120000" "$_w2" "CMA_TOOL_TOKEN_BUDGET=40000 overrides the reserve"
# A context too small to reserve the budget exports NO window (loud upstream
# failure, not a guard that cannot hold). The guard prints "<window> <cap>",
# so an empty window leaves a single field (the cap) on the line.
_res="$(_guard 65536 8192)"
assert_eq "1" "$(wc -w <<<"$_res")" "one field only (the cap) — no window exported for ctx=65536 with an 80000 tool reserve"
assert_eq "8192" "$(awk '{print $1}' <<<"$_res")" "the surviving field is the output cap"

it "unknown limits export no guard at all (honest, not invented)"
read -r _w _o <<<"$(_guard "" "")"
assert_eq "" "$_w" "no context => no auto-compact window"
assert_eq "" "$_o" "no context => no output cap"

it "autocompact safety margin lowers the window when the provider can afford it (thrashing guard)"
# The raw window (context - output - tool_budget) consumes the entire model
# window, leaving zero headroom for the compacted summary. A 24k safety margin
# is reserved so compaction fires earlier and a large file/tool output is less
# likely to refill the context to the limit immediately after a compact.
read -r _w _o <<<"$(_guard 1000000 128000)"
assert_eq "176000" "$_w" "1M ctx: 200000 raw window reduced by 24000 safety margin"
_sum=$(( _w + 80000 + _o )); _ok=0; [ "$_sum" -le 1000000 ] && _ok=1
assert_eq 1 "$_ok" "margin-adjusted window(176000)+tools(80000)+output($_o)=$_sum <= 1000000"

it "safety margin is capped at min-compact-window floor"
# helixagent shape: raw window 141184, min_win 120000 -> max margin 21184.
# The default 24000 margin is capped so the window never drops below min_win.
read -r _w _o <<<"$(_guard 229376 8192)"
assert_eq "120000" "$_w" "helixagent shape: margin capped at min_win floor"

it "tight providers keep their window unchanged (no margin to give)"
# opencode shape: raw window 71808 is already below min_win, so no margin.
read -r _w _o <<<"$(_guard 160000 8192)"
assert_eq "71808" "$_w" "opencode shape: below-min_win window unchanged by margin"

it "CMA_AUTO_COMPACT_SAFETY_MARGIN=0 disables the margin"
CMA_AUTO_COMPACT_SAFETY_MARGIN=0
read -r _w _o <<<"$(_guard 1000000 128000)"
unset CMA_AUTO_COMPACT_SAFETY_MARGIN
assert_eq "200000" "$_w" "margin disabled -> raw capped window restored"

it "invalid safety margin values are treated as 0"
CMA_AUTO_COMPACT_SAFETY_MARGIN=abc
read -r _w _o <<<"$(_guard 1000000 128000)"
unset CMA_AUTO_COMPACT_SAFETY_MARGIN
assert_eq "200000" "$_w" "non-numeric margin treated as 0"


summary
