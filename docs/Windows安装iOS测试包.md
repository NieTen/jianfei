# Windows 安装 iOS 测试包

## 当前状态

项目已提供自动运行、也可手动触发的 GitHub Actions 工作流，位置为 .github/workflows/ios-test-package.yml。推送到 main 或提交目标为 main 的合并请求时，客户端相关文件发生变化就会自动构建；纯文档变更会跳过。

0.1.7 调整体重日期与单位输入、简化记餐、拍照后自动识别、首次身体信息引导，并同时显示体重与摄入图表。无密钥注册、HealthKit 签名声明、HTTP 后台和 AI 凭据保存继续保留。工作流生成两种独立产物：BingJian-unsigned.ipa 用于手机重签名安装，BingJian-simulator.zip 用于 iOS 模拟器。测试包保存在本机 build/iOS测试包-0.1.7，网页测试包为 build/网页测试包/BingJian-0.1.7-Appetize.zip。页面截图及校验结果见《测试与验收.md》。手机安装仍需使用 Apple 账号签名，真机运行尚待验证。

## 准备 GitHub 仓库

1. 登录自己的 GitHub 账号。
2. 使用私有仓库存放项目，确认该仓库已启用 Actions。
3. 上传项目源码时包含 .github、ios，以及 backend/app/resources/food_schema.json，保留原有目录结构。
4. 在 Actions 中查看自动触发的“iOS 测试包与界面验收”；需要重新构建时，进入该流程，点击 Run workflow。
5. 构建成功后，在本次运行的 Artifacts 中下载 BingJian-unsigned 开头的产物。
6. 解压下载的文件，取出 BingJian-unsigned.ipa。

使用 GitHub Desktop 时，可从本项目目录创建仓库，再通过 Publish repository 上传，保持“Keep this code private”选中。提交前检查变更列表，配置文件、签名材料、数据库和本地数据应留在本机。.gitignore 已列出这些常见路径。

