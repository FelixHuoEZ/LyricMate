# Isolated Source Alpha Acceptance

## Evidence Scope

The 2026-10-23 closeout validation is based on public main `6070e7deaa174b8441a6b79172ebb663ad039db2`. It reuses the production controller, source adapter, settings, recording preferences, SwiftUI workspace, AppKit floating panel and menu presentation, but uses a **test-only entry point**, injected playback work and intercepted HTTP. It is not a fresh install of a signed consumer release.

| Case | Observed Result |
| --- | --- |
| Fresh temporary suite | Disconnected and empty; no remembered following, floating window or experimental platform sources. |
| Native seed process | 29 checks passed, including initial score selection, version-specific offsets, track isolation, menu, transparent panel, hover controls and command feedback/readback. |
| Separate restore process | 31 checks passed. A saved lower-scoring version overrides the highest score after revalidation; two versions retain 450 ms and -200 ms independently, another recording retains 700 ms. Sources, floating settings and position also restore. |
| Injected permission denial | 11 checks passed: visible error, no live highlighting, disabled controls and no automatic retry. This is application error-handling evidence, not the macOS consent dialog. |
| Injected missing player | 10 checks passed without launching a player. |
| Separate real macOS permission probes | Two new test identities returned initially `-1744` (consent needed). The user allowed one (`0`) and denied the other (`-1743`); non-prompting rechecks returned the same decisions. Only permission preflight was called, with no song reads or playback events. |

The native reports contain 81 passing checks across four synthetic phases, with different process IDs for seed and restore. Actual permission decisions are recorded separately from each probe's expected-status verdict: one probe had an expectation mismatch, while its raw request/recheck values establish the allowed branch. The original failed verdict is retained privately, not overwritten or hidden by resetting permissions. An expectation mismatch alone is not a production defect.

Own-view PNG renders and app-scoped accessibility observations supplement the assertions. They do not certify every compositor effect, monitor layout, animation quality, accessibility setting or audible synchronization. No real catalog search, recording identity, playback command or listening test is claimed by this run. Local evidence and screenshots stay outside the source tree.

## Repeat The Synthetic Native Checks

Build scripts only compile and ad-hoc sign. They never launch, install or overwrite an existing output. Native runs below open test windows; run them intentionally in a macOS desktop session, not hosted CI.

```sh
bash scripts/build-source-alpha-acceptance.sh
work="$(mktemp -d /private/tmp/lyricmate-alpha-acceptance.XXXXXXXX)"
app='dist/LyricMate Alpha Acceptance.app/Contents/MacOS/LyricMateAlphaAcceptance'
"$app" --phase seed --workspace "$work" --auto-run --auto-exit
"$app" --phase restore --workspace "$work" --auto-run --auto-exit
cat "$work/seed.json" "$work/restore.json"
```

Use a **different new workspace** for each `--phase denied` and `--phase missing` run. Verify each report has `finished: true`, `passed: true` and every check passing; exit code zero alone is insufficient. Omit `--auto-exit` to inspect the workspace. Omit `--auto-run` to inspect the disconnected first state before clicking Run.

The HTTP protocol intercepts every request and fails closed except for the synthetic `fixture.invalid` responses. The playback work never discovers or contacts a real player. Preferences use `local.lyricmate.alpha.acceptance.<temporary-directory-name>`, never the production or daily edition domain. Saved fixture data and reports are temporary and must not be published as personal acceptance evidence.

After all test processes exit, the exact random suite can be removed:

```sh
suite="local.lyricmate.alpha.acceptance.${work##*/}"
defaults delete "$suite"
```

Do not broaden this to production suites, blanket preferences cleanup or TCC resets. Retain reports privately if needed, then remove only the exact generated temporary workspaces and test bundles.

## Optional Real Permission Checks

These require separate user authorization and an already-running Spotify. They do not run automatically, including in CI.

```sh
bash scripts/build-source-alpha-acceptance.sh --permission-denied
bash scripts/build-source-alpha-acceptance.sh --permission-allowed
```

Open one generated bundle with `open -n -a <exact-bundle-path> --args --workspace <new-temporary-workspace>`, then click Request isolated permission. The second bundle is named **LyricMate Permission Check 2**. Use `--expect-denied` when testing denial with that identity. System decisions remain with the user.

The dedicated IDs end in `.acceptance.permission.denied` and `.acceptance.permission.allowed`. These suffixes are test identities, not the actual user's decision. A previously used identity is not reset or prompted again; a reused-identity report does not satisfy the fresh-consent check. Permission entries for these test identities may remain in macOS; the test never deletes or changes another application's permission. This is [Apple's permission-preflight API](https://developer.apple.com/documentation/coreservices/3025784-aedeterminepermissiontoautomatet), not a request for song properties or a playback command.

## Control Readback Recovery Regression

Run `--phase recovery` with a new temporary workspace for each language (`-AppleLanguages '(en)'` or `-AppleLanguages '(zh-Hans)'`). This synthetic phase uses the production controller and serial queue, but never contacts Spotify or a live lyric service. It checks transient track changes and reply timeouts, two bounded retries, no control resend, preserved command failures, process replacement, denial, exhaustion, cancellation and manual reconnection. A successful ordinary read must not erase a genuine command error.

The control remains pending only during the existing bounded read-recovery episode. A safe recovery updates the message to say that playback following recovered and the controls reflect the latest read, not that the requested command effect has been independently proven. Process identity, deadlines, maximum attempts and the single read/control queue remain in force. Detailed local diagnostics retain the initial failed readback and record recovery separately; the share projection still excludes request identifiers and song metadata.

Local validation passed 419 unit tests and all 41 recovery assertions in each of English and Simplified Chinese. Localization validation and the ordinary optimized app build also passed. These are local results, not a new hosted-CI run.

The local 2026-10-23 real-player check also exercised this branch with an independent test application: a real concurrent track change produced `track_changed`, then the normal recovery succeeded and the native menu showed the recovered-state message. Six uninstrumented track transitions passed without reproducing the race. The targeted real check therefore used a four-second **test-only timing barrier**, plus an explicit Spotify-native next-track click. It did not inject a snapshot, failure or HTTP response. `PREVIEW_ACCEPTANCE` alone exposes that synchronization hook; it is absent from ordinary builds and unset in synthetic checks. This is controlled-concurrency evidence, not evidence of spontaneous race frequency, audible alignment or long-term stability. Private observations, playback history and local configuration are not included here. This revision has not been pushed and does not claim a new hosted-CI result or installer release.

## Remaining Release Gates

- The baseline main PR and CI passed; every closeout revision must pass its own PR and hosted CI before merge. Inspect the exact commit in [Source checks](https://github.com/FelixHuoEZ/LyricMate/actions/workflows/source-checks.yml). Local native runs do not prove CI has executed a workflow or dependency pin.
- External-account private vulnerability reporting remains deferred; a maintainer advisory form is not an external reporter's form.
- Intel, older macOS, actual fresh installation/upgrade/uninstallation, Developer ID signing, notarization and Gatekeeper remain separate distribution gates. No installer is released.
- Live catalog availability, recording identity, audible synchronization and long-term stability are not inferred from synthetic results.
