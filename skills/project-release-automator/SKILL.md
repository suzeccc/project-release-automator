---
name: project-release-automator
description: Detects and configures Tauri, Node.js, Go, Python, Rust, .NET, and Java repositories, then automates packaging and formal releases. Use when the user asks to create or validate release automation, generate a tag-triggered GitHub Actions workflow, or says 打包, 发布, or 正式发布 followed by a semantic version such as v1.2.3. Uses .codex-release.json for version updates, tests, builds, artifacts, tags, workflows, and GitHub Releases without hard-coded project paths.
---

# Project Release Automator

把“打包 vX.Y.Z”视为用户对当前 Git 仓库执行本地构建、提交、推送、创建标签和正式发布的一次性授权。只执行 `.codex-release.json` 声明的项目步骤，不猜测或复用其他仓库的配置。

## 初始化项目

在仓库根目录运行独立的初始化器。`Detect` 只读，`Generate` 创建配置和工作流，`Validate` 检查二者的一致性：

```powershell
$setup = "$env:USERPROFILE\.codex\skills\project-release-automator\scripts\setup-project.ps1"
& $setup -Mode Detect -RepositoryRoot "<仓库根目录>"
& $setup -Mode Generate -RepositoryRoot "<仓库根目录>"
& $setup -Mode Validate -RepositoryRoot "<仓库根目录>"
```

自动支持 Tauri、Node.js、Go、Python、Rust、.NET 和 Java（Maven/Gradle）。Tauri 优先识别；其他多生态清单并存时，必须用 `-ProjectType` 显式指定类型。生成器会：

- 创建 schema v2 `.codex-release.json`。
- 创建标签触发的 `.github/workflows/release.yml`。
- 根据锁文件选择 npm、pnpm、Yarn 或 Bun。
- 为 Tauri 生成 Windows x64/ARM64、macOS Intel/Apple Silicon 和 Linux 构建矩阵。
- 为 Node.js 生成 `.tgz`，为 Go 生成 Windows/Linux/macOS 的 amd64/arm64 二进制。
- 为 Python 生成 wheel 与 sdist，为 Rust 生成 `.crate`，为 .NET 生成 `.nupkg`，为 Java 生成 `.jar`。
- 创建草稿 GitHub Release，等待本地发布流程校验后再公开。

若现有配置或工作流没有 Project Release Automator 的托管标记，生成器必须停止，禁止覆盖。重复生成托管文件必须幂等。配置和工作流属于项目，应与代码一起提交；禁止写入 Token、密钥或账号凭据。完整字段见 [配置参考](references/config.md)。

生成后运行 `Validate`，再运行 `Plan`。在配置可解释且计划正确前不得进入 `Prepare`。

## 发布顺序

严格按 Plan、Prepare、Publish 执行，不得跳过验证。

### 1. Plan

运行：

```powershell
& "$env:USERPROFILE\.codex\skills\project-release-automator\scripts\release.ps1" `
  -Mode Plan -Version vX.Y.Z -Summary "一句中文总结。" `
  -RepositoryRoot "<仓库根目录>"
```

同时读取 `git status --short`、最近版本标签后的提交和当前差异，生成：

- `Summary`：单行中文提交/标签总结。
- `ReleaseNotes`：以配置中的标题开头，列出配置要求数量的中文用户可感知重点。

若存在未提交修改，只暂存当前任务明确相关的文件。来源不明、无关或冲突的修改必须暂停并询问用户。禁止使用 `git add .`、`git add -A` 或等价全量暂存。

### 2. Prepare

使用同一版本和总结运行：

```powershell
& "$env:USERPROFILE\.codex\skills\project-release-automator\scripts\release.ps1" `
  -Mode Prepare -Version vX.Y.Z -Summary "一句中文总结。" `
  -RepositoryRoot "<仓库根目录>"
```

脚本按配置同步版本、运行测试和构建、整理产物并校验 SHA256。任一步骤失败时立即停止并回滚脚本引入的版本文件修改；并行任务失败时终止本次启动的兄弟进程。

成功后重新检查差异，只用显式路径暂存当前任务文件和版本文件。不要暂存配置排除的构建目录、密钥或 Token。用 `Summary` 提交；若版本已是目标值且没有新文件变化，可用 `git commit --allow-empty` 创建发布标记提交。

### 3. Publish

确认工作区干净且 `HEAD` 提交主题与 `Summary` 完全一致，再运行：

```powershell
$releaseNotes = @"
## 更新内容

- 新增：第一项用户可感知重点。
- 修复：第二项用户可感知重点。
"@

& "$env:USERPROFILE\.codex\skills\project-release-automator\scripts\release.ps1" `
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
