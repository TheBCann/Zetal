//! NSApplication bootstrap and quit-request delegate, the non-blocking per-frame event pump, and the pure-data input state it fills.

const std = @import("std");
const objc = @import("../objc.zig");

// ============================================================
// APPKIT CONSTANTS (SDK headers: NSEvent.h, NSRunningApplication.h, NSRunLoop.h)
// ============================================================

/// Virtual key codes (kVK_ANSI_*) the game reads by name; every other code still lands in `Input.keys`.
pub const KeyCode = enum(u16) {
    a = 0x00,
    s = 0x01,
    d = 0x02,
    q = 0x0C,
    w = 0x0D,
    e = 0x0E,
    space = 0x31,
    escape = 0x35,
    _,
};

/// NSEventType values the event pump tells apart; every other type stays representable.
pub const EventType = enum(u64) {
    left_mouse_down = 1,
    left_mouse_up = 2,
    right_mouse_down = 3,
    right_mouse_up = 4,
    mouse_moved = 5,
    left_mouse_dragged = 6,
    right_mouse_dragged = 7,
    key_down = 10,
    key_up = 11,
    flags_changed = 12,
    app_kit_defined = 13,
    other_mouse_down = 25,
    other_mouse_up = 26,
    other_mouse_dragged = 27,
    _,
};

/// The mouse buttons `Input` tracks.
pub const MouseButton = enum { left, right };

const NSApplicationActivationPolicyRegular: i64 = 0;
const NSEventMaskAny: u64 = std.math.maxInt(u64);
const NSEventSubtypeApplicationDeactivated: i16 = 2;

// The Foundation global itself (the string "kCFRunLoopDefaultMode"); linking needs Foundation.
extern const NSDefaultRunLoopMode: objc.Object;

// ============================================================
// INPUT — what the game reads each frame (pure data, unit-tested)
// ============================================================

/// Keyboard and mouse state built from events. Held state lasts until the matching up event (or
/// focus loss); mouse deltas and `*_pressed` edges cover one frame (see `beginFrame`).
pub const Input = struct {
    /// Held state per virtual key code.
    keys: [256]bool = @splat(false),
    /// Mouse motion since `beginFrame`: summed NSEvent deltaX/deltaY (+x right, +y down).
    mouse_dx: f32 = 0,
    mouse_dy: f32 = 0,
    /// Held state of each button, and whether it went down since `beginFrame`.
    mouse_left: bool = false,
    mouse_left_pressed: bool = false,
    mouse_right: bool = false,
    mouse_right_pressed: bool = false,
    /// Latched by Escape; never cleared.
    quit_requested: bool = false,

    /// Starts a frame: clears the mouse deltas and pressed edges, keeps held keys and buttons.
    /// Call it once per frame, before the first `App.pollEvents` (main pumps twice per frame).
    pub fn beginFrame(self: *Input) void {
        self.mouse_dx = 0;
        self.mouse_dy = 0;
        self.mouse_left_pressed = false;
        self.mouse_right_pressed = false;
    }

    /// Records a key press; Escape also requests quit. Codes outside `keys` are ignored.
    pub fn keyDown(self: *Input, code: u16) void {
        if (code >= self.keys.len) return;
        self.keys[code] = true;
        if (code == @backingInt(KeyCode.escape)) self.quit_requested = true;
    }

    /// Records a key release. Codes outside `keys` are ignored.
    pub fn keyUp(self: *Input, code: u16) void {
        if (code >= self.keys.len) return;
        self.keys[code] = false;
    }

    /// Adds one motion event's delta to this frame's totals.
    pub fn mouseMoved(self: *Input, dx: f64, dy: f64) void {
        self.mouse_dx += @as(f32, @floatCast(dx));
        self.mouse_dy += @as(f32, @floatCast(dy));
    }

    /// Records a button transition; a press also sets the button's pressed edge for this frame,
    /// so a click that goes down and up between two frames still fires.
    pub fn mouseButton(self: *Input, button: MouseButton, down: bool) void {
        switch (button) {
            .left => {
                self.mouse_left = down;
                if (down) self.mouse_left_pressed = true;
            },
            .right => {
                self.mouse_right = down;
                if (down) self.mouse_right_pressed = true;
            },
        }
    }

    /// Releases every held key and button but keeps `quit_requested`. Up events go to the active
    /// app only, so anything held while focus leaves (Cmd-Tab) would otherwise stay down.
    pub fn focusLost(self: *Input) void {
        self.keys = @splat(false);
        self.mouse_left = false;
        self.mouse_right = false;
    }

    /// True while `key` is held.
    pub fn isDown(self: *const Input, key: KeyCode) bool {
        const code = @backingInt(key);
        return code < self.keys.len and self.keys[code];
    }
};

