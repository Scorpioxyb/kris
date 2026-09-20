# Kris Coach AI Decision Pipeline V2

状态：开发态 V2 核心链路已实现并有环节级集成验证；V2 UI 自动化和单条端到端全闭环待补；生产 AI 尚未接入  
基线日期：2026-09-20  
适用范围：iPhone App、本地规则、AI Gateway、训练候选审核、Watch 执行与训练结果回流

## 1. 文档边界

本文定义 Kris Coach AI 决策链路的数据契约、权限边界、失败处理和发布验收标准，也记录 2026-09-20 开发态实现的验收结果。这里的“已实现”只表示 provider-neutral V2、deterministic Stub Provider、本地 validation/persistence 与训练结果回流各环节已有代码和集成测试证据。它不表示 V2 审核页的交互自动化、从 Stub 生成到未来 context 的单条端到端测试、真实模型、生产认证或真机发布已经完成。

术语状态：

- `开发态已实现`：可由 2026-09-20 工作区代码和环节级单元/集成测试证明；具体 UI 和端到端验收状态以第 10 节为准。
- `生产待办`：接入真实 Provider 或正式发布前仍需实现。
- `待真机验证`：已有代码或模拟器证据，但缺少 iPhone/Apple Watch 真机端到端证据。

开发态已实现：

- `UserIntent -> TrainingContext.v2 -> AIRecommendation.v2 -> TrainingPlanCandidate.v2 -> UserDecision -> TrainingPlan -> TrainingSessionContract` 各代码环节已连通，并有分段集成测试；尚未用单条端到端用例覆盖整条链路。
- objective health、subjective feedback、confirmed training、observed workout、deterministic rule 和 AI inference 使用不同类型或 provenance 表达。
- V2 wire request 不包含 readiness/recovery/body-state score、HealthKit UUID、设备名、数据源名或原始样本时间序列。
- 本地 validator 会检查 evidence 引用、missing/unknown、safety restriction、progression permission、器械、时长、计划结构和采用时新鲜度。
- 候选的查看、编辑、采用和拒绝界面及模型操作已落地；计划与 candidate 采用为原子保存，失败会回滚。V2 审核交互仍待专门 UI 自动化验收。
- 已确认训练结果会以实际 `weight x reps` 的 `set_performance` evidence 回流；HealthKit workout 仍保持为独立 observation。
- V1 candidate 继续可解码、查看和拒绝，但不能通过旧路径直接发布。
- Gateway V2 使用严格 request/provider schema、evidence 引用验证、错误分类、开发期 HMAC、进程内限流/幂等和 deterministic Stub Provider；production mode fail closed。

开发态验收待办包括：V2 review/edit/accept/reject 的专门 UI 自动化，以及从 Stub 生成、用户决定、训练执行到未来 context 回流的单条端到端测试。

生产待办包括：真实 Provider、Provider timeout/cancellation/circuit breaker、App Attest 或可撤销短期会话、共享限流与幂等存储、标准 CI/Linux 回归，以及 iPhone + Apple Watch 真机端到端验收。

## 2. 不可破坏的设计原则

1. 客观健康数据、实际训练数据、主观用户反馈、本地确定性结论和 AI 推断必须分别建模。
2. 缺失、未知、过期和冲突必须保留原状；不得折叠为“正常”“无症状”或零值。
3. 不新增 readiness、recovery、body state 等黑盒综合评分。
4. V2 发给 AI 的上下文不得包含 V1 readiness score 或 components score。
5. Safety restriction 和 progression permission 只能由本地确定性规则产生。
6. AI 只能提出 recommendation、解释、备选和不确定性，不能发布计划、解除限制或写训练结果。
7. AI 输出必须是严格结构化数据；自然语言只能存在于结构化字段内，不能依赖解析自由文本来恢复关键决策。
8. 任何 AI 候选都必须由用户明确 review、edit、accept 或 reject。
9. 接受时必须用最新本地状态重新验证，不能只信生成时的上下文。
10. Watch 只执行已发布并冻结 revision 的 `TrainingPlan`，训练中不依赖 AI 可用性。
11. 计划、设备 workout 和用户确认的实际训练结果不是同一种事实。
12. Provider、Gateway 或 AI schema 失败时，既有训练与健康主流程必须继续可用。

## 3. V2 数据分层

