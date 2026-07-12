菜单栏图标（Menu bar icon）
============================

与系统图标一致 / Match macOS menu bar style
--------------------------------------------
菜单栏里微信、Wi‑Fi 等是 **Template 图**：**黑色形状 + 透明底**，系统按浅色/深色栏自动染成黑或白。

本项目的 `MenuBarIcon` 已按此方式导出；不要用带彩色底块的 App 图标直接当菜单栏图。

菜单栏专用图一键导出 / Export menu bar asset
----------------------------------------------------
在项目根目录执行：
  python3 scripts/export_menu_bar_icon.py

默认读取：**dist/icon4-menu.png**，**抠深色外框**（RGB 均 <120，可调 `--dark-threshold`）为透明，保留中间浅色图形；与 Dock 用的「抠近白」相反。  
若仍要用白底主图：  
  `python3 scripts/export_menu_bar_icon.py --key white --src dist/icon3_1024x1024.png`  
输出：`Media.xcassets/MenuBarIcon.imageset/` 内 PNG，并在 `Resources/` 根目录写入 `MenuBarIcon_statusbar.png` / `MenuBarIcon_statusbar@2x.png`（供安装版菜单栏稳定加载）。

替换自己的图 / Use your own icon
--------------------------------
1. 自备 **Template PNG**：黑/灰单色图形 + 透明底，18×18 pt（@2x 为 36 px）常见。
2. 覆盖上述两个文件名，或改脚本里的源路径后重跑脚本。
3. 重新编译运行。

恢复系统麦克风图标 / Revert to SF Symbol mic
---------------------------------------------
在 FlowTypeApp.swift 里把 MenuBarExtra 改回：
  MenuBarExtra("FlowType", systemImage: "mic") { ... }

Dock / .app 应用图标 / App icon (Dock & packaging)
---------------------------------------------------
与菜单栏分开：Dock / icns 由 **export_app_icon.py** 只做 **多档缩放**，不抠图、不改内容：
  python3 scripts/export_app_icon.py

默认读取：**dist/icon3_1024x1024.png**（1024×1024 方图；可用 `--src` 指定）。  
输出：`AppDockIcon.png`、`dist/FlowTypeApp.iconset`、`dist/FlowTypeApp.icns`。  
若打包独立 `.app`，将 `FlowTypeApp.icns` 放入 `Contents/Resources` 并在 `Info.plist` 里配置 `CFBundleIconFile`（不含扩展名）。`Scripts/package-dmg.sh` 会在存在 `dist/FlowTypeApp.icns` 或 `dist/FlowTypeApp.iconset` 时自动处理。

语音模型缓存默认在 `~/Library/Application Support/FlowType/huggingface`（不再使用文稿目录，避免系统「访问文稿」提示）。
