---
name: auto-release
description: Detects and configures common application, library, native, mobile, desktop, and container repositories, then provides local test builds, deep .gitignore audits and safe rule completion, style-aware single or grouped commit-and-push, formal GitHub releases, dry-run previews, and JSON results. Supports Tauri, Node.js, Go, Python, Rust, .NET, Java, CMake, Flutter, Android, Electron, and Docker. Use when the user asks to build locally without changing version, inspect or complete Git ignore rules, stop tracking generated files without deleting them, classify changes into coherent commits and push them together, create release automation, or publish a semantic version such as v1.2.3.
---

# Auto Release

只执行当前仓库声明的项目步骤，不猜测或复用其他仓库的配置。用户未明确操作时，显示 `LocalBuild`、`Ignore`、`CommitPush`、`Release` 四项选择；不得把“本地打包”解释为正式发布。用户只说“忽略”时选择 `Ignore Audit`，先展示计划，不直接修改。

## 初始化项目

在仓库根目录运行独立的初始化器。`Detect` 只读，`GenerateLocal` 只创建本地构建配置，`Generate` 创建完整配置和工作流，`Validate` 检查现有配置：

```powershell
$setup = "$env:USERPROFILE\.codex\skills\auto-release\scripts\setup-project.ps1"
& $setup -Mode Detect -RepositoryRoot "<仓库根目录>"
& $setup -Mode GenerateLocal -RepositoryRoot "<仓库根目录>"
& $setup -Mode Generate -RepositoryRoot "<仓库根目录>"
& $setup -Mode Validate -RepositoryRoot "<仓库根目录>"
```

自动支持 Tauri、Node.js、Go、Python、Rust、.NET、Java、CMake、Flutter、Android、Electron 和 Docker。专用应用类型优先识别；其他多生态清单并存时，必须用 `-ProjectType` 显式指定类型。生成器会：

- 创建 schema v2 `.codex-release.json`。
- 配置提交信息自动分析；无法可靠确定最近风格时回退到 Conventional Commits。
- 创建标签触发的 `.github/workflows/release.yml`。
- 根据锁文件选择 npm、pnpm、Yarn 或 Bun。
- 为 Tauri 生成 Windows x64/ARM64、macOS Intel/Apple Silicon 和 Linux 构建矩阵。
- 为 Node.js 生成 `.tgz`，为 Go 生成 Windows/Linux/macOS 的 amd64/arm64 二进制。
- 为 Python 生成 wheel 与 sdist，为 Rust 生成 `.crate`，为 .NET 生成 `.nupkg`，为 Java 生成 `.jar`。
- 为 CMake 和 Electron 生成六平台压缩包，为 Flutter 生成移动端、桌面端和 Web 包，为 Android 生成 APK/AAB。
- 为 Docker 构建并推送 GHCR 多架构镜像，同时发布镜像摘要清单。
- 创建草稿 GitHub Release，等待本地发布流程校验后再公开。

若现有配置或工作流没有 Auto Release 或旧版 Project Release Automator 的托管标记，生成器必须停止，禁止覆盖。重复生成托管文件必须幂等。配置和工作流属于项目，应与代码一起提交；禁止写入 Token、密钥或账号凭据。完整字段见 [配置参考](references/config.md)。

生成后运行 `Validate`，再运行 `Plan`。在配置可解释且计划正确前不得进入 `Prepare`。

## 用户操作

统一入口：

```powershell
$invoke = "$env:USERPROFILE\.codex\skills\auto-release\scripts\invoke-release.ps1"
```

### 1. LocalBuild

用于本地测试，不修改版本，不提交、不推送：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $invoke -Operation LocalBuild -RepositoryRoot "<仓库根目录>"
```

用户要求预览或确认操作时追加 `-WhatIf`，不得修改配置、版本、构建产物、Git 或 GitHub。机器调用时追加 `-OutputFormat Json`，只依赖最后一行 JSON；失败结果包含 `stage`、`errorCode` 和 `message`。

只校验本地版本源、构建命令和产物，不得因 GitHub 工作流缺少标签触发器而阻止 `LocalBuild`。首次使用时调用 `GenerateLocal`，不得读取、覆盖或创建 GitHub 工作流；用户以后选择 `Release` 时再升级为完整发布配置。执行 `prepare.localCommands`；旧配置未声明时回退到 `prepare.commands`。先按 `prepare.bootstrapInputs` 和依赖命令计算缓存，仅在输入变化时执行 `prepare.bootstrapCommands`。保留构建工具的原始产物，并统一复制到 `<仓库根目录>/output/<项目名><扩展名>`。`output` 目录或目标文件不存在时自动创建，已存在时覆盖；目录名和文件名都不得包含版本号或标签。

默认先验证 `.git/auto-release/local-build.json` 的源码指纹和产物 SHA256，全部有效时直接复用；用户明确要求重新打包时传入 `-ForceRebuild`。生成配置优先使用快速本地命令：Tauri 不生成安装器，Python 只生成 wheel，Rust 执行 release build，.NET 执行 build，Electron 使用当前平台构建。只按完整路径终止当前配置产物或上次收据记录的 EXE，不得遍历并终止 `output` 中的无关程序。构建后只记录底层执行器返回的本次产物清单，清理上次由 Skill 管理但本次不再生成的旧输出；禁止因文件占用创建 `-2`、`-3` 等备用文件。状态文件不进入 Git，并兼容读取旧目录中的收据。

### 2. Ignore

深度检查仓库并补全缺失的 Git 忽略规则。默认只审计：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $invoke -Operation Ignore -IgnoreMode Audit -RepositoryRoot "<仓库根目录>"
```

