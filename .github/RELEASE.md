# GitHub 发布说明

## 触发

- 推送 tag：`v*`（推荐）
- Actions → **Release** → Run workflow

## 本地等价命令

```bash
./Scripts/ci_package.sh 0.1.0
```

## Secrets

见根目录 [README.md](../README.md)「GitHub Actions 自动发布」。

导出 `.p12` 为 base64：

```bash
base64 -i DeveloperID.p12 | pbcopy
```

导出 `.p8`：

```bash
base64 -i AuthKey_XXX.p8 | pbcopy
```
