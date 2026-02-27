const std = @import("std");

pub const Object = *anyopaque;
pub const Selector = *anyopaque;

pub extern "c" fn sel_registerName(str: [*:0]const u8) ?Selector;
pub extern "c" fn objc_getClass(name: [*]const u8) ?Object;
pub extern "c" fn objc_msgSend(self: ?Object, op: ?Selector, ...) ?Object;

pub fn getSelector(name: [:0]const u8) ?Selector {
    const sel = sel_registerName(name);
    if (sel == null) {
        std.debug.print("ERROR: Failed to register selector: {s}\n", .{name});
    }
    return sel;
}

// CHANGED: Uses robust factory method 'stringWithUTF8String:'
// Requires [:0]const u8 (null-terminated slice)
pub fn createNSString(content: [:0]const u8) ?Object {
    const ns_string_class = objc_getClass("NSString");
    if (ns_string_class == null) return null;

    const sel = getSelector("stringWithUTF8String:");

    // Signature: (Class, SEL, const char*) -> NSString*
    const FactoryFn = *const fn (?Object, ?Selector, [*:0]const u8) callconv(.c) ?Object;
    const factory_msg: FactoryFn = @ptrCast(&objc_msgSend);

    const raw_string = factory_msg(ns_string_class, sel, content.ptr);

    if (raw_string == null) {
        std.debug.print("ERROR: NSString.stringWithUTF8String returned nil for '{s}'\n", .{content});
    }

    return raw_string;
}

pub const CGRect = extern struct {
    origin_x: f64,
    origin_y: f64,
    width: f64,
    height: f64,
};
