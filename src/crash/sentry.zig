const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const sentry = @import("sentry");
const internal_os = @import("../os/main.zig");
const crash = @import("main.zig");
const state = &@import("../global.zig").state;

const log = std.log.scoped(.sentry);

/// Process-wide initialization of our Sentry client.
///
/// PRIVACY NOTE: I want to make it very clear that Ghostty by default does
/// NOT send any data over the network. We use the Sentry native SDK to collect
/// crash reports and logs, but we only store them locally (see Transport).
/// It is up to the user to grab the logs and manually send them to us
/// (or they own Sentry instance) if they want to.
pub fn init(gpa: Allocator) !void {
    // Not supported on Windows currently, doesn't build.
    if (comptime builtin.os.tag == .windows) return;

    // const start = try std.time.Instant.now();
    // const start_micro = std.time.microTimestamp();
    // defer {
    //     const end = std.time.Instant.now() catch unreachable;
    //     // "[updateFrame critical time] <START us>\t<TIME_TAKEN us>"
    //     std.log.err("[sentry init time] start={}us duration={}ns", .{ start_micro, end.since(start) / std.time.ns_per_us });
    // }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const transport = sentry.Transport.init(&Transport.send);
    errdefer transport.deinit();

    const opts = sentry.c.sentry_options_new();
    errdefer sentry.c.sentry_options_free(opts);
    sentry.c.sentry_options_set_release_n(
        opts,
        build_config.version_string.ptr,
        build_config.version_string.len,
    );
    sentry.c.sentry_options_set_transport(opts, @ptrCast(transport));

    // Determine the Sentry cache directory.
    const cache_dir = try internal_os.xdg.cache(alloc, .{ .subdir = "ghostty/sentry" });
    sentry.c.sentry_options_set_database_path_n(
        opts,
        cache_dir.ptr,
        cache_dir.len,
    );

    // Debug logging for Sentry
    sentry.c.sentry_options_set_debug(opts, @intFromBool(true));

    // Initialize
    if (sentry.c.sentry_init(opts) != 0) return error.SentryInitFailed;

    // Setup some basic tags that we always want present
    sentry.setTag("app-runtime", @tagName(build_config.app_runtime));
    sentry.setTag("font-backend", @tagName(build_config.font_backend));
    sentry.setTag("renderer", @tagName(build_config.renderer));

    // Log some information about sentry
    log.debug("sentry initialized database={s}", .{cache_dir});
}

/// Process-wide deinitialization of our Sentry client. This ensures all
/// our data is flushed.
pub fn deinit() void {
    if (comptime builtin.os.tag == .windows) return;

    _ = sentry.c.sentry_close();
}

pub const Transport = struct {
    pub fn send(envelope: *sentry.Envelope, ud: ?*anyopaque) callconv(.C) void {
        _ = ud;
        defer envelope.deinit();

        // Call our internal impl. If it fails there is nothing we can do
        // but log to the user.
        sendInternal(envelope) catch |err| {
            log.warn("failed to persist crash report err={}", .{err});
        };
    }

    /// Implementation of send but we can use Zig errors.
    fn sendInternal(envelope: *sentry.Envelope) !void {
        var arena = std.heap.ArenaAllocator.init(state.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Some envelopes don't contain a crash report. Discord them.
        if (try shouldDiscard(alloc, envelope)) {
            log.info("sentry envelope does not contain crash, discarding", .{});
            return;
        }

        // Generate a UUID for this envelope. The envelope DOES have an event_id
        // header but I don't think there is any public API way to get it
        // afaict so we generate a new UUID for the filename just so we don't
        // conflict.
        const uuid = sentry.UUID.init();

        // Get our XDG state directory where we'll store the crash reports.
        // This directory must exist for writing to work.
        const crash_dir = try internal_os.xdg.state(alloc, .{ .subdir = "ghostty/crash" });
        try std.fs.cwd().makePath(crash_dir);

        // Build our final path and write to it.
        const path = try std.fs.path.join(alloc, &.{
            crash_dir,
            try std.fmt.allocPrint(alloc, "{s}.ghosttycrash", .{uuid.string()}),
        });
        log.debug("writing crash report to disk path={s}", .{path});
        try envelope.writeToFile(path);

        log.warn("crash report written to disk path={s}", .{path});
    }

    fn shouldDiscard(alloc: Allocator, envelope: *sentry.Envelope) !bool {
        // If our envelope doesn't have an event then we don't do anything.
        // To figure this out we first encode it into a string, parse it,
        // and check if it has an event. Kind of wasteful but the best
        // option we have at the time of writing this since the C API doesn't
        // expose this information.
        const json = envelope.serialize();
        defer sentry.free(@ptrCast(json.ptr));

        // Parse into an envelope structure
        var fbs = std.io.fixedBufferStream(json);
        var parsed = try crash.Envelope.parse(alloc, fbs.reader());
        defer parsed.deinit();

        // If we have an event item then we're good.
        for (parsed.items) |item| {
            if (item.type == .event) return false;
        }

        return true;
    }
};
