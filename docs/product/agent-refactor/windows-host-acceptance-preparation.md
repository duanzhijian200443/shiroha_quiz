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
| L1-OBJECTS | L1-ADMISSION 独立通过 + 新批次授权；新根与 §9.D 精确目录逐个一次创建（具体清单/总数 REQUIRES USER DECISION）；App acquire 1、竞争 acquire 1 次预期拒绝、Bridge acquire 1；每对象最多两次安全/身份观察；新目标发布 1、替换 1、读回 2 | 60 秒 | `B1ObjectsDiagnostic`；`runtime.lock`、`bridge/client.lock`、批准的一个对象/一个临时文件；必须提交批准根的 Volume/File ID 并在 `begin` 时与注入 seam 实测身份比对（路径黑名单仅为补充），发布/读回 kind 为必填批准项（1 或 2，`REQUIRES USER DECISION`）；检查 C: NTFS volume/File ID、Owner SID、受保护单 ACE DACL、父目录身份、非重解析、硬链接数；未知归属保留不删，禁用 Host A 与正式根 |
| L1-STORE | L1-ADMISSION、L1-CRYPTO、L1-OBJECTS 独立通过 + 新批次授权；protect 2/unprotect 2（明文字节 ≤65024，ABI 缓冲上界 65536）；credential（kind 1/2/4）或 association（kind 3）begin ≤3、对应 commit ≤2、对应 abort ≤1；每批仅选定单一 Store kind（1、2、3 或 4） | 60 秒 | `B1StoreDiagnostic` + `StorePrimitiveLedger`；同样绑定批准根身份；复用 P18/P20/P21/P23 既有 native CAS/create-if-missing 事务（`SHREXOBJ` 帧在 native 之上的既有编解码层，不属 B1-D 范围）；不建第二套 DPAPI 存储；不得把 App kind 1/2/3 与 Bridge kind 4 混入同批；展开底层原语调用账本并擦除临时敏感缓冲 |
| L1-RELEASE | 前述已授权试验精确对象；每已登记唯一 Owner 的资源仅允许 1 次释放尝试；工作前、每操作后、结算后采样；最终 metadata capture 只有明确纳入授权才允许一次 | 30 秒 | `B1ReleaseLedger`；STOP 不阻止其他独立 Owner 合法释放；释放失败不重试；Void 返回不证底层释放、CloseHandle 不证进程退出、超时不证同步调用终止；无所有权证明禁止删除；无重试/强杀/崩溃/清扫 |

五份申请共同的设备/根/OS/产物/资源上限/负责人/窗口都尚未选择，
状态 **DRAFT_NOT_AUTHORIZED**（`executionAuthorized = false`）。有上限不表示必须完成这些调用；首个异常立即减少后续操作至零，
只保留原契约准许的单次安全释放。下层 Native 调用可能阻塞，候选时限不是硬终止保证。
预算上限与 PASS 完成性分开判定：OBJECTS 不允许关闭 DACL 检查，批准对象集合须非空，
每个批准对象至少成功完成一次安全/身份/父目录观察，并完成锁/发布/替换/读回步骤；
发布对象还须单独绑定批准的对象 ID、kind 和父目录 Volume/File ID。其两次观察只能来自
既有 native 事务对实际发布/替换目标的校验，不能由另一借用 Handle 的观察替代。
写入前核对批准父目录，替换前核对前次发布身份，读回核对当前发布身份；原子替换允许
File ID 按已验证的临时对象到发布对象链路变化。内部诊断证据不改变导出 ABI 或运行许可。
STORE 须成功结算 Protect 2、Unprotect 2、Begin 3、Commit 2、Abort 1 及 Owner 释放。
零工作量或部分完成不得 PASS。两者的根探测句柄在身份不匹配时仍登记并只关闭一次，
关闭失败保留 UNKNOWN custody，不重试。
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
`pr-contract-checks.yml` 的 `windows_native` 作业内执行
`check_l1_windows_source.ps1 -SelfTest`（含 B1 Admission-only 及 R1 入口/托管/证据隔离负例，数量以实际输出为准）与
`check_acceptance_readiness.ps1 -SelfTest`（含 E4、E5、B1 及 B2 共同冻结/恢复/证据负例；数量以实际输出为准），任一失败即
throw 使作业红。该作业现由影响计划调度，但任何验收材料、Source Guard、Native 源码或
`tool/external/` 变更都会要求它执行；因此这些确定性检查仍有硬失败覆盖，不再触发
"另插固定目标 Verifier"的条件；
独立 Reviewer 仍须审阅 JSON/文档与主契约的语义一致性，未来调整覆盖范围需明确 CI 修改范围。
CI 的独立 `impact` 作业另行无条件执行 Bootstrap、上述两个 `-SelfTest` 及
standing manifest/分类器/复用/聚合回归检查，并生成按影响范围调度验证单元的固定计划。
`windows_native` 仍执行上述两个检查器；由于验收计划与准备指南的唯一消费方是
`check_acceptance_readiness.ps1`，其修改只会映射到该 Native 作业，而不会映射到不读取
这些文件的 Contract shards。最终 `Changed Dart and focused contracts` 聚合作业重新读取
计划、绑定当前 Head/Base、重算分类并核对 GitHub 结果，缺失、损坏或与计划不一致时失败；
不再有"只观察、不调度"的影子阶段。跨 Head 复用只在可证明输入等价时成立，不是测试 PASS 缓存，
也不改变 WINDOWS_PENDING 或授予实验许可。
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
acquire 1/1/1、每对象观察 ≤2、发布 1、替换 1、读回 2、发布 kind 必填批准、批准根
Volume/File ID 与注入 seam 实测绑定）、`B1StoreDiagnostic` +
`StorePrimitiveLedger`（60s，单批单一 Store kind 1/2/3/4、Protect/Unprotect ≤2、
明文 ≤65024 B（ABI 缓冲上界 65536）、Begin ≤3、Commit ≤2、Abort ≤1、同样绑定批准根）
和 `B1ReleaseLedger`（30s，每唯一
Owner 最多 1 次释放尝试、STOP 允许其他独立 Owner 释放、无所有权证明禁删），并在
`windows-host-acceptance-plan.json` 的 `requests[0..4]` 中冻结五份独立申请模板。
任一试验获批均不自动解锁下一项试验。

