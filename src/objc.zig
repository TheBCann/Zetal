<<<<<<< HEAD
//! Comptime-typed Objective-C bridge: objc_msgSend cast per call, cached selectors/classes, NSString helpers.
const std = @import("std");
const builtin = @import("builtin");

// ============================================================
// Types
// ============================================================

/// An Objective-C object pointer (`id`).
pub const Object = *anyopaque;
/// A registered selector (`SEL`).
pub const Selector = *anyopaque;
/// An Objective-C class object (`Class`).
pub const Class = *anyopaque;

/// CoreGraphics scalar: `double` on every 64-bit Apple target.
pub const CGFloat = f64;
/// `CGPoint` / `NSPoint`.
pub const CGPoint = extern struct { x: CGFloat, y: CGFloat };
/// `CGSize` / `NSSize`.
pub const CGSize = extern struct { width: CGFloat, height: CGFloat };
/// `CGRect` / `NSRect`.
pub const CGRect = extern struct { origin: CGPoint, size: CGSize };

// ============================================================
// libobjc entry points
// ============================================================

extern "c" fn sel_registerName(name: [*:0]const u8) ?Selector;
extern "c" fn objc_getClass(name: [*:0]const u8) ?Class;
// Declared without parameters on purpose: objc_msgSend is a trampoline that must be called through the
// method's exact C prototype, so it is only ever reached via the per-call cast in `msgSend`.
extern "c" fn objc_msgSend() void;

// ============================================================
// Selectors and classes (looked up once, cached per name)
// ============================================================

/// Returns the selector `name`, registered on first use and served from a per-name static afterwards.
/// Main-thread only: the cache is an unsynchronized static.
pub fn sel(comptime name: [:0]const u8) Selector {
    const cache = &SelectorCache(name).value;
    if (cache.*) |s| return s;
    const s = sel_registerName(name.ptr) orelse std.debug.panic("sel_registerName(\"{s}\") returned NULL", .{name});
    cache.* = s;
    return s;
}

/// Returns the class `name`, looked up once and then cached per name; panics when no such class is
/// registered (usually: its framework is not linked). Main-thread only, like `sel`.
pub fn class(comptime name: [:0]const u8) Class {
    const cache = &ClassCache(name).value;
    if (cache.*) |c| return c;
    const c = objc_getClass(name.ptr) orelse
        std.debug.panic("objc_getClass(\"{s}\") returned nil: class not registered (framework not linked?)", .{name});
    cache.* = c;
    return c;
}

// One static per name. The `key = name` capture is load-bearing: a container's identity is its declaration
// site plus what it captures, so without it every name collapses into ONE struct sharing ONE cached
// pointer (probed). Two separate functions keep sel("X") and class("X") in different slots.
fn SelectorCache(comptime name: [:0]const u8) type {
    return struct {
        const key = name;
        var value: ?Selector = null;
    };
}

fn ClassCache(comptime name: [:0]const u8) type {
    return struct {
        const key = name;
        var value: ?Class = null;
    };
}

// ============================================================
// Message sending
// ============================================================

/// Sends `selector` to `target` (an Object/Class, optional or not) with `args` and returns `Ret`.
/// Every argument needs a concrete C type: `@as(u64, n)`, `@as(f64, x)`, `@as(?Object, null)`, `str.ptr`.
/// Example: `msgSend(void, encoder, "setVertexBuffer:offset:atIndex:", .{ buf, @as(u64, 0), @as(u64, 1) })`.
pub inline fn msgSend(comptime Ret: type, target: anytype, comptime selector: [:0]const u8, args: anytype) Ret {
    const Send = BuildMsgSendFn(Ret, @TypeOf(target), @TypeOf(args));
    const send: Send = @ptrCast(&objc_msgSend);
    return @call(.auto, send, .{ target, sel(selector) } ++ args);
}

/// Returns the C function-pointer type `Ret (*)(Target, SEL, args...)` for one msgSend call shape,
/// rejecting receivers, arguments and returns the bridge cannot pass correctly.
fn BuildMsgSendFn(comptime Ret: type, comptime Target: type, comptime Args: type) type {
    // msgSend is inline, so this evaluation is charged to the CALLER's comptime branch quota; a function
    // with ~100 distinct call shapes would otherwise exceed the default 1000 backwards branches (probed).
    @setEvalBranchQuota(100_000);

    const args_info = @typeInfo(Args);
    if (args_info != .@"struct" or !args_info.@"struct".is_tuple) {
        @compileError("msgSend args must be a tuple, got " ++ @typeName(Args));
    }
    checkReceiver(Target);
    checkReturn(Ret);

    const arg_types = args_info.@"struct".field_types;
    var param_types: [arg_types.len + 2]type = undefined;
    param_types[0] = Target;
    param_types[1] = Selector;
    for (arg_types, 0..) |T, i| {
        checkArgument(T, i);
        param_types[i + 2] = T;
    }
    const param_attrs: [arg_types.len + 2]std.lang.Type.Fn.ParamAttributes = @splat(.{});
    return *const @Fn(&param_types, &param_attrs, Ret, .{ .@"callconv" = .c });
}

