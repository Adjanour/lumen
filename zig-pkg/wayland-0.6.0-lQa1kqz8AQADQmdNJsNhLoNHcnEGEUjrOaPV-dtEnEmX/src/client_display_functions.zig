pub inline fn connect(name: ?[*:0]const u8) error{ConnectFailed}!*Display {
    return ffi.client.wl_display_connect(name) orelse return error.ConnectFailed;
}

pub inline fn connectToFd(fd: c_int) error{ConnectFailed}!*Display {
    return ffi.client.wl_display_connect_to_fd(fd) orelse return error.ConnectFailed;
}

pub inline fn disconnect(display: *Display) void {
    ffi.client.wl_display_disconnect(display);
}

pub inline fn getFd(display: *Display) c_int {
    return ffi.client.wl_display_get_fd(display);
}

pub inline fn dispatch(display: *Display) posix.E {
    return posix.errno(ffi.client.wl_display_dispatch(display));
}

pub inline fn dispatchQueue(display: *Display, queue: *client.wl.EventQueue) posix.E {
    return posix.errno(ffi.client.wl_display_dispatch_queue(display, queue));
}

pub inline fn dispatchPending(display: *Display) posix.E {
    return posix.errno(ffi.client.wl_display_dispatch_pending(display));
}

pub inline fn dispatchQueuePending(display: *Display, queue: *client.wl.EventQueue) posix.E {
    return posix.errno(ffi.client.wl_display_dispatch_queue_pending(display, queue));
}

pub inline fn roundtrip(display: *Display) posix.E {
    return posix.errno(ffi.client.wl_display_roundtrip(display));
}

pub inline fn roundtripQueue(display: *Display, queue: *client.wl.EventQueue) posix.E {
    return posix.errno(ffi.client.wl_display_roundtrip_queue(display, queue));
}

pub inline fn flush(display: *Display) posix.E {
    return posix.errno(ffi.client.wl_display_flush(display));
}

pub inline fn createQueue(display: *Display) error{OutOfMemory}!*client.wl.EventQueue {
    return ffi.client.wl_display_create_queue(display) orelse error.OutOfMemory;
}

pub inline fn getError(display: *Display) c_int {
    return ffi.client.wl_display_get_error(display);
}

/// Succeeds if the queue is empty and returns true.
/// Fails and returns false if the queue was not empty.
pub inline fn prepareReadQueue(display: *Display, queue: *client.wl.EventQueue) bool {
    switch (ffi.client.wl_display_prepare_read_queue(display, queue)) {
        0 => return true,
        -1 => return false,
        else => unreachable,
    }
}

/// Succeeds if the queue is empty and returns true.
/// Fails and returns false if the queue was not empty.
pub inline fn prepareRead(display: *Display) bool {
    switch (ffi.client.wl_display_prepare_read(display)) {
        0 => return true,
        -1 => return false,
        else => unreachable,
    }
}

pub inline fn cancelRead(display: *Display) void {
    ffi.client.wl_display_cancel_read(display);
}

pub inline fn readEvents(display: *Display) posix.E {
    return posix.errno(ffi.client.wl_display_read_events(display));
}
