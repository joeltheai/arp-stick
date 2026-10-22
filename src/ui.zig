const builtin = @import("builtin");
const engine = @import("engine.zig");
pub const native = @cImport({
    @cInclude("ui/macos.h");
});

pub fn config(context: *anyopaque, read: *const fn (?*anyopaque, u32) callconv(.c) u32, change: *const fn (?*anyopaque, u32, u32) callconv(.c) bool) native.ArpStickUIConfig {
    var result: native.ArpStickUIConfig = .{
        .context = context,
        .read = read,
        .change = change,
        .options = @splat(@splat(null)),
        .counts = undefined,
    };
    for (engine.labels, 0..) |choices, id| {
        result.counts[id] = @intCast(choices.len);
        for (choices, 0..) |label, value| result.options[id][value] = label.ptr;
    }
    return result;
}

pub fn create(settings: *const native.ArpStickUIConfig) ?*anyopaque {
    if (builtin.os.tag == .macos) return native.arp_ui_create(settings);
    return null;
}
pub fn destroy(handle: ?*anyopaque) void {
    if (builtin.os.tag == .macos) native.arp_ui_destroy(handle);
}
pub fn attach(handle: ?*anyopaque, parent: ?*anyopaque) bool {
    if (builtin.os.tag == .macos) return native.arp_ui_attach(handle, parent);
    return false;
}
pub fn show(handle: ?*anyopaque, visible: bool) void {
    if (builtin.os.tag == .macos) native.arp_ui_show(handle, visible);
}
