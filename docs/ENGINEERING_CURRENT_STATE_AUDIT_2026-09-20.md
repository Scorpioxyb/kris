# Kris Coach 工程现状审计

审计日期：2026-09-20  
审计范围：当前工作区的实际文件，包括未提交修改与未跟踪文件。  
审计性质：只读代码审计；未修改应用源码、产品逻辑、数据模型或服务端逻辑。

## 0. 结论摘要

状态标记：`confirmed` 表示有代码或测试直接证据；`reasonable_inference` 表示由调用链推导；`insufficient_data` 表示需要真机、真实 HealthKit 数据或部署环境验证。

1. `confirmed`：工程是一个无第三方运行时依赖的原生多目标项目，包含 iPhone App、Watch App、Live Activity、Swift 单元测试和 UI 测试。iOS/watchOS deployment target 均为 26.0，Swift 6 严格并发。
2. `confirmed`：iPhone 是计划、HealthKit 聚合、SwiftData、历史、AI 候选审核和 Live Activity 的主协调端；Watch 是 HealthKit 训练执行端和离线事件源；共享代码以 Codable 契约为主，但 Watch 只编译其中两个共享文件。
3. `confirmed`：AI 尚未接入真实模型。Gateway 只有 provider-neutral `PlanProvider` 协议和 deterministic `StubPlanProvider`，生产模式明确 fail closed。
4. `confirmed`：AI 不能直接发布计划。返回值经过服务端契约校验、客户端解码/范围校验、候选持久化校验、规则版本与 safety gate 校验，最后还需要用户显式采用。
5. `confirmed`：没有发现客户端保存模型供应商 API key。客户端仅在 Keychain 中读取 Gateway session token；旧 DeepSeek key 标识只用于一次性删除迁移。
6. `confirmed`：AI 请求不直接包含 `HealthBatch` 或 HealthKit UUID/device/source/raw timestamp；Gateway 还递归拒绝相关字段。开发 Mac companion 可选择性接收原始 `HealthBatch`，它与 AI Gateway 是两条不同链路。
7. `confirmed`：准备度分数仍存在于本地规则、趋势页和 AI 上下文。这与“状态分只能作为弱参考、不能成为产品和 AI 权威”的目标冲突。
8. `confirmed`：用户可手动编辑当前计划，也可生成、编辑、拒绝或采用 AI 候选计划；当前并非“完全不能自定义”。但手动编辑器和 AI 编辑器使用不同参数上限，计划校验入口不统一。
9. `confirmed`：iPhone 端可以丢弃零组或已有组次的草稿且不生成历史；Watch 管理的训练必须先结束 HealthKit session，再自动完成丢弃。历史支持删除本地记录或隐藏 HealthKit/远端摘要，不会删除 Apple 健康中的 workout。
10. `confirmed`：当前 SwiftData 主要保存 JSON payload，而非标准化的计划/动作/组次关系。实现简单且契约清晰，但查询、迁移、局部更新和长期数据治理成本会随产品增长上升。

## A. 当前架构图

```text
                           +---------------------------+
                           | AI Gateway (Python stdlib)|
                           | auth / rate limit / audit |
                           | request+response validate |
                           | PlanProvider protocol     |
                           | -> StubPlanProvider       |
                           +-------------^-------------+
                                         | HTTPS + Bearer device session
                                         | AIRedactedPlanContext
+----------------------+        +--------+-----------------------------------+
| Apple Health         |<------>| iPhone KrisCoach                           |
| HealthKit samples    |        | AppModel (main coordinator)               |
| imported workouts    |        | HealthKitService -> HealthReducers         |
+----------------------+        | TrainingIntelligence / ReadinessEngine     |
                                | SwiftData JSON records / UserDefaults      |
                                | AI candidate review / manual plan editor   |
                                | WorkoutLiveActivityController              |
                                +--------+----------------+------------------+
                                         |                |
                  WatchConnectivity      |                | ActivityKit
          applicationContext/userInfo    |                v
          + Workout Mirroring realtime   |      +-------------------------+
                                         |      | Live Activity extension |
                                         v      | lock screen / island    |
                                +-------------------------+
                                | watchOS Kris            |
                                | WatchAppModel           |
                                | WorkoutManager          |
                                | HKWorkoutSession        |
                                | local execution snapshot|
                                | durable event queue     |
                                +-------------------------+

Optional development-only archive path:
iPhone HealthBatch / TrainingSession -> pinned-TLS Mac companion
```

