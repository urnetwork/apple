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
- `intents-debugging` (`34b07bb3`): current `DisconnectIntent` already awaits
  `VPNManager.updateVpnServiceAndWait` (or stale-profile stop completion),
  reports failure, and closes its controller with `defer`. Preserve that
  current reconciliation owner. The old listeners had neither one-shot
  continuation fencing nor removal and could resume a continuation repeatedly;
  they also targeted a view-model path since removed. No such listeners are
  reintroduced by this historical merge.
- `egress-contract-listeners` (`da649059`): merged the view-owned stats
  subscription and removal of the unused ContentView API property. Adapted the
  old misspelled SDK selector to current `addEgressContractStatsChangeListener`,
  marshaled published changes to the main queue, retained weak ownership and
  subscription closure, and removed raw-stat debug prints. Current picker,
  billing, drawer and referral initialization remain intact.

Validation here checks branch ancestry, conflict resolution, current SDK selector
and subscription ownership, and the repository diff. This Linux workspace has
no Swift/Xcode toolchain; Apple native compile/runtime validation remains pending.
No application build or device deployment is selected by this source integration.
