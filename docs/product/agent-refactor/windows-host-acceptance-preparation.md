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
  CTest 只注册 Fake 目标，包括 `shiroha_l1_crypto_probe_offline`、
  `shiroha_l1_crypto_observation_offline` 和 `shiroha_l1_crypto_admission_offline`，
  不注册真实候选。
- 当前未提供通过批准的隔离根、仅认证无业务路由的真实 TLS 可执行 Composition；
  也未提供 G0-I 的真实 App/Bridge、可信人工 Pairing、合成 DB/B0 与操作员组合。
- 构建、部署、启动、停止/销毁是分别授权的动作；编译成功或静态 inventory 不授权启动。
  当前 L0 不构建/安装/运行 App/Bridge Release/AOT，也不调用现有诊断执行器。

## 2. A0–A12 / X0–X12 正式矩阵

E2 准入加固补充（G0-L0）：`l1_crypto_admission.h` 提供纯 OFFLINE 的
GrantTarget、FakeGrantCell、OfflineSupervisor 与 OfflineEvidence；
`l1_native_observation.h` 只在诊断构建中观察原 RAII 的底层返回和资源结算。
完整 ABI 尝试预算为 `1+3+3+6+3+45+45=106`，最多 5 个同时存活 Buffer；
失败/返回空值/抛异常的 Allocation 都消耗尝试，释放不重置累计预算。
底层显式调用表与唯一释放规则见 Native diagnostics README；正常路径观察
47 个 CNG/crypt32 资源，失败释放保留 UNKNOWN/隔离，不能由 void buffer-free
正常返回或采样句柄数推导完整释放。Windows 内部不可见分配不在观察承诺内。

Supervisor 模型从实验进程开始尝试计 30 秒，在截止点拒绝新工作；
已进入的同步原语不可被安全取消，超时不等于退出或结算。Fake Supervisor
要求独立 observer 记录和原有 18 点采样，不能只相信 Worker 的 PASS/exit=0。
保留进程启动/结束观察、工作完成数、OS peak bytes 和采样句柄数；没有实测
精度或精确 handle high-water 声明。真实 Working Set/Commit/Handle ceiling
仍为 REQUIRES USER DECISION，任何未设限的未来真实申请必须拒绝。

单次授权模型绑定全部目标、身份、Hash、编译器/OS、操作/预算、窗口、用户批准、
独立审查/验证及 STOP/恢复/Evidence 责任；Fake 消费在启动尝试前发生，
失败、过期、目标不匹配或未知回执均不重置。复制/重启 Fake 不证明真实单次性。
真实 Windows 身份证明、权限保护的持久记录、跨进程原子消费、进程创建、
可信 IPC/observer、独立时钟/STOP、证据 I/O 和产物闭包尚未实施，必须另授。
此包不选择账户/根目录/真实预算/时间窗口/责任人，不创建实验目录，不触碰 Host A。
`kRealExecutionAuthorized=false`，E0 入口持续无条件拒绝，CLI/环境变量/配置
不产生真实通道。最高范围为 L1-CRYPTO ADMISSION SOURCE HARDENED / OFFLINE TESTED；
所有真实实验和正式验收仍待单独授权。Evidence 仅 OFFLINE/FAKE，无私钥、
PKCS#8、PEM、完整证书、原始环境/路径或异常正文。
Native gate 在构建缓存中生成独立 STATIC Hash 清单（源码、工具、EXE、SDK/OS
及直接依赖名），标明 WORKING_TREE_NOT_FROZEN / executionAuthorized=false。
该清单不是获准运行产物或完整部署依赖闭包；最终源码提交、产物和真实加载
依赖的固定目标审查仍是未来申请前置条件。

### E3 Windows 单次准入源码候选（仅 G0-L0）

E3 新增 `l1_windows_admission.h` 与 `l1_windows_operations.h/.cpp`，
承接上述 E2 唯一 GrantTarget/GrantState、OfflineSupervisor、ABI 和 Native 资源账本。
E2 “没有真实适配源码”的历史描述由本节补充；最高范围为
**L1-CRYPTO WINDOWS ADMISSION SOURCE PREPARED / OFFLINE TESTED**。

