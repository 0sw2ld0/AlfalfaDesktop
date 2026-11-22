# Reproduce a click without Screen Recording

This example builds a temporary macOS app and clicks its only button using the AlfalfaDesktop CLI. It targets
the PID it launched and checks the visible result through the accessibility tree.

## Run the test

Use macOS 14 or later, Node.js 20 or later, the Xcode command-line tools, and AlfalfaDesktop 0.1.1 or later.
Run this from the repository root in an AlfalfaCode task, in a VS Code agent's integrated terminal, or in a shell:

```sh
ALFALFA_DESKTOP="$HOME/.local/bin/alfalfa-desktop" node Examples/AccessibilityClick/test-click.mjs
```

Set `ALFALFA_DESKTOP` to the absolute path of the installed CLI. Run `"$ALFALFA_DESKTOP" permissions` from the
same host if the test reports missing Accessibility access. Enable only Accessibility for this example. The
same CLI command runs in both agents, so allow the scoped command in the agent if it asks.

The test checks that the label starts at `Pendiente` (pending), sends one background `AXPress` to
`Verificar control`, and reads `Control confirmado` (control confirmed) on the next inspection. The fixture
closes after the test. The script never requests a capture or a Screen Recording permission prompt.

## Recorded runs

These results were recorded with the AlfalfaDesktop 0.1.1 CLI through the two agents. Both reported
`accessibility: true`, `screenRecording: false`, and a successful `AXPress`.

- [AlfalfaCode JSON](results/alfalfacode-desktop.json)
- [VS Code JSON](results/vscode-desktop.json)
