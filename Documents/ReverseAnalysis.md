# 原生逆向分析工具：功能与使用

这是一个独立的 iOS 原生分析扩展，用来理解未加密 ARM64 Mach-O 的静态结构。它分析的是可执行文件，不会运行样本，也不是把汇编交给语言模型改写成伪代码。

## 四项功能分别解决什么问题？

| 工具 | 作用 | 适合提出的问题 |
| --- | --- | --- |
| `analyze_functions` | 列出静态分析发现的函数，按地址排序并分页；不只是读取已有符号表 | 这个文件有哪些函数？目标函数入口在哪里？ |
| `analyze_cfg` | 返回指定函数的基本块、指令及控制流边 | 这个函数如何分支、循环和返回？ |
| `analyze_references` | 查询函数的入向或出向静态引用 | 谁调用了这个函数？这个函数又调用了谁？ |
| `decompile_function` | 用原生 Ghidra 组件生成 C 伪代码、地址注解与 P-code | 这个函数大致在做什么？它的条件和计算逻辑是什么？ |

伪代码是分析结果，不是原始源码。变量名、类型和结构可能需要人工修正；静态引用也不等于实际执行路径，尤其不能保证覆盖间接调用和 Objective-C 动态消息派发。

## 兼容性与安装

- 系统：越狱 iOS 16.0 及以上；支持 roothide 和 rootless 布局。
- 包标识符：`com.xyzl.agent-tools.reverse-analysis`。
- roothide 选择 `iphoneos-arm64e` 包；rootless 选择 `iphoneos-arm64` 包，后者包含 arm64 和 arm64e 执行切片。不要靠重命名互换软件包。
- 输入：最大 32 MiB、未加密的 arm64 或 arm64e **薄 Mach-O**。`arch` 必须与样本切片匹配。胖文件须先另行提取目标切片；不支持直接传入 `.app` 目录、加密文件或恢复完整工程。
- 运行时不需要 Java、Python 或桌面版 Ghidra。

需要取得本扩展单独的 `.deb` 后，在包管理器中确认并安装。主应用安装包不内置本分析引擎，安装主应用不等于已经安装本扩展；也不要把主应用的发行附件当作本扩展包。

当前记录的独立包版本为 0.1.2。本文不保证仓库 Releases 已经公开提供这个独立包；只有对应包和校验文件实际发布后，才应把它称为可下载版本。

## 在 Apelin 中使用

设计流程是：安装独立扩展后，让支持通用工具扩展协议的宿主重新枚举工具，在一次新会话中确认出现上述四个工具。然后直接描述要分析的文件、架构和目标，例如：

> 分析 `/绝对路径/样本`，架构为 arm64e。先列出函数，再查看目标函数的控制流、谁调用它，以及它的 C 伪代码。不要修改样本。

建议按以下顺序调用：

1. 用 `analyze_functions` 获取函数入口；需要更多函数时使用返回的分页位置。
2. 把返回的十六进制入口传给 `analyze_cfg` 或 `decompile_function`，不要把符号名、表达式或一整条引擎命令塞进 `address`。
3. 用 `analyze_references` 的 `direction: "in"` 查询入向引用，用 `"out"` 查询出向引用。
4. 将反编译结果与 CFG、引用及反汇编交叉核对，不把反编译器推断当成源代码事实。

工具参数示例；这些是 `args` 内容，不是完整协议帧：

```json
{"binary":"/绝对路径/样本","arch":"arm64e","offset":0,"limit":100}
{"binary":"/绝对路径/样本","arch":"arm64e","address":"0x100004000"}
{"binary":"/绝对路径/样本","arch":"arm64e","address":"0x100004000","direction":"in"}
```

示例地址必须替换为该样本实际返回的函数入口。全部工具接受 `timeout_seconds`，范围 0.001～60 秒，默认 15 秒；函数页大小 `limit` 为 1～500。宿主还可以用绑定 `binary` 参数的只读描述符附件替代路径。

**真实主应用中的安装、工具发现和会话调用仍待验收。**上面的流程是已实现协议的使用方式，不代表已经在当前安装的主应用上逐步验证过。

## 是否强制绑定 Apelin？

**不强制绑定运行，也没有将 Apelin 声明为软件包强制依赖。**协议服务和分析工作进程是独立可执行文件；引擎不链接进主应用或守护进程。

当前交付的是兼容 `ApelinToolHost` v1 的扩展。其他客户端或自己的脚本可以实现同样的握手和调用协议，不必引入主应用代码。但这不是现成的 MCP 服务、HTTP 服务或通用命令行前端，也没有单独的图形界面；其他客户端需要适配，不能承诺即插即用。独立运行仍要求兼容的 iOS 环境，不能把这些 iOS 可执行文件直接放到 Windows、Linux 或 macOS 上运行。

### 自己的宿主如何接入？

