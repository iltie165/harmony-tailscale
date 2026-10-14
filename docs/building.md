# 构建指南

## 支持的开发环境

Linux x86-64 主机，Bash、Git、Make、Python 3、Docker Engine。签名还需要
主机 `openssl`、`jq`。目前未验证 macOS/Windows 原生构建或标准 DevEco GUI
直接构建；手机运行目标为 HarmonyOS ARM64，最低 API 24、目标/编译 API 26。

| 输入 | 当前要求 |
| --- | --- |
| 上游模块 | `tailscale.com v1.86.2`，commit `d72494bac7a2fb6b6a01715cfc5bcc903dbd7594` |
| Go | go.mod 最低 1.24.4；当前镜像为 OpenHarmony Go 1.24.5 |
| Go 镜像 | `harmonyos-go:1.24`；必须同时支持 linux/amd64 CGO 与 openharmony/arm64 CGO |
| SDK 镜像 | `harmonyos-dev:24.04`；Huawei Command Line Tools/SDK API 26、Hvigor 6.26.8、配套 Node/TypeScript |
| 模块缓存 | `.cache/gomod` 或绝对路径 `HARMONY_GOMODCACHE`，匹配 go.mod/go.sum |

普通 upstream Go 不包含本项目所需的 `GOOS=openharmony`；不能直接替代已验证的
工具链。镜像名称是本地标签，不是已公开的镜像仓库地址。

## 新贡献者准备步骤

1. 从华为官方渠道取得 API 26 Linux Command Line Tools，遵守 SDK 使用条款。
2. 准备上述两个工具链镜像。内部路径必须匹配脚本约定：
   `/opt/harmony/command-line-tools/{sdk,tool/node,hvigor,codelinter}`。
3. 在经授权的联网准备阶段填充固定版本 Go 模块缓存，保留校验和；准备好
   Hvigor/OHPM 元数据。不要把下载步骤隐式放入测试或离线构建。
4. 运行 `make doctor`，再运行 `make test` / `make check`。

**目前缺项**：经验证、可公开分发的 Dockerfile/镜像 digest、OpenHarmony Go
源码来源/commit、官方 SDK 下载标识与校验和，以及可复跑的缓存准备命令尚未
随项目提供。现有本地环境能构建，不等于新贡献者可从空机器完整复现。
不要用未经验证的镜像配方填补这个结论。跟踪见 [准备审查](project-readiness.md)。

## 命令入口

```bash
make lint       # 只读源码/文档检查，无需 Docker/SDK
make doctor     # 检查已存在的镜像、模块缓存和工具，不下载
make test-ui    # 生产 ArkTS 逻辑 + mocked 平台端口；不渲染 ArkUI
make test       # 全部宿主回归、覆盖率门槛和真实 ABI/NAPI
make build      # Go ARM64 库 + 未签名 debug HAP + 内容校验
make check      # 发布/行为变更完整门槛：test + build
make verify-hap # 核对已存在的 HAP 原生内容
```

输出：`dist/libtailscale_ohos.{so,h}`、
`dist/hap/tailscale-probe-unsigned.hap` 与 `dist/tests/`。
脚本仍保留历史 `probe` 文件名，避免破坏工具、下载入口和升级流程。
`make build` 当前明确使用 debug；不能称作 release-mode 构建。

## 配置

脚本接收环境变量，不自动读取 `.env`，无需新建配置文件。变量只影响本次
命令；不得将私钥或密码写入仓库。

| 变量 | 用途/默认 |
| --- | --- |
| `HARMONY_GO_IMAGE` | Go 镜像，默认 `harmonyos-go:1.24` |
| `HARMONY_DEV_IMAGE` | SDK 镜像，默认 `harmonyos-dev:24.04` |
| `HARMONY_GOMODCACHE` | 预填充缓存绝对路径，默认项目 `.cache/gomod` |
| `HARMONY_BUILD_NETWORK` | HAP 构建网络，默认 `none`；只在明确准备环境时改动 |
| `HARMONY_PROXY_URL` / `HARMONY_ALL_PROXY_URL` | 显式联网准备阶段的代理；离线模式不依赖代理 |
| `HARMONY_SIGNING_DIR` | 私有签名目录，默认 `$HOME/harmony-signing` |
| `HARMONY_KEYSTORE_FILE` / `HARMONY_APP_CERT_FILE` / `HARMONY_PROFILE_FILE` | 分别覆盖私有 P12、证书链、授权 profile 路径 |
| `HARMONY_KEYSTORE_PASSWORD` / `HARMONY_KEY_PASSWORD` | 临时签名密码；仅签名使用 |
| `HARMONY_KEY_ALIAS` / `HARMONY_COMPATIBLE_API` | 可选密钥 alias；签名兼容 API 默认 24 |

已跟踪的 `local.properties` 只包含容器内统一的 `sdk.dir=/tmp/ohos-sdk`，
并非维护者机器路径。build-hap 在容器中建立该 SDK 软链接。

## CI

- `source.yml`：GitHub-hosted Ubuntu 上运行 `make lint`，可处理 fork PR。
- `check.yml`：可信 self-hosted runner 上运行 `make check`。只有设置仓库变量
  `HARMONY_CI_ENABLED=true` 后才启用；不运行外部 fork PR 的代码。
- 全量 runner 还需要 `harmonyos` 标签、固定镜像、预填充只读模块缓存
  （默认 `/opt/harmony-ci/gomod`，可用 `HARMONY_CI_MODULE_CACHE` 覆盖）。

这些 workflow 是配置，不表示已部署 runner 或已有远程成功记录。
签名、设备安装、GitHub Release 发布不由 PR CI 自动执行。
