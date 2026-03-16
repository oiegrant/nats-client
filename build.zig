// This file is licensed under the CC0 1.0 license.
// See: https://creativecommons.org/publicdomain/zero/1.0/legalcode
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Fetch the raw nats.c C source
    const nats_c_src = b.dependency("nats_c_src", .{});
    const src_root = nats_c_src.path("src");

    // Build nats.c static library using Zig 0.15 addLibrary API
    const nats_lib = b.addLibrary(.{
        .name = "nats",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });

    const cflags: []const []const u8 = &.{};

    nats_lib.linkLibC();
    // common_sources excludes glib_dispatch_pool.c — we compile a patched copy instead
    nats_lib.addCSourceFiles(.{
        .root = src_root,
        .files = common_sources,
        .flags = cflags,
    });
    // Patched glib_dispatch_pool.c: guards memcpy(dst, NULL, 0) UB that crashes on GCC 15+
    nats_lib.addCSourceFiles(.{
        .root = b.path("patches"),
        .files = &.{"glib_dispatch_pool.c"},
        .flags = cflags,
    });
    nats_lib.addIncludePath(nats_c_src.path("include"));
    // glib internals need the upstream src/ and src/glib/ on the include path
    nats_lib.addIncludePath(src_root);
    nats_lib.addIncludePath(nats_c_src.path("src/glib"));

    const tinfo = target.result;
    if (tinfo.os.tag.isDarwin()) {
        nats_lib.root_module.addCMacro("DARWIN", "");
        nats_lib.addCSourceFiles(.{
            .root = src_root,
            .files = unix_sources,
            .flags = cflags,
        });
    } else if (tinfo.os.tag == .windows) {
        nats_lib.addCSourceFiles(.{
            .root = src_root,
            .files = win_sources,
            .flags = cflags,
        });
        nats_lib.linkSystemLibrary("ws2_32");
    } else {
        nats_lib.root_module.addCMacro("_GNU_SOURCE", "");
        nats_lib.root_module.addCMacro("LINUX", "");
        nats_lib.addCSourceFiles(.{
            .root = src_root,
            .files = unix_sources,
            .flags = cflags,
        });
        if (!tinfo.abi.isAndroid()) {
            nats_lib.linkSystemLibrary("pthread");
            nats_lib.linkSystemLibrary("rt");
        }
    }

    nats_lib.root_module.addCMacro("_REENTRANT", "");
    // NATS_HAS_STREAMING intentionally not defined — disables stan/protobuf-c dependency

    for (install_headers) |header| {
        nats_lib.installHeader(
            nats_c_src.path(b.pathJoin(&.{ "src", header })),
            b.pathJoin(&.{ "nats", header }),
        );
    }

    b.installArtifact(nats_lib);

    // Zig wrapper module
    const nats = b.addModule("nats", .{
        .root_source_file = b.path("src/nats.zig"),
    });
    nats.linkLibrary(nats_lib);

    // Tests
    const tests = b.addTest(.{
        .name = "nats-zig-unit-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("nats", nats);
    tests.linkLibrary(nats_lib);

    const run_main_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addInstallArtifact(tests, .{}).step);
    test_step.dependOn(&run_main_tests.step);

    add_examples(b, .{
        .target = target,
        .optimize = optimize,
        .nats_module = nats,
    });
}

const ExampleOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    nats_module: *std.Build.Module,
};

const Example = struct {
    name: []const u8,
    file: []const u8,
};

const examples = [_]Example{
    .{ .name = "request_reply", .file = "examples/request_reply.zig" },
    .{ .name = "headers", .file = "examples/headers.zig" },
    .{ .name = "pub_bytes", .file = "examples/pub_bytes.zig" },
};

pub fn add_examples(b: *std.Build, options: ExampleOptions) void {
    const example_step = b.step("examples", "build examples");

    inline for (examples) |example| {
        const ex_exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.file),
                .target = options.target,
                .optimize = .Debug,
            }),
        });

        ex_exe.root_module.addImport("nats", options.nats_module);

        const install = b.addInstallArtifact(ex_exe, .{});
        example_step.dependOn(&install.step);
    }
}

const install_headers: []const []const u8 = &.{
    "nats.h",
    "status.h",
    "version.h",
};

const common_sources: []const []const u8 = &.{
    "asynccb.c",
    "comsock.c",
    "crypto.c",
    "dispatch.c",
    "glib/glib.c",
    "glib/glib_async_cb.c",
    // glib/glib_dispatch_pool.c — compiled from patches/ (GCC 15 null-ptr fix)
    "glib/glib_gc.c",
    "glib/glib_last_error.c",
    "glib/glib_ssl.c",
    "glib/glib_timer.c",
    "js.c",
    "kv.c",
    "nats.c",
    "nkeys.c",
    "opts.c",
    "pub.c",
    "stats.c",
    "sub.c",
    "url.c",
    "buf.c",
    "conn.c",
    "hash.c",
    "jsm.c",
    "msg.c",
    "natstime.c",
    "nuid.c",
    "parser.c",
    "srvpool.c",
    "status.c",
    "timer.c",
    "util.c",
};

const unix_sources: []const []const u8 = &.{
    "unix/cond.c",
    "unix/mutex.c",
    "unix/sock.c",
    "unix/thread.c",
};

const win_sources: []const []const u8 = &.{
    "win/cond.c",
    "win/mutex.c",
    "win/sock.c",
    "win/strings.c",
    "win/thread.c",
};
