# Moving your Bittensor key to a wallet

**Status: unverified.** These steps are written from the tools' published docs and, for
btcli, from `btcli wallet regen-coldkey --help` in bittensor-cli 9.23.2. Nobody has run
them yet with a phrase from the app. Whoever does should change this line, and fix
anything that doesn't match what the tool showed.

URnetwork is not a wallet. It creates one key so you can receive SN25α. To transfer or
use your SN25α, you enter the key's recovery phrase into a Bittensor wallet or btcli.

## Before you start

- The phrase is 12 words, from **Bittensor recovery phrase** on the Earnings screen in
  the app. It is not your account seed phrase from sign-up, which has 24 words.
- Anyone with this phrase controls your SN25α. URnetwork will never ask for it, and
  can't recover it. Enter it only into the wallet you chose, on a device you trust.
- Write down the address the app shows. It starts with `5`. After the import, the wallet
  has to show the same address. If it shows another one, the wallet used other settings:
  remove that account from the wallet and check the steps below. Don't send anything to
  it.

The key is a sr25519 key with no password and no derivation path. Wallets that ask for
these should use those values.

## Talisman (browser extension)

From [Talisman Wallet: How to Restore an Account](https://support.polkadot.network/support/solutions/articles/65000185624-talisman-wallet-how-to-restore-an-account)
and the [Autonomys guide to Talisman](https://docs.autonomys.xyz/wallets/talisman).
Menu names can differ between versions.

1. Open Talisman and unlock it.
2. Open the menu, choose **Add account**, then **Import**.
3. Choose **Import via Recovery Phrase**, and **Polkadot** as the account type. Don't
   choose Ethereum: that makes a different account from the same words.
4. Enter the 12 words in order, and name the account.
5. Leave the derivation path as it is. Check that the address is the one the app showed.
   Talisman can show an address in another network's format, so compare it with the
   Bittensor network selected.

## Nova Wallet (phone)

From [How to set up or recover your account using Nova Wallet](https://docs.alephzero.org/aleph-zero/setting-up-or-restoring-a-wallet/how-to-set-up-or-recover-your-azero-account-using-nova-wallet)
and [Nova Wallet: Advanced Account Creation Options and Derivation](https://support.polkadot.network/support/solutions/articles/65000185657-nova-wallet-advanced-account-creation-options-and-derivation),
which says it is no longer maintained. Menu names can differ between versions.

1. Open Nova Wallet and go to its wallets list, or start from its first screen.
2. Choose **Import wallet**, then the mnemonic (passphrase) option.
3. Enter the 12 words in order, and a name for the wallet.
4. Leave the advanced settings as they are: the crypto type stays **sr25519
   (Schnorrkel)**, with no derivation path and no password. Changing any of them makes a
   different account.
5. Open the wallet's Bittensor account. Check that the address is the one the app showed.

## btcli

```sh
btcli wallet regen-coldkey --wallet-name my-urnetwork-key
```

1. Run the command above. Choose any wallet name that isn't already in
   `~/.bittensor/wallets`.
2. Leave out `--mnemonic` so the phrase doesn't go into your shell's history. btcli then
   asks which kind of secret you have: choose **Mnemonic**, and enter the 12 words in
   order, separated by spaces.
3. If btcli asks for a password, set one. It protects the key file on this computer. The
   phrase itself has no password, so don't add one anywhere it's offered for the phrase.
4. Run `btcli wallet list`, and check that the coldkey's address is the one the app showed.

## If the key holds no TAO

SN25α you claim lands on this key as stake. A key that has never held TAO can pay some
fees from its alpha, according to the chain's source. **Whether Talisman, Nova and btcli
let such a key send a transaction at all is still unknown.** If yours refuses:

- Don't enter the phrase anywhere else to work around it.
- While the key is still on your device, convert in the app, when your version has it.
  That TAO stays on the same key and pays the fee in the wallet.
- Otherwise, the SN25α stays safe on the key until the wallet can send. Claims keep
  working without the app holding the key.

This section has to be replaced with what actually happens once someone has tried it.
