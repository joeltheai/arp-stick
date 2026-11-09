const std = @import("std");

pub const slots = 128;
pub const voices = 8;
pub const patterns = 12;
pub const steps = 16;
pub const lanes = 8;
pub const pitch_classes = 12;

pub const Lane = enum(usize) {
    note = 0,
    random = 1,
    octave = 2,
    pitch = 3,
    velocity = 4,
    gate = 5,
    late = 6,
    harmony = 7,
};

pub const lane_names = [lanes][]const u8{ "NOTE", "RAND", "OCT", "PITCH", "VEL", "GATE", "LATE", "HARM" };
pub const lane_min = [lanes]i16{ -1, -8, -8, -12, 0, 0, -100, -12 };
pub const lane_max = [lanes]i16{ 15, 8, 8, 12, 200, 100, 100, 12 };
pub const lane_defaults = [lanes]i16{ -1, 0, 0, 0, 100, 100, 0, 0 };

/// Persistent patch data. Layout is private; state is written with `bytes()`.
pub const Model = extern struct {
    chord_notes: [slots][voices]i8,
    chord_vel: [slots][voices]u8,
    lock_on: [voices]bool,
    lock_note: [voices]i8,
    graph: [lanes][patterns][steps]i16,
    reset: [patterns][steps]bool,
    mute: [patterns]u16,
    lane_len: [patterns][lanes]u8,
    lane_div: [patterns][lanes]u8,
    rate: [patterns]u8,
    retrig: [patterns]bool,
    chord_mode: [patterns]bool,
    link: [patterns]bool,
    constraint: [pitch_classes]u8,
    pen: [7]bool,
    swing: [patterns]u8,
    names: [patterns][24]u8,
    free_on: bool,
    free_hz: f32,
    watch_on: bool,
    scale_key: u8,
    scale_type: u8,
    cur_graph: u8,
    chord_clip_valid: bool,
    chord_clip: [voices]i8,
    chord_clip_vel: [voices]u8,
    graph_clip_valid: bool,
    graph_clip: [steps]i16,
    graph_clip_len: u8,
    graph_clip_div: u8,
    graph_clip_lane: u8,
    graph_clip_reset: [steps]bool,

    pub fn init() Model {
        var m: Model = undefined;
        @memset(std.mem.asBytes(&m), 0);
        m.free_hz = 8;
        m.rate = @splat(8);
        for (0..voices) |v| {
            m.lock_note[v] = -1;
            m.chord_clip[v] = -1;
        }
        m.graph_clip_len = 16;
        m.graph_clip_div = 1;

        // Factory bank: a minor triad rooted on every key.
        for (0..slots) |s| {
            m.chord_notes[s] = @splat(-1);
            m.chord_vel[s] = @splat(100);
            const root: i16 = if (s + 7 > 127 and s >= 12) @as(i16, @intCast(s)) - 12 else @intCast(s);
            m.chord_notes[s][0] = @intCast(root);
            m.chord_notes[s][1] = @intCast(root + 3);
            m.chord_notes[s][2] = @intCast(root + 7);
        }

        for (0..patterns) |p| {
            for (0..lanes) |l| {
                for (0..steps) |i| m.graph[l][p][i] = lane_defaults[l];
                m.lane_len[p][l] = 16;
                m.lane_div[p][l] = 1;
            }
            m.rate[p] = 8;
        }
        // Pattern A is an ascending 16th-note arpeggio.
        for (0..steps) |i| m.graph[0][0][i] = 8;
        m.pen = @splat(true);
        m.scale_key = 0;
        m.scale_type = 0;
        m.cur_graph = 0;
        return m;
    }

    pub fn clone(self: *const Model) Model {
        var result: Model = undefined;
        result = self.*;
        return result;
    }

    pub fn setGraph(self: *Model, lane: usize, pattern: usize, column: usize, value: i16) void {
        const clamped = std.math.clamp(value, lane_min[lane], lane_max[lane]);
        self.graph[lane][pattern][column] = clamped;
    }

    pub fn graphVal(self: *const Model, lane: usize, pattern: usize, column: usize) i16 {
        return self.graph[lane][pattern][column];
    }

    pub fn patternUsed(self: *const Model, p: usize) bool {
        if (self.mute[p] != 0 or self.rate[p] != 8 or self.retrig[p] or self.chord_mode[p]) return true;
        for (0..lanes) |l| {
            for (0..steps) |i| {
                if (self.graph[l][p][i] != lane_defaults[l] or self.reset[p][i]) return true;
            }
        }
        return false;
    }

    pub fn used(self: *const Model, slot: usize) bool {
        for (self.chord_notes[slot]) |n| {
            if (n >= 0) return true;
        }
        return false;
    }

    pub fn slotClear(self: *Model, slot: usize) void {
        self.chord_notes[slot] = @splat(-1);
        self.chord_vel[slot] = @splat(100);
    }

    pub fn slotCopy(self: *Model, dst: usize, src: usize) void {
        self.chord_notes[dst] = self.chord_notes[src];
        self.chord_vel[dst] = self.chord_vel[src];
    }

    pub fn collapseSlots(self: *Model) void {
        var d: usize = 0;
        for (0..slots) |s| {
            if (self.used(s)) {
                if (d != s) self.slotCopy(d, s);
                d += 1;
            }
        }
        for (d..slots) |s| self.slotClear(s);
    }

    pub fn sortNotes(self: *Model, slot: usize) void {
        var i: usize = 1;
        while (i < voices) : (i += 1) {
            const nn = self.chord_notes[slot][i];
            const vv = self.chord_vel[slot][i];
            var j = i;
            while (j > 0) {
                const prev = self.chord_notes[slot][j - 1];
                if (nn >= 0 and (prev < 0 or prev > nn)) {
                    self.chord_notes[slot][j] = prev;
                    self.chord_vel[slot][j] = self.chord_vel[slot][j - 1];
                    j -= 1;
                } else break;
            }
            self.chord_notes[slot][j] = nn;
            self.chord_vel[slot][j] = vv;
        }
    }

    fn slotKey(self: *const Model, slot: usize, mode: u8) i64 {
        var lo: i16 = 999;
        var hi: i16 = -1;
        var cnt: i16 = 0;
        var pcset: u16 = 0;
        for (self.chord_notes[slot]) |n| {
            if (n >= 0) {
                if (n < lo) lo = n;
                if (n > hi) hi = n;
                cnt += 1;
                pcset |= @as(u16, 1) << @intCast(@mod(n, 12));
            }
        }
        if (cnt == 0) return 1_000_000_000;
        const root = hindRoot(pcset);
        return switch (mode) {
            0 => lo,
            1 => @as(i64, @mod(lo, 12)) * 128 + lo,
            2 => hi,
            3 => -@as(i64, cnt) * 128 + lo,
            4 => @as(i64, root) * 128 + lo,
            else => @as(i64, @mod(root * 7, 12)) * 128 + lo,
        };
    }

    pub fn sortSlots(self: *Model, mode: u8) void {
        var order: [slots]usize = undefined;
        var keys: [slots]i64 = undefined;
        for (0..slots) |i| {
            keys[i] = self.slotKey(i, mode);
            order[i] = i;
        }
        for (1..slots) |i| {
            const k = keys[i];
            const id = order[i];
            var j: isize = @intCast(i);
            while (j > 0 and keys[@intCast(j - 1)] > k) : (j -= 1) {
                keys[@intCast(j)] = keys[@intCast(j - 1)];
                order[@intCast(j)] = order[@intCast(j - 1)];
            }
            keys[@intCast(j)] = k;
            order[@intCast(j)] = id;
        }
        const notes = self.chord_notes;
        const vels = self.chord_vel;
        for (0..slots) |i| {
            self.chord_notes[i] = notes[order[i]];
            self.chord_vel[i] = vels[order[i]];
        }
    }

    pub fn makeThird(self: *Model, delta: i16) void {
        for (0..slots) |s| {
            var pcset: u16 = 0;
            var cnt: usize = 0;
            for (self.chord_notes[s]) |n| {
                if (n >= 0) {
                    pcset |= @as(u16, 1) << @intCast(@mod(n, 12));
                    cnt += 1;
                }
            }
            if (cnt < 2) continue;
            const root = hindRoot(pcset);
            var tpc: i16 = -1;
            if ((pcset & (@as(u16, 1) << @intCast(@mod(root + 3, 12)))) != 0) tpc = @mod(root + 3, 12);
            if ((pcset & (@as(u16, 1) << @intCast(@mod(root + 4, 12)))) != 0) tpc = @mod(root + 4, 12);
            if (tpc < 0) continue;
            for (0..voices) |v| {
                const nn = self.chord_notes[s][v];
                if (nn >= 0 and @mod(nn, 12) == tpc) {
                    const iv: i16 = @mod(tpc - @as(i16, root) + 12, 12);
                    if (iv == 4 and delta == 3) self.chord_notes[s][v] -= 1;
                    if (iv == 3 and delta == 4) self.chord_notes[s][v] += 1;
                    if ((iv == 3 or iv == 4) and delta == 5) self.chord_notes[s][v] += 5 - @as(i8, @intCast(iv));
                    break;
                }
            }
        }
    }

    pub fn transformPrevent(self: *Model) void {
        for (0..slots) |s| {
            for (0..voices) |v| {
                const nn = self.chord_notes[s][v];
                if (nn < 0) continue;
                const st = self.constraint[@intCast(@mod(nn, 12))];
                self.chord_notes[s][v] = switch (st) {
                    1 => -1,
                    2 => nn + 1,
                    3 => nn - 1,
                    else => nn,
                };
            }
        }
    }

    pub fn transformMatch(self: *Model, slot: usize) void {
        var pcs: [voices]i16 = undefined;
        var cnt: usize = 0;
        for (self.chord_notes[slot]) |n| {
            if (n >= 0) {
                pcs[cnt] = @mod(n, 12);
                cnt += 1;
            }
        }
        if (cnt == 0) return;
        // Dedupe.
        var i: usize = 0;
        while (i < cnt) {
            var j = i + 1;
            while (j < cnt) {
                if (pcs[i] == pcs[j]) {
                    pcs[j] = pcs[cnt - 1];
                    cnt -= 1;
                } else j += 1;
            }
            i += 1;
        }
        // Sort ascending.
        i = 1;
        while (i < cnt) : (i += 1) {
            const t = pcs[i];
            var j: isize = @intCast(i);
            while (j > 0 and pcs[@intCast(j - 1)] > t) : (j -= 1) pcs[@intCast(j)] = pcs[@intCast(j - 1)];
            pcs[@intCast(j)] = t;
        }
        for (0..slots) |s| {
            for (0..voices) |v| {
                const nn = self.chord_notes[s][v];
                if (nn < 0) continue;
                const p = pcs[v % cnt];
                const oct = @divFloor(@as(i16, nn), 12);
                var cand = oct * 12 + p;
                if (cand > nn + 6) cand -= 12;
                if (cand < nn - 6) cand += 12;
                if (cand < 0) cand += 12;
                if (cand > 127) cand -= 12;
                self.chord_notes[s][v] = @intCast(cand);
            }
        }
    }

    pub fn populateEmpty(self: *Model) void {
        for (0..slots) |s| {
            if (self.used(s)) continue;
            var src: isize = -1;
            var d: usize = 1;
            while (src < 0 and d < slots) : (d += 1) {
                if (s >= d and self.used(s - d)) src = @intCast(s - d);
                if (s + d < slots and src < 0 and self.used(s + d)) src = @intCast(s + d);
            }
            if (src < 0) continue;
            const source: usize = @intCast(src);
            for (0..voices) |v| {
                var nn: i16 = self.chord_notes[source][v];
                if (nn < 0) continue;
                var t = nn + (@as(i16, @intCast(s)) - @as(i16, @intCast(source)));
                while (t > 127) t -= 12;
                while (t < 0) t += 12;
                nn = t;
                self.chord_notes[s][v] = @intCast(nn);
            }
        }
    }

    pub fn removeDups(self: *Model) void {
        for (0..slots) |s| self.sortNotes(s);
        var s: usize = 0;
        while (s < slots) : (s += 1) {
            if (!self.used(s)) continue;
            var t = s + 1;
            while (t < slots) : (t += 1) {
                if (!self.used(t)) continue;
                var same = true;
                for (0..voices) |v| {
                    const a = self.chord_notes[s][v];
                    const b = self.chord_notes[t][v];
                    if (!((a < 0 and b < 0) or a == b)) {
                        same = false;
                        break;
                    }
                }
                if (same) self.slotClear(t);
            }
        }
        self.collapseSlots();
    }

    pub fn removeNNotes(self: *Model, k: usize) void {
        for (0..slots) |s| {
            var cnt: usize = 0;
            for (self.chord_notes[s]) |n| {
                if (n >= 0) cnt += 1;
            }
            if (cnt == k) self.slotClear(s);
        }
        self.collapseSlots();
    }

    pub fn removeUnwatched(self: *Model, watched: *const [slots]bool) void {
        for (0..slots) |s| {
            if (!watched[s]) self.slotClear(s);
        }
        self.collapseSlots();
    }

    pub fn randomChord(self: *Model, slot: usize, rand: *std.Random.DefaultPrng) void {
        for (0..voices) |v| {
            if (!self.lock_on[v]) self.chord_notes[slot][v] = -1;
        }
        const random = rand.random();
        const t = random.uintLessThan(u32, 12);
        const root: i16 = 48 + @as(i16, @intCast(random.uintLessThan(u32, 24)));
        const shape: []const i16 = switch (t) {
            0 => &.{ 0, 4, 7 },
            1 => &.{ 0, 3, 7 },
            2 => &.{ 0, 4, 7, 10 },
            3 => &.{ 0, 3, 7, 10 },
            4 => &.{ 0, 4, 7, 11 },
            5 => &.{ 0, 3, 6, 9 },
            6 => &.{ 0, 5, 7 },
            7 => &.{ 0, 4, 8 },
            8 => &.{ 0, 4, 7, 9 },
            9 => &.{ 0, 3, 7, 9 },
            10 => &.{ 0, 4, 7, 10, 14 },
            else => &.{ 0, 3, 7, 10, 14 },
        };
        for (shape, 0..) |iv, i| self.chord_notes[slot][i] = @intCast(root + iv);
        self.chord_vel[slot] = @splat(100);
    }

    pub fn scaleSemitone(mode: u8, i: usize) i16 {
        const major = [7]i16{ 0, 2, 4, 5, 7, 9, 11 };
        const dorian = [7]i16{ 0, 2, 3, 5, 7, 9, 10 };
        const phrygian = [7]i16{ 0, 1, 3, 5, 7, 8, 10 };
        const lydian = [7]i16{ 0, 2, 4, 6, 7, 9, 11 };
        const mixolydian = [7]i16{ 0, 2, 4, 5, 7, 9, 10 };
        const aeolian = [7]i16{ 0, 2, 3, 5, 7, 8, 10 };
        const locrian = [7]i16{ 0, 1, 3, 5, 6, 8, 10 };
        return switch (mode) {
            0 => major[i],
            1 => dorian[i],
            2 => phrygian[i],
            3 => lydian[i],
            4 => mixolydian[i],
            5 => aeolian[i],
            else => locrian[i],
        };
    }

    pub const Scale = struct {
        map: [12]i8,
        sem: [16]i16,
    };

    pub fn scale(self: *const Model) Scale {
        var result: Scale = .{ .map = @splat(-1), .sem = @splat(0) };
        for (0..7) |i| {
            const r = scaleSemitone(self.scale_type, i);
            result.sem[i] = r;
            result.map[@intCast(r)] = @intCast(i);
        }
        for (0..8) |i| result.sem[i + 7] = result.sem[i] + 12;
        return result;
    }

    /// Replace every slot with the diatonic chord built on that slot's degree.
    pub fn scaleDiatonic(self: *Model, stack: usize) void {
        const scl = self.scale();
        for (0..slots) |s| {
            const d = scl.map[@intCast(@mod(@as(i16, @intCast(s)) - @as(i16, self.scale_key) + 120, 12))];
            if (d < 0) {
                self.slotClear(s);
                continue;
            }
            self.chord_notes[s] = @splat(-1);
            self.chord_vel[s] = @splat(100);
            var tmp: [8]i16 = @splat(-1);
            tmp[0] = @intCast(s);
            var k: usize = 1;
            const di: usize = @intCast(d);
            while (k < stack) : (k += 1) {
                const sem = scl.sem[di + 2 * k] - scl.sem[di];
                tmp[k] = @as(i16, @intCast(s)) + sem;
            }
            var maxn: i16 = tmp[0];
            k = 1;
            while (k < stack) : (k += 1) maxn = @max(maxn, tmp[k]);
            while (maxn > 127) {
                for (0..stack) |j| tmp[j] -= 12;
                maxn -= 12;
            }
            for (tmp, 0..) |note, v| {
                self.chord_notes[s][v] = if (note < -1) -1 else if (note > 127) 127 else @intCast(note);
            }
        }
    }

    pub fn applyChordPreset(self: *Model, preset: usize) void {
        for (0..slots) |s| self.slotClear(s);
        switch (preset) {
            0...11 => {
                self.scale_key = @intCast(preset);
                self.scale_type = 0;
                self.scaleDiatonic(3);
            },
            13 => {},
            14...25 => {
                self.scale_key = @intCast(preset - 14);
                self.scale_type = 5;
                self.scaleDiatonic(3);
            },
            27 => {
                self.setTriad(48, 48, 52, 55);
                self.setTriad(55, 55, 59, 62);
                self.setTriad(57, 57, 60, 64);
                self.setTriad(53, 53, 57, 60);
            },
            28...39 => {
                self.scale_key = @intCast(preset - 28);
                self.scale_type = 0;
                self.scaleDiatonic(4);
            },
            41 => {
                self.setTriad(57, 57, 60, 64);
                self.setTriad(53, 53, 57, 60);
                self.setTriad(48, 48, 52, 55);
                self.setTriad(55, 55, 59, 62);
            },
            42...53 => {
                self.scale_key = @intCast(preset - 42);
                self.scale_type = 5;
                self.scaleDiatonic(4);
            },
            55 => {
                self.setTriad(55, 55, 59, 62);
                self.setTriad(52, 52, 55, 59);
                self.setTriad(48, 48, 52, 55);
                self.setTriad(50, 50, 54, 57);
            },
            else => {},
        }
    }

    fn setTriad(self: *Model, slot: usize, a: i8, b: i8, c: i8) void {
        self.slotClear(slot);
        self.chord_notes[slot][0] = a;
        self.chord_notes[slot][1] = b;
        self.chord_notes[slot][2] = c;
    }

    pub fn applyArpPreset(self: *Model, pattern: usize, preset: usize, rand: *std.Random.DefaultPrng) void {
        self.patternDefaults(pattern);
        switch (preset) {
            0...6 => {
                const v: i16 = switch (preset) {
                    0 => 8,
                    1 => 9,
                    2 => 10,
                    3 => 11,
                    4 => 12,
                    5 => 14,
                    else => 15,
                };
                for (0..steps) |i| self.graph[0][pattern][i] = v;
            },
            10 => {
                for (0..steps) |i| self.graph[0][pattern][i] = 13;
            },
            7 => {
                for (0..steps) |i| self.graph[0][pattern][i] = @intCast(rand.random().uintLessThan(u32, 8));
            },
            8 => {
                for (0..steps) |i| self.graph[0][pattern][i] = 8;
                for (0..steps) |i| {
                    self.graph[2][pattern][i] = if (i < 4) 0 else if (i < 8) 1 else if (i < 12) 2 else if (i < 15) 1 else 0;
                }
            },
            else => {},
        }
    }

    pub fn patternDefaults(self: *Model, pattern: usize) void {
        for (0..lanes) |l| {
            for (0..steps) |i| self.graph[l][pattern][i] = lane_defaults[l];
            self.lane_len[pattern][l] = 16;
            self.lane_div[pattern][l] = 1;
        }
        for (0..steps) |i| self.reset[pattern][i] = false;
        self.mute[pattern] = 0;
        self.rate[pattern] = 8;
        self.retrig[pattern] = false;
        self.chord_mode[pattern] = false;
        self.link[pattern] = false;
        self.swing[pattern] = 0;
    }

    pub fn copyPattern(self: *Model, from: usize, to: usize) void {
        for (0..lanes) |l| {
            self.graph[l][to] = self.graph[l][from];
            self.lane_len[to][l] = self.lane_len[from][l];
            self.lane_div[to][l] = self.lane_div[from][l];
        }
        self.reset[to] = self.reset[from];
        self.mute[to] = self.mute[from];
        self.rate[to] = self.rate[from];
        self.retrig[to] = self.retrig[from];
        self.chord_mode[to] = self.chord_mode[from];
        self.link[to] = self.link[from];
        self.swing[to] = self.swing[from];
        self.names[to] = self.names[from];
    }

    pub fn graphCopy(self: *Model, lane: usize, pattern: usize) void {
        for (0..steps) |i| {
            self.graph_clip[i] = self.graph[lane][pattern][i];
            self.graph_clip_reset[i] = self.reset[pattern][i];
        }
        self.graph_clip_len = self.lane_len[pattern][lane];
        self.graph_clip_div = self.lane_div[pattern][lane];
        self.graph_clip_lane = @intCast(lane);
        self.graph_clip_valid = true;
    }

    pub fn graphPaste(self: *Model, lane: usize, pattern: usize) void {
        if (!self.graph_clip_valid) return;
        for (0..steps) |i| self.graph[lane][pattern][i] = self.graph_clip[i];
        self.lane_len[pattern][lane] = self.graph_clip_len;
        self.lane_div[pattern][lane] = self.graph_clip_div;
        if (lane == 0 and self.graph_clip_lane == 0) {
            for (0..steps) |i| self.reset[pattern][i] = self.graph_clip_reset[i];
        }
    }

    pub fn graphRandom(self: *Model, lane: usize, pattern: usize, rand: *std.Random.DefaultPrng) void {
        var r = rand.random();
        for (0..steps) |i| {
            const v: i16 = switch (lane) {
                0 => blk: {
                    const x = r.uintLessThan(u32, 20);
                    break :blk if (x < 2) -1 else if (x < 10) @intCast(x - 2) else 8 + @as(i16, @intCast(r.uintLessThan(u32, 8)));
                },
                1 => @as(i16, @intCast(r.uintLessThan(u32, 17))) - 8,
                2 => @as(i16, @intCast(r.uintLessThan(u32, 5))) - 2,
                3 => @as(i16, @intCast(r.uintLessThan(u32, 9))) - 4,
                4 => 60 + @as(i16, @intCast(r.uintLessThan(u32, 141))),
                5 => 20 + @as(i16, @intCast(r.uintLessThan(u32, 81))),
                6 => @as(i16, @intCast(r.uintLessThan(u32, 101))) - 50,
                else => @as(i16, @intCast(r.uintLessThan(u32, 13))) - 6,
            };
            self.setGraph(lane, pattern, i, v);
        }
    }

    pub fn chordCopy(self: *Model, slot: usize) void {
        self.chord_clip = self.chord_notes[slot];
        self.chord_clip_vel = self.chord_vel[slot];
        self.chord_clip_valid = true;
    }

    pub fn chordPaste(self: *Model, slot: usize) void {
        if (!self.chord_clip_valid) return;
        self.chord_notes[slot] = self.chord_clip;
        self.chord_vel[slot] = self.chord_clip_vel;
    }

    pub fn nameLen(self: *const Model, pattern: usize) usize {
        var i: usize = 0;
        while (i < 23 and self.names[pattern][i] != 0) : (i += 1) {}
        return i;
    }

    pub fn name(self: *const Model, pattern: usize) []const u8 {
        return self.names[pattern][0..self.nameLen(pattern)];
    }

    pub fn setNameChar(self: *Model, pattern: usize, index: usize, ch: u8) void {
        if (index >= 24) return;
        self.names[pattern][index] = ch;
        if (index < 23) self.names[pattern][index + 1] = 0;
    }
};

