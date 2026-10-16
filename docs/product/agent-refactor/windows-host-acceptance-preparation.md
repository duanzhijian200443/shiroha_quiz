# Windows Host acceptance preparation (G0-L0)

本文件是可复用的安全验收准备契约和申请模板，不是执行许可或路线图任务数据库。
主权威为 [readiness §§6、7、9.F、21](windows-host-security-readiness.md)；
身份/授权继续由 [external boundary §12](external-agent-boundary.md#12-p15-external-credential-boundary-offline-implementation-candidate) 和原有 P0/P12/P15/P8/P7 拥有。
冻结条件冲突时停止相关准备，不能用本模板替代原契约。

**HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED;
REAL WINDOWS = PENDING; FORMAL ACCEPTANCE = PENDING.**

最高准备状态只能是 **AR-R6A ACCEPTANCE PREPARATION READY**。
它表示证据分类、差距和可审查申请已备妥，不表示 Windows 安全或系统稳定性通过。
精确 Git/CI/Review 结果归属交付记录和原 PR，不把本文件的模板状态当作执行事实。

## 1. 证据分类与源码入口审计

| 分类 | 可证明的范围 | 不可推断的结果 |
|---|---|---|
| STATIC | 源码、格式、静态依赖、ABI/FFI 清单、来源可追踪 | OS 行为、原生释放、可运行的端到端入口 |
| OFFLINE | 公共向量、Fake I/O/native、合成 SQLite、确定性生命周期 | crypt32/CNG/DPAPI/NTFS/DACL、真实 TLS/进程/跨 SID |
| LOCAL-L1 | 固定设备/对象/版本上已授权的原语子集 | 完整 A 项、跨设备稳定性、业务权限 |
| LOCAL-L2 | 固定有界认证/连接子集 | P9/P10 业务、STAGE、正式发布 |
| INDEPENDENT-WINDOWS | 独立内核环境中精确批准并实际观测的 X/A 条件 | 未执行项目或漂移后的目标 |

下表是直接源码/测试索引，不表示本次重跑了整个 Package 1–3；
每次交付须另列实际命令、结果和未运行项。Executor 的证据审计不构成独立 Reviewer/Verifier 批准。

| 包/责任 | 已实现的边界与源码 | 离线证据 | 真实验证缺口 |
|---|---|---|---|
| Package 1 Credential | P21 DER/PKCS#8、P25 初始化/受限签发；[initialization](../../../lib/data/external/windows_credential_initialization.dart)、[crypto](../../../lib/data/external/native/windows_external_crypto.dart) | external_certificate_der、windows_external_crypto、windows_credential_initialization suites | CNG/crypt32 输出/加载、真实私钥资源生命周期；X.509 用 DER ECDSA-Sig-Value，自定义 Proof/Descriptor 用 raw r‖s |
| Package 1 Protected Store | P20/P23 共用 Owner/事务；[association](../../../lib/data/external/windows_credential_association_store.dart)、[objects](../../../lib/data/external/windows_credential_object_store.dart) | windows_external_native、association_object_codec、windows_credential_association_store、windows_credential_object_store suites | 当前目标下真实 DPAPI、Owner/DACL/NTFS/重解析、锁、Flush/替换/持久性、跨 SID |
| Package 1 Pairing | [P27](../../../lib/data/external/windows_pairing.dart) 原字节消费、独立人工比较/批准、P15/P0 完成、Missing-only kind 4 | windows_pairing、external_trust_coordinator、pairing_transcript_codec suites；公共向量数学运算 | 独立可信人工界面/准入、真实 App/Bridge 进程、私钥与已批准对象操作 |
| Package 1 Exchange/Discovery | [Exchange](../../../lib/data/external/windows_exchange_file_store.dart)、[Discovery](../../../lib/data/external/windows_discovery.dart) 的受控消费、签名/epoch/high-water | windows_exchange_file_store、windows_exchange_consumption、windows_discovery、bootstrap/discovery/exchange source guards | 真实父级/文件身份、消费/释放/共享、签名发布原子性与残留 |
| Package 2 TLS/Peer/P15 | [transport](../../../lib/data/external/windows_tls_transport.dart)、[channel](../../../lib/data/external/windows_tls_channel.dart)、[peer policy](../../../lib/data/external/native/windows_peer_certificate_policy.dart)；TLS → native role policy → protected identity → P15/P0 | windows_tls_transport、windows_peer_certificate_policy、windows_tls_source_guard suites | BoringSSL TLS 1.3/CertificateVerify、crypt32 真实拒绝、原生 TLS/Socket 释放 |
| Package 2 P9/P10/资源 | [resources](../../../lib/data/external/windows_tls_resources.dart)、[Host](../../../lib/data/external/windows_tls_host.dart)、原 P9/P10 编解码/投影 | ipc_envelope_codec、ipc_command_schema/projection、TLS budget/deadline/settlement fixtures | OS 缓冲/内存/句柄峰值、背压、原始 Future/实际关闭确认；Fake 预约量不是全进程内存 |
| Package 3 生命周期 | 同一 Host 的 owned/start/revoke/shutdown；Owner/lock 最后释放，未知释放保留 custody | windows_tls_lifecycle；原 P0/P12/P15/B0 tests | 真实竞争 Runtime、进程终止、Restore、跨进程释放与异常恢复 |
| Package 3 A8 | 原 P3 SQLite commit 后 Fake Channel 丢响应，新 P15 Session 用原 SubmissionKey 对账 | windows_tls_lifecycle 的 C2/A8 fixtures、原 STAGE/P8 tests | 真实通道精确响应切断；业务测试只属 G0-I |
| Package 3 发布候选 | [inventory/PE](../../../lib/data/external/windows_release_candidate.dart)、[Bridge source entry](../../../tool/external/bridge_candidate.dart) | windows_release_candidate；纯 PE bytes、Fake loader、递归依赖审计 | 完整插件/CRT 部署闭包、AOT、真实冷启动/升级/异常启动 |
| Native ABI-3 | [header](../../../windows/external_native/shiroha_external_native.h)、[FFI](../../../lib/data/external/native/external_native_bindings.dart) | 27 符号源清单；既有 check_offline 编译/导出/导入/Fake CTest gate | 静态源匹配不等于当前产物匹配，更不是 DLL 真实调用结果 |

历史实测必须保留其原限定：readiness §12 记录过一次隔离 P20 根上的
A/B 发布、DPAPI 和读回观察。它不覆盖 Package 1–3 完整组合、当前目标、生产根、跨 SID、崩溃或 G0-I。
本准备不重新读取该根或原始私有记录，不声称获得独立完整 Windows 证明。
Batch 1/2 不能给 Host A Batch 3 带来继承许可。

### 实际可执行入口

- `WindowsTlsHost.owned` 构造不获取 OS Owner、不绑定网络；它接收已经获取的 Owner，
  核对同一 P25/P26/P27/P20/P15/P12 组合并占用一次 claimRuntime。
  `start()` 才观察 P8 Ready、准备凭据、绑定、确认 P26 发布。其显式调用仍需要真实实验许可。
- `tool/external/bridge_candidate.dart` 参数无效返回 64，合法空参数返回 78/
  `externalHostActivationPending`。它不是完整 Windows 验收 Bridge。
- `OwnedHarness` / `TlsHarness`（windows_tls_lifecycle/transport tests）使用 Fake listener/channel/native、
  公共签名向量和合成 SQLite。可复用确定性测试思想和端口，不能直接改成真实设备执行器。
- `windows/external_native/diagnostics/l1_crypto_probe.h` 与 `l1_crypto_probe.cpp`（由默认关闭的
  `SHIROHA_L1_CRYPTO_CANDIDATE_BUILD` 编译为 `shiroha_l1_crypto_candidate.exe`）提供 `L1-CRYPTO`
  专用短生命周期原生候选：物理排除 `native_windows.cpp`、`protected_objects.cpp`、`protected_windows.cpp`
  及所有 Store/Exchange/Discovery/Owner 翻译单元，仅链接 `crypt32`/`bcrypt`/`psapi`；通过 7 符号白名单门禁
  拒绝其余 20 个 ABI-3 导出，内建 1/3/3/6(3 正+3 负)/3 同步预留账本、单次释放槽位与 18 点资源采样。
  其入口 `l1_crypto_candidate_entry` 在 E0 固定拒绝真实运行（`l1_crypto_execution_not_authorized`，exit 10）；
  CTest 仅注册纯 Fake 的 `shiroha_l1_crypto_probe_offline`。
- 当前未提供通过批准的隔离根、仅认证无业务路由的真实 TLS 可执行 Composition；
  也未提供 G0-I 的真实 App/Bridge、可信人工 Pairing、合成 DB/B0 与操作员组合。
- 构建、部署、启动、停止/销毁是分别授权的动作；编译成功或静态 inventory 不授权启动。
  当前 L0 不构建/安装/运行 App/Bridge Release/AOT，也不调用现有诊断执行器。

## 2. A0–A12 / X0–X12 正式矩阵

机器可检查的完整记录为 [acceptance plan](windows-host-acceptance-plan.json) 的 `matrix`。
每行包含 frozenCriterion、windowsTrial、success、source、offlineTests、依赖、局部层级和责任。
环境统一引用 `environment`，负责人统一引用 `ownership`，失败/STOP 统一引用 `failurePolicy`，
这些是每一行的必填字段而非可省略默认值。所有完整 A 项都必须保持 **WINDOWS_PENDING**，
直到对应固定目标 G0-I 实证和独立判定具备；局部 L1/L2 成功不更改它们。

共同目标环境：用户另选、独立内核的受控 Windows 候选，首轮建议 Windows 11 x64，
实际 Edition/Build/Patch/架构/SDK/Flutter/Dart/MSVC/CMake/lockfile 必须另冻。
普通本机 VM 不自动合格；Windows 10 servicing、Arm64、其他打包模型须单独决定。
每行证据负责人、非特权操作员、固定目标 Verifier、独立 Reviewer 均为 **REQUIRES USER DECISION**。
业务语义和原生资源分别由原服务和设备观察负责，不由传输层重造权威。

| A / X | 冻结验收条件及量化成功标准（完整条件见 §7） | 必要 X 前置 | 当前离线证据 | 剩余真实实验 / 局部层级 | 状态 |
|---|---|---|---|---|---|
| A0 / X0 | Actual local address exactly 127.0.0.1, selected port, shared=false; reject wildcard/LAN/IPv6/configuration substitution and unprotected publication. Measure actual bound address and publication acknowledgement; mismatches have zero usable admission. | X1, X3 | `windows_tls_transport_test.dart`, `windows_tls_lifecycle_test.dart`, `windows_discovery_test.dart` | 仅 G0-L2 的 §6 明确子集；完整 X0 需 G0-I | WINDOWS_PENDING |
| A1 / X1 | Fresh real possession proof resolves exactly one selected Profile; duplicate identity, substitution and generation mismatch resolve none; X2/X4 correlate the same TLS peer. One active association per identity/Profile; all substituted/duplicate cases open zero Sessions. | X3 | `windows_pairing_test.dart`, `windows_credential_initialization_test.dart`, `windows_credential_association_store_test.dart` | 仅 G0-L1 的 §6 明确子集；完整 X1 需 G0-I | WINDOWS_PENDING |
| A2 / X2 | Valid control succeeds only under exact pinned anchor and TLS 1.3; missing/forged/wrong-anchor/wrong-role/expired/retired/replayed credentials yield no usable Session, handler or content. One valid control; every named negative rejected; negotiated TLS version 1.3, zero TLS 1.2 success and zero fallback. | X0, X1, X3 | `windows_tls_transport_test.dart`, `windows_peer_certificate_policy_test.dart`, `windows_external_crypto_test.dart` | 仅 G0-L2 的 §6 明确子集；完整 X2 需 G0-I | WINDOWS_PENDING |
| A3 / X3 | Unauthorized second SID cannot read/alter/replace/delete/redirect protected objects; reject inheritance/reparse/parent replacement/corruption; never silently rekey. All protected negative attempts denied; original sentinel identities/content unchanged; zero silent rekeys. | Approved object design / candidate inventory | `windows_external_native_test.dart`, `windows_credential_object_store_test.dart`, `windows_credential_association_store_test.dart`, `windows_exchange_consumption_test.dart` | 仅 G0-L1 的 §6 明确子集；完整 X3 需 G0-I | WINDOWS_PENDING |
| A4 / X4 | Unauthorized SID may connect but receives no business data; independently provisioned second-SID client follows current Profile/Grant/Scope/Egress/Enablement. Positive synthetic READ/STAGE follows exact approved policy; every denied path has zero handler/content release. | X0, X1, X2, X3, X6, X7_PRIMITIVE | `windows_tls_transport_test.dart` | 无 L1/L2 业务替代；完整 X4 需 G0-I | WINDOWS_PENDING |
| A5 / X5 | No old Session/Context/Enablement or withheld egress revives after disable/revoke/expiry/rotation/restart/Restore/raw rollback; fresh proof and rebinding required. Zero resurrection; failed revoke CAS never recorded as success; history may remain while authorization stays disabled. | X4, X7_SETTLEMENT | `windows_tls_lifecycle_test.dart`, `windows_pairing_test.dart` | 仅 L1 测试凭据 invalidation/reload、L2 正常连接关闭；不证明业务生命周期；完整 X5 需 G0-I | WINDOWS_PENDING |
| A6 / X6 | Reject zero/high-bit/over-limit/unsupported header and invalid ID before declared body allocation; safe close without resync or weaker limits. Declared-body allocation and handler count both zero for every invalid header/ID; channel closed. | X0, X1, X2, X3 | `ipc_envelope_codec_test.dart`, `windows_tls_transport_test.dart` | 无 L1/L2 业务替代；完整 X6 需 G0-I | WINDOWS_PENDING |
| A7 / X7 | Frozen reservations and deadlines hold for fragmented/coalesced/slow/cut/cancelled traffic; resources released only after original work and acknowledged close settle. 8 sockets/2 handshakes/2 pipelines; 16 MiB protocol/32 MiB strings/512 KiB output; 5/2/10 s deadlines; no premature reuse; measured OS ceilings separately frozen. | X0, X1, X2, X3, X6; settlement additionally X4 | `windows_tls_transport_test.dart`, `windows_tls_lifecycle_test.dart` | 仅 G0-L2 的 §6 明确子集；完整 X7 需 G0-I | WINDOWS_PENDING |
| A8 / X8 | Commit then cut response; fresh admitted Session reconciles original SubmissionKey to same Proposal; no restage/duplicate/formal Question COMMIT. Revoke-first publishes none; publication-first retains history without unauthorized egress. Exactly one original Proposal after lost response, zero duplicate/formal Question writes; unknown remains unknown until original-key reconciliation. | X4, X5, X6, X7_SETTLEMENT | `windows_tls_lifecycle_test.dart`, `ipc_command_projection_test.dart` | 无 L1/L2 业务替代；完整 X8 需 G0-I | WINDOWS_PENDING |
| A9 / X9 | App absent/not-ready/closed/recovering is bounded unavailable/denied; packaged Bridge never opens business SQLite, repositories/migrations or replacement writer. Zero business-DB opens/writes in Bridge audit; all unavailable cases settle inside separately approved deadline. | Approved object design / candidate inventory | `windows_release_candidate_test.dart` | 无 L1/L2 业务替代；完整 X9 需 G0-I | WINDOWS_PENDING |
| A10 / X10 | Keep exactly ten internal external routes and six read-only MCP v0 tools; external COMMIT/DESTRUCTIVE/Built-in denied; no vNext registration. 10 external routes, 6 MCP v0 READ tools; zero added tools/forbidden routes; any stdio process test separately granted. | Approved object design / candidate inventory | `ipc_command_projection_test.dart`, `ipc_command_schema_test.dart` | 无 L1/L2 业务替代；完整 X10 需 G0-I | WINDOWS_PENDING |
| A11 / X11 | Second live runtime neither binds/publishes/serves nor writes Store; close/startup races/crashed predecessor/replacement never delete foreign objects. Ambiguous custody denies and retains residue. At most 1 live runtime/writer; zero interleaved Store transactions or foreign sentinel changes; unknown release keeps lock/admission quarantined. | X3, X7_SETTLEMENT | `windows_tls_lifecycle_test.dart`, `windows_discovery_test.dart`, `windows_exchange_consumption_test.dart` | 仅 L1 owned-lock contention/正常释放、L2 正常 Socket close；无崩溃/竞争 Host/foreign attack；完整 X11 需 G0-I | WINDOWS_PENDING |
| A12 / X12 | Exact non-elevated App/Bridge AOT package works from space/Unicode roots with sanitized environment; cold-start/upgrade/abnormal-close and invalid-artifact rejection; stale endpoint/leaf/high-water and same-generation successor cases. All inventory/hash/ABI/x64/Release dependency checks pass; invalid DLL/Store/Anchor denies before Owner; successor accepted without re-enrollment; old endpoint cannot impersonate. | X1, X2, X3, X4, X5, X6, X7_SETTLEMENT, X8, X9, X10, X11 | `windows_release_candidate_test.dart`, `windows_tls_lifecycle_test.dart` | 仅 L1 另授 primitive-only helper 的空间/Unicode 路径加载；不含 App/Bridge 启动；完整 X12 需 G0-I | WINDOWS_PENDING |

X7 必须分两段，避免循环依赖：X0–X3 → X6 → **X7_PRIMITIVE** → X4 →
**X7_SETTLEMENT** → X5/X8。X9/X10 仍需自己的候选产物/回归和单独运行许可；
X11 需 X3 与 X7，X12 在 X1–X11 完成且打包模型冻结后进行。
保守完整顺序见 JSON dependencyOrder。L2 不能运行 X6 帧测试、X4 业务、X8 STAGE 或 X7 业务结算。

### 固定失败分类与 STOP

以下是脱敏验收记录的类别，**不新增或替代生产 ExternalFailure/P15/Native 状态**。

| Code | 条件 / 处理 |
|---|---|
| ADMISSION_BLOCKED | 缺设备、授权、独立审查、入口、对象清单或前置证据；不启动 |
| TARGET_DRIFT / ENVIRONMENT_DRIFT | 源码/产物/设备/依赖/重要环境改变；受影响证据失效，重新冻结和审查 |
| OWNERSHIP_UNKNOWN | Owner/SID/父级/对象身份或句柄归属不明；保留对象，关闭准入 |
| SECURITY_REJECT_MISMATCH | 预期拒绝未发生、错误地址/证书/授权通过；停止，不补救性回退 |
| UNAUTHORIZED_ACCESS | 越出批准的对象、操作、业务或正式数据；停止并由恢复负责人处置 |
| BUDGET_EXCEEDED | 任一批准资源/时间上限超出；停止新工作，不能把超时当作已终止 |
| MEASUREMENT_UNAVAILABLE | 峰值/句柄/真实关闭观测不完整；INCONCLUSIVE，不得用 Fake 值填补 |
| SETTLEMENT_UNKNOWN / COMMIT_UNKNOWN | 原 Future/关闭/持久化效果未明；保留 custody、原 Key 与 UNKNOWN，不重试/重发 |
| ARTIFACT_INVALID | hash/PE/ABI/依赖/Store/Anchor 不符；保持禁用，不修复或自动重建 |
| SYSTEM_ANOMALY | 蓝屏、硬挂、驱动/内核异常、异常提权/系统修改；停止，不在主机复现 |

任何失败先阻断新准入；响应正常的已批准设备上等待原 Owner 工作结算，再做已授权 teardown。
卡死设备只允许预先批准的恢复操作员/镜像流程；本模板不授权强杀。
禁止自动重试、扫目录、放宽 ACL/共享、提权、清正式 Store 或终止无关进程。
安全性与系统稳定性的判定分别记录；两者都不能由一条局部 PASS 代替。

## 3. 共同申请封面与准入字段

JSON `environment` 与每份 `requests` 合并后构成申请草案。
所有 **REQUIRES USER DECISION** 都是未决输入，不能被检查器通过解释为准入通过。
设备/路径/账户/权限/操作员不能从当前开发机、环境变量或旧实验记录自动选择。

每份申请必须在实际授权前补齐：

- 用户明确选择的设备、所有者、独立性证据（G0-I）、时间窗口和非特权执行方式。
- OS Edition/Build/Patch、架构、toolchain/lockfile，准确 Source/Base SHA 与全部产物 SHA-256。
- 独立于正式 Shiroha/Provider/个人数据的 NTFS 空测试根；具体允许的目录/文件/锁/凭据身份清单。
- 精确操作、次数、大小、进程和端口；固定最大执行时长、OS 内存/句柄及协议资源上限。
- 备份/恢复/清理负责人及恢复镜像/操作步骤，STOP 时如何处理尚未结算资源。
- 每对象清理权限/次数与归属验证；未批准删除时只允许保留惰性残留。
- 固定目标 Verifier、独立 Reviewer、预期判定/脱敏结果格式与该次明确用户许可。

申请中的数字是待审查的上限候选，**不是已授权负载或经测量可行的值**。
未定的 OS 内存/句柄值保持 REQUIRES USER DECISION；没有完整数值/观测方法不得开始。

### G0-L1 四份最小原语申请候选

| 草案 | 依赖、精确操作候选 | 时限候选 | 对象/边界 |
|---|---|---|---|
| L1-CRYPTO | `l1_crypto_probe` 隔离候选与 Fake 门禁已就绪（G0-L0），待固定目标独立源码审查及单次授权；3 次临时 P-256 key generation、3 个证书 encode/sign、6 次验签（3 正/3 改动）、3 次 crypt32 profile 检查；每资源仅一次正常释放 | 30 秒 | 仅限 7 个白名单导出；三组内存测试 issuer/server/client，不装全局信任根，不写正式凭据；证书签名 DER、自定义签名 raw |
| L1-OBJECTS | 新根与 §9.D 精确目录逐个一次创建（具体清单/总数 REQUIRES USER DECISION）；App acquire 1、竞争 acquire 1 次预期拒绝、Bridge acquire 1；每对象最多两次安全/身份观察；新目标发布 1、替换 1、读回 2 | 60 秒 | runtime.lock、bridge/client.lock、批准的一个对象/一个临时文件；无第二 SID/攻击/崩溃；隔离诊断 seam 需另行实现审查 |
| L1-STORE | CRYPTO/OBJECTS 通过；protect 2/unprotect 2（每次 ≤65536 bytes）；association begin ≤3、commit ≤2、abort ≤1；每批选定一种 Store kind | 60 秒 | App kind 1/2/3 或 Bridge kind 4 是候选范围；具体 kind、导出调用账本和对象清单必须另冻，不能一个批次隐含覆盖全部 |
| L1-RELEASE | 前述精确对象；每尚持有资源正常 close 一次；工作前、每操作后、结算后采样；最终 metadata capture 只有明确纳入授权才允许一次 | 30 秒 | 无重试/强杀/崩溃/清扫；删除列表、身份/次数与预算 REQUIRES USER DECISION |

四份申请共同的设备/根/OS/产物/资源上限/负责人/窗口都尚未选择，
状态 **DRAFT_NOT_AUTHORIZED**。有上限不表示必须完成这些调用；首个异常立即减少后续操作至零，
只保留原契约准许的单次安全释放。下层 Native 调用可能阻塞，候选时限不是硬终止保证。
Store 候选在实际执行器审查时需把上层操作展开为精确原生调用数，不能跳过任何准入字段。

### Host A Batch 3 独立阻断

只可静态阅读 [diagnostics contract](../../../windows/external_native/diagnostics/README.md#host-a-preparation-candidate)。
旧根非空例外、metadata capture、runtime identity handoff、supervisor 生命周期裁定、真实调用是分别审批的动作。
当前 Runner/Native gate 拒绝真实执行；metadata snapshot 不是持续身份绑定。
历史名字/大小不证明当前 File ID/volume/Owner/DACL；原 Batch 1/2 不授权读取或清理旧对象。
本轮不执行 capture、freeze runner、supervisor、旧根检查或任何诊断真实模式。
该路线保持 **BLOCKED**；新根候选也不能被用来绕过这条旧根专属规则。
Readiness §12 仍明确保留历史 supervisor P2-2 为 OPEN：G0-L0 的
start/identity 修复不能自行替代独立 Reviewer 闭合，receipt/holding/expiry 的
生命周期候选亦待裁定。最小后续范围是对该固定源码修复独立复核和有界契约裁定，
不是获准执行 metadata capture、持有 Worker 或运行 Batch 3。本包不修复该历史路径。

## 4. G0-L2 连接申请草案

前置：必要的真实 LOCAL-L1 固定目标结果通过，精确 helper/transport/隔离连接组合经过独立源码审查；
设备、端口、证书/测试根和产物 hash 固定，再取得单独 L2 用户许可。
同一源码的 L0/Fake 结果不满足真实 L1 依赖。
仅一条固定数字 IPv4 127.0.0.1 监听候选、明确端口、shared=false，不接受 LAN/wildcard/IPv6/远程配置。

| 资源 | 第一轮冻结候选上限 |
|---|---:|
| Socket | 8 |
| Pending Handshake | 2 |
| Active Pipeline | 2 |
| 协议预约 | 16 MiB |
| 解码字符串预约 | 32 MiB |
| 输出队列 | 512 KiB |
| Handshake | 5 秒 |
| 无进度 | 2 秒 |
| Frame 总期限 | 10 秒 |
| 每连接请求 | 1（L2 实际发送业务请求数为 0） |

L2-AUTH 候选总时限 120 秒，7 个顺序证书场景各一次握手：有效、缺失、伪造、错误 Anchor、
错误角色、过期、已退役；另有 TLS 1.2 floor 拒绝一次，共最多 8 次，不自动重试。
成功标准：正例仅认证连接；负例零 usable Session/业务 handler/content，TLS 1.2 零成功。
零 P9 frame、P10 路由、READ/STAGE Context、公开工具或 App DB。
2 pipelines/预约与 frame 时间是不得扩大之上限，不授权 L2 运行帧/业务负载。

OS 观测候选：记录操作前、每握手/拒绝后及最终结算后的 process peak working set/commit、
当前与采样最大 handles；跟踪每个真实 Socket、TLS upgrade Future、Native certificate context、
subscription 和 TLS context 的归属与实际关闭确认。OS backlog/native TLS buffers 不等同于 Dart 预约，
采样 handle 最大值不等于精确 OS high-water，SDK/GC key copies 不声称已即时清零。
需要另行审查 observer/sampler 与采样完整性；不能从现有 Fake 推导真实数值。
缺少可观测释放路径则 MEASUREMENT_UNAVAILABLE/SETTLEMENT_UNKNOWN，保留 custody，停止后续用例。
OS 内存/句柄上限、环境、operator、端口、清理范围均为 REQUIRES USER DECISION。

## 5. G0-I 独立 Windows 正式申请草案

环境尚未批准，保持 **BLOCKED**；本文件不默认指定当前本机或普通本机 VM。
需要独立内核的 Windows 设备/远程 Windows 主机，两个一次性不同 SID 的本地 Principal，
独立 NTFS 空根、只含合成内容的 SQLite/B0、可恢复镜像/操作员流程、精确 App/Bridge AOT/
Native DLL/plugin/CRT/资产与 toolchain/lockfile hash 清单。
建账户/权限准备、构建、安装、运行、终止/崩溃注入、恢复和清理各有精确独立授权范围。

G0-I-FORMAL 的 600 秒只是每次有界申请的时限候选，不是全 X0–X12 的批准或可行性断言。
每项操作次数、进程、对象、空间/Unicode 包路径、资源上限和观察时间尚需用户决定。
以下分类必须展开成每 case 的账本后才可申请：

| X | 必须列明的实际可授权动作与数量/资源 |
|---|---|
| X3 → X1 | 两 SID 对每对象 read/write/replace/delete/redirect 拒绝；独立信任人工 Pairing、唯一身份/重复/替换；每动作次数 REQUIRES USER DECISION |
| X0 → X2 | 实际固定 bind/publication、地址替换拒绝；完整证书/Proof replay/retired/expiry 矩阵；ports/connections/trials REQUIRES USER DECISION |
| X6 → X7 primitive | 原 header/ID 极值、fragment/coalesce/slow/cut/deadline、OS 资源/实际释放；每输入大小/次数及 OS ceilings REQUIRES USER DECISION |
| X4 → X7 settlement | 跨 SID 合成 Grant 正负权限、READ/STAGE 精确 scope/egress、取消/关闭后的原 owning work；次数/对象 REQUIRES USER DECISION |
| X5 | Disable/Revoke/Expiry、client/server rotation、restart、B0 Restore/raw rollback；每转换次数/副本/恢复权限 REQUIRES USER DECISION |
| X8 | 精确 durable commit 后切响应，fresh Session 用原 Key 对账、revoke 两种顺序；次数/切断点 REQUIRES USER DECISION |
| X9/X10 | 真 Bridge 的 absent/not-ready/closed/recovering 与 synthetic-DB access audit；10-route/6-tool 兼容，stdio 启动另列；次数 REQUIRES USER DECISION |
| X11 | 两 Runtime/Store-writer 排斥、启动/关闭竞争、受控终止/替换、foreign sentinel；每进程/终止/对象操作次数 REQUIRES USER DECISION |
| X12 | 精确 AOT 构建/部署、冷启动/升级/异常关闭，wrong/missing DLL/ABI/Store/Anchor、stale descriptor/retired leaf/high-water 和同 generation successor；每动作次数 REQUIRES USER DECISION |

安全验收记录与系统稳定性记录分开；形式 PASS 需对应每行冻结条件和量化指标均有真实证据。
Administrator/kernel/same-SID arbitrary code 隔离、品牌/进程真实性、CRL/OCSP 不在冻结承诺内，
不能以拒绝所有跨 SID 连接替代 B-class 正例。所有 A 项仍 WINDOWS_PENDING。

## 6. 真正的源码/环境缺口与最小后续范围

这些是准入缺口分类，**不是已确认的 P0/P1/P2 生产漏洞列表**。
本轮没有授权通过新增默认激活代码填补它们。

| 分类 / 缺口 | 类型、阻断范围、最小另授范围与复核 |
|---|---|
| MUST_FIX_BEFORE_L1：设备/空根/权限/预算/恢复/角色未选 | 环境/操作授权；补齐共同封面和精确调用账本，再固定目标独立 Reviewer/Verifier，不得推断当前主机获准 |
| MUST_FIX_BEFORE_L1：完整原语隔离入口 | `L1-CRYPTO` 原生隔离候选（`l1_crypto_probe.h`/`.cpp`，`L1-CRYPTO HARNESS SOURCE READY / OFFLINE TESTED`）已在 E0 具备默认拒绝门禁、7 符号白名单、`dumpbin` 物理依赖隔离与 Fake CTest，仍需独立 Reviewer 源码审查及用户单次授权方可开启真实调用；`L1-OBJECTS`/`L1-STORE` 的新空根隔离执行器仍待另授实现与审查 |
| MUST_FIX_BEFORE_L1（仅 Host A Batch 3 路线） | 旧根专属契约/实现：非空例外、metadata approval、runtime identity bridge、supervisor lifecycle ruling 分开解决；不读旧根，也不通过重写生产 recipe 规避 |
| MUST_FIX_BEFORE_L2：真实连接专用 Composition | 源码/入口；另授隔离 Owner/证书/Discovery + 明确原生 I/O 的测试执行器，只认证/连接、无 P9/P10/DB/公开工具；L1 实证和独立源码审查先行 |
| MUST_FIX_BEFORE_L2：真实 Socket/Handle/TLS 观察 | 测量/源码接口候选；现有 budget.used、whenConnectionsSettled、whenSettled 是显式预约/owning barrier，不是 OS 测量；另审 observer、真实释放确认、未知释放隔离及数值 ceilings |
| MUST_FIX_BEFORE_G0-I：App/Bridge 与可信人工 Pairing | 源码/测试准入；disabled Bridge 不能执行完整 X9/X12；另授真实隔离组合和独立可信人工比较/批准，沿用 P0/P15/P27，无替代业务写入器，生产入口继续禁用 |
| MUST_FIX_BEFORE_G0-I：独立设备/两 SID/SQLite/B0/恢复 | 环境/权限；不把普通主机 VM、Fake 或局部 L1/L2 换算成正式验收 |
| MUST_FIX_BEFORE_G0-I：Release/AOT 部署与异常启动 | 构建/执行授权和产物闭包；另授 App/Bridge Release/CRT/plugin inventory/hash、受控启动/异常恢复，静态 PE 不是部署证明 |
| MUST_FIX_BEFORE_G0-I：X5/X12 Anchor Rotation 分支 | 冻结规格缺口；§9.A.6 要求旧 issuer 签名 record，但 record bytes/domain/version/replay/持久化提交尚未冻结且无实现。另授最小格式/生命周期契约 + 实现/离线/独立复核后才验证此分支；显式 re-enrollment 仍可用，却不能冒充已通过该 rotation 分支 |
| DEFERRED / NOT_BLOCKING：主动 Discovery 删除 | §21 保留惰性 Endpoint/Anchor/Installation/temp 与 §9.D/A11 的“只能删已证归属对象”相容，不要求成功删除。实际残留/新旧 epoch/单活与 sentinel 安全仍须 X11/X12；若未来要求删 Endpoint，另授 opaque publication pin + conditional identity delete，不能当前新增路径清扫 |
| DEFERRED / NOT_BLOCKING：生产多用户 provisioning、same-SID/Admin 加固、AR-R6B | 冻结排除/未授权后续，不把这些扩展为本包源码修复 |

若后续只读审计发现真实 P0/P1/P2，停止受影响交付，记录最早失败边界，提出独立最小修复和固定目标复核；
不扩大本包去重构安全层、改 Native ABI/生产授权/持久化格式或削弱验收。

## 7. 最小证据格式与漂移

每个实际结果必须包含 JSON evidenceFields：Test/Trial/case ID，Source/Base SHA、Artifact SHA-256，
OS/toolchain/设备脱敏 ID，预期条件、实际状态、资源计数/单位/观测精度、耗时、固定 Failure Code，
Verifier/Reviewer/判定、STOP 与恢复结果。另记证据等级、同一原 SubmissionKey 的不透明关联 ID
（不能完整披露 Key），以及系统稳定性独立判定。
状态仅 NOT_RUN/BLOCKED/PASS/FAIL/INCONCLUSIVE/UNKNOWN；PASS 只适用于实际执行且完整覆盖的命名子集。
预期负例的拒绝是该 case 的成功，不能忽略副作用或释放失败。

禁止私钥、完整 Credential Blob/PEM、TLS key log、Provider Secret、完整 Prompt/Answer/用户文档/题库、
未脱敏路径/环境变量、含敏感数据的内存转储；不上传原始进程日志或异常正文。
只用固定阶段/类别、计数、时间和公共摘要引用；Source manifest 不应读取私有数据或旧实验根。
安全操作员所需的精确路径/对象身份清单只放在另行批准的受限申请，公开证据使用别名。

Source/Artifact/Device/dependency/重要环境漂移使受影响 PASS 失效；不得只改报告里的 SHA 来复用结果。
Review 与 fixed-target Verifier 重新检查适用目标，PR 必须另过 current-head/current-base standing CI。

## 8. G0-L0 检查器与交付边界

`pwsh -NoProfile -File tool/external/check_acceptance_readiness.ps1 -SelfTest`
只读取固定仓库 JSON、文档存在性、源码/测试与 standing manifest；负例仅在内存克隆中修改。
检查 A/X 完整性、分阶段依赖、必填字段、WINDOWS_PENDING/未授权状态、固定预算、STOP/恢复字段、
Host A 阻断、27 个 ABI header/FFI/既有编译 gate 源符号匹配和引用 suite 的唯一 CI 注册。
它不加载 DLL、不看设备/测试根、不生成执行器、不运行子进程/网络、不写文件。
PASS 仅表示结构检查通过；不验证自然语言充分性、人工批准真实性、真实内存/释放或当前 CI 成功。
新增检查器尚未注册 standing CI；独立 Reviewer 必须审阅 JSON/文档与主契约是否语义一致，
未来纳入 CI 需要明确 CI 修改范围。已有 standing manifest 验证独立运行，不声称它自动执行新工具。
若按当前范围交付 PR，由于新增 PS 检查器/负例尚无 standing-CI 硬失败覆盖，
须插入独立固定目标 Verifier 复跑检查器及负例；若未来获准纳入 standing CI，
则按实际覆盖重新判断是否还存在此确定性验收缺口。真实 Windows 验收仍另需独立 Verifier。

Native 编译/导出检查可沿用现有 check_offline gate；只修改准备材料/PS 时无须重编 Native 或
伪称运行 Flutter/Dart analyze/format。本次是否实际重跑 Package tests/Source Guards/manifest、
以及未运行的 Native/AOT/runtime 检查必须在交付记录如实报告。

当前 Executor 可完成 D1–D4 的 G0-L0 准备后停下；Git staging/commit/push/PR/merge 均另授。
非平凡 PR 需最终目标 standing PR contract checks 与独立 Reviewer；确定性准备检查之外的真实 Windows
验收必须有独立 fixed-target Verifier。本文件本身不制造任何独立批准，也不启动下一阶段。
