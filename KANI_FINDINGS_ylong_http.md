# Direct Kani Verification of ylong_http

Direct bounded-model-checking with **Kani 0.67.0** — no bmc_agent / LLM in the loop.
All proofs are `#[cfg(kani)]`-gated, fully inert under normal `cargo build`/`cargo test`
(verified: 122 unit tests still pass).

## How to run

```bash
cd ~/oh-rust/commonlibrary_rust_ylong_http/ylong_http
cargo kani --features http2,huffman              # all proofs (per-harness unwind)
cargo kani --features http2,huffman --harness <name>             # one proof
```

Proofs live in: `src/kani_proofs.rs` (public API) + in-module
`#[cfg(kani)] mod kani_*_proofs` blocks in `h2/hpack/integer.rs` and
`request/uri/mod.rs` (for `pub(crate)` access).

## Results — 15 proofs, all SOUND (0 bugs)

### Panic/OOB-freedom (memory safety)

| Proof | Target | Checks | Verdict |
|---|---|---|---|
| `proof_encode_no_panic` | `IntegerEncoder::next_byte` (full usize) | — | ✓ panic-free |
| `proof_encode_small_value_single_byte` | RFC 7541 single-byte case | — | ✓ `pre\|i`, finishes |
| `proof_decode_first_byte` | `IntegerDecoder::first_byte` | — | ✓ Ok/Err + index/shift correct |
| `proof_decode_next_byte_continuation` | `IntegerDecoder::next_byte` | — | ✓ continuation-bit logic + checked-arith overflow→Err |
| `proof_scheme_token_no_panic` | URI scheme parser | 183 | ✓ OOB/panic-free |
| `proof_authority_token_no_panic` | URI authority parser | 785 | ✓ OOB/panic-free (solver: kissat) |
| `proof_path_token_no_panic` | URI path parser | 293 | ✓ OOB/panic-free |
| `proof_query_token_no_panic` | URI query parser | 291 | ✓ OOB/panic-free |
| `proof_host_port_no_panic` | host:port splitter | 708 | ✓ OOB/panic-free |

### Functional correctness (new — not just safety)

| Proof | Target | Checks | Verdict |
|---|---|---|---|
| `proof_status_from_u16_range_invariant` | `StatusCode::from_u16` | — | ✓ accepts only 100..1000 |
| `proof_status_as_bytes_sound` | `StatusCode::as_bytes` | — | ✓ no overflow, all bytes are ASCII digits |
| `proof_version_as_str_distinct` | `Version::as_str` | 81 | ✓ injective (4 variants → 4 distinct strings) |
| `proof_version_roundtrip` | `Version` try_from ∘ as_str | 377 | ✓ exact inverse on all 4 variants |
| `proof_table_update_respects_bound` | `DynamicTable::update` + `fit_size` | — | ✓ RFC 7541 §4.3: size bound holds after insert |
| `proof_table_update_size_reestablishes_bound` | `DynamicTable::update_size` | — | ✓ shrink evicts to respect new bound |

### Techniques applied (learned from model-checking/kani repo)

- **Per-harness `#[kani::unwind(N)]`** — each proof declares its own bound (no global
  `--default-unwind` flag). Unwind = loop_iterations + 1.
- **`#[kani::solver(kissat)]`** on the slow `authority_token` proof.
- **Fixed-length strings + bounded unwind** for VecDeque proofs — Kani models heap
  collection drops as unrolled loops; symbolic-length Strings explode it (600+
  iterations). Fixed strings + `#[kani::unwind(12)]` keeps the table proofs tractable.

## Key finding: the earlier "as_bytes overflow (CWE-190)" was a FALSE POSITIVE

The bmc-agent run flagged `StatusCode::as_bytes` as an integer-overflow bug:
`(self.0/100) as u8 + b'0'` overflows for codes ≥ 25600.

**Direct Kani proves this is unreachable**: `StatusCode::from_u16` validates
`100..=1000` (`if !(100..1000).contains(&code) { return Err(...) }`), and the
tuple struct field is private, so no construction path can produce an
out-of-range code. Over the valid range, `as_bytes` is sound. This is exactly
the kind of false positive agentic/LLM spec-generation produces that direct
model-checking eliminates.

## ⚠ Soundness Findings — `from_utf8_unchecked` on network input (2 UB sites)

