const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine.zig");
const model = @import("model.zig");
const ui = @import("ui.zig");
const c = @cImport({
    @cInclude("clap/clap.h");
    @cInclude("ui/macos.h");
});

const Model = model.Model;

const features = [_:null]?[*:0]const u8{ "note-effect", "stereo" };
const descriptor: c.clap_plugin_descriptor_t = .{
    .clap_version = .{ .major = 1, .minor = 2, .revision = 9 },
    .id = "dev.arpstick",
    .name = "Arp Stick",
    .vendor = "Arp Stick",
    .url = "",
    .manual_url = "",
    .support_url = "",
    .version = "0.2.0",
    .description = "Chord memorizer and pattern arpeggiator. Put a synth after this MIDI effect.",
    .features = @ptrCast(&features),
};

const Instance = struct {
    plugin: c.clap_plugin_t,
    host: [*c]const c.clap_host_t,
    values: [engine.param_count]std.atomic.Value(i32),
    patch: Model,
    render: Model,
    shared: engine.Shared,
    arp: engine.Engine,
    ui_rng: std.Random.DefaultPrng,
    version: std.atomic.Value(u32) = std.atomic.Value(u32).init(2),
    render_version: u32 = 2,
    editor: ?*anyopaque = null,
    transport_playing: bool = false,
    was_playing: bool = false,
    gui_changes: [64]struct { id: u32, value: i32 } = undefined,
    gui_write: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    gui_read: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    gui_phase: u2 = 0,

    fn get(plugin: [*c]const c.clap_plugin_t) *Instance {
        return @ptrCast(@alignCast(plugin.*.plugin_data.?));
    }
    fn snapshot(self: *Instance) [engine.param_count]i32 {
        var result: [engine.param_count]i32 = undefined;
        for (&result, 0..) |*value, i| value.* = self.values[i].load(.monotonic);
        return result;
    }
    fn params(self: *Instance) engine.Params {
        return .fromValues(self.snapshot());
    }
    fn setParam(self: *Instance, id: u32, raw: i32, emit: bool) bool {
        if (id >= engine.param_count) return false;
        const v = std.math.clamp(raw, engine.minima[id], engine.maxima[id]);
        self.values[id].store(v, .monotonic);
        if (emit) self.queueChange(id, v);
        return true;
    }
    fn queueChange(self: *Instance, id: u32, value: i32) void {
        const write = self.gui_write.load(.monotonic);
        if (write -% self.gui_read.load(.acquire) >= self.gui_changes.len) return;
        self.gui_changes[write % self.gui_changes.len] = .{ .id = id, .value = value };
        self.gui_write.store(write +% 1, .release);
        requestGuiFlush(self);
    }
    fn beginEdit(self: *Instance) void {
        _ = self.version.fetchAdd(1, .acquire);
    }
    fn endEdit(self: *Instance) void {
        _ = self.version.fetchAdd(1, .release);
    }
    fn syncRender(self: *Instance) void {
        const v = self.version.load(.acquire);
        if (v & 1 != 0 or v == self.render_version) return;
        const copy = self.patch;
        if (self.version.load(.acquire) == v) {
            self.render = copy;
            self.render_version = v;
        }
    }
    fn slot(self: *Instance) usize {
        return @intCast(std.math.clamp(self.shared.cur_slot.load(.monotonic), 0, 127));
    }
    fn pattern(self: *Instance) usize {
        return @intCast(std.math.clamp(self.values[7].load(.monotonic), 0, 11));
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
    self.arp = engine.Engine.init(sample_rate);
    self.transport_playing = false;
    self.was_playing = false;
    return true;
}
fn noOp(_: [*c]const c.clap_plugin_t) callconv(.c) void {}
fn start(_: [*c]const c.clap_plugin_t) callconv(.c) bool {
    return true;
}
fn reset(plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    const self = Instance.get(plugin);
    self.arp = engine.Engine.init(self.arp.sample_rate);
    self.transport_playing = false;
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

fn parseTransport(self: *Instance, info: [*c]const c.clap_event_transport_t) engine.Transport {
    if (info == null) return .{ .playing = self.transport_playing };
    const factor: f64 = 2147483648.0;
    var tr: engine.Transport = .{
        .playing = (info.*.flags & c.CLAP_TRANSPORT_IS_PLAYING) != 0,
        .tempo = if ((info.*.flags & c.CLAP_TRANSPORT_HAS_TEMPO) != 0 and std.math.isFinite(info.*.tempo) and info.*.tempo > 0)
            std.math.clamp(info.*.tempo, 1, 999)
        else
            120,
        .beat = 0,
        .seconds = 0,
    };
    if ((info.*.flags & c.CLAP_TRANSPORT_HAS_BEATS_TIMELINE) != 0) {
        tr.beat = @as(f64, @floatFromInt(info.*.song_pos_beats)) / factor;
    } else if ((info.*.flags & c.CLAP_TRANSPORT_HAS_SECONDS_TIMELINE) != 0) {
        tr.seconds = @as(f64, @floatFromInt(info.*.song_pos_seconds)) / factor;
        tr.beat = tr.seconds * tr.tempo / 60.0;
    }
    if ((info.*.flags & c.CLAP_TRANSPORT_HAS_SECONDS_TIMELINE) != 0)
        tr.seconds = @as(f64, @floatFromInt(info.*.song_pos_seconds)) / factor;
    self.transport_playing = tr.playing;
    return tr;
}
fn parameterEvent(self: *Instance, header: [*c]const c.clap_event_header_t) void {
    if (header.*.space_id != c.CLAP_CORE_EVENT_SPACE_ID or header.*.type != c.CLAP_EVENT_PARAM_VALUE or
        header.*.size < @sizeOf(c.clap_event_param_value_t)) return;
    const event: *const c.clap_event_param_value_t = @ptrCast(@alignCast(header));
    if (event.note_id == -1 and event.port_index == -1 and event.channel == -1 and event.key == -1) {
        if (std.math.isFinite(event.value)) _ = self.setParam(event.param_id, @intFromFloat(std.math.round(event.value)), false);
    }
}

fn midiRemote(self: *Instance, p: engine.Params, data: [3]u8) void {
    if (!p.midi_remote) return;
    const status = data[0] & 0xf0;
    if (status != 0xb0) return;
    const ch = data[0] & 15;
    const cc = data[1] & 127;
    const value: i32 = data[2] & 127;
    if (ch == 2 and cc < 12) {
        _ = self.setParam(7, cc, false);
        self.arp.setPattern(@intCast(cc));
        return;
    }
    if (ch != 1) return;
    const current = self.slot();
    if (cc >= 101 and cc <= 108) {
        self.patch.chord_notes[current][cc - 101] = @intCast(value);
        self.render.chord_notes[current][cc - 101] = @intCast(value);
        self.shared.watch(current);
    } else if (cc < 16) {
        const lane: usize = @min(self.patch.cur_graph, 7);
        const y = 48.0 + @as(f64, @floatFromInt(127 - value)) * 296.0 / 127.0;
        const v = engine.Engine.cellYToVal(lane, y);
        self.patch.setGraph(lane, self.pattern(), cc, v);
        self.render.setGraph(lane, self.pattern(), cc, v);
    }
}

fn process(plugin: [*c]const c.clap_plugin_t, block: [*c]const c.clap_process_t) callconv(.c) c.clap_process_status {
    const self = Instance.get(plugin);
    const p = &block[0];
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
    self.syncRender();
    var output: Output = .{ .events = p.out_events };
    const sink: engine.Sink = .{ .context = &output, .push = Output.push };
    var tr: engine.Transport = .{ .playing = self.transport_playing };
    tr = parseTransport(self, p.transport);
    var pvals = self.params();
    self.arp.beginBlock(&self.render, &self.patch, &self.shared, pvals, tr, sink);
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
                    pvals = self.params();
                    self.arp.updateParams(&self.render, &self.shared, pvals);
                },
                c.CLAP_EVENT_TRANSPORT => if (header.*.size >= @sizeOf(c.clap_event_transport_t)) {
                    tr = parseTransport(self, @ptrCast(@alignCast(header)));
                    self.arp.transport_playing = tr.playing;
                },
                c.CLAP_EVENT_MIDI => {
                    if (header.*.size < @sizeOf(c.clap_event_midi_t)) continue;
                    const event: *const c.clap_event_midi_t = @ptrCast(@alignCast(header));
                    if (event.port_index != 0) continue;
                    const status = event.data[0] & 0xf0;
                    if (status == 0x90 or status == 0x80) {
                        self.arp.noteEvent(&self.render, &self.patch, &self.shared, event.data, time);
                    } else {
                        self.arp.control(event.data);
                        midiRemote(self, pvals, event.data);
                        _ = sink.send(time, event.data);
                    }
                },
                else => {},
            }
        }
        const tone = self.arp.tick(&self.render, &self.shared, time);
        if (tone != 0) {
            for (0..p.audio_outputs_count) |port| {
                const out = &p.audio_outputs[port];
                for (0..out.channel_count) |channel| {
                    if (out.data32 != null) out.data32[channel][sample] += tone;
                    if (out.data64 != null) out.data64[channel][sample] += tone;
                }
            }
        }
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
    return engine.param_count;
}
fn paramInfo(_: [*c]const c.clap_plugin_t, id: u32, info: [*c]c.clap_param_info_t) callconv(.c) bool {
    if (id >= engine.param_count or info == null) return false;
    info.* = std.mem.zeroes(c.clap_param_info_t);
    info.*.id = id;
    info.*.flags = c.CLAP_PARAM_IS_STEPPED | c.CLAP_PARAM_IS_AUTOMATABLE;
    if (engine.param_labels[id] != null) info.*.flags |= c.CLAP_PARAM_IS_ENUM;
    put(info[0].name[0..], engine.param_names[id]);
    info.*.min_value = @floatFromInt(engine.minima[id]);
    info.*.max_value = @floatFromInt(engine.maxima[id]);
    info.*.default_value = @floatFromInt(engine.defaults[id]);
    return true;
}
fn paramValue(plugin: [*c]const c.clap_plugin_t, id: u32, value: [*c]f64) callconv(.c) bool {
    if (id >= engine.param_count or value == null) return false;
    value.* = @floatFromInt(Instance.get(plugin).values[id].load(.monotonic));
    return true;
}
fn formatParam(id: u32, value: i32, buffer: [*c]u8, capacity: u32) bool {
    if (id >= engine.param_count or buffer == null or capacity == 0) return false;
    var scratch: [64]u8 = undefined;
    const text: []const u8 = switch (id) {
        2 => std.fmt.bufPrint(&scratch, "{s}{d}", .{ if (value >= 0) "+" else "", value }) catch return false,
        4 => std.fmt.bufPrint(&scratch, "{d}%", .{value}) catch return false,
        5 => if (value == 0) "Input" else std.fmt.bufPrint(&scratch, "CH {d}", .{value}) catch return false,
        7 => std.fmt.bufPrint(&scratch, "{c}", .{@as(u8, 'A') + @as(u8, @intCast(std.math.clamp(value, 0, 11)))}) catch return false,
        else => blk: {
            const labels = engine.param_labels[id] orelse return false;
            const index = std.math.clamp(value, 0, @as(i32, @intCast(labels.len - 1)));
            break :blk labels[@intCast(index)];
        },
    };
    if (text.len >= capacity) return false;
    put(buffer[0..capacity], text);
    return true;
}
fn valueText(_: [*c]const c.clap_plugin_t, id: u32, value: f64, buffer: [*c]u8, capacity: u32) callconv(.c) bool {
    if (id >= engine.param_count or !std.math.isFinite(value)) return false;
    return formatParam(id, @intFromFloat(std.math.round(value)), buffer, capacity);
}
fn textValue(_: [*c]const c.clap_plugin_t, id: u32, text: [*c]const u8, value: [*c]f64) callconv(.c) bool {
    if (id >= engine.param_count or text == null or value == null) return false;
    const s: []const u8 = std.mem.span(text);
    if (engine.param_labels[id]) |labels| {
        for (labels, 0..) |label, i| {
            if (std.ascii.eqlIgnoreCase(s, label)) {
                value.* = @floatFromInt(i);
                return true;
            }
        }
    }
    if (id == 7 and s.len == 1) {
        const ch = std.ascii.toUpper(s[0]);
        if (ch >= 'A' and ch <= 'L') {
            value.* = @floatFromInt(ch - 'A');
            return true;
        }
    }
    var trimmed = s;
    if (id == 5 and trimmed.len > 2 and std.ascii.eqlIgnoreCase(trimmed[0..2], "CH")) trimmed = trimmed[2..];
    while (trimmed.len > 0 and (trimmed[0] == '+' or trimmed[0] == ' ')) trimmed = trimmed[1..];
    while (trimmed.len > 0 and (trimmed[trimmed.len - 1] == '%' or trimmed[trimmed.len - 1] == ' ')) trimmed = trimmed[0 .. trimmed.len - 1];
    const numeric = std.fmt.parseFloat(f64, trimmed) catch return false;
    if (!std.math.isFinite(numeric) or numeric < @as(f64, @floatFromInt(engine.minima[id])) or numeric > @as(f64, @floatFromInt(engine.maxima[id]))) return false;
    value.* = @trunc(numeric);
    return true;
}
fn flush(plugin: [*c]const c.clap_plugin_t, input: [*c]const c.clap_input_events_t, output: [*c]const c.clap_output_events_t) callconv(.c) void {
    const self = Instance.get(plugin);
    emitGuiChanges(self, output);
    if (input == null) return;
    for (0..input.*.size.?(input)) |i| {
        const header = input.*.get.?(input, @intCast(i));
        if (header != null) parameterEvent(self, header);
    }
}

