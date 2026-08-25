# `hello` — a minimal Vivarium example

The smallest project that exercises the manifest, both harvesting paths, and
streamed output. Its test command is POSIX `sh`, so it runs unchanged on
either guest.

```
examples/hello/
  viv.json    the manifest
  test.sh     the test command it names
```

`viv.json`:

```json
{
  "name": "hello",
  "test": "sh test.sh",
  "artifacts": ["logs/**/*"],
  "env": { "GREETING": "hello from viv.json" }
}
```

`test.sh` writes to stdout and stderr, writes `logs/build.log` (harvested
because it matches the `artifacts` glob), and writes
`$VIV_ARTIFACTS/greeting.txt` (harvested regardless of any glob, because
everything under `$VIV_ARTIFACTS` is collected). It exits 0.

## Running it

With a template already created (see the top-level `README.md`):

```sh
viv run --code examples/hello
```

Vivarium reads `examples/hello/viv.json` for the command, copies
`examples/hello` into the guest, runs `sh test.sh` there, and streams its
output to the terminal as it runs:

```
hello from stdout, run <run-id>
hello from stderr, run <run-id>
```

## What to expect in `results/`

```
~/.vivarium/runs/<run-id>/results/
  report.json
  report.md
  test-stdout.txt      "hello from stdout, run <run-id>"
  test-stderr.txt      "hello from stderr, run <run-id>"
  run.log
  artifacts/
    greeting.txt        "hello from viv.json"
    logs/
      build.log          "build finished, run <run-id>"
```

The run passed, so `VM.bundle` and `Shared/` under
`~/.vivarium/runs/<run-id>/` are already gone by the time this finishes —
only `results/` is left.
