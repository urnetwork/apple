import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import {
  chmodSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import test from "node:test";

import {
  PhysicalConsoleParser,
  evaluateEligibility,
  parseArgs,
  parseSuite,
  outputWriter,
  runCapture,
  sanitizeBenchmark,
  summarize,
} from "./physical_lowbar_capture.mjs";

const transportTypes = ["h3", "h1", "dns", "dnspump", "p2p", "unknown"];

function counters(overrides = {}) {
  return {
    remoteEgressPacketCount: 0,
    remoteEgressByteCount: 0,
    remoteIngressPacketCount: 0,
    remoteIngressByteCount: 0,
    localEgressPacketCount: 0,
    localEgressByteCount: 0,
    localIngressPacketCount: 0,
    localIngressByteCount: 0,
    blockEgressPacketCount: 0,
    blockEgressByteCount: 0,
    blockIngressPacketCount: 0,
    blockIngressByteCount: 0,
    ...overrides,
  };
}

function transports(active = "h3") {
  return Object.fromEntries(transportTypes.map((type) => [
    type,
    counters(type === active ? {
      remoteEgressPacketCount: 4,
      remoteEgressByteCount: 1_000,
      remoteIngressPacketCount: 6,
      remoteIngressByteCount: 2_000,
    } : {}),
  ]));
}

function snapshot(mode = "h3") {
  return {
    timeUnixMs: 1_787_000_000_000,
    appPhysicalFootprintBytes: 42_000_000,
    lowPowerMode: false,
    thermalState: "nominal",
    batteryLevel: 0.7,
    batteryState: "unplugged",
    physicalPath: {
      status: "satisfied",
      expensive: true,
      constrained: false,
      cellular: true,
      wifi: false,
      wiredEthernet: false,
      supportsIPv4: true,
      supportsIPv6: true,
      supportsDNS: true,
    },
    packetStats: {
      totals: counters({ remoteEgressByteCount: 10_000 }),
      transports: transports(mode === "auto" ? "h1" : mode),
    },
    transportSettings: {
      mode,
      autoModes: ["h3", "h1", "dns", "dnspump"],
    },
  };
}

function benchmark(mode = "h3", active = "h3") {
  return {
    label: "web-1",
    requestedUrl: "https://private.example/path?token=secret",
    finalUrl: "https://private.example/final",
    benchmarkRoute: "vpn",
    expectedTransportMode: mode,
    routeReadinessMs: 123,
    driverCommitMs: 200,
    driverFinishMs: 400,
    navigation: {
      dnsMs: 10,
      connectMs: 30,
      tlsMs: 20,
      ttfbMs: 100,
      responseEndMs: 300,
      domContentLoadedMs: 350,
      loadMs: 390,
      transferBytes: 2_500,
      protocol: "h2",
    },
    resourceCount: 3,
    originCount: 1,
    maxRequestConcurrency: 2,
    maxDnsConcurrency: 1,
    resourcesWithDns: 1,
    totalResourceDnsMs: 10,
    resourceTtfbMedianMs: 80,
    resourceTtfbP95Ms: 120,
    resourceTtfbMaxMs: 130,
    totalTransferBytes: 4_000,
    physicalTelemetry: {
      start: snapshot(mode),
      end: { ...snapshot(mode), timeUnixMs: 1_787_000_000_400 },
      packetDelta: {
        totals: counters({
          remoteEgressPacketCount: 4,
          remoteEgressByteCount: 1_000,
          remoteIngressPacketCount: 6,
          remoteIngressByteCount: 2_000,
        }),
        transports: transports(active),
        counterResetDetected: false,
      },
    },
  };
}

function options(overrides = {}) {
  return {
    route: "vpn",
    transport: "h3",
    expectedCarrier: undefined,
    confirmOneBar: true,
    runLabel: "run-1",
    ...overrides,
  };
}

test("arguments enforce explicit and non-contradictory campaign inputs", () => {
  const parsed = parseArgs([
    "--device", "device-id",
    "--suite-json", '[{"url":"https://example.com","label":"web"}]',
    "--route", "vpn",
    "--transport", "h3",
    "--expected-carrier", "h3",
    "--confirm-one-bar",
  ]);
  assert.equal(parsed.confirmOneBar, true);
  assert.equal(parsed.transport, "h3");
  assert.throws(() => parseArgs([
    "--device", "device-id",
    "--suite-json", "[]",
    "--route", "direct",
    "--transport", "h3",
  ]), /cannot select a transport/);
  assert.throws(() => parseArgs([
    "--device", "device-id",
    "--suite-json", "[]",
    "--transport", "h3",
    "--expected-carrier", "h1",
  ]), /disagree/);
  assert.throws(() => parseArgs([
    "--device", "device-id",
    "--suite-json", "[]",
    "--suite-file", "suite.json",
  ]), /exactly one/);
});

test("suite parser requires bounded, unique, privacy-safe page metadata", () => {
  assert.deepEqual(parseSuite(
    '[{"url":"https://example.com","label":"web-1"}]',
  ), [{ url: "https://example.com/", label: "web-1" }]);
  assert.throws(() => parseSuite(
    '[{"url":"https://user:secret@example.com","label":"web"}]',
  ), /credential-free/);
  assert.throws(() => parseSuite(
    '[{"url":"https://example.com/1","label":"same"},' +
      '{"url":"https://example.com/2","label":"same"}]',
  ), /unique/);
});

test("chunk parser reassembles out-of-order Unicode and observes cleanup", () => {
  const value = benchmark();
  value.label = "web-1";
  value.unusedUnicode = "低速".repeat(20);
  const encoded = Buffer.from(JSON.stringify(value), "utf8").toString("base64");
  const pieces = [];
  for (let offset = 0; offset < encoded.length; offset += 24) {
    pieces.push(encoded.slice(offset, offset + 24));
  }
  const parser = new PhysicalConsoleParser();
  let decoded;
  for (const index of [...pieces.keys()].reverse()) {
    const record = parser.ingestLine(
      `prefix [PhysicalPageBenchmarkChunk] record-1 ${index + 1}/${pieces.length} ${pieces[index]}`,
    );
    if (record !== undefined) decoded = record;
  }
  assert.deepEqual(decoded, value);
  assert.equal(parser.incompleteChunkRecordCount, 0);
  parser.ingestLine(
    "prefix [PhysicalPeerTest] benchmark session complete route=vpn transport=h3",
  );
  assert.equal(parser.sessionComplete, true);
});

test("console parser accepts legacy records and rejects conflicting chunks", () => {
  const parser = new PhysicalConsoleParser();
  assert.deepEqual(
    parser.ingestLine(`prefix [PhysicalPageBenchmark] ${JSON.stringify({ label: "web" })}`),
    { label: "web" },
  );
  parser.ingestLine("[PhysicalPageBenchmarkChunk] id 1/2 eyJh");
  assert.throws(
    () => parser.ingestLine("[PhysicalPageBenchmarkChunk] id 1/2 eyJi"),
    /changed/,
  );
});

test("console parser classifies CoreDevice failures without retaining details", () => {
  const parser = new PhysicalConsoleParser();
  parser.ingestLine(
    'Unable to launch private.bundle because the device was not, or could not be, unlocked.',
  );
  assert.equal(parser.devicectlFailure, "device-locked");
  parser.ingestLine(
    "A connection to this device could not be established. Network.NWError error 60",
  );
  assert.equal(parser.devicectlFailure, "device-unreachable");
  parser.ingestLine("[PhysicalPeerTest] benchmark route restore failed");
  assert.deepEqual([...parser.driverFailures], ["benchmark-route-restore-failed"]);
});

test("capture orchestration launches the suite and waits for driver cleanup", async () => {
  const raw = benchmark();
  const encoded = Buffer.from(JSON.stringify(raw), "utf8").toString("base64");
  const pieces = [encoded.slice(0, 720), encoded.slice(720)];
  let launched;
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.exitCode = null;
  child.signalCode = null;
  child.killSignals = [];
  child.kill = (signal) => {
    child.killSignals.push(signal);
    child.signalCode = signal;
    return true;
  };
  const fakeSpawn = (command, args, spawnOptions) => {
    launched = { command, args, spawnOptions };
    queueMicrotask(() => {
      // CoreDevice stdout/stderr do not have a shared ordering guarantee. A
      // cleanup marker received first must not finish collection early.
      child.stdout.write(
        "[PhysicalPeerTest] benchmark session complete route=vpn transport=h3\n",
      );
      queueMicrotask(() => {
        for (const [index, piece] of pieces.entries()) {
          child.stderr.write(
            `[PhysicalPageBenchmarkChunk] id ${index + 1}/${pieces.length} ${piece}\n`,
          );
        }
      });
    });
    return child;
  };
  const captureOptions = {
    ...options(),
    device: "private-device-id",
    bundleId: "network.ur",
    peer: "private-provider-id",
    timeoutSeconds: 1,
  };
  const result = await runCapture(
    captureOptions,
    [{ url: "https://private.example/", label: "web-1" }],
    fakeSpawn,
  );

  assert.equal(launched.command, "xcrun");
  assert.equal(launched.spawnOptions.stdio[0], "ignore");
  assert.deepEqual(result.records, [raw]);
  assert.equal(result.sessionComplete, true);
  assert.deepEqual(result.driverFailures, []);
  assert.deepEqual(child.killSignals, ["SIGINT"]);
  assert.equal(launched.args.includes("private-device-id"), true);
  assert.equal(launched.args.includes("private-provider-id"), true);
  assert.equal(launched.args.includes("--urnetwork-physical-test-transport"), true);
});

test("forced H3 eligibility proves route, radio state, and carrier activity", () => {
  assert.deepEqual(evaluateEligibility(benchmark(), options()), {
    eligible: true,
    reasons: [],
  });

  const invalid = structuredClone(benchmark());
  invalid.physicalTelemetry.start.physicalPath.wifi = true;
  invalid.physicalTelemetry.end.batteryState = "charging";
  invalid.physicalTelemetry.end.thermalState = "serious";
  invalid.physicalTelemetry.packetDelta.transports = transports("h1");
  assert.deepEqual(evaluateEligibility(invalid, options({ confirmOneBar: false })), {
    eligible: false,
    reasons: [
      "one-bar-not-confirmed",
      "start-underlay-is-not-cellular-only",
      "end-thermal-state-ineligible",
      "end-external-power-connected-or-unknown",
      "expected-carrier-unused",
      "unexpected-carrier-used",
    ],
  });
});

test("Direct eligibility requires zero remote packet activity", () => {
  const direct = benchmark();
  direct.benchmarkRoute = "direct";
  direct.expectedTransportMode = "current";
  direct.physicalTelemetry.packetDelta.totals = counters();
  direct.physicalTelemetry.packetDelta.transports = transports("none");
  const directOptions = options({ route: "direct", transport: "current" });
  assert.equal(evaluateEligibility(direct, directOptions).eligible, true);
  direct.physicalTelemetry.packetDelta.totals.remoteEgressByteCount = 1;
  assert.deepEqual(evaluateEligibility(direct, directOptions).reasons, [
    "direct-used-remote-route",
  ]);
  direct.physicalTelemetry.packetDelta.totals = counters();
  direct.physicalTelemetry.packetDelta.transports = transports("h3");
  assert.deepEqual(evaluateEligibility(direct, directOptions).reasons, [
    "direct-used-remote-route",
  ]);
});

test("explicit P2P eligibility rejects an Auto carrier fallback", () => {
  const p2p = benchmark("auto", "p2p");
  assert.equal(evaluateEligibility(p2p, options({
    transport: "auto",
    expectedCarrier: "p2p",
  })).eligible, true);
  p2p.physicalTelemetry.packetDelta.transports.h3.remoteEgressByteCount = 1;
  assert.deepEqual(evaluateEligibility(p2p, options({
    transport: "auto",
    expectedCarrier: "p2p",
  })).reasons, ["unexpected-carrier-used"]);
});

test("sanitization removes URLs, provider material, and raw error text", () => {
  const raw = benchmark();
  raw.providerId = "secret-provider";
  raw.error = "navigation: secret-host.example failed";
  const sanitized = sanitizeBenchmark(raw, options());
  const json = JSON.stringify(sanitized);
  assert.equal(json.includes("private.example"), false);
  assert.equal(json.includes("secret-provider"), false);
  assert.equal(json.includes("secret-host"), false);
  assert.equal(sanitized.errorClass, "navigation");
  assert.equal(sanitized.navigationSucceeded, false);
});

test("summary requires exact results, driver cleanup, and page eligibility", () => {
  const record = sanitizeBenchmark(benchmark(), options());
  const summary = summarize([record], options(), {
    expectedResultCount: 1,
    sessionComplete: true,
    driverFailures: [],
    incompleteChunkRecordCount: 0,
  });
  assert.equal(summary.allEligible, true);
  assert.equal(summary.collectionComplete, true);
  assert.equal(summary.medianDriverFinishMs, 400);
  assert.equal(summary.transportRemoteBytes.h3, 3_000);
  assert.equal(summary.peakAppPhysicalFootprintBytes, 42_000_000);
});

test("output writer replaces existing permissions with private mode", () => {
  const directory = mkdtempSync(join(tmpdir(), "physical-capture-output-"));
  const path = join(directory, "capture.ndjson");
  try {
    writeFileSync(path, "stale\n", { mode: 0o644 });
    chmodSync(path, 0o644);
    const stdout = [];
    const emit = outputWriter(path, { write: (value) => stdout.push(value) });
    emit({ type: "summary", allEligible: true });
    assert.equal(statSync(path).mode & 0o777, 0o600);
    assert.deepEqual(
      JSON.parse(readFileSync(path, "utf8")),
      { type: "summary", allEligible: true },
    );
    assert.equal(stdout.length, 1);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
