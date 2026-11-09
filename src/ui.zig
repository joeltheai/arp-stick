const builtin = @import("builtin");

pub const native = @cImport({
    @cInclude("ui/macos.h");
});

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
