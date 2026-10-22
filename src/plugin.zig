const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine.zig");
const ui = @import("ui.zig");
const c = @cImport({
    @cInclude("clap/clap.h");
});

const features = [_:null]?[*:0]const u8{ "note-effect", "stereo" };
const descriptor: c.clap_plugin_descriptor_t = .{
    .clap_version = .{ .major = 1, .minor = 2, .revision = 9 },
    .id = "dev.arpstick.basic",
    .name = "Arp Stick",
    .vendor = "Arp Stick",
    .url = "",
    .manual_url = "",
    .support_url = "",
    .version = "0.1.0",
    .description = "Basic chord generator and ascending arpeggiator. Put a synth after this MIDI effect.",
    .features = @ptrCast(&features),
};

const Instance = struct {
    plugin: c.clap_plugin_t,
    host: [*c]const c.clap_host_t,
    values: [4]std.atomic.Value(u8),
    arp: engine.Engine = .{},
    was_playing: bool = false,
    editor: ?*anyopaque = null,
    // Single producer (GUI/main thread), single consumer (process/flush). No locks on the audio thread.
    gui_changes: [32]struct { id: u32, value: u32 } = undefined,
    gui_write: std.atomic.Value(u32) = .init(0),
    gui_read: std.atomic.Value(u32) = .init(0),
    gui_phase: u2 = 0,

    fn get(plugin: [*c]const c.clap_plugin_t) *Instance {
        return @ptrCast(@alignCast(plugin.*.plugin_data.?));
    }
    fn snapshot(self: *Instance) [4]u8 {
        var result: [4]u8 = undefined;
        for (&result, 0..) |*value, i| value.* = self.values[i].load(.monotonic);
        return result;
    }
    fn set(self: *Instance, id: u32, value: f64) void {
        if (id >= 4 or !std.math.isFinite(value)) return;
        const bounded = std.math.clamp(value, 0, @as(f64, @floatFromInt(engine.maxima[id])));
        self.values[id].store(@intFromFloat(bounded), .monotonic);
    }
};

fn same(a: [*c]const u8, b: []const u8) bool {
    return a != null and std.mem.eql(u8, std.mem.span(a), b);
}
fn put(buffer: []u8, value: []const u8) void {
    @memset(buffer, 0);
    const len = @min(value.len, buffer.len - 1);
    @memcpy(buffer[0..len], value[0..len]);
}
fn init(_: [*c]const c.clap_plugin_t) callconv(.c) bool {
    return true;
}
fn destroy(plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    guiDestroy(plugin);
    std.heap.c_allocator.destroy(Instance.get(plugin));
}
fn activate(plugin: [*c]const c.clap_plugin_t, sample_rate: f64, _: u32, _: u32) callconv(.c) bool {
    if (!std.math.isFinite(sample_rate) or sample_rate <= 0) return false;
    const self = Instance.get(plugin);
    self.arp = .{ .sample_rate = sample_rate };
    self.was_playing = false;
    return true;
}
fn noOp(_: [*c]const c.clap_plugin_t) callconv(.c) void {}
fn start(_: [*c]const c.clap_plugin_t) callconv(.c) bool {
    return true;
}
fn reset(plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    const self = Instance.get(plugin);
    self.arp = .{ .sample_rate = self.arp.sample_rate };
    self.was_playing = false;
}

const Output = struct {
    events: [*c]const c.clap_output_events_t,
    fn push(context: *anyopaque, time: u32, bytes: [3]u8) bool {
        const self: *Output = @ptrCast(@alignCast(context));
        var event = std.mem.zeroes(c.clap_event_midi_t);
        event.header = .{ .size = @sizeOf(c.clap_event_midi_t), .time = time, .space_id = c.CLAP_CORE_EVENT_SPACE_ID, .type = c.CLAP_EVENT_MIDI, .flags = 0 };
        event.port_index = 0;
        event.data = bytes;
        return self.events.*.try_push.?(self.events, &event.header);
    }
};

