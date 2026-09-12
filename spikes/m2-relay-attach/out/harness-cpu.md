# M2 harness (windowed AppKit + SwiftTerm TerminalView)

## 20 live terminal panes — CPU (PRD §10.1: idle CPU < 2% of one core)

| condition | CPU (% of one core) | RSS |
|---|---|---|
| empty window, 0 panes (baseline) | 0.02 | 45.30 MB |
| 20 panes attached + parented + visible, shells idle at a prompt | **0.03** | 59.72 MB |
| the same 20 attached but unparented (off-screen lane) | 0.01 | 61.50 MB |
| 3 of the 20 emitting 20 lines/s (a working agent) | 0.76 | 64.64 MB |
| all 20 emitting 200 lines/s (worst case) | 7.83 | 84.06 MB |
