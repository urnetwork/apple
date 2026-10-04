# Audited branch integration, 2026-10-04

The integration starts at origin/main 7653780d78f8534c196924caf3f37774512d06b1.
Historical branch parents are retained without replacing current SDK bindings or
network-space, VPN, and picker lifecycle owners.

- `copilot/fix-code-review-comment` (`0a88f2be`): merged the login guard's
  indentation correction.
- `network-space-fix` (`21ed343f`, `59f6fe94`): the old
  `network/network/Shared/ViewModels/DeviceManager.swift` path has been replaced
  by `app/network/Shared/ViewModels/DeviceManager.swift`. The callback-owned
  `updateNetworkSpace` behavior is present in `prepareBundledNetworkSpace` and
  `NetworkSpaceUpdateCallback`, now using `NetworkConfig` and preserving the
  user's selected network space. Restoring the deleted file or old constants
  would regress that current ownership; retain the current implementation.
