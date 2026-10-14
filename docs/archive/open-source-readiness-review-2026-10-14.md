# 版本规范化后的开源准备复查 — 2026-10-14

> 后续版本更新回滚和签名交付保护已修复，首发用户功能已补齐。见
> [首发候选验证](first-alpha-candidate-2026-10-14.md)。下文是当时审查快照。

审查基线：`e580aaf0c05204f93c0d039fbcc1bebc4f1a1a1b`，开发目标
`0.1.0-alpha.1 / versionCode 3004002`。本次是结构/发布流程复查，
不是 VPN 业务逻辑的完整安全审计；没有新增真机证据。

## 已核实状态

- 版本规范化已同步到 GitHub main；353 项宿主/版本用例和真实目标构建通过。
- 实际未签名 HAP 为 0.1.0-alpha.1/3004002；旧 3.4.1 签名包仍保留原样。
- [基础 CI](https://github.com/iltie165/harmony-tailscale/actions/runs/38501955041)
  在 e580aaf 上成功，不再只是未运行的配置。
- [全量 CI](https://github.com/iltie165/harmony-tailscale/actions/runs/38501955103)
  状态为 skipped；启用/部署可信 runner 仍待处理。
- GitHub branches API 返回 main `protected: false`；releases API 当前返回空列表。
  没有因为提交版本规范而生成正式发行或 tag。

## 仍需修改/补齐

| 优先级 | 事项 | 证据与建议 |
| --- | --- | --- |
| P1 | 签名产物防覆盖/失败交付 | [sign-hap.sh](../../scripts/sign-hap.sh) 直接把最终目标路径交给 sign-app，缺少已存在目标拒绝；验签/内容检查在其后。应先写临时包、全部核验通过后再以不覆盖方式交付，失败不留下看似有效的新发行文件 |
| P2 | 版本更新的写盘失败回滚 | [version.py](../../scripts/version.py) 顺序 write_text 四个文件；第二处 I/O 失败时第一处已改变。应暂存后更新、对可捕获失败回滚，并补回归；进程崩溃仍需一致性门槛，不能声称多文件完全原子 |
| P1 | 新机器构建复现 | 现有镜像标签不是公开可下载镜像；缺固定 OpenHarmony Go source/commit、SDK 标识/校验和、镜像配方/digest 和缓存准备命令。完成后以干净环境验收 |
| P1 | 正式构建/分发 | [build-hap.sh](../../scripts/build-hap.sh) 固定 debug；现有签名是设备受限 profile。需要明确 release-mode 路径、合法公众安装渠道、manifest/校验和和升级验收；不直接替换现有 bundle |
| P1 | 当前版本真机验收 | 新版本尚未签名/安装；必须验证旧包覆盖升级保留身份、首次允许/拒绝/取消、暖态 ON/OFF、实际流量、网络切换与后台/界面 |
| P1 | 素材与第三方声明 | 自有代码 MIT 已落实，但用户 PNG/SVG 来源与再分发许可、实际链接依赖/Go/原生运行库 notices/SBOM 未完成；不能由 MIT 推定已解决 |
| P2 | 全量 CI 与分支规则 | 全量 CI 实际跳过、main 未保护。需要可信 runner、实际成功记录及合适的 PR/checks 规则；避免把外部 fork 放进可信 runner。仅审查，未修改仓库设置 |
| P2 | 用户可见开源说明 | 设置页目前只显示产品名、应用/核心版本与 Alpha 限制；缺社区非官方说明、源码/反馈入口及许可证/第三方声明。应集中放“关于”，不在登录或 VPN 授权流程堆工程细节 |

后续可补支持 FAQ、隐私数据流、截图/大字号/辅助技术证据；模块拆分放在有
行为回归保护的独立变更中，不用目录搬动替代功能稳定性工作。

## 本机复现与边界

在临时测试工程中调用生产 set_version，注入根 oh-package.json5 写盘 OSError：
AppScope 已变成 alpha.2，但 VERSION 仍是 alpha.1，确定存在部分更新。
随后生产 check 明确拒绝该漂移，说明当前构建门槛仍会 fail closed，
不应把这个工具问题描述成现有手机 VPN 卡死。临时工程已清理，真实源码未改坏。

签名问题由已阅读的文件写入/验签顺序确定为缺失保护，没有为证明它而重签或
覆盖真实安装包。本次新增审查不宣称这些修复已完成，也不宣称手机验收通过。
