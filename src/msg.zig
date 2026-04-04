const key = @import("key.zig");
const mouse = @import("mouse.zig");

pub const WindowSizeMsg = struct {
    width: u16,
    height: u16,
};

pub const Msg = union(enum) {
    key_press: key.KeyMsg,
    mouse_click: mouse.MouseMsg,
    mouse_release: mouse.MouseMsg,
    mouse_wheel: mouse.MouseMsg,
    mouse_motion: mouse.MouseMsg,
    window_size: WindowSizeMsg,
    focus,
    blur,
    quit,
    interrupt,
};
