# Version 6 source export

## Population

This release contains the 98 unique accepted runs in the [published dataset](https://github.com/kkondaurov/sweatbench/blob/9077a7a2edb3f0cd9d53c34697dca2922871237f/evaluation/results/v6/accepted-runs.json): 73 Model runs and 25 additional Harnesses runs. The dashboard's Harnesses tab reuses another 20 Model runs. Those shared runs appear only once in this archive.

The dataset's SHA-256 is `1deb5f27754f8de1adc7c8f1f02554fcc2bb40bdc222611d3f0e3562a6042e78`. Public IDs and sample numbers are used throughout. They do not expose or depend on the numbering of discarded experiment attempts.

Every run contains the source at milestones 1 through 7. A completed run is included even when its implementation failed tests. No abandoned run, invalid evaluation, discarded attempt, or analyst-repaired implementation is included. Scores are unchanged.

## Included files

- Application modules, configuration, database migrations and static assets.
- Candidate-written tests and test support.
- The request and product documents present in each milestone workspace.
- Application README, formatter settings, `.tool-versions`, `mix.exs` and `mix.lock`.
- The benchmark workspace marker and original `.gitignore` where present in the accepted source.

The scaffold and benchmark-supplied documents are part of the application snapshot; not every file was authored by the candidate. No application source is reformatted or repaired for publication.

## Exclusions

Downloaded dependencies (`deps/`, `node_modules/`), build output (`_build/`), Git internals, runtime databases and journals, crash dumps, logs, temporary directories, coverage/generated documentation, and editor or search caches are omitted. Local copies of other milestone directories are not part of an application's source export. Raw model sessions and provider metadata are not included.

The archived applications use fictional benchmark data. Development/test keys and localhost configuration remain as submitted; they are not production settings. Install the locked dependencies in an isolated environment before attempting to run a snapshot. This source release does not include the original container images or runtime databases.

## Checksums and provenance

Each run's `run.json` identifies the model, harness, reasoning effort, public sample, final scores, accepted candidate commits and evaluation-report hashes. Every exported source file has a byte count and SHA-256 checksum. `v6/index.json` binds the complete run inventory to those per-run manifests.

The `source_tree_sha256` field hashes the exported files in lexicographic path order. For each file the input is its UTF-8 relative path, a NUL byte, the original file bytes, and another NUL byte. The export has fewer files than the local runtime snapshot, so this hash is separate from `recorded_checkpoint_sha256`.

The latter is the original full checkpoint hash where the runner recorded one. All 91 recorded hashes were verified before publication: 87 against the local snapshot as stored, and four after excluding subsequently added editor caches, downloaded dependencies or nested snapshot copies. The four affected snapshots' tracked files also matched their accepted Git commits. No source replacements were needed. Each snapshot's `checkpoint_verification` records the result and any excluded post-evaluation paths.

The other 595 snapshots belong to older runs that did not record a full checkpoint hash; their value is `null`, not a retrospectively invented historical hash. The file hashes still permit byte-for-byte verification of the published archive. All 98 run identities and public sample mappings, 686 milestone evaluation records, and recorded candidate-test inventories were checked against the accepted local records. A second read of all 41,445 exported source files confirmed their hashes independently.

From the repository root:

```sh
node tools/verify.mjs
```

The verifier reads files only. It does not compile or execute candidate applications, contact model providers, or rerun the benchmark.