- Windows API 叶子源码仅编译为未链接 OBJECT 库：精确 SID/非提权 Primary Medium Token
  与启用权限、句柄 File ID/C: NTFS/Owner/受保护单 Owner ACL/非重解析/单链接、
  LockFileEx 条件烧录和 Flush，以及进程 peak/采样句柄/真实退出观察。均未调用。
- 完整后端仍拒绝可信批准、身份准入和进程启动；消费在 I/O 前返回 UNKNOWN。
  单独烧录叶子即使 Flush 成功也只返回 UNKNOWN，未实现可信发行和独立持久请求日志，
  不声称真实跨进程、断电或重启单次性。普通 JSON 的批准布尔值无效。
  若选择签名凭据，签名者/验证密钥/信任边界/保管方式先独立冻结，本次不生成可信密钥。
- Fake 使用共享内存持久模型、独立请求门闩和互斥 E2 Cell，覆盖竞争、客户端重建、
  消费后崩溃、回执丢失及写入失败 UNKNOWN。它不等于真实 Windows 持久化证明。
  复制对象字节不能复制独立身份/批准/日志；不宣称防御恶意同 SID 进程或管理员。
- Worker、消费者、Supervisor 绑定相同批次/设备/账户/Source/Base/EXE/依赖/工具链及范围。
  Worker port 不接收任意命令行/环境。未来挂起创建、真实 Token/image 复核、认证 IPC、
  显式句柄/环境与恢复仍为 STOP；没有可运行的真实 Worker 启动器。
- 状态保留 NOT_STARTED、GRANT_CONSUMED、START_ATTEMPTED、RUNNING、STOP_REQUESTED、
  SETTLING、COMPLETE、SETTLEMENT_UNKNOWN、BLOCKED；独立记录消费请求与启动尝试。
  30,000 ms 恰好截止关闭新工作，不终止同步 Native 调用。Supervisor/Native 双向停止门闩
  及逐原生操作超时清理已纳入 Fake 必要条件，真实异常/缺失/未结算证据不能 PASS。
  候选禁止复制和移动，共享 Fake 请求记录在启动前保留唯一额度，失败/异常/未知回执不恢复。
  COMPLETE/SETTLEMENT_UNKNOWN/BLOCKED 的状态、首次失败和完整证据快照不可被迟到事件改写；
  STOP_REQUESTED/DEADLINE_EXCEEDED/SETTLING 仍可合法释放和结算。接受退出后立即关闭新工作，
  正常退出进入结算，异常退出 STOP，退出不证明 Native 结算。控制器事件及观察必须串行，
  Fake 覆盖 EXIT/STOP/SAMPLE 排列与经同一串行边界的并发生产者；这不证明真实跨进程能力。
- 证据仅 OFFLINE/FAKE：E2 18 点样本和计数、脱敏身份/Hash、发行/消费/启动/退出、
  STOP/恢复及独立判定字段；Verifier/Reviewer 初始 NOT_RUN。无 raw SID/路径/环境、
  私钥/证书/进程日志；未提供获准的证据 I/O。

以下全部继续为 **REQUIRES USER DECISION**：精确新根/文件/对象清单、设备、非提权 SID/Token、
实验窗口、Working Set/Commit/采样句柄上限、STOP/恢复/证据负责人、可信批准来源、
持久请求日志方案、进程/IPC/句柄/环境计划及最终目标 Reviewer/Verifier。仅 C: 为候选卷；
本次不创建或检查任何真实测试根，不复用 Host A。

