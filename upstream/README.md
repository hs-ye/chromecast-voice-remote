# Upstream staging plan

`upstream/remaining` is a **staging branch**, based on `b0o/atvvoice` `0e8f641`.
It contains only the work that is not already covered by open upstream changes.
Do not open PRs from it until the prerequisites merge and it is rebased.

## Prerequisites

- **PR #27** (`b0o/ATVVOICE`, `zhanglongqi`) — HoldToTalk gestures and TX
  write-op selection.
- **issue #28** — `sanitize_name` fallback for all-non-ASCII names (a PR is
  expected from `kehao-chen`).

Do **not** resubmit `8eb31d6` (BLE write-op), `b8b6949` (HTT `START_SEARCH`),
`686d301` (hyphenated name), `a96fa3e` (14 dB gain) or the DC blocker:
PR #27, issue #28 and issue #13 cover or supersede them.

## Commits on this branch

| Commit | Subject | Goes in |
|---|---|---|
| `3b44d2c` | sink-backed virtual microphone | PR A |
| `055803d` | `--trigger-cmd` | PR B |
| `9368abf` | trigger logged at info | PR B (squash) |
| `793f85e` | pacing + stop hold | PR A |
| `e1106c3` | capped 150 ms lead | PR A |
| `80911d3` | phantom start + `ATVVOICE_TRIGGER` + stop on disconnect | PR B |

Hashes are staging hashes; they change on rebase.

## Tickets to raise

1. **New issue — `Audio/Source` stream never scheduled; in-process playback
   stream SIGSEGV.** Two symptoms, one code path (creating an in-process
   PipeWire stream). Evidence: the process callback ran 0 times while the
   node reported `state=running`; `pw-top` showed `QUANT 0 / BUSY 0.0us`;
   creating the same stream with `Direction::Input` produced signal 11.
   Cross-link issue #15.
2. **PR A — opt-in `--backend sink`.** Null sink + `module-remap-source` +
   `pw-cat`, pacing/lead/stop-hold, working `--mic-on-demand`, and
   `sanitize_name` from issue #28. The stock `Audio/Source` backend remains
   the default.
3. **PR B — reliable external trigger.** `--trigger-cmd` with
   `ATVVOICE_TRIGGER=start|stop`, the 750 ms / 3-frame implicit-start
   debounce, and stop on disconnect. One press = one start, one release =
   one stop.
4. **Optional PR C — sequence-gap warning.** Only if issue #9 wants it.

## Comments only

- issue #13 (gain) — the 20 dB clipping measurements; no PR unless asked.
- issue #20 (frame timeout) — current `main` resets the timer on
  `AUDIO_START`; ask for a retest/close.
- issue #9 (sequence gaps) — the `65535` values are a 16-bit underflow in
  `frame.seq.wrapping_sub(expected)`, not 65 535 dropped frames.
- issue #15 (audio doesn't start) — cross-link the new issue.

## Before opening PR A

- [ ] Make the sink backend opt-in (`--backend sink`); keep the stock
      `Audio/Source` backend as the default. This branch currently replaces
      it.
- [ ] Implement `--mic-on-demand` for the sink backend (issues #11/#12);
      do not regress it.
- [ ] Rebase onto `main` after PR #27 and issue #28 merge.
- [ ] Run `cargo test --locked`, `cargo fmt --check`, and the Nix CI checks.

## Rebase order

1. PR #27 merges.
2. issue #28's PR merges.
3. `git fetch origin && git rebase origin/main upstream/remaining`.
4. Open the new issue, then PR A and PR B.
