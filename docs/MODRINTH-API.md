# Modrinth API 使用说明（M6.2）

本项目只通过 **Modrinth 官方 v2 API** 提供 Fabric 模组浏览和安装；不内置模组文件，不搭建镜像，不抓取网页。

## 官方规范与限制

- API base：`https://api.modrinth.com/v2`
- OpenAPI 版本：`v2.7.0`（2026-10-27 获取）
- 文档：[OpenAPI spec](https://docs.modrinth.com/openapi.yaml)、[Search API](https://docs.modrinth.com/api/operations/searchprojects/)
- 条款：[Modrinth Terms of Use](https://modrinth.com/legal/terms)
- 速率限制：**300 requests/minute per IP**；响应提供 `X-Ratelimit-Limit`、`X-Ratelimit-Remaining`、`X-Ratelimit-Reset`。
- 必须提供可唯一识别应用的 `User-Agent`。本项目使用：
  `LingXiFox/LingXiLauncher/<version> (https://github.com/LingXiFox/LingXiLauncher)`
- 搜索分页；单页最大 100 条。客户端默认每页 20 条，不并发轰炸 API。

## 使用边界

- 只搜索 `project_type:mod`，且强制 `categories:fabric` + 当前实例的 `versions:<minecraft>`。
- 只展示 Modrinth 返回的项目元数据（标题、简介、作者、图标、许可证、下载量）。
- 模组文件由用户确认安装后，从 Modrinth 返回的 `cdn.modrinth.com` HTTPS 地址直接下载。
- Core 拒绝非 HTTPS、非 `cdn.modrinth.com` 的模组下载地址；不跟随用户输入的任意 URL。
- 不缓存或再分发模组 JAR；不绕过项目许可证。安装记录保留 `project_id`、`version_id`、许可证名称与原始文件名。
- 不把 Microsoft/Xbox/Minecraft 令牌发送到 Modrinth；API 请求不携带认证信息。
- Modrinth API License 是有限、可撤销的许可；本项目按条款以用户主动操作的方式查询/下载内容，不宣称对模组内容拥有权利。
- Modrinth 名称与商标属于其权利人；UI 仅作来源说明。

## 依赖语义

Modrinth `VersionDependency.dependency_type`：

| 类型 | 行为 |
|---|---|
| `required` | 递归解析并自动安装；固定 `version_id` 时校验该版本 |
| `optional` | 展示，不自动安装 |
| `incompatible` | 安装前阻断并明确报错 |
| `embedded` | 随主模组提供，不重复下载 |

所有文件先写入实例私有 staging 目录；SHA-512（优先）或 SHA-1 + size 校验通过后才移入 `mods/`。更新时旧文件先移到备份路径，任何失败都会恢复。

## 参考

- [Modrinth API documentation](https://docs.modrinth.com/)
- [Modrinth Terms of Use](https://modrinth.com/legal/terms)
- [Modrinth OpenAPI v2.7.0](https://docs.modrinth.com/openapi.yaml)
