# Yetipsy App 图标更换说明

以后要更换手机桌面上的 App 图标，请按下面步骤操作。

## 先准备图片

- 使用正方形 PNG，建议导出 192×192 和 512×512 两个尺寸。
- 图案和文字尽量放在中间，边缘留空，避免手机圆角裁切时被切掉。
- 文件名和路径要保持不变；这样不必修改 manifest 配置。

## 更换会员端图标

会员端使用以下文件：

- `play/icon-192.png`
- `play/icon-512.png`

在 GitHub 打开仓库 `yetipsy98-cpu/yetipsy-tonight`，进入 `play` 文件夹，点 **Add file → Upload files**，上传同名的新图片并提交。

客户端的 `play/manifest.webmanifest` 已经指向这两个文件，保持文件名即可。

## 更换管理端图标

管理端使用以下文件：

- `play/admin-icon-192.png`
- `play/admin-icon-512.png`
- `play/admin-icon.svg`（浏览器标签页图标）

按相同方式上传同名文件并提交。若只更换 PNG，安装清单路径无需修改。若也要更换浏览器标签页图标，再替换 `play/admin-icon.svg`。

管理端 PWA 配置位于 `play/admin.webmanifest`；iPhone 主屏幕图标路径还写在以下入口页中：

- `play/owner/index.html`
- `play/staff/index.html`
- `play/cashier/index.html`
- `play/pos/index.html`

如需改文件名或目录，要同步修改 manifest 的 `icons` 路径和这些入口页的 `apple-touch-icon` 路径。

## 让手机显示新图标

提交后等待 GitHub Pages 更新，再从浏览器打开对应页面并重新添加到主屏幕。已安装的旧图标可能会继续缓存；如果没有变化，先移除旧快捷方式，再重新添加。

- 会员端入口：网站的 `/play-v12/` 客户端页面
- 管理端入口：`/play-v12/owner/`、`/play-v12/staff/` 或 `/play-v12/cashier/`

## GitHub 上传步骤

1. 打开仓库 `yetipsy98-cpu/yetipsy-tonight`。
2. 进入 `play` 文件夹。
3. 选择 **Add file → Upload files**。
4. 拖入同名图标文件，确认目标目录是 `play/`。
5. 在页面底部填写提交说明，例如 `Update member app icons`，然后提交到 `main`。
