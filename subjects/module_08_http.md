# Module 08 — HTTP/1.1

### Because once you have a reliable stream, the web is just text with rules

```
Summary:
You will implement a minimal HTTP/1.1 client and/or server over your TCP
layer: GET and HEAD requests, response parsing, and persistent
(keep-alive) connections. This is where your byte stream finally carries
something a human recognizes.

RFC: 2616 (HTTP/1.1)
Depends on: Module 07 (TCP lite)
```

---

## Foreword

After the binary precision of every layer below, HTTP feels almost
relaxed: it is line-oriented text, terminated by blank lines, carrying
headers a person can read. But that informality hides exact rules —
`CRLF` line endings, the blank line that ends the headers, the
`Content-Length` that says where the body ends, and the `Connection`
header that decides whether the socket lives on. Honor them and your
stack speaks to any web server on earth.

---

## Common Instructions

- Your project must be written in C.
- Your functions must not crash on a malformed request line, a missing
  header terminator, or a body shorter than its declared
  `Content-Length`.
- No memory leaks — headers and bodies are heap-allocated per
  request/response.
- The module must compile from the project's single Makefile with
  `-Wall -Wextra -Werror`, and must not relink.
- This module rides on TCP (Module 07). It deals in the TCP byte stream
  and knows nothing of segments, sequence numbers, or retransmission.

---

## Mandatory part

| | |
|---|---|
| **Module name** | `http` |
| **Files** | `http.c`, `http.h` |
| **Entry points** | `http_get`, `http_head`, `http_parse_response`, `http_handle_request` |
| **Allowed externals** | `memcpy`, `memmem`, `strncmp`, `strchr`, `atoi`, `malloc`, `free`, plus Module 07 functions |
| **Depends on** | Module 07 (TCP) |
| **Description** | Build and send HTTP/1.1 GET/HEAD requests, parse responses (status line, headers, body), and support persistent connections via keep-alive. |

Your HTTP layer must provide:

- **`http_get(host, path)`** — open (or reuse) a TCP connection, send a
  well-formed GET request, and return the parsed response.
- **`http_head(host, path)`** — same as GET but the HEAD method;
  the response has headers but no body.
- **`http_parse_response(stream)`** — parse the status line
  (`HTTP/1.1 200 OK`), the headers up to the blank `CRLF CRLF`, and the
  body delimited by `Content-Length`.
- **`http_handle_request(stream)`** (server side, may be partial) —
  parse an incoming request line + headers and produce a response.

A well-formed request must include, at minimum:
```
GET /path HTTP/1.1\r\n
Host: example.com\r\n
Connection: keep-alive\r\n
\r\n
```

Here are the requirements:

- Lines end in `CRLF` (`\r\n`), and the header section ends with a
  blank line (`\r\n\r\n`). Locate this terminator without assuming the
  whole response arrived in one TCP read — data may span multiple
  segments.
- The body length is determined by `Content-Length`. Read exactly that
  many bytes; do not assume the body ends when the first read does.
- A HEAD response carries headers (including `Content-Length`) but no
  body — do not block waiting for a body that will never come.
- **Keep-alive**: with `Connection: keep-alive`, the TCP connection is
  reused for the next request rather than reopened. With
  `Connection: close`, it is closed after the response.

---

## Bonus part

- **Chunked transfer-encoding**: parse `Transfer-Encoding: chunked`
  bodies (no `Content-Length`), reassembling the chunks.
- **A tiny static server**: serve files from a directory in response to
  GET, with correct status codes (200, 404) and `Content-Length`.

The bonus is only worth attempting once GET/HEAD with `Content-Length`
and keep-alive work against a real server.

---

## Done when

- `http_get` against a real HTTP/1.1 server (e.g. a `python3 -m
  http.server` on a peer) returns status 200 and a body whose length
  matches `Content-Length` exactly.
- `http_head` returns headers with no body and does not hang.
- Two sequential `http_get`s over a keep-alive connection reuse one TCP
  connection (one handshake, visible in Wireshark).
- A `Connection: close` response closes the TCP connection.
- No leaks across multiple requests; no crash on a truncated response.

---
---

# Test specification (for AI-generated tests)

> This section is **not** part of the subject. It defines the test
> cases an AI assistant should generate. Each test is a **contract**.

## Group A — Request building (unit)

**A1 — GET request well-formed**
`http_get("example.com", "/index.html")`.
Expected emitted request bytes:
```
GET /index.html HTTP/1.1\r\nHost: example.com\r\nConnection: keep-alive\r\n\r\n
```

**A2 — HEAD request well-formed**
`http_head("example.com", "/")`.
Expected: identical but method `HEAD` and path `/`.

## Group B — Response parsing (unit)

**B1 — Status line + headers + body**
Input:
```
HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/plain\r\n\r\nhello
```
Expected: `status=200`, header map includes `Content-Length: 5` and
`Content-Type: text/plain`, `body="hello"` (5 bytes).

**B2 — Body read respects Content-Length, not read boundary**
Input delivered in two chunks: first
`HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhe`, then `llo`.
Expected: parser waits for all 5 body bytes; `body="hello"`.

**B3 — HEAD response has no body**
Input: `HTTP/1.1 200 OK\r\nContent-Length: 1234\r\n\r\n` (no body bytes,
HEAD request).
Expected: parse completes; `body` empty; no blocking wait for 1234
bytes.

**B4 — Missing header terminator handled**
Input: a response with headers but no final blank line, stream ends.
Expected: parser reports "incomplete", does not crash or over-read.

**B5 — 404 status parsed**
Input: `HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n`.
Expected: `status=404`, empty body.

## Group C — Keep-alive (integration)

**C1 — Connection reused**
Two `http_get`s with `Connection: keep-alive`.
Expected: one TCP handshake total (Wireshark shows a single SYN/SYN-ACK
/ACK); both responses received.

**C2 — Connection closed on demand**
A response with `Connection: close`.
Expected: TCP connection closed (FIN exchange) after the body.

## Group D — Integration (on the bridge)

**D1 — Real server GET**
Run `python3 -m http.server 8080` on a peer; `http_get` a known file.
Expected: status 200; body length == `Content-Length`; `sha256sum`
matches the served file.

**D2 — Real server HEAD**
`http_head` the same file.
Expected: headers present, no body, no hang.

## Group E — Robustness (fuzz)

**E1 — Random response bytes never crash**
Feed N random buffers to `http_parse_response`.
Expected: no crash, no over-read under ASan; each parsed or reported
incomplete.
