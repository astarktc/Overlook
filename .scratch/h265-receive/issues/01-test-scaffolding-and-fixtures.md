# 01 — Test scaffolding: unit-test target + committed Comet fixtures

**What to build:** The project's first automated test infrastructure. A unit-test target that runs green from the command line, with the two verified Comet H.265 bitstream fixtures (steady-state and rejoin captures, 2560×1440@60, GOP 60, parameter sets before every IDR) promoted from the incoming drop zone into committed test resources. This is prefactoring: it makes tickets 02 and 03 easy, and they can proceed in parallel once it lands.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] A unit-test target exists in the project and a trivial smoke test passes via a command-line test invocation (document the exact command in the ticket's comments when done)
- [ ] Both Comet fixtures are committed as test resources, loadable from test code, with their SHA-256 hashes verified against the provenance README before the drop-zone copy is removed
- [ ] The fixtures' provenance documentation (capture method, format, verified NAL structure, hashes) is preserved alongside them
- [ ] The app target still builds and runs unchanged
