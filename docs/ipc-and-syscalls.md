# IPC, Unix Sockets, and Syscall Efficiency in Lumen

This document covers the design and implementation of the single-instance IPC
mechanism in `src/main.zig`, the Linux syscall patterns used, and the reasoning
behind each optimisation. It is written to be useful as a reference for anyone
reading or extending the code, or learning these concepts for the first time.

---

## 1. The single-instance pattern

When your file manager opens three images, it typically launches three separate
processes. Lumen avoids this by nominating the **first running instance as the
server** and making every later invocation a **client that hands off its paths
and exits**.

```
Second invocation (client)          First invocation (server)
────────────────────────────        ────────────────────────────
socket()
connect() ──────────────────────►  accept()
writev("a.jpg\nb.png\n") ────────► read() → parse lines → open tabs
close()                             raise window, render
exit
```

The channel between them is a **Unix domain socket** — a socket that lives in
the filesystem instead of on the network. It is the right tool here because:

- It is local-only (no network stack overhead)
- It supports `SOCK_STREAM` (ordered, reliable byte stream), so framing with
  newlines is safe
- It appears as a file path, which makes it easy to find and clean up
- Access control follows normal filesystem permissions

---

## 2. Unix domain sockets: the mechanics

### Socket path

```zig
fn socketPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("XDG_RUNTIME_DIR")) |dir_ptr| {
        const dir = std.mem.sliceTo(dir_ptr, 0);
        return try std.fmt.allocPrint(allocator, "{s}/lumen.sock", .{dir});
    }
    const uid = std.c.getuid();
    return try std.fmt.allocPrint(allocator, "/tmp/lumen-{d}.sock", .{uid});
}
```

`$XDG_RUNTIME_DIR` (e.g. `/run/user/1000`) is the XDG Base Directory for
per-user runtime files. It is on a tmpfs, cleared on logout, and only readable
by the owning user — ideal for socket files. The UID-based `/tmp` fallback
handles systems without a session manager (e.g. bare X11).

### `sockaddr_un` and its length

Unlike TCP sockets which encode address as an IP + port, a Unix socket address
is a null-terminated path stored in `sockaddr_un`:

```c
struct sockaddr_un {
    sa_family_t sun_family;   // AF_UNIX (2 bytes)
    char        sun_path[108]; // path including null terminator
};
```

The critical detail: `bind()` and `connect()` do **not** take `sizeof(sockaddr_un)`.
They take the *actual* length of the populated structure:

```zig
const addr_len: std.posix.socklen_t =
    @intCast(@sizeOf(std.posix.sa_family_t) + spath.len + 1);
//                   ^^^^^^^^^^^^^^^^^^^^^^^^^^  ^^^^^^^^^^  ^
//                   2 bytes for sun_family      path bytes  null terminator
```

Passing `sizeof(sockaddr_un)` works on most kernels but wastes bytes and is
technically wrong per POSIX. The kernel reads exactly `addr_len` bytes when
matching abstract or path sockets.

### Why the path must fit in `sun_path`

`sun_path` is 108 bytes on Linux (104 on macOS, 104 on BSDs). If your socket
path is longer the bind will fail silently or with a confusing error. The code
guards against this:

```zig
if (spath.len >= addr.path.len) return error.SocketPathTooLong;
```

This converts a confusing bind failure into a clear error at the point where
the path is validated.

### Stale socket cleanup

If the server crashed without cleaning up, the socket file remains on disk.
A new instance must remove it before binding, otherwise `bind()` returns
`EADDRINUSE`:

```zig
_ = std.os.linux.unlink(spath_z.ptr);  // ignore error — file may not exist
const server_fd = try syscallFd(std.os.linux.socket(...));
// then bind(), listen()...
defer {
    _ = std.os.linux.close(server_fd);
    _ = std.os.linux.unlink(spath_z.ptr);  // clean up on normal exit
}
```

The `errdefer _ = std.os.linux.close(server_fd)` ensures the fd is closed if
any subsequent setup step fails before the `defer` block is registered.

---

## 3. Raw Linux syscall conventions in Zig

