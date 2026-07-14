# REAPER 震动设计工具链 · 安装说明

> 在 REAPER 里像剪音频一样设计手机震动,保存后 1 秒内 iPhone 真机试感受。
> 设计师日常只用 Windows;Mac 仅在给手机打包 app 时需要一次。

## 一、整体结构

| 环节        | 机器                 | 工具                                                 |
| ----------- | -------------------- | ---------------------------------------------------- |
| 设计 & 导出 | Windows              | REAPER + 面板脚本(本仓库 `scripts/reaper/`)          |
| 传输        | Windows              | 一键本地服务器 `serve-haptics.bat`(面板里可直接启动) |
| 试感受      | iPhone(iOS 13+ 真机) | HapticFeedback app,REAPER 调试台页签                 |

## 二、设计师安装(Windows,约 5 分钟)

1. clone 本仓库到本地(位置随意)
2. 打开 REAPER → `?` 打开 Actions → **New action → Load ReaScript**,加载:
   - `scripts/reaper/ReaperHaptics_Panel.lua`(主面板,必装)
   - `scripts/reaper/ReaperHaptics_InsertTransient.lua`(选装,绑到 `T` 键:鼠标处快速插瞬态)
3. 建议:右键工具栏 → Customize toolbar → 把 Panel 加成常驻按钮
4. 电脑需要能运行 python(装过 miniconda/Anaconda 即可,面板启动服务器时自动查找)

> 💡 面板五个按钮就是全部流程:①启用震动编辑 → ②插入瞬态 → ③启动手机服务器 → ④试发送选中 / ⑤导出。手机要填的 URL 直接显示在面板上。

## 三、手机 app 打包(Mac,一次性)

环境要求:Xcode 16.1+、Node 22+、ruby(系统自带即可)。

```bash
git clone <仓库地址> && cd reaper-haptic-feedback
npm install                      # 仓库根目录,必须先装
cd example
npm install
bundle install                   # 安装 CocoaPods(锁定版本)
bundle exec pod install --project-directory=ios
open ios/HapticFeedbackExample.xcworkspace
```

Xcode 里:

1. 插上 iPhone,顶部设备选真机
2. TARGETS → HapticFeedbackExample → Signing & Capabilities → 登录 Apple ID,勾选 Automatically manage signing
3. **Product → Scheme → Edit Scheme → Run → Build Configuration 选 Release**(Debug 包会有黑色 Metro 横幅且启动慢)
4. ⌘R 运行;首次需在 iPhone 设置 → 通用 → VPN与设备管理 里信任证书

> ⚠️ 签名有效期:免费 Apple ID 装的 app 7 天后失效,需重新部署;团队长期使用建议用付费开发者证书或走 TestFlight(90 天/构建,无需 Mac 安装)。

## 四、首次联调(每台手机一次)

1. Windows:REAPER 面板点 **③ 启动手机服务器**(首次会问导出文件夹;防火墙弹窗点允许)
2. iPhone 与电脑连**同一 WiFi**,打开 app → REAPER 调试台 → 填面板显示的 URL(形如 `http://10.1.x.x:8765/preview.ahap`)→ 开启监听
3. REAPER 里插一个瞬态 → 点 **⑤ 导出** → 手机 1 秒内震动,即联调成功

之后的日常:改 item → 导出 → 手机自动震,无限循环。

## 五、常见问题

| 现象                             | 原因 / 解决                                                                                                             |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `husky: command not found`       | 没先在仓库根目录 `npm install`,补装后重来                                                                               |
| `pod: command not found`         | 用 `bundle exec pod install`(CocoaPods 装在 bundle 环境里)                                                              |
| 构建报 `Sandbox: deny` / `EPERM` | 拉取最新代码(已在工程和 Podfile 里关闭 Xcode 16 脚本沙箱)后重跑 `bundle exec pod install`                               |
| 手机 fetch 失败                  | 先用手机 Safari 打开 `http://电脑IP:8765` 测试:打不开 = 防火墙未放行或不在同一网段(公司 WiFi 有设备隔离时,可用手机热点) |
| app 顶部黑色 Metro 横幅 / 启动慢 | 打的是 Debug 包,按上文切 Release 重新打包                                                                               |
| app 打不开(装了超过 7 天)        | 免费签名过期,重新连 Mac 部署一次                                                                                        |

## 六、设计速查

| 操作                     | 含义                           |
| ------------------------ | ------------------------------ |
| 短 item(< 45ms)          | 瞬态(点一下)                   |
| 长 item(≥ 45ms)          | 持续震动,时长 = item 长度      |
| item 音量把手            | 强度 0–1(0dB = 1.0)            |
| take 名 / 备注写 `s=0.3` | 锐度(0 钝 → 1 脆,默认 = 强度)  |
| 备注写 `i=0.6`           | 直接指定强度(empty item 用)    |
| 瞬态间隔                 | ≥ 20ms 可分辨,越密单发力度越弱 |
