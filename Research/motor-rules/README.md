# MoveGrow 运动规则原型：从文字描述到可计算规则

这是 MoveGrow 的“无标注数据”核心：把文献和官方资料里对婴儿动作的文字描述，编译成带出处、带参数来源、能主动说“这次没法判断”的时间序列规则。输入就是 App 导出的 `PoseArchive`（`<id>.poses.raw.json`），输出是描述性、非诊断的发现。

只关注两类问题：

- **高频 / 节律性肢体运动**：细震颤（jitteriness 样）、粗震颤、正常的节律性踢腿挥手、一侧持续的规律抽动、成串的短暂同步动作。
- **超出常见范围的姿势**：头总偏一侧、头歪、ATNR（击剑样）姿势在较大月龄仍持续、蛙腿样姿势、剪刀样交叉腿、一侧手臂明显少动、6 个月后看不到双手合拢。

## 结构

```
文字描述 + 出处 (rules/sources.json)
   │  人工或 LLM 离线编译（tools/llm_compile_prompt.md），只能用特征目录里的特征
   ▼
rules/rules.json ── tools/validate_rules.py（静态检查） ── tests/（合成正例 / 反例）
   │
   ▼  运行时（确定性，无 LLM，无训练数据）
PoseArchive ─► 体坐标系（躯干长度归一、左右按解剖学）
           ├─► 原始关键点 ─► 频谱窗口（4–14 Hz / 0.4–6 Hz）─► 节律规则
           ├─► 轻度平滑 ───► 逐帧姿势特征 ──────────────────► 姿势规则
           └─► 轻度平滑 ───► 速度、活动段、同步爆发 ─────────► 不对称 / 成串动作规则
   ▼
发现（detected / not_detected / abstained / expected_for_age / not_applicable）
   + 年龄门控 + 场景门控 + 帧率门控 + 覆盖率门控 + 跨天纵向汇总
```

## 快速开始

```bash
pip install numpy scipy
python3 tests/test_scenarios.py          # 19 个场景 + 纵向测试 + 基线误报 + 混叠演示
python3 tools/validate_rules.py          # 规则库静态检查
python3 run_demo.py --list               # 列出合成场景
python3 run_demo.py --synthetic clonic_left_arm_2hz
python3 run_demo.py path/to/<id>.poses.raw.json --age-weeks 14 --context supine --out report.json
python3 tools/sweep.py                   # 多随机种子可观测性扫描 → out/sweep.json
python3 tools/make_fixtures.py           # 给 Swift 移植用的对齐测试数据
```

## 规则一览

