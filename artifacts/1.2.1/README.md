# MarkCam 1.2.1 (build 6)

[下载 IPA](MarkCam-1.2.1-resign-required.ipa) · [SHA-256 校验](SHA256SUMS.txt) · [修复说明及真机复测步骤](../../docs/HOTFIX-1.2.1.md)

- arm64，iOS 16.5 起，Bundle ID `app.markcam.camera`。
- Mach-O 仅有 ad-hoc 签名，没有 Apple 发行签名/描述文件，安装前需要合法重签。
- 源码提交：`6aacef87de4c9f6d2f12c415a69a420e962ad657`；后续交付提交仅增加本目录文件。
- 构建：clang/LLD 21.1.5 + 固定提交的 theos iPhoneOS16.5 SDK；工具与校验结果见 JSON 报告。
- 本地检查：217 项 IPA/静态检查、33 项拍摄恢复检查、20 项 Live 接线检查、506 项布局/倍率检查通过；拍照回调正反编译通过。
- 未执行 iOS 模拟器或真机拍摄测试，不把编译成功当作设备功能已验收。

IPA SHA-256：`4c139f7fceb5f5dfed7b85630cdd6fe8be36a15f28ea71d63284c5fd6c614062`

原始照片和用户诊断日志不在本目录中。
