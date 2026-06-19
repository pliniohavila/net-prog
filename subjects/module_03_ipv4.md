# Module 03 — IPv4

### Because Ethernet only reaches the next hop; IP is how you mean the destination

```
Summary:
You will parse and build IPv4 headers, validate and compute the header
checksum, and make a minimal routing decision: is this packet for me,
or for someone I must forward toward? This is the layer where addresses
stop being local and start being global.

RFC: 791
Depends on: Module 01 (Ethernet), Module 02 (ARP)
```

---

## Foreword

Ethernet asks "who is physically next to me?" IP asks "where in the
world is this going?" The IPv4 header carries that intent in twenty
tightly-packed bytes, guarded by a checksum that catches corruption
with nothing but additions and a complement. Parse it wrong by one bit
and the checksum will tell you — if you implement the checksum
correctly. That is the heart of this module.

---

## Common Instructions

- Your project must be written in C.
- Your functions must not crash on a header claiming a bogus length, a
  truncated packet, or a header with options you did not expect.
- No memory leaks.
- The module must compile from the project's single Makefile with
  `-Wall -Wextra -Werror`, and must not relink.
- This module depends on ARP to resolve the next-hop MAC before
  sending, but knows nothing about ICMP, UDP, or TCP — it only
  *dispatches* to them by protocol number.

---

## Mandatory part

| | |
|---|---|
| **Module name** | `ip` |
| **Files** | `ip.c`, `ip.h`, `checksum.c`, `checksum.h` |
| **Entry points** | `ip_parse`, `ip_build`, `ip_handle`, `ip_send`, `inet_checksum` |
| **Allowed externals** | `memcpy`, `memset`, plus Module 01/02 functions |
| **Depends on** | Module 01 (Ethernet), Module 02 (ARP for next-hop resolution) |
| **Description** | Parse/build IPv4 headers, verify and compute the Internet checksum, dispatch by protocol number, and send upper-layer payloads by resolving the next hop via ARP. |

Your IPv4 layer must provide:

- **`inet_checksum(data, len)`** — the standard one's-complement
  Internet checksum (RFC 1071), used for the IP header here and reused
  by ICMP, UDP, and TCP later. Get this right once; everything above
  depends on it.
- **`ip_parse(buf, len, out)`** — extract version, IHL, total length,
  TTL, protocol, source and destination addresses, and the payload
  pointer/length. Reject packets whose IHL or total-length fields are
  inconsistent with the actual buffer.
- **`ip_handle(buf, len)`** — verify the checksum; if the destination
  is one of *my* addresses, dispatch the payload by protocol number
  (`1` → ICMP, `6` → TCP, `17` → UDP); otherwise apply the routing
  decision below.
- **`ip_send(dst_ip, proto, payload, len)`** — build a header (correct
  checksum, TTL, total length), resolve the next-hop MAC via ARP, and
  hand the frame to Ethernet. If ARP resolution is pending, the packet
  is held or dropped per your ARP module's contract.
- **`ip_build(...)`** — assemble a valid header in front of a payload.

Routing is intentionally minimal:
- If `dst_ip` is on my local subnet (same network as my configured
  IP/mask), the next hop is `dst_ip` itself.
- Otherwise the next hop is a configured default gateway.
- Forwarding (decrementing TTL and re-sending packets *not* addressed
  to me) is bonus, not mandatory.

Here are the requirements:

- All multi-byte header fields are network byte order.
- The checksum field must be zeroed before computing the checksum over
  the header, then written back.
- A packet failing checksum verification is dropped silently.
- IHL may be greater than 5 (options present); your parser must use IHL
  to locate the payload, not assume a fixed 20-byte header.

---

## Bonus part

- **Forwarding + TTL**: when a packet is not for me, decrement TTL,
  recompute the checksum, and re-send toward the next hop; when TTL
  reaches zero, signal ICMP (Module 04) to emit a time-exceeded.
