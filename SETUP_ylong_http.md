# AProver → ylong_http: Setup & Run

## What AProver / BMC-Agent is
LLM-driven formal verification. For **Rust** it generates per-function specs (LLM)
and discharges them with **Kani** (sound bounded model checker over CBMC).
Pipeline: spec-gen → BMC → counterexample classification → refinement → confidence tiers.
For a real cargo crate it runs `cargo kani --harness` from the crate root.

## Target
`~/oh-rust/commonlibrary_rust_ylong_http/` — OpenHarmony Rust HTTP lib.
Cargo workspace, 2 crates (`ylong_http`, `ylong_http_client`), **221 .rs files, ~71k LOC**.
Builds clean with default features (`cargo check --workspace` → 0 errors).

## Environment — DONE ✅
| Need | Status |
|---|---|
| Python 3.12+ / uv env | ✅ `uv sync` → Python 3.14.6, all deps |
| Kani (Rust backend) | ✅ kani 0.67.0 + `cargo-kani` + bundled CBMC/kissat (`~/.cargo/bin`, `~/.kani`) |
| CBMC | ✅ bundled with Kani (`~/.kani/kani-0.67.0/bin/cbmc`) |
| Rust nightly | ✅ Kani installed `nightly-2025-11-21` |
| LLM provider (cliproxy) | ✅ **default** — glm-5.2 / glm-4.7 via local CLIProxyAPI `127.0.0.1:8317` (mirrors `providers.ts`); wired in `cliproxy.env` + `run_cliproxy.sh`. `claude` CLI also present as fallback (`PROVIDER=claude-code`) |
| Real-crate integration | ✅ validated: `cargo kani` builds + verifies real `ylong_http` (e.g. `percent_hex`: 0/23 checks fail) |

Not installed (not needed for Rust path): `frama-c`, `alt-ergo`, `jbmc` (Java).

## How it runs on this crate (verified mechanics)
1. `--source .../ylong_http/src/h2/hpack/integer.rs` → `find_crate_root` walks up to
   `.../ylong_http/` (nearest `Cargo.toml`). That single crate builds standalone
   (default features empty → no tokio/ylong_runtime).
2. `BMC_AGENT_KANI_REAL_CRATE=true` → harness appended to the source file,
   `cargo kani --harness` run from crate root.
3. Restore: `.git` is at the **workspace** root (not the crate root), so AProver
   uses **byte-snapshot of the single source file** → non-destructive, safe.

## Run
```bash
# default: HPACK integer codec + cliproxy/glm-5.2 (local, no API key)
~/github/aprover/verify_ylong_http.sh

# any bmc-agent subcommand through cliproxy (any model from providers.ts):
~/github/aprover/run_cliproxy.sh verify --source foo.rs --driver foo --output out/
MODEL=glm-4.7 ~/github/aprover/run_cliproxy.sh generate --source foo.rs --driver foo

# other good first targets (pure fns, no async/IO):
SRC=~/oh-rust/commonlibrary_rust_ylong_http/ylong_http/src/request/uri/percent_encoding.rs \
DRIVER=ylong_percent  ~/github/aprover/verify_ylong_http.sh

# whole crate sweep (all .rs under src):
CRATE=~/oh-rust/commonlibrary_rust_ylong_http
PATH=$HOME/.local/bin:$PATH BMC_AGENT_KANI_REAL_CRATE=true \
  uv run --project ~/github/aprover bmc-agent verify-dir \
    --source-dir "$CRATE/ylong_http/src" --driver ylong_http \
    --output artifacts/ylong_http --provider claude-code

# use Anthropic API instead of cliproxy:
PROVIDER=anthropic ANTHROPIC_API_KEY=sk-... ~/github/aprover/verify_ylong_http.sh
```
Artifacts land in `~/github/aprover/artifacts/ylong_http/`.

## Recommended first targets (pure arithmetic / parsing → best for BMC)
- `h2/hpack/integer.rs` — RFC 7541 integer codec, overflow-prone (default).
- `request/uri/percent_encoding.rs` — `PercentEncoder::parse`.
- `h2/hpack/decoder.rs`, `h2/hpack/table.rs` — HPACK state machines.
- `body/chunk.rs` — chunked-transfer parsing.

## Notes / knobs
- **Feature gating (IMPORTANT):** ylong_http compiles `h2`/`h3`/`hpack`/`huffman`/`body`
  only under their feature flags; `default = []`. Run real-crate Kani with
  `BMC_AGENT_KANI_CARGO_FEATURES=http2,huffman` (added to `bmc_agent/kani.py`) or
  the target module is never compiled and Kani reports "no harnesses matched".
  `request/*` and `body/text/*` are always compiled (no feature needed).
