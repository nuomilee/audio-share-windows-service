# 部署指南

把服务安装到另一台 Windows 电脑，替换原来的 cmd 启动方式。全程约 5 分钟，只需要管理员权限。
命令都在 **管理员 PowerShell** 中执行。

## 准备

- 目标电脑：Windows 10/11，声音播放正常
- 在开发机生成发布包：

  ```powershell
  powershell -ExecutionPolicy Bypass -File scripts\package.ps1
  ```

  得到 `dist\audio-share-service-1.0.0-win64.zip`（约 1 MB）
- 用远程桌面文件传输 / 共享目录 / U 盘把 zip 复制到目标电脑
- 记住目标电脑上旧启动方式的启动项位置（下一步清理用）

## 1. 停掉旧的 cmd 方式

先关掉桌面上那个 `as-cmd` 的 cmd 窗口；如果不方便关，在管理员 PowerShell 里：

```powershell
Get-Process as-cmd -ErrorAction SilentlyContinue | Stop-Process -Force

# 确认端口已释放：没有任何输出就是干净的
Get-NetTCPConnection -LocalPort 65530 -State Listen -ErrorAction SilentlyContinue
```

再清掉开机自启，避免重启后又冒出旧实例：

```powershell
# 启动文件夹 / 注册表 Run 里的快捷方式
Get-CimInstance Win32_StartupCommand |
  Where-Object { $_.Command -match 'as-cmd|audio-share' } |
  Format-List Name, Command, Location, User

# 计划任务
Get-ScheduledTask |
  Where-Object { $_.Actions.Execute -match 'as-cmd' } |
  Select-Object TaskName, TaskPath, State
```

- 启动文件夹：`Win+R` 输入 `shell:startup`，删掉相关快捷方式
- 任务计划：`taskschd.msc` 里删除对应任务
- 注册表：`regedit` → `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`

> 旧的 cmd 窗口如果是“以管理员身份运行”开的，普通 PowerShell 可能结束不掉，
> 用管理员 PowerShell 再执行一次 `Stop-Process`。

## 2. 解压并安装

把 zip 解压到任意目录（例如 `C:\Services\audio-share-service-1.0.0`），然后：

- 右键 **`install.cmd`** → **以管理员身份运行**
- UAC 弹窗点“是”，会新开一个管理员窗口显示过程

脚本会依次完成：

1. 如果已装过旧版本，先停掉并删除旧服务
2. 复制文件到 `C:\Services\audio-share`（已有 `settings.ini` 会保留）
3. 检查端口是否被占用（被占用会直接报错，提示先关旧程序）
4. 创建防火墙入站规则：TCP/UDP 65530、UDP 65531
5. 注册服务 `AudioShareServer`：自动启动、依赖 `Audiosrv`、崩溃自动重启
6. 启动服务，并等到日志里出现 `server started`

成功时最后一行是：

```
OK: AudioShareServer 已安装并运行，开机自动启动。
```

## 3. 验证

```powershell
Get-Service AudioShareServer
sc.exe qc AudioShareServer

$log = "C:\Services\audio-share\logs\as-cmd-$(Get-Date -f yyyyMMdd).log"
Get-Content $log -Tail 30

Get-NetTCPConnection -LocalPort 65530 -State Listen
```

日志里应该能看到：

```
[service] as-cmd started, pid=...
[info] tcp listen success on 0.0.0.0:65530
[info] server started
[info] select audio endpoint: 扬声器 (...)
```

然后用手机 App 连接 `目标电脑IP:65530`，确认声音正常。

## 4. 验证开机自启（可选）

重启目标电脑，**不登录**任何账号，等 1 分钟，手机直接连接：

- 能播放 → 开机自启没问题
- 连不上 → 查看服务状态和日志（见[常见问题](troubleshooting.md)）

## 5. 按需调整

- 电脑上如果有多个声卡 / 虚拟声卡，先列出设备：

  ```powershell
  C:\Services\audio-share\as-cmd.exe -l
  ```

  带 `*` 的是当前默认设备。
- 编辑 `C:\Services\audio-share\settings.ini`，例如固定采集某个设备：

  ```ini
  args=--bind=0.0.0.0 --discovery -e "{0.0.0.00000000}.{xxxxxxxx-xxxx-...}"
  ```

- 改完重启服务：

  ```powershell
  Restart-Service AudioShareServer
  ```

更多参数见[配置说明](configuration.md)。

## 6. 升级

把新版本 zip 解压到新目录，再运行一次 `install.cmd` 即可。
`settings.ini` 和 `logs\` 会保留，服务会被平滑替换。

## 7. 回滚

```powershell
# 停止并删除服务（保留文件）
.\uninstall.cmd

# 连文件一起删
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -RemoveFiles
```

然后把原来的 cmd 启动方式放回去。

## 备注

- 如果开着第三方安全软件，可能需要手动放行 `C:\Services\audio-share\as-cmd.exe`
  和 65530/65531 端口（脚本只写 Windows 防火墙规则）。
- 多台电脑可以同时跑服务，手机在 App 里选哪台就连哪台；
  局域网发现会同时看到多台，这是正常的。
- 服务在后台会话中运行，实测可以正常采集默认播放设备（包括虚拟声卡）。
