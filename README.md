# AlfalfaDesktop

[Español](README.es.md)

AlfalfaDesktop extracts AlfalfaCode's native macOS desktop controller into a Swift package. It lists running apps, inspects
their accessibility trees, and performs explicitly approved actions. Background input uses a virtual pointer and targets
the selected application.

## Download

AlfalfaDesktop requires macOS 14 or later. Choose the executable for your Mac and verify it against the checksum
manifest before running it.

| Mac | Download |
| --- | --- |
| Apple Silicon | [alfalfa-desktop-macos-arm64](https://github.com/0sw2ld0/AlfalfaDesktop/releases/latest/download/alfalfa-desktop-macos-arm64) |
| Intel | [alfalfa-desktop-macos-x64](https://github.com/0sw2ld0/AlfalfaDesktop/releases/latest/download/alfalfa-desktop-macos-x64) |

[SHA256SUMS](https://github.com/0sw2ld0/AlfalfaDesktop/releases/latest/download/SHA256SUMS)

For example, after downloading the Apple Silicon binary and manifest from the same release:

```sh
grep '  alfalfa-desktop-macos-arm64$' SHA256SUMS | shasum -a 256 -c
chmod +x alfalfa-desktop-macos-arm64
./alfalfa-desktop-macos-arm64 --version
```

## Build and use the CLI

Build with Swift 5.10 or later on macOS 14 or later.

```sh
swift build
swift test

desktop=.build/debug/alfalfa-desktop
"$desktop" --version
"$desktop" list
"$desktop" permissions
"$desktop" inspect --pid=12345 --window=0 --approve
"$desktop" action --pid=12345 --window=0 --kind=click --path=1 --role=AXButton --approve
```

Use the PID from `list` and the element path and role from `inspect`. The window index defaults to `0`.
`inspect --capture --approve` adds a capture path when macOS permits it. Capture files are stored in a private temporary
directory and should be removed after use. `permissions --request --approve` asks macOS to request the required access.
macOS grants Accessibility and Screen Recording separately to the responsible app. In production, use a signed host app
for a stable permission identity. The CLI's `--approve` authorizes one invocation and cannot grant macOS permissions.

Supported actions include clicks, scrolling, drag, hover, text and key input, setting an accessibility value, menu
selection, and explicit focus. Use only the target app's documented capabilities. App restrictions apply before both
CLI and PACAI calls. A target window is checked again after approval.

To build an optimized executable from a local AlfalfaDesktop checkout, run the following from the
repository root. SwiftPM builds for the current Mac.

```sh
swift build -c release
desktop="$(swift build -c release --show-bin-path)/alfalfa-desktop"
printf '%s\n' "$desktop"
"$desktop" --version
```

Give the resulting absolute path to your VS Code agent if you want it to use that build.

## Use the CLI from a VS Code agent

1. Download and verify the executable for your Mac. In the VS Code terminal, point to it with its full path
   and run the following commands from a local macOS workspace:

   ```sh
   desktop="$HOME/Downloads/alfalfa-desktop-macos-arm64" # Use alfalfa-desktop-macos-x64 on Intel.
   chmod +x "$desktop"
   "$desktop" --version
   "$desktop" permissions
   "$desktop" list
   ```

2. Open a new, empty TextEdit document and leave VS Code in front. If Accessibility is missing, run
   `"$desktop" permissions --request --approve` yourself and grant it to the responsible app shown by macOS.
   Screen Recording is needed only when you request window images with `inspect --capture`.

3. Start a local agent chat with terminal access and give it this prompt. Replace the path with the one you
   verified. Review each terminal command when VS Code asks for approval.

   > Use `/absolute/path/to/alfalfa-desktop-macos-arm64` to check my empty TextEdit document. Run `list` to
   > find TextEdit's PID. Ask me before running `inspect --pid=PID --window=0 --approve` and report the title. If the
   > inspection finds the blank test document, choose a point inside its editing area from the accessibility
   > tree. Ask me before running `action --pid=PID --window=0 --kind=click --x=X --y=Y --approve`. Leave
   > VS Code in front and stop after the click.

VS Code can also load the [`alfalfadesktop-cli` workspace skill](.github/skills/alfalfadesktop-cli/SKILL.md).
In a local Copilot chat, use `/alfalfadesktop-cli` followed by the name of the app and what you want to verify.

The local agent invokes the executable through its terminal tool. Use `--approve` on the specific inspection or
action you reviewed. See [VS Code agent tools](https://code.visualstudio.com/docs/agents/run/tools).

## PACAI over stdio

Run `alfalfa-desktop pacai` and exchange PACAI 0.3 JSONL records over its input and output streams. Send a client
`hello` first. Each `input` has one structured command block with this data shape:

```json
{
  "type": "structured",
  "schema": "urn:alfalfadesktop:command:v1",
  "data": {
    "command": "inspect",
    "options": { "pid": "12345", "window": "0", "capture": "true" }
  }
}
```

Use `list`, `inspect`, `action`, or `permissions` as the command. Option names are the CLI flags without the leading
dashes. A sensitive command emits `approval_request` with a canonical digest and accepts only `once` approval via
`approval_result.reply_to`. An eligible `interrupt` cancels a pending approval and closes the run. Native operations run
synchronously once approved. Results are structured blocks in `tool_end` and end with `run_finished`. Disconnect
discards pending approvals. This local adapter does not implement network transport, reattachment, or an MCP server.

## Real macOS fixture

`Tests/Fixtures/DesktopFixture.swift` opens a separate AppKit counter and records its focus during actions.
`Scripts/test-desktop.mjs` can verify both the CLI and PACAI against it. The example performs one approved click through each interface and checks that a denied or interrupted request does not change the count.

```sh
fixture_dir=$(mktemp -d)
swiftc Tests/Fixtures/DesktopFixture.swift -o "$fixture_dir/AlfalfaDesktopFixture"
touch "$fixture_dir/focus.jsonl"
"$fixture_dir/AlfalfaDesktopFixture" "$fixture_dir/focus.jsonl" &
fixture_pid=$!
# Wait until the fixture window appears, then continue with another app in the foreground.
node Scripts/test-desktop.mjs "$PWD/.build/debug/alfalfa-desktop" "$fixture_pid" "$fixture_dir/focus.jsonl"
kill "$fixture_pid"
```

Add `--capture` to verify that the two real PNG captures differ when the counter changes. Use `--list-only` for real
application discovery, PACAI handshake, and denial and cancellation without sending any native input.

## References

- [AlfalfaCode](https://github.com/0sw2ld0/AlfalfaCode)
- [PACAI](https://github.com/0sw2ld0/PACAI)
- [CuyBrowser](https://github.com/0sw2ld0/cuybrowser)
