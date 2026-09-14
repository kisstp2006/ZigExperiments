//! OpenGL 3.3 core loader + shader compilation helpers.
//! All modern functions are fetched at runtime via wglGetProcAddress.

const std = @import("std");
const win32 = @import("win32.zig");

pub const GLenum = u32;
pub const GLboolean = u8;
pub const GLint = i32;
pub const GLuint = u32;
pub const GLsizei = i32;
pub const GLfloat = f32;
pub const GLchar = u8;

pub const GL_FALSE: GLboolean = 0;
pub const GL_FLOAT: GLenum = 0x1406;
pub const GL_TRIANGLES: GLenum = 0x0004;
pub const GL_ARRAY_BUFFER: GLenum = 0x8892;
pub const GL_DYNAMIC_DRAW: GLenum = 0x88E4;
pub const GL_COLOR_BUFFER_BIT: GLenum = 0x4000;
pub const GL_BLEND: GLenum = 0x0BE2;
pub const GL_SRC_ALPHA: GLenum = 0x0302;
pub const GL_ONE_MINUS_SRC_ALPHA: GLenum = 0x0303;
pub const GL_COMPILE_STATUS: GLenum = 0x8B81;
pub const GL_LINK_STATUS: GLenum = 0x8B82;
pub const GL_INFO_LOG_LENGTH: GLenum = 0x8B84;
pub const GL_VERTEX_SHADER: GLenum = 0x8B31;
pub const GL_FRAGMENT_SHADER: GLenum = 0x8B32;
pub const GL_SHADER_TYPE: GLenum = 0x8B33;
pub const GL_VERSION: GLenum = 0x1F02;
pub const GL_RENDERER: GLenum = 0x1F01;
pub const GL_RGBA: GLenum = 0x1908;
pub const GL_UNSIGNED_BYTE: GLenum = 0x1401;
pub const GL_INVALID_ENUM: GLenum = 0x0500;
pub const GL_TEXTURE_2D: GLenum = 0x0DE1;
pub const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
pub const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
pub const GL_NEAREST: GLenum = 0x2600;
pub const GL_LINEAR: GLenum = 0x2601;
pub const GL_CLAMP_TO_EDGE: GLenum = 0x812F;
pub const GL_UNPACK_ALIGNMENT: GLenum = 0x0CF5;

const FnCreateShader = *const fn (GLenum) callconv(.c) GLuint;
const FnShaderSource = *const fn (GLuint, GLsizei, [*c]const [*c]const GLchar, [*c]const GLint) callconv(.c) void;
const FnCompileShader = *const fn (GLuint) callconv(.c) void;
const FnGetShaderiv = *const fn (GLuint, GLenum, [*c]GLint) callconv(.c) void;
const FnGetShaderInfoLog = *const fn (GLuint, GLsizei, ?*GLsizei, [*c]GLchar) callconv(.c) void;
const FnDeleteShader = *const fn (GLuint) callconv(.c) void;
const FnCreateProgram = *const fn () callconv(.c) GLuint;
const FnAttachShader = *const fn (GLuint, GLuint) callconv(.c) void;
const FnLinkProgram = *const fn (GLuint) callconv(.c) void;
const FnGetProgramiv = *const fn (GLuint, GLenum, [*c]GLint) callconv(.c) void;
const FnGetProgramInfoLog = *const fn (GLuint, GLsizei, ?*GLsizei, [*c]GLchar) callconv(.c) void;
const FnGetError = *const fn () callconv(.c) GLenum;
const FnGetString = *const fn (GLenum) callconv(.c) [*c]const GLchar;

