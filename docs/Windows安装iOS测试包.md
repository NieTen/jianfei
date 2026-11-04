# Windows 安装 iOS 测试包

## 当前状态

项目已提供手动触发的 GitHub Actions 工作流，位置为 .github/workflows/ios-test-package.yml。

2026 年 11 月 4 日，云端 Xcode 16.4 已成功编译 iPhone 与 Watch，并生成 0.1.0 的 BingJian-unsigned.ipa、SHA-256 校验文件和构建日志。IPA 已下载到本机 build/iOS测试包-0.1.0，完整性、arm64 架构和必要资源检查通过。安装时仍需使用 Apple 账号签名，真机运行尚待验证。[成功构建记录](https://github.com/NieTen/jianfei/actions/runs/41794042406)

## 准备 GitHub 仓库

1. 登录自己的 GitHub 账号。
2. 使用私有仓库存放项目，确认该仓库已启用 Actions。
3. 上传项目源码时包含 .github、ios，以及 backend/app/resources/food_schema.json，保留原有目录结构。
4. 在仓库默认分支包含工作流后，进入 Actions，选择“iOS 真机测试包”，点击 Run workflow。
5. 构建成功后，在本次运行的 Artifacts 中下载 BingJian-unsigned 开头的产物。
6. 解压下载的文件，取出 BingJian-unsigned.ipa。

使用 GitHub Desktop 时，可从本项目目录创建仓库，再通过 Publish repository 上传，保持“Keep this code private”选中。提交前检查变更列表，配置文件、签名材料、数据库和本地数据应留在本机。.gitignore 已列出这些常见路径。

工作流使用 GitHub 托管的 macOS 运行器。私有仓库会消耗账号的 Actions 配额，超过可用额度时按账号账单设置处理。运行前查看 GitHub 的 Billing and licensing 页面。[GitHub 托管运行器说明](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) [GitHub Actions 计费说明](https://docs.github.com/en/billing/concepts/product-billing/github-actions)

构建失败时，下载 BingJian-build-logs 开头的产物，提供其中的 xcodebuild.log 以排查编译错误。只有编译、资源检查与 ZIP 校验全部通过，才会上传 IPA。

## 在 Windows 签名与安装

1. 从 Sideloadly 官方网站下载 Windows 版，按照其官方说明安装所需 Apple 驱动。
2. 用数据线连接 iPhone，在手机上确认信任这台电脑。
3. 打开 Sideloadly，选择手机，将 BingJian-unsigned.ipa 拖入窗口。
4. 在 Sideloadly 中登录自己的 Apple 账号，按提示完成双重认证和签名安装。
5. 按系统提示，在 iPhone“设置 → 通用 → VPN 与设备管理”中信任自己的开发者身份。
6. 如果手机提示需要开发者模式，在“设置 → 隐私与安全性 → 开发者模式”中开启并按提示重启。

Apple 账号登录在本机安装工具中完成。GitHub 工作流只做编译，运行时所需输入为仓库源码。[Sideloadly 官方网站](https://sideloadly.io/) [官方安装与故障说明](https://sideloadly.io/faq.html)

Sideloadly 官方说明，普通免费账号签名有效期为七天，支持在电脑与手机具备连接条件时自动续签。更新测试包时保持相同 Apple 账号及 Bundle ID，使用覆盖安装，并提前导出重要记录。[签名有效期、自动续签与覆盖安装说明](https://sideloadly.io/faq.html)

## 功能验证范围

- 手机系统最低要求为 iOS 17。
- 首轮可验证首次设置、地址持久化、饮食与体重记录、趋势、AI 接口配置、导入导出，以及连接实际后台后的同步与双人功能。
- 普通 Apple 开发者账号支持 HealthKit，重签名工具还需要正确保留对应授权，实际健康数据读取须在手机验证。
- 远程 APNs 推送需要支持 Push Notifications 的开发者会员签名。本地提醒可单独测试。
- IPA 包含 Watch 应用，第三方重签名的 Watch 安装与配对兼容性需要另行验证。遇到签名或安装报错时，应保留错误信息再处理。

账号能力以上述 Apple 官方能力表为准。[Apple iOS 能力与会员类型](https://developer.apple.com/help/account/reference/supported-capabilities-ios)

## 首次打开

可以先体验离线记录。在首次设置或“我的”中填写实际后台 HTTPS 地址、AI 接口地址、密钥与模型。

后台地址及 AI 配置保存后，后续启动自动读取。内网自签证书的安装、开户凭据与后台运行方法见同目录的《部署与运行.md》。
