# 常见问题

## 服务起不来 / 启动后马上停止

先看日志：

```powershell
Get-Content "C:\Services\audio-share\logs\as-cmd-$(Get-Date -f yyyyMMdd).log" -Tail 40
```

- `[service] failed to start as-cmd: ...` → 文件被杀软隔离，或 `as-cmd.exe` 路径不对
- `bind: ...` → 端口被占用（见下一条）
- 日志文件根本没生成 → 检查安装目录权限，或服务账号没有访问权限

`sc create` 直接注册 `as-cmd.exe` 会报 **1053**，这是正常的：控制台程序不响应 SCM。
请用本项目的 `install.ps1` 注册 `AudioShareService.exe`。

## 端口被占用

```powershell
Get-NetTCPConnection -LocalPort 65530 -State Listen |
  Select-Object LocalAddress, LocalPort, OwningProcess
Get-Process -Id <OwningProcess>
```

常见原因是旧的 cmd 窗口还开着。结束它再 `Start-Service`：

```powershell
Get-Process as-cmd -ErrorAction SilentlyContinue | Stop-Process -Force
```

## 手机搜不到 / 连不上

1. 确认手机和电脑在同一网段
2. 电脑上端口在监听：

   ```powershell
   Get-NetTCPConnection -LocalPort 65530 -State Listen
   ```

3. 防火墙放行：安装脚本会创建三条入站规则，名字是 `Audio Share Server ...`；
   如果被安全软件拦截，手动放行 `as-cmd.exe` 和 65530/65531
4. 电脑有多个网卡 / VPN 时，`--bind=0.0.0.0` 最稳；也可以直接在 App 里手动填 `IP:65530`
5. 路由器开了 AP 隔离（客户端隔离）时，同一 WiFi 下也互相连不通

## 连上了但没声音

- 看日志里的 `select audio endpoint:` 是不是你想采的设备
- 该设备上是否真的有声音在播放（系统音量、播放器是否静音）
- 服务启动后才切换的默认设备，需要 `Restart-Service AudioShareServer`
- 采集的是“默认播放设备”的 loopback，蓝牙耳机切走之后旧设备可能已经没声了

## 手机听到“别的电脑”的声音

典型场景：本机用 **ToDesk / 向日葵 / mstsc** 远程控制另一台电脑，并且开了“远程声音”。
远端的声音会被这些软件播放到本机的某个播放设备上；如果它和本机音乐在同一个设备，
`as-cmd` 采到的是整条设备的混音，手机就会同时听到两台电脑的声音。

判断方法：

- 打开「设置 → 系统 → 声音 → 音量合成器」，看当前默认设备上哪些应用在出声
- 最快的办法：把 ToDesk 的“声音”关掉 / 断开远程会话，再让手机重连，对比一下

解决：

- 只想让手机听本机：在 ToDesk 工具栏关闭“声音”，或串流时断开远程会话
- 想保留远程声音、但不进手机：把 ToDesk 的输出设备切到 `ToDesk Virtual Audio`
  （ToDesk 设置里的扬声器选择，或 Windows 的“每应用音频输出”）
- `mstsc`：远程桌面连接 → 本地资源 → 远程音频 → 选“不播放”
- 只想听另一台：手机直接连另一台的服务器，不经过本机

> `as-cmd` 按“设备”采集，不能按进程采集；所以要先让不同来源的声音落到不同设备上。

## 日志不更新

`as-cmd` 只在启动、连接、断开、设备变化等事件时写日志；没人连接时日志静默是正常的。
想确认进程活着：

```powershell
Get-Process as-cmd
Get-Service AudioShareServer
```

## 日志文件删不掉 / 被占用

宿主每写一行就关闭文件（`FileShare.ReadWrite | Delete`），正常情况下可以直接删除。
如果删不掉，检查是否有编辑器/杀软正打开着它。

## 彻底卸载

```powershell
# 发布包目录里
.\uninstall.cmd

# 或
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -RemoveFiles
```

服务、防火墙规则、`C:\Services\audio-share` 会一并清理。

## 需要更多信息

```powershell
Get-Service AudioShareServer | Format-List *
sc.exe qc AudioShareServer
sc.exe qfailure AudioShareServer
Get-Content "C:\Services\audio-share\logs\as-cmd-$(Get-Date -f yyyyMMdd).log" -Tail 100
```

## Windows 7 / 旧系统

- 安装脚本需要 **PowerShell 3.0+** 和 **.NET Framework 4.5+**
- 旧系统没有 `Get-NetFirewallRule`、`Get-NetTCPConnection` 也没关系：
  1.0.1 起防火墙改用 `netsh`、端口检查改用 `netstat`
- 查端口：`netstat -ano | findstr :65530`
- 查防火墙规则：`netsh advfirewall firewall show rule name="Audio Share Server TCP 65530"`
- 删除防火墙规则：`netsh advfirewall firewall delete rule name="Audio Share Server TCP 65530"`