const FnUseProgram = *const fn (GLuint) callconv(.c) void;
const FnDeleteProgram = *const fn (GLuint) callconv(.c) void;
const FnGenVertexArrays = *const fn (GLsizei, [*c]GLuint) callconv(.c) void;
const FnBindVertexArray = *const fn (GLuint) callconv(.c) void;
const FnDeleteVertexArrays = *const fn (GLsizei, [*c]const GLuint) callconv(.c) void;
const FnGenBuffers = *const fn (GLsizei, [*c]GLuint) callconv(.c) void;
const FnBindBuffer = *const fn (GLenum, GLuint) callconv(.c) void;
const FnBufferData = *const fn (GLenum, isize, ?*const anyopaque, GLenum) callconv(.c) void;
const FnDeleteBuffers = *const fn (GLsizei, [*c]const GLuint) callconv(.c) void;
const FnVertexAttribPointer = *const fn (GLuint, GLint, GLenum, GLboolean, GLsizei, ?*const anyopaque) callconv(.c) void;
const FnEnableVertexAttribArray = *const fn (GLuint) callconv(.c) void;
const FnGetUniformLocation = *const fn (GLuint, [*:0]const GLchar) callconv(.c) GLint;
const FnUniformMatrix4fv = *const fn (GLint, GLsizei, GLboolean, [*c]const GLfloat) callconv(.c) void;
const FnDrawArrays = *const fn (GLenum, GLint, GLsizei) callconv(.c) void;
const FnReadPixels = *const fn (GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, ?*anyopaque) callconv(.c) void;
const FnGenTextures = *const fn (GLsizei, [*c]GLuint) callconv(.c) void;
const FnBindTexture = *const fn (GLenum, GLuint) callconv(.c) void;
const FnTexImage2D = *const fn (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, ?*const anyopaque) callconv(.c) void;
const FnTexParameteri = *const fn (GLenum, GLenum, GLint) callconv(.c) void;
const FnPixelStorei = *const fn (GLenum, GLint) callconv(.c) void;
const FnDeleteTextures = *const fn (GLsizei, [*c]const GLuint) callconv(.c) void;
const FnUniform1i = *const fn (GLint, GLint) callconv(.c) void;
const FnClearColor = *const fn (GLfloat, GLfloat, GLfloat, GLfloat) callconv(.c) void;
const FnClear = *const fn (GLenum) callconv(.c) void;
const FnViewport = *const fn (GLint, GLint, GLsizei, GLsizei) callconv(.c) void;
const FnEnable = *const fn (GLenum) callconv(.c) void;
const FnBlendFunc = *const fn (GLenum, GLenum) callconv(.c) void;

pub var glCreateShader: FnCreateShader = undefined;
pub var glShaderSource: FnShaderSource = undefined;
pub var glCompileShader: FnCompileShader = undefined;
pub var glGetShaderiv: FnGetShaderiv = undefined;
pub var glGetShaderInfoLog: FnGetShaderInfoLog = undefined;
pub var glDeleteShader: FnDeleteShader = undefined;
pub var glCreateProgram: FnCreateProgram = undefined;
pub var glAttachShader: FnAttachShader = undefined;
pub var glLinkProgram: FnLinkProgram = undefined;
pub var glGetProgramiv: FnGetProgramiv = undefined;
pub var glGetProgramInfoLog: FnGetProgramInfoLog = undefined;
pub var glGetString: FnGetString = undefined;
pub var glGetError: FnGetError = undefined;
pub var glUseProgram: FnUseProgram = undefined;
pub var glDeleteProgram: FnDeleteProgram = undefined;
pub var glGenVertexArrays: FnGenVertexArrays = undefined;
pub var glBindVertexArray: FnBindVertexArray = undefined;
pub var glDeleteVertexArrays: FnDeleteVertexArrays = undefined;
pub var glGenBuffers: FnGenBuffers = undefined;
pub var glBindBuffer: FnBindBuffer = undefined;
pub var glBufferData: FnBufferData = undefined;
pub var glDeleteBuffers: FnDeleteBuffers = undefined;
pub var glVertexAttribPointer: FnVertexAttribPointer = undefined;
pub var glEnableVertexAttribArray: FnEnableVertexAttribArray = undefined;
pub var glGetUniformLocation: FnGetUniformLocation = undefined;
pub var glUniformMatrix4fv: FnUniformMatrix4fv = undefined;
pub var glDrawArrays: FnDrawArrays = undefined;
pub var glReadPixels: FnReadPixels = undefined;
pub var glGenTextures: FnGenTextures = undefined;
pub var glBindTexture: FnBindTexture = undefined;
pub var glTexImage2D: FnTexImage2D = undefined;
pub var glTexParameteri: FnTexParameteri = undefined;
pub var glPixelStorei: FnPixelStorei = undefined;
pub var glDeleteTextures: FnDeleteTextures = undefined;
pub var glUniform1i: FnUniform1i = undefined;
pub var glClearColor: FnClearColor = undefined;
pub var glClear: FnClear = undefined;
pub var glViewport: FnViewport = undefined;
pub var glEnable: FnEnable = undefined;
pub var glBlendFunc: FnBlendFunc = undefined;

fn load(comptime name: [:0]const u8, comptime T: type) T {
    // Modern (3.x) entry points come from wglGetProcAddress; the fixed GL 1.1
    // set may need to fall back to opengl32.dll's export table.
    if (win32.wglGetProcAddress(name.ptr)) |p| return @ptrCast(p);
    if (win32.getProcAddressOpenGL32(name.ptr)) |p| return @ptrCast(p);
    std.debug.print("missing GL proc: {s}\n", .{name});
    @panic("missing GL proc");
}

