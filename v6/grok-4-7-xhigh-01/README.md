# Grok 4.7 xhigh / OpenCode - Run 1

[All v6 runs](../README.md) | [Dashboard](https://kkondaurov.github.io/sweatbench/#models)

Public run ID: `grok-4-7-xhigh-01`. Final scores: **35 out of 39 Core**, **7 out of 10 Maintenance**, **87 out of 94 scenarios**.

The run completed on 21 September 2026 using `openrouter/x-ai/grok-4.7` with xhigh reasoning in OpenCode 1.18.31. Agent runtime was 3h 49m; recorded API cost was $36.5156816. Costs include all seven milestone sessions and reconcile with their saved OpenCode records. No subagents were used.

These are the submitted source files, including the original bugs and candidate-written tests. No implementation has been repaired or reformatted for publication. All seven recorded checkpoint hashes and evaluation-report hashes were verified against the accepted run.

| Milestone | Source | Candidate request |
| --- | --- | --- |
| 1 | [Browse](milestone-1/) | [Request](milestone-1/TASK.md) |
| 2 | [Browse](milestone-2/) | [Request](milestone-2/TASK.md) |
| 3 | [Browse](milestone-3/) | [Request](milestone-3/TASK.md) |
| 4 | [Browse](milestone-4/) | [Request](milestone-4/TASK.md) |
| 5 | [Browse](milestone-5/) | [Request](milestone-5/TASK.md) |
| 6 | [Browse](milestone-6/) | [Request](milestone-6/TASK.md) |
| 7 | [Browse](milestone-7/) | [Request](milestone-7/TASK.md) |

Start with [milestone 7](milestone-7/) for the final implementation. Application code is in `lib/`, candidate-written tests in `test/`, and migrations in `priv/repo/migrations/`. Install locked dependencies in an isolated environment. Runtime databases, dependencies and raw agent sessions are not included.

[File checksums and provenance](run.json) | [Export details](../EXPORT.md)