工作流使用 GitHub 托管的 macOS 运行器。私有仓库会消耗账号的 Actions 配额，超过可用额度时按账号账单设置处理。运行前查看 GitHub 的 Billing and licensing 页面。[GitHub 托管运行器说明](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) [GitHub Actions 计费说明](https://docs.github.com/en/billing/concepts/product-billing/github-actions)

构建失败时，下载 BingJian-build-logs 开头的产物，提供其中的 xcodebuild.log 以排查编译错误。只有编译、资源检查与 ZIP 校验全部通过，才会上传 IPA。

## 在 Windows 浏览器先体验

1. 在成功运行的 Artifacts 中下载 BingJian-simulator 开头的产物，解压一次。
2. 找到其中的 BingJian-simulator.zip；它包含 ARM64 的模拟器应用，与手机 IPA 分开构建。
3. 若选择使用 Appetize，登录自己的账号并上传 BingJian-simulator.zip，在浏览器启动 iOS 模拟器。无需连接手机或开启手机开发者模式。
4. 可先选择“先离线记录，稍后配置”，检查饮食、体重、趋势和设置页。需要测试同步或 AI 时，再配置可从云端访问的后台或接口。

Appetize 要求压缩的 iOS 模拟器 .app，不能上传真机 IPA。本项目的模拟器包在运行测试前生成，不携带 XCTest 测试组件或截图用示例记录。云端模拟器无法直接访问你电脑的 localhost 或普通家庭内网地址，HealthKit、手机相机、推送与 Watch 配对仍需实际设备验收。[Appetize 官方格式说明](https://docs.appetize.io/platform/app-management/uploading-apps/ios)

本次只生成和检查模拟器包，尚未上传第三方模拟平台。工作流附带的 ui-preview 目录包含实际模拟器页面截图，其中数据为测试示例。

### 更新 AI 凭据保存修复包

旧 0.1.1 模拟器包关闭了代码签名，缺少钥匙串所需的应用身份和访问组授权。它可能正常读取模型、通过连接测试，但在“保存 AI 设置”时报“安全凭据保存失败”。

请将最新的 BingJian-0.1.7-Appetize.zip 上传为新构建，在 Appetize 中选择新构建启动，再填写 AI 设置并保存。无需解压 ZIP，也无需开启手机开发者模式。0.1.2 起的模拟器包使用临时签名并携带专用授权，密钥仍写入系统钥匙串。

### 使用 HTTP 后台

0.1.3 起，在首次设置或“我的 → 私有服务器与账号”填写 `http://后台地址:端口` 即可，保存后自动复用。HTTP 不需要安装证书；省略协议时仍默认 HTTPS。群晖部署默认使用 18080 HTTP 端口，详细步骤见 deploy/synology/群晖部署说明.md。

HTTP 不会改变网络可达性：同一局域网的手机可以访问 NAS 内网地址，Appetize 仍需配置云端可访问的地址。仅修改后台部署无法让旧 0.1.2 客户端接受 HTTP，必须更新 App。

## 在 Windows 签名与安装

1. 从 Sideloadly 官方网站下载 Windows 版，按照其官方说明安装所需 Apple 驱动。
2. 用数据线连接 iPhone，在手机上确认信任这台电脑。
3. 打开 Sideloadly，选择手机，将 BingJian-unsigned.ipa 拖入窗口。
4. 在 Sideloadly 中登录自己的 Apple 账号，按提示完成双重认证和签名安装。
5. 按系统提示，在 iPhone“设置 → 通用 → VPN 与设备管理”中信任自己的开发者身份。
6. 如果手机提示需要开发者模式，在“设置 → 隐私与安全性 → 开发者模式”中开启并按提示重启。

Apple 账号登录在本机安装工具中完成。GitHub 工作流只做编译，运行时所需输入为仓库源码。[Sideloadly 官方网站](https://sideloadly.io/) [官方安装与故障说明](https://sideloadly.io/faq.html)

Sideloadly 官方说明，普通免费账号签名有效期为七天，支持在电脑与手机具备连接条件时自动续签。更新测试包时保持相同 Apple 账号及 Bundle ID，使用覆盖安装，并提前导出重要记录。[签名有效期、自动续签与覆盖安装说明](https://sideloadly.io/faq.html)

## Sideloadly 安装后缺少 HealthKit 授权

`missing com.apple.developer.healthkit entitlement` 表示当前安装包的签名缺少 HealthKit 权限声明，不能靠反复点健康权限按钮解决。之前的待签名 IPA 没有原始签名授权信息；0.1.6 会先对 iPhone 和 Watch 加入携带 HealthKit 声明的临时签名，方便重签名工具读取。临时签名不是可用于真机安装的个人签名，也不代表已获得 Apple 的健康数据访问授权。

用原 Apple 账号和原 Bundle ID，在 Sideloadly 中对新版 IPA 重新签名并覆盖安装，再到 App 请求健康权限。最终签名和描述文件都必须保留 `com.apple.developer.healthkit = true`。普通 Apple Developer 账号在 Apple 的能力表中支持 HealthKit，但具体重签名工具仍须正确申请并保留该能力。[Apple 能力表](https://developer.apple.com/help/account/reference/supported-capabilities-ios) [Apple 健康授权说明](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)

若重签后仍报同样的错误，可对工具导出的最终 IPA 执行：

~~~powershell
python tools/check_ios_health_entitlements.py '实际重签名后的文件.ipa'
~~~

该工具静态检查 iPhone、Watch 的真实签名授权和个人描述文件；不验证 Apple 证书链，也不能代替真机授权测试。检查构建提供的待个人签名包时使用 `--allow-prepared`，此模式不会把缺少个人描述文件当作错误。应用会在签名缺失时说明原因并停止自动健康读取，手动体重、饮食等功能继续保留。

## 功能验证范围

- 手机系统最低要求为 iOS 17。
- 首轮可验证首次设置、地址持久化、饮食与体重记录、趋势、AI 接口配置、导入导出，以及连接实际后台后的同步与双人功能。
- 普通 Apple 开发者账号支持 HealthKit，重签名工具还需要正确保留对应授权，实际健康数据读取须在手机验证。
- 远程 APNs 推送需要支持 Push Notifications 的开发者会员签名。本地提醒可单独测试。
- IPA 包含 Watch 应用，第三方重签名的 Watch 安装与配对兼容性需要另行验证。遇到签名或安装报错时，应保留错误信息再处理。

账号能力以上述 Apple 官方能力表为准。[Apple iOS 能力与会员类型](https://developer.apple.com/help/account/reference/supported-capabilities-ios)

## 首次打开

可以先体验离线记录。在首次设置或“我的”中填写实际后台 HTTP 或 HTTPS 地址、AI 接口地址、密钥与模型。

后台地址及 AI 配置保存后，后续启动自动读取。内网自签证书的安装、直接注册与后台运行方法见同目录的《部署与运行.md》。
