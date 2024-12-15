const root = @import("root");
const std = @import("std");
const testing = std.testing;
const c = @cImport({
    @cInclude("cgif.h");
});

const num_colors = 10;

pub const palette = blk: {
    var array: [num_colors * 3]u8 = @splat(0);

    var index: usize = array.len;

    const sum = 190 / (num_colors - 1);

    var value: u8 = 20;

    while (index > 0) : (index -= 3) {
        array[index - 1] = value;

        value +|= sum;
    }

    break :blk array;
};

const palette_black = palette ++ [_]u8{ 0, 0, 0, 0xff, 0, 0 };

const palette_pointer = &palette_black;

pub const GifDLA = struct {
    // allocator: std.mem.Allocator,
    // width: usize,
    // height: usize,
    // gif: *c.CGIF,
    // gif_config: c.CGIF_Config,
    // frame_config: c.CGIF_FrameConfig,
    // dla : DLA,

    pub fn create(alloc: std.mem.Allocator, name: [:0]const u8, width: usize, height: usize, num_particles: usize) !void {
        var dla = try DLA.init(std.heap.c_allocator, width, height, num_particles);
        defer dla.deinit();

        var config = c.CGIF_Config{};

        config.width = @truncate(width);
        config.height = @truncate(height);
        config.numGlobalPaletteEntries = num_colors + 2;
        config.pGlobalPalette = @ptrCast(@constCast(palette_pointer));
        config.path = name;

        const gif = c.cgif_newgif(&config);

        var image_data = try alloc.alloc(u8, width * height);
        defer alloc.free(image_data);

        const max_distance = @min(width, height) / 2;

        const max_distance_float: f64 = @floatFromInt(max_distance);

        const threshold = max_distance / num_colors;

        while (dla.canPlay()) {
            std.debug.print("remaining {d}\n", .{dla.remaining});
            for (0..height) |y| {
                for (0..width) |x| {
                    const index = y * width + x;
                    if (dla.grid[index] == true) {
                        const distance: usize = @intFromFloat(std.math.hypot(
                            @as(f64, @floatFromInt(x)) - max_distance_float,
                            @as(f64, @floatFromInt(y)) - max_distance_float,
                        ));

                        const color_index: usize = @min(num_colors - 1, distance / threshold);
                        image_data[index] = @truncate(color_index);
                    } else if (dla.grid[index] == false) {
                        image_data[index] = num_colors + 1;
                    } else {
                        image_data[index] = num_colors;
                    }
                }
            }

            var frame_config = c.CGIF_FrameConfig{};

            frame_config.delay = 1;

            frame_config.pImageData = image_data.ptr;

            _ = c.cgif_addframe(gif, &frame_config);

            dla.nextFrame();
        }

        for (0..height) |y| {
            for (0..width) |x| {
                const index = y * width + x;
                if (dla.grid[index] == true) {
                    const distance: usize = @intFromFloat(std.math.hypot(
                        @as(f64, @floatFromInt(x)) - max_distance_float,
                        @as(f64, @floatFromInt(y)) - max_distance_float,
                    ));

                    const color_index: usize = @min(num_colors - 1, distance / threshold);
                    image_data[index] = @truncate(color_index);
                } else if (dla.grid[index] == false) {
                    image_data[index] = num_colors + 1;
                } else {
                    image_data[index] = num_colors;
                }
            }
        }

        var frame_config = c.CGIF_FrameConfig{};

        frame_config.delay = 100;

        frame_config.pImageData = image_data.ptr;

        _ = c.cgif_addframe(gif, &frame_config);

        _ = c.cgif_close(gif);
    }
};

const Particle = struct {
    x: usize,
    y: usize,
};