fn transport(self: *Instance, info: [*c]const c.clap_event_transport_t) void {
    if (info == null) return;
    if (info.*.flags & c.CLAP_TRANSPORT_HAS_TEMPO != 0 and std.math.isFinite(info.*.tempo) and info.*.tempo > 0)
        self.arp.tempo = std.math.clamp(info.*.tempo, 1, 999);
    const playing = info.*.flags & c.CLAP_TRANSPORT_IS_PLAYING != 0;
    if (self.was_playing and !playing) self.arp.panic(null);
    self.was_playing = playing;
}

fn parameterEvent(self: *Instance, header: [*c]const c.clap_event_header_t) void {
    if (header.*.space_id != c.CLAP_CORE_EVENT_SPACE_ID or header.*.type != c.CLAP_EVENT_PARAM_VALUE or
        header.*.size < @sizeOf(c.clap_event_param_value_t)) return;
    const event: *const c.clap_event_param_value_t = @ptrCast(@alignCast(header));
    if (event.note_id == -1 and event.port_index == -1 and event.channel == -1 and event.key == -1)
        self.set(event.param_id, event.value);
}

fn process(plugin: [*c]const c.clap_plugin_t, block: [*c]const c.clap_process_t) callconv(.c) c.clap_process_status {
    const self = Instance.get(plugin);
    const p = &block[0];
    // Audio is unchanged; the effect only transforms MIDI.
    for (0..p.audio_outputs_count) |port| {
        const output = &p.audio_outputs[port];
        output.constant_mask = 0;
        for (0..output.channel_count) |channel| {
            const has_input = port < p.audio_inputs_count and channel < p.audio_inputs[port].channel_count;
            if (output.data32 != null) {
                const dest = output.data32[channel][0..p.frames_count];
                if (has_input and p.audio_inputs[port].data32 != null) {
                    const source = p.audio_inputs[port].data32[channel][0..p.frames_count];
                    if (dest.ptr != source.ptr) @memcpy(dest, source);
                } else @memset(dest, 0);
            }
            if (output.data64 != null) {
                const dest = output.data64[channel][0..p.frames_count];
                if (has_input and p.audio_inputs[port].data64 != null) {
                    const source = p.audio_inputs[port].data64[channel][0..p.frames_count];
                    if (dest.ptr != source.ptr) @memcpy(dest, source);
                } else @memset(dest, 0);
            }
        }
    }
    if (p.out_events == null) return c.CLAP_PROCESS_ERROR;
    emitGuiChanges(self, p.out_events);
    var output: Output = .{ .events = p.out_events };
    const sink: engine.Sink = .{ .context = &output, .push = Output.push };
    transport(self, p.transport);
    self.arp.configure(self.snapshot());
    const count = if (p.in_events != null) p.in_events.*.size.?(p.in_events) else 0;
    var index: u32 = 0;
    for (0..p.frames_count) |sample| {
        const time: u32 = @intCast(sample);
        while (index < count) {
            const header = p.in_events.*.get.?(p.in_events, index);
            if (header == null) {
                index += 1;
                continue;
            }
            if (header.*.time > time) break;
            index += 1;
            if (header.*.space_id != c.CLAP_CORE_EVENT_SPACE_ID) continue;
            switch (header.*.type) {
                c.CLAP_EVENT_PARAM_VALUE => {
                    parameterEvent(self, header);
                    self.arp.configure(self.snapshot());
                },
                c.CLAP_EVENT_TRANSPORT => if (header.*.size >= @sizeOf(c.clap_event_transport_t)) {
                    transport(self, @ptrCast(@alignCast(header)));
                },
                c.CLAP_EVENT_MIDI => {
                    if (header.*.size < @sizeOf(c.clap_event_midi_t)) continue;
                    const event: *const c.clap_event_midi_t = @ptrCast(@alignCast(header));
                    if (event.port_index != 0) continue;
                    self.arp.midi(event.data);
                    const status = event.data[0] & 0xf0;
                    if (status != 0x80 and status != 0x90) _ = sink.send(time, event.data);
                },
                else => {},
            }
        }
        self.arp.tick(time, sink);
    }
    return c.CLAP_PROCESS_CONTINUE;
}

