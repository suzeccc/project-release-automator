# `.codex-release.json` 配置参考

配置位于 Git 仓库根目录。所有相对路径都以仓库根目录为基准，所有正则表达式使用 .NET 语法。

## 完整结构

```json
{
  "schemaVersion": 1,
  "projectName": "ExampleApp",
  "branch": "main",
  "remote": "origin",
  "remoteUrlPattern": "github\\.com[:/]owner/repository(?:\\.git)?$",
  "tagPrefix": "v",
  "version": {
    "read": {
      "path": "package.json",
      "pattern": "\\\"version\\\"\\s*:\\s*\\\"(?<version>\\d+\\.\\d+\\.\\d+)\\\""
    },
    "updates": [
      {
        "path": "package.json",
        "pattern": "(\\\"version\\\"\\s*:\\s*\\\")\\d+\\.\\d+\\.\\d+(\\\")",
        "replacement": "${1}{version}$2",
        "expectedMatches": 1
      }
    ]
  },
  "prepare": {
    "parallel": false,
    "commands": [
      { "name": "Tests", "command": "npm test" },
      { "name": "Build", "command": "npm run build" }
    ],
    "artifacts": [
      {
        "source": "dist/ExampleApp.exe",
        "destination": "output/{tag}/ExampleApp.exe",
        "verifyWindowsVersion": true,
        "sha256": true
      }
    ]
  },
  "releaseNotes": {
    "heading": "## 更新内容",
    "minItems": 2,
    "maxItems": 6,
    "requireChinese": true
  },
  "publish": {
    "workflow": {
      "name": "Release",
      "event": "push",
      "findTimeoutSeconds": 120,
      "waitTimeoutMinutes": 90
    },
    "release": {
      "mode": "publish-draft",
      "title": "{projectName} {tag}",
      "requireDraft": true,
      "requiredAssets": [
        { "pattern": "(?i)setup\\.exe$", "label": "Windows installer" }
      ]
    }
  }
}
```

## 字段规则

- `schemaVersion`：目前只能是 `1`。
- `projectName`、`branch`、`remote`：必填。
- `remoteUrlPattern`：可选；设置后必须匹配 `git remote get-url <remote>`。
- `tagPrefix`：可选，默认 `v`。
- `version.read.pattern`：必须包含命名捕获组 `(?<version>...)`。
- `version.updates`：每项在升级版本时执行；`expectedMatches` 必须与实际匹配数完全一致。
- `prepare.commands`：Windows `cmd.exe` 命令；`parallel: true` 时并行执行并在首个失败后终止兄弟进程。
- `prepare.artifacts`：可为空；`destination` 可省略，省略时直接校验源文件。
- `publish.workflow`：可省略；存在时按标签和 `HEAD` SHA 等待对应 GitHub Actions 工作流。

`publish.release.mode` 支持：

- `publish-draft`：工作流先创建草稿 Release，脚本校验产物后公开。
- `create`：脚本在工作流成功后创建 Release；用 `uploadAssets` 列出要上传的文件或通配符。
- `none`：只推送分支和标签，不创建 GitHub Release。

字符串字段支持 `{projectName}`、`{version}` 和 `{tag}` 占位符。`version.updates[].replacement` 同时支持 .NET 正则替换引用，例如 `${1}` 和 `$2`。

## 最小无工作流示例

```json
{
  "schemaVersion": 1,
  "projectName": "my-cli",
  "branch": "main",
  "remote": "origin",
  "tagPrefix": "v",
  "version": {
    "read": {
      "path": "package.json",
      "pattern": "\\\"version\\\"\\s*:\\s*\\\"(?<version>\\d+\\.\\d+\\.\\d+)\\\""
    },
    "updates": []
  },
  "prepare": {
    "parallel": false,
    "commands": [{ "name": "Check", "command": "npm test" }],
    "artifacts": []
  },
  "publish": {
    "release": {
      "mode": "create",
      "title": "{projectName} {tag}",
      "uploadAssets": ["dist/*"]
    }
  }
}
```