fn guiRead(context: ?*anyopaque, id: u32) callconv(.c) i32 {
    const self: *Instance = @ptrCast(@alignCast(context.?));
    if (id >= engine.param_count) return 0;
    return self.values[id].load(.monotonic);
}
fn guiChange(context: ?*anyopaque, id: u32, value: i32) callconv(.c) bool {
    const self: *Instance = @ptrCast(@alignCast(context.?));
    return self.setParam(id, value, true);
}
fn guiReadField(context: ?*anyopaque, field: u32, a: u32, b: u32) callconv(.c) i32 {
    const self: *Instance = @ptrCast(@alignCast(context.?));
    const slot = self.slot();
    const pat = self.pattern();
    return switch (field) {
        c.ARP_FIELD_CHORD_NOTE => if (a < 128 and b < 8) self.patch.chord_notes[a][b] else -1,
        c.ARP_FIELD_CHORD_VEL => if (a < 128 and b < 8) self.patch.chord_vel[a][b] else 0,
        c.ARP_FIELD_LOCK_ON => if (a < 8) @intFromBool(self.patch.lock_on[a]) else 0,
        c.ARP_FIELD_LOCK_NOTE => if (a < 8) self.patch.lock_note[a] else -1,
        c.ARP_FIELD_CELL => if (a < 8 and b < 16) self.patch.graph[a][pat][b] else 0,
        c.ARP_FIELD_RESET => if (b < 16) @intFromBool(self.patch.reset[pat][b]) else 0,
        c.ARP_FIELD_MUTE => if (b < 16) @intFromBool(((self.patch.mute[pat] >> @intCast(b)) & 1) != 0) else 0,
        c.ARP_FIELD_LEN => if (a < 8) self.patch.lane_len[pat][a] else 0,
        c.ARP_FIELD_DIV => if (a < 8) self.patch.lane_div[pat][a] else 0,
        c.ARP_FIELD_RATE => self.patch.rate[pat],
        c.ARP_FIELD_SWING => self.patch.swing[pat],
        c.ARP_FIELD_RETRIG => @intFromBool(self.patch.retrig[pat]),
        c.ARP_FIELD_LINK => @intFromBool(self.patch.link[pat]),
        c.ARP_FIELD_CHORD_MODE => @intFromBool(self.patch.chord_mode[pat]),
        c.ARP_FIELD_CONSTRAINT => if (a < 12) self.patch.constraint[a] else 0,
        c.ARP_FIELD_PEN => if (a < 7) @intFromBool(self.patch.pen[a]) else 0,
        c.ARP_FIELD_CUR_SLOT => @intCast(slot),
        c.ARP_FIELD_PATTERN => @intCast(pat),
        c.ARP_FIELD_FREE_ON => @intFromBool(self.patch.free_on),
        c.ARP_FIELD_FREE_HZ => @intFromFloat(@round(@as(f64, self.patch.free_hz) * 100.0)),
        c.ARP_FIELD_WATCH_ON => @intFromBool(self.patch.watch_on),
        c.ARP_FIELD_WATCHED => if (a < 128) @intFromBool(self.shared.isWatched(a)) else 0,
        c.ARP_FIELD_NAME_CHAR => if (a < 24) self.patch.names[pat][a] else 0,
        c.ARP_FIELD_CUR_GRAPH => self.patch.cur_graph,
        c.ARP_FIELD_SCALE_KEY => self.patch.scale_key,
        c.ARP_FIELD_SCALE_TYPE => self.patch.scale_type,
        c.ARP_FIELD_LEARNING => @intFromBool(self.shared.learning.load(.monotonic)),
        c.ARP_FIELD_LEARN_MODE => self.shared.learn_mode.load(.monotonic),
        c.ARP_FIELD_LEARN_TIMER => @intFromBool(self.shared.learn_timer.load(.monotonic)),
        c.ARP_FIELD_LEARN_COUNT => self.shared.learn_count.load(.monotonic),
        c.ARP_FIELD_LEARN_NOTE => if (a < 8) self.shared.learn_notes[a].load(.monotonic) else -1,
        c.ARP_FIELD_PLAYING => @intFromBool(self.arp.transport_playing or self.patch.free_on),
        c.ARP_FIELD_LAST_FIRED => @intCast(self.arp.last_fired),
        c.ARP_FIELD_LAST_OUT => self.arp.last_out_note,
        c.ARP_FIELD_ARP_COUNT => @intCast(self.arp.arp_cnt),
        c.ARP_FIELD_SND_COUNT => @intCast(self.arp.snd_cnt),
        c.ARP_FIELD_ACTIVE_SLOT => self.arp.active_slot,
        c.ARP_FIELD_PATTERN_USED => if (a < 12) @intFromBool(self.patch.patternUsed(a)) else 0,
        else => 0,
    };
}
fn guiWriteField(context: ?*anyopaque, field: u32, a: u32, b: u32, value: i32) callconv(.c) bool {
    const self: *Instance = @ptrCast(@alignCast(context.?));
    const pat = self.pattern();
    const slot = self.slot();
    self.beginEdit();
    defer self.endEdit();
    switch (field) {
        c.ARP_FIELD_CHORD_NOTE => {
            if (a >= 128 or b >= 8) return false;
            self.patch.chord_notes[a][b] = @intCast(std.math.clamp(value, -1, 127));
        },
        c.ARP_FIELD_CHORD_VEL => {
            if (a >= 128 or b >= 8) return false;
            self.patch.chord_vel[a][b] = @intCast(std.math.clamp(value, 0, 200));
        },
        c.ARP_FIELD_LOCK_ON => {
            if (a >= 8) return false;
            self.patch.lock_on[a] = value != 0;
            if (value != 0) self.patch.lock_note[a] = @max(-1, self.patch.chord_notes[slot][a]);
        },
        c.ARP_FIELD_LOCK_NOTE => {
            if (a >= 8) return false;
            self.patch.lock_note[a] = @intCast(std.math.clamp(value, -1, 127));
        },
        c.ARP_FIELD_CELL => {
            if (a >= 8 or b >= 16) return false;
            self.patch.setGraph(a, pat, b, @intCast(value));
        },
        c.ARP_FIELD_RESET => {
            if (b >= 16) return false;
            self.patch.reset[pat][b] = value != 0;
        },
        c.ARP_FIELD_MUTE => {
            if (b >= 16) return false;
            const bit: u16 = @as(u16, 1) << @intCast(b);
            if (value != 0) self.patch.mute[pat] |= bit else self.patch.mute[pat] &= ~bit;
        },
        c.ARP_FIELD_LEN => {
            if (a >= 8) return false;
            self.patch.lane_len[pat][a] = @intCast(std.math.clamp(value, 1, 16));
        },
        c.ARP_FIELD_DIV => {
            if (a >= 8) return false;
            self.patch.lane_div[pat][a] = @intCast(std.math.clamp(value, 1, 8));
        },
        c.ARP_FIELD_RATE => self.patch.rate[pat] = @intCast(std.math.clamp(value, 0, 15)),
        c.ARP_FIELD_SWING => self.patch.swing[pat] = @intCast(std.math.clamp(value, 0, 75)),
        c.ARP_FIELD_RETRIG => self.patch.retrig[pat] = value != 0,
        c.ARP_FIELD_LINK => self.patch.link[pat] = value != 0,
        c.ARP_FIELD_CHORD_MODE => self.patch.chord_mode[pat] = value != 0,
        c.ARP_FIELD_CONSTRAINT => {
            if (a >= 12) return false;
            self.patch.constraint[a] = @intCast(@mod(value, 4));
        },
        c.ARP_FIELD_PEN => {
            if (a >= 7) return false;
            self.patch.pen[a] = value != 0;
        },
        c.ARP_FIELD_CUR_SLOT => self.shared.cur_slot.store(std.math.clamp(value, 0, 127), .release),
        c.ARP_FIELD_PATTERN => return self.setParam(7, value, true),
        c.ARP_FIELD_FREE_ON => self.patch.free_on = value != 0,
        c.ARP_FIELD_FREE_HZ => self.patch.free_hz = @floatCast(std.math.clamp(@as(f64, @floatFromInt(value)) / 100.0, 0.05, 40)),
        c.ARP_FIELD_WATCH_ON => {
            self.patch.watch_on = value != 0;
            if (value != 0) self.shared.unwatchAll();
        },
        c.ARP_FIELD_NAME_CHAR => {
            if (a >= 24) return false;
            self.patch.setNameChar(pat, a, @intCast(std.math.clamp(value, 0, 255)));
        },
        c.ARP_FIELD_CUR_GRAPH => self.patch.cur_graph = @intCast(std.math.clamp(value, 0, 7)),
        c.ARP_FIELD_SCALE_KEY => self.patch.scale_key = @intCast(std.math.clamp(value, 0, 11)),
        c.ARP_FIELD_SCALE_TYPE => self.patch.scale_type = @intCast(std.math.clamp(value, 0, 6)),
        c.ARP_FIELD_LEARNING => {
            self.shared.learning.store(value != 0, .release);
            if (value == 0) {
                self.shared.learn_mode.store(0, .release);
                self.shared.resetLearn();
            }
        },
        c.ARP_FIELD_LEARN_MODE => self.shared.learn_mode.store(@intCast(std.math.clamp(value, 0, 3)), .release),
        c.ARP_FIELD_LEARN_TIMER => self.shared.learn_timer.store(value != 0, .release),
        c.ARP_FIELD_LEARN_COUNT => {
            self.shared.resetLearn();
            self.arp.lrn_cnt = 0;
        },
        else => return false,
    }
    return true;
}
fn guiAction(context: ?*anyopaque, action: u32, a: i32, b: i32) callconv(.c) bool {
    const self: *Instance = @ptrCast(@alignCast(context.?));
    const pat = self.pattern();
    self.beginEdit();
    defer self.endEdit();
    switch (action) {
        c.ARP_ACTION_COPY_PATTERN => {
            if (a < 0 or a > 11 or b < 0 or b > 11) return false;
            self.patch.copyPattern(@intCast(a), @intCast(b));
            _ = self.setParam(7, b, true);
        },
        c.ARP_ACTION_COPY_GRAPH => self.patch.graphCopy(self.patch.cur_graph, pat),
        c.ARP_ACTION_PASTE_GRAPH => self.patch.graphPaste(self.patch.cur_graph, pat),
        c.ARP_ACTION_RAND_GRAPH => self.patch.graphRandom(self.patch.cur_graph, pat, &self.ui_rng),
        c.ARP_ACTION_ARP_PRESET => if (a >= 0 and a <= 10) self.patch.applyArpPreset(pat, @intCast(a), &self.ui_rng),
        c.ARP_ACTION_CHORD_PRESET => if (a >= 0 and a <= 55) self.patch.applyChordPreset(@intCast(a)),
        c.ARP_ACTION_SORT => if (a >= 0 and a <= 5) self.patch.sortSlots(@intCast(a)),
        c.ARP_ACTION_REMOVE_DUPS => self.patch.removeDups(),
        c.ARP_ACTION_REMOVE_N => if (a >= 0 and a <= 8) self.patch.removeNNotes(@intCast(a)),
        c.ARP_ACTION_REMOVE_UNWATCHED => {
            var watched: [128]bool = undefined;
            for (0..128) |i| watched[i] = self.shared.isWatched(i);
            self.patch.removeUnwatched(&watched);
        },
        c.ARP_ACTION_CLEAR_ALL => for (0..model.slots) |s| self.patch.slotClear(s),
        c.ARP_ACTION_MAKE_THIRD => if (a == 3 or a == 4 or a == 5) self.patch.makeThird(@intCast(a)),
        c.ARP_ACTION_TRANSFORM_PREVENT => self.patch.transformPrevent(),
        c.ARP_ACTION_TRANSFORM_MATCH => if (a >= 0 and a < 128) self.patch.transformMatch(@intCast(a)),
        c.ARP_ACTION_POPULATE_EMPTY => self.patch.populateEmpty(),
        c.ARP_ACTION_COPY_CHORD => if (a >= 0 and a < 128) self.patch.chordCopy(@intCast(a)),
        c.ARP_ACTION_PASTE_CHORD => if (a >= 0 and a < 128) self.patch.chordPaste(@intCast(a)),
        c.ARP_ACTION_RAND_CHORD => if (a >= 0 and a < 128) self.patch.randomChord(@intCast(a), &self.ui_rng),
        c.ARP_ACTION_PREVIEW_CHORD => if (a >= 0 and a < 128) {
            self.shared.preview_channel.store(if (b >= 0) b else self.arp.last_in_chan, .release);
            self.shared.preview_slot.store(a, .release);
        },
        c.ARP_ACTION_PANIC => self.shared.panic.store(true, .release),
        c.ARP_ACTION_TOGGLE_LEARN => {
            const on = self.shared.learning.load(.monotonic);
            if (on) {
                self.shared.learning.store(false, .release);
                self.shared.learn_mode.store(0, .release);
                self.shared.resetLearn();
            } else {
                self.shared.learning.store(true, .release);
                self.shared.learn_mode.store(@intCast(std.math.clamp(a, 1, 3)), .release);
                self.shared.learn_timer.store(b != 0, .release);
                self.shared.resetLearn();
            }
        },
        c.ARP_ACTION_IMPORT_MIDI => {},
        else => return false,
    }
    return true;
}
fn guiReadText(context: ?*anyopaque, kind: u32, a: u32, b: u32, buffer: [*c]u8, size: u32) callconv(.c) void {
    _ = b;
    const self: *Instance = @ptrCast(@alignCast(context.?));
    if (buffer == null or size == 0) return;
    var scratch: [128]u8 = undefined;
    var text: []const u8 = "";
    switch (kind) {
        c.ARP_TEXT_CHORD_NAME => if (a < 128) {
            text = model.chordName(&self.patch, a, &scratch);
        },
        c.ARP_TEXT_RATE => if (a <= 15) {
            text = model.fmtRate(&scratch, @intCast(a));
        },
        c.ARP_TEXT_PATTERN_NAME => {
            const p = if (a > 11) @as(u32, 0) else a;
            const name = self.patch.name(p);
            if (name.len == 0) {
                text = std.fmt.bufPrint(&scratch, "Pattern {c}", .{@as(u8, 'A') + @as(u8, @intCast(p))}) catch "Pattern";
            } else text = name;
        },
        c.ARP_TEXT_NOTE => if (a <= 127) {
            text = model.noteName(&scratch, @intCast(a));
        },
        c.ARP_TEXT_PC => if (a < 12) {
            text = model.pcName(@intCast(a));
        },
        else => {},
    }
    const n = @min(text.len, size - 1);
    @memcpy(buffer[0..n], text[0..n]);
    buffer[n] = 0;
}
fn guiBeginEdit(context: ?*anyopaque) callconv(.c) void {
    const self: *Instance = @ptrCast(@alignCast(context.?));
    self.beginEdit();
}
fn guiEndEdit(context: ?*anyopaque) callconv(.c) void {
    const self: *Instance = @ptrCast(@alignCast(context.?));
    self.endEdit();
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
    if (self.host.*.request_callback) |request_callback| request_callback(self.host);
}

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
                _ = self.setParam(change.id, change.value, false);
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
fn uiConfig(self: *Instance) ui.native.ArpStickUIConfig {
    return .{
        .context = self,
        .read_param = guiRead,
        .write_param = guiChange,
        .read_field = guiReadField,
        .write_field = guiWriteField,
        .action = guiAction,
        .read_text = guiReadText,
        .begin_edit = guiBeginEdit,
        .end_edit = guiEndEdit,
    };
}
fn guiCreate(plugin: [*c]const c.clap_plugin_t, api: [*c]const u8, floating: bool) callconv(.c) bool {
    const self = Instance.get(plugin);
    if (!guiSupported(plugin, api, floating) or self.editor != null) return false;
    const settings = uiConfig(self);
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
}
fn guiSize(plugin: [*c]const c.clap_plugin_t, width: [*c]u32, height: [*c]u32) callconv(.c) bool {
    if (Instance.get(plugin).editor == null or width == null or height == null) return false;
    width.* = 960;
    height.* = 640;
    return true;
}
fn guiResizable(_: [*c]const c.clap_plugin_t) callconv(.c) bool {
    return false;
}
fn guiHints(_: [*c]const c.clap_plugin_t, _: [*c]c.clap_gui_resize_hints_t) callconv(.c) bool {
    return false;
}
fn guiSetSize(plugin: [*c]const c.clap_plugin_t, width: u32, height: u32) callconv(.c) bool {
    return Instance.get(plugin).editor != null and width == 960 and height == 640;
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

const state_magic = [4]u8{ 'A', 'R', 'P', 2 };
fn streamWrite(stream: [*c]const c.clap_ostream_t, bytes: []const u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = stream.*.write.?(stream, bytes[offset..].ptr, bytes.len - offset);
        if (written <= 0 or written > bytes.len - offset) return false;
        offset += @intCast(written);
    }
    return true;
}
fn writeInt(stream: [*c]const c.clap_ostream_t, comptime T: type, value: T) bool {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    return streamWrite(stream, &bytes);
}
fn streamRead(stream: [*c]const c.clap_istream_t, bytes: []u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const received = stream.*.read.?(stream, bytes[offset..].ptr, bytes.len - offset);
        if (received <= 0 or received > bytes.len - offset) return false;
        offset += @intCast(received);
    }
    return true;
}
fn readInt(stream: [*c]const c.clap_istream_t, comptime T: type) ?T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    if (!streamRead(stream, &bytes)) return null;
    return std.mem.readInt(T, &bytes, .little);
}
fn save(plugin: [*c]const c.clap_plugin_t, stream: [*c]const c.clap_ostream_t) callconv(.c) bool {
    if (stream == null) return false;
    const self = Instance.get(plugin);
    if (!streamWrite(stream, &state_magic)) return false;
    if (!writeInt(stream, u16, 2)) return false;
    for (self.snapshot()) |value| if (!writeInt(stream, i32, value)) return false;
    if (!writeInt(stream, i32, self.shared.cur_slot.load(.monotonic))) return false;
    for (self.shared.watched_bits) |bits| if (!writeInt(stream, u64, bits.load(.monotonic))) return false;
    return streamWrite(stream, model.bytes(&self.patch));
}
fn load(plugin: [*c]const c.clap_plugin_t, stream: [*c]const c.clap_istream_t) callconv(.c) bool {
    if (stream == null) return false;
    var magic: [4]u8 = undefined;
    if (!streamRead(stream, &magic) or !std.mem.eql(u8, &magic, &state_magic)) return false;
    const version = readInt(stream, u16) orelse return false;
    if (version != 2) return false;
    var values: [engine.param_count]i32 = undefined;
    for (&values) |*v| v.* = readInt(stream, i32) orelse return false;
    const cur_slot = readInt(stream, i32) orelse return false;
    var watched: [2]u64 = undefined;
    for (&watched) |*w| w.* = readInt(stream, u64) orelse return false;
    var patch = Model.init();
    if (!streamRead(stream, std.mem.asBytes(&patch))) return false;
    if (!model.validate(&patch)) return false;

    const self = Instance.get(plugin);
    self.beginEdit();
    self.patch = patch;
    self.shared.cur_slot.store(std.math.clamp(cur_slot, 0, 127), .release);
    self.shared.watched_bits[0].store(watched[0], .monotonic);
    self.shared.watched_bits[1].store(watched[1], .monotonic);
    for (values, 0..) |value, i| _ = self.setParam(@intCast(i), value, false);
    self.endEdit();
    self.arp.setPattern(@intCast(self.pattern()));
    self.arp.arp_dirty = true;
    const raw = self.host.*.get_extension.?(self.host, "clap.params");
    if (raw) |ptr| {
        const host_params: *const c.clap_host_params_t = @ptrCast(@alignCast(ptr));
        host_params.rescan.?(self.host, c.CLAP_PARAM_RESCAN_VALUES);
    }
    ui.native.arp_ui_refresh(self.editor);
    return true;
}