/// Infer a chord root from a 12-bit pitch-class set, preferring perfect
/// fifths, then fourths, then the lowest present class.
pub fn hindRoot(ps: u16) u8 {
    const bit = struct {
        fn has(set: u16, i: usize) bool {
            return (set & (@as(u16, 1) << @intCast(@mod(i, 12)))) != 0;
        }
    }.has;
    for (0..12) |p| {
        if (bit(ps, p) and bit(ps, p + 7)) return @intCast(p);
    }
    for (0..12) |p| {
        if (bit(ps, p) and bit(ps, p + 5)) return @intCast(@mod(p + 5, 12));
    }
    for (0..12) |p| {
        if (bit(ps, p)) return @intCast(p);
    }
    return 0;
}

pub fn degreeOf(iv: i16) usize {
    return switch (iv) {
        0 => 1,
        1, 2 => 2,
        3, 4 => 3,
        5 => 4,
        6, 7 => 5,
        8, 9 => 6,
        else => 7,
    };
}

pub fn noteName(buf: []u8, n: i16) []const u8 {
    const names = [12][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
    const pc = @mod(n, 12);
    const oct = @divFloor(n, 12) - 1;
    return std.fmt.bufPrint(buf, "{s}{d}", .{ names[@intCast(pc)], oct }) catch buf[0..0];
}

pub fn pcName(n: i16) []const u8 {
    const names = [12][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
    return names[@intCast(@mod(n, 12))];
}

pub fn fmtRate(buf: []u8, i: u8) []const u8 {
    if (i < 5) {
        const bars: u32 = @as(u32, 16) >> @as(u5, @intCast(i));
        return std.fmt.bufPrint(buf, "{d} bar", .{bars}) catch buf[0..0];
    }
    if (i == 5) return std.fmt.bufPrint(buf, "1/2", .{}) catch buf[0..0];
    const denominator: u32 = @as(u32, 1) << @as(u5, @intCast(i - 4));
    return std.fmt.bufPrint(buf, "1/{d}", .{denominator}) catch buf[0..0];
}

/// Human-readable chord label, matching the JSFX's vocabulary.
pub fn chordName(m: *const Model, slot: usize, buf: []u8) []const u8 {
    var pcset: u16 = 0;
    var cnt: usize = 0;
    for (m.chord_notes[slot]) |n| {
        if (n >= 0) {
            pcset |= @as(u16, 1) << @intCast(@mod(n, 12));
            cnt += 1;
        }
    }
    if (cnt == 0) return std.fmt.bufPrint(buf, "-- empty --", .{}) catch buf[0..0];
    const root = hindRoot(pcset);
    var iv: u16 = 0;
    for (1..12) |pc| {
        if ((pcset & (@as(u16, 1) << @intCast(@mod(root + pc, 12)))) != 0) iv += @as(u16, 1) << @intCast(pc);
    }
    var root_buf: [8]u8 = undefined;
    const root_name = noteName(&root_buf, @as(i16, root) + 60);
    const suffix: []const u8 = switch (iv) {
        128 => "5",
        136 => "min",
        144 => "maj",
        72 => "dim",
        272 => "aug",
        160 => "sus4",
        132 => "sus2",
        1160 => "m7",
        1168 => "7",
        2192 => "maj7",
        1096 => "m7b5",
        584 => "dim7",
        656 => "6",
        648 => "m6",
        1184 => "7sus4",
        148 => "add9",
        140 => "madd9",
        2196 => "maj9",
        1164 => "m9",
        1172 => "9",
        1170 => "7b9",
        2184 => "minmaj7",
        else => return std.fmt.bufPrint(buf, "{s} ({d} notes)", .{ root_name[0 .. root_name.len - 1], cnt }) catch buf[0..0],
    };
    return std.fmt.bufPrint(buf, "{s} {s}", .{ root_name[0 .. root_name.len - 1], suffix }) catch buf[0..0];
}

/// Serialize the persistent patch. Raw bytes are versioned by the caller.
pub fn bytes(m: *const Model) []const u8 {
    return std.mem.asBytes(m);
}

pub fn fromBytes(m: *Model, data: []const u8) bool {
    if (data.len != @sizeOf(Model)) return false;
    @memcpy(std.mem.asBytes(m), data);
    return validate(m);
}

fn sanitizeBool(value: *bool) void {
    const raw: u8 = @as(*const u8, @ptrCast(value)).*;
    value.* = raw != 0;
}

pub fn validate(m: *Model) bool {
    // Guard against malformed values from older/hostile state.
    for (&m.lock_on) |*b| sanitizeBool(b);
    for (&m.retrig) |*b| sanitizeBool(b);
    for (&m.chord_mode) |*b| sanitizeBool(b);
    for (&m.link) |*b| sanitizeBool(b);
    for (&m.pen) |*b| sanitizeBool(b);
    sanitizeBool(&m.watch_on);
    sanitizeBool(&m.free_on);
    sanitizeBool(&m.chord_clip_valid);
    sanitizeBool(&m.graph_clip_valid);
    for (0..patterns) |p| {
        for (&m.reset[p]) |*b| sanitizeBool(b);
    }
    for (&m.graph_clip_reset) |*b| sanitizeBool(b);
    if (!std.math.isFinite(m.free_hz)) m.free_hz = 8;
    for (0..patterns) |p| {
        m.rate[p] = @min(m.rate[p], 15);
        m.swing[p] = @min(m.swing[p], 75);
        for (0..lanes) |l| {
            m.lane_len[p][l] = std.math.clamp(m.lane_len[p][l], 1, 16);
            m.lane_div[p][l] = std.math.clamp(m.lane_div[p][l], 1, 8);
            for (0..steps) |i| m.setGraph(l, p, i, m.graph[l][p][i]);
        }
    }
    for (0..slots) |s| {
        for (0..voices) |v| {
            m.chord_vel[s][v] = @min(m.chord_vel[s][v], 200);
            if (m.chord_notes[s][v] < -1) m.chord_notes[s][v] = -1;
        }
    }
    for (0..patterns) |p| m.names[p][23] = 0;
    for (0..voices) |v| {
        if (m.lock_note[v] < -1) m.lock_note[v] = -1;
    }
    for (0..pitch_classes) |i| m.constraint[i] = @min(m.constraint[i], 3);
    m.cur_graph = @min(m.cur_graph, 7);
    m.scale_key = @mod(m.scale_key, 12);
    m.scale_type = @min(m.scale_type, 6);
    m.graph_clip_len = std.math.clamp(m.graph_clip_len, 1, 16);
    m.graph_clip_div = std.math.clamp(m.graph_clip_div, 1, 8);
    m.graph_clip_lane = @min(m.graph_clip_lane, 7);
    m.free_hz = std.math.clamp(m.free_hz, 0.05, 40);
    return true;
}
