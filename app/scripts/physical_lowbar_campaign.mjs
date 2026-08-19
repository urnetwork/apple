#!/usr/bin/env node

// One-command acquisition for a balanced, Direct-bracketed physical iOS
// low-bar campaign. Device/provider identifiers are process inputs only and
// are never written into the campaign directory or emitted in progress logs.

import { randomInt } from "node:crypto";
import {
  chmodSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, resolve } from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

import {
  parseSuite,
  runCapture,
  sanitizeBenchmark,
  summarize,
} from "./physical_lowbar_capture.mjs";
import { analyzeManifestFile } from "./physical_lowbar_compare.mjs";

const SCHEMA_VERSION = 1;
const BUNDLE_ID = "network.ur";
const MODES = ["h1", "h3", "auto"];
const SAFE_LABEL = /^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$/;
const SAFE_BUNDLE_ID = /^[A-Za-z0-9][A-Za-z0-9.-]{0,199}$/;
const SAFE_FAILURE = /^[a-z0-9][a-z0-9-]{0,79}$/;
const MIN_CYCLES = 5;
const MAX_CYCLES = 100;

export class CampaignRunError extends Error {
  constructor(code, context = {}) {
    super(code);
    this.code = code;
    this.context = context;
  }
}

function fail(code, context) {
  throw new CampaignRunError(code, context);
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
    throw new Error(`${name} must be positive`);
  }
  return number;
}

function positiveInteger(value, name) {
  const number = positiveNumber(value, name);
  if (!Number.isSafeInteger(number)) throw new Error(`${name} must be an integer`);
  return number;
}

export function parseArgs(argv) {
  const options = {
    device: undefined,
    peer: undefined,
    bundleId: BUNDLE_ID,
    campaignLabel: undefined,
    suiteFile: undefined,
    outputDirectory: undefined,
    cycleCount: MIN_CYCLES,
    timeoutSeconds: undefined,
    maxDirectDriftPercent: 35,
    maxCycleMinutes: 60,
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
      case "--peer": options.peer = next(); break;
      case "--bundle-id": options.bundleId = next(); break;
      case "--campaign-label": options.campaignLabel = next(); break;
      case "--suite-file": options.suiteFile = next(); break;
      case "--output-dir": options.outputDirectory = next(); break;
      case "--cycles": options.cycleCount = positiveInteger(next(), "cycles"); break;
      case "--timeout-seconds":
        options.timeoutSeconds = positiveNumber(next(), "timeout-seconds");
        break;
      case "--max-direct-drift-percent":
        options.maxDirectDriftPercent = positiveNumber(
          next(), "max-direct-drift-percent",
        );
        break;
      case "--max-cycle-minutes":
        options.maxCycleMinutes = positiveNumber(next(), "max-cycle-minutes");
        break;
      case "--confirm-one-bar": options.confirmOneBar = true; break;
      case "--help":
      case "-h": options.help = true; break;
      default: throw new Error(`unknown option: ${option}`);
    }
  }
  if (options.help) return options;
  if (!options.device) throw new Error("--device is required");
  if (!options.peer) throw new Error("--peer is required");
  if (!options.suiteFile) throw new Error("--suite-file is required");
  if (!options.outputDirectory) throw new Error("--output-dir is required");
  if (!SAFE_LABEL.test(options.campaignLabel ?? "")) {
    throw new Error("campaign-label is invalid");
  }
  if (!SAFE_BUNDLE_ID.test(options.bundleId)) throw new Error("bundle-id is invalid");
  if (options.cycleCount < MIN_CYCLES || options.cycleCount > MAX_CYCLES) {
    throw new Error(`cycles must be between ${MIN_CYCLES} and ${MAX_CYCLES}`);
  }
  if (!options.confirmOneBar) {
    throw new Error("--confirm-one-bar is required for a physical campaign");
  }
  return options;
}

export function usage() {
  return [
    "usage: physical_lowbar_campaign.mjs [options]",
    "",
    "required:",
    "  --device ID                 paired CoreDevice identifier",
    "  --peer ID                   expected VPN provider identifier",
    "  --campaign-label LABEL      privacy-safe campaign label",
    "  --suite-file FILE           synthetic credential-free page suite",
    "  --output-dir DIRECTORY      new private campaign directory",
    "  --confirm-one-bar           attest one bar for the whole campaign",
    "",
    "gates:",
    "  --cycles COUNT              balanced cycles (default 5, minimum 5)",
    "  --timeout-seconds SECONDS   per-run collection deadline",
    "  --max-direct-drift-percent PERCENT  Direct bracket gate (default 35)",
    "  --max-cycle-minutes MINUTES         cycle duration gate (default 60)",
    "  --bundle-id ID              Debug app bundle id (default network.ur)",
  ].join("\n");
}

