# B1 TaskCenter Backend

Contract: `./00-contract.md`

本文件是历史已完成 package，正常任务选择只看文件名即可跳过，不需要读取正文。

## 范围
- P5a：v31 ImportTask current-attempt event timestamps；
- P5b：TaskCenter facade、completed-only cleanup、retry-selection compatibility adapter；
- CP2-I acceptance。

## 已确认交付事实
- fixed implementation head: `f94b8baef4892ed540e19ee81e08cc5694ee8407`;
- standing PR CI: PASS；
- independent T3 verification: PASS；
- PR #227: MERGED；
- runtime schema: v31。

历史初审在 Verifier 前给出 INCONCLUSIVE，但未发现 P0/P1/P2；随后 T3
Verifier 在同一 fixed head PASS。用户已明确把 B1 视为完成项，本轮文档
重构不重新开启其实现或验收。

## 保留边界
TaskCenter UI、I3 production composition、Home/configuration UI 均不属于 B1。
