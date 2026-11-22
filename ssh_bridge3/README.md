# ssh-bridge v3 · 3.0-s13-r4（独立发布仓库 + 应用内升级 + 分屏布局持久化）

原生 Win32 单进程桌面工具：串口 / SSH / 日志共用一个环形缓冲，界面直读内存；
另带一条**只在本机**的 HTTP 桥，让 AI（或脚本）像操作 DOM 一样读写每一个控件。

> 源码仓库：<https://github.com/yanggan2015/ssh-bridge-v3>  
> 二进制发布仓库：<https://github.com/yanggan2015/ssh-bridge-v3-releases>

## 一分钟上手

```powershell
# 1) 解压后进入目录（路径不要带空格以外的怪字符；中文路径没问题）
# 2) 直接双击 ssh_bridge3.exe，或：
.\ssh_bridge3.exe
# 3) 另开一个终端做冒烟（会自己起进程、驱动控件、再退出）
powershell -NoProfile -File tools\smoke.ps1
```

窗口起来后：左侧是通道树（示例配置里有一块 `loop:ai` 回环板，可当“有回显的板子”用），
右侧是终端视图，上方搜索框输入即定位。

## 更新

发布仓库固定提供：

- `ssh-bridge-v3-<版本>-win64.zip`：更新包本体。
- `ssh-bridge-v3-<版本>-win64.UPDATE.json`：本地版本清单，含 zip 与 exe 的 SHA-256。
- `ssh-bridge-v3-<版本>-win64.zip.sha256`：zip 校验文件。

应用内升级：

**帮助 → 检查更新…**，或 **关于 → 检查更新**。默认读取：

`https://raw.githubusercontent.com/yanggan2015/ssh-bridge-v3-releases/windows_x86_64/UPDATE.json`

