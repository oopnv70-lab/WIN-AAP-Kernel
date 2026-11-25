# NOTICE

本仓库（`oopnv70-lab/Win-AAP-Kernel`）是荣耀 WIN（AAP-AN00）纯 GKI 内核的第三方构建工程。
仓库根目录 `LICENSE` 为 **GNU General Public License v2.0（GPL-2.0）**，适用于本仓库的自有代码
与内核衍生部分。以下第三方组件分别适用其各自的许可证，特此逐项声明。

## 第三方组件许可证清单

| 组件 | 许可证 | 仓库链接（含分支） | LICENSE 文件 | 用途 |
| --- | --- | --- | --- | --- |
| 荣耀 AAP-AN00 开源源码（Linux 内核 6.12.58） | GPL-2.0 | https://www.honor.com/global/opensource/ （按型号 `AAP-AN00` 检索，包名 `AAP-AN00_MagicOS11.0_Opensource.zip`；文件 URL 为实时签名、会过期，故只记入口） | `LICENSES/GPL-2.0.txt` | 编译内核本体 |
| AOSP kernel/common（`common-android16-6.12` 分支） | GPL-2.0 | https://android.googlesource.com/kernel/common （分支 `common-android16-6.12`，经 `kernel/manifest` 拉取） | `LICENSES/GPL-2.0.txt` | 内核源码基线（被荣耀源码覆盖） |
| AOSP kernel/build（Kleaf 构建工具链） | Apache-2.0 | https://android.googlesource.com/kernel/build | `LICENSES/Apache-2.0.txt` | Bazel/Kleaf 构建工具链 |
| AnyKernel3（osm0sis） | BSD-3-Clause | https://github.com/osm0sis/AnyKernel3 | `LICENSES/AnyKernel3-LICENSE.txt` | AnyKernel3 刷机包打包模板 |

各许可证全文见 `LICENSES/` 目录：
- `GPL-2.0.txt` —— GNU GPL v2.0 标准原文（荣耀内核 / AOSP kernel/common 共用）
- `Apache-2.0.txt` —— Apache License 2.0 标准原文（AOSP kernel/build）
- `AnyKernel3-LICENSE.txt` —— AnyKernel3 的 BSD-3-Clause 许可证原文

> 注：`GPL-3.0.txt` 也随仓库保留，但本工程当前**未**集成任何 GPL-3.0 组件（无 SukiSU-Nova /
> SUSFS / KPM），仅为将来可能的扩展预留。

## 重要说明

1. **内核为 GPL-2.0 衍生作品**：本工程产出物（Image / AnyKernel3 刷机包）包含 GPL-2.0 许可的
   内核代码，因此整体作为 GPL-2.0 衍生作品分发，须遵循 GPL-2.0 义务（含提供对应源码）。

2. **纯 GKI，无第三方内核补丁**：本工程只做荣耀官方源码的纯 GKI 构建，不集成 KSU、SUSFS、
   KPM 等任何第三方内核功能补丁。

3. **AI 参与声明**：本工程的构建脚本、CI 流程与集成方案由 AI（Operit）辅助编写与验证。
   刷机与使用风险自负。

4. **刷机风险**：自编译 GKI 未使用厂商私钥签名，AVB / vermagic 不匹配时刷入可能无法开机。
   请在解锁引导加载程序并理解风险后操作。