Zig's `std.os.linux.*` functions are thin wrappers around raw Linux syscalls.
They return `usize` — the raw register value the kernel writes back. By
convention:

- **Success**: return value is `>= 0` (often a file descriptor or byte count)
- **Error**: return value is a small *negative* number, cast to unsigned: the
  bitwise representation of `-(errno)`. For example, `EINTR` (errno 4) returns
  as the `usize` bit pattern of `-4`.

This is different from libc wrappers, which return `-1` and set `errno` as a
thread-local variable.

### Helper functions

Three small helpers eliminate the repeated cast-and-compare boilerplate:

```zig
// Is the syscall return a success?
fn syscallOk(r: usize) bool {
    return @as(isize, @bitCast(r)) >= 0;
}

// Extract a file descriptor, or fail.
fn syscallFd(r: usize) error{Syscall}!i32 {
    if (@as(isize, @bitCast(r)) < 0) return error.Syscall;
    return @intCast(r);
}

// Was the syscall interrupted by a signal?
fn isEintr(r: usize) bool {
    return @as(isize, @bitCast(r)) ==
        -@as(isize, @intCast(@intFromEnum(std.posix.E.INTR)));
}
```

`isEintr` matters because any blocking syscall (`accept`, `read`, `epoll_wait`)
can be interrupted by a signal — a background thread waking up, `SIGCHLD` from
a child process, etc. The kernel returns `EINTR` to indicate "try again"; it is
not a real error. Without the check, an interrupted `accept()` would look like
"no clients available" and the connection would be silently dropped.

---

## 4. Avoiding short writes with `writev`

### The short-write problem

`write()` is not guaranteed to write all the bytes you give it in one call. If
the kernel buffer is nearly full it may write some bytes and return a count less
than the requested length. This is called a *short write*. On a local Unix
socket with small payloads it essentially never happens — but "essentially
never" is not a correctness guarantee.

The `writeAll` helper loops until all bytes are sent:

```zig
fn writeAll(fd: i32, data: []const u8) void {
    var remaining = data;
    while (remaining.len > 0) {
        const written = @as(isize, @bitCast(
            std.os.linux.write(fd, remaining.ptr, remaining.len)
        ));
        if (written <= 0) break;
        remaining = remaining[@intCast(written)..];
    }
}
```

### `writev`: scatter-gather I/O

Even with `writeAll`, sending N paths with a trailing newline each costs `2N`
syscalls. `writev` (vectorised write) accepts an array of `iovec` buffers and
sends them all **atomically in one syscall**:

```zig
const iov = try allocator.alloc(std.posix.iovec_const, (args.len - 1) * 2);
for (args[1..], 0..) |p, i| {
    iov[i * 2]     = .{ .base = p.ptr, .len = p.len };
    iov[i * 2 + 1] = .{ .base = "\n",  .len = 1 };
}
_ = std.os.linux.writev(sock, iov.ptr, iov.len);
```

The kernel concatenates the iovec segments into the socket buffer in one
operation. `2N → 1` syscall regardless of how many files are passed. The cost
is a small heap allocation for the iovec array, which is insignificant relative
to the syscall savings and is freed with the arena on exit.

`writev` also has an atomicity property: if the total payload fits in the
socket buffer, the entire message is written or nothing is — there is no
interleaving with writes from other processes on the same fd.

---

## 5. `SOCK_NONBLOCK`: removing two `fcntl` calls

The server socket needs to be non-blocking so that `accept()` returns
immediately with `EAGAIN` when no client is waiting, instead of blocking the
render loop indefinitely.

The traditional approach is:

```c
fd = socket(...);
flags = fcntl(fd, F_GETFL);       // syscall 1
fcntl(fd, F_SETFL, flags | O_NONBLOCK); // syscall 2
```

Since Linux 2.6.27 (2008), `SOCK_NONBLOCK` can be OR'd into the `type`
argument of `socket()` directly:

```zig
const server_fd = try syscallFd(std.os.linux.socket(
    std.posix.AF.UNIX,
    std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
    0,
));
```

Two fewer syscalls at startup. The flag also applies atomically — there is no
window between `socket()` and `fcntl()` where another thread could `accept()`
on a blocking fd.

