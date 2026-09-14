//! Hand-written extern declarations for the embedded Lua 5.4 C API.
//! (Lua headers are C; declaring the small surface we need directly avoids
//! translate-c entirely.)

pub const lua_State = opaque {};
pub const lua_Integer = c_longlong;
pub const lua_Number = f64;
pub const lua_KContext = isize;

pub const lua_CFunction = *const fn (*lua_State) callconv(.c) c_int;
pub const lua_KFunction = ?*const fn (?*lua_State, c_int, lua_KContext) callconv(.c) c_int;
pub const lua_Alloc = *const fn (?*anyopaque, ?*anyopaque, usize, usize) callconv(.c) ?*anyopaque;

pub const luaL_Reg = extern struct {
    name: ?[*:0]const u8,
    func: lua_CFunction,
};

// --- status codes ---
pub const LUA_OK: c_int = 0;
pub const LUA_YIELD: c_int = 1;
pub const LUA_ERRRUN: c_int = 2;
pub const LUA_ERRSYNTAX: c_int = 3;
pub const LUA_ERRMEM: c_int = 4;
pub const LUA_ERRERR: c_int = 5;

// --- basic types ---
pub const LUA_TNONE: c_int = -1;
pub const LUA_TNIL: c_int = 0;
pub const LUA_TBOOLEAN: c_int = 1;
pub const LUA_TLIGHTUSERDATA: c_int = 2;
pub const LUA_TNUMBER: c_int = 3;
pub const LUA_TSTRING: c_int = 4;
pub const LUA_TTABLE: c_int = 5;
pub const LUA_TFUNCTION: c_int = 6;
pub const LUA_TUSERDATA: c_int = 7;
pub const LUA_TTHREAD: c_int = 8;

pub const LUA_MULTRET: c_int = -1;

// LUA_REGISTRYINDEX = -LUAI_MAXSTACK - 1000, with LUAI_MAXSTACK = 1000000
pub const LUA_REGISTRYINDEX: c_int = -1001000;

// --- state manipulation ---
pub extern fn lua_newstate(f: lua_Alloc, ud: ?*anyopaque) ?*lua_State;
pub extern fn lua_close(L: ?*lua_State) void;
pub extern fn lua_newthread(L: ?*lua_State) ?*lua_State;
pub extern fn lua_resume(L: ?*lua_State, from: ?*lua_State, nargs: c_int, nresults: ?*c_int) c_int;
pub extern fn lua_xmove(from: ?*lua_State, to: ?*lua_State, n: c_int) void;

/// Macro lua_upvalueindex(i) == (LUA_REGISTRYINDEX - i)
pub fn lua_upvalueindex(i: c_int) c_int {
    return LUA_REGISTRYINDEX - i;
}

// --- stack manipulation ---
pub extern fn lua_gettop(L: ?*lua_State) c_int;
pub extern fn lua_settop(L: ?*lua_State, idx: c_int) void;
pub extern fn lua_pushvalue(L: ?*lua_State, idx: c_int) void;
pub extern fn lua_copy(L: ?*lua_State, fromidx: c_int, toidx: c_int) void;

/// Macro lua_pop(L,n) == lua_settop(L, -(n)-1)
pub fn lua_pop(L: ?*lua_State, n: c_int) void {
    lua_settop(L, -n - 1);
}

/// Macro lua_replace(L,idx) == lua_copy(L,-1,idx); lua_pop(L,1)
pub fn lua_replace(L: ?*lua_State, idx: c_int) void {
    lua_copy(L, -1, idx);
    lua_pop(L, 1);
}

// --- basic stack pushing ---
pub extern fn lua_pushnil(L: ?*lua_State) void;
pub extern fn lua_pushnumber(L: ?*lua_State, n: lua_Number) void;
pub extern fn lua_pushinteger(L: ?*lua_State, n: lua_Integer) void;
pub extern fn lua_pushboolean(L: ?*lua_State, b: c_int) void;
pub extern fn lua_pushlstring(L: ?*lua_State, s: [*c]const u8, len: usize) [*:0]const u8;
pub extern fn lua_pushstring(L: ?*lua_State, s: [*:0]const u8) [*:0]const u8;
pub extern fn lua_pushlightuserdata(L: ?*lua_State, p: ?*anyopaque) void;
pub extern fn lua_pushcclosure(L: ?*lua_State, f: lua_CFunction, n: c_int) void;
pub extern fn lua_createtable(L: ?*lua_State, narr: c_int, nrec: c_int) void;
pub extern fn lua_newuserdatauv(L: ?*lua_State, size: usize, nuvalue: c_int) ?*anyopaque;

