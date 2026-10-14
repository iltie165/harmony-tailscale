# 首个可发布 Alpha 的功能范围与验收

目标为 **0.1.0-alpha.1**：GitHub 开源预发布，不是 1.0 稳定版，也不是已经
上架或保证所有设备可安装的公共签名包。源码目标尚未发行，当前准备的是候选。

## 必需的用户闭环

| 流程 | 当前实现/首发要求 |
| --- | --- |
| 首次启动/登录 | 官方浏览器认证；返回后检查结果，审批与普通认证分开；登录不触发 VPN |
| 开启/关闭 VPN | 显式 ON 处理系统允许/拒绝/取消；暖态 OFF 保留账号与健康核心；错误清理可重试 |
| 使用设备 | 在线列表、标签/用户/名称筛选、详情、明确陈旧数据；新增本机/设备 IPv4 一键复制 |
| 首次使用与失败排障 | 新增离线使用帮助：服务端口/ACL、防火墙、IP 而非 MagicDNS、切网/后台和升级说明 |
| 关于与开源 | 新增社区非官方说明、源码/发行/反馈/上游隐私政策入口、离线完整许可文本分页查看 |
| 问题反馈 | 新增只含版本、系统与状态的摘要快照；先预览再显式复制，不自动上传、不含身份/IP/原始日志 |
| 发行工具 | 版本更新失败回滚；签名临时包核验后原子交付且拒绝覆盖；真实 release-mode 与版本/许可内容核对 |

首发不追加 MagicDNS、IPv6、出口节点、子网路由、Taildrive/SSH、开机常驻或
自定义控制服务器。每项后续能力都需要独立设计、错误处理和实际平台验收。

## 已完成的工程补齐

- 应用/包元数据统一为 0.1.0-alpha.1/3004002；bundle/节点状态身份不变。
- `make release-check` 使用原有离线工具链完成宿主回归和真实 release-mode HAP。
  实际 module.json 必须 `app.debug=false`，且本地许可资源与源声明字节一致。
- 已收集当前实际链接的 **57 个 Go 模块**所附 license/notice/专利/作者文本，
  保留 Go 与 SDK LLVM supplied notices。清单和摘要在
  [linked-modules.json](../third_party/linked-modules.json)，合并原文在
  [THIRD_PARTY_NOTICES.txt](../THIRD_PARTY_NOTICES.txt)。这不是全范围人工法律审查。
- 反馈摘要是白名单，不打包当前原始诊断 output；后台变化不会悄悄替换已预览
  的快照，只有明确刷新才更新。复制失败/页面离开有相应处理。
- 签名工具模拟回归验证：已有产物不覆盖、失败不交付、并发创建目标不被覆盖、
  通过核对的完整字节才交付。模拟结果不代表签名或手机运行证据。

## 候选包与记录

未签名包：`dist/hap/harmony-tailscale-0.1.0-alpha.1-arm64-unsigned.hap`。

```bash
make release-check
python3 scripts/release-manifest.py dist/hap/harmony-tailscale-0.1.0-alpha.1-arm64-unsigned.hap
```

第二条生成 SHA-256 与候选 manifest，记录源 commit/工作树摘要、实际版本和
release mode，并明确 `signed=false` / `phoneVerified=false`；它不发布到网络。
`.sha256` 只能证明文件一致性，不能替代验签或真机证据。源码有未提交改动时
manifest 会记录 sourceDirty=true；最终发布应基于干净、冻结的发布 commit。

## 首发前尚待完成（不以测试代替）

1. **素材再分发授权**：现有 PNG/SVG 来源/权限尚待维护者答复，不能由 MIT
   自动推定。若有未获许可素材，应替换后重新构建，不公开有疑问的二进制。
2. **签名与安装范围**：现有 profile 是设备受限调试授权；需明确是受限测试
   包还是可公开安装渠道。release-mode 编译不使 debug profile 变成公共签名。
3. **实际设备验收**：当前没有检测到可用本地 HDC 会话，未安装本候选。按
   [验收指南](device-test.md) 记录覆盖升级、账号/IP连续性、授权允许/拒绝/取消、
   真正 TCP/UDP 业务流量、暖态开关、切网/锁屏、关于/许可/剪贴板和反馈流程。
4. **干净环境复现与维护**：固定工具链来源、镜像/SDK摘要及缓存准备流程；
   部署可信全量 CI 并核实分支/安全报告设置。当前基础 CI 与本地完整 gate 是
   已有证据，不是已部署全量 runner。

全部必需条件确认后，才冻结 Changelog、创建 `v0.1.0-alpha.1` tag 和标记
Prerelease 的 GitHub Release，附合适产物/安装范围、校验和、许可、验收证据。
当前没有自动创建 tag/Release，没有把旧 3.4.1 签名包改名冒充新版本。
