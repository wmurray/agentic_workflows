# mission-control

The engine behind the mission-control board: a set of read-only detectors, a single-writer
lock, and a terminal dashboard, all driven off one `state.json`. It runs several tickets
through plan → implement → review → draft-PR concurrently, stopping at two human gates.

This directory holds the **code and config**. The **runtime data** (`state.json`, the
archive, the writer lock, the heartbeat, the inbox, the pause and coder flags) lives in
`~/.claude/mission-control/`, which symlinks the scripts back here. One copy of the code,
so the repo and the running loop cannot diverge; git is the durable backup.

## Layout

```
mc-*.sh              the engine — detectors, the lock, the inbox drain
dash.sh              the renderer (a pure function of state.json)
adapters/
  CONTRACT.md        the two adapter contracts, and the decisions behind them
  dispatch.sh        sourced by every script: routes `tracker …` / `host …`
  tracker/           jira.sh · fixture.sh
  host/              github.sh · fixture.sh
profiles/
  example.env        starter template — copy to local.env and fill in
  fixture.env        points the engine at the file-backed adapters (committed)
  local.env          your real values (GITIGNORED)
fixtures/example/    a board + tracker + host dataset the whole engine can run against
test/smoke.sh        runs the engine against the fixtures; asserts the live board is untouched
```

## No provider is named in the engine

Every tracker or PR-host call goes through one of two dispatchers, so swapping providers
means writing an adapter, not editing the engine:

```sh
tracker fields_of KEY-1 KEY-2      # → adapters/tracker/$MC_TRACKER.sh
host    list_prs owner/repo all    # → adapters/host/$MC_HOST.sh
```

Five tracker ops and four host ops cover the whole engine. `cycles`, `vetting` and
`review_threads` are **optional capabilities** — a provider without a sprint/cycle concept
degrades deliberately rather than breaking. See `adapters/CONTRACT.md`.

## Running it without a tracker account

```sh
./test/smoke.sh        # the whole engine against fixtures, plus the cycle-less degrade
./test/smoke.sh -v     # ... printing each script's output
```

`profiles/fixture.env` redirects every write target into the fixture directory, so nothing
touches the real board. The smoke test stamps the live runtime files first and re-checks
them at the end, so a script that escapes fails the run.

To drive one script by hand:

```sh
MC_PROFILE=profiles/fixture.env ./mc-poll.sh
```

## Setting it up for your own org

1. `cp profiles/example.env profiles/local.env` and fill it in. Every value is
   `${VAR:-default}`, so an explicit environment variable always wins.
2. Point `MC_TRACKER` / `MC_HOST` at an adapter. Ship one for your provider if it isn't
   there yet — the contract is five ops and four ops.
3. Symlink the scripts into your runtime directory, and keep the runtime data out of git.

`local.env` is gitignored. This repo is public: no org value belongs in a committed file.
