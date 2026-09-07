import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const version = path.join(root, 'v6');
const index = JSON.parse(fs.readFileSync(path.join(version, 'index.json')));
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const safe = value => typeof value === 'string' && value && !value.startsWith('/') && !value.split('/').some(p => !p || p === '.' || p === '..' || p.includes('\\'));
function walk(directory, relative = '') {
  const result = [];
  for (const item of fs.readdirSync(path.join(directory, relative), { withFileTypes: true })) {
    assert(!item.isSymbolicLink(), `Unexpected symlink: ${relative}/${item.name}`);
    const rel = path.posix.join(relative, item.name);
    if (item.isDirectory()) result.push(...walk(directory, rel));
    else { assert(item.isFile(), rel); result.push(rel); }
  }
  return result.sort();
}
assert.equal(index.version, 6);
assert.equal(index.runs.length, 98);
assert.equal(new Set(index.runs.map(r => r.id)).size, 98);
assert.equal(index.runs.filter(r => r.view === 'models').length, 73);
assert.equal(index.runs.filter(r => r.view === 'harness').length, 25);
const actualRuns = fs.readdirSync(version, {withFileTypes:true}).filter(d => d.isDirectory()).map(d => d.name).sort();
assert.deepEqual(actualRuns, [...index.runs.map(r => r.id), 'interventions'].sort());
let fileCount = 0, bytes = 0, snapshots = 0;
for (const expected of index.runs) {
  assert(safe(expected.id) && !expected.id.includes('/'));
  const dir = path.join(version, expected.id);
  const raw = fs.readFileSync(path.join(dir, 'run.json'));
  assert.equal(sha(raw), expected.manifest_sha256, `${expected.id}: manifest`);
  const run = JSON.parse(raw);
  for (const field of ['id','group','sample','model','effort','harness','view']) assert.deepEqual(run[field], expected[field], `${run.id}: ${field}`);
  assert.deepEqual(run.snapshots.map(s => s.milestone), [1,2,3,4,5,6,7]);
  const expectedFiles = ['README.md', 'run.json'];
  for (const snapshot of run.snapshots) {
    assert.equal(snapshot.directory, `milestone-${snapshot.milestone}`);
    const seen = new Set();
    const tree = crypto.createHash('sha256');
    let snapshotBytes = 0;
    for (const file of snapshot.files) {
      assert(safe(file.path), `Unsafe path in ${run.id}`);
      assert(!seen.has(file.path), `Duplicate path in ${run.id}`);
      seen.add(file.path);
      const relative = `${snapshot.directory}/${file.path}`;
      const content = fs.readFileSync(path.join(dir, relative));
      assert.equal(content.length, file.bytes, `${run.id}/${relative}: size`);
      assert.equal(sha(content), file.sha256, `${run.id}/${relative}: checksum`);
      tree.update(file.path); tree.update('\0'); tree.update(content); tree.update('\0');
      expectedFiles.push(relative);
      fileCount++; snapshotBytes += content.length;
    }
    assert.deepEqual(snapshot.files.map(f => f.path), [...seen].sort(), 'File order');
    assert.equal(tree.digest('hex'), snapshot.source_tree_sha256);
    assert.equal(snapshotBytes, snapshot.bytes);
    assert(seen.has('mix.exs') && seen.has('mix.lock') && seen.has('TASK.md'), `${run.id}: incomplete application`);
    bytes += snapshotBytes; snapshots++;
  }
  assert.deepEqual(walk(dir), expectedFiles.sort(), `${run.id}: file inventory`);
}
assert.equal(snapshots, index.snapshots);
assert.equal(fileCount, index.files);
assert.equal(bytes, index.bytes);
console.log(`Verified ${index.runs.length} runs, ${snapshots} snapshots, ${fileCount} source files (${bytes} bytes).`);
const { verifyReadableElixir } = await import('./verify-readable-elixir.mjs');
verifyReadableElixir(root);
