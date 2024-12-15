const root = @import("root");
const std = @import("std");
const testing = std.testing;
const c = @cImport({
    @cInclude("cgif.h");
});

// Number of colors (excluding special colors)
const num_colors = 10;

// Generate a gradient palette array of size num_colors * 3 (R, G, B)
pub const palette = blk: {
    var color_array: [num_colors * 3]u8 = @splat(0);
    var index: usize = color_array.len;
    const increment = 190 / (num_colors - 1);
    var value: u8 = 20;

    while (index > 0) : (index -= 3) {
        color_array[index - 1] = value;
        value +|= increment;
    }

    break :blk color_array;
};

// Append black colors at the end of the palette for stuck and null states
const extended_palette = palette ++ [_]u8{
    0, 0, 0, // BLACK
    0xff, 0xff, 0xff, // RED
};

// Pointer to the global palette array
const global_palette_pointer = &extended_palette;

pub const GifDLA = struct {
    /// Compute the color index for a given pixel based on its position and state.
    /// pixel:    - null means not used
    ///          - true means stuck particle
    ///          - false means moving particle
    /// (x, y): coordinates of the pixel
    /// height and width: dimensions of the grid
    fn getPixelColor(pixel: ?bool, x: usize, y: usize, height: usize, width: usize) u8 {
        const max_distance = @min(width, height) / 2;
        const max_distance_float: f64 = @floatFromInt(max_distance);
        const threshold = max_distance / num_colors;

        if (pixel == true) {
            // Stuck particle: color depends on distance from center
            const distance: usize = @intFromFloat(std.math.hypot(
                @as(f64, @floatFromInt(x)) - max_distance_float,
                @as(f64, @floatFromInt(y)) - max_distance_float,
            ));
            const color_index: usize = @min(num_colors - 1, distance / threshold);
            return @truncate(color_index);
        } else if (pixel == false) {
            // Moving particle: use the next-to-last color
            return num_colors + 1;
        } else {
            // Null pixel: use the last color
            return num_colors;
        }
    }

    /// Create a GIF from the DLA simulation.
    /// alloc:          allocator for memory
    /// name:           GIF output file name
    /// width, height:  dimensions of the grid
    /// num_particles:  initial number of particles
    /// frame_save_interval: how often to save frames
    pub fn create(alloc: std.mem.Allocator, name: [:0]const u8, width: usize, height: usize, num_particles: usize, frame_save_interval: usize) !void {
        // Initialize the DLA simulation
        var dla_instance = try DLA.initialize(std.heap.c_allocator, width, height, num_particles);
        defer dla_instance.deinitialize();

        // Configure GIF settings
        var gif_config = c.CGIF_Config{};
        gif_config.width = @truncate(width);
        gif_config.height = @truncate(height);
        gif_config.numGlobalPaletteEntries = num_colors + 2;
        gif_config.pGlobalPalette = @ptrCast(@constCast(global_palette_pointer));
        gif_config.path = name;

        const gif = c.cgif_newgif(&gif_config);

        // Allocate memory for image data (one byte per pixel)
        var image_data = try alloc.alloc(u8, width * height);
        defer alloc.free(image_data);

        var frame_count: usize = 0;
        while (dla_instance.hasRemainingParticles()) : ({
            dla_instance.simulateFrame();
            frame_count += 1;
        }) {
            if (frame_count % frame_save_interval != 0) {
                continue;
            }

            std.debug.print("Remaining particles: {d}\n", .{dla_instance.remaining_particles});
            for (0..height) |y| {
                for (0..width) |x| {
                    const index = y * width + x;
                    image_data[index] = getPixelColor(dla_instance.grid[index], x, y, height, width);
                }
            }

            var frame_config = c.CGIF_FrameConfig{};
            frame_config.delay = 1; // short delay between frames
            frame_config.pImageData = image_data.ptr;
            _ = c.cgif_addframe(gif, &frame_config);
        }

        // Add a final frame with a longer delay
        for (0..height) |y| {
            for (0..width) |x| {
                const index = y * width + x;
                image_data[index] = getPixelColor(dla_instance.grid[index], x, y, height, width);
            }
        }

        var final_frame_config = c.CGIF_FrameConfig{};
        final_frame_config.delay = 100; // longer delay for final frame
        final_frame_config.pImageData = image_data.ptr;
        _ = c.cgif_addframe(gif, &final_frame_config);

        _ = c.cgif_close(gif);
    }
};

/// A single particle with coordinates (x, y).
const Particle = struct {
    x: usize,
    y: usize,
};

