# Changelog

本项目版本采用 [SemVer](docs/versioning.md)，以 [VERSION](VERSION) 为唯一
来源。**目前尚未公开发行**；旧 2.x/3.x 编号只是内部开发包，保存于
[历史测试记录](docs/releases/README.md)，不作为正式发行历史。

## Unreleased — 目标 0.1.0-alpha.1

以下是首个开源预发布的开发基线，不表示已经创建 tag、发布 GitHub Release
或上架应用商店。

### Added

- 官方 Tailscale 登录、账号恢复、在线设备、名称/用户/标签筛选及设备详情。
- 基于官方 Go 核心与 HarmonyOS 系统 VPN 扩展的 Tailnet IPv4 数据路径。
- 免 VPN 授权的前台账号核心，显式 ON 才独占转交；正常 ON/OFF 保留健康核心。
- 诊断、脱敏日志与分层的宿主/目标/设备验证边界。
- MIT 许可证、贡献/构建/支持/安全指南、Issue/PR 模板及基础 CI。

### Fixed in the development baseline

- 首次系统授权的参数丢失/启动互等、迟到回执协调及启动失败清理。
- VPN 开关响应式更新、转交期间前台恢复、认证与管理员审批提示。
- 最新筛选补查、设备无闪烁同步、同步与内容变更时间分离。

### Versioning

- 将应用显示与包元数据统一为 `0.1.0-alpha.1`，不再使用内部 `3.4.1` 作产品版本。
- 独立升级序号从旧包 3004001 递增到 3004002，保留覆盖升级的身份边界。
- 新增版本管理/一致性检查和标准版本化 HAP 文件名，旧包不覆盖或改名。

### Limitations / acceptance pending

MagicDNS、IPv6、出口节点/子网和保证常驻不在当前支持范围。
首次授权、ArkUI 界面、网络切换/后台行为仍需当前版本真机验收；公开签名渠道、
第三方/素材完整声明与新机器复现仍未完成。历史 345 项回归和内部包构建记录
不是这个新版本已公开发行的证据。详见 [发布状态](docs/release-readiness.md)。
