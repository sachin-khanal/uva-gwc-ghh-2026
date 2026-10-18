// Optional Node 20+ runner; no npm install or dependencies required.
import { readFile } from "node:fs/promises";
import { runRouteChecks } from "./route-tests.js";
import { runCloudChecks } from "./cloud-tests.js";
import { runGeometryChecks } from "./geometry-tests.js";
const read = async (name) => JSON.parse(await readFile(new URL(name, import.meta.url), "utf8"));
const vectors = await read("../Samples/route-vectors.json"), samples = {};
for (const fixture of vectors.fixtures) if (fixture.sample) samples[fixture.sample] = await read(`./fixtures/${fixture.sample}`);
// The viewer ships no sample building: no runtime file may fetch or embed a fixture (tests and the two JSON fixtures are exempt).
const runtimeFiles = ["app.js", "cloud.js", "router.js", "walkthrough.js", "building-model.js", "meshloader.js", "surfaces.js", "geometry3d.js", "index.html"]; // serve.py is the dev server and legitimately lists the two test-only fixtures
const sampleLeaks = [];
for (const name of runtimeFiles) {
  const text = await readFile(new URL(name, import.meta.url), "utf8");
  if (/fixtures\/|rice-hall-sample|route-vectors|preview-map|hand-written sample/i.test(text)) sampleLeaks.push(name);
}
const policy = [{ pass: sampleLeaks.length === 0, name: "No runtime file references a sample/fixture map", error: `found in: ${sampleLeaks.join(", ")}` }];
const results = [...policy, ...runRouteChecks(vectors, samples), ...await runCloudChecks(), ...await runGeometryChecks(samples["rice-hall-sample.json"])];
for (const test of results) console.log(`${test.skipped ? "SKIP" : test.pass ? "PASS" : "FAIL"} ${test.name}${test.error ? `: ${test.error}` : ""}`);
const executed = results.filter((test) => !test.skipped);
console.log(`${executed.filter((test) => test.pass).length}/${executed.length} passed; ${results.length - executed.length} browser-only checks skipped (run web/tests.html)`);
if (results.some((test) => !test.pass)) process.exitCode = 1;
