//! Git context evaluation — reads .git directly (no git binary fork).
//!
//! Lookup strategy:
//!   1. Walk up from CWD looking for ".git".
//!   2. If ".git" is a directory: use it as the gitdir.
//!   3. If ".git" is a file: parse "gitdir: <path>" → that's the gitdir
//!      (worktree case). HEAD lives inside the worktree's gitdir.
//!   4. Read HEAD → branch name (ref: refs/heads/<name>) or "" if detached.
//!   5. Read config → [remote "origin"] url → repo+org.
//!
//! All values default to empty string when not available.

const std = @import("std");
const Io = std.Io;

pub const Context = struct {
    repo: []const u8 = "",
    org: []const u8 = "",
    branch: []const u8 = "",
    /// Basename of cwd. Used for `<current_dir>` interpolation.
    current_dir: []const u8 = "",
    /// Absolute path of cwd. Used for `<current_dir:...>` glob matching.
    current_path: []const u8 = "",
};

pub const Needed = struct {
    repo: bool = false,
    org: bool = false,
    branch: bool = false,
    /// Basename of cwd (interpolation).
    current_dir: bool = false,
    /// Absolute path of cwd (condition matching).
    current_path: bool = false,
};

/// Build the context, performing only the I/O required by `needed`.
///
/// `cwd` is the absolute path of the current working directory. `arena`
/// owns all returned strings.
pub fn build(arena: std.mem.Allocator, io: Io, cwd: []const u8, needed: Needed) !Context {
    var ctx: Context = .{};

    if (needed.current_dir) {
        ctx.current_dir = try arena.dupe(u8, std.fs.path.basename(cwd));
    }
    if (needed.current_path) {
        ctx.current_path = try arena.dupe(u8, cwd);
    }

    if (!needed.repo and !needed.org and !needed.branch) {
        return ctx;
    }

    const gitdir_path = (try findGitDir(arena, io, cwd)) orelse return ctx;

    if (needed.branch) {
        ctx.branch = try readBranch(arena, io, gitdir_path);
    }
    if (needed.repo or needed.org) {
        const url = try readOriginUrl(arena, io, gitdir_path);
        const parsed = parseOriginUrl(url);
        if (needed.repo) ctx.repo = try arena.dupe(u8, parsed.repo);
        if (needed.org) ctx.org = try arena.dupe(u8, parsed.org);
    }

    return ctx;
}

const GitFound = struct {
    is_dir: bool,
    path: []const u8,
};

/// Probe `<dir>/.git`. Returns the kind+path when present, null otherwise.
fn probeDotGit(arena: std.mem.Allocator, io: Io, dir: []const u8) !?GitFound {
    const candidate = try std.fs.path.join(arena, &.{ dir, ".git" });
    // Try as directory first.
    if (Io.Dir.cwd().openDir(io, candidate, .{})) |d| {
        var dd = d;
        dd.close(io);
        return .{ .is_dir = true, .path = candidate };
    } else |err| switch (err) {
        error.NotDir => {}, // It's a file — fall through to file branch.
        else => return null,
    }
    // Try as regular file.
    if (Io.Dir.cwd().openFile(io, candidate, .{})) |f| {
        f.close(io);
        return .{ .is_dir = false, .path = candidate };
    } else |_| {
        return null;
    }
}

/// Walk up from `cwd` looking for ".git". If found as a directory, return
/// its absolute path. If found as a file (gitfile, used by worktrees),
/// follow the "gitdir:" pointer. Returns null if not in a git repo.
fn findGitDir(arena: std.mem.Allocator, io: Io, cwd: []const u8) !?[]const u8 {
    var current: []const u8 = cwd;

    while (true) {
        if (try probeDotGit(arena, io, current)) |found| {
            if (found.is_dir) return found.path;
            // gitfile: "gitdir: <path>\n"
            const contents = Io.Dir.cwd().readFileAlloc(io, found.path, arena, .limited(4096)) catch return null;
            const trimmed = std.mem.trim(u8, contents, " \t\r\n");
            const prefix = "gitdir:";
            if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
            const raw = std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
            if (std.fs.path.isAbsolute(raw)) {
                return try arena.dupe(u8, raw);
            }
            return try std.fs.path.resolve(arena, &.{ current, raw });
        }
        // Move up one directory.
        if (current.len == 0) return null;
        if (current.len == 1 and current[0] == '/') return null;
        const parent = std.fs.path.dirname(current) orelse return null;
        if (parent.len == current.len) return null;
        current = parent;
    }
}

