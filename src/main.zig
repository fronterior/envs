//! envs — local env router (Zig native rewrite).
//!
//! Modes:
//!   envs <name> <cmd...>          normal — match + export .env + exec cmd
//!   envs --source-match [name]    source — print resolved .env path, exit 0
//!
//! Hot path optimizations:
//!   * No subprocess spawn for git (reads .git directly)
//!   * Lazy git context: skip .git I/O entirely if no rule needs it
//!   * Single readAll for config; in-place byte slice parse
//!   * ArenaAllocator for all strings; one writeAll for source mode output
//!
//! Fail-open semantics for normal mode (match: matching/parse errors still
//! exec the user command); source mode is silent and exits 1 on any failure.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const version = @import("version.zig");
const context = @import("context.zig");
const rule_mod = @import("rule.zig");
const interp = @import("interp.zig");

const Mode = enum { normal, source };

const ParsedArgs = struct {
    mode: Mode,
    env_name: []const u8,
    /// In normal mode: cmd argv (argv0...).
    cmd_argv: []const [:0]const u8,
};

// libc execvp — used to exec the user's command with PATH lookup.
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        writeStderr(io, USAGE);
        return 2;
    }

    var parsed: ParsedArgs = undefined;
    if (std.mem.eql(u8, args[1], "--source-match")) {
        const name: []const u8 = if (args.len >= 3) args[2] else "";
        parsed = .{ .mode = .source, .env_name = name, .cmd_argv = &.{} };
    } else if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-V")) {
        const line = try std.fmt.allocPrint(arena, "envs {s}\n", .{version.VERSION});
        var stdout_buf: [256]u8 = undefined;
        var stdout_w = Io.File.stdout().writer(io, &stdout_buf);
        try stdout_w.interface.writeAll(line);
        try stdout_w.interface.flush();
        return 0;
    } else if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        writeStderr(io, USAGE);
        return 0;
    } else {
        if (args.len < 3) {
            writeStderr(io, USAGE);
            return 2;
        }
        parsed = .{
            .mode = .normal,
            .env_name = args[1],
            .cmd_argv = args[2..],
        };
    }

    return run(arena, io, init.environ_map, parsed);
}