fn portCount(_: [*c]const c.clap_plugin_t, _: bool) callconv(.c) u32 {
    return 1;
}
fn notePort(_: [*c]const c.clap_plugin_t, index: u32, input: bool, info: [*c]c.clap_note_port_info_t) callconv(.c) bool {
    if (index != 0 or info == null) return false;
    info.* = std.mem.zeroes(c.clap_note_port_info_t);
    info.*.id = 0;
    info.*.supported_dialects = c.CLAP_NOTE_DIALECT_MIDI;
    info.*.preferred_dialect = c.CLAP_NOTE_DIALECT_MIDI;
    put(info[0].name[0..], if (input) "Keys in" else "Generated notes");
    return true;
}
fn audioPort(_: [*c]const c.clap_plugin_t, index: u32, _: bool, info: [*c]c.clap_audio_port_info_t) callconv(.c) bool {
    if (index != 0 or info == null) return false;
    info.* = std.mem.zeroes(c.clap_audio_port_info_t);
    info.*.id = 0;
    put(info[0].name[0..], "Stereo passthrough");
    info.*.flags = c.CLAP_AUDIO_PORT_IS_MAIN | c.CLAP_AUDIO_PORT_SUPPORTS_64BITS | c.CLAP_AUDIO_PORT_REQUIRES_COMMON_SAMPLE_SIZE;
    info.*.channel_count = 2;
    info.*.port_type = "stereo";
    info.*.in_place_pair = 0;
    return true;
}

fn paramCount(_: [*c]const c.clap_plugin_t) callconv(.c) u32 {
    return 4;
}
fn paramInfo(_: [*c]const c.clap_plugin_t, id: u32, info: [*c]c.clap_param_info_t) callconv(.c) bool {
    if (id >= 4 or info == null) return false;
    info.* = std.mem.zeroes(c.clap_param_info_t);
    info.*.id = id;
    info.*.flags = c.CLAP_PARAM_IS_STEPPED | c.CLAP_PARAM_IS_ENUM | c.CLAP_PARAM_IS_AUTOMATABLE;
    const names = [_][]const u8{ "Mode", "Chord", "Rate", "Octaves" };
    put(info[0].name[0..], names[id]);
    info.*.max_value = @floatFromInt(engine.maxima[id]);
    info.*.default_value = @floatFromInt(engine.defaults[id]);
    return true;
}
fn paramValue(plugin: [*c]const c.clap_plugin_t, id: u32, value: [*c]f64) callconv(.c) bool {
    if (id >= 4 or value == null) return false;
    value.* = @floatFromInt(Instance.get(plugin).values[id].load(.monotonic));
    return true;
}
fn valueText(_: [*c]const c.clap_plugin_t, id: u32, value: f64, buffer: [*c]u8, capacity: u32) callconv(.c) bool {
    if (id >= 4 or buffer == null or capacity == 0 or !std.math.isFinite(value)) return false;
    const choice: usize = @intFromFloat(std.math.clamp(value, 0, @as(f64, @floatFromInt(engine.maxima[id]))));
    const text = engine.labels[id][choice];
    if (text.len >= capacity) return false;
    put(buffer[0..capacity], text);
    return true;
}
fn textValue(_: [*c]const c.clap_plugin_t, id: u32, text: [*c]const u8, value: [*c]f64) callconv(.c) bool {
    if (id >= 4 or text == null or value == null) return false;
    for (engine.labels[id], 0..) |label, i| {
        if (std.ascii.eqlIgnoreCase(std.mem.span(text), label)) {
            value.* = @floatFromInt(i);
            return true;
        }
    }
    const numeric = std.fmt.parseFloat(f64, std.mem.span(text)) catch return false;
    if (!std.math.isFinite(numeric) or numeric < 0 or numeric > @as(f64, @floatFromInt(engine.maxima[id]))) return false;
    value.* = @trunc(numeric);
    return true;
}
fn flush(plugin: [*c]const c.clap_plugin_t, input: [*c]const c.clap_input_events_t, output: [*c]const c.clap_output_events_t) callconv(.c) void {
    emitGuiChanges(Instance.get(plugin), output);
    if (input == null) return;
    for (0..input.*.size.?(input)) |i| {
        const header = input.*.get.?(input, @intCast(i));
        if (header != null) parameterEvent(Instance.get(plugin), header);
    }
}