pub const DLA = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    grid: []?bool,
    num_particles: usize,
    remaining: usize,
    particles: std.ArrayList(Particle),

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, width: usize, height: usize, num_particles: usize) !Self {
        const max = width * height;
        var grid = try alloc.alloc(?bool, max);

        @memset(grid, null);

        const mid_x = width / 2;
        const mid_y = height / 2;

        grid[mid_y * width + mid_x] = true;

        var particles = try std.ArrayList(Particle).initCapacity(alloc, num_particles);

        var remaining_particles = num_particles;

        while (remaining_particles > 0) {
            const index = std.crypto.random.intRangeLessThan(usize, 0, max);

            if (grid[index] != null) {
                continue;
            }

            grid[index] = false;

            const x = index % width;
            const y = index / width;

            particles.appendAssumeCapacity(Particle{ .x = x, .y = y });

            remaining_particles -= 1;
        }

        const self = Self{
            .allocator = alloc,
            .width = width,
            .height = height,
            .grid = grid,
            .num_particles = num_particles,
            .remaining = num_particles,
            .particles = particles,
        };

        return self;
    }

    pub fn canPlay(self: *Self) bool {
        return self.remaining != 0;
    }

    pub fn nextFrame(self: *Self) void {
        var play = true;
        while (play) {
            for (self.particles.items) |*particle| {
                const x = particle.x;
                const y = particle.y;

                const index = y * self.width + x;

                var placed = false;

                var tries: usize = 0;

                while (!placed and tries < 15) : (tries += 1) {
                    const x_offset = std.crypto.random.intRangeLessThan(isize, -1, 2);
                    const y_offset = std.crypto.random.intRangeLessThan(isize, -1, 2);

                    var new_x = @as(isize, @intCast(x)) + x_offset;
                    var new_y = @as(isize, @intCast(y)) + y_offset;

                    if (new_x < 0) {
                        new_x += @intCast(self.width);
                    } else if (new_x >= self.width) {
                        new_x -= @intCast(self.width);
                    }

                    if (new_y < 0) {
                        new_y += @intCast(self.height);
                    } else if (new_y >= self.height) {
                        new_y -= @intCast(self.height);
                    }

                    const new_index: usize = @intCast(new_y * @as(isize, @intCast(self.width)) + new_x);

                    if (self.grid[new_index] != null) {
                        continue;
                    }

                    self.grid[index] = null;

                    self.grid[new_index] = false;

                    particle.x = @intCast(new_x);
                    particle.y = @intCast(new_y);

                    placed = true;
                }
            }

            play = !self.newStuck();
        }
    }

    fn newStuck(self: *Self) bool {
        var stucked = false;
        for (self.particles.items, 0..) |particle, particle_index| {
            const x = particle.x;
            const y = particle.y;

            const index = y * self.width + x;

            neighbors: for ([_]isize{ -1, 0, 1 }) |y_offset| {
                for ([_]isize{ -1, 0, 1 }) |x_offset| {
                    const new_x = @as(isize, @intCast(x)) + x_offset;
                    const new_y = @as(isize, @intCast(y)) + y_offset;

                    if (new_x >= self.width or new_x < 0 or new_y >= self.height or new_y < 0) {
                        continue;
                    }

                    const new_index: usize = @intCast(new_y * @as(isize, @intCast(self.width)) + new_x);

                    if (self.grid[new_index]) |cell| {
                        if (cell) {
                            self.remaining -= 1;
                            self.grid[index] = true;
                            stucked = true;
                            _ = self.particles.swapRemove(particle_index);
                            break :neighbors;
                        }
                    }
                }
            }
        }

        return stucked;
    }

    pub fn deinit(self: *Self) void {
        self.particles.deinit();
        self.allocator.free(self.grid);
    }
};

test "test gif" {
    try GifDLA.create(testing.allocator, @ptrCast("test.gif"), 20, 20, 50);
}

test "test dla" {
    var dla = try DLA.init(testing.allocator, 100, 100, 100);
    defer dla.deinit();

    while (dla.canPlay()) {
        std.debug.print("remaining {d}\n", .{dla.remaining});
        dla.nextFrame();
    }
}
