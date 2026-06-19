# Module 05 — UDP

### Because sometimes you just want to throw a datagram and not look back

```
Summary:
You will implement a minimal UDP layer: build and parse datagrams,
compute the checksum over the pseudo-header, and fan incoming datagrams
out to the right application by destination port. This is the first
transport layer and the foundation for TFTP and DNS.

RFC: 768
Depends on: Module 03 (IPv4)
```

---

## Foreword

UDP is the honest minimum of a transport protocol: ports, a length, a
checksum, and your data. No connection, no ordering, no retransmission
— if you want those, you build them on top (and you will, in TFTP). Its
one subtlety is the checksum, which reaches *down* into the IP layer for
a pseudo-header. Everything else is almost too simple, which is exactly
why it is the right place to learn port demultiplexing.

---

## Common Instructions

- Your project must be written in C.
- Your functions must not crash on a datagram whose length field
  disagrees with the actual payload.
- No memory leaks — the port-binding table is long-lived.
- The module must compile from the project's single Makefile with
  `-Wall -Wextra -Werror`, and must not relink.
- This module rides on IPv4 (Module 03) and reuses `inet_checksum`. It
  knows nothing about TFTP or DNS — it only delivers datagrams to bound
  ports.

---

## Mandatory part

| | |
|---|---|
| **Module name** | `udp` |
| **Files** | `udp.c`, `udp.h` |
| **Entry points** | `udp_handle`, `udp_send`, `udp_bind`, `udp_unbind` |
| **Allowed externals** | `memcpy`, `memset`, `malloc`, `free`, plus Module 03 functions |
| **Depends on** | Module 03 (IPv4) |
| **Description** | Parse/build UDP datagrams with a correct pseudo-header checksum, and demultiplex incoming datagrams to handlers bound on destination ports. |

Your UDP layer must provide:

- **`udp_send(dst_ip, src_port, dst_port, payload, len)`** — build a
  datagram (source/dest port, length, checksum) and hand it to
  `ip_send` with protocol number 17.
- **`udp_handle(ip_src, ip_dst, buf, len)`** — verify the checksum,
  then look up a handler bound to the destination port and deliver the
  payload to it. If no handler is bound, drop (or, as bonus, trigger
  ICMP port-unreachable).
- **`udp_bind(port, handler)` / `udp_unbind(port)`** — register/remove
  the application handler for a port. This is the "port fan-out"
  mechanism that lets TFTP and DNS coexist.

Here are the requirements:

- The UDP checksum is computed over a **pseudo-header** (source IP, dest
  IP, protocol, UDP length) **plus** the UDP header and data. This is
  the field most people get wrong; verify against Wireshark.
- A received checksum of `0x0000` means "no checksum" and must be
  accepted without verification (per RFC 768).
- The length field must be validated against the actual datagram size;
  a mismatch is rejected.
- Port lookup must not be a fragile linear scan if you expect many
  bindings — but with a handful of ports, a small table is acceptable;
  document the choice.

---

## Bonus part

- **ICMP port-unreachable**: when a datagram arrives for an unbound
  port, emit ICMP type 3 code 3 (ties into Module 04).
- **Ephemeral source ports**: auto-assign an unused source port for
  `udp_send` when the caller does not specify one (needed by the DNS
  resolver in Module 09).

The bonus is only worth attempting once send, receive, checksum, and
fan-out are correct.

---

## Done when

- A datagram built by `udp_send` is dissected by Wireshark with a valid
  checksum and correct ports/length.
- A datagram you deliberately corrupt fails verification and is dropped.
- Two handlers bound on two different ports each receive only their own
  datagrams.
- `nc -u` (or a second instance) can send a datagram your stack
  delivers to the right handler.
- No leaks; no crash on a 4-byte "UDP" datagram.

---
---

# Test specification (for AI-generated tests)

> This section is **not** part of the subject. It defines the test
> cases an AI assistant should generate. Each test is a **contract**.

## Group A — Checksum with pseudo-header (unit)

**A1 — Known-good pseudo-header checksum**
Input: a datagram + its pseudo-header fields (src 10.0.0.1, dst
10.0.0.2, proto 17) taken from a real Wireshark capture, checksum field
zeroed.
Expected: computed checksum equals the captured value.

**A2 — Verification succeeds on a valid datagram**
Input: a complete datagram with correct checksum and matching
pseudo-header.
Expected: verifies as valid.

**A3 — Zero checksum accepted unverified**
Input: a datagram with checksum field `0x0000`.
Expected: accepted (no verification), per RFC 768.

**A4 — Corruption detected**
Input: a valid datagram with one payload byte flipped.
Expected: verification fails.

## Group B — Parse & build (unit)

**B1 — Round-trip build then parse**
Build `src_port=4500 dst_port=69 payload=0102`.
Expected emitted header:
```
1194 0045 <length=10> <checksum> 0102
```
Parsing reproduces the inputs; length = 8 (header) + 2 (payload) = 10.

**B2 — Length mismatch rejected**
Input: a datagram whose `length` field is 20 but actual size is 10.
Expected: parser rejects.

## Group C — Port fan-out (unit)

**C1 — Datagram delivered to bound port**
Bind a stub handler on port 69. Feed `udp_handle` a datagram with
`dst_port=69`.
Expected: the stub receives the payload.

**C2 — Two ports isolated**
Bind stub X on 69, stub Y on 53. Feed a datagram to each port.
Expected: X gets only the :69 datagram, Y only the :53 one.

**C3 — Unbound port dropped**
Feed a datagram to `dst_port=12345` (nothing bound).
Expected: dropped; no crash; (bonus: ICMP port-unreachable emitted).

**C4 — Unbind stops delivery**
Bind then unbind port 69; feed a :69 datagram.
Expected: not delivered.

## Group D — Integration (on the bridge)

**D1 — Receive from nc**
Bind a handler on port 9999. From a peer: `echo hello | nc -u <ip>
9999`.
Expected: handler receives `hello`.

**D2 — Send to a real listener**
Run `nc -u -l 9999` on a peer; `udp_send` a datagram to it.
Expected: the peer prints the payload.

## Group E — Robustness (fuzz)

**E1 — Random datagrams never crash**
Feed N random buffers (0–60 bytes) to `udp_handle`.
Expected: no crash, no over-read under ASan.
