# Working on CuyDesktop

- Write Swift identifiers, comments, public API documentation, and tests in US English.
- Follow the [RedMadRobot Swift Style Guide](https://github.com/RedMadRobot/RMR-swift-style-guide). Use descriptive names, Swift casing conventions, and a 120-character line guide.
- Keep window control and authorization in the shared core. Keep PACAI and MCP framing in their respective adapters.
- Ask for macOS permissions from the signed app when the relevant capability is first used. Scope access to the authorized app and window.
- Test changes to background input or captures with a dedicated macOS fixture and verify that the foreground app keeps focus.