最小真实准入阻塞：必填参数及操作次数尚未批准；无已审查固定运行入口/实测身份与新目录
pin 交接；Source/EXE/依赖未冻结；人工恢复/清理和借用句柄交接方案、独立目标
Verifier/Reviewer 未指定。解除这些阻塞仍需分别授权 Git 交付及真实试验，不能把
E5/B1 编译/Fake 成功当作启动许可或新增通用研发阶段。

HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED;
REAL WINDOWS = PENDING; FORMAL ACCEPTANCE = PENDING.

### B2 fixed-target applications and STOP-1 (G0-L0)

B2 复用上节五份申请和同一机器计划的 `requests[0..4]`，共同参数只在
`l1Preparation` 定义、由各申请的 `preparationRef` 引用。它不是新的审批数据库、
运行配置或授权接口。填写参数、检查器 PASS、人工 UI、B1 合并均不发行真实许可。
存在以下源码阻塞时，结论必须是 **B2-L1-ADMISSION BLOCKED**；本节可交付供审查的
首次申请草案，但不能签发可执行批准。当前轮次必须 STOP-1，后续也不得自动开始 CRYPTO。

#### 入口核对与最小源码阻塞

下表保留 B2 首次静态审计的历史边界；R1 的接线源码、端口及剩余实机阻塞以
下文 **B2-R1 diagnostic wiring amendment** 为准，不把已补齐的 Fake 接口继续称为不存在。

| 边界 | 已有能力与尚缺的必要接口 |
|---|---|
| Admission Controller/Worker | `b1::UnifiedAdmissionController` 包装原 E5 Controller，可组合原 E4 GrantFlow/IPC/E2 Supervisor；`b1::admission_only_worker` 是独立无 Crypto 解析器/调用的候选。CMake 仍仅生成 E5 Windows、Crypto Worker、B1 Admission Worker 的未链接 OBJECT；没有 Controller/Admission EXE、`wmain` 或固定目标装配入口。不要增加一个只会返回拒绝的 EXE 冒充完成实测接线。 |
| 执行信任边界 | `WindowsPlatform::runtime_allowed()` 固定 false，E0/E3/B1 默认拒绝保留。需要单独审查的单批固定入口/授权边界；CLI、环境、JSON 或 Fake Approval 不能授予执行权。Worker 如何接收并核验同一不可变 FixedTarget 仍需入口装配；最终 EXE Hash 不能靠编译进它自身形成自引用冻结。 |
| 系统/工具链身份 | `WindowsPlatform::inspect_target` 会核对 Token、父链、映像及依赖 pins；但 `WindowsPins.observed_device_id/observed_os_id` 是调用方标签。GrantTarget 绑定 compiler/toolchain 摘要，并不实测编译器。缺少选定设备的实际 OS/设备证据、构建证明及受审查的 pin 获取/保留/交接组合；不能自动拿当前 SID 或字符串当用户选择。 |
| 人工发行顺序 | 原 Controller 先检查目标和资源，显示完整摘要/输入后缀，复核同一目标和人工响应，才调用原 `GrantFlow::issue`。这条顺序可复用；真实 UI、文件和单次性均未验证。不能合成勾选或把模板参数解释为批准。 |
| 创建失败与 Custody | Win32 `CreateProcessW` 返回失败且未取得子进程时，不宣称存在可清理 Worker；管道/记录等已取得资源各由原 Owner 保管。创建成功后的 Token/映像/依赖/Resume/HELLO 失败，由 `WindowsPlatform.custody_` 持有原 process/thread；进程未退出不能关闭后宣称结算，更不能再 Resume。创建结果未知时只保留可证归属，不能猜 PID。 |
| Controller 崩溃 | `WindowsPlatform::handoff` 仅设置内存标志，没有外部托管者确认/持久证据写入；`SuspendedWorkerCustody` 无析构清理。Controller 消失会失去其内存句柄；不能称其仍持有可供人工使用的 HANDLE。现有 128B Journal 记录启动请求/时间/Hash，不含创建后 PID/创建时间/进程身份。缺少在允许创建前就可用的外部人工 Custody 及崩溃证据交接，故不能安全声称人工可识别残留。 |
| 证据保存 | `e5::Evidence` 仍为 OFFLINE/FAKE 的内存快照。没有 LOCAL-L1 受审查结果导出/脱敏/批准输出适配；`FixedScope::inventory` 明确 external-evidence:0。不能仅重命名证据等级。外部人工记录或新持久输出的目的地、写入次数、所有者和保留方式须先冻结；新增 I/O 必须纳入原 scope/摘要，不改 E4 记录格式。 |
| OBJECTS/STORE/RELEASE | 原 B1 专用诊断和 sole-owner 账本可复用；不是已装配真实 Controller/Worker。`GrantTarget` 只接受 ADMISSION/CRYPTO，E5 固定 30s，不能直接把它改名用于 60s OBJECTS/STORE。需要各 Trial 隔离入口接线与审查，不扩大生产 ABI、不重建 Grant/IPC/Supervisor。 |

最小后续源码责任限于诊断 composition：固定目标传递与入口、实际设备/产物/pin 证据桥接、
外部 Custody/脱敏证据交接及其 Fake 回归；不改生产启动、E4 字节格式或既有默认拒绝。
信任边界未完成单独审查前，不通过“返回 true”补齐入口。新增自动 Kill、取消同步原语、
重启/恢复 Worker、借 PID 重新打开或关闭/终止进程的能力不在这里实现；即使仅准备源码，
也应先取得该能力的具体范围授权。人工终止某个精确已验证进程另需单次操作许可。

#### 五份申请的共同固定产物清单

每份申请都须附 `l1Preparation.artifactFreeze.requiredFields` 的全部字段；非适用项须有
独立审查理由，不能留空或用旧 Trial 的批准填充。

