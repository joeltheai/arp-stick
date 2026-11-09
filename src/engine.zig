const std = @import("std");
const model = @import("model.zig");
const Model = model.Model;

pub const param_count = 8;
pub const defaults = [param_count]i32{ 1, 1, 0, 0, 0, 0, 0, 0 };
pub const minima = [param_count]i32{ 0, 0, -36, 0, 0, 0, 0, 0 };
pub const maxima = [param_count]i32{ 1, 1, 36, 1, 100, 16, 1, 11 };
pub const param_names = [param_count][]const u8{
    "Chord Module", "Arp Module",     "Chord Transpose", "MIDI Latch",
    "Test Tone",    "Output Channel", "MIDI Remote",     "Pattern",
};
pub const param_labels = [param_count]?[]const []const u8{
    &.{ "Off", "On" },
    &.{ "Off", "On" },
    null,
    &.{ "Off", "On" },
    null,
    &.{ "Input", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16" },
    &.{ "Off", "On" },
    &.{ "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L" },
};

pub const Params = struct {
    chord_on: bool = true,
    arp_on: bool = true,
    transpose: i16 = 0,
    latch: bool = false,
    tone: u8 = 0,
    out_channel: u8 = 0,
    midi_remote: bool = false,
    pattern: u8 = 0,

    pub fn fromValues(values: [param_count]i32) Params {
        return .{
            .chord_on = values[0] != 0,
            .arp_on = values[1] != 0,
            .transpose = @intCast(values[2]),
            .latch = values[3] != 0,
            .tone = @intCast(std.math.clamp(values[4], 0, 100)),
            .out_channel = @intCast(std.math.clamp(values[5], 0, 16)),
            .midi_remote = values[6] != 0,
            .pattern = @intCast(std.math.clamp(values[7], 0, 11)),
        };
    }
};

pub const Transport = struct {
    playing: bool = false,
    tempo: f64 = 120,
    beat: f64 = 0,
    seconds: f64 = 0,
};

pub const Sink = struct {
    context: *anyopaque,
    push: *const fn (*anyopaque, u32, [3]u8) bool,
    pub fn send(self: Sink, time: u32, data: [3]u8) bool {
        return self.push(self.context, time, data);
    }
};

/// Values shared with the editor. Audio advances the slot/learn display.
pub const Shared = struct {
    cur_slot: std.atomic.Value(i32) = std.atomic.Value(i32).init(48),
    watched_bits: [2]std.atomic.Value(u64),
    learning: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    learn_mode: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    learn_timer: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    learn_count: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    learn_notes: [8]std.atomic.Value(i16) = @splat(std.atomic.Value(i16).init(-1)),
    preview_slot: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),
    preview_channel: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    panic: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init() Shared {
        var s: Shared = .{
            .watched_bits = .{ std.atomic.Value(u64).init(0xffffffffffffffff), std.atomic.Value(u64).init(0xffffffffffffffff) },
        };
        s.resetLearn();
        return s;
    }
    pub fn watch(self: *Shared, slot: usize) void {
        _ = self.watched_bits[slot / 64].fetchOr(@as(u64, 1) << @intCast(slot % 64), .monotonic);
    }
    pub fn isWatched(self: *Shared, slot: usize) bool {
        return (self.watched_bits[slot / 64].load(.monotonic) & (@as(u64, 1) << @intCast(slot % 64))) != 0;
    }
    pub fn unwatchAll(self: *Shared) void {
        self.watched_bits[0].store(0, .monotonic);
        self.watched_bits[1].store(0, .monotonic);
    }
    pub fn watchAll(self: *Shared) void {
        self.watched_bits[0].store(0xffffffffffffffff, .monotonic);
        self.watched_bits[1].store(0xffffffffffffffff, .monotonic);
    }
    pub fn resetLearn(self: *Shared) void {
        self.learn_count.store(0, .monotonic);
        for (&self.learn_notes) |*n| n.store(-1, .monotonic);
    }
};