检查到新版本后会自动下载 GitHub Release 资产、校验 zip 与 exe 的 SHA-256、停止旧进程、替换文件并重启。
配置、`work\`、`logs\`、`keys` 不会被改动。

命令行方式：

```powershell
# 只检查
powershell -NoProfile -File tools\update.ps1 -CheckOnly
# 下载并更新；成功后自动重启原来在运行的实例
powershell -NoProfile -File tools\update.ps1
# 也可以显式指定清单
powershell -NoProfile -File tools\update.ps1 -Manifest <UPDATE.json 的 http(s) 地址或本地路径>
```

更新器只替换 `ssh_bridge3.exe`、`README.md`、`VERSION.txt` 和 `tools\` 下的文件；
**不会修改** `ssh_bridge_config.json`、`work\`、`logs\`、`keys\` 或任何用户数据。
校验或替换失败会回滚并返回非 0。

## 界面与快捷键

- 首次启动按工作区 **90%** 开窗；之后记住上次的位置和大小（`output\ui_prefs.ini`）。
- 工具栏：`新建` `刷新` `重连` `断开` `清屏` `通道`（重连/断开作用于当前选中通道；`断开` 会释放串口/SSH，之后可再点“重连”恢复）。
- 快捷键：**F5** 刷新 · **F3** 下一个命中 · **Ctrl+F** 跳到搜索框 · **Ctrl+B** 显示/隐藏通道树。
- 回车发送：**SSH 固定发单个 CR**（避免 PTY 把 CRLF 当两次换行、产生双提示符）；串口按该通道 `line_ending` 配置发送（CRLF / LF / CR / 无）。
- 状态栏 4 段：通道汇总 / 当前通道（分屏时显示 `画框N · 通道`） / **触发按钮 ID + 执行状态** / **脚本当前输出行**（执行结束后保留最后一行）。
- `关于` 窗口读取安装目录 `VERSION.txt`，显示实际发布版本；开发目录没有该文件时显示 `3.0-dev`。
- 关闭窗口（X）＝收进托盘；托盘菜单里才是真正退出。

## 配置查找顺序

启动目录 → exe 同目录 → `~\.ssh-bridge\ssh_bridge_config.json` → `config.json`。
先看启动目录，便于同一台机器用不同配置做测试；双击绿色版时启动目录没有配置，自然落到 exe 同目录。
启动成功后程序会把工作目录切到 `project_root`，状态文件不会落到 `System32`。

## 目录

| 文件 | 说明 |
| --- | --- |
| `ssh_bridge3.exe` | 主程序（静态链接，目标机不需要 MSYS2 / DLL） |
| `VERSION.txt` | 当前版本、构建 UTC、exe SHA-256 |
| `ssh_bridge_config.json` | 示例配置：`agent.enable=true`，端口 18086，token 为空 |
| `tools\ui_probe.py` | 桥接探针（技能自带；**本程序端口是 18086**，用 `--base` 指定） |
| `tools\smoke.ps1` | 冒烟脚本：起进程 → 读树 → 输入/搜索/滚动/分屏/关于窗 → 退出 |
| `tools\update.ps1` | 独立更新器：版本比较、SHA-256 校验、白名单替换、失败回滚 |
| `README.md` | 本文件 |

## 配置要点

```json
{
  "boards": [ {"name":"loop1","serial_device":"loop:ai","auto_open":true} ],
  "ssh":    [ {"name":"board","host":"192.168.1.10","port":22,"username":"root","password":""} ],
  "agent":  {"enable": true, "port": 18086, "token": ""}
}
```

- `serial_device` 支持 `COM5` 这类真实串口，也支持 `loop:<名字>` 回环端点（无硬件时自测用）。
- `agent.enable=false`（或删掉 `agent` 段）时进程**不监听任何端口**，回到纯本地形态。
- `agent.token` 非空后，所有请求要带 `X-Ui-Token`，否则 401。建议对外演示时设一个。

## 桥接接口（127.0.0.1:18086）

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/ping` | 探活：`{"ok":true,"protocol":"1.1"}` |
| GET | `/capabilities` | 协议、端口、可用动作白名单 |
| GET | `/ui-tree` | 扁平控件清单（id/role/text/rect/actions/items/value…） |
| GET | `/control?id=...` | 单控件快照；不存在 404 |
| GET | `/state` | 业务真值：通道、终端分屏/回看位置/尾 2 行/搜索命中、关于窗是否打开 |
| POST | `/action` | `{"id":"btn.refresh","action":"click"}`、`{"id":"edit.search","action":"set_text","text":"abc"}`、`{"id":"term.scroll","action":"set_value","value":4}` |
| GET | `/logs?since=N` | 动作审计（环形 128 条） |

**关键约定**：`ok:true` 只代表动作送达 UI 线程，业务是否正确必须紧接 `/state` 或 `/control` 复核。

## 控件清单（可直接喂给 AI）

| 控件 id | 类型 | 能做什么 |
| --- | --- | --- |
| `btn.refresh` / `btn.reconnect` / `btn.disconnect` / `btn.clear` / `btn.toggleTree` | 按钮 | 刷新视图 / 重连 / 断开并释放通道 / 清屏 / 收起展开通道树 |
| `tree.channels` | 树 | 读通道清单（items/item_count/selected），`select` 切通道 |
| `label.searchHint` / `label.keyHint` | 静态文本 | 搜索标签 / 快捷键提示（窄窗自动收起） |
| `label.status` | 状态栏 | 四段文案（汇总 / 当前通道 / 触发按钮与状态 / 脚本当前输出行） |
| `edit.search` | 编辑框 | 写搜索词（输入即定位）、读、清空 |
| `term.view` | 自绘终端 | 读文字、聚焦 |
| `term.input` | 虚拟编辑框 | 写文字并**回车**（发到板端） |
| `term.send` | 虚拟编辑框 | 只发原始文字，不回车（可带 `\r\n` 造多行） |
| `term.search` | 虚拟编辑框 | 在回看里搜索，命中即滚到命中行 |
| `term.scroll` | 虚拟滑条 | `value` = 距底部行数；`set_value` 绝对定位 |
| `term.clear/copy/paste/reload/focus` | 虚拟按钮 | 清屏 / 复制选区 / 粘贴 / 加载历史 / 聚焦 |
| `term.split1/split2/split4` | 虚拟按钮 | 1 / 2 / 4 窗格 |
| `menu.view.*`、`menu.tray.*`、`menu.file.exit`、`menu.help.about` | 虚拟菜单 | 与真实菜单同一条 `WM_COMMAND` 路径 |
| `about.text` / `btn.about.ok` | 关于窗 | 读内容 / 关闭（关于窗是非模态，不挡桥接） |

