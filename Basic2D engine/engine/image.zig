//! Minimal image loading for sprites: uncompressed BMP (24/32-bit) and PNG
//! (8-bit RGB/RGBA) with a compact self-contained zlib inflater.

const std = @import("std");
const win32 = @import("win32.zig");

pub const Image = struct {
    width: u32,
    height: u32,
    /// RGBA8, top-down rows (row 0 is the top of the image).
    data: []u8,

    pub fn deinit(self: *Image, alloc: std.mem.Allocator) void {
        alloc.free(self.data);
    }
};

pub fn loadImage(alloc: std.mem.Allocator, path: []const u8) !Image {
    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);

    const bytes = try readFileAll(alloc, path_z);
    defer alloc.free(bytes);

    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) {
        return loadPng(alloc, bytes);
    }
    if (bytes.len >= 2 and bytes[0] == 'B' and bytes[1] == 'M') {
        return loadBmp(alloc, bytes);
    }
    return error.UnsupportedImageFormat;
}

/// Reads a whole file via the Win32 API (std.fs has no sync File API in 0.16).
fn readFileAll(alloc: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const GENERIC_READ: u32 = 0x80000000;
    const FILE_SHARE_READ: u32 = 0x00000001;
    const OPEN_EXISTING: u32 = 3;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x00000080;

    const fh = win32.CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null) orelse
        return error.FileNotFound;
    defer _ = win32.CloseHandle(fh);

    var size: i64 = 0;
    if (win32.GetFileSizeEx(fh, &size) == 0) return error.ReadFailed;
    if (size < 0 or size > 64 * 1024 * 1024) return error.FileTooBig;

    const bytes = try alloc.alloc(u8, @intCast(size));
    errdefer alloc.free(bytes);
    var read: u32 = 0;
    if (win32.ReadFile(fh, bytes.ptr, @intCast(bytes.len), &read, null) == 0) return error.ReadFailed;
    if (read != bytes.len) return error.ReadFailed;
    return bytes;
}

fn be32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .big);
}

// ---------------------------------------------------------------------------
// BMP (uncompressed, 24/32 bpp)
// ---------------------------------------------------------------------------

fn loadBmp(alloc: std.mem.Allocator, bytes: []const u8) !Image {
    if (bytes.len < 54) return error.InvalidBmp;
    const pixel_offset = std.mem.readInt(u32, bytes[10..14], .little);
    const width_i = std.mem.readInt(i32, bytes[18..22], .little);
    const height_i = std.mem.readInt(i32, bytes[22..26], .little);
    const bpp = std.mem.readInt(u16, bytes[28..30], .little);
    if (width_i <= 0 or height_i == 0) return error.InvalidBmp;
    if (bpp != 24 and bpp != 32) return error.UnsupportedBmpDepth;

    const width: u32 = @intCast(width_i);
    const top_down = height_i < 0;
    const height: u32 = @intCast(@abs(height_i));
    const bytes_pp: u32 = @intCast(bpp / 8);
    const row_size = ((width * bytes_pp + 3) / 4) * 4;
    if (pixel_offset + row_size * height > bytes.len) return error.InvalidBmp;

    const data = try alloc.alloc(u8, width * height * 4);
    errdefer alloc.free(data);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_y: u32 = if (top_down) y else height - 1 - y;
        const row = bytes[pixel_offset + src_y * row_size ..][0 .. width * bytes_pp];
        const dst = data[y * width * 4 ..][0 .. width * 4];
        for (0..width) |x| {
            dst[x * 4 + 0] = row[x * bytes_pp + 2]; // R
            dst[x * 4 + 1] = row[x * bytes_pp + 1]; // G
            dst[x * 4 + 2] = row[x * bytes_pp + 0]; // B
            dst[x * 4 + 3] = if (bpp == 32) row[x * bytes_pp + 3] else 255;
        }
    }
    return .{ .width = width, .height = height, .data = data };
}

