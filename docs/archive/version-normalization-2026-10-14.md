# 项目版本规范化 — 2026-10-14

用户确认尚未正式发行/上架，要求将内部编号规范为开源项目版本。
迁移前源码 commit：`63ff9a08c51b3c26d42b042f507ba8d98b19cb66`。

## 变更

- 项目开发目标由内部 `3.4.1` 规范为 `0.1.0-alpha.1`，建立 VERSION 唯一来源。
- 同步 AppScope versionName 与两处包元数据（原包版本为 2.0.0）。
- versionCode 从 3004001 增至 3004002，不按语义版本重算或归零；bundle/签名
  身份不变。上游 Tailscale 1.86.2、Go、C ABI 3、IPC schema 未改号。
- 增加版本管理与一致性/HAP 元数据检查，统一版本化产物；旧签名包不覆盖。
- Changelog 改为未发行基线；旧 2.x/3.x 说明标明是内部测试记录，原证据保留。
- 规范见 [版本与发布规则](../versioning.md)，不是技能/环境变更。

## 实际验证

- `make check`：353 项用例通过（8 版本管理、110 Go、6 ctypes、11 real NAPI、
  14 mock NAPI、204 UI/服务/恢复），race/vet/覆盖率和模块完整性门槛通过。
- ARM64 ELF/TLS/导出、C++ smoke link、ArkTS、debug HAP 构建/原生内容核对通过。
- HAP module.json 实际为 `versionName: 0.1.0-alpha.1`、`versionCode: 3004002`、
  `bundleName: com.ezoo.tailscaleprobe`，不是只修改文件名。
- `make verify-hap` 的版本化默认入口通过；兼容 unsigned 副本与新包字节一致。
- 旧 3.4.1 signed HAP 保持 3.4.1/3004001；设备测试入口拒绝该旧元数据，
  在调用 HDC 前即失败，未执行手机安装。
- 版本管理回归包括渠道/数字顺序、错误格式、元数据漂移、版本/序号倒退、SDK
  范围、旧包/异 bundle 拒绝及产物名随版本更新。没有依赖安装或环境更改。

## 产物与边界

未签名产物：`dist/hap/harmony-tailscale-0.1.0-alpha.1-arm64-unsigned.hap`。
SHA-256：`06dd539b30e5e972ba807e92fec4ac6f7d1ee0d0bcef1a2a675c8650b839ecb1`。
完整本地日志：`dist/tests/version-normalization-check.log`（不提交）。

没有生成新签名包、创建版本 tag、发布 GitHub Release 或上架。
尚未完成新编号的真实覆盖安装、授权/UI/网络与后台验收；公开分发/签名及许可
门槛仍保留。源码同步到 GitHub 不代表本版本已发行。
