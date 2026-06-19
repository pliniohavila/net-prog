# Module 02 — ARP

### Because an IP address is useless until you know who actually holds it

```
Summary:
You will implement the Address Resolution Protocol — request, reply, and
a cache — on top of the raw Ethernet layer from Module 01. This is the
first module where your stack stops merely observing frames and starts
answering them. Welcome to the wire.

RFC: 826
Depends on: Module 00 (TAP), Module 01 (Ethernet)
```

---

## Foreword

IPv4 sends packets to IP addresses. Ethernet delivers frames to MAC
addresses. Nothing connects the two until something asks, out loud, on
the wire: "who has 10.0.0.2?" — and waits for "10.0.0.2 is at
aa:bb:cc:dd:ee:02" to come back. That something is ARP, and after this
module it is yours.

---

## Common Instructions

- Your project must be written in C.
- Your functions must not crash (segfault, bus error, double free) on
  any input, including malformed or truncated frames arriving from the
  wire. A crash on hostile input is a failed module.
- All heap-allocated memory must be freed. No leaks — the ARP cache is
  long-lived, so a per-entry leak will accumulate for the lifetime of
  the program.
- The module must compile from the project's single Makefile with
  `-Wall -Wextra -Werror`, and must not relink.
- This module links against Module 00 and Module 01 only. It must not
  reach into IP, ICMP, or any layer above — ARP knows nothing about
  what rides on top of IP.

---

## Mandatory part

| | |
|---|---|
| **Module name** | `arp` |
| **Files** | `arp.c`, `arp.h`, `arp_cache.c`, `arp_cache.h` |
| **Entry points** | `arp_handle_frame`, `arp_resolve`, `arp_cache_lookup`, `arp_cache_insert` |
| **Allowed externals** | `memcpy`, `memcmp`, `memset`, `malloc`, `free`, plus your Module 00/01 functions |
| **Depends on** | Module 00 (`tap_read`/`tap_write`), Module 01 (`eth_parse`/`eth_build`) |
| **Description** | Resolve IPv4 addresses to MAC addresses on the local link, answer resolution requests for your own address, and cache results with O(1) lookup. |

Your ARP layer must handle two directions of traffic and maintain one
data structure:

**Incoming** — a frame with EtherType `0x0806` arrives from Module 01.
Your `arp_handle_frame` must parse it and:
- If it is a **request** (`opcode 1`) targeting *your* protocol address,
  build and send a **reply** (`opcode 2`) with your MAC as the sender
  hardware address.
- If it is a **request** targeting someone else, ignore it.
- If it is a **reply** (`opcode 2`), insert the sender's
  (IP → MAC) mapping into the cache.
- Regardless of opcode, you may opportunistically cache the sender's
  (IP → MAC) mapping — every ARP packet carries it for free.

**Outgoing** — when an upper layer needs the MAC for a given IPv4
address, `arp_resolve` must:
- Return the MAC immediately if the cache holds it.
- Otherwise broadcast a request (`opcode 1`) and report "pending" to
  the caller, so the upper layer can hold or retry the packet.

**The cache** must provide:
- **O(1) average lookup** by IPv4 address — a hash table, not a linear
  scan.
- **Bounded size with LRU eviction** — when full, the least recently
  used entry is evicted. A cache that grows without bound is not a
  cache.

Here are the requirements:

- The ARP packet layout must follow RFC 826 exactly: hardware type,
  protocol type, hardware/protocol address lengths, opcode, then the
  four address fields. Verify field-for-field in Wireshark.
- All multi-byte fields are in **network byte order** on the wire.
  Conversion at the parse/build boundary is your responsibility.
- A truncated or malformed ARP frame must be rejected without reading
  out of bounds and without crashing.
- Your own IPv4 address and MAC are configuration constants of your
  program (the kernel owns no address on the TAP — see Module 00).

---

## Bonus part

- **Pending-request queue**: hold the actual outgoing IP packet that
  triggered a resolution, and flush it automatically when the matching
  reply arrives, instead of dropping it and relying on an upper-layer
  retry.
- **Cache entry expiry**: age entries out after a timeout (RFC-style
  staleness), not only by LRU pressure.
- **Gratuitous ARP**: announce your own mapping unsolicited on startup,
  and correctly absorb gratuitous ARP from peers.

The bonus is only worth attempting if the mandatory part is solid:
correct replies on the wire, O(1) lookup, working LRU eviction, and
clean behaviour under malformed input.

---

## Done when

- A peer (a second instance of your program, or `arping` from a real
  host on the bridge) sends "who has 10.0.0.1?" and your program
  answers with the correct reply, visible and correctly dissected in
  Wireshark.
- `arp_resolve` on a cached address returns the MAC with no frame sent.
- `arp_resolve` on an unknown address emits exactly one broadcast
  request.
- The cache evicts the least-recently-used entry — and only that entry
  — when it overflows.
