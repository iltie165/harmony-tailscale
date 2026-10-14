# 版本与发布规范

本项目采用 [Semantic Versioning 2.0.0](https://semver.org/lang/zh-CN/)。
是否上架应用商店与是否稳定是两件事；版本由功能/兼容性和验证成熟度决定，
不按修复次数或内部测试包次数直接增长主版本。

## 当前基线与唯一来源

- 当前开发目标：**`0.1.0-alpha.1`**。尚未创建对应 tag 或公开 GitHub Release。
- `VERSION` 是项目语义版本唯一来源，不包含 `v` 前缀。
- `AppScope/app.json5` 的 `versionName`、根及 entry 的 `oh-package.json5`
  的 `version` 必须与 VERSION 完全一致。应用界面从系统读取 versionName。
- `AppScope/app.json5` 的 `versionCode` 是独立的平台升级序号，当前 **3004002**。
- Tailscale 上游版本 `1.86.2`、Go 工具链版本、C ABI `3`、IPC/cache schema
  版本均为独立契约，**不随本项目改号**。

原来的 `2.x` / `3.x` 只是内部探针/开发包编号，不代表本项目公开稳定版本。
历史记录和已签名包保留原编号、时间、摘要及证据，不能简单改名冒充新包。
当前源码包含旧 `3.4.1` 开发包的功能基线，但新版本需要独立验证和产物。
[旧编号记录](releases/README.md) 与新版 Changelog 明确分开。

## 语义版本递增

| 格式/阶段 | 使用条件 | 示例 |
| --- | --- | --- |
| `0.MINOR.PATCH-alpha.N` | 功能和平台行为还在验证，有明确限制 | `0.1.0-alpha.1` → `0.1.0-alpha.2` |
| `0.MINOR.PATCH-beta.N` | 已完成功能范围，重点测试可靠性/兼容性 | `0.1.0-beta.1` |
| `X.Y.Z-rc.N` | 发布候选，仅处理发布阻塞项；全部必需门槛可验收 | `0.1.0-rc.1` |
| `0.MINOR.PATCH` | 范围已验证的正式 0.x 发行，接口仍可演进 | `0.1.0` |
| `1.0.0` | 核心功能、公开兼容契约、安装/升级与维护流程稳定 | `1.0.0` |

- 同一个目标版本按 `alpha.1 < alpha.2 < beta.1 < rc.1 < 正式版` 演进，
  不按字符串排序；进入新功能周期可使用 `0.2.0-alpha.1`。
- 0.x 阶段：新增功能或破坏性契约变更提升 MINOR，兼容修复提升 PATCH。
  稳定 1.x 以后：破坏性变更 MAJOR、兼容新增 MINOR、兼容修复 PATCH。
- 上游依赖更新本身不要求主版本递增；根据对项目公开契约和用户行为的影响判断。
- 允许的预发布渠道为 `alpha`、`beta`、`rc`，编号从 1 开始，无前导零。
- 规范源码版本不使用 `+build` 后缀；未发布 main 快照通过 commit SHA 区分。
  SemVer 本身允许 build metadata，这是本项目的版本管理约定。
- 合并一次提交不等于发布一次版本。维护 VERSION 表示当前开发目标，只有
  对应 tag 与发布记录产生后才能称为该版本已发行。

## HarmonyOS 升级序号

`versionCode` **不得根据 X.Y.Z 重新计算或归零**。旧开发包最高已使用 3004001；
因此这次显示版本虽规范为 0.1.0-alpha.1，升级序号取 3004002，且保留原
`com.ezoo.tailscaleprobe` 和签名身份。版本显示降低不代表平台升级序号降低。
覆盖升级还取决于有效且兼容的签名/profile 和系统规则；这次源码修改不等于
已经通过真机覆盖安装。

后续每个不同的可安装发行/测试发行分配比此前更大的整数，建议依次 +1；
范围为 1..2147483647，本项目另外要求高于旧包升级下限 3004001。
同一源码的可复现构建不自动改号；不能把重新构建包装成新的发行。
已发布版本的源码/产物不得覆盖替换：内容变化时递增语义版本与 versionCode。
同一版本不同签名渠道只允许同源码/同升级序号、不同明确产物名，不冒充新版本。

## 日常维护命令

```bash
make version
python3 scripts/version.py check
# 示例：准备下一个 Alpha；显式指定新的平台升级序号。
python3 scripts/version.py set 0.1.0-alpha.2 --code 3004003
make lint
make check
```

`set` 同时更新 VERSION 和三处元数据，拒绝版本倒退、重复版本/升级序号、
格式不合法、超过 SDK 范围或原文件漂移。只修改本地文件，**不自动提交、打 tag、
签名或上传**。更新版本后同步 Changelog/当前指南并在 PR 中说明升级影响。

`make lint` 在无 SDK 环境验证一致性和版本管理回归。构建前校验版本，HAP
打包后再核对实际 module.json 的 versionName/versionCode/bundleName，
防止版本名看似更新、产物仍是旧包。

## 产物命名

- 未签名：`harmony-tailscale-0.1.0-alpha.1-arm64-unsigned.hap`
- 已签名：`harmony-tailscale-0.1.0-alpha.1-arm64-signed.hap`
- 规范形式：`harmony-tailscale-<VERSION>-<ARCH>-<KIND>.hap`，写入 `dist/hap/`。

`build-hap.sh` 同时保留 `tailscale-probe-unsigned.hap` 兼容入口；它只是当前
未签名构建的副本，不用于公开发行。签名默认输出版本化文件，**不覆盖**旧的
`tailscale-probe-signed.hap` 或旧 3.x 签名包。旧包不重命名为新版本。
任何公开签名渠道/配置和 release-mode 构建仍需单独验收。

## Git 标签、Changelog 与发布

- 标签为 `v<VERSION>`，例如 `v0.1.0-alpha.1` 或 `v1.0.0`；使用注释标签，
  指向实际发布源码 commit。不使用 `release-3.4.1` 这类内部编号作为新基线。
- 预发布 GitHub Release 标记 **Prerelease**；正式发行不带预发布后缀。
- Changelog 维护 Unreleased，正式决定发行时才转为带日期的版本章节，并新增
  发行说明。不要预填尚未发行的历史版本。
- 新版 tag、commit、VERSION、HAP 元数据、文件名和发布说明必须一致。
  发布后不移动 tag；错误通过新版本修复，不覆盖原文件/校验和。
- tag 与 GitHub Release 由明确的发布操作创建，不由构建/PR CI 自动产生。

发行前必需：完整 `make check`；当前平台/业务流量的真机验收；适用素材与
第三方 notice；确认安装渠道和签名有效范围；记录 commit、工具链、versionCode、
包 SHA-256、测试及平台证据。产物附校验和、依赖声明/许可和支持限制。
[发布状态](release-readiness.md) 中未完成的条件不能因改号自动视为通过。

参考手工标签命令（仅在发行条件满足、发布 commit 已确认后执行）：

```bash
git tag -a v0.1.0-alpha.1 -m "harmony-tailscale 0.1.0-alpha.1" <release-commit>
git push origin v0.1.0-alpha.1
```