const note_ports: c.clap_plugin_note_ports_t = .{ .count = portCount, .get = notePort };
const audio_ports: c.clap_plugin_audio_ports_t = .{ .count = portCount, .get = audioPort };
const params_extension: c.clap_plugin_params_t = .{ .count = paramCount, .get_info = paramInfo, .get_value = paramValue, .value_to_text = valueText, .text_to_value = textValue, .flush = flush };
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
    if (same(id, "clap.params")) return &params_extension;
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
    if (!same(id, "dev.arpstick") or host == null or host.*.clap_version.major != 1) return null;
    const self = std.heap.c_allocator.create(Instance) catch return null;
    const patch = Model.init();
    self.* = .{
        .plugin = .{ .desc = &descriptor, .plugin_data = self, .init = init, .destroy = destroy, .activate = activate, .deactivate = noOp, .start_processing = start, .stop_processing = noOp, .reset = reset, .process = process, .get_extension = extension, .on_main_thread = onMainThread },
        .host = host,
        .values = .{ .init(engine.defaults[0]), .init(engine.defaults[1]), .init(engine.defaults[2]), .init(engine.defaults[3]), .init(engine.defaults[4]), .init(engine.defaults[5]), .init(engine.defaults[6]), .init(engine.defaults[7]) },
        .patch = patch,
        .render = patch,
        .shared = engine.Shared.init(),
        .arp = engine.Engine.init(48000),
        .ui_rng = std.Random.DefaultPrng.init(0x5549524152505354),
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