// The checks below give C-ABI mistakes readable errors (left alone, the compiler reports most of them at
// objc.zig:1:1 with the real call site buried in a "called inline here" note) and reject the one it would
// accept silently: an x86_64 struct return that needs objc_msgSend_stret.

fn checkReceiver(comptime Target: type) void {
    const Ptr = switch (@typeInfo(Target)) {
        .optional => |o| o.child,
        else => Target,
    };
    switch (@typeInfo(Ptr)) {
        // Exactly an id (Object and Class are *anyopaque): any other pointer, such as `&wrapper`,
        // would have libobjc read a Zig address as an object and crash at run time.
        .pointer => |p| if (p.size == .one and p.child == anyopaque) return,
        else => {},
    }
    @compileError("msgSend receiver must be an Object or Class (pass `.handle` of a wrapper), got " ++
        @typeName(Target));
}

fn checkReturn(comptime Ret: type) void {
    switch (@typeInfo(Ret)) {
        // arm64 returns every struct through plain objc_msgSend (HFAs in d0-d3, the rest via x8).
        // x86_64 returns structs over 16 bytes in memory, which needs objc_msgSend_stret instead.
        .@"struct", .@"union" => if (builtin.target.cpu.arch == .x86_64 and @sizeOf(Ret) > 16) {
            @compileError(std.fmt.comptimePrint(
                "msgSend cannot return {s} ({d} bytes) on x86_64: structs over 16 bytes come back through " ++
                    "objc_msgSend_stret, which this bridge does not implement (aarch64 needs no stret)",
                .{ @typeName(Ret), @sizeOf(Ret) },
            ));
        },
        .pointer => |p| if (p.size == .slice) {
            @compileError("msgSend cannot return a slice (" ++ @typeName(Ret) ++
                "); return the C pointer, e.g. ?[*:0]const u8, and slice it with std.mem.span");
        },
        else => {},
    }
}

fn checkArgument(comptime T: type, comptime index: usize) void {
    const problem: ?[]const u8 = switch (@typeInfo(T)) {
        .comptime_int, .comptime_float => "is an untyped number literal; " ++
            "give it a C type, e.g. @as(u64, n) or @as(f64, x)",
        .null => "is a bare null; write @as(?Object, null)",
        .enum_literal => "is an enum literal; pass a typed value instead",
        .pointer => |p| if (p.size == .slice) "is a slice; C only sees a pointer, so pass `.ptr`" else null,
        else => null,
    };
    if (problem) |text| {
        @compileError(std.fmt.comptimePrint("msgSend argument {d} ({s}) {s}", .{ index, @typeName(T), text }));
    }
}

// ============================================================
// Ownership and strings
// ============================================================

/// Sends -retain (+1) and returns `obj`.
pub fn retain(obj: Object) Object {
    _ = msgSend(?Object, obj, "retain", .{});
    return obj;
}

/// Sends -release (-1), balancing alloc/new/copy/retain.
pub fn release(obj: Object) void {
    msgSend(void, obj, "release", .{});
}

/// Returns an autoreleased NSString copy of `str` (+stringWithUTF8String:), valid until the enclosing
/// autorelease pool drains; panics on nil (Foundation rejects invalid UTF-8).
pub fn nsString(str: [:0]const u8) Object {
    return msgSend(?Object, class("NSString"), "stringWithUTF8String:", .{str.ptr}) orelse
        std.debug.panic("+[NSString stringWithUTF8String:] returned nil for \"{s}\" (invalid UTF-8?)", .{str});
}

/// Returns the UTF-8 bytes of `ns` (-UTF8String), or "" when it has none. The buffer belongs to the string:
/// it is only valid while `ns` lives and the enclosing autorelease pool has not drained, so copy what you keep.
pub fn fromNSString(ns: Object) [:0]const u8 {
    return std.mem.span(msgSend(?[*:0]const u8, ns, "UTF8String", .{})) orelse "";
}

/// Returns `[class_name new]` (+1: the caller releases it), or null when +new returns nil.
pub fn new(comptime class_name: [:0]const u8) ?Object {
    return msgSend(?Object, class(class_name), "new", .{});
}

// ============================================================
// Tests (libobjc + Foundation only; no window server)
// ============================================================

const testing = std.testing;

