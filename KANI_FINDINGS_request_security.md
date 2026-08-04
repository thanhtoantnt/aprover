# Direct Kani Verification of request_request + security_asset

Direct bounded-model-checking with **Kani 0.67.0** — no bmc_agent / LLM in the loop.
Neither repo builds as a workspace (git dependencies unavailable offline), so
all proofs are **standalone extractions** of the verifiable pure logic
(`kani file.rs`, no cargo). Runtime execution + concrete reasoning confirm the
production logic where Kani's SIMD modeling blocks direct verification.

## request_request — `common/utils/src/file_control.rs` (5 proofs)

Security-critical path validation (path-traversal guard + app-base membership).

### `belong_app_base` — sound, with a prefix-confusion weakness

| Proof | Property | Verdict |
|---|---|---|
| `proof_belong_app_base_accepts_known` | EL1/EL2/EL5 base prefixes accepted | ✓ |
| `proof_belong_app_base_rejects_outside` | non-base paths rejected | ✓ |
| `proof_belong_app_base_prefix_confusion` | `cover!` SAT — sibling dir misreported | ⚠ weakness |

**Prefix-confusion weakness**: `belong_app_base` uses `starts_with` without a
trailing separator, so `/data/storage/el1/base_evil_sibling` is reported as
"belongs to base". Low severity (depends on how the predicate is used), but a
classic prefix-matching pitfall.

### `check_standardized_path` — logic correct, Kani-blocked by SIMD modeling

The function rejects `.`/`..` segments correctly (concrete battery passes), but
direct symbolic verification is **blocked**: it calls `NOT_ALLOWED.contains(&segment)`
and `path.contains("//")`, both dispatching to `<[T]>::contains`/`str::contains`
→ SIMD-accelerated `memchr` (`TwoWaySearcher`). Kani cannot model the SIMD
intrinsics (`Mask::from_int_unchecked`), producing 2700+ undetermined checks.

The security **intent** is verified on a faithful SIMD-free replica
(`proof_traversal_detected_iff_segment_present`: for any bounded ASCII buffer,
a `.`/`..` segment is detected iff present) + a concrete battery
(`proof_posix_replica_concrete`). Runtime confirms the production function is correct.

## security_asset — arithmetic invariants (5 proofs + 1 smell)

### `ChallengeStore` time arithmetic (anti-replay store) — sound

| Proof | Property | Verdict |
|---|---|---|
| `proof_remaining_valid_no_underflow` | valid branch: `expire - now` never underflows | ✓ |
| `proof_expired_ago_no_underflow` | expired branch: `now - expire` never underflows | ✓ |
| `proof_max_remaining_no_underflow` | `saturating_sub` is total (no underflow for any inputs) | ✓ |

The branch structure guarantees soundness: the valid branch runs only when
`expire >= now`, the expired branch only when `expire < now`.

### `Counter` — decrease guarded, increase not

| Proof | Property | Verdict |
|---|---|---|
| `proof_counter_decrease_never_underflows` | decrease from 0 stays 0 | ✓ |
| `proof_counter_inc_dec_roundtrip` | inc/inc/dec/dec returns to start | ✓ |

**Smell (not a proof)**: `Counter::increase` has `self.count += 1` with **no
overflow guard** (decrease IS guarded). Under a debug build, `count == u32::MAX`
then `increase()` **panics** (arithmetic overflow); in release it wraps to 0.
Only reachable after 2³² uses of the global singleton — low severity, but the
guard asymmetry is a real smell.

## `crypto.rs` — checked, sound (not a bug)

`exec_crypt` guards `cipher.len() <= (TAG_SIZE + NONCE_SIZE)` before
`cipher.len() - TAG_SIZE - NONCE_SIZE` — the `<=` correctly prevents underflow
(subtraction yields ≥1). The module is otherwise FFI wrappers around HUKS
(Huawei Universal KeyStore) C calls — not model-checkable.

## Files
- `~/oh-rust/kani_standalone/file_control.rs` — 5 proofs
- `~/oh-rust/kani_standalone/security_asset_arith.rs` — 5 proofs + Counter smell note
