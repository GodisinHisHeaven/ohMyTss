# v2 唯一进度入口

## 2026-10-25 人体图视觉补全

- 前后视图改为原生矢量人体与肌群轮廓，加入选中反馈、分侧体感着色、图例、深浅色与大字号适配；人体卡片移到 Today 顶部。
- 颜色只来自最近七天的实际体感记录，未记录保持中性，不由训练负荷推断左右侧或恢复状态。
- 6 项状态测试 + 4 项 UI 测试通过；最后的装饰图标辅助功能修正后，相关 UI 流程再次通过。模拟器人工检查前后视图、深浅色、最大辅助功能字号和列表入口。
- 截图、复现命令和本轮源文件指纹见 [人体图视觉验证](evidence/BODY_MAP_2026-10-25.md)。本轮改动随 PR #18 交付；本地测试结果与云端检查状态分别记录。

## 2026-10-25 本地 Xcode 验证

PR #18 的 `8bb4973f6d7860ba4d5f7b54bb10c6e11c0bc26e` 已在独立本地分支 `codex/v2-xcode-validation` 验证并修复 Apple 平台问题。Apple 平台修复与后续人体图改动共用该验证分支；PR 保持 draft。

- Xcode 27.1 / iPhone 17 Pro / iOS 26.4：完整 scheme test 通过，42 次单元测试 + 9 次 UI 测试执行，0 失败、0 跳过。xcresult 按唯一测试计数为 48 项。
- 30 个共享领域测试、9 个生产 Strava 合成 HTTP 场景、4 个配置测试通过。
- 最终模型的真实 SwiftData 基线迁移、iOS 不卸载升级与重启保留数据通过；保留旧 TSS/CTL/ATL/TSB、设置、关系和新增体感记录。
- 修复初始化编译错误、测试类型名歧义、表达式编译超时、与 SwiftData 冲突的删除字段，以及 UI 测试定位和初始方向。
- 实机 HealthKit/真实 Strava 授权、完整 VoiceOver/离线人工清单和真人记录计时仍待验证。

完整范围、失败修复过程和可复现命令见 [本地 Xcode 报告](evidence/LOCAL_XCODE_2026-10-25.md)。以下保留 PR 提交时的 Linux 环境记录；其中 Apple 环境 blocked 描述是历史状态，以本节和报告为准。

## PR 提交时检查点（历史记录）
- 分支：`codex/v2-mvp`；基线 `fdab778b6b51181bd76c3627b765da8af5ed6eef`。
- 初始 checkout：新克隆 main，干净，无用户未提交更改；根 AGENTS.md 已读，无子目录规则或旧实施计划。
- 当前：本轮代码切片与独立审查修复已集成；已提交并推送 draft PR #18。**代码已实现 ≠ iOS 已构建或可发布**。
- 2026-10-25 可执行回归：30 个共享生产 Swift 领域测试、9 个生产 Strava API 合成 HTTP 情景、4 个原配置测试通过（43 个工程检查）。最近验证的代码提交为 `cf900d1b59f713fe582359203929dc4ca7ca1e5e`（与通过回归/语法检查的生产代码一致）；后续提交只更新交付入口。
- Debian 13 / Swift 6.0.3（本次下载并真实执行）；无 Xcode、xcrun、iOS SDK/模拟器。app 原 target 18.6、测试原 target 26.1、bundle/签名/entitlements 保持不变。

## 验收状态
状态表示验证层级：Apple 运行依赖项即使已有完整代码也仍为 blocked。

|编号|状态|实现与证据|
|---|---|---|
|A1 时间与缺失|passed|实际 app 共用 Domain；规则/不规则信号、30秒窗、暂停缺口、异常/乱序、未来截止、扭矩与日期测试；`evidence/regression.txt`|
|A2 导入|blocked|HK关联quantity series/source fallback、踏频/路线/泳姿、FTP解耦、失败通道保留；生产Strava HTTP9情景passed；HK实际回调/权限与iOS类型检查blocked|
|A3 同步|blocked|稳定来源组、幂等upsert、可恢复来源撤销/不可自动复活用户删除、组次体感迁移、跨日重算；19项SwiftData测试中的相关路径待Apple执行|
|B1 体感|blocked|9区域前后图+列表+VoiceOver标签、左右、unknown/none/skip、CRUD/补录历史持久化接通；模拟器/重启/VoiceOver/10–20秒计时待执行|
|C1 力量|blocked|26动作、搜索/区域过滤、模板、原子多组、RIR0、已有/新建/后关联、归档；领域行为passed，持久化与UI运行待Apple|
|D1 区域模型|passed|跑骑游力量独立单位、真实支持才影响标记、个人近期背景、版本覆盖原因；30领域测试passed；实际页面检查归E1|
|E1 用户流程|blocked|Today、活动/区域详情、分侧体感、标签重算、旧TSS/CTL/ATL、首次/离线可用路径及3项UI测试已实现；iOS编译/交互未运行|
|F1 研究基础|blocked|观测/录入/编辑时间、测量截止/知识截止、来源与输入版本快照；无恢复预测；保存重读依赖SwiftData运行|
|M1 迁移|blocked|增量字段、新实体、旧TSS保留、关系nullify；精确基线旧模型→真实同库迁移脚本已写；Linux执行返回BLOCKED/exit2|
|V1 回归与审查|blocked|可执行43工程检查passed；独立review发现的严重接线/逻辑问题已修复并复核；全量iOS XCTest、编译、迁移、交互仍blocked|