The same flag exists for `accept4()` (set the accepted socket non-blocking),
`pipe2()`, `open()` (as `O_NONBLOCK`), and `eventfd()`.

---

## 6. `epoll`: event-driven I/O instead of polling

### The polling problem

Before `epoll`, the server checked for incoming connections on every frame:

```zig
while (running) {
    while (true) {
        accept(server_fd)  // syscall — returns EAGAIN almost every time
        ...
    }
    // render
    SDL_Delay(16)          // sleep 16ms
}
```

At 60 fps that is **~3,600 `accept()` syscalls per minute at idle** — every one
of which immediately returns `EAGAIN` and contributes nothing. This is
*polling*: asking "is anything ready?" on a fixed schedule.

### How `epoll` works

`epoll` is a Linux kernel mechanism that lets you register a set of file
descriptors and then block until **one of them becomes ready**, eliminating the
polling loop:

```
epoll_create1()  →  returns an epoll fd (a set, initially empty)
epoll_ctl(ADD, server_fd, EPOLLIN)  →  add server_fd to the set
epoll_wait(timeout_ms)  →  block until server_fd readable OR timeout
```

The epoll fd itself is a kernel object; the `EPOLLIN` event means "data is
available to read" (for a listening socket, that means a connection is waiting
to be accepted).

### Using `epoll_wait` as the frame timer

`epoll_wait` takes a `timeout` in milliseconds. `-1` means block forever; `0`
means return immediately; a positive value is a maximum wait time. By passing
`16` (one frame at 60 fps) it serves double duty:

```zig
const nready = std.os.linux.epoll_wait(epoll_fd, &epoll_ready, 4, 16);
if (!isEintr(nready) and @as(isize, @bitCast(nready)) > 0) while (true) {
    // a client is waiting — drain all connections
    const ar = std.os.linux.accept(server_fd, null, null);
    ...
};
// always: process SDL events and render
```

- **Timeout (nready == 0)**: 16ms passed with no connection. Fall straight
  through to rendering. Zero extra syscalls.
- **Connection ready (nready > 0)**: A client connected. Accept and handle it,
  then render the frame. `accept()` is called only when epoll says it will
  succeed.
- **EINTR**: A signal interrupted the wait. Skip the accept loop and render
  the frame. The connection will be picked up on the next iteration.

`SDL_Delay(16)` is removed — `epoll_wait` provides the timing.

### The accept drain loop

Even when epoll signals readiness, multiple clients may have connected during
the same frame (unlikely but possible given the backlog of 8). The `while (true)`
loop drains them all until `accept()` returns `EAGAIN`:

```zig
while (true) {
    const ar = std.os.linux.accept(server_fd, null, null);
    if (isEintr(ar)) continue;  // signal — retry
    if (!syscallOk(ar)) break;  // EAGAIN — no more clients
    ...
}
```

This works because `server_fd` was created with `SOCK_NONBLOCK`. Without it,
`accept()` would block waiting for the second client if only one had arrived.

### `epoll` vs `select`/`poll`

`select` and `poll` are older alternatives. They require passing the full set
of watched fds on every call, which costs O(n) even when nothing is ready.
`epoll` registers fds once and internally maintains the ready set — `epoll_wait`
is O(ready events), not O(watched fds). For one fd the difference is
immaterial, but the epoll pattern is worth knowing for cases where you watch
hundreds of fds.

---

## 7. `io_uring`: what it is and when it applies

### What it does

`io_uring` (added in Linux 5.1) provides two shared-memory ring buffers between
userspace and the kernel: a **submission queue** (SQE ring) and a **completion
queue** (CQE ring). To do I/O you write entries into the SQE ring and call
`io_uring_enter()` once to submit them all and optionally wait for completions —
**one syscall for many operations**. With `IORING_SETUP_SQPOLL`, a kernel thread
polls the submission ring continuously, reducing syscalls to zero for sustained
I/O workloads.

Additional features: linked operations (submit A then B only if A succeeded),
registered fixed buffers (avoids per-call copy), multishot accept (accept
repeatedly from one submission), zero-copy sends.

