# 原生逆向分析隔离试验

验证 iOS 原生进程中完成函数列表、CFG、双向调用引用和真正的 Ghidra C 伪代码输出。本目录保留隔离原型及正式扩展的验收代码；独立扩展位于 `Extensions/AgentTools/ReverseAnalysis/`，已生成并验收双 bootstrap 软件包，尚未安装，也未完成主应用工具发现验收。

## 已实测

在 iOS 16.3.1 的本机环境中，使用自行编译的 arm64、arm64e Mach-O 样本：

- 函数列表发现三个已知函数，以及主函数和导入桩。
- 分支函数恢复 6 个基本块、7 条控制流边，边的目标均属于该函数。
- 对照样本恢复到目标函数的 3 个调用者，以及调用者中的 2 条出向调用。
- `pdgj` 返回 C 伪代码、地址注解和原生 P-code 信息，不是汇编改写或模型生成。
- 仅将函数符号中的点号改为合法 C 标识符后，回编译伪代码；每个架构对 2001 个输入核对三个函数，共 6003 次结果核对通过。
- 对重复的真实反编译任务触发 0.5 秒超时及主动取消，终止并回收进程组；分析前后源码与两个样本的 SHA-256 一致。

小样本每次启动进程、重建分析并反编译一个函数约 0.31～0.33 秒，不代表大型程序的耗时。原始结果、诊断与机器可读报告写入 `build/reverse-analysis/results/`。

## 复现

需要现有的 C/C++ 工具链、兼容的 iPhoneOS SDK、Python 3、make、静态归档工具和 ldid。脚本只把依赖下载、解包、编译到项目内的 `build/reverse-analysis/`，不向系统安装依赖。

```sh
python3 Tests/ReverseAnalysis/fetch_sources.py
python3 Tests/ReverseAnalysis/build_native.py all --jobs 2
python3 Tests/ReverseAnalysis/verify_native.py
python3 Tests/ReverseAnalysis/verify_service.py
```

下载脚本固定 radare2、r2ghidra、SLEIGH 数据为 6.2.6，patch-ng 为 1.19.1，并核对大小和 SHA-256；这不是“始终使用最新版”的入口。编译包装器转换 bootstrap shell 与原生编译器的路径视角，并在每次链接后签名。构建在项目环境中运行，由环境提供根目录及工具链位置，不保存设备会变化的根路径。

`build_native.py` 支持单独执行 `configure`、`engine`、`plugin`、`static`、`session`、`fixture` 阶段。静态阶段复用插件的 C++ 编译对象，仍需先完成 `plugin` 阶段；`session` 复用静态阶段的对象，仅重新编译、链接并签名固定接口驱动。

## 固定操作与会话原型

`session_driver.c` 是独立的原生工作进程。它只读打开宿主提供的快照，执行一次分析，然后接受函数列表、CFG、入向引用、出向引用和反编译五种固定内部操作；地址只能是完整十六进制函数入口，不接受符号表达式、重定向或任意引擎命令。引擎诊断转到 stderr，stdout 仅输出带长度的 JSON 帧。

`analysis_service.py` 是尚未注册为 AI 工具的 Python 宿主原型，向上统一为四种 JSON 操作：

| `op` | 附加字段 | 返回内容 |
| --- | --- | --- |
| `functions` | 可选 `offset`、`limit` | 按地址排序的函数页、总数、下一页位置 |
| `cfg` | `address` | 函数基本块、指令与控制流边 |
| `refs` | `address`、`direction`（`in` 或 `out`） | 静态入向或出向引用 |
| `decompile` | `address` | Ghidra C 伪代码、注解与 P-code |

所有请求都须带项目相对 `path` 和明确的 `arch`（`arm64` 或 `arm64e`）。未知字段会被拒绝，地址以 `0x` 十六进制字符串传递。函数页大小为 1～500，默认 100；引用与 CFG 的完整性仍受静态分析能力限制。

```json
{"op":"functions","path":"build/reverse-analysis/fixture-arm64","arch":"arm64","offset":0,"limit":2}
{"op":"decompile","path":"build/reverse-analysis/fixture-arm64","arch":"arm64","address":"0x10000400c"}
```

可执行 `python3 Tests/ReverseAnalysis/analysis_service.py`，逐行输入 JSON，得到逐行响应。成功响应包含 `data` 及会话命中、PID、输入摘要、引擎摘要和耗时；失败响应包含稳定错误码及中文原因。该演示入口不是 MCP，也不是正式扩展协议。

### 只读输入、缓存和资源边界