/// Pushes an NSAutoreleasePool for one test body; objc.zig cannot import platform/autorelease.zig.
fn pushTestPool() !Object {
    const raw = msgSend(?Object, class("NSAutoreleasePool"), "alloc", .{}) orelse return error.PoolAllocFailed;
    return msgSend(?Object, raw, "init", .{}) orelse return error.PoolInitFailed;
}

fn drainTestPool(pool: Object) void {
    msgSend(void, pool, "drain", .{});
}

/// Unwraps a factory result, failing the test cleanly (instead of panicking) on nil.
fn nonNil(obj: ?Object) !Object {
    return obj orelse return error.TestUnexpectedResult;
}

test "sel registers a selector once and caches it per name" {
    const pool = try pushTestPool();
    defer drainTestPool(pool);

    const name = "zetalObjcCacheProbe:";
    try testing.expectEqual(null, SelectorCache(name).value);
    const first = sel(name);
    try testing.expectEqual(first, SelectorCache(name).value); // stored by the first call
    try testing.expectEqual(first, sel(name));
    try testing.expectEqual(sel_registerName(name), first); // the runtime's uniqued pointer

    // Per-name slots (the capture fix): a shared slot would hand "hash" the "description" selector.
    try testing.expect(sel("description") != sel("hash"));
    try testing.expect(sel("description") != first);
    try testing.expect(SelectorCache("description") != SelectorCache("hash"));
    try testing.expect(sel("NSObject") != class("NSObject"));
}

test "class looks up a class once and caches it" {
    const pool = try pushTestPool();
    defer drainTestPool(pool);

    const ns_object = class("NSObject");
    try testing.expectEqual(objc_getClass("NSObject"), ns_object);
    try testing.expectEqual(ns_object, ClassCache("NSObject").value);
    try testing.expectEqual(ns_object, class("NSObject"));
    try testing.expect(class("NSString") != ns_object);
    try testing.expect(msgSend(bool, class("NSString"), "isSubclassOfClass:", .{ns_object}));
}

test "new returns a +1 object that retain/release keep balanced" {
    const pool = try pushTestPool();
    defer drainTestPool(pool);

    const obj = try nonNil(new("NSObject"));
    defer release(obj); // balances +new
    try testing.expect(msgSend(bool, obj, "isKindOfClass:", .{class("NSObject")}));
    try testing.expectEqual(@as(u64, 1), msgSend(u64, obj, "retainCount", .{}));
    try testing.expectEqual(obj, retain(obj));
    try testing.expectEqual(@as(u64, 2), msgSend(u64, obj, "retainCount", .{}));
    release(obj);
    try testing.expectEqual(@as(u64, 1), msgSend(u64, obj, "retainCount", .{}));
}

test "nsString round-trips UTF-8 including non-ASCII" {
    const pool = try pushTestPool();
    defer drainTestPool(pool);

    const text: [:0]const u8 = "Zetal \u{2713} h\u{e9}llo \u{1F3AF}";
    const ns = nsString(text);
    try testing.expectEqualStrings(text, fromNSString(ns));
    // -length counts UTF-16 code units: one per BMP character, two for U+1F3AF (a surrogate pair).
    try testing.expectEqual(@as(u64, 16), msgSend(u64, ns, "length", .{}));
    try testing.expectEqualStrings("", fromNSString(nsString("")));
}

test "msgSend passes and returns CG structs by value" {
    const pool = try pushTestPool();
    defer drainTestPool(pool);
    const value_class = class("NSValue");

    const size: CGSize = .{ .width = 3.5, .height = -4.25 };
    const size_value = try nonNil(msgSend(?Object, value_class, "valueWithSize:", .{size}));
    try testing.expectEqual(size, msgSend(CGSize, size_value, "sizeValue", .{}));

    const point: CGPoint = .{ .x = -1.5, .y = 2 };
    const point_value = try nonNil(msgSend(?Object, value_class, "valueWithPoint:", .{point}));
    try testing.expectEqual(point, msgSend(CGPoint, point_value, "pointValue", .{}));

    const rect: CGRect = .{ .origin = .{ .x = 1, .y = 2 }, .size = .{ .width = 30, .height = 40 } };
    const rect_value = try nonNil(msgSend(?Object, value_class, "valueWithRect:", .{rect}));
    // Returning 32 bytes needs objc_msgSend_stret on x86_64, which msgSend rejects at compile time.
    if (comptime builtin.target.cpu.arch != .x86_64) {
        try testing.expectEqual(rect, msgSend(CGRect, rect_value, "rectValue", .{}));
    }
}

