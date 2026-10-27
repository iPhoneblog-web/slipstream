# AGENTS.md

Rules for agents changing this repository. [README.md](README.md) explains what Slipstream is
and how to build it; read it next, then only the page your task needs. The queue and the worker
it embeds are [kyrios/encode-queue](https://github.com/kyrios/encode-queue); the Funkhaus it
works for and the servers behind it are documented outside this repository.

## 1. Always

- **Write in English**, through `/anthropic-skills:plain-english`: pages, commit messages,
  answers to the maintainer. The app's screens, its messages and
  [docs/anleitung.md](docs/anleitung.md) are German, because its users read German.
- **The measurements decide the intermediate.** Every number in `Plan.swift` follows
  [docs/encoding.md](docs/encoding.md), which names the source of each. Change a number there
  first, with the measurement that justifies it (`bin/rungs.zsh`). Never guess a different one:
  ask the maintainer. The tool versions are encode-queue's ([docs/tools.md](docs/tools.md)).
- **The repository is public and neutral.** No secret, no hostname or address of a real
  installation, no fixed Funkhaus site, no personal data, no person's or customer's name in
  code, pages or commit messages; examples use `funkhaus.example.org`. The site is the user's
  choice at first launch (docs/traps.md, "Origins").
- **Run `bin/package` before you push**: the tests, the Xcode build, the signed bundle (needs
  `xcodegen`). CI runs the same on every push and pull request, and signs and notarises; a red
  run is yours.
- **Stage named paths.** Never `git add -A`, `git commit -a` or `git stash`.
- **Only CI signs with the Developer ID**, from repository secrets (decided 2026-10-26,
  [docs/release.md](docs/release.md)). Locally `bin/package` signs ad hoc. Never handle the keys,
  and never sign with the Apple Development certificate (team `2X64N8XML3`).
- **Never install anything on a user's Mac**, and never pair the maintainer's Mac with the
  queue for a test (§4).

## 2. Work in your own worktree

**The maintainer's checkout is theirs.** No edits, commits or branch switches there. Make your
own worktree under `~/worktrees`, outside any folder a sync service copies (`/tmp` is empty after
a restart):

```bash
git -C <any checkout> fetch origin
git -C <any checkout> worktree add ~/worktrees/slipstream/<topic> -b <topic> origin/main
```

- **Every change is a pull request onto `main`.** Squash only, so one pull request is one commit.
  Never push to `main`.
- **A release is a tag `v<major>.<minor>.<patch>`** on `main`, pushed after the merge:
  `git tag -a v1.0.1 -m "Slipstream 1.0.1" origin/main && git push origin v1.0.1`. CI builds,
  signs, notarises and publishes it; never upload a build from a Mac by hand. `bin/package`
  reads the tag into the bundle's version. (`v1.2` is ProRes Drop's last release.)
- **When merged:** `git worktree remove ~/worktrees/slipstream/<topic>` and
  `git branch -d <topic>`.

## 3. Commit messages

English, through `/anthropic-skills:plain-english`. The first line says what changed. The body
says why; where a number cost a measurement, the message keeps the measurement.

## 4. Tests and trying the app

**No change to `DropCore` or `HelperCore` is finished without a test** (`Tests/`, XCTest).

- **A guard needs a test in which it fires**: a file that is not a video, a codec the Mac cannot
  decode, a cancel, a wrong origin or token, a slice that does not fit, an index at the end.
- **Media tests read real files.** `Tests/DropCoreTests/fixtures/make.sh` makes them with
  ffmpeg; they are committed because they are small. Run it only to change them.
- **A change to the encode runs `bin/test-encode`** and puts its numbers into
  [docs/encoding.md](docs/encoding.md), "Measured", with the date and the Mac.
- **Try the app** from `dist/` and talk to its loopback endpoint the way the bridge does; the
  port and token are in the app group file:

  ```bash
  open -n dist/Slipstream.app
  cat ~/Library/Group\ Containers/W9N692KH39.io.github.kyrios.slipstream/loopback.json
  curl -H 'Origin: safari-web-extension://x' -H "X-Slipstream-Token: $TOKEN" \
    -H 'X-Slipstream-Site: https://<the configured host>' http://127.0.0.1:$PORT/v1/ping
  /usr/bin/log show --last 5m --predicate 'subsystem == "io.github.kyrios.slipstream"'
  ```

  Quit the app by PID when done. Never beside a running Slipstream: both would write the one app
  group file the extension reads.

Say in the pull request which tests cover the change and what is still untested; the menu and
Safari's extension settings need a person looking at the screen.

## 5. Documentation

**A page describes how things are now. Git holds how they got there.**

| kind | where | lives until |
|---|---|---|
| Entry | `AGENTS.md`, `CLAUDE.md` (imports this file), `README.md` | always |
| Reference | `docs/<topic>.md`, one topic per page | the topic ends |
| Queue | `docs/TODO.md`, open work only | each item deleted when done |

No file for handovers, session notes, reviews or status reports. Present tense; a rule carries
its reason in a sentence or two; one fact, one home. **In the same commit**, a change updates
the page that describes it and deletes a finished TODO item.