- 路径先规范化并确认位于项目内，随后逐组件以不跟随符号链接的方式打开；拒绝目录、路径越界、链接和嵌入 NUL。
- 每次请求重新计算输入内容摘要，比较复制前后的文件身份、大小和修改信息，再分析只读私有快照。只支持最大 32 MiB 的未加密 ARM64 薄 Mach-O，并检查架构和 load command 边界；这不是完整的恶意文件验证器。
- 缓存键包含样本 SHA-256、架构、引擎 SHA-256 和接口版本。同内容别名可以复用；内容即使保持相同大小与 mtime，仍会失效。新建工作进程前复查引擎摘要。
- 每个宿主最多保留两个进程，LRU 淘汰；每进程最多完成 128 次请求。`expire()` 清理空闲 60 秒的会话，在每次请求入口执行，也可由未来宿主的空闲定时器调用。当前演示不运行后台定时器，因此无新请求时不会仅因时间流逝主动退出工作进程。
- 内部响应帧上限 1 MiB、每进程累计诊断上限 1 MiB、对外成功响应上限 256 KiB；过大结果失败，不返回被静默截断的伪代码。引擎可能先分配内存再输出，尚无硬性进程内存限额。
- Python 调用接口的 `timeout` 默认 15 秒、最多 60 秒；调用者持有 `threading.Event` 传播取消。排队等待也计时且可取消。取消、超时及输出超限会终止并回收进程组，丢弃该会话和快照；宿主关闭时清理全部会话。正式 AI 宿主的取消令牌尚未接入。

### 新接口已实测

`verify_service.py` 对两个架构重新验证四项能力、同进程复用和函数分页；从新接口导出的伪代码分别通过 6003 次回编译结果核对。本次小样本测得函数列表冷请求约 131～145 ms、复用请求约 8～9 ms，仅是一次本机记录，不代表大型程序性能。

另外验收了 27 项宿主输入拒绝及 8 项原生协议拒绝、同大小同 mtime 的内容失效、跨架构与 LRU 淘汰、工作进程死亡后重建、请求次数轮换、显式空闲清理、引擎变化拒绝、排队取消、初始化取消、真实反编译期间超时/取消、对外响应超限，以及 JSONL 错误隔离与 EOF 回收。读取竞争测试仅固定真实副本被修改的时机，不伪造分析结果。所有测试进程组均已消失，原始源码与两个样本的 SHA-256 保持不变。

机器可读报告为 `build/reverse-analysis/results/session-report.json`，新接口回编译产物同在 `results/`。这些是可复现的实验验收，不是正式扩展、主程序集成或恶意输入安全审计。

## 正式独立扩展与软件包验收（2026-11-27）

独立扩展使用 Objective-C 协议服务及 C/C++ 静态工作进程，提供 `analyze_functions`、`analyze_cfg`、`analyze_references`、`decompile_function`，遵循现有 JSONL、取消和 SCM_RIGHTS 只读附件协议；不向主应用或守护进程链接分析引擎，也不依赖 Python 运行时。完整用法、资源边界与离线重建说明见扩展目录的 `README.md`。

正式扩展的输入上限现为 48 MiB，路径、附件和工作进程采用相同边界；上方 32 MiB 仅属于保留作对照的旧 Python 原型，不随此次修改改变。`test_capacity.py` 检查源码、描述符与真实回归入口的一致性，不执行引擎。`verify_extension.py` 的容量回归在两个架构上分析尾部填充至 32 MiB 加一字节、41 MiB、48 MiB 的自有样本，并核对 48 MiB 附件复用、超限拒绝、失败恢复及输入摘要；填充样本通过不代表大型应用准确性验收。

已完成上述隔离试验构建时，可复用上游对象进行本机联调，链接后自动签名：

```sh
python3 Extensions/AgentTools/ReverseAnalysis/Scripts/build_local.py
python3 Tests/ReverseAnalysis/verify_extension.py
```

`verify_extension.py` 也接受 `RA_RUNTIME` 指向项目内其他已签名运行目录，`RA_REPORT_NAME` 指定结果文件名。它实际执行握手、四项分析、分页与复用、两个样本各 6003 次伪代码回编译核对、20 项输入拒绝、附件传递和拒绝、真实反编译期间超时／取消、初始化取消、后台空闲回收、LRU、工作进程死亡重建、EOF 和服务被强杀后的进程回收。组件故障测试确实由主入口调用，覆盖运行中引擎变化、语言数据清单变化、诊断与内部响应超限；不是只定义测试而未执行。

### 有界分页修复与大样本验证（2026-11-28）

正式工作进程现直接从分析函数集合选取目标页，只序列化该页，不再先生成完整函数 JSON 后截取。`test_paging.py` 编译并执行生产分页头文件，覆盖十万函数取小页、排序、末页和越界页、转义及超大单条目拒绝；与容量、构建和打包契约合计 55 项回归通过。

新编译并签名的 arm64e 独立程序，在本机以 arm64 架构读取 42,944,784 字节的 FLEQ 样本，完整返回 10,185 个函数、21 页，无重复或遗漏游标；路径与只读附件结果一致，CFG、双向引用、带注解及 P-code 的真实反编译、超时后恢复均通过。原样本摘要未变，测试进程组已回收。这仅验证所选函数及协议行为，不代表整个应用的静态语义都准确。

```sh
python3 Tests/ReverseAnalysis/verify_large_sample.py \
  --runtime "${RUNTIME:?项目内已签名运行目录}" \
  --binary "${SAMPLE:?项目内未加密薄 Mach-O}" --arch arm64
```