| 规则 | 文字依据 | 关键阈值（来源） | 需要 | 级别 |
|---|---|---|---|---|
| `rhythm.fast_fine` | 细震颤：>6 Hz、<3 cm，常见于健康新生儿 | 6–12 Hz、≤3 cm（S01）；峰突出 ≥8 dB、节律性 ≥0.4、≥3 s 且频率稳定、刚体运动 R² ≤0.6（先验） | ≥24 fps，原始关键点 | note |
| `rhythm.coarse` | 粗震颤：频率更低、幅度更大 | <6 Hz 或 >3 cm（S01） | ≥24 fps | discuss |
| `rhythm.slow_bout` | 节律性踢腿挥手是正常发育的一部分（Thelen） | 0.75–4.5 Hz，≥4 s（约 3 次以上重复） | ≥24 fps | info |
| `rhythm.slow_unilateral_sustained` | 一侧肢体每秒 1–4 次规律抽动 | 1–4 Hz（S02）；对侧同频功率 ≤25%、≥10 s（先验） | ≥24 fps | safety |
| `burst.spasm_like_cluster` | 成串、每次 1–3 s、双侧同步、累及颈躯干 | ≤3 s（S05）、间隔 <60 s（S06）、双侧+轴向（S06/S07）；中位间隔 ≤20 s、替代数据检验 p ≤0.05（先验） | ≥15 fps，4–104 周 | safety（研究中） |
| `posture.head_preference` | 头总偏向一侧（斜颈 / 体位偏好） | 偏好指数 ≥0.6、转头时间 ≥40%、≥60 s（先验）；纵向 3 次 / 7 天 | 仰卧 | note → discuss |
| `posture.head_tilt` | 眼线与肩线夹角（照片测量法） | 中位数 ≥10°（先验） | 仰卧 | 研究中 |
| `posture.atnr_like_persistent` | ATNR 在 1–4 个月最明显，3–9 个月消失 | 脸侧肘 ≥140°、枕侧肘 ≤100°、≥3 s（先验）；≥26 周才提示，<26 周显示“这个月龄常见” | 仰卧 | note / discuss |
| `posture.frog_leg` | 仰卧蛙腿姿势是低张力的初步印象 | 大腿外展 ≥50°、屈膝、平贴、膝距 ≥2.2 倍髋宽、≥50% 时间、腿活动 ≤35%（先验） | 仰卧 | note → discuss |
| `posture.scissoring` | 抱起时腿变僵、交叉 | 踝交叉 + 膝伸直 + 内收（先验），仰卧只是近似场景 | 仰卧，≥8 周 | 研究中 |
| `asym.arm_use` | 单侧不对称，约 15 周后更明显；12 个月前明显手偏好需评估 | 不对称指数 ≥0.33、两侧置信度差 ≤0.1（先验）；≥15 周（S15） | 仰卧 | note → discuss |
| `milestone.hands_together_absent` | 6 个月以上难以双手合拢 | 120 s 内合拢 ≤0.5 s（先验）；≥26 周（S14） | 仰卧 | info → note |
| `abstain.finger_fisting` | 握拳 / 手指姿势 | COCO-17 没有手指关键点 → 永远弃权 | — | — |

“先验”= engineering_prior：我们定的起始值，必须用真实数据校准；“文献”参数在 `rules.json` 里都标了来源编号。

## 合成数据上的结果（只说明“看得见”，不代表临床准确性）

- 19 个场景 + 纵向测试全部通过，包括反例：摄像机 8 Hz 抖动不触发细震颤；双侧节律踢腿不触发“一侧抽动”；两次孤立惊跳、规律的双手合拢都不触发“成串动作”；15 fps 时高频规则全部弃权。
- 多种子：除细震颤外，各规则在两种关键点噪声下命中 7–8/8（ATNR 在低噪声下 6/8）。基线误报：每条规则在 30/60 fps × 两种噪声 × 24 个种子中都是 0。
- 细震颤可检出下限（躯干约占画面高度 20%，1280 px 竖屏，1 cm ≈ 13 px）：30 fps + 3 px 噪声约 1.0 cm 峰峰值；60 fps + 3 px 约 0.6 cm；60 fps + 6 px 约 1.0 cm；30 fps + 6 px 需要约 1.6 cm。更细小的抖动低于关键点噪声，需要别的信号（见下）。
- 混叠演示：11 Hz 的一侧抖动在 30 fps 下峰值是 11 Hz；隔帧抽成 15 fps（当前 App 的做法）后变成 4 Hz，落进“一侧规律抽动”的频段。这就是慢节律规则也要求 ≥24 fps 的原因。

## 现有 App 里的阻碍和改法

见 `swift/SWIFT_INTEGRATION.md`。要点：`VideoAnalyzer` 以 1/15 s 抽帧（奈奎斯特 7.5 Hz，且无抗混叠）；One-Euro（minCutoff 2.2 Hz）和 `MovementEngine` 的 0.12 s 低通会削掉 6–12 Hz；`PoseArchive` 没存宽高比和帧率；`Baby` 只有生日，没有矫正月龄；没有拍摄场景标签（躺着/抱着）。

## 局限

- 所有“先验”阈值都未经真实婴儿数据校准；合成数据由同一段文字生成，存在循环论证风险，只能当单元测试。
- 2D 俯拍下，抬腿、躯干拱背、头前屈都是离开画面平面的动作，只能用投影缩短间接估计。
- 关键点噪声限制了细震颤的可检出幅度；建议下一步在手腕 / 脚踝 ROI 上做光流频谱（Vision `VNGenerateOpticalFlowRequest`），用像素级运动补足关键点精度。
- 输出永远是描述 + 出处 + 下一步观察建议，不是诊断。