/// Read HEAD from `gitdir`. Returns branch name, or "" if detached/unreadable.
fn readBranch(arena: std.mem.Allocator, io: Io, gitdir: []const u8) ![]const u8 {
    const head_path = try std.fs.path.join(arena, &.{ gitdir, "HEAD" });
    const contents = Io.Dir.cwd().readFileAlloc(io, head_path, arena, .limited(4096)) catch return "";
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    const ref_prefix = "ref: refs/heads/";
    if (std.mem.startsWith(u8, trimmed, ref_prefix)) {
        return try arena.dupe(u8, trimmed[ref_prefix.len..]);
    }
    return "";
}

/// Resolve the directory that contains `config` for a given `gitdir`.
///
/// For a normal repo this is `gitdir` itself. For a worktree, `gitdir` is
/// the per-worktree directory (e.g. `<main>/.git/worktrees/<name>`); its
/// `config` lives in the main repo's `.git` directory, reachable via the
/// `commondir` file. The file may contain an absolute path or a relative
/// one (resolved against `gitdir`).
///
/// Falls back to `gitdir` itself when `commondir` is missing or empty.
pub fn resolveConfigDir(arena: std.mem.Allocator, io: Io, gitdir: []const u8) ![]const u8 {
    const commondir_path = try std.fs.path.join(arena, &.{ gitdir, "commondir" });
    const raw = Io.Dir.cwd().readFileAlloc(io, commondir_path, arena, .limited(4096)) catch return gitdir;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return gitdir;
    if (std.fs.path.isAbsolute(trimmed)) return try arena.dupe(u8, trimmed);
    return try std.fs.path.resolve(arena, &.{ gitdir, trimmed });
}

/// Read [remote "origin"].url from the repo config. For worktrees the
/// config lives in the main repo (reached via `commondir`), not in the
/// per-worktree gitdir. Returns "" if not found.
pub fn readOriginUrl(arena: std.mem.Allocator, io: Io, gitdir: []const u8) ![]const u8 {
    const cfg_dir = try resolveConfigDir(arena, io, gitdir);
    const cfg_path = try std.fs.path.join(arena, &.{ cfg_dir, "config" });
    const contents = Io.Dir.cwd().readFileAlloc(io, cfg_path, arena, .limited(1 * 1024 * 1024)) catch return "";
    return findOriginUrl(contents);
}

/// In-place scan of a git config file for the `url` under `[remote "origin"]`.
/// Returns a slice of `contents` (no alloc) or "".
pub fn findOriginUrl(contents: []const u8) []const u8 {
    var in_origin = false;
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const header = std.mem.trim(u8, line[1..end], " \t");
            in_origin = isOriginHeader(header);
            continue;
        }

        if (!in_origin) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, key, "url")) continue;
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        // Strip optional surrounding quotes.
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        }
        return val;
    }
    return "";
}

fn isOriginHeader(header: []const u8) bool {
    // Accept: remote "origin"
    if (!std.mem.startsWith(u8, header, "remote")) return false;
    const rest = std.mem.trim(u8, header[6..], " \t");
    if (rest.len < 2) return false;
    if (rest[0] != '"' or rest[rest.len - 1] != '"') return false;
    return std.mem.eql(u8, rest[1 .. rest.len - 1], "origin");
}

pub const ParsedUrl = struct {
    repo: []const u8,
    org: []const u8,
};

/// Parse an origin URL into repo/org components.
///   - Strip trailing ".git"
///   - repo = basename
///   - org  = second-to-last segment after splitting on '/' or ':'
pub fn parseOriginUrl(url: []const u8) ParsedUrl {
    if (url.len == 0) return .{ .repo = "", .org = "" };

    var s = url;
    if (std.mem.endsWith(u8, s, ".git")) s = s[0 .. s.len - 4];

    // Find last and second-to-last separator (':' or '/').
    var last_sep: ?usize = null;
    var second_last: ?usize = null;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '/' or s[i] == ':') {
            second_last = last_sep;
            last_sep = i;
        }
    }
    const repo: []const u8 = if (last_sep) |idx| s[idx + 1 ..] else s;
    const org: []const u8 = if (last_sep) |last| blk: {
        const start = if (second_last) |sl| sl + 1 else 0;
        break :blk s[start..last];
    } else "";
    return .{ .repo = repo, .org = org };
}
