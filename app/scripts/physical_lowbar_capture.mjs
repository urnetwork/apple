#!/usr/bin/env node

// Privacy-safe host launcher and acceptance gate for physical iOS low-bar
// runs. Raw devicectl output stays in memory. Only an explicit allow-list of
// benchmark timing, route, transport, path, resource, and packet-counter data
// is written as NDJSON.

import { spawn } from "node:child_process";
import {
  appendFileSync,
  chmodSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import process from "node:process";
import { pathToFileURL } from "node:url";

const SCHEMA_VERSION = 1;
const BUNDLE_ID = "network.ur";
const RESULT_PREFIX = "[PhysicalPageBenchmark] ";
const CHUNK_PREFIX = "[PhysicalPageBenchmarkChunk] ";
const SESSION_COMPLETE = "[PhysicalPeerTest] benchmark session complete";
const MAX_SUITE_BYTE_COUNT = 64 * 1024;
const MAX_RESULT_BASE64_BYTE_COUNT = 4 * 1024 * 1024;
const MAX_CHUNK_COUNT = 8_192;
const SAFE_LABEL = /^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/;
const SAFE_BUNDLE_ID = /^[A-Za-z0-9][A-Za-z0-9.-]{0,199}$/;
const ROUTES = new Set(["direct", "vpn"]);
const MODES = new Set(["current", "auto", "h3", "h1", "dns", "dnspump"]);
const TRANSPORT_TYPES = ["h3", "h1", "dns", "dnspump", "p2p", "unknown"];
const EXPECTED_CARRIERS = new Set(TRANSPORT_TYPES.filter((type) => type !== "unknown"));
const COUNTER_KEYS = [
  "remoteEgressPacketCount",
  "remoteEgressByteCount",
  "remoteIngressPacketCount",
  "remoteIngressByteCount",
  "localEgressPacketCount",
  "localEgressByteCount",
  "localIngressPacketCount",
  "localIngressByteCount",
  "blockEgressPacketCount",
  "blockEgressByteCount",
  "blockIngressPacketCount",
  "blockIngressByteCount",
];

class CaptureError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function requireValue(argv, index, option) {
  const value = argv[index + 1];
  if (value === undefined || value.startsWith("--")) {
    throw new Error(`${option} requires a value`);
  }
  return value;
}

function positiveNumber(value, name) {
  const number = Number(value);
  if (!Number.isFinite(number) || number <= 0) {
    throw new Error(`${name} must be a positive number`);
  }
  return number;
}

export function parseArgs(argv) {
  const options = {
    device: undefined,
    bundleId: BUNDLE_ID,
    route: "vpn",
    transport: "current",
    peer: undefined,
    expectedCarrier: undefined,
    runLabel: "physical-lowbar",
    suiteFile: undefined,
    suiteJson: undefined,
    timeoutSeconds: undefined,
    output: undefined,
    confirmOneBar: false,
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
      case "--device": options.device = next(); break;
      case "--bundle-id": options.bundleId = next(); break;
      case "--route": options.route = next(); break;
      case "--transport": options.transport = next(); break;
      case "--peer": options.peer = next(); break;
      case "--expected-carrier": options.expectedCarrier = next(); break;
      case "--run-label": options.runLabel = next(); break;
      case "--suite-file": options.suiteFile = next(); break;
      case "--suite-json": options.suiteJson = next(); break;
      case "--timeout-seconds":
        options.timeoutSeconds = positiveNumber(next(), "timeout-seconds");
        break;
      case "--output": options.output = next(); break;
      case "--confirm-one-bar": options.confirmOneBar = true; break;
      case "--help":
      case "-h": options.help = true; break;
      default: throw new Error(`unknown option: ${option}`);
    }
  }

  if (options.help) return options;
  if (!options.device) throw new Error("--device is required");
  if (!SAFE_BUNDLE_ID.test(options.bundleId)) {
    throw new Error("bundle-id is invalid");
  }
  if (!ROUTES.has(options.route)) throw new Error("route must be direct or vpn");
  if (!MODES.has(options.transport)) throw new Error("transport is invalid");
  if (!SAFE_LABEL.test(options.runLabel)) throw new Error("run-label is invalid");
  const suiteInputCount = Number(options.suiteFile !== undefined)
    + Number(options.suiteJson !== undefined);
  if (suiteInputCount !== 1) {
    throw new Error("use exactly one of --suite-file or --suite-json");
  }
  if (options.route === "direct") {
    if (options.transport !== "current") {
      throw new Error("Direct runs cannot select a transport");
    }
    if (options.peer !== undefined) {
      throw new Error("Direct runs cannot select a provider");
    }
    if (options.expectedCarrier !== undefined) {
      throw new Error("Direct runs cannot require a VPN carrier");
    }
  }
  if (options.expectedCarrier !== undefined &&
      !EXPECTED_CARRIERS.has(options.expectedCarrier)) {
    throw new Error("expected-carrier is invalid");
  }
  if (!["current", "auto"].includes(options.transport) &&
      options.expectedCarrier !== undefined &&
      options.expectedCarrier !== options.transport) {
    throw new Error("forced transport and expected-carrier disagree");
  }
  return options;
}

