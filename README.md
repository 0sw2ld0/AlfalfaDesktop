# CuyDesktop

CuyDesktop is a planned native macOS app-control tool for inspecting windows and performing approved actions while the user works in another app.

This repository defines the extraction plan. The current implementation lives in AlfalfaCode.

## Design

| Component | Responsibility |
| --- | --- |
| Swift core | Find apps and windows, read accessibility trees, capture approved windows, and perform scoped actions with a virtual pointer. |
| PACAI adapter | Expose execution, approval, and cancellation events to PACAI clients over stdio using the PACAI JSONL framing. |
| MCP adapter | Expose the same desktop capabilities to MCP hosts through MCP JSON-RPC over stdio. |
| CLI | Run a single operation or select a protocol adapter from the terminal. |

Each protocol mode owns its own input and output stream. Both adapters and the CLI use the same capability checks and per-app authorization.

## First milestone

1. Extract the Swift helper currently in `alfalfa/apps/ayudante.swift`.
2. Validate the signed executable's Accessibility and Screen Recording permission flow on macOS.
3. Test with a real app fixture. Verify a window capture and a background action while a separate app retains foreground focus.
4. Integrate a pinned build into AlfalfaCode, using CuyBrowser's version and checksum verification as a reference.

The AlfalfaCode sidebar preview stays in the AlfalfaCode client. CuyDesktop should provide the window observations and action results the preview needs.

## References

- [AlfalfaCode](https://github.com/0sw2ld0/AlfalfaCode)
- [PACAI](https://github.com/0sw2ld0/PACAI)
- [CuyBrowser](https://github.com/0sw2ld0/cuybrowser)
- [MCP transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
