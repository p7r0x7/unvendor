// SPDX-License-Identifier: Apache-2.0
// Copyright © 2024 The Unvendor Contributors. All rights reserved.
// Contributors responsible for this file:
// @p7r0x7 <mattrbonnette@pm.me>

const io = @import("std").io;
const fs = @import("std").fs;
const fmt = @import("std").fmt;
const mem = @import("std").mem;
const tar = @import("std").tar;
const heap = @import("std").heap;
const proc = @import("std").process;
const compress = @import("std").compress;
const zstd = @import("std").compress.zstd;
const B3 = @import("std").crypto.hash.Blake3;

pub fn main() !void {
    const hash_bitlen, const project_root = .{ 256, "/whixy" };
    const tarball_name, const out_dir_name = .{ "vendor.tzst", "vendor" };
    const zstd_window, const read_buffer = .{ 1 << 29, 64 << 10 };

    var expected: [hash_bitlen / 8]u8 = undefined;
    const wd = blk: {
        var buf: [fs.max_path_bytes + hash_bitlen / 4]u8 = undefined;
        var fba = heap.FixedBufferAllocator.init(buf[0..]); // Not reused
        var arg_iter = proc.argsWithAllocator(fba.allocator()) catch return error.ArgsLargerThanExpected;
        defer arg_iter.deinit();

        _ = arg_iter.skip(); // Skip program name.
        var buf2: [fs.max_path_bytes]u8 = undefined;
        const wd_path = try fs.cwd().realpath(arg_iter.next() orelse return error.MissingWorkingDirectoryArg, buf2[0..]);
        if (!mem.endsWith(u8, wd_path, project_root)) return error.InvalidWorkingDirectory;
        {
            const hash_hex = arg_iter.next() orelse return error.MissingTarballHashArg;
            _ = fmt.hexToBytes(expected[0..], hash_hex) catch return error.InvalidTarballHash;
        }
        break :blk try fs.cwd().openDir(wd_path, .{});
    };
    var tarball = try wd.openFile(tarball_name, .{ .mode = .read_only });
    var out_dir = try wd.makeOpenPath(out_dir_name, .{});
    defer tarball.close();
    defer out_dir.close();

    errdefer wd.deleteTree(out_dir_name) catch {};

    if (blk: {
        const ally = heap.page_allocator;
        const window = try ally.alloc(u8, zstd_window);
        defer ally.free(window);

        var bfrd = io.bufferedReaderSize(read_buffer, tarball.reader());
        var unzstd = zstd.decompressor(bfrd.reader(), .{ .window_buffer = window });
        var hasher = compress.hashedReader(unzstd.reader(), B3.init(.{}));
        try tar.pipeToFileSystem(out_dir, hasher.reader(), .{});
        {
            var buf: [128]u8 = undefined;
            while (try hasher.reader().readAll(buf[0..]) == buf.len) {}
        }
        var actual: [hash_bitlen / 8]u8 = undefined;
        hasher.hasher.final(actual[0..]);
        break :blk !mem.eql(u8, expected[0..], actual[0..]);
    }) return error.HashMismatch;
}
