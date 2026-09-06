# Sweat Bench run sources

The applications produced by accepted [Sweat Bench](https://github.com/kkondaurov/sweatbench) runs, preserved at each milestone.

## Versions

- [Version 6: 98 runs, 686 milestone snapshots](v6/README.md)

Run numbers match the [public dashboard](https://kkondaurov.github.io/sweatbench/). Only completed runs admitted to that dataset are included, regardless of score. Abandoned and invalid attempts are not included.

Each run has its own directory, a short index, and seven source snapshots. The snapshots retain the submitted implementation and candidate-written tests, including bugs. They have not been repaired or reformatted for publication.

This is a source archive, not a deployment. Use an isolated environment to execute these applications. Dependencies, build output, databases, editor caches and raw agent sessions are not included.

## Verify

With Node.js installed, run:

```sh
node tools/verify.mjs
```

The verifier checks every published source file against its SHA-256 checksum, checks the complete run and milestone inventory, and rejects missing or unexpected files. See [export details](v6/EXPORT.md) for provenance and exclusions.

## License

Published under the [MIT license](LICENSE). See [notices](NOTICE.md) for the scope of the archive and third-party dependencies.