/// Macro lua_pushcfunction(L,f) == lua_pushcclosure(L, f, 0)
pub fn lua_pushcfunction(L: ?*lua_State, f: lua_CFunction) void {
    lua_pushcclosure(L, f, 0);
}

/// Macro lua_newuserdata(L,size) == lua_newuserdatauv(L, size, 1)
pub fn lua_newuserdata(L: ?*lua_State, size: usize) ?*anyopaque {
    return lua_newuserdatauv(L, size, 1);
}

// --- access functions ---
pub extern fn lua_type(L: ?*lua_State, idx: c_int) c_int;
pub extern fn lua_toboolean(L: ?*lua_State, idx: c_int) c_int;
pub extern fn lua_tolstring(L: ?*lua_State, idx: c_int, len: ?*usize) ?[*:0]const u8;
pub extern fn lua_touserdata(L: ?*lua_State, idx: c_int) ?*anyopaque;
pub extern fn lua_tothread(L: ?*lua_State, idx: c_int) ?*lua_State;
pub extern fn lua_tonumberx(L: ?*lua_State, idx: c_int, isnum: ?*c_int) lua_Number;
pub extern fn lua_tointegerx(L: ?*lua_State, idx: c_int, isnum: ?*c_int) lua_Integer;

/// Macro lua_tointeger(L,i) == lua_tointegerx(L, i, NULL)
pub fn lua_tointeger(L: ?*lua_State, idx: c_int) lua_Integer {
    return lua_tointegerx(L, idx, null);
}

/// Macro lua_isfunction(L,i) == (lua_type(L, i) == LUA_TFUNCTION)
pub fn lua_isfunction(L: ?*lua_State, idx: c_int) c_int {
    return @intFromBool(lua_type(L, idx) == LUA_TFUNCTION);
}

/// Macro lua_isnumber(L,i) == (lua_type(L, i) == LUA_TNUMBER)
pub fn lua_isnumber(L: ?*lua_State, idx: c_int) c_int {
    return @intFromBool(lua_type(L, idx) == LUA_TNUMBER);
}

/// Macro lua_isuserdata(L,i) == (lua_type(L, i) == LUA_TUSERDATA)
pub fn lua_isuserdata(L: ?*lua_State, idx: c_int) c_int {
    return @intFromBool(lua_type(L, idx) == LUA_TUSERDATA);
}

/// Macro lua_isnil(L,i) == (lua_type(L, i) == LUA_TNIL)
pub fn lua_isnil(L: ?*lua_State, idx: c_int) c_int {
    return @intFromBool(lua_type(L, idx) == LUA_TNIL);
}

/// Macro lua_tonumber(L,i) == lua_tonumberx(L, i, NULL)
pub fn lua_tonumber(L: ?*lua_State, idx: c_int) lua_Number {
    return lua_tonumberx(L, idx, null);
}

/// Macro lua_tostring(L,i) == lua_tolstring(L, i, NULL)
pub fn lua_tostring(L: ?*lua_State, idx: c_int) ?[*:0]const u8 {
    return lua_tolstring(L, idx, null);
}

// --- get/set (table + global) ---
pub extern fn lua_getfield(L: ?*lua_State, idx: c_int, k: [*:0]const u8) c_int;
pub extern fn lua_setfield(L: ?*lua_State, idx: c_int, k: [*:0]const u8) void;
pub extern fn lua_getglobal(L: ?*lua_State, name: [*:0]const u8) c_int;
pub extern fn lua_setglobal(L: ?*lua_State, name: [*:0]const u8) void;
pub extern fn lua_rawgeti(L: ?*lua_State, idx: c_int, n: lua_Integer) c_int;
pub extern fn lua_getmetatable(L: ?*lua_State, idx: c_int) c_int;
pub extern fn lua_setmetatable(L: ?*lua_State, idx: c_int) c_int;

