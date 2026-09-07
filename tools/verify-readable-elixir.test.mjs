import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { verifyReadableElixir } from './verify-readable-elixir.mjs';

const archive = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const collection = 'v6/interventions/readable-elixir';
const id = 'v6-readable-astra-low-01';
const solMedium = 'v6-readable-sol-medium-01';
const solHigh = 'v6-readable-sol-high-01';
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'archive-repeat-verifier-test-'));
  t.after(() => fs.rmSync(root, {recursive:true,force:true}));
  fs.mkdirSync(path.join(root, 'v6'), {recursive:true});
  fs.copyFileSync(path.join(archive, 'v6/index.json'), path.join(root, 'v6/index.json'));
  fs.cpSync(path.join(archive, collection), path.join(root, collection), {recursive:true});
  return root;
}

function mutateRun(root, mutate, runId = id) {
  const dir = path.join(root, collection);
  const manifest = path.join(dir, runId, 'run.json');
  const run = JSON.parse(fs.readFileSync(manifest));
  const index = JSON.parse(fs.readFileSync(path.join(dir, 'index.json')));
  mutate(run, index);
  const bytes = JSON.stringify(run, null, 2) + '\n';
  fs.writeFileSync(manifest, bytes);
  index.runs.find(r => r.id === runId).manifest_sha256 = sha(bytes);
  fs.writeFileSync(path.join(dir, 'index.json'), JSON.stringify(index, null, 2) + '\n');
}

function reject(name, mutate, expected) {
  test(name, t => {
    const root = fixture(t);
    mutate(root, path.join(root, collection));
    assert.throws(() => verifyReadableElixir(root, {quiet:true}), expected);
  });
}

test('verifies 18 mixed-model interventions and 12 sweeps without changing baseline population', () => {
  const result = verifyReadableElixir(archive, {quiet:true});
  assert.equal(result.runs, 18);
  assert.equal(result.sweeps, 12);
  assert.equal(result.snapshots, 126);
  assert.equal(result.files, 8054);
  assert.equal(result.bytes, 23792853);
  assert.equal(JSON.parse(fs.readFileSync(path.join(archive, 'v6/index.json'))).runs.length, 98);
});

test('retains the completed, non-perfect Sol medium trajectory and public Run 1', () => {
  const run = JSON.parse(fs.readFileSync(path.join(archive, collection, solMedium, 'run.json')));
  assert.equal(run.model, 'gpt-5.6-sol'); assert.equal(run.sample, 1);
  assert.deepEqual(run.scores, {core:38,maintenance:8,scenarios:92});
  assert.equal(run.snapshots[6].correctness.status, 'failed');
  assert.equal(run.snapshots[6].correctness.scenario_tests.filter(t => t.status === 'failed').length, 2);
  assert.equal(run.correctness.final_families.filter(f => f.status === 'failed').length, 3);
  assert.equal(run.correctness.prefix_depth, 6);
});

function scenarioFailure(run, milestone, familyId) {
  const current = run.snapshots[milestone - 1].correctness;
  const member = 'GroupStay.Private.LaunchDepositApiTest::test a flexible group sums separately rounded room deposits';
  current.scenario_tests.find(t => t.id === member).status = 'failed';
  current.scenarios.passed--; current.status = 'failed';
  for (const vector of [current.introduced_families, current.cumulative_core_families]) {
    const family = vector.find(f => f.id === familyId);
    if (family) {family.status = 'failed'; family.failing_members = [member];}
  }
}

test('accepts an internally consistent ship-time failure repaired before final state', t => {
  const root = fixture(t);
  mutateRun(root, run => {
    scenarioFailure(run, 1, 'deposit-pricing');
    run.snapshots[0].correctness.family_tracks.core.passed--;
    run.correctness.tracks.core.ship_time.passed--;
    run.correctness.scenarios.ship_time.passed--;
    run.correctness.scenarios.checkpoint_invocations.passed--;
    run.correctness.prefix_depth = 0;
  }, solHigh);
  assert.equal(verifyReadableElixir(root, {quiet:true}).runs, 18);
});

test('accepts a recovered Core regression without conflating it with ship or final scores', t => {
  const root = fixture(t);
  mutateRun(root, run => {
    scenarioFailure(run, 2, 'deposit-pricing');
    run.correctness.prefix_depth = 1;
    run.correctness.regression_episodes = {count:1,episodes:[{family:'deposit-pricing',opened_at:2,recovered_at:3}]};
  }, solHigh);
  assert.equal(verifyReadableElixir(root, {quiet:true}).runs, 18);
});