export function usage() {
  return [
    "usage: physical_lowbar_capture.mjs [options]",
    "",
    "required:",
    "  --device ID                 paired CoreDevice identifier",
    "  --suite-file FILE           JSON page suite (exclusive with --suite-json)",
    "  --suite-json JSON           inline JSON page suite",
    "",
    "campaign:",
    "  --route direct|vpn          benchmark route (default vpn)",
    "  --transport MODE            current, auto, h3, h1, dns, or dnspump",
    "  --peer ID                   expected provider for a VPN run",
    "  --expected-carrier TYPE     require h3/h1/dns/dnspump/p2p packet activity",
    "  --confirm-one-bar           operator confirms one bar at run start",
    "  --run-label LABEL           privacy-safe correlation label",
    "  --timeout-seconds SECONDS   collection deadline",
    "  --output FILE               also write sanitized NDJSON to FILE",
    "  --bundle-id ID              Debug app bundle id (default network.ur)",
  ].join("\n");
}

export function parseSuite(json) {
  if (Buffer.byteLength(json, "utf8") > MAX_SUITE_BYTE_COUNT) {
    throw new Error("suite is too large");
  }
  let value;
  try {
    value = JSON.parse(json);
  } catch {
    throw new Error("suite is not valid JSON");
  }
  if (!Array.isArray(value) || value.length === 0 || value.length > 32) {
    throw new Error("suite must contain between 1 and 32 pages");
  }
  const labels = new Set();
  return value.map((item) => {
    if (item === null || typeof item !== "object" || Array.isArray(item) ||
        !SAFE_LABEL.test(item.label ?? "")) {
      throw new Error("every suite page needs a privacy-safe label");
    }
    if (labels.has(item.label)) throw new Error("suite labels must be unique");
    labels.add(item.label);
    let url;
    try {
      url = new URL(item.url);
    } catch {
      throw new Error("every suite page needs a valid URL");
    }
    if (!["http:", "https:"].includes(url.protocol) ||
        url.username || url.password || item.url.length > 2_048) {
      throw new Error("suite URLs must be credential-free http(s) URLs");
    }
    return { url: url.href, label: item.label };
  });
}

function stripAnsi(line) {
  return line.replace(/\x1b\[[0-9;]*m/g, "");
}

function decodeBenchmarkJson(json) {
  const value = JSON.parse(json);
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("benchmark result is not an object");
  }
  return value;
}

export class PhysicalConsoleParser {
  constructor() {
    this.chunkRecords = new Map();
    this.completedChunkIds = new Set();
    this.legacyRecords = new Set();
    this.sessionComplete = false;
    this.driverFailures = new Set();
    this.devicectlFailure = undefined;
  }