- **Fragment awareness**: at minimum, detect the More-Fragments flag
  and a non-zero fragment offset and reject rather than mis-parse
  (full reassembly is out of scope).

The bonus is only worth attempting once parse, checksum, dispatch, and
`ip_send` (with ARP) work end to end.

---

## Done when

- A hand-built IPv4 packet's checksum matches what Wireshark computes,
  and Wireshark flags no header errors.
- `ip_handle` correctly drops a packet whose checksum you deliberately
  corrupt.
- `ip_send` to a local-subnet address triggers ARP resolution and then
  emits a correct frame to the resolved MAC.
- A packet addressed to you is dispatched to the right protocol stub by
  protocol number.
- No leaks; no crash on a header claiming `total_length` larger than
  the buffer.

---
---

# Test specification (for AI-generated tests)

> This section is **not** part of the subject. It defines the test
> cases an AI assistant should generate. Each test is a **contract**.

## Group A — Checksum (unit)

**A1 — Known-good checksum**
Input: the 20-byte header from RFC 1071 / a known Wireshark capture
(checksum field zeroed).
Expected: `inet_checksum` returns the documented value.

**A2 — Verification of a valid header succeeds**
Input: a complete header with its correct checksum in place.
Expected: running the checksum over the whole header yields `0x0000`
(or `0xFFFF`, per convention) — i.e. "valid".

**A3 — Odd-length data is padded correctly**
Input: a buffer of odd length.
Expected: the final byte is treated as the high byte of a 16-bit word
(zero-padded low byte), per RFC 1071. Result matches a reference
implementation.

**A4 — Corruption is detected**
Input: a valid header with one byte flipped.
Expected: verification fails.

## Group B — Parsing (unit)

**B1 — Standard 20-byte header parses**
Input: a valid header, `version=4 IHL=5 TTL=64 proto=1`,
`src=10.0.0.1 dst=10.0.0.2`, 8-byte payload.
Expected: all fields parsed; `payload_len=8`; payload pointer at offset
20.

**B2 — Header with options (IHL=6) locates payload correctly**
Input: `IHL=6` (24-byte header) + payload.
Expected: payload pointer at offset 24, not 20.

**B3 — total_length > buffer is rejected**
Input: header with `total_length=1000` but a 40-byte buffer.
Expected: parser returns error; no over-read.

**B4 — IHL < 5 is rejected**
Input: `IHL=4` (impossible: header can't be < 20 bytes).
Expected: parser returns error.

## Group C — Build & send (unit / integration)

**C1 — Built header has a valid checksum**
Build a packet with `ip_build`; verify its checksum independently.
Expected: checksum verifies as valid.

**C2 — Round-trip build then parse**
Build with known fields, parse the result.
Expected: parsed fields equal the inputs.

**C3 — ip_send resolves next hop on local subnet**
`ip_send(10.0.0.2, proto=17, payload, len)` with an empty ARP cache,
your IP 10.0.0.1/24.
Expected: an ARP request for 10.0.0.2 is emitted (next hop = dst
itself); after resolution, the IPv4 frame is sent to that MAC.

**C4 — ip_send off-subnet targets the gateway**
`ip_send(8.8.8.8, ...)` with a configured gateway 10.0.0.254.
Expected: ARP resolution targets the gateway, not 8.8.8.8.

## Group D — Dispatch (unit, with stubs)

**D1 — Protocol number routing**
Feed `ip_handle` packets addressed to you with `proto=1`, `6`, `17`.
Expected: ICMP, TCP, UDP stubs invoked respectively; payload offset
correct in each.

**D2 — Packet not for me is not dispatched**
Input: valid packet with `dst` = some other address (forwarding
disabled).
Expected: no protocol stub invoked.

## Group E — Robustness (fuzz)

**E1 — Random bytes never crash**
Feed N random buffers (0–60 bytes) to `ip_handle`.
Expected: no crash, no over-read under ASan; each is parsed-and-handled
or dropped.
