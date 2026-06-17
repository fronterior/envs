//! Unit tests entry point — `zig build test`.

const std = @import("std");

const context = @import("context.zig");
const rule_mod = @import("rule.zig");
const interp = @import("interp.zig");

// ----- context.parseOriginUrl -----

test "parseOriginUrl: ssh github" {
    const r = context.parseOriginUrl("git@github.com:ridi/myapp.git");
    try std.testing.expectEqualStrings("myapp", r.repo);
    try std.testing.expectEqualStrings("ridi", r.org);
}

test "parseOriginUrl: https github" {
    const r = context.parseOriginUrl("https://github.com/ridi/myapp.git");
    try std.testing.expectEqualStrings("myapp", r.repo);
    try std.testing.expectEqualStrings("ridi", r.org);
}

test "parseOriginUrl: no .git suffix" {
    const r = context.parseOriginUrl("https://github.com/ridi/myapp");
    try std.testing.expectEqualStrings("myapp", r.repo);
    try std.testing.expectEqualStrings("ridi", r.org);
}

test "parseOriginUrl: empty" {
    const r = context.parseOriginUrl("");
    try std.testing.expectEqualStrings("", r.repo);
    try std.testing.expectEqualStrings("", r.org);
}

// ----- context.findOriginUrl -----

test "findOriginUrl: standard config" {
    const cfg = "[core]\n    repositoryformatversion = 0\n[remote \"origin\"]\n    url = git@github.com:ridi/myapp.git\n    fetch = +refs/heads/*:refs/remotes/origin/*\n";
    const url = context.findOriginUrl(cfg);
    try std.testing.expectEqualStrings("git@github.com:ridi/myapp.git", url);
}

test "findOriginUrl: no origin section" {
    const cfg = "[core]\n    repositoryformatversion = 0\n";
    const url = context.findOriginUrl(cfg);
    try std.testing.expectEqualStrings("", url);
}

test "findOriginUrl: with comments and quoted url" {
    const cfg = "# comment\n[remote \"origin\"]\n    url = \"https://github.com/ridi/myapp.git\"\n";
    const url = context.findOriginUrl(cfg);
    try std.testing.expectEqualStrings("https://github.com/ridi/myapp.git", url);
}

// ----- context.readOriginUrl + resolveConfigDir (worktree support) -----
//
// Each test builds a mock layout inside std.testing.tmpDir() and exercises
// readOriginUrl with absolute paths so std.fs.path.resolve behaves the same
// as in production (where gitdir is always absolute).

const test_origin_cfg = "[core]\n    repositoryformatversion = 0\n[remote \"origin\"]\n    url = git@github.com:ridi/myapp.git\n";

fn dupeAbs(arena: std.mem.Allocator, dir: std.Io.Dir, sub: []const u8) ![]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try dir.realPathFile(std.testing.io, sub, &buf);
    return try arena.dupe(u8, buf[0..n]);
}

test "readOriginUrl: regular repo reads gitdir/config directly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tio = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Layout: <tmp>/regular/.git/config
    try tmp.dir.createDirPath(tio, "regular/.git");
    try tmp.dir.writeFile(tio, .{ .sub_path = "regular/.git/config", .data = test_origin_cfg });

    const gitdir = try dupeAbs(a, tmp.dir, "regular/.git");
    const url = try context.readOriginUrl(a, tio, gitdir);
    try std.testing.expectEqualStrings("git@github.com:ridi/myapp.git", url);
}

test "readOriginUrl: worktree with absolute commondir reads main repo config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tio = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Layout:
    //   <tmp>/main/.git/config                  ← real config
    //   <tmp>/main/.git/worktrees/wt/commondir  ← absolute path to <tmp>/main/.git
    try tmp.dir.createDirPath(tio, "main/.git/worktrees/wt");
    try tmp.dir.writeFile(tio, .{ .sub_path = "main/.git/config", .data = test_origin_cfg });
    const main_gitdir_abs = try dupeAbs(a, tmp.dir, "main/.git");
    try tmp.dir.writeFile(tio, .{ .sub_path = "main/.git/worktrees/wt/commondir", .data = main_gitdir_abs });

    const wt_gitdir = try dupeAbs(a, tmp.dir, "main/.git/worktrees/wt");
    const url = try context.readOriginUrl(a, tio, wt_gitdir);
    try std.testing.expectEqualStrings("git@github.com:ridi/myapp.git", url);
}