编译边界以 `native/make_project.py:155-200` 为准：iPhone 编译全部 Shared、iPhone 文件和 Activity attributes；Watch 只编译 `Contracts.swift`、`WatchExecutionPersistence.swift` 与 Watch 文件；Live Activity 只编译 attributes 和 widget UI。目标定义见 `native/make_project.py:262-272`。

## B. 核心数据模型

### B1. 共享领域契约

- `HealthSampleContract` / `HealthBatch`：包含 sample UUID、时间、值、单位、source 和 metadata；见 `native/Shared/Contracts.swift:68-109`。
- `ExercisePlan` / `TrainingPlan`：动作处方、器械变体、重量、组次、休息、安全门槛、plan revision；见 `native/Shared/Contracts.swift:115-143`。
- `TrainingPlanCandidate`：`draft -> awaiting_confirmation -> published/rejected`，注释明确“候选不能隐式替换当前计划”；见 `native/Shared/Contracts.swift:145-164`。
- `CompletedSet` / `ExerciseResult` / `TrainingSessionContract`：保存实际重量、次数、末组感受、计划引用、整体反馈、Watch workout UUID 和 workout 汇总；见 `native/Shared/Contracts.swift:253-345`。
- `SnapshotReadiness` / `SnapshotTrends` / `CoachSnapshot`：本地或 companion 快照契约；仍包含 score、components 和 readiness time series；见 `native/Shared/Contracts.swift:348-449`。
- `WorkoutLifecycleSnapshot` / `WorkoutCommand` / `WatchEvent` / `WorkoutMirrorEnvelope`：Watch 与 Phone 的状态机、命令和幂等事件契约，位于 `native/Shared/Contracts.swift` 后半部分。

### B2. SwiftData

`native/Shared/PersistenceModels.swift` 定义 8 个模型：

| 模型 | 用途 | 存储方式 |
|---|---|---|
| `SyncQueueItem` | 开发 companion 离线同步队列 | kind + JSON `Data` |
| `CachedPlanRecord` | 计划 revision 缓存及 active 标记 | 索引字段 + JSON `Data` |
| `TrainingPlanCandidateRecord` | AI 候选及状态 | 状态 + JSON `Data` |
| `ActiveTrainingRecord` | 崩溃/重启恢复中的训练 | session/plan 索引 + draft JSON |
| `ArchivedSessionRecord` | 已完成训练历史 | session 索引 + session JSON |
| `WatchEventRecord` | Watch 事件 inbox、幂等与 applied 标记 | event 索引 + event JSON |
| `HealthAnchorRecord` | HealthKit anchored query 游标 | metric + archive data |
| `CachedHealthSampleRecord` | 本地 HealthKit 样本缓存 | UUID/metric/date + sample JSON |

证据：`native/Shared/PersistenceModels.swift:4-127`。当前策略是“可索引外壳 + Codable payload”，不是关系化训练数据库。

## C. 当前 AI pipeline

```text
用户输入目标/时长/器械/备注/症状
  -> AppModel.makeAIPlanContext
  -> AIRedactedPlanContext
  -> KrisAIGatewayService (ephemeral URLSession, 45s request / 60s resource)
  -> Bearer Gateway session token
  -> Gateway auth -> strict request validation -> rate limit -> idempotency
  -> PlanProvider.generate_plan
  -> StubPlanProvider deterministic response
  -> strict response validation
  -> client decode + AIPlanPolicy.draftErrors
  -> makeCandidate
  -> local publicationErrors + SwiftData candidate
  -> user edit/reject/adopt
  -> savePlan only after explicit adopt
```

