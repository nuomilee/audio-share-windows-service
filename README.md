# Audio Share Windows Service

把 [audio-share-plus](https://github.com/outusuke/audio-share-plus) 的命令行服务端 `as-cmd.exe`
封装成标准的 Windows 服务：**开机自启、无窗口、按天写日志、只保留最近 7 天、崩溃自动重启**。

## 特性

- 开机自动启动，不需要登录桌面
- 后台静默运行，没有窗口和托盘
- 日志按天切分：`logs\as-cmd-YYYYMMDD.log`（UTF-8）
- 自动清理 7 天前的日志
- 进程异常退出自动拉起，服务本身也有失败重启策略
- 安装脚本自动配置防火墙、服务依赖和启动类型
- 一个压缩包，双击 `install.cmd` 即可完成安装

## 快速开始

### 使用发布包

1. 从 [Releases](https://github.com/nuomilee/audio-share-windows-service/releases/latest)
   下载 `audio-share-service-1.0.0-win64.zip` 并解压
2. 右键 `install.cmd` → **以管理员身份运行**
3. 手机 App 连接 `电脑IP:65530`

### 从源码打包

```powershell
powershell -ExecutionPolicy Bypass -File scripts\package.ps1
```

发布包生成在 `dist\`，只需要 Windows 自带的 .NET Framework，无需安装 SDK。

## 安装之后

```powershell
Get-Service AudioShareServer
Get-Content "C:\Services\audio-share\logs\as-cmd-$(Get-Date -f yyyyMMdd).log" -Tail 30
```

| 项目 | 位置 |
| --- | --- |
| 服务名 | `AudioShareServer` |
| 程序目录 | `C:\Services\audio-share` |
| 配置文件 | `C:\Services\audio-share\settings.ini` |
| 日志目录 | `C:\Services\audio-share\logs` |

## 文档

| 文档 | 内容 |
| --- | --- |
| [部署指南](docs/deployment.md) | 在另一台电脑上替换原来的 cmd 启动方式 |
| [配置说明](docs/configuration.md) | 监听地址、音频设备、码率、日志保留 |
| [常见问题](docs/troubleshooting.md) | 端口、防火墙、无声、日志等 |

## 目录

```
audio-share-windows-service/
├─ src/          # 服务宿主源码
├─ config/       # 默认配置
├─ scripts/      # 构建、打包、安装、卸载
├─ vendor/       # as-cmd.exe 与许可证
├─ docs/         # 文档
└─ dist/         # 发布包（生成）
```

## 致谢与许可

- 本项目（宿主与脚本）：[MIT](LICENSE)
- `as-cmd.exe` 来自 [audio-share-plus](https://github.com/outusuke/audio-share-plus)，
  遵循 Apache-2.0（见 [vendor/LICENSE](vendor/LICENSE)）