审计项目清单、根和嵌套 `.gitignore`、当前 tracked/untracked/ignored 状态、构建输出、缓存、IDE/OS 文件、敏感路径、受保护文件和历史生成路径；计划写入 `.git/auto-release/ignore-plan.json`。只有用户确认后才使用 `Apply`；只有明确要求保留本地文件并停止 Git 跟踪时才使用 `ApplyAndUntrack`。

禁止把存在的凭据仅靠忽略隐藏，禁止删除本地文件，禁止宽泛执行 `git rm --cached .`，禁止自动重写历史。计划过期、托管标记异常、新规则隐藏锁文件/工作流或本地文件哈希变化时停止并回滚。完整行为见 [Ignore 参考](references/ignore.md)。本操作不提交或推送；需要时随后运行 `CommitPush`。

### 3. CommitPush

检查冲突和疑似密钥后，把更改区、暂存区、删除和未跟踪文件全部提交，并推送当前分支：

```powershell
$style = "$env:USERPROFILE\.codex\skills\auto-release\scripts\commit-style.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $style -RepositoryRoot "<仓库根目录>"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $invoke -Operation CommitPush -Summary "一句符合分析结果的中文总结" -RepositoryRoot "<仓库根目录>"
```

提交前分析最近 30 条非合并提交。至少 3 条样本且某种风格占比达到 60% 时沿用该风格；样本不足、并列或置信度不足时使用 Conventional Commits。支持识别 Conventional、纯文本、`[type]`、工单前缀和 Gitmoji；`commit.policy` 可固定为 `conventional` 或设为 `off`。根据完整差异生成单行中文 `Summary`，并用分析器校验后再提交。`-WhatIf -OutputFormat Json` 会在 `commitStyle` 返回选择结果、置信度和回退原因。

改动包含两个以上相互独立的目的时，优先生成 `.git/auto-release/commit-plan.json` 并使用 `AutoSplit`。按实际 diff 语义分类，不只按目录分类；清单与锁文件、实现与对应测试、源文件与生成文件必须同组，同一文件默认只属于一组。限制为 2 至 4 个提交；微小组、低置信度组或有循环依赖的组合并，无法可靠分类时回退到上述单提交。计划格式见 [配置参考](references/config.md)。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $invoke `
  -Operation CommitPush -CommitStrategy AutoSplit `
  -CommitPlanPath "<仓库根目录>/.git/auto-release/commit-plan.json" `
  -RepositoryRoot "<仓库根目录>" -WhatIf

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $invoke `
  -Operation CommitPush -CommitStrategy AutoSplit `
  -CommitPlanPath "<仓库根目录>/.git/auto-release/commit-plan.json" `
  -RepositoryRoot "<仓库根目录>"
```

先用 `-WhatIf` 核对计划，再运行与各组相关的测试和最终完整验证。执行器要求计划精确覆盖所有改动，在临时 `auto-release/transaction-*` 分支依次提交；任何组失败会回到原分支并恢复原暂存区和未提交改动。全部组成功后才快进原分支并执行一次 push。推送前远程发生变化时停止，已验证的本地提交保留以便安全重试。

本操作明确允许等价于 `git add -A` 的全量暂存，但仍遵守 `.gitignore`；发现 `.env`、私钥、凭据文件或密钥内容时停止并恢复原暂存区。远程领先或分叉时停止，不自动合并或变基。
即使 `.codex-release.json` 的发布分支与当前分支不同，也必须提交并推送当前分支；配置分支只约束正式 `Release`。

### 4. Release

正式发布要求稳定语义版本、符合仓库提交风格的单行中文总结和中文 Release Notes：

```powershell
$notes = @"
## 更新内容

