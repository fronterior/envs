//! Path interpolation + resolution.
//!
//! Path template rules:
//!   - `<keyword>` → context value (or env_name for `<name>`)
//!   - `<key:value>` form is NOT interpolation (left as-is — caller should
//!     never see this since rule parser already extracted conditions).
//!   - If any referenced variable is empty, the rule is skipped (caller).
//!   - Unknown `<keyword>` → returns `.unknown_keyword` so caller can warn/skip.
//!
//! Path resolver (after interpolation):
//!   - `/...`  → as-is
//!   - `~/...` → `$HOME/...`
//!   - other   → `$ENVS_CONFIG_DIR/...`

const std = @import("std");
const context = @import("context.zig");
const rule_mod = @import("rule.zig");

pub const InterpError = enum {
    none,
    empty_variable, // referenced key has empty value
    unknown_keyword,
};

pub const InterpResult = struct {
    err: InterpError,
    /// On `.none`, the fully interpolated path (arena-owned).
    path: []const u8 = "",
    /// On `.unknown_keyword`, the offending token (e.g. "<foo>") — for diagnostics.
    bad_token: []const u8 = "",
};

/// Interpolate placeholders. Returns either `.none` with the interpolated
/// path, or an error variant (no path).
pub fn interpolate(
    arena: std.mem.Allocator,
    template: []const u8,
    env_name: []const u8,
    ctx: context.Context,
) !InterpResult {
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '<') {
            const close = std.mem.indexOfScalarPos(u8, template, i + 1, '>') orelse {
                // Unterminated `<` — treat as literal.
                try buf.append(arena, template[i]);
                i += 1;
                continue;
            };
            const inner = template[i + 1 .. close];

            // `<key:value>` form — not interpolation, copy literal.
            if (std.mem.indexOfScalar(u8, inner, ':') != null) {
                try buf.appendSlice(arena, template[i .. close + 1]);
                i = close + 1;
                continue;
            }

            const key = rule_mod.Key.fromInterpStr(inner) orelse {
                return .{
                    .err = .unknown_keyword,
                    .bad_token = template[i .. close + 1],
                };
            };
            const val: []const u8 = switch (key) {
                .repo => ctx.repo,
                .org => ctx.org,
                .branch => ctx.branch,
                .current_dir => ctx.current_dir,
                .name => env_name,
            };
            if (val.len == 0) {
                return .{ .err = .empty_variable };
            }
            try buf.appendSlice(arena, val);
            i = close + 1;
        } else {
            try buf.append(arena, template[i]);
            i += 1;
        }
    }
    return .{ .err = .none, .path = try buf.toOwnedSlice(arena) };
}

/// Resolve an (already-interpolated) path to its absolute filesystem location.
/// `home_dir` = $HOME, `config_dir` = $ENVS_CONFIG_DIR.
pub fn resolvePath(
    arena: std.mem.Allocator,
    p: []const u8,
    home_dir: []const u8,
    config_dir: []const u8,
) ![]const u8 {
    if (p.len == 0) return try arena.dupe(u8, p);
    if (p[0] == '/') return try arena.dupe(u8, p);
    if (p.len >= 2 and p[0] == '~' and p[1] == '/') {
        return try std.fmt.allocPrint(arena, "{s}/{s}", .{ home_dir, p[2..] });
    }
    // strip leading "./" if present (mirrors sh behavior).
    var rel = p;
    if (rel.len >= 2 and rel[0] == '.' and rel[1] == '/') rel = rel[2..];
    return try std.fmt.allocPrint(arena, "{s}/{s}", .{ config_dir, rel });
}
