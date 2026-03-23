# OpenDisplay

[English](README.md)

轻量级 macOS 菜单栏多显示器管理工具。完全通过 Claude Code 的 agentic coding 方式实现。

## 功能

- **非 4K 屏幕启用 HiDPI** — 在 2K/1440p 外接显示器上实现 Retina 渲染。即时生效，无需注销。
- **分辨率和刷新率切换** — 完整模式列表，含 HiDPI 模式。
- **关闭/开启显示器** — 无需拔线即可禁用外接显示器，退出 app 时自动恢复。
- **设置主显示器** — 一键将任意显示器设为主屏。
- **自动恢复** — 记住每个显示器的 HiDPI 状态和分辨率，重新连接或启动 app 时自动恢复。
- **开机自启动** — 原生 macOS 登录项支持。

## 系统要求

- macOS 13+（Ventura 及以上）
- Apple Silicon Mac

## 构建

```bash
make          # 编译
make install  # 安装到 /Applications
make run      # 编译并运行
make clean    # 清理
```


## 隐私

- 无网络请求
- 无数据收集或遥测
- 不存储敏感数据（UserDefaults 中仅保存显示器厂商/产品 ID 和模式编号）
- 无需特殊权限

## 免责声明

这是一个面向高级用户的实验性开源工具。本软件按原样提供，不附带任何保证，且尚未在所有硬件配置上进行完整测试。使用风险自负，作者不对使用过程中可能出现的任何问题承担责任。

## 许可证

MIT
