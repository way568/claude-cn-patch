# 贡献指南

## 最有价值的贡献：版本适配

Claude Desktop 每次大版本更新都可能让补丁锚点漂移。适配流程：

1. 安装新版 Claude Desktop，运行 `bash patch.sh`，记录输出中的「锚点漂移」项
2. 解包新版 `ion-dist.asar`（任意 asar 工具），按漂移项的功能关键词搜索新代码：
   - `ON()词典目录` → 搜 `dataset.i18nCatalogs`（词典清单解析函数）
   - `H()选择器清单` → 搜 `dataset.i18nReleased`（已发布语言读取函数）
   - `选择器渲染点` → 搜语言选择器组件（`LanguagePicker` / `Choose your language`）
3. 把 `patch.sh` 中 `PAIRS` 的旧锚点串替换为新版对应代码片段，保证替换后语法有效
4. 本地完整跑一遍 `bash patch.sh` 并截图验证中文生效，提交 PR

## 提交规范

- 一个 PR 只做一件事（锚点适配 / 词典更新 / 文档）
- 描述里注明验证过的 App 版本号
- 通过 CI（语法双 locale 检查、全角标点扫描、词典完整性）

## 声明

涉及 Anthropic 官方内容的修改（词典等）请参考 README 的「词典来源与版权」章节。
