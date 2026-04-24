# /release — TNT 项目发布命令

发布新版本到 GitHub Releases。自动完成以下步骤：

## 执行流程

### 1. 确认版本升级类型

询问用户本次版本升级类型（patch / minor / major），默认 patch。

### 2. 生成 Release Note

- 运行 `git log $(git describe --tags --abbrev=0 2>/dev/null || echo HEAD~10)..HEAD --oneline` 获取自上个 tag 以来的所有提交
- 基于提交信息自动分类生成 release note（feat / fix / chore / refactor 等）
- 将 release note 写入 `package.json` 的 `releaseHistory` 数组（追加到数组开头）

### 3. 升级版本号

- 运行 `./scripts/bump-version.sh {type}` 自动更新 VERSION、package.json、project.yml
- 读取新的版本号

### 4. 编译验证

- 运行 `swift build` 确保代码能编译通过
- 如果编译失败，中止发布并报告错误

### 5. 提交并打 Tag

- `git add -A`
- `git commit -m 'chore: release vx.y.z'` （使用实际版本号）
- `git tag vx.y.z`

### 6. 推送触发 CI

- `git push origin main --tags`
- 这会自动触发 GitHub Actions 构建 DMG 并创建 Release

### 7. 报告结果

告知用户新版本号、release note 摘要、GitHub Actions 构建进度链接。

## 注意事项

- 如果当前有未提交的改动，先提示用户确认是否一并提交
- 不要重复推送已存在的 tag
- 如果 bump 脚本或 swift build 失败，中止并报告
