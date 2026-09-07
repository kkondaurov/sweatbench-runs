# Readable Elixir Instruction: Astra And Sol

**18 completed trajectories, 126 accepted milestone snapshots, 12 Core-and-Maintenance sweeps.** This is a separate v6 intervention collection, not an addition to the [original 98-run dataset](../../README.md). Each model-and-effort configuration has three treatment samples, numbered **Run 1**, **Run 2**, and **Run 3**, retaining its exact `v6-readable-astra-*-01/02/03` or `v6-readable-sol-*-01/02/03` identifier. The six original Run 1 directories, including their manifests and historical READMEs, are preserved byte for byte; this collection README describes the full population.

| Configuration | Sample | Final Core | Final Maintenance | Source trajectory |
| --- | --- | --- | --- | --- |
| GPT-6 Astra low | Run 1 | 39 out of 39 | 10 out of 10 | [All seven milestones](v6-readable-astra-low-01/README.md) |
| GPT-6 Astra medium | Run 1 | 39 out of 39 | 10 out of 10 | [All seven milestones](v6-readable-astra-medium-01/README.md) |
| GPT-6 Astra high | Run 1 | 39 out of 39 | 10 out of 10 | [All seven milestones](v6-readable-astra-high-01/README.md) |
| GPT-6 Astra xhigh | Run 1 | 39 out of 39 | 10 out of 10 | [All seven milestones](v6-readable-astra-xhigh-01/README.md) |
| GPT-5.6 Sol medium | Run 1 | 38 out of 39 | 8 out of 10 | [All seven milestones](v6-readable-sol-medium-01/README.md) |
| GPT-5.6 Sol high | Run 1 | 39 out of 39 | 10 out of 10 | [All seven milestones](v6-readable-sol-high-01/README.md) |
| GPT-6 Astra low | Run 2 | 38 out of 39 | 9 out of 10 | [All seven milestones](v6-readable-astra-low-02/README.md) |
| GPT-6 Astra medium | Run 2 | 39 out of 39 | 10 out of 10 | [All seven milestones](v6-readable-astra-medium-02/README.md) |
| GPT-6 Astra high | Run 2 | 39 out of 39 | 10 out of 10 | [All seven milestones](v6-readable-astra-high-02/README.md) |
| GPT-6 Astra xhigh | Run 2 | 39 out of 39 | 10 out of 10 | [All seven milestones](v6-readable-astra-xhigh-02/README.md) |
| GPT-5.6 Sol medium | Run 2 | 37 out of 39 | 7 out of 10 | [All seven milestones](v6-readable-sol-medium-02/README.md) |
| GPT-5.6 Sol high | Run 2 | 37 out of 39 | 10 out of 10 | [All seven milestones](v6-readable-sol-high-02/README.md) |
| GPT-6 Astra low | Run 3 | 38 out of 39 | 9 out of 10 | [All seven milestones](v6-readable-astra-low-03/README.md) |
| GPT-6 Astra medium | Run 3 | 39 out of 39 | 10 out of 10 | [All seven milestones](v6-readable-astra-medium-03/README.md) |
| GPT-6 Astra high | Run 3 | 39 out of 39 | 10 out of 10 | [All seven milestones](v6-readable-astra-high-03/README.md) |
| GPT-6 Astra xhigh | Run 3 | 39 out of 39 | 10 out of 10 | [All seven milestones](v6-readable-astra-xhigh-03/README.md) |
| GPT-5.6 Sol medium | Run 3 | 39 out of 39 | 10 out of 10 | [All seven milestones](v6-readable-sol-medium-03/README.md) |
| GPT-5.6 Sol high | Run 3 | 38 out of 39 | 10 out of 10 | [All seven milestones](v6-readable-sol-high-03/README.md) |

## Design

The treatment is the exact text in [instruction.txt](instruction.txt): a general request for idiomatic, well-structured, readable Elixir/Phoenix code, cohesive modules, descriptive names, and useful domain documentation. The runner appended the same instruction to every standard milestone prompt using `--prompt-suffix`. The file is retained byte for byte, including its trailing newline; the effective suffix is the whitespace-trimmed text. Both hashes are recorded in [index.json](index.json).

The frozen v6 requirements, evaluator, deterministic scoring, and endogenous candidate-test policy were unchanged. The handoff protocol starts each trajectory from a fresh scaffold and uses a fresh Codex session at each milestone, carrying forward that trajectory's own implementation, history, and tests. No baseline source, evaluator feedback, failure analysis, or mechanism-specific advice was supplied to the candidates.

Both campaigns record GPT-6 Astra and GPT-5.6 Sol on Codex CLI 0.153.4, with the same immutable container image, 2 CPUs and 4096 MiB memory. Exact benchmark, runner, container, campaign, and source-state fingerprints are in the manifests. `v6-readable-elixir-pilot-20260907-01` contains the six Run 1 trajectories; `v6-readable-elixir-repeats-20260907-01` contains all 12 Run 2 and Run 3 trajectories. These are additional samples, not replacement attempts or baseline reruns.