| 项目 | 候选冻结方法 / 当前缺口 |
|---|---|
| Source/Base、干净工作树 | 正式 Source 是最终提交的 40 位 SHA，Base 是批准的 merge target；跟踪/未跟踪文件均检查。源码改动中只有候选字节清单；无 commit 权限不制造最终 Source 身份，已有无关文件保留。 |
| 工具链 | MSVC/Windows SDK/CMake 精确版本；cl/link/cmake 工具 SHA-256、配置/生成器/x64/编译链接 flags 和源码清单摘要。编译主机信息只属 STATIC，不能选定实验机。 |
| Controller/Worker/Native | 各自 SHA-256；Admission 不链接 Native/Crypto/DPAPI DLL，Native 项须记“经审查不链接”，不能为凑清单加载生产 DLL。E0 Crypto EXE 静态链接七符号 core，仅是拒绝运行候选，不能替代完整 E5 Worker。OBJECTS/STORE/RELEASE 的实际链接模型待固定入口决定；生产 ABI-3 仍是 27 导出。 |
| 依赖闭包 | 直接导入名/Hash、实际加载模块闭包、每文件 Volume/File ID、Owner/DACL 摘要及保留 pin。E5 manifest 包含 Worker 映像，最多 128 个不重复身份；加载闭包在 HELLO 后、ADMISSION 前核对。仅 dumpbin 依赖名不是完整闭包，未授权不得为取得闭包启动 Worker。 |
| 设备/PE | 实际 OS Edition/Build/Patch/x64、设备别名及身份来源；PE x64、ASLR/NX/CFG、导入/导出限制。Admission 物理无 Crypto/DPAPI 引用和依赖须在最终 PE/link 闭包验证；OBJECT-only 源码守卫不等于 EXE 证明。 |
| 入口调用 | 精确 Controller 命令/参数、工作目录、环境、继承句柄和 UI 启动次数。当前叶子的 Worker 命令形状为 `l1-worker <read-handle> <write-handle>`，但无解析它的可执行入口，因此不是可执行命令。仅 SystemRoot/WINDIR 的固定环境、显式两管道端继承清单须审查；参数本身不授予许可。 |
| 绑定与审查 | E4 Target Hash、产物 Manifest Hash、最终 Head/当前 Base 的 standing CI、独立 Reviewer/必要 Verifier 记录；Review 产物与实测产物完全相同。任一 Source/产物/依赖/工具链/OS/范围漂移使批准失效，重新冻结，不继承旧 Hash 的许可。 |

工作树 STATIC manifest 只能表示 **CANDIDATE_NOT_FROZEN**。本准备不默认构建/安装/运行
App/Bridge Release/AOT，也不为填写缺失字段探测系统安全对象或读取已有实验根。

#### 集中未决参数与资源采样申请

完整未决表在 `l1Preparation.parameters`，与原 `environment`/`ownership` 配合：

| 参数组 | 必须由用户选定或另授实测的输入 |
|---|---|
| 设备/账户/批准者 | 设备、Edition/Build/Patch/x64、操作员/批准者；受限申请中的精确 SID、公开 account digest；非提权 Primary Medium Token。不自动选择当前开发机或查询当前 SID。 |
| 新空间/禁止对象 | 全新独立 C: NTFS 目录及每级父目录/对象/文件清单、Owner/DACL/Volume/File ID 获取与校验方法；生产根/Host A 根的受限精确清单，公开只用别名。路径黑名单不能证明隔离，不访问禁止根来“确认”其内容。 |
| Controller 三项 | Working Set bytes、Commit bytes、sampled handles 上限分别待定，包含 Approval UI；不得套用 64 MiB/128 handles。 |
| Custodian 三项 | Working Set bytes、Commit bytes、sampled handles 上限分别待定，单列第三进程预算，不得并入 Controller。 |
| Worker 三项 | Working Set bytes、Commit bytes、sampled handles 上限分别待定，不能沿用 Controller 数字。 |
| 观测完整性 | GetProcessMemoryInfo 的 OS peak bytes 和 GetProcessHandleCount 点采样候选；Worker 18 个协议点，与 Controller/poll 观察分开。Admission 的 18 个 Worker 点由循环连续产生，不是均匀时间采样或真实阶段逐点观测。间隔/最大采样和轮询次数、误差来源及不可观测区间待定；不存在当前可声称的最大误差或精确 handle high-water。 |
| 职责/恢复/证据 | STOP、Recovery、Evidence、借用 pin 最终关闭责任人、备份确认/恢复记录摘要、外部托管确认、证据目的地/写入次数/保留期限、Verifier/Reviewer、Batch/case/UTC 窗口。 |

如果六个资源上限必须依靠先行只读采样确定，申请必须单列：**指定设备、已存在且明确
获准观察的进程身份、方法、次数、间隔、时窗、观察者本身预算与脱敏输出**；不启动任何
候选进程，不创建实验对象，不查询未批准根或凭据。本轮未运行这项采样，亦不以“只读”
自动获得权限。若目标 Worker 尚不存在，采样申请不能借此启动它；首次受控启动及其保守
预算需要另行明确批准，不能声称已有真实依据。

#### 首次 L1-ADMISSION 申请操作账本（未授权）

申请 ID/Batch/case、精确 Target/Artifact Hash、设备/SID/根、六项上限、窗口与职责均引用
上述共同表且待定。申请拆为 **1A 对象准备/只读冻结** 与 **1B 单次准入**，分别批准，
1A 成功不授权 1B。下表是确定上限与必须补齐的次数，不是可执行脚本。