- 客户端入口：`AppModel.startAIPlanGeneration`，见 `native/iPhone/AppModel.swift:2104-2152`。
- 上下文构造：发送用户输入、聚合 readiness、`LocalPlanDecision`、最近 6 次确认训练摘要、当前计划摘要、最多 8 条 progression 和 data gaps；见 `native/iPhone/AppModel.swift:2058-2101`。
- 客户端网络：`KrisAIGatewayService` 仅允许 HTTPS 或 `127.0.0.1` HTTP；使用 ephemeral session，无 cookie/cache/credential storage；见 `native/iPhone/AIService.swift:34-60, 90-113`。
- timeout：request 45 秒、resource 60 秒；只对“200 但空 body”重试 1 次，不对 transport/429/5xx 自动重试；见 `native/iPhone/AIService.swift:103-138`。
- provider-neutral 接口：`PlanProvider.generate_plan(context)`；当前唯一实现是 `StubPlanProvider`；见 `services/ai_gateway/provider.py:7-52`。
- Gateway 生产闸门：production mode 直接拒绝启动，且只允许 `stub`；见 `services/ai_gateway/config.py:42-56`。

## D. 当前 safety / validation pipeline

### D1. AI 输入隐私

- `AIRedactedPlanContext` 明确不含 HealthKit UUID、device ID、source name、raw sample timestamp；见 `native/Shared/AIContracts.swift:40-53`。
- 实际构造没有引用 `HealthBatch`，只使用聚合摘要；见 `native/iPhone/AppModel.swift:2058-2101`。
- Gateway 对 context 全树扫描 forbidden key，包括不同命名风格的 sample/device/source/raw keys；见 `services/ai_gateway/contracts.py:19-39, 86-95, 98-135`。
- `confirmed`：未发现 HealthKit 原始数据直接发送给 AI 的路径。
- 注意：开发 companion export 是另一条链路，开关为 `development.companionExportEnabled`；见 `native/iPhone/AppModel.swift:524-526, 1777-1794`。

### D2. AI 输出与采用

1. Gateway 严格拒绝多余字段并限制 title、时长、动作数、重量、组数、次数和休息；见 `services/ai_gateway/contracts.py:226-277`。
2. iOS 解码后再次执行同类范围校验；见 `native/Shared/AIContracts.swift:98-143`。
3. `makeCandidate` 强制加入本地 rollback condition 和急症停止文案；见 `native/Shared/AIContracts.swift:145-187`。
4. `publicationErrors` 检查本地规则版本、`stop_and_seek_care`、safety gates 和参数边界；见 `native/Shared/AIContracts.swift:190-220`。
5. `publishPlanCandidate` 要求 `awaitingConfirmation`，重新验证后才调用 `savePlan`；见 `native/iPhone/AppModel.swift:2028-2046`。
6. 候选 UI 明确展示“尚未发布”，支持编辑、拒绝、采用；见 `native/iPhone/AIViews.swift:261-379, 515-520`。

`confirmed`：当前 AI 调用链没有绕过 local validation 的路径。  
`risk`：`AppModel.savePlan` 本身是宽入口，手动编辑器和 development companion 可直接调用；它负责 revision 冲突但不执行统一的完整处方校验，见 `native/iPhone/AppModel.swift:1961-2002`。

### D3. 训练安全规则