test "readOriginUrl: worktree with relative commondir reads main repo config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tio = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Layout same as absolute case, but commondir holds "../..\n" — the
    // standard relative form git writes for worktrees.
    try tmp.dir.createDirPath(tio, "main/.git/worktrees/wt");
    try tmp.dir.writeFile(tio, .{ .sub_path = "main/.git/config", .data = test_origin_cfg });
    try tmp.dir.writeFile(tio, .{ .sub_path = "main/.git/worktrees/wt/commondir", .data = "../..\n" });

    const wt_gitdir = try dupeAbs(a, tmp.dir, "main/.git/worktrees/wt");
    const url = try context.readOriginUrl(a, tio, wt_gitdir);
    try std.testing.expectEqualStrings("git@github.com:ridi/myapp.git", url);
}

test "readOriginUrl: missing commondir falls back to gitdir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tio = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // No commondir file — same shape as a regular repo. Must read gitdir/config.
    try tmp.dir.createDirPath(tio, "plain/.git");
    try tmp.dir.writeFile(tio, .{ .sub_path = "plain/.git/config", .data = test_origin_cfg });

    const gitdir = try dupeAbs(a, tmp.dir, "plain/.git");
    const url = try context.readOriginUrl(a, tio, gitdir);
    try std.testing.expectEqualStrings("git@github.com:ridi/myapp.git", url);
}

test "readOriginUrl: empty commondir falls back to gitdir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tio = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // commondir present but empty (whitespace only) — fallback to gitdir.
    try tmp.dir.createDirPath(tio, "empty/.git");
    try tmp.dir.writeFile(tio, .{ .sub_path = "empty/.git/config", .data = test_origin_cfg });
    try tmp.dir.writeFile(tio, .{ .sub_path = "empty/.git/commondir", .data = "   \n" });

    const gitdir = try dupeAbs(a, tmp.dir, "empty/.git");
    const url = try context.readOriginUrl(a, tio, gitdir);
    try std.testing.expectEqualStrings("git@github.com:ridi/myapp.git", url);
}

test "readOriginUrl: commondir target without config returns empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tio = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // commondir points to a dir that exists but has no `config` file — fail-open ("").
    try tmp.dir.createDirPath(tio, "main/.git/worktrees/wt");
    const main_gitdir_abs = try dupeAbs(a, tmp.dir, "main/.git");
    try tmp.dir.writeFile(tio, .{ .sub_path = "main/.git/worktrees/wt/commondir", .data = main_gitdir_abs });

    const wt_gitdir = try dupeAbs(a, tmp.dir, "main/.git/worktrees/wt");
    const url = try context.readOriginUrl(a, tio, wt_gitdir);
    try std.testing.expectEqualStrings("", url);
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

// ----- evalConditions -----

test "evalConditions: AND match" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = try rule_mod.parseLine(a, "<repo:myapp,branch:main>dev:.env");
    const ctx: context.Context = .{ .repo = "myapp", .branch = "main" };
    try std.testing.expectEqual(rule_mod.ConditionResult.matched, rule_mod.evalConditions(r.rule.?, ctx));
}

test "evalConditions: AND one mismatch" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = try rule_mod.parseLine(a, "<repo:myapp,branch:main>dev:.env");
    const ctx: context.Context = .{ .repo = "myapp", .branch = "feature" };
    try std.testing.expectEqual(rule_mod.ConditionResult.not_matched, rule_mod.evalConditions(r.rule.?, ctx));
}

test "evalConditions: empty context value never matches" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = try rule_mod.parseLine(a, "<repo:myapp>dev:.env");
    const ctx: context.Context = .{ .repo = "" };
    try std.testing.expectEqual(rule_mod.ConditionResult.not_matched, rule_mod.evalConditions(r.rule.?, ctx));
}

test "evalConditions: current_dir bare substring (legacy compat)" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = try rule_mod.parseLine(a, "<current_dir:myapp>dev:.env");
    const ctx: context.Context = .{ .current_path = "/Users/me/code/myapp" };
    try std.testing.expectEqual(rule_mod.ConditionResult.matched, rule_mod.evalConditions(r.rule.?, ctx));
}

test "evalConditions: current_dir bare substring matches anywhere (intentional)" {
    // Bare "foo" is a substring match — this is the looser legacy form.
    // Tighter match needs `*/foo` (suffix) or `*/foo/*` (segment).
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = try rule_mod.parseLine(a, "<current_dir:foo>dev:.env");
    const ctx: context.Context = .{ .current_path = "/x/foobar/y" };
    try std.testing.expectEqual(rule_mod.ConditionResult.matched, rule_mod.evalConditions(r.rule.?, ctx));
}

