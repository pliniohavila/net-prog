# Module 06 — TFTP

### Because UDP gives you datagrams; turning them into a file transfer is on you

```
Summary:
You will implement a Trivial File Transfer Protocol client and/or
server on top of your UDP layer: the five opcodes (RRQ, WRQ, DATA, ACK,
ERROR), block sequencing, and the lockstep stop-and-wait that turns an
unreliable datagram service into a working file transfer.

RFC: 1350
Depends on: Module 05 (UDP)
```

---

## Foreword

TFTP is the smallest real application protocol worth writing. It has no
authentication, no negotiation in its base form, and a transfer model so
simple it fits on a napkin: send a block, wait for its ACK, send the
next. Yet that lockstep is your first taste of building reliability on
top of an unreliable layer — the same problem TCP solves at far greater
cost. Transfer one real file with it and you have closed the loop from
the wire to a usable service.

---

## Common Instructions

- Your project must be written in C.
- Your functions must not crash on a malformed packet, an unexpected
  opcode, or a block number out of sequence.
- No memory leaks — a transfer allocates buffers per block; all must be
  freed.
- The module must compile from the project's single Makefile with
  `-Wall -Wextra -Werror`, and must not relink.
- This module rides entirely on UDP (Module 05). It opens a UDP binding
  for its transfer port and speaks only in TFTP opcodes.

---

## Mandatory part

| | |
|---|---|
| **Module name** | `tftp` |
| **Files** | `tftp.c`, `tftp.h` |
| **Entry points** | `tftp_handle`, `tftp_get`, `tftp_put` |
| **Allowed externals** | `memcpy`, `memset`, `malloc`, `free`, `open`, `read`, `write`, `close`, plus Module 05 functions |
| **Depends on** | Module 05 (UDP) |
| **Description** | Implement TFTP read/write transfers: the five opcodes, 512-byte block sequencing, ACK-driven stop-and-wait, and termination on a short (< 512-byte) final block. |

Your TFTP layer must handle the five opcodes:

- **RRQ (1)** — read request: `opcode | filename | 0 | mode | 0`.
- **WRQ (2)** — write request: same layout, opposite direction.
- **DATA (3)** — `opcode | block# (2 bytes) | up to 512 data bytes`.
- **ACK (4)** — `opcode | block# (2 bytes)`.
- **ERROR (5)** — `opcode | error code (2) | message | 0`.

The transfer model (mandatory):

- A **read** (`tftp_get`) sends RRQ, then receives DATA blocks,
  ACKing each by block number, writing data to a local file, until a
  block shorter than 512 bytes signals end-of-transfer.
- A **write** (`tftp_put`) sends WRQ, waits for ACK 0, then sends DATA
  blocks of 512 bytes (the last shorter), waiting for the matching ACK
  before sending the next block.
- Block numbers start at 1 for DATA and 0 for the WRQ's initial ACK,
  and wrap is out of scope (files small enough not to exceed 65535
  blocks).

Here are the requirements:

- Strings (filename, mode) are NUL-terminated inside the packet; parse
  them safely without assuming a terminator exists.
- A DATA block of exactly 512 bytes means "more to come"; a block of
  0–511 bytes means "this is the last". This length test is the entire
  termination logic — get it exactly right.
- An out-of-sequence or duplicate block must be handled per RFC
  (re-ACK, do not write twice), not crash.
- On any unrecoverable problem, send an ERROR packet rather than going
  silent.

---

## Bonus part

- **Server mode**: bind port 69, accept RRQ/WRQ from real clients, and
  serve/store files — interoperate with the system `tftp` client.
- **Timeout + retransmit**: if an expected ACK/DATA does not arrive
  within a timeout, retransmit the last packet; give up after N
  retries. (Stop-and-wait without timeouts deadlocks on a single lost
  packet — this is where you feel why TCP exists.)

The bonus is only worth attempting once a clean transfer works against a
real TFTP implementation.

---

## Done when

- Your client `tftp_get` retrieves a file from a real server
  (`tftpd-hpa` on a peer), and the bytes match exactly (`diff` /
  `sha256sum`).
- Your client `tftp_put` uploads a file the real server stores intact.
- A transfer whose final block is exactly 512 bytes terminates
  correctly (requires an empty trailing block — a classic edge case).
- Malformed or out-of-sequence packets produce an ERROR or a re-ACK,
  never a crash.
- No leaks across a multi-block transfer.

---
---

# Test specification (for AI-generated tests)

> This section is **not** part of the subject. It defines the test
> cases an AI assistant should generate. Each test is a **contract**.

## Group A — Opcode parsing & building (unit)

**A1 — RRQ round-trip**
Build RRQ for filename `test.txt`, mode `octet`.
Expected bytes:
```
0001 "test.txt" 00 "octet" 00
```
Parsing reproduces filename and mode.

**A2 — DATA parse**
Input: `0003 0001 <512 data bytes>`.
Expected: `opcode=3 block=1`, 512-byte data pointer/length.

**A3 — ACK round-trip**
Build ACK for block 5.
Expected: `0004 0005`. Parsing yields block=5.

**A4 — ERROR parse**
Input: `0005 0001 "File not found" 00`.
Expected: `opcode=5 errcode=1 message="File not found"`.

**A5 — Unterminated string rejected**
Input: an RRQ whose filename has no NUL before buffer end.
Expected: parser rejects; no over-read.

## Group B — Transfer logic (unit, with a stub UDP)

**B1 — Read ACKs each block by number**
Feed DATA block 1 (512 B), block 2 (512 B), block 3 (200 B).
Expected: ACKs for 1, 2, 3 emitted in order; file content = concatenation
of the three data payloads; transfer ends after block 3 (short).

**B2 — 512-byte final block needs empty trailing block**
Feed DATA block 1 (512 B) then block 2 (0 B).
Expected: ACK 1, ACK 2; transfer ends on the empty block; file = 512
bytes.

**B3 — Duplicate DATA block re-ACKed, not re-written**
Feed DATA block 1, then DATA block 1 again.
Expected: ACK 1 sent both times; file contains block 1's data once, not
twice.

**B4 — Write waits for ACK before next block**
Drive `tftp_put` with a 2-block file; withhold ACK 1.
Expected: block 2 is not sent until ACK 1 arrives.

## Group C — Error handling (unit)

**C1 — Unexpected opcode → ERROR**
Feed a DATA packet with `opcode=9`.
Expected: an ERROR packet emitted; no crash.

**C2 — Missing file on read → ERROR 1**
`tftp_get` a non-existent file (server side).
Expected: ERROR with code 1 ("File not found").

## Group D — Integration (against real tftpd)

**D1 — Get matches source**
`tftp_get` a known file from `tftpd-hpa` on a peer.
Expected: `sha256sum` of received file == source.

**D2 — Put stored intact**
`tftp_put` a file; read it back from the server's store.
Expected: byte-identical.

**D3 — Binary file integrity**
Transfer a binary (non-text) file in `octet` mode.
Expected: no byte altered (no CR/LF translation).

## Group E — Robustness (fuzz)

**E1 — Random TFTP packets never crash**
Feed N random buffers (0–600 bytes) to `tftp_handle`.
Expected: no crash, no over-read under ASan; each handled or ERROR'd.
