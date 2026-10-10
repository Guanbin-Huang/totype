# Mac 定制版 0.3.88（95）

基于 Towow-ai/totype；原始 LICENSE、NOTICE、THIRD_PARTY_NOTICES.md 均保留。

## 当前功能
- 豆包流式 ASR，保留原有其他 Provider 与离线实现。
- 聊天模式轻量校对，格式化模式轻量提炼并结构化；完整模式规则仍发给整理模型。
- 显示实时 ASR 草稿，最终文字经正常整理后只提交一次。
- 启发式快路径：2–40 字、单句中文且未检测到复杂线索时使用 `doubao-seed-2-0-mini-260428`；数字、中英混排、改口/否定/排版指令、词典术语等检测到的复杂内容使用 `doubao-seed-2-0-lite-260428`。这是保守路由而非语义正确率保证。
- 标准功能键字形 F11/F12、键盘音量语境下的明确同音误识别，以及中英混排保留。
- 录音、历史、词库和凭据仍由本机应用管理，源码包不包含用户数据。

## 构建与配置
需要 Apple Silicon Mac、Xcode 与匹配 SDK。参考原 README 的安装流程。

```bash
cp config/local.env.example config/local.env
# 按自己环境填写签名身份；local.env 已被 gitignore 排除。
VERBATIM_BUNDLE_MODEL=0 bash scripts/build.sh
```

豆包语音识别与 Ark 文字整理是两个 API 用途，需要在应用设置中填写各自凭据；仓库中不预置真实 Key。其他 Provider 同样使用自己的凭据。

## 定向测试
```bash
bash scripts/chat-polish-test/run.sh
bash scripts/short-model-routing-test/run.sh
```

测试拦截 HTTP，不调用收费接口。26 项原整理回归，以及25条路由输入、完整提示一致性、取消传播已在当前 Mac 通过。真实 API 小样中 Mini 较快，但不承诺每次固定延迟或与 Lite 完全同等质量。

## 版本边界
本次发布对象为当前 Mac 源码。`VerbatimVoiceMobile/` 保留此源码树原有移动端实现，是继承的参考目录，不代表手机上另行构建安装的最新 iOS 预览版本；本次没有宣称或打包更新 iPhone。未采用的预请求实验不包含在生产代码中。

## 发布排除项
不提交真实 API Key/其他凭据、签名私钥、描述文件、本机配置、个人资料导出、录音、输入历史、构建缓存或已签名安装包。配置模板与源代码完整保留。
