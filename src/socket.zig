/// Unix-domain socket IPC: raw syscall helpers, socket-path resolution,
/// client handoff, and the non-blocking epoll-backed server.
const std = @import("std");

//Raw syscall helpers
//
// std.os.linux.* wrappers return `usize` using the raw kernel convention:
//   success  →  value >= 0  (often an fd or byte count)
//   error    →  bitwise representation of -(errno)
//
// These three helpers eliminate the repeated @as(isize, @bitCast(r)) pattern.

/// True when a raw Linux syscall return value indicates success (≥ 0).
pub fn syscallOk(r: usize) bool {
    return @as(isize, @bitCast(r)) >= 0;
}

/// Extract a file descriptor from a raw Linux syscall return, or error.Syscall.
pub fn syscallFd(r: usize) error{Syscall}!i32 {
    if (@as(isize, @bitCast(r)) < 0) return error.Syscall;
    return @intCast(r);
}

/// True when a raw Linux syscall return value is EINTR (interrupted by signal).
/// Any blocking syscall (accept, read, epoll_wait) can return EINTR when a
/// signal arrives — it means "try again", not a real error.
pub fn isEintr(r: usize) bool {
    return @as(isize, @bitCast(r)) ==
        -@as(isize, @intCast(@intFromEnum(std.posix.E.INTR)));
}

/// Write all bytes to fd, retrying on short writes.
/// write(2) may write fewer bytes than requested if the kernel buffer is nearly
/// full; looping until done is the correct portable approach.
pub fn writeAll(fd: i32, data: []const u8) void {
    var remaining = data;
    while (remaining.len > 0) {
        const written = @as(isize, @bitCast(
            std.os.linux.write(fd, remaining.ptr, remaining.len),
        ));
        if (written <= 0) break;
        remaining = remaining[@intCast(written)..];
    }
}

//Socket path

/// Return the path to use for the IPC socket.
/// Prefers $XDG_RUNTIME_DIR (tmpfs, per-user, cleared on logout).
/// Falls back to /tmp/lumen-<uid>.sock for systems without a session manager.
pub fn socketPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("XDG_RUNTIME_DIR")) |dir_ptr| {
        const dir = std.mem.sliceTo(dir_ptr, 0);
        return std.fmt.allocPrint(allocator, "{s}/lumen.sock", .{dir});
    }
    const uid = std.c.getuid();
    return std.fmt.allocPrint(allocator, "/tmp/lumen-{d}.sock", .{uid});
}

//Client handoff

/// Try to connect to an already-running instance and send it the paths.
/// Returns true if the handoff succeeded — the caller should then exit.
/// Returns false if no server is listening (this process should become the server).
pub fn tryHandoff(
    allocator: std.mem.Allocator,
    spath: []const u8,
    args: []const [:0]const u8,
) !bool {
    const sock = syscallFd(std.os.linux.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM,
        0,
    )) catch return false;
    defer _ = std.os.linux.close(sock);

    var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    if (spath.len >= addr.path.len) return error.SocketPathTooLong;
    @memcpy(addr.path[0..spath.len], spath);
    const addr_len: std.posix.socklen_t = @intCast(
        @sizeOf(std.posix.sa_family_t) + spath.len + 1,
    );
    if (!syscallOk(std.os.linux.connect(sock, @ptrCast(&addr), addr_len))) return false;

    // writev sends all paths in one syscall: [path, "\n"] iovec pairs.
    const iov = try allocator.alloc(std.posix.iovec_const, (args.len - 1) * 2);
    for (args[1..], 0..) |p, i| {
        iov[i * 2] = .{ .base = @ptrCast(p.ptr), .len = p.len };
        iov[i * 2 + 1] = .{ .base = "\n", .len = 1 };
    }
    _ = std.os.linux.writev(sock, iov.ptr, iov.len);
    return true;
}

//Server

/// A non-blocking Unix-domain socket server backed by epoll.
///
/// Design notes:
///   - SOCK_NONBLOCK is passed at socket() creation — no fcntl(GETFL/SETFL).
///   - epoll_wait(timeout_ms) replaces SDL_Delay: the same call that gates
///     accept() also provides the frame timer, so accept() is never called
///     when no client is waiting.
pub const Server = struct {
    fd: i32,
    epoll_fd: i32,

    pub fn init(spath: []const u8) !Server {
        // SOCK_NONBLOCK at creation avoids two fcntl(GETFL/SETFL) calls.
        const fd = try syscallFd(std.os.linux.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
            0,
        ));
        errdefer _ = std.os.linux.close(fd);

        var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..spath.len], spath);
        const addr_len: std.posix.socklen_t = @intCast(
            @sizeOf(std.posix.sa_family_t) + spath.len + 1,
        );
        if (!syscallOk(std.os.linux.bind(fd, @ptrCast(&addr), addr_len))) return error.BindFailed;
        if (!syscallOk(std.os.linux.listen(fd, 8))) return error.ListenFailed;

        const epoll_fd = try syscallFd(std.os.linux.epoll_create1(0));
        errdefer _ = std.os.linux.close(epoll_fd);
        var ev = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .fd = fd },
        };
        if (!syscallOk(std.os.linux.epoll_ctl(
            epoll_fd,
            std.os.linux.EPOLL.CTL_ADD,
            fd,
            &ev,
        ))) return error.EpollCtlFailed;

        return .{ .fd = fd, .epoll_fd = epoll_fd };
    }

    pub fn deinit(self: Server, spath_z: [:0]const u8) void {
        _ = std.os.linux.close(self.epoll_fd);
        _ = std.os.linux.close(self.fd);
        _ = std.os.linux.unlink(spath_z.ptr);
    }

    /// Block up to timeout_ms waiting for incoming connections.
    /// Reads all data from every ready client into pending.
    /// Returns true if any new bytes were received.
    ///
    /// The caller owns pending and is responsible for clearing it after
    /// processing. Partial lines are preserved across calls.
    pub fn poll(
        self: Server,
        allocator: std.mem.Allocator,
        pending: *std.ArrayList(u8),
        read_buf: []u8,
        timeout_ms: i32,
    ) !bool {
        var epoll_ready: [4]std.os.linux.epoll_event = undefined;
        const nready = std.os.linux.epoll_wait(self.epoll_fd, &epoll_ready, 4, timeout_ms);
        if (isEintr(nready) or !syscallOk(nready) or @as(isize, @bitCast(nready)) == 0)
            return false;

        var got_data = false;
        // Drain all connections that became ready in this epoll cycle.
        while (true) {
            const ar = std.os.linux.accept(self.fd, null, null);
            if (isEintr(ar)) continue;
            if (!syscallOk(ar)) break; // EAGAIN — no more clients
            const client: i32 = @intCast(ar);
            defer _ = std.os.linux.close(client);
            while (true) {
                const nr = std.os.linux.read(client, read_buf.ptr, read_buf.len);
                if (isEintr(nr)) continue;
                if (!syscallOk(nr)) break;
                const n: usize = @intCast(nr);
                if (n == 0) break; // EOF — client closed connection
                try pending.appendSlice(allocator, read_buf[0..n]);
                got_data = true;
            }
        }
        return got_data;
    }
};
