pub const MouseButton = enum {
    left,
    right,
    middle,
    wheel_up,
    wheel_down,
    wheel_left,
    wheel_right,
    backward,
    forward,
    none,
};

pub const MouseMsg = struct {
    x: i32,
    y: i32,
    button: MouseButton,
};
