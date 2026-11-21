---
name: alfalfadesktop-cli
description: Inspect and test a local macOS app from a VS Code agent using the AlfalfaDesktop CLI. Use for accessibility trees, window captures, and approved background actions while developing a desktop app.
---

# AlfalfaDesktop CLI

Use the terminal tool in a local VS Code agent session on macOS 14 or later. Use the executable the user
already installed, identified by its absolute path. If it is missing, point the user to the
[official releases](https://github.com/0sw2ld0/AlfalfaDesktop/releases) for the correct architecture and
`SHA256SUMS`. The executables are named `alfalfa-desktop-macos-arm64` and `alfalfa-desktop-macos-x64`.
Prefer the path the user provides when there is more than one installation.

## Inspect and act

1. Run `"$desktop" --version`, `"$desktop" permissions`, and `"$desktop" list`, where `desktop` is the
   absolute path to the executable. Select the requested app by bundle identifier or name and use its
   current PID. Ask which window to use if the target is ambiguous.
2. Review the requested scope with the user before inspecting or acting. Keep VS Code terminal approvals
   for the individual commands. The CLI's `--approve` acknowledges the specific operation and only applies
   to the current invocation.
3. Inspect the authorized window. The examples use variables for the actual PID and zero-based window index
   identified for this task.

   ```sh
   "$desktop" inspect --pid="$pid" --window="$window" --approve
   ```

   Read `title`, `tree`, and `elements` from stdout. Add `--capture` only when a window image is part of
   the task. The JSON response returns the local PNG path. Keep the image local unless the user asks to share it.
4. Take the approved action using the latest element `path` and its matching `role`, or coordinates in points
   from the window's upper-left corner. Use background input by default so VS Code can keep the focus. For a
   click on a button, substitute the values from the inspection:

   ```sh
   "$desktop" action --pid="$pid" --window="$window" --kind=click --path="$path" --role="$role" --approve
   ```

   For a coordinate click, replace `--path` and `--role` with `--x="$x" --y="$y"`. Reinspect after the
   action when you need to verify its effect. If the window or element changed, inspect again before deciding
   what to do. Stop when the CLI refuses the target or the user declines the operation.

## macOS permissions

macOS may attribute Accessibility and Screen Recording to the app responsible for launching the command.
If permission is missing, ask the user to run `"$desktop" permissions --request --approve` and use the
system prompt or System Settings. Accessibility supports inspection and actions. Screen Recording is needed
for window images. If the login session is locked, ask the user to unlock it before retrying the window check.
