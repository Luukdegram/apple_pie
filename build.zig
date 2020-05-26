const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    // builds the library as a static library
    const mode = b.standardReleaseOptions();
    const lib = b.addStaticLibrary("apple_pie", "src/server.zig");
    lib.setBuildMode(mode);
    lib.install();

    // builds and runs the tests
    var main_tests = b.addTest("src/server.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    // Allows for running the example
    var example = b.addExecutable("example", "example/example.zig");
    example.addPackagePath("apple_pie", "src/server.zig");
    example.setBuildMode(mode);
    example.install();

    const run_example = example.run();
    run_example.step.dependOn(b.getInstallStep());

    const example_step = b.step("example", "Run example");
    example_step.dependOn(&run_example.step);
}