默认报告为 `build/reverse-analysis/results/large-sample-paging.json`；本轮完整协议报告为同目录的 `paging-fixed-extension-report.json`。后者重新通过两个架构合计 12,006 次伪代码回编译结果核对、48 MiB 路径与附件边界、超限拒绝、取消、缓存、进程回收及组件故障测试。

宿主会话已补入按扩展版本失效、共享关闭任务、迟到打开回收及有界重试的修复，并新增 8 项测试。本机缺少可用的 `swift-test` 与 `xcodebuild`，因此这些 Swift 单测和新版宿主的真实工具调用尚未运行，完整 `make check` 仍被阻塞。本次没有安装、重启或发布软件包。

`verify_package.py` 按构建 ID、bootstrap 和 SHA-256 读取现有发行包，不重新打包，也不安装：

```sh
# BUILD_ID、PACKAGE_SHA256 分别使用该发行包的实际构建 ID 和摘要。
python3 Tests/ReverseAnalysis/verify_package.py \
  --build-id "$BUILD_ID" --bootstrap rootless --digest "$PACKAGE_SHA256"
```

包级验收核对包摘要、发现清单、完整对应源码及 63 份通知摘要；随后对原包程序和每个提取后的唯一架构切片分别运行两轮完整协议回归。提取保留原有签名，不重新编译或签名。区分 roothide 首启元数据更新与代码／权限变化，第二轮要求完整文件摘要稳定；最后确认输入未变、全部测试工作进程组已回收、原包解出程序没有被切片验收改动。

0.1.2 的 roothide 包（arm64e）及 rootless 包（arm64、arm64e）均已按上述切片路径实际运行。包级报告在 `build/reverse-analysis/results/package-<bootstrap>-verification.json`，逐切片协议报告及两轮日志也在 `results/`。这里的 rootless 结论是同一台 roothide 设备上解包执行其二进制，不代表已在 rootless 实机安装验收。

## 构建隔离契约与交叉编译检查

```sh
python3 Tests/ReverseAnalysis/test_build.py
```

此契约使用假编译器验证宿主／目标 SDK 分离、显式 iOS target、两种架构、缺失环境拒绝、链接后签名、失败不签名、路径转换、平台识别和语言数据摘要；不下载依赖，也不执行分析引擎。它不能证明 macOS 上的真实编译已成功。

`.github/workflows/reverse-analysis.yml` 在匹配路径的 push／pull request 和手动触发时先执行契约，再由 `xcode-27` 专用 runner 的 Xcode 27.1 分别交叉编译 arm64 和 arm64e。`Scripts/ci_build.py` 在 macOS 上单独为 sdb 生成器选择 macOS SDK，为协议服务和静态工作进程选择 iPhoneOS SDK，并静态核验最终二进制和数据。

成功的检查产物包含对应源码和许可；`verification.json` 明确记录未执行 iOS 程序、未验收设备、未打包及未安装。此路径不调用 `verify_extension.py`／`verify_package.py`，不生成 `.deb`，不发布独立扩展，也不改动主应用发行链。专用 runner 不在线时编译作业会排队，不能用契约通过代替真实编译通过。

## 真实限制

- 动态 `core_ghidra.dylib` 已编译、签名，但本机加载时被系统拒绝映射；成功路径是将同一套真实反编译对象静态链接到独立的 `reverse-native`，没有修改系统权限或安装设置。
- `driver.c` 的任意命令参数仅用于旧的受控验收；新的固定操作入口位于 `session_driver.c`，外部 JSON 原型在 `analysis_service.py`。它们保留作实验对照，不作为正式扩展入口。
- 原型的空闲清理由请求或显式调用驱动；正式扩展已有独立生命周期、后台定时回收及原生取消传播，但两者均无进程内存硬限额。
- 仅使用两个保留符号的自有薄 Mach-O 验收分析结果；大型文件、去符号、胖二进制、Objective-C 消息派发、Swift 类型信息和混淆尚未验证。少量畸形头及加密标志只验证提前拒绝，不代表通过恶意样本语料或解析器安全审计。
- 引用是静态分析候选；验收只对 `CALL` 类型核对已知调用图，不能把全部数据/代码候选当作真实执行路径。
- 最小化插件集合会出现缺少 ARM 文本格式化器的诊断；不影响已验证的 CFG、调用和反编译结果，但不是完整工具包的兼容性验收。
- 上游包含 LGPL/GPL 家族许可文本；实验生成物留在忽略的缓存目录。正式扩展将引擎、数据、通知和完整对应源码放在自身独立软件包中，未加入主应用依赖、许可集合或发行包；未进行公开发布。

完整 `make check` 本机仍受缺少 xcodebuild 阻塞，不能用本试验替代主应用的检查门槛。恢复到具备 Xcode 的环境后仍须执行。补跑的脚本语法、JSON／权限解析、删除变量守卫、schema fixtures 和差异空白检查通过；`check-templates.py --no-build` 在读取四类模板后因本机缺少 `/private/tmp` 无法建立测试临时目录，整项仍未通过，没有为此修改系统目录或跳过检查。
