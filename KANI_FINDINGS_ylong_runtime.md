# Direct Kani Verification of commonlibrary_rust_ylong_runtime

Direct bounded-model-checking with **Kani 0.67.0` — no bmc_agent / LLM in the loop.

## Repo status

The workspace has 5 crates. Build status under the current toolchain:

| Crate | Builds? | Kani proofs |
|---|---|---|
| `ylong_io` | ✓ | 4 (Interest bit-ops) — in-crate, `#[cfg(kani)]` |
| `ylong_signal` | ✓ | 3 (spin lock version arithmetic) — standalone |
| `ylong_runtime` | ✗ | 3 (xorshift PRNG) — standalone (crate has pre-existing lint errors) |
| `ylong_runtime_macros` | ✓ | — (proc-macro, not directly verifiable) |
| `ylong_ffrt` | ✗ | — (native FFI build) |

`ylong_runtime` fails to compile (`implicit autoref creates a reference to the
dereference of a raw pointer` ×3) — a pre-existing issue with the newer Rust
toolchain, unrelated to verification. Its `fastrand` xorshift* logic was verified
via a standalone replication instead.

## Results — 10 proofs, all SOUND (0 bugs)

### ylong_io — Interest bit operations (4 proofs, in-crate)

`Interest::add` uses `unsafe { NonZeroU8::new_unchecked(self.0.get() | other.0.get()) }`.

| Proof | Property | Verdict |
|---|---|---|
| `proof_interest_add_nonzero_sound` | OR of two non-zero u8 is non-zero → `new_unchecked` is sound | ✓ |
| `proof_interest_flag_tests` | `is_readable`/`is_writable` correctly test the flag bits | ✓ |
| `proof_interest_readable_or_writable` | `READABLE \| WRITABLE` sets both flags | ✓ |
| `proof_interest_add_idempotent` | `i.add(i) == i` (OR idempotency) | ✓ |

### ylong_runtime — fastrand xorshift* PRNG (3 proofs, standalone)

| Proof | Property | Verdict |
|---|---|---|
| `proof_step_no_panic` | xorshift step: no overflow/panic for any u64 | ✓ |
| `proof_nonzero_state_preserved` | non-zero state never maps to zero (no PRNG collapse) | ✓ |
| `proof_zero_is_absorbing` | zero state is absorbing (why `seed()` loops until non-zero) | ✓ |

### ylong_signal — SpinningRwLock version arithmetic (3 proofs, standalone)

| Proof | Property | Verdict |
|---|---|---|
| `proof_versions_always_distinct` | writer always swaps to the other slot (double-buffering) | ✓ |
| `proof_version_in_range` | reader's slot index is always valid {0,1} | ✓ |
| `proof_holder_count_boundary` | overflow guard catches MAX before wrap-to-0 | ✓ |

## Limitations

- **Spin lock full correctness** (reader/writer exclusion, use-after-free freedom)
  is a thread-interleaving property — Kani's sequential model cannot verify it.
  Only the pure modular-arithmetic invariants were checked.
- **`ylong_io` sys module** (epoll/socket FFI) — foreign functions, not
  model-checkable.

## Files
- `ylong_io/src/interest.rs` — 4 in-crate proofs (58 lines, `#[cfg(kani)]`)
- `~/oh-rust/kani_standalone/fastrand_xorshift.rs` — 3 standalone proofs
- `~/oh-rust/kani_standalone/spin_rwlock_version.rs` — 3 standalone proofs
