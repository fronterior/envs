//! Unit tests entry point — `zig build test`.
//!
//! Scope: pure string/struct functions only. Runtime behaviour (rule matching,
//! git context resolution, worktrees, warnings) is proven end-to-end against the
//! real binary in tests/*.bats — see tests/envs-routing.bats and
//! tests/envs-context-git.bats. Things that are awkward or redundant to cover via
//! e2e (URL string parsing variants, config-line parsing, path interpolation)
//! stay here.

const std = @import("std");

const context = @import("context.zig");
const rule_mod = @import("rule.zig");
const interp = @import("interp.zig");

// ----- context.parseOriginUrl -----

test "parseOriginUrl: ssh github" {
    const r = context.parseOriginUrl("git@github.com:octocat/myapp.git");
    try std.testing.expectEqualStrings("myapp", r.repo);
    try std.testing.expectEqualStrings("octocat", r.org);
}

test "parseOriginUrl: https github" {
    const r = context.parseOriginUrl("https://github.com/octocat/myapp.git");
    try std.testing.expectEqualStrings("myapp", r.repo);
    try std.testing.expectEqualStrings("octocat", r.org);
}

test "parseOriginUrl: no .git suffix" {
    const r = context.parseOriginUrl("https://github.com/octocat/myapp");
    try std.testing.expectEqualStrings("myapp", r.repo);
    try std.testing.expectEqualStrings("octocat", r.org);
}

test "parseOriginUrl: empty" {
    const r = context.parseOriginUrl("");
    try std.testing.expectEqualStrings("", r.repo);
    try std.testing.expectEqualStrings("", r.org);
}

// ----- context.findOriginUrl -----

test "findOriginUrl: standard config" {
    const cfg = "[core]\n    repositoryformatversion = 0\n[remote \"origin\"]\n    url = git@github.com:octocat/myapp.git\n    fetch = +refs/heads/*:refs/remotes/origin/*\n";
    const url = context.findOriginUrl(cfg);
    try std.testing.expectEqualStrings("git@github.com:octocat/myapp.git", url);
}

test "findOriginUrl: no origin section" {
    const cfg = "[core]\n    repositoryformatversion = 0\n";
    const url = context.findOriginUrl(cfg);
    try std.testing.expectEqualStrings("", url);
}

test "findOriginUrl: with comments and quoted url" {
    const cfg = "# comment\n[remote \"origin\"]\n    url = \"https://github.com/octocat/myapp.git\"\n";
    const url = context.findOriginUrl(cfg);
    try std.testing.expectEqualStrings("https://github.com/octocat/myapp.git", url);
}

// ----- rule parser -----

test "parseLine: blank/comment skipped" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r1 = try rule_mod.parseLine(a, "");
    try std.testing.expect(r1.rule == null);
    const r2 = try rule_mod.parseLine(a, "  # comment");
    try std.testing.expect(r2.rule == null);
}

test "parseLine: with conds and path interp" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = try rule_mod.parseLine(a, "<repo:foo,branch:main>dev:~/envs/<repo>/.env.dev");
    try std.testing.expect(r.rule != null);
    const rule = r.rule.?;
    try std.testing.expectEqual(@as(usize, 2), rule.conds.len);
    try std.testing.expectEqualStrings("repo", rule.conds[0].key_str);
    try std.testing.expectEqualStrings("foo", rule.conds[0].value);
    try std.testing.expectEqualStrings("branch", rule.conds[1].key_str);
    try std.testing.expectEqualStrings("main", rule.conds[1].value);
    try std.testing.expectEqualStrings("dev", rule.env_name);
    try std.testing.expectEqualStrings("~/envs/<repo>/.env.dev", rule.path_template);
}

test "parseLine: no conds, empty env_name" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = try rule_mod.parseLine(a, ":/abs/path/.env");
    try std.testing.expect(r.rule != null);
    try std.testing.expectEqual(@as(usize, 0), r.rule.?.conds.len);
    try std.testing.expectEqualStrings("", r.rule.?.env_name);
    try std.testing.expectEqualStrings("/abs/path/.env", r.rule.?.path_template);
}

test "parseLine: malformed missing colon" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = try rule_mod.parseLine(a, "<repo:foo>dev_path_no_colon");
    try std.testing.expect(r.rule == null);
    try std.testing.expectEqual(rule_mod.ParseError.malformed_line, r.err);
}

// ----- analyzeNeeded (which context fields a config needs) -----

