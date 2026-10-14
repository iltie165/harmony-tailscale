# HarmonyOS 设备安装与验收

当前源码版本为 **3.4.1 Alpha**。已有 debug profile 可能只授权指定设备，
覆盖安装要求兼容 bundle/签名且 versionCode 不降级；不要承诺所有手机可安装。

## 签名

准备项目外的 P12、完整证书链和匹配 `com.ezoo.tailscaleprobe` 的签名 profile。
按自己的文件配置路径，不要将它们复制到仓库。脚本先验证 profile、再签名和
`verify-app`，最后核对原生 HAP 内容。

```bash
export HARMONY_SIGNING_DIR="$HOME/harmony-signing"
export HARMONY_KEYSTORE_FILE="$HARMONY_SIGNING_DIR/debug.p12"
export HARMONY_APP_CERT_FILE="$HARMONY_SIGNING_DIR/app-cert-chain.cer"
export HARMONY_PROFILE_FILE="$HARMONY_SIGNING_DIR/app-profile.p7b"
read -rsp 'P12 password: ' HARMONY_KEYSTORE_PASSWORD
echo
export HARMONY_KEYSTORE_PASSWORD
# 仅在私钥密码不同时设置 HARMONY_KEY_PASSWORD。
./scripts/sign-hap.sh dist/hap/tailscale-probe-unsigned.hap dist/hap/tailscale-probe-3.4.1-signed.hap
unset HARMONY_KEYSTORE_PASSWORD HARMONY_KEY_PASSWORD
```

这些命令是操作说明，不会被 `make check` 执行。签名成功不是设备运行证据。

## 安装与日志

开启开发者模式/USB 调试，在设备上授权主机，并用 SDK 的 `hdc list targets`
确认目标。先在 APP 关闭 VPN，保留原包供回退；覆盖安装，**不要先卸载**。

```bash
hdc install -r dist/hap/tailscale-probe-3.4.1-signed.hap
hdc shell aa start -a EntryAbility -b com.ezoo.tailscaleprobe
```

现有 `./scripts/device-test.sh <signed.hap>` 也可完成覆盖安装、启动和日志捕获，
但会使用 USB/privileged Docker，并持续运行直至 Ctrl-C；仅主动设备验收时使用。
日志在 `dist/device-logs/`，公开前再次脱敏。

## 当前版本验收清单

1. 新登录/恢复/管理员审批各自提示正确，登录不触发 VPN 系统授权。
2. 首次 ON：系统允许后连接；拒绝/取消/晚到授权不偷偷开启，重试可用。
3. 健康扩展暖态 ON/OFF 不重复启停；账号、节点身份、Tailnet IP 保持不变。
4. 从另一手机应用访问 Tailnet peer 的 TCP/UDP（例如 Moonlight）；确认普通
   Internet 不受影响。区分直连和 DERP，不把能力探针当真实流量。
5. 回到前台、断网/切网、锁屏/解锁、系统撤销权限后，界面与实际 VPN 状态一致；
   未清理完的接口保留可见错误。
6. 筛选/详情/滚动/后台同步无周期加载闪烁，最近同步时间与内容变化区分。
7. 小屏/大字号/长名字/系统安全区及辅助功能检查；保存脱敏截图与日志。

记录包 SHA-256、commit、系统/API/型号、日期、用例及结果。
[3.4.1 记录](releases/ui-3.4.1.md) 和 [VPN 边界](vpn-alpha.md) 是验收依据。
宿主 Node 测试不是 ArkUI 渲染；目标构建/验签不是手机联网结果。

早期 probe 操作与限制可查 [构建历史](archive/build-report.md)。