- Readiness safety gate 独立于 score：急症 flag -> `stop_and_seek_care`，pain >= 3 -> `reduce`；见 `native/Shared/ReadinessEngine.swift:136-139` 和 `shared/rules/readiness.v1.json:29-34`。
- 急症包括胸痛、晕厥、明显呼吸困难、异常心悸、放射性背痛、麻木、无力、大小便改变。
- 缺失信号保持 nil，不被解释为正常；信号不足时是 `insufficient_data`；见 `native/Shared/ReadinessEngine.swift:76-107`。
- AI 生成要求症状明确为 `noneReported`；见 `native/Shared/AIContracts.swift:139-141` 和 `native/iPhone/AppModel.swift:2109-2115`。

## E. 当前训练执行 pipeline

### E1. iPhone 发起

`startTraining -> beginTraining -> ActiveTrainingRecord -> Live Activity -> Watch applicationContext`，见 `native/iPhone/AppModel.swift:1338-1375`。

- 每组变化先更新 UI，再 debounce SwiftData；生命周期边界、动作替换和归档前立即落盘，见 `native/iPhone/AppModel.swift:1377-1440, 1701-1768`。
- iPhone 本地训练支持 pause/resume/stop；Watch 接管后命令同时走 Workout Mirroring 与 WatchConnectivity，见 `native/iPhone/AppModel.swift:1443-1483`。
- 新计划在活跃训练期间只缓存不激活，结束/丢弃后再激活；见 `native/iPhone/AppModel.swift:1961-2002, 2161-2188`。

### E2. Watch 执行

- Watch 以 `HKWorkoutSession` + `HKLiveWorkoutBuilder` 执行室内传统力量训练，读取心率和活动能量并写 workout/active energy；见 `native/Watch/WorkoutManager.swift:73-109`。
- Watch 本地先保存 `WatchExecutionSnapshot`，再启动 HealthKit；写入采用 atomic + complete file protection；见 `native/Watch/WatchAppModel.swift:93-118`、`native/Watch/WatchExecutionStore.swift:21-38`。
- 完成组会生成绝对 rest deadline 和 `WatchEvent`；最后一组自动 stop；见 `native/Watch/WatchAppModel.swift:154-192`。
- HealthKit 保存使用 write-ahead `SubmissionRecord`，避免重启后重复 `finishWorkout`；见 `native/Watch/WorkoutManager.swift:329-370`。
- Watch 重启可恢复 active/paused/finalizing/failed/completed 状态；见 `native/Watch/WatchAppModel.swift:56-86`。

### E3. Phone/Watch 通信

- 计划：`updateApplicationContext`，适合“最新状态”；见 `native/iPhone/PhoneWatchConnectivity.swift:63-68`。
- 命令：reachable 时 `sendMessage`，失败或不可达时 `transferUserInfo`；见 `native/iPhone/PhoneWatchConnectivity.swift:70-82`。
- 事件：Watch 先写文件队列；实时 `sendMessage` 失败转 `transferUserInfo`；见 `native/Watch/WatchEventQueue.swift:18-68`。
- 实时训练状态：HealthKit Workout Mirroring，payload 上限 90KB；见 `native/iPhone/MirroredWorkoutCoordinator.swift:29-33, 66-80, 112-133` 与 `native/Watch/WorkoutManager.swift:230-246`。
- iPhone inbox 用 `eventId` 去重、按 lifecycle sequence/createdAt 重放；见 `native/iPhone/AppModel.swift:1854-1939`。

### E4. 结束、丢弃和历史

- `finishTraining` 只有在 Watch terminal 或本地 stopped 后才归档；archive 保存失败会保留 active draft 和 Live Activity；见 `native/iPhone/AppModel.swift:1548-1606`。
- `discardTraining` 不创建 `TrainingSessionContract`。本地训练立即删除 draft；Watch 训练先发 stop，terminal event 到达后自动继续丢弃；见 `native/iPhone/AppModel.swift:1493-1545, 1933-1938`。
- `deleteLocalSession` 删除 SwiftData archive 和待上传队列；对于 HealthKit/远端摘要只记录隐藏 ID，不删除 Apple 健康数据；见 `native/iPhone/AppModel.swift:1631-1678`。
- 训练历史 UI 展示来源与设备原始名称，见 `native/iPhone/Views.swift:4200-4203`。这解释了用户仍会看到 “iPhone/Apple Watch/本地” 字样。

