const engine = @import("engine.zig");
const ui = @import("ui.zig");

// The preview shares the actual editor, with a local parameter backend. It produces no audio/MIDI.
const Preview = struct { values: [4]u8 = engine.defaults };
fn read(context: ?*anyopaque, id: u32) callconv(.c) u32 {
    const self: *Preview = @ptrCast(@alignCast(context.?));
    return if (id < 4) self.values[id] else 0;
}
fn change(context: ?*anyopaque, id: u32, value: u32) callconv(.c) bool {
    if (id >= 4 or value > engine.maxima[id]) return false;
    const self: *Preview = @ptrCast(@alignCast(context.?));
    self.values[id] = @intCast(value);
    return true;
}
pub fn main() void {
    var state: Preview = .{};
    const settings = ui.config(&state, read, change);
    _ = ui.native.arp_ui_preview(&settings);
}
