# Project Release Automator

一个配置驱动的 Codex Skill，用于在 Windows 上打包和正式发布本地 Git 项目。它将版本更新、测试、构建、产物校验、Git 标签、GitHub Actions 和 GitHub Release 统一为可复现的 `Plan -> Prepare -> Publish` 流程。

## 安装

在 PowerShell 中运行：

```powershell
python -X utf8 "$env:USERPROFILE\.codex\skills\.system\skill-installer\scripts\install-skill-from-github.py" --repo suzeccc/project-release-automator --path skills/project-release-automator
```

安装后请开启一个新的 Codex 任务，让 Skill 列表重新加载。

## 使用

在任意本地 Git 项目中告诉 Codex：

```text
打包 v1.2.3
```

或：

```text
正式发布 v1.2.3
```

项目根目录需要 `.codex-release.json`。首次使用时，Codex 会检查项目清单、测试/构建命令、CI 工作流和产物路径，然后生成项目专属配置。完整字段说明见 [`skills/project-release-automator/references/config.md`](skills/project-release-automator/references/config.md)。

## 支持能力

- 项目级版本读取和多文件正则更新
- 串行或并行测试与构建
- 构建产物复制、Windows 文件版本校验和 SHA256
- 分支、远程、版本降级、标签冲突和远程分叉保护
- GitHub Actions 精确匹配与结构化轮询
- 创建 GitHub Release 或公开工作流生成的草稿 Release
- 禁止强推、覆盖标签、自动变基和失败后公开 Release

## 环境要求

- Windows PowerShell 5.1 或 PowerShell 7+
- Git
- Python（使用上述安装命令时）
- GitHub CLI `gh`（使用 GitHub Actions 或 GitHub Release 时）

## 验证

```powershell
& ".\skills\project-release-automator\tests\validate.ps1"
```

## English

`project-release-automator` is a configuration-driven Codex Skill for packaging and publishing local Git projects on Windows. Each repository defines its release behavior in `.codex-release.json`; the Skill safely executes version updates, tests, builds, artifact checks, Git tags, GitHub Actions, and GitHub Releases.

## License

[MIT](LICENSE)
