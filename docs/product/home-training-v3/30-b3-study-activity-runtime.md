# B3 StudyActivity Runtime

Contract: `./00-contract.md`

## 范围
- P8a：Practice StudyActivity integration；
- P8b：MockExam StudyActivity integration；
- I1：Practice / Exam production composition。

## 前置
- P4b / CP2-A 已接受；
- P3b launch semantics 保持；
- B2 按当前串行 rollout 已完成。

## 主要 ownership
- PracticePage Activity wiring；
- MockExam Activity wiring；
- composition root / injection 中直接必要的 I1 路径；
- focused lifecycle/runtime regressions。

## Runtime 实施边界
- production composition 在 B0 startup recovery 与 DB ready 后构造唯一的
  PersistentStudyActivityService，并在首个 begin 前尝试 Activity startup recovery；
  restore recomposition 使用 fresh service 与 route scope，不复用旧 owner。
- system time adapter 使用 Stopwatch monotonic elapsed；同 mappingRevision 的
  UTC 必须严格由已发布 UTC anchor + monotonic delta 投影。wall jitter 不直接
  发布为 continuous sample；只有 wall/zone/rules discontinuity 或 calendar
  重新捕获才切换 revision 并使用新 raw wall anchor。engine 精确 invariant 不放宽。
- Practice launcher 显式传 ordinaryPractice / studyPlanPractice，Category review
  descriptor 为 I2 entry 准备；preview 不 begin。AnswerAttempt normal/focused 保持。
- 共用 route binding 管理 opaque owner、30 秒有界 checkpoint、background /
  retained temporary cover pause、同 owner resume 和 single-shot terminal。
  Photo cancel/error 与 dialog 取消恢复原 owner；queue terminal 为 queueFinished，
  true exit / dispose fallback 为 exited。
- MockExam durable submit 成功后才 submitted。early submit 失败后 Activity
  resume 且原 remainingSeconds countdown 继续；已归零的 force submit 失败
  保持 0，允许显式重试，不启动普通 countdown 或自动重复 submit。
- Activity failure 不阻断 answering / grading / FSRS / navigation / background
  exam grading；countdown 与 Pomodoro 仍是独立 authority，schema 保持 v31。
- B3 implementation 不等于 package closure 或完整 CP3；I2/I3 不在本包激活。

## 验收
- Practice 与 MockExam 使用同一已冻结 StudyActivity lifecycle/persistence authority；
- grading、queue、countdown、submit 与 FSRS 行为不回归；
- owner / pause / resume / terminal / process interruption 语义保持；
- 不引入第二套累计时长 authority；
- required standing CI PASS，Independent Reviewer APPROVE。

## Documentation responsibility
- `./00-contract.md`: CHECK_ONLY
- `ARCHITECTURE.md`: UPDATE
- `docs/architecture/shiroha-project-roadmap.md`: UPDATE
- `./30-b3-study-activity-runtime.md`: UPDATE