function shuffled(values, random = randomInt) {
  const result = [...values];
  for (let index = result.length - 1; index > 0; index -= 1) {
    const selected = random(index + 1);
    [result[index], result[selected]] = [result[selected], result[index]];
  }
  return result;
}

// Every prefix of this six-row design is position-balanced. A full block also
// contains every permutation, reducing first-order carryover bias.
const BALANCED_TEMPLATE = [
  [0, 1, 2],
  [1, 2, 0],
  [2, 0, 1],
  [0, 2, 1],
  [1, 0, 2],
  [2, 1, 0],
];

export function balancedOrders(cycleCount, random = randomInt) {
  if (!Number.isSafeInteger(cycleCount) ||
      cycleCount < MIN_CYCLES || cycleCount > MAX_CYCLES) {
    throw new Error("cycle count is invalid");
  }
  const result = [];
  while (result.length < cycleCount) {
    const labels = shuffled(MODES, random);
    const columns = shuffled([0, 1, 2], random);
    for (const row of BALANCED_TEMPLATE) {
      result.push(columns.map((column) => labels[row[column]]));
      if (result.length === cycleCount) break;
    }
  }
  return result;
}

function cycleNumber(index) {
  return String(index + 1).padStart(3, "0");
}

export function createManifest(campaignLabel, orders) {
  if (!SAFE_LABEL.test(campaignLabel ?? "") || !Array.isArray(orders) ||
      orders.length < MIN_CYCLES || orders.length > MAX_CYCLES ||
      orders.some((order) => !Array.isArray(order) || order.length !== MODES.length ||
        new Set(order).size !== MODES.length ||
        MODES.some((mode) => !order.includes(mode)))) {
    throw new Error("campaign manifest input is invalid");
  }
  return {
    schemaVersion: SCHEMA_VERSION,
    campaignLabel,
    cycles: orders.map((order, index) => {
      const number = cycleNumber(index);
      return {
        label: `cycle-${number}`,
        directBefore: `c${number}-direct-before.ndjson`,
        order: [...order],
        h1: `c${number}-h1.ndjson`,
        h3: `c${number}-h3.ndjson`,
        auto: `c${number}-auto.ndjson`,
        directAfter: `c${number}-direct-after.ndjson`,
      };
    }),
  };
}

function privateWrite(path, contents, exclusive = true) {
  writeFileSync(path, contents, {
    encoding: "utf8",
    flag: exclusive ? "wx" : "w",
    mode: 0o600,
  });
  chmodSync(path, 0o600);
}

export class FileCampaignStore {
  constructor(outputDirectory, manifest) {
    try {
      mkdirSync(outputDirectory, { recursive: false, mode: 0o700 });
      chmodSync(outputDirectory, 0o700);
      this.directory = realpathSync(outputDirectory);
      this.manifestPath = resolve(this.directory, "campaign.json");
      privateWrite(
        this.manifestPath,
        `${JSON.stringify(manifest, null, 2)}\n`,
      );
    } catch {
      fail("output-directory-unavailable");
    }
  }

  resolveReference(reference) {
    if (basename(reference) !== reference || dirname(reference) !== ".") {
      fail("campaign-reference-invalid");
    }
    const path = resolve(this.directory, reference);
    if (dirname(path) !== this.directory) fail("campaign-reference-invalid");
    return path;
  }

  writeRun(reference, records, summary) {
    const ndjson = [...records, summary]
      .map((record) => JSON.stringify(record)).join("\n");
    try {
      privateWrite(this.resolveReference(reference), `${ndjson}\n`);
    } catch (error) {
      if (error instanceof CampaignRunError) throw error;
      fail("campaign-write-failed");
    }
  }

  writeReport(report) {
    try {
      privateWrite(
        resolve(this.directory, "comparison.json"),
        `${JSON.stringify(report, null, 2)}\n`,
      );
    } catch {
      fail("campaign-write-failed");
    }
  }
}

function failureCode(error) {
  return SAFE_FAILURE.test(error?.code ?? "") ? error.code : "capture-failed";
}

function failureSummary(captureOptions, expectedResultCount, error) {
  return {
    schemaVersion: SCHEMA_VERSION,
    type: "summary",
    runLabel: captureOptions.runLabel,
    benchmarkRoute: captureOptions.route,
    requestedTransportMode: captureOptions.transport,
    oneBarConfirmed: true,
    expectedResultCount,
    resultCount: 0,
    eligibleResultCount: 0,
    allEligible: false,
    collectionComplete: false,
    collectionFailure: failureCode(error),
  };
}