fn guiRead(context: ?*anyopaque, id: u32) callconv(.c) u32 {
    if (id >= 4) return 0;
    const self: *Instance = @ptrCast(@alignCast(context.?));
    return self.values[id].load(.monotonic);
}
fn guiChange(context: ?*anyopaque, id: u32, value: u32) callconv(.c) bool {
    if (id >= 4 or value > engine.maxima[id]) return false;
    const self: *Instance = @ptrCast(@alignCast(context.?));
    const write = self.gui_write.load(.monotonic);
    if (write -% self.gui_read.load(.acquire) >= self.gui_changes.len) return false;
    self.gui_changes[write % self.gui_changes.len] = .{ .id = id, .value = value };
    self.gui_write.store(write +% 1, .release);
    requestGuiFlush(self);
    return true;
}
fn requestGuiFlush(self: *Instance) void {
    const raw = self.host.*.get_extension.?(self.host, "clap.params");
    if (raw) |ptr| {
        const host_params: *const c.clap_host_params_t = @ptrCast(@alignCast(ptr));
        host_params.request_flush.?(self.host);
    } else if (self.host.*.request_process) |request| request(self.host);
}
fn onMainThread(plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    const self = Instance.get(plugin);
    if (self.gui_read.load(.acquire) != self.gui_write.load(.acquire)) requestGuiFlush(self);
}
fn retryGuiFlush(self: *Instance) void {
    // request_flush itself is forbidden on the audio thread. Ask the main thread to schedule it.
    if (self.host.*.request_callback) |request_callback| request_callback(self.host);
}

// Send UI changes through CLAP with a complete gesture. Resume at the failed event if a host's
// output list fills, preserving gesture order and retaining the queued value until it is accepted.
fn emitGuiChanges(self: *Instance, output: [*c]const c.clap_output_events_t) void {
    if (output == null) return;
    var drained: usize = 0;
    while (drained < self.gui_changes.len) : (drained += 1) {
        const read = self.gui_read.load(.monotonic);
        if (read == self.gui_write.load(.acquire)) return;
        const change = self.gui_changes[read % self.gui_changes.len];
        while (self.gui_phase < 3) : (self.gui_phase += 1) {
            if (self.gui_phase == 1) {
                var event = std.mem.zeroes(c.clap_event_param_value_t);
                event.header = .{ .size = @sizeOf(c.clap_event_param_value_t), .time = 0, .space_id = c.CLAP_CORE_EVENT_SPACE_ID, .type = c.CLAP_EVENT_PARAM_VALUE, .flags = c.CLAP_EVENT_IS_LIVE };
                event.param_id = change.id;
                event.note_id = -1;
                event.port_index = -1;
                event.channel = -1;
                event.key = -1;
                event.value = @floatFromInt(change.value);
                if (!output.*.try_push.?(output, &event.header)) {
                    retryGuiFlush(self);
                    return;
                }
                self.set(change.id, event.value);
            } else {
                var event: c.clap_event_param_gesture_t = .{
                    .header = .{ .size = @sizeOf(c.clap_event_param_gesture_t), .time = 0, .space_id = c.CLAP_CORE_EVENT_SPACE_ID, .type = if (self.gui_phase == 0) c.CLAP_EVENT_PARAM_GESTURE_BEGIN else c.CLAP_EVENT_PARAM_GESTURE_END, .flags = c.CLAP_EVENT_IS_LIVE },
                    .param_id = change.id,
                };
                if (!output.*.try_push.?(output, &event.header)) {
                    retryGuiFlush(self);
                    return;
                }
            }
        }
        self.gui_phase = 0;
        self.gui_read.store(read +% 1, .release);
    }
}

