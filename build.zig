const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // Verify build.zig.zon .version matches src/version.zig VERSION.
    // Source of truth is src/version.zig.
    //
    // Gated by `-Dskip-version-check=true` so `zig build sync-version` can run
    // even when zon is currently out of sync (otherwise this exits 1 before
    // sync-version's makeFn ever fires — chicken-and-egg).
    const skip_version_check = b.option(
        bool,
        "skip-version-check",
        "Skip src/version.zig <-> build.zig.zon version consistency check (used by sync-version)",
    ) orelse false;
    if (!skip_version_check) verifyVersionConsistency(b);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // main.zig calls execvp/setenv via `extern "c"`; required for cross-compile.
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "envs",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run envs");
    run_step.dependOn(&run_cmd.step);

    // Unit tests.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // `zig build sync-version` — rewrite build.zig.zon .version from src/version.zig.
    // Manual one-shot. Edit src/version.zig, run this, commit both files together.
    const sync_step = b.step("sync-version", "Sync build.zig.zon .version from src/version.zig VERSION");
    const sync = b.allocator.create(SyncVersionStep) catch @panic("OOM");
    sync.* = SyncVersionStep.init(b);
    sync_step.dependOn(&sync.step);
}

fn verifyVersionConsistency(b: *std.Build) void {
    const io = b.graph.io;
    const version_zig = b.build_root.handle.readFileAlloc(
        io,
        "src/version.zig",
        b.allocator,
        .limited(16 * 1024),
    ) catch |err| {
        std.debug.print("build: failed to read src/version.zig: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const zon = b.build_root.handle.readFileAlloc(
        io,
        "build.zig.zon",
        b.allocator,
        .limited(64 * 1024),
    ) catch |err| {
        std.debug.print("build: failed to read build.zig.zon: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const v_from_src = extractQuoted(version_zig, "VERSION") orelse {
        std.debug.print("build: could not locate VERSION = \"...\" in src/version.zig\n", .{});
        std.process.exit(1);
    };
    const v_from_zon = extractQuoted(zon, ".version") orelse {
        std.debug.print("build: could not locate .version = \"...\" in build.zig.zon\n", .{});
        std.process.exit(1);
    };

    if (!std.mem.eql(u8, v_from_src, v_from_zon)) {
        std.debug.print(
            "build: version mismatch: src/version.zig={s} build.zig.zon={s}\n  -> run `zig build sync-version` to rewrite build.zig.zon from src/version.zig\n",
            .{ v_from_src, v_from_zon },
        );
        std.process.exit(1);
    }
}

/// Find `<key>` then the next quoted "..." after it.
fn extractQuoted(src: []const u8, key: []const u8) ?[]const u8 {
    const key_idx = std.mem.indexOf(u8, src, key) orelse return null;
    var i = key_idx + key.len;
    while (i < src.len and src[i] != '"') : (i += 1) {}
    if (i >= src.len) return null;
    const start = i + 1;
    var j = start;
    while (j < src.len and src[j] != '"') : (j += 1) {}
    if (j >= src.len) return null;
    return src[start..j];
}

// Custom Step that rewrites build.zig.zon's .version literal from src/version.zig's VERSION.
// Idempotent. Single-source-of-truth = src/version.zig.
//
// Usage when zon is out of sync (verify would block plain `zig build sync-version`):
//   zig build -Dskip-version-check=true sync-version
// Then a subsequent `zig build` succeeds because zon now matches.
const SyncVersionStep = struct {
    step: std.Build.Step,
    b: *std.Build,

    fn init(b: *std.Build) SyncVersionStep {
        return .{
            .b = b,
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "sync-version",
                .owner = b,
                .makeFn = make,
            }),
        };
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const self: *SyncVersionStep = @fieldParentPtr("step", step);
        const b = self.b;
        const io = b.graph.io;

        const version_zig = try b.build_root.handle.readFileAlloc(
            io,
            "src/version.zig",
            b.allocator,
            .limited(16 * 1024),
        );
        const v = extractQuoted(version_zig, "VERSION") orelse {
            return step.fail("could not locate VERSION in src/version.zig", .{});
        };

        const zon = try b.build_root.handle.readFileAlloc(
            io,
            "build.zig.zon",
            b.allocator,
            .limited(64 * 1024),
        );

        // Find `.version` then the quoted literal after it.
        const key = ".version";
        const key_idx = std.mem.indexOf(u8, zon, key) orelse {
            return step.fail("could not locate .version in build.zig.zon", .{});
        };
        var i = key_idx + key.len;
        while (i < zon.len and zon[i] != '"') : (i += 1) {}
        if (i >= zon.len) return step.fail("malformed .version line in build.zig.zon", .{});
        const lit_start = i; // position of opening quote
        var j = i + 1;
        while (j < zon.len and zon[j] != '"') : (j += 1) {}
        if (j >= zon.len) return step.fail("malformed .version line in build.zig.zon", .{});
        const lit_end = j + 1; // position after closing quote

        const old_literal = zon[lit_start..lit_end];
        const new_literal = try std.fmt.allocPrint(b.allocator, "\"{s}\"", .{v});

        if (std.mem.eql(u8, old_literal, new_literal)) {
            std.debug.print("sync-version: build.zig.zon already at {s}\n", .{v});
            return;
        }

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(b.allocator);
        try out.appendSlice(b.allocator, zon[0..lit_start]);
        try out.appendSlice(b.allocator, new_literal);
        try out.appendSlice(b.allocator, zon[lit_end..]);

        try b.build_root.handle.writeFile(io, .{
            .sub_path = "build.zig.zon",
            .data = out.items,
        });
        std.debug.print(
            "sync-version: build.zig.zon .version {s} -> \"{s}\"\n",
            .{ old_literal, v },
        );
    }
};
