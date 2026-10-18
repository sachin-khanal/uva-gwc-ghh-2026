// Owner: U3. Shared-vector and malformed-input regressions, browser or Node.
import { key, route, routeSummary, validateMap } from "./router.js";

export function runRouteChecks(vectors, samples) {
  const results = [];
  function check(name, operation) {
    try { operation(); results.push({ name, pass: true }); }
    catch (error) { results.push({ name, pass: false, error: error.message }); }
  }
  function assert(value, message = "Assertion failed") { if (!value) throw new Error(message); }
  for (const fixture of vectors.fixtures) {
    const map = fixture.map || samples[fixture.sample];
    check(`${fixture.name}: valid fixture`, () => validateMap(map));
    for (const test of fixture.cases) check(`${fixture.name}: ${test.name}`, () => {
      const actual = route(map, test.start, test.goal, test.allowStairs)?.map((n) => key(n.id)) ?? null;
      const expected = test.expected?.map(key) ?? null;
      assert(JSON.stringify(actual) === JSON.stringify(expected), `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    });
  }
  const sample = samples["rice-hall-sample.json"];
  check("Route length excludes stairs penalty", () => {
    const path = route(sample, sample.nodes[4].id, sample.nodes[7].id);
    const summary = routeSummary(sample, path);
    assert(summary.meters === 3 && summary.stairs);
  });
  const mutations = [
    ["missing fields", (m) => { delete m.nodes; }],
    ["duplicate case-insensitive IDs", (m) => { m.nodes.push({ ...m.nodes[0], id: m.nodes[0].id.toLowerCase() }); }],
    ["unsafe segment", (m) => { m.nodes[0].segmentId = "../escape"; }],
    ["invalid coordinates", (m) => { m.nodes[0].position[0] = Infinity; }],
    ["boolean coordinates", (m) => { m.nodes[0].position[0] = true; }],
    ["Float overflow", (m) => { m.nodes[0].position[0] = 1e100; }],
    ["missing endpoint", (m) => { m.edges[0].to = m.id; }],
    ["self-loop", (m) => { m.edges[0].to = m.edges[0].from; }],
    ["shortcut distance", (m) => { m.edges[0].distance = 100; }],
    ["unknown hazard", (m) => { m.edges[0].hazard = "unknown"; }],
  ];
  for (const [name, mutate] of mutations) check(`Reject ${name}`, () => {
    const map = structuredClone(sample); mutate(map);
    let rejected = false; try { validateMap(map); } catch { rejected = true; }
    assert(rejected, "Malformed map was accepted");
  });
  check("Bundle map can be previewed without decoding binary files", () => assert(validateMap({ map: sample, worldMaps: {} }) === sample));
  check("Untrusted text remains plain data", () => {
    const map = structuredClone(sample); map.name = "<script>ignored</script>";
    assert(validateMap(map).name === map.name);
  });
  return results;
}
