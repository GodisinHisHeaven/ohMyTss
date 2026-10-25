# Apple 平台验证入口（当前 blocked，未声称通过）

Linux Swift Package 测试只验证真实共享领域代码，不覆盖 SwiftUI、HealthKit、SwiftData 或 iOS 编译。本文件的命令需要 macOS、合适的 Xcode/iOS SDK 和模拟器；不要降低 deployment target、修改签名/权限来绕过条件。现有 Xcode Cloud 会发布到 TestFlight，本任务不调用它。

## 构建与全部回归

在仓库根目录执行。先确认实际 scheme 与可用 destination：

```sh
xcodebuild -version
xcodebuild -list -project onMyTss/onMyTss.xcodeproj
xcodebuild -showdestinations -project onMyTss/onMyTss.xcodeproj -scheme onMyTss
xcrun simctl list devices available
```

保留 app 原有 18.6 和 test target 原有 26.1 最低系统版本，选择满足测试 target 的实际模拟器 UDID。把下例 `SIMULATOR_UDID` 替换成上一步真实列出的 ID，不照抄设备名称：

```sh
xcodebuild -project onMyTss/onMyTss.xcodeproj -scheme onMyTss \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath /tmp/ohmytss-v2-derived \
  -resultBundlePath /tmp/ohmytss-v2-regression.xcresult \
  test -enableCodeCoverage YES
```

若已有本地 Strava 私密配置，沿用现有配置；没有配置时应保持未连接并检查可用的手动/HealthKit 路径。不得提交个人健康记录、网络 token 或密钥。不要运行 Archive 或任何发布后操作。

须保留命令输出、`.xcresult` 和 destination/SDK 版本。`V2PersistenceTests` 覆盖真实 SwiftData 写入、重读、磁盘重开、组次编辑删除、零与未知、补录时刻、来源重复、显式关联、用户删除、模板复用和估计快照幂等。每项失败单独追踪，不跳过失败测试以取得绿色结果。

## 真实旧库迁移

运行以下命令会从固定基线 `fdab778b6b51181bd76c3627b765da8af5ed6eef` 提取**原版模型源文件**，用 Apple SwiftData 在临时目录生成明确标注的合成旧库，结束旧进程，再用当前生产模型打开同一个库：

```sh
bash scripts/check_v2_migration.sh
```

脚本不访问应用个人库，不删除旧库让验证通过。它验证 Workout、TSS/CTL/ATL/TSB、设置、来源标识、关系保留，以及新增字段默认值与 v2 写入。Linux 返回 `BLOCKED`/exit 2；这不是迁移通过。该检查验证真实 SwiftData 引擎的模型迁移，仍需下面的 iOS 升级路径。

iOS 升级检查：在专门测试模拟器安装基线 build，用合成活动建立历史并记下 TSS/设置；终止 app，保留其数据容器，安装同 bundle 的 v2 build，重新启动并确认旧数据、关系和新功能。禁止先卸载、重置模拟器、删数据库或用重装掩盖失败。备份测试容器后再做回退；v2 写入后的库不保证能被旧二进制读取。回退代码可 `git revert` 对应提交；数据回退须恢复升级前备份，不能清库。

## 实际交互证据表

逐项记录设备/系统、build commit、结果与截图/录屏路径。所有条目当前都需要 Apple 环境执行；下表是检查步骤，不是已通过报告。

|流程|操作与预期|
|---|---|
|首次/无权限|新测试容器启动，跳过 FTP，不授予 HealthKit 读取；进入 Today，Cardio 为未知而非 0；仍能记录体感和力量。|
|人体图与列表|前后切换，点 Front thighs；改左侧、轻度、保存；再用列表入口录右侧无明显不适。历史必须显示两个不同侧报告。开启 VoiceOver 验证区域可读可操作。|
|跳过与补录|打开体感后 Skip，历史不增加；新增昨天的观测，录入时间应保持今天；编辑、删除后重启确认一致。|
|特殊不适|选 Sharp pain / Joint pain 并保存；历史保留类型，不显示普通酸痛恢复倒计时。|
|力量新建|Today → Record or supplement a session → Create strength session；搜索 Squat，记录组次、重量和 RIR=0，保存。活动详情和区域估计随新增/编辑/删除组变化。|
|力量补录|选已有导入力量会话补组，同步两次；原会话只出现一次，Cardio 不因补组增加，组次不丢。|
|模板|从活动保存模板，在另一会话应用；组数、动作与可选未知努力保留，新组身份独立。|
|先手动后同步|手动会话录组与体感，导入对应外部活动后在详情显式关联；活动贡献一次，组次和体感历史可读。|
|跑骑游详情|查看分段覆盖、缺 HR/踏频/路线解释；更改活动标签并重算。未提供地形/姿势/泳姿时不得显示为已测得。|
|历史和删除|旧 History 仍显示 TSS/CTL/ATL；删除活动后贡献移除，用户体感和组次历史保留。再次同步不复活用户本地删除。|
|离线|断网后启动与进入已有活动，记录体感/力量；同步失败有明确提示，本地记录与估计不被清空。|
|常规记录计时|从 Today 开始计时，选区域→选择等级→Save，记录真实耗时、点击数与可访问性问题。10–20 秒是工程目标，不把一次内部操作当用户研究。|

恢复时间、恢复百分比和训练安全预测应始终不出现。以合成数据观察工程行为不得推断真实生理准确性。
