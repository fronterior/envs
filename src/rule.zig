//! Rule + matcher.
//!
//! Config line syntax:
//!     <cond1,cond2,...>env_name:path
//!     env_name:path
//!     :path                (empty env_name)
//!
//! Conditions: comma = AND, `key:value` exact match.
//! `#` comments and blank lines are skipped.
//! env_name must match exactly (empty matches empty).
//! First match wins.

const std = @import("std");
const context = @import("context.zig");

pub const Key = enum {
    repo,
    org,
    branch,
    current_dir,
    name, // path interpolation only; not a condition key (treated as unknown if used in cond)

    pub fn fromConditionStr(s: []const u8) ?Key {
        if (std.mem.eql(u8, s, "repo")) return .repo;
        if (std.mem.eql(u8, s, "org")) return .org;
        if (std.mem.eql(u8, s, "branch")) return .branch;
        if (std.mem.eql(u8, s, "current_dir")) return .current_dir;
        // `name` is interpolation-only; not allowed as condition key.
        return null;
    }

    pub fn fromInterpStr(s: []const u8) ?Key {
        if (std.mem.eql(u8, s, "repo")) return .repo;
        if (std.mem.eql(u8, s, "org")) return .org;
        if (std.mem.eql(u8, s, "branch")) return .branch;
        if (std.mem.eql(u8, s, "current_dir")) return .current_dir;
        if (std.mem.eql(u8, s, "name")) return .name;
        return null;
    }
};

/// Single parsed rule line.
pub const Rule = struct {
    /// Conditions in the form `<key:value>` pairs.
    conds: []const Cond,
    /// env_name (may be empty).
    env_name: []const u8,
    /// Raw path template (may contain `<keyword>` placeholders).
    path_template: []const u8,
    /// Original line text — used for diagnostics + `_emit_match`.
    raw_line: []const u8,

    pub const Cond = struct {
        key_str: []const u8, // verbatim (for diagnostics)
        key: ?Key, // null = unknown key
        value: []const u8,
    };
};

pub const ParseError = enum {
    none,
    malformed_line, // missing ":" after conds
};

pub const ParsedLine = struct {
    rule: ?Rule,
    err: ParseError,
};

/// Parse a single (already trimmed) config line.
///
/// Returns `null` rule for comments/empty lines, with `err == .none`.
/// On malformed (missing ':'), returns `null` rule with `err == .malformed_line`.
pub fn parseLine(arena: std.mem.Allocator, raw: []const u8) !ParsedLine {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return .{ .rule = null, .err = .none };

    var cursor: []const u8 = trimmed;
    var conds: []const Rule.Cond = &.{};

    if (cursor.len > 0 and cursor[0] == '<') {
        const close = std.mem.indexOfScalar(u8, cursor, '>') orelse {
            return .{ .rule = null, .err = .malformed_line };
        };
        const cond_str = cursor[1..close];
        conds = try parseConditions(arena, cond_str);
        cursor = cursor[close + 1 ..];
    }

    // Now cursor must look like `<env_name>:<path>`.
    const colon = std.mem.indexOfScalar(u8, cursor, ':') orelse {
        return .{ .rule = null, .err = .malformed_line };
    };

    const env_name = cursor[0..colon];
    const path_tpl = cursor[colon + 1 ..];

    return .{
        .rule = .{
            .conds = conds,
            .env_name = env_name,
            .path_template = path_tpl,
            .raw_line = trimmed,
        },
        .err = .none,
    };
}

fn parseConditions(arena: std.mem.Allocator, src: []const u8) ![]const Rule.Cond {
    var list: std.ArrayList(Rule.Cond) = .empty;
    var it = std.mem.splitScalar(u8, src, ',');
    while (it.next()) |raw_cond| {
        const c = std.mem.trim(u8, raw_cond, " \t");
        if (c.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, c, ':');
        if (colon == null) {
            try list.append(arena, .{
                .key_str = std.mem.trim(u8, c, " \t"),
                .key = null,
                .value = "",
            });
            continue;
        }
        const k = std.mem.trim(u8, c[0..colon.?], " \t");
        const v = std.mem.trim(u8, c[colon.? + 1 ..], " \t");
        try list.append(arena, .{
            .key_str = k,
            .key = Key.fromConditionStr(k),
            .value = v,
        });
    }
    return list.toOwnedSlice(arena);
}

pub const ConditionResult = enum {
    matched,
    not_matched,
    unknown_key, // rule should be skipped, optionally emit warning in normal mode
};

/// Evaluate all conditions against `ctx`. Logical AND.
pub fn evalConditions(rule: Rule, ctx: context.Context) ConditionResult {
    for (rule.conds) |c| {
        const k = c.key orelse return .unknown_key;
        const actual = ctxValue(ctx, k);
        // Empty context value never matches anything.
        if (actual.len == 0) return .not_matched;
        if (!std.mem.eql(u8, actual, c.value)) return .not_matched;
    }
    return .matched;
}

fn ctxValue(ctx: context.Context, key: Key) []const u8 {
    return switch (key) {
        .repo => ctx.repo,
        .org => ctx.org,
        .branch => ctx.branch,
        .current_dir => ctx.current_dir,
        .name => "", // sentinel — only used via interpolation, not eval
    };
}

/// What context values the parsed rules use (drives lazy git read).
pub const NeededReport = struct {
    needed: context.Needed = .{},
    has_unknown_cond_key: bool = false,
};

pub fn analyzeNeeded(rules: []const Rule) NeededReport {
    var report: NeededReport = .{};
    for (rules) |rule| {
        for (rule.conds) |c| {
            const k = c.key orelse {
                report.has_unknown_cond_key = true;
                continue;
            };
            switch (k) {
                .repo => report.needed.repo = true,
                .org => report.needed.org = true,
                .branch => report.needed.branch = true,
                .current_dir => report.needed.current_dir = true,
                .name => {},
            }
        }
        // Path interpolation may also reference context vars.
        analyzePath(rule.path_template, &report);
    }
    return report;
}

fn analyzePath(path: []const u8, report: *NeededReport) void {
    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '<') {
            const close = std.mem.indexOfScalarPos(u8, path, i + 1, '>') orelse return;
            const inner = path[i + 1 .. close];
            // Skip <key:value> form (not an interpolation token).
            if (std.mem.indexOfScalar(u8, inner, ':') == null) {
                if (Key.fromInterpStr(inner)) |k| switch (k) {
                    .repo => report.needed.repo = true,
                    .org => report.needed.org = true,
                    .branch => report.needed.branch = true,
                    .current_dir => report.needed.current_dir = true,
                    .name => {}, // env_name; always available
                };
            }
            i = close + 1;
        } else {
            i += 1;
        }
    }
}
