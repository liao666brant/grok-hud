# Grok HUD

Grok Build 的非官方额度监测插件。在状态栏中查看账户用量、重置时间、会话成本和 Token，也可以导出中文 HTML 看板。

**Windows x64 / Linux x64 · Rust 原生 · 0.5.0 · MIT License**

[下载最新版](https://github.com/liao666brant/grok-hud/releases/latest) · [版本记录](https://github.com/liao666brant/grok-hud/releases) · [反馈问题](https://github.com/liao666brant/grok-hud/issues)

## 功能

- **账户额度**：服务端已用百分比、Build / Chat 占比和实际重置时间。
- **会话统计**：生成中按本地流式事件更新 `≈` Token 和费用，结算后切回真实值；支持恢复会话时按准确的会话 ID 读取账本。
- **生成指标**：会话缓存命中率、最近轮次输出速度和首字等待时长；生成等待期间实时增长。
- **环境计数**：状态栏显示已加载的 Skill 与 MCP 服务器数量。
- **自动刷新**：活跃时约 10 秒查询账户，回答结束后主动查询并按需补查。
- **本地看板**：每日成本、模型消耗、数据质量、明暗主题及摘要导出。
- **历史估算**：记录额度样本，估算周限与耗尽时间，并标明未知、旧数据和不完整统计。

预编译分发包无需 Python、Node.js 或 Rust。独立查询和后台监测不调用模型；通过 `/budget` 让 Grok 解释结果可能消耗模型额度。

> 账户百分比来自服务端；美元和 Token 周限是本地估算，不是官方上限。本机成本是账本记录值，不等于订阅实际扣款。

## 快速开始

### 环境要求

- Windows x64 或 Linux x64，已安装并登录 Grok Build。
- Windows：已验证 **Grok Build 1.0.41**；Linux 尚待真机验收。其他版本未逐一验证。
- Linux：安装器需要 `jq`；自动刷新需要可用的 systemd 用户会话（`systemctl --user`），无 systemd 时安装仍完成，只是跳过后台监测。
- Windows 自动刷新需要系统允许创建当前用户的 Windows 计划任务。

### 下载与安装

从 [Releases](https://github.com/liao666brant/grok-hud/releases/latest) 下载对应平台的 ZIP，解压后在分发包根目录运行安装器。

Windows（PowerShell）：

```powershell
./install.ps1
```

Windows 也可以不下载 ZIP，直接从 GitHub 运行安装器：

```powershell
irm https://raw.githubusercontent.com/liao666brant/grok-hud/main/install.ps1 | iex
```

该命令从最新 Release 下载 `GrokHUD-windows-x64.zip` 并校验 SHA-256，解压到 `%USERPROFILE%\.grok\grok-hud\source` 后安装；重复执行同一命令即可更新。校验文件不可用或哈希不匹配时，安装器会退出。若该 Release 尚未提供 Windows 包，安装器会提示并退出，此时请按上面的方式下载 ZIP 后手动运行 `./install.ps1`。

Linux（POSIX shell）：

```bash
./install.sh
```

Linux / WSL 也可以不下载 ZIP，直接从 GitHub 运行安装器：

```bash
curl -fsSL https://raw.githubusercontent.com/liao666brant/grok-hud/main/install.sh | sh
```

该命令从最新 Release 下载 `GrokHUD-linux-x64.zip` 并校验 SHA-256，解压到 `~/.grok/grok-hud/source` 后安装；重复执行同一命令即可更新。校验文件不可用或哈希不匹配时，安装器会退出。若该 Release 尚未提供 Linux 包，安装器会提示并退出，此时请按上面的方式下载 ZIP 后手动运行 `./install.sh`。

安装器会注册插件、配置状态栏，并启动当前用户的后台监测。监测使用普通用户权限、隐藏运行，不保存登录密码；登录时自动启动，退出或被停止后每分钟自动拉起，运行中的实例不会重复启动。Windows 通过计划任务 `GrokHudMonitor` 实现，Linux 通过 systemd 用户单元 `grok-hud-monitor.service` 和 `grok-hud-monitor.timer` 实现。

Linux 分发包中的二进制沿用 `.exe` 文件名，使插件 hooks 与清单在两个平台保持一致；Linux 对可执行文件扩展名没有要求。

**安装或更新后，请重新启动 Grok 客户端，让定时配置和 hooks 生效。** 安装器不会主动结束当前会话。

发布页提供 SHA-256 校验文件。Windows 用 `Get-FileHash <下载的ZIP路径> -Algorithm SHA256` 核对；Linux 在 ZIP 所在目录执行 `sha256sum -c <下载的ZIP路径>.sha256` 核对。

## 使用

在分发包根目录直接调用原生程序（两个平台相同）：

```sh
# 查询额度与本机统计
./grok-hud/grok-hud.exe

# 主动刷新服务端数据
./grok-hud/grok-hud.exe --refresh

# 输出 JSON 摘要
./grok-hud/grok-hud.exe --json

# 只读历史快照，不联网、不刷新本机统计
./grok-hud/grok-hud.exe --offline

# 持续采样；Ctrl+C 停止
./grok-hud/grok-hud.exe --watch 10

# 生成看板
./grok-hud/grok-hud.exe --html output/grok-hud.html
```

Windows 用 `Start-Process ./output/grok-hud.html` 打开，Linux 用 `xdg-open ./output/grok-hud.html` 打开。

新 Grok 会话中的 `/budget` 可以让模型解释查询结果。看板是静态快照，刷新浏览器不会重新查询；需要新数据时，再执行一次 `--html` 导出命令。

`--no-color` 或环境变量 `NO_COLOR` 可关闭颜色。默认读取当前用户的 `.grok` 目录；`GROK_HOME` 或 `--grok-home` 可指定其他目录，`--data-dir` 可指定插件数据目录。独立查询可直接运行，自动后台刷新需要先安装。

## 状态栏怎么看

示意数据（100 列）：

```text
词元 1.64M │ 缓存率 93.8% │ 输出: 217.0 tok/s │ 首字 3.3s │ 费用 $0.53 │ ⚡ 技能 33 │ 🔌 MCP 2
用量 4% (重置剩余 6d 12h) | 本机 $1.54 · 5.94M 词元 | 周限 ≈$51.19 · ≈197.89M 词元
```

排版按 claude-hud 的源码对齐：第一行是会话行，各部分用 ` │ ` 连接（对应 claude-hud 的项目行），费用之后是技能与 MCP 计数；第二行是用量行，各部分用 ` | ` 连接（对应其 usage 元素内部）。用量只显示百分比，不画进度条（对应 claude-hud 关闭进度条的模式），重置时间是倒计时括注「重置剩余 …」。同一行放不下时逐元素换行，整体不超过 Grok 的 5 行上限。

| 字段 | 含义 |
| --- | --- |
| 费用 | 当前会话累计成本；`*` 表示统计不完整 |
| 词元 | 当前会话累计输入＋输出 Token |
| 缓存率 | 会话输入 Token 中命中读取缓存的比例；无数据时隐藏 |
| 输出 | 最近已结算轮次的输出速度：输出 Token ÷ 各次调用首字到最后一字的生成时长之和；输出不足 100 Token 的轮次不显示。`≈` 表示账本计费含未随流输出的推理 Token（推理不外露的模型） |
| 首字 | 最近一次模型调用从开始到首个输出 Token 的等待时长；生成等待期间该值实时增长，首字落地后冻结 |
| 技能 | ⚡ 已加载的 Skill 数量；数量为 0 时隐藏 |
| MCP | 🔌 配置中的 MCP 服务器数量；数量为 0 时隐藏 |
| 用量 | 服务端账户已用百分比；括注为重置倒计时 |
| 本机 | 本周期本机成本和 Token |
| 周限 | 美元和 Token 预估上限，使用 `≈` 标记 |
| 旧数据 | 服务端额度接口暂不可用时在用量括注里提示 |

标签按语义着色：蓝＝数量（词元、用量），青＝缓存与技能，绿＝输出与 MCP，黄＝时间与限额（首字、周限），品红＝金额（费用、本机）；数值保持默认色，技能与 MCP 的标签和数值同色，生成中为暗色；用量百分比亮蓝，达到 75% / 90% 时转为亮品红 / 红色；倒计时为默认色。图标为 emoji，颜色由终端 emoji 字体呈现，需要终端字体支持（Windows Terminal 默认支持）；`NO_COLOR` 只关闭 ANSI 颜色，图标照常显示。

`$--` / `--` 表示未知，`*` 表示统计不完整，“旧数据”表示查询失败、样本超过 180 秒或周期已结束。额度暂不可用时，仍尽量显示当前会话统计。

## 刷新机制

状态栏和 hooks 只提交信号，由独立后台任务统一查询。同一账户的多个会话共用缓存与请求预约。

| 场景 | 行为 |
| --- | --- |
| 状态栏显示 | 每 1 秒重新读取本地结果；会话状态变化也会触发更新 |
| 生成中 | 按当前会话的新流式事件更新会话与本机累计 Token、费用估算，标注 `≈`；账本结算后去掉估算增量。账本文件还没写出时，流里已结束轮次的 `usage` 作为基数。客户端 Token 已经更高而费用还没到时，保留该 Token 数，并用已结算单价补上会话金额 |
| 活跃会话 | 账户额度约每 10 秒查询一次 |
| 空闲会话 | 账户额度约每 60 秒查询一次 |
| 会话启动 / 恢复 | 提交立即查询信号，受请求合并和最低间隔限制 |
| 回答结束 | 提交约 2 秒后的查询；额度信息未变化时，约 10 秒后补查一次 |
| 无会话信号 | 最后一次状态栏 / hook 信号超过 20 秒后，不再自动访问额度接口 |
| 后台退出或被停止 | 由 Windows 计划任务或 Linux watchdog timer 在下一个一分钟触发点自动拉起；用户必须处于登录状态，系统须可运行任务 |
| 手动刷新 | 跳过普通缓存等待，不重复发起进行中的请求，也不绕过服务端限流 |

自动请求至少间隔 5 秒，刚完成的查询可能合并或推迟事件请求。最后一次活跃信号后保留 60 秒活跃窗口；实际显示延迟还受服务端记账和状态栏刷新时机影响。

本机统计按账本文件变化刷新，聚合缓存最多保留 10 秒。新显示统计不会写回历史估算样本：JSON 的 `local` 为额度采样时的统计，`live_local` 为本次显示统计，`local_refreshed_at` 为显示统计更新时间。

状态栏的流式估算读取当前会话的 `updates.jsonl`：每次模型调用的上下文数量只计一次，文本按 ASCII 约 4 字符 / Token、其他字符约 1 字符 / Token 粗估；可见思考文本也计入。费用按最近 20 条同模型已结算记录的平均美元 / Token 估算，没有匹配历史时显示 `$--`。生成时 Token 按与结算后相同的 K/M/B 缩写显示，金额显示四位小数。

这些是临时显示值，可能遗漏隐藏推理、工具参数、并行子代理和缓存折扣差异，结束校正时可以下降。本机累计只叠加当前状态栏所属会话的未结算估算，其他会话在账本更新后计入。估算不会写入历史样本、周限或耗尽时间计算，也不会用于推算服务端百分比。

刷新速度受 Grok 将事件写入文件的时机限制：没有新事件时不会凭时间虚增。超过 16 MiB 的当前轮事件无法完整读取时保留已结算值。账户百分比、重置时间仍来自约 10 秒一次的接口查询，周限在取得新额度样本时重算；它们不是逐 Token 推送。定时回调即使携带旧数据，插件也会重新读取对应会话账本。

网络请求最多等待 5 秒。普通失败按 10、20、40 秒逐步退避，最高 5 分钟；401/403 自动等待 5 分钟，重新登录后可手动刷新；429 遵守 `Retry-After`。

## 数据来源与估算

| 数据 | 来源与范围 |
| --- | --- |
| 账户占比 | 官方 `https://cli-chat-proxy.grok.com/v1/billing?format=credits` 接口；`creditUsagePercent` 的 1.0 表示 1% |
| 周期与重置 | `currentPeriod.start/end`，不假设自然周或周一重置 |
| Build / Chat 占比 | `productUsage`，接口未返回时保持未知 |
| 本机成本 | 周期内已结束轮次的 `costUsdTicks / 10^10` |
| 累计 Token | 去重后的 `totalTokens`，不重复加上已包含的缓存或推理 Token |
| 周限 | 根据成本与占比推算，接口未公开美元或 Token 周上限 |
| 缓存率 | 会话取账本 `cachedReadTokens ÷ inputTokens`（输入含缓存），周期报告取同口径累计；两者都缺失时用状态栏载荷的三个互斥缓存桶兜底 |
| 速度 / 首字 | 会话目录内部事件流 `events.jsonl` 的时间戳（`loop_started`、`first_token`、逐块 `phase_changed`、`turn_ended`），只读取时间与相位，不读取内容；该文件未随版本承诺，字段变化时相关指标自动隐藏 |
| 技能 / MCP 数量 | 磁盘配置计数。Skill 统计用户 `skills`、内置 `bundled/skills`、已启用插件的 `skills` 和项目 `.grok/skills` 下含 `SKILL.md` 的目录，按目录名去重；MCP 统计用户与项目 `config.toml` 的 `[mcp_servers]` 表、项目 `.mcp.json` 和已启用插件的 `.mcp.json`，按名称去重；Grok 内置 MCP 服务器（如 `tasks`）没有磁盘定义，不计入 |

账本按轮次事实去重、按结束时间归入周期。其他设备、Chat、进行中的调用和动态折扣会造成偏差；账本没有账户归属，切换账户后可能混入旧账户记录。

<details>
<summary>估算公式与适用条件</summary>

优先使用 Build 产品占比。同账户、同周期、无占比和成本回退，占比增量至少 3 个百分点、样本间隔至少 60 秒时：

```text
预估美元周限 = 成本增量 ÷ Build 占比增量 × 100
```

样本不足时使用低可信度粗估：

```text
预估美元周限 = 本周期本机成本 ÷ Build 占比 × 100
预估 Token 周限 = 预估美元周限 × 同次采样 Token ÷ 同次采样成本
```

缺少可用占比、0% 或 100% 封顶、非周周期、成本缺失、账本不完整时不估算。缺少 Build 占比且已有 Chat 消耗时，不直接用账户总占比反推美元周限。产品占比与共享周池的换算没有官方说明，估算依赖本机消耗覆盖率和计费权重稳定的假设。

敏感区间假设每个百分比端点存在 ±1 个百分点误差；它不是统计置信区间，也不保证覆盖真实上限。1% 单样本无法约束上界。

耗尽时间使用账户总占比（包含 Chat），要求至少 30 分钟的单调样本跨度和至少 1 个百分点变化；它只是按历史增速外推。

</details>

## 更新与卸载

下载新版本后运行 `./install.ps1`（Windows）或 `./install.sh`（Linux），两个平台也可以重复执行上面的一行安装命令。若同名插件来自另一个仍存在的目录，安装器会停止；使用原安装来源目录更新，或加 `-ReplaceSource`（Windows）/ `--replace-source`（Linux）让安装器改为当前目录。

从旧 `grok-budget` 安装升级时，安装器会先停止旧计划任务 / systemd 单元并禁用旧插件，把 `.grok/grok-budget` 的数据目录（包括 `history.sqlite3`、WAL/SHM 文件和旧备份）完整合并到 `.grok/grok-hud`。新监测启动并验证成功后，安装器才移除旧的计划任务 / systemd 单元、卸载旧插件并删除旧数据目录；如果新监测安装失败，会恢复原有监测并重新启用旧插件。

安装前会将旧配置、新旧插件副本、注册信息及已有任务或单元定义（包括旧 `grok-budget` 定义）备份到 `.grok/grok-hud/backups/<时间>/`。历史数据库位于 `.grok/grok-hud/history.sqlite3`，更新时保留数据。

安装器生成的状态栏启动入口（Windows 为 `.grok/grok-hud/statusline.cmd`，Linux 为 `.grok/grok-hud/statusline.sh`）是 Grok 的兼容启动入口，需要保留。仓库和分发包不再提供额外的 `.cmd` 包装脚本。

```powershell
./uninstall.ps1
```

```bash
./uninstall.sh
```

卸载脚本会先停止并禁用后台监测的触发器（Windows 计划任务 / Linux systemd 用户单元），移除属于本插件的状态栏配置，再通过 Grok 卸载插件。历史、运行文件和备份保留；重启 Grok 后生效。

## 常见问题

**安装后状态栏没变化？**

重新启动 Grok 客户端。Grok 在启动时读取配置，已经打开的客户端可能继续使用旧定时设置。

**一直显示旧数据？**

先运行 `./grok-hud/grok-hud.exe --refresh` 查看错误。登录失效时打开 Grok 刷新登录，必要时执行 `grok login`。后台状态可通过以下命令查看：

```powershell
Get-ScheduledTask -TaskName GrokHudMonitor | Select-Object TaskName, State
Get-ScheduledTaskInfo -TaskName GrokHudMonitor | Select-Object LastRunTime, LastTaskResult
```

```bash
systemctl --user status grok-hud-monitor.service
systemctl --user list-timers grok-hud-monitor.timer
```

0.3.1 起，后台停止后通常在一分钟内恢复；`Running` / `active` 表示正在运行。需要立即启动：Windows 执行 `Start-ScheduledTask -TaskName GrokHudMonitor`，Linux 执行 `systemctl --user start grok-hud-monitor.service`。如需持续暂停：Windows 先 `Disable-ScheduledTask -TaskName GrokHudMonitor` 再 `Stop-ScheduledTask -TaskName GrokHudMonitor`；Linux 先 `systemctl --user disable grok-hud-monitor.timer`（关掉 watchdog）再 `systemctl --user stop grok-hud-monitor.service`；恢复时对应执行 enable 和 start。单独停止服务会被自动拉起。

**为什么金额变了，百分比没变？**

金额来自本机账本，百分比来自服务端，两者的更新时机与统计范围不同。服务端记账也可能延迟。

**会上传聊天内容吗？**

流式估算会在本机读取当前会话的事件文本以统计字符，不保存或上传正文；速度与首字指标只读取会话事件流的时间戳和相位标记，不读取文本内容。登录令牌仅在内存中用于固定官方 HTTPS 接口，拒绝重定向，不打印、不入库、不自行刷新。SQLite 保存账户哈希、额度、汇总信息和刷新调度状态，额度样本保留 90 天。HTML 看板没有外部资源或追踪。流式估算仅用于状态栏，独立 JSON / HTML 报告仍使用已结算统计。

## 从源码构建

需要 rustup；Windows 另需 C++ 构建工具，Linux 需要 `jq`、`unzip`、coreutils（`sha256sum`），以及 `zip` 或 Linux 原生 7-Zip（`7zz`/`7z`）。`rust-toolchain.toml` 固定 Rust 1.96.0、rustfmt 和 Clippy。在仓库根目录执行：

Windows：

```powershell
./scripts/build.ps1
./install.ps1
```

Linux：

```bash
./scripts/build.sh
./install.sh
```

构建脚本检查格式、运行 release 测试和 Clippy、检查脚本语法与监测定义（Windows 检查 PowerShell 语法与计划任务定义，Linux 用 `sh -n` 与 systemd 单元定义测试），然后生成对应平台的 ZIP 和 SHA-256。打包时逐文件核对内容，并执行解压后的程序验证版本。仅编译时执行 `cargo build --release --locked`，程序位于 `target/release/grok-hud`（Windows 为 `grok-hud.exe`）。

真实恢复测试需在已登录的用户会话执行：Windows `powershell -NoProfile -ExecutionPolicy Bypass -File tests/monitor-task.ps1 -Integration`；Linux `sh tests/monitor-service.sh -Integration`。两者都使用独立定义和无登录凭据的测试目录，验证停止后自动恢复及多次启动只保留一个实例，最后移除测试单元。CI 运行定义、程序格式与退出码测试；真实恢复测试在对应平台的本机验收。

GitHub Actions 在推送和 PR 时构建、测试并保存两个平台的 ZIP；推送与清单版本一致的 `v*` 标签后，仅在全部检查通过时上传 GitHub Release。版本说明见 [CHANGELOG.md](CHANGELOG.md)。

| 路径 | 内容 |
| --- | --- |
| `src/` | 额度接口、账本统计、缓存调度和终端显示 |
| `grok-hud/` | 插件清单、hooks、`/budget` 命令及内嵌看板模板 |
| `install.ps1` / `uninstall.ps1` | Windows 安装、更新与卸载 |
| `install.sh` / `uninstall.sh` | Linux 安装、更新与卸载 |
| `scripts/monitor-task.ps1` | Windows 计划任务定义（安装器与测试共用） |
| `scripts/monitor-service.sh` | Linux systemd 用户单元定义（安装器与测试共用） |
| `scripts/migrate-data.*` | 旧数据目录迁移（安装器与测试共用） |
| `scripts/build.*` / `scripts/package.*` | 各平台构建检查与发布包生成 |
| `.github/workflows/build.yml` | 双平台 CI 与标签发布 |
| `tests/monitor-task.ps1` / `tests/monitor-service.sh` | 后台监测定义与真实恢复测试 |
| `tests/migrate-data.*` / `tests/install-bootstrap.sh` | 数据迁移与 GitHub 引导安装测试 |
| `tests/native.rs` | 数据口径、刷新调度、并发与显示回归测试 |
| `tests/speed.rs` | 生成指标、排版合并与端到端状态栏测试 |

本仓库只包含 Grok HUD 插件，不包含 Grok Build 本体、账户凭据或使用历史。使用 [MIT License](LICENSE) 发布。

## 致谢

本项目 fork 自 [CodingChiao/grok-budget](https://github.com/CodingChiao/grok-budget)：额度监测、账本统计、后台监测与安装器的实现均来自该上游仓库。
