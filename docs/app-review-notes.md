# App Review notes

Paste what applies into the Notes field of App Store Connect, with the release that adds it.

## The Bittensor key on the Earnings screen

URnetwork pays people who share bandwidth in SN25α, a token on the Bittensor network. To
be paid, a network needs a Bittensor address. Set up payouts on the Earnings screen makes
one on the device, so someone with no crypto wallet can be paid. Existing wallets still
work: **Use a wallet I already have** is on the same card.

What the key does:

- It's one key per URnetwork network. The app generates it on the device from the
  system's secure random source.
- It signs one thing: a text statement from our server that says "pay this network's
  earnings to this address". The statement is sent to our API and never goes on a
  blockchain. No transaction is signed, and it costs nothing.
- The recovery phrase is stored in the Keychain on this device only
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), so it isn't in backups and isn't
  synced. In the flow where the user saves the phrase first, it stays in memory only.
- The phrase and the private key never leave the device. Our servers receive only the
  public address and the signature. We can't recover the key.

What it isn't:

- The app isn't a wallet. It can't send funds to anyone. To transfer or use their SN25α,
  the user enters the recovery phrase into another wallet, such as Talisman or Nova, or
  into `btcli`. The screens say this before the user taps and on the key's own screen.
- There's no in-app purchase of crypto and no exchange. If a later release adds converting
  SN25α to TAO on the same key, these notes change with that release.

Where the reviewer finds it:

1. Sign in with the review account, which is a normal signed-in account and not a guest.
2. Go to Account, then Earnings. The payout card is near the top.
3. **Set up payouts** does the whole setup with one tap: it makes the key, stores it and
   signs. A banner then says **Back up your key**.
4. Tap the banner. The words are hidden until **Tap to reveal**, which asks for Face ID,
   Touch ID or the passcode. **Hide** and **Copy** appear once they show. They hide again
   after 60 seconds and when the app leaves the foreground.
5. **I have saved the key, it's OK to delete it now.** asks for two of the words before it
   deletes the key from the device.

Permissions: Face ID (or Touch ID, or the device passcode) is asked for only before the app
shows the phrase of a stored key, or before the user confirms it's saved, which can delete it.
Setting up payouts asks for nothing. No new background mode or network destination is added. The local notification goes out once,
when the first earnings can be claimed, and only if the user already allowed notifications
in Settings.

Why the screen hides itself: the phrase controls the user's funds, so the words are drawn
in a way that keeps them out of most screenshots and recordings. That is best effort, and
the app doesn't promise it.

## Export compliance

The key uses sr25519 signatures from the app's existing sdk. It adds no encryption of user
data beyond the Keychain's. Check this against the app's existing export compliance answers
before submitting.
