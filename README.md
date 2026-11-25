# Win-AAP-Kernel

荣耀 WIN (AAP-AN00) 纯 GKI 内核 · CI (GitHub Actions) 构建

## 设备信息

| 项 | 值 |
|---|---|
| 设备 | 荣耀 WIN |
| 型号 | AAP-AN00 |
| 内核主线 | Linux 6.12.58 |
| 内核代际 | common-android16-6.12 (GKI) |
| 路线 | 纯 GKI（不集成 KSU / SUSFS / KPM） |

## 源码来源

- 荣耀官方开源源码包：`AAP-AN00_MagicOS11.0_Opensource.zip`（648 MB，多层嵌套压缩）
- 构建工具链：AOSP kernel/common（`common-android16-6.12`）+ kernel/build（Kleaf）

## 构建方式

在 CI 中拉取源码并构建，本地只维护配方。触发为**手动**（workflow_dispatch）。

流程：
1. 清理磁盘空间
2. 动态查询荣耀开源中心接口，获取当前有效下载链接（解决链接过期问题）
3. aria2 多线程下载源码包（curl -L 兜底，带 Referer 防盗链）
4. 递归展开多层嵌套压缩包
5. repo 拉取 AOSP kernel（common-android16-6.12）
6. 荣耀 kernel 覆盖 common
7. kleaf 编译三个 target（Image / boot.img / system_dlkm）
8. 打包 AnyKernel3 刷机包

构建命令：
```
tools/bazel build --config=fast \
  //common:kernel_aarch64 \
  //common:kernel_aarch64_gki_artifacts \
  //common:kernel_aarch64_images
```

## 产物

- `AAP-AN00-GKI-AnyKernel3-*.zip` —— AnyKernel3 刷机包（含 Image）
- `system_dlkm.ext4.img` / `system_dlkm.erofs.img` —— 自编 GKI 模块镜像

## 使用

1. 到 Actions 页手动触发 `Build GKI (AAP-AN00)`
2. 从 artifacts 下载 AnyKernel3 刷机包
3. 用自定义 Recovery（如 TWRP）刷入，或解包后 fastboot 刷 boot

## 许可证

本工程产出物为 GPL-2.0 衍生作品，第三方组件许可证详见 [NOTICE.md](NOTICE.md)。

## 免责声明

自编译内核刷机风险自负。本仓库由 AI（Operit）参与构建与验证。