export async function collectRun(captureOptions, suite) {
  let collection;
  try {
    collection = await runCapture(captureOptions, suite);
  } catch (error) {
    return {
      records: [],
      summary: failureSummary(captureOptions, suite.length, error),
    };
  }
  const records = collection.records.map(
    (record) => sanitizeBenchmark(record, captureOptions),
  );
  return {
    records,
    summary: summarize(records, captureOptions, {
      ...collection,
      expectedResultCount: suite.length,
    }),
  };
}

function plannedRuns(cycle) {
  return [
    { role: "direct-before", key: "directBefore", mode: "direct" },
    ...cycle.order.map((mode) => ({ role: mode, key: mode, mode })),
    { role: "direct-after", key: "directAfter", mode: "direct" },
  ];
}

function captureOptions(options, cycleIndex, run) {
  const route = run.mode === "direct" ? "direct" : "vpn";
  const transport = route === "direct" ? "current" : run.mode;
  return {
    device: options.device,
    peer: route === "vpn" ? options.peer : undefined,
    bundleId: options.bundleId,
    route,
    transport,
    expectedCarrier: ["h1", "h3"].includes(run.mode) ? run.mode : undefined,
    runLabel: `${options.campaignLabel}-c${cycleNumber(cycleIndex)}-${run.role}`,
    timeoutSeconds: options.timeoutSeconds,
    confirmOneBar: true,
  };
}

export async function runCampaign(
  options,
  suite,
  manifest,
  store,
  dependencies = {},
) {
  const collect = dependencies.collect ?? collectRun;
  const analyze = dependencies.analyze ?? ((manifestPath) =>
    analyzeManifestFile(manifestPath, {
      minCycles: options.cycleCount,
      maxDirectDriftPercent: options.maxDirectDriftPercent,
      maxCycleMinutes: options.maxCycleMinutes,
    }));
  const progress = dependencies.progress ?? (() => {});

  for (const [cycleIndex, cycle] of manifest.cycles.entries()) {
    for (const run of plannedRuns(cycle)) {
      const context = { cycle: cycle.label, role: run.role };
      progress({ type: "run-start", ...context });
      let result;
      try {
        result = await collect(captureOptions(options, cycleIndex, run), suite);
      } catch {
        fail("capture-failed", context);
      }
      store.writeRun(cycle[run.key], result.records, result.summary);
      if (result.summary.allEligible !== true) {
        const code = result.summary.collectionFailure === undefined
          ? "run-ineligible"
          : failureCode({ code: result.summary.collectionFailure });
        fail(code, context);
      }
      progress({ type: "run-complete", ...context });
    }
  }

  let report;
  try {
    report = analyze(store.manifestPath);
  } catch (error) {
    fail(SAFE_FAILURE.test(error?.code ?? "") ? error.code : "analysis-failed");
  }
  store.writeReport(report);
  return report;
}

async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`physical campaign arguments: ${error.message}\n`);
    process.exitCode = 1;
    return;
  }
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return;
  }

  let suite;
  try {
    suite = parseSuite(readFileSync(options.suiteFile, "utf8"));
  } catch {
    process.stderr.write("physical campaign: suite-invalid\n");
    process.exitCode = 1;
    return;
  }
  const manifest = createManifest(
    options.campaignLabel,
    balancedOrders(options.cycleCount),
  );
  let store;
  try {
    store = new FileCampaignStore(options.outputDirectory, manifest);
  } catch (error) {
    process.stderr.write(
      `physical campaign: ${error instanceof CampaignRunError
        ? error.code : "output-directory-unavailable"}\n`,
    );
    process.exitCode = 1;
    return;
  }

  try {
    const report = await runCampaign(options, suite, manifest, store, {
      progress(event) {
        process.stderr.write(
          `physical campaign: ${event.type} cycle=${event.cycle} role=${event.role}\n`,
        );
      },
    });
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  } catch (error) {
    const code = error instanceof CampaignRunError ? error.code : "campaign-failed";
    const context = error instanceof CampaignRunError ? error.context : {};
    const suffix = SAFE_LABEL.test(context.cycle ?? "") &&
      /^[a-z0-9-]{1,24}$/.test(context.role ?? "")
      ? ` cycle=${context.cycle} role=${context.role}` : "";
    process.stderr.write(`physical campaign: ${code}${suffix}\n`);
    process.exitCode = 1;
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  await main();
}
