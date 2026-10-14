# 文档导航

## 当前维护指南

| 文档 | 用途 |
| --- | --- |
| [构建指南](building.md) | 工具链、离线缓存、环境变量、构建输出 |
| [架构](architecture.md) | 状态所有权、语言边界、前台/扩展转交 |
| [测试](testing.md) | 必需检查、证据格式和真机边界 |
| [设备验收](device-test.md) | 签名、覆盖安装与当前版本验收 |
| [VPN 范围](vpn-alpha.md) | IPv4 数据路径、资源所有权与限制 |
| [版本规范](versioning.md) | 0.x/预发布、平台升级序号、标签与产物规则 |
| [发布状态](release-readiness.md) | 当前开发目标的证据与公开发布条件 |
| [路线图](roadmap.md) | 按优先级安排的后续工作 |
| [开源准备审查](project-readiness.md) | 本次结构整理及仍缺的部分 |

根目录维护 [贡献指南](../CONTRIBUTING.md)、[更新记录](../CHANGELOG.md)、
[支持](../SUPPORT.md)、[安全报告](../SECURITY.md) 与 [第三方说明](../THIRD_PARTY.md)。

## 历史资料

- [内部开发包记录](releases/README.md)：旧 2.x/3.x 编号对应实现与验收快照，
  不是本项目正式发行历史。
- [设计/审查存档](archive/README.md)：实验、设计、审查和旧构建快照；与当前指南
  冲突时，以当前源码、维护指南和新证据为准。

新增文档时，当前流程放在本目录；版本交付说明放在 `releases/`；一次性的
设计、复盘、实验放在 `archive/`。所有相对链接由 `make lint` 检查。
