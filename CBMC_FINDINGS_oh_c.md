# Direct CBMC Verification of ~/oh-c/

Direct bounded-model-checking with **CBMC 6.8.0** (bundled with Kani) — no bmc_agent / LLM in the loop.
Toolchain: `goto-cc` compiles C → GOTO, `cbmc` verifies. All proofs are standalone extractions
(the OpenHarmony crates need system headers unavailable offline).

## How to run

```bash
export PATH="$(dirname ~/.kani/kani-*/bin/cbmc):$PATH"
cd ~/oh-c/cbmc_standalone
goto-cc --function main <file>.c -o <file>.goto
cbmc [--unwind N] <file>.goto
```

## Repos surveyed

19 C repos. Most are Linux-kernel glue (skb/rcu/hlist) or HAL wrappers. Verified the
self-contained utility functions, codecs, parsers, and security primitives.

## CBMC techniques learned from the cbmc repo (`~/github/cbmc/`, develop branch)

Studied the official CBMC manual (`doc/cprover-manual/`) and regression tests
(`regression/contracts-dfcc/`) to improve the testing methodology. Key techniques
adopted this round:

### 1. Compile & verify REAL production files (no replicas) — `static-functions.md`

The biggest methodology upgrade. Previously I hand-wrote standalone replicas of
each function. The manual's workflow lets you compile the **actual production
`.c`** to a GOTO object, link with a thin harness, and verify the real code:

```sh
goto-cc -c real_production.c -o real.o              # real file → GOTO object
goto-cc harness.c real.o -o combined.goto           # link thin harness
cbmc --function harness combined.goto               # verify real code
```

Applied to three real files (previously replica-only):
- `developtools_syscap_codec/src/endian_internal.c` — real `HtonlInter`/`NtohlInter`
- `communication_sfc_newip/src/common/nip_checksum.c` — real `_nip_check_sum` + fold loop
- `security_deviceauth/common_lib/impl/src/string_util.c` — real `ByteToHexString`/`HexStringToByte`

For files with deep dependency trees (HDF framework), minimal stub headers are
created; `--generate-havocing-body` / `--remove-function-body` can auto-stub
called functions. `--export-file-local-symbols` exposes `static` functions.

### 2. `--unwinding-assertions` — sound loop verification

**Critical correctness fix**: `--unwind N` *without* `--unwinding-assertions` is
**unsound** (per `unsound_options.md`) — CBMC may report SUCCESS for a bug that
only manifests beyond N iterations. All prior proofs were re-run with
`--unwinding-assertions` and confirmed **SOUND** (the unwind bounds were sufficient).

### 3. `goto-analyzer` — unbounded abstract interpretation

