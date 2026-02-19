const std = @import("std");
const Io = std.Io;

const projects = @import("projects");
const clap = @import("clap");

const c = @cImport({
    @cInclude("git2.h");
});

pub fn main(init: std.process.Init) !void {
    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    // Initialize libgit2 - always call this first
    _ = c.git_libgit2_init();
    defer _ = c.git_libgit2_shutdown();

    // First we specify what parameters our program can take.
    // We can use `parseParamsComptime` to parse a string into an array of `Param(Help)`.
    const params = comptime clap.parseParamsComptime(
        \\-h, --help        Display this help and exit.
        \\-d, --depth <int> The depth of directories to scan for projects. Defaults to three levels deep.
        \\<path>            The path to scan for projects
        \\
    );

    const parsers = .{
        .int = clap.parsers.int(usize, 10),
        .path = clap.parsers.string,
    };

    // Initialize our diagnostics, which can be used for reporting useful errors.
    // This is optional. You can also pass `.{}` to `clap.parse` if you don't
    // care about the extra information `Diagnostics` provides.
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
    }) catch |err| {
        // Report useful error and exit.
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(io, .stdout(), clap.Help, &params, .{});
    }

    const directory = res.positionals[0] orelse {
        return try clap.helpToFile(io, .stdout(), clap.Help, &params, .{});
    };

    const depth = res.args.depth orelse 3;

    try scanDirectoryDepth(init.gpa, init.io, directory, depth);

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try projects.printAnotherMessage(stdout_writer);

    std.debug.print("\n", .{});
    try stdout_writer.flush(); // Don't forget to flush!
}

pub fn scanDirectoryDepth(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    max_depth: usize,
) !void {
    try scanDirectoryRecursive(allocator, io, dir_path, max_depth, 0);
}

fn scanDirectoryRecursive(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    max_depth: usize,
    current_depth: usize,
) !void {
    if (current_depth >= max_depth) return;

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    std.debug.print("\n", .{});

    if (current_depth > 0) {
        std.debug.print("|", .{});
    }
    for (0..current_depth) |_| {
        std.debug.print("-", .{});
    }
    std.debug.print(" {s}", .{dir_path});

    // This shouldn't go here...
    // determine if this directory is a known project type.
    if (try determineProjectType(allocator, io, dir, dir_path)) |pt| {
        std.debug.print(" found project: ({s})", .{@tagName(pt.project_type)});
        return;
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .directory) {
            const sub_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            defer allocator.free(sub_path);

            try scanDirectoryRecursive(allocator, io, sub_path, max_depth, current_depth + 1);
        }
    }
}

const ProjectType = enum {
    zig,
    go,
    elixir,
    typescript,
    javascript,
    python,
    ruby,
    c,
    cpp,
    rust,
    java,
    php,
    unknown,
};

const project = struct {
    marker: []const u8,
    project_type: ProjectType,
};

const knownProjectTypes = [_]project{
    // Zig
    .{ .marker = "build.zig", .project_type = .zig },
    .{ .marker = "build.zig.zon", .project_type = .zig },

    // Go
    .{ .marker = "go.mod", .project_type = .go },
    .{ .marker = "go.sum", .project_type = .go },

    // Elixir
    .{ .marker = "mix.exs", .project_type = .elixir },

    // TypeScript
    .{ .marker = "tsconfig.json", .project_type = .typescript },

    // JavaScript/Node
    .{ .marker = "package.json", .project_type = .javascript },

    // Python
    .{ .marker = "pyproject.toml", .project_type = .python },
    .{ .marker = "setup.py", .project_type = .python },
    .{ .marker = "requirements.txt", .project_type = .python },
    .{ .marker = "Pipfile", .project_type = .python },

    // Ruby
    .{ .marker = "Gemfile", .project_type = .ruby },
    .{ .marker = ".ruby-version", .project_type = .ruby },

    // Rust
    .{ .marker = "Cargo.toml", .project_type = .rust },
    .{ .marker = "rust-toolchain.toml", .project_type = .rust },

    // C/C++
    .{ .marker = "CMakeLists.txt", .project_type = .cpp },
    .{ .marker = "configure.ac", .project_type = .c },

    // Java
    .{ .marker = "pom.xml", .project_type = .java },
    .{ .marker = "build.gradle", .project_type = .java },

    // PHP
    .{ .marker = "composer.json", .project_type = .php },
};

fn determineProjectType(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    dir_path: []const u8,
) !?project {
    // In this program project roots must have a git directory
    dir.access(io, ".git", .{}) catch |err| {
        switch (err) {
            error.FileNotFound => return null,
            else => {},
        }
    };
    // We know that we are in a directory that is a git repository...
    // now I'd like to know if there are any uncommitted changes and what the origin is

    const dir_path_z = try allocator.dupeZ(u8, dir_path);
    defer allocator.free(dir_path_z);

    // Open the repository
    var repo: ?*c.git_repository = null;
    const err = c.git_repository_open(&repo, dir_path_z);
    if (err < 0) {
        const e = c.git_error_last();
        std.debug.print("Failed to open repo: {s}\n", .{e.*.message});
        return error.RepoOpenFailed;
    }
    defer c.git_repository_free(repo);

    // --- 1. Print the origin URL ---
    try printOriginUrl(repo);

    // --- 2. Show unpushed commits ---
    try showUnpushedCommits(repo, allocator);

    // --- 3. Show working tree status (untracked, modified, staged) ---
    try showWorkingTreeStatus(repo);

    for (knownProjectTypes) |pt| {
        // is this a zig project
        dir.access(io, pt.marker, .{}) catch continue;
        return pt;
    }
    return null;
}