## 命令行自测（不写代码）

```powershell
$base = 'http://127.0.0.1:18086'
(Invoke-RestMethod "$base/ping")
(Invoke-RestMethod "$base/capabilities").actions
(Invoke-RestMethod "$base/ui-tree").controls | Select-Object id,role,actions
(Invoke-RestMethod "$base/state").state.terminal

# 写搜索框 + 回读
$b = @{id='edit.search';action='set_text';text='hello'} | ConvertTo-Json
Invoke-RestMethod -Method Post "$base/action" -ContentType 'application/json' -Body $b
(Invoke-RestMethod -Method Post "$base/action" -ContentType 'application/json' `
    -Body (@{id='edit.search';action='get_text'} | ConvertTo-Json)).result.text

# 往板端发一行命令，再搜回来
Invoke-RestMethod -Method Post "$base/action" -ContentType 'application/json' `
    -Body (@{id='term.input';action='set_text';text='ls -l'} | ConvertTo-Json)
(Invoke-RestMethod "$base/state").state.terminal.panes[0]

# 探针（技能自带，注意 --base）
python tools\ui_probe.py --base $base tree
python tools\ui_probe.py --base $base click btn.refresh
```

## 已知边界

- 只监听 `127.0.0.1`，不对外网开放；没有 token 时同机任何程序都能驱动，正式演示请设 `agent.token`。
- 搜索需要“回看行”：回显端点按 CRLF 分行，单行输入会不断覆盖当前行，搜不到别怪搜索。
- 串口/SSH 的真实板子要自己填 `boards` / `ssh`；`loop:` 端点只是自测回显。
- 关闭窗口（X）是收进托盘，托盘菜单里才是退出；桥接进程退出后端口立即释放。

## 许可与来源

桥接层与探针来自 `win32-ai-ui-bridge` 技能（mongoose 7.x + cJSON）；终端与串口/SSH 为本项目自研。

## SFTP 文件传输（S10）

菜单 **文件 → SFTP 文件传输…（F7）** 打开非模态双栏面板：左侧本地、右侧远端。

- 顶部：通道下拉（只列 SSH 通道）+ 连接。
- 本地/远端：路径是可编辑下拉（历史路径可直接选），刷新/上级在标题行，路径独占整行不截断。
- 列表下方是属性条：
  - 远端：`目录|文件|链接 · 权限 · uid:gid · 大小 · 修改时间（本地时区）`；
  - 本地：`目录|文件 · 大小 · 修改时间`。
  - 选中条目立即刷新属性；选中远端项会把纯名（无尾斜杠）回填到名称框。
