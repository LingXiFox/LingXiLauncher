# M8 验证记录：Minecraft 运行时性能采集与自动调优

## 范围

M8 在 Apple Silicon 上提供可重复的启动器侧性能采集，并基于真实数据给出保守调优建议：

- 采集硬件、macOS、Java、Loader、Minecraft 版本、可见模组列表和实例 JVM 参数。
- 支持启动、资源重载、世界加载/区块生成、渲染工作负载；有界超时、取消、进程身份校验和退出原因标记。
- `startupSeconds` 优先使用日志中的首次菜单就绪时间，其次使用进程/菜单可观测时间；不使用猜测值。
- 只展示实际采集到的 CPU/内存采样；没有游戏内帧计数器时明确标记 FPS 不可用，不伪造帧率。
- 报告保存到 `dataRoot/performance/reports/<uuid>.json`，包含轮次、阶段、采样和证据。
- `PerformanceTuningEngine` 基于内存、CPU、Loader、模组数量和 macOS OpenGL 限制生成建议；应用修改前要求确认，支持恢复原设置。
- CLI：`lingxi performance benchmark|reports|tune`；GUI：实例详情「性能工作台」。

## 自动化测试

```
swift test --parallel --num-workers 4
Executed 316 tests, with 0 failures (0 unexpected)
```

`PerformanceTests` 覆盖 profile 持久化、报告比较、版本/渠道策略、调优应用与恢复，以及 mock 进程的基准流程。

## 真实基准

环境：Apple M5（10 core）/ 32 GB / macOS 27.2 / Java 17（Fabric）、Java 21（NeoForge）。

| 实例 | Loader / MC | 启动到菜单 | 总耗时 | 峰值 RSS | 备注 |
|---|---|---:|---:|---:|---|
| `m73-fabric` | Fabric 0.20.1 / 1.20.1 | 5.148 s | 7.197 s | 968,392,704 B | 无快速进入世界 |
| `m8-neoforge` | NeoForge 21.1.265 / 1.21.1 | 4.000 s | 8.604 s | 1,184,399,360 B | 含 2 个模组 |

FPS 未采集：Minecraft 没有向外部启动器暴露稳定帧计数器；报告明确写入 `No in-game frame counter was available.`，不使用 CPU 使用率冒充 FPS。原始指标摘要：[m8-benchmark-summary.json](evidence/m8-benchmark-summary.json)。

调优应用实测：将 `m8-neoforge` 的 `-Xmx` 从 8 GiB 调整到 6 GiB，报告记录启动 1.190 s、峰值 RSS 381 MiB；单轮数据仅用于验证“建议 → 确认 → 应用”的链路，不宣称 FPS 提升。

GUI 证据：

- [基准运行](evidence/m8-performance-benchmark.jpg)
- [调优建议](evidence/m8-performance-tuning.jpg)
- [应用结果](evidence/m8-performance-applied.jpg)
- [报告对比](evidence/m8-performance-reports.jpg)

## 已知限制

- 单轮/无预热基准会受系统缓存和后台负载影响；工作台允许配置预热轮数，但不会把一次结果包装成稳定结论。
- 世界加载、区块生成和渲染工作负载需要有可快速进入的世界；未指定时报告会明确说明负载未测量。
- 外部进程无法读取 Minecraft 内部帧时间，因此 FPS/1% low 目前不可用。

## CI 与提交

- 随 M7.3/M8 提交 `3683638` 一同验证；CI [run 40976695758](https://github.com/LingXiFox/LingXiLauncher/actions/runs/40976695758) success。
- 316 tests / 0 failures，Release CLI/GUI 与 App Bundle 通过；Artifact `LingXiMac-ci-368363857f28363e42c2aed5205d0582b77ffe03.zip` 仅用于测试。
