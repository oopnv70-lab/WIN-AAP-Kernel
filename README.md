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

- 荣耀官方开源源码包：`AAP-AN00_MagicOS11.0_Opensource.zip`（648 MB，zip → tar.gz 两层嵌套）
- 构建工具链：Google ack（`common-android16-6.12`）

## 构建方式

在 CI 中拉取源码并构建，本地只维护配方。触发为**手动**（workflow_dispatch）。

流程：
1. aria2 多线程下载荣耀源码包（curl -L 兜底）
2. 两层解压：zip → tar.gz → Code_Opensource/{kernel,external,vendor}
3. repo 拉取 Google ack（common-android16-6.12）
4. 荣耀 kernel 覆盖 ack common
5. kleaf 构建纯 GKI 产物

构建命令：
```
tools/bazel run //common:kernel_aarch64_abi_dist --config=release
```

## 使用

1. 在仓库 Secrets 中配置 `SRC_URL`（荣耀源码下载链接，可选，缺省使用内置链接）
2. 到 Actions 页手动触发 `Build GKI (AAP-AN00)`
3. 从 artifacts 下载 GKI 产物

## 免责声明

自编译内核刷机风险自负。本仓库由 AI（Operit）参与构建与验证。
