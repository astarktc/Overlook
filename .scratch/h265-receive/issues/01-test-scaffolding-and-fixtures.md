# 01 — Test scaffolding: unit-test target + committed Comet fixtures

**What to build:** The project's first automated test infrastructure. A unit-test target that runs green from the command line, with the two verified Comet H.265 bitstream fixtures (steady-state and rejoin captures, 2560×1440@60, GOP 60, parameter sets before every IDR) promoted from the incoming drop zone into committed test resources. This is prefactoring: it makes tickets 02 and 03 easy, and they can proceed in parallel once it lands.

**Blocked by:** None — can start immediately.

**Status:** done

- [x] A unit-test target exists in the project and a trivial smoke test passes via a command-line test invocation (document the exact command in the ticket's comments when done)
- [x] Both Comet fixtures are committed as test resources, loadable from test code, with their SHA-256 hashes verified against the provenance README before the drop-zone copy is removed
- [x] The fixtures' provenance documentation (capture method, format, verified NAL structure, hashes) is preserved alongside them
- [x] The app target still builds and runs unchanged

## Comments

- Added a non-hosted `OverlookTests` XCTest bundle. It has no `TEST_HOST`, no app-target dependency, and does not import the app module; upcoming module sources can be compiled directly into the test target.
- Added a shared `Overlook` scheme with a test action so headless CLI tests are discoverable.
- Re-verified both incoming fixtures with `shasum -a 256` before removing the drop zone, then preserved the fixtures and provenance README under `OverlookTests/Fixtures/` as test resources. The resource test loads both files from the test bundle and checks their documented SHA-256 hashes.
- Exact test command (exit 0): `xcodebuild -project Overlook.xcodeproj -scheme Overlook -configuration Debug -derivedDataPath /tmp/overlook-tests -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test`
- Baseline Release app build command also completed successfully with exit 0.
