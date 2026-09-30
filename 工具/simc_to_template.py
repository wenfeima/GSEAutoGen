#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SimC/官方数据 -> GSEAutoGen TEMPLATES 转换器  (v2)

数据源（全部来自 JustAC 的 Data/，由暴雪客户端 DB2 生成）：
  1. SimcRotations.lua        —— SimulationCraft 全职业优先级（40 专精），分 st/cleave/aoe/burst
  2. SpellCooldowns.lua       —— 技能冷却毫秒（用于过滤长 CD 大招）
  3. AssistedCombatOrder.lua  —— 暴雪官方 Assisted Combat 优先级编号（交叉验证）
  4. SpellArchetypes.lua      —— 技能原型（aoe/单体、builder/spender）

核心规则（v2 修正了 v1 的致命错误）
----------------------------------
v1 错误：机械取 SimC 列表前 N 个无条件技能当 core —— 结果抓到的是
         "起手铺垫/位移/控制"（天神下凡、破坏者、挫志怒吼、勇士之跃），
         而真正的输出核心（盾牌猛击）排在后面被漏掉。

v2 正确规则：
  a) 用 **冷却时间** 过滤：CD > 30 秒的技能 = 大招/长CD，**不进自动循环**
  b) 在剩下的"短 CD / 无 CD"技能里，**保留 SimC 的原始顺序**作为优先级
  c) 无条件（gates 为空）的排前面 → core
  d) 有条件的降级 → optional（静态宏无法做条件判断，靠 rep 近似频率）
  e) SimC 的 aoe 列表独有技能 → 进 AOE 分支
  f) burst 列表 → 永远不进自动循环

用法
----
    python simc_to_template.py --data-dir <JustAC/Data> [--out 输出.lua]
                               [--specs WARRIOR_3,WARLOCK_2] [--dump]