// ============================================================
// APP — NSApplication without -run: the game loop pumps events itself
// ============================================================

/// The shared NSApplication plus the input its events feed. Main-thread only; call everything
/// inside an autorelease pool (events are autoreleased).
pub const App = struct {
    /// `+[NSApplication sharedApplication]` (shared; never released).
    ns_app: objc.Object,
    /// Filled by `pollEvents`; the game calls `input.beginFrame()` once per frame.
    input: Input = .{},

    /// Creates NSApp as a regular foreground app with the quit-request delegate, and finishes
    /// launching. Call once, before any window.
    pub fn init() App {
        const ns_app = objc.msgSend(?objc.Object, objc.class("NSApplication"), "sharedApplication", .{}) orelse
            @panic("+[NSApplication sharedApplication] returned nil");
        // Unbundled executables start Prohibited (no Dock icon, no key window, no activation). The BOOL
        // only reports whether the policy changed, so NO is not an error.
        _ = objc.msgSend(bool, ns_app, "setActivationPolicy:", .{NSApplicationActivationPolicyRegular});
        // Before finishLaunching, as in a normal Cocoa launch. See applicationShouldTerminate.
        objc.msgSend(void, ns_app, "setDelegate:", .{appDelegate()});
        // -run would call this; a hand-rolled event loop must call it once before the first pump.
        objc.msgSend(void, ns_app, "finishLaunching", .{});
        return .{ .ns_app = ns_app };
    }

    /// Brings the app and its key window to the front so they get keyboard input.
    pub fn activate(self: *App) void {
        // Not -activate: that one is cooperative and may be refused when launched from a terminal.
        objc.msgSend(void, self.ns_app, "activateIgnoringOtherApps:", .{true});
    }

    /// Drains every queued event without blocking, feeds `input`, and hands everything except key
    /// events on to AppKit (-sendEvent:). Does not call `input.beginFrame()`.
    pub fn pollEvents(self: *App) void {
        while (objc.msgSend(?objc.Object, self.ns_app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
            NSEventMaskAny,
            @as(?objc.Object, null), // nil date: return at once when the queue is empty
            NSDefaultRunLoopMode,
            true,
        })) |handle| {
            const event: NSEvent = .{ .handle = handle };
            if (routeEvent(&self.input, event.eventType(), event)) {
                objc.msgSend(void, self.ns_app, "sendEvent:", .{handle});
            }
        }
    }

    /// True while the app is hidden (Cmd-H); its windows then report isVisible == NO.
    pub fn isHidden(self: *const App) bool {
        return objc.msgSend(bool, self.ns_app, "isHidden", .{});
    }

    /// True once the player asked to quit (Escape) or the system did (the Dock's Quit, logout, a quit
    /// Apple Event: see applicationShouldTerminate).
    pub fn shouldQuit(self: *const App) bool {
        return self.input.quit_requested or terminate_requested;
    }
};

// ============================================================
// SYSTEM QUIT REQUESTS — the app delegate, built at run time
// ============================================================

// libobjc's class-building API (objc/runtime.h). The IMP parameter is typed as the one method added
// below, so the compiler checks its C signature.
const ShouldTerminateImp = *const fn (objc.Object, objc.Selector, ?objc.Object) callconv(.c) u64;
extern "c" fn objc_lookUpClass(name: [*:0]const u8) ?objc.Class;
extern "c" fn objc_allocateClassPair(superclass: objc.Class, name: [*:0]const u8, extra_bytes: usize) ?objc.Class;
extern "c" fn objc_registerClassPair(cls: objc.Class) void;
extern "c" fn class_addMethod(cls: objc.Class, name: objc.Selector, imp: ShouldTerminateImp, types: [*:0]const u8) bool;