将来真实运行还须独立实现/审查可信发行与日志、父链/产物固定和 IPC/启动，
并逐项授权安全对象、锁、文件持久化/证据 I/O、进程创建/观察/正常关闭、可选 Job；
强制终止、Crash Injection 和系统恢复不在本候选权限内。
冻结方式：另授提交后从精确 Source/Base 重编译，记录 EXE、实际直接依赖与工具链 Hash、
SDK/OS/配置和完整加载闭包，再取得相同目标独立批准；任意漂移失效。
当前 STATIC manifest 为 WORKING_TREE_NOT_FROZEN，依赖名不是依赖 Hash。
离线不能证明真实跨进程持久性、ACL/身份竞争、调度/IPC、未采样句柄或 Windows 内部资源。

`executionAuthorized=false`，L1-CRYPTO DRAFT_NOT_AUTHORIZED，A0–A12 WINDOWS_PENDING；
原入口继续无条件拒绝，Source Guard 和 Fake PE 审核先于 CTest，所有真实叶子均不注册执行。
具体叶子能力、STOP 与授权清单见 [diagnostics README](../../../windows/external_native/diagnostics/README.md#windows-admission-candidates-e3-source--compile--fake-only)。

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

### G0-L1 五份独立原语申请候选（R6A-B1 统一离线基础设施）

| 草案 | 依赖、精确操作候选 | 时限候选 | 对象/边界 |
|---|---|---|---|
| L1-ADMISSION | 无前置 L1；零 CNG/crypt32 密码学调用（ABI=0、Native=0）；复用 E4/E5 两步人工确认、CREATE_NEW 256B receipt/1B grant/128B journal（6 次写入/Flush、1 次条件 burn）、单次挂起创建、Token/映像/依赖校验、Resume 1 次、64B IPC（44/3 帧上限、18 点采样、24 段零密码学结算）、正常退出观察与各持有句柄 1 次关闭 | 30 秒 | `l1_b1_admission_worker.cpp` 独立无密码学 Worker 候选（不得用 Crypto Worker 冒充）；五阶段账本（consume/create/resume/ipc/close）与六状态进程生命周期；未退出/未知保留 Custody 与人工交接 |
| L1-CRYPTO | L1-ADMISSION 独立通过 + 新批次授权；ABI 1、Generate 3、Encode/Sign 3、Verify 6（3 正/3 改动）、Policy 3、Allocation/Free 各 45，合计 106；最多 5 个 Buffer 同时存活，47 个直接 Native 资源，每资源一次释放尝试 | 30 秒 | 仅限 7 个白名单导出；三组内存测试 issuer/server/client，不装信任根或写正式凭据；证书 DER、自定义签名 raw；收到 ADMISSION 前零密码学操作 |
| L1-OBJECTS | L1-ADMISSION 独立通过 + 新批次授权；新根与 §9.D 精确目录逐个一次创建（具体清单/总数 REQUIRES USER DECISION）；App acquire 1、竞争 acquire 1 次预期拒绝、Bridge acquire 1；每对象最多两次安全/身份观察；新目标发布 1、替换 1、读回 2 | 60 秒 | `B1ObjectsDiagnostic`；`runtime.lock`、`bridge/client.lock`、批准的一个对象/一个临时文件；检查 C: NTFS volume/File ID、Owner SID、受保护单 ACE DACL、父目录身份、非重解析、硬链接数；未知归属保留不删，禁用 Host A 与正式根 |
| L1-STORE | L1-ADMISSION、L1-CRYPTO、L1-OBJECTS 独立通过 + 新批次授权；protect 2/unprotect 2（每次 ≤65536 bytes）；association/store begin ≤3、commit ≤2、abort ≤1；每批仅选定单一 Store kind（1、2、3 或 4） | 60 秒 | `B1StoreDiagnostic` + `StorePrimitiveLedger`；复用 P18/P20/P21/P23 既有格式与 CAS/create-if-missing；不建第二套 DPAPI 存储；不得把 App kind 1/2/3 与 Bridge kind 4 混入同批；展开底层原语调用账本并擦除临时敏感缓冲 |
| L1-RELEASE | 前述已授权试验精确对象；每已登记唯一 Owner 的资源仅允许 1 次释放尝试；工作前、每操作后、结算后采样；最终 metadata capture 只有明确纳入授权才允许一次 | 30 秒 | `B1ReleaseLedger`；STOP 不阻止其他独立 Owner 合法释放；释放失败不重试；Void 返回不证底层释放、CloseHandle 不证进程退出、超时不证同步调用终止；无所有权证明禁止删除；无重试/强杀/崩溃/清扫 |

五份申请共同的设备/根/OS/产物/资源上限/负责人/窗口都尚未选择，
状态 **DRAFT_NOT_AUTHORIZED**（`executionAuthorized = false`）。有上限不表示必须完成这些调用；首个异常立即减少后续操作至零，
只保留原契约准许的单次安全释放。下层 Native 调用可能阻塞，候选时限不是硬终止保证。
每种实验均有独立 Operation Allowlist（`operation_allowed_for_trial`），CRYPTO 授权绝不顺带允许 OBJECTS 或 STORE 操作。

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
| MUST_FIX_BEFORE_L1：完整原语隔离入口 | E0/E2 基础上，E3 增加未链接的 Windows 叶子源码与 E2 Supervisor/Fake 持久模型衔接；可信批准、发行/独立持久日志、父链/实际产物固定、进程/IPC/独立真实 STOP 仍为 STOP。源码/产物须独立审查并取得逐项及单次批次许可；见本文件 E3 节。`L1-OBJECTS`/`L1-STORE` 新空根执行器仍待另授 |
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
两个检查器已由 `windows/external_native/check_offline.ps1` 接入 standing CI：该脚本在
`pr-contract-checks.yml` 的 `windows_native` 作业内无条件执行
`check_l1_windows_source.ps1 -SelfTest`（15 个源码隔离负例，含 B1 Admission-only 无密码学守卫）与
`check_acceptance_readiness.ps1 -SelfTest`（51 个计划负例，含 E4、E5 及 B1 五份统一申请负例），任一失败即
throw 使作业红。因此这些确定性检查已有硬失败覆盖，不再触发"另插固定目标 Verifier"的条件；
独立 Reviewer 仍须审阅 JSON/文档与主契约的语义一致性，未来调整覆盖范围需明确 CI 修改范围。
CI 的独立 `impact` 影子观察作业另行无条件执行 Bootstrap、上述两个 `-SelfTest` 及
standing manifest/分类器回归检查；观察建议尚不用于跳过任何现有验证作业。
其失败、取消或跳过同样阻断最终汇总，Native 中原有调用继续保留。影子报告不构成测试
PASS 的跨 Head 复用证据，也不改变 WINDOWS_PENDING 或授予实验许可。
已有 standing manifest 验证独立运行，不声称它自动执行新工具。真实 Windows 验收
仍另需独立 fixed-target Verifier。

Native 编译/导出检查可沿用现有 check_offline gate；只修改准备材料/PS 时无须重编 Native 或
伪称运行 Flutter/Dart analyze/format。本次是否实际重跑 Package tests/Source Guards/manifest、
以及未运行的 Native/AOT/runtime 检查必须在交付记录如实报告。

当前 Executor 可完成 D1–D4 的 G0-L0 准备后停下；Git staging/commit/push/PR/merge 均另授。
非平凡 PR 需最终目标 standing PR contract checks 与独立 Reviewer；确定性准备检查之外的真实 Windows
验收必须有独立 fixed-target Verifier。本文件本身不制造任何独立批准，也不启动下一阶段。

### E5 two independent single-trial applications

以下是可审批的单次申请模板，**均未授权**，不是可执行任务包。
E5 的接线及冻结格式由
[diagnostics E5](../../../windows/external_native/diagnostics/README.md#e5-controlled-diagnostic-composition-g0-l0-only)
及 [readiness E5](windows-host-security-readiness.md#e5-controlled-diagnostic-admission-composition-g0-l0)
拥有。在 B1 统一基础设施收口后，最高源码范围为 **R6A-B1 L1 UNIFIED SOURCE READY / OFFLINE TESTED**
（承接 **E5 CONTROLLED ADMISSION SOURCE READY / OFFLINE TESTED**）。
E0/E3/E5 Windows 运行门禁继续拒绝，Controller/Worker 只编译为未链接 OBJECT；
不得以改 E0 返回值、CLI、环境变量或普通 JSON 批准布尔值开启运行。

| 必填冻结字段 | Trial 1 / Trial 2 的审批要求 |
|---|---|
| 当前 Windows 设备、Edition/Build/Patch、x64、内部精确 SID、Token | 待用户确认并另授只读实测；必须为非提权 Primary / Medium，启用权限仅允许遍历检查；现有设备/OS 字符串不是独立身份实测 |
| 精确新目录 | 各批独立、全新、未存在的 C: NTFS 目录，待用户确认；不得复用历史 Host A 或生产目录；未授权探测/创建 |
| 固定对象清单 | 每批一个目录；其内仅 `approval.receipt` 256 B、`grant.bin` 1 B、`request.journal` 128 B；两条匿名管道、一个 Worker 及其主线程；借用并保留父链/EXE/依赖 pins；Evidence 默认仅内存返回，不写文件 |
| 精确 Batch ID | 每批独立的安全 ID，待用户确认；失败、UNKNOWN、崩溃或重启均废弃，不重发同一批次 |
| Worker 和 Controller/UI 的 WS / Commit / Handle 上限 | 六个数值均待用户确认；不沿用 64 MiB / 128 Handles 示例。方法候选：`GetProcessMemoryInfo` 的 PeakWorkingSetSize / PeakPagefileUsage，`GetProcessHandleCount` 的点采样；方法及采样次数上限也须批准 |
| 实验窗口 | 每批独立 UTC 起止，待确认；消费及启动须至少剩余 30000 ms；候选工作从唯一启动尝试起最多 30 秒，不因握手延迟续期 |
| STOP、恢复、清理、Evidence 负责人 | 四项姓名/安全 ID 均待用户确认；恢复文档 Hash、人工交接确认方式、借用 pins 的最终关闭职责必须独立冻结 |
| Source / Base / EXE / 依赖 / 工具链 | 待单独授权 Git 交付后固定 Source/Base Git 身份、源码清单 SHA-256，重编译并固定 Controller、对应 Worker、全部实际依赖及工具链 SHA-256、SDK/配置；当前 working-tree STATIC manifest 不是冻结产物，依赖名不是依赖 Hash |
| 固定目标 Verifier / Reviewer | 两个独立身份及匹配本批 Source/Base/产物/环境的判定记录 Hash，均待指定；Executor 自检不替代独立批准 |

**Trial 1 — L1-ADMISSION，独立申请，默认拒绝。**
仅验证上述新对象上的身份、发行/WAL/单次消费、进程创建和观察、IPC 及正常结算。
B1 已在 `l1_b1_unified.h` 与 `l1_b1_admission_worker.cpp` 中补齐独立的
`admission_only_worker_candidate` 与未链接 `OBJECT` 目标 `shiroha_l1_b1_admission_worker`
（**不链接、不调用 CNG/crypt32 密码学实现**，物理禁止将 Crypto Worker 重命名冒充）。
沿用现有 Grant/Journal/六类诊断帧，机制结算报告单独判定（ABI=0、Native=0、18 点采样、
24 段零密码学结算、五阶段账本与六状态生命周期），不能伪造 106 次调用或原 Supervisor 的 Crypto PASS。
不得调用生产 Store、网络、App、Bridge、DPAPI、证书 Store 或密码学原语。

若目录建立和随后运行需要不同许可，同一次 Trial 1 申请分两项授权：

1. **1A 对象准备/只读冻结**：批准的精确新目录 CREATE_NEW 最多一次，仅给该
   目录设置一次已批准的 Owner/DACL；读既定父链/产物和 Token，记录实际 File ID、
   volume、Owner/DACL/Hash。所有读取/临时句柄次数上限由固定产物审查列明后批准。
   目标存在、未知、漂移或需修改父级 ACL 即 STOP；不发行 Grant、不启动 Worker。
2. **1B 单次准入**：仅在 1A 目标复核通过后批准。两步人工审批一次；三个固定
   文件各 CREATE_NEW 最多一次；发行/消费/启动顺序合计精确写入和 Flush 各最多六次
   （receipt 1、grant 2、journal 3），条件 burn 一次及 Lock/Unlock 各一次；
   挂起创建最多一次、Resume 最多一次；两条管道、最多 44/3 帧；只对已确认退出的
   Worker 进程/线程各关闭一次，三个记录和四个管道端的已取得句柄各关闭一次。
   观察/校验用的临时句柄、采样/轮询和借用 pins 的关闭总次数必须在固定目标操作清单
   中补齐再批准；UNKNOWN 关闭不重试。Controller/UI 自身启动也须在本次许可中列明。

1A 不授权 1B。审批尚未冻结的次数不视为无上限许可；任一字段未定时不得发出可执行批准。
禁止强杀、Kill-on-timeout、崩溃注入、重启恢复、删除/覆盖记录或自动重试。
挂起残留/未知创建/卡住原语/未退出即保留 PID、process/thread custody，通知指定
人工操作员并 STOP；未获批准的恢复操作只能另请授权，不能用 CloseHandle 推导退出。
清理只在实测结算且所有者确认后进行，删除实验目录/记录仍需用户明确授权。
独立 Verifier 核验本批身份、写入顺序、消费一次性、实际退出及关闭证据，Reviewer
判定通过后才能满足 Trial 2 的前置；Fake 竞争不是 NTFS/断电持久性证明。

**Trial 2 — L1-CRYPTO，第二份独立申请，默认拒绝。**
仅在 Trial 1 完成、独立证据判定通过，且用户针对新的精确 Batch/目录/窗口再次明确
授权后，才申请 E5 Crypto Worker 的一次启动。复用已验证的准入机制；重新冻结
本批全部参数和 1B 中每类真实 OS 操作及次数，不继承 Trial 1 的授权。
只允许既有七个 ABI 符号：ABI 1、Generate 3、Encode/Sign 3、Verify 6（3 正/3 改动）、
Policy 3、Allocation 45、Free 45，总计 **106 次 ABI 尝试**；最多 **5** 个同时存活
Buffer、**47** 个直接 Native 资源、**18** 点采样、**30000 ms** 候选工作期限。
Native 各类别尝试上限仍为机器计划的 `nativeAttemptBudget`；每个 owner 只释放一次。
首次异常停止新工作，失败不自动重试；正常退出不代替 IPC/Native/句柄结算。
未知释放/未返回调用/进程未退出保留 UNKNOWN 和人工交接，不增加终止权限。
无生产 Store、网络、App/Bridge、信任根安装或正式凭据；只处理内存测试键/公开证书。

**Trial 3 (`L1-OBJECTS`)、Trial 4 (`L1-STORE`)、Trial 5 (`L1-RELEASE`) — 独立申请，默认拒绝。**
B1 在 `l1_b1_unified.h` 中同时补齐了 `B1ObjectsDiagnostic`（60s，App/Competing/Bridge
acquire 1/1/1、每对象观察 ≤2、发布 1、替换 1、读回 2）、`B1StoreDiagnostic` +
`StorePrimitiveLedger`（60s，单批单一 Store kind 1/2/3/4、Protect/Unprotect ≤2、
数据 ≤65536 B、Begin ≤3、Commit ≤2、Abort ≤1）和 `B1ReleaseLedger`（30s，每唯一
Owner 最多 1 次释放尝试、STOP 允许其他独立 Owner 释放、无所有权证明禁删），并在
`windows-host-acceptance-plan.json` 的 `requests[0..4]` 中冻结五份独立申请模板。
任一试验获批均不自动解锁下一项试验。

最小真实准入阻塞：必填参数及操作次数尚未批准；无已审查固定运行入口/实测身份与新目录
pin 交接；Source/EXE/依赖未冻结；人工恢复/清理和借用句柄交接方案、独立目标
Verifier/Reviewer 未指定。解除这些阻塞仍需分别授权 Git 交付及真实试验，不能把
E5/B1 编译/Fake 成功当作启动许可或新增通用研发阶段。

HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED;
REAL WINDOWS = PENDING; FORMAL ACCEPTANCE = PENDING.

### E4 local-human single-use admission source candidate (G0-L0)

E4 supplements, and does not retroactively change, the E2/E3 source boundary.
The diagnostic-only `l1_e4_admission.h` / `l1_e4_protocol.h` compose the same
GrantTarget, OfflineSupervisor, ABI ledger and NativeObservation. Full durable
wire/hash/persistence/custody rules are owned by
[diagnostics README E4](../../../windows/external_native/diagnostics/README.md#e4-local-human-admission-candidate-g0-l0-only).
The machine plan indexes this slice under `requests[0].windowsAdmission.e4`.

Pre-approval validity, independent review readiness, human confirmation and
issuance stay separate. A versioned length-prefixed LE target hash excludes
the derived user-approved flag and later object IDs; the second hash binds that
target to measured directory/receipt/grant IDs. Missing/drifting IDs STOP.
Only a matching two-step local-human response can reach issuance; it is not
strong authentication against malicious same-SID automation. No signing/test
key or JSON/CLI/environment flag provides authority.

The receipt is 256 bytes, write-ahead journal 128, marker one byte. CREATE_NEW
request reservation and locked conditional burn precede launch. Sequential
WriteFile/Flush operations are not one multi-file atomic transaction and prove
no power-loss durability. Unknown/partial/existing records and lost receipts
never restore or reissue a Batch. Restarted controllers cannot resume approval.

UTC alone validates the approved window, monotonic time alone drives the
Supervisor and Worker from the same actual launch-attempt origin (30000ms).
UTC much greater than monotonic is valid; rollback, invalid source, session
change or >1000ms relative drift rejects. A delayed handshake earns no time.

Diagnostic IPC has six message types and 64-byte LE frames. ADMISSION explicitly
contains handles/Working Set/Commit. Positive partial reads accumulate exactly
one frame; incomplete EOF/timeout/malformed sequence rejects. Settlement uses
24 parts with all seven ABI and fourteen NativeOp six-field u32 CallCounts,
all declared scalar counters, clocks, STOP/UNKNOWN/first-failure fields and
checksum. Maximum Worker/Controller frames are 44/3, combined 3008 bytes.
Missing data never PASS; independent controller observations still govern time,
resource ceilings, process identity and actual exit. Worker exit zero is insufficient.

Suspended creation, token/image/dependency checks, fixed environment/explicit
inherited pipe handles, UI and journal Windows leaves are SOURCE/COMPILE only
in the unlinked OBJECT library. Actual creation is distinct from work admission;
Resume failure/unknown cannot retry. Created-process failure keeps UNKNOWN
custody; CloseHandle is not termination. Controller crash may leave a suspended
child. Exact recovery/retention/handle-close and any required termination authority
remain hard prerequisites for real L1, never automatic actions.

All real Worker/Controller/UI memory/Commit/sampled-handle ceilings and valid
measurement methods remain REQUIRES USER DECISION. 64 MiB/128 handles are only
unverified synthetic examples. No approved numbers/method means DENY. This
local-human mode records a design choice, not permission to launch its UI or
create a new C: experiment root. No Host A access/reuse or production activation.

Eligible source description after actual passing checks is E4 ADMISSION SOURCE
IMPLEMENTED / OFFLINE TESTED, never REAL WINDOWS TESTED or LOCAL-L1 PASS.
The original real entry and integrated backend remain unconditionally closed;
CTest runs only Fakes. Real device/object/security/IPC/crypto behavior, OS recovery
and formal acceptance remain pending; all future real actions require exact
separate batch scope.

HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED;
REAL WINDOWS = PENDING; FORMAL ACCEPTANCE = PENDING.
