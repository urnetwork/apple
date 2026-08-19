#!/usr/bin/env node

// Strict, privacy-safe acceptance and comparison for paired physical low-bar
// captures. Input paths and page URLs never appear in the emitted report.

import {
  chmodSync,
  readFileSync,
  realpathSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

const SCHEMA_VERSION = 1;
const CANDIDATE_MODES = ["h1", "h3", "auto"];
const TRANSPORT_TYPES = ["h3", "h1", "dns", "dnspump", "p2p", "unknown"];
const SAFE_LABEL = /^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/;
const MAX_MANIFEST_BYTES = 128 * 1024;
const MAX_RUN_BYTES = 8 * 1024 * 1024;
const MAX_CYCLES = 100;
const MAX_RECORDS_PER_RUN = 64;
function transferredBytes(page) {
  const navigationBytes = page.navigation?.transferBytes;
  const resourceBytes = page.totalTransferBytes;
  return finiteNonNegative(navigationBytes) && finiteNonNegative(resourceBytes)
    ? navigationBytes + resourceBytes : Number.NaN;
}

const PERFORMANCE_METRICS = [
  ["driverFinishMs", (page) => page.driverFinishMs],
  ["ttfbMs", (page) => page.navigation?.ttfbMs],
  ["loadMs", (page) => page.navigation?.loadMs],
  ["transferBytes", transferredBytes],
];
const DRIFT_METRICS = PERFORMANCE_METRICS;

export class CampaignError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function fail(code) {
  throw new CampaignError(code);
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function finiteNonNegative(value) {
  return Number.isFinite(value) && value >= 0;
}

function finitePositive(value) {
  return Number.isFinite(value) && value > 0;
}

function positiveNumber(value, name) {
  const number = Number(value);
  if (!finitePositive(number)) throw new Error(`${name} must be positive`);
  return number;
}

function positiveInteger(value, name) {
  const number = positiveNumber(value, name);
  if (!Number.isSafeInteger(number)) throw new Error(`${name} must be an integer`);
  return number;
}

function requireValue(argv, index, option) {
  const value = argv[index + 1];
  if (value === undefined || value.startsWith("--")) {
    throw new Error(`${option} requires a value`);
  }
  return value;
}

export function parseArgs(argv) {
  const options = {
    manifest: undefined,
    minCycles: 5,
    maxDirectDriftPercent: 35,
    maxCycleMinutes: 60,
    output: undefined,
    help: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    const next = () => {
      const value = requireValue(argv, index, option);
      index += 1;
      return value;
    };
    switch (option) {
      case "--manifest": options.manifest = next(); break;
      case "--min-cycles":
        options.minCycles = positiveInteger(next(), "min-cycles");
        break;
      case "--max-direct-drift-percent":
        options.maxDirectDriftPercent = positiveNumber(
          next(), "max-direct-drift-percent",
        );
        break;
      case "--max-cycle-minutes":
        options.maxCycleMinutes = positiveNumber(next(), "max-cycle-minutes");
        break;
      case "--output": options.output = next(); break;
      case "--help":
      case "-h": options.help = true; break;
      default: throw new Error(`unknown option: ${option}`);
    }
  }
  if (!options.help && options.manifest === undefined) {
    throw new Error("--manifest is required");
  }
  return options;
}

export function usage() {
  return [
    "usage: physical_lowbar_compare.mjs --manifest FILE [options]",
    "",
    "options:",
    "  --min-cycles COUNT                  minimum accepted cycles (default 5)",
    "  --max-direct-drift-percent PERCENT  per-page bracket drift (default 35)",
    "  --max-cycle-minutes MINUTES         elapsed cycle limit (default 60)",
    "  --output FILE                       also write the sanitized report",
  ].join("\n");
}

function parseJsonObject(json, code) {
  let value;
  try {
    value = JSON.parse(json);
  } catch {
    fail(code);
  }
  if (!isObject(value)) fail(code);
  return value;
}

export function parseManifest(json) {
  if (Buffer.byteLength(json, "utf8") > MAX_MANIFEST_BYTES) {
    fail("manifest-too-large");
  }
  const value = parseJsonObject(json, "manifest-invalid");
  if (value.schemaVersion !== SCHEMA_VERSION ||
      !SAFE_LABEL.test(value.campaignLabel ?? "") ||
      !Array.isArray(value.cycles) ||
      value.cycles.length === 0 || value.cycles.length > MAX_CYCLES) {
    fail("manifest-invalid");
  }
  const cycleLabels = new Set();
  const runReferences = new Set();
  const cycles = value.cycles.map((cycle) => {
    if (!isObject(cycle) || !SAFE_LABEL.test(cycle.label ?? "") ||
        cycleLabels.has(cycle.label) || !Array.isArray(cycle.order) ||
        cycle.order.length !== CANDIDATE_MODES.length ||
        new Set(cycle.order).size !== CANDIDATE_MODES.length ||
        !CANDIDATE_MODES.every((mode) => cycle.order.includes(mode))) {
      fail("manifest-cycle-invalid");
    }
    cycleLabels.add(cycle.label);
    const references = [
      cycle.directBefore,
      ...CANDIDATE_MODES.map((mode) => cycle[mode]),
      cycle.directAfter,
    ];
    if (references.some((reference) =>
      typeof reference !== "string" || reference.length === 0 ||
      reference.length > 4_096 || runReferences.has(reference))) {
      fail("manifest-run-reference-invalid");
    }
    for (const reference of references) runReferences.add(reference);
    return {
      label: cycle.label,
      directBefore: cycle.directBefore,
      order: [...cycle.order],
      h1: cycle.h1,
      h3: cycle.h3,
      auto: cycle.auto,
      directAfter: cycle.directAfter,
    };
  });
  return {
    schemaVersion: SCHEMA_VERSION,
    campaignLabel: value.campaignLabel,
    cycles,
  };
}

export function parseRunNdjson(json) {
  if (Buffer.byteLength(json, "utf8") > MAX_RUN_BYTES) fail("run-too-large");
  const lines = json.split(/\r?\n/).filter((line) => line.trim().length > 0);
  if (lines.length < 2 || lines.length > MAX_RECORDS_PER_RUN) {
    fail("run-record-count-invalid");
  }
  const records = lines.map((line) => parseJsonObject(line, "run-record-invalid"));
  const summaries = records.filter((record) => record.type === "summary");
  const pages = records.filter((record) => record.type === "page");
  if (summaries.length !== 1 || pages.length !== records.length - 1 ||
      records.at(-1)?.type !== "summary") {
    fail("run-shape-invalid");
  }
  return { pages, summary: summaries[0] };
}

function counterRemoteBytes(counters) {
  if (!isObject(counters)) return null;
  const egress = counters.remoteEgressByteCount;
  const ingress = counters.remoteIngressByteCount;
  return finiteNonNegative(egress) && finiteNonNegative(ingress)
    ? egress + ingress : null;
}

function pageRemoteBytes(page) {
  const transports = page.physicalTelemetry?.packetDelta?.transports;
  if (!isObject(transports)) fail("run-packet-telemetry-invalid");
  let total = 0;
  const byTransport = {};
  for (const transport of TRANSPORT_TYPES) {
    const bytes = counterRemoteBytes(transports[transport]);
    if (bytes === null) fail("run-packet-telemetry-invalid");
    byTransport[transport] = bytes;
    total += bytes;
  }
  return { total, byTransport };
}

function pathFingerprint(path) {
  if (!isObject(path)) fail("run-path-invalid");
  const fingerprint = {
    status: path.status,
    expensive: path.expensive,
    constrained: path.constrained,
    cellular: path.cellular,
    wifi: path.wifi,
    wiredEthernet: path.wiredEthernet,
    supportsIPv4: path.supportsIPv4,
    supportsIPv6: path.supportsIPv6,
    supportsDNS: path.supportsDNS,
  };
  if (typeof fingerprint.status !== "string" ||
      Object.entries(fingerprint).some(([key, item]) =>
        key !== "status" && typeof item !== "boolean")) {
    fail("run-path-invalid");
  }
  return JSON.stringify(fingerprint);
}

function validateEndpoint(snapshot, route, requestedMode) {
  if (!isObject(snapshot) || snapshot.lowPowerMode !== false ||
      !["nominal", "fair"].includes(snapshot.thermalState) ||
      snapshot.batteryState !== "unplugged") {
    fail("run-environment-ineligible");
  }
  const path = snapshot.physicalPath;
  if (!isObject(path) || path.status !== "satisfied" ||
      path.cellular !== true || path.wifi !== false ||
      path.wiredEthernet !== false || path.supportsIPv4 !== true ||
      path.supportsDNS !== true) {
    fail("run-environment-ineligible");
  }
  if (route === "vpn" &&
      (!isObject(snapshot.transportSettings) ||
       snapshot.transportSettings.mode !== requestedMode)) {
    fail("run-transport-settings-mismatch");
  }
}

function expectedRoute(mode) {
  return mode === "direct" ? "direct" : "vpn";
}

function expectedRequestedMode(mode) {
  return mode === "direct" ? "current" : mode;
}

function validateRun(run, mode) {
  const { pages, summary } = run;
  const route = expectedRoute(mode);
  const requestedMode = expectedRequestedMode(mode);
  if (summary.schemaVersion !== SCHEMA_VERSION ||
      !SAFE_LABEL.test(summary.runLabel ?? "") ||
      summary.benchmarkRoute !== route ||
      summary.requestedTransportMode !== requestedMode ||
      summary.oneBarConfirmed !== true ||
      summary.collectionComplete !== true || summary.allEligible !== true ||
      summary.collectionFailure !== undefined ||
      !Array.isArray(summary.driverFailures) || summary.driverFailures.length !== 0 ||
      summary.incompleteChunkRecordCount !== 0 ||
      summary.expectedResultCount !== pages.length ||
      summary.resultCount !== pages.length ||
      summary.eligibleResultCount !== pages.length) {
    fail("run-summary-ineligible");
  }
  if ((mode === "h1" || mode === "h3") &&
      summary.expectedCarrier !== mode) {
    fail("run-carrier-mismatch");
  }
  if ((mode === "direct" || mode === "auto") &&
      summary.expectedCarrier !== null && summary.expectedCarrier !== undefined) {
    fail("run-carrier-mismatch");
  }

  const labels = [];
  const seenLabels = new Set();
  let startTime = Infinity;
  let endTime = -Infinity;
  let previousEnd = -Infinity;
  let fingerprint;
  let peakFootprintBytes = 0;
  const pageValues = new Map();
  const transportRemoteBytes = Object.fromEntries(
    TRANSPORT_TYPES.map((transport) => [transport, 0]),
  );
  for (const page of pages) {
    if (page.schemaVersion !== SCHEMA_VERSION || page.type !== "page" ||
        page.runLabel !== summary.runLabel || !SAFE_LABEL.test(page.label ?? "") ||
        seenLabels.has(page.label) || page.benchmarkRoute !== route ||
        page.expectedTransportMode !== requestedMode ||
        page.oneBarConfirmed !== true || page.navigationSucceeded !== true ||
        page.errorClass !== null || page.eligibility?.eligible !== true ||
        !Array.isArray(page.eligibility?.reasons) ||
        page.eligibility.reasons.length !== 0 ||
        !finiteNonNegative(page.routeReadinessMs)) {
      fail("run-page-ineligible");
    }
    for (const [, getValue] of PERFORMANCE_METRICS) {
      if (!finitePositive(getValue(page))) fail("run-metric-invalid");
    }
    const start = page.physicalTelemetry?.start;
    const end = page.physicalTelemetry?.end;
    if (!isObject(start) || !isObject(end) ||
        !finiteNonNegative(start.timeUnixMs) ||
        !finiteNonNegative(end.timeUnixMs) ||
        start.timeUnixMs > end.timeUnixMs || start.timeUnixMs < previousEnd ||
        !finitePositive(start.appPhysicalFootprintBytes) ||
        !finitePositive(end.appPhysicalFootprintBytes)) {
      fail("run-timeline-invalid");
    }
    validateEndpoint(start, route, requestedMode);
    validateEndpoint(end, route, requestedMode);
    const startFingerprint = pathFingerprint(start.physicalPath);
    const endFingerprint = pathFingerprint(end.physicalPath);
    if (startFingerprint !== endFingerprint ||
        (fingerprint !== undefined && fingerprint !== startFingerprint)) {
      fail("run-path-changed");
    }
    fingerprint = startFingerprint;
    startTime = Math.min(startTime, start.timeUnixMs);
    endTime = Math.max(endTime, end.timeUnixMs);
    previousEnd = end.timeUnixMs;
    peakFootprintBytes = Math.max(
      peakFootprintBytes,
      start.appPhysicalFootprintBytes,
      end.appPhysicalFootprintBytes,
    );
    const packetDelta = page.physicalTelemetry?.packetDelta;
    if (!isObject(packetDelta) || packetDelta.counterResetDetected !== false) {
      fail("run-packet-telemetry-invalid");
    }
    const remote = pageRemoteBytes(page);
    const aggregateRemoteBytes = counterRemoteBytes(packetDelta.totals);
    if (aggregateRemoteBytes === null || aggregateRemoteBytes !== remote.total) {
      fail("run-packet-telemetry-invalid");
    }
    if (mode === "direct" && remote.total !== 0) {
      fail("direct-remote-traffic-detected");
    }
    if (mode !== "direct" && remote.total === 0) {
      fail("vpn-remote-traffic-missing");
    }
    if ((mode === "h1" || mode === "h3") &&
        (remote.byTransport[mode] === 0 || TRANSPORT_TYPES.some(
          (transport) => transport !== mode && remote.byTransport[transport] > 0,
        ))) {
      fail("run-carrier-mismatch");
    }
    if (mode === "auto" && !TRANSPORT_TYPES.some(
      (transport) => transport !== "unknown" && remote.byTransport[transport] > 0,
    )) {
      fail("run-carrier-mismatch");
    }
    for (const transport of TRANSPORT_TYPES) {
      transportRemoteBytes[transport] += remote.byTransport[transport];
    }
    labels.push(page.label);
    seenLabels.add(page.label);
    pageValues.set(page.label, {
      driverFinishMs: page.driverFinishMs,
      ttfbMs: page.navigation.ttfbMs,
      loadMs: page.navigation.loadMs,
      transferBytes: transferredBytes(page),
      resourceCount: page.resourceCount,
      originCount: page.originCount,
      routeReadinessMs: page.routeReadinessMs,
      remoteBytes: remote.total,
      remoteBytesByTransport: remote.byTransport,
    });
  }
  if (!isObject(summary.transportRemoteBytes)) {
    fail("run-summary-packet-totals-mismatch");
  }
  for (const transport of TRANSPORT_TYPES) {
    if (summary.transportRemoteBytes[transport] !==
        transportRemoteBytes[transport]) {
      fail("run-summary-packet-totals-mismatch");
    }
  }
  return {
    runLabel: summary.runLabel,
    labels,
    startTime,
    endTime,
    fingerprint,
    peakFootprintBytes,
    pageValues,
    transportRemoteBytes,
  };
}

function mean(left, right) {
  return (left + right) / 2;
}

function symmetricDifferencePercent(left, right) {
  if (left === 0 && right === 0) return 0;
  return Math.abs(left - right) / mean(left, right) * 100;
}

function median(values) {
  if (values.length === 0) return null;
  const ordered = [...values].sort((left, right) => left - right);
  const middle = Math.floor(ordered.length / 2);
  return ordered.length % 2 === 0
    ? mean(ordered[middle - 1], ordered[middle])
    : ordered[middle];
}

function percentile(values, percentileValue) {
  if (values.length === 0) return null;
  const ordered = [...values].sort((left, right) => left - right);
  const index = Math.ceil(percentileValue * ordered.length) - 1;
  return ordered[Math.max(0, Math.min(index, ordered.length - 1))];
}

function rounded(value) {
  return Math.round(value * 1_000) / 1_000;
}

function sameArray(left, right) {
  return left.length === right.length &&
    left.every((value, index) => value === right[index]);
}

function validateModeOrderBalance(cycles) {
  for (const mode of CANDIDATE_MODES) {
    const counts = CANDIDATE_MODES.map((_, position) =>
      cycles.filter((cycle) => cycle.order[position] === mode).length,
    );
    if (Math.max(...counts) - Math.min(...counts) > 1) {
      fail("candidate-order-unbalanced");
    }
  }
}

function aggregateMode(samples, mode, cycleCount) {
  const metrics = {};
  for (const [metric] of PERFORMANCE_METRICS) {
    const relevant = samples.filter((sample) => sample.mode === mode);
    const ratios = relevant.map((sample) => sample[metric] / sample.direct[metric]);
    const improvements = ratios.map((ratio) => (1 - ratio) * 100);
    metrics[metric] = {
      sampleCount: relevant.length,
      medianCandidate: rounded(median(relevant.map((sample) => sample[metric]))),
      medianBracketedDirect: rounded(
        median(relevant.map((sample) => sample.direct[metric])),
      ),
      medianImprovementPercent: rounded(median(improvements)),
      p95CandidateToDirectRatio: rounded(percentile(ratios, 0.95)),
      winCount: improvements.filter((improvement) => improvement > 0).length,
    };
  }
  const relevant = samples.filter((sample) => sample.mode === mode);
  const remoteBytes = relevant.map((sample) => sample.remoteBytes);
  const transferBytes = relevant.map((sample) => sample.transferBytes);
  const readiness = relevant.map((sample) => sample.routeReadinessMs);
  const byTransport = Object.fromEntries(TRANSPORT_TYPES.map((transport) => [
    transport,
    relevant.reduce((total, sample) =>
      total + sample.transportRemoteBytes[transport], 0),
  ]));
  return {
    cycleCount,
    pageSampleCount: relevant.length,
    metrics,
    medianRouteReadinessMs: rounded(median(readiness)),
    remoteBytesPerTransferByte: rounded(
      remoteBytes.reduce((total, value) => total + value, 0) /
      transferBytes.reduce((total, value) => total + value, 0),
    ),
    transportRemoteBytes: byTransport,
  };
}

export function analyzeCampaign(manifest, loadRun, options = {}) {
  const minCycles = options.minCycles ?? 5;
  const maxDirectDriftPercent = options.maxDirectDriftPercent ?? 35;
  const maxCycleMinutes = options.maxCycleMinutes ?? 60;
  if (!Number.isSafeInteger(minCycles) || minCycles <= 0 ||
      !finitePositive(maxDirectDriftPercent) || !finitePositive(maxCycleMinutes)) {
    fail("analysis-options-invalid");
  }
  if (manifest.cycles.length < minCycles) fail("campaign-too-few-cycles");
  validateModeOrderBalance(manifest.cycles);

  const samples = [];
  const cycleReports = [];
  let campaignLabels;
  let campaignFingerprint;
  const observedRunLabels = new Set();
  let previousCycleEnd = -Infinity;
  for (const [cycleIndex, cycle] of manifest.cycles.entries()) {
    const roleModes = [
      ["directBefore", "direct"],
      ...cycle.order.map((mode) => [mode, mode]),
      ["directAfter", "direct"],
    ];
    const runs = {};
    for (const [role, mode] of roleModes) {
      let rawRun;
      try {
        rawRun = loadRun(cycle[role]);
      } catch (error) {
        if (error instanceof CampaignError) throw error;
        fail("run-read-failed");
      }
      runs[role] = validateRun(rawRun, mode);
      if (observedRunLabels.has(runs[role].runLabel)) {
        fail("campaign-run-label-reused");
      }
      observedRunLabels.add(runs[role].runLabel);
    }
    const labels = runs.directBefore.labels;
    for (const [role] of roleModes) {
      if (!sameArray(runs[role].labels, labels)) fail("campaign-page-set-mismatch");
      if (runs[role].fingerprint !== runs.directBefore.fingerprint) {
        fail("campaign-path-changed");
      }
    }
    if (campaignLabels === undefined) campaignLabels = labels;
    else if (!sameArray(campaignLabels, labels)) fail("campaign-page-set-mismatch");
    if (campaignFingerprint === undefined) {
      campaignFingerprint = runs.directBefore.fingerprint;
    } else if (campaignFingerprint !== runs.directBefore.fingerprint) {
      fail("campaign-path-changed");
    }

    let priorEnd = previousCycleEnd;
    for (const [role] of roleModes) {
      if (runs[role].startTime < priorEnd) fail("campaign-order-invalid");
      priorEnd = runs[role].endTime;
    }
    const cycleElapsedMs = runs.directAfter.endTime - runs.directBefore.startTime;
    if (cycleElapsedMs > maxCycleMinutes * 60_000) fail("campaign-cycle-too-long");
    previousCycleEnd = runs.directAfter.endTime;

    let peakDirectDriftPercent = 0;
    for (const label of labels) {
      const before = runs.directBefore.pageValues.get(label);
      const after = runs.directAfter.pageValues.get(label);
      if (!Number.isSafeInteger(before.resourceCount) || before.resourceCount < 0 ||
          !Number.isSafeInteger(before.originCount) || before.originCount < 0 ||
          before.resourceCount !== after.resourceCount ||
          before.originCount !== after.originCount ||
          CANDIDATE_MODES.some((mode) => {
            const candidate = runs[mode].pageValues.get(label);
            return candidate.resourceCount !== before.resourceCount ||
              candidate.originCount !== before.originCount;
          })) {
        fail("campaign-content-shape-changed");
      }
      for (const [metric] of DRIFT_METRICS) {
        const drift = symmetricDifferencePercent(before[metric], after[metric]);
        peakDirectDriftPercent = Math.max(peakDirectDriftPercent, drift);
        if (drift > maxDirectDriftPercent) fail("direct-bracket-drift-exceeded");
      }
      const direct = Object.fromEntries(PERFORMANCE_METRICS.map(([metric]) => [
        metric,
        mean(before[metric], after[metric]),
      ]));
      for (const mode of CANDIDATE_MODES) {
        const candidate = runs[mode].pageValues.get(label);
        samples.push({
          mode,
          direct,
          ...candidate,
          transportRemoteBytes: candidate.remoteBytesByTransport,
        });
      }
    }
    cycleReports.push({
      cycle: cycleIndex + 1,
      label: cycle.label,
      order: [...cycle.order],
      pageCount: labels.length,
      elapsedMs: rounded(cycleElapsedMs),
      peakDirectDriftPercent: rounded(peakDirectDriftPercent),
      peakAppPhysicalFootprintBytes: Math.max(
        ...Object.values(runs).map((run) => run.peakFootprintBytes),
      ),
    });
  }

  return {
    schemaVersion: SCHEMA_VERSION,
    type: "physical-lowbar-comparison",
    campaignLabel: manifest.campaignLabel,
    accepted: true,
    cycleCount: manifest.cycles.length,
    pageLabels: [...campaignLabels],
    gates: {
      minCycles,
      maxDirectDriftPercent,
      maxCycleMinutes,
      pathStable: true,
      chronologyValid: true,
      candidateOrderBalanced: true,
    },
    cycles: cycleReports,
    modes: Object.fromEntries(CANDIDATE_MODES.map((mode) => [
      mode,
      aggregateMode(samples, mode, manifest.cycles.length),
    ])),
  };
}

function boundedRead(path, maximumBytes, failureCode) {
  try {
    const stats = statSync(path);
    if (!stats.isFile() || stats.size > maximumBytes) fail(failureCode);
    return readFileSync(path, "utf8");
  } catch (error) {
    if (error instanceof CampaignError) throw error;
    fail(failureCode);
  }
}

export function analyzeManifestFile(manifestPath, options = {}) {
  let canonicalManifestPath;
  try {
    canonicalManifestPath = realpathSync(manifestPath);
  } catch {
    fail("manifest-read-failed");
  }
  const manifest = parseManifest(
    boundedRead(canonicalManifestPath, MAX_MANIFEST_BYTES, "manifest-read-failed"),
  );
  const baseDirectory = dirname(canonicalManifestPath);
  const canonicalRuns = new Set();
  const loadRun = (reference) => {
    let path;
    try {
      path = realpathSync(resolve(baseDirectory, reference));
    } catch {
      fail("run-read-failed");
    }
    if (canonicalRuns.has(path)) fail("run-file-reused");
    canonicalRuns.add(path);
    return parseRunNdjson(boundedRead(path, MAX_RUN_BYTES, "run-read-failed"));
  };
  return analyzeCampaign(manifest, loadRun, options);
}

async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`physical comparison arguments: ${error.message}\n`);
    process.exitCode = 1;
    return;
  }
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return;
  }
  try {
    const report = analyzeManifestFile(options.manifest, options);
    const output = `${JSON.stringify(report, null, 2)}\n`;
    process.stdout.write(output);
    if (options.output !== undefined) {
      writeFileSync(options.output, output, { mode: 0o600 });
      chmodSync(options.output, 0o600);
    }
  } catch (error) {
    process.stderr.write(
      `physical comparison: ${error instanceof CampaignError ? error.code : "analysis-failed"}\n`,
    );
    process.exitCode = 1;
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  await main();
}