// ---------------------------------------------------------------------------
// PNG + zlib inflate
// ---------------------------------------------------------------------------

const Inflate = struct {
    src: []const u8,
    pos: usize = 0,
    bitbuf: u32 = 0,
    bitcnt: u32 = 0,

    fn bit(self: *Inflate) !u32 {
        if (self.bitcnt == 0) {
            if (self.pos >= self.src.len) return error.TruncatedData;
            self.bitbuf = self.src[self.pos];
            self.pos += 1;
            self.bitcnt = 8;
        }
        self.bitcnt -= 1;
        const b = self.bitbuf & 1;
        self.bitbuf >>= 1;
        return b;
    }

    fn bits(self: *Inflate, n: u32) !u32 {
        var v: u32 = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            v |= (try self.bit()) << @intCast(i);
        }
        return v;
    }

    fn alignByte(self: *Inflate) void {
        self.bitcnt = 0;
    }
};

const Huff = struct {
    counts: [16]u16 = [_]u16{0} ** 16,
    symbols: [286]u16 = [_]u16{0} ** 286,

    fn build(self: *Huff, lengths: []const u8) !void {
        var max_len: usize = 0;
        for (lengths) |l| {
            if (l > 15) return error.InvalidHuffmanCode;
            if (l > 0) self.counts[l] += 1;
            max_len = @max(max_len, l);
        }
        var offsets: [16]u16 = [_]u16{0} ** 16;
        var off: u16 = 0;
        var len: usize = 1;
        while (len <= 15) : (len += 1) {
            offsets[len] = off;
            off += self.counts[len];
        }
        for (lengths, 0..) |l, i| {
            if (l == 0) continue;
            self.symbols[offsets[l]] = @intCast(i);
            offsets[l] += 1;
        }
    }

    fn decode(self: *const Huff, r: *Inflate) !u16 {
        var code: u32 = 0;
        var first: u32 = 0;
        var index: u32 = 0;
        var len: u32 = 1;
        while (len <= 15) : (len += 1) {
            code |= try r.bit();
            const cnt = self.counts[len];
            if (code - first < cnt) return self.symbols[index + (code - first)];
            index += cnt;
            first += cnt;
            first <<= 1;
            code <<= 1;
        }
        return error.InvalidHuffmanCode;
    }
};

fn fixedHuff() Huff {
    var h = Huff{};
    for (0..288) |i| {
        const l: u8 = if (i <= 143)
            8
        else if (i <= 255)
            9
        else if (i <= 279)
            7
        else
            8;
        h.counts[l] += 1;
    }
    var lengths: [288]u8 = undefined;
    for (0..288) |i| {
        lengths[i] = if (i <= 143)
            8
        else if (i <= 255)
            9
        else if (i <= 279)
            7
        else
            8;
    }
    h.build(lengths[0..]) catch unreachable;
    return h;
}

fn fixedDistHuff() Huff {
    var h = Huff{};
    var lengths: [30]u8 = undefined;
    for (0..30) |i| lengths[i] = 5;
    h.build(lengths[0..]) catch unreachable;
    return h;
}

const length_base = [29]u16{
    3,  4,  5,  6,  7,  8,  9,  10, 11,  13,  15,  17,  19,  23,  27,
    31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
};
const length_extra = [29]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2,
    2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
};
const dist_base = [30]u16{
    1,    2,    3,    4,    5,    7,    9,    13,    17,    25,
    33,   49,   65,   97,   129,  193,  257,  385,   513,   769,
    1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
};
const dist_extra = [30]u8{
    0, 0, 0, 0, 1, 1, 2, 2,  3,  3,  4,  4,  5,  5,  6,
    6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
};