reject('rejects model identity drift even with rebound index identity', root => {
  mutateRun(root, (run, index) => {run.model = 'gpt-6-astra'; index.runs.find(r => r.id === run.id).model = run.model;}, solMedium);
}, /strictly equal/);
reject('rejects inflated Sol medium headline and index scores', root => {
  mutateRun(root, (run, index) => {run.scores.core = 39; index.runs.find(r => r.id === run.id).scores.core = 39;}, solMedium);
}, /Final score projection/);
reject('rejects inflated final track scores even when headlines agree', root => {
  mutateRun(root, (run, index) => {
    run.scores.core = 39; index.runs.find(r => r.id === run.id).scores.core = 39;
    run.correctness.tracks.core.final_state.passed = 39;
  }, solMedium);
}, /Final family score/);
reject('rejects impossible scenario scores', root => {
  mutateRun(root, run => {run.correctness.scenarios.final_state.passed = 95;}, solMedium);
}, /passed bounds/);
reject('rejects inflated ship-time family scores', root => {
  mutateRun(root, run => {run.correctness.tracks.core.ship_time.passed = 39;}, solMedium);
}, /Ship-time family score/);
reject('rejects inflated ship-time scenario scores', root => {
  mutateRun(root, run => {run.correctness.scenarios.ship_time.passed = 94;}, solMedium);
}, /Ship-time scenario score/);
reject('rejects changed milestone status', root => {
  mutateRun(root, run => {run.snapshots[6].correctness.status = 'passed';}, solMedium);
}, /Milestone status/);
reject('rejects missing failure evidence', root => {
  mutateRun(root, run => {run.correctness.final_families.find(f => f.status === 'failed').failing_members = [];}, solMedium);
}, /family failure evidence/);
reject('rejects a failure that names a passing scenario', root => {
  mutateRun(root, run => {
    const c = run.snapshots[6].correctness;
    const member = c.scenario_tests.find(t => t.status === 'passed').id;
    const familyId = run.correctness.final_families.find(f => f.status === 'failed').id;
    for (const vector of [run.correctness.final_families,c.introduced_families,c.cumulative_core_families]) {
      const f = vector.find(f => f.id === familyId); if (f) f.failing_members = [member];
    }
  }, solMedium);
}, /Family failure\/scenario evidence/);
reject('rejects removed scenario evidence from a non-perfect run', root => {
  mutateRun(root, run => {for (const s of run.snapshots) delete s.correctness.scenario_tests;}, solMedium);
}, /Non-perfect scenarios require case evidence/);
reject('rejects duplicate scenario IDs', root => {
  mutateRun(root, run => {const t = run.snapshots[6].correctness.scenario_tests; t[1].id = t[0].id;}, solMedium);
}, /Duplicate scenario ID/);
reject('rejects incorrect scenario evidence totals', root => {
  mutateRun(root, run => {run.snapshots[6].correctness.scenario_tests.find(t => t.status === 'failed').status = 'passed';}, solMedium);
}, /Scenario evidence summary/);
reject('rejects an inflated Core prefix', root => {
  mutateRun(root, run => {run.correctness.prefix_depth = 7;}, solMedium);
}, /Core prefix depth/);
reject('rejects fabricated regression episodes', root => {
  mutateRun(root, run => {run.correctness.regression_episodes.count = 1;}, solMedium);
}, /Regression episodes/);
reject('rejects an inflated sweep count', (_, dir) => {
  const filename = path.join(dir, 'index.json');
  const index = JSON.parse(fs.readFileSync(filename)); index.sweeps = 6;
  fs.writeFileSync(filename, JSON.stringify(index));
}, /Sweep count/);
reject('rejects a private machine path after rebinding file and manifest hashes', (root, dir) => {
  mutateRun(root, run => {
    const file = run.snapshots[0].files.find(f => f.path === 'config/dev.exs');
    const filename = path.join(dir, solMedium, 'milestone-1', file.path);
    const bytes = Buffer.concat([fs.readFileSync(filename), Buffer.from('\n# /' + 'Users/example/private\n')]);
    fs.writeFileSync(filename, bytes); file.bytes = bytes.length; file.sha256 = sha(bytes);
  }, solMedium);
}, /Publication-safety hazard/);

