const std = @import("std");
const mem = std.mem;

pub fn range(s: []const u8) Range {
    return Range.init(s);
}

pub const Range = struct {
    doc: []const u8,

    pub const empty = Range.init("");

    pub fn init(s: []const u8) Range {
        return .{ .doc = s };
    }

    pub inline fn isEmpty(r: Range) bool {
        return r.doc.len == 0;
    }

    pub fn substringFrom(r: Range, start: usize) Range {
        return .{ .doc = r.doc[start..] };
    }

    pub fn substringTo(r: Range, len: usize) Range {
        return .{ .doc = r.doc[0..len] };
    }

    pub fn substring(r: Range, start: usize, end: usize) Range {
        return .{ .doc = r.doc[start..end] };
    }

    pub fn find(haystack: Range, needle: Range) ?usize {
        return mem.indexOf(u8, haystack.doc, needle.doc);
    }

    pub fn splitAt(r: Range, mid: usize) [2]Range {
        return .{ r.substringTo(mid), r.substringFrom(mid) };
    }

    pub fn eql(a: Range, b: Range) bool {
        return mem.eql(u8, a.doc, b.doc);
    }

    pub fn endsWith(a: Range, b: Range) bool {
        return mem.endsWith(u8, a.doc, b.doc);
    }

    pub fn startsWith(a: Range, b: Range) bool {
        return mem.startsWith(u8, a.doc, b.doc);
    }

    pub fn dupe(r: Range, allocator: mem.Allocator) !Range {
        return range(try allocator.dupe(u8, r.doc));
    }

    pub fn format(
        r: Range,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = try writer.write(r.doc);
    }
};
