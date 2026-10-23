# 配置说明

配置文件：`C:\Services\audio-share\settings.ini`
修改后执行 `Restart-Service AudioShareServer` 生效。

```ini
exe=as-cmd.exe
args=--bind=0.0.0.0 --discovery
workdir=.
logdir=logs
retaindays=7
```

## 配置项

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `exe` | `as-cmd.exe` | 要托管的本体程序，相对路径以安装目录为基准 |
| `args` | `--bind=0.0.0.0 --discovery` | 传给 `as-cmd.exe` 的参数，按空格分隔 |
| `workdir` | `.` | 工作目录 |
| `logdir` | `logs` | 日志目录 |
| `retaindays` | `7` | 日志保留天数（含当天） |

## 常用参数

`args` 里直接拼 `as-cmd` 的启动参数：

| 参数 | 作用 |
| --- | --- |
| `--bind=0.0.0.0` | 监听所有网卡（换 IP 也不用改） |
| `--bind=192.168.1.100:65530` | 只监听某块网卡 / 指定端口 |
| `--discovery` | 应答手机 App 的局域网搜索（UDP 65531） |
| `-e "{...}"` | 固定采集某个播放设备 |
| `--bitrate=96` | Opus 码率（kbps），网络差可调低 |
| `--compression=none` | 关闭 Opus，直接发 PCM（更吃带宽） |
| `--silence-timeout=2` | 静音多少秒后暂停发送，省手机电 |
| `-V` | trace 级日志（排错时临时用） |

完整列表：`C:\Services\audio-share\as-cmd.exe --help`

## 选择播放设备

服务启动时选一次“默认播放设备”，之后不会自动跟随系统默认设备变化。

```powershell
C:\Services\audio-share\as-cmd.exe -l
```

输出里带 `*` 的是当前默认设备。把它的 id 写进配置：

```ini
args=--bind=0.0.0.0 --discovery -e "{0.0.0.00000000}.{c0b9bb4b-6338-4a5a-867a-f113ce26efa9}"
```

id 里有空格和花括号，ini 里原样加引号即可（宿主把整串参数交给 Windows 解析）。

> 切换了系统默认设备（例如插上耳机、切到蓝牙）后，执行
> `Restart-Service AudioShareServer` 重新选择；想固定设备就用 `-e`。

## 端口与防火墙

| 端口 | 协议 | 用途 |
| --- | --- | --- |
| 65530 | TCP + UDP | 音频流（TCP 控制 + UDP 数据） |
| 65531 | UDP | 局域网发现 |

改端口只需改 `args` 里的 `--bind=...:端口`，安装脚本的防火墙规则会按 65530 生成；
改端口后需要手动补对应端口的入站规则：

```powershell
New-NetFirewallRule -DisplayName "Audio Share Server TCP 7000" -Direction Inbound `
  -Action Allow -Protocol TCP -LocalPort 7000 -Program "C:\Services\audio-share\as-cmd.exe"
```

## 服务操作

```powershell
Get-Service AudioShareServer
Start-Service AudioShareServer
Stop-Service AudioShareServer
Restart-Service AudioShareServer
```

## 日志

- 文件：`logs\as-cmd-YYYYMMDD.log`，UTF-8（带 BOM）
- 每天零点后第一次写日志时切新文件，并删除 7 天前的 `as-cmd-*.log`
- `as-cmd` 自己带时间戳，原样保留；宿主事件行带 `[service]`，stderr 行带 `[stderr]`
- 写日志是“打开→写→关闭”，运行中可以直接读取、清空或删除当天文件

实时查看：

```powershell
Get-Content "C:\Services\audio-share\logs\as-cmd-$(Get-Date -f yyyyMMdd).log" -Tail 50 -Wait
```

## 前台调试

不装服务也可以直接跑宿主（会占用 65530，先停服务）：

```powershell
Stop-Service AudioShareServer
cd C:\Services\audio-share
.\AudioShareService.exe --console
```

回车退出，然后再 `Start-Service AudioShareServer`。

## 目录

```
C:\Services\audio-share\
├─ as-cmd.exe
├─ AudioShareService.exe
├─ settings.ini
├─ LICENSE-as-cmd.txt
└─ logs\
```
