const std = @import("std");

pub const defaults = [4]u8{ 1, 0, 1, 0 }; // Arp, Major, 1/8, one octave
pub const maxima = [4]u8{ 1, 3, 2, 1 };
pub const labels = [4][]const []const u8{
    &.{ "Chord", "Arp" },
    &.{ "Major", "Minor", "Sus2", "Octave" },
    &.{ "1/4", "1/8", "1/16" },
    &.{ "1 octave", "2 octaves" },
};

pub const Sink = struct {
    context: *anyopaque,
    push: *const fn (*anyopaque, u32, [3]u8) bool,
    pub fn send(self: Sink, time: u32, data: [3]u8) bool {
        return self.push(self.context, time, data);
    }
};

/// Fixed storage, no allocations or locks in processing. Each array index is channel * 128 + key.
pub const Engine = struct {
    params: [4]u8 = defaults,
    held: [2048]u8 = @splat(0),
    wanted: [2048]u8 = @splat(0),
    sounding: [2048]u8 = @splat(0),
    sample_rate: f64 = 48000,
    tempo: f64 = 120,
    dirty: bool = true,
    retry_chord: bool = false,
    cursor: usize = 0,
    wanted_count: usize = 0,
    sounding_count: usize = 0,
    until_step: f64 = 0,
    until_off: f64 = 0,

    pub fn configure(self: *Engine, values: [4]u8) void {
        if (!std.mem.eql(u8, &self.params, &values)) {
            self.params = values;
            self.dirty = true;
        }
    }

    pub fn panic(self: *Engine, channel: ?u4) void {
        for (&self.held, 0..) |*velocity, i| {
            if (channel == null or i / 128 == channel.?) velocity.* = 0;
        }
        self.dirty = true;
    }

    pub fn midi(self: *Engine, data: [3]u8) void {
        const channel: u4 = @truncate(data[0]);
        const key = data[1] & 127;
        const velocity = data[2] & 127;
        const index = @as(usize, channel) * 128 + key;
        switch (data[0] & 0xf0) {
            0x90 => {
                self.held[index] = velocity;
                self.dirty = true;
            },
            0x80 => {
                self.held[index] = 0;
                self.dirty = true;
            },
            0xb0 => if (key == 120 or key == 123) self.panic(channel),
            else => {},
        }
    }

    fn rebuild(self: *Engine) void {
        @memset(&self.wanted, 0);
        const intervals: []const u8 = switch (self.params[1]) {
            0 => &.{ 0, 4, 7 },
            1 => &.{ 0, 3, 7 },
            2 => &.{ 0, 2, 7 },
            else => &.{ 0, 12 },
        };
        for (self.held, 0..) |velocity, index| {
            if (velocity == 0) continue;
            for (0..@as(usize, self.params[3]) + 1) |octave| {
                for (intervals) |interval| {
                    const key = index % 128 + interval + octave * 12;
                    if (key < 128) {
                        const dest = index / 128 * 128 + key;
                        self.wanted[dest] = @max(self.wanted[dest], velocity);
                    }
                }
            }
        }
        self.wanted_count = 0;
        for (self.wanted) |velocity| {
            if (velocity != 0) self.wanted_count += 1;
        }
    }

    fn note(self: *Engine, index: usize, velocity: u8, time: u32, sink: Sink) bool {
        if (!sink.send(time, .{
            @as(u8, if (velocity == 0) 0x80 else 0x90) | @as(u8, @intCast(index / 128)),
            @intCast(index % 128),
            velocity,
        })) return false;
        if (self.sounding[index] == 0 and velocity != 0) self.sounding_count += 1;
        if (self.sounding[index] != 0 and velocity == 0) self.sounding_count -= 1;
        self.sounding[index] = velocity;
        return true;
    }

    fn silence(self: *Engine, time: u32, sink: Sink) bool {
        if (self.sounding_count == 0) return true;
        var success = true;
        for (self.sounding, 0..) |velocity, i| {
            if (velocity != 0 and !self.note(i, 0, time, sink)) success = false;
        }
        return success;
    }

    pub fn tick(self: *Engine, time: u32, sink: Sink) void {
        if (self.dirty) {
            self.rebuild();
            self.dirty = false;
            self.retry_chord = true;
            self.cursor = 0;
            self.until_step = 0;
            self.until_off = 0;
        }
        if (self.params[0] == 0) {
            if (!self.retry_chord) return;
            self.retry_chord = false;
            // Release obsolete notes before emitting new notes. Shared chord tones stay held.
            for (self.sounding, 0..) |velocity, i| {
                if (velocity != 0 and self.wanted[i] == 0 and !self.note(i, 0, time, sink)) self.retry_chord = true;
            }
            if (self.retry_chord) return;
            for (self.wanted, 0..) |velocity, i| {
                if (velocity != 0 and self.sounding[i] == 0 and !self.note(i, velocity, time, sink)) self.retry_chord = true;
            }
            return;
        }
        if (self.until_off <= 0 and !self.silence(time, sink)) return;
        if (self.until_step <= 0) {
            if (!self.silence(time, sink)) return;
            const count = self.wanted_count;
            if (count == 0) return;
            var remaining = self.cursor % count;
            for (self.wanted, 0..) |velocity, i| {
                if (velocity == 0) continue;
                if (remaining == 0) {
                    if (!self.note(i, velocity, time, sink)) return;
                    break;
                }
                remaining -= 1;
            }
            self.cursor = (self.cursor + 1) % count;
            const beats: f64 = switch (self.params[2]) {
                0 => 1,
                1 => 0.5,
                else => 0.25,
            };
            const duration = self.sample_rate * 60 / self.tempo * beats;
            self.until_step += duration;
            self.until_off = duration * 0.75; // Fixed 75% gate for the first version.
        }
        self.until_step -= 1;
        self.until_off -= 1;
    }
};