  ingestLine(rawLine) {
    const line = stripAnsi(rawLine);
    if (line.includes(SESSION_COMPLETE)) this.sessionComplete = true;
    if (line.includes("[PhysicalPeerTest] benchmark readiness timeout")) {
      this.driverFailures.add("benchmark-readiness-timeout");
    }
    if (line.includes("[PhysicalPeerTest] direct route stop failed")) {
      this.driverFailures.add("direct-route-stop-failed");
    }
    if (line.includes("[PhysicalPeerTest] transport pin unavailable")) {
      this.driverFailures.add("transport-pin-unavailable");
    }
    if (line.includes("[PhysicalPeerTest] no initialized device")) {
      this.driverFailures.add("device-initialization-failed");
    }
    if (line.includes("[PhysicalPageBenchmark] result serialization failed")) {
      this.driverFailures.add("result-serialization-failed");
    }
    if (line.includes("[PhysicalPeerTest] benchmark route preparation failed")) {
      this.driverFailures.add("benchmark-route-preparation-failed");
    }
    if (line.includes("[PhysicalPeerTest] benchmark route restore failed")) {
      this.driverFailures.add("benchmark-route-restore-failed");
    }
    if (line.includes("[PhysicalPeerTest] benchmark lost initialized device")) {
      this.driverFailures.add("benchmark-device-lost");
    }
    if (line.includes("The application failed to launch")) {
      this.devicectlFailure = "app-launch-failed";
    }
    if (line.includes("because the device was not, or could not be, unlocked") ||
        line.includes("BSErrorCodeDescription = Locked")) {
      this.devicectlFailure = "device-locked";
    }
    if (line.includes("A connection to this device could not be established") ||
        line.includes("Network.NWError error 60") ||
        line.includes("Operation timed out")) {
      this.devicectlFailure = "device-unreachable";
    }

    const chunkOffset = line.indexOf(CHUNK_PREFIX);
    if (chunkOffset >= 0) {
      return this.ingestChunk(line.slice(chunkOffset + CHUNK_PREFIX.length));
    }
    const resultOffset = line.indexOf(RESULT_PREFIX);
    if (resultOffset >= 0) {
      const json = line.slice(resultOffset + RESULT_PREFIX.length).trim();
      if (this.legacyRecords.has(json)) return undefined;
      const record = decodeBenchmarkJson(json);
      this.legacyRecords.add(json);
      return record;
    }
    return undefined;
  }

  ingestChunk(payloadLine) {
    const match = payloadLine.match(
      /^([A-Za-z0-9._-]{1,80}) (\d+)\/(\d+) ([A-Za-z0-9+/=]+)\s*$/,
    );
    if (!match) throw new Error("invalid physical benchmark chunk");
    const [, recordId, indexText, countText, payload] = match;
    if (this.completedChunkIds.has(recordId)) return undefined;
    const index = Number(indexText);
    const count = Number(countText);
    if (!Number.isInteger(index) || !Number.isInteger(count) ||
        index < 1 || count < 1 || index > count || count > MAX_CHUNK_COUNT) {
      throw new Error("physical benchmark chunk index is invalid");
    }
    let state = this.chunkRecords.get(recordId);
    if (state === undefined) {
      state = { count, parts: new Map(), byteCount: 0 };
      this.chunkRecords.set(recordId, state);
    } else if (state.count !== count) {
      throw new Error("physical benchmark chunk count changed");
    }
    const previous = state.parts.get(index);
    if (previous !== undefined && previous !== payload) {
      throw new Error("physical benchmark chunk changed");
    }
    if (previous === undefined) {
      state.parts.set(index, payload);
      state.byteCount += payload.length;
    }
    if (state.byteCount > MAX_RESULT_BASE64_BYTE_COUNT) {
      throw new Error("physical benchmark result is too large");
    }
    if (state.parts.size !== state.count) return undefined;

    const encoded = Array.from(
      { length: state.count },
      (_, offset) => state.parts.get(offset + 1),
    ).join("");
    if (encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) {
      throw new Error("physical benchmark result base64 is invalid");
    }
    const json = Buffer.from(encoded, "base64").toString("utf8");
    const record = decodeBenchmarkJson(json);
    this.chunkRecords.delete(recordId);
    this.completedChunkIds.add(recordId);
    return record;
  }