fn inflate(alloc: std.mem.Allocator, src: []const u8, out: *std.ArrayList(u8)) !void {
    var r = Inflate{ .src = src };
    const lit = fixedHuff();
    const dist = fixedDistHuff();

    var have_dynamic = false;
    var dyn_lit = Huff{};
    var dyn_dist = Huff{};

    while (true) {
        const final = try r.bit();
        const btype = try r.bits(2);
        switch (btype) {
            0 => {
                r.alignByte();
                if (r.pos + 4 > src.len) return error.TruncatedData;
                const len = std.mem.readInt(u16, src[r.pos..][0..2], .little);
                r.pos += 2;
                const nlen = std.mem.readInt(u16, src[r.pos..][0..2], .little);
                r.pos += 2;
                if (len != ~nlen) return error.CorruptInflateData;
                if (r.pos + len > src.len) return error.TruncatedData;
                try out.appendSlice(alloc, src[r.pos .. r.pos + len]);
                r.pos += len;
            },
            1 => {
                try inflateBlock(&r, alloc, out, lit, dist);
            },
            2 => {
                const hlit = try r.bits(5);
                const hdist = try r.bits(5);
                const hclen = try r.bits(4);
                if (!have_dynamic) {
                    have_dynamic = true;
                    const order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
                    var cl_lengths: [19]u8 = [_]u8{0} ** 19;
                    var i: u32 = 0;
                    while (i < hclen + 4) : (i += 1) {
                        cl_lengths[order[i]] = @intCast(try r.bits(3));
                    }
                    var cl_huff = Huff{};
                    try cl_huff.build(cl_lengths[0..]);
                    const total: u32 = hlit + 257 + hdist + 1;
                    var lengths: [320]u8 = [_]u8{0} ** 320;
                    var n: u32 = 0;
                    while (n < total) {
                        const sym = try cl_huff.decode(&r);
                        if (sym <= 15) {
                            lengths[n] = @intCast(sym);
                            n += 1;
                        } else if (sym == 16) {
                            if (n == 0) return error.CorruptInflateData;
                            const rep: u32 = 3 + try r.bits(2);
                            var k: u32 = 0;
                            while (k < rep and n < total) : (k += 1) {
                                lengths[n] = lengths[n - 1];
                                n += 1;
                            }
                        } else if (sym == 17) {
                            const rep: u32 = 3 + try r.bits(3);
                            var k: u32 = 0;
                            while (k < rep and n < total) : (k += 1) {
                                lengths[n] = 0;
                                n += 1;
                            }
                        } else { // 18
                            const rep: u32 = 11 + try r.bits(7);
                            var k: u32 = 0;
                            while (k < rep and n < total) : (k += 1) {
                                lengths[n] = 0;
                                n += 1;
                            }
                        }
                    }
                    try dyn_lit.build(lengths[0 .. hlit + 257]);
                    try dyn_dist.build(lengths[hlit + 257 ..][0 .. hdist + 1]);
                }
                try inflateBlock(&r, alloc, out, dyn_lit, dyn_dist);
            },
            else => return error.CorruptInflateData,
        }
        if (final != 0) break;
    }
}

fn inflateBlock(
    r: *Inflate,
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    lit_huff: Huff,
    dist_huff: Huff,
) !void {
    while (true) {
        const sym = try lit_huff.decode(r);
        if (sym < 256) {
            try out.append(alloc, @intCast(sym));
        } else if (sym == 256) {
            return;
        } else {
            const li = sym - 257;
            if (li >= 29) return error.CorruptInflateData;
            const len: u32 = length_base[li] + try r.bits(length_extra[li]);
            const dsym = try dist_huff.decode(r);
            if (dsym >= 30) return error.CorruptInflateData;
            const d: u32 = dist_base[dsym] + try r.bits(dist_extra[dsym]);
            if (d > out.items.len) return error.CorruptInflateData;
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const b = out.items[out.items.len - d];
                try out.append(alloc, b);
            }
        }
    }
}

