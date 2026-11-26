# NOTICE
本仓库（`oopnv70-lab/WIN-AAP-Kernel`）是荣耀 WIN（AAP-AN00）自编译 GKI 内核的第三方构建工程。
仓库根目录 `LICENSE` 为 **GNU General Public License v2.0（GPL-2.0）**，适用于本仓库的自有代码
与内核衍生部分。该 `LICENSE` 为 GNU GPL v2.0 标准原文（自由软件基金会 FSF 发布，与 Linux 内核
`COPYING` 同文；经 commit `7916c7c` 引入，与 `LICENSES/GPL-2.0.txt` 内容一致）。以下第三方组件
分别适用其各自的许可证，特此逐项声明。

## 第三方组件许可证清单
| 组件 | 许可证 | 仓库链接（含分支） | LICENSE 文件 | 用途 |
| --- | --- | --- | --- | --- |
| 荣耀 AAP-AN00 开源源码（Linux 内核 6.12.58） | GPL-2.0 | https://www.honor.com/global/opensource/ （按型号 `AAP-AN00` 检索，包名 `AAP-AN00_MagicOS11.0_Opensource.zip`；文件 URL 为实时签名、会过期，故只记入口） | `LICENSES/GPL-2.0.txt` | 编译内核本体 |
| AOSP kernel/common（`common-android16-6.12` 分支） | GPL-2.0 | https://android.googlesource.com/kernel/common （经 `kernel/manifest` 拉取） | `LICENSES/GPL-2.0.txt` | 内核源码基线（被荣耀源码覆盖） |
| AOSP kernel/build（Kleaf 构建工具链） | Apache-2.0 | https://android.googlesource.com/kernel/build | `LICENSES/Apache-2.0.txt` | Bazel/Kleaf 构建编排 |
| Bazel（bazelbuild/bazel） | Apache-2.0 | https://github.com/bazelbuild/bazel | `LICENSES/Apache-2.0.txt` | Kleaf 底层构建引擎 |
| Clang/LLVM（AOSP prebuilts/clang） | Apache-2.0 WITH LLVM Exceptions | https://github.com/llvm/llvm-project （LICENSE.TXT） | `LICENSES/Apache-2.0.txt`（+ LLVM Exceptions 说明） | 内核 C 编译器 |
| pahole/dwarves（AOSP prebuilts/kernel-build-tools） | GPL-2.0 | https://github.com/acmel/dwarves （COPYING） | `LICENSES/GPL-2.0.txt` | BTF / 类型信息生成 |
| SukiSU-Nova（`builtin-new` @ `5a3ec414`，内置 KSU） | GPL-2.0 | https://github.com/SukiSU-Nova/SukiSU-Nova （分支 `builtin-new`，commit `5a3ec4145059ed2c4f22c70a16a28a616e104c33`；注意 main 分支为 GPL-3.0，本项目用 builtin-new 的 GPL-2.0） | `LICENSES/GPL-2.0.txt` | 内核级 root（内置 CONFIG_KSU=y） |
| SUSFS（susfs4ksu @ `9b0b13f0`） | GPL-3.0 | https://gitlab.com/simonpunk/susfs4ksu （分支 `gki-android16-6.12`，commit `9b0b13f069673b9b07b713a5c66977de4d62b175`） | `LICENSES/GPL-3.0.txt` | 文件系统隐藏 / 路径伪装 / SUS_MAP 等 |
| KernelPatch（SukiSU-Nova fork @ `1c5b6089`） | GPL-2.0 | https://github.com/SukiSU-Nova/SukiSU_KernelPatch_patch （分支 `main`，commit `1c5b608916357ac86a94cc736e235db1fac4a29d`；fork 自 bmax121/KernelPatch，已含 6.12 CFI/BTI/MTE 修复） | `LICENSES/GPL-2.0.txt` | KPM 加载器（编译后对 Image 后处理注入 kpimg） |
| AnyKernel3（osm0sis） | BSD-3-Clause | https://github.com/osm0sis/AnyKernel3 | `LICENSES/AnyKernel3-LICENSE.txt` | AnyKernel3 刷机包打包模板 |

各许可证全文见 `LICENSES/` 目录：
- `GPL-2.0.txt` —— GNU GPL v2.0 标准原文（荣耀内核 / AOSP kernel/common / SukiSU-Nova builtin-new / KernelPatch / pahole-dwarves 共用）
- `GPL-3.0.txt` —— GNU GPL v3.0 标准原文（SUSFS）
- `Apache-2.0.txt` —— Apache License 2.0 标准原文（AOSP kernel/build / Bazel / Clang-LLVM）
- Clang/LLVM 的 `LLVM Exceptions`（编译豁免 + GPLv2 兼容条款）全文见 https://github.com/llvm/llvm-project 的 `LICENSE.TXT`
- `AnyKernel3-LICENSE.txt` —— AnyKernel3 的 BSD-3-Clause 许可证原文

## 对应源码获取（GPL-2.0 义务）

本刷机包内的 `Image` 为 GPL-2.0 衍生二进制，按 GPL-2.0 第 3 条提供对应完整源码，具体获取方式：

1. **本仓库**：`https://github.com/oopnv70-lab/WIN-AAP-Kernel`（main 分支），含全部构建配方（`.github/workflows/build-gki.yml`、`scripts/`）与上游组件锁定 commit；构建本刷机包的确切 commit 见对应 Release / Actions 运行记录的 head_sha。
2. **荣耀官方内核源码**：入口 `https://www.honor.com/global/opensource/` → 按型号 `AAP-AN00` 检索 → 下载 `AAP-AN00_MagicOS11.0_Opensource.zip`（文件 URL 为实时签名、会过期，经上述入口重定向可重新获取有效链接）。
3. **AOSP 基线**：`https://android.googlesource.com/kernel/common`（`common-android16-6.12`）+ `https://android.googlesource.com/kernel/build`（Kleaf）+ `kernel/manifest`。
4. **上游补丁组件**：SukiSU-Nova / SUSFS / KernelPatch，仓库与锁定 commit 见上表。

## 重要说明
1. **内核为 GPL-2.0 衍生作品**：本工程产出物（Image / AnyKernel3 刷机包）包含 GPL-2.0 许可的内核
   代码，因此整体作为 GPL-2.0 衍生作品分发，须遵循 GPL-2.0 义务（含提供对应源码）。
2. **第三方内核功能补丁**：本工程集成 SukiSU-Nova（builtin-new，GPL-2.0）、SUSFS（GPL-3.0，编译期
   打补丁进内核源码）、KernelPatch（GPL-2.0，编译后对 Image 后处理）。其中 SUSFS 为 GPL-3.0，与内核
   主体 GPL-2.0 许可证不兼容，二者以「独立补丁 / 独立文件」形态并存分发，各按自身许可证约束。
3. **AI 参与声明**：本工程的构建脚本、CI 流程与集成方案由 AI（Operit）辅助编写与验证。刷机与使用风险自负。
4. **刷机风险**：自编译 GKI 未使用厂商私钥签名，AVB / vermagic 不匹配时刷入可能无法开机。请在解锁引导加载程序并理解风险后操作。
5. **构建工具链不随包分发**：刷机包仅含 `Image` 内核二进制与 AnyKernel3 打包脚本，不含 Clang/Bazel/pahole 等工具链。GPL-2.0 第 3 条豁免「操作系统主要组件（编译器、内核等）通常分发的东西」，Clang 的 LLVM Exceptions 亦豁免「编译产物中嵌入的 LLVM 部分」，故不触发工具链的源码分发义务；上表逐项声明仅为透明。
