import assert from "node:assert/strict";
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
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  CampaignError,
  analyzeCampaign,
  analyzeManifestFile,
  parseArgs,
  parseManifest,
  parseRunNdjson,
} from "./physical_lowbar_compare.mjs";

const modes = ["h1", "h3", "auto"];
const transports = ["h3", "h1", "dns", "dnspump", "p2p", "unknown"];
const orders = [
  ["h1", "h3", "auto"],
  ["h3", "auto", "h1"],
  ["auto", "h1", "h3"],
  ["h1", "h3", "auto"],
  ["h3", "auto", "h1"],
];

function path() {
  return {
    status: "satisfied",
    expensive: true,
    constrained: false,
    cellular: true,
    wifi: false,
    wiredEthernet: false,
    supportsIPv4: true,
    supportsIPv6: true,
    supportsDNS: true,
  };
}

function counters(bytes = 0) {
  return {
    remoteEgressPacketCount: bytes === 0 ? 0 : 4,
    remoteEgressByteCount: bytes / 3,
    remoteIngressPacketCount: bytes === 0 ? 0 : 6,
    remoteIngressByteCount: bytes * 2 / 3,
    localEgressPacketCount: 0,
    localEgressByteCount: 0,
    localIngressPacketCount: 0,
    localIngressByteCount: 0,
    blockEgressPacketCount: 0,
    blockEgressByteCount: 0,
    blockIngressPacketCount: 0,
    blockIngressByteCount: 0,
  };
}

function transportCounters(mode, remoteBytes) {
  const values = Object.fromEntries(transports.map((transport) => [
    transport,
    counters(),
  ]));
  if (mode === "auto") {
    values.h3 = counters(remoteBytes / 2);
    values.h1 = counters(remoteBytes / 2);
  } else if (mode !== "direct") {
    values[mode] = counters(remoteBytes);
  }
  return values;
}

function timingMultiplier(mode) {
  return {
    direct: 1,
    h1: 0.8,
    h3: 0.6,
    auto: 0.5,
  }[mode];
}

function page(mode, label, startTime, timingScale = 1) {
  const multiplier = timingMultiplier(mode) * timingScale;
  const remoteBytes = mode === "direct" ? 0 : 12_000;
  const requestedMode = mode === "direct" ? "current" : mode;
  const route = mode === "direct" ? "direct" : "vpn";
  const transportValues = transportCounters(mode, remoteBytes);
  return {
    schemaVersion: 1,
    type: "page",
    runLabel: `run-${startTime}`,
    oneBarConfirmed: true,
    label,
    requestedUrl: "https://secret.example/private?token=do-not-emit",
    benchmarkRoute: route,
    expectedTransportMode: requestedMode,
    routeReadinessMs: 100 * multiplier,
    navigationSucceeded: true,
    errorClass: null,
    driverFinishMs: 1_000 * multiplier,
    navigation: {
      ttfbMs: 400 * multiplier,
      loadMs: 900 * multiplier,
      transferBytes: 0,
    },
    resourceCount: 4,
    originCount: 2,
    totalTransferBytes: 10_000 * multiplier,
    physicalTelemetry: {
      start: {
        timeUnixMs: startTime,
        appPhysicalFootprintBytes: 40_000_000,
        lowPowerMode: false,
        thermalState: "nominal",
        batteryState: "unplugged",
        physicalPath: path(),
        transportSettings: { mode: requestedMode, autoModes: modes },
      },
      end: {
        timeUnixMs: startTime + 1_000,
        appPhysicalFootprintBytes: 42_000_000,
        lowPowerMode: false,
        thermalState: "nominal",
        batteryState: "unplugged",
        physicalPath: path(),
        transportSettings: { mode: requestedMode, autoModes: modes },
      },
      packetDelta: {
        totals: counters(remoteBytes),
        transports: transportValues,
        counterResetDetected: false,
      },
    },
    eligibility: { eligible: true, reasons: [] },
  };
}

