# 未交付交互修改审查 — 2026-10-12

> 后续状态：用户已授权修复，以下六项已完成源码修改；修复说明及最终
> 回归结果见 [修复记录](interaction-review-fixes-2026-10-12.md)。下文保留
> 审查时的缺陷与复现事实，不代表当前源码仍具有这些缺陷。后续恢复授权后，
> 已完成 [3.4.1 打包交付](../releases/ui-3.4.1.md)，真机尚待验收。

## 范围与结论

审查工作树内拟交付 3.4.1 的修改，以及与之直接相连的 3.4.0
生命周期代码。用户要求暂停构建仍有效。本轮没有修改业务源码、
安装依赖、运行本机/目标原生构建、打包或签名，也没有推送。

**建议修复以下问题后再进入目标验证与交付。** 前两项是启动/资源
缺陷，第三项是新精细化视图更新下的漏通知风险。后三项影响状态文案和查询交互。

## 发现与需要的改动

### 1. P1 — 授权宿主确认后，晚到的 SDK 错误仍可中断转交

位置：`entry/src/main/ets/vpn/NetworkServiceClient.ets:149`。

`initialize` 接受新 owner 的 `handoff_wait` 后释放账号核心、发送转交命令，
但循环下一轮仍无条件优先抛出 `sdkError`。新核心正常启动期间，晚到的
SDK Promise rejection 会结束本次连接；上层随即撤销开启意图。
现有“晚到 rejection”回归只在整个 `ensure` **已成功返回**之后拒绝 SDK，
没有覆盖转交已经完成而新宿主仍在 booting 的窗口。

需要：按 owner/意图代次协调启动回执与宿主确认。有效的授权宿主确认后，
不能仅凭迟到的启动回执推翻连接；继续验证对应 actor/核心/系统资源的实际状态。
真实授权撤销或宿主失败仍必须关闭并报告。补充“转交中拒绝回执”回归。

### 2. P1 — 核心启动后的监听失败没有回滚，报告却声称已经停止

位置：`entry/src/main/ets/vpn/NetworkServicePlatform.ets:29`；
`entry/src/main/ets/vpn/NetworkServiceModel.ets:209`、`:270`。

平台 `boot()` 先成功调用 `startService`，再注册网络监听。
监听注册拒绝/超时使 `boot()` 抛错，actor 尚未设置 `coreTouched`，
finally 不调用 `closeCore`，却把 `coreAlive` 写成 false 并发布 stopped。
真实核心与状态锁仍在，后续账号恢复/重试会受到影响。

需要：把平台启动变成有所有权证明的事务；成功获得本次核心后，
监听及后续初始化失败必须回滚本次核心与监听。不要简单在 boot 前设置
coreTouched，否则会重新引入“启动被租约拒绝却关闭前台账号核心”的问题。
真实清理失败必须保持待确认状态，而不是报告 stopped。

### 3. P1 — 原地改 VPN 字段绕过精细化响应式更新

位置：`entry/src/main/ets/pages/ClientController.ets:732`；
视图 `@Track vpn`、`ClientView.apply`；`Index.ets` 的 Toggle 读取 `view.vpn.connected`。

恢复报告为 blocked/retry_wait 时，代码直接执行 `this.vpn.connected=false`。
控制器和视图此前共享同一个未声明为 @Observed 的 VpnState 对象，
apply 比较引用相同而不赋值 `@Track vpn`。审查用 setter 证明此路径没有
VPN 属性赋值通知；其他 label 属性更新不能替代 Toggle 自身的观察依赖。
Node 测试将 @Observed/@Track 替换为空实现，不能证明 ArkUI 真实显示已更新。

需要：发布不可变 VPN 快照，或把 Toggle 使用的 connected 等字段投影为
独立被跟踪的基础类型；避免共享对象原地修改。增加通知边界回归，
目标验证恢复中/被其他 VPN 阻断后的开关、标签与包计数一致性。
此处复现的是漏属性赋值，不是实际手机画面证据。

### 4. P2 — 授权期间回前台误报恢复失败，成功后仍残留

位置：`entry/src/main/ets/pages/ClientController.ets` 的 foregroundCallback；
`recoverForeground:696`、`:706`；`AccountSessionPlatform.ensure`。

VPN 转交期间 `transferring=true`，前台事件仍触发账号恢复；ensure 的正常
“正在转交”保护被转成全局“网络服务恢复失败”。之后同一核心恢复成功不会
清除这条 message，导致正常首页持续显示错误。系统授权是否恰好触发该
前台事件要真机确认，但这组生产代码时序已在宿主测试中复现。

需要：转交期间合并/延后前台恢复，不把互斥中的正常等待视为故障；
账号恢复消息应有独立归属与阶段，在对应操作成功时清除，保留不相关诊断。

### 5. P2 — 筛选提交遇到正在同步，会被直接丢弃

位置：`entry/src/main/ets/pages/ClientController.ets:500`；
loadData 的 filter 一致性检查；`Index.ets:217`。

后台同步进行中提交新筛选，refreshData 因 refreshTask 已存在直接返回。
旧响应随后因为 filter 不符被丢弃，但新筛选没有立即补查；旧列表仍显示
为当前在线结果，直到下一次约五秒的定时查询。筛选框与当前列表实际查询条件不一致。

需要：记录待处理的最新查询条件/查询 revision；single-flight 完成后立即
补查最新筛选，或取消旧查询再查询。等待时保留旧列表但明确它还不是新筛选结果。
不恢复全屏加载，也不重新创建行或核心。

### 6. P2 — 管理员批准超时后提示重新浏览器登录

位置：`entry/src/main/ets/pages/ClientController.ets:311`；欢迎页登录按钮条件。

NeedsMachineAuth 使用同一个 awaitingLogin 超时分支，期限到后原有
“需要管理员批准”被替换成“尚未确认认证完成…重新打开登录页面”。
awaitingLogin 又被置 false，按钮回到“登录 Tailscale”，而不是检查批准结果。
浏览器认证超时也存在消息说“可继续检查”，按钮却只提供重新登录的操作不匹配。

需要：浏览器认证、管理员批准分别维护阶段与消息；超时只是停止快速轮询，
不能丢失待确认阶段。保留明确的“检查登录结果”/“检查授权状态”按钮，
另提供重新登录，不把审批等待当成账号认证失败。

## 另外需要整理的两项

- **时间语义**：当前静默取得相同数据不会更新 lastUpdated，所以“更新于”
  已不严格代表最近成功同步时间。分开 lastSuccessfulSyncAt 与 lastContentChangedAt；
  文案与实际时间对应。成功同步可仅更新独立时间 Text，不插入 loading 行、
  不替换整棵页面或设备行。若显示数据变更时间，明确称“数据变更于”。
- **测试层级**：保留已有 188 项；把本次错误时序转为正式修复回归。
  Node 空装饰器/TypeScript transpile 不等于 ArkTS 编译和 ArkUI 响应式运行。
  用户恢复构建后才运行完整 make check；真机分别验收首次允许/拒绝/取消、
  暖态 ON/OFF、身份不变、Moonlight、后台恢复，以及滚动位置与视觉闪烁。

## 本轮验证

- `scripts/check-source.sh` 通过。
- `scripts/test-ui.sh`：188 项通过，0 失败/跳过。
- 审查专用复现：6 项均复现上述行为；其 PASS 表示成功证明问题，**不是问题已修好**。
- 证据：`dist/review-ui-2026-10-12.log`、
  `dist/review-audit-2026-10-12.cjs`、`dist/review-audit-2026-10-12.log`。
- 没有新增手机证据，也没有构建/签名新包；下载仍是旧 3.4.0。