fn run(
    arena: Allocator,
    io: Io,
    env_map: *std.process.Environ.Map,
    parsed: ParsedArgs,
) !u8 {
    const home = env_map.get("HOME") orelse "";
    const config_dir = env_map.get("ENVS_CONFIG_DIR") orelse blk: {
        if (home.len == 0) break :blk @as([]const u8, "/.config/envs");
        break :blk try std.fmt.allocPrint(arena, "{s}/.config/envs", .{home});
    };
    const config_file = try std.fmt.allocPrint(arena, "{s}/config", .{config_dir});

    // Read config (1 syscall path).
    const cfg_bytes = Io.Dir.cwd().readFileAlloc(io, config_file, arena, .limited(16 * 1024 * 1024)) catch {
        if (parsed.mode == .source) return 1;
        const msg = try std.fmt.allocPrint(
            arena,
            "config not found at {s} (running without env injection)",
            .{config_file},
        );
        emitError(arena, io, msg);
        execCmdOrExit(arena, parsed.cmd_argv);
        return 1;
    };

    // Parse all rules first so we can analyze which context vars are needed.
    var rules: std.ArrayList(rule_mod.Rule) = .empty;
    var line_it = std.mem.splitScalar(u8, cfg_bytes, '\n');
    while (line_it.next()) |raw| {
        const parsed_line = try rule_mod.parseLine(arena, raw);
        if (parsed_line.rule) |r| {
            try rules.append(arena, r);
        } else if (parsed_line.err == .malformed_line and parsed.mode == .normal) {
            const msg = try std.fmt.allocPrint(arena, "skipping malformed line: {s}", .{std.mem.trim(u8, raw, " \t\r")});
            emitError(arena, io, msg);
        }
    }

    // Lazy git: build context only with what rules reference.
    const report = try rule_mod.analyzeNeeded(arena, rules.items);
    const needed = report.needed;

    if (parsed.mode == .normal) {
        for (report.unsupported_current_dir) |p| {
            const msg = try std.fmt.allocPrint(
                arena,
                "unsupported current_dir pattern: {s} (only foo, */foo, */foo/, */foo/* supported)",
                .{p},
            );
            emitError(arena, io, msg);
        }
    }

    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const cwd: []const u8 = cwd_buf[0..cwd_len];

    const ctx = try context.build(arena, io, cwd, needed);

    // First-match-wins.
    var matched_path: ?[]const u8 = null;
    var matched_raw: []const u8 = "";
    for (rules.items) |rule| {
        if (!std.mem.eql(u8, rule.env_name, parsed.env_name)) continue;
        switch (rule_mod.evalConditions(rule, ctx)) {
            .matched => {},
            .not_matched => continue,
            .unknown_key => {
                if (parsed.mode == .normal) {
                    const msg = try std.fmt.allocPrint(arena, "skipping unknown keyword in: {s}", .{rule.raw_line});
                    emitError(arena, io, msg);
                }
                continue;
            },
        }
        const ir = try interp.interpolate(arena, rule.path_template, parsed.env_name, ctx);
        switch (ir.err) {
            .none => {},
            .empty_variable => continue,
            .unknown_keyword => {
                if (parsed.mode == .normal) {
                    const msg = try std.fmt.allocPrint(arena, "warning: unknown variable in path: {s}", .{ir.bad_token});
                    emitError(arena, io, msg);
                }
                continue;
            },
        }
        matched_path = try interp.resolvePath(arena, ir.path, home, config_dir);
        matched_raw = rule.raw_line;
        break;
    }

    if (matched_path == null) {
        if (parsed.mode == .source) return 1;
        emitNoMatch(arena, io, parsed.env_name, ctx, config_file);
        execCmdOrExit(arena, parsed.cmd_argv);
        return 1;
    }

    const mp = matched_path.?;

    // Verify .env file is readable + read in source mode just to verify.
    if (parsed.mode == .source) {
        // Confirm we can open it.
        const f = Io.Dir.cwd().openFile(io, mp, .{}) catch return 1;
        f.close(io);
        const line = try std.fmt.allocPrint(arena, "{s}\n", .{mp});
        var stdout_buf: [4096]u8 = undefined;
        var stdout_w = Io.File.stdout().writer(io, &stdout_buf);
        try stdout_w.interface.writeAll(line);
        try stdout_w.interface.flush();
        return 0;
    }

    // Normal mode: read .env, set vars, exec cmd.
    const env_bytes = Io.Dir.cwd().readFileAlloc(io, mp, arena, .limited(16 * 1024 * 1024)) catch {
        const msg = try std.fmt.allocPrint(arena, "env file not readable: {s}", .{mp});
        emitError(arena, io, msg);
        execCmdOrExit(arena, parsed.cmd_argv);
        return 1;
    };

    emitMatch(arena, io, parsed.env_name, mp, matched_raw);

    var env_it = std.mem.splitScalar(u8, env_bytes, '\n');
    while (env_it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = trimmed[0..eq];
        var val: []const u8 = trimmed[eq + 1 ..];
        if (val.len >= 2) {
            const q = val[0];
            if ((q == '"' or q == '\'') and val[val.len - 1] == q) {
                val = val[1 .. val.len - 1];
            }
        }
        const keyZ = try arena.dupeZ(u8, key);
        const valZ = try arena.dupeZ(u8, val);
        _ = setenv(keyZ.ptr, valZ.ptr, 1);
    }

    execCmdOrExit(arena, parsed.cmd_argv);
    return 1;
}

