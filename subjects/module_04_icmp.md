# Module 04 — ICMP

### Because the first thing anyone asks a new host is "are you there?"

```
Summary:
You will implement ICMP echo (the engine behind ping) and
time-exceeded. After this module, a real `ping` from another host on
the bridge gets a real reply from your stack — the classic proof that
IP is alive.

RFC: 792
Depends on: Module 03 (IPv4)
```

---

## Foreword

ICMP is IP's own voice — the way the network talks about itself. Its
most famous message is the echo request: a packet whose only purpose is
to come back. When you can answer one correctly, you have proven that
your Ethernet, ARP, IP, and checksum code all agree with the rest of
the internet. `ping` becomes your smoke test for the entire lower
stack.

---

## Common Instructions

- Your project must be written in C.
- Your functions must not crash on a truncated ICMP message or a bad
  length field.
- No memory leaks.
- The module must compile from the project's single Makefile with
  `-Wall -Wextra -Werror`, and must not relink.
- This module rides on IPv4 (Module 03) and reuses `inet_checksum`. It
  must not duplicate checksum logic.

---

## Mandatory part

| | |
|---|---|
| **Module name** | `icmp` |
| **Files** | `icmp.c`, `icmp.h` |
| **Entry points** | `icmp_handle`, `icmp_send_echo_reply`, `icmp_send_time_exceeded` |
| **Allowed externals** | `memcpy`, plus Module 03 functions (`ip_send`, `inet_checksum`) |
| **Depends on** | Module 03 (IPv4) |
| **Description** | Parse ICMP messages dispatched from IPv4, reply to echo requests, and emit time-exceeded messages on TTL expiry. |

Your ICMP layer must handle:

- **Echo request (type 8)** — verify the ICMP checksum, then build an
  **echo reply (type 0)** that copies back the identifier, sequence
  number, and payload of the request unchanged, with a freshly computed
  checksum, and send it via `ip_send` back to the requester.
- **Time-exceeded (type 11)** — provide
  `icmp_send_time_exceeded(orig_packet)` that builds a type-11 message
  whose body contains the IP header + first 8 bytes of the offending
  packet (per RFC 792). This is called by IPv4 forwarding (Module 03
  bonus) when TTL hits zero; implementing the *sender* here is
  mandatory even if the IPv4 forwarding that calls it is bonus.

Here are the requirements:

- The ICMP checksum covers the entire ICMP message (header + body), not
  just the header. Reuse `inet_checksum`.
- An echo reply must echo the request's identifier, sequence, and
  payload **byte-for-byte** — `ping` verifies this and reports
  corruption otherwise.
- Unknown ICMP types are dropped without crashing.
- The checksum field is zeroed before computation, then written back.

---

## Bonus part

- **Echo request sender + RTT**: emit your own echo requests and match
  replies by identifier/sequence, measuring round-trip time — your own
  miniature `ping`.
- **Destination-unreachable (type 3)**: emit when a UDP datagram
  arrives for a port with no listener (ties into Module 05).

The bonus is only worth attempting once echo reply answers a real
`ping` cleanly.

---

## Done when

- `ping 10.0.0.1` from a host on the bridge receives replies from your
  stack, with 0% loss and matching payload, dissected cleanly in
  Wireshark.
- A deliberately corrupted echo request (bad checksum) gets no reply.
- An echo reply's identifier, sequence, and payload exactly match the
  request.
- A time-exceeded message you emit contains the correct quoted IP
  header + 8 bytes and passes Wireshark dissection.
- No leaks; no crash on a 4-byte "ICMP" message.

---
---

# Test specification (for AI-generated tests)

> This section is **not** part of the subject. It defines the test
> cases an AI assistant should generate. Each test is a **contract**.

## Group A — Echo parsing & reply (unit)

**A1 — Echo request parses**
Input ICMP message:
```
08 00 <checksum> <id=0001> <seq=0001> <payload: 8 bytes>
```
Expected: `type=8 code=0`, id/seq parsed, payload pointer/length
correct.

**A2 — Reply echoes id/seq/payload**
Input: A1 (a valid echo request to your address).
Expected emitted reply:
```
00 00 <new checksum> <id=0001> <seq=0001> <same 8-byte payload>
```
id, seq, and payload identical to the request; `type=0`.

**A3 — Reply checksum is valid**
After building the reply, verify its checksum independently.
Expected: valid (whole-message checksum = 0).

**A4 — Bad-checksum request gets no reply**
Input: A1 with the checksum byte corrupted.
Expected: no reply emitted.

**A5 — Unknown type dropped**
Input: `type=13` (timestamp), valid checksum.
Expected: no reply; no crash.

## Group B — Time-exceeded (unit)

**B1 — Body quotes IP header + 8 bytes**
Input: an offending IPv4 packet (20-byte header + ≥ 8 payload bytes).
Call `icmp_send_time_exceeded`.
Expected emitted message: `type=11 code=0`, body = the offending
packet's 20-byte IP header followed by exactly its first 8 payload
bytes.

**B2 — Time-exceeded checksum valid**
Expected: emitted message's checksum verifies.

## Group C — Integration (on the bridge)

**C1 — Real ping answered**
Run `ping -c 5 10.0.0.1` from a peer.
Expected: 5 replies, 0% loss; Wireshark shows request/reply pairs with
no errors.

**C2 — Payload integrity under ping**
`ping -s 100 10.0.0.1` (100-byte payload).
Expected: replies carry the identical 100-byte payload; `ping` reports
no corruption.

## Group D — Robustness (fuzz)

**D1 — Random ICMP bodies never crash**
Feed N random buffers (0–60 bytes) to `icmp_handle`.
Expected: no crash, no over-read under ASan; each replied-to or dropped.
