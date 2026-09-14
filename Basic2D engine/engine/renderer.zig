//! Sprite batching renderer: every visible SpriteRenderer becomes a quad
//! (or a shaded circle) in one dynamic vertex buffer -> one draw call.

const std = @import("std");
const gl = @import("gl.zig");
const types = @import("types.zig");

const Vec2 = types.Vec2;
const Color = types.Color;

pub const Vertex = struct {
    pos_x: f32,
    pos_y: f32, // world position of the sprite center
    local_x: f32,
    local_y: f32, // local offset in [-1,1]
    r: f32,
    g: f32,
    b: f32,
    a: f32, // color tint
    shape: f32, // 0 = quad, 1 = circle
    rot: f32, // rotation in radians
    size_x: f32,
    size_y: f32, // full width/height of the quad
    uv_x: f32,
    uv_y: f32, // texture coordinates
    tex: f32, // 0 = solid color, 1 = sample texture
};

const vertex_shader_src: [:0]const u8 =
    \\#version 330 core
    \\layout(location = 0) in vec2 aPos;
    \\layout(location = 1) in vec2 aLocal;
    \\layout(location = 2) in vec4 aColor;
    \\layout(location = 3) in float aShape;
    \\layout(location = 4) in float aRot;
    \\layout(location = 5) in vec2 aSize;
    \\layout(location = 6) in vec2 aUV;
    \\layout(location = 7) in float aTex;
    \\uniform mat4 uProj;
    \\out vec4 vColor;
    \\out vec2 vLocal;
    \\out float vShape;
    \\out vec2 vUV;
    \\out float vTex;
    \\void main() {
    \\    float c = cos(aRot);
    \\    float s = sin(aRot);
    \\    vec2 localRot = vec2(aLocal.x * c - aLocal.y * s, aLocal.x * s + aLocal.y * c);
    \\    vec2 world = aPos + localRot * aSize * 0.5;
    \\    gl_Position = uProj * vec4(world, 0.0, 1.0);
    \\    vColor = aColor;
    \\    vLocal = aLocal;
    \\    vShape = aShape;
    \\    vUV = aUV;
    \\    vTex = aTex;
    \\}
;

const fragment_shader_src: [:0]const u8 =
    \\#version 330 core
    \\in vec4 vColor;
    \\in vec2 vLocal;
    \\in float vShape;
    \\in vec2 vUV;
    \\in float vTex;
    \\uniform sampler2D uTexture;
    \\out vec4 fragColor;
    \\void main() {
    \\    float alpha = 1.0;
    \\    if (vShape > 0.5) {
    \\        float d = length(vLocal);
    \\        alpha = 1.0 - smoothstep(0.95, 1.0, d);
    \\    }
    \\    vec4 base = vColor;
    \\    if (vTex > 0.5) base *= texture(uTexture, vUV);
    \\    fragColor = vec4(base.rgb, base.a * alpha);
    \\}
;

/// Column-major orthographic projection. Origin at the camera center,
/// Y points up, one world unit == one pixel.
fn ortho(l: f32, r: f32, b: f32, t: f32) [16]f32 {
    return .{
        2.0 / (r - l),      0.0,                0.0,  0.0,
        0.0,                2.0 / (t - b),      0.0,  0.0,
        0.0,                0.0,                -1.0, 0.0,
        -(r + l) / (r - l), -(t + b) / (t - b), 0.0,  1.0,
    };
}

pub const Renderer = struct {
    program: gl.GLuint,
    vao: gl.GLuint,
    vbo: gl.GLuint,
    u_proj: gl.GLint,
    u_texture: gl.GLint,

    pub fn init() !Renderer {
        if (!gl.detectFragmentShaderWorkaround()) {
            std.debug.print("Basic2D: no working fragment shader path on this OpenGL driver\n", .{});
            return error.NoFragmentShaderSupport;
        }
        const program = try gl.createProgram(vertex_shader_src, fragment_shader_src);
        errdefer gl.glDeleteProgram(program);

        var vao: gl.GLuint = 0;
        var vbo: gl.GLuint = 0;
        gl.glGenVertexArrays(1, &vao);
        gl.glBindVertexArray(vao);
        gl.glGenBuffers(1, &vbo);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vbo);

        const stride: gl.GLsizei = @sizeOf(Vertex);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, null);
        gl.glEnableVertexAttribArray(1);
        gl.glVertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "local_x")));
        gl.glEnableVertexAttribArray(2);
        gl.glVertexAttribPointer(2, 4, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "r")));
        gl.glEnableVertexAttribArray(3);
        gl.glVertexAttribPointer(3, 1, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "shape")));
        gl.glEnableVertexAttribArray(4);
        gl.glVertexAttribPointer(4, 1, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "rot")));
        gl.glEnableVertexAttribArray(5);
        gl.glVertexAttribPointer(5, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "size_x")));
        gl.glEnableVertexAttribArray(6);
        gl.glVertexAttribPointer(6, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "uv_x")));
        gl.glEnableVertexAttribArray(7);
        gl.glVertexAttribPointer(7, 1, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "tex")));

        gl.glEnable(gl.GL_BLEND);
        gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);

        const u_proj = gl.glGetUniformLocation(program, "uProj");
        const u_texture = gl.glGetUniformLocation(program, "uTexture");
        gl.glUseProgram(program);
        gl.glUniform1i(u_texture, 0);

        return .{ .program = program, .vao = vao, .vbo = vbo, .u_proj = u_proj, .u_texture = u_texture };
    }

    pub fn deinit(self: *Renderer) void {
        gl.glDeleteBuffers(1, &self.vbo);
        gl.glDeleteVertexArrays(1, &self.vao);
        gl.glDeleteProgram(self.program);
    }

    /// Clears the frame; call once before flushing any groups.
    pub fn beginFrame(
        self: *Renderer,
        screen_w: u32,
        screen_h: u32,
        clear: Color,
    ) void {
        _ = self;
        gl.glViewport(0, 0, @intCast(screen_w), @intCast(screen_h));
        gl.glClearColor(clear.r, clear.g, clear.b, clear.a);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    }

    /// Draws one vertex group with one texture. Does NOT clear the frame.
    pub fn flush(
        self: *Renderer,
        verts: []const Vertex,
        screen_w: u32,
        screen_h: u32,
        camera: Vec2,
        zoom: f32,
        texture: ?gl.GLuint,
    ) void {
        if (verts.len == 0) return;

        const hw: f32 = (@as(f32, @floatFromInt(screen_w)) / 2.0) / zoom;
        const hh: f32 = (@as(f32, @floatFromInt(screen_h)) / 2.0) / zoom;
        const mat = ortho(camera.x - hw, camera.x + hw, camera.y - hh, camera.y + hh);

        gl.glUseProgram(self.program);
        gl.glBindVertexArray(self.vao);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, self.vbo);
        gl.glBufferData(
            gl.GL_ARRAY_BUFFER,
            @intCast(verts.len * @sizeOf(Vertex)),
            verts.ptr,
            gl.GL_DYNAMIC_DRAW,
        );
        gl.glBindTexture(gl.GL_TEXTURE_2D, texture orelse 0);
        gl.glUniformMatrix4fv(self.u_proj, 1, gl.GL_FALSE, &mat);
        gl.glDrawArrays(gl.GL_TRIANGLES, 0, @intCast(verts.len));
    }
};
