const std = @import("std");

pub const Object = *anyopaque;
pub const Selector = *anyopaque;

// The raw C imports
pub extern "c" fn sel_registerName(str: [*:0]const u8) ?Selector;
pub extern "c" fn objc_getClass(name: [*]const u8) ?Object;
pub extern "c" fn objc_msgSend(self: ?Object, op: ?Selector, ...) ?Object;

/// Helper to get a Selector (like a method name)
pub fn getSelector(name: [:0]const u8) ?Selector {
    return sel_registerName(name);
}

/// Helper to create an NSString from a Zig slice
/// We moved this here because it's purely a helper, not core Engine logic.
pub fn createNSString(content: []const u8) ?Object {
    const ns_string_class = objc_getClass("NSString");
    if (ns_string_class == null) return null;

    const alloc_sel = getSelector("alloc");
    const init_sel = getSelector("initWithBytes:length:encoding:");

    // 1. Allocate
    // We can use the raw msgSend here because we are inside the "unsafe" file
    const raw_obj = objc_msgSend(ns_string_class, alloc_sel);

    // 2. Initialize
    const InitFn = *const fn (?Object, ?Selector, [*]const u8, usize, u64) callconv(.c) ?Object;
    const init_msg_send: InitFn = @ptrCast(&objc_msgSend);

    return init_msg_send(raw_obj, init_sel, content.ptr, content.len, 4); // 4 is UTF-8
}
