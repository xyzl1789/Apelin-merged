# 原生逆向分析工具扩展

在独立原生进程中分析未加密 ARM64 Mach-O，提供四项只读工具：

| 工具 | 功能 |
| --- | --- |
| `analyze_functions` | 按地址排列并分页列出分析发现的函数，而非仅读取符号表 |
| `analyze_cfg` | 返回函数基本块、指令及控制流边 |
| `analyze_references` | 查询函数入向或出向的静态调用／数据引用 |
| `decompile_function` | 输出真实 Ghidra C 伪代码、地址注解及 P-code |

## 兼容性与使用

需要 iOS 16.0+，兼容 roothide 和 rootless。独立协议服务器使用 Objective-C、Foundation、POSIX 和 CommonCrypto；工作进程使用 C/C++、radare2 6.2.6 及 r2ghidra 6.2.6 的 Ghidra 原生组件，不需要 Java、Python 运行时或桌面 Ghidra。

扩展遵循现有 `ApelinToolHost` v1 的 JSONL、取消及 SCM_RIGHTS 附件协议。主应用按已安装清单发现工具，不增加主应用、守护进程或原有反汇编扩展的链接依赖。

工具参数 `binary` 为绝对路径，`arch` 必须明确指定 `arm64` 或 `arm64e`。宿主也可用绑定 `binary` 的只读附件替代路径；附件中不传递跨进程 fd 数字。先列函数，再使用返回的函数入口调用 CFG、引用或反编译：

```json
{"binary":"/绝对路径/样本","arch":"arm64","limit":100}
{"binary":"/绝对路径/样本","arch":"arm64","address":"0x100004000"}
```

`analyze_references` 另需 `direction: "in"` 或 `"out"`。函数分页接受 `offset` 和 `limit`（1～500）；全部工具接受 `timeout_seconds`（0.001～60，默认 15）。调用时限包括读取、排队、分析及序列化；外层宿主时限为 65 秒。

## 资源与失败处理

- 输入限 32 MiB 的未加密 arm64/arm64e 薄 Mach-O，先检查头、load command 边界和架构，再创建只读私有快照；拒绝符号链接和非普通文件。
- 每次重新计算输入 SHA-256；会话键还包含架构、工作进程、SLEIGH 数据和接口版本。最多保留两个 LRU 会话，每会话最多 128 次任务，后台空闲 60 秒主动回收。
- 服务启动时先执行无样本、无引擎初始化的工作进程启动检查，最长 2 秒，然后固定完整文件 SHA-256。这样兼容 roothide 首次执行的引导标记／签名页更新；运行中的代码、签名或数据变化仍会被拒绝，不忽略指纹中的字节。
- 单次只执行一个分析任务；取消、超时、协议损坏、输出超限和宿主退出都会停止并回收相应工作进程及快照。
- 内部帧最大 1 MiB、诊断累计最大 1 MiB、对外成功数据最大 256 KiB。过大结果报错，不静默截断伪代码。尚无独立的进程内存硬限额。
- 仅允许固定操作和严格十六进制函数入口；不提供任意 radare2 命令、表达式或写文件接口。

## 对应源码与离线重建

每个软件包自身携带完整对应源码归档，而不是只提供下载地址。清单旁的 `licenses/source.json` 记录归档文件名与 SHA-256。归档保留完整上游原始依赖、版权及许可，以及本扩展全部源文件和构建、静态链接配方。

在有 C/C++ 工具链、iPhoneOS SDK、make、Python 3、ar、lipo、strip、ldid 的 iOS 原生环境，将归档解至一个独立工作目录。在该目录的已准备工具链环境运行：

```sh
RA_OFFLINE=1 python3 Extensions/AgentTools/ReverseAnalysis/Scripts/rebuild.py --arch arm64e
# 通用 ARM64 切片：将 --arch 改为 arm64
```

环境需提供原生编译器可识别的项目根目录、`SDKROOT` 和工具链 `PATH`。构建脚本使用现有项目环境的 `APELIN_PROJECT_ROOT`，不将设备随机安装根路径写入源码或产物。输入归档固定版本与 SHA-256；离线模式拒绝缺失依赖，不安装任何系统软件。编译器包装器处理路径视角并在每次链接后使用随附权限签名。

正式原生打包默认在 `build/reverse-analysis/distribution/native-v2/<架构>/runtime/` 保存协议程序、独立工作进程、SLEIGH 数据与数据摘要；直接离线重建默认使用 `distribution/v1/`，CI 使用独立的 `distribution/ci-v1/`，三者不混用对象。只修改协议程序或 `Worker.c` 会复用摘要核验后的上游对象；修改引擎构建配方时指定新的非空 `RA_BUILD_TAG`，不会悄悄混用旧对象。可重新编译、链接、签名和替换工作进程；无额外禁止调试、为修改而逆向或替换的限制。

## 交叉编译与安装包

GitHub 的独立工作流分别编译 arm64 和 arm64e，使用独立的 macOS 宿主生成器和明确指定 iOS target 的编译器。它静态核验架构、平台、系统动态依赖、签名权限、私有路径与语言数据摘要，保存完整对应源码和许可；不在 Mac 上执行 iOS 程序。专用 `xcode-27` runner 不在线时仍待检查。

编译通过后，打包任务只封装同一轮已核验的切片，不重新编译引擎：roothide 包含 arm64e，rootless 同时包含 arm64 与 arm64e。每个 `.deb` 内含完整对应源码及上游许可，生成后重新读取软件包逐文件核对内容与权限。

主分支成功构建会在仓库的 Releases 页面生成独立的 `reverse-analysis-v…` 预发行版，不替换主应用的最新版。版本形如 `0.1.3+ci.<运行序号>`；附件包括两份 `.deb`、完整对应源码、包内核验报告与 `SHA256SUMS`。Actions 的 `reverse-analysis-ios-…` 仍是单架构编译产物，不是安装包；需要安装时下载发行版中的 `.deb`，用你选择的软件包管理器安装，不要把两个引导类型混用。

这些检查不安装软件包，也不替代主应用工具发现、真实会话调用及设备功能验收。

构建隔离契约可以在已有 Python 3 与 bash 的项目环境中独立运行，不下载依赖：

```sh
python3 -m unittest discover -s Tests/ReverseAnalysis -p 'test_*.py' -v
```

## 许可边界与真实限制

协议服务器沿用仓库 MIT；静态工作进程整体按 GPL-3.0-only 交付，所有上游文件保留原始许可。通知、LGPL/GPL 原文、Apache、BSD、Capstone、zlib 等声明随包保留。引擎、数据和对应源码仅属于本独立扩展，不进入主应用的许可证集合或分发产物。

静态引用不等于已执行路径；间接调用、Objective-C 消息派发、Swift 类型恢复、去符号、混淆和大型真实应用尚未完成准确性验收。不支持胖二进制输入、加密输入或恢复原始工程。进程隔离与输入限制不代表恶意样本安全审计。

本机可独立构建和验收此扩展；主应用仍需在具备 Xcode 的环境运行完整 `make check`。独立测试不替代主应用检查或安装后工具发现验收。
