# Contributing

This is a source-only Alpha maintained by FelixHuoEZ with codex. No installer,
hosted lyric service or response-time guarantee is offered.

## Safe Reports

Use the bug form with the version/commit, macOS version, synthetic reproduction
steps and error category. Review every attachment yourself. Do not attach
preferences, source backups, playback histories, unredacted logs, credentials,
private URLs or complete lyrics. See [SECURITY.md](SECURITY.md) for vulnerabilities;
public issues are not a private reporting channel.

## Changes And Checks

Keep tests offline, using synthetic metadata, intercepted HTTP and isolated
temporary settings. Never use personal app settings as fixtures. Run:

```sh
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
python3 scripts/check-localization.py
python3 scripts/test-public-source.py
python3 scripts/test-release-safety.py
python3 scripts/check-release-safety.py
bash scripts/build-lyric-preview.sh
bash scripts/scan-secrets.sh
```

Secret scanning requires a locally installed Gitleaks 8.30.1, or its absolute
path in GITLEAKS_BIN. The script does not install tools or upload source.
Generated output stays outside the source allowlist. Review changes before
adding files to release-files.txt; do not add broad patterns or personal audits.

Preserve existing configuration domains, keys, stable source IDs and upstream
notices. Source publication does not authorize erasing users' saved settings.
Platform adapters blocked by the source policy must not be re-enabled without
reviewing access, display rights, terms and privacy. Custom JSON is a schema,
not a grant of rights to any service or content.

All new code is contributed under the root MIT license; provide provenance for
assets and third-party code. No lyric databases or unlicensed fixtures belong
here. Do not use pull_request_target or grant write permissions to source checks.
Changes to workflows, dependencies and allowlists need explicit review.

CI does not publish, install or launch the app. A green build is not live Spotify,
signing, notarization, trademark or content-rights acceptance.
