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
        if (k == .current_dir) {
            // Path-aware glob matching against cwd absolute path.
            // Empty path (shouldn't happen in practice) never matches.
            if (ctx.current_path.len == 0) return .not_matched;
            if (!matchCurrentDir(ctx.current_path, c.value)) return .not_matched;
            continue;
        }
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

/// Match a `current_dir` glob pattern against `path` (cwd absolute path).
///
/// Supported patterns (per spec):
///   - `foo`            → substring: path contains "foo"
///   - `*/foo`          → suffix:    path ends with "/foo"
///   - `*/foo/`         → suffix:    path ends with "/foo" or "/foo/"
///   - `*/foo/*`        → contains:  path contains "/foo/" (foo is a segment, with more after)
///   - anything else    → fall back to literal substring of the pattern
///
/// Hot path: zero alloc, only std.mem.{eql,endsWith,indexOf,startsWith}.
pub fn matchCurrentDir(path: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return false;

    // `*/foo/*` → contains "/foo/"
    if (pattern.len >= 4 and
        std.mem.startsWith(u8, pattern, "*/") and
        std.mem.endsWith(u8, pattern, "/*"))
    {
        const inner = pattern[1 .. pattern.len - 1]; // "/foo/"
        if (inner.len < 2) return false; // need at least "//"
        // No further '*' allowed in the middle for this exact form.
        if (std.mem.indexOfScalar(u8, inner, '*') != null) {
            return std.mem.indexOf(u8, path, pattern) != null;
        }
        return std.mem.indexOf(u8, path, inner) != null;
    }

    // `*/foo` or `*/foo/` → suffix
    if (pattern.len >= 2 and std.mem.startsWith(u8, pattern, "*/")) {
        const tail = pattern[1..]; // "/foo" or "/foo/"
        if (std.mem.indexOfScalar(u8, tail, '*') != null) {
            return std.mem.indexOf(u8, path, pattern) != null;
        }
        if (std.mem.endsWith(u8, tail, "/")) {
            // "/foo/" — accept either "/foo" or "/foo/" tail
            const stripped = tail[0 .. tail.len - 1];
            return std.mem.endsWith(u8, path, tail) or
                std.mem.endsWith(u8, path, stripped);
        }
        return std.mem.endsWith(u8, path, tail);
    }

    // No leading `*/`: literal substring.
    return std.mem.indexOf(u8, path, pattern) != null;
}

/// True if a `current_dir` condition value uses `*` in a position the matcher
/// does not interpret. matchCurrentDir only honours `*` in `*/foo`, `*/foo/`,
/// and `*/foo/*`; any other `*` silently falls back to literal substring, which
/// never matches a real path (paths don't contain `*`). Bare patterns (no `*`)
/// are the intended substring form and are supported.
pub fn isUnsupportedCurrentDirPattern(pattern: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) return false;

    // `*/foo/*` (contains): leading "*/", trailing "/*", no extra '*' between.
    if (pattern.len >= 4 and
        std.mem.startsWith(u8, pattern, "*/") and
        std.mem.endsWith(u8, pattern, "/*"))
    {
        const inner = pattern[1 .. pattern.len - 1];
        return std.mem.indexOfScalar(u8, inner, '*') != null;
    }
    // `*/foo` or `*/foo/` (suffix): leading "*/", no extra '*' in the tail.
    if (std.mem.startsWith(u8, pattern, "*/")) {
        const tail = pattern[1..];
        return std.mem.indexOfScalar(u8, tail, '*') != null;
    }
    return true;
}

/// What context values the parsed rules use (drives lazy git read).
pub const NeededReport = struct {
    needed: context.Needed = .{},
    has_unknown_cond_key: bool = false,
    /// `current_dir` condition values using unsupported `*` patterns.
    /// Collected at parse time so callers can warn (normal mode only).
    unsupported_current_dir: []const []const u8 = &.{},
};

pub fn analyzeNeeded(arena: std.mem.Allocator, rules: []const Rule) !NeededReport {
    var report: NeededReport = .{};
    var unsupported: std.ArrayList([]const u8) = .empty;
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
                // current_dir as a condition matches against the full cwd path.
                .current_dir => {
                    report.needed.current_path = true;
                    if (isUnsupportedCurrentDirPattern(c.value)) {
                        try unsupported.append(arena, c.value);
                    }
                },
                .name => {},
            }
        }
        // Path interpolation may also reference context vars.
        analyzePath(rule.path_template, &report);
    }
    report.unsupported_current_dir = try unsupported.toOwnedSlice(arena);
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
