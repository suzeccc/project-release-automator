---
name: project-release-automator
description: Automates packaging and formal releases for local Git projects. Use after the user says 打包, 发布, or 正式发布 followed by a semantic version such as v1.2.3 or 1.2.3. Uses a repository-level .codex-release.json file to drive version updates, tests, builds, artifacts, tags, GitHub Actions, and GitHub Releases without hard-coded project paths.
---

# Project Release Automator

把“打包 vX.Y.Z”视为用户对当前 Git 仓库执行本地构建、提交、推送、创建标签和正式发布的一次性授权。只执行 `.codex-release.json` 声明的项目步骤，不猜测或复用其他仓库的配置。

## 首次配置

在仓库根目录查找 `.codex-release.json`。若不存在：

1. 检查项目清单、锁文件、测试/构建脚本、CI 工作流、产物路径和现有 Release 方式。
2. 按 [配置参考](references/config.md) 创建最小配置。
3. 运行 `Plan` 验证配置；在配置可解释且计划正确前不得进入 `Prepare`。

配置属于项目，应与代码一起提交。禁止把 Token、密钥或账号凭据写入配置。

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