pub const Engine = struct {
    sample_rate: f64 = 48000,
    sample_clock: u64 = 0,
    smpi: u32 = 0,
    bps: f64 = 0,
    L: f64 = 0.25,
    synced: bool = true,
    free_clock: bool = false,
    now: f64 = 0,
    trig_base: f64 = 0,
    next_step: i64 = 0,
    last_fired: i64 = -1,
    shape_pos: i64 = 0,
    want_retrig: bool = false,
    want_silence: bool = false,
    arp_dirty: bool = false,
    panic_request: bool = false,
    playing: bool = false,
    prev_play: bool = false,
    prev_free: bool = false,
    prev_pattern: u8 = 0,
    prev_len: f64 = 0,
    prev_chord: bool = false,
    prev_arp: bool = false,
    prev_channel: u8 = 0,
    last_beat_pos: f64 = 0,
    last_time: f64 = 0,
    last_in_vel: u8 = 100,
    last_in_chan: u8 = 0,
    out_chan: u8 = 0,
    last_out_note: i16 = -1,
    pattern: u8 = 0,
    params: Params = .{},

    in_n: [128]u8 = @splat(0),
    act_r: [128]u8 = @splat(0),
    act_l: [8]i16 = @splat(0),
    act_v: [128]u8 = @splat(0),
    act_cnt: usize = 0,
    active_slot: i16 = -1,
    act_ch: u8 = 0,

    hel_b: [128]u8 = @splat(0),
    arp_cnt: usize = 0,
    arp_root: u8 = 0,

    snd_n: [16]i16 = @splat(0),
    snd_c: [16]u8 = @splat(0),
    snd_o: [16]f64 = @splat(0),
    snd_cnt: usize = 0,
    out_refs: [16][128]u8 = @splat(@splat(0)),

    tv_n: [16]i16 = @splat(-1),
    tv_v: [16]u8 = @splat(0),
    tv_p: [16]f64 = @splat(0),
    tv_t: [16]f64 = @splat(0),
    tv_e: [16]f64 = @splat(0),

    prv_n: [8]i16 = @splat(0),
    prv_c: [8]u8 = @splat(0),
    prv_t: [8]f64 = @splat(0),
    prv_cnt: usize = 0,

    lrn_cnt: usize = 0,
    lrn_b: [8]i16 = @splat(-1),
    lrn_held: usize = 0,
    lrn_offs: u64 = 0,
    lrn_t0: f64 = 0,
    bkdB: [16]i16 = @splat(0),

    rng: std.Random.DefaultPrng,
    lane_len: [8]usize = @splat(1),
    sink: ?Sink = null,
    transport_playing: bool = false,

    pub fn init(sample_rate: f64) Engine {
        return .{
            .sample_rate = if (sample_rate > 0 and std.math.isFinite(sample_rate)) sample_rate else 48000,
            .rng = std.Random.DefaultPrng.init(0x415250535449434b),
        };
    }

    fn randomFloat(self: *Engine) f64 {
        return self.rng.random().float(f64);
    }
    fn randomBelow(self: *Engine, n: u32) f64 {
        if (n == 0) return 0;
        return self.randomFloat() * @as(f64, @floatFromInt(n));
    }

    pub fn reset(self: *Engine) void {
        const rate = self.sample_rate;
        self.* = init(rate);
    }

    pub fn panic(self: *Engine) void {
        self.panic_request = true;
    }

    pub fn setPattern(self: *Engine, p: u8) void {
        self.pattern = @min(p, 11);
    }

    /// Apply automation from inside a block, matching the JSFX @slider/@block
    /// ordering: module routing changes flush generated voices immediately.
    pub fn updateParams(self: *Engine, m: *Model, shared: *Shared, p: Params) void {
        if (p.chord_on != self.params.chord_on or p.arp_on != self.params.arp_on or
            p.out_channel != self.params.out_channel or self.panic_request)
        {
            self.silenceAll(shared);
            self.releaseChord(m, shared, 0);
            self.in_n = @splat(0);
            self.act_r = @splat(0);
            self.arp_cnt = 0;
            self.want_retrig = true;
            self.panic_request = false;
            self.prev_chord = p.chord_on;
            self.prev_arp = p.arp_on;
            self.prev_channel = p.out_channel;
        }
        self.params = p;
        self.pattern = p.pattern;
    }

    pub fn beginBlock(self: *Engine, m: *Model, ui: *Model, shared: *Shared, params: Params, tr: Transport, sink: Sink) void {
        _ = ui;
        self.sink = sink;
        self.transport_playing = tr.playing;
        self.params = params;
        self.pattern = params.pattern;
        self.smpi = 0;
        const bps = if (tr.tempo > 0 and std.math.isFinite(tr.tempo)) tr.tempo / (60.0 * self.sample_rate) else 120.0 / (60.0 * self.sample_rate);
        self.bps = bps;
        const pl = tr.playing;

        self.free_clock = m.free_on or !pl;
        const i: usize = @intCast(@min(m.rate[self.pattern], 15));
        const rate_b: f64 = if (i <= 4)
            64.0 / @as(f64, @floatFromInt(@as(u32, 1) << @intCast(i)))
        else if (i == 5)
            2.0
        else
            1.0 / @as(f64, @floatFromInt(@as(u32, 1) << @intCast(i - 6)));
        self.synced = !self.free_clock;
        self.L = if (self.synced) rate_b else 1.0 / @max(0.05, @as(f64, m.free_hz));

        if (self.free_clock != self.prev_free or self.pattern != self.prev_pattern or @abs(self.L - self.prev_len) > 0.000001)
            self.want_retrig = true;
        self.prev_free = self.free_clock;
        self.prev_pattern = self.pattern;
        self.prev_len = self.L;

        for (0..8) |l| self.lane_len[l] = @max(1, @as(usize, m.lane_len[self.pattern][l]));

        if (pl and !self.prev_play) {
            self.trig_base = if (self.synced) tr.beat else @as(f64, @floatFromInt(self.sample_clock)) / self.sample_rate;
            self.next_step = 0;
            self.last_fired = -1;
            self.shape_pos = 0;
        }
        if (!pl and self.prev_play) self.want_retrig = true;
        self.prev_play = pl;

        if (pl and self.synced) {
            const jump = @abs(tr.beat - self.last_beat_pos);
            if (jump > @max(self.L * 2, 0.5)) {
                self.trig_base = 0;
                self.next_step = @intFromFloat(@floor(tr.beat / @max(self.L, 0.0001)));
                self.last_fired = self.next_step - 1;
                self.shape_pos = 0;
                self.silenceAll(shared);
            }
        }
        self.last_beat_pos = tr.beat;
        self.last_time = tr.seconds;

        if (shared.panic.swap(false, .acquire)) self.panic_request = true;
        if (params.chord_on != self.prev_chord or params.arp_on != self.prev_arp or params.out_channel != self.prev_channel or self.panic_request) {
            self.silenceAll(shared);
            self.releaseChord(m, shared, 0);
            self.in_n = @splat(0);
            self.act_r = @splat(0);
            self.arp_cnt = 0;
            self.want_retrig = true;
            self.panic_request = false;
        }
        self.prev_chord = params.chord_on;
        self.prev_arp = params.arp_on;
        self.prev_channel = params.out_channel;

        const preview_slot = shared.preview_slot.load(.acquire);
        if (preview_slot >= 0) {
            shared.preview_slot.store(-1, .release);
            const slot: usize = @intCast(@min(preview_slot, 127));
            self.silenceAll(shared);
            self.previewChord(m, slot, @intCast(@min(shared.preview_channel.load(.monotonic), 15)), 0);
        }
    }

    fn previewChord(self: *Engine, m: *Model, slot: usize, ch: u8, offs: u32) void {
        var cnt: usize = 0;
        const trans = self.params.transpose;
        for (0..model.voices) |i| {
            const raw: i16 = if (m.lock_on[i]) m.lock_note[i] else m.chord_notes[slot][i];
            if (raw < 0 or cnt >= 8) continue;
            const vel: u8 = @intCast(std.math.clamp(@divFloor(100 * @as(i16, m.chord_vel[slot][i]) + 50, 100), 1, 127));
            const nn: i16 = std.math.clamp(raw + trans, 0, 127);
            self.sendOn(offs, ch, nn, vel);
            self.prv_n[cnt] = nn;
            self.prv_c[cnt] = ch;
            self.prv_t[cnt] = @as(f64, @floatFromInt(self.sample_clock)) / self.sample_rate + 0.18;
            cnt += 1;
        }
        self.prv_cnt = cnt;
    }

    fn previewOffs(self: *Engine, offs: u32) void {
        const now = @as(f64, @floatFromInt(self.sample_clock)) / self.sample_rate;
        var i: usize = 0;
        while (i < self.prv_cnt) {
            if (now >= self.prv_t[i]) {
                self.sendOff(offs, self.prv_c[i], self.prv_n[i]);
                self.prv_cnt -= 1;
                self.prv_n[i] = self.prv_n[self.prv_cnt];
                self.prv_c[i] = self.prv_c[self.prv_cnt];
                self.prv_t[i] = self.prv_t[self.prv_cnt];
            } else i += 1;
        }
    }

    fn toneOn(self: *Engine, note: i16, vel: u8) void {
        if (self.params.tone == 0) return;
        var found: ?usize = null;
        for (0..16) |i| {
            if (self.tv_n[i] == note) {
                found = i;
                break;
            }
        }
        const f = found orelse blk: {
            for (0..16) |i| {
                if (self.tv_n[i] < 0) break :blk i;
            }
            break :blk 0;
        };
        self.tv_n[f] = note;
        self.tv_v[f] = vel;
        self.tv_t[f] = @as(f64, @floatFromInt(vel)) / 127.0 * (@as(f64, @floatFromInt(self.params.tone)) / 100.0);
        self.tv_p[f] = 0;
    }

    fn toneOff(self: *Engine, note: i16) void {
        if (self.params.tone == 0) return;
        for (0..16) |i| {
            if (self.tv_n[i] == note) self.tv_t[i] = 0;
        }
    }

    fn sendOn(self: *Engine, offs: u32, ch: u8, note: i16, vel: u8) void {
        const n: u8 = @intCast(std.math.clamp(note, 0, 127));
        const c: u8 = ch & 15;
        const r = &self.out_refs[c][n];
        if (r.* == 0) _ = self.sinkSend(offs, .{ 0x90 | c, n, vel });
        r.* +|= 1;
        self.toneOn(n, vel);
    }

    fn sendOff(self: *Engine, offs: u32, ch: u8, note: i16) void {
        const n: u8 = @intCast(std.math.clamp(note, 0, 127));
        const c: u8 = ch & 15;
        const r = &self.out_refs[c][n];
        if (r.* > 0) {
            r.* -= 1;
            if (r.* == 0) _ = self.sinkSend(offs, .{ 0x80 | c, n, 0 });
        }
        self.toneOff(n);
    }

    fn sinkSend(self: *Engine, offs: u32, data: [3]u8) bool {
        return if (self.sink) |s| s.send(offs, data) else true;
    }

    fn silenceAll(self: *Engine, shared: *Shared) void {
        _ = shared;
        for (0..16) |c| {
            for (0..128) |n| {
                if (self.out_refs[c][n] > 0) {
                    _ = self.sinkSend(self.smpi, .{ 0x80 | @as(u8, @intCast(c)), @intCast(n), 0 });
                    self.out_refs[c][n] = 0;
                }
            }
        }
        self.snd_cnt = 0;
        self.prv_cnt = 0;
        for (0..16) |i| {
            self.tv_t[i] = 0;
            self.tv_n[i] = -1;
        }
    }

    fn releaseChord(self: *Engine, m: *Model, shared: *Shared, offs: u32) void {
        var i: usize = 0;
        while (i < self.act_cnt) : (i += 1) {
            const nn = self.act_l[i];
            if (nn < 0 or nn > 127) continue;
            const key: usize = @intCast(nn);
            if (self.act_r[key] > 0) {
                self.act_r[key] -= 1;
                if (!self.params.arp_on) self.sendOff(offs, self.act_ch, nn);
            }
        }
        self.act_cnt = 0;
        self.active_slot = -1;
        self.arp_dirty = true;
        _ = m;
        _ = shared;
    }

    fn chordTrigger(self: *Engine, m: *Model, shared: *Shared, n: usize, v: u8, ch: u8, offs: u32) void {
        self.in_n[n] +|= 1;
        shared.cur_slot.store(@intCast(n), .release);
        shared.watch(n);
        if (self.active_slot >= 0 and self.active_slot != @as(i16, @intCast(n))) self.releaseChord(m, shared, offs);
        if (self.in_n[n] > 1) return;

        self.active_slot = @intCast(n);
        self.act_ch = ch;
        var cnt: usize = 0;
        const trans = self.params.transpose;
        for (0..model.voices) |i| {
            const raw: i16 = if (m.lock_on[i]) m.lock_note[i] else m.chord_notes[n][i];
            if (raw >= 0 and m.chord_vel[n][i] > 0) {
                const nn: i16 = std.math.clamp(raw + trans, 0, 127);
                const vel: u8 = @intCast(std.math.clamp(@divFloor(@as(i32, v) * m.chord_vel[n][i] + 50, 100), 1, 127));
                if (!self.params.arp_on) self.sendOn(offs, ch, nn, vel);
                self.act_r[@intCast(nn)] +|= 1;
                self.act_v[@intCast(nn)] = vel;
                self.act_l[cnt] = nn;
                cnt += 1;
            }
        }
        self.act_cnt = cnt;
        self.arp_dirty = true;
        if (self.params.arp_on and m.retrig[self.pattern]) self.want_retrig = true;
    }

    fn learnCommit(self: *Engine, m: *Model, ui: *Model, shared: *Shared) void {
        if (self.lrn_cnt == 0) return;
        var ok = true;
        if (shared.learn_timer.load(.monotonic)) {
            const now = @as(f64, @floatFromInt(self.sample_clock)) / self.sample_rate;
            if (now - self.lrn_t0 < 1.0) ok = false;
        }
        const slot: usize = @intCast(@min(shared.cur_slot.load(.monotonic), 127));
        if (ok) {
            for (0..8) |i| {
                const note: i8 = if (i < self.lrn_cnt) @intCast(self.lrn_b[i]) else -1;
                ui.chord_notes[slot][i] = note;
                m.chord_notes[slot][i] = note;
                ui.chord_vel[slot][i] = 100;
                m.chord_vel[slot][i] = 100;
            }
            if (shared.learn_mode.load(.monotonic) != 3 and slot < 127)
                shared.cur_slot.store(@intCast(slot + 1), .release);
        } else {
            for (0..8) |i| {
                ui.chord_notes[slot][i] = @intCast(self.bkdB[i]);
                m.chord_notes[slot][i] = @intCast(self.bkdB[i]);
                ui.chord_vel[slot][i] = @intCast(self.bkdB[8 + i]);
                m.chord_vel[slot][i] = @intCast(self.bkdB[8 + i]);
            }
        }
        self.lrn_cnt = 0;
        if (shared.learn_mode.load(.monotonic) == 3) {
            shared.learning.store(false, .release);
            shared.learn_mode.store(0, .release);
        }
        shared.resetLearn();
    }

    fn learnOn(self: *Engine, m: *Model, ui: *Model, shared: *Shared, n: u8) void {
        const mode = shared.learn_mode.load(.monotonic);
        if (mode == 2) {
            if (self.lrn_cnt > 0 and @abs(@as(f64, @floatFromInt(self.sample_clock)) - @as(f64, @floatFromInt(self.lrn_offs))) > 0.008 * self.sample_rate)
                self.learnCommit(m, ui, shared);
            self.lrn_offs = self.sample_clock;
        } else if (self.lrn_cnt == 0) {
            self.lrn_t0 = @as(f64, @floatFromInt(self.sample_clock)) / self.sample_rate;
            const slot: usize = @intCast(@min(shared.cur_slot.load(.monotonic), 127));
            for (0..8) |i| {
                self.bkdB[i] = ui.chord_notes[slot][i];
                self.bkdB[8 + i] = ui.chord_vel[slot][i];
            }
            for (0..8) |i| {
                ui.chord_notes[slot][i] = -1;
                m.chord_notes[slot][i] = -1;
            }
        }
        var dup = false;
        for (0..self.lrn_cnt) |i| {
            if (self.lrn_b[i] == n) dup = true;
        }
        if (!dup and self.lrn_cnt < 8) {
            self.lrn_b[self.lrn_cnt] = n;
            shared.learn_notes[self.lrn_cnt].store(n, .release);
            self.lrn_cnt += 1;
        }
        shared.learn_count.store(@intCast(self.lrn_cnt), .release);
    }

    fn inputNoteOn(self: *Engine, m: *Model, ui: *Model, shared: *Shared, n: u8, v: u8, ch: u8, offs: u32) void {
        self.last_in_vel = v;
        self.last_in_chan = ch;
        const learning = shared.learning.load(.acquire);
        if (self.params.latch and !learning) {
            if (self.active_slot >= 0) self.releaseChord(m, shared, offs);
            self.in_n = @splat(0);
            if (self.params.arp_on) {
                self.want_silence = true;
                if (m.retrig[self.pattern]) self.want_retrig = true;
            }
        }
        if (learning) {
            self.lrn_held += 1;
            self.learnOn(m, ui, shared, n);
        } else if (self.params.chord_on) {
            self.chordTrigger(m, shared, n, v, ch, offs);
        } else {
            self.in_n[n] +|= 1;
            if (self.params.arp_on) {
                self.arp_dirty = true;
                if (m.retrig[self.pattern]) self.want_retrig = true;
            } else {
                self.sendOn(offs, ch, n, v);
            }
        }
    }

    fn inputNoteOff(self: *Engine, m: *Model, ui: *Model, shared: *Shared, n: u8, ch: u8, offs: u32) void {
        const learning = shared.learning.load(.acquire);
        if (self.params.latch and !learning) return;
        if (learning) {
            if (self.lrn_held > 0) self.lrn_held -= 1;
            if (self.lrn_held == 0 and shared.learn_mode.load(.monotonic) != 2) self.learnCommit(m, ui, shared);
        } else if (self.params.chord_on) {
            if (self.in_n[n] > 0) self.in_n[n] -= 1;
            if (self.active_slot == @as(i16, @intCast(n)) and self.in_n[n] == 0) self.releaseChord(m, shared, offs);
        } else {
            if (self.in_n[n] > 0) self.in_n[n] -= 1;
            if (self.params.arp_on) {
                self.arp_dirty = true;
            } else {
                self.sendOff(offs, ch, n);
            }
        }
    }

    fn rebuildArp(self: *Engine, m: *Model, shared: *Shared) void {
        var cnt: usize = 0;
        for (0..128) |i| {
            const ref: u8 = if (self.params.chord_on) self.act_r[i] else self.in_n[i];
            if (ref > 0) {
                self.hel_b[cnt] = @intCast(i);
                cnt += 1;
            }
        }
        self.arp_cnt = cnt;
        var pcset: u16 = 0;
        for (0..cnt) |i| pcset |= @as(u16, 1) << @intCast(self.hel_b[i] % 12);
        self.arp_root = if (cnt > 0) model.hindRoot(pcset) else 0;
        if (cnt == 0) self.want_silence = true;
        _ = m;
        _ = shared;
    }

    fn constrain(_: *Engine, m: *Model, nn_in: i16) i16 {
        if (nn_in < 0 or nn_in > 127) return -1;
        const nn = nn_in;
        return switch (m.constraint[@intCast(@mod(nn, 12))]) {
            1 => -1,
            2 => nn + 1,
            3 => nn - 1,
            else => nn,
        };
    }

    fn lateFrac(self: *Engine, m: *Model, s: i64) f64 {
        const pat: usize = self.pattern;
        const late_div = @max(1, @as(i64, m.lane_div[pat][6]));
        const late_len = @max(1, @as(i64, @as(i64, @intCast(self.lane_len[6]))));
        const idx = @mod(@divFloor(s, late_div), late_len);
        const late = @as(f64, @floatFromInt(m.graph[6][pat][@intCast(idx)])) / 100.0;
        const swing = @as(f64, @floatFromInt(m.swing[pat])) / 100.0;
        return late + @as(f64, @floatFromInt(@mod(s, 2))) * swing;
    }

    fn trigOf(self: *Engine, m: *Model, s: i64) f64 {
        return self.trig_base + @as(f64, @floatFromInt(s)) * self.L + self.lateFrac(m, s) * self.L;
    }

    fn arpFire(self: *Engine, m: *Model, shared: *Shared, s: i64) void {
        const n = self.arp_cnt;
        if (n == 0) {
            self.last_fired = s;
            return;
        }
        const pat: usize = self.pattern;
        const div0 = @max(1, @as(i64, m.lane_div[pat][0]));
        const s_n: usize = @intCast(@mod(@divFloor(s, div0), @as(i64, @intCast(self.lane_len[0]))));
        const muted = ((m.mute[pat] >> @intCast(s_n)) & 1) == 1;
        const v: i16 = m.graph[0][pat][s_n];
        if (muted or v < 0) {
            self.silenceAll(shared);
            self.last_fired = s;
            return;
        }
        if (m.reset[pat][s_n]) self.shape_pos = 0;
        var idx: i64 = 0;
        var oct: i64 = 0;
        if (v < 8) {
            const div1 = @max(1, @as(i64, m.lane_div[pat][1]));
            const r: i16 = m.graph[1][pat][@intCast(@mod(@divFloor(s, div1), @as(i64, @intCast(self.lane_len[1]))))];
            const idx0: i64 = @as(i64, v) + (if (r > 0)
                @as(i64, @intFromFloat(@floor(self.randomBelow(@as(u32, @intCast(r + 1))))))
            else if (r < 0)
                -@as(i64, @intFromFloat(@floor(self.randomBelow(@as(u32, @intCast(1 - r))))))
            else
                0);
            idx = @mod(idx0, @as(i64, @intCast(n)));
            oct = @divFloor(idx0, @as(i64, @intCast(n)));
        } else if (v == 8) {
            idx = @mod(self.shape_pos, @as(i64, @intCast(n)));
        } else if (v == 9) {
            idx = @as(i64, @intCast(n)) - 1 - @mod(self.shape_pos, @as(i64, @intCast(n)));
        } else if (v == 10) {
            const p = @max(2 * @as(i64, @intCast(n)) - 2, 1);
            const k = @mod(self.shape_pos, p);
            idx = if (k < @as(i64, @intCast(n))) k else 2 * @as(i64, @intCast(n)) - 2 - k;
        } else if (v == 11) {
            const p = @max(2 * @as(i64, @intCast(n)) - 2, 1);
            const k = @mod(self.shape_pos, p);
            idx = if (k < @as(i64, @intCast(n))) @as(i64, @intCast(n)) - 1 - k else k - @as(i64, @intCast(n)) + 1;
        } else if (v == 12) {
            const p = 2 * @as(i64, @intCast(n));
            const k = @mod(self.shape_pos, p);
            idx = if (k < @as(i64, @intCast(n))) k else 2 * @as(i64, @intCast(n)) - 1 - k;
        } else if (v == 13) {
            const p = 2 * @as(i64, @intCast(n));
            const k = @mod(self.shape_pos, p);
            idx = if (k < @as(i64, @intCast(n))) @as(i64, @intCast(n)) - 1 - k else k - @as(i64, @intCast(n));
        } else if (v == 14) {
            const jj = @divFloor(self.shape_pos, 2);
            idx = if (@mod(self.shape_pos, 2) == 0) @mod(jj, @as(i64, @intCast(n))) else @as(i64, @intCast(n)) - 1;
        } else {
            const jj = @divFloor(self.shape_pos, 2);
            idx = if (@mod(self.shape_pos, 2) == 0) @as(i64, @intCast(n)) - 1 - @mod(jj, @as(i64, @intCast(n))) else 0;
        }
        if (v >= 8 and @mod(s + 1, div0) == 0) self.shape_pos += 1;

        const base: i16 = @as(i16, self.hel_b[@intCast(idx)]) + 12 * @as(i16, @intCast(oct));
        const div2 = @max(1, @as(i64, m.lane_div[pat][2]));
        const ov: i16 = m.graph[2][pat][@intCast(@mod(@divFloor(s, div2), @as(i64, @intCast(self.lane_len[2]))))];
        const div3 = @max(1, @as(i64, m.lane_div[pat][3]));
        const pv: i16 = m.graph[3][pat][@intCast(@mod(@divFloor(s, div3), @as(i64, @intCast(self.lane_len[3]))))];
        const root: i16 = self.arp_root;

        var out: [16]i16 = @splat(0);
        var out_cnt: usize = 0;
        if (m.chord_mode[pat]) {
            for (0..n) |i| {
                const ni: i64 = idx + @as(i64, @intCast(i));
                var nn: i16 = @as(i16, self.hel_b[@intCast(@mod(ni, @as(i64, @intCast(n))))]) +
                    12 * @as(i16, @intCast(@divFloor(ni, @as(i64, @intCast(n))))) + 12 * @as(i16, @intCast(oct)) + 12 * ov;
                if (pv != 0) {
                    const pc = @mod(nn, 12);
                    const deg = model.degreeOf(@mod(pc - root + 120, 12));
                    if (m.pen[deg - 1]) nn += pv;
                }
                nn = self.constrain(m, nn);
                if (nn >= 0 and nn <= 127 and out_cnt < 16) {
                    out[out_cnt] = nn;
                    out_cnt += 1;
                }
            }
        } else {
            var nn: i16 = base + 12 * ov;
            if (pv != 0) {
                const pc = @mod(nn, 12);
                const deg = model.degreeOf(@mod(pc - root + 120, 12));
                if (m.pen[deg - 1]) nn += pv;
            }
            nn = self.constrain(m, nn);
            if (nn >= 0 and nn <= 127) {
                out[0] = nn;
                out_cnt = 1;
            }
        }
        const div7 = @max(1, @as(i64, m.lane_div[pat][7]));
        const hv: i16 = m.graph[7][pat][@intCast(@mod(@divFloor(s, div7), @as(i64, @intCast(self.lane_len[7]))))];
        if (hv != 0) {
            const hn = self.constrain(m, base + 12 * ov + hv);
            if (hn >= 0 and hn <= 127 and out_cnt < 16) {
                out[out_cnt] = hn;
                out_cnt += 1;
            }
        }
        const div4 = @max(1, @as(i64, m.lane_div[pat][4]));
        const vv: i16 = m.graph[4][pat][@intCast(@mod(@divFloor(s, div4), @as(i64, @intCast(self.lane_len[4]))))];
        const source_vel: u8 = if (self.params.chord_on) self.act_v[@intCast(self.hel_b[@intCast(idx)])] else self.last_in_vel;
        const ovel: u8 = @intCast(std.math.clamp(@divFloor(@as(i32, source_vel) * vv + 50, 100), 1, 127));
        const div5 = @max(1, @as(i64, m.lane_div[pat][5]));
        const gv: i16 = m.graph[5][pat][@intCast(@mod(@divFloor(s, div5), @as(i64, @intCast(self.lane_len[5]))))];
        if (vv <= 0 or gv <= 0) out_cnt = 0;
        const off_t: f64 = if (gv >= 100) self.now + 1_000_000_000 else self.now + @as(f64, @floatFromInt(gv)) * self.L / 100.0;

        var i: usize = 0;
        while (i < self.snd_cnt) {
            var found = false;
            for (0..out_cnt) |j| {
                if (out[j] == self.snd_n[i] and self.out_chan == self.snd_c[i]) found = true;
            }
            if (found) {
                self.snd_o[i] = off_t;
                i += 1;
            } else {
                self.sendOff(self.smpi, self.snd_c[i], self.snd_n[i]);
                self.snd_cnt -= 1;
                self.snd_n[i] = self.snd_n[self.snd_cnt];
                self.snd_c[i] = self.snd_c[self.snd_cnt];
                self.snd_o[i] = self.snd_o[self.snd_cnt];
            }
        }
        i = 0;
        while (i < out_cnt) : (i += 1) {
            var found = false;
            for (0..self.snd_cnt) |j| {
                if (self.snd_n[j] == out[i] and self.snd_c[j] == self.out_chan) found = true;
            }
            if (!found and self.snd_cnt < 16) {
                self.sendOn(self.smpi, self.out_chan, out[i], ovel);
                self.snd_n[self.snd_cnt] = out[i];
                self.snd_c[self.snd_cnt] = self.out_chan;
                self.snd_o[self.snd_cnt] = off_t;
                self.snd_cnt += 1;
            }
        }
        self.last_out_note = if (out_cnt > 0) out[out_cnt - 1] else -1;
        self.last_fired = s;
    }

    pub fn noteEvent(self: *Engine, m: *Model, ui: *Model, shared: *Shared, data: [3]u8, offs: u32) void {
        const status = data[0] & 0xf0;
        const ch = data[0] & 15;
        const n = data[1] & 127;
        const v = data[2] & 127;
        const routed: u8 = if (self.params.out_channel > 0) self.params.out_channel - 1 else ch;
        if (status == 0x90 and v > 0) {
            self.inputNoteOn(m, ui, shared, n, v, routed, offs);
        } else {
            self.inputNoteOff(m, ui, shared, n, routed, offs);
        }
        self.out_chan = if (self.params.out_channel > 0) self.params.out_channel - 1 else self.last_in_chan;
    }

    pub fn control(self: *Engine, data: [3]u8) void {
        const cc = data[1] & 127;
        if (cc == 120 or cc == 123) self.panic_request = true;
    }

    /// Advance one sample. Returns the added test-tone sample.
    pub fn tick(self: *Engine, m: *Model, shared: *Shared, offs: u32) f32 {
        self.smpi = offs;
        if (self.arp_dirty) {
            self.rebuildArp(m, shared);
            self.arp_dirty = false;
        }
        if (self.want_silence) {
            self.silenceAll(shared);
            self.want_silence = false;
        }
        self.playing = self.transport_playing or self.free_clock;
        if (self.playing and self.params.arp_on) {
            self.now = if (self.synced)
                self.last_beat_pos + @as(f64, @floatFromInt(offs)) * self.bps
            else
                @as(f64, @floatFromInt(self.sample_clock)) / self.sample_rate;
            if (self.want_retrig) {
                self.want_retrig = false;
                self.silenceAll(shared);
                self.shape_pos = 0;
                self.trig_base = self.now - self.lateFrac(m, 0) * self.L;
                self.next_step = 0;
                self.last_fired = -1;
            }
            var s = self.next_step;
            var guard: usize = 0;
            while (self.now >= self.trigOf(m, s) and guard < 64) : (guard += 1) {
                self.arpFire(m, shared, s);
                s += 1;
            }
            self.next_step = s;
            var i: usize = 0;
            while (i < self.snd_cnt) {
                if (self.now >= self.snd_o[i]) {
                    self.sendOff(offs, self.snd_c[i], self.snd_n[i]);
                    self.snd_cnt -= 1;
                    self.snd_n[i] = self.snd_n[self.snd_cnt];
                    self.snd_c[i] = self.snd_c[self.snd_cnt];
                    self.snd_o[i] = self.snd_o[self.snd_cnt];
                } else i += 1;
            }
        }
        self.previewOffs(offs);

        var tone: f32 = 0;
        if (self.params.tone > 0) {
            var sum: f64 = 0;
            for (0..16) |i| {
                if (self.tv_n[i] >= 0) {
                    const f = 440.0 * std.math.exp((@as(f64, @floatFromInt(self.tv_n[i])) - 69.0) * @log(2.0) / 12.0);
                    self.tv_p[i] += f / self.sample_rate;
                    if (self.tv_p[i] >= 1) self.tv_p[i] -= 1;
                    const k = if (self.tv_t[i] > self.tv_e[i]) 0.2 else 1.0 / (0.04 * self.sample_rate);
                    self.tv_e[i] += (self.tv_t[i] - self.tv_e[i]) * k;
                    sum += (2 * self.tv_p[i] - 1) * self.tv_e[i];
                    if (self.tv_t[i] == 0 and self.tv_e[i] < 0.001) self.tv_n[i] = -1;
                }
            }
            tone = @floatCast(sum * 0.15);
        }

        self.smpi += 1;
        self.sample_clock += 1;
        return tone;
    }

    // ---- chord-bank helpers used by the editor ----
    pub fn cellYToVal(lane: usize, y: f64) i16 {
        const f = (y - 48) / 296.0;
        return switch (lane) {
            0 => @intCast(15 - @as(i32, @intFromFloat(@floor(f * 17)))),
            1, 2 => @intCast(8 - @as(i32, @intFromFloat(@floor(f * 17)))),
            3 => @intCast(12 - @as(i32, @intFromFloat(@floor(f * 25)))),
            4 => @intCast(200 - @as(i32, @intFromFloat(@floor(f * 201)))),
            5 => @intCast(100 - @as(i32, @intFromFloat(@floor(f * 101)))),
            6 => @intCast(100 - @as(i32, @intFromFloat(@floor(f * 201)))),
            else => @intCast(12 - @as(i32, @intFromFloat(@floor(f * 25)))),
        };
    }
};

