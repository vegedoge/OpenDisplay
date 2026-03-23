# OpenDisplay

[English](README.md)

轻量级 macOS 菜单栏多显示器管理工具。完全通过 Claude Code 的 agentic coding 方式实现。

## 功能

- **非 4K 屏幕启用 HiDPI** — 通过虚拟显示器 + 镜像，在 2K/1440p 外接显示器上实现 Retina 渲染。即时生效，无需注销。
- **分辨率和刷新率切换** — 完整模式列表（含 HiDPI 模式），使用 CGS 私有 API（兼容 macOS 26，公开 API 已不再返回 HiDPI 模式）。
- **关闭/开启显示器** — 无需拔线即可禁用外接显示器，退出 app 时自动恢复。
- **设置主显示器** — 一键将任意显示器设为主屏。
- **自动恢复** — 记住每个显示器的 HiDPI 状态和分辨率，重新连接或启动 app 时自动恢复。
- **开机自启动** — 基于 SMAppService。

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

## 工作原理

**HiDPI**：通过 CGVirtualDisplay 私有 API 创建高分辨率虚拟显示器，并将物理显示器镜像到虚拟显示器。macOS 以 2 倍分辨率渲染到虚拟显示器，再缩放输出到物理屏幕，从而在非 Retina 屏上获得 Retina 级文字清晰度。

**模式切换**：使用 `CGSGetNumberOfDisplayModes` / `CGSConfigureDisplayMode` 私有 API 枚举和切换显示模式。macOS 26 上 `CGDisplayCopyAllDisplayModes` 公开 API 已不再返回 HiDPI 模式，本项目通过逆向 CGS 结构体布局解决了这一问题。

**显示器控制**：使用 `CGDisplayCapture` / `CGDisplayRelease` 公开 API 实现显示器的启用和禁用。

## 隐私

- 无网络请求
- 无数据收集或遥测
- 不存储敏感数据（UserDefaults 中仅保存显示器厂商/产品 ID 和模式编号）
- 无需特殊权限

## 免责声明

本项目使用了 macOS 私有 API（CGVirtualDisplay、CGS 显示模式函数），这些接口未被 Apple 公开文档记录，可能在未来的 macOS 更新中失效。软件按原样提供，不附带任何保证，且尚未在所有硬件配置上进行完整测试。使用风险自负——显示器配置异常通常可以通过重启 Mac 恢复，但作者不对使用过程中可能出现的任何问题承担责任。

## 许可证

MIT