- 新增：第一项用户可感知变化。
- 修复：第二项用户可感知变化。
"@

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $invoke -Operation Release -Version vX.Y.Z -Summary "chore(release): 一句中文总结" `
  -ReleaseNotes $notes -RepositoryRoot "<仓库根目录>"
```

依次执行 `Plan -> Prepare -> Commit -> Publish`：更新版本、必要时本地构建、全量安全提交、原子推送分支和标签、等待 GitHub Actions、校验全部产物并公开草稿 Release。若本地构建收据、源文件指纹和产物 SHA256 全部有效，则跳过本地程序构建；否则草稿式 GitHub 发布的本地验证产物仍必须写到 `output/<项目名><扩展名>`，不得创建带版本目录。提交前必须再次验证指纹。构建期间源码变化时用新状态重建一次，仍持续变化则停止。GitHub Actions 始终重新构建正式发布包。

工作流已存在时：

- Skill 托管工作流：更新或复用。
- 兼容的人工发布工作流：用 `-WorkflowPolicy ReuseCompatible` 复用并设为非托管。
- 不兼容或普通 CI：用 `-WorkflowPolicy CreateSeparate` 保留原文件并创建 `.github/workflows/auto-release.yml`。
- 未选择策略：默认 `Stop`，绝不覆盖人工工作流。

托管工作流必须具备标签级 `concurrency`、每个任务的 `timeout-minutes`、上传产物的短期 `retention-days` 和任务级最小权限。所有 `uses:` 必须固定到 40 位 commit SHA；版本标签只放在同行注释中，禁止写入浮动 `@vN` 或 `@stable`。

## 底层发布顺序

严格按 Plan、Prepare、Publish 执行，不得跳过验证。

### 1. Plan

运行：

```powershell
& "$env:USERPROFILE\.codex\skills\auto-release\scripts\release.ps1" `
  -Mode Plan -Version vX.Y.Z -Summary "一句中文总结。" `
  -RepositoryRoot "<仓库根目录>"
```

同时读取 `git status --short`、最近版本标签后的提交和当前差异，并分析最近提交信息风格，生成：

- `Summary`：符合已检测风格的单行中文提交/标签总结；无法确定风格时使用 Conventional Commits。
- `ReleaseNotes`：以配置中的标题开头，列出配置要求数量的中文用户可感知重点。

底层 `Plan` 不暂存文件。只有用户选择 `CommitPush` 或 `Release` 时才允许全量暂存；其他上下文禁止使用 `git add .`、`git add -A` 或等价操作。

### 2. Prepare

使用同一版本和总结运行：

```powershell
& "$env:USERPROFILE\.codex\skills\auto-release\scripts\release.ps1" `
  -Mode Prepare -Version vX.Y.Z -Summary "一句中文总结。" `
  -RepositoryRoot "<仓库根目录>"
```

脚本按配置同步版本、运行测试和构建、整理产物并校验 SHA256。任一步骤失败时立即停止并回滚脚本引入的版本文件修改；并行任务失败时终止本次启动的兄弟进程。

成功后由统一入口重新检查完整差异和敏感文件。没有文件变化时不创建空提交；`Publish` 可在现有 `HEAD` 上创建标签。

### 3. Publish

确认工作区干净且 `HEAD` 提交主题与 `Summary` 完全一致，再运行：

```powershell
$releaseNotes = @"
## 更新内容

- 新增：第一项用户可感知重点。
- 修复：第二项用户可感知重点。
"@

& "$env:USERPROFILE\.codex\skills\auto-release\scripts\release.ps1" `
  -Mode Publish -Version vX.Y.Z -Summary "一句中文总结。" `
  -ReleaseNotes $releaseNotes `
  -RepositoryRoot "<仓库根目录>"
```

脚本校验分支、远程、版本、标签和 ReleaseNotes，原子推送配置分支与标签；若配置了 GitHub Actions，则结构化轮询匹配标签和提交 SHA 的工作流；最后按配置创建 Release 或公开工作流生成的草稿 Release。

## 强制保护

- 禁止使用任何 `--force` 推送或强制更新标签。
- 禁止移动、重建或覆盖已存在的版本标签。
- 禁止自动合并、变基或解决远程分叉。
- 禁止在工作流或产物校验失败时公开 Release。
- 本地等待失败时不取消远程工作流，也不修改或公开草稿 Release。
- 禁止提交未在当前任务中确认的本地产物。
- `gh` 缺失或未登录时停止，完成安装和 `gh auth login` 后再继续。
- 发布后发现问题时创建新的补丁版本，不修改旧版本。

## 最终汇报

只汇报决定性结果：单行总结、更新重点、产物完整路径与 SHA256、Git 提交、版本标签、工作流和 GitHub Release URL；失败时报告停止阶段及可复现错误。
