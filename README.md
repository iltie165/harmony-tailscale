# harmony-tailscale

非官方的 HarmonyOS ARM64 Tailscale 客户端，基于官方 Go 核心、ArkUI 与
系统 VPN 扩展。与 Tailscale Inc.、华为无隶属或官方背书关系。

**当前版本：3.4.1 · Alpha**。源码、测试和目标构建已有验证；3.4.1 的首次
系统授权、界面及网络切换效果仍待真机验收。现有签名包是设备受限的调试包，
不是可供所有手机安装的正式发行版。详见 [发布状态](docs/release-readiness.md)。

## 功能与边界

- 官方浏览器登录、账号恢复、在线设备查询、名称/用户/标签筛选及设备详情。
- 显式开启 VPN 后使用系统扩展，将其他应用的 Tailnet IPv4 流量交给官方
  WireGuard 引擎；不添加默认路由，也不覆盖系统 DNS。
- 登录不请求 VPN 授权；正常 ON/OFF 保留账号和健康核心，开关反映实际接口状态。
- IPv4 TCP/UDP 与有限的本地 ICMP 应答；日志与诊断对认证 URL 做脱敏。
- **未支持**：MagicDNS、IPv6、出口节点、子网路由、开机自启/保证常驻、SSH
  服务端、Taildrive、策略组管理。后台/锁屏行为不承诺稳定。

历史真机反馈包含 3.0.6 登录/设备查询与 3.2.0 Moonlight 使用；不能把这些
证据当作 3.4.1 已完成真机验证。

## 快速开始

面向 Linux x86-64 开发环境。需要预先准备专用工具链镜像和模块缓存；
**新 clone 不会自动安装 SDK 或下载依赖**。准备步骤和当前复现缺项见
[构建指南](docs/building.md)。

```bash
git clone https://github.com/iltie165/harmony-tailscale.git
cd harmony-tailscale
make lint       # 文档链接、目录、脚本语法及源文件规范；无需 SDK
make doctor     # 只读检查本机工具链/镜像/缓存
make test       # 离线 Go race/vet、C ABI/NAPI 与 UI 回归
make check      # 上述检查 + ARM64/ArkTS 编译及 HAP 内容核对
```

构建产物在 `dist/`；`make build` 输出未签名 HAP。签名与设备安装是独立步骤，
参见 [设备验收](docs/device-test.md)。不要把私钥、配置凭据或调试包提交到 Git。

## 工程布局

```text
.
├── AppScope/                  # HarmonyOS 应用身份、版本和全局资源
├── entry/                     # 标准 Stage 模块（保留 SDK 约定）
│   └── src/main/
│       ├── ets/entryability/  # 应用/窗口生命周期
│       ├── ets/pages/         # ArkUI 页面、共享控制器和账号视图模型
│       ├── ets/vpn/           # 服务 actor、私有 IPC、VPN/恢复状态机
│       ├── cpp/               # 异步 NAPI 桥接与 FD 所有权
│       └── resources/         # 图标、字符串和页面声明
├── core/                      # Go C ABI、官方核心适配、账号/包转发逻辑
├── tests/                     # 跨语言/平台边界回归；Go 测试与源码同目录
├── scripts/                   # 检查、构建、签名和设备工具
├── docs/                      # 当前维护指南与统一索引
│   ├── releases/              # 历史版本说明和对应验收边界
│   └── archive/               # 历史设计、审查与实验记录
├── third_party/               # 上游许可证/专利授权原文，不含 SDK/依赖源码
├── patches/                   # 有依据的上游补丁记录（当前无补丁）
└── .github/                   # CI、Issue 表单与 PR 模板
```

Go `core/` 是 `c-shared` 的 main 包，不为目录美观拆成重复状态所有者；
`entry/`、`AppScope/`、Hvigor 配置和 bundle identity 保持现有兼容性。
缓存、编译输出、测试证据和设备日志不属于源码目录。

## 文档与参与

- [文档导航](docs/README.md) · [架构与契约](docs/architecture.md)
- [贡献指南](CONTRIBUTING.md) · [测试边界](docs/testing.md)
- [更新记录](CHANGELOG.md) · [后续计划](docs/roadmap.md)
- [问题与支持](SUPPORT.md) · [安全报告](SECURITY.md)
- [第三方说明](THIRD_PARTY.md) · [开源准备审查](docs/project-readiness.md)

## 许可证

本项目自有代码与文档采用 [MIT License](LICENSE)。使用及再分发时请保留
版权和许可声明。

第三方代码、SDK 和素材不因本项目采用 MIT 而改变原有许可。上游 Tailscale
的 BSD-3-Clause 与附加专利授权原文在 `third_party/tailscale/`；图标再分发
授权仍待确认。详见 [第三方说明](THIRD_PARTY.md)。
