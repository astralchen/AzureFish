# AzureFish 登录与个人中心 · 本地归档

日期：2026-09-26。方案：02。源文件：[Figma Design](https://www.figma.com/design/su1BAcMKAwW11bE2n2n9rN)。

打开 [index.html](index.html) 可离线浏览已保存图像。工程内另有打包文件 [AzureFish-Login-Profile-2026-09-26.zip](../AzureFish-Login-Profile-2026-09-26.zip)。

## 已保存

- `pages/`：8 个 Figma 页面总览与封面，共 9 张 PNG。大页面总览被导出服务限制为最长边 4096 px，适合检查总体结构。
- `screens/`：28 张实际导出的独立设计稿，分辨率见 `data/exports.json`；这些图像可直接离线查看。
- `data/design-index.json`：全部 712 个设计实例、97 个演示场景的节点索引，以及流程说明。索引不含完整节点树。
- `data/design-tokens.json`：53 个设计变量及 24 个文字样式的实际 Figma 快照。
- `data/copy-four-locales.json`：133 组简中、繁中、英文及阿拉伯语主要文案。
- `data/exports.json`：每张已导出图片的来源节点、像素尺寸、文件大小及 SHA-256。
- [设计交接与验收记录](../../figma-handoff.md)。

## 导出限制

**本归档尚不包含原生 `.fig` 文件。** 当前可用浏览器未登录 Figma，无法执行原生文件导出；批量导出时又触发 Figma MCP Education 套餐调用额度上限。实际完成 28 张单页稿，其余 684 张单页高清导出未完成。全部 8 页已有总览图片。

PNG 不包含可编辑文字、Auto Layout、组件实例或原型交互；JSON 用于索引、参数和文案留档，不能直接作为完整 Figma 工程导入。可编辑工程仍以云端源文件为准。登录 Figma 后仍需补充原生 `.fig`，才能形成完整的可编辑本地备份。

本目录按当前实际导出结果记录，不宣称已保存全部 712 张单页稿或完成原生文件备份。未改动客户端代码、网络接口或数据库。

## 检查

37 个 PNG 的文件签名、尺寸及读取检查通过。归档不包含临时下载 URL、会话凭据或 token。文件校验信息见 `SHA256SUMS`。