本节以当前 Swift domain model 为准。Gateway wire schema 使用对应的 `snake_case` 字段；产品概念名若与实现名不同，会在文中明确说明，不把未落地的目标字段当作当前契约。

### 3.1 UserIntent

`UserIntent` 表达用户这次希望系统处理什么，而不是模型推测的目标。

当前实现字段：

- `intentId`
- `kind`：`createPlan`、`revisePlan`、`replaceExercise`、`adaptToEquipment`、`shortenPlan`、`explainRecommendation`
- `requestedDate`
- `objective`
- `availableMinutes`
- `equipment[]`：元素为 `EquipmentAvailability(name, status)`
- `targetPlanId?`
- `targetPlanRevision?`
- `requestedExerciseId?`
- `requestedChanges[]`
- `notes?`

`availableMinutes = 30`、某器械不可用、只换一个动作都必须进入结构化字段，不能只埋在备注中。

### 3.2 TrainingContext

`TrainingContext` 是一次推荐请求的不可变、带有效期快照。

当前实现字段：

- `schemaVersion = TrainingContext.v2`
- `contextId`
- `generatedAt`
- `expiresAt`
- `intent`
- `objectiveHealth`
- `subjectiveUser`
- `trainingHistory`
- `progression`
- `safety`
- `currentPlan?`
- `evidence[]`
- `dataGaps[]`

候选采用时至少复核 `expiresAt`、当前 `planId/revision`、本地规则版本和最新 safety restrictions。

### 3.3 ObjectiveHealthContext

`ObjectiveHealthContext` 当前只保存 `asOf` 和 `evidenceIds[]`；具体客观信号作为 `Evidence` 存储并通过 ID 引用。这些信号包括：

- 睡眠区间或总时长及覆盖质量；
- HRV、静息心率及同口径个人基线差异；
- 当日数据是否完整、缺失或过期；
- 客观 workout observation 的时间、类型、时长和心率摘要。

它不能包含“今天精力很好”“疼痛”“建议减量”等用户事实或推断。

### 3.4 SubjectiveUserContext

`SubjectiveUserContext` 当前只保存 `reportedAt` 和 `evidenceIds[]`；用户主动报告的事实和偏好作为 `Evidence` 存储并通过 ID 引用，例如：

- `userReportedEnergy`
- `fatigue`
- `symptoms[]`
- `painLocation/intensity/behavior`（仅记录用户描述，不作医学诊断）
- `exercisePreference`
- `equipmentAvailability`
- `timeConstraint`

`notReported` 与 `noneReported` 必须是不同状态。

### 3.5 TrainingHistoryContext

历史必须至少分成两组：

- `confirmedSessions[]`：来自 Kris 执行链、包含实际组次或明确完成状态的 `TrainingSessionContract` 摘要。
- `observedWorkouts[]`：来自 HealthKit/设备的 workout observation。

设备观察可以补充客观时长和心率，但不能替代用户确认动作、重量、次数、疼痛或完成事实。

### 3.6 ProgressionContext

复用现有 gated double progression 的原则。当前 `ProgressionContext` 包含 `ruleVersion` 和 `permissions[]`，每个 `ProgressionPermission` 包含：

- `exerciseName`
- `equipmentVariant`
- `allowsLoadIncrease`
- `maximumWeightKg?`
- `evidenceIds[]`

只有同器械、同方案连续两次全部达到次数上限，且两次均有“轻松/合适”反馈，才允许最小档加重。主观“今天状态很好”或单个健康信号不能创建进阶许可。

### 3.7 SafetyContext 与 SafetyRestriction

`SafetyContext` 由本地规则产生：

- `disposition`：`allow`、`constrain`、`needsUserInput`、`block`
- `restrictions[]`
- `ruleVersion`
- `evaluatedAt`
- `expiresAt`

每个 `SafetyRestriction` 当前包含：

- `id`
- `kind`
- `severity`
- `evidenceIds[]`
- `authority = localRule`
- `message`
- `subject?`

当前约束类型为：`prohibitTraining`、`prohibitUnapprovedLoadIncrease`、`excludeExercise`、`prohibitEquipment`、`requireSymptomConfirmation`、`recoveryOnly`。减量可以作为经本地限制后的候选调整表达，但当前不是独立的 `SafetyRestrictionKind`。

AI 只能返回自己确认遵守的 `acknowledgedRestrictionIds`，不能新增、删除或降级本地 restriction。

### 3.8 Evidence

