# GSEAutoGen

**GSE 自动序列生成器** —— 魔兽世界（正式服 12.1.0 / Interface 120100）自研插件。

根据**专精 + 天赋（法术书）+ 急速 + 主动饰品**，自动生成 GSE 输出序列；并支持基于官方
`C_AssistedCombat` 推荐优先级的**后台学习**（`/ags learn` 采样 → 生成贴近官方的手感循环）。

| | |
|---|---|
| 作者 | mawen |
| 当前版本 | **1.9.47**（见 `src/GSEAutoGen.toc` 的 `## Version:`） |
| SavedVariables | `GSEAutoGenDB` |
| 依赖 | GSE（`## OptionalDeps: GSE`） |

---

## 目录结构

```
.
├── src/                     # ★ 插件本体（唯一要部署到游戏的目录，共 8 个文件）
│   ├── GSEAutoGen.toc       #   清单：版本号 / 接口版本 / SavedVariables
│   ├── Core.lua             #   初始化、DB 结构、斜杠命令、公共工具
│   ├── Data.lua             #   职业/专精数据、技能 ID、序列模板定义
│   ├── Engine.lua           #   优先级引擎：按天赋/急速/饰品装配技能序列
│   ├── Learner.lua          #   /ags learn 后台采样（官方 AssistedCombat 优先级）
│   ├── Writer.lua           #   把序列写成 GSE 宏块（体量最大，+204 行/近一轮）
│   ├── UI.lua               #   设置界面（专精/选项/滑块/块预览）
│   └── Bindings.xml         #   按键绑定
├── 工具/
│   └── simc_to_template.py  # SimulationCraft API 数据 → 序列模板
├── 参考数据/
│   ├── AGSSample/           # 配套采样插件（独立 addon）
│   ├── 官方AssistedCombat技能池.md
│   └── JustAC数据备份/       # （已 gitignore）第三方 JustAC 数据导出
├── 备份/                     # （已 gitignore）版本快照留档
├── CHANGELOG.md
└── README.md
```

> `备份/`、`参考数据/JustAC数据备份/` 已在 `.gitignore` 中排除，理由见文件内注释。

---

## 部署到游戏

插件**只在游戏启动时读取** `.lua`/`.toc`，`/reload` 不会重读文件 —— 必须先**完全退出魔兽**。

```bash
SRC="L:/工作流/小工具/魔兽插件/GSE自动序列/src"
DST="E:/Blizzard/World of Warcraft/_retail_/Interface/AddOns/GSEAutoGen"
cp -f "$SRC"/{Core.lua,Data.lua,Engine.lua,Learner.lua,UI.lua,Writer.lua,GSEAutoGen.toc,Bindings.xml} "$DST"/
```

⚠️ 备份目录**不要放进 `Interface/AddOns/`** —— 魔兽会把 AddOns 下任何子目录当插件加载。
统一放 `E:\Blizzard\_addon_backup\`。

---

## 游戏内命令

| 命令 | 作用 |
|---|---|
| `/ags` | 打开设置界面 |
| `/ags gen` | 按当前专精/天赋/急速/饰品生成序列（v1.9.34 起不再自动弹导入串） |
| `/ags str [aoe]` | 按需弹出 GSE3 导入串 |
| `/ags learn` | 后台开始采样官方推荐优先级 |
| `/ags gen` 后配合一键「生成并重载」（v1.9.40） | 一步生成并 `/reload` |

---

## 开发记录

见 [CHANGELOG.md](CHANGELOG.md)。