Over-approximating interpreter (vs cbmc's under-approximation). Proves
properties true for **ALL** iterations without unwinding. Result classes:
`pass` / `fail if reachable` / `unknown` (over-approximation imprecise, not a
failure). Ran on `seq_num_check`: 60 pass, 0 fail, 32 unknown — a useful cheap
pre-filter. Timed out on loop-heavy code (nip fold) — best for bounded-loop /
arithmetic-heavy functions.

### 4. `--string-abstraction` (prior round, reused) — real strlen verification

Tracks C strings symbolically. Used to re-confirm the GetDirName and HcStrlen
bugs against the actual `strlen` code (no length-parameter replicas).

### 5. `__CPROVER_loop_invariant` / `--unwindset` (prior round)

Per-loop unwind bounds (`--unwindset [T:]L:B`) and loop-contract annotations.

### Limitation

Building newer CBMC (6.10.0, has `goto-harness` auto-generator + full `--dfcc`
contracts) needs `flex`/`bison` (no sudo). The Kani-bundled 6.8.0 has
cbmc/goto-cc/goto-instrument/goto-analyzer — sufficient for everything except
auto-harness generation and fully modular contract verification.

## Verified against REAL production code (this round)

Using real-file compilation (technique #1), three components previously verified
only via replicas are now verified against the actual production objects:

| File | Function | Property | Verdict |
|---|---|---|---|
| `endian_internal.c` | real `HtonlInter`/`NtohlInter` | roundtrip `ntohl(htonl(x))==x` | ✓ |
| `nip_checksum.c` | real `_nip_check_sum` + fold | carry-fold converges; 40 ptr checks | ✓ |
| `string_util.c` | real `ByteToHexString`/`HexStringToByte` | hex bijection; 60 ptr checks | ✓ |

## Network parser proven safe (this round)

### Real CoAP codec (`coap_codec_comm.c`) — memory-safe against attacker input

Compiled the **real** `coap_codec_comm.c` (with minimal stub headers) and fed a
nondeterministic CoAP packet to `CoapCommParseOptions` via a thin harness. Ran CBMC's
**auto-generated** checks (`--bounds-check --pointer-check --signed-overflow-check
--conversion-check`) — every option/extension parse path verified memory-safe. The manual
review had flagged a missing overflow guard on `*pos + extendLen` in `CoapCommParseExtension`,
but it is dominated by the caller's invariant `*pos < raw->len` (real buffer length), so it is
not reachable. **A network-facing parser proven safe against arbitrary packets** — a
meaningful positive result.

## Methodology: analyze-then-confirm

The most bug-efficient workflow this round (sanctioned by the user): manually read the code to
spot a *candidate* bug (cheap, targeted), then write a minimal CBMC proof that **confirms** or
**refutes** it (rigorous, no false positives). Pure blind symbolic exploration is expensive;
manual review alone can be wrong. The combination found Bug 4 in minutes: reading
`BuildCloudOption` noticed the SEQ write had no bit guard that the calc had, then `cloud_option_count.c`
proved the disagreement for all bitmaps. Several other manual candidates were **refuted** by
CBMC (saved by preconditions or `ClibMalloc(.,0)` zero-fill) — the tool kept the review honest.

## Soundness re-confirmed (this round)

All prior bounded proofs re-run with `--unwinding-assertions` (sound loop
verification): endian, hex_codec, hdmi_checksum, seq_num_check, deal_format —
all confirmed SOUND (no bugs hiding beyond the unwind bound).

## ⚠ Bugs Found — 2 OOB reads + 1 verified-boot overflow-guard gap + 1 latent heap OOB

Bugs 1-2 are the same class: a `while` loop dereferences a pointer before checking bounds,
reading one byte outside the buffer. Bug 3 is an integer-overflow guard gap. Bug 4 (new) is
a calc/write disagreement found via analyze-then-confirm.

### Bug 4 — `BuildCloudOption` alloc/write count mismatch → latent heap OOB (`communication_iot_connect/core/wifi/application/cloud/biz/m2m_cloud_send.c`)

Found by manual analysis, then **confirmed by CBMC** (`cloud_option_count.c`). The allocation
size and the write count disagree on the SEQ option:

```c
// CloudOptionNumCalc (line 28) — drives the calloc size:
if (UTILS_IS_BIT_SET(option->opBitMap, CLOUD_OPTION_BIT_SEQ_NUM_ID)) ++opNum;  // conditional

// BuildCloudOption (lines 84-91) — the actual writes:
ops[index].option = COAP_OPTION_TYPE_SEQ_NUM_ID;   // NO bit guard — unconditional
...
ops[index++].value.len = sizeof(uint32_t);          // always written
```

When `CLOUD_OPTION_BIT_SEQ_NUM_ID` is clear, the calc returns N but the writer does N+1
`ops[index++]` writes → the final write lands one element past the `IotcCalloc`'d CoAP-option
array → **heap out-of-bounds write**.

**CBMC confirmation** (`cloud_option_count.c`, faithful replica of both counting functions):
- `write_count <= alloc_count` → **FAILURE** (the overflow is reachable)
- witness: without the SEQ bit, writer does exactly `alloc_count + 1` writes → **SUCCESS**

**Severity: latent.** All 9 current callers set the SEQ bit (`m2m_cloud_{sync,psk,authcode,token,
dev_mgr,heartbeat}.c`), so calc==writes today and no overflow fires. The mismatch is a real
contract/implementation inconsistency: a new caller that omits the bit — or guarding the SEQ
write to match the calc — surfaces a heap overflow in CoAP packet construction (network-facing).
Same class as Bug 3 (defense-in-depth gap that doesn't corrupt memory today).

**Fix:** either drop the bit test in `CloudOptionNumCalc` (always count SEQ, matching the write),
or guard the SEQ write in `BuildCloudOption` with the same bit test. Pick one; the two must agree.

### Bug 3 — `_footer_parser` cert-offset overflow guard gap (`startup_hvb/libhvb/src/footer/hvb_footer.c:56`)

```c
size = footer->cert_offset + footer->cert_size + HVB_FOOTER_SIZE;
if (footer->cert_offset < footer->image_size ||
    size < footer->cert_offset + HVB_FOOTER_SIZE ||   // overflow guard
    size > footer->partition_size) {
    return HVB_ERROR_INVALID_FOOTER_FORMAT;
}
```

The overflow guard `size < cert_offset + HVB_FOOTER_SIZE` is **defeated when `cert_offset`
itself is near UINT64_MAX**: then `cert_offset + HVB_FOOTER_SIZE` (104) **wraps to a small
value**, so `size < small` is false even though `size` wrapped. Unlike `image_size`
(bounded above by `partition_size`, keeping its `+ FOOTER` from wrapping), `cert_offset`
has **no upper bound** — only `>= image_size`.

**CBMC witness**: `cert_offset=0xFFFFFFFFFFFFFFBF`, `cert_size=517996505` →
`size` wraps to ~0x1EDFFFEF (< partition_size), accepted as valid.

- **Impact**: defense-in-depth LOGIC gap, NOT memory corruption. The downstream
  `_load_cert` passes the huge offset to `read_partition`, which fails at the I/O layer
  (offset beyond partition). Validation *claims* to reject overflow but doesn't here.
- **Severity**: low (no memory-safety impact; footer validation runs before signature
  verification, so an attacker controlling the partition image can trip it, but the I/O
  layer catches the out-of-range offset).
- **Fix A** (bound cert_offset): add `cert_offset >= partition_size → reject`.
- **Fix B** (sound overflow detect): change `size < cert_offset + HVB_FOOTER_SIZE` to
  `size < cert_offset` (a bare value that cannot itself wrap).
- Both fixes **verified SOUND** by CBMC (`hvb_footer_sizes_fixed.c`).

### Bug 1 — `GetDirName` OOB read (`hiviewdfx_blackbox/blackbox_core.c:58`)

```c
const char *end = path + strlen(path);
while (*end != '/' && end >= path) {   // *end evaluated BEFORE end>=path
    end--;
}
```

The `&&` evaluates `*end` **before** `end >= path`. When the path contains no `/`
(e.g. empty path `""`), `end` decrements to `path - 1` and the next iteration
dereferences `*(path-1)` — a 1-byte out-of-bounds read before the buffer.

**CBMC witness**: `len=0`, `path=""` → reads `*(path-1)`.
**Fix**: `while (end > path && *end != '/')` — check bounds first, use `>` not `>=`
(fixing `>=` alone still forms the UB pointer `path-1` for comparison). Verified SOUND.
**Severity**: low (error-path code, 1-byte read, no memory corruption).

### Bug 2 — `HcStrlen` off-by-one OOB read (`security_device_auth/common_lib/impl/src/hc_types.c:72`)

```c
const char *p = str;
while (*p++ != '\0' && (p - str - 1) < MAX_STR_LEN) {}
return p - str - 1;
```

`*p++` dereferences and increments **before** the bounds check. A non-null-terminated
buffer of exactly `MAX_STR_LEN` bytes reads `str[MAX_STR_LEN]` (one past the scan range)
before the bounds check terminates the loop. The return value IS correctly capped — only
the transient read is OOB.

- `MAX_STR_LEN = 512 * 1024` in production — trigger requires a 512KB+ non-null-terminated string.
**CBMC witness**: `buf[MAX_STR_LEN]` all nonzero → reads `buf[MAX_STR_LEN]`.
**Fix**: index-based loop `for (i=0; i<MAX_STR_LEN; i++) { if (str[i]=='\0') return i; }`. Verified SOUND.
**Severity**: very low (transient 1-byte read, huge trigger threshold).

## Positive Results — verified SOUND

### deal_format bounds (`drivers_hdf_core/.../osal_deal_log_format.c`)

| Proof | Property | Verdict |
|---|---|---|
| `index <= size` | `index` never exceeds `size`; `strncpy_s`/`strcat_s` dest-size args never underflow | ✓ |
| `no OOB write` | all writes to `dest` stay within `[0, size-1]` for any bounded `fmt` | ✓ |

### CoAP option-delta overflow guard (`communication_iot_connect/.../coap_codec_comm.c`)

| Proof | Property | Verdict |
|---|---|---|
| `delta exact` | on accept, `delta += curDelta` is exact (no truncation) | ✓ |
| `delta <= UINT16_MAX` | result fits in uint16 | ✓ |
| `overflow rejected` | sum exceeding u16 is rejected by the guard | ✓ |
| `zero-delta accepted` | no-op delta always accepted | ✓ |

The entire CoAP codec is memory-safe: every copy goes through `memcpy_s` (which rejects
destSize < count), and the option-delta accumulation has a u16 overflow guard. The token
field is `uint8_t token[COAP_TOKEN_MAX_LEN=8]`, but `tkl` (4 bits, 0-15) is caught by
`memcpy_s` when > 8 — no overflow, just a spec deviation (RFC allows up to 15).

### TEE BigInt ConvertToS32 (`tee_tee_os_framework/.../tee_arith_api.c`)

| Proof | Property | Verdict |
|---|---|---|
| `MSB guard` | 4-byte value with top byte ≥ 0x80 is rejected (prevents signed-int overflow) | ✓ |
| `reconstruction correct` | accepted value matches little-endian byte reconstruction | ✓ |
| `no signed-overflow UB` | the `<< (8*i)` shifts never overflow signed int on the accept path | ✓ |

### SM2 big-number arithmetic (`startup_hvb/libhvb/src/crypto/hvb_sm2_bn.c`)

| Proof | Property | Verdict |
|---|---|---|
| `add_with_carry exact` | result == (a+b+c) mod 2⁶⁴; carry counts overflows (∈{0,1,2}) | ✓ |
| `sub_with_borrow exact` | result == (a-b-c) mod 2⁶⁴; borrow counts underflows | ✓ |
| `sm2_bn_cmp total order` | reflexive, antisymmetric, handles zero | ✓ |

### SHA-256 message schedule (`communication_t2stack/fillp/.../sha256.c`)

| Proof | Property | Verdict |
|---|---|---|
| `wbuf index bounds` | all 4 schedule keys ∈ [0,16) | ✓ |
| `hash index bounds` | all 8 hash keys ∈ [0,8), incl. `(0-index)&7` | ✓ |

### Endian swap roundtrip (`developtools_syscap_codec/src/endian_internal.c`)

| Proof | Property | Verdict |
|---|---|---|
| `swap32 involution` | `swap(swap(x)) == x` for all u32 | ✓ |
| `swap16 involution` | `swap(swap(x)) == x` for all u16 | ✓ |

### Hex codec roundtrip (`security_deviceauth/common_lib/impl/src/string_util.c`)

| Proof | Property | Verdict |
|---|---|---|
| `high/low nibble decodes` | `HexToChar` output always valid hex char | ✓ |
| `hex roundtrip` | `decode(encode(byte)) == byte` | ✓ |
| `char range` | output char ∈ {0-9, A-F} | ✓ |

### NewIP checksum fold (`communication_sfc_newip/src/common/nip_checksum.c`)

| Proof | Property | Verdict |
|---|---|---|
| `fold converges` | carry-fold yields sum ≤ 0xFFFF (RFC 1071) | ✓ |
| `fold terminates` | converges within 3 iterations for any u32 | ✓ |

### HDMI checksum (`drivers_framework/.../hdmi_infoframe.c`)

| Proof | Property | Verdict |
|---|---|---|
| `sum-to-zero` | byte-sum including checksum == 0 mod 256 | ✓ |
| `two's complement` | checksum is `256 - running_sum` | ✓ |

### Anonymization bounds (`xts_device_attest/.../attest_utils.c`)

| Proof | Property | Verdict |
|---|---|---|
| `power-of-2` | `CalUnAnonyStrLen` returns a power of 2 (under caller's strLen>8 precondition) | ✓ |
| `memset in bounds` | anonymization offset within the string | ✓ |

### Parcel boundary read (`security_deviceauth/common_lib/impl/src/hc_parcel.c`)

| Proof | Property | Verdict |
|---|---|---|
| `cursor bound` | after read, `beginPos <= endPos` | ✓ |
| `oversized refused` | read larger than remaining bytes is rejected | ✓ |

### Replay-protection sequence check (`communication_iot_connect/.../seq_num_utils.c`)

| Proof | Property | Verdict |
|---|---|---|
| `delta <= window` | on success, delta bounded by window | ✓ |
| `shift-safe` | delta ≤ 31 (makes caller's `1UL << delta` sound) | ✓ |

## Audited and found SOUND (by reading)

- `hvb_uint64_to_base10` (startup_hvb): 32-byte buffer, uint64 max = 20 digits.
- `ParseTlvStruct` (security_deviceauth): `childTotalLength` checked against `MAX_TLV_LENGTH` after each add.
- `perm_srv_print_buff` (tee): `buff[type*i]` indexing sound (i < buff_size/4 ⟹ 4i+3 < buff_size).
- `cmdline_append_option` (startup_hvb): bounds check before append.
- `ConvertInfixToPrefix` (startup_init): bounds check after writes.
- `task_mgr.c` size-overflow guards (lines 690, 774): correct idiom `src >= MAX/unit_size`
  before `src * unit_size` — sound by algebra (`src < MAX/unit ⟹ src*unit < MAX`).
- All division sites in `tee_ssa_sfs.c`: `block_size == 0` / `unit_size == 0` guarded.
- `strtol` in TEE ELF verify: range-checked (`val < 0 || val > 0xFFFF`) before cast to uint16.
- `calculate_master_hmac` (tee sfs.c): `block_id < cipher_blks` holds by construction — block_ids are
  assigned sequentially (`last+1`, starting from `SFS_START_BLOCKID=0`) over the same linked list that
  `cipher_blks` counts, so `block_id` can never reach `cipher_blks`. The `block_id*HASH_LEN` index and
  the `cipher_blks*HASH_LEN - block_id*HASH_LEN` size arg are therefore always in range.
  **Defensive-coding gap** (not a bug): no explicit `if (block_id >= cipher_blks)` guard — the safety
  relies entirely on the list-construction invariant. A future refactor that lets `block_id` diverge
  from list position (e.g. deserializing from disk) would expose a heap OOB write here.

## Files
- `~/oh-c/cbmc_standalone/overflow_guards.c` — 4 proofs (CoAP delta u16 guard)
- `~/oh-c/cbmc_standalone/bigint_to_s32.c` — 3 proofs (BigInt→S32 reconstruction + overflow guard)
- `~/oh-c/cbmc_standalone/deal_format.c` — 2 proofs (format-string parser bounds)
- `~/oh-c/cbmc_standalone/sfs_hash_index.c` — analysis (defensive-coding gap, sound by construction)
- `~/oh-c/cbmc_standalone/sm2_addsub.c` — 6 proofs (big-number carry/borrow exactness)
- `~/oh-c/cbmc_standalone/sm2_cmp.c` — 5 proofs (comparison total order)
- `~/oh-c/cbmc_standalone/sha256_indexing.c` — 2 proofs (index bounds)
- `~/oh-c/cbmc_standalone/hvb_footer_sizes.c` — Bug 3 proof
- `~/oh-c/cbmc_standalone/hvb_footer_sizes_fixed.c` — Bug 3 fix verification
- `~/oh-c/cbmc_standalone/getdirname_real_strlen.c` — Bug 1 re-verified against real strlen
- `~/oh-c/cbmc_standalone/hc_strlen_real.c` — Bug 2 re-verified against real strlen
- `~/oh-c/cbmc_standalone/ismatch.c` — IsMatch glob matcher memory safety (new)
- `~/oh-c/cbmc_standalone/cloud_option_count.c` — Bug 4 calc/write mismatch (new)
- `~/oh-c/cbmc_standalone/nip_fold_loopinv.c` — loop_invariant demonstration
- `~/oh-c/cbmc_standalone/endian_internal.c` — 2 proofs (roundtrip)
- `~/oh-c/cbmc_standalone/hex_codec.c` — 5 proofs (roundtrip + range)
- `~/oh-c/cbmc_standalone/nip_checksum.c` — 2 proofs (fold termination + bound)
- `~/oh-c/cbmc_standalone/hdmi_checksum.c` — 2 proofs (sum-to-zero invariant)
- `~/oh-c/cbmc_standalone/anon_strlen.c` — 5 proofs (power-of-2 + bounds)
- `~/oh-c/cbmc_standalone/parcel_read.c` — 2 proofs (boundary soundness)
- `~/oh-c/cbmc_standalone/seq_num_check.c` — 2 proofs (replay delta bound)
- `~/oh-c/cbmc_standalone/getdirname_oob.c` / `getdirname_fixed.c` — Bug 1 + fix
- `~/oh-c/cbmc_standalone/hc_strlen.c` / `hc_strlen_fixed.c` — Bug 2 + fix