所有理由必须引用可追踪 evidence，而不是复述成无法核对的自然语言。

当前 Swift domain 字段：

- `id`
- `provenance`：`objectiveHealth`、`subjectiveUser`、`confirmedTraining`、`observedWorkout`、`deterministicRule`
- `key`
- `observedAt?`
- `quality`：`confirmed`、`partial`、`missing`、`stale`
- `value?`：`JSONValue`，`quality = missing` 时必须为空
- `source`
- `note?`

在 Gateway wire adapter 中，`key + value` 会转成受 schema 约束的类型化 payload，当前包括：

- `quantity`：如睡眠 `6.33 h`、HRV `49.8 ms`
- `userReport`：如 energy `low`、pain `limiting`
- `setPerformance`：如 `60 kg x 8 x 3`
- `missingSignal`：如 sleep `missing`
- `ruleResult`：如 `load_increase_not_allowed`

AI recommendation 内的每个 `evidenceId` 必须存在于当前 `TrainingContext`，且引用类别必须与用途相符。

### 3.9 AIRecommendation 与 RecommendationReason

V2 当前输出包含：

- `schemaVersion = AIRecommendation.v2`
- `recommendationId`
- `requestId?`
- `contextId?`
- `kind`
- `recommendation`
- `proposedPlan?`
- `reasons[]`
- `evidenceIds[]`
- `confidence`
- `uncertainties[]`
- `optionalAdjustment?`
- `alternatives[]`
- `safetyConsiderations[]`
- `acknowledgedRestrictionIds[]`
- `userConfirmationRequired = true`
- `inferenceMetadata?`

每个 `RecommendationReason` 包含稳定 `code`、展示文本和 `evidenceIds[]`。

`confidence` 只表达“这条建议的证据充分程度”，使用 `low/medium/high` 等定性枚举，不表达身体恢复概率或医学风险概率。

### 3.10 Candidate、UserDecision 与 TrainingOutcome

优先复用当前模型：

- `TrainingPlanCandidateV2` 作为可审核、不可直接执行的 V2 计划候选；原 `TrainingPlanCandidate` 仅保留 V1 兼容读取。
- `TrainingOutcome` 不新建重复训练结果表；语义上复用 `TrainingSessionContract`。
- `UserDecision` 记录 recommendation/candidate 与用户决定的关系。

当前 `UserDecision` 字段：

- `recommendationId`
- `candidateId`
- `kind`：`accepted`、`acceptedWithEdits`、`rejected`
- `decidedAt`
- `acceptedPlanId?`
- `acceptedPlanRevision?`
- `edits[]`：元素为 `PlanChange(path, before, after)`
- `rejectionReason?`

## 4. 完整 Pipeline

```text
UserIntent
  -> Input Validation
  -> Context Builder
  -> TrainingContext.v2
  -> Local Safety Rules
  -> Local Progression Rules
  -> Pre-AI Gate
  -> AI Gateway / Provider
  -> AIRecommendation.v2
  -> Schema Validation
  -> Evidence Reference Validation
  -> TrainingPlan Domain Validation
  -> Safety / Progression Alignment Validation
  -> TrainingPlanCandidate
  -> User Review / Edit / Accept / Reject
  -> Accept-time Freshness Revalidation
  -> Published TrainingPlan + immutable revision
  -> Watch deterministic execution
  -> TrainingSessionContract (actual outcome)
  -> Future TrainingContext
```

### 4.1 生成前

1. 校验 intent 的日期、目标计划 revision、时间和器械状态。
2. 构建有 provenance 的 context；未知与缺失不补值。
3. 本地 safety engine 先运行。`block` 时不请求训练处方；`needsUserInput` 时先收集必要信息。
4. 本地 progression engine 产生明确许可或禁止结论。
5. 只发送最小化、聚合后的 V2 context；不发送原始 HealthKit UUID、设备 ID、原始样本时间序列或 readiness score。

### 4.2 AI 返回后

1. Gateway 和客户端分别执行严格 schema 校验。
2. 校验每条 reason、uncertainty 和 adjustment 的 evidence 引用。
3. 校验 AI 已确认所有适用 restriction，且没有试图定义本地 restriction。
4. 对候选计划执行统一领域校验：日期、时长、器械、动作、组次、次数、休息和重量范围。
5. 将候选变化与 progression permission 对齐；没有许可不得加重。
6. 只有全部通过后才创建 reviewable candidate。

