# 1.4.0：原生 Liquid Glass 与重启恢复

已有相机权限时，冷启动曾直接从 `viewDidLoad` 启动相机，此时 App 可能仍未活跃。首次安装的授权弹窗会改变这个顺序，因此“首次能拍、退出后再进失效”需要单独检查。现在相机启动等待活跃通知，返回前台、结束系统中断和媒体服务重置也使用同一恢复路径。授权请求防止重复，恢复操作防止重入。

中断、失败以及保存结果待确认的历史文件仍保存在 Pending，保留重试与导出入口；它们不再占用普通照片的六个待处理名额。正在接收的照片仍最多两张，内存、温度、Live/视频处理限制保留，并检查可用存储空间。`saving` 状态不会自动重试，避免重复写入相册。

## 界面

| Before | After | Why |
| --- | --- | --- |
| iOS 16.5 SDK、手绘深色工具块 | iOS 26 SDK、系统 `glassButtonConfiguration` | 使用 UIKit 提供的真实 Liquid Glass 材质与交互 |
| 薄荷绿选中块、大面积毛玻璃底板 | 中性色控件、状态用黄色点明、视频底部仅有对比渐变 | 把视觉重点还给取景画面，避免层叠模糊 |
| 固定深色编辑页、顶部填色分段栏 | 系统分组背景、默认导航栏、底部工具切换 | 跟随系统外观，保留清晰的内容与操作层级 |
| 已授权冷启动不等待 App 活跃 | 激活后启动，前后台恢复串行完成 | 覆盖与首次授权不同的启动顺序 |
| 所有历史恢复记录占用快门容量 | 可运行任务与待恢复文件分别计数 | 旧的中断状态不会长期锁住新拍摄 |

快门仍为即时按下反馈，不叠加缩放、弹簧或闪屏动画；连续点击没有人为延时。工具按钮、菜单和导航使用原生系统动效，遵循减少动态效果、减少透明度和提高对比度设置。iOS 16.5–18 使用系统材质回退。

## 验证范围

GitHub Actions 使用 Apple Xcode 26 / iOS 26 SDK 构建 arm64 IPA。UIKit 回归在 iOS Simulator 执行相机/编辑器操作、标准与紧凑尺寸、横竖屏、大字体及高对比度检查，并在同一次安装上终止进程再启动，保留 Documents。测试中的相机硬件和可用内存为受控依赖，启动/恢复方法和队列文件扫描为生产实现。

原有真实照片代理回调测试、共享 C 布局/容量策略、回调拼写负向编译和 IPA 检查继续执行。截图使用明确标注的模拟取景样本。模拟器无法证明真机快门速度、光学画质、Live Photo 播放或用户设备上的复现已经消失；截图由模拟器系统合成器直接截取；具体测试结果以当前发布附件为准。

## 构建与安装

从 1.4.0 起发布构建需要 macOS 与 Xcode 26+，不再使用旧版 Linux/theos SDK。最低运行版本仍为 iOS 16.5。构建脚本生成 ad-hoc 签名 IPA，安装到普通 iPhone 前需要有效证书和描述文件重签。

使用原 Bundle ID `app.markcam.camera` 和原签名身份覆盖安装，保留本机模板及待恢复作品。

参考：[Apple Liquid Glass 迁移指南](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)、[UIKit 玻璃按钮](https://developer.apple.com/documentation/uikit/uibuttonconfiguration/glassbuttonconfiguration)、[Emil Kowalski 设计技能](https://github.com/emilkowalski/skills)。
