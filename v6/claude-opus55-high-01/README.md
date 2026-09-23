# Claude Opus 5.5 high / Claude Code - Run 1

[All v6 runs](../README.md) | [Dashboard](https://kkondaurov.github.io/sweatbench/#models)

Public run ID: `claude-opus55-high-01`. Final scores: **38 out of 39 Core**, **10 out of 10 Maintenance**. The only failed Core family is hotel-credit lifecycle; two ordering checks failed. This is one completed run, not an estimate of the model's general success rate.

These are the submitted source files at each completed milestone, not later repairs. The public run number is the first accepted Opus 5.5 run; an earlier incomplete attempt is excluded.

| Milestone | Source | Candidate request | Files |
| --- | --- | --- | ---: |
| 1 | [Browse](milestone-1/) | [Request](milestone-1/TASK.md) | 50 |
| 2 | [Browse](milestone-2/) | [Request](milestone-2/TASK.md) | 62 |
| 3 | [Browse](milestone-3/) | [Request](milestone-3/TASK.md) | 71 |
| 4 | [Browse](milestone-4/) | [Request](milestone-4/TASK.md) | 79 |
| 5 | [Browse](milestone-5/) | [Request](milestone-5/TASK.md) | 82 |
| 6 | [Browse](milestone-6/) | [Request](milestone-6/TASK.md) | 89 |
| 7 | [Browse](milestone-7/) | [Request](milestone-7/TASK.md) | 93 |

Start with [milestone 7](milestone-7/) for the final implementation. Application code is in `lib/`, agent-written tests in `test/`, and migrations in `priv/repo/migrations/`. Earlier snapshots preserve the preceding versions. Dependencies must be installed separately using `mix.lock`; build and runtime files are omitted.

[File checksums and provenance](run.json) | [Export details](../EXPORT.md)
