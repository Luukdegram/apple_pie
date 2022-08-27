const std = @import("std");

pub fn fmtDate(timestamp: i128) std.fmt.Formatter(fmtDateImpl) {
    return .{ .data = timestamp };
}

fn fmtDateImpl(
    timestamp: i128,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    const timestamp_s = @intCast(u64, @divFloor(timestamp, std.time.ns_per_s));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = timestamp_s };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const day_seconds = epoch_seconds.getDaySeconds();
    const day_string = switch (epoch_day.day % 7) {
        0 => "Thu", // UTC time starts on Thursday
        1 => "Fri",
        2 => "Sat",
        3 => "Sun",
        4 => "Mon",
        5 => "Tue",
        6 => "Wed",
        else => unreachable,
    };
    const month_string = switch (month_day.month) {
        .jan => "Jan",
        .feb => "Feb",
        .mar => "Mar",
        .apr => "Apr",
        .may => "May",
        .jun => "Jun",
        .jul => "Jul",
        .aug => "Aug",
        .sep => "Sep",
        .oct => "Oct",
        .nov => "Nov",
        .dec => "Dec",
    };

    try writer.print(
        "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT",
        .{
            day_string,
            month_day.day_index + 1,
            month_string,
            year_day.year,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}