| 子项 | 固定动作与上限 / 尚须冻结 |
|---|---|
| 1A 根 | 一个批准的新目录 CREATE_NEW ≤1；仅该目录的批准 Owner/DACL 设置 ≤1；若存在/未知/需修改父 ACL 即 STOP。每级父链/产物/Token/元数据读取、临时句柄及其关闭次数由固定入口展开，当前待定，不视为无限次。 |
| 1A 交接 | 新根和批准父链的 Volume/File ID/Owner/DACL、EXE/依赖 Hash 与 pins 由指定负责人保留、复核并交接；精确借用数量/最终关闭次数待定。不发行 Grant、不创建管道、不启动 Worker。 |
| 1B Controller/UI | Controller 自身启动 ≤1；一次摘要确认、一次手输六字符后缀；批准前后原目标/预算复核。外部真实许可必须先存在，UI 不产生全局执行权；取消不再弹出或重试。 |
| 1B 持久记录 | 三文件各 CREATE_NEW ≤1：256B Receipt、1B Grant、128B Journal；写入/Flush 各 ≤6（Receipt 1、Grant 2、Journal 3）；Grant 条件 burn ≤1，Lock/Unlock 各 ≤1，烧录前读取 marker ≤1。完整元数据/校验读取、临时资源的低层调用总次数仍待固定源码展开，不能由这六次写入推断。 |
| 1B 启动 | 持久请求→消费确认→启动记录，均先于 Create；挂起 Worker 创建 ≤1，Token/Image/依赖精确复核后 Resume ≤1；失败、UNKNOWN、崩溃或截止均不返还额度。进程身份验证及临时句柄次数待定；禁止启动 Crypto Worker。 |
| 1B IPC/工作 | 两条匿名管道（四端）；仅 Worker 两端继承；六类 64B 帧，Worker ≤44、Controller ≤3、总字节 ≤3008；18 点资源样本、24 段完整零密码学结算。所有 Crypto ABI 尝试=0、直接 Crypto Native 资源尝试=0；OS Token/文件/管道操作另计。 |
| 1B 时间/观察 | 同一启动尝试起 30000 ms 包含式截止，不因 HELLO/检查/无数据续期；UTC/monotonic 双时钟；独立进程退出观察、Controller/Worker 资源观察。采样/轮询上限、间隔/误差及所有观察调用次数待定；时限不保证内核同步调用可取消。 |
| 1B 正常结算 | 已实际观察退出后，Controller 拥有的 process/thread 句柄各 ≤1 次关闭；Controller 拥有的三个记录句柄/四管道端各 ≤1；Worker 自己拥有的两个继承端各 ≤1；父端重复句柄与子端是不同 Owner。临时/借用 pins 清单和正常最终关闭职责须先冻结。若把此项作为 L1-RELEASE 子集验收，必须在本批批准中明示。 |
| 1B 异常/证据 | 第一异常关闭新工作；同步调用未返回、未退出、未知释放均 UNKNOWN 并移交外部 Custody，不重试。证据保存由 Evidence owner 在关键节点及退出/STOP 后完成；当前仅内存，外部记录方案/次数未定，因此阻断启动。目录/文件删除=0、Kill=0、Crash Injection=0、提权=0、重放=0。 |

每个有界副作用仍需真实授权；任何“待定”次数/预算/接口都阻止批准 1B。
若 Controller 崩溃，保留现场/三记录且不得重新运行发行者；外部 Recovery owner 只能按
**已批准**步骤对精确 PID+创建时间+映像/账户绑定识别原进程。现有代码尚无该交接能力，
不按 PID 独自寻找或终止进程。没有终止权时保留 UNKNOWN，另申请特定进程处置；
CloseHandle、void 返回、超时、进程退出均不能补造底层资源或效果 PASS。恢复后以原
消费/启动记录、外部 Custody 观察和禁止重新发行/Resume 的记录证明无隐式重放；无法
证明则维持 UNKNOWN，不重新启动“验证”。

#### 独立证据与后续四份申请

`l1Preparation.evidence.requiredFields` 定义五份统一证据封面，叠加原 `evidenceFields`：
STATIC/OFFLINE/LOCAL-L1 分类、Target/Artifact Manifest Hash、Batch/Trial/case、OS/身份
来源与别名、发行/请求/消费/启动、Worker 身份/IPC/退出、各预算的尝试/返回/接受/结算/
UNKNOWN、样本/盲区、全部 STOP、残留 Custody/人工恢复、Verifier/Reviewer 目标记录。
安全和系统稳定性必须两个独立 Verdict。保存次数/时点和脱敏责任由 Evidence owner
事先批准；公开结果不得含原始 SID、敏感绝对路径、私钥、证书全文、个人文件/数据库或
原始异常/进程日志。崩溃时未保全的数据写缺失/UNKNOWN，不能回填为观察值。

LOCAL-L1 PASS 仅属获准、实际执行且完整证明的单一子集；不提升任何 A0–A12。
独立 Verifier 对实机/OS、单次性/身份/退出/恢复作匹配目标检查，Reviewer 对范围和语义
给独立判断；Executor 的离线输出不是两者批准。最终源码提交/构建后才冻结正式 Hash，
并满足 final-head/current-base standing CI 和独立审查，不用旧 B1 记录批准 B2。

Trial 2 保持 16 步、18 点、7 符号、106 尝试、5 live buffers、47 直接资源和 30s；
Trial 3 保持批准对象 ID/kind 1/2/父目录及实际发布身份链，不能退回观察 A/发布 B；
Trial 4 必须 Admission/Crypto/Objects 相应实测独立 PASS、新批单一 kind，明文 ≤65024 B、
Protect/Unprotect 2/2、Begin/Commit/Abort 3/2/1、60s；Trial 5 每唯一 Owner 最多一次合法
释放尝试、结算窗口 ≤30s。各自操作/前置/清单仍由原 requests 行拥有，任一结果不授予
下一项权限。Release 与其他 Trial 合并观察须明示精确释放子集，或独立许可，不默认扩权。

HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED;
REAL WINDOWS = PENDING; FORMAL ACCEPTANCE = PENDING.

### B2-R1 diagnostic wiring amendment (G0-L0)

R1 实现 `l1_r1_wiring.h/.cpp`、专用 Controller/Worker entry 和
`tests/l1_r1_wiring_test.cpp`。这些均为独立诊断代码；原 E2–E5/B1 Grant/Journal/
Supervisor/Ledger/64B IPC/ProtectedObjects 不重写，生产 ABI 不变。机器字段沿用
`l1Preparation.r1Wiring`，仍不是执行配置。当前总结果为 **B2 ADMISSION SOURCE BLOCKED**。

