# Windows Lightroom Classic 导出 HDR Gain Map HEIC

## 安装和导出

1. 解压 `HDR-Gain-Map-HEIC-windows-x64.zip`。在 Lightroom Classic 中打开「文件 → 增效工具管理器 → 添加」，选择解压后的 `HDR Gain Map HEIC.lrplugin` 文件夹。
2. 在「修改照片」中为要输出的照片开启 HDR 编辑。选中照片，在导出窗口顶部的「导出到」选择 **HDR Gain Map HEIC**。
3. 选择目录、文件命名方式和编码质量，点击导出。质量默认 85。插件输出 `.heic`，已有的同名 HEIC 会保留并显示冲突。缺少 HDR 增益图的照片会显示失败，批次继续处理其余照片。

插件随附 Windows x64 编码器。Lightroom 在后台渲染 16 位 HDR Display P3 TIFF。编码器使用 Lightroom 的 SDR 底图，从 TIFF 的增益图恢复 HDR，生成 ISO 21496-1 增益图 HEIC。导出后会清理中间 TIFF。取消时，当前渲染或编码可能需要完成，之后会清理临时文件。

0.1.2 修正了 Windows 解码发绿和奇数尺寸兼容性。用旧版生成的 HEIC 需要从 Lightroom 照片或原始 HDR TIFF 重新导出。

0.1.3 保留 Lightroom 导出窗口中选定的元数据设置。要保留 GPS，请在「元数据」中选择「所有元数据」，并取消勾选「删除位置信息」。

## 从源码构建

在具备 Rust 1.94.1 或更新版本及 MSVC C++ 构建工具的 Windows x64 上，从仓库根目录运行下面的命令。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/package-lrplugin-windows.ps1
```

压缩包写入 `out/HDR-Gain-Map-HEIC-windows-x64.zip`。移植以 [Congee/tohdr](https://github.com/Congee/tohdr/commit/e77c454a1a8af9cee02c07019b732f65bd3ad4d8) 为基础，使用锁定的 `hpvca` HEVC 编码后端。
