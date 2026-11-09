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
};