const Recorder = struct {
    const Event = struct { time: u32, data: [3]u8 };
    events: [128]Event = undefined,
    len: usize = 0,
    reject: bool = false,
    fn push(context: *anyopaque, time: u32, data: [3]u8) bool {
        const self: *Recorder = @ptrCast(@alignCast(context));
        if (self.reject) return false;
        self.events[self.len] = .{ .time = time, .data = data };
        self.len += 1;
        return true;
    }
    fn sink(self: *Recorder) Sink {
        return .{ .context = self, .push = push };
    }
};

test "chords preserve shared tones until the last root releases" {
    var e: Engine = .{};
    e.params[0] = 0;
    var r: Recorder = .{};
    e.midi(.{ 0x90, 60, 100 });
    e.tick(0, r.sink());
    try std.testing.expectEqual(@as(usize, 3), r.len);
    try std.testing.expectEqual([3]u8{ 0x90, 64, 100 }, r.events[1].data);
    e.midi(.{ 0x90, 64, 100 });
    e.tick(1, r.sink());
    e.midi(.{ 0x80, 60, 0 });
    e.tick(2, r.sink());
    try std.testing.expectEqual(@as(u8, 100), e.sounding[64]);
    try std.testing.expectEqual(@as(u8, 0), e.sounding[60]);
    e.midi(.{ 0x90, 64, 0 });
    e.tick(3, r.sink());
    for (e.sounding) |v| try std.testing.expectEqual(@as(u8, 0), v);
}

test "arp emits sample accurate eighth notes with gate and release" {
    var e: Engine = .{ .sample_rate = 48000, .tempo = 120 };
    var r: Recorder = .{};
    e.midi(.{ 0x92, 60, 80 });
    for (0..24001) |i| e.tick(@intCast(i), r.sink());
    try std.testing.expectEqual(@as(usize, 5), r.len);
    try std.testing.expectEqual(@as(u32, 9000), r.events[1].time);
    try std.testing.expectEqual(@as(u32, 12000), r.events[2].time);
    try std.testing.expectEqual([3]u8{ 0x92, 64, 80 }, r.events[2].data);
    try std.testing.expectEqual([3]u8{ 0x92, 67, 80 }, r.events[4].data);
    e.midi(.{ 0x82, 60, 0 });
    e.tick(24001, r.sink());
    try std.testing.expectEqual([3]u8{ 0x82, 67, 0 }, r.events[5].data);
}

test "rejected note offs are retried and panic clears all channels" {
    var e: Engine = .{};
    var r: Recorder = .{};
    e.midi(.{ 0x90, 127, 100 });
    e.tick(0, r.sink());
    try std.testing.expectEqual(@as(usize, 1), r.len); // Chord tones above 127 are discarded.
    r.reject = true;
    e.panic(null);
    e.tick(1, r.sink());
    try std.testing.expect(e.sounding[127] != 0);
    r.reject = false;
    e.tick(2, r.sink());
    try std.testing.expectEqual(@as(u8, 0), e.sounding[127]);
}
