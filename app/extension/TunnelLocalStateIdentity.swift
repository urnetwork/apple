import Foundation

// A client JWT is a renewable credential, not the identity of the persisted
// DeviceLocal state. A token rotation for the same device instance must retain
// its destination and routing memory. Missing, unreadable, or different
// instance identity remains fail closed: that state cannot be attributed to
// the tunnel being started.
func tunnelLocalStateRequiresReset(
    storedByJwt: String,
    storedInstanceId: String?,
    configuredByJwt: String,
    configuredInstanceId: String
) -> Bool {
    guard let storedInstanceId,
          !storedInstanceId.isEmpty,
          !configuredInstanceId.isEmpty else {
        return true
    }

    // Deliberately ignore the raw JWT values once the stable instance matches.
    // They are accepted here to make that credential-vs-identity contract
    // explicit at the startup call site and in its regression tests.
    _ = storedByJwt
    _ = configuredByJwt
    return storedInstanceId != configuredInstanceId
}
