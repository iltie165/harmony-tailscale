# Support

本项目是社区 Alpha，不提供稳定性承诺或商业 SLA；非官方 Tailscale/Huawei
支持渠道。先查 [功能范围](README.md) 和 [设备验收](docs/device-test.md)。

## 提交问题

使用 [GitHub Issues](https://github.com/iltie165/harmony-tailscale/issues) 中的
Bug report 或 Feature request。提供版本、HarmonyOS API/系统版本、设备型号、
复现步骤、预期与实际行为。构建问题请附 `make doctor` 和失败命令输出。

提供最小化且脱敏的诊断；不要上传完整 app-private state、登录链接、私钥、
签名密码、profile、Token 或账号邮件。设备名、Tailnet 名称与 IP 也应按需遮盖。
疑似凭据泄漏或安全漏洞请使用 [安全报告流程](SECURITY.md)，不要公开细节。

## 数据与隐私

登录使用官方控制平面；账号/节点密钥保存在应用私有 `filesDir/tailscale`。
关闭 VPN 保留登录和健康核心；卸载通常会丢失该私有状态。
本项目不是自托管控制平面，也不能替代上游服务的隐私政策。

诊断涉及日志、设备/接口信息、网络连通性探测；调用上游核心可能产生上游
日志/控制平面通信。认证 URL 脱敏不等于所有身份元数据都已脱敏。
公开发行前仍需核验完整的数据流和日志上传行为，见 [路线图](docs/roadmap.md)。