### 4.3 用户审核和采用

1. UI 分区显示客观数据、用户反馈、本地限制、AI 理由和不确定性。
2. 编辑候选会使旧确认失效，并重新运行本地校验。
3. 接受时重新构建或读取最新 safety/progression 状态。
4. context 过期、计划 revision 已变化、规则版本变化或出现新 restriction 时，拒绝采用并要求重新评估。
5. 采用成功才创建正式 `TrainingPlan` revision 和 `UserDecision`。

### 4.4 执行和回流

1. Watch 只收到已发布 plan/revision，不收到 AIRecommendation。
2. 训练期间记录实际重量、次数、完成状态和用户反馈。
3. 结束后生成 `TrainingSessionContract`；设备 workout 只作为关联 observation。
4. 未来 context 只把确认训练结果作为 `confirmedSessions`，不能把计划或单独设备 workout 冒充为完成训练。

## 5. 权限与 Validation Boundary

| 能力 | 用户 | 本地规则/Validator | AI | Gateway | Watch |
|---|---|---|---|---|---|
| 声明意图、时间、器械、主观状态 | 是 | 校验 | 读取 | 透传校验 | 否 |
| 产生客观健康事实 | 否 | 聚合设备数据 | 只读摘要 | 不推断 | 记录 workout |
| 创建 SafetyRestriction | 否 | 唯一授权方 | 否 | 否 | 执行停止条件 |
| 创建 progression permission | 否 | 唯一授权方 | 否 | 否 | 否 |
| 提出计划或局部调整 | 手动编辑 | 校验 | 是 | 校验结构 | 否 |
| 发布计划 | 明确确认 | 最终授权校验 | 否 | 否 | 否 |
| 写实际训练结果 | 明确反馈 | 保存/校验 | 否 | 否 | 采集执行事件 |
| 覆盖新鲜安全状态 | 否 | 否 | 否 | 否 | 否 |

本地 validation 的失败必须 fail closed：不创建可发布候选、不改变当前计划、不向 Watch 发送新 revision。错误应返回稳定 code 和可理解说明，而不是只有一个布尔值。

AI 可以：

- 提出完整候选或局部修改；
- 提出动作替代、时间压缩和可选减量方案；
- 解释多条证据之间的冲突；
- 明确表达 uncertainty；
- 对危险请求返回结构化拒绝建议。

AI 不可以：

- 输出或修改 `SafetyRestriction`；
- 把 missing 写成 normal；
- 生成 readiness/recovery/body-state score；
- 仅凭 HRV、睡眠或主观状态决定加重；
- 引用不存在的 evidence；
- 诊断伤病；
- 把 `userConfirmationRequired` 设为 false；
- 创建正式 plan ID/revision/publishedAt；
- 写入或修改实际训练结果。

## 6. 十四个场景的确定行为

| 场景 | V2 行为 | 必须阻止的行为 |
|---|---|---|
| 1. 正常训练 | 构建完整 context，生成候选，校验后交用户确认 | AI 直接发布或启动训练 |
| 2. 用户要求改变计划 | `revisePlan` 指向明确 planId/revision，返回结构化差异 | 静默覆盖其他 revision |
| 3. 用户要求更换动作 | `replaceExercise` 指向 exerciseId，只修改目标动作并校验肌群、器械和限制 | 用自由文本无法追踪地重写整份计划 |
| 4. 临时没有器械 | 标记器械 unavailable，仅允许可用器械/自重替代 | 候选继续要求不可用器械 |
| 5. 只有 30 分钟 | 本地强制候选总时长不超过 30 分钟，可给结构化删减方案 | 仅在文案中承诺 30 分钟但处方超时 |
| 6. 用户反馈状态很好 | 记录为 subjective evidence，可影响解释与保守选择 | 单独授权加重或覆盖客观/安全限制 |
| 7. 用户反馈很累 | 记录为高优先级 subjective evidence，可维持、减量或提供恢复备选 | 因缺少客观异常而忽略疲劳 |
| 8. HRV 较低但主观正常 | 两条证据并存，显式记录冲突和 uncertainty，保持保守候选 | 合并成单一分数并宣称“状态差/状态正常” |
| 9. 睡眠数据缺失 | 产生 missing evidence/data gap，允许在其他信息充分且安全时给保守候选 | 把缺失解释为零睡眠或恢复正常 |
| 10. 用户主动报告疼痛 | 本地 `constrain/needsUserInput/block` 先于 AI；限制受影响动作或停止训练 | AI 用一般安全文案覆盖疼痛限制 |
| 11. 用户坚持明显不合理训练 | 本地 block 不可被用户 insist 或 AI 降级；可提供安全替代或拒绝 | 以“用户已确认风险”为理由发布 |
| 12. AI provider unavailable | 保留当前计划、输入和手动编辑能力；训练执行继续；可稍后重试 | 伪装成本地已生成 AI 候选或清空当前计划 |
| 13. AI 输出 schema invalid | 丢弃响应，不创建候选，记录结构错误；不解析自由文本补救 | 保存部分响应或猜测缺失字段 |
| 14. local validation failed | recommendation 可用于诊断审计，但不得变成可执行候选；显示本地失败原因 | 跳过本地 validator 或让 AI 自我修正后直接发布 |

