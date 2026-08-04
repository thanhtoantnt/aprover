# Direct Kani Verification of ylong_json

Direct bounded-model-checking with **Kani 0.67.0** — no bmc_agent / LLM in the loop.
All proofs are `#[cfg(kani)]`-gated, fully inert under normal `cargo build`/`cargo test`
(verified: 119 unit tests still pass).

## How to run

```bash
cd ~/oh-rust/commonlibrary_rust_ylong_json
cargo kani                    # all proofs (per-harness bounds)
cargo kani --harness <name>   # one proof
```

## Soundness Finding — `char::from_u32_unchecked` UB in `read_error_char`

**`states::read_error_char`** (the error-path UTF-8 decoder, called via the
`unexpected_character!` macro) assembles a `u32` from 1–4 raw input bytes using
UTF-8 continuation-bit logic, then calls **`unsafe { char::from_u32_unchecked(ch) }`**
**without validating** that `ch` is a valid Unicode scalar.

**Kani proof** (`proof_utf8_assembly_can_produce_surrogate`, `kani::cover!` SATISFIABLE)
shows the 3-byte path **can** produce a surrogate-range value:

```
bytes [0xED, 0x20, 0x00]  →  U+D800  (a UTF-16 surrogate, 0xD800–0xDFFF)
```

`char::from_u32_unchecked(0xD800)` is **undefined behaviour** per the Rust reference
(`char` must hold a valid Unicode scalar; surrogates are excluded).

- **Trigger**: malformed JSON input containing raw byte `0xED` at an unexpected
  position (e.g. not inside a valid string). The parser hits `unexpected_character!`,
  which calls `read_error_char` → assembles the surrogate → UB.
- **Root cause**: the function trusts UTF-8 continuation bytes without checking
  they're valid continuation bytes (0x80–0xBF) and doesn't validate the final scalar.
- **Severity**: low (error-path only, silent UB, no memory corruption) — but it IS UB.
- **Fix**: replace `char::from_u32_unchecked(ch)` with `char::from_u32(ch)` (returns
  `Option`, None on invalid scalar) and handle the None case.

## Proofs verified — 8/8 SOUND

### Number API (functional correctness)

| Proof | Property | Verdict |
|---|---|---|
| `proof_number_try_as_u64` | only `Unsigned` converts to u64 | ✓ |
| `proof_number_try_as_i64_unsigned_bound` | Unsigned→i64 iff u ≤ i64::MAX | ✓ |
| `proof_number_try_as_i64_signed` | Signed always converts to i64 | ✓ |
| `proof_number_try_as_f64_all` | all variants convert to f64 | ✓ |
| `proof_number_eq_unsigned` | equal u64 numbers compare equal | ✓ |

### JsonValue + soundness

| Proof | Property | Verdict |
|---|---|---|
| `proof_jsonvalue_predicates_exclusive` | `new_null` → exactly one is_* flag | ✓ |
| `proof_jsonvalue_number_roundtrip` | Number→JsonValue→is_number | ✓ |
| `proof_utf8_assembly_can_produce_surrogate` | `read_error_char` 3-byte path reaches surrogate range | ⚠ **UB confirmed** |

## Limitation: full parser too complex for bounded Kani

The recursive JSON descent (`Array`/`Object` nesting) + heap `Vec` growth makes
`JsonValue::from_text(arbitrary_bytes)` intractable for Kani within reasonable time
(the SliceReader position loop + recursive value descent blow up the unwind).
Verified the Number API, JsonValue predicates, and isolated the UTF-8 soundness
concern via pure-logic replication instead.

## Files
- `src/kani_proofs.rs` — all proofs (`#[cfg(kani)]`, inert)
- `src/lib.rs` — 4-line module registration
