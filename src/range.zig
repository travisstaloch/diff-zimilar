const std = @import("std");
const mem = std.mem;
pub const Range = struct {
    doc: []const u8,

    pub fn init(s: []const u8) Range {
        return .{ .doc = s };
    }
    pub const empty = Range.init("");
    pub inline fn isEmpty(r: Range) bool {
        return r.doc.len == 0;
    }
    pub fn trimLeft(r: Range, offset: usize) Range {
        return .{ .doc = r.doc[offset..] };
    }
    pub fn trimRight(r: Range, offset: usize) Range {
        return .{ .doc = r.doc[0..offset] };
    }
    pub fn find(haystack: Range, needle: Range) ?usize {
        std.log.debug("find '{}' '{}'", .{ haystack, needle });
        return mem.indexOf(u8, haystack.doc, needle.doc);
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
    pub fn format(r: Range, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        _ = try writer.write(r.doc);
    }
};
