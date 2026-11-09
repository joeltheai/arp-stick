const std = @import("std");
const engine = @import("engine.zig");
const model = @import("model.zig");
const ui = @import("ui.zig");

const Model = model.Model;

// The preview shares the actual editor with a local backend. It produces no
// audio or MIDI, but every bank/pattern edit behaves like the plugin.
const Preview = struct {
    values: [engine.param_count]std.atomic.Value(i32),
    patch: Model,
    shared: engine.Shared,
    arp: engine.Engine,

    fn init() Preview {
        const patch = Model.init();
        var result: Preview = .{
            .values = undefined,
            .patch = patch,
            .shared = engine.Shared.init(),
            .arp = engine.Engine.init(48000),
        };
        for (&result.values, 0..) |*v, i| v.* = std.atomic.Value(i32).init(engine.defaults[i]);
        return result;
    }
    fn p(self: *Preview, id: u32) i32 {
        return if (id < engine.param_count) self.values[id].load(.monotonic) else 0;
    }
    fn pat(self: *Preview) usize {
        return @intCast(std.math.clamp(self.p(7), 0, 11));
    }
    fn slot(self: *Preview) usize {
        return @intCast(std.math.clamp(self.shared.cur_slot.load(.monotonic), 0, 127));
    }
};

fn readParam(context: ?*anyopaque, id: u32) callconv(.c) i32 {
    const self: *Preview = @ptrCast(@alignCast(context.?));
    if (id >= engine.param_count) return 0;
    return self.values[id].load(.monotonic);
}
fn writeParam(context: ?*anyopaque, id: u32, value: i32) callconv(.c) bool {
    const self: *Preview = @ptrCast(@alignCast(context.?));
    if (id >= engine.param_count) return false;
    self.values[id].store(std.math.clamp(value, engine.minima[id], engine.maxima[id]), .monotonic);
    return true;
}
fn readField(context: ?*anyopaque, field: u32, a: u32, b: u32) callconv(.c) i32 {
    const self: *Preview = @ptrCast(@alignCast(context.?));
    const pat = self.pat();
    const slot = self.slot();
    return switch (field) {
        ui.native.ARP_FIELD_CHORD_NOTE => if (a < 128 and b < 8) self.patch.chord_notes[a][b] else -1,
        ui.native.ARP_FIELD_CHORD_VEL => if (a < 128 and b < 8) self.patch.chord_vel[a][b] else 0,
        ui.native.ARP_FIELD_LOCK_ON => if (a < 8) @intFromBool(self.patch.lock_on[a]) else 0,
        ui.native.ARP_FIELD_LOCK_NOTE => if (a < 8) self.patch.lock_note[a] else -1,
        ui.native.ARP_FIELD_CELL => if (a < 8 and b < 16) self.patch.graph[a][pat][b] else 0,
        ui.native.ARP_FIELD_RESET => if (b < 16) @intFromBool(self.patch.reset[pat][b]) else 0,
        ui.native.ARP_FIELD_MUTE => if (b < 16) @intFromBool(((self.patch.mute[pat] >> @intCast(b)) & 1) != 0) else 0,
        ui.native.ARP_FIELD_LEN => if (a < 8) self.patch.lane_len[pat][a] else 0,
        ui.native.ARP_FIELD_DIV => if (a < 8) self.patch.lane_div[pat][a] else 0,
        ui.native.ARP_FIELD_RATE => self.patch.rate[pat],
        ui.native.ARP_FIELD_SWING => self.patch.swing[pat],
        ui.native.ARP_FIELD_RETRIG => @intFromBool(self.patch.retrig[pat]),
        ui.native.ARP_FIELD_LINK => @intFromBool(self.patch.link[pat]),
        ui.native.ARP_FIELD_CHORD_MODE => @intFromBool(self.patch.chord_mode[pat]),
        ui.native.ARP_FIELD_CONSTRAINT => if (a < 12) self.patch.constraint[a] else 0,
        ui.native.ARP_FIELD_PEN => if (a < 7) @intFromBool(self.patch.pen[a]) else 0,
        ui.native.ARP_FIELD_CUR_SLOT => @intCast(slot),
        ui.native.ARP_FIELD_PATTERN => @intCast(pat),
        ui.native.ARP_FIELD_FREE_ON => @intFromBool(self.patch.free_on),
        ui.native.ARP_FIELD_FREE_HZ => @intFromFloat(@round(@as(f64, self.patch.free_hz) * 100.0)),
        ui.native.ARP_FIELD_WATCH_ON => @intFromBool(self.patch.watch_on),
        ui.native.ARP_FIELD_WATCHED => if (a < 128) @intFromBool(self.shared.isWatched(a)) else 0,
        ui.native.ARP_FIELD_NAME_CHAR => if (a < 24) self.patch.names[pat][a] else 0,
        ui.native.ARP_FIELD_CUR_GRAPH => self.patch.cur_graph,
        ui.native.ARP_FIELD_SCALE_KEY => self.patch.scale_key,
        ui.native.ARP_FIELD_SCALE_TYPE => self.patch.scale_type,
        ui.native.ARP_FIELD_LEARNING => @intFromBool(self.shared.learning.load(.monotonic)),
        ui.native.ARP_FIELD_LEARN_MODE => self.shared.learn_mode.load(.monotonic),
        ui.native.ARP_FIELD_LEARN_TIMER => @intFromBool(self.shared.learn_timer.load(.monotonic)),
        ui.native.ARP_FIELD_LEARN_COUNT => self.shared.learn_count.load(.monotonic),
        ui.native.ARP_FIELD_LEARN_NOTE => if (a < 8) self.shared.learn_notes[a].load(.monotonic) else -1,
        ui.native.ARP_FIELD_PLAYING => @intFromBool(self.patch.free_on),
        ui.native.ARP_FIELD_LAST_FIRED => -1,
        ui.native.ARP_FIELD_LAST_OUT => -1,
        ui.native.ARP_FIELD_ARP_COUNT => 0,
        ui.native.ARP_FIELD_SND_COUNT => 0,
        ui.native.ARP_FIELD_ACTIVE_SLOT => -1,
        ui.native.ARP_FIELD_PATTERN_USED => if (a < 12) @intFromBool(self.patch.patternUsed(a)) else 0,
        else => 0,
    };
}
fn writeField(context: ?*anyopaque, field: u32, a: u32, b: u32, value: i32) callconv(.c) bool {
    const self: *Preview = @ptrCast(@alignCast(context.?));
    const pat = self.pat();
    const slot = self.slot();
    switch (field) {
        ui.native.ARP_FIELD_CHORD_NOTE => {
            if (a >= 128 or b >= 8) return false;
            self.patch.chord_notes[a][b] = @intCast(std.math.clamp(value, -1, 127));
        },
        ui.native.ARP_FIELD_CHORD_VEL => {
            if (a >= 128 or b >= 8) return false;
            self.patch.chord_vel[a][b] = @intCast(std.math.clamp(value, 0, 200));
        },
        ui.native.ARP_FIELD_LOCK_ON => {
            if (a >= 8) return false;
            self.patch.lock_on[a] = value != 0;
            if (value != 0) self.patch.lock_note[a] = @max(-1, self.patch.chord_notes[slot][a]);
        },
        ui.native.ARP_FIELD_LOCK_NOTE => {
            if (a < 8) self.patch.lock_note[a] = @intCast(std.math.clamp(value, -1, 127));
        },
        ui.native.ARP_FIELD_CELL => if (a < 8 and b < 16) self.patch.setGraph(a, pat, b, @intCast(value)),
        ui.native.ARP_FIELD_RESET => {
            if (b < 16) self.patch.reset[pat][b] = value != 0;
        },
        ui.native.ARP_FIELD_MUTE => {
            if (b >= 16) return false;
            const bit: u16 = @as(u16, 1) << @intCast(b);
            if (value != 0) self.patch.mute[pat] |= bit else self.patch.mute[pat] &= ~bit;
        },
        ui.native.ARP_FIELD_LEN => {
            if (a < 8) self.patch.lane_len[pat][a] = @intCast(std.math.clamp(value, 1, 16));
        },
        ui.native.ARP_FIELD_DIV => {
            if (a < 8) self.patch.lane_div[pat][a] = @intCast(std.math.clamp(value, 1, 8));
        },
        ui.native.ARP_FIELD_RATE => self.patch.rate[pat] = @intCast(std.math.clamp(value, 0, 15)),
        ui.native.ARP_FIELD_SWING => self.patch.swing[pat] = @intCast(std.math.clamp(value, 0, 75)),
        ui.native.ARP_FIELD_RETRIG => self.patch.retrig[pat] = value != 0,
        ui.native.ARP_FIELD_LINK => self.patch.link[pat] = value != 0,
        ui.native.ARP_FIELD_CHORD_MODE => self.patch.chord_mode[pat] = value != 0,
        ui.native.ARP_FIELD_CONSTRAINT => {
            if (a < 12) self.patch.constraint[a] = @intCast(@mod(value, 4));
        },
        ui.native.ARP_FIELD_PEN => {
            if (a < 7) self.patch.pen[a] = value != 0;
        },
        ui.native.ARP_FIELD_CUR_SLOT => self.shared.cur_slot.store(std.math.clamp(value, 0, 127), .monotonic),
        ui.native.ARP_FIELD_PATTERN => _ = writeParam(context, 7, value),
        ui.native.ARP_FIELD_FREE_ON => self.patch.free_on = value != 0,
        ui.native.ARP_FIELD_FREE_HZ => self.patch.free_hz = @floatCast(std.math.clamp(@as(f64, @floatFromInt(value)) / 100.0, 0.05, 40)),
        ui.native.ARP_FIELD_WATCH_ON => {
            self.patch.watch_on = value != 0;
            if (value != 0) self.shared.unwatchAll();
        },
        ui.native.ARP_FIELD_NAME_CHAR => if (a < 24) self.patch.setNameChar(pat, a, @intCast(std.math.clamp(value, 0, 255))),
        ui.native.ARP_FIELD_CUR_GRAPH => self.patch.cur_graph = @intCast(std.math.clamp(value, 0, 7)),
        ui.native.ARP_FIELD_SCALE_KEY => self.patch.scale_key = @intCast(std.math.clamp(value, 0, 11)),
        ui.native.ARP_FIELD_SCALE_TYPE => self.patch.scale_type = @intCast(std.math.clamp(value, 0, 6)),
        ui.native.ARP_FIELD_LEARNING => {
            self.shared.learning.store(value != 0, .monotonic);
            if (value == 0) {
                self.shared.learn_mode.store(0, .monotonic);
                self.shared.resetLearn();
            }
        },
        ui.native.ARP_FIELD_LEARN_MODE => self.shared.learn_mode.store(@intCast(std.math.clamp(value, 0, 3)), .monotonic),
        ui.native.ARP_FIELD_LEARN_TIMER => self.shared.learn_timer.store(value != 0, .monotonic),
        ui.native.ARP_FIELD_LEARN_COUNT => {
            self.shared.resetLearn();
            self.arp.lrn_cnt = 0;
        },
        else => return false,
    }
    return true;
}
fn action(context: ?*anyopaque, action_id: u32, a: i32, b: i32) callconv(.c) bool {
    const self: *Preview = @ptrCast(@alignCast(context.?));
    const pat = self.pat();
    switch (action_id) {
        ui.native.ARP_ACTION_COPY_PATTERN => {
            if (a < 0 or a > 11 or b < 0 or b > 11) return false;
            self.patch.copyPattern(@intCast(a), @intCast(b));
            _ = writeParam(context, 7, b);
        },
        ui.native.ARP_ACTION_COPY_GRAPH => self.patch.graphCopy(self.patch.cur_graph, pat),
        ui.native.ARP_ACTION_PASTE_GRAPH => self.patch.graphPaste(self.patch.cur_graph, pat),
        ui.native.ARP_ACTION_RAND_GRAPH => self.patch.graphRandom(self.patch.cur_graph, pat, &self.arp.rng),
        ui.native.ARP_ACTION_ARP_PRESET => if (a >= 0 and a <= 10) self.patch.applyArpPreset(pat, @intCast(a), &self.arp.rng),
        ui.native.ARP_ACTION_CHORD_PRESET => if (a >= 0 and a <= 55) self.patch.applyChordPreset(@intCast(a)),
        ui.native.ARP_ACTION_SORT => if (a >= 0 and a <= 5) self.patch.sortSlots(@intCast(a)),
        ui.native.ARP_ACTION_REMOVE_DUPS => self.patch.removeDups(),
        ui.native.ARP_ACTION_REMOVE_N => if (a >= 0 and a <= 8) self.patch.removeNNotes(@intCast(a)),
        ui.native.ARP_ACTION_REMOVE_UNWATCHED => {
            var watched: [128]bool = undefined;
            for (0..128) |i| watched[i] = self.shared.isWatched(i);
            self.patch.removeUnwatched(&watched);
        },
        ui.native.ARP_ACTION_CLEAR_ALL => for (0..model.slots) |s| self.patch.slotClear(s),
        ui.native.ARP_ACTION_MAKE_THIRD => if (a == 3 or a == 4 or a == 5) self.patch.makeThird(@intCast(a)),
        ui.native.ARP_ACTION_TRANSFORM_PREVENT => self.patch.transformPrevent(),
        ui.native.ARP_ACTION_TRANSFORM_MATCH => if (a >= 0 and a < 128) self.patch.transformMatch(@intCast(a)),
        ui.native.ARP_ACTION_POPULATE_EMPTY => self.patch.populateEmpty(),
        ui.native.ARP_ACTION_COPY_CHORD => if (a >= 0 and a < 128) self.patch.chordCopy(@intCast(a)),
        ui.native.ARP_ACTION_PASTE_CHORD => if (a >= 0 and a < 128) self.patch.chordPaste(@intCast(a)),
        ui.native.ARP_ACTION_RAND_CHORD => if (a >= 0 and a < 128) self.patch.randomChord(@intCast(a), &self.arp.rng),
        ui.native.ARP_ACTION_PREVIEW_CHORD => {
            self.shared.preview_slot.store(a, .monotonic);
            self.shared.preview_channel.store(b, .monotonic);
        },
        ui.native.ARP_ACTION_PANIC => {},
        ui.native.ARP_ACTION_TOGGLE_LEARN => {
            const on = self.shared.learning.load(.monotonic);
            if (on) {
                self.shared.learning.store(false, .monotonic);
                self.shared.learn_mode.store(0, .monotonic);
                self.shared.resetLearn();
            } else {
                self.shared.learning.store(true, .monotonic);
                self.shared.learn_mode.store(@intCast(std.math.clamp(a, 1, 3)), .monotonic);
                self.shared.learn_timer.store(b != 0, .monotonic);
                self.shared.resetLearn();
            }
        },
        ui.native.ARP_ACTION_IMPORT_MIDI => {},
        else => return false,
    }
    return true;
}
fn readText(context: ?*anyopaque, kind: u32, a: u32, b: u32, buffer: [*c]u8, size: u32) callconv(.c) void {
    _ = b;
    const self: *Preview = @ptrCast(@alignCast(context.?));
    if (buffer == null or size == 0) return;
    var scratch: [128]u8 = undefined;
    var result: []const u8 = "";
    switch (kind) {
        ui.native.ARP_TEXT_CHORD_NAME => if (a < 128) {
            result = model.chordName(&self.patch, a, &scratch);
        },
        ui.native.ARP_TEXT_RATE => if (a <= 15) {
            result = model.fmtRate(&scratch, @intCast(a));
        },
        ui.native.ARP_TEXT_PATTERN_NAME => {
            const p = if (a > 11) @as(u32, 0) else a;
            const name = self.patch.name(p);
            if (name.len == 0) {
                result = std.fmt.bufPrint(&scratch, "Pattern {c}", .{@as(u8, 'A') + @as(u8, @intCast(p))}) catch "Pattern";
            } else result = name;
        },
        ui.native.ARP_TEXT_NOTE => if (a <= 127) {
            result = model.noteName(&scratch, @intCast(a));
        },
        ui.native.ARP_TEXT_PC => if (a < 12) {
            result = model.pcName(@intCast(a));
        },
        else => {},
    }
    const n = @min(result.len, size - 1);
    @memcpy(buffer[0..n], result[0..n]);
    buffer[n] = 0;
}
fn beginEdit(_: ?*anyopaque) callconv(.c) void {}
fn endEdit(_: ?*anyopaque) callconv(.c) void {}

pub fn main() void {
    var state = Preview.init();
    const settings: ui.native.ArpStickUIConfig = .{
        .context = &state,
        .read_param = readParam,
        .write_param = writeParam,
        .read_field = readField,
        .write_field = writeField,
        .action = action,
        .read_text = readText,
        .begin_edit = beginEdit,
        .end_edit = endEdit,
    };
    _ = ui.native.arp_ui_preview(&settings);
}
