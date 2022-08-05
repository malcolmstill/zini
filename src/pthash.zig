const std = @import("std");
const Wyhash = std.hash.Wyhash;

const Bucketer = struct {
    n: usize,
    m: usize,
    p1: usize,
    p2: usize,

    pub fn init(n: usize, c: usize) Bucketer {
        const m = c * n / (std.math.log2_int(usize, n) + 1);
        const p1 = @floatToInt(usize, 0.6 * @intToFloat(f64, n));
        const p2 = @floatToInt(usize, 0.3 * @intToFloat(f64, m));

        return Bucketer{
            .n = n,
            .m = m,
            .p1 = p1,
            .p2 = p2,
        };
    }

    pub fn getBucket(self: Bucketer, hash: u64) u64 {
        if (hash % self.n < self.p1) {
            return hash % self.p2;
        } else {
            return self.p2 + (hash % (self.m - self.p2));
        }
    }
};

const HashedKey = struct {
    hash: u64,
    bucket: u64,

    fn lessThan(_: void, lhs: HashedKey, rhs: HashedKey) bool {
        return lhs.bucket < rhs.bucket;
    }
};

const BucketSummary = struct {
    idx: usize,
    entry_start: usize,
    entry_end: usize,

    fn count(self: BucketSummary) usize {
        return self.entry_end - self.entry_start;
    }

    fn compare(_: void, a: BucketSummary, b: BucketSummary) std.math.Order {
        const a_count = a.count();
        const b_count = b.count();
        if (a_count == b_count) return std.math.order(a.idx, b.idx);
        return std.math.order(a_count, b_count).invert();
    }
};

/// A minimal perfect hash function for a given type and a hash function.
fn HashFn(
    comptime Key: type,
    comptime hasher: fn (seed: u64, Key: Key) u64,
) type {
    return struct {
        const Self = @This();

        const hasher = hasher;

        bucketer: Bucketer,
        seed: u64,

        // TODO: Pivots should be configurable type.
        pivots: []u64,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.pivots);
            self.* = undefined;
        }

        pub fn get(self: *const Self, key: Key) u64 {
            const hash = hasher(self.seed, key);
            const bucket = self.bucketer.getBucket(hash);
            const bucket_hash = Wyhash.hash(self.seed, std.mem.asBytes(&self.pivots[bucket]));
            const full_hash = Wyhash.hash(bucket_hash, std.mem.asBytes(&hash));
            return full_hash % self.bucketer.n;
        }

        pub fn build(
            allocator: std.mem.Allocator,
            keys: []const Key,
            c: usize,
        ) !Self {
            const bucketer = Bucketer.init(keys.len, c);

            var seed: u64 = 66904272; // random number
            // try std.os.getrandom(std.mem.asBytes(&seed));

            // Step 1: Hash all the inputs and figure out which bucket they belong to.

            var entries = try allocator.alloc(HashedKey, keys.len);
            defer allocator.free(entries);

            for (keys) |key, idx| {
                const hash = hasher(seed, key);
                const bucket = bucketer.getBucket(hash);
                entries[idx] = HashedKey{ .hash = hash, .bucket = bucket };
            }

            std.sort.sort(HashedKey, entries, {}, HashedKey.lessThan);

            // Step 2: Group the entries into buckets ordered by size.

            var bucket_summaries = std.PriorityQueue(BucketSummary, void, BucketSummary.compare).init(allocator, {});
            defer bucket_summaries.deinit();

            try bucket_summaries.ensureTotalCapacity(bucketer.m);

            var bucket_start: usize = 0;
            var bucket_idx: usize = 0;
            var i: usize = 1;
            while (i < entries.len + 1) : (i += 1) {
                const at_boundary = (i == entries.len) or (entries[i - 1].bucket != entries[i].bucket);
                if (at_boundary) {
                    bucket_summaries.add(BucketSummary{
                        .idx = entries[i - 1].bucket,
                        .entry_start = bucket_start,
                        .entry_end = i,
                    }) catch unreachable;
                    bucket_idx += 1;
                    bucket_start = i;
                }
            }

            // Step 3: Determine pivots

            var taken = try std.bit_set.DynamicBitSet.initEmpty(allocator, keys.len);
            defer taken.deinit();

            var attempted_taken = try std.bit_set.DynamicBitSet.initEmpty(allocator, keys.len);
            defer attempted_taken.deinit();

            var pivots = try allocator.alloc(u64, bucketer.m);
            errdefer allocator.free(pivots);
            std.mem.set(u64, pivots, 0);

            while (bucket_summaries.removeOrNull()) |b| {
                var pivot: u64 = 0;
                find_pivot: while (true) : (pivot += 1) {
                    // Reset attempted_taken
                    attempted_taken.setRangeValue(.{ .start = 0, .end = attempted_taken.capacity() }, false);

                    for (entries[b.entry_start..b.entry_end]) |entry| {
                        const bucket_hash = Wyhash.hash(seed, std.mem.asBytes(&pivot));
                        const full_hash = Wyhash.hash(bucket_hash, std.mem.asBytes(&entry.hash));
                        const pos = full_hash % bucketer.n;

                        const is_taken_earlier_bucket = taken.isSet(pos);
                        const is_taken_same_bucket = attempted_taken.isSet(pos);

                        if (is_taken_earlier_bucket or is_taken_same_bucket) {
                            continue :find_pivot;
                        }

                        attempted_taken.set(pos);
                    }

                    pivots[b.idx] = pivot;

                    taken.setUnion(attempted_taken);
                    break;
                }
            }

            return Self{
                .bucketer = bucketer,
                .seed = seed,
                .pivots = pivots,
            };
        }
    };
}

fn AutoHashFn(comptime Key: type) type {
    const hasher = struct {
        fn hash(seed: u64, key: Key) u64 {
            if (comptime std.meta.trait.hasUniqueRepresentation(Key)) {
                return Wyhash.hash(seed, std.mem.asBytes(&key));
            } else {
                var hasher = Wyhash.init(seed);
                std.hash.autoHash(&hasher, key);
                return hasher.final();
            }
        }
    }.hash;

    return HashFn(Key, hasher);
}

const testing = std.testing;

test "basic bucketing" {
    const b = Bucketer.init(100, 7);
    try testing.expectEqual(@as(u64, 0), b.getBucket(0));
}

test "building" {
    var data: [256]u64 = undefined;

    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        data[i] = i * i;
    }

    var h = try AutoHashFn(u64).build(testing.allocator, &data, 7);
    defer h.deinit(testing.allocator);

    var seen = std.hash_map.AutoHashMap(u64, usize).init(testing.allocator);
    defer seen.deinit();

    for (data) |val, idx| {
        const out = h.get(val);
        if (try seen.fetchPut(out, idx)) |other_entry| {
            std.debug.print("collision between idx={} and {}\n", .{ other_entry.value, idx });
            return error.TestCollision;
        }
    }
}