- No leaks (`valgrind`) and no crashes on malformed frames
  (`-fsanitize=address`).

---
---

# Test specification (for AI-generated tests)

> This section is **not** part of the subject. It defines the test
> cases an AI assistant should generate so you can implement against
> them. Each test is a **contract**: given an input, your function must
> produce the stated output or effect. Implement the module until every
> contract holds.
>
> Inputs are raw byte buffers (what arrives from the wire) or address
> values; outputs are parsed structs, emitted frames, or cache state.

## Group A — Parsing (unit, no network)

Feed a fixed byte buffer to your ARP parser; assert on the parsed
struct. Bytes shown big-endian as they appear on the wire.

**A1 — Valid request parses correctly**
Input (28-byte ARP payload):
```
0001 0800 06 04 0001 aabbccddee01 0a000001 000000000000 0a000002
```
Expected parse:
```
hw_type=1  proto_type=0x0800  hw_len=6  proto_len=4  opcode=1
sender_mac=aa:bb:cc:dd:ee:01  sender_ip=10.0.0.1
target_mac=00:00:00:00:00:00  target_ip=10.0.0.2
```

**A2 — Valid reply parses correctly**
Input: same as A1 but `opcode=0002` and `target_mac=aabbccddee02`.
Expected: `opcode=2`, fields parsed accordingly.

**A3 — Truncated payload is rejected**
Input: first 20 bytes of A1 only.
Expected: parser returns an error/`-1`; no read past buffer end; no
crash.

**A4 — Wrong hardware/protocol type is rejected**
Input: A1 with `hw_type=0006` (not Ethernet).
Expected: parser returns an error; nothing is cached.

**A5 — Inconsistent length fields are rejected**
Input: A1 with `hw_len=08` (claims 8-byte MACs).
Expected: parser returns an error rather than trusting the field and
over-reading.

## Group B — Reply generation (unit)

Given a parsed request and your identity (`MY_IP=10.0.0.1`,
`MY_MAC=aa:bb:cc:dd:ee:01`), assert on the bytes your builder emits.

**B1 — Request for me → correct reply**
Input request: A1 (target_ip = 10.0.0.1).
Expected emitted ARP payload:
```
opcode=2
sender_mac=aa:bb:cc:dd:ee:01  sender_ip=10.0.0.1
target_mac=<requester's mac>  target_ip=<requester's ip>
```
And the surrounding Ethernet frame: `dst = requester MAC`,
`src = MY_MAC`, `ethertype = 0x0806`.

**B2 — Request for someone else → no reply**
Input request: A1 but `target_ip=10.0.0.9`.
Expected: builder emits nothing; function signals "not for me".

## Group C — Cache behaviour (unit)

Drive the cache API directly; assert on lookups and eviction order.

**C1 — Insert then lookup hits**
Insert (10.0.0.2 → aa:bb:cc:dd:ee:02), lookup 10.0.0.2.
Expected: returns that MAC.

**C2 — Lookup miss**
Empty cache, lookup 10.0.0.2.
Expected: returns "not found" (not a zeroed MAC mistaken for a hit).

**C3 — Update existing entry**
Insert 10.0.0.2 → ...ee:02, then insert 10.0.0.2 → ...ee:99.
Expected: lookup returns ...ee:99; entry count unchanged.

**C4 — LRU eviction order**
Cache capacity = N. Insert N+1 distinct addresses; before inserting the
last, touch (look up) the oldest so it is no longer least-recently-used.
Expected: the evicted entry is the *second*-oldest (the true LRU), not
the one you just touched.

**C5 — O(1) lookup sanity**
Insert many entries (e.g. 10k). Lookup time must not scale with entry
count (i.e. it is a hash table, not a scan). This is a structural
assertion, not a strict timing test — but a linear scan should be
visibly disqualified.

## Group D — Integration (on the bridge)

Run against a second instance or a real host on `br0`.

**D1 — Answer a real request**
Peer sends "who has 10.0.0.1?" (e.g. `arping -I tapX 10.0.0.1`).
Expected: your reply arrives; peer's `arping` reports the MAC; Wireshark
dissects request and reply with no malformed-field warnings.

**D2 — Resolve emits exactly one request**
Call `arp_resolve(10.0.0.2)` with an empty cache.
Expected: exactly one broadcast request on the wire; function reports
"pending".

**D3 — Resolve from cache is silent**
Pre-populate the cache with 10.0.0.2, then `arp_resolve(10.0.0.2)`.
Expected: MAC returned; **zero** frames on the wire.

## Group E — Robustness (fuzz)

**E1 — Random bytes never crash**
Feed N random buffers of random lengths (0–60 bytes) labelled as
EtherType 0x0806 to `arp_handle_frame`.
Expected: no crash, no leak, no out-of-bounds read under ASan; each is
either parsed or cleanly rejected.
