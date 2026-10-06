# URnetwork iOS

## Development Notes

### Broken Previews

If you encounter broken previews, in XCode click on the topmost folder `network`, then select the `networkTests` target and the `Build Settings` tab. Make sure that the `Testing` section is empty.


### Debugging Network Extension

In the console app, under Action, check:

- Include Info Messages
- Include Debug Messages

### Native profile invariants

`test-hardware-startup.sh`, called by the full MAIN harness, runs the profile
gateway, split-tunnel device-subscription, and source-contract regressions before runtime
inventory or provisioning. A failure stops the startup lane; the retained
`profile-boundary-test.log` is in that run's artifact directory. The existing
simulator matrix and its full unit/UI corpora still run afterward.

To run only these native regressions from the workspace root:

```sh
GOMAXPROCS=2 go test -p 1 -parallel 1 -count=1 \
  apple/test-vpn-profile-system_test.go \
  apple/test-split-tunnel-device-generation_test.go
```

The tests compile the actual Swift gateway/controller against synthetic
NetworkExtension and SDK modules, and separately typecheck them against the
installed Apple SDK. They do not call Apple's profile services, activate an
extension, or use a device, simulator, keychain, or network fixture. Canonical
runs clear the source-root and sanitizer investigation overrides. The command
contract, failure propagation, and ordering are tested by
`bash apple/test-hardware-startup.test.sh` with fake tools.

The source contract uses `test-hardware-profile-scan.go` to audit the same
`app/network` Swift scope. It recognizes direct profile operations across
newlines, nested comments, escaped names and expression receivers, and scans
executable string interpolation while ignoring ordinary/raw/multiline literal
text. Only the exact gateway file and unqualified `VPNProfileSystem` receiver
are exempt. This lexical check does not resolve arbitrary Swift type aliases or
dynamic dispatch; unsupported regex literals and ambiguous slash forms fail
closed. Native-SDK-typechecked controls exercise the actual Bash contract;
bare-slash-regex controls explicitly enable that otherwise-disabled feature.

Each scanner invocation has a 90-second compile-inclusive timeout with a
five-second hard-kill grace, a 60-second scan budget, and bounded inventory,
file, total-source and nesting sizes. Go uses two processors and one build
worker without toolchain downloads. Readiness-barrier tests cover inventory
cancellation and outer termination, including the Go wrapper and compiled CLI.