| 修复 | 源码责任及界限 |
|---|---|
| A 固定接线 | **CLOSED（SOURCE/FAKE）**。两个 EXE 链接同一个 `Composition` 与入口函数；生产 bootstrap 固定 `ClosedWindowsBoundary`，无可配置真实后端。Fake Controller 入口经原 `UnifiedAdmissionController`/E5/E4 发起，独立 Fake creator 用原 `launch_once` 创建/核验/Resume，Worker 入口调用原 `admission_only_worker_candidate`；实际双向内存管道等待正确 ADMISSION，18 点/24 段结算后由真实 Controller 算法发 ACK，无预填成功 ACK。两 EXE 从不注册 CTest，不能把 Crypto Worker 改名使用。 |
| B 独立测量/Pin | **CLOSED（接口/FAKE）**。`IdentityPort::measure` 先测量，再比对 `Frozen`；设备、OS、Token/SID、独立 BuildEvidence、Controller/Worker/dependencies、精确 pin/parent/security/owner 均分别比较。`Origin::kFake` 不可提升为 Windows 实测。每个 pin 由 manifest 的单一 `pin_owner` 持有；Controller 不取得借用 HANDLE。真实 Windows adapter 未实现，本轮不测当前机器。 |
| C 独立 Custody | **BLOCKED（真实边界）**；`CustodyPort`/独立存活 Fake creator 及崩溃窗口回归已补齐。创建权只属于 creator，创建前接受 Intent；创建后绑定 PID+creation time+image+account+Target，确认其仍拥有 process/thread 才允许 Resume。Controller 无创建/恢复 fallback。真实外部创建者、认证的跨进程交接、创建前可验证责任记录、UNKNOWN 保留未实现；Fake receipt/内存 ACK 不是实际托管证明。 |
| D Evidence | **CLOSED（接口/FAKE）**。`EvidenceSink` 接受白名单 Record、递增序号/前记录 Hash，返回完整性与保留确认；调用/写后 ACK 丢失、拒绝、异常、错 Hash 均 UNKNOWN，不重试、不 PASS。E5/B1 Evidence 留在 Result，Record 仅投影安全字段。真实持久 adapter、目的地/ACL/保留期限/Owner 未实现或批准，故不宣称 LOCAL-L1 崩溃保全。 |

实际 Windows 入口均拒绝，**不是**实机接线 CLOSED。仅端口/Fake 结果可审查；真实信任
边界和操作预算完整前不得改门禁、签发执行许可或宣称 L1-ADMISSION READY TO EXECUTE。

#### 固定 Target、产物与 Owner

先构建两个不嵌入目标的 EXE，再从最终产物计算 Hash，装配只读 `Frozen`；Worker 的
不可变目标通过受审查 composition 的 `EntryPort` 传入，不靠自身二进制内嵌 Hash。
Artifact/build、选定设备/OS 摘要、pin 清单/parent/security/owner、P 和三类 Owner 经
原 `CanonicalHashBuilder` 得到 R1 Manifest Hash，写入 E5 `FixedScope` 新增的可选
`wiring_manifest_sha256`，再进入原 E4 Target Hash/人工摘要。空字段保留旧 E5 Hash
字节，非空附加带 domain 的摘要；E4 Receipt/Grant/Journal/帧字节完全不变。
Worker 只接收两个不同的正整数管道 token，Controller 不接收其他参数；这些数值是
传输数据，不是权限。Closed bootstrap 不调用 Fake attach 或任何 Win32 安全叶子。

Owner 分工：Controller 独占一次 issuance/consume/start 请求和原 Supervisor；外部
creator 独占 Worker 创建/Resume、process/thread 与管道；pin Owner 持有所有祖先、根、
映像和依赖 pins；Evidence owner 独占输出保留。原 GrantIo 仍是记录文件唯一 Owner，
诊断端口不接收复制 HANDLE。退出未知或创建结果 UNKNOWN 时不关闭借用 pins，交外部
Owner 保留；确认退出后才允许一次句柄结算/最终 pin 关闭，失败不重试。

#### Custody 窗口与尚需的具体授权

交接 receipt 必须包含所观察 ProcessIdentity 的规范 Hash，覆盖 PID、创建时间、映像、
账户、Target 和 Owner；其他进程的 ACK 不可复用。每个启动步骤和 Resume 前都复核同一
启动原点的双时钟/30秒包含式期限；耗时的 ACK 不延长窗口，截止后禁止 Resume。

同批路径为 Create Intent → Custody Accepted → 原人工批准/持久消费/start → Create
Attempt → Process Identity Observed → Custody Handoff Acknowledged → Resume →
IPC → Exit Observed → Handle Settlement；任一不确定进入 UNKNOWN/Recovery Required。
Fake creator 的状态/句柄 token 寿命超过 Controller 对象；不靠 Controller 析构执行清理。
确定性回归覆盖接受后但创建前、创建尝试前、已创建未观察身份、身份后未交接、交接 ACK
丢失/已记录但未返回、Resume 后和正常交接后 Controller 消失。旧 Intent/创建额度不恢复，
重建 Controller 也不允许重新创建/Resume。Receipt/Journals 的原单次性仍由原 E4 拥有。

最小真实方案需要一个**专用于该 Batch 的外部创建/托管进程**在创建前承担责任，
不需要生产服务，但它是新增实际进程与信任边界。必须另行冻结并授权其启动次数、身份、
认证 IPC、独立三项资源预算、证据保留/确认和 Controller 死亡后的行为；不能只给现有
Controller/Worker 六项预算就启动第三进程。同步调用不返回时如何保留这个 Owner、谁
接手及其退出条件也必须裁定，不能默许变成长驻服务或超时退出丢失 Custody。
真实 adapter/协议与这项权限边界独立审查前 C 保持 BLOCKED。本轮未实现自动 Kill、
OpenProcess 按 PID 恢复、句柄转移、崩溃注入或真实保全文件；实际终止仍须特定进程许可。

#### 同一 1A/1B 申请的精确端口账本

令 **P** 为批准的 Controller pump 总上限，必须 `1 ≤ P ≤ 4096`，当前 P、实际间隔、
误差和盲区均 `REQUIRES USER DECISION`。4096 是源码硬上界，不是已批准负载。所有
调用计数在尝试前消耗；首次不确定停止新工作，释放仅限已拥有资源。下表是新组合中
可执行的端口上界，不能替代尚未存在的真实 adapter 的 OS 调用预算。

