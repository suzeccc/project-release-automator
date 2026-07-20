# Project Release Automator

一个通用的 Codex Skill，用于自动识别项目、生成发布配置与 GitHub Actions，并在 Windows 上打包和正式发布本地 Git 项目。它将初始化阶段的 `Detect -> Generate -> Validate` 与发布阶段的 `Plan -> Prepare -> Publish` 统一为可复现流程。

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

首次使用时可直接要求 Codex“为这个项目创建发布工作流”，或手动运行：

```powershell
$setup = "$env:USERPROFILE\.codex\skills\project-release-automator\scripts\setup-project.ps1"
& $setup -Mode Detect -RepositoryRoot "<仓库根目录>"
& $setup -Mode Generate -RepositoryRoot "<仓库根目录>"
& $setup -Mode Validate -RepositoryRoot "<仓库根目录>"
```

生成器支持 Tauri、Node.js、Go、Python、Rust、.NET 和 Java（Maven/Gradle），创建项目级 `.codex-release.json` 与标签触发的 `.github/workflows/release.yml`。若工作流由人工维护，生成器会拒绝覆盖。完整字段说明见 [`skills/project-release-automator/references/config.md`](skills/project-release-automator/references/config.md)。

## 支持能力

- 自动检测 Tauri、Node.js、Go、Python、Rust、.NET、Maven 和 Gradle
- 识别 npm、pnpm、Yarn、Bun、pip、uv、Poetry、Cargo、NuGet 等工具链
- 安全、幂等地生成发布配置与 GitHub Actions，拒绝覆盖人工工作流
- Tauri 五平台、Go 六目标和 Node.js `.tgz` 发布矩阵
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

`project-release-automator` detects Tauri, Node.js, Go, Python, Rust, .NET, and Java repositories, safely generates repository-specific release configuration and tag-triggered GitHub Actions, then packages and publishes releases from Windows. Human-managed workflows are never overwritten.

## License

[MIT](LICENSE)
