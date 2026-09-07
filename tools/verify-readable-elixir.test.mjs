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
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'readable-elixir-verifier-test-'));
  t.after(() => fs.rmSync(root, {recursive:true,force:true}));
  fs.mkdirSync(path.join(root, 'v6'), {recursive:true});
  fs.copyFileSync(path.join(archive, 'v6/index.json'), path.join(root, 'v6/index.json'));
  fs.cpSync(path.join(archive, collection), path.join(root, collection), {recursive:true});
  return root;
}

function mutateRun(root, mutate) {
  const dir = path.join(root, collection);
  const manifest = path.join(dir, id, 'run.json');
  const run = JSON.parse(fs.readFileSync(manifest));
  const index = JSON.parse(fs.readFileSync(path.join(dir, 'index.json')));
  mutate(run, index);
  const bytes = JSON.stringify(run, null, 2) + '\n';
  fs.writeFileSync(manifest, bytes);
  index.runs[0].manifest_sha256 = sha(bytes);
  fs.writeFileSync(path.join(dir, 'index.json'), JSON.stringify(index, null, 2) + '\n');
}

function reject(name, mutate, expected) {
  test(name, t => {
    const root = fixture(t);
    mutate(root, path.join(root, collection));
    assert.throws(() => verifyReadableElixir(root, {quiet:true}), expected);
  });
}

test('verifies all four interventions without changing baseline population', () => {
  const result = verifyReadableElixir(archive, {quiet:true});
  assert.equal(result.runs, 4);
  assert.equal(result.snapshots, 28);
  assert.equal(result.files, 1801);
  assert.equal(result.bytes, 5459604);
  assert.equal(JSON.parse(fs.readFileSync(path.join(archive, 'v6/index.json'))).runs.length, 98);
});

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