fn loadPng(alloc: std.mem.Allocator, bytes: []const u8) !Image {
    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var color_type: u8 = 0;
    var idat = std.ArrayList(u8).empty;
    defer idat.deinit(alloc);

    while (pos + 8 <= bytes.len) {
        if (pos + 12 > bytes.len) return error.InvalidPng;
        const len = be32(bytes, pos);
        const chunk_type = bytes[pos + 4 .. pos + 8];
        if (pos + 12 + len > bytes.len) return error.InvalidPng;
        const data = bytes[pos + 8 .. pos + 8 + len];
        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (len < 13) return error.InvalidPng;
            width = be32(bytes, pos + 8);
            height = be32(bytes, pos + 12);
            if (data[8] != 8) return error.UnsupportedPngDepth; // bit depth
            color_type = data[9];
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            try idat.appendSlice(alloc, data);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }
        pos += 12 + len;
    }

    const bpp: u32 = switch (color_type) {
        2 => 3, // RGB
        6 => 4, // RGBA
        else => return error.UnsupportedPngColorType,
    };
    if (width == 0 or height == 0 or idat.items.len < 2) return error.InvalidPng;

    // zlib header (CMF/FLG), then inflate.
    if (idat.items[0] & 0x0F != 8) return error.UnsupportedPngCompression;
    const stream = idat.items[2..]; // skip CMF + FLG

    const stride = width * bpp + 1;
    var raw = std.ArrayList(u8).empty;
    defer raw.deinit(alloc);
    try raw.ensureTotalCapacity(alloc, stride * height);
    try inflate(alloc, stream, &raw);
    if (raw.items.len < stride * height) return error.TruncatedData;

    try unfilter(raw.items, width, height, bpp);

    const data = try alloc.alloc(u8, width * height * 4);
    errdefer alloc.free(data);
    for (0..height) |y| {
        const row = raw.items[y * stride ..][1 .. 1 + width * bpp];
        const dst = data[y * width * 4 ..][0 .. width * 4];
        if (bpp == 4) {
            @memcpy(dst, row);
        } else {
            for (0..width) |x| {
                dst[x * 4 + 0] = row[x * 3 + 0];
                dst[x * 4 + 1] = row[x * 3 + 1];
                dst[x * 4 + 2] = row[x * 3 + 2];
                dst[x * 4 + 3] = 255;
            }
        }
    }
    return .{ .width = width, .height = height, .data = data };
}

fn paeth(a: i32, b: i32, c: i32) u8 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    return @intCast(if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c);
}

/// Reverses PNG scanline filtering in place.
fn unfilter(raw: []u8, width: u32, height: u32, bpp: u32) !void {
    const stride = width * bpp + 1;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row = raw[y * stride ..][0..stride];
        const filter = row[0];
        const cur = row[1..];
        const prev: []const u8 = if (y > 0) raw[(y - 1) * stride + 1 ..][0 .. width * bpp] else &.{};
        switch (filter) {
            0 => {},
            1 => { // Sub
                var i: u32 = 0;
                while (i < width * bpp) : (i += 1) {
                    const left: u8 = if (i >= bpp) cur[i - bpp] else 0;
                    cur[i] +%= left;
                }
            },
            2 => { // Up
                for (0..width * bpp) |i| cur[i] +%= prev[i];
            },
            3 => { // Average
                var i: u32 = 0;
                while (i < width * bpp) : (i += 1) {
                    const left: u16 = if (i >= bpp) cur[i - bpp] else 0;
                    cur[i] +%= @intCast((left + prev[i]) / 2);
                }
            },
            4 => { // Paeth
                var i: u32 = 0;
                while (i < width * bpp) : (i += 1) {
                    const left: i32 = if (i >= bpp) cur[i - bpp] else 0;
                    const above: i32 = prev[i];
                    const above_left: i32 = if (i >= bpp) prev[i - bpp] else 0;
                    cur[i] +%= paeth(left, above, above_left);
                }
            },
            else => return error.UnsupportedPngFilter,
        }
    }
}