"""

import argparse
import re
import sys
from pathlib import Path

# ---------------------- 可调参数 ----------------------

# 冷却超过这个值（毫秒）视为"大招/长CD"，不进自动循环
LONG_CD_MS = 30000

# core 最多放几个技能（太长会让 GSE 循环变慢）
CORE_MAX = 4

# AOE 额外技能最多几个
AOE_ADD_MAX = 3


# ---------------------- 通用解析 ----------------------


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace")


SPEC_BLOCK_RE = re.compile(r'\["([A-Z]+)_(\d)"\]\s*=\s*\{')
SECTION_RE = re.compile(r'\b(st|cleave|aoe|burst)\s*=\s*\{')
ENTRY_RE = re.compile(
    r"\{id\s*=\s*(\d+)\s*,\s*gates\s*=\s*(\{.*?\})\s*(?:,\s*delegated\s*=\s*true\s*)?\}",
    re.S,
)


def split_spec_blocks(text: str):
    """{specKey: block_text}"""
    blocks, matches = {}, list(SPEC_BLOCK_RE.finditer(text))
    for i, m in enumerate(matches):
        key = f"{m.group(1)}_{m.group(2)}"
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        blocks[key] = text[m.end(): end]
    return blocks


def split_sections(block_text: str):
    out, matches = {}, list(SECTION_RE.finditer(block_text))
    for i, m in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(block_text)
        out[m.group(1)] = block_text[m.end(): end]
    return out


def parse_entries(section_text: str):
    """保序解析条目 -> [{'id':int, 'gates':str, 'delegated':bool}]"""
    out = []
    for m in ENTRY_RE.finditer(section_text):
        out.append({
            "id": int(m.group(1)),
            "gates": m.group(2).strip(),
            "delegated": "delegated" in m.group(0),
        })
    if not out:  # burst 是纯数字列表
        for m in re.finditer(r"\b(\d{4,7})\b", section_text):
            out.append({"id": int(m.group(1)), "gates": "{}", "delegated": False})
    return out


def has_conditions(gates: str) -> bool:
    inner = gates.strip()
    if inner in ("{}", "{ }", ""):
        return False
    inner = inner[1:-1].strip() if inner.startswith("{") else inner
    return len(inner) > 0


# ---------------------- 冷却表 ----------------------


def parse_cooldowns(text: str) -> dict:
    """[spellID] = cooldownMs（含 {maxCharges, rechargeMs} 形式取 recharge）"""
    cds = {}
    for m in re.finditer(r"\[(\d{4,7})\]\s*=\s*(\d+)\s*,", text):
        cds[int(m.group(1))] = int(m.group(2))
    for m in re.finditer(r"\[(\d{4,7})\]\s*=\s*\{\s*(\d+)\s*,\s*(\d+)\s*\}", text):
        cds[int(m.group(1))] = int(m.group(3))
    return cds


# ---------------------- 官方 AC 顺序 ----------------------


def parse_ac_order(text: str) -> dict:
    """{specKey: {spellID: rank}}"""
    out = {}
    for block in re.finditer(r'\["([A-Z]+_\d)"\]\s*=\s*\{(.*?)\n\s*\},', text, re.S):
        key, body = block.group(1), block.group(2)
        ranks = {}
        for m in re.finditer(r"\[(\d{4,7})\]\s*=\s*(\d+)", body):
            ranks[int(m.group(1))] = int(m.group(2))
        out[key] = ranks
    return out


# ---------------------- 原型（AOE 判定） ----------------------


def parse_archetypes(text: str) -> dict:
    """{spellID: set(原型)}  至少能拿到 'aoe'"""
    out = {}
    # 按 section 名分组：  aoe = { [id]="melee", ... }
    for sec in re.finditer(r"(\w+)\s*=\s*\{\s*--[^\n]*\n(.*?)\n\s*\},", text, re.S):
        name, body = sec.group(1), sec.group(2)
        for m in re.finditer(r"\[(\d{4,7})\]", body):
            out.setdefault(int(m.group(1)), set()).add(name)
    return out


# ---------------------- 组装模板 ----------------------


def build_spec(spec_key, sections, cds, ac_ranks, archetypes, spell_names):
    st = parse_entries(sections.get("st", ""))
    aoe = parse_entries(sections.get("aoe", ""))
    burst = {e["id"] for e in parse_entries(sections.get("burst", ""))}
    aoe_ids = {i for i, proto in archetypes.items() if "aoe" in proto}

    def cd_of(sid):
        return cds.get(sid)          # None = 无CD或未知

    def is_long_cd(sid):
        c = cd_of(sid)
        return c is not None and c > LONG_CD_MS

    # ---- 单体：剔除爆发 + 长CD ----
    usable = []
    for e in st:
        sid = e["id"]
        if sid in burst:
            continue
        if is_long_cd(sid):
            continue
        usable.append(e)

    # 无条件的排前（能安全进循环），有条件的降级
    unconditional = [e for e in usable if not e["delegated"] and not has_conditions(e["gates"])]
    conditional = [e for e in usable if e["delegated"] or has_conditions(e["gates"])]

    # core：无条件的、SimC 顺序靠前的；但要排除"纯 AOE 技能"（否则单体空放）
    core = []
    for e in unconditional:
        if e["id"] in aoe_ids and e["id"] not in {x["id"] for x in st[:len(core) + 3]}:
            # 是 AOE 技能且不是高优先级 → 留到 AOE 分支
            continue
        core.append(e["id"])
        if len(core) >= CORE_MAX:
            break

    core_set = set(core)
    optional = [e["id"] for e in unconditional if e["id"] not in core_set]
    optional += [e["id"] for e in conditional]

    # ---- AOE 分支：SimC aoe 列表里、单体没有的 ----
    st_ids = {e["id"] for e in st}
    aoe_add = []
    for e in aoe:
        sid = e["id"]
        if sid in burst or sid in st_ids or is_long_cd(sid):
            continue
        aoe_add.append(sid)
        if len(aoe_add) >= AOE_ADD_MAX:
            break

    # ---- 交叉验证：官方 AC 顺序 ----
    ac = ac_ranks or {}
    mismatch = []
    if ac:
        for sid in core:
            if sid not in ac:
                mismatch.append(sid)

    return {
        "core": core,
        "optional": optional,
        "aoe_add": aoe_add,
        "burst": sorted(burst),
        "skipped_long_cd": sorted({e["id"] for e in st if is_long_cd(e["id"])}),
        "ac_missing": mismatch,
    }


# ---------------------- 主流程 ----------------------


def main():
    ap = argparse.ArgumentParser(description="SimC/官方数据 -> GSEAutoGen 模板转换器 v2")
    ap.add_argument("--data-dir", required=True, help="JustAC 的 Data 目录")
    ap.add_argument("--out", default=None, help="输出 .lua（默认 stdout）")
    ap.add_argument("--specs", default=None, help="只处理指定专精，逗号分隔")
    ap.add_argument("--dump", action="store_true", help="只打印解析结果")
    args = ap.parse_args()

    dd = Path(args.data_dir)
    need = ["SimcRotations.lua", "SpellCooldowns.lua"]
    for f in need:
        if not (dd / f).exists():
            print(f"缺少数据文件：{dd / f}", file=sys.stderr)
            return 1

    simc = read(dd / "SimcRotations.lua")
    cds = parse_cooldowns(read(dd / "SpellCooldowns.lua"))
    ac = parse_ac_order(read(dd / "AssistedCombatOrder.lua")) if (dd / "AssistedCombatOrder.lua").exists() else {}
    archetypes = parse_archetypes(read(dd / "SpellArchetypes.lua")) if (dd / "SpellArchetypes.lua").exists() else {}

    print(f"# CD 表 {len(cds)} 条 | AC 顺序 {len(ac)} 专精 | 原型 {len(archetypes)} 技能", file=sys.stderr)

    blocks = split_spec_blocks(simc)
    want = {s.strip().upper() for s in args.specs.split(",")} if args.specs else None

    results = {}
    for key, block in blocks.items():
        if want and key not in want:
            continue
        results[key] = build_spec(key, split_sections(block), cds, ac.get(key), archetypes, {})

    if args.dump:
        for key in sorted(results):
            r = results[key]
            print(f"\n=== {key} ===")
            print(f"  core            : {r['core']}")
            print(f"  optional        : {r['optional']}")
            print(f"  aoe_add         : {r['aoe_add']}")
            print(f"  burst(不进循环)  : {r['burst']}")
            print(f"  长CD剔除        : {r['skipped_long_cd']}")
            if r["ac_missing"]:
                print(f"  ⚠️ 不在官方AC表 : {r['ac_missing']}")
        return 0

    lines = ["-- 由 simc_to_template.py v2 自动生成",
             "-- 数据源：JustAC Data/ (SimcRotations + SpellCooldowns + AssistedCombatOrder + SpellArchetypes)",
             "-- ⚠️ 原始转换结果，需人工核对 spellID 与中文名后再并入 Data.lua",
             "return {"]
    for key in sorted(results):
        r = results[key]
        lines.append(f'  ["{key}"] = {{')
        lines.append(f"    core     = {{ {', '.join(map(str, r['core']))} }},")
        lines.append(f"    optional = {{ {', '.join(map(str, r['optional']))} }},")
        lines.append(f"    aoeAdd   = {{ {', '.join(map(str, r['aoe_add']))} }},")
        if r["burst"]:
            lines.append(f"    burst    = {{ {', '.join(map(str, r['burst']))} }},")
        lines.append("  },")
    lines.append("}")
    output = "\n".join(lines)

    if args.out:
        Path(args.out).write_text(output, encoding="utf-8")
        print(f"# 已写入 {args.out}", file=sys.stderr)
    else:
        print(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