/// DLA simulation structure.
/// - width, height: size of the simulation grid
/// - grid: array representing each pixel in the simulation:
///   - null: empty cell
///   - true: stuck particle cell
///   - false: moving particle cell
/// - num_particles: total initial particles
/// - remaining_particles: how many are still moving
/// - particles: list of moving particles
pub const DLA = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    grid: []?bool,
    num_particles: usize,
    remaining_particles: usize,
    particles: std.ArrayList(Particle),
    random: std.Random,

    const Self = @This();

    /// Initialize the DLA simulation by placing a single stuck particle in the center
    /// and randomly distributing the remaining particles.
    pub fn initialize(alloc: std.mem.Allocator, width: usize, height: usize, num_particles: usize) !Self {
        const max = width * height;
        var grid = try alloc.alloc(?bool, max);
        @memset(grid, null);

        // Place the initial stuck particle at the center
        const mid_x = width / 2;
        const mid_y = height / 2;
        grid[mid_y * width + mid_x] = true;

        // Place the remaining particles randomly
        var particles = try std.ArrayList(Particle).initCapacity(alloc, num_particles);
        var remaining = num_particles;

        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));

        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        while (remaining > 0) {
            const index = rand.intRangeLessThan(usize, 0, max);
            if (grid[index] != null) {
                continue;
            }

            grid[index] = false;
            const x = index % width;
            const y = index / width;
            particles.appendAssumeCapacity(Particle{ .x = x, .y = y });
            remaining -= 1;
        }

        const self = Self{
            .allocator = alloc,
            .width = width,
            .height = height,
            .grid = grid,
            .num_particles = num_particles,
            .remaining_particles = num_particles,
            .particles = particles,
            .random = rand,
        };

        return self;
    }

    /// Check if there are still moving particles left.
    pub fn hasRemainingParticles(self: *Self) bool {
        return self.remaining_particles != 0;
    }

    /// Simulate one frame of particle movement. Each particle tries to move
    /// randomly until it settles next to a stuck particle.
    pub fn simulateFrame(self: *Self) void {
        var continue_simulation = true;
        while (continue_simulation) {
            for (self.particles.items) |*particle| {
                const x = particle.x;
                const y = particle.y;
                const index = y * self.width + x;

                var placed = false;
                var attempts: usize = 0;

                // Try up to 15 random moves for each particle
                while (!placed and attempts < 15) : (attempts += 1) {
                    const x_offset = self.random.intRangeLessThan(isize, -1, 2);
                    const y_offset = self.random.intRangeLessThan(isize, -1, 2);

                    var new_x = @as(isize, @intCast(x)) + x_offset;
                    var new_y = @as(isize, @intCast(y)) + y_offset;

                    // Wrap around the grid if needed (toroidal boundary conditions)
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
                        continue; // can't move here, it's occupied or stuck
                    }

                    // Move particle
                    self.grid[index] = null;
                    self.grid[new_index] = false;

                    particle.x = @intCast(new_x);
                    particle.y = @intCast(new_y);

                    placed = true;
                }
            }

            // Check if new particles have become stuck in this iteration
            continue_simulation = !self.checkAndRemoveStuckParticles();
        }
    }

    /// Check if any moving particle has become stuck by being adjacent
    /// to a stuck particle. If so, remove it from the moving list and mark it as stuck.
    fn checkAndRemoveStuckParticles(self: *Self) bool {
        var stuck_found = false;
        for (self.particles.items, 0..) |particle, particle_index| {
            const x = particle.x;
            const y = particle.y;
            const index = y * self.width + x;

            neighbors: for ([_]isize{ -1, 0, 1 }) |y_offset| {
                for ([_]isize{ -1, 0, 1 }) |x_offset| {
                    const new_x = @as(isize, @intCast(x)) + x_offset;
                    const new_y = @as(isize, @intCast(y)) + y_offset;

                    // Check boundary conditions
                    if (new_x >= self.width or new_x < 0 or new_y >= self.height or new_y < 0) {
                        continue;
                    }

                    const new_index: usize = @intCast(new_y * @as(isize, @intCast(self.width)) + new_x);

                    // If adjacent to a stuck particle, this one becomes stuck
                    if (self.grid[new_index]) |cell| {
                        if (cell) {
                            self.remaining_particles -= 1;
                            self.grid[index] = true;
                            stuck_found = true;
                            _ = self.particles.swapRemove(particle_index);
                            break :neighbors;
                        }
                    }
                }
            }
        }

        return stuck_found;
    }

    /// Free allocated resources.
    pub fn deinitialize(self: *Self) void {
        self.particles.deinit();
        self.allocator.free(self.grid);
    }
};

// Test that creates a small GIF for debugging
test "test gif" {
    try GifDLA.create(testing.allocator, @ptrCast("test.gif"), 20, 20, 50, 5);
}

// Test the DLA simulation logic without GIF output
test "test dla" {
    var dla_instance = try DLA.initialize(testing.allocator, 100, 100, 100);
    defer dla_instance.deinitialize();

    while (dla_instance.hasRemainingParticles()) {
        std.debug.print("Remaining particles: {d}\n", .{dla_instance.remaining_particles});
        dla_instance.simulateFrame();
    }
}
