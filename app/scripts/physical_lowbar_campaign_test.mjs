import assert from "node:assert/strict";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  CampaignRunError,
  FileCampaignStore,
  balancedOrders,
  createManifest,
  parseArgs,
  runCampaign,
} from "./physical_lowbar_campaign.mjs";

const modes = ["h1", "h3", "auto"];

function options(overrides = {}) {
  return {
    device: "private-device",
    peer: "private-provider",
    bundleId: "network.ur",
    campaignLabel: "one-bar-01",
    cycleCount: 5,
    timeoutSeconds: 120,
    maxDirectDriftPercent: 35,
    maxCycleMinutes: 60,
    confirmOneBar: true,
    ...overrides,
  };
}

function memoryStore() {
  return {
    manifestPath: "private-manifest-path",
    runs: [],
    report: undefined,
    writeRun(reference, records, summary) {
      this.runs.push({ reference, records, summary });
    },
    writeReport(report) {
      this.report = report;
    },
  };
}

function successfulResult(runNumber) {
  return {
    records: [{ schemaVersion: 1, type: "page", label: `page-${runNumber}` }],
    summary: { schemaVersion: 1, type: "summary", allEligible: true },
  };
}

function assertBalanced(orders) {
  for (const order of orders) {
    assert.deepEqual(new Set(order), new Set(modes));
  }
  for (const mode of modes) {
    const counts = modes.map((_, position) =>
      orders.filter((order) => order[position] === mode).length,
    );
    assert.ok(Math.max(...counts) - Math.min(...counts) <= 1, `${mode}: ${counts}`);
  }
}

test("campaign arguments require explicit physical attestations and identities", () => {
  const parsed = parseArgs([
    "--device", "private-device",
    "--peer", "private-provider",
    "--campaign-label", "one-bar-01",
    "--suite-file", "suite.json",
    "--output-dir", "capture-output",
    "--confirm-one-bar",
  ]);
  assert.equal(parsed.cycleCount, 5);
  assert.equal(parsed.confirmOneBar, true);
  assert.throws(() => parseArgs([
    "--device", "private-device",
    "--peer", "private-provider",
    "--campaign-label", "one-bar-01",
    "--suite-file", "suite.json",
    "--output-dir", "capture-output",
  ]), /confirm-one-bar is required/);
  assert.throws(() => parseArgs([
    "--device", "private-device",
    "--peer", "private-provider",
    "--campaign-label", "one-bar-01",
    "--suite-file", "suite.json",
    "--output-dir", "capture-output",
    "--cycles", "4",
    "--confirm-one-bar",
  ]), /cycles must be between/);
});

test("every supported campaign length has balanced candidate positions", () => {
  for (let cycleCount = 5; cycleCount <= 100; cycleCount += 1) {
    assertBalanced(balancedOrders(cycleCount));
  }
});

test("manifest contains only safe labels and unique relative run files", () => {
  const manifest = createManifest("one-bar-01", balancedOrders(5));
  const encoded = JSON.stringify(manifest);
  assert.equal(encoded.includes("private-device"), false);
  assert.equal(encoded.includes("private-provider"), false);
  const references = manifest.cycles.flatMap((cycle) => [
    cycle.directBefore,
    cycle.h1,
    cycle.h3,
    cycle.auto,
    cycle.directAfter,
  ]);
  assert.equal(new Set(references).size, 25);
  assert.ok(references.every((reference) => !reference.includes("/")));
  assert.throws(
    () => createManifest("one-bar-01", Array(5).fill(["h1", "h1", "auto"])),
    /manifest input is invalid/,
  );
});

test("runner executes Direct brackets and each manifest candidate order", async () => {
  const campaignOptions = options();
  const manifest = createManifest("one-bar-01", balancedOrders(5, () => 0));
  const store = memoryStore();
  const captures = [];
  const progress = [];
  const expectedReport = { accepted: true, type: "physical-lowbar-comparison" };
  const report = await runCampaign(
    campaignOptions,
    [{ url: "https://synthetic.example/", label: "web" }],
    manifest,
    store,
    {
      async collect(captureOptions) {
        captures.push(captureOptions);
        return successfulResult(captures.length);
      },
      analyze(manifestPath) {
        assert.equal(manifestPath, store.manifestPath);
        return expectedReport;
      },
      progress(event) { progress.push(event); },
    },
  );
  assert.equal(report, expectedReport);
  assert.equal(store.report, expectedReport);
  assert.equal(captures.length, 25);
  assert.equal(store.runs.length, 25);
  assert.equal(progress.length, 50);
  for (let cycleIndex = 0; cycleIndex < 5; cycleIndex += 1) {
    const offset = cycleIndex * 5;
    assert.equal(captures[offset].route, "direct");
    assert.equal(captures[offset].transport, "current");
    assert.equal(captures[offset].peer, undefined);
    assert.deepEqual(
      captures.slice(offset + 1, offset + 4).map((capture) => capture.transport),
      manifest.cycles[cycleIndex].order,
    );
    assert.equal(captures[offset + 4].route, "direct");
    assert.equal(captures[offset + 4].peer, undefined);
  }
  const h3 = captures.find((capture) => capture.transport === "h3");
  const auto = captures.find((capture) => capture.transport === "auto");
  assert.equal(h3.expectedCarrier, "h3");
  assert.equal(auto.expectedCarrier, undefined);
  assert.equal(JSON.stringify(store).includes("private-device"), false);
  assert.equal(JSON.stringify(store).includes("private-provider"), false);
});

test("runner persists the failed run and stops before analyzer use", async () => {
  const manifest = createManifest("one-bar-01", balancedOrders(5, () => 0));
  const store = memoryStore();
  let captureCount = 0;
  let analyzeCalled = false;
  await assert.rejects(
    runCampaign(options(), [{ label: "web" }], manifest, store, {
      async collect() {
        captureCount += 1;
        if (captureCount === 3) {
          return {
            records: [],
            summary: { allEligible: false, collectionFailure: "device-locked" },
          };
        }
        return successfulResult(captureCount);
      },
      analyze() {
        analyzeCalled = true;
        return { accepted: true };
      },
    }),
    (error) => error instanceof CampaignRunError &&
      error.code === "device-locked" && error.context.cycle === "cycle-001",
  );
  assert.equal(captureCount, 3);
  assert.equal(store.runs.length, 3);
  assert.equal(analyzeCalled, false);
});

test("file store creates a private, non-overwriting campaign directory", () => {
  const parent = mkdtempSync(join(tmpdir(), "physical-campaign-test-"));
  const outputDirectory = join(parent, "campaign");
  try {
    const manifest = createManifest("one-bar-01", balancedOrders(5, () => 0));
    const store = new FileCampaignStore(outputDirectory, manifest);
    store.writeRun(
      manifest.cycles[0].directBefore,
      [{ type: "page" }],
      { type: "summary" },
    );
    store.writeReport({ accepted: true });
    assert.equal(statSync(outputDirectory).mode & 0o777, 0o700);
    assert.equal(statSync(store.manifestPath).mode & 0o777, 0o600);
    assert.equal(
      statSync(join(outputDirectory, manifest.cycles[0].directBefore)).mode & 0o777,
      0o600,
    );
    assert.equal(statSync(join(outputDirectory, "comparison.json")).mode & 0o777, 0o600);
    assert.equal(JSON.parse(readFileSync(store.manifestPath, "utf8")).campaignLabel,
      "one-bar-01");
    assert.throws(
      () => new FileCampaignStore(outputDirectory, manifest),
      (error) => error instanceof CampaignRunError &&
        error.code === "output-directory-unavailable",
    );
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
});
