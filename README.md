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

AI 在“我的 → AI 与个性化估算 → 设置 AI 接口、密钥与模型”配置。支持保存接口地址、API Key、调用方式和模型，读取接口的模型列表或手动填写模型标识。接口采用 Responses API 格式。可选私有后台代发或 iPhone 直连，外部照片处理需要用户明确开启。

## 运行入口

后台部署、HTTPS 证书、开户、Xcode 签名与备份操作见 docs/部署与运行.md。

测试结果、已验证边界与真机验收项见 docs/测试与验收.md。

~~~powershell
Set-Location 'D:\codeing\jianfei'
Copy-Item .env.example .env
New-Item -ItemType Directory -Path secrets -Force
# 编辑 .env，填入实际局域网地址
docker compose up -d --build
docker compose exec api python -m app.cli enrollment
~~~

在 Mac 上打开 ios/BingJian.xcodeproj，选择签名团队和自己的 Bundle Identifier 后构建。

## GitHub 云端自动测试

推送到 main，或创建、更新目标为 main 的合并请求时，按变更内容自动验证；两个流程也支持在 Actions 页面点击 Run workflow 手动运行。

- [后台自动测试与 Docker 验收](https://github.com/NieTen/jianfei/actions/workflows/backend-tests.yml)：Python 3.11、3.13 执行后台测试；另在 Linux 构建镜像、启动 API 与 Caddy、校验 HTTPS，并检查重建容器后的数据卷保留。
- [iOS 测试包与界面验收](https://github.com/NieTen/jianfei/actions/workflows/ios-test-package.yml)：云端 Mac 编译 iPhone 与 Watch、执行 XCTest，并保存 IPA、模拟器包和页面截图。

后台或部署配置变更触发后台流程，iOS、工程生成器或共享食物协议变更触发客户端流程。单纯修改说明文档不会启动构建。同一分支的新提交会取消该流程未完成的旧任务，日志与测试产物保留七天。详细覆盖范围见 docs/测试与验收.md。

## 当前验证状态

后台已在 GitHub 的 Linux 运行器上完成 Python 3.11 与 3.13 两组回归，每组 42 项全部通过，包含真实 HTTP 启动与重启、配置保留和后台删除任务。Docker 已通过 linux/amd64 镜像构建、API 与 Caddy 启动、HTTPS 和重建容器后的数据卷保留检查。万条合成记录下的日期汇总查询命中了复合索引。

2026 年 11 月 6 日，0.1.2 已通过云端 Xcode 16.4 的 iPhone 与 Watch 编译，16 项 XCTest 通过，包含实际钥匙串写入、更新和 AI 配置重新加载。此次修复网页模拟器中“安全凭据保存失败”，为模拟器包补齐应用身份与钥匙串授权，保留 0.1.1 的暖白、森林绿、深色模式及大字体适配。工作流同时生成待签名 IPA、模拟器应用包和页面截图，Windows 安装及浏览器模拟流程见 docs/Windows安装iOS测试包.md。

签名安装、HealthKit 与 Watch 真机联调，以及实际设备的帧率和内存仍待验证。Docker 的 linux/arm64、多架构部署、空卷恢复及受限资源下的负载测试仍待验证。真实 AI 服务、USDA 和 APNs 联调需要对应凭据。

备份默认复用哈希相同的加密附件，也可生成独立的完整加密包。每次备份执行恢复完整性校验。完整验收以测试与验收文档为准。
