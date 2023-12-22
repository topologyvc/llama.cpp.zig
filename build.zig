const std = @import("std");
const llama = @import("build_llama.zig");
const CrossTarget = std.zig.CrossTarget;
const ArrayList = std.ArrayList;
const CompileStep = std.Build.CompileStep;
const ConfigHeader = std.Build.Step.ConfigHeader;
const Mode = std.builtin.Mode;
const TranslateCStep = std.Build.TranslateCStep;
const Module = std.Build.Module;

const clblast = @import("clblast");

const llama_cpp_path_prefix = "llama.cpp/"; // point to where llama.cpp root is

pub const Options = struct {
    target: CrossTarget,
    optimize: Mode,
    lto: bool = false,
    opencl: ?clblast.OpenCL = null,
    clblast: bool = false,
};

/// Build context
pub const Context = struct {
    const Self = @This();
    llama: llama.Context,
    module_: *Module,

    pub fn init(b: *std.Build, options: Options) Self {
        var zop = b.addOptions();
        zop.addOption(bool, "opencl", options.opencl != null);

        var llama_cpp = llama.Context.init(b, .{
            .target = options.target,
            .optimize = options.optimize,
            .shared = false,
            .lto = options.lto,
            .opencl = options.opencl,
            .clblast = options.clblast,
        }, "llama.cpp");

        const deps: []const std.Build.ModuleDependency = &.{ .{
            .name = "llama.h",
            .module = llama_cpp.addModule(),
        }, .{
            .name = "llama_options",
            .module = zop.createModule(),
        } };
        const mod = b.createModule(.{ .source_file = .{ .path = "llama.cpp.zig/llama.zig" }, .dependencies = deps });

        return .{ .llama = llama_cpp, .module_ = mod };
    }

    pub fn module(self: Self) *Module {
        return self.module_;
    }

    pub fn link(self: *Self, comp: *CompileStep) void {
        self.llama.link(comp);
    }
};

pub fn build(b: *std.Build) !void {
    const use_clblast = b.option(bool, "clblast", "Use clblast acceleration") orelse true;
    const opencl_includes = b.option([]const u8, "opencl_includes", "Path to OpenCL headers");
    const opencl_libs = b.option([]const u8, "opencl_libs", "Path to OpenCL libs");
    const install_cpp_samples = b.option(bool, "cpp_samples", "Install llama.cpp samples") orelse false;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lto = b.option(bool, "lto", "Enable LTO optimization, (default: false)") orelse false;

    const opencl_maybe = if (opencl_includes != null or opencl_libs != null) llama.clblast.OpenCL{ .include_path = (opencl_includes orelse ""), .lib_path = (opencl_libs orelse "") } else llama.clblast.OpenCL.fromOCL(b, target);
    if (use_clblast and opencl_maybe == null) @panic("OpenCL not found. Please specify include or libs manually if its installed!");

    var llama_zig = Context.init(b, .{
        .target = target,
        .optimize = optimize,
        .lto = lto,
        .opencl = opencl_maybe,
        .clblast = use_clblast,
    });

    llama_zig.llama.samples(install_cpp_samples) catch |err| std.log.err("Can't build CPP samples, error: {}", .{err});

    { // simple example
        var exe = b.addExecutable(.{ .name = "simple", .root_source_file = .{ .path = "examples/simple.zig" } });
        exe.addModule("llama", llama_zig.module());
        llama_zig.link(exe);
        b.installArtifact(exe); // location when the user invokes the "install" step (the default step when running `zig build`).

        const run_exe = b.addRunArtifact(exe);
        if (b.args) |args| run_exe.addArgs(args); // passes on args like: zig build run -- my fancy args
        run_exe.step.dependOn(b.default_step); // allways copy output, to avoid confusion
        b.step("run-simple", "Run simple example").dependOn(&run_exe.step);
    }

    { // tests
        const main_tests = b.addTest(.{
            .root_source_file = .{ .path = "llama.cpp.zig/llama.zig" },
            .target = target,
            .optimize = optimize,
        });
        llama_zig.link(main_tests);
        const run_main_tests = b.addRunArtifact(main_tests);

        const test_step = b.step("test", "Run library tests");
        test_step.dependOn(&run_main_tests.step);
    }
}
