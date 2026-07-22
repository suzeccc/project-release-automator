# Ignore 审计与应用

`Ignore` 只处理当前 Git 仓库，不扫描仓库外的用户目录。默认 `Audit` 为只读工作区操作，仅把计划写入 `.git/auto-release/ignore-plan.json`；`-WhatIf` 连计划文件也不写。

## 模式

```powershell
$invoke = "$env:USERPROFILE\.codex\skills\auto-release\scripts\invoke-release.ps1"

& $invoke -Operation Ignore -IgnoreMode Audit -RepositoryRoot "<仓库根目录>"
& $invoke -Operation Ignore -IgnoreMode Apply -RepositoryRoot "<仓库根目录>"
& $invoke -Operation Ignore -IgnoreMode ApplyAndUntrack -RepositoryRoot "<仓库根目录>"
```

- `Audit`：识别项目类型、现有忽略来源、候选规则、已跟踪匹配、敏感路径、受保护路径和历史生成路径。
- `Apply`：只把高置信度缺失规则追加到根 `.gitignore` 的托管区块，不暂存、提交或推送。
- `ApplyAndUntrack`：在 `Apply` 基础上对计划中的精确已跟踪文件执行 `git rm --cached`；本地文件内容和 SHA256 必须保持不变。

## 计划

计划包含 `baseHead` 和完整工作区指纹。应用前 HEAD、暂存区、未暂存区或未跟踪文件发生任何变化时，计划作废，必须重新 `Audit`。

```json
{
  "schemaVersion": 1,
  "baseHead": "commit SHA",
  "worktreeFingerprint": "SHA256",
  "rules": [
    {
      "pattern": "/previews/",
      "reason": "Local design and preview artifacts",
      "confidence": 1,
      "trackedMatches": ["previews/example.html"]
    }
  ],
  "untrackPaths": ["previews/example.html"],
  "sensitivePaths": [],
  "protectedPaths": ["package-lock.json"]
}
```

## 分类规则

- 只自动应用置信度至少 0.8 的候选规则。
- 已跟踪文件默认进入 `review`；只有明确的构建、本地输出或无引用预览允许进入安全计划。
- 实际 `.env`、私钥和签名凭据存在时停止应用，不能用忽略规则代替凭据处置。
- 锁文件、`.codex-release.json` 和 `.github/workflows/**` 为受保护路径；新规则不得改变它们的可见性。
- `build/`、`dist/`、`target/`、`bin/`、`obj/` 等规则只有检测到对应工具链时才生成；发现已跟踪引用时转入 `review`。
- `.env.*` 必须与 `!.env.example` 一起管理。

## 托管区块

人工内容、顺序和注释保持不变。托管规则只追加到以下区块；标记缺失时创建，标记不完整或重复时停止：

```gitignore
# BEGIN Auto Release managed ignores

# Build
output/

# END Auto Release managed ignores
```

重复执行必须幂等。后续新增规则追加到现有区块，禁止删除旧托管规则。

## 回滚和验证

应用前备份 `.gitignore` 和 Git index。失败时恢复二者。应用后验证：

- 每个新增规则通过 `git check-ignore --no-index` 命中探针。
- 原本可见的受保护路径仍然可见。
- `git diff --check` 通过。
- `ApplyAndUntrack` 前后的本地文件数量、路径和 SHA256 一致。

本操作不删除本地文件、不提交、不推送、不重写 Git 历史。完成后如需提交，另行执行 `CommitPush`；分类提交应把 `.gitignore` 与停止跟踪的文件放入同一个 `chore(repo)` 组。
