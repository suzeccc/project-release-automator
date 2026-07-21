# Auto Release

一个通用的 Codex Skill，用于自动识别项目、生成发布配置与 GitHub Actions，并提供本地测试构建、全部更改提交推送和正式发布三种可复现操作。

## 安装

在 PowerShell 中运行：

```powershell
python -X utf8 "$env:USERPROFILE\.codex\skills\.system\skill-installer\scripts\install-skill-from-github.py" --repo suzeccc/auto-release --path skills/auto-release
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
$setup = "$env:USERPROFILE\.codex\skills\auto-release\scripts\setup-project.ps1"
& $setup -Mode Detect -RepositoryRoot "<仓库根目录>"
& $setup -Mode GenerateLocal -RepositoryRoot "<仓库根目录>"
& $setup -Mode Generate -RepositoryRoot "<仓库根目录>"
& $setup -Mode Validate -RepositoryRoot "<仓库根目录>"
```

生成器支持 Tauri、Node.js、Go、Python、Rust、.NET、Java、CMake、Flutter、Android、Electron 和 Docker。`GenerateLocal` 只创建本地构建配置，不读取或创建 GitHub 工作流；`Generate` 创建完整 `.codex-release.json` 与标签触发的 `.github/workflows/release.yml`。若工作流由人工维护，完整生成器会拒绝覆盖。完整字段说明见 [`skills/auto-release/references/config.md`](skills/auto-release/references/config.md)。

## 三种操作

```powershell
$invoke = "$env:USERPROFILE\.codex\skills\auto-release\scripts\invoke-release.ps1"

# 1. 不改版本，仅构建本地测试程序
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $invoke -Operation LocalBuild -RepositoryRoot "<仓库根目录>"

# 忽略已有有效构建记录，强制重新构建；依赖仍仅在锁文件变化时重新安装
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $invoke -Operation LocalBuild -ForceRebuild -RepositoryRoot "<仓库根目录>"

# 2. 中文提交全部更改并推送当前分支
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $invoke -Operation CommitPush -Summary "一句中文总结" -RepositoryRoot "<仓库根目录>"

# 3. 构建全部发布包并正式发布 GitHub
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $invoke -Operation Release -Version v1.2.3 -Summary "一句中文总结" `
  -ReleaseNotes "<中文 Release Notes>" -RepositoryRoot "<仓库根目录>"
```

`LocalBuild` 只校验本地版本、命令和产物配置，不要求 GitHub 工作流具备标签触发器。它会自动创建 `<仓库根目录>/output`，把本地构建产物复制为不含版本号的 `output/<项目名><扩展名>`；例如 `output/CopyShare.exe`。若该项目当前或上次管理的同路径 EXE 正在运行，先按完整路径强制终止对应进程，再覆盖标准文件；不会终止 `output` 中的其他程序，也不会改用 `-2` 等备用文件名。构建记录只包含本次实际生成的产物，并清理上次由 Skill 管理、这次已不再生成的旧文件。

默认情况下，源码和产物 SHA256 未变化时直接复用现有结果；使用 `-ForceRebuild` 可强制重新构建。新生成的配置把依赖安装、快速本地构建和完整正式构建分开：锁文件未变化时跳过依赖安装，Tauri 本地构建使用无安装包模式，正式发布仍生成全部安装包。正式发布在提交前会再次核对源码指纹，构建期间发生变化时自动重建一次，持续变化则停止发布。GitHub Actions 始终重新生成正式发布包。

人工工作流默认不覆盖：可选择兼容复用，或保留原工作流并新建 `.github/workflows/auto-release.yml`。

## 支持能力

- 自动检测 Tauri、Node.js、Go、Python、Rust、.NET、Maven 和 Gradle
- 自动检测 CMake、Flutter、Android、Electron 和 Docker
- 识别 npm、pnpm、Yarn、Bun、pip、uv、Poetry、Cargo、NuGet 等工具链
- 安全、幂等地生成发布配置与 GitHub Actions，拒绝覆盖人工工作流
- 本地构建不改版本；全量中文提交推送；正式发布三种独立操作
- 本地构建统一输出到 `output/<项目名><扩展名>`，目录或文件不存在时自动创建
- 基于源文件指纹和 SHA256 复用有效本地构建
- 基于锁文件缓存依赖安装，区分快速本地构建和完整正式构建
- 精确记录本次产物，只终止和清理当前项目已管理的程序
- 正式发布提交前重新验证构建输入，避免旧产物对应新源码
- 兼容复用人工工作流，或保留原文件创建独立发布工作流
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
& ".\skills\auto-release\tests\validate.ps1"
```

## English

`auto-release` detects twelve common project families, safely generates repository-specific release configuration and tag-triggered GitHub Actions, then packages and publishes releases from Windows. Human-managed workflows are never overwritten.

## License

[MIT](LICENSE)