| 调用位置 | 单批硬上界与最早边界 |
|---|---|
| `Composition::begin/inspect_target` 独立测量 | 1 次预检 + 最多 4 次（人工前、人工后、创建前、HELLO 后）；总 ≤5。测量失败不发行/启动；后置漂移不发送 ADMISSION。 |
| Custody Intent/Accept | ≤1，早于 Grant/Worker；拒绝/未知不启动，已有独立责任记录不重置。 |
| `start_suspended` / 原 `launch_once` | create ≤1；process identity ≤1；Token/Image/handles 检查各≤1；dependency 检查≤2（Resume 前、HELLO 后）；identity ACK≤1；Resume≤1；loader HELLO≤1。ACK 失败留挂起 Custody，不 Resume。 |
| 原 `GrantFlow` / R1 GrantIo wrapper | principal/issue/request/burn 各≤1，Journal update≤2；记录 inspect≤`3P+16`（新 wrapper 在调用前硬拒绝超限）。仍是三文件各创建≤1、总写/Flush≤6、Lock/Unlock/marker read 各≤1。 |
| `read_clock/observe/next/send` | Controller clock≤`4P+16`；Controller+Worker 组合 observation≤`2P+16`；next≤P；send≤3；每次 next 交付一个原64B Frame，无无限内层循环。Worker 原44帧、Controller原3帧、总3008B不变。 |
| 原 Worker | 收到正确 ADMISSION 后执行18点（连续协议检查点，非时间间隔保证）及24段零 Crypto/DPAPI/Store 结算；仍为30秒包含式期限。 |
| 退出/关闭 | 独立退出观察后 process/thread 各一次关闭；记录/管道各已取得 Owner 一次关闭；pin 集合最终 close 请求≤1。正在同步调用/未退出不结算；Evidence 失败仍允许已拥有 Owner 的单次释放。 |
| `EvidenceSink::preserve` | ≤`P+32` 次尝试，关键副作用前后及每次 pump 保存；序号/目标/前 Hash 和 receipt 完整性校验。Record 字段固定白名单、最长安全 ID 80、Hash 64、样本18/ABI7/Native14，不接收任意字节正文。真实每条编码/Write/Flush 次数及字节上限须由实际输出 adapter 展开后批准。 |

**1A 未新增真实根 adapter**：根 CREATE_NEW≤1、批准 Owner/DACL 设置≤1，精确祖先/
根/文件清单、读/临时句柄次数及 acquisition 方案仍待用户固定；没有这些参数不得执行。
**1B 当前真实 OS API 调用预算为零**：R1 新源码仅调用注入端口，不链接实际 Windows
叶子、Native DLL、Crypto/DPAPI/Store。以下是既有叶子的完整 API 类别/位置与逐次上界，
用于实际 adapter 的展开；不伪造一个尚不存在的可执行 OS 账本。

| 既有源码位置 | API 类型及逐次上界（均未运行） |
|---|---|
| `l1_windows_operations.cpp::inspect_exact_token/token_field` | ConvertStringSidToSid/OpenProcessToken 各≤1；5个 token_field 各 GetTokenInformation≤2（合计≤10）；EqualSid、IsValidSid、IsTokenRestricted、LookupPrivilegeValue 各≤1；GetSidSubAuthorityCount≤2、GetSidSubAuthority≤1；已取得 Token CloseHandle≤1、SID LocalFree≤1。 |
| 同文件 `inspect_e4_pin` | 每 pin：GetFinalPathNameByHandle/GetVolumeInformationByHandle 各≤1，GetFileInformationByHandleEx≤3；ConvertStringSidToSid/GetSecurityInfo/IsValidAcl/GetSecurityDescriptorControl/GetAce 各≤1、EqualSid≤2、LocalFree≤2。 |
| 同文件 `inspect_e4_parent_chain` | 祖先数 H≤16；每级 FinalPath/Volume 各≤1、FileInformation≤2；首级 GetSecurityInfo/SDDL conversion各≤1、LocalFree≤2；其余 H−1 级各调用一次上述 pin 检查。 |
| 同文件 `create_e4_record/write_e4_record` | 每 create：pin检查≤1，GetModuleHandle/GetProcAddress/ConvertSid各≤1、LocalFree≤1；InitializeSecurityDescriptor/SetOwner/InitializeAcl/AddAccessAllowedAceEx/SetDacl/SetControl六项各≤1，NtCreateFile≤1（失败返回的已取得句柄 CloseHandle≤1）。每 write：FileInformation≤2、pin检查≤2、SetFilePointer/WriteFile/FlushFileBuffers各≤1；无 replace/delete fallback。 |
| 同文件 `E4WindowsGrantIo` | issue 创建/写各≤2、额外 FileId≤2、inspect≤1；request 创建/写/FileId各≤1；burn pin检查≤2、Lock/Unlock/SetPointer/marker Read各≤1、write≤1；两个 update各write≤1；每 inspect：principal≤1和目录/Receipt/Grant pin检查共≤3；记录 CloseHandle≤3且各一次。 |
| 同文件 `verify_e4_artifact` | 每文件≤64MiB，FileInformation≤3、GetSecurityInfo/SDDL conversion/SetPointer各≤1、LocalFree≤2；ReadFile 每次至少前进1B，因此最坏 **67,108,864 次/文件**，不能误写为1024次。实际 adapter 必须另定更小可接受的调用预算/失败关闭规则；当前不获授权运行此极端上界。 |
| 同文件 `inspect_e4_image/inspect_e4_dependencies` | image：FinalPath/QueryFullProcessImageName/CreateFile/FileId/Close各≤1；dependencies D≤128：EnumProcessModulesEx≤1，每模块 GetModuleFileName/CreateFile/FileId/Close各≤1，加每个匹配 pin一次artifact校验。加载闭包不能由名字清单代替。 |
| 同文件 `create_e4_suspended/resume_e4_once/close_e4_observed_exit` | 创建前pin检查/artifact校验各≤1；FinalPath≤2、GetWindowsDirectory≤1、GetHandleInformation/GetFileType各≤2、InitializeProcThreadAttributeList≤2、Update/Delete属性表各≤1、额外双时钟读≤1、CreateProcessW≤1；ResumeThread≤1；退出 Wait≤1及process/thread Close各≤1。实际外部 creator adapter 未接线，不能把Controller直接创建冒充外部创建。 |
| 同文件 `create_e4_pipe_pair/read_e4_pipe_chunk` 与 B1 Worker | CreatePipe≤2、SetHandleInformation≤2；每读 chunk：Peek≤1、ReadFile≤1、GetTickCount64≤2、容量≤64B；Worker send每帧WriteFile≤1，最多44；其 inherited两端各Close≤1。Win32 Worker receive/poll原有30000次循环/时钟截止，真实轮询预算须缩到批准值并由 adapter 硬限制。 |
| 同文件 `read_e4_clock/observe_process` | 每clock：GetSystemTimePreciseAsFileTime/GetTickCount64各≤1；每process观察：GetProcessMemoryInfo/GetProcessHandleCount/WaitForSingleObject/GetTickCount64各≤1、确认退出后GetExitCodeProcess≤1；E5组合观察至多两个process（pseudo GetCurrentProcess每组≤1）。两种峰值bytes与点采样handle分别报告。 |
| 同文件 `show_e4_approval` | MultiByteToWideChar≤2、摘要MessageBox/后缀Dialog/GetModuleHandle各≤1；初始化SetWindowLongPtr/SendMessage/SetTimer各≤1、CreateWindowEx≤4；每事件GetWindowLongPtr≤1、终结GetDlgItemText/EndDialog各≤1。消息数取决于人机交互，实际受限输入/事件预算尚未实现；不把“一次UI”换算成无上限许可。 |
| 新 Identity/Custody/Evidence ports | 本轮 Windows API调用=0；第三进程创建/认证、创建时间测量、真实 pin acquisition、输出持久化/保留无实现，不能列作已关闭的实机预算。它们和 Win32 UI/短读/轮询的剩余预算约束使完整1A/1B准入继续 BLOCKED。 |

