# zchomptic

A Zig re-implementation of [charmbracelet/bubbletea](https://github.com/charmbracelet/bubbletea).

## Requirements

- Zig 0.15.2 or later

## Build & Run

```sh
zig build        # build
zig build run    # run the example
zig build test   # run tests
```

## Usage

zchomptic is a TUI framework based on the [Elm Architecture](https://guide.elm-lang.org/architecture/).
Implement three methods — **init / update / view** — and you have a working terminal UI.

### 1. Define a Model

Create a struct with `init`, `update`, and `view` methods.

```zig
const std = @import("std");
const tea = @import("zchomptic");

const MyModel = struct {
    count: i32 = 0,

    /// Called once at startup. Return an initial Cmd, or null for none.
    pub fn init(self: *MyModel) ?tea.Cmd {
        _ = self;
        return null;
    }

    /// Called for every Msg. Mutate state in-place and return the next Cmd.
    pub fn update(self: *MyModel, m: tea.Msg) ?tea.Cmd {
        switch (m) {
            .key_press => |k| switch (k.key) {
                .char => |c| if (c == 'q') return tea.cmd.quit,
                .code => |code| switch (code) {
                    .up   => self.count += 1,
                    .down => self.count -= 1,
                    else  => {},
                },
                .ctrl => |c| if (c == 3) return tea.cmd.quit, // Ctrl+C
            },
            .interrupt => return tea.cmd.quit,
            else => {},
        }
        return null;
    }

    /// Render the current state to the given writer.
    pub fn view(self: *MyModel, writer: std.io.AnyWriter) !void {
        try writer.print("Count: {d}\nPress ↑/↓ to change, q to quit.\n", .{self.count});
    }
};
```

### 2. Run the Program

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var m = MyModel{};
    var prog = tea.Program.init(gpa.allocator(), tea.model(&m));
    defer prog.deinit();

    try prog.run();
}
```

### Msg variants

| Tag | Description |
|---|---|
| `.key_press` | Keyboard input (`tea.key.KeyMsg`) |
| `.mouse_click` / `.mouse_release` / `.mouse_wheel` / `.mouse_motion` | Mouse events |
| `.window_size` | Terminal resize (`.width`, `.height`) |
| `.focus` / `.blur` | Terminal focus gained / lost |
| `.quit` | Quit requested |
| `.interrupt` | Ctrl+C or Ctrl+D |

### Key variants

The `.key` field inside a `key_press` message is a tagged union:

| Variant | Description |
|---|---|
| `.char(u21)` | Printable Unicode codepoint |
| `.code(KeyCode)` | Special key: `.up` `.down` `.left` `.right` `.enter` `.backspace` `.escape` `.f1`–`.f12`, etc. |
| `.ctrl(u8)` | Control character (`3` = Ctrl+C, `4` = Ctrl+D, …) |

Modifier keys are available as `k.mod.shift`, `k.mod.alt`, `k.mod.ctrl`, and `k.mod.meta`.

### Cmd values

| Value | Effect |
|---|---|
| `null` / `tea.cmd.none` | No-op |
| `tea.cmd.quit` | Exit the program |
| Custom function | Any `*const fn () tea.Msg` function pointer |

Example of a custom Cmd:

```zig
fn doWork() tea.Msg {
    // perform some work ...
    return .quit; // return a Msg when done
}

// Inside update:
return doWork; // return the function pointer as a Cmd
```

