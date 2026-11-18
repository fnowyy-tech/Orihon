# Orihon（折本）

为折叠双屏优化的原生 iOS 漫画阅读器：展开就是一本书，两块屏幕合成一个跨页，书脊落在铰链上。

Orihon 是开源漫画阅读器 **[Mihon](https://github.com/mihonapp/mihon)** 的**非官方** iOS / macOS 移植（原生 Swift + SwiftUI），与 Mihon 项目没有关联，也未获其认可。功能包括书架与分类、智能更新、阅读历史、多源浏览与跨源迁移、本地漫画（文件夹 / ZIP / CBZ / EPUB）、自建 Komga 服务器（含阅读进度同步）、下载、5 种阅读模式，以及 `.tachibk` 备份的导入与导出。

## 双屏优化

- **展开态布局**：左侧导航栏与列表，右侧实时详情，中间为铰链留出空隙。
- **跨页阅读**：自动把两页拼成一个跨页，支持从右到左 / 从左到右，封面可单独成页让后面的跨页对齐。
- **翻页**：默认平移翻页；也可以选仿真卷页（测试中），像翻纸书一样翻过书脊。
- **章节衔接**：读到章末时在后台预载下一话，翻过章节卡片直接就是下一话的第一个跨页，不黑屏、不转圈。

## 架构概览

1. **`Sources/MihonDomain` (核心领域层)**
   - [`DomainModels.swift`](./Sources/MihonDomain/Models/DomainModels.swift)：包含 `Manga`、`Chapter`、`MangaCategory`、`Track`、`HistoryEntry`、`ExtensionModel`、`DownloadItem`、`MihonBackupPayload` 等完整领域实体。
   - [`SourceAPI.swift`](./Sources/MihonDomain/SourceAPI/SourceAPI.swift)：1:1 对齐 Mihon `source-api` 的 `Source`、`CatalogueSource`、`HttpSource`、`ParsedHttpSource`、`SManga`、`SChapter`、`Page` 与 `SourceFilter`。
   - [`ChapterRecognitionAndFetchInterval.swift`](./Sources/MihonDomain/Utilities/ChapterRecognitionAndFetchInterval.swift)：1:1 移植 `ChapterRecognition.kt` 章节号识别算法与 `FetchInterval.kt` 智能更新周期计算器。

2. **`Sources/MihonData` (数据、网络与图像处理层)**
   - [`PerformanceAndNetworkEngine.swift`](./Sources/MihonData/PerformanceAndNetworkEngine.swift)：令牌桶限流 (`MihonRateLimitInterceptor`)、Cloudflare 检测、通过 `CGImageSource` 进行子采样解码、像素级白边/黑边裁切 (`crop_borders`)、超长条漫分片 (`splitTallWebtoonImage`)、双层内存/磁盘缓存 (`MihonTwoTierImageCache`) 与滑动窗口预加载器 (`MihonReaderPagePreloader`)。
   - [`MihonRepositoryStore.swift`](./Sources/MihonData/MihonRepositoryStore.swift)：统一管理书架、分类、章节筛选与排序、更新流、阅读历史、下载队列、多源迁移、Tracker 同步以及备份恢复。

3. **`Sources/MihonPresentation` (原生 SwiftUI Material 3 视图层)**
   - [`MihonRootView.swift`](./Sources/MihonPresentation/Root/MihonRootView.swift)：自适应折叠态底栏导航与 iPhone Duo 展开态双屏主从分栏 (`NavigationRail` + 铰链安全区 + 实时详情面板)。
   - [`LibraryScreen.swift`](./Sources/MihonPresentation/Library/LibraryScreen.swift)：分类标签栏、三种网格/列表布局、徽章系统、三合一底部抽屉（筛选/排序/显示）及批量操作栏。
   - [`UpdatesScreen.swift`](./Sources/MihonPresentation/Updates/UpdatesScreen.swift) & [`HistoryScreen.swift`](./Sources/MihonPresentation/History/HistoryScreen.swift)：按日期分组的更新流与阅读历史记录。
   - [`BrowseScreen.swift`](./Sources/MihonPresentation/Browse/BrowseScreen.swift)：图源浏览、扩展管理与跨源迁移。
   - [`MangaDetailScreen.swift`](./Sources/MihonPresentation/MangaDetail/MangaDetailScreen.swift)：高斯模糊背景顶栏、四宫格操作栏、可折叠简介、流式标签、章节列表与悬浮续读按钮。
   - [`MangaReaderScreen.swift`](./Sources/MihonPresentation/Reader/MangaReaderScreen.swift)：支持日式从右至左、从左至右、垂直翻页、条漫长图 (Webtoon)、连续垂直及 **iPhone Duo 双页书本跨页模式**。
   - [`MoreAndSettingsScreen.swift`](./Sources/MihonPresentation/More/MoreAndSettingsScreen.swift)：无痕模式、仅限已下载、下载队列、分类管理、阅读统计、备份与恢复、全局设置。

## 构建与测试

```bash
CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache swift build \
  --disable-sandbox \
  --package-path . \
  -Xswiftc -module-cache-path -Xswiftc /tmp/swift-module-cache
```

## 许可

本项目以 [Apache License 2.0](./LICENSE) 发布。它移植自 [Mihon](https://github.com/mihonapp/mihon)（The Mihon Open Source Project，Apache License 2.0）。