0不是忽略所需操作，而是当前禁止执行；真实底层预算、采样精度、外部托管信任边界、
三进程资源/恢复/证据方案、最终 Hash/依赖及独立 Reviewer/Verifier 尚需固定。
本轮不新增长期服务、账户/权限、真正的目录/Grant/Journal/Lock/进程/输出文件。

新回归只使用 Fake I/O和内存线程，不创建 Worker OS进程；覆盖漂移、未批准/单次性、
创建/交接崩溃窗口、失去ACK、退出未知、Evidence失败/UNKNOWN、截止与合法释放、终态
不可变；原 B1-C 绑定回归仍在同一 Fake CTest 中执行。机械通过不关闭真实 Custody。

HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED;
REAL WINDOWS = PENDING; FORMAL ACCEPTANCE = PENDING.

### B2-R2 Batch Custodian, Windows adapters and hard OS ceilings (G0-L0)

R2 在同一 B2 分支集中实现 `l1_r2_adapters.h/.cpp`、`l1_r2_custodian_entry.cpp`、
`l1_r2_windows.h/.cpp` 与 `tests/l1_r2_adapters_test.cpp`。机器字段写入
`l1Preparation.r2Adapters` 及九项三进程资源参数，不新增第二套验收计划。所有五份
L1 实验保持 `DRAFT_NOT_AUTHORIZED`；最高状态为
**B2 WINDOWS ADMISSION SOURCE REVIEWABLE / OFFLINE TESTED**。

| 责任模块 | R2 源码实现与硬边界 |
|---|---|
| 1. 独立 Batch Custodian | `Custodian`、`Endpoint`、`Proxy`、`CustodyJournal` 及 `shiroha_l1_r2_custodian_candidate.exe`。每 Batch 最多启动一次；Controller 只拥有人工审批与 `GrantIo`/Supervisor，所有 Worker 创建、process/thread/pipe HANDLE 持有、身份观察、Resume 与退出关闭均经 512B 受约束控制通道由 Custodian 独占执行。Custodian 在 `create()` 前通过 `ProofPort::read_once` 独立校验 E4 256B Receipt、1B Grant(`marker==2`)、128B Journal(`stage==3`) 及因果时钟序，不把普通 IPC ACK 当作持久化证明。`CustodyJournal` 定义独立版本(`0x324a4353`)、512B 哈希链记录（上限 16 条，正向 12 个状态转换：`ready` → `accepted` → `consumed` → `intent` → `attempt` → `identity` → `acknowledged` → `resume_intent` → `resumed` → `exited` → `settled` → `released`），每条写后立即 Flush 并前后复核父目录/文件 pin，不宣称与 E4 三文件构成四文件原子事务。Controller 崩溃或失联时 Custodian 写入 `unknown` 并保留原 HANDLE，不自动 Terminate/重启/清扫。Custodian 对 `dependencies`（`identity`/`resumed`）、`next`/`send`（`resumed`）、`observe`（`accepted` 仅 Controller/Custodian 采样，或 `resumed`）、`close_owned_io`（`settled`）使用显式状态允许表；任何 UNKNOWN 终止最多写一条 `unknown` 记录，合法 `released` 后迟到的失联不得改写终态。`WindowsControl::serve_once` 在 `peer_checked`/`take`/`put` 失败时通知 Custodian 一次并停止服务。 |
| 2. Windows Identity / Pin Adapter | `l1_r2_windows.h/.cpp`（编译为未链接 OBJECT `shiroha_l1_r2_windows`）提供 `measure_runtime`、`measure_artifact`、`inspect_process_pin`、`bounded_dependencies`、`WindowsIdentity`、`WindowsProof`、`WindowsControl`、`WindowsWorkerLink`、`bounded_approval` 与 `WindowsOwner`。先从 `RtlGetVersion`/`GetProductInfo`/注册表 UBR/`IsWow64Process2`/Token SID/进程创建时间与 Volume/File ID 实测来源采集，再由 `Frozen::matches` 比对，拒绝把字符串/环境变量/JSON 当作 OS 证明。`bounded_hash` 将单文件限制为 `≤16 MiB`、固定 `64 KiB` 块（最多 256 次 `ReadFile`），任何短读或读后大小变化立即 STOP，消除 R1 逐字节极端上界。每个借用 pin 与进程 pin 标明唯一 Owner，不在未退出或 UNKNOWN 时关闭。`bounded_approval` 要求摘要、复核确认、后缀输入与批准按钮四个控件全部创建成功，并校验摘要文本长度与可见性；任一失败立即 `cancelled`，`displayed_hash` 仅在完整获批响应时写入，摘要使用可滚动只读多行控件，避免固定对话框裁剪长文本。 |
| 3. Evidence Persistence Adapter | `PersistentEvidence` 与 `WindowsPersistence` 复用 R1 `EvidenceSink`，将固定白名单 `Record` 编码为版本化 8192B 记录（上限 `P+32` 条，含前序 Hash、Target/Batch/Owner、18 点样本、ABI 7 类、Native 14 类、双 Verdict）。每条记录恰好一次 `WriteFile` + 一次 `FlushFileBuffers` 及前后目标/父链复核；短写、Flush 失败、校验失败或 ACK 丢失立即熔断流并置 `UNKNOWN`，绝不补写伪造 PASS。Controller 崩溃时 Custodian 可通过独立 `evidence-custodian.r2` 流保留 `kRecoveryRequired` 证据。8192B `Record` 白名单仍只含 Controller 峰值与 18 点 Worker 样本；Custodian 三进程峰值在内存 `peaks_` 中分别核对，第三进程峰值的版本化持久化列为 P3 后续格式决策，不宣称已写入持久化证据。 |
| 4. 三进程九项预算与硬上限 | `Limits` 强制要求 Controller、Custodian、Worker 各自独立的 Peak Working Set、Peak Commit、Sampled Handles 共九项非零上限（经 `OwnerPort::sample_three` 每次观察同步核对并分别记录峰值），并通过 `Manifest::r2_sha256` 绑定进 Target Hash。三进程峰值在 `Custodian::peaks()` 内存中分别保留；持久化 8192B `Record` 仍只含 Controller 峰值与 Worker 18 点样本，第三进程峰值不进入当前冻结记录格式。硬编码上限：`kPolls = 512`（取代原未批准的 30000 次轮询）、`poll_ms ∈ [1, 50]`、`kUiEvents = 128`（单模型无模式对话框统管全部消息，取代无界双弹窗）、`approval_ms ≤ 60000`、`handoff_ms ≤ 30000`、`kPins = 64`、`kParents = 16`、`kDependencies = 32`。 |

