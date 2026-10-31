# Developing zafi

This file exists only on the `dev` branch.

## Branches

| Branch | Contents |
| --- | --- |
| `main` | The package and nothing else: `src/`, `build.zig`, `build.zig.zon`, `README.md`, `LICENSE`. What users fetch. |
| `dev` | Everything: the package plus the verification tooling, benchmarks, audits, plans and reviews. All work happens here. |

`main` is never edited directly. `tools/release.sh [version]` copies the package
paths from `dev` onto `main`, runs the unit-test gates, commits and optionally
tags `v<version>`. It does not push.

## Layout (dev)

```
build.zig, build.zig.zon, src/   the package (identical on main)
tools/                           separate Zig package depending on ../ via .path
  build.zig                      fixtures, parity, audit and benchmark steps
  fixtures/                      Taffy XML fixture runner (+ run_all.py, one process per fixture)
  parity/                        Rust-vs-Zig differential harness
  bench/                         Zig benchmarks, Rust Taffy mirror, compare scripts
  api_audit.py                   static public-surface diff against Taffy
  fetch-reference.sh, pin.env    the pinned Taffy checkout under .references/taffy
  release.sh                     dev -> main
docs/                            porting ledger, parity report, campaign plan
audit/                           raw evidence and past review reports
```

## Gates

From the repository root:

```sh
zig build test
zig build test -Dserde=true
```

From `tools/` (needs `.references/taffy`; run `tools/fetch-reference.sh`):

```sh
zig build fixtures -Doptimize=ReleaseSafe          # Taffy XML corpus at TAFFY_REV
zig build fixtures -- --group grid --filter span    # subset
zig build parity -- --report                        # needs cargo
zig build audit
zig build bench-compare -- --repeat 5               # vs Rust Taffy at TAFFY_REV
zig build bench-cpu -- --repeat 5 --cpu 2
zig build bench-allocs
```

`tools/pin.env` names the tracked Taffy revision. The fixture corpus and the Rust
benchmark mirror both read `.references/taffy`, so keep that checkout at
`TAFFY_REV` when measuring.
