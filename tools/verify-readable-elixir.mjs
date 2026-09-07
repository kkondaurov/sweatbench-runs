import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';

const efforts = ['low', 'medium', 'high', 'xhigh'];
const configurations = [...efforts.map(e => ['astra', e, 'gpt-6-astra']), ...['medium', 'high'].map(e => ['sol', e, 'gpt-5.6-sol'])];
const milestones = [1,2,3,4,5,6,7];
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const safe = name => typeof name === 'string' && /^[a-zA-Z0-9_.\/-]+$/.test(name) && !name.split('/').some(p => !p || p === '.' || p === '..');
const hash = value => assert.match(value, /^[a-f0-9]{64}$/, 'Invalid SHA-256');
const gitHash = value => assert.match(value, /^[a-f0-9]{40}$/, 'Invalid Git object ID');
const normalize = families => [...families].sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
const excludedDirs = new Set(['deps','_build','.git','node_modules','tmp','.elixir_ls','.lexical','.cache','.ck','.expert','cover','doc','logs','sessions','__pycache__']);
const sensitiveName = /^(?:\.env(?:\..*)?|\.netrc|\.npmrc|\.pypirc|auth\.json|credentials(?:\.json)?|id_rsa|id_ed25519|\.DS_Store)$|\.(?:pem|p12|pfx|key|db|sqlite|sqlite3)(?:-(?:wal|shm|journal))?$|\.(?:beam|ez|log|dump|pyc|jsonl|har|pcap|zip|gz|tar)$/i;
const hazards = [
  /-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----|PuTTY-User-Key-File-\d+:/,
  /\b(?:sk-(?:proj-|svcacct-|ant-api\d+-)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|(?:AKIA|ASIA)[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{30,}|xox[baprs]-[A-Za-z0-9-]{15,}|(?:sk|rk)_live_[A-Za-z0-9]{16,}|glpat-[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{30,}|hf_[A-Za-z0-9]{25,})\b/,
  /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/,
  /(?:\/Users\/|\/home\/|\/root\/|[A-Za-z]:\\Users\\|\/private\/(?:var|tmp)\/)\S+/,
  /\b(?:https?|postgres(?:ql)?|mysql|redis|amqps?|mongodb(?:\+srv)?):\/\/[^\s/"'<>@]+@[^\s"'<>]+/,
  /\b(?:Bearer|Basic)\s+[A-Za-z0-9+/_=.~-]{12,}/i,
  /SQLite format 3/,
];

function regular(filename) {
  const stat = fs.lstatSync(filename);
  assert(stat.isFile() && !stat.isSymbolicLink(), `Expected regular file: ${filename}`);
  return fs.readFileSync(filename);
}

function directory(filename) {
  const stat = fs.lstatSync(filename);
  assert(stat.isDirectory() && !stat.isSymbolicLink(), `Expected real directory: ${filename}`);
}

function walk(root, relative = '', result = {files: [], directories: []}) {
  directory(path.join(root, relative));
  for (const item of fs.readdirSync(path.join(root, relative), {withFileTypes: true})) {
    const rel = path.posix.join(relative, item.name);
    assert(safe(rel), `Unsafe archive path: ${rel}`);
    assert(!item.isSymbolicLink(), `Unexpected symlink: ${rel}`);
    if (item.isDirectory()) { result.directories.push(rel); walk(root, rel, result); }
    else { assert(item.isFile(), `Unexpected non-file: ${rel}`); result.files.push(rel); }
  }
  return result;
}

function safety(rel, content) {
  assert(safe(rel), `Unsafe source path: ${rel}`);
  assert(!rel.split('/').slice(0, -1).some(p => excludedDirs.has(p)), `Excluded directory: ${rel}`);
  assert(!sensitiveName.test(path.posix.basename(rel)), `Excluded filename: ${rel}`);
  assert(!/^milestone-\d+\//.test(rel), `Nested snapshot: ${rel}`);
  if (rel === 'priv/static/favicon.ico') {
    assert.equal(sha(content), '01723aeae3ce3b5195a8f42e3eb6e9018a8c08b7acda4ed382b31341811f0a8a', 'Unexpected scaffold icon');
  } else {
    const text = new TextDecoder('utf-8', {fatal: true}).decode(content);
    assert(!text.includes('\0'), `Unexpected binary: ${rel}`);
    for (const pattern of hazards) assert(!pattern.test(text), `Publication-safety hazard in ${rel}`);
  }
}

function validateFamilies(families, label) {
  assert.equal(new Set(families.map(f => f.id)).size, families.length, `${label}: duplicate families`);
  for (const family of families) {
    assert.equal(typeof family.id, 'string', label);
    assert(['passed', 'failed'].includes(family.status), label);
    assert(Array.isArray(family.failing_members), label);
    assert.equal(family.status === 'passed', family.failing_members.length === 0, `${label}: family failure evidence`);
    assert.equal(new Set(family.failing_members).size, family.failing_members.length, label);
    assert(family.failing_members.every(m => typeof m === 'string' && m.length > 0), label);
    assert(['core', 'judgment'].includes(family.track), label);
    assert(milestones.includes(family.stage), label);
  }
}

const tally = items => ({passed:items.filter(f => f.status === 'passed').length, total:items.length});
const definitions = families => normalize(families.map(({id, stage, track}) => ({id, stage, track})));
function score(value, total, label) {
  assert.deepEqual(Object.keys(value).sort(), ['passed', 'total'], label);
  assert.equal(value.total, total, `${label}: total`);
  assert(Number.isInteger(value.passed) && value.passed >= 0 && value.passed <= total, `${label}: passed bounds`);
}

export function verifyReadableElixir(archiveRoot, {quiet = false} = {}) {
  const interventions = path.join(archiveRoot, 'v6/interventions');
  directory(interventions);
  assert.deepEqual(fs.readdirSync(interventions), ['readable-elixir'], 'Intervention collection inventory');
  const root = path.join(interventions, 'readable-elixir');
  const actual = walk(root);
  const indexBytes = regular(path.join(root, 'index.json'));
  safety('index.json', indexBytes);
  const index = JSON.parse(indexBytes);
  assert.equal(index.schema_version, 1);
  assert.equal(index.version, 6);
  assert.equal(index.collection, 'readable-elixir');
  assert.equal(index.view, 'interventions');
  assert.equal(index.campaign_id, 'v6-readable-elixir-pilot-20260907-01');
  assert.deepEqual(index.runs.map(r => r.id), configurations.map(([family, effort]) => `v6-readable-${family}-${effort}-01`));
  assert.equal(index.baseline.index, '../../index.json');
  const baselineBytes = regular(path.join(archiveRoot, 'v6/index.json'));
  assert.equal(sha(baselineBytes), index.baseline.index_sha256, 'Original baseline index changed');
  const baseline = JSON.parse(baselineBytes);
  assert.equal(baseline.runs.length, 98);
  assert.equal(baseline.snapshots, 686);
  assert.equal(index.baseline.runs, 98);
  assert.equal(index.baseline.snapshots, 686);
  assert.equal(index.baseline.included_here, false);
  assert(index.runs.every(r => !baseline.runs.some(b => b.id === r.id)), 'Treatment ID collides with baseline');
  for (const value of Object.values(index.provenance)) hash(value);
  assert.equal(index.instruction.file, 'instruction.txt');
  assert.equal(index.instruction.channel, '--prompt-suffix');
  assert.deepEqual(index.instruction.milestones, milestones);
  const instruction = regular(path.join(root, 'instruction.txt'));
  safety('instruction.txt', instruction);
  assert.equal(instruction.length, index.instruction.bytes);
  assert.equal(sha(instruction), index.instruction.file_sha256);
  assert.equal(index.instruction.file_sha256, '55af546ecb51f2b4f9181aa09ca5a3d77a5158d2219c08862434767420f09d39');
  assert.equal(sha(Buffer.from(instruction.toString('utf8').trim())), index.instruction.effective_prompt_suffix_sha256);
  assert.deepEqual(index.documentation.map(d => d.path), ['README.md']);
  const expectedFiles = ['index.json', 'instruction.txt', 'README.md'];
  const design = regular(path.join(root, 'README.md'));
  safety('README.md', design);
  assert.equal(sha(design), index.documentation[0].sha256, 'Design README checksum');
  let files = 0, bytes = 0, snapshots = 0, testFiles = 0, sweeps = 0;
  let familyDefinitions;
  const seenContents = new Set();
  for (const [position, entry] of index.runs.entries()) {
    const runRoot = path.join(root, entry.id);
    const raw = regular(path.join(runRoot, 'run.json'));
    assert.equal(sha(raw), entry.manifest_sha256, `${entry.id}: manifest checksum`);
    safety('run.json', raw);
    const run = JSON.parse(raw);
    for (const k of ['id','group','sample','display','view','model','effort','harness','scores']) assert.deepEqual(run[k], entry[k], `${entry.id}: ${k}`);
    const [modelFamily, effort, model] = configurations[position];
    assert.equal(run.group, `readable-${modelFamily}-${effort}`);
    assert.equal(run.effort, effort);
    assert.equal(run.model, model);
    assert.equal(run.sample, 1);
    assert.equal(run.view, 'interventions');
    assert.equal(run.harness, 'codex');
    assert.equal(run.protocol, 'handoff');
    assert.equal(run.candidate_tests, 'endogenous');
    assert.equal(run.canonical_milestone_tests_provided, false);
    assert.equal(run.codex_version, 'codex-cli 0.153.4');
    assert.equal(run.container.container_cpus, 2);
    assert.equal(run.container.container_memory_mib, 4096);
    assert.equal(run.container.container_image, run.container.container_image_id);
    assert.match(run.container.container_image, /^sha256:[a-f0-9]{64}$/);
    assert(Number.isFinite(Date.parse(run.created_at)) && Date.parse(run.completed_at) > Date.parse(run.created_at));
    gitHash(run.benchmark_commit); gitHash(run.runner_commit); hash(run.runner_sha256);
    assert.equal(run.provenance.source_run_id, run.id);
    assert.equal(run.provenance.campaign_id, index.campaign_id);
    assert.equal(run.provenance.campaign_manifest_sha256, index.provenance.campaign_manifest_sha256);
    assert.equal(run.provenance.instruction_file_sha256, index.instruction.file_sha256);
    assert.equal(run.provenance.effective_prompt_suffix_sha256, index.instruction.effective_prompt_suffix_sha256);
    for (const k of ['source_state_sha256','benchmark_manifest_sha256','benchmark_bundle_sha256']) hash(run.provenance[k]);
    assert.deepEqual(Object.keys(run.provenance.benchmark_entrypoint_sha256).sort(), ['bench.py', 'run_candidate.py']);
    for (const value of Object.values(run.provenance.benchmark_entrypoint_sha256)) hash(value);
    for (const phase of ['ship_time', 'final_state']) {
      score(run.correctness.tracks.core[phase], 39, `${run.id}: Core ${phase}`);
      score(run.correctness.tracks.maintenance[phase], 10, `${run.id}: Maintenance ${phase}`);
      score(run.correctness.scenarios[phase], 94, `${run.id}: scenarios ${phase}`);
    }
    score(run.correctness.scenarios.checkpoint_invocations, 94, `${run.id}: checkpoint invocations`);
    assert.deepEqual(run.scores, {core:run.correctness.tracks.core.final_state.passed,
      maintenance:run.correctness.tracks.maintenance.final_state.passed, scenarios:run.correctness.scenarios.final_state.passed}, 'Final score projection');
    if (run.scores.core === 39 && run.scores.maintenance === 10) sweeps++;
    validateFamilies(run.correctness.final_families, run.id);
    familyDefinitions ??= definitions(run.correctness.final_families);
    assert.deepEqual(definitions(run.correctness.final_families), familyDefinitions, 'Frozen family definitions');
    for (const [track, count] of [['core',39],['judgment',10]]) assert.equal(run.correctness.final_families.filter(f => f.track === track).length, count);
    for (const [track, publicTrack] of [['core','core'],['judgment','maintenance']]) {
      assert.deepEqual(run.correctness.tracks[publicTrack].final_state, tally(run.correctness.final_families.filter(f => f.track === track)), 'Final family score');
    }
    const readme = regular(path.join(runRoot, 'README.md'));
    safety('README.md', readme);
    assert.equal(sha(readme), entry.readme_sha256, `${entry.id}: README checksum`);
    assert(readme.toString().includes('Run 1'));
    expectedFiles.push(`${run.id}/run.json`, `${run.id}/README.md`);
    assert.deepEqual(run.snapshots.map(s => s.milestone), milestones);
    const introduced = [];
    const systemOutcomes = new Map(), previousTests = new Set(), everPassed = new Set(), openEpisodes = new Map(), episodes = [];
    let prefix = 0, prefixIntact = true, shipPassed = 0, shipTotal = 0, previousTestCount = 0;
    const explicitScenarios = run.snapshots.some(s => s.correctness.scenario_tests !== undefined);
    for (const snapshot of run.snapshots) {
      const n = snapshot.milestone;
      assert.equal(snapshot.directory, `milestone-${n}`);
      gitHash(snapshot.candidate_commit); gitHash(snapshot.candidate_commit_tree);
      hash(snapshot.evaluation_report_sha256); hash(snapshot.recorded_checkpoint_sha256);
      assert.equal(snapshot.checkpoint_verification.status, 'matched_recorded_hash');
      assert.equal(snapshot.checkpoint_verification.recomputed_sha256, snapshot.recorded_checkpoint_sha256);
      assert.deepEqual(snapshot.checkpoint_verification.excluded_post_evaluation_paths, []);
      assert.deepEqual(snapshot.evaluation_verification, {report_hash_matches_state:true,integrity_audit:{status:'passed',hits:[]},report_scores_match_state:true,report_families_match_state:true});
      const correctness = snapshot.correctness;
      const caseCount = [12,22,29,50,61,73,83][n-1];
      const checkCount = [0,2,1,2,2,2,2][n-1];
      score(correctness.scenarios, caseCount + checkCount, `${run.id} M${n}: scenario summary`);
      assert.equal(correctness.status, correctness.scenarios.passed === correctness.scenarios.total ? 'passed' : 'failed', 'Milestone status');
      const expectedFamilies = run.correctness.final_families.filter(f => f.stage === n);
      validateFamilies(correctness.introduced_families, `${run.id} M${n}: introduced`);
      validateFamilies(correctness.cumulative_core_families, `${run.id} M${n}: cumulative`);
      assert.deepEqual(definitions(correctness.introduced_families), definitions(expectedFamilies), 'Introduced family inventory');
      introduced.push(...correctness.introduced_families);
      assert.deepEqual(definitions(correctness.cumulative_core_families), definitions(run.correctness.final_families.filter(f => f.stage <= n && f.track === 'core')), 'Cumulative family inventory');
      assert.deepEqual(normalize(correctness.introduced_families.filter(f => f.track === 'core')), normalize(correctness.cumulative_core_families.filter(f => f.stage === n)), 'Introduced/cumulative Core outcomes');
      if (n === 7) assert.deepEqual(normalize(correctness.cumulative_core_families), normalize(run.correctness.final_families.filter(f => f.track === 'core')), 'Final cumulative outcomes');
      if (n === 7) assert.deepEqual(normalize(correctness.introduced_families), normalize(expectedFamilies), 'Final introduced outcomes');
      for (const track of ['core','judgment']) {
        assert.deepEqual(correctness.family_tracks[track], tally(correctness.introduced_families.filter(f => f.track === track)), 'Introduced family score');
      }
      assert.equal(correctness.system_checks.length, checkCount);
      for (const check of correctness.system_checks) {
        assert(typeof check.name === 'string' && check.name.length > 0 && !systemOutcomes.has(check.name), 'System-check identity');
        assert(['passed','failed'].includes(check.status), 'System-check status');
        systemOutcomes.set(check.name, check.status);
        shipPassed += Number(check.status === 'passed'); shipTotal++;
      }
      if (explicitScenarios) {
        const tests = correctness.scenario_tests;
        assert(Array.isArray(tests) && tests.length === caseCount, 'Scenario-test inventory');
        const currentTests = new Map(tests.map(t => [t.id, t.status]));
        assert.equal(currentTests.size, tests.length, 'Duplicate scenario ID');
        assert(tests.every(t => typeof t.id === 'string' && t.id.length > 0 && ['passed','failed'].includes(t.status)), 'Scenario status');
        assert([...previousTests].every(id => currentTests.has(id)), 'Cumulative scenario inventory');
        assert.deepEqual(correctness.scenarios, tally([...tests, ...correctness.system_checks]), 'Scenario evidence summary');
        for (const t of tests) {
          if (!previousTests.has(t.id)) {shipTotal++; shipPassed += Number(t.status === 'passed');}
          previousTests.add(t.id);
        }
        for (const f of [...correctness.introduced_families, ...correctness.cumulative_core_families, ...(n === 7 ? run.correctness.final_families : [])]) {
          for (const member of f.failing_members) assert.equal(member.startsWith('system:') ? systemOutcomes.get(member.slice(7)) : currentTests.get(member), 'failed', 'Family failure/scenario evidence');
        }
      } else {
        // Legacy manifests omit individual cases; only lossless all-pass inference is possible.
        assert.equal(correctness.scenarios.passed, correctness.scenarios.total, 'Non-perfect scenarios require case evidence');
        assert([...correctness.introduced_families, ...correctness.cumulative_core_families].every(f => f.status === 'passed'), 'Legacy family/scenario evidence');
        shipTotal += caseCount - previousTestCount; shipPassed += caseCount - previousTestCount;
      }
      previousTestCount = caseCount;
      prefixIntact &&= correctness.cumulative_core_families.every(f => f.status === 'passed');
      if (prefixIntact) prefix = n;
      for (const f of correctness.cumulative_core_families) {
        if (f.status === 'passed') {
          everPassed.add(f.id);
          if (openEpisodes.has(f.id)) {openEpisodes.get(f.id).recovered_at = n; openEpisodes.delete(f.id);}
        } else if (everPassed.has(f.id) && !openEpisodes.has(f.id)) {
          const episode = {family:f.id, opened_at:n, recovered_at:null};
          episodes.push(episode); openEpisodes.set(f.id, episode);
        }
      }
      assert.deepEqual(snapshot.files.map(f => f.path), snapshot.files.map(f => f.path).sort(), 'Source file order');
      const seen = new Map();
      const tree = crypto.createHash('sha256');
      let snapshotBytes = 0;
      for (const file of snapshot.files) {
        assert(safe(file.path), `Unsafe manifest path: ${file.path}`);
        assert(!seen.has(file.path), `Duplicate source path: ${file.path}`);
        seen.set(file.path, file.sha256);
        const rel = `${run.id}/${snapshot.directory}/${file.path}`;
        const content = regular(path.join(root, rel));
        assert.equal(content.length, file.bytes, `${rel}: size`);
        assert.equal(sha(content), file.sha256, `${rel}: checksum`);
        // Check path policy on every file, even when its bytes repeat elsewhere.
        safety(file.path, content);
        seenContents.add(file.sha256);
        tree.update(file.path); tree.update('\0'); tree.update(content); tree.update('\0');
        expectedFiles.push(rel); files++; snapshotBytes += content.length;
      }
      assert.equal(tree.digest('hex'), snapshot.source_tree_sha256, 'Source tree checksum');
      assert.equal(snapshotBytes, snapshot.bytes);
      assert(snapshot.checkpoint_verification.full_tree_files >= seen.size);
      assert(snapshot.checkpoint_verification.full_tree_bytes >= snapshotBytes);
      const excludedCount = Object.values(snapshot.export_exclusions).reduce((sum, count) => {
        assert(Number.isInteger(count) && count > 0); return sum + count;
      }, 0);
      assert.equal(snapshot.checkpoint_verification.full_tree_files, seen.size + excludedCount);
      for (const required of ['mix.exs','mix.lock','TASK.md','README.md','docs/PRODUCT.md']) assert(seen.has(required), `${run.id}: missing ${required}`);
      const inventory = snapshot.candidate_test_inventory;
      assert.equal(inventory.files.length, inventory.file_count);
      assert.deepEqual(inventory.files.map(f => f.path).sort(), [...seen.keys()].filter(p => p.startsWith('test/') && /\.exs?$/.test(p)).sort());
      for (const test of inventory.files) assert.equal(seen.get(test.path), test.sha256, 'Candidate test inventory checksum');
      testFiles += inventory.file_count;
      bytes += snapshotBytes; snapshots++;
    }
    for (const [track, publicTrack] of [['core','core'],['judgment','maintenance']]) {
      assert.deepEqual(run.correctness.tracks[publicTrack].ship_time, tally(introduced.filter(f => f.track === track)), 'Ship-time family score');
    }
    assert.deepEqual(run.correctness.scenarios.ship_time, {passed:shipPassed,total:shipTotal}, 'Ship-time scenario score');
    assert.deepEqual(run.correctness.scenarios.checkpoint_invocations, {passed:shipPassed,total:shipTotal}, 'Checkpoint scenario score');
    const last = run.snapshots.at(-1).correctness;
    const finalPassed = last.scenarios.passed - tally(last.system_checks).passed + [...systemOutcomes.values()].filter(s => s === 'passed').length;
    assert.deepEqual(run.correctness.scenarios.final_state, {passed:finalPassed,total:83 + systemOutcomes.size}, 'Final scenario score');
    assert.equal(run.correctness.prefix_depth, prefix, 'Core prefix depth');
    assert.deepEqual(run.correctness.regression_episodes, {count:episodes.length,episodes}, 'Regression episodes');
  }
  assert.deepEqual(actual.files.sort(), expectedFiles.sort(), 'Intervention file inventory: missing or unexpected files');
  const expectedDirs = new Set();
  for (const filename of expectedFiles) {
    const parts = filename.split('/');
    for (let n = 1; n < parts.length; n++) expectedDirs.add(parts.slice(0, n).join('/'));
  }
  assert.deepEqual(actual.directories.sort(), [...expectedDirs].sort(), 'Intervention directory inventory');
  const runs = index.runs.length;
  assert.equal(snapshots, index.snapshots); assert.equal(snapshots, runs * milestones.length);
  assert.equal(files, index.files);
  assert.equal(bytes, index.bytes);
  assert.equal(sweeps, index.sweeps, 'Sweep count');
  assert.deepEqual(index.publication_validation, {runs,snapshots,checkpoint_hashes_matched:snapshots,report_hashes_matched:snapshots,
    integrity_audits_passed:snapshots,test_inventories_matched:snapshots,source_files:files,source_bytes:bytes,source_symlinks:0,post_evaluation_exclusions:0});
  const summary = {runs,sweeps,snapshots,files,bytes,unique_source_contents:seenContents.size,candidate_test_files:testFiles};
  if (!quiet) console.log(`Verified readable-Elixir intervention: ${runs} runs, ${sweeps} sweeps, ${snapshots} snapshots, ${files} source files (${bytes} bytes); baseline inventory remains 98 runs.`);
  return summary;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  verifyReadableElixir(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..'));
}