### Why it is not the right fit here

Going through each operation in Lumen:

| Operation | After epoll | With io_uring |
|---|---|---|
| Frame timer + socket wait | 1 × `epoll_wait` per frame | 1 × `io_uring_enter` — same |
| Client handoff (rare) | `accept` + `read` + `close` | Chainable as linked SQEs — saves ~2 syscalls on a rare path |
| `writev` to server | 1 syscall | 1 SQE → still 1 enter — same |
| Image file load | `open` + `stat` + `pread` + `close` | Could overlap with decoding — marginal |

The hot path at idle is already one syscall per frame. io_uring cannot reduce
that below one — you still need to enter the kernel to block on the timeout.
The socket handoff is infrequent (not a throughput bottleneck). The dominant
costs — JPEG/STB decoding and SDL GPU rendering — are CPU and GPU bound;
io_uring does not touch those.

### Where io_uring genuinely wins

- **High-connection-rate servers**: a web server doing `accept + recv + send +
  close` tens of thousands of times per second where the syscall overhead
  itself is measurable in `perf stat`
- **File I/O pipelines**: batch transcoding or indexing where you want to
  overlap kernel reads on the next file with CPU decoding of the current one
- **Zero-copy networking**: large payload transfers using registered buffers to
  avoid the userspace ↔ kernel copy on every `send`

The rule of thumb: if `perf stat` shows your program spending a significant
fraction of time in `syscall` instructions, and those syscalls are I/O (not
GPU/GPU driver ioctls), io_uring is worth evaluating. If the bottleneck is
compute or GPU, it will not help.

---

## 8. Syscall cost model

A rough mental model for relative costs on a modern Linux system:

| Operation | Approximate cost |
|---|---|
| Function call (same process) | ~1 ns |
| L1 cache miss | ~4 ns |
| L3 cache miss / RAM access | ~60 ns |
| Syscall (vDSO-accelerated, e.g. `clock_gettime`) | ~10–20 ns |
| Syscall (full kernel entry, e.g. `read`, `write`) | ~100–300 ns |
| Context switch | ~1–10 µs |
| `epoll_wait` returning immediately (EAGAIN equivalent) | ~200 ns |
| Unix domain socket round trip | ~5–20 µs |
| TCP loopback round trip | ~20–50 µs |

At 60 fps you have a **16,666 µs budget per frame**. Eliminating 3,600
unnecessary `accept()` calls per minute saves roughly 3,600 × 200 ns = 720 µs
per minute = 12 µs per second — negligible for this app, but the pattern
matters at scale.

The value of the epoll refactor here is not the raw nanoseconds saved; it is
that polling loops are **architecturally wrong** — they consume CPU at idle and
obscure intent. Event-driven code is easier to reason about, easier to extend
(add another fd to the epoll set), and scales to any number of watched fds.

---

## 9. Summary of changes and their rationale

| Change | File | Syscalls removed | Reason |
|---|---|---|---|
| `syscallOk` / `syscallFd` helpers | `main.zig` | 0 (readability) | Eliminate repeated `@as(isize, @bitCast(r)) >= 0` |
| `isEintr` helper | `main.zig` | 0 (correctness) | Retry on signal interruption instead of silently dropping |
| `writeAll` helper | `main.zig` | 0 (correctness) | Handle short writes |
| `error.SocketPathTooLong` | `main.zig` | 0 (correctness) | Fail loudly instead of falling through silently |
| Named `addr_len` constant | `main.zig` | 0 (readability) | Single source of truth for the sockaddr_un length formula |
| `writev` for client handoff | `main.zig` | `2N - 1` per handoff | One syscall regardless of number of paths |
| `SOCK_NONBLOCK` in `socket()` | `main.zig` | 2 at startup | Replaces `fcntl(GETFL)` + `fcntl(SETFL)` |
| `epoll_wait` replacing poll loop | `main.zig` | ~3,600/min at idle | Accept only when a client is actually waiting |
| Remove `SDL_Delay(16)` | `main.zig` | 1/frame | `epoll_wait(timeout=16)` is the frame timer |
