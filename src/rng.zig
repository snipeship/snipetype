pub const Rng = struct {
    state: u64,

    pub fn init(seed: u64) Rng {
        return .{ .state = seed | 1 };
    }

    pub fn next(self: *Rng) u64 {
        var x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        return x *% 0x2545F4914F6CDD1D;
    }

    pub fn range(self: *Rng, max: usize) usize {
        if (max == 0) return 0;
        return @intCast(self.next() % @as(u64, @intCast(max)));
    }
};