test "msgSend carries scalar arguments and returns, and messaging nil yields nil" {
    const pool = try pushTestPool();
    defer drainTestPool(pool);
    const number_class = class("NSNumber");

    const d = try nonNil(msgSend(?Object, number_class, "numberWithDouble:", .{@as(f64, 2.5)}));
    try testing.expectEqual(@as(f64, 2.5), msgSend(f64, d, "doubleValue", .{}));
    const f = try nonNil(msgSend(?Object, number_class, "numberWithFloat:", .{@as(f32, -0.75)}));
    try testing.expectEqual(@as(f32, -0.75), msgSend(f32, f, "floatValue", .{}));
    const big = try nonNil(msgSend(?Object, number_class, "numberWithUnsignedLongLong:", .{@as(u64, 1 << 40)}));
    try testing.expectEqual(@as(u64, 1 << 40), msgSend(u64, big, "unsignedLongLongValue", .{}));
    const neg = try nonNil(msgSend(?Object, number_class, "numberWithInt:", .{@as(i32, -7)}));
    try testing.expectEqual(@as(i32, -7), msgSend(i32, neg, "intValue", .{}));
    const yes = try nonNil(msgSend(?Object, number_class, "numberWithBool:", .{true}));
    try testing.expect(msgSend(bool, yes, "boolValue", .{}));
    try testing.expect(msgSend(bool, d, "isEqualToNumber:", .{d}));
    try testing.expect(!msgSend(bool, d, "isEqualToNumber:", .{f}));

    try testing.expectEqual(null, msgSend(?Object, @as(?Object, null), "description", .{}));
}
||||||| empty tree
=======
const std = @import("std");

pub const Object = *anyopaque;
pub const Selector = *anyopaque;
pub const Class = *anyopaque;

pub extern "c" fn sel_registerName(str: [*:0]const u8) ?Selector;
pub extern "c" fn objc_getClass(name: [*:0]const u8) ?Class;
pub extern "c" fn objc_msgSend() void;
pub extern "c" fn object_getClass(obj: ?Object) ?Class;

/// Comptime-cached selector. First call registers, subsequent calls are free.
/// Each unique `name` gets its own static storage via comptime monomorphization.
pub fn sel(comptime name: [:0]const u8) Selector {
    return sel_registerName(name.ptr) orelse {
        std.debug.panic("Failed to register selector: {s}", .{name});
    };
}

pub fn class(comptime name: [:0]const u8) Class {
    return objc_getClass(name.ptr) orelse {
        std.debug.panic("Failed to look up class: {s}", .{name});
    };
}

/// Send an Objective-C message with comptime-typed signature.
///
/// `Ret`           - the return type of the message
/// `target`        - receiver (Object or Class, optional or not)
/// `selector_name` - the selector as a string literal (gets cached)
/// `args`          - tuple of arguments after `self` and `_cmd`
///
/// Example:
///   const tex = msgSend(?Object, descriptor, "texture", .{});
///   msgSend(void, encoder, "setVertexBuffer:offset:atIndex:", .{ buf, 0, 1 });
pub inline fn msgSend(
    comptime Ret: type,
    target: anytype,
    comptime selector_name: [:0]const u8,
    args: anytype,
) Ret {
    const Args = @TypeOf(args);
    const args_info = @typeInfo(Args);
    if (args_info != .@"struct" or !args_info.@"struct".is_tuple) {
        @compileError("msgSend args must be a tuple, got " ++ @typeName(Args));
    }
    const Target = @TypeOf(target);
    const FnType = BuildMsgSendFn(Ret, Target, Args);
    const msg: FnType = @ptrCast(&objc_msgSend);
    return @call(.auto, msg, .{ target, sel(selector_name) } ++ args);
}

fn BuildMsgSendFn(comptime Ret: type, comptime Target: type, comptime Args: type) type {
    const arg_types = @typeInfo(Args).@"struct".field_types;
    const total_params = arg_types.len + 2;

    var param_types: [total_params]type = undefined;
    var param_attrs: [total_params]std.lang.Type.Fn.ParamAttributes = undefined;

    param_types[0] = Target;
    param_types[1] = Selector;
    param_attrs[0] = .{};
    param_attrs[1] = .{};

    inline for (arg_types, 0..) |T, i| {
        param_types[i + 2] = T;
        param_attrs[i + 2] = .{};
    }

    const FnType = @Fn(
        &param_types,
        &param_attrs,
        Ret,
        .{ .@"callconv" = std.lang.CallingConvention.c },
    );
    return *const FnType;
}

pub fn release(obj: ?Object) void {
    if (obj) |o| msgSend(void, o, "release", .{});
}

pub fn retain(obj: ?Object) ?Object {
    if (obj) |o| _ = msgSend(?Object, o, "retain", .{});
    return obj;
}

pub fn createNSString(content: [:0]const u8) ?Object {
    return msgSend(?Object, class("NSString"), "stringWithUTF8String:", .{content.ptr});
}

pub const CGRect = extern struct {
    origin_x: f64,
    origin_y: f64,
    width: f64,
    height: f64,
};
>>>>>>> Zetal/main
