# 后台运行模块

此模块将 Immortalizer 的场景保持与“启用前台通知”机制适配为只服务本应用的功能。

来源：https://github.com/CySxL/Immortalizer
固定参考提交：`4d716867c87a842cdb362d3078bafbfe359952c3`（2.8.5）。
原作者：Serge Alagon；原版权：Copyright (C) 2024 Serge Alagon。
本目录的 Objective-C 模块及其修改按 GPL-3.0-or-later 提供，完整许可见 LICENSE。

模块只注入 SpringBoard，不链接进主应用或守护进程；主应用只通过 Darwin 通知交换开关和状态。
安装包同时提供本目录对应源码和构建脚本，不以改写语法或代码隔离为由去除 GPL 义务。

## 行为与边界

- “后台保活”默认关闭；开启后保持本应用的场景，关闭后恢复系统最后请求的设置。
- “启用前台通知”默认开启；即使应用被保持为前台，也允许其通知正常递送。
- 仅修改本应用的场景副本，转交原 transition 与 completion；不吞整次场景更新，不全局屏蔽场景失活。
- 增加仅针对本应用的切换器卡片锁定，以及运行／停止、锁定标记的独立开关（均默认关闭）；不引入其他应用名单、控制中心或 AltList。
- 锁定不依赖后台保活开关，只防划掉本应用的单应用卡片；混合布局放行。关闭时恢复系统最后请求的 killable 原值，不强制把它改为 YES。
- 运行标记依据实际 PID，不把进程存在等同于持续执行。关闭显示后恢复原图标附件及名称；应用退出保留显示偏好以呈现停止状态，PID 与场景保持请求不持久化。
- 不绕过系统通知权限、专注模式或静音；主应用退出时撤销状态。
- 类或 ABI 不兼容时不安装 hook；模块未连接时设置页不显示“已生效”。
- 私有接口只在原项目覆盖的 iOS 16 系列内作为待验收目标，其他版本不能据此承诺支持。

首次安装模块后需重新加载 SpringBoard。后台持续运行、锁屏、通知点击、旋转与键盘仍须安装后逐项验证。

构建：在有 iPhoneOS SDK 的环境运行 `bash build.sh <输出dylib> roothide` 或
`bash build.sh <输出dylib> rootless`。成品按设备的注入机制安装到 bootstrap 的
`Library/MobileSubstrate/DynamicLibraries/`，旁边放同名过滤器；使用 `ldid -S` 签名。
源码与完整许可随包放在 bootstrap 的 `usr/share/apelin/ForegroundSource/`。
模块本身无担保；用户可以按 GPL 第3版或更新版本修改、重新构建及再分发。
设置 → 关于 → 许可证中的 Immortalizer 条目提供原作者声明和完整条款；后台运行页不再单设许可入口。