/// Resolves all OpenGL entry points. Must be called with a current context.
pub fn loadAll() void {
    glCreateShader = load("glCreateShader", FnCreateShader);
    glShaderSource = load("glShaderSource", FnShaderSource);
    glCompileShader = load("glCompileShader", FnCompileShader);
    glGetShaderiv = load("glGetShaderiv", FnGetShaderiv);
    glGetShaderInfoLog = load("glGetShaderInfoLog", FnGetShaderInfoLog);
    glDeleteShader = load("glDeleteShader", FnDeleteShader);
    glCreateProgram = load("glCreateProgram", FnCreateProgram);
    glAttachShader = load("glAttachShader", FnAttachShader);
    glLinkProgram = load("glLinkProgram", FnLinkProgram);
    glGetProgramiv = load("glGetProgramiv", FnGetProgramiv);
    glGetProgramInfoLog = load("glGetProgramInfoLog", FnGetProgramInfoLog);
    glGetString = load("glGetString", FnGetString);
    glGetError = load("glGetError", FnGetError);
    glUseProgram = load("glUseProgram", FnUseProgram);
    glDeleteProgram = load("glDeleteProgram", FnDeleteProgram);
    glGenVertexArrays = load("glGenVertexArrays", FnGenVertexArrays);
    glBindVertexArray = load("glBindVertexArray", FnBindVertexArray);
    glDeleteVertexArrays = load("glDeleteVertexArrays", FnDeleteVertexArrays);
    glGenBuffers = load("glGenBuffers", FnGenBuffers);
    glBindBuffer = load("glBindBuffer", FnBindBuffer);
    glBufferData = load("glBufferData", FnBufferData);
    glDeleteBuffers = load("glDeleteBuffers", FnDeleteBuffers);
    glVertexAttribPointer = load("glVertexAttribPointer", FnVertexAttribPointer);
    glEnableVertexAttribArray = load("glEnableVertexAttribArray", FnEnableVertexAttribArray);
    glGetUniformLocation = load("glGetUniformLocation", FnGetUniformLocation);
    glUniformMatrix4fv = load("glUniformMatrix4fv", FnUniformMatrix4fv);
    glDrawArrays = load("glDrawArrays", FnDrawArrays);
    glReadPixels = load("glReadPixels", FnReadPixels);
    glGenTextures = load("glGenTextures", FnGenTextures);
    glBindTexture = load("glBindTexture", FnBindTexture);
    glTexImage2D = load("glTexImage2D", FnTexImage2D);
    glTexParameteri = load("glTexParameteri", FnTexParameteri);
    glPixelStorei = load("glPixelStorei", FnPixelStorei);
    glDeleteTextures = load("glDeleteTextures", FnDeleteTextures);
    glUniform1i = load("glUniform1i", FnUniform1i);
    glClearColor = load("glClearColor", FnClearColor);
    glClear = load("glClear", FnClear);
    glViewport = load("glViewport", FnViewport);
    glEnable = load("glEnable", FnEnable);
    glBlendFunc = load("glBlendFunc", FnBlendFunc);
}

/// Prints the driver's GL version and renderer strings (diagnostics).
pub fn printInfo() void {
    if (glGetString(GL_VERSION)) |s| std.debug.print("GL_VERSION:  {s}\n", .{std.mem.span(s)});
    if (glGetString(GL_RENDERER)) |s| std.debug.print("GL_RENDERER: {s}\n", .{std.mem.span(s)});
}

/// Uploads an RGBA8 image as a new 2D texture.
pub fn createTextureRGBA(w: u32, h: u32, data: []const u8, nearest: bool) !GLuint {
    var id: GLuint = 0;
    glGenTextures(1, &id);
    if (id == 0) return error.TextureCreationFailed;
    glBindTexture(GL_TEXTURE_2D, id);
    const filter: GLint = if (nearest) GL_NEAREST else GL_LINEAR;
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filter);
    glTexParameteri(GL_TEXTURE_2D, 0x2802, GL_CLAMP_TO_EDGE); // WRAP_S
    glTexParameteri(GL_TEXTURE_2D, 0x2803, GL_CLAMP_TO_EDGE); // WRAP_T
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, @intCast(w), @intCast(h), 0, GL_RGBA, GL_UNSIGNED_BYTE, data.ptr);
    glBindTexture(GL_TEXTURE_2D, 0);
    return id;
}

