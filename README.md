# ROMCover

macOS 原生 ROM 封面刮削器。扫描 ROM 文件夹或掌机存储卡，从 Libretro 和 SteamGridDB 查找封面，按目标固件的目录规则写入 PNG 图片。

## 下载

从 [Releases](https://github.com/Drafffffff/ROMCover/releases/latest) 下载最新的 `ROMCover-<版本>-macOS-universal.zip`，解压后将 `ROMCover.app` 放进“应用程序”文件夹。支持 macOS 14 及以上的 Apple Silicon 与 Intel Mac。

当前发布版使用临时签名，尚未经过 Apple 公证。首次打开如被 macOS 拦截，先尝试打开一次，然后前往“系统设置”→“隐私与安全性”选择“仍要打开”。参见 [Apple 的操作说明](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac)。

## 使用

1. 下载发布版，或在 macOS 14 及以上运行 `zsh Scripts/build-app.sh` 从源码构建，再打开 `dist/ROMCover.app`。也可用 Xcode 打开 `Package.swift` 运行 `ROMCover` target。
2. 选择 ROM 文件夹或存储卡。扫描后自动开始搜索；可随时取消。未识别的平台可逐项或批量指定。
3. 在“API 设置”中输入自己的 SteamGridDB API Key，保存到 macOS 钥匙串。没有 Key 时仍可使用 Libretro。中文改名等无法匹配的 ROM，可输入自己的 DeepSeek API Key 并开启“未匹配时用 DeepSeek Flash 解析名称”，或在游戏详情中单次点击“用 DeepSeek 解析”。
4. 选择目标固件预设，核对候选封面与右侧预计路径，点击“写入封面”。默认只补缺失文件；逐项勾选“替换已有封面”才覆盖。

“选择文件夹”位于左侧“当前来源”。点击候选封面可打开大图预览；可在预览中或候选旁的选择按钮确认版本。

启动时不读取钥匙串，因此打开应用不会触发密码提示。需要使用已保存的 Key 时，在“API 设置”里点击对应的“读取已存 Key”；系统弹窗可选“始终允许”，让同一版本后续读取不再询问。当前本机构建使用临时签名，更新应用后 macOS 可能再次要求授权；正式分发应使用稳定的开发者签名。

游戏列表顶部可按全部、待确认、未命中、待写入、已有封面、已写入、失败和待处理筛选。待确认项目无需逐个点选：批量写入会默认使用第一张候选；手动选中其他候选后，以手动选择为准。在“待确认”筛选中手动选图后，当前项目会暂时留在原位并显示“待写入 · 当前”；切换项目或筛选后按新状态显示。筛选只改变列表显示，批量写入仍处理所有可写入项目。

界面采用系统原生的 `NavigationSplitView` 全高侧边栏与工具栏。使用 macOS 26 SDK 构建并在 macOS 26 或更新版本运行时，系统会为侧边栏、工具栏和标准控件提供 Liquid Glass；macOS 14–15 继续使用对应的系统原生外观。封面列表、候选卡片与图片预览保留内容层的清晰背景，避免在内容上叠加玻璃效果。

应用图标源文件位于 `Assets/AppIcon.png`，采用奶油白复古卡带、黑色印刷标签与珊瑚红像素放射图案。青色卡带备选稿保存在 `Assets/IconConcepts/CyanCartridge.png`。`Scripts/build-app.sh` 会将当前图标生成为 macOS 图标资源并打包进应用。

## AI 名称解析

常规封面搜索无结果时，可选用 DeepSeek Flash 从 ROM 文件名、游戏平台和可读取的内部标题推测英文游戏名，再用该名称查找 Libretro 和 SteamGridDB。AI 找到的候选会标为“待确认”，仍可按第一张候选直接批量写入；建议先核对游戏与版本。手动解析按钮也可用于已有候选但名称不准确的游戏。请求不会上传完整路径或 ROM 内容；DeepSeek Key 保存在 macOS 钥匙串。此功能默认关闭，调用 DeepSeek API 可能产生费用。

对于中文汉化的 NDS ROM，应用优先读取文件头的四位游戏代码，用 [Libretro 的 No-Intro NDS 目录](https://github.com/libretro/libretro-database/blob/master/metadat/no-intro/Nintendo%20-%20Nintendo%20DS.dat) 找标准标题，再匹配 Libretro 封面。该目录由 Libretro 提供，遵循其 [CC BY-SA 4.0 许可](https://github.com/libretro/libretro-database/blob/master/LICENSE)；应用运行时获取目录，不随应用分发副本。代码匹配的候选仍需人工核对地区与版本。目录不可用时继续使用文件名、内部标题和可选的 DeepSeek 解析。

游戏代码只对应一张标准标题与地区相符的封面时，应用会预选；有多个地区、修订版或其他歧义时保持“待确认”，并优先排列对应地区的正式发行封面。

## 固件预设

- 安伯尼克原厂 Linux（已按 RG DS Plus 原厂卡核对）：`ROMS/<系统>/Imgs/<ROM 文件名>.png`。现有 JPG/PNG 均识别并跳过；手动替换时沿用原文件格式。只有原本存在 `gamelist.xml` 时才合并，不会在 RG DS Plus 卡上新建它。
- NextUI：按[官方封面规则](https://nextui.loveretro.games/customizing/game-artwork/)写入 ROM 所在目录的 `.media/<ROM 文件名去扩展名>.png`；ZIP 与多光盘列表也使用主文件名。支持 `(GB)`、`(GBA)`、`(MGBA)` 等目录标签和同平台多个物理文件夹；不创建 `gamelist.xml`。发现卡根目录的 NextUI `.pakz` 文件时自动选择此预设。
- GarlicOS / OnionOS：`Roms/<系统>/Imgs/<ROM 文件名>.png`。
- muOS：读取 `MUOS/info/assign/<系统>/global.ini` 的 `catalogue` 值，输出到 `MUOS/info/catalogue/<catalogue>/box/`。
- KNULLI / Batocera / ArkOS：输出到系统目录的 `images/` 并合并 `gamelist.xml`。
- RetroArch：输出到 `thumbnails/<播放列表名>/Named_Boxarts/`。

导出时会保留现有 `gamelist.xml` 字段；首次修改前生成 `.romcover-backup`。手动替换封面时也会保留一次图片备份。源 ROM 文件不会被改动。

## 开发验证

运行 swift run ROMCoverNameValidation 可用模拟响应检查 DeepSeek 请求格式、名称解析及无效密钥处理。

运行 swift run ROMCoverLiveValidation --nds-sample /path/to/NDS_ROM 可统计整个 NDS 测试目录的在线匹配和可预选数量；只读取 ROM，不写入测试目录。

`swift run ROMCoverValidation` 运行离线验证，覆盖多光盘合并、平台识别、导出路径、重复运行及 `gamelist.xml` 合并。`swift run ROMCoverValidation --rgds-card /Volumes/<卡名>` 会只读核对真实 RG DS Plus 目录。`swift run ROMCoverLiveValidation` 检查 Libretro 在线目录匹配；中文改名的 GB/GBA/NDS ROM 还会尝试使用文件头内的英文标题提出候选，无法匹配时可在右侧手动修改搜索标题。当前机器仅安装 Xcode Command Line Tools，可完成 Swift 构建及本机应用打包；Xcode 工程运行与正式签名分发仍需完整 Xcode。

源码以 [MIT License](LICENSE) 发布。仓库与发布包不包含 ROM、游戏封面库、API Key 或 RG DS Plus 存储卡内容。