// --- function calls ---
/// lua_pcall is a macro for lua_pcallk(L, n, r, f, 0, NULL).
pub fn lua_pcall(L: ?*lua_State, nargs: c_int, nresults: c_int, errfunc: c_int) c_int {
    return lua_pcallk(L, nargs, nresults, errfunc, 0, null);
}
pub extern fn lua_pcallk(
    L: ?*lua_State,
    nargs: c_int,
    nresults: c_int,
    errfunc: c_int,
    ctx: lua_KContext,
    k: lua_KFunction,
) c_int;

// --- auxiliary library ---
pub extern fn luaL_newstate() ?*lua_State;
pub extern fn luaL_openlibs(L: ?*lua_State) void;
pub extern fn luaL_checktype(L: ?*lua_State, arg: c_int, t: c_int) void;
pub extern fn luaL_checknumber(L: ?*lua_State, arg: c_int) lua_Number;
pub extern fn luaL_optnumber(L: ?*lua_State, arg: c_int, def: lua_Number) lua_Number;
pub extern fn luaL_checkinteger(L: ?*lua_State, arg: c_int) lua_Integer;
pub extern fn luaL_checklstring(L: ?*lua_State, arg: c_int, len: ?*usize) [*:0]const u8;
pub extern fn luaL_tolstring(L: ?*lua_State, idx: c_int, len: ?*usize) [*:0]const u8;
pub extern fn luaL_checkudata(L: ?*lua_State, arg: c_int, tname: [*:0]const u8) *anyopaque;
pub extern fn luaL_testudata(L: ?*lua_State, arg: c_int, tname: [*:0]const u8) ?*anyopaque;
pub extern fn luaL_newmetatable(L: ?*lua_State, tname: [*:0]const u8) c_int;
pub extern fn luaL_setmetatable(L: ?*lua_State, tname: [*:0]const u8) void;
pub extern fn luaL_ref(L: ?*lua_State, t: c_int) c_int;
pub extern fn luaL_unref(L: ?*lua_State, t: c_int, ref: c_int) void;
pub extern fn luaL_setfuncs(L: ?*lua_State, l: [*c]const luaL_Reg, nup: c_int) void;
pub extern fn luaL_error(L: ?*lua_State, fmt: [*:0]const u8, ...) c_int;
pub extern fn luaL_traceback(L: ?*lua_State, L1: ?*lua_State, msg: [*c]const u8, level: c_int) void;
pub extern fn lua_atpanic(L: ?*lua_State, panicf: lua_CFunction) lua_CFunction;
pub extern fn luaL_loadbufferx(
    L: ?*lua_State,
    buff: [*c]const u8,
    size: usize,
    name: [*:0]const u8,
    mode: ?[*:0]const u8,
) c_int;

/// Macro luaL_checkstring(L,n) == luaL_checklstring(L, n, NULL)
pub fn luaL_checkstring(L: ?*lua_State, arg: c_int) [*:0]const u8 {
    return luaL_checklstring(L, arg, null);
}
/// Macro luaL_loadbuffer == luaL_loadbufferx(L, buff, sz, name, NULL)
pub fn luaL_loadbuffer(
    L: ?*lua_State,
    buff: [*c]const u8,
    size: usize,
    name: [*:0]const u8,
) c_int {
    return luaL_loadbufferx(L, buff, size, name, null);
}

/// Creates a new table filled with the functions of `regs` (like luaL_newlib).
/// Avoids luaL_setfuncs, whose NULL-sentinel convention is easy to get wrong.
pub fn registerLib(L: ?*lua_State, regs: []const luaL_Reg) void {
    lua_createtable(L, 0, @intCast(regs.len));
    for (regs) |r| {
        if (r.name) |n| {
            lua_pushcfunction(L, r.func);
            lua_setfield(L, -2, n);
        }
    }
}