fn execCmdOrExit(arena: Allocator, cmd_argv: []const [:0]const u8) void {
    if (cmd_argv.len == 0) return;
    const argv0 = cmd_argv[0];
    const buf = arena.alloc(?[*:0]const u8, cmd_argv.len + 1) catch return;
    for (cmd_argv, 0..) |a, i| buf[i] = a.ptr;
    buf[cmd_argv.len] = null;
    _ = execvp(argv0.ptr, @ptrCast(buf.ptr));
    // execvp returns only on error.
    std.debug.print("envs: exec failed: {s}\n", .{argv0});
    std.process.exit(127);
}

// ----- pretty output -----

fn colorEnabled(io: Io) bool {
    const stderr_file = Io.File.stderr();
    const tty = stderr_file.isTty(io) catch return false;
    if (!tty) return false;
    // env access happens via Environ, but for color we look at posix env directly.
    if (std.process.Environ.empty.getPosix("NO_COLOR")) |v| {
        if (v.len > 0) return false;
    }
    if (std.process.Environ.empty.getPosix("TERM")) |t| {
        if (std.mem.eql(u8, t, "dumb")) return false;
    }
    return true;
}

fn emitMatch(arena: Allocator, io: Io, env_name: []const u8, path: []const u8, raw_line: []const u8) void {
    var bw: std.ArrayList(u8) = .empty;
    const color = colorEnabled(io);
    appendPrefix(arena, &bw, color);
    appendColored(arena, &bw, color, "32", "✓ ");
    appendColored(arena, &bw, color, "1", env_name);
    bw.append(arena, ' ') catch return;
    appendColored(arena, &bw, color, "36", "→ ");
    appendColored(arena, &bw, color, "36", path);
    bw.append(arena, '\n') catch return;
    appendColored(arena, &bw, color, "2", "↳ ");
    appendColored(arena, &bw, color, "2", raw_line);
    bw.append(arena, '\n') catch return;
    writeStderr(io, bw.items);
}

fn emitNoMatch(arena: Allocator, io: Io, env_name: []const u8, ctx: context.Context, config_file: []const u8) void {
    var bw: std.ArrayList(u8) = .empty;
    const color = colorEnabled(io);
    appendPrefix(arena, &bw, color);
    appendColored(arena, &bw, color, "33", "✗ ");
    bw.appendSlice(arena, "no rule for ") catch return;
    appendColored(arena, &bw, color, "1", env_name);
    bw.append(arena, '\n') catch return;
    appendColored(arena, &bw, color, "2", "↳ ");
    const info = std.fmt.allocPrint(arena, "repo={s} branch={s} current_dir={s} org={s}\n", .{
        ctx.repo, ctx.branch, ctx.current_dir, ctx.org,
    }) catch return;
    appendColored(arena, &bw, color, "2", info);
    appendColored(arena, &bw, color, "2", "↳ ");
    const cfg = std.fmt.allocPrint(arena, "config: {s}\n", .{config_file}) catch return;
    appendColored(arena, &bw, color, "2", cfg);
    writeStderr(io, bw.items);
}

fn emitError(arena: Allocator, io: Io, msg: []const u8) void {
    var bw: std.ArrayList(u8) = .empty;
    const color = colorEnabled(io);
    appendPrefix(arena, &bw, color);
    appendColored(arena, &bw, color, "31", "! ");
    bw.appendSlice(arena, msg) catch return;
    bw.append(arena, '\n') catch return;
    writeStderr(io, bw.items);
}

fn appendPrefix(arena: Allocator, bw: *std.ArrayList(u8), color: bool) void {
    appendColored(arena, bw, color, "1;7;36", " envs ");
    bw.append(arena, ' ') catch return;
}

fn appendColored(arena: Allocator, bw: *std.ArrayList(u8), color: bool, code: []const u8, text: []const u8) void {
    if (color) {
        const s = std.fmt.allocPrint(arena, "\x1b[{s}m{s}\x1b[0m", .{ code, text }) catch return;
        bw.appendSlice(arena, s) catch return;
    } else {
        bw.appendSlice(arena, text) catch return;
    }
}

fn writeStderr(io: Io, bytes: []const u8) void {
    Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

const USAGE =
    \\usage: envs <env_name> <command...>
    \\       envs --source-match [env_name]
    \\
;