## F. readiness / status / recovery 位置与用途

| 位置 | 类型/方法 | 当前用途 |
|---|---|---|
| `shared/rules/readiness.v1.json` | `ReadinessRules.v1` | 权重、阈值、置信度、安全 flag 的版本化配置 |
| `native/Shared/ReadinessEngine.swift:66-143` | `ReadinessEngine.evaluate` | 按个人基线计算 0-100 score、state、confidence、safety gate |
| `native/iPhone/HealthKitService.swift:125-153` | 本地 engine + cached presentation | HealthKit 聚合后生成、缓存 readiness/trends |
| `native/iPhone/AppModel.swift:528-599` | `effectiveReadiness`, `localPlanDecision` | 只使用本地 HealthKit readiness，不用 companion 冒充今日状态；驱动安全/处方结论 |
| `native/iPhone/Views.swift:1396-1473` | 恢复判断/恢复信号 | 首页之外的决策依据视图，以状态、置信度、信号参与情况呈现 |
| `native/iPhone/Views.swift:3194-3216, 3477-3480` | `TrendMetric.readiness` | 趋势页仍显示“准备度/分”并解释分数 |
| `native/Shared/AIContracts.swift:18-23` | `AIRedactedReadiness` | AI context 仍包含 score/state/confidence/safetyGate |
| `native/iPhone/AppModel.swift:2058-2063` | `makeAIPlanContext` | 实际把 `$0.score` 发给 AI Gateway |

规则权重为 sleep 0.45、HRV 0.25、RHR 0.15、load 0.15；阈值仍映射为“可推进/维持/降阶/恢复优先”，见 `shared/rules/readiness.v1.json:3-20`。

## G. 已符合产品原则的地方

1. 用户控制：AI 只能产出候选，必须显式采用；也能编辑和拒绝。
2. provider-neutral：客户端只认识 Gateway schema；Gateway 只依赖 `PlanProvider` 协议。
3. 隐私最小化：AI context 使用聚合摘要，并双端拒绝原始 HealthKit identifier。
4. 本地安全优先：模型不能覆盖本地 safety gate、规则版本和参数边界。
5. 离线优先训练：Watch 有本地执行快照、事件队列和 HealthKit 恢复/核验。
6. 不把计划当完成：历史来自明确归档 session 或 HealthKit workout，计划本身不进入完成历史。
7. 缺失数据不装作正常：readiness components、confidence 和 data gaps 保留缺口。
8. 器械变体隔离：progression 按动作 + equipment variant 分组。
9. 双进阶有门槛：需要连续两次同方案到达上限，且明确反馈轻松/合适；动作变形会 hold。见 `native/Shared/TrainingIntelligence.swift:406-466`。
10. 训练草稿可丢弃、历史可删除/隐藏，且不误删 Apple 健康 workout。

## H. 与产品原则冲突的地方

### H1. 高优先级

1. **准备度分仍有产品权威感**：虽然首页主表达已改为“今日状态/恢复判断”，趋势页仍明确显示“准备度（分）”，AI context 也发送 score。它会把内部启发式重新变成用户和模型的决策锚点。
2. **手动计划与 AI 计划不是同一套验证边界**：手动编辑器允许 20 组/100 次，AI 上限是 10 组/50 次；`savePlan` 没有统一 validator。相同领域对象因入口不同具有不同安全约束。
3. **训练历史泄漏底层来源表达**：详情页直接显示 `sourceName` / `deviceName`，因此出现 “iPhone 本地/Apple Watch” 等实现口径，而不是用户口径。

### H2. 中优先级

