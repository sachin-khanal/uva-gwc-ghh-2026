// Optional Node 20+ runner; no npm install or dependencies required.
import { readFile } from "node:fs/promises";
import { runRouteChecks } from "./route-tests.js";
import { runCloudChecks } from "./cloud-tests.js";
import { runGeometryChecks } from "./geometry-tests.js";
const read = async (name) => JSON.parse(await readFile(new URL(name, import.meta.url), "utf8"));
const vectors = await read("../Samples/route-vectors.json"), samples = {};
for (const fixture of vectors.fixtures) if (fixture.sample) samples[fixture.sample] = await read(`./fixtures/${fixture.sample}`);
const results = [...runRouteChecks(vectors, samples), ...await runCloudChecks(), ...await runGeometryChecks(samples["rice-hall-sample.json"])];
for (const test of results) console.log(`${test.pass ? "PASS" : "FAIL"} ${test.name}${test.error ? `: ${test.error}` : ""}`);
console.log(`${results.filter((test) => test.pass).length}/${results.length} passed`);
if (results.some((test) => !test.pass)) process.exitCode = 1;
