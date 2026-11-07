# 并肩

本地优先的减脂记录与伙伴激励应用。当前交付包含 iPhone、Apple Watch 源码，以及可独立运行的轻量后台。

## 本次开发范围

用户确认的 P0、P1、P2 均纳入本次开发，项目暂用名为“并肩”。

- SwiftUI 原生界面，包含档案、饮食、体重、围度、健康摘要、趋势、伙伴和设置。
- Python、FastAPI、SQLite 后台，使用 Docker Compose 与 Caddy 部署。
- 本机保存、增量同步、版本冲突处理、多设备和账号隔离。
- HealthKit 历史回填与增量读取，覆盖步数、能量、体重、运动、心率、睡眠、距离和体脂率。
- 本机 Vision 分类、Responses API 图片识别、营养库搜索、常用食物和估算偏好。
- 双人及最多八人挑战、逐成员共享授权、积分、连续记录、鼓励和可选 APNs 通知。
- Watch 快捷记录与持久化传输队列。
- 加密导出导入、数据删除、删除回执、自动备份和恢复校验。

## 首次设置

第一次打开应用时填写后台地址。保存后自动复用，后续可在“我的 → 私有服务器与账号”修改。

注册用户名为 3～64 位英文字母、数字或 . _ -，密码为 10～128 位，称呼为 1～40 个字符。0.1.6 起直接注册，无需系统密钥或开户凭据；需同时更新 App 与 NAS 后台。提交时同时标红全部不合格字段并逐项提示，修改后逐项清除。后台连接测试只检查服务可达性，不代表表单已通过校验。

0.1.3 起可显式填写 `http://` 后台地址，适合可信局域网测试；不写协议仍默认 HTTPS。HTTP 连接不需要安装证书。群晖部署默认提供 18080 HTTP 端口，同时保留 8443 HTTPS。

AI 在“我的 → AI 与个性化估算 → 设置 AI 接口、密钥与模型”配置。支持保存接口地址、API Key、调用方式和模型，读取接口的模型列表或手动填写模型标识。接口采用 Responses API 格式。可选私有后台代发或 iPhone 直连，外部照片处理需要用户明确开启。

0.1.4 起，首次记录体重时可选择公斤或斤，保存后作为本机统一单位，下次录入和重新打开应用都会沿用。也可在“我的 → 使用偏好 → 本机体重单位”修改。首页、目标、体重历史、趋势、肌肉量和伙伴体重按本机单位换算，已配对 Watch 跟随手机单位；原有磅选项继续支持。伙伴选择斤时，你的 70 公斤会在伙伴端显示为 140 斤。体重存储、健康读取和同步仍统一用公斤，旧 NAS 后台无需升级，饮食的克、毫升及营养单位保持各自含义。

## 运行入口

后台部署、HTTPS 证书、开户、Xcode 签名与备份操作见 docs/部署与运行.md。

群晖 Container Manager 使用 deploy/synology 中的部署文件，直接拉取 `ghcr.io/nieten/jianfei-api:latest`，无需导入本地镜像或在 NAS 编译。配置内网 IP、登录私有镜像仓库、HTTP 连接及可选 HTTPS 的步骤见 deploy/synology/群晖部署说明.md。

测试结果、已验证边界与真机验收项见 docs/测试与验收.md。

~~~powershell
Set-Location 'D:\codeing\jianfei'
Copy-Item .env.example .env
New-Item -ItemType Directory -Path secrets -Force
# 编辑 .env，填入实际局域网地址
docker compose up -d --build
docker compose exec api python -m app.cli status
~~~

在 Mac 上打开 ios/BingJian.xcodeproj，选择签名团队和自己的 Bundle Identifier 后构建。

## GitHub 云端自动测试

推送到 main，或创建、更新目标为 main 的合并请求时，按变更内容自动验证。镜像发布只在 main 运行；各流程也支持在 Actions 页面点击 Run workflow 手动运行。

- [后台自动测试与 Docker 验收](https://github.com/NieTen/jianfei/actions/workflows/backend-tests.yml)：Python 3.11、3.13 执行后台测试；另在 Linux 构建镜像、启动 API 与 Caddy、校验 HTTPS，并检查重建容器后的数据卷保留。
- [iOS 测试包与界面验收](https://github.com/NieTen/jianfei/actions/workflows/ios-test-package.yml)：云端 Mac 编译 iPhone 与 Watch、执行 XCTest，并保存 IPA、模拟器包和页面截图。
- [群晖后台镜像发布](https://github.com/NieTen/jianfei/actions/workflows/docker-publish.yml)：main 的后台或群晖部署配置变更时构建 AMD64、ARM64 镜像，完成容器回归与部署检查后更新 GHCR 的 latest 标签。

后台或根目录部署配置变更触发后台流程，iOS、工程生成器或共享食物协议变更触发客户端流程；后台和 deploy/synology 变更触发镜像发布。只修改 README 或 docs 下的说明不会启动构建。同一分支的新提交会取消后台、iOS 流程未完成的旧任务，镜像发布串行执行。日志与测试产物保留七天。详细覆盖范围见 docs/测试与验收.md。

## 当前验证状态

后台已在 GitHub 的 Linux 运行器上完成 Python 3.11 与 3.13 两组回归，每组 44 项全部通过，包含无密钥注册、旧字段兼容、身份隔离、真实 HTTP 启动与重启、配置保留和后台删除任务。Docker 已通过镜像构建、API 与 Caddy 启动、HTTPS 和重建容器后的数据卷保留检查。万条合成记录下的日期汇总查询命中了复合索引。

2026 年 11 月 7 日，0.1.6 已通过云端 Xcode 16.4 的 iPhone 与 Watch 编译，41 项 XCTest 全部通过，包含真实 HealthKit 授权状态查询、签名错误分类、注册字段校验、体重单位、真实 HTTP、钥匙串和 AI 配置保存。手机 IPA 的 iPhone 与 Watch 均已携带 HealthKit 声明；仍须通过个人账号重新签名安装。模拟器包保留钥匙串授权。安装及浏览器模拟流程见 docs/Windows安装iOS测试包.md。

群晖镜像已发布 AMD64、ARM64 两种架构，各通过 44 项容器回归，以及无密钥注册、登录、HTTP、HTTPS 和重建后数据保留检查；ARM64 使用 QEMU 验证。需同时更新 App 与 NAS 后台才能使用新版注册。使用者的真实群晖部署、Sideloadly 最终签名、HealthKit 与 Watch 真机联调，以及设备帧率、内存、空卷恢复和负载测试仍待验证。真实 AI 服务、USDA 和 APNs 联调需要对应凭据。

备份默认复用哈希相同的加密附件，也可生成独立的完整加密包。每次备份执行恢复完整性校验。完整验收以测试与验收文档为准。
