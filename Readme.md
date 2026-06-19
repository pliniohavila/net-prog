# Minimal Internet Protocol Suite in C

A single C codebase, no external libraries, implementing a minimal but
interoperable network stack from Ethernet up to application-layer
protocols. Built for learning: every layer is written by hand against
its RFC, then verified on the wire with `tcpdump`/Wireshark.

## Protocols

- ARP (RFC 826): request, reply, cache
- IPv4 core: header parse, route, checksum
- ICMP (RFC 792): echo, time-exceeded
- UDP mini-stack: send, receive, port fan-out
- TFTP (RFC 1350): RRQ, WRQ, DATA, ACK, ERROR
- TCP lite: 3-way handshake, basic resend
- HTTP/1.1 (RFC 2616): GET, HEAD, keep-alive
- DNS resolver (RFC 1035): iterative A and AAAA queries

## Architecture

A single binary, single event loop, one module per protocol. Each
module exposes a narrow "receive from below / send to above" interface
— the same separation the Linux kernel itself uses internally — so any
layer can be unit-tested by calling its entry function directly with a
byte buffer, with no network involved.

```
                  ┌─────────────────────────────┐
                  │         event loop           │
                  │   (select/poll on the TAP    │
                  │    fd + application sockets) │
                  └─────────────────────────────┘
                              │
                  raw bytes from /dev/net/tun
                              ▼
                    ┌───────────────────┐
                    │  eth_handle_frame  │ → ARP or IPv4?
                    └───────────────────┘
                       │              │
                       ▼              ▼
              ┌──────────────┐  ┌──────────────┐
              │  arp_handle() │  │  ip_handle()  │ → checksum, route,
              │ hash+LRU cache│  │               │   protocol dispatch
              └──────────────┘  └──────┬───────┘
                                        │
                       ┌────────────────┼────────────────┐
                       ▼                ▼                ▼
                ┌────────────┐  ┌─────────────┐  ┌──────────────┐
                │icmp_handle()│  │ udp_handle() │  │ tcp_handle()  │
                └────────────┘  └──────┬──────┘  └──────┬───────┘
                                        │                │
                              ┌─────────┴───┐      ┌─────┴──────┐
                              ▼             ▼      ▼            ▼
                        tftp_handle()  dns_handle() http_handle() (TCP)
```

Threads are deliberately avoided in this phase — concurrency bugs
(races in the ARP cache, in the TCP connection table) are a separate
class of problem, better tackled once the sequential logic is solid.

## Network lab topology

Two TAP interfaces ("dumb": no IP assigned by the kernel) bridged at
layer 2, simulating two hosts on a private wire. Addressing (IP/MAC) is
owned entirely by the C program on each side — the kernel never knows
an IP exists on either interface.

```
┌───────────────┐        ┌──────────┐        ┌───────────────┐
│  your program  │ tap0   │          │  tap1  │  your program  │
│   (host A,     │◄──────►│   br0    │◄──────►│  (host B,      │
│   10.0.0.1)    │        │ (switch) │        │   10.0.0.2)    │
└───────────────┘        └──────────┘        └───────────────┘
```

Why TAP and not `AF_PACKET` on a real interface: a real interface
already has the Linux kernel's own IP/ARP stack listening on it, which
would compete with your own implementation for the same traffic. A TAP
device is a private layer-2 wire that belongs to whichever process
opens `/dev/net/tun` — nothing else interferes.

### Lab setup: `setup_lab.sh`

