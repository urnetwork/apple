# Physical iOS low-bar capture

The Debug iOS app has an opt-in physical benchmark driver. Normal launches are
unchanged. A VPN benchmark waits for both the SDK connection and Network
Extension tunnel; a Direct benchmark first stops the tunnel without removing
its profile, then waits for the SDK to report disconnected and for the extension
to be stopped. After the timed pages it reconnects and verifies the exact
pre-run VPN location before declaring the session complete. Each page runs in a
non-persistent `WKWebView` and emits one
sorted JSON record as bounded `[PhysicalPageBenchmarkChunk]` console frames.
The host collector reassembles the frames; this avoids truncating the large
per-transport result at an implementation-dependent device-log limit.

Every page record now contains `physicalTelemetry.start`, `.end`, and
`.packetDelta`:

- cumulative and per-transport VPN packet/byte counters from the production
  `DeviceRemote` RPC path;
- the exact transport mode and Auto mode order active for the sample;
- physical-path cellular/Wi-Fi/Ethernet, expensive, constrained, status, and
  IPv4/IPv6/DNS support without interface names, gateways, or addresses;
- app physical footprint, battery state/level, low-power mode, and thermal
  state.

The app footprint is not the Network Extension footprint. Collect the existing
parseable `ExtensionMemoryMonitor` records from unified logging alongside the
page output. A packet-counter decrease marks `counterResetDetected`; do not use
that page as a traffic delta because the extension or counter generation
changed during the sample.

Build and install a Debug app on the physical device, establish the intended
provider connection, then disconnect USB and use wireless CoreDevice access for
the measurement. Put only synthetic, credential-free URLs and privacy-safe
labels in a suite file:

```json
[
  {"url":"https://BENCHMARK_HOST/web","label":"web"}
]
```

The recommended forced-H3 capture is:

```sh
node app/scripts/physical_lowbar_capture.mjs \
  --device DEVICE \
  --run-label h3-lowbar-01 \
  --suite-file physical-suite.json \
  --route vpn \
  --transport h3 \
  --expected-carrier h3 \
  --peer EXPECTED_PROVIDER_ID \
  --confirm-one-bar \
  --output h3-lowbar-01.ndjson
```

The collector keeps raw `devicectl` output in memory and writes only an
allow-listed NDJSON result without URLs, device/provider IDs, addresses, or raw
error text. Exit status zero means every requested page passed the strict gate;
two means the collection completed but at least one page was ineligible; one
means launch, framing, or collection failed. The gate requires:

- explicit operator confirmation of one bar because public iOS APIs do not
  expose cellular signal strength;
- a satisfied cellular-only underlay, unplugged power, Low Power Mode off, and
  nominal or fair thermal state at both endpoints;
- the requested Direct/VPN route and transport mode before timing;
- successful navigation, complete telemetry, and no packet-counter reset;
- attributed remote traffic on the forced carrier, with no other carrier used;
- zero aggregate and per-carrier remote traffic for Direct.

The collector does not finish merely because it received the last page. It
waits for the driver's cleanup marker, so failure to restore the previous
transport policy or the pre-Direct VPN connection invalidates the collection.

Use `h1`, `h3`, `auto`, `dns`, or `dnspump` to select a VPN policy. The driver
snapshots the live `DeviceRemote` policy, restores it after a controlled
benchmark even when readiness or navigation fails, and never writes the pin to
app settings. Omitting the transport or using `current` preserves the active
policy. The expected provider is optional for VPN, but specifying it prevents a
sample from silently using the wrong exit. Auto accepts all healthy carriers in
parallel and reports their separate byte totals. To validate a P2P sample, use
the active `current` or `auto` policy plus `--expected-carrier p2p`; an explicit
expected carrier is exclusive, so fallback traffic invalidates the sample.

For the matching Direct run, omit both provider and transport because neither
can apply without a tunnel:

```sh
node app/scripts/physical_lowbar_capture.mjs \
  --device DEVICE \
  --run-label direct-lowbar-01 \
  --suite-file physical-suite.json \
  --route direct \
  --confirm-one-bar \
  --output direct-lowbar-01.ndjson
```

Both the host and driver reject contradictory or unknown route/transport
arguments. The driver logs route-readiness time before the first page and
records `benchmarkRoute`, `expectedTransportMode`, `routeReadinessMs`, navigation
DNS/connect/TLS/TTFB/load, resource concurrency, per-resource TTFB, and
transferred bytes in every result.

Run the same suite repeatedly for Direct, forced H1, forced H3, Auto, and P2P
where available on the same weak cellular path. Record failed readiness and
navigation attempts rather than retrying them out of the sample. Physical path
support for IPv6 describes the radio underlay; it does not mean the VPN
advertises IPv6. Verify the tunnel's IPv4-only policy separately from the
device capture and the application-visible 1,200-byte QUIC Initial test.

