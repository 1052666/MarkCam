# 1.0.1 拍照闪退修复说明

## 已定位的问题

旧版可以正常取景，但按快门时在 `AVCapturePhotoOutput capturePhotoWithSettings:delegate:` 内抛出 Objective-C 异常，导致 `SIGABRT`。

源码与对应构建的二进制方法表均包含错误回调：

```objc
photoOutput:didFinishProcessingPhoto:error:
photoOutput:didFinishCaptureForResolvedSettings:error:
```

AVFoundation 要求的是：

```objc
captureOutput:didFinishProcessingPhoto:error:
captureOutput:didFinishCaptureForResolvedSettings:error:
```

SDK 将这些代理方法标成 `@optional`，但明确规定 JPEG 等非 RAW-only 捕获必须实现照片处理回调，否则 `capturePhotoWithSettings:delegate:` 抛出 `NSInvalidArgumentException`。因此普通编译没有指出此拼写错误，而设备上的拍照请求校验会失败。原始崩溃报告未包含异常 reason 文本，但调用栈、缺失的方法表以及 SDK 约束吻合。

本次发布不包含原始崩溃日志或设备/签名身份信息。

## 修复

- 修正上述两个 selector，照片处理/结束状态能够接收系统回调。
- 新增继承 AVFoundation 协议的 `MCPhotoCaptureContract`，将这两个回调显式设为 `@required`。
- 构建启用 `-Werror=protocol`，缺失必要方法时不再允许生成交付包。
- 拍照前检查摄像头会话、连接、JPEG 支持及实际输出能力。
- 对同步拍照请求的异常保存具体原因并恢复 UI，不伪装成成功或静默反复重试。
- 本地错误文件：`Documents/LastCaptureError.json`。没有任何诊断上传逻辑。
- 版本号 `1.0.1`，构建号 `2`，Bundle ID 仍为 `app.markcam.camera`。
- 不修改水印存储格式、模板数据或已有 Pending 作品。

## 已完成验证

1. 使用真实 iOS 16.5 SDK，重新编译全部 Objective-C 源文件并链接 arm64 Mach-O。
2. 140 项结构、源码与二进制断言通过。
3. 直接解析打包内 Mach-O 类方法表，确认两个正确回调存在、两个旧错误回调消失。
4. 正反编译回归：当前源文件编译通过；临时副本故意恢复旧拼写时，编译报缺失两个必要回调，符合预期。
5. 原图标、渲染模块、编辑器及数据结构不变。

这些是编译/静态验证，**不是模拟器或真机功能验证**。新版本拍照、水印合成和相册保存仍需实际复测。

## 升级与复测

1. 先导出水印备份。使用与旧版相同的 Bundle ID 与签名身份重签覆盖安装，不要先卸载。
2. 后置拍一张，允许“添加照片”，检查系统相册是否收到带水印照片。
3. 前置再拍一张，检查镜像与文字方向。
4. 水印开启/关闭各试一次；切换到视频再切回照片，确认仍可拍摄。
5. 若出现错误弹窗，将弹窗或 `LastCaptureError.json` 私下提供给维护者；若仍退出，提供新 `.ips`。

不要把私人照片、完整设备日志或证书提交到公开仓库。