## 实际命令与结果

|命令|结果/证据|
|---|---|
|`git status --short --branch`（基线）|`main...origin/main`，无修改；切换到独立v2分支|
|`python3 -B -m unittest discover -s onMyTss/ci_scripts/tests -v`（基线）|4 passed；无已证实的原测试失败，Apple原测试未运行|
|`PATH=/workspace/toolchains/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin:$PATH scripts/check_v2_domain.sh`|exit0；30 Swift + 9生产Strava HTTP + 4原配置；`evidence/regression.txt`|
|`swiftc -frontend -parse onMyTss/**/*.swift docs/v2/fixtures/*.swift`（脚本展开文件）|exit0；**仅语法**，不是Apple类型检查/宏展开；`evidence/swift-parse.txt`|
|`bash -n scripts/check_v2_domain.sh scripts/check_v2_migration.sh`|exit0 shell语法|
|`bash scripts/check_v2_migration.sh`|exit2 BLOCKED：没有Apple SwiftData；`evidence/migration-environment.txt`|
|工具检测 `xcodebuild -version` / `xcrun simctl list devices available`|可执行文件不存在，不能运行；`evidence/apple-toolchain.txt`|
|`git diff --check`|passed，无空白错误；不代表编译|

不存在被隐藏/跳过的已知正确失败测试。领域实现期间的问题已修复后重跑；本轮没有未解决的已执行测试失败。未运行的Apple测试绝不算passed。

## 迭代与审查闭环

1. **时序与持久化切片**：移除FTP全局门槛、真实时间NP和HR积分；新增独立组次/体感/估计实体。领域测试验证时间分布与未知不为零。
2. **原生完整流程**：Today→人体图/报告、力量会话→动作组/模板→活动/区域、导入与手动关联。持久化/组编辑触发版本化重算；UI使用真实Store，无生产假数据。DEBUG UI测试flag仅启用内存库，不污染用户库。
3. **来源/删除闭环**：保留源行、匹配组、显式HK删除/Strava成功分页后详情404确认；空/权限/离线不清库。来源404可能是可见性变化，用来源撤销表达；后续正向返回可恢复。
4. **独立review与修复**：跨日旧TSS、来源切换丢组次、缺失覆盖旧样本/TSS、按样本数选源、用户删除复活、标签无法取消、未知严重度变轻度、混合活动覆盖、未来海拔/跑步背景泄漏、归档不可访问均修复。详见 `evidence/REVIEW.md`；19项SwiftData测试覆盖相应不变量，待Apple执行。
5. **收敛检查**：可执行全回归43检查通过，最终静态review未发现未解决严重问题。所有剩余发布前验证依赖真实Apple环境；停止无目标重构，不声称已可发布。

## 工程取舍、迁移与回退
- 继续原SwiftUI/SwiftData；Swift Package只引用app的Domain源码，无第三方依赖/服务器。模型启发式与降级规则见 `MODEL.md`，不拿合成测试证明生理准确性。
- 不删库、不更改旧实体名；新字段可选/有默认，新增独立实体。历史原TSS首次更新保存原值并可在活动页查看。关系由cascade改nullify，避免清聚合误删Workout。
- 需要执行真实迁移后才确认兼容。macOS脚本从固定基线提取原模型创建合成旧库，再用当前生产模型打开同一路径；iOS升级检查禁止卸载/重装掩盖问题。
- 回退代码使用 `git revert` 本次提交；**不保证旧二进制读取升级后库**。数据回退使用升级前测试/用户备份，绝不以删库回退。

## 阻塞与下一步（仅3项）
1. macOS + 合适Xcode/iOS SDK：按 `MACOS_CHECKS.md` 发现真实destination，运行项目scheme的完整test（原test最低26.1）；修复任何Apple类型/宏/运行问题。
2. 执行 `scripts/check_v2_migration.sh` 与iOS不卸载升级、磁盘重开；保存真实xcresult/迁移证据。
3. 实机/模拟器走首次、权限空、离线、导入、体感、力量、关联、归档和VoiceOver路径，记录10–20秒目标实际耗时。然后更新本入口，再决定是否解除draft；本任务不发布或合并。

现有Xcode Cloud main工作流附带TestFlight后操作，未经调用；没有安全可调用的现成非发布macOS CI。没有购买资源、改权限或签名来绕过阻塞。

## 交付入口
- Draft PR：[GodisinHisHeaven/ohMyTss #18](https://github.com/GodisinHisHeaven/ohMyTss/pull/18)
- 工作分支：`codex/v2-mvp`，已推送 `origin/codex/v2-mvp`。
- 实现/验证提交：`cf900d1b59f713fe582359203929dc4ca7ca1e5e`（Implement traceable v2 training load MVP）。
- 本状态入口的后续提交仅记录远端链接，未改变已验证算法。PR 保持 draft；未合并、未发布。
