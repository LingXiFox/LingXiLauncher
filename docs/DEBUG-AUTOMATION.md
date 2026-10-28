# GUI debug automation（仅调试）

默认完全关闭。只有显式设置 `LINGXI_DEBUG_AUTOMATION=1` 或传入 `--debug-automation` 才会启动本机回环 TCP 控制接口。

## 启动

```bash
LINGXI_DEBUG_AUTOMATION=1 \
LINGXI_DEBUG_AUTOMATION_PORT=59321 \
LINGXI_DATA_ROOT="$PWD/.dev-sandbox/data" \
LINGXI_GAME_ROOT="$PWD/.dev-sandbox/mc" \
  ./dist/LingXiMac.app/Contents/MacOS/LingXiMac
```

监听地址：`127.0.0.1:59321`（不接受非 loopback 连接）。协议为每行一个 JSON：

```json
{"action":"mods.state","params":{}}
```

响应是一行 JSON，带 `ok` 和真实执行后的状态。

## 原则

- 调试 action **调用视图真实按钮使用的同一个方法/属性**，不是另写一套安装/删除逻辑。
- 例如 `mods.install` 调用 `ModsStore.install`，`mods.toggle` 调用 `ModsStore.toggle`，`mods.update` 调用 `ModsStore.update`；真实 UI 按钮也调用这些方法。
- 每次 action 返回后会读取当前 `installed`、`versions`、`updates`、`error` 等状态，避免“内部点击成功、页面没有变化”的假阳性。
- 关闭窗口 / `.onDisappear` 时自动注销该实例的 action。

## 已注册 action

| Action | 参数 | 作用 |
|---|---|---|
| `debug.actions` | — | 列出当前可见 action |
| `app.state` | — | 页面、选中实例、实例列表 |
| `app.section` | `section` | 切换页面（home/instances/downloads/accounts/logs/settings） |
| `mods.open` | `instanceID` | 打开指定实例的模组管理（与按钮共用 `AppModel.openMods`） |
| `mods.state` | — | 当前 tab、本地模组、搜索结果、选中项目/版本、更新、错误 |
| `mods.tab` | `tab=installed|browse` | 切换双视图（共用 `ModsStore.selectTab`） |
| `mods.search` | `query`, `category`, `sort` | 执行真实搜索 |
| `mods.select` | `projectID` | 打开真实项目详情/兼容版本 |
| `mods.install` | `versionID?`, `replace=true?` | 调用真实安装流程并等待结束 |
| `mods.toggle` | `file` | 调用真实启用/禁用流程 |
| `mods.delete` | `file` | 调用真实删除确认后的删除方法 |
| `mods.checkUpdates` | — | 调用真实更新检测 |
| `mods.update` | `projectID` | 调用真实更新流程并等待结束 |
| `mods.close` | — | 关闭模组管理 sheet |

示例：

```bash
python3 - <<'PY'
import json, socket
def call(action, **params):
    s = socket.create_connection(("127.0.0.1", 59321), timeout=60)
    s.sendall((json.dumps({"action": action, "params": params}) + "\n").encode())
    print(s.recv(1 << 20).decode())
    s.close()
call("mods.open", instanceID="fabric-mods")
call("mods.search", query="sodium")
call("mods.state")
PY
```

该接口不用于生产，不提供认证；只监听 loopback，且需要显式环境变量，避免正常用户误触。调试结束后取消环境变量并重启即可完全关闭。