#### R2 收口后的 L1-ADMISSION 硬性操作与 OS API 上界

令批准轮询上限 `P ≤ 512`、祖先链深度 `H ≤ 16`、依赖模块数 `D ≤ 32`、受检 pin 总数 `M ≤ 64`：

- **进程与创建**：Controller 启动 ≤1、Custodian 启动 ≤1、Worker `CreateProcessW(CREATE_SUSPENDED)` ≤1、`ResumeThread` ≤1；任一失败或 UNKNOWN 均保留 Custody 且不重试。
- **产物与依赖读取**：每产物文件 `≤16 MiB`，`ReadFile` 块大小固定 `65536 B`，单文件 `ReadFile ≤ 256` 次（短读立即失败关闭）；Resume 前静态校验 `D` 个依赖 pin，HELLO 后 `EnumProcessModulesEx` ≤1 并核对 `D` 个已加载模块 File ID 与 SHA-256。
- **控制与工作管道**：Controller↔Custodian 控制通道（512B 包）交换 `≤ 8P + 64` 次；Custodian↔Worker 64B 帧通道：Worker 发送 ≤44 帧、Custodian 转发 Controller 发送 ≤3 帧，Custodian 与 Worker 各自 `PeekNamedPipe`/`ReadFile` 轮询均硬限制 `≤ P`（512 次）且包含在 30000 ms 期限内。
- **人工确认 UI**：单个有界对话框，窗口创建 ≤5、消息分发 `≤ 128` 事件、总时长 `≤ 60000 ms`。
- **持久化写入**：E4 三文件创建各 ≤1、写入/Flush 各 ≤6；CustodyJournal (`custody.r2`) 创建 ≤1、512B 写入/Flush 各 ≤16；Evidence (`evidence-controller.r2` / `evidence-custodian.r2`) 创建各 ≤1、8192B 写入/Flush 各 `≤ P + 32`。
- **同步调用盲区与人工恢复**：Win32 同步 I/O 或内核调用无法被用户态硬性取消；若调用未返回或 Worker 未观察到 OS 退出，禁止调用 `CloseHandle` 伪造结算，保持 `UNKNOWN` 并由具名 Recovery owner 按已批准的（PID + 创建时间 + 映像 + 账户 SID）绑定接管，任何实际进程终止仍须针对该已验证进程的单独用户授权。

HOST_STABILITY_HALT = ACTIVE; TRANSPORT = BLOCKED; AR-R6A = NOT_ACCEPTED;
REAL WINDOWS = PENDING; FORMAL ACCEPTANCE = PENDING.


### B2 F1 Custodian executable identity binding (G0-L0)

`Limits::custodian_sha256` is the sole approved Custodian digest. Its existing
`Limits::hash()` -> `Manifest::r2_sha256` -> manifest/Target binding is retained;
`custodianExeSha256` in Artifact Freeze must supply that same value, never a
second independently editable expected hash or a self-embedded executable hash.
Process indices remain Controller 0, Custodian 1, admission-only Worker 2.
The shared `match_images` gate requires independent process/HANDLE identity,
actual pinned image byte SHA-256, and matching approved Volume/File ID and
artifact inventory under the frozen source/build/Target manifest. Missing,
drifted, failed-read or UNKNOWN observations deny.

Before Batch custody, `Custodian::accept_intent` requires the Owner's two-host
measurement; `WindowsOwner::accept_intent` independently enforces the same gate
before acceptance, latching rejection against retry. These checks need only the
already existing Controller/Custodian. After Worker creation, the three-process
`WindowsIdentity::measure` requires all three executable comparisons without a
Custodian exception. No Worker is started to obtain pre-custody evidence.
The pre-custody Controller/Custodian images are each byte-hashed once per
WindowsOwner Batch: the second acceptance check reuses the captured image
identity, digest and frozen Owner/DACL proof, while rechecking process/File ID
and actual Owner/DACL without a second ReadFile. A failed first measurement
burns the snapshot and cannot be retried. Thus the two-host pre-custody phase
has at most 256 ReadFile calls per host artifact, not two full 256-call scans.
The existing R1 three-process measurement API is not a complete phased startup
composition: S3's staged Pin handoff and cross-phase aggregate file-read
accounting remain separate blockers before any real trial.

This source amendment does not close S1/S2/S3/F2/F3/D1 or claim independent F1
review approval. E4 Receipt/Grant/Journal and IPC bytes are unchanged. No real
Controller/Custodian/Worker entry is enabled or added to CTest; all five trials
remain `DRAFT_NOT_AUTHORIZED`. B2-TRIAL1A BLOCKED.

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
