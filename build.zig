const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();

    // builds the library as a static library
    {
        const lib = b.addStaticLibrary("apple_pie", "src/server.zig");
        lib.setBuildMode(mode);
        lib.use_stage1 = true;
        lib.install();
    }

    // builds and runs the tests
    {
        var main_tests = b.addTest("src/apple_pie.zig");
        main_tests.setBuildMode(mode);
        main_tests.use_stage1 = true;
        const test_step = b.step("test", "Run library tests");
        test_step.dependOn(&main_tests.step);
    }

    // example
    {
        var opt = b.option([]const u8, "example", "The example to build & run") orelse "basic";
        const example_file = blk: {
            if (std.mem.eql(u8, opt, "router"))
                break :blk "examples/router.zig";

            if (std.mem.eql(u8, opt, "static"))
                break :blk "examples/static.zig";

            if (std.mem.eql(u8, opt, "template"))
                break :blk "examples/template.zig";

            if (std.mem.eql(u8, opt, "form"))
                break :blk "examples/form.zig";

            break :blk "examples/basic.zig";
        };

        // Allows for running the example
        var example = b.addExecutable(opt, example_file);
        example.addPackage(.{
            .name = "apple_pie",
            .source = .{ .path = "src/apple_pie.zig" },
        });
        example.setBuildMode(mode);
        example.use_stage1 = true;
        example.install();

        const run_example = example.run();
        run_example.step.dependOn(b.getInstallStep());

        const example_step = b.step("example", "Run example");
        example_step.dependOn(&run_example.step);
    }
}
