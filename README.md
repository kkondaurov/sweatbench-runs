# Sweat Bench run sources

The applications produced by accepted [Sweat Bench](https://github.com/kkondaurov/sweatbench) runs, preserved at each milestone.

## Versions

- [Version 6: 98 runs, 686 milestone snapshots](v6/README.md)
- [Version 6 readable-Elixir intervention: 18 Astra and Sol runs, 126 snapshots](v6/interventions/readable-elixir/README.md)

The [Intervention dashboard](https://kkondaurov.github.io/sweatbench/#intervention) compares readable-Elixir treatment runs with historical baselines and examines their code. This source collection contains 12 Core-and-Maintenance sweeps across 18 completed trajectories. All completed runs are retained, including non-perfect results.

The original v6 collection's run numbers match the [public dashboard](https://kkondaurov.github.io/sweatbench/). Only completed runs admitted to that dataset are included there, regardless of score. Abandoned and invalid attempts are not included. The readable-Elixir intervention is a separate collection with three treatment samples per model and effort, numbered Run 1, Run 2, and Run 3. The original 98 runs and six intervention Run 1 directories remain byte-identical.

Each run has its own directory, a short index, and seven source snapshots. The snapshots retain the submitted implementation and candidate-written tests, including bugs. They have not been repaired or reformatted for publication.

This is a source archive, not a deployment. Use an isolated environment to execute these applications. Dependencies, build output, databases, editor caches and raw agent sessions are not included.

## Verify

With Node.js installed, run:

```sh
node tools/verify.mjs
```

The verifier checks every published source file against its SHA-256 checksum, checks the complete run and milestone inventory, and rejects missing or unexpected files. It verifies the original 98 runs first, then calls the independent readable-Elixir intervention verifier. See [original export details](v6/EXPORT.md) and [intervention provenance](v6/interventions/readable-elixir/README.md#provenance-and-verification) for provenance and exclusions.

## License

Published under the [MIT license](LICENSE). See [notices](NOTICE.md) for the scope of the archive and third-party dependencies.