const lowRepeat = 'v6-readable-astra-low-02';
test('retains failed historical upgrade checks even when the repeat final milestone passes', () => {
  for (const suffix of ['02', '03']) {
    const run = JSON.parse(fs.readFileSync(path.join(archive, collection, `v6-readable-astra-low-${suffix}`, 'run.json')));
    assert.equal(run.sample, Number(suffix));
    assert.deepEqual(run.scores, {core:38, maintenance:9, scenarios:92});
    assert.equal(run.snapshots[3].correctness.status, 'failed');
    assert.equal(run.snapshots[3].correctness.system_checks.filter(c => c.status === 'failed').length, 2);
    assert.equal(run.snapshots[6].correctness.status, 'passed');
    assert.equal(run.correctness.prefix_depth, 3);
  }
});

test('retains all four Sol repeats including the non-sweeps', () => {
  for (const [suffix, core, maintenance, scenarios] of [
    ['medium-02',37,7,90], ['medium-03',39,10,94], ['high-02',37,10,92], ['high-03',38,10,92],
  ]) {
    const run = JSON.parse(fs.readFileSync(path.join(archive, collection, `v6-readable-sol-${suffix}`, 'run.json')));
    assert.deepEqual(run.scores, {core,maintenance,scenarios});
    assert.equal(run.snapshots.length, 7);
  }
});

reject('rejects rebinding a repeat to the pilot campaign', root => {
  mutateRun(root, (run, index) => {
    run.provenance.campaign_id = index.campaign_id;
    run.provenance.campaign_manifest_sha256 = index.provenance.campaign_manifest_sha256;
  }, lowRepeat);
}, /Run campaign/);

reject('rejects a repeat campaign manifest mismatch', root => {
  mutateRun(root, run => {run.provenance.campaign_manifest_sha256 = '0'.repeat(64);}, lowRepeat);
}, /Run campaign manifest/);

reject('rejects baseline-style repeat renumbering even when the index agrees', root => {
  mutateRun(root, (run, index) => {run.sample = 4; index.runs.find(r => r.id === run.id).sample = 4;}, lowRepeat);
}, /Exact intervention sample/);

reject('rejects missing repeat runs', (_, dir) => {
  const filename = path.join(dir, 'index.json');
  const index = JSON.parse(fs.readFileSync(filename)); index.runs.pop();
  fs.writeFileSync(filename, JSON.stringify(index));
}, /Exact intervention run inventory/);

reject('rejects repeat campaign membership drift', (_, dir) => {
  const filename = path.join(dir, 'index.json');
  const index = JSON.parse(fs.readFileSync(filename)); index.campaigns[1].run_ids.pop();
  fs.writeFileSync(filename, JSON.stringify(index));
}, /Campaign run membership/);

reject('rejects repeat benchmark drift even with a valid hash shape', root => {
  mutateRun(root, run => {run.provenance.benchmark_bundle_sha256 = '0'.repeat(64);}, lowRepeat);
}, /Frozen benchmark, runner, and container/);

reject('rejects removed scenario evidence from a perfect repeat', root => {
  mutateRun(root, run => {for (const s of run.snapshots) delete s.correctness.scenario_tests;}, 'v6-readable-astra-high-03');
}, /Repeat scenario evidence required/);

reject('rejects historical failures relabeled as a repeat sweep', root => {
  mutateRun(root, (run, index) => {
    run.scores = {core:39,maintenance:10,scenarios:94};
    index.runs.find(r => r.id === run.id).scores = run.scores;
  }, lowRepeat);
}, /Final score projection/);

