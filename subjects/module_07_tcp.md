# Module 07 — TCP lite

### Because reliability is not free, and now you pay for it yourself

```
Summary:
You will implement a minimal TCP: the three-way handshake, sequence and
acknowledgement numbers, a basic retransmission on timeout, and orderly
connection teardown. This is the most stateful module in the project —
a connection is a state machine, and you are building it by hand.

RFC: 793
Depends on: Module 03 (IPv4)
```

---

## Foreword

UDP threw datagrams into the void. TCP promises something far harder: a
reliable, ordered byte stream over the same unreliable network. It keeps
that promise with sequence numbers, acknowledgements, retransmission,
and a connection state machine that has tripped up generations of
implementers. You will not build all of TCP — congestion control, window
scaling, and the subtler corners are out of scope — but you will build
the spine: SYN, SYN-ACK, ACK, data with resend, and FIN.

---

## Common Instructions

- Your project must be written in C.
- Your functions must not crash on a segment with a bogus data offset,
  an unexpected flag combination, or a sequence number far outside the
  window.
- No memory leaks — each connection holds buffers that must be freed on
  teardown.
- The module must compile from the project's single Makefile with
  `-Wall -Wextra -Werror`, and must not relink.
- This module rides on IPv4 (Module 03), reuses `inet_checksum` with a
  TCP pseudo-header, and exposes a stream interface to HTTP (Module 08).

---

## Mandatory part

| | |
|---|---|
| **Module name** | `tcp` |
| **Files** | `tcp.c`, `tcp.h`, `tcp_conn.c`, `tcp_conn.h` |
| **Entry points** | `tcp_handle`, `tcp_connect`, `tcp_listen`, `tcp_send`, `tcp_close` |
| **Allowed externals** | `memcpy`, `memset`, `malloc`, `free`, plus Module 03 functions |
| **Depends on** | Module 03 (IPv4) |
| **Description** | Implement the TCP three-way handshake, sequence/ack tracking, stop-and-wait retransmission, and FIN teardown, maintaining a per-connection state machine. |

Your TCP layer must implement, per connection:

- **The handshake**: active open sends SYN, expects SYN-ACK, replies
  ACK; passive open (`tcp_listen`) receives SYN, replies SYN-ACK,
  expects ACK. Initial sequence numbers are chosen per connection.
- **Sequence/acknowledgement tracking**: every byte of data advances
  the sequence space; received data is acknowledged with the next
  expected sequence number.
- **Basic retransmission**: unacknowledged data is resent after a
  timeout. Stop-and-wait (one outstanding segment) is sufficient for
  mandatory; a sliding window is bonus.
- **Teardown**: `tcp_close` sends FIN, and the state machine progresses
  through the closing states to fully closed, freeing the connection.

The connection state machine must track at least: `CLOSED`, `SYN_SENT`,
`SYN_RECEIVED`, `ESTABLISHED`, `FIN_WAIT`, `CLOSE_WAIT`, `LAST_ACK`,
`TIME_WAIT` (a simplified subset of RFC 793 is acceptable, but the
handshake and teardown transitions must be correct).

Here are the requirements:

- The TCP checksum uses the same pseudo-header construction as UDP
  (src/dst IP, protocol 6, TCP length) plus the TCP header and data.
- The data offset field (header length in 32-bit words) must be honored
  when locating the payload — options may be present.
- Out-of-window or unexpected segments must be handled per the state
  machine (often: drop or send an ACK), never crash.
- A retransmission timeout that never fires turns a single lost segment
  into a hang — your resend logic is mandatory, not optional.

---

## Bonus part

- **Sliding window**: allow multiple unacknowledged segments in flight,
  bounded by an advertised window.
- **Delayed/duplicate ACK handling** and a basic fast-retransmit.
- **Simultaneous open/close** edge cases of the state machine.

The bonus is only worth attempting once a single connection completes
handshake, data exchange with resend, and teardown reliably.

---

## Done when

- Your active open completes a three-way handshake with a real peer
  (a second instance, or — if you implement `tcp_listen` — a real
  client), visible in Wireshark with correct SYN/SYN-ACK/ACK flags and
  sequence numbers.
- A segment deliberately dropped is retransmitted and the transfer
  recovers.
- The TCP checksum validates in Wireshark.
- A connection closes cleanly through the FIN exchange with no leaked
  connection state.
- No crash on a segment with a bogus data offset.

---
---

# Test specification (for AI-generated tests)

> This section is **not** part of the subject. It defines the test
> cases an AI assistant should generate. Each test is a **contract**.

## Group A — Checksum & parsing (unit)

**A1 — Pseudo-header checksum matches capture**
Input: a TCP segment + pseudo-header from a Wireshark capture, checksum
zeroed.
Expected: computed checksum equals captured value.

**A2 — Data offset honored**
Input: a segment with `data_offset=6` (24-byte header with options).
Expected: payload located at offset 24, not 20.

**A3 — Flag parsing**
Input: segments with SYN, SYN|ACK, ACK, FIN|ACK set.
Expected: each flag combination parsed correctly.

## Group B — Handshake state machine (unit, stub IP)

**B1 — Active open sequence**
Drive `tcp_connect`. Feed a SYN-ACK in response to the SYN.
Expected transitions: `CLOSED → SYN_SENT → ESTABLISHED`; an ACK is
emitted with the correct ack number (peer's ISN + 1).

**B2 — Passive open sequence**
Drive `tcp_listen`. Feed a SYN.
Expected: SYN-ACK emitted; `LISTEN/CLOSED → SYN_RECEIVED`; on the
following ACK → `ESTABLISHED`.

**B3 — Sequence numbers advance by data length**
In `ESTABLISHED`, send 100 bytes.
Expected: next sequence number = previous + 100; peer's ACK of that data
advances `snd_una`.

## Group C — Retransmission (unit, controllable clock)

**C1 — Unacked data is resent after timeout**
Send a segment; do not deliver its ACK; advance the clock past the RTO.
Expected: the identical segment is retransmitted.

**C2 — Acked data is not resent**
Send a segment; deliver its ACK before the timeout.
Expected: no retransmission.

**C3 — Give up after N retries**
Withhold ACK across N retransmissions.
Expected: connection aborts/resets after the Nth attempt; no infinite
resend.

## Group D — Teardown (unit)

**D1 — Active close**
From `ESTABLISHED`, call `tcp_close`.
Expected: FIN emitted; transitions through `FIN_WAIT...` to closed on
the peer's FIN/ACK; connection state freed.

**D2 — Passive close**
Receive a FIN in `ESTABLISHED`.
Expected: ACK then FIN emitted; `CLOSE_WAIT → LAST_ACK → CLOSED`.

## Group E — Integration (on the bridge)

**E1 — Handshake with a real peer**
Complete a three-way handshake against a second instance (or a real
`nc` if `tcp_listen` is implemented).
Expected: Wireshark shows correct SYN/SYN-ACK/ACK and valid checksums.

**E2 — Recovery from a dropped segment**
Use `tc`/manual drop or a lossy stub to drop one data segment.
Expected: retransmission recovers; received stream is complete and
in-order.

## Group F — Robustness (fuzz)

**F1 — Random segments never crash**
Feed N random buffers (0–60 bytes) to `tcp_handle` across various
connection states.
Expected: no crash, no over-read under ASan.
