# Module 01 — Ethernet

### Because every frame needs an envelope before anyone reads the letter

```
Summary:
You will parse and build Ethernet II frame headers, and dispatch
incoming frames to the right upper layer by EtherType. This is the
first interpretation layer: raw bytes from Module 00 become structured
frames, and structured frames become raw bytes on the way out.

RFC: none (Ethernet II / DIX framing)
Depends on: Module 00 (TAP)
```

---

## Foreword

A frame is just a header followed by a payload. The header says who it
is from, who it is for, and what kind of thing the payload is. Get
those three fields right — destination MAC, source MAC, EtherType — and
you can hand the payload to whoever should handle it. Get the byte
offsets wrong, and every layer above you inherits the mistake.

---

## Common Instructions

- Your project must be written in C.
- Your functions must not crash on truncated input — a buffer shorter
  than 14 bytes is not a valid frame and must be rejected, not parsed
  past its end.
- No memory leaks.
- The module must compile from the project's single Makefile with
  `-Wall -Wextra -Werror`, and must not relink.
- This module knows the *names* of the EtherTypes it dispatches
  (`0x0806`, `0x0800`) but nothing about what those protocols *do*.
  Dispatch is a table lookup, not protocol logic.

---

## Mandatory part

| | |
|---|---|
| **Module name** | `eth` |
| **Files** | `eth.c`, `eth.h` |
| **Entry points** | `eth_parse`, `eth_build`, `eth_handle_frame` |
| **Allowed externals** | `memcpy`, `memcmp`, plus Module 00 functions |
| **Depends on** | Module 00 (`tap_read`/`tap_write`) |
| **Description** | Parse and build the 14-byte Ethernet II header, and route incoming frames to the registered handler for their EtherType. |

Your Ethernet layer must provide:

- **`eth_parse(buf, len, out)`** — split a raw frame into destination
  MAC (6 bytes), source MAC (6 bytes), EtherType (2 bytes,
  network-order), and a pointer + length for the payload. Reject
  frames shorter than 14 bytes.
- **`eth_build(dst, src, ethertype, payload, payload_len, out)`** —
  assemble a complete frame: header followed by payload, ready for
  `tap_write`.
- **`eth_handle_frame(buf, len)`** — parse the frame and dispatch the
  payload to the correct upper-layer handler based on EtherType:
  `0x0806` → ARP (Module 02), `0x0800` → IPv4 (Module 03). Unknown
  EtherTypes are dropped.

Here are the requirements:

- The EtherType field is a 2-byte big-endian value. Convert at the
  boundary; never compare raw bytes against a host-order constant.
- `eth_handle_frame` must not assume a payload handler exists for every
  EtherType — unknown or unhandled types are silently dropped, never
  crash.
- The payload pointer returned by `eth_parse` must point *into* the
  original buffer (no copy), and its length must be `len - 14`.

---

## Bonus part

- **Handler registration table**: instead of a hard-coded `switch` on
  EtherType, support registering `(ethertype → handler)` pairs at
  startup, so adding a protocol later does not touch `eth.c`.
- **MAC address helpers**: `mac_to_str` / `mac_equal` /
  `mac_is_broadcast` utilities, used across this and later modules.

The bonus is only worth attempting once parse/build/dispatch are
correct on the wire.

---

## Done when

- A frame captured from `tap0` is parsed into the correct dst/src/type
  fields, matching Wireshark's dissection byte-for-byte.
- A frame built with `eth_build` and written to `tap0` is received
  intact on `tap1`, with the header Wireshark expects.
- `eth_handle_frame` routes an ARP frame and an IPv4 frame to two
  different handlers, and drops an unknown EtherType without crashing.
- No leaks; no out-of-bounds read on a 13-byte buffer.

---
---

# Test specification (for AI-generated tests)

> This section is **not** part of the subject. It defines the test
> cases an AI assistant should generate. Each test is a **contract**:
> given an input, your function must produce the stated output.

## Group A — Parsing (unit)

**A1 — Valid frame parses**
Input (header + 4-byte dummy payload):
```
ffffffffffff aabbccddee01 0806 deadbeef
```
Expected:
```
dst=ff:ff:ff:ff:ff:ff  src=aa:bb:cc:dd:ee:01  ethertype=0x0806
payload=deadbeef  payload_len=4
```

**A2 — IPv4 EtherType recognised**
Input: header with `ethertype=0800`, any payload.
Expected: `ethertype` parses to `0x0800`.

**A3 — Exactly 14 bytes (empty payload) is valid**
Input: 14-byte header, no payload.
Expected: parses; `payload_len=0`; payload pointer valid but unused.

**A4 — 13 bytes is rejected**
Input: 13 bytes.
Expected: returns error; no read at offset 13.

**A5 — Payload pointer aliases the input**
Input: A1.
Expected: the returned payload pointer equals `buf + 14` (no copy made).

## Group B — Building (unit)

**B1 — Round-trip build then parse**
Build with `dst=aa:bb:cc:dd:ee:02`, `src=aa:bb:cc:dd:ee:01`,
`ethertype=0x0800`, `payload=0102`.
Expected emitted bytes:
```
aabbccddee02 aabbccddee01 0800 0102
```
Parsing the result must reproduce the inputs.

**B2 — EtherType is written big-endian**
Build with `ethertype=0x0806`.
Expected: bytes 12–13 of the frame are `08 06`, in that order.

## Group C — Dispatch (unit, with stub handlers)

**C1 — ARP frame routed to ARP handler**
Input: frame with `ethertype=0806`. Register a stub ARP handler.
Expected: the ARP stub is invoked with the payload; the IPv4 stub is
not.

**C2 — IPv4 frame routed to IPv4 handler**
Input: `ethertype=0800`.
Expected: IPv4 stub invoked; ARP stub not.

**C3 — Unknown EtherType dropped**
Input: `ethertype=88b5` (no handler).
Expected: neither stub invoked; no crash; function returns cleanly.

## Group D — Robustness (fuzz)

**D1 — Random buffers never crash**
Feed N random buffers of length 0–60 to `eth_handle_frame`.
Expected: no crash, no out-of-bounds read under ASan; each is dispatched
or dropped.