const DELEGATE_CLASS_NAME = "ZetalAppDelegate";
// NSApplicationTerminateReply (NSApplication.h): -terminate: gives up and returns.
const NSTerminateCancel: u64 = 0;

/// Set by the delegate when AppKit asks to terminate; read by `App.shouldQuit`. Main-thread only.
var terminate_requested = false;
/// The delegate (+1, kept for the life of the process: NSApplication holds its delegate weakly).
var app_delegate: ?objc.Object = null;

/// The delegate's -applicationShouldTerminate:. Without a delegate, -[NSApplication terminate:] (the
/// Dock's Quit, logout, `osascript -e 'quit app ...'`) ends in exit() from inside pollEvents, so none
/// of main's defers would run (teardown, the leak check, the smoke summary). This flags a quit for
/// the game loop instead and cancels the termination.
fn applicationShouldTerminate(_: objc.Object, _: objc.Selector, _: ?objc.Object) callconv(.c) u64 {
    terminate_requested = true;
    // Not NSTerminateLater: that spins a modal run loop inside -terminate: until
    // -replyToApplicationShouldTerminate:, which would trap the hand-rolled loop. The price of Cancel:
    // during logout or shutdown macOS reports that Zetal cancelled it, and the user tries again
    // once the game has quit (SDL and GLFW pay the same).
    return NSTerminateCancel;
}

/// Returns the delegate class, an NSObject subclass that answers -applicationShouldTerminate:,
/// registering it with the runtime on first use.
fn delegateClass() objc.Class {
    if (objc_lookUpClass(DELEGATE_CLASS_NAME)) |cls| return cls;
    const cls = objc_allocateClassPair(objc.class("NSObject"), DELEGATE_CLASS_NAME, 0) orelse
        @panic("objc_allocateClassPair(\"" ++ DELEGATE_CLASS_NAME ++ "\") failed");
    // Returns an NSUInteger (Q) and takes self (@), _cmd (:) and the sender (@).
    if (!class_addMethod(cls, objc.sel("applicationShouldTerminate:"), &applicationShouldTerminate, "Q@:@")) {
        @panic("class_addMethod(applicationShouldTerminate:) failed");
    }
    objc_registerClassPair(cls);
    return cls;
}

/// Returns the process's app delegate, creating it on first use.
fn appDelegate() objc.Object {
    if (app_delegate) |delegate| return delegate;
    const delegate = objc.msgSend(?objc.Object, delegateClass(), "new", .{}) orelse
        @panic("+[" ++ DELEGATE_CLASS_NAME ++ " new] returned nil");
    app_delegate = delegate;
    return delegate;
}

// ============================================================
// EVENT ROUTING
// ============================================================

/// An NSEvent with the accessors `routeEvent` uses. NSEvent raises (which aborts a Zig process) when
/// sent an accessor its type lacks, so `routeEvent` only calls each one for the types that define it.
const NSEvent = struct {
    handle: objc.Object,

    fn eventType(self: NSEvent) EventType {
        return @fromBackingInt(objc.msgSend(u64, self.handle, "type", .{}));
    }

    fn keyCode(self: NSEvent) u16 {
        return objc.msgSend(u16, self.handle, "keyCode", .{});
    }

    fn deltaX(self: NSEvent) f64 {
        return objc.msgSend(f64, self.handle, "deltaX", .{});
    }

    fn deltaY(self: NSEvent) f64 {
        return objc.msgSend(f64, self.handle, "deltaY", .{});
    }

    fn subtype(self: NSEvent) i16 {
        return objc.msgSend(i16, self.handle, "subtype", .{});
    }
};

/// Applies one event to `input` and returns whether AppKit should see it too. `event` is an `NSEvent`,
/// or in tests any value with the same accessors.
fn routeEvent(input: *Input, event_type: EventType, event: anytype) bool {
    switch (event_type) {
        // Kept from AppKit: no responder handles game keys, so -sendEvent: would beep on every key-down.
        .key_down => {
            input.keyDown(event.keyCode());
            return false;
        },
        .key_up => {
            input.keyUp(event.keyCode());
            return false;
        },
        // While a button is held, motion arrives as *Dragged rather than MouseMoved; reading only
        // MouseMoved froze mouse look for as long as the fire button was down.
        .mouse_moved, .left_mouse_dragged, .right_mouse_dragged, .other_mouse_dragged => {
            input.mouseMoved(event.deltaX(), event.deltaY());
        },
        .left_mouse_down => input.mouseButton(.left, true),
        .left_mouse_up => input.mouseButton(.left, false),
        .right_mouse_down => input.mouseButton(.right, true),
        .right_mouse_up => input.mouseButton(.right, false),
        // On deactivation (Cmd-Tab) the up events for anything still held go to the next app.
        .app_kit_defined => if (event.subtype() == NSEventSubtypeApplicationDeactivated) input.focusLost(),
        else => {},
    }
    return true;
}

