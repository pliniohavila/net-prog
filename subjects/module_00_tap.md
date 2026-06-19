# Module 00 — TAP Device

### Because you cannot push a single bit until you own the wire

```
Summary:
You will open a TAP device, claim it as the exclusive owner of a
layer-2 link, and read raw Ethernet frames from it in a loop. No
parsing yet — just prove that bytes flow from the wire into your
program and back out. This is the foundation every other module stands
on.

RFC: none (Linux TUN/TAP — kernel documentation)
Depends on: nothing
```

---

## Foreword

Every network stack begins with a question that has nothing to do with
protocols: how do bytes enter the program at all? On Linux, a TAP
device answers it. It is a virtual Ethernet interface whose other end
is a file descriptor. Whatever you `read()` from that fd is a frame the
"network" sent you; whatever you `write()` is a frame you put on the
"network". Master this, and every layer above is just interpreting
those bytes.

---

## Common Instructions

- Your project must be written in C.
- Your functions must not crash on any condition, including a failed
  `open`, a failed `ioctl`, or a zero-length read.
- All resources must be released: the TAP fd must be closeable cleanly,
  and no descriptors may leak across the program's lifetime.
- The module must compile from the project's single Makefile with
  `-Wall -Wextra -Werror`, and must not relink.
- This module sits at the very bottom. It must know nothing about
  Ethernet, ARP, or any protocol — it deals only in opaque byte
  buffers.

---

## Mandatory part

| | |
|---|---|
| **Module name** | `tap` |
| **Files** | `tap.c`, `tap.h` |
| **Entry points** | `tap_open`, `tap_read`, `tap_write`, `tap_close` |
| **Allowed externals** | `open`, `close`, `read`, `write`, `ioctl`, `memset`, `strncpy`, `perror` |
| **Depends on** | nothing |
| **Description** | Open a named TAP interface via `/dev/net/tun`, and provide blocking read/write of raw frames over its file descriptor. |

Your TAP layer must provide four operations:

- **`tap_open(name)`** — open `/dev/net/tun`, issue the `TUNSETIFF`
  `ioctl` with flags `IFF_TAP | IFF_NO_PI` and the given interface name
  (e.g. `"tap0"`), and return the resulting file descriptor. Opening
  the fd is what makes the interface report carrier "up" — until a
  process holds it open, the bridge will not forward frames through it.
- **`tap_read(fd, buf, len)`** — block until a frame arrives, copy up
  to `len` bytes into `buf`, and return the number of bytes read.
- **`tap_write(fd, buf, len)`** — write a complete frame to the wire;
  return the number of bytes written.
- **`tap_close(fd)`** — release the fd (which drops the interface's
  carrier).

Here are the requirements:

- `IFF_NO_PI` must be set, so the kernel does not prepend its 4-byte
  packet-info header. You want the raw Ethernet frame and nothing else.
- The interface name must be configurable (your two test hosts use
  `tap0` and `tap1`).
- A failed `open` or `ioctl` must be reported (via `perror` or a clear
  return code) and must not be treated as success.
- The interface is created and bridged **outside** your program (by
  `setup_lab.sh`). Your program only *opens* it; it does not create or
  configure it.

A minimal driver program for this module reads frames in a loop and
hex-dumps each one, so you can confirm bytes are arriving.

---

## Bonus part

- **Non-blocking mode**: open the fd `O_NONBLOCK` and integrate it with
  a `select`/`poll` loop, so the same loop can later multiplex the TAP
  fd alongside application sockets (you will need this from Module 05
  onward).
- **Frame length sanity**: reject or flag reads shorter than the
  minimum Ethernet frame (14-byte header) before passing them upward.

The bonus is only worth attempting once the mandatory read/write loop
is proven on the wire.

---

## Done when

- Your driver opens `tap0`, and frames sent into it (by `setup_lab.sh
  test`, by a second instance on `tap1`, or by a real host on the
  bridge) appear in your hex-dump output.
- The interface reports `carrier=1` in `setup_lab.sh status` while your
  program holds it open, and drops back to `NO-CARRIER` after it exits.
- A frame written with `tap_write` on `tap0` is received by a reader on
  `tap1` (the path validated by `setup_lab.sh test`).
- No descriptor leaks; clean shutdown on exit.

---
---

# Test specification (for AI-generated tests)

> This section is **not** part of the subject. It defines the test
> cases an AI assistant should generate so you can implement against
> them. Each test is a **contract**: given an input or precondition,
> your function must produce the stated output or effect.

## Group A — Open / close (integration, needs the lab up)

**A1 — Open succeeds on an existing TAP**
Precondition: `setup_lab.sh up` has created `tap0`.
Call `tap_open("tap0")`.
Expected: returns a valid fd (≥ 0); `setup_lab.sh status` now reports
`tap0 carrier=1`.

**A2 — Open fails cleanly on a non-existent TAP**
Call `tap_open("tap_does_not_exist")`.
Expected: returns a negative value / signals error; no crash; error
reported.

**A3 — Close drops carrier**
After A1, call `tap_close(fd)`.
Expected: `setup_lab.sh status` reports `tap0` back to `NO-CARRIER`.

## Group B — Read / write round-trip (integration)

**B1 — Written frame is received on the peer**
Open `tap0` in process X and `tap1` in process Y (or use two threads).
Write this 42-byte frame on `tap0`:
```
ffffffffffff aabbccddee01 0806 0001080006040001 aabbccddee01 0a000001 000000000000 0a000002
```
Expected: `tap_read` on `tap1` returns 42 bytes identical to what was
written.

**B2 — Read returns the exact byte count**
Given a known frame of length L written by a peer, `tap_read` returns
exactly L and fills `buf[0..L)` with those bytes.

**B3 — IFF_NO_PI verified**
Write a frame whose first 14 bytes are a known Ethernet header; read it
on the peer.
Expected: the received buffer starts with that exact header — no 4-byte
kernel prefix in front of it. (If a prefix appears, `IFF_NO_PI` is
missing.)

## Group C — Robustness

**C1 — Oversized read buffer is fine**
`tap_read(fd, buf, 4096)` for a 42-byte frame.
Expected: returns 42; only the first 42 bytes of `buf` are meaningful.

**C2 — Repeated open/close does not leak**
Open and close `tap0` in a loop (e.g. 1000×) under `valgrind`.
Expected: no fd leak, no memory leak.