pub fn deleteTexture(id: GLuint) void {
    if (id != 0) glDeleteTextures(1, &id);
}

/// The enum used to create fragment shaders. Some driver builds reject the
/// spec value GL_FRAGMENT_SHADER (0x8B32) with GL_INVALID_ENUM; in that case
/// detectFragmentShaderWorkaround() switches this to the enum that the driver
/// actually accepts for the fragment stage (verified with a raster probe).
pub var fragment_shader_enum: GLenum = GL_FRAGMENT_SHADER;

/// Detects drivers that reject GL_FRAGMENT_SHADER and, when needed, validates
/// the fallback enum by linking a probe program and reading a pixel back.
/// Returns true when a working fragment path is available.
pub fn detectFragmentShaderWorkaround() bool {
    _ = glGetError();
    const probe = glCreateShader(GL_FRAGMENT_SHADER);
    const err = glGetError();
    if (probe != 0) {
        glDeleteShader(probe);
        return true; // spec-compliant driver
    }
    if (err != GL_INVALID_ENUM) return false;

    const vs_src: [:0]const u8 =
        \\#version 330 core
        \\void main(){
        \\vec2 p=vec2(float((gl_VertexID<<1)&2),float(gl_VertexID&2));
        \\gl_Position=vec4(p*2.0-1.0,0.0,1.0);}
    ;
    const fs_src: [:0]const u8 =
        \\#version 330 core
        \\out vec4 fragColor;
        \\void main(){fragColor=vec4(1.0,0.0,0.0,1.0);}
    ;

    fragment_shader_enum = 0x8B30;

    const vs = compileShader(GL_VERTEX_SHADER, vs_src) catch return false;
    defer glDeleteShader(vs);
    const fs = compileShader(fragment_shader_enum, fs_src) catch return false;
    defer glDeleteShader(fs);

    const program = glCreateProgram();
    defer glDeleteProgram(program);
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glLinkProgram(program);
    var ok: GLint = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (ok == 0) return false;

    var vao: GLuint = 0;
    glGenVertexArrays(1, &vao);
    defer glDeleteVertexArrays(1, &vao);
    glBindVertexArray(vao);

    glUseProgram(program);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    var px = [4]u8{ 0, 0, 0, 0 };
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &px);
    if (px[0] > 200 and px[1] < 50) {
        std.debug.print("Basic2D: driver rejects GL_FRAGMENT_SHADER; using enum 0x8B30 workaround\n", .{});
        return true;
    }
    return false;
}

pub fn compileShader(kind: GLenum, source: [:0]const u8) !GLuint {
    const shader = glCreateShader(kind);
    if (shader == 0) {
        std.debug.print("glCreateShader(0x{X}) failed, glError 0x{X}\n", .{ kind, glGetError() });
        return error.ShaderCompileFailed;
    }
    errdefer glDeleteShader(shader);

    const src: [*c]const GLchar = source.ptr;
    var sources = [1][*c]const GLchar{src};
    glShaderSource(shader, 1, @ptrCast(&sources), null);
    glCompileShader(shader);

    var ok: GLint = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (ok == GL_FALSE) {
        var log_buf: [2048]GLchar = undefined;
        var written: GLsizei = 0;
        glGetShaderInfoLog(shader, log_buf.len, &written, &log_buf);
        std.debug.print("shader compile error ({d} bytes): {s}\n", .{
            written,
            log_buf[0..@intCast(@max(written, 0))],
        });
        std.debug.print("--- offending source ---\n{s}\n", .{source});
        return error.ShaderCompileFailed;
    }
    return shader;
}

pub fn createProgram(vertex_src: [:0]const u8, fragment_src: [:0]const u8) !GLuint {
    const vs = try compileShader(GL_VERTEX_SHADER, vertex_src);
    defer glDeleteShader(vs);
    const fs = try compileShader(fragment_shader_enum, fragment_src);
    defer glDeleteShader(fs);

    const program = glCreateProgram();
    errdefer glDeleteProgram(program);
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glLinkProgram(program);

    var ok: GLint = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (ok == GL_FALSE) {
        var log_buf: [2048]GLchar = undefined;
        var written: GLsizei = 0;
        glGetProgramInfoLog(program, log_buf.len, &written, &log_buf);
        std.debug.print("program link error: {s}\n", .{log_buf[0..@intCast(written)]});
        return error.ProgramLinkFailed;
    }
    return program;
}