// ============================================================
// TESTS — Input state and event routing (no AppKit, no window server)
// ============================================================

const testing = std.testing;

fn codeOf(key: KeyCode) u16 {
    return @backingInt(key);
}

test "beginFrame clears deltas and pressed edges but keeps held state" {
    var input: Input = .{};
    input.keyDown(codeOf(.w));
    input.mouseButton(.left, true);
    input.mouseButton(.right, true);
    input.mouseMoved(3, -2);
    try testing.expect(input.mouse_left_pressed and input.mouse_right_pressed);

    input.beginFrame();

    try testing.expectEqual(0, input.mouse_dx);
    try testing.expectEqual(0, input.mouse_dy);
    try testing.expect(!input.mouse_left_pressed and !input.mouse_right_pressed);
    try testing.expect(input.mouse_left and input.mouse_right);
    try testing.expect(input.isDown(.w));
}

test "a click that goes down and up within one frame keeps its pressed edge" {
    var input: Input = .{};
    input.mouseButton(.left, true);
    input.mouseButton(.left, false);
    try testing.expect(input.mouse_left_pressed);
    try testing.expect(!input.mouse_left);
    try testing.expect(!input.mouse_right_pressed); // buttons are independent
}

test "escape latches quit_requested and other keys do not" {
    var input: Input = .{};
    input.keyDown(codeOf(.w));
    input.keyDown(codeOf(.space));
    try testing.expect(!input.quit_requested);

    input.keyDown(codeOf(.escape));
    input.keyUp(codeOf(.escape));
    input.beginFrame();

    try testing.expect(input.quit_requested);
}

test "mouse deltas accumulate across events until beginFrame" {
    var input: Input = .{};
    input.mouseMoved(1.5, -2.0);
    input.mouseMoved(0.25, 0.5);
    input.mouseMoved(-0.75, 4.0);
    try testing.expectEqual(1.0, input.mouse_dx);
    try testing.expectEqual(2.5, input.mouse_dy);
}

test "key codes outside the table are ignored" {
    var input: Input = .{};
    input.keyDown(256);
    input.keyDown(std.math.maxInt(u16));
    input.keyUp(300);
    try testing.expectEqual(Input{}, input);
    try testing.expect(!input.isDown(@fromBackingInt(256)));

    input.keyDown(255); // the last valid slot
    try testing.expect(input.keys[255]);
    input.keyUp(255);
    try testing.expect(!input.keys[255]);
}

test "focusLost releases held keys and buttons but keeps quit_requested" {
    var input: Input = .{};
    input.keyDown(codeOf(.w));
    input.keyDown(codeOf(.d));
    input.mouseButton(.left, true);
    input.mouseButton(.right, true);
    input.keyDown(codeOf(.escape));

    input.focusLost();

    for (input.keys) |held| try testing.expect(!held);
    try testing.expect(!input.mouse_left and !input.mouse_right);
    try testing.expect(input.quit_requested);
}

/// Stands in for an NSEvent. An accessor whose field is null panics, the way NSEvent raises for a
/// selector its type does not support, so a routing slip fails the test loudly.
const FakeEvent = struct {
    key_code: ?u16 = null,
    delta: ?[2]f64 = null,
    sub: ?i16 = null,

    fn keyCode(self: FakeEvent) u16 {
        return self.key_code.?;
    }

    fn deltaX(self: FakeEvent) f64 {
        return self.delta.?[0];
    }

    fn deltaY(self: FakeEvent) f64 {
        return self.delta.?[1];
    }

    fn subtype(self: FakeEvent) i16 {
        return self.sub.?;
    }
};

