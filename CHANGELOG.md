# 更新日志

## 1.0.1 — 2026-10-23

兼容性修复：

- 防火墙规则改用 `netsh`，不再依赖 `NetSecurity` 模块（Windows 7 等旧系统也可安装）
- 端口占用检查改用 `netstat`，不再依赖 `Get-NetTCPConnection`
- 脚本兼容 Windows 7 SP1 + PowerShell 3.0，并检查 .NET Framework 4.5+
- 服务描述改用 `sc.exe` 设置，去掉 `New-Service -Description` 的版本限制

## 1.0.0 — 2026-10-23

首个可用版本：

- 服务宿主 `AudioShareService.exe`：启动/停止 `as-cmd.exe`、捕获输出、崩溃退避重启
- 日志按天切分、UTF-8、保留 7 天、写入时不长期占用文件
- 安装/卸载脚本：自动提权、防火墙规则、服务依赖 `Audiosrv`、失败重启策略
- 发布包：`dist\audio-share-service-1.0.0-win64.zip`
- 文档：部署、配置、排错
