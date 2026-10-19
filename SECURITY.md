# Security Policy

Maintainer: [FelixHuoEZ](https://github.com/FelixHuoEZ). Development credit:
FelixHuoEZ and codex. The source Alpha has no guaranteed security support period
or response SLA.

## Private Vulnerability Reports

For a public repository with private vulnerability reporting enabled, use
[Report a vulnerability](https://github.com/FelixHuoEZ/LyricMate/security/advisories/new).
Check that GitHub actually offers a private report before entering details.
GitHub only offers this feature on public repositories. A link in this document
does not claim the channel is enabled or usable: verify the live GitHub form.
Maintainers must enable and read back the setting when publishing the repository,
and recheck it after visibility or security-setting changes.

If the private form is unavailable, do not publish vulnerability details. You
may open a content-free issue asking the maintainer to arrange a private channel.
Do not include an exploit, credentials, private URLs or personal data there.
No personal email address is collected or published by this policy.

In a confirmed private report, include only the affected version/commit,
synthetic reproduction, impact and relevant error category. Do not send real
tokens, cookies, complete logs, personal settings, playback histories or lyrics.
Suspected leaked credentials must be revoked by their owner; never test them
against a real account. Removing a Git file does not revoke a credential.

## Application Boundaries

- No remote JavaScript, LX/six-tone scripts, audio download or authentication bypass.
- Custom sources use constrained, credential-free HTTPS JSON manifests. Confirm
  the receiving service before enabling it.
- Kugou, NetEase, Kuwo, QQ Music and Migu adapters are unavailable in the source
  Alpha pending access and display-rights review. Old configurations remain
  stored, but the registry refuses to construct or contact these adapters.
- Playback controls require explicit clicks and revalidated Spotify identity.
  A timeout does not prove that an Apple Event was cancelled; controls are not
  automatically repeated.
- Default tests are offline, with intercepted HTTP and synthetic settings.
- Local secret scanning covers all local refs and the exact source export.
  Reports are redacted and not uploaded. A scan is not proof that no secret,
  privacy issue or license problem exists.

For each source publication, verify the actual GitHub private-reporting setting
and form, repository secret protection availability, final refs and source
archive. Installer signing/notarization remains a separate gate.

See GitHub's [reporting documentation](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/report-privately).

## 中文摘要

漏洞不要发到公开 issue。上面的 GitHub 私密报告入口只有在公开仓库且维护者启用后
才可使用；文档链接不代表入口当前可用，请核对 GitHub 实际表单。入口不可用时，只能
公开询问如何私密联系，不附漏洞细节、凭据、日志或个人数据。本项目不承诺安全响应时限。