## 7. V1 Readiness 迁移策略

V1 readiness 当前仍被 UI、趋势和 `LocalPlanEngine` 使用，因此不能直接删除；它已经从 V2 AI context 移除。旧 V1 context 只为兼容测试和旧数据读取保留，不是默认生成路径。

### Phase 0：冻结与标记

- 冻结 V1 score 算法，不增加新消费者。
- 在契约和 UI 代码中标记 legacy/deprecated 用途。
- 记录现有读取点和持久化位置。
- V1 继续支持现有 App，避免迁移前破坏训练主流程。

### Phase 1：建立 V2 evidence context

- [x] 从相同底层聚合结果生成 `ObjectiveHealthContext` 和 evidence。
- [x] `TrainingContext.v2` 不包含 score、components score 或 score-derived body state。
- [x] V2 safety context 使用明确症状、缺失状态和本地规则结论，不授权 AI 创建 restriction。
- [x] V1 score 暂时只服务旧 UI/旧规则兼容层。

### Phase 2：影子比较

状态：未实施。当前 V2 candidate 经用户采用后已能发布正式 plan revision，因此不能再把“V2 尚不改变正式计划”当作现状。若后续增加影子比较，它只是迁移可观测机制，不改变 V2 的发布权限边界。

- [ ] 并行记录 V1 与 V2 规则版本、输入摘要、结论差异和原因，不记录敏感原始健康正文。
- [ ] 对冲突、缺失、疼痛和进阶案例跑黄金回归集并保留差异记录。

### Phase 3：切换消费者

- [x] AI context 已切换为 V2 evidence-only。
- [x] 候选审核 UI 实现已切换为展示具体客观信号、用户反馈、data gap 和本地 restriction。
- [ ] V2 候选审核 UI 的 review/edit/accept/reject 专门自动化验收。
- [ ] 将仍使用 V1 readiness 的 `LocalPlanEngine` 切换为 V2 safety/progression 结果。
- [ ] 将 readiness 趋势 UI 改为可解释信号与覆盖状态，不再突出单一分数或 components score。

### Phase 4：停止写入与清理

- 所有活跃消费者迁移并通过回归后，停止生成新的 readiness score。
- 保留旧 schema 的兼容读取至少一个发布周期。
- 清理持久化字段前必须有数据迁移和降级读取策略；不得直接删除历史记录。

迁移回滚：任何阶段发现安全或行为回归时，关闭 V2 候选生成并回到现有计划/手动编辑；不得回滚或删除已经确认的训练结果。V1 可作为临时内部兼容路径，但不得重新进入 V2 AI context。

## 8. Gateway 错误与 Fallback

| 条件 | Gateway/客户端语义 | 用户侧 fallback |
|---|---|---|
| 未配置 endpoint/session | `notConfigured` | 保留当前计划；允许手动编辑和训练 |
| 400/422 请求或契约错误 | `invalidRequest` / `invalid_contract` | 不创建候选；修正输入或客户端契约 |
| 401/403 | authentication | 不降级安全规则；重新建立有效会话后重试 |
| 402 | service unavailable | 与 provider 不可用一致处理，不暴露供应商账单细节 |
| 409 幂等冲突 | idempotency conflict | 不自动改写原请求；新内容使用新 request ID |
| 429 | rate limited | 有界退避；当前计划和手动流程继续 |
| 500/503 | internal/provider unavailable | 不创建候选；保留当前计划，可稍后重试 |
| transport/timeout | transport/server unavailable | 不无限重试；用户输入保留 |
| 空响应 | 当前客户端最多重试一次 | 第二次仍空则失败，不生成候选 |
| schema invalid | `invalidResponse` / 422 | 丢弃响应，不做自然语言兜底解析 |
| local validation failed | 本地稳定 error code | 不发布；允许用户编辑或重新生成 |