Direct model-checking + data-flow tracing found **two `String::from_utf8_unchecked`
UB sites on the H2/H1 header-decode paths**. Both take attacker-controlled wire
bytes, never validate UTF-8, and hand the bytes straight to the `unsafe`
constructor. This is the same bug class as the `ylong_json` `char::from_u32_unchecked`
finding, but on the **network-input path** — a malicious HTTP/2 or HTTP/1.1 peer
triggers it.

Proofs: `~/oh-rust/kani_standalone/{hpack_utf8_soundness,h1_header_utf8_soundness}.rs`.

### Finding A — HPACK literal header value (`h2/hpack/decoder.rs:194`)

`HpackDecoder::get_header_by_name_and_value` runs
`unsafe { String::from_utf8_unchecked(value) }` on the decoded header value.
Data flow: `AsciiStringBytes::decode` (`representation/decoder.rs:449`) copies raw
wire bytes into a `Vec<u8>` with **zero UTF-8 validation**, which flows untouched
to the `unsafe` call.

The shipped unit test `ut_decode_literal_non_utf8_header_value` (decoder.rs:597)
feeds bytes containing `0xE5,0xBB,0x6F` (INVALID UTF-8 — `0x6F` is not a
continuation byte) and asserts `decode()` is `Ok`, **proving the `unsafe` path
is reached with invalid bytes**. `std::str::from_utf8` returns `Err` on those bytes
(verified at runtime).

Kani: `proof_non_utf8_reaches_unchecked` (exact test bytes) + `proof_raw_copy_preserves_arbitrary_bytes`
(`kani::cover!(!is_valid)` SATISFIED — arbitrary non-UTF8 bytes reach the site).

- **Trigger**: malicious HTTP/2 peer sends an HPACK literal header with non-UTF-8 bytes.
- **Severity**: medium (remote, UB on peer-controlled input).
- **Fix**: `String::from_utf8(value)?` → `H2Error::CompressionError` on invalid bytes.

### Finding B — H1 response header value (`h1/response/decoder.rs:617`)

`header_insert` runs `unsafe { String::from_utf8_unchecked(header_value) }`.
The parser gate `HEADER_VALUE_BYTES[b]` (`util/header_bytes.rs:62`) **allows
obs-text (0x80..=0xFF all `true`)** per RFC 7230, so a single byte `0xFF` passes
the parser but is invalid UTF-8 → `from_utf8_unchecked` is UB.

Kani: `proof_h1_value_obs_text_is_unsound` (byte `0xFF`: table-accepted AND invalid
UTF-8) + `proof_every_high_byte_is_unsound_value` (symbolic: every byte ≥0x80 is
accepted and invalid).

- **Trigger**: malicious HTTP/1.1 server returns a response with an obs-text byte in a header value.
- **Severity**: medium (remote, UB on server-controlled input).
- **Fix**: `String::from_utf8(header_value)?`.

### Contrast — SOUND `from_utf8_unchecked` sites (not bugs)

- **H1 header *name*** (`decoder.rs:616`): `HEADER_NAME_BYTES` sets 0x80..=0xFF all
  `false` → names are ASCII-only → `from_utf8_unchecked` is sound.
  (`proof_h1_name_is_ascii_only_sound`.)
- **`percent_encoding_char`** (`request/uri/percent_encoding.rs:269,282`): input is
  `&str` (valid UTF-8) and offsets never split a multibyte char. Sound.

## H2 wire-format boundary — verified SOUND (4 in-crate proofs)

Audited the H2 frame decoder (`h2/decoder.rs`), the outermost trust boundary where
raw bytes become structured frames. All byte-reconstruction arithmetic is sound:

| Proof | Property | Verdict |
|---|---|---|
| `proof_frame_stream_id_reserved_bit_masked` | `get_stream_id` clears reserved bit R → result < 2³¹ | ✓ |
| `proof_frame_stream_id_semantics` | matches big-endian reconstruction w/ 0x7f mask | ✓ |
| `proof_frame_payload_length_24bit` | 3-byte length ≤ 0xFFFFFF (no overflow, ~16 MiB max) | ✓ |
| `proof_frame_is_connection_frame_zero` | stream-id==0 is exactly the connection-frame test | ✓ |

