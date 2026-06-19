# Module 09 — DNS resolver

### Because every name you have ever typed had to become a number first

```
Summary:
You will implement a DNS resolver over your UDP layer: build queries,
parse responses, handle the compression scheme, and resolve A (IPv4) and
AAAA (IPv6) records. With this, your HTTP client can finally accept a
hostname instead of a raw address — closing the loop on the whole stack.

RFC: 1035
Depends on: Module 05 (UDP)
```

---

## Foreword

DNS is the internet's phone book, and its wire format is a small puzzle
box: a fixed header, a question section, and answer records — with a
compression scheme that lets names point *backwards* into the packet to
save space. That pointer scheme is the one genuinely tricky parse in the
whole project, and the place a naive parser loops forever or reads out
of bounds. Handle it correctly and you can turn `example.com` into an
address the way every program on your machine silently does.

---

## Common Instructions

- Your project must be written in C.
- Your functions must not crash on a malformed response, a truncated
  record, or — critically — a compression pointer that loops or points
  outside the packet.
- No memory leaks — parsed records are heap-allocated.
- The module must compile from the project's single Makefile with
  `-Wall -Wextra -Werror`, and must not relink.
- This module rides on UDP (Module 05). It speaks to a configured DNS
  server address and parses what comes back.

---

## Mandatory part

| | |
|---|---|
| **Module name** | `dns` |
| **Files** | `dns.c`, `dns.h` |
| **Entry points** | `dns_resolve`, `dns_build_query`, `dns_parse_response`, `dns_parse_name` |
| **Allowed externals** | `memcpy`, `memset`, `malloc`, `free`, plus Module 05 functions |
| **Depends on** | Module 05 (UDP) |
| **Description** | Build DNS queries for A/AAAA records, send them over UDP, and parse responses including the name-compression scheme, returning resolved addresses. |

Your DNS resolver must provide:

- **`dns_build_query(hostname, type)`** — construct a query packet:
  header (with a random query ID, RD flag set), one question (the
  hostname encoded as length-prefixed labels, plus QTYPE A=1 or
  AAAA=28, QCLASS IN=1).
- **`dns_parse_name(packet, offset)`** — decode a name at a given
  offset, **following compression pointers** (a label whose top two
  bits are `11` is a pointer to another offset in the packet). Must
  terminate safely on a pointer loop or an out-of-bounds pointer.
- **`dns_parse_response(packet, len, out)`** — parse the header, skip
  the question, and extract answer records (name, type, class, TTL,
  rdata), returning the A/AAAA addresses.
- **`dns_resolve(hostname, type)`** — the end-to-end call: build, send
  via UDP, await the response, parse, and return the address(es).

Here are the requirements:

- Names are sequences of length-prefixed labels terminated by a zero
  byte; a label length byte with its top two bits set (`0xC0` mask) is
  a 2-byte compression pointer, not a length.
- **A compression pointer must never cause an infinite loop or an
  out-of-bounds read** — bound the number of pointer jumps and validate
  every target offset. This is the single most important safety
  requirement in the module.
- The query ID in the response must match the one sent (basic
  spoofing/mismatch guard).
- An A record's rdata is 4 bytes (IPv4); an AAAA record's is 16 bytes
  (IPv6). Validate rdata length against the record type.

---

## Bonus part

- **Iterative resolution from the root**: instead of asking one
  recursive resolver, start at a root server and follow NS referrals
  down the delegation chain yourself (the "iterative" in the project
  brief).
- **CNAME following**: resolve a name that answers with a CNAME by
  chasing the canonical name.
- **Wire `http_get` to names**: let Module 08 accept a hostname,
  resolving it through `dns_resolve` before connecting.

The bonus is only worth attempting once A and AAAA resolution against a
configured resolver works reliably, including compressed names.

---

## Done when

- `dns_resolve("example.com", A)` against a configured resolver returns
  the correct IPv4 address(es), matching `dig example.com`.
- `dns_resolve("example.com", AAAA)` returns the IPv6 address(es).
- A response using name compression is parsed correctly (most real
  responses do).
- A crafted response with a self-referential compression pointer is
  rejected without hanging or crashing.
- A response whose query ID does not match is rejected.
- No leaks; no crash on a truncated or hostile response.

---
---

# Test specification (for AI-generated tests)

> This section is **not** part of the subject. It defines the test
> cases an AI assistant should generate. Each test is a **contract**.

## Group A — Query building (unit)

**A1 — A query well-formed**
`dns_build_query("example.com", A)`.
Expected: header with RD set, QDCOUNT=1; question section encodes
`07"example"03"com"00`, QTYPE=1, QCLASS=1.

**A2 — AAAA query type**
`dns_build_query("example.com", AAAA)`.
Expected: identical but QTYPE=28.

**A3 — Random query ID**
Two successive builds.
Expected: differing query IDs (not a fixed constant).

## Group B — Name parsing & compression (unit) — the critical group

**B1 — Uncompressed name**
Input at offset O: `03"www"07"example"03"com"00`.
Expected: parses to `www.example.com`; consumes the right number of
bytes.

**B2 — Compressed name (pointer)**
Input: `example.com` encoded once at offset 12; a later name encodes
`03"www"` followed by a pointer `C0 0C` (→ offset 12).
Expected: parses to `www.example.com`.

**B3 — Pointer loop is rejected**
Input: a pointer at offset X pointing to offset X (or a 2-cycle).
Expected: parser terminates with an error after a bounded number of
jumps; **no infinite loop**.

**B4 — Out-of-bounds pointer is rejected**
Input: a pointer targeting an offset past the packet end.
Expected: parser returns error; no over-read.

**B5 — Oversized name is rejected**
Input: a chain producing a name longer than 255 bytes.
Expected: rejected per DNS limits.

## Group C — Response parsing (unit)

**C1 — Single A record**
Input: a response with one A answer, rdata `5db8d822` (93.184.216.34).
Expected: parsed address = 93.184.216.34; type=A; rdata length 4.

**C2 — Single AAAA record**
Input: a response with one AAAA answer (16-byte rdata).
Expected: parsed IPv6 address correct; rdata length 16.

**C3 — Multiple answers**
Input: a response with two A records.
Expected: both addresses returned.

**C4 — Query-ID mismatch rejected**
Input: a response whose ID ≠ the query's ID.
Expected: rejected.

**C5 — rdata length wrong for type**
Input: an "A" record claiming 16-byte rdata.
Expected: rejected, not mis-parsed as AAAA.

## Group D — Integration (real resolver)

**D1 — A record matches dig**
`dns_resolve("example.com", A)` against a configured resolver
(e.g. 1.1.1.1, or `dnsmasq` on a peer).
Expected: address(es) match `dig +short example.com`.

**D2 — AAAA record matches dig**
Same for AAAA vs `dig +short AAAA example.com`.

## Group E — Robustness (fuzz)

**E1 — Random response bytes never crash**
Feed N random buffers (0–512 bytes) to `dns_parse_response`.
Expected: no crash, no infinite loop, no over-read under ASan; each
parsed or rejected. (Pay special attention to bytes that look like
compression pointers.)