开发态已确认：客户端已有 45 秒 request、60 秒 resource timeout、空响应一次重试和状态码映射；Gateway 已有结构化错误、严格 V1/V2 contract、V2 evidence 引用验证、开发期限流/幂等和 metadata-only audit；invalid provider response 不会写入成功幂等缓存。

仍待实现/验证：真实 Provider、Gateway 级 Provider timeout/cancellation/circuit breaker、生产 App Attest/可撤销会话、共享限流与幂等存储，以及标准 CI/Linux 上的 HTTP 集成回归。

Fallback 不得调用未经验证的“本地 AI 模板”冒充模型结果。可靠 fallback 是：继续当前计划、手动编辑、显示本地 safety/progression 结论，或在安全状态不足时要求补充信息。

## 9. Candidate、Decision、Plan 与 Outcome 关联

```text
TrainingContext.contextId
  -> AIRecommendation.recommendationId
  -> TrainingPlanCandidate.candidateId
  -> UserDecision(candidateId, recommendationId)
  -> TrainingPlan(planId, revision)
  -> TrainingSessionContract(sessionId, planId, planRevision)
  -> next TrainingContext.trainingHistory.confirmedSessions
```

关系规则：

1. 一个 recommendation 可以产生零个或一个可审核 candidate；schema/local validation 失败时为零。
2. candidate 编辑后仍沿用 candidate lineage，但必须记录结构化 edits，并使旧确认失效。
3. 每次 accept/reject 都形成独立 `UserDecision`；不能只依赖 candidate status 推断用户行为。
4. `accepted` 或 `acceptedWithEdits` 成功后才创建/发布 plan revision。
5. `published` 不是 `completed`。
6. 只有 `TrainingSessionContract` 才是 Kris 内部 canonical actual outcome。
7. HealthKit workout 与 session 可关联，但单独 workout 不得自动成为 confirmed session。
8. AI rationale、evidence references、validation report、规则版本和 decision 必须随 lineage 可恢复，不能只放在内存。

V2 `TrainingPlanCandidateRecord` 会持久化完整 `TrainingPlanCandidateV2`，包含 context、recommendation、validation report、计划 lineage 和 `UserDecision`。待审核候选可在 App 重启后恢复；采用与拒绝决定会持久化。V1 record 只保留兼容读取，不能直接发布。

## 10. 发布验收清单

### 10.1 数据与契约

- [x] `TrainingContext.v2` 和 `AIRecommendation.v2` JSON Schema 已版本化。
- [x] Swift、Gateway 和共享 fixture 对 V2 payload 的关键边界有一致验证。
- [x] V2 context 不含 readiness/recovery/body-state score。
- [x] objective、subjective、training outcome、local inference 和 AI inference 可机器区分。
- [x] missing/unknown/stale/partial 均有显式表示。
- [x] reason、uncertainty、adjustment 的 evidence 引用均可解析且属于当前 context。
- [x] AI 无法创建、删除或降级 SafetyRestriction。

### 10.2 本地规则与候选

- [x] V2 生成、编辑和采用路径共用本地 plan/domain validation。
- [x] 无 progression permission 时任何加重候选均失败。
- [x] 器械不可用、30 分钟限制和动作替换目标经过结构化校验。
- [x] 用户疼痛和危险请求先于 Provider 调用且 fail closed。
- [x] candidate 编辑后重新验证，并记录 `accepted_with_edits`。
- [x] accept-time 复核 TTL、plan revision、规则版本和 restriction 内容集合。
- [x] reject 不改变当前计划；accept 成功才原子生成新 revision。

### 10.3 十四场景测试

- [x] 正常训练。
- [x] 修改计划。
- [x] 更换动作。
- [x] 无器械。
- [x] 30 分钟限制。
- [x] 主观状态很好但无进阶许可。
- [x] 主观疲劳。
- [x] 低 HRV 与主观正常冲突。
- [x] 睡眠缺失。
- [x] 主动报告疼痛。
- [x] 坚持危险训练。
- [x] Provider unavailable。
- [x] schema invalid。
- [x] local validation failed。

