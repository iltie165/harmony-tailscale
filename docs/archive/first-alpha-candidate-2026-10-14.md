# 首发候选补齐与验证 — 2026-10-14

目标0.1.0-alpha.1/3004002，非官方社区 Alpha。基线42ece82。
功能范围和发行草稿见 [首发范围](../first-release.md) 与
[发行说明草稿](../releases/v0.1.0-alpha.1.md)。

## 实现

本机/设备 Tailnet IPv4 复制；离线使用/排障指南；社区关于与源码/反馈/上游
隐私入口；离线完整许可文本分页；白名单反馈摘要快照，显式复制、不自动上传。
保留原登录/VPN/设备功能、节点/bundle身份，上游/ABI/协议范围不扩大。

版本更新采用预暂存+单文件原子替换，可捕获失败回滚；签名临时包验签/核对
通过后以拒绝覆盖的硬链接交付最终文件。中途失败和并发已有目标不交付/覆盖。
进程被杀仍可能中断多文件更新，一致性门槛会拒绝漂移，未声称文件系统事务。

## 验证证据

最终 make release-check：**369项通过**：110 Go、6 ctypes、11真实宿主NAPI、
14 mock NAPI、211 UI/服务/恢复、10版本管理、4签名工具模拟、3候选元数据。
Go race/vet、模块验证/覆盖率、ARM64 ELF/TLS/导出、C++ smoke link、ArkTS、
HAP内容全部通过。最终本地日志：dist/tests/first-alpha-release-check.log。

首轮目标构建发现pasteboard归属Kit错误；读取实际SDK导出后修正为
@kit.BasicServicesKit，再执行最终完整gate。纯Node回归不替代这项目标检查。

实际HAP：versionName=0.1.0-alpha.1，versionCode=3004002，app.debug=false，
bundle=com.ezoo.tailscaleprobe。包内许可资源与源notice bundle逐字节一致；
本次实际链接57个Go模块及其supplied notices有清单和摘要，不宣称完成人工法律审查。

产物：dist/hap/harmony-tailscale-0.1.0-alpha.1-arm64-unsigned.hap。
SHA256：e9d66c5877b29fc653b2ccabadf61a04ddbaf826829b1f83e78c4f8517231245

## 未完成事项

没有真实签名、手机安装或新版本流量/UI证据；当前未检测到本地可用HDC会话。
素材来源/权限与设备安排已经询问，尚未收到答复；公共签名/安装范围仍待确认。
没有创建tag、GitHub Release或上架，候选manifest明确记录unsigned和未验收。
旧3.4.1签名包未被覆盖/改名。模拟签名回归不使用实际密钥，不代表真实验签结果。
