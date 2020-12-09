# Apple Pie

Apple pie is HTTP Server implementation in [Zig](https://ziglang.org). The initial goal is to offer full support for http versions 1.0 and 1.1 with 2.0 and further being out of scope. With Apple Pie I'd like to offer a library that contains all features you'd expect from a server, while still remaining performant. Rather than hiding complexity, I want to expose its functionality so users can replace and/or expand upon to fit their needs.
For performance and cross-platform support, Apple Pie uses [zap](https://github.com/kprotty/zap) for its scheduling and [Pike](https://github.com/lithdew/pike) for cross-platform I/O support.

## Roadmap
- Add control flow to the template engine. take a look at [examples/template.zig](examples/template.zig) for an example.

## Example

A very basic implementation would be as follow:

```zig
const std = @import("std");
const http = @import("apple_pie");

// setup Pike with the scheduler
pub const pike_dispatch = http.dispatch;
pub const pike_batch = http.batch;
pub const pike_task = http.task;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    try http.server.listenAndServe(
        &gpa.allocator,
        try std.net.Address.parseIp("127.0.0.1", 8080),
        index,
    );
}

fn index(response: *http.Response, request: http.Request) !void {
    try response.writer().writeAll("Hello Zig!");
}
```

More examples can be found in the [examples](examples) folder.

## Building

Apple Pie is being developed on Zig's master branch and tries to keep up-to-date with its latest development.

To build Apple Pie a simple
`zig build` will suffice.

To build any of the examples, use the following:
```
zig build example -Dexample=<example_name>
```