4. **Live Activity 信息密度偏高**：expanded island 同时显示图标、时长、动作、下一组、休息或完成组数；lock screen 还展示计划、生命周期、动作、进度。功能完整，但与原生健身类应用强调单一主任务的克制表达存在距离。见 `native/LiveActivity/KrisLiveActivity.swift:19-74, 77-131`。
5. **完成 Live Activity 固定保留 45 秒**：`dismissalPolicy.after(now + 45s)`，不是根据用户是否需要完成回执动态决定；见 `native/iPhone/WorkoutLiveActivityController.swift:95-122`。
6. **训练负荷仍是启发式代理**：负荷为 duration × title-derived factor，标题变化会改变分类；见 `native/Shared/TrainingIntelligence.swift:468-489`。
7. **步数不是 HealthKit statistics 聚合**：当前算法按时间片选择 Watch > iPhone > other，并假设样本内步数均匀分布；见 `native/Shared/HealthReducers.swift:342-400`。它解决重叠重复计数，但仍可能与 Apple 健康总数不一致。

## I. 潜在架构风险

| 优先级 | 风险 | 影响 |
|---|---|---|
| P0 release gate | Gateway 仍是 development-only HMAC token + stub；production 明确不能启动 | 不能发布真实 AI 服务，但这是正确的 fail-closed 状态 |
| P1 | `savePlan` 是未经统一领域校验的公共写入口 | 手动编辑、companion 或未来入口可能写入与 AI policy 不一致的计划 |
| P1 | readiness score 同时进入 UI 趋势与 AI context | 内部启发式可能被放大成用户/模型权威判断 |
| P1 | SwiftData 大量 JSON payload | 迁移、查询、局部更新、冲突合并和数据修复会越来越困难 |
| P1 | Gateway rate limit、idempotency 都是进程内内存 | 多实例/重启后不一致；不能用于生产配额或幂等保证 |
| P1 | Provider 调用是同步协议，无 Gateway 级 provider timeout/circuit breaker | 真实 provider 接入后可能占住 HTTP worker；客户端 timeout 不等于服务端取消 |
| P1 | session token 只有 HMAC 自包含校验，无 server-side revoke；App Attest 未实现 | 设备会话无法可靠撤销，不满足生产认证要求 |
| P2 | Watch 事件在 `transferUserInfo` 接受后立即从本地 queue 删除 | 系统交付通常可靠，但缺少 phone-level ACK；极端情况下无法端到端证明已应用 |
| P2 | step overlap 采用自定义均匀分配和 source priority | 与 Apple Health 展示值可能偏差，尤其长区间样本和跨午夜样本 |
| P2 | load factor 依赖标题字符串 | 文案、语言或命名调整可能改变训练负荷趋势 |
| P2 | candidate rationale/cautions 只在内存，不在 candidate record 内 | App 重启后候选本体仍在，但模型解释可能丢失 |
| P2 | Live Activity provisional 状态可在 Watch mirror 接受时先出现 | 若 session 后续未匹配/启动，短期可能显示“正在连接”；虽有 orphan cleanup，仍需真机竞态验证 |
| P3 | 多处 `try?` 静默吞掉持久化/通信错误 | UI 可继续工作，但诊断性弱，难区分用户环境问题与数据未写入 |

## J. 建议下一步修改的文件和原因

以下仅是建议顺序，本阶段未执行：