function run(mode, startTime, timingScale = 1) {
  const pages = [
    page(mode, "small-web", startTime, timingScale),
    page(mode, "large-web", startTime + 2_000, timingScale),
  ];
  for (const pageValue of pages) pageValue.runLabel = `run-${startTime}`;
  const requestedMode = mode === "direct" ? "current" : mode;
  const route = mode === "direct" ? "direct" : "vpn";
  const remoteBytes = mode === "direct" ? 0 : 24_000;
  return {
    pages,
    summary: {
      schemaVersion: 1,
      type: "summary",
      runLabel: pages[0].runLabel,
      benchmarkRoute: route,
      requestedTransportMode: requestedMode,
      expectedCarrier: ["h1", "h3"].includes(mode) ? mode : null,
      oneBarConfirmed: true,
      expectedResultCount: pages.length,
      resultCount: pages.length,
      eligibleResultCount: pages.length,
      allEligible: true,
      collectionComplete: true,
      driverFailures: [],
      incompleteChunkRecordCount: 0,
      transportRemoteBytes: Object.fromEntries(transports.map((transport) => [
        transport,
        mode === "auto" && ["h1", "h3"].includes(transport)
          ? remoteBytes / 2
          : transport === mode ? remoteBytes : 0,
      ])),
    },
  };
}

function campaignFixture() {
  const runs = new Map();
  const cycles = orders.map((order, cycleIndex) => {
    const base = 1_800_000_000_000 + cycleIndex * 100_000;
    const cycle = {
      label: `cycle-${cycleIndex + 1}`,
      directBefore: `cycle-${cycleIndex + 1}-before`,
      order: [...order],
      h1: `cycle-${cycleIndex + 1}-h1`,
      h3: `cycle-${cycleIndex + 1}-h3`,
      auto: `cycle-${cycleIndex + 1}-auto`,
      directAfter: `cycle-${cycleIndex + 1}-after`,
    };
    const chronology = ["directBefore", ...order, "directAfter"];
    chronology.forEach((role, position) => {
      const mode = role.startsWith("direct") ? "direct" : role;
      runs.set(cycle[role], run(mode, base + position * 10_000));
    });
    return cycle;
  });
  return {
    manifest: {
      schemaVersion: 1,
      campaignLabel: "one-bar-campaign",
      cycles,
    },
    runs,
  };
}

function expectCampaignError(code, action) {
  assert.throws(action, (error) =>
    error instanceof CampaignError && error.code === code,
  );
}

test("arguments and manifests require explicit bounded campaign structure", () => {
  assert.deepEqual(parseArgs(["--manifest", "campaign.json"]), {
    manifest: "campaign.json",
    minCycles: 5,
    maxDirectDriftPercent: 35,
    maxCycleMinutes: 60,
    output: undefined,
    help: false,
  });
  assert.throws(() => parseArgs([]), /manifest is required/);
  const { manifest } = campaignFixture();
  assert.deepEqual(parseManifest(JSON.stringify(manifest)), manifest);
  const invalid = structuredClone(manifest);
  invalid.cycles[0].order = ["h1", "h1", "auto"];
  expectCampaignError(
    "manifest-cycle-invalid",
    () => parseManifest(JSON.stringify(invalid)),
  );
});

test("analyzer accepts balanced Direct-bracketed cycles and reports gains", () => {
  const { manifest, runs } = campaignFixture();
  const report = analyzeCampaign(manifest, (reference) => runs.get(reference));
  assert.equal(report.accepted, true);
  assert.equal(report.cycleCount, 5);
  assert.deepEqual(report.pageLabels, ["small-web", "large-web"]);
  assert.equal(report.modes.h3.pageSampleCount, 10);
  assert.equal(report.modes.h3.metrics.driverFinishMs.medianImprovementPercent, 40);
  assert.equal(report.modes.h1.metrics.ttfbMs.medianImprovementPercent, 20);
  assert.equal(report.modes.auto.metrics.loadMs.medianImprovementPercent, 50);
  assert.equal(report.modes.h3.metrics.driverFinishMs.winCount, 10);
  assert.equal(report.modes.h3.remoteBytesPerTransferByte, 2);
  assert.equal(report.modes.auto.transportRemoteBytes.h3, 60_000);
  assert.equal(JSON.stringify(report).includes("secret.example"), false);
  assert.equal(JSON.stringify(report).includes("cycle-1-h3"), false);
});