- **名称（可编辑下拉）** + `新建目录` / `重命名` / `删除`：
  - 新建：输入名称 → 新建目录；
  - 重命名：先在远端列表选中 → 名称自动带出 → 改成新名 → 重命名；
  - 删除：先选中 → 第一次点“删除”变“确认删除”，3 秒内再点才执行；删除成功后名称框清空。
  - 空名称、含 `/` 或 `\`、`.`/`..`、新旧同名都会被拦截并提示。
- **目录递归传输**：选中目录后点上传/下载自动切换为递归模式，保留空目录与嵌套层级；
  上传保留源目录名（本地 `tree_src` → 远端 `/tmp/tree_src`）。
- **断点续传**：上传/下载中途取消或失败会保留 `.part`，点“重试”从已传字节继续；
  成功后才改名/覆盖并清理 `.part`。源文件在断点之后被修改时，守卫条件会判定断点失效并从 0 重传。
- **队列明细**：目录任务显示“当前文件 + 百分比 + 下一个文件 + 排队数”；`/state` 暴露完整计划。
- 底部：进度条、队列/阶段、状态；成功 100%；刷新后进度归 0。
- 完整性：≤4 MB 上传后做全量 MD5；>4 MB 只核对远端大小，避免二次全量回读拖慢完成反馈。
- 目录非空删除会失败并提示“目录可能非空或无权限”。
- **传输历史**：底部“历史”打开独立窗口，记录最近 50 条（最新在上）：时间、方向、文件、大小、耗时、均速、结果、重试次数；选中行后下方只读框显示完整失败原因/校验结果，可清空。成功、失败、取消、重试都会入历史。
- **限速设置**：底部“设置”打开独立窗口；限速是**可编辑下拉**（0 / 100 / 500 / 1024 / 5120 / 10240 KB/s，也可手输），0 = 不限。保存才生效，关闭不落盘。限速只作用于 SFTP 上传/下载，**不影响串口/SSH 回显与终端操作**。
- 历史与设置可同时打开；两者自动上下排布（历史在上、设置在下），不会互相遮挡。

AI 桥接 id（主面板 30 个 + 历史 5 个 + 设置 5 个，共 40 个）：

主面板：`sftp.channel`、`sftp.connect`、`sftp.local.path/list/refresh/up/info`、`sftp.remote.path/list/refresh/up/info`、`sftp.name`、`sftp.mkdir`、`sftp.rename`、`sftp.delete`、`sftp.upload`、`sftp.download`、`sftp.cancel`、`sftp.retry`、`sftp.history.open`、`sftp.settings.open`、`sftp.close`、`sftp.progress`、`sftp.status`、`sftp.queue`，以及 `sftp.label.channel/local/remote/name`。

历史窗口：`sftp.history.summary`、`sftp.history.list`、`sftp.history.detail`、`sftp.history.clear`、`sftp.history.close`。

设置窗口：`sftp.settings.label.speed`、`sftp.settings.speed`、`sftp.settings.note`、`sftp.settings.save`、`sftp.settings.close`。

列表 `select` 支持 `name/`、`name\` 或纯名；找不到会返回 404，不会静默选第一项。

`POST /action` 例：

```powershell
$b='http://127.0.0.1:18086'
# 选中远端目录（支持 “name/” 或纯名）
Invoke-RestMethod "$b/action" -Method Post -ContentType 'application/json' `
  -Body (@{id='sftp.remote.list';action='select';text='demo_a'}|ConvertTo-Json)
# 改名为 demo_b
Invoke-RestMethod "$b/action" -Method Post -ContentType 'application/json' `
  -Body (@{id='sftp.name';action='set_text';text='demo_b'}|ConvertTo-Json)
Invoke-RestMethod "$b/action" -Method Post -ContentType 'application/json' `
  -Body (@{id='sftp.rename';action='click'}|ConvertTo-Json)
# 删除（必须两次，间隔 <3s）
Invoke-RestMethod "$b/action" -Method Post -ContentType 'application/json' `
  -Body (@{id='sftp.remote.list';action='select';text='demo_b'}|ConvertTo-Json)