1. `native/Shared/AIContracts.swift`、`native/iPhone/AppModel.swift`、`shared/schemas/KrisAIPlanRequest.v1.schema.json`、`services/ai_gateway/contracts.py`：从 AI context 移除 readiness score，只保留 state/confidence/safety gate 和明确证据摘要。
2. `native/iPhone/Views.swift`：把“准备度分”趋势改为可解释恢复信号或状态带；训练历史将 source/device 映射为用户语言，默认不展示底层设备品牌。
3. `native/Shared/Contracts.swift` 或新建不依赖 UI 的 shared validator：统一 manual/AI/companion 的 `TrainingPlan` 领域校验，再让 `AppModel.savePlan` 成为受控入口。
4. `native/Shared/HealthReducers.swift`、`native/iPhone/HealthKitService.swift`：评估使用 `HKStatisticsCollectionQuery`/HealthKit statistics 的日步数口径，并以 Apple 健康同日总数做真机对照。
5. `native/LiveActivity/KrisLiveActivity.swift`、`native/iPhone/WorkoutLiveActivityController.swift`：以 Apple Fitness 运动中状态为参考，降低 expanded/lock-screen 信息密度，并通过真机后台/跨 App/灵动岛 compact-minimal 状态验证长度与生命周期。
6. `services/ai_gateway/provider.py`、`service.py`、`controls.py`、`auth.py`：接真实模型之前先定义 async provider timeout、取消、持久化幂等/限流、App Attest/可撤销 session 和 provider error taxonomy。
7. `native/Shared/PersistenceModels.swift`：先写数据版本与迁移策略；是否标准化 exercise/set 表应基于未来查询需求决定，不建议立即重构。
8. `native/Shared/TrainingIntelligence.swift`：把负荷分类从标题推断迁移到显式 workout/category 字段，保留旧记录兼容层。

## 20 项检查结论索引

1. 整体架构：见 A。  
2. iOS/watchOS/shared 职责：见 A、E。  
3. SwiftData：见 B2。  
4. HealthKit：42 天 backfill + anchored/observer + contract cache + reducers，见 `native/iPhone/HealthKitService.swift:157-185, 297-365`。  
5. 计划模型和生命周期：见 B1、C、D2。  
6. 训练执行：见 E。  
7. Watch/iPhone 通信：见 E3。  
8. Live Activity：ActivityKit controller + widget extension，见 H2。  
9. 历史/结果保存：见 B2、E4。  
10. progression/load：gated double progression + duration/title proxy，见 G9、H2。  
11. AI Gateway：见 C。  
12. Stub Provider：见 C。  
13. candidate schema：`shared/schemas/AIPlanResponse.v1.schema.json` + `TrainingPlanCandidate`，见 B1、D2。  
14. validation/edit/adopt/reject：见 D2。  
15. safety rules：见 D3。  
16. readiness/recovery/status：见 F。  
17. 原始 HealthKit 发 AI：`confirmed no`，见 D1。  
18. AI 绕过 local validation：当前 AI 调用链 `confirmed no`；宽 `savePlan` 是未来风险，见 D2/I。  
19. 客户端 vendor key：`confirmed no`；只保存 Gateway session token 和 companion device token。  
20. 错误/timeout/fallback/logging：客户端 45/60 秒 timeout、状态码映射、空响应一次重试；Gateway 结构化 metadata-only audit；Watch 有离线队列和恢复；但大量 `try?`，Gateway provider 无 timeout/circuit breaker，见 C/I。

## 验证记录

- `xcodebuild ... build`：成功，包含 iPhone、Watch、Live Activity 三目标。
- `xcodebuild test ... -only-testing:KrisCoachTests`：98 tests，0 failures。
- 覆盖的关键回归包括：空训练丢弃不留历史、已有组次丢弃、历史删除、Watch terminal 后丢弃、AI safety stop 不可绕过、AI 候选确认、HealthKit identifier 不进入 AI context、step overlap 处理。
- `python3 -m unittest -v tests.test_ai_gateway`：13 项中 11 项服务/契约测试通过；2 项本机 loopback HTTP 测试报 `RemoteDisconnected`。使用最小 Python `ThreadingHTTPServer` 复现了相同断连，因此当前证据更符合本机 Python 3.14 loopback 运行环境问题，不足以判定为 Gateway handler 代码缺陷；部署前仍应在标准 CI/Linux 环境重跑。
- `git diff --check`：通过。
- 未运行完整 UI tests，也未做真实 iPhone + Apple Watch 的后台、断连、Live Activity 和 HealthKit 对照测试；这些属于 `insufficient_data`。

