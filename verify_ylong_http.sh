#!/usr/bin/env bash
# Run AProver / BMC-Agent against the OpenHarmony ylong_http Rust crate.
#
# Prep already done in this env:
#   - uv env synced (Python 3.14, aprover deps)        -> `uv sync`
#   - kani 0.67.0 + cargo-kani + bundled CBMC installed -> ~/.cargo/bin, ~/.kani
#   - real-crate `cargo kani` path validated on ylong_http (778 checks pass)
#
# LLM backend: defaults to `cliproxy` (glm-5.2, no API key — local CLIProxyAPI
# at 127.0.0.1:8317, config in cliproxy.env, mirrors providers.ts).
#   Other backends:  PROVIDER=claude-code ./verify_ylong_http.sh
#                    PROVIDER=anthropic ANTHROPIC_API_KEY=sk-... ./verify_ylong_http.sh
set -euo pipefail

cd "$(dirname "$0")"

# kani/cargo-kani live here; ensure resolvable for the cargo subcommand too.
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

# Run Kani via `cargo kani --harness` from the crate root (real-crate mode).
export BMC_AGENT_KANI_REAL_CRATE=true

# Feature-gated modules: ylong_http compiles h2/h3/hpack only under their feature
# flag (default features are EMPTY). Without this, cargo kani never compiles the
# target module -> "no harnesses matched". Pick per target:
#   h2/hpack/*        -> http2,huffman   (h2 pulls in huffman)
#   h3/*              -> http3,huffman
#   request/*, body/text/*  -> (none; always compiled)
export BMC_AGENT_KANI_CARGO_FEATURES="${BMC_AGENT_KANI_CARGO_FEATURES:-http2,huffman}"

CRATE="$HOME/oh-rust/commonlibrary_rust_ylong_http"
OUT="${OUT:-artifacts/ylong_http}"
PROVIDER="${PROVIDER:-cliproxy}"

# Default target: HPACK RFC-7541 integer codec — pure arithmetic, classic
# overflow-hunt. Override:  SRC=.../percent_encoding.rs DRIVER=percent ./...
SRC="${SRC:-$CRATE/ylong_http/src/h2/hpack/integer.rs}"
DRIVER="${DRIVER:-ylong_http_hpack_int}"

# Real crate can be slow under Kani; lift the per-harness timeout.
export BMC_AGENT_KANI_TIMEOUT="${BMC_AGENT_KANI_TIMEOUT:-300}"

# Cliproxy is OpenAI-compatible, so route via AProver's existing "openai"
# provider. cliproxy.env sets base_url/api_key/model (no code change needed).
if [ "$PROVIDER" = cliproxy ]; then
  # shellcheck source=cliproxy.env
  source ./cliproxy.env
  BMC_CLI_PROVIDER=openai
else
  BMC_CLI_PROVIDER="$PROVIDER"
fi

# --no-plan: this file's only no-arg roots are #[cfg(test)] unit tests, so the
# PlanAgent anchors on a test fn and the only_functions filter then matches
# nothing in the non-test set. Legacy mode verifies every generated spec.
EXTRA="${EXTRA:- --no-plan}"
echo ">> AProver verify  src=$SRC  driver=$DRIVER  backend=$PROVIDER (model ${BMC_AGENT_LLM_MODEL:-default})"
uv run bmc-agent verify \
  --source "$SRC" \
  --driver "$DRIVER" \
  --output "$OUT" \
  --provider "$BMC_CLI_PROVIDER" \
  $EXTRA
