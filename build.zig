const std = @import("std");

// MAJOR.MINOR.PATCH default for local/dev builds. CI overrides with
// `-Dversion=MAJOR.MINOR.<run>` so the compiled binary's version matches the
// release tag (see .github/workflows/release.yml). Mirrors how the old TS build
// inlined package.json's version.
const DEFAULT_VERSION = "0.1.0";
const REPO = "ohidurbappy/orb";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = b.option([]const u8, "version", "Version string baked into the binary") orelse DEFAULT_VERSION;

    // build_options: compile-time constants the binary reads (version, repo).
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "repo", REPO);

    const exe = b.addExecutable(.{
        .name = "orb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);

    // `zig build run -- <args>`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run orb");
    run_step.dependOn(&run_cmd.step);

    // Tests: src/tests.zig references every module so all `test` blocks run.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addOptions("build_options", options);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(&run_tests.step);
}
