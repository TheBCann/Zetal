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
