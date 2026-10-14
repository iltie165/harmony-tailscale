# 当前发布状态

更新：2026-10-14。源码开发目标 **0.1.0-alpha.1 / versionCode 3004002**。
尚未创建该版本 tag/公开 Release，未正式上架。详见 [版本规范](versioning.md)。

## 已有证据

- 维护者已选定 [MIT License](../LICENSE)，自有代码和文档许可已落实；
  第三方代码、SDK 和素材的条款独立保留。
- 功能基线来自旧内部包 3.4.1，已记录 345 项回归、ARM64/ArkTS/HAP 构建与签名验签；
  改号不能将旧包当作 0.1.0-alpha.1，当前版本需独立验证。
  [交付记录](releases/ui-3.4.1.md) 区分宿主、编译与手机证据。
- 3.0.6 的真实登录/设备查询与 3.2.0 的 Moonlight 使用有用户反馈。
- 新版 `make check` 的 353 项回归与目标构建已通过；未签名 HAP 实际为
  0.1.0-alpha.1/3004002，尚未签名或安装。见 [迁移验证](archive/version-normalization-2026-10-14.md)。
- 保留 `com.ezoo.tailscaleprobe` 的 bundle identity 与 versionCode 递增，避免已有
  安装、私有账号状态和签名升级链被目录整理破坏。
- 已有签名包是授权设备的 debug HAP，不是公共发行版。
- e580aaf 的 [远程基础 CI](https://github.com/iltie165/harmony-tailscale/actions/runs/38501955041)
  已成功；全量 HarmonyOS CI 被跳过，可信 runner 的部署/执行仍未验证。

## 首发候选功能补齐

离线帮助/关于/开源声明、IPv4 复制和反馈摘要已实现；版本更新失败回滚与
签名交付保护已补齐；真实 release-mode 与包内许可资源核对已验证。
最终完整 release-check 369 项回归通过，当前未签名 HAP 的 app.debug=false。
新增功能与两处工具保护的证据见 [候选验证](archive/first-alpha-candidate-2026-10-14.md)。
当前实际功能范围及仍待确认的首发条件见 [首发说明](first-release.md)。

## 公开发布前的门槛

| 优先级 | 工作 | 完成条件 |
| --- | --- | --- |
| P0 | 第三方及素材授权 | 链接依赖/运行时 notice 审查；图标来源/再分发许可明确 |
| P0 | 当前预发布真机验收 | 首次允许/拒绝/取消、暖态 ON/OFF、网络切换与业务流量证据 |
| P0 | 公共安装/升级渠道 | 非设备受限的合法签名方式、支持设备、安装/升级/卸载说明 |
| P1 | 新机器复现 | SDK/Go 来源和固定版本、公开镜像配方/digest、缓存准备流程 |
| P1 | 正式 release 流程 | 验证 release-mode 构建、版本 tag、源 commit、校验和与 notices/SBOM |
| P1 | 维护配置 | 启用并验证 CI runner、分支规则、私密安全报告渠道 |
| P1 | 隐私/可访问性 | 核验上游日志和数据流；真机屏幕、对比度、字号、辅助技术验收 |

[开源准备审查](project-readiness.md) 记录本次结构改动；
[路线图](roadmap.md) 记录后续顺序。旧的 3.2.0 发布分析保存在
[历史报告](archive/release-readiness-2026-10-10.md)，不作为当前状态。

后续具体工程问题见 [版本规范化后复查](archive/open-source-readiness-review-2026-10-14.md)。
