
When E2E encryption is enables, each client has an identity key that is shared via the platform. There is a risk that the platform dishonestly distributes the identity, and/or tries to MITM the E2E encryption between client and provider. In this case the client would see an identity for the provider that does not match the provider. The client being able to distribute and directly validate identity of providers/other clients is what prevents bad actors and makes the E2E encryption ultimately verifiable.

The app will add a "Post Quantum Identity" (PQI) panel in the account tab under the current plan and earnings panel. The new PQI panel will have five parts:

1. On the left, full span of the panel, an identicon for the public identity key of the DeviceLocal provider client
2. On the right of the identicon, aligned to top should be the public identity key hash. We shoul use a SHA256 and render the hash in base32. Tapping the hash should copy it.
3. On the right, under the hash and aligned to the bottom, should be a stack of all the public identity key identicons of the providers the client is connected to. This will only matter for providers that are using E2E encryption and have done the client identity key exchange. Tapping the stack should open the provider public identity key details view.
4. At the bottom of the panel, full width, will be an explanation of the client identity key. The identity key is a unique key stored locally on the device. The network operator shares the key with other clients, but the user can also distribute the key through any side channel. The user must be able to verify the key of the connected providers with the key the provider shares on any channel. If the verification fails, it means the network operator may not be honestly distributing keys or trying to intercept PQE traffic between your client and the provider.
5. The provider public identity key details view will be a live list with one row per currently connected provider in an E2E session. Each row will have the identicon of the provider identity key on the left, the hash of the provider identity key on the top, and the client_id under that. The key hash and the client id should copy on tap.
6. Use the local package ../goidenticons to generate identicons. Extend and modify the package as needed to make it easy and efficient to use. Render the identicons in the app image view with a slightly rounded edge clipping.
7. The currently connected provider identity key listeners and state will need to be exposed in the client and threaded through the sdk DeviceLocal and DeviceRemote RPC.

This is an initial implementation that exposes the E2E identity state and the DeviceLocal provider identity. Further iterations will build it into a "contacts" list where users can pin identities and sync them across their devices.

