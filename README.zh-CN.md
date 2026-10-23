# LyricMate Alpha

<img src="LyricPreview/Resources/LyricMateIcon-1024.png" width="96" height="96" alt="LyricMate 应用图标">

[English](README.md) | 简体中文

作者：[FelixHuoEZ](https://github.com/FelixHuoEZ) and codex。

macOS 菜单栏与透明双行悬浮歌词工具，跟随已经运行的 Spotify 桌面客户端。

这是独立开发中的源码 Alpha，不是 Lyric Fever 官方发行版，也不是 Spotify 或歌词平台的官方产品。部分代码基于 [Lyric Fever](https://github.com/aviwad/LyricFever)，保留原 MIT 许可与第三方署名。目前没有官方安装包、自动更新或稳定性承诺。

## 功能

- 菜单栏歌词、透明双行浮层、智能换行、向上换句与开唱提示。
- 可选歌手搜索、仅歌名补搜、匹配评分、候选先载入后升级、人工选择与偏移重核验。
- 按 Spotify 录音记住已核验的歌词版本，每组录音与歌词版本分别保存延时；重核验后的绑定优先于评分，可用“恢复自动选择”清除绑定及该录音各版本的偏移。
- 播放／暂停、上一首／下一首与菜单中的前后跳转；浮层控件仅悬停时显示，锁定鼠标穿透时隐藏。
- 本地 LRC、设置记忆、备份与有界本机诊断。不附带歌词库或账户凭据。

匹配分不是同步准确率；临时匹配可能是错误录音。逐字演唱、重音／吸气标记不在当前范围内。

## 界面语言

界面跟随系统的应用语言偏好，支持英文和简体中文；不支持的语言回退英文。在 macOS 修改应用语言后，重新启动生效。歌词正文、歌曲资料与用户自定义来源名称保持原样，不自动翻译。

语言选择不会重命名配置键、来源 ID、数据目录或录音指纹；连接恢复、悬浮歌词设置、已添加来源及偏移继续使用原配置域。

## 构建与测试

目前构建目标仅为 Apple Silicon、macOS 15 及以上，需安装完整 Xcode 并使 `xcrun --show-sdk-path` 可用。Intel 和更早系统未验收。独立构建不依赖原版 Xcode 工程或第三方编译宏。

```sh
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
python3 scripts/check-localization.py
python3 scripts/test-public-source.py
python3 scripts/test-release-safety.py
python3 scripts/check-release-safety.py
bash scripts/build-lyric-preview.sh
bash scripts/test-lyricmate-icon.sh "dist/LyricMate Alpha.app"
python3 scripts/public-source.py check
python3 scripts/public-source.py archive
```

应用输出为 `dist/LyricMate Alpha.app`，源码归档为 `dist/LyricMate-source.tar.gz`。脚本只构建，不安装、不启动、不覆盖已有输出；再次构建前将旧输出移走。构建仅使用本机 ad-hoc 签名，不是 Developer ID、公证或 Gatekeeper 发行验收；不建议把此产物直接发给普通用户。

## 使用与权限

1. 自行启动 Spotify 和所构建的 Alpha。
2. 点击“启用只读跟随 Spotify”，自行决定是否授予 macOS 自动化权限。
3. 打开悬浮歌词或手动搜索；可以只填歌名。所有播放控制必须明确点击。

不会自行登录、读取 Spotify Cookie 或启动 Spotify；失去播放状态后停止实时高亮。初始默认来源为 LRCLIB，另支持本地 LRC、主动添加的 AMLL 和无凭据自定义 HTTPS JSON。酷狗、网易云、酷我、QQ 音乐和咪咕因接入与展示权利待核实，在源码 Alpha 中不能启用或测试；已有配置保留但不会通过这些适配器联网。实验实现及原有历史仍在，不声称代码已彻底删除或获得授权。Musixmatch 和 LyricFind 仍未接入。

LRCLIB 请求使用应用名、版本和项目链接标识；跨客户端串行调用，上次响应后至少等待 250 毫秒，并共享 Retry-After 冷却。项目链接用于标识本源码 Alpha，不表示服务方认可或内容已获授权。

应用标识为 `local.lyricmate.alpha`，配置域为 `local.lyricmate.alpha.daily.v1`，与其他版本隔离，不自动迁移其配置。内部目录／模块保留部分历史命名，以降低行为变更风险。

## 隐私、来源与维护

搜索会向所选服务发送歌名、歌手及必要候选标识；开启跟随后可能自动搜索，服务方也能获知 IP 与请求时刻。本地导入不联网。设置、歌词文件与有界诊断保存在本机。公开反馈请先用“预览脱敏诊断”：只投影步骤、状态、耗时、数字错误码及控制动作类型，不含歌曲资料、地址、进程／请求标识或绝对时间。详细诊断另行确认后才保存，仅供私密排查。两种保存都不上传。

请阅读 [隐私说明](docs/privacy.md)、[来源说明](docs/sources.md)、[安全边界](SECURITY.md)、[需求与设计](docs/requirements-and-design.md) 和 [发布检查](docs/release-checklist.md)。反馈缺陷时仅提供脱敏步骤、版本和错误类别，勿附账户令牌、个人设置、播放记录或完整歌词。

代码适用 [MIT](LICENSE) 及 [第三方声明](NOTICE.md)；歌词、歌曲、商标与服务不因代码许可证获得额外授权。公开发行与签名安装包仍需独立验收。

源码构建包含 AI 辅助生成的原创[应用图标](docs/app-icon.md)，对所持权利按[图标许可](LICENSES/LyricMate-assets-MIT.txt)授权，不保证排他版权或商标权；不附带已安装应用的截图、个人设置或播放记录。

见[贡献与反馈](CONTRIBUTING.md)。只读自动检查包含离线测试、构建和固定校验和的秘密扫描，不上传报告、不发布任何产物。发布前使用本机 Gitleaks 8.30.1 运行 `bash scripts/scan-secrets.sh`。工作流文件保存不代表 GitHub 托管运行已通过；私密漏洞渠道需在另行批准公开时启用并回读。