fn guiSupported(_: [*c]const c.clap_plugin_t, api: [*c]const u8, floating: bool) callconv(.c) bool {
    return builtin.os.tag == .macos and !floating and same(api, "cocoa");
}
fn guiPreferred(_: [*c]const c.clap_plugin_t, api: [*c][*c]const u8, floating: [*c]bool) callconv(.c) bool {
    if (builtin.os.tag != .macos or api == null or floating == null) return false;
    api.* = @ptrCast(&c.CLAP_WINDOW_API_COCOA);
    floating.* = false;
    return true;
}
fn guiCreate(plugin: [*c]const c.clap_plugin_t, api: [*c]const u8, floating: bool) callconv(.c) bool {
    const self = Instance.get(plugin);
    if (!guiSupported(plugin, api, floating) or self.editor != null) return false;
    const settings = ui.config(self, guiRead, guiChange);
    self.editor = ui.create(&settings);
    return self.editor != null;
}
fn guiDestroy(plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    const self = Instance.get(plugin);
    ui.destroy(self.editor);
    self.editor = null;
}
fn guiScale(_: [*c]const c.clap_plugin_t, _: f64) callconv(.c) bool {
    return false;
} // Cocoa uses logical points.
fn guiSize(plugin: [*c]const c.clap_plugin_t, width: [*c]u32, height: [*c]u32) callconv(.c) bool {
    if (Instance.get(plugin).editor == null or width == null or height == null) return false;
    width.* = 480;
    height.* = 340;
    return true;
}
fn guiResizable(_: [*c]const c.clap_plugin_t) callconv(.c) bool {
    return false;
}
fn guiHints(_: [*c]const c.clap_plugin_t, _: [*c]c.clap_gui_resize_hints_t) callconv(.c) bool {
    return false;
}
fn guiSetSize(plugin: [*c]const c.clap_plugin_t, width: u32, height: u32) callconv(.c) bool {
    return Instance.get(plugin).editor != null and width == 480 and height == 340;
}
fn guiParent(plugin: [*c]const c.clap_plugin_t, window: [*c]const c.clap_window_t) callconv(.c) bool {
    if (window == null or !same(window.*.api, "cocoa")) return false;
    return ui.attach(Instance.get(plugin).editor, window.*.unnamed_0.cocoa);
}
fn guiTransient(_: [*c]const c.clap_plugin_t, _: [*c]const c.clap_window_t) callconv(.c) bool {
    return false;
}
fn guiTitle(_: [*c]const c.clap_plugin_t, _: [*c]const u8) callconv(.c) void {}
fn guiShow(plugin: [*c]const c.clap_plugin_t) callconv(.c) bool {
    const self = Instance.get(plugin);
    if (self.editor == null) return false;
    ui.show(self.editor, true);
    return true;
}
fn guiHide(plugin: [*c]const c.clap_plugin_t) callconv(.c) bool {
    const self = Instance.get(plugin);
    if (self.editor == null) return false;
    ui.show(self.editor, false);
    return true;
}

fn save(plugin: [*c]const c.clap_plugin_t, stream: [*c]const c.clap_ostream_t) callconv(.c) bool {
    if (stream == null) return false;
    const values = Instance.get(plugin).snapshot();
    const bytes = [_]u8{ 'A', 'R', 'P', 1 } ++ values;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = stream.*.write.?(stream, bytes[offset..].ptr, bytes.len - offset);
        if (written <= 0 or written > bytes.len - offset) return false;
        offset += @intCast(written);
    }
    return true;
}
fn load(plugin: [*c]const c.clap_plugin_t, stream: [*c]const c.clap_istream_t) callconv(.c) bool {
    if (stream == null) return false;
    var bytes: [8]u8 = undefined;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const received = stream.*.read.?(stream, bytes[offset..].ptr, bytes.len - offset);
        if (received <= 0 or received > bytes.len - offset) return false;
        offset += @intCast(received);
    }
    if (!std.mem.eql(u8, bytes[0..4], &.{ 'A', 'R', 'P', 1 })) return false;
    for (bytes[4..], 0..) |value, i| {
        if (value > engine.maxima[i]) return false;
    }
    const self = Instance.get(plugin);
    for (bytes[4..], 0..) |value, i| self.values[i].store(value, .monotonic);
    const raw = self.host.*.get_extension.?(self.host, "clap.params");
    if (raw) |ptr| {
        const host_params: *const c.clap_host_params_t = @ptrCast(@alignCast(ptr));
        host_params.rescan.?(self.host, c.CLAP_PARAM_RESCAN_VALUES);
    }
    return true;
}