reject('rejects retained databases even after adding them to a repeat manifest', (root, dir) => {
  mutateRun(root, run => {
    const bytes = Buffer.from('not a real database');
    const snapshot = run.snapshots[0];
    fs.writeFileSync(path.join(dir, lowRepeat, snapshot.directory, 'data.db'), bytes);
    snapshot.files.push({path:'data.db',bytes:bytes.length,sha256:sha(bytes)});
    snapshot.files.sort((a,b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  }, lowRepeat);
}, /Excluded filename/);

reject('rejects a dependency path containing otherwise safe repeated bytes', (root, dir) => {
  mutateRun(root, run => {
    const bytes = fs.readFileSync(path.join(dir, lowRepeat, 'milestone-1/mix.exs'));
    const directory = path.join(dir, lowRepeat, 'milestone-1/deps');
    fs.mkdirSync(directory);
    fs.writeFileSync(path.join(directory, 'mix.exs'), bytes);
    run.snapshots[0].files.push({path:'deps/mix.exs',bytes:bytes.length,sha256:sha(bytes)});
    run.snapshots[0].files.sort((a,b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  }, lowRepeat);
}, /Excluded directory/);

reject('rejects changed source bytes', (_, dir) => {
  fs.appendFileSync(path.join(dir, id, 'milestone-1/mix.exs'), '\n');
}, /size/);
reject('rejects missing candidate documentation', (_, dir) => {
  fs.unlinkSync(path.join(dir, id, 'milestone-7/docs/PRODUCT.md'));
}, /ENOENT/);
reject('rejects extra source files', (_, dir) => {
  fs.writeFileSync(path.join(dir, id, 'milestone-7/unexpected.txt'), 'unexpected');
}, /file inventory/);
reject('rejects extra collection metadata', (_, dir) => {
  fs.writeFileSync(path.join(dir, 'unexpected.json'), '{}');
}, /file inventory/);
reject('rejects empty unexpected directories', (_, dir) => {
  fs.mkdirSync(path.join(dir, id, 'milestone-7/deps'));
}, /directory inventory/);
reject('rejects an unexpected intervention collection', root => {
  fs.mkdirSync(path.join(root, 'v6/interventions/unknown'));
}, /collection inventory/);
reject('rejects file symlinks even if target bytes match', (_, dir) => {
  const filename = path.join(dir, id, 'milestone-1/mix.exs');
  fs.unlinkSync(filename);
  fs.symlinkSync('../milestone-2/mix.exs', filename);
}, /symlink/);
reject('rejects directory symlinks', (_, dir) => {
  const filename = path.join(dir, id, 'milestone-1/docs');
  fs.rmSync(filename, {recursive:true});
  fs.symlinkSync('../milestone-2/docs', filename);
}, /symlink/);
reject('rejects duplicate manifest paths after rebinding manifest checksum', root => {
  mutateRun(root, run => run.snapshots[0].files.splice(1, 0, run.snapshots[0].files[0]));
}, /Duplicate source path/);
reject('rejects path traversal after rebinding manifest checksum', root => {
  mutateRun(root, run => { run.snapshots[0].files[0].path = '../escaped'; });
}, /Unsafe manifest path/);
reject('rejects a missing accepted milestone', root => {
  mutateRun(root, run => run.snapshots.pop());
}, /deep-equal/);
reject('rejects baseline-style renumbering', root => {
  mutateRun(root, (run, index) => { run.sample = 4; index.runs[0].sample = 4; });
}, /4 !== 1/);
reject('rejects an altered checkpoint verification hash', root => {
  mutateRun(root, run => { run.snapshots[0].checkpoint_verification.recomputed_sha256 = '0'.repeat(64); });
}, /strictly equal/);
reject('rejects a failed integrity audit', root => {
  mutateRun(root, run => { run.snapshots[0].evaluation_verification.integrity_audit.status = 'failed'; });
}, /deep-equal/);
reject('rejects an incorrect candidate-test inventory hash', root => {
  mutateRun(root, run => { run.snapshots[0].candidate_test_inventory.files[0].sha256 = '0'.repeat(64); });
}, /test inventory checksum/);
reject('rejects changed instruction bytes', (_, dir) => {
  fs.appendFileSync(path.join(dir, 'instruction.txt'), '\n');
}, /strictly equal/);
reject('rejects changed design documentation', (_, dir) => {
  fs.appendFileSync(path.join(dir, 'README.md'), '\n');
}, /README checksum/);
reject('rejects an altered original baseline index', root => {
  fs.appendFileSync(path.join(root, 'v6/index.json'), '\n');
}, /baseline index changed/);
reject('rejects a provider-token pattern even with rebound file and manifest hashes', (root, dir) => {
  mutateRun(root, run => {
    const file = run.snapshots[0].files.find(f => f.path === 'config/dev.exs');
    const filename = path.join(dir, id, 'milestone-1', file.path);
    const bytes = Buffer.concat([fs.readFileSync(filename), Buffer.from('\n# ' + 'sk-' + 'x'.repeat(32) + '\n')]);
    fs.writeFileSync(filename, bytes);
    file.bytes = bytes.length; file.sha256 = sha(bytes);
  });
}, /Publication-safety hazard/);