Do not compare isolated mode runs. Use at least five cycles, bracket each
candidate group with Direct, and rotate the order of H1, H3, and Auto. The
preferred acquisition path creates a new private directory, generates a
balanced order, runs every capture, and invokes the strict analyzer only after
all samples pass:

```sh
node app/scripts/physical_lowbar_campaign.mjs \
  --device DEVICE \
  --peer EXPECTED_PROVIDER_ID \
  --campaign-label one-bar-campaign-01 \
  --suite-file physical-suite.json \
  --output-dir one-bar-campaign-01 \
  --confirm-one-bar
```

The directory must not already exist; the runner never overwrites an earlier
campaign. It uses a randomized, position-balanced six-order design, runs
`Direct-before`, the cycle's H1/H3/Auto order, then `Direct-after`, and stops at
the first capture or eligibility failure. The failed sanitized NDJSON remains
available for diagnosis, but no comparison report is produced. On success,
`campaign.json`, every run, and `comparison.json` are mode `0600` inside a mode
`0700` directory. Device and provider identifiers are never stored there.

`--confirm-one-bar` attests that the operator will monitor and maintain one bar
for the whole uninterrupted campaign. Abort if the displayed signal changes;
iOS has no public signal-strength API, so path and Direct-drift gates cannot
independently prove the number of bars. Keep the phone awake, unplugged, and on
a cellular-only data path. Do not interrupt during a run, because the app emits
its completion marker only after restoring the prior VPN route and policy.

For manual acquisition or review, the generated campaign manifest contains
only local file references and privacy-safe labels:

```json
{
  "schemaVersion": 1,
  "campaignLabel": "one-bar-campaign-01",
  "cycles": [
    {
      "label": "cycle-01",
      "directBefore": "direct-before-01.ndjson",
      "order": ["h1", "h3", "auto"],
      "h1": "h1-01.ndjson",
      "h3": "h3-01.ndjson",
      "auto": "auto-01.ndjson",
      "directAfter": "direct-after-01.ndjson"
    }
  ]
}
```

Add four more cycles and rotate their candidate orders so every mode appears in
each position equally, or with counts differing by no more than one. Analyze a
manually completed campaign with:

```sh
node app/scripts/physical_lowbar_compare.mjs \
  --manifest physical-campaign.json \
  --min-cycles 5 \
  --max-direct-drift-percent 35 \
  --max-cycle-minutes 60 \
  --output physical-campaign-report.json
```

The analyzer fails closed unless every input run passed the collector, all runs
use the same ordered page set and resource/origin counts, run labels and files
are unique, timestamps follow the manifest order, and the sanitized physical
path fingerprint stays fixed. Each Direct bracket must have no more than the
configured symmetric drift for driver completion, TTFB, load, and total browser
transfer bytes. The default 60-minute cycle bound limits slow radio drift.

An accepted report compares each candidate page with the mean of its enclosing
Direct pair. Positive `medianImprovementPercent` means lower candidate time or
bytes; `p95CandidateToDirectRatio` and `winCount` retain the tail and pairwise
view. `remoteBytesPerTransferByte` reports VPN carrier cost per browser byte,
and `transportRemoteBytes` reports Auto's actual carrier mix. Input paths, URLs,
timestamps, device/provider identities, and raw errors are not emitted. Report
files are forced to mode `0600`, including when replacing an existing file.

For packet evidence, attach the device's Remote Virtual Interface and collect a
matching edge capture under the same opaque run label. Raw captures contain IP
addresses and can contain user data even with a short snap length: keep them in
restricted temporary storage, use synthetic benchmark URLs, derive only the
needed packet-size/timing/retry aggregates, and never check raw captures into a
repository. Do not put device IDs, account/provider IDs, carrier/cell identity,
IP addresses, DNS answers, or payloads into checked-in results.

The focused simulator validation is:

```sh
xcodebuild test \
  -project app/app.xcodeproj \
  -scheme URnetwork \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:networkTests/PhysicalPageBenchmarkResultTests \
  -only-testing:networkTests/PhysicalPeerTestReadinessTests \
  -only-testing:networkTests/PhysicalBenchmarkConfigurationTests \
  -only-testing:networkTests/PhysicalPageBenchmarkSuiteTests \
  -only-testing:networkTests/PhysicalPacketStatsSnapshotTests
```

The host framing, privacy, eligibility, and paired-comparison validation is:

```sh
node --test \
  app/scripts/physical_lowbar_campaign_test.mjs \
  app/scripts/physical_lowbar_capture_test.mjs \
  app/scripts/physical_lowbar_compare_test.mjs
```
