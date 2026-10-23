# Dependency Security Maintenance

Dependency alerts, version-update proposals and tested upgrades are separate controls. None is a guarantee that all dependencies are vulnerability-free.

## Current Scope

- `Package.swift` declares local targets, not remote Swift packages. Do not add a fictitious Swift dependency update job merely to make the configuration look complete.
- `.github/dependabot.yml` requests monthly GitHub Actions update PRs, with at most three open proposals. It becomes active only after it reaches the default branch; a local file does not prove a hosted run.
- Changes still require the protected PR path and passing `source` / `secrets` checks. Automatic merging remains disabled. Do not replace commit pins with floating version tags.
- On 2026-10-23 the repository vulnerability-alert switch was enabled and read back successfully. The open-alert query returned an empty list at that time; this is not a complete dependency audit or a future-health claim.
- The closeout workflow pins `actions/checkout` v7.0.1 to `3d3c42e5aac5ba805825da76410c181273ba90b1`. The official tag and verified commit were checked, along with Node 24 / runner requirements and the safer fork-PR default. The workflow keeps `persist-credentials: false` and never opts into unsafe PR checkout. This and every later upgrade require their own hosted PR checks before merge; an earlier main CI result does not cover a new pin.

GitHub documents [Actions version updates](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/auto-update-actions) and [Dependabot alert limitations](https://docs.github.com/en/code-security/concepts/supply-chain-security/dependabot-alerts). Commit-SHA-pinned Actions require separate review rather than assuming vulnerability alerts cover every pin.
The reviewed update is documented in the official [v7.0.1 release](https://github.com/actions/checkout/releases/tag/v7.0.1) and [runtime requirements](https://github.com/actions/checkout/blob/v7.0.1/README.md).

## Upgrade Checklist

| Component | Update Evidence And Required Checks |
| --- | --- |
| `actions/checkout` | Review the official release, runtime requirements and exact tagged commit; retain `persist-credentials: false`, full history and read-only job permissions. Update the reviewed pin in the workflow and release guard together, then run guard mutation tests and hosted CI. |
| Gitleaks | Review the official release and publisher checksums. Update the version, archive checksum and release-guard checksum together. Re-scan the proposed tree/history without uploading the report. Dependabot's Actions configuration does not update this shell download. |
| Xcode / Swift / macOS runner | Check the official SDK and runner release notes; compile both production and acceptance entry points and run strict offline tests. An SDK upgrade does not prove older systems or Intel compatibility. |
| Vendored lyric parser | Review upstream changes manually and retain the parser license and attribution. Do not silently treat copied source as a package-manager dependency. |
| New remote packages | Before adding one, review provenance and license, lock its resolved version, identify supported dependency-graph coverage, and update this inventory. |

Do not enable automatic merges, weaken branch checks, upload private scanner findings, or change the installed application's configuration as part of routine dependency maintenance.