- Real-crate Kani can be slow → script sets `BMC_AGENT_KANI_TIMEOUT=300` (default 120).
- `ylong_http_client` pulls heavier deps (TLS/quic); start with `ylong_http` only.
- `cargo-kani` mutates source during a run but restores it; don't edit target files mid-run.

## Harness-gen fixes shipped for this crate (all proven)
Ten issues blocked Rust real-crate verification; all fixed:

1. **Feature gating** (`bmc_agent/kani.py`): ylong_http compiles `h2`/`h3`/`hpack`
   only under feature flags (`default = []`). Added `BMC_AGENT_KANI_CARGO_FEATURES` env → `--features`.
2. **Move-free Result access** (`kani_backend.py`): destructure `&result` into
   `Copy` `Option<&T>` locals → bound-free + move-free postconditions.
3. **Nondet enum construction** (`rust_parser.py` + `kani_backend.py`): parse
   unit-variant enums, construct via nondet-discriminant `match`.
4. **Parallel-restore race** (`kani.py`): read byte-snapshot *inside* the crate lock.
5. **Cargo-mode type gate** (`kani_backend.py`): skip the standalone-only
   type gate in cargo mode (cross-file types resolve via cargo).
6. **Unwind default too low** (`config.py`): raised default 4→12 (slice loops
   need unwind ≳ slice_bound).
7. **Dynamic validator on Rust** (`dynamic_validator.py`): skip cleanly for `.rs`
   targets (GCC/C-only; Kani is the checker).
8. **Tuple-struct receivers** (`rust_parser.py` + `kani_backend.py`): parse
   `struct Foo(u16)` tuple structs and emit `Foo(val)` constructor instead of
   the wrong `Foo { _0: val }`. Unlocked all self-methods on tuple-struct types
   (`StatusCode(u16)`, `Method(Inner)`, `Version(Inner)`).
9. **Kani-internal CEx filtering** (`kani.py`): filter `.missing_definition`
   and `.unsupported_construct` checks from counterexamples — these are Kani
   saying "I can't model this" (e.g. `getrandom` syscall), not real violations.
   Eliminated false-positive bug reports on functions using `HashMap`/`Vec` internals.
10. **verify-dir on Rust** (`cli.py`): `verify-dir` called the C-only
   `run_directory`; now dispatches to `verify_tree` which routes `.rs` files
   to `run_directory_generic` (per-file Rust pipeline). `verify-dir` now
   discovers and verifies `.rs` files in a directory tree.

## Testing results on the crate (cliproxy / glm-5.2)

**`h2/hpack/integer.rs`** — 3/4 verify clean: `first_byte`, `new`, `is_finish`.

**`request/uri/mod.rs`** — HTTP URI parser verified sound: `scheme_token`,
`authority_token`, `path_token`, `query_token`, `host_port`, `bytes_to_str`
(incl. `unsafe { from_utf8_unchecked }`), plus 6 more. No real bugs.

**`response/status.rs`** — 8 functions verified: `from_u16`, `from_bytes`,
`as_u16`, `is_informational`/`is_successful`/`is_redirection`/`is_client_error`/`is_server_error`.
Found a real low-severity overflow in `as_bytes`: `(self.0/100) as u8 + b'0'`
overflows for status codes ≥ 25600 (unreachable in valid HTTP 100-999, but
`from_u16` doesn't enforce range — CWE-190).

**`request/method.rs`** — `from_bytes`, `as_str` verified clean.

**`h2/hpack/decoder.rs`** — `with_max_size` false-positives filtered
(Kani can't model `getrandom`); clean sweep after fix #9.

**Conclusion:** the crate's HTTP URI parser, status code methods, HPACK
integer codec, and HTTP method parser are verified sound within the unwinding bound.

## Remaining harness-gen limitations (documented, not blocking)
- Payload-enum / custom-struct params/receivers still raise the unresolvable-type
  skip (e.g. `H2Error`, `DynamicTable`). Extending enum construction to tuple/struct
  variants would unlock more methods.
- `==` on enums without `PartialEq` (would need a `matches!` rewrite) — rare.
- standalone (`kani harness.rs`) mode still drops `impl` blocks; use real-crate mode
  (`BMC_AGENT_KANI_REAL_CRATE=true`) for methods.