const note_ports: c.clap_plugin_note_ports_t = .{ .count = portCount, .get = notePort };
const audio_ports: c.clap_plugin_audio_ports_t = .{ .count = portCount, .get = audioPort };
const params: c.clap_plugin_params_t = .{ .count = paramCount, .get_info = paramInfo, .get_value = paramValue, .value_to_text = valueText, .text_to_value = textValue, .flush = flush };
const state: c.clap_plugin_state_t = .{ .save = save, .load = load };
const gui: c.clap_plugin_gui_t = .{
    .is_api_supported = guiSupported,
    .get_preferred_api = guiPreferred,
    .create = guiCreate,
    .destroy = guiDestroy,
    .set_scale = guiScale,
    .get_size = guiSize,
    .can_resize = guiResizable,
    .get_resize_hints = guiHints,
    .adjust_size = guiSize,
    .set_size = guiSetSize,
    .set_parent = guiParent,
    .set_transient = guiTransient,
    .suggest_title = guiTitle,
    .show = guiShow,
    .hide = guiHide,
};
fn extension(_: [*c]const c.clap_plugin_t, id: [*c]const u8) callconv(.c) ?*const anyopaque {
    if (same(id, "clap.note-ports")) return &note_ports;
    if (same(id, "clap.audio-ports")) return &audio_ports;
    if (same(id, "clap.params")) return &params;
    if (same(id, "clap.state")) return &state;
    if (builtin.os.tag == .macos and same(id, "clap.gui")) return &gui;
    return null;
}
fn factoryCount(_: [*c]const c.clap_plugin_factory_t) callconv(.c) u32 {
    return 1;
}
fn factoryDescriptor(_: [*c]const c.clap_plugin_factory_t, index: u32) callconv(.c) [*c]const c.clap_plugin_descriptor_t {
    return if (index == 0) &descriptor else null;
}
fn create(_: [*c]const c.clap_plugin_factory_t, host: [*c]const c.clap_host_t, id: [*c]const u8) callconv(.c) [*c]const c.clap_plugin_t {
    if (!same(id, "dev.arpstick.basic") or host == null or host.*.clap_version.major != 1) return null;
    const self = std.heap.c_allocator.create(Instance) catch return null;
    self.* = .{
        .plugin = .{ .desc = &descriptor, .plugin_data = self, .init = init, .destroy = destroy, .activate = activate, .deactivate = noOp, .start_processing = start, .stop_processing = noOp, .reset = reset, .process = process, .get_extension = extension, .on_main_thread = onMainThread },
        .host = host,
        .values = .{ .init(engine.defaults[0]), .init(engine.defaults[1]), .init(engine.defaults[2]), .init(engine.defaults[3]) },
    };
    return &self.plugin;
}
const factory: c.clap_plugin_factory_t = .{ .get_plugin_count = factoryCount, .get_plugin_descriptor = factoryDescriptor, .create_plugin = create };
fn entryInit(_: [*c]const u8) callconv(.c) bool {
    return true;
}
fn entryDeinit() callconv(.c) void {}
fn getFactory(id: [*c]const u8) callconv(.c) ?*const anyopaque {
    return if (same(id, "clap.plugin-factory")) &factory else null;
}
pub export const clap_entry: c.clap_plugin_entry_t = .{
    .clap_version = .{ .major = 1, .minor = 2, .revision = 9 },
    .init = entryInit,
    .deinit = entryDeinit,
    .get_factory = getFactory,
};
