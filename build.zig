const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const pike = std.build.Pkg{
        .name = "pike",
        .path = "libs/pike/pike.zig",
    };

    const zap = std.build.Pkg{
        .name = "zap",
        .path = "libs/zap/src/zap.zig",
    };
    const mode = b.standardReleaseOptions();

    // builds the library as a static library
    {
        const lib = b.addStaticLibrary("apple_pie", "src/server.zig");
        lib.setBuildMode(mode);
        lib.addPackage(pike);
        lib.addPackage(zap);
        lib.install();
    }

    // builds and runs the tests
    {
        var main_tests = b.addTest("src/apple_pie.zig");
        main_tests.setBuildMode(mode);
        main_tests.addPackage(pike);
        main_tests.addPackage(zap);
        const test_step = b.step("test", "Run library tests");
        test_step.dependOn(&main_tests.step);
    }

    // example
    {
        const opt = b.option([]const u8, "example", "The example to build & run") orelse "";
        const example_file = blk: {
            var file: []const u8 = undefined;
            file = "examples/basic.zig";

            if (std.mem.eql(u8, opt, "router"))
                file = "examples/router.zig";

            if (std.mem.eql(u8, opt, "static"))
                file = "examples/static.zig";

            if (std.mem.eql(u8, opt, "template"))
                file = "examples/template.zig";

            break :blk file;
        };

        // Allows for running the example
        var example = b.addExecutable("example", example_file);
        example.addPackage(.{
            .name = "apple_pie",
            .path = "src/apple_pie.zig",
            .dependencies = &[_]std.build.Pkg{ pike, zap },
        });
        example.setBuildMode(mode);
        example.install();

        const run_example = example.run();
        run_example.step.dependOn(b.getInstallStep());

        const example_step = b.step("example", "Run example");
        example_step.dependOn(&run_example.step);
    }
}