Also confirmed sound by reading (bounded arithmetic, not separately proved):
- **WINDOW_UPDATE increment** (`decoder.rs:513`): `0x7f` mask on reserved bit +
  correct `<<24/16/8` reconstruction + zero-increment rejected (RFC 7540 §6.9).
- **Payload-length checks** per frame type: PING==8, PRIORITY==5, WINDOW_UPDATE==4,
  GOAWAY≥8 — all enforced before parsing.
- **HPACK header-list size** (`header_size += addition`): unguarded usize add, but
  overflow needs ~2⁶⁴ bytes of header data — not exploitable.

## ylong_http_client — redirect off-by-one + soundness audit

### `Redirect` limit off-by-one (`util/redirect.rs`)

`limited(N)` follows exactly **N−1 redirects**, not N. `redirect()` pushes the
current URI to `previous` **before** the limit check (`trigger()` tests
`previous.len() < max`), so the counter reaches `max` one step early.

- Default `limited(10)`: follows 9 redirects, errors on the 10th.
- `limited(1)`: follows **0** redirects (push→len=1, `1 < 1` false → error).
- Doc comment says "up to a maximum of 10".
- **Severity**: low (safe-direction off-by-one: the bound IS enforced, no
  infinite redirect loop; just fewer redirects than documented).
- **Fix**: change `<` to `<=` in `trigger()`, or push after the check.

Proofs: `~/oh-rust/kani_standalone/redirect_limit.rs` (3 proofs, including a
symbolic bound-enforcement check and a `<=`-semantics comparison).

### `from_utf8_unchecked` soundness audit (ylong_http_client + remaining ylong_http sites)

Audited all remaining `from_utf8_unchecked` sites. Result: **all SOUND**
(input validation makes the unsafe justified).

| Site | Why sound | Proof |
|---|---|---|
| `headers.rs:247` `normalize` | `HEADER_CHARS[b]` maps every byte to ASCII (<0x80) or 0 (reject); `dst` only holds non-zero entries | `proof_header_chars_all_ascii` |
| `mimetype.rs:119,135,151` | `MEDIA_TYPE_VALID_BYTES` rejects all bytes ≥0x80; `MimeTypeTag` matching rejects non-ASCII | `proof_media_type_rejects_high_bytes`, `proof_accepted_media_byte_is_ascii` |
| `uri/mod.rs:1028` `bytes_to_str` | URI slices are valid UTF-8 by construction (ASCII delimiters never appear inside multibyte sequences) | (reasoned) |
| `percent_encoding.rs:*` | operates on valid `&str`; offsets never split a char | (prior round) |
| `chunk.rs:17` | dead import — `from_utf8_unchecked` imported but **never called** | (grep) |
| `c_ssl_stream.rs:102` | `from_raw_parts_mut` on ReadBuf's own unfilled region — standard sound pattern | (reasoned) |

Proofs: `~/oh-rust/kani_standalone/http_array_soundness.rs` (3 proofs, arrays
spliced verbatim from source).

### Other checks (sound, not bugs)

- **`hex_to_decimal`** (`chunk.rs:1083`): `checked_mul(16)` + `checked_add` —
  proper overflow checking on chunk-size accumulation.
- **Retry loop** (`client.rs:162`): `retries > 0` guard before `retries -= 1` —
  no underflow, bounded retries.

## Targets checked but not bugs

- **`DynamicTable::update`** `curr_size += header.len() + value.len() + 32` —
  usize overflow needs ~2^64 bytes; not realistic.
- **`percent_encoding_char`'s `unsafe { from_utf8_unchecked }`** — sound by
  construction: input is `&str` (valid UTF-8), and in valid UTF-8 every byte
  ≥0x80 of a multibyte sequence gets percent-encoded individually, so the slice
  offsets never split a char. (Kani models `str` as valid-by-construction, so it
  can't directly flag a misuse of `from_utf8_unchecked`; reasoned manually.)

## Limitation hit

Kani struggles with Rust iterator closure chains: a `slice.iter().enumerate().find()`
over **16** symbolic bytes caused the `try_fold` unrolling to explode (566+
iterations, timeout). Bounding the slice to **4 bytes** + `--default-unwind 8`
makes the same proof tractable (183 checks, ~2s). For broader sweeps, prefer
functions without iterator-`find`/`position`, or keep symbolic slice bounds small.
