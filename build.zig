const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // Verify build.zig.zon .version matches src/version.zig VERSION.
    verifyVersionConsistency(b);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
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
            "build: version mismatch: src/version.zig={s} build.zig.zon={s}\n",
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