1..2 | ForEach-Object {
  Invoke-RestMethod "$b/action" -Method Post -ContentType 'application/json' `
    -Body (@{id='sftp.delete';action='click'}|ConvertTo-Json)
  Start-Sleep -Milliseconds 100
}
(Invoke-RestMethod "$b/state").state.ui.sftp
# 传输取消后，从已保留的 .part 续传
Invoke-RestMethod "$b/action" -Method Post -ContentType 'application/json' `
  -Body (@{id='sftp.retry';action='click'}|ConvertTo-Json)
```

`/state.ui.sftp` 关键字段：`connected`、`remote_path`、`remote_items`、`remote_entries`、`local_info`、`remote_info`、`remote_sel`、`name_text`、`delete_armed`、`transfer.phase_code/percent/files/total_files/note`、`transfer.plan/plan_index/plan_total/can_retry`、`history_open`、`settings_open`、`history_count`、`history[]`、`speed_limit_kbps`、`speed_limit_text`、`status`。

## 示例通道（已脱敏）

| 名称 | 类型 | 参数 |
| --- | --- | --- |
| loop1 / s6loop2 | 回环 | `loop:ai`，无硬件也能看回显 |
| ztl | 串口 | COM3 @1500000 |
| ok3568 | 串口 | COM5 @115200（密码已清空，请自行填写） |
| ssh-link-demo1 | SSH | 39.97.234.200:52222 demo/123456 |
| ssh-link-demo2 | SSH | sshbridge.online:52223 demo/123456 |

## 继电器与板控按钮（S12）

顶级菜单 **继电器** 打开独立窗口，三页签：

1. **继电器设备**：设备名/Windows 串口/波特率/通道数为可编辑下拉；Linux 串口为选填；写后延时、脉冲时长可编辑下拉；IO 低电平有效、脉冲极性取反、启用设备为复选。支持新增/保存/删除/刷新、测试 ON/OFF/脉冲，状态回读 CH1..N。
2. **板卡绑定**：选择目标 SSH/串口通道，为板子绑定单路继电器动作；必填 ID、按钮文字、继电器、通道、模式（hold_on/hold_off/pulse）、保持/脉冲秒、启用、极性取反。支持新增/保存/删除/测试执行；一键生成 `power_on / power_off / reboot`，以及生成“进升级模式”脚本按钮。
3. **按钮脚本**：为当前通道添加 Lua 5.4 脚本或简单脚本（行式 DSL）。Lua 支持 `channel.*`、`relay` / `relay_mode`、`action` / `board.action`、`board.power_on/power_off/reboot`、`msleep` / `sleep`、`print`、`host_exec` / `hostcmd`、`remotecmd`；简单脚本支持 `write/send/keys/send_keys/login/relay/msleep/action`，并新增 `hostcmd/remotecmd/expect/echo/sleep`。脚本正文按多行显示，`测试执行` 不落盘也能先跑。

按钮被点击后，主窗口状态栏第三段立即显示触发的按钮 ID 和耗时，第四段逐行显示脚本 `print/echo/hostcmd/remotecmd` 的当前输出；执行完成后保留最后一行。

菜单 **板控按钮** 直接进入“按钮脚本”页。主窗口当前画框有启用按钮时，终端上方显示按钮条；分屏时按钮条跟随**当前激活画框**自动切换，左侧显示 `板控 · 画框N · 通道名`，空画框显示“未绑定通道”，没有按钮的通道标注“（无按钮）”。点击按钮走统一执行器，继电器、板端命令、本机命令、Lua 脚本都从同一入口执行。分屏数量、各画框通道和激活画框会自动保存到配置 `ui.split / ui.pane_channels / ui.active_pane`，重启后恢复原布局。

### 继电器与文件服务是分开的

- 继电器窗口只管继电器和板卡按钮；不再与 TFTP/共享/NFS 混在一起。
- 菜单 **文件服务** 打开独立窗口，关闭窗口不会停止已启动的服务。

### 文件服务

- 三者共用“共用目录”（默认 `work/share`），可手输/下拉，也可点“选择…”调用系统目录对话框。
- TFTP：地址下拉（自动 / 127.0.0.1 / 本机 IP），端口下拉 69/6969/1069；`允许写入` 取消后 WRQ 返回 `ERROR code 2`；越界路径返回 `ERR:bad path`。
- 共享 HTTP：端口可编辑下拉（18082/18083/8080）；`/`、`/browse`、`/upload`（multipart 或 `?file=` 裸 PUT）、`/files`、`/mkdir`、`/delete`；中文目录/文件名可用；启动后可一键打开浏览器。
- NFS：别名 `/share` 与 `/mnt/share` 均可挂载；UID/GID 可编辑下拉；使用内嵌 WinNFSd，监听 111/1058/2049。
- 端口冲突会给中文原因；`全部停止` 一次释放全部服务端口。

继电器窗口主要控件：`relay.dev.*`、`relay.bind.*`、`relay.script.*`、`relay.message/close`；文件服务窗口：`filesvc.root*`、`filesvc.tftp.*`、`filesvc.share.*`、`filesvc.nfs.*`、`filesvc.save/stopall/close/message`；主窗口按钮：`board.btn.<id>`。完整设计与验收见仓库 `docs/详细设计-S12-工作台重构.md`。