1. 找到协议程序 `xyzl-reverse-analysis`，保留同目录的 `xyzl-reverse-worker`、`sleigh/` 和 `data-sha256.json`。安装根路径在 roothide 上可能变化，客户端应在运行时定位，不能把某次设备路径写死。
2. 可先以 `--describe` 查看实际工具描述符；不要将其误当作反编译命令。
3. 启动协议程序，通过 stdin/stdout 读写 **一行一个 JSON**。stderr 是诊断，不是协议结果；客户端应持续读取，不能让诊断管道阻塞。
4. 先发送握手并等待成功响应，再发送调用；通过 `requestID` 对应结果或错误。一次只允许一个活动分析调用。

握手帧：

```json
{"protocolVersion":1,"type":"hello","requestID":"hello-1","supportedVersions":[1],"maxFrameBytes":1048576}
```

列函数帧：

```json
{"protocolVersion":1,"type":"call","requestID":"functions-1","tool":"analyze_functions","args":{"binary":"/绝对路径/样本","arch":"arm64e","limit":100}}
```

反编译帧；须先将地址替换为函数列表中的入口：

```json
{"protocolVersion":1,"type":"call","requestID":"decompile-1","tool":"decompile_function","args":{"binary":"/绝对路径/样本","arch":"arm64e","address":"0x100004000","timeout_seconds":15}}
```

取消当前请求：

```json
{"protocolVersion":1,"type":"cancel","requestID":"decompile-1"}
```

成功响应为 `type: "result"`，其中 `content[0].text` 是需要再解析一次的分析 JSON，包含 `data` 和 `meta`。失败为 `type: "error"`，检查 `error.code` 和中文 `error.message`；不要把失败或过大结果当作空的成功结果。关闭 stdin 会结束服务并清理工作进程。

只使用绝对路径调用时不需要附件通道。需要附件时，宿主额外建立 Unix datagram socket，通过 `APELIN_TOOL_ATTACHMENT_FD` 指定传入服务的 socket fd，使用 SCM_RIGHTS 传递文件描述符，并在调用帧中按附件 ID 绑定 `binary`。不要在 JSON 里发送一个数字，假定它在另一个进程中仍代表同一个文件。原生协议测试示例见 `Tests/ReverseAnalysis/verify_extension.py`。

## 资源边界和常见失败

- 输入会复制为只读私有快照，分析不会写回原始样本。每次重新计算输入内容摘要。
- 最多缓存两个分析会话；后台空闲 60 秒回收。每个会话最多处理 128 次任务。
- 取消、超时、损坏协议及输出超限会回收相应工作进程，不留下一个已经失败的会话继续使用。
- 内部帧和累计诊断各限 1 MiB，对外成功数据限 256 KiB。过大结果返回错误，不静默截断伪代码。
- 同一服务运行期间，工作进程或语言数据变化会被拒绝；更换组件后需重新打开服务。
- 目前没有独立的进程内存硬限额；进程隔离不等于已完成恶意样本安全审计。

## 已验证什么，尚未验证什么？

已在本机自有 arm64／arm64e 样本上验证四项能力、6 块 7 边 CFG、已知调用关系，以及每个样本 6003 次伪代码回编译结果核对。双 bootstrap 软件包中的执行切片已分别实际运行，并覆盖附件、缓存、超时取消、进程回收、组件变化拒绝和故障输出限额。

rootless 包是在同一台 roothide 设备上解包执行，不等于 rootless 实机安装验证。大型程序、去符号、混淆、Objective-C 动态派发、Swift 类型恢复、安装后工具发现与真实会话调用均未完成验收，不能宣称“任何程序都完美可用”。

GitHub 的 `.github/workflows/reverse-analysis.yml` 独立检查先运行构建隔离契约，再分别编译 arm64 和 arm64e 协议服务与静态工作进程。macOS 生成器单独使用 macOS SDK，最终程序明确指定 iPhoneOS SDK；静态核验架构、iOS 平台、动态依赖、签名权限、私有路径及语言数据摘要，不在 macOS 上执行 iOS 程序。

该检查沿用仓库的 `xcode-27` 专用 runner，要求 Xcode 27.1；没有匹配 runner 时会排队，不能当作已通过。成功时保存编译检查产物、完整对应源码和许可，不生成 `.deb`、不安装、也不自动发布本扩展。现有主应用自动编译／发行链保持独立；编译检查、主应用全量检查和设备验收不能相互替代。

## 源码与许可

协议服务使用 Objective-C、Foundation、POSIX 和 CommonCrypto；工作进程使用 C/C++、固定的 radare2 6.2.6 和 r2ghidra 6.2.6 原生组件。协议服务沿用 MIT，静态工作进程整体按 GPL-3.0-only 交付，各上游文件保留原始许可。

分析引擎、语言数据、许可通知及完整对应源码属于本独立扩展，不加入主应用的依赖或许可集合。离线重建与组件替换说明见 `Extensions/AgentTools/ReverseAnalysis/README.md`；本机验收方法见 `Tests/ReverseAnalysis/README.md`。