The pilot has five sweeps and the repeat campaign has seven. Astra medium, high, and xhigh sweep all three samples; Astra low sweeps only Run 1. Sol medium sweeps only Run 3; Sol high sweeps only Run 1. All 12 sweeps record 39 out of 39 Core, 10 out of 10 Maintenance, and 94 out of 94 scenarios. The six non-sweeps retain their failures: Astra low Runs 2 and 3, Sol medium Run 1, and Sol high Runs 2 and 3 each record 92 out of 94 final-state scenarios; Sol medium Run 2 records 90 out of 94. Ship-time and final-state headline scores agree for every run in this collection. Completion, passed integrity, and source acceptance do not mean every evaluation passed.

These are the existing evaluator outcomes, not a new readability score or a benchmark rerun. Per-milestone scenario totals in the manifests include the checks invoked at that milestone; they must not be summed to infer the final-state total. Historical upgrade checks retain their trajectory outcomes in final-state scoring.

Three treatment samples per model and effort test repeatability, not a randomized instruction effect. Historical baseline samples are not paired reruns. Earlier Sol baselines ran natively on macOS with Codex CLI 0.149.0-alpha.4.3 or 0.150.0-alpha.8; these Sol intervention runs used Docker with Codex CLI 0.153.4, so the execution environment also differs. These results do **not** establish that the instruction caused an improvement in readability, correctness, or maintainability. Source organization, naming, domain documentation, and change behavior need separate, concrete source review; module counts and code size are not quality scores. Cost, usage, runtime comparisons, and qualitative findings are outside this source export.

## Source Boundary

Every run contains all seven accepted source snapshots, including application code, configuration, migrations, static assets, `mix.exs`, `mix.lock`, candidate-written tests and support, README and domain documentation, and benchmark-supplied requests and product documents. Not every file was authored by the candidate. No candidate code, tests, or documentation were repaired, reformatted, or redacted.

Dependencies, builds, Git internals, databases and journals, runtime temporary files, generated documentation, coverage, editor caches, logs, raw sessions, and private machine paths are excluded. The original full checkpoint hashes were verified **before** applying source-only exclusions. All 126 matched as stored, with no post-evaluation paths removed to restore a match. The 262 omitted non-source files were under runtime `tmp/` directories; empty runtime directories are also not exported. The archive contains 8,054 source-file instances (23,792,853 bytes) across these snapshots.

These applications contain fictional benchmark data and scaffold development/test key material, not production credentials. Run them only in an isolated environment with separately installed locked dependencies. This is a source archive, not a deployment.

## Provenance And Verification

[index.json](index.json) binds the 18 run manifests, their READMEs, this design README, and the exact instruction file to SHA-256 checksums. Its schema-2 `campaigns` array assigns each exact run ID and sample to its source campaign; the legacy singular `campaign_id` and `provenance` fields continue to describe the pilot only. `source_validation_sha256` identifies the combined publication-time audit of both campaigns. Each `run.json` records the original campaign and run IDs, original state and campaign hashes, benchmark manifest/bundle and entrypoint hashes, runner identity, accepted candidate commits and Git tree IDs, all seven evaluation-report and original checkpoint hashes, correctness projections, candidate-test inventories, and every exported file's path, byte count, and SHA-256. Individual scenario IDs and statuses are included for all repeat runs and the two original Sol runs. The four original Astra manifests retain their legacy all-pass evidence without modification.

The source-tree digest is SHA-256 over the exported files in lexicographic relative-path order, appending each UTF-8 path, a NUL byte, its original bytes, and another NUL byte. The original checkpoint digest used the runner's sorted `pathlib.Path` order over **all** files, before source filtering. These are distinct digests and must not be substituted for one another.

Before export, an independent read-only audit recomputed all 126 original checkpoint and report hashes, checked all integrity statuses and candidate-test inventories, and recomputed 49 family outcomes and 94 scenario outcomes per trajectory from reports and the frozen benchmark definitions. It also reconciled milestone inventories, ship-time scores, cumulative Core families, Core prefixes, and regression episodes with the states. All 18 frozen benchmark bundles and entrypoint hashes were verified; both campaigns use identical benchmark, runner, container, and instruction identities. The six existing manifests were reconciled again and their 2,672 source-file instances compared byte for byte with the frozen snapshots. The exporter independently reread and hashed every new source file. The manifests retain publication-time evidence of these checks; raw state/report files are not published because they contain local paths or execution output. The public verifier checks archive bytes and internal consistency, not the unavailable private artifacts or model execution.

From the archive repository root:

```sh
node tools/verify.mjs
node tools/verify-readable-elixir.mjs
node --test tools/verify-readable-elixir.test.mjs
```

The first command preserves the original **98-run / 686-snapshot** verification, then invokes the independent intervention verifier. The second verifies only this collection. Both reject missing files, unexpected files or directories, and symlinks within this collection; the intervention verifier also checks manifest references, test inventories, source checksums, and common publication-safety hazards. Neither command executes candidate code, contacts providers, or reruns the benchmark. Static safety scanning does not prove the absence of every possible secret.
