# Sidebar AX 问题只读核对

证据：`native-ax-diagnostic.log`、`ax-diagnostic-attachments/manifest.json` 和其中的逐问题截图。本次没有更改 App、测试或模拟器状态。

## 逐问题对应

| 未解决问题索引 | 自动报告 | 截图 |
|---|---|---|
| 0 | Contrast failed，element=nil | F662405A-8EC1-41BD-B017-A937CD09FF13.png |
| 1 | Contrast failed，element=nil | B59BB0FB-310A-45F1-8B07-C535A2C843C7.png |
| 2 | Contrast failed，草稿标题 | D4EF6416-3B2C-4EB2-89D8-BFE63A64DB35.png |
| 3 | Contrast failed，element=nil | 2182DCEF-F2DD-47FC-8910-ABB61225B73D.png |
| 4 | Text may be clipped at larger Dynamic Type，element=nil | 1CF90E9E-05B6-4F79-ADBE-B8221DC718B6.png |
| 5 | Text may be clipped at larger Dynamic Type，element=nil | 59D003FE-D074-4C11-8A5C-731DE3A2019E.png |

在第一个未解决问题之前，还有 8 个索引同为 0 的截图，对应日志里已识别为被侧栏遮挡的 AI 工作台文字/操作。不能仅按附件名称把这 8 个截图算作新增失败。

## 截图能够证明的内容

14 个逐问题截图的解码像素完全相同（SHA-256 前缀 `99b625ff0585`），没有逐问题定位框，也没有显示放大后的字体。因此不能从它们定位三个 element=nil 对比度问题或两个裁切预测。

1206×2622 sRGB 图对应 402×874pt、3×分辨率。草稿标题的实际字形边界为 x25.00…56.33pt、y357.67…373.00pt；所报 AX 行为 x8、y340、宽353.7、高50.3pt。字形完整位于该区域中，远离滚动视口上下边缘。

核心字形 RGB(25,26,30)、邻近背景众数与中位数 RGB(244,244,244)，按 sRGB 相对亮度计算代表性对比度为 **15.81:1**。最近对话标题同样约15.81:1；搜索占位文字 RGB(106,106,106) 对 RGB(236,236,236) 约4.58:1。截图中的标题没有显示低对比或裁切。数值是对已渲染截图的局部像素测量，不能替代所有显示模式/背景的检查。

最末可见历史条目的标题与日期也完整；下一批列表内容位于滚动视口之外，不等同于可见文字被裁切。但未知裁切问题没有元素或坐标，不能确认它们就是视口边缘。

## 尚不能证明的内容

裁切详细描述是“更大 Dynamic Type 下可能被裁切”的预测。当前普通字号截图不能据此判定其正确或错误，需要真实最大辅助字号、自然滚动和控件可达性矩阵。

日志直接证明自动审计仍枚举了被玻璃侧栏遮挡的工作台文字。源代码已对工作区设置 accessibilityHidden，二者的差异需要继续区分系统审计的图像/元素归属与真实 VoiceOver 焦点行为。不能把无法归属的 element=nil 报告直接归入这批已确认遮挡元素，也不能因此豁免整个对比度或裁切类别。

当前证据支持“草稿标题在本次实际截图中高对比且完整”；不支持“所有 Sidebar AX 失败均为误报”。建议保留原始失败，并结合独立侧栏呈现/真实辅助字号矩阵进一步定位，暂不增加推测性豁免或仅为通过审计改颜色。

机器可读像素测量及映射：`sidebar-issue-time-analysis.json`。