test "evalConditions: current_dir suffix `*/foo` matches last segment only" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = try rule_mod.parseLine(a, "<current_dir:*/foo>dev:.env");
    const ctx_hit: context.Context = .{ .current_path = "/a/b/foo" };
    const ctx_miss: context.Context = .{ .current_path = "/a/foo/bar" };
    const ctx_partial: context.Context = .{ .current_path = "/a/foobar" };
    try std.testing.expectEqual(rule_mod.ConditionResult.matched, rule_mod.evalConditions(r.rule.?, ctx_hit));
    try std.testing.expectEqual(rule_mod.ConditionResult.not_matched, rule_mod.evalConditions(r.rule.?, ctx_miss));
    try std.testing.expectEqual(rule_mod.ConditionResult.not_matched, rule_mod.evalConditions(r.rule.?, ctx_partial));
}

test "evalConditions: current_dir segment `*/foo/*` matches inner segment" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = try rule_mod.parseLine(a, "<current_dir:*/foo/*>dev:.env");
    const ctx_hit: context.Context = .{ .current_path = "/a/foo/bar" };
    const ctx_miss_tail: context.Context = .{ .current_path = "/a/b/foo" };
    const ctx_miss_partial: context.Context = .{ .current_path = "/a/foobar/x" };
    try std.testing.expectEqual(rule_mod.ConditionResult.matched, rule_mod.evalConditions(r.rule.?, ctx_hit));
    try std.testing.expectEqual(rule_mod.ConditionResult.not_matched, rule_mod.evalConditions(r.rule.?, ctx_miss_tail));
    try std.testing.expectEqual(rule_mod.ConditionResult.not_matched, rule_mod.evalConditions(r.rule.?, ctx_miss_partial));
}

test "matchCurrentDir: bare substring" {
    try std.testing.expect(rule_mod.matchCurrentDir("/a/foo/b", "foo"));
    try std.testing.expect(rule_mod.matchCurrentDir("/a/foobar/b", "foo"));
    try std.testing.expect(!rule_mod.matchCurrentDir("/a/bar", "foo"));
}

test "matchCurrentDir: `*/foo` suffix" {
    try std.testing.expect(rule_mod.matchCurrentDir("/x/foo", "*/foo"));
    try std.testing.expect(rule_mod.matchCurrentDir("/foo", "*/foo"));
    try std.testing.expect(!rule_mod.matchCurrentDir("/x/foo/y", "*/foo"));
    try std.testing.expect(!rule_mod.matchCurrentDir("/x/foobar", "*/foo"));
}

test "matchCurrentDir: `*/foo/` accepts trailing slash" {
    try std.testing.expect(rule_mod.matchCurrentDir("/x/foo", "*/foo/"));
    try std.testing.expect(rule_mod.matchCurrentDir("/x/foo/", "*/foo/"));
    try std.testing.expect(!rule_mod.matchCurrentDir("/x/foo/y", "*/foo/"));
    try std.testing.expect(!rule_mod.matchCurrentDir("/x/foobar", "*/foo/"));
}

test "matchCurrentDir: `*/foo/*` segment" {
    try std.testing.expect(rule_mod.matchCurrentDir("/x/foo/y", "*/foo/*"));
    try std.testing.expect(rule_mod.matchCurrentDir("/foo/y", "*/foo/*"));
    try std.testing.expect(!rule_mod.matchCurrentDir("/x/foo", "*/foo/*"));
    try std.testing.expect(!rule_mod.matchCurrentDir("/x/foobar/y", "*/foo/*"));
}

test "matchCurrentDir: disambiguates sampleapp-dev vs sampleapp-dev2" {
    // The very scenario that motivated the spec change. With `*/sampleapp-dev`
    // the pattern only matches when sampleapp-dev is the last path segment.
    try std.testing.expect(rule_mod.matchCurrentDir(
        "/Users/me/worktrees/sampleapp-dev",
        "*/sampleapp-dev",
    ));
    try std.testing.expect(!rule_mod.matchCurrentDir(
        "/Users/me/worktrees/sampleapp-dev2",
        "*/sampleapp-dev",
    ));
}

test "evalConditions: unknown key" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = try rule_mod.parseLine(a, "<rpeo:myapp>dev:.env");
    const ctx: context.Context = .{ .repo = "myapp" };
    try std.testing.expectEqual(rule_mod.ConditionResult.unknown_key, rule_mod.evalConditions(r.rule.?, ctx));
}

// ----- analyzeNeeded -----

test "analyzeNeeded: current_dir condition needs current_path (not basename)" {
    const arena_a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_a);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var rules: std.ArrayList(rule_mod.Rule) = .empty;
    const p = try rule_mod.parseLine(a, "<current_dir:myapp>dev:.env");
    try rules.append(a, p.rule.?);
    const report = rule_mod.analyzeNeeded(rules.items);
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
    const report = rule_mod.analyzeNeeded(rules.items);
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
    const report = rule_mod.analyzeNeeded(rules.items);
    try std.testing.expect(report.needed.repo);
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