fn printOriginUrl(repo: ?*c.git_repository) !void {
    var remote: ?*c.git_remote = null;
    const err = c.git_remote_lookup(&remote, repo, "origin");
    if (err < 0) {
        std.debug.print("No 'origin' remote found.\n", .{});
        return;
    }
    defer c.git_remote_free(remote);

    const url = c.git_remote_url(remote);
    std.debug.print("------\n\nOrigin URL: {s}\n\n", .{url});
}

fn showUnpushedCommits(repo: ?*c.git_repository, allocator: std.mem.Allocator) !void {
    _ = allocator;

    // Get HEAD commit OID
    var head_ref: ?*c.git_reference = null;
    var err = c.git_repository_head(&head_ref, repo);
    if (err < 0) {
        std.debug.print("Could not get HEAD (maybe no commits yet?)\n", .{});
        return;
    }
    defer c.git_reference_free(head_ref);

    const local_oid = c.git_reference_target(head_ref);

    // Try to find @{u} (upstream) of HEAD
    var upstream_ref: ?*c.git_reference = null;
    err = c.git_branch_upstream(&upstream_ref, head_ref);
    if (err < 0) {
        std.debug.print("No upstream branch configured for HEAD.\n\n", .{});
        return;
    }
    defer c.git_reference_free(upstream_ref);

    const upstream_oid = c.git_reference_target(upstream_ref);

    // Walk commits reachable from HEAD but not from upstream
    var walk: ?*c.git_revwalk = null;
    _ = c.git_revwalk_new(&walk, repo);
    defer c.git_revwalk_free(walk);

    _ = c.git_revwalk_sorting(walk, c.GIT_SORT_TOPOLOGICAL | c.GIT_SORT_TIME);
    _ = c.git_revwalk_push(walk, local_oid);
    _ = c.git_revwalk_hide(walk, upstream_oid);

    var count: usize = 0;
    var oid: c.git_oid = undefined;

    std.debug.print("------\n\nUnpushed commits (local but not on origin):\n", .{});

    while (c.git_revwalk_next(&oid, walk) == 0) {
        var commit: ?*c.git_commit = null;
        if (c.git_commit_lookup(&commit, repo, &oid) == 0) {
            defer c.git_commit_free(commit);

            var oid_str: [41]u8 = undefined;
            _ = c.git_oid_tostr(&oid_str, oid_str.len, &oid);

            const summary = c.git_commit_summary(commit);
            std.debug.print("  {s}  {s}\n", .{ oid_str[0..7], summary });
            count += 1;
        }
    }

    if (count == 0) {
        std.debug.print("  (none - everything is pushed)\n", .{});
    }
    std.debug.print("\n", .{});
}

fn showWorkingTreeStatus(repo: ?*c.git_repository) !void {
    var opts = c.git_status_options{
        .version = c.GIT_STATUS_OPTIONS_VERSION,
        .show = c.GIT_STATUS_SHOW_INDEX_AND_WORKDIR,
        .flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED |
            c.GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS,
        .pathspec = .{ .strings = null, .count = 0 },
        .baseline = null,
        .rename_threshold = 0,
    };

    var status_list: ?*c.git_status_list = null;
    const err = c.git_status_list_new(&status_list, repo, &opts);
    if (err < 0) {
        std.debug.print("Failed to get status list\n", .{});
        return;
    }
    defer c.git_status_list_free(status_list);

    const count = c.git_status_list_entrycount(status_list);
    std.debug.print("Working tree status ({d} entries):\n", .{count});

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const entry = c.git_status_byindex(status_list, i);
        if (entry == null) continue;

        const status = entry.*.status;
        const path = if (entry.*.index_to_workdir != null)
            entry.*.index_to_workdir.*.new_file.path
        else if (entry.*.head_to_index != null)
            entry.*.head_to_index.*.new_file.path
        else
            @as([*c]const u8, "(unknown)");

        // Staged changes
        if (status & c.GIT_STATUS_INDEX_NEW != 0) std.debug.print("  A  {s}\n", .{path});
        if (status & c.GIT_STATUS_INDEX_MODIFIED != 0) std.debug.print("  M  {s}\n", .{path});
        if (status & c.GIT_STATUS_INDEX_DELETED != 0) std.debug.print("  D  {s}\n", .{path});
        if (status & c.GIT_STATUS_INDEX_RENAMED != 0) std.debug.print("  R  {s}\n", .{path});

        // Unstaged changes
        if (status & c.GIT_STATUS_WT_NEW != 0) std.debug.print("  ?  {s}\n", .{path});
        if (status & c.GIT_STATUS_WT_MODIFIED != 0) std.debug.print("  m  {s}\n", .{path});
        if (status & c.GIT_STATUS_WT_DELETED != 0) std.debug.print("  d  {s}\n", .{path});
    }

    if (count == 0) {
        std.debug.print("  (clean)\n", .{});
    }

    std.debug.print("------\n\n", .{});
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
