import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';

const efforts = ['low', 'medium', 'high', 'xhigh'];
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

function allPassed(families, label) {
  assert.equal(new Set(families.map(f => f.id)).size, families.length, `${label}: duplicate families`);
  for (const family of families) {
    assert.equal(family.status, 'passed', label);
    assert.deepEqual(family.failing_members, [], label);
    assert(['core', 'judgment'].includes(family.track), label);
    assert(milestones.includes(family.stage), label);
  }
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
  assert.deepEqual(index.runs.map(r => r.id), efforts.map(e => `v6-readable-astra-${e}-01`));
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
  let files = 0, bytes = 0, snapshots = 0, testFiles = 0;
  const seenContents = new Set();
  for (const [position, entry] of index.runs.entries()) {
    const runRoot = path.join(root, entry.id);
    const raw = regular(path.join(runRoot, 'run.json'));
    assert.equal(sha(raw), entry.manifest_sha256, `${entry.id}: manifest checksum`);
    safety('run.json', raw);
    const run = JSON.parse(raw);
    for (const k of ['id','group','sample','display','view','model','effort','harness','scores']) assert.deepEqual(run[k], entry[k], `${entry.id}: ${k}`);
    assert.equal(run.group, `readable-astra-${efforts[position]}`);
    assert.equal(run.effort, efforts[position]);
    assert.equal(run.model, 'gpt-6-astra');
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
    assert.deepEqual(run.scores, {core:39, maintenance:10, scenarios:94});
    for (const phase of ['ship_time', 'final_state']) {
      assert.deepEqual(run.correctness.tracks.core[phase], {passed:39,total:39});
      assert.deepEqual(run.correctness.tracks.maintenance[phase], {passed:10,total:10});
      assert.deepEqual(run.correctness.scenarios[phase], {passed:94,total:94});
    }
    assert.equal(run.correctness.prefix_depth, 7);
    assert.deepEqual(run.correctness.regression_episodes, {count:0,episodes:[]});
    allPassed(run.correctness.final_families, run.id);
    for (const [track, count] of [['core',39],['judgment',10]]) assert.equal(run.correctness.final_families.filter(f => f.track === track).length, count);
    const readme = regular(path.join(runRoot, 'README.md'));
    safety('README.md', readme);
    assert.equal(sha(readme), entry.readme_sha256, `${entry.id}: README checksum`);
    assert(readme.toString().includes('Run 1'));
    expectedFiles.push(`${run.id}/run.json`, `${run.id}/README.md`);
    assert.deepEqual(run.snapshots.map(s => s.milestone), milestones);
    const introduced = [];
    for (const snapshot of run.snapshots) {
      const n = snapshot.milestone;
      assert.equal(snapshot.directory, `milestone-${n}`);
      gitHash(snapshot.candidate_commit); gitHash(snapshot.candidate_commit_tree);
      hash(snapshot.evaluation_report_sha256); hash(snapshot.recorded_checkpoint_sha256);
      assert.equal(snapshot.checkpoint_verification.status, 'matched_recorded_hash');
      assert.equal(snapshot.checkpoint_verification.recomputed_sha256, snapshot.recorded_checkpoint_sha256);
      assert.deepEqual(snapshot.checkpoint_verification.excluded_post_evaluation_paths, []);
      assert.deepEqual(snapshot.evaluation_verification, {report_hash_matches_state:true,integrity_audit:{status:'passed',hits:[]},report_scores_match_state:true,report_families_match_state:true});
      assert.equal(snapshot.correctness.status, 'passed');
      assert.equal(snapshot.correctness.scenarios.passed, snapshot.correctness.scenarios.total);
      const expectedFamilies = run.correctness.final_families.filter(f => f.stage === n);
      assert.deepEqual(normalize(snapshot.correctness.introduced_families), normalize(expectedFamilies));
      introduced.push(...snapshot.correctness.introduced_families);
      assert.deepEqual(normalize(snapshot.correctness.cumulative_core_families), normalize(run.correctness.final_families.filter(f => f.stage <= n && f.track === 'core')));
      for (const track of ['core','judgment']) {
        const total = expectedFamilies.filter(f => f.track === track).length;
        assert.deepEqual(snapshot.correctness.family_tracks[track], {passed:total,total});
      }
      assert(snapshot.correctness.system_checks.every(c => c.status === 'passed'));
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
    assert.deepEqual(normalize(introduced), normalize(run.correctness.final_families));
  }
  assert.deepEqual(actual.files.sort(), expectedFiles.sort(), 'Intervention file inventory: missing or unexpected files');
  const expectedDirs = new Set();
  for (const filename of expectedFiles) {
    const parts = filename.split('/');
    for (let n = 1; n < parts.length; n++) expectedDirs.add(parts.slice(0, n).join('/'));
  }
  assert.deepEqual(actual.directories.sort(), [...expectedDirs].sort(), 'Intervention directory inventory');
  assert.equal(snapshots, index.snapshots); assert.equal(snapshots, 28);
  assert.equal(files, index.files); assert.equal(files, 1801);
  assert.equal(bytes, index.bytes); assert.equal(bytes, 5459604);
  assert.deepEqual(index.publication_validation, {runs:4,snapshots:28,checkpoint_hashes_matched:28,report_hashes_matched:28,
    integrity_audits_passed:28,test_inventories_matched:28,source_files:files,source_bytes:bytes,source_symlinks:0,post_evaluation_exclusions:0});
  const summary = {runs:4,snapshots,files,bytes,unique_source_contents:seenContents.size,candidate_test_files:testFiles};
  if (!quiet) console.log(`Verified readable-Elixir intervention: 4 runs, ${snapshots} snapshots, ${files} source files (${bytes} bytes); baseline inventory remains 98 runs.`);
  return summary;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  verifyReadableElixir(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..'));
}