test("analyzer rejects ineligible summaries, routes, and page-set changes", () => {
  const ineligible = campaignFixture();
  ineligible.runs.get("cycle-1-h3").summary.allEligible = false;
  expectCampaignError(
    "run-summary-ineligible",
    () => analyzeCampaign(ineligible.manifest, (reference) => ineligible.runs.get(reference)),
  );

  const routeMismatch = campaignFixture();
  routeMismatch.runs.get("cycle-1-h1").pages[0].benchmarkRoute = "direct";
  expectCampaignError(
    "run-page-ineligible",
    () => analyzeCampaign(
      routeMismatch.manifest,
      (reference) => routeMismatch.runs.get(reference),
    ),
  );

  const pageMismatch = campaignFixture();
  pageMismatch.runs.get("cycle-2-auto").pages[1].label = "different-page";
  expectCampaignError(
    "campaign-page-set-mismatch",
    () => analyzeCampaign(pageMismatch.manifest, (reference) => pageMismatch.runs.get(reference)),
  );

  const contentMismatch = campaignFixture();
  contentMismatch.runs.get("cycle-2-h1").pages[1].resourceCount += 1;
  expectCampaignError(
    "campaign-content-shape-changed",
    () => analyzeCampaign(
      contentMismatch.manifest,
      (reference) => contentMismatch.runs.get(reference),
    ),
  );
});

test("analyzer rejects path changes and nonchronological captures", () => {
  const pathChange = campaignFixture();
  pathChange.runs.get("cycle-3-h3").pages[1]
    .physicalTelemetry.end.physicalPath.constrained = true;
  expectCampaignError(
    "run-path-changed",
    () => analyzeCampaign(pathChange.manifest, (reference) => pathChange.runs.get(reference)),
  );

  const chronology = campaignFixture();
  const h3 = chronology.runs.get("cycle-1-h3");
  for (const pageValue of h3.pages) {
    pageValue.physicalTelemetry.start.timeUnixMs -= 30_000;
    pageValue.physicalTelemetry.end.timeUnixMs -= 30_000;
  }
  expectCampaignError(
    "campaign-order-invalid",
    () => analyzeCampaign(chronology.manifest, (reference) => chronology.runs.get(reference)),
  );
});

test("analyzer rejects unstable Direct brackets", () => {
  const { manifest, runs } = campaignFixture();
  const after = runs.get("cycle-4-after");
  for (const pageValue of after.pages) pageValue.driverFinishMs *= 3;
  expectCampaignError(
    "direct-bracket-drift-exceeded",
    () => analyzeCampaign(manifest, (reference) => runs.get(reference)),
  );
});

test("analyzer rejects positional bias in candidate ordering", () => {
  const { manifest, runs } = campaignFixture();
  for (const cycle of manifest.cycles) cycle.order = ["h1", "h3", "auto"];
  expectCampaignError(
    "candidate-order-unbalanced",
    () => analyzeCampaign(manifest, (reference) => runs.get(reference)),
  );
});

test("NDJSON parsing requires pages followed by exactly one summary", () => {
  const value = run("h3", 1_800_000_000_000);
  const ndjson = [...value.pages, value.summary]
    .map((record) => JSON.stringify(record)).join("\n");
  assert.equal(parseRunNdjson(ndjson).pages.length, 2);
  expectCampaignError(
    "run-shape-invalid",
    () => parseRunNdjson(`${JSON.stringify(value.summary)}\n${JSON.stringify(value.pages[0])}`),
  );
});

test("file analysis keeps manifest paths, run paths, and raw fields private", () => {
  const temporaryDirectory = mkdtempSync(join(tmpdir(), "physical-lowbar-"));
  try {
    const { manifest, runs } = campaignFixture();
    for (const [reference, value] of runs) {
      const ndjson = [...value.pages, value.summary]
        .map((record) => JSON.stringify(record)).join("\n");
      writeFileSync(join(temporaryDirectory, reference), `${ndjson}\n`);
    }
    const manifestPath = join(temporaryDirectory, "private-manifest.json");
    writeFileSync(manifestPath, JSON.stringify(manifest));
    const report = analyzeManifestFile(manifestPath);
    const encoded = JSON.stringify(report);
    assert.equal(encoded.includes(temporaryDirectory), false);
    assert.equal(encoded.includes("secret.example"), false);

    const outputPath = join(temporaryDirectory, "report.json");
    writeFileSync(outputPath, "stale\n", { mode: 0o644 });
    chmodSync(outputPath, 0o644);
    const result = spawnSync(process.execPath, [
      fileURLToPath(new URL("./physical_lowbar_compare.mjs", import.meta.url)),
      "--manifest", manifestPath,
      "--output", outputPath,
    ], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(result.stdout).accepted, true);
    assert.equal(JSON.parse(readFileSync(outputPath, "utf8")).accepted, true);
    assert.equal(statSync(outputPath).mode & 0o777, 0o600);
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});