test "key events update Input and are kept from AppKit" {
    var input: Input = .{};
    try testing.expect(!routeEvent(&input, .key_down, FakeEvent{ .key_code = codeOf(.w) }));
    try testing.expect(input.isDown(.w));
    try testing.expect(!routeEvent(&input, .key_up, FakeEvent{ .key_code = codeOf(.w) }));
    try testing.expect(!input.isDown(.w));
    try testing.expect(!routeEvent(&input, .key_down, FakeEvent{ .key_code = codeOf(.escape) }));
    try testing.expect(input.quit_requested);
}

test "moved and every dragged event feed mouse look and reach AppKit" {
    var input: Input = .{};
    const motion = [_]EventType{ .mouse_moved, .left_mouse_dragged, .right_mouse_dragged, .other_mouse_dragged };
    for (motion) |event_type| {
        try testing.expect(routeEvent(&input, event_type, FakeEvent{ .delta = .{ 1.0, -0.5 } }));
    }
    try testing.expectEqual(4.0, input.mouse_dx);
    try testing.expectEqual(-2.0, input.mouse_dy);
}

test "left and right button events set held state and edges and reach AppKit" {
    var input: Input = .{};
    try testing.expect(routeEvent(&input, .left_mouse_down, FakeEvent{}));
    try testing.expect(input.mouse_left and input.mouse_left_pressed);
    try testing.expect(routeEvent(&input, .left_mouse_up, FakeEvent{}));
    try testing.expect(!input.mouse_left and input.mouse_left_pressed);

    try testing.expect(routeEvent(&input, .right_mouse_down, FakeEvent{}));
    try testing.expect(input.mouse_right and input.mouse_right_pressed);
    try testing.expect(routeEvent(&input, .right_mouse_up, FakeEvent{}));
    try testing.expect(!input.mouse_right and input.mouse_right_pressed);
}

test "app deactivation releases held input; other AppKit-defined events do not" {
    var input: Input = .{};
    input.keyDown(codeOf(.w));
    input.mouseButton(.left, true);

    const activated: i16 = 1; // NSEventSubtypeApplicationActivated
    try testing.expect(routeEvent(&input, .app_kit_defined, FakeEvent{ .sub = activated }));
    try testing.expect(input.isDown(.w) and input.mouse_left);

    try testing.expect(routeEvent(&input, .app_kit_defined, FakeEvent{ .sub = NSEventSubtypeApplicationDeactivated }));
    try testing.expect(!input.isDown(.w) and !input.mouse_left);
}

test "other event types reach AppKit and leave Input untouched" {
    var input: Input = .{};
    const scroll_wheel: EventType = @fromBackingInt(22); // NSEventTypeScrollWheel, unnamed here
    const others = [_]EventType{ .flags_changed, .other_mouse_down, .other_mouse_up, scroll_wheel };
    for (others) |event_type| try testing.expect(routeEvent(&input, event_type, FakeEvent{}));
    try testing.expectEqual(Input{}, input);
}

test "the app delegate cancels AppKit's terminate and turns it into a quit request" {
    // libobjc only: the delegate is sent the message directly, as -[NSApplication terminate:] would.
    const pool = @import("autorelease.zig").AutoreleasePool.init();
    defer pool.deinit();
    const cls = delegateClass();
    try testing.expectEqual(cls, delegateClass()); // registered once, then looked up
    const delegate = objc.msgSend(?objc.Object, cls, "new", .{}) orelse return error.TestUnexpectedResult;
    defer objc.release(delegate);
    try testing.expect(objc.msgSend(bool, delegate, "respondsToSelector:", .{objc.sel("applicationShouldTerminate:")}));

    const placeholder = objc.new("NSObject") orelse return error.TestUnexpectedResult; // shouldQuit never messages it
    defer objc.release(placeholder);
    const app: App = .{ .ns_app = placeholder };
    terminate_requested = false;
    defer terminate_requested = false;
    try testing.expect(!app.shouldQuit());

    const reply = objc.msgSend(u64, delegate, "applicationShouldTerminate:", .{@as(?objc.Object, null)});
    try testing.expectEqual(NSTerminateCancel, reply);
    try testing.expect(terminate_requested);
    try testing.expect(app.shouldQuit());
}