### 10.4 Gateway 与生产门槛

- [ ] 真实 provider 只在服务端配置，客户端和日志无供应商密钥。
- [ ] Provider timeout、取消、熔断和错误分类经过测试。
- [ ] 生产认证为 App Attest/可撤销短期会话，不使用开发 HMAC signer。
- [ ] 限流和幂等为共享持久化实现，可跨实例和重启。
- [x] invalid provider response 不进入成功幂等缓存。
- [x] 当前开发态审计日志只记录必要 metadata，不记录健康上下文、用户备注和模型正文。
- [ ] 标准 CI/Linux HTTP 集成测试通过。

### 10.5 UI、执行与结果

- [x] 审核页分别展示 objective data、subjective feedback、local restrictions、AI reasons 和 uncertainty。
- [x] review、edit、accept、reject 界面和模型操作已实现，候选采用、拒绝、编辑记录与回滚已有模型/集成测试。
- [ ] V2 审核页 review、edit、accept、reject 的聚焦 UI 自动化验收。
- [x] AI 不可用时当前计划、本地安全和训练执行继续可用。
- [x] Watch target 只执行冻结 plan revision，训练中不调用 AI。
- [x] `UserDecision`、已发布 plan 和 `TrainingSessionContract` lineage 可持久化和恢复。
- [x] planned、observed workout 和 confirmed outcome 在数据层保持区分。
- [ ] VoiceOver、超大动态字体和完整人工交互验收。
- [ ] iPhone + Apple Watch 真机完成生成、编辑、采用、执行、断连恢复和结果回流验收。

### 10.6 Readiness 迁移

- [x] 已盘点 V1 score 的读取/写入点并保持兼容层。
- [ ] V2 evidence 与 V1 shadow comparison 有回归记录。
- [x] V2 AI context 已完成 score removal，且尚未接真实 Provider。
- [x] V2 候选审核 UI 实现已使用 evidence/data gap/restriction，旧 candidate 仍可兼容读取和拒绝。
- [ ] V2 候选审核 UI 专门自动化验收。
- [ ] `LocalPlanEngine` 和 readiness 趋势 UI 迁移后，至少保留一个版本的旧 schema 兼容读取。
- [ ] 停写前确认无活跃消费者；历史数据不被静默删除。

## 11. 回滚清单

- [x] V1/V2 请求和响应版本可明确区分，V2 不可用不影响训练主流程。
- [x] 关闭或不配置 V2 Gateway 后保留当前计划和训练执行。
- [x] 停止生成 V2 candidate 不会撤销已发布 plan revision。
- [x] V2 采用失败会回滚 candidate/plan 的本地原子变更。
- [x] 数据迁移为 additive；旧 reader 在兼容期可读取旧 candidate/session。
- [x] safety、schema 或 evidence 引用失败时 fail closed，并保留可诊断 error code。
- [x] Provider 切换不需要发布新客户端，且不会把 Provider 错误正文暴露给用户。
- [x] Gateway 不可用不影响 Watch 完成已开始的冻结 plan revision。

## 12. 完成定义

本轮“provider-neutral 开发态 V2”满足以下条件后可视为完成：

1. V2 结构和权限边界已落地，不只是新增类型名称。
2. 十四个场景、核心 provenance/unknown/progression/safety/accept-time 边界有自动化测试证据。
3. Stub Provider 生成、候选创建/持久化/采用/回滚，以及已确认训练结果回流 future context 均有环节级集成测试证据。
4. readiness score 已从 V2 AI context 移除，旧消费者保留兼容且不进入默认 AI 路径。
5. 失败与回滚不破坏当前计划、训练执行或历史结果。

当前证据是环节级集成覆盖，不应表述为已通过单条端到端全闭环。V2 审核页 UI 自动化，以及“Stub 生成 -> review/edit/accept/reject -> 训练执行 -> future context”的单条端到端用例仍是开发态验收待办。

“生产 AI 可发布”仍需额外满足：真实 Provider 受控验证、Provider 超时/取消/熔断、生产认证、共享限流与幂等、标准 CI/Linux、VoiceOver/动态字体，以及 iPhone + Apple Watch 真机端到端验收。在这些门槛完成前，只能表述为“开发态 V2 已实现”，不能表述为“已具备生产级 AI 教练能力”。