test "analyzeNeeded: current_dir condition needs current_path (not basename)" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var rules: std.ArrayList(rule_mod.Rule) = .empty;
    const p = try rule_mod.parseLine(a, "<current_dir:myapp>dev:.env");
    try rules.append(a, p.rule.?);
    const report = try rule_mod.analyzeNeeded(a, rules.items);
    try std.testing.expect(report.needed.current_path);
    try std.testing.expect(!report.needed.current_dir);
    try std.testing.expect(!report.needed.repo);
    try std.testing.expect(!report.needed.org);
    try std.testing.expect(!report.needed.branch);
}

test "analyzeNeeded: current_dir interp pulls basename" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var rules: std.ArrayList(rule_mod.Rule) = .empty;
    const p = try rule_mod.parseLine(a, "dev:./<current_dir>/.env");
    try rules.append(a, p.rule.?);
    const report = try rule_mod.analyzeNeeded(a, rules.items);
    try std.testing.expect(report.needed.current_dir);
    try std.testing.expect(!report.needed.current_path);
}

test "analyzeNeeded: path interp pulls repo" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var rules: std.ArrayList(rule_mod.Rule) = .empty;
    const p = try rule_mod.parseLine(a, "dev:~/envs/<repo>/.env");
    try rules.append(a, p.rule.?);
    const report = try rule_mod.analyzeNeeded(a, rules.items);
    try std.testing.expect(report.needed.repo);
}

test "analyzeNeeded: collects unsupported current_dir patterns" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var rules: std.ArrayList(rule_mod.Rule) = .empty;
    try rules.append(a, (try rule_mod.parseLine(a, "<current_dir:a/*/b>dev:.env")).rule.?);
    try rules.append(a, (try rule_mod.parseLine(a, "<current_dir:*/foo>dev:.env")).rule.?); // supported
    try rules.append(a, (try rule_mod.parseLine(a, "<current_dir:foo*>dev:.env")).rule.?);
    try rules.append(a, (try rule_mod.parseLine(a, "<current_dir:bare>dev:.env")).rule.?); // supported

    const report = try rule_mod.analyzeNeeded(a, rules.items);
    try std.testing.expectEqual(@as(usize, 2), report.unsupported_current_dir.len);
    try std.testing.expectEqualStrings("a/*/b", report.unsupported_current_dir[0]);
    try std.testing.expectEqualStrings("foo*", report.unsupported_current_dir[1]);
}

// ----- interpolation -----

test "interpolate: basic" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const ctx: context.Context = .{ .repo = "myapp", .current_dir = "sub" };
    const r = try interp.interpolate(a, "~/envs/<repo>/<current_dir>/.env", "dev", ctx);
    try std.testing.expectEqual(interp.InterpError.none, r.err);
    try std.testing.expectEqualStrings("~/envs/myapp/sub/.env", r.path);
}

test "interpolate: name placeholder" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const ctx: context.Context = .{};
    const r = try interp.interpolate(a, ".env.<name>", "prod", ctx);
    try std.testing.expectEqual(interp.InterpError.none, r.err);
    try std.testing.expectEqualStrings(".env.prod", r.path);
}

test "interpolate: empty variable" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const ctx: context.Context = .{ .repo = "" };
    const r = try interp.interpolate(a, "~/<repo>/.env", "dev", ctx);
    try std.testing.expectEqual(interp.InterpError.empty_variable, r.err);
}

test "interpolate: unknown keyword" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const ctx: context.Context = .{};
    const r = try interp.interpolate(a, "~/<foo>/.env", "dev", ctx);
    try std.testing.expectEqual(interp.InterpError.unknown_keyword, r.err);
    try std.testing.expectEqualStrings("<foo>", r.bad_token);
}

test "interpolate: key:value not interpolated" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const ctx: context.Context = .{};
    const r = try interp.interpolate(a, "<foo:bar>/.env", "dev", ctx);
    try std.testing.expectEqual(interp.InterpError.none, r.err);
    try std.testing.expectEqualStrings("<foo:bar>/.env", r.path);
}

// ----- path resolution -----

test "resolvePath: absolute" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = try interp.resolvePath(a, "/abs/path/.env", "/h", "/c");
    try std.testing.expectEqualStrings("/abs/path/.env", r);
}

test "resolvePath: tilde" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = try interp.resolvePath(a, "~/envs/.env", "/Users/me", "/c");
    try std.testing.expectEqualStrings("/Users/me/envs/.env", r);
}

test "resolvePath: relative goes under config_dir" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = try interp.resolvePath(a, ".env.dev", "/h", "/c");
    try std.testing.expectEqualStrings("/c/.env.dev", r);
}

test "resolvePath: ./ prefix stripped" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = try interp.resolvePath(a, "./.env.dev", "/h", "/c");
    try std.testing.expectEqualStrings("/c/.env.dev", r);
}