  get incompleteChunkRecordCount() {
    return this.chunkRecords.size;
  }
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function finiteNonNegative(value) {
  return Number.isFinite(value) && value >= 0;
}

function addReason(reasons, reason) {
  if (!reasons.includes(reason)) reasons.push(reason);
}

function remoteTraffic(totals) {
  if (!isObject(totals)) return 0;
  return [
    totals.remoteEgressPacketCount,
    totals.remoteEgressByteCount,
    totals.remoteIngressPacketCount,
    totals.remoteIngressByteCount,
  ].reduce((sum, value) => sum + (finiteNonNegative(value) ? value : 0), 0);
}

function expectedCarrier(options) {
  if (options.expectedCarrier !== undefined) return options.expectedCarrier;
  if (!["current", "auto"].includes(options.transport)) return options.transport;
  return undefined;
}

function validateSnapshot(snapshot, position, reasons) {
  if (!isObject(snapshot)) {
    addReason(reasons, `${position}-telemetry-missing`);
    return;
  }
  if (!finiteNonNegative(snapshot.timeUnixMs) ||
      !finiteNonNegative(snapshot.appPhysicalFootprintBytes) ||
      snapshot.appPhysicalFootprintBytes === 0) {
    addReason(reasons, `${position}-resource-telemetry-invalid`);
  }
  if (snapshot.lowPowerMode !== false) {
    addReason(reasons, `${position}-low-power-mode-enabled-or-unknown`);
  }
  if (!["nominal", "fair"].includes(snapshot.thermalState)) {
    addReason(reasons, `${position}-thermal-state-ineligible`);
  }
  if (snapshot.batteryState !== "unplugged") {
    addReason(reasons, `${position}-external-power-connected-or-unknown`);
  }
  const path = snapshot.physicalPath;
  if (!isObject(path)) {
    addReason(reasons, `${position}-physical-path-missing`);
    return;
  }
  if (path.status !== "satisfied") {
    addReason(reasons, `${position}-physical-path-unsatisfied`);
  }
  if (path.cellular !== true || path.wifi !== false ||
      path.wiredEthernet !== false) {
    addReason(reasons, `${position}-underlay-is-not-cellular-only`);
  }
  if (path.supportsIPv4 !== true || path.supportsDNS !== true) {
    addReason(reasons, `${position}-underlay-lacks-ipv4-or-dns`);
  }
}

export function evaluateEligibility(record, options) {
  const reasons = [];
  if (!options.confirmOneBar) addReason(reasons, "one-bar-not-confirmed");
  if (!isObject(record)) {
    return { eligible: false, reasons: [...reasons, "benchmark-result-invalid"] };
  }
  if (record.benchmarkRoute !== options.route) {
    addReason(reasons, "benchmark-route-mismatch");
  }
  const requestedMode = options.route === "direct" ? "current" : options.transport;
  if (record.expectedTransportMode !== requestedMode) {
    addReason(reasons, "benchmark-transport-mismatch");
  }
  if (typeof record.error === "string" || !isObject(record.navigation)) {
    addReason(reasons, "navigation-failed-or-incomplete");
  }
  if (!finiteNonNegative(record.routeReadinessMs)) {
    addReason(reasons, "route-readiness-missing");
  }
  const telemetry = record.physicalTelemetry;
  if (!isObject(telemetry)) {
    addReason(reasons, "physical-telemetry-missing");
    return { eligible: reasons.length === 0, reasons };
  }
  validateSnapshot(telemetry.start, "start", reasons);
  validateSnapshot(telemetry.end, "end", reasons);

  if (options.route === "vpn") {
    for (const position of ["start", "end"]) {
      const settings = telemetry[position]?.transportSettings;
      if (!isObject(settings) || typeof settings.mode !== "string") {
        addReason(reasons, `${position}-transport-settings-missing`);
      } else if (options.transport !== "current" &&
                 settings.mode !== options.transport) {
        addReason(reasons, `${position}-transport-mode-mismatch`);
      }
    }
  }

  const delta = telemetry.packetDelta;
  if (isObject(delta) && delta.counterResetDetected !== false) {
    addReason(reasons, "packet-counter-reset-or-unknown");
  }
  const aggregateTraffic = remoteTraffic(delta?.totals);
  if (options.route === "direct") {
    if (isObject(delta) &&
        (!isObject(delta.totals) || !isObject(delta.transports))) {
      addReason(reasons, "direct-packet-delta-invalid");
    }
    const attributedTraffic = TRANSPORT_TYPES.reduce(
      (sum, type) => sum + remoteTraffic(delta?.transports?.[type]),
      0,
    );
    if (aggregateTraffic > 0 || attributedTraffic > 0) {
      addReason(reasons, "direct-used-remote-route");
    }
  } else {
    if (!isObject(delta)) {
      addReason(reasons, "vpn-packet-delta-missing");
    } else if (aggregateTraffic === 0) {
      addReason(reasons, "vpn-remote-traffic-missing");
    }
    const transports = delta?.transports;
    if (!isObject(transports)) {
      addReason(reasons, "vpn-transport-attribution-missing");
    } else {
      const carrier = expectedCarrier(options);
      if (carrier !== undefined && remoteTraffic(transports[carrier]) === 0) {
        addReason(reasons, "expected-carrier-unused");
      }
      const exclusiveCarrier = options.expectedCarrier !== undefined ||
        !["current", "auto"].includes(options.transport);
      if (carrier !== undefined && exclusiveCarrier) {
        const unexpected = TRANSPORT_TYPES.some(
          (type) => type !== carrier && remoteTraffic(transports[type]) > 0,
        );
        if (unexpected) addReason(reasons, "unexpected-carrier-used");
      }
      if (carrier === undefined && !TRANSPORT_TYPES.some(
        (type) => type !== "unknown" && remoteTraffic(transports[type]) > 0,
      )) {
        addReason(reasons, "known-carrier-traffic-missing");
      }
    }
  }
  return { eligible: reasons.length === 0, reasons };
}

function numberOrNull(value) {
  return finiteNonNegative(value) ? value : null;
}

function booleanOrNull(value) {
  return typeof value === "boolean" ? value : null;
}

function sanitizeCounters(value) {
  if (!isObject(value)) return null;
  return Object.fromEntries(COUNTER_KEYS.map((key) => [key, numberOrNull(value[key])]));
}

function sanitizePacketSnapshot(value) {
  if (!isObject(value)) return null;
  return {
    totals: sanitizeCounters(value.totals),
    transports: Object.fromEntries(TRANSPORT_TYPES.map(
      (type) => [type, sanitizeCounters(value.transports?.[type])],
    )),
  };
}

function sanitizePacketDelta(value) {
  if (!isObject(value)) return null;
  return {
    ...sanitizePacketSnapshot(value),
    counterResetDetected: booleanOrNull(value.counterResetDetected),
  };
}

function sanitizePath(value) {
  if (!isObject(value)) return null;
  const status = ["satisfied", "requiresConnection", "unsatisfied", "unknown"]
    .includes(value.status) ? value.status : "unknown";
  return {
    status,
    expensive: booleanOrNull(value.expensive),
    constrained: booleanOrNull(value.constrained),
    cellular: booleanOrNull(value.cellular),
    wifi: booleanOrNull(value.wifi),
    wiredEthernet: booleanOrNull(value.wiredEthernet),
    supportsIPv4: booleanOrNull(value.supportsIPv4),
    supportsIPv6: booleanOrNull(value.supportsIPv6),
    supportsDNS: booleanOrNull(value.supportsDNS),
  };
}

function sanitizeTransportSettings(value) {
  if (!isObject(value)) return null;
  return {
    mode: MODES.has(value.mode) && value.mode !== "current" ? value.mode : "unknown",
    autoModes: Array.isArray(value.autoModes)
      ? value.autoModes.filter((mode) => MODES.has(mode) && !["current", "auto"].includes(mode))
      : [],
  };
}

function sanitizeSnapshot(value) {
  if (!isObject(value)) return null;
  return {
    timeUnixMs: numberOrNull(value.timeUnixMs),
    appPhysicalFootprintBytes: numberOrNull(value.appPhysicalFootprintBytes),
    lowPowerMode: booleanOrNull(value.lowPowerMode),
    thermalState: ["nominal", "fair", "serious", "critical", "unknown"]
      .includes(value.thermalState) ? value.thermalState : "unknown",
    batteryLevel: numberOrNull(value.batteryLevel),
    batteryState: ["unplugged", "charging", "full", "unknown"]
      .includes(value.batteryState) ? value.batteryState : "unknown",
    physicalPath: sanitizePath(value.physicalPath),
    packetStats: sanitizePacketSnapshot(value.packetStats),
    transportSettings: sanitizeTransportSettings(value.transportSettings),
  };
}

function sanitizeNavigation(value) {
  if (!isObject(value)) return null;
  const protocol = typeof value.protocol === "string" &&
    /^[A-Za-z0-9./_-]{0,24}$/.test(value.protocol) ? value.protocol : "";
  return {
    dnsMs: numberOrNull(value.dnsMs),
    connectMs: numberOrNull(value.connectMs),
    tlsMs: numberOrNull(value.tlsMs),
    ttfbMs: numberOrNull(value.ttfbMs),
    responseEndMs: numberOrNull(value.responseEndMs),
    domContentLoadedMs: numberOrNull(value.domContentLoadedMs),
    loadMs: numberOrNull(value.loadMs),
    transferBytes: numberOrNull(value.transferBytes),
    protocol,
  };
}

function errorClass(value) {
  if (typeof value !== "string") return null;
  if (value === "timeout") return "timeout";
  if (value.startsWith("provisional navigation:")) return "provisional-navigation";
  if (value.startsWith("navigation:")) return "navigation";
  if (value.startsWith("metrics evaluation:")) return "metrics-evaluation";
  if (value === "invalid navigation metrics") return "invalid-navigation-metrics";
  return "other";
}

export function sanitizeBenchmark(record, options) {
  const eligibility = evaluateEligibility(record, options);
  const telemetry = isObject(record.physicalTelemetry) ? record.physicalTelemetry : null;
  return {
    schemaVersion: SCHEMA_VERSION,
    type: "page",
    runLabel: options.runLabel,
    oneBarConfirmed: options.confirmOneBar,
    label: SAFE_LABEL.test(record.label ?? "") ? record.label : "invalid-label",
    benchmarkRoute: ROUTES.has(record.benchmarkRoute) ? record.benchmarkRoute : "unknown",
    expectedTransportMode: MODES.has(record.expectedTransportMode)
      ? record.expectedTransportMode : "unknown",
    routeReadinessMs: numberOrNull(record.routeReadinessMs),
    navigationSucceeded: typeof record.error !== "string",
    errorClass: errorClass(record.error),
    driverCommitMs: numberOrNull(record.driverCommitMs),
    driverFinishMs: numberOrNull(record.driverFinishMs),
    navigation: sanitizeNavigation(record.navigation),
    resourceCount: numberOrNull(record.resourceCount),
    originCount: numberOrNull(record.originCount),
    maxRequestConcurrency: numberOrNull(record.maxRequestConcurrency),
    maxDnsConcurrency: numberOrNull(record.maxDnsConcurrency),
    resourcesWithDns: numberOrNull(record.resourcesWithDns),
    totalResourceDnsMs: numberOrNull(record.totalResourceDnsMs),
    resourceTtfbMedianMs: numberOrNull(record.resourceTtfbMedianMs),
    resourceTtfbP95Ms: numberOrNull(record.resourceTtfbP95Ms),
    resourceTtfbMaxMs: numberOrNull(record.resourceTtfbMaxMs),
    totalTransferBytes: numberOrNull(record.totalTransferBytes),
    physicalTelemetry: telemetry === null ? null : {
      start: sanitizeSnapshot(telemetry.start),
      end: sanitizeSnapshot(telemetry.end),
      packetDelta: sanitizePacketDelta(telemetry.packetDelta),
    },
    eligibility,
  };
}

function median(values) {
  if (values.length === 0) return null;
  const ordered = [...values].sort((a, b) => a - b);
  const middle = Math.floor(ordered.length / 2);
  return ordered.length % 2 === 0
    ? (ordered[middle - 1] + ordered[middle]) / 2
    : ordered[middle];
}

export function summarize(records, options, collection) {
  const invalidReasonCounts = {};
  const transportRemoteBytes = Object.fromEntries(
    TRANSPORT_TYPES.map((type) => [type, 0]),
  );
  let peakAppPhysicalFootprintBytes = 0;
  for (const record of records) {
    for (const reason of record.eligibility.reasons) {
      invalidReasonCounts[reason] = (invalidReasonCounts[reason] ?? 0) + 1;
    }
    for (const snapshot of [
      record.physicalTelemetry?.start,
      record.physicalTelemetry?.end,
    ]) {
      peakAppPhysicalFootprintBytes = Math.max(
        peakAppPhysicalFootprintBytes,
        snapshot?.appPhysicalFootprintBytes ?? 0,
      );
    }
    for (const type of TRANSPORT_TYPES) {
      const counters = record.physicalTelemetry?.packetDelta?.transports?.[type];
      transportRemoteBytes[type] +=
        (counters?.remoteEgressByteCount ?? 0) +
        (counters?.remoteIngressByteCount ?? 0);
    }
  }
  const complete = collection.sessionComplete &&
    collection.incompleteChunkRecordCount === 0 &&
    collection.driverFailures.length === 0 &&
    records.length === collection.expectedResultCount;
  const eligibleCount = records.filter((record) => record.eligibility.eligible).length;
  return {
    schemaVersion: SCHEMA_VERSION,
    type: "summary",
    runLabel: options.runLabel,
    benchmarkRoute: options.route,
    requestedTransportMode: options.transport,
    expectedCarrier: expectedCarrier(options) ?? null,
    oneBarConfirmed: options.confirmOneBar,
    expectedResultCount: collection.expectedResultCount,
    resultCount: records.length,
    eligibleResultCount: eligibleCount,
    allEligible: complete && eligibleCount === records.length,
    collectionComplete: complete,
    driverFailures: collection.driverFailures,
    incompleteChunkRecordCount: collection.incompleteChunkRecordCount,
    invalidReasonCounts,
    medianRouteReadinessMs: median(
      records.map((record) => record.routeReadinessMs).filter(Number.isFinite),
    ),
    medianDriverFinishMs: median(
      records.map((record) => record.driverFinishMs).filter(Number.isFinite),
    ),
    medianNavigationTtfbMs: median(
      records.map((record) => record.navigation?.ttfbMs).filter(Number.isFinite),
    ),
    medianNavigationLoadMs: median(
      records.map((record) => record.navigation?.loadMs).filter(Number.isFinite),
    ),
    peakAppPhysicalFootprintBytes,
    transportRemoteBytes,
  };
}

export function devicectlArguments(options, suiteJson) {
  const appArguments = [
    "--urnetwork-physical-test-action", "benchmark-suite",
    "--urnetwork-physical-test-route", options.route,
    "--urnetwork-physical-test-suite", suiteJson,
  ];
  if (options.route === "vpn" && options.transport !== "current") {
    appArguments.push("--urnetwork-physical-test-transport", options.transport);
  }
  if (options.peer !== undefined) {
    appArguments.push("--urnetwork-physical-test-peer", options.peer);
  }
  return [
    "devicectl", "device", "process", "launch",
    "--device", options.device,
    "--terminate-existing",
    "--console",
    options.bundleId,
    ...appArguments,
  ];
}

export function runCapture(options, suite, spawnProcess = spawn) {
  const suiteJson = JSON.stringify(suite);
  const timeoutSeconds = options.timeoutSeconds ?? (90 + 90 * suite.length);
  const parser = new PhysicalConsoleParser();

  return new Promise((resolve, reject) => {
    const child = spawnProcess("xcrun", devicectlArguments(options, suiteJson), {
      stdio: ["ignore", "pipe", "pipe"],
    });
    const records = [];
    let settled = false;

    let deadline;
    const stopChild = () => {
      if (child.exitCode === null && child.signalCode === null) {
        child.kill("SIGINT");
        const hardStop = setTimeout(() => child.kill("SIGTERM"), 1_000);
        hardStop.unref();
      }
    };
    const settle = (error) => {
      if (settled) return;
      settled = true;
      if (deadline !== undefined) clearTimeout(deadline);
      stopChild();
      if (error) reject(error);
      else resolve({
        records,
        sessionComplete: parser.sessionComplete,
        driverFailures: [...parser.driverFailures].sort(),
        incompleteChunkRecordCount: parser.incompleteChunkRecordCount,
      });
    };
    const processLine = (line) => {
      let record;
      try {
        record = parser.ingestLine(line);
      } catch {
        settle(new CaptureError("invalid-driver-output"));
        return;
      }
      if (record !== undefined) records.push(record);
      if (records.length > suite.length) {
        settle(new CaptureError("too-many-benchmark-results"));
      } else if (parser.sessionComplete &&
                 (records.length === suite.length || parser.driverFailures.size > 0)) {
        settle(undefined);
      }
    };
    const makeLineSink = () => {
      const decoder = new TextDecoder();
      let pending = "";
      return {
        ingest(chunk) {
          pending += decoder.decode(chunk, { stream: true });
          if (pending.length > MAX_RESULT_BASE64_BYTE_COUNT * 2) {
            settle(new CaptureError("console-line-too-large"));
            return;
          }
          let newline;
          while ((newline = pending.indexOf("\n")) >= 0) {
            const line = pending.slice(0, newline).replace(/\r$/, "");
            pending = pending.slice(newline + 1);
            processLine(line);
            if (settled) return;
          }
        },
        finish() {
          pending += decoder.decode();
          if (pending) processLine(pending.replace(/\r$/, ""));
          pending = "";
        },
      };
    };
    const stdoutSink = makeLineSink();
    const stderrSink = makeLineSink();
    child.stdout.on("data", (chunk) => stdoutSink.ingest(chunk));
    child.stderr.on("data", (chunk) => stderrSink.ingest(chunk));
    child.on("error", () => settle(new CaptureError("devicectl-launch-failed")));
    child.on("close", (code, signal) => {
      if (settled) return;
      stdoutSink.finish();
      if (!settled) stderrSink.finish();
      if (!settled) {
        settle(new CaptureError(
          parser.devicectlFailure ?? (
            code === 0 && signal === null
              ? "devicectl-ended-before-driver-completion"
              : "devicectl-failed"
          ),
        ));
      }
    });
    deadline = setTimeout(
      () => settle(new CaptureError("capture-timeout")),
      timeoutSeconds * 1_000,
    );
  });
}

export function outputWriter(path, stdout = process.stdout) {
  if (path !== undefined) {
    writeFileSync(path, "", { mode: 0o600 });
    chmodSync(path, 0o600);
  }
  return (value) => {
    const line = `${JSON.stringify(value)}\n`;
    stdout.write(line);
    if (path !== undefined) appendFileSync(path, line, { mode: 0o600 });
  };
}

async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`physical capture arguments: ${error.message}\n`);
    process.exitCode = 1;
    return;
  }
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return;
  }

  let suite;
  try {
    const suiteJson = options.suiteFile !== undefined
      ? readFileSync(options.suiteFile, "utf8")
      : options.suiteJson;
    suite = parseSuite(suiteJson);
  } catch (error) {
    process.stderr.write(`physical capture suite: ${error.message}\n`);
    process.exitCode = 1;
    return;
  }

  let emit;
  try {
    emit = outputWriter(options.output);
  } catch {
    process.stderr.write("physical capture: output-open-failed\n");
    process.exitCode = 1;
    return;
  }
  const safeEmit = (value) => {
    try {
      emit(value);
      return true;
    } catch {
      process.stderr.write("physical capture: output-write-failed\n");
      process.exitCode = 1;
      return false;
    }
  };
  let collection;
  try {
    collection = await runCapture(options, suite);
  } catch (error) {
    safeEmit({
      schemaVersion: SCHEMA_VERSION,
      type: "summary",
      runLabel: options.runLabel,
      benchmarkRoute: options.route,
      requestedTransportMode: options.transport,
      oneBarConfirmed: options.confirmOneBar,
      expectedResultCount: suite.length,
      resultCount: 0,
      eligibleResultCount: 0,
      allEligible: false,
      collectionComplete: false,
      collectionFailure: error instanceof CaptureError
        ? error.code : "capture-failed",
    });
    process.exitCode = 1;
    return;
  }

  const records = collection.records.map(
    (record) => sanitizeBenchmark(record, options),
  );
  for (const record of records) {
    if (!safeEmit(record)) return;
  }
  const summary = summarize(records, options, {
    ...collection,
    expectedResultCount: suite.length,
  });
  if (!safeEmit(summary)) return;
  process.exitCode = summary.allEligible ? 0 : 2;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  await main();
}