`setup_lab.sh` creates and tears down the lab topology. It is
idempotent — `up` and `down` can be re-run any number of times without
erroring if the interfaces already exist (or don't).

```bash
chmod +x setup_lab.sh

sudo ./setup_lab.sh up        # creates tap0, tap1, br0 and wires them together
sudo ./setup_lab.sh status    # shows interface state, carrier, IPv6 status
sudo ./setup_lab.sh test      # sanity check: writes a raw ARP frame into tap0's
                               # fd and confirms tap1 receives it through br0
sudo ./setup_lab.sh down      # tears everything down
```

`test` writes the frame directly into the TAP file descriptor — the
same path your C program will use (`open("/dev/net/tun")` +
`ioctl(TUNSETIFF)` + `write()`) — rather than injecting it via
`AF_PACKET`/scapy. Injection through `AF_PACKET` does not reliably
cross the bridge to the other TAP, even though it is delivered to the
local interface; writing to the TAP fd does, since that is the actual
transmit path. This was confirmed empirically while building this lab,
so `test` is intentionally written against the path that matters.

A TAP interface only reports carrier ("link up") while some process
holds its `/dev/net/tun` fd open; with no process attached it is
administratively `UP` but operationally `NO-CARRIER`, and the bridge
will not forward frames through it. `setup_lab.sh status` surfaces
carrier state explicitly for this reason — it was the first thing worth
checking when the lab doesn't behave as expected.

## Modules

Implementation proceeds in this order so each step is independently
verifiable on the wire before moving to the next:

| # | Module | Done when |
|---|--------|-----------|
| 0 | TAP setup + raw read loop | bytes are visible arriving from the fd |
| 1 | Ethernet layer (header parse) | EtherType is correctly identified |
| 2 | ARP (request, reply, hash+LRU cache) | host A resolves host B's MAC, visible in Wireshark |
| 3 | IPv4 (parse, checksum, simple routing) | a correct IP header shows up in Wireshark |
| 4 | ICMP (echo request/reply, time-exceeded) | the program replies to `ping` |
| 5 | UDP (send/recv, port fan-out) | a UDP application socket works end to end |
| 6 | TFTP (RRQ/WRQ/DATA/ACK/ERROR over UDP) | a real file is transferred |
| 7 | TCP lite (3-way handshake, basic resend) | a connection completes a basic exchange |
| 8 | HTTP/1.1 (GET/HEAD, keep-alive over TCP) | a plain `curl` request succeeds |
| 9 | DNS resolver (iterative A/AAAA over UDP) | a real internet hostname resolves |

ARP before IPv4 because IP-over-Ethernet needs ARP to resolve the next
hop's MAC before anything can be sent. ICMP right after IPv4 because
`ping` is the smallest possible proof that IP is working. UDP before
TCP because it's stateless — checksums and port fan-out come first,
connection state machines later. TFTP rides on UDP, closing the loop on
a real application protocol before TCP is needed at all. DNS is UDP
too, but is ordered last since it only matters once something (the
HTTP client) needs to resolve a name.

## Implementation

### Tools

```bash
sudo apt update
sudo apt install -y build-essential gdb valgrind
sudo apt install -y tcpdump wireshark-common netcat-openbsd socat
sudo apt install -y net-tools iproute2 bridge-utils python3-pip
pip3 install scapy --break-system-packages
```

`scapy` is not required by `setup_lab.sh` itself, but is useful later
for forging malformed or adversarial packets to test each protocol
parser's robustness once the basic path works.

### Testing strategy

Three levels, from most isolated to most integrated:

1. **Unit (no network)** — feed a fixed byte buffer straight into a
   parser (e.g. `parse_arp_packet(buf, len, &out)`) and assert on the
   output fields. Catches most offset/endianness/checksum bugs without
   touching the network at all.
2. **Local integration (`setup_lab.sh` topology)** — run the program on
   one TAP and either a second instance, or a real reference
   implementation (`tftpd-hpa`, `dnsmasq`, etc.), on the other.
   Interoperating with a real server catches bugs unit tests can't.
3. **RFC conformance via capture** — capture with `tcpdump`/Wireshark
   and compare field by field against the RFC. Wireshark already
   dissects ARP/IP/ICMP/UDP/TCP/DNS/HTTP natively, so malformed fields
   are flagged automatically.

`valgrind` / `-fsanitize=address` are essential here: byte-level
parsing in C is exactly where off-by-one errors live.

## Reference

- https://x.com/tetsuoai/status/1942891931744579745
- https://blog.cloudflare.com/virtual-networking-101-understanding-tap/
- https://ldpreload.com/p/tuntap-notes.txt
- https://www.kernel.org/doc/Documentation/networking/tuntap.txt
- https://backreference.org/2010/03/26/tuntap-interface-tutorial/