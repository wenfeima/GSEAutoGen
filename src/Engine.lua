-- ==========================================================
-- GSEAutoGen - Engine.lua  (v1.2)
--
-- 扫描角色 -> 套 SCG 模板 -> 产出 GSE 块列表
-- 块的类型只有两种（与 SCG 一致）：
--   { kind = "spell", id = 12345, rep = 3 }  -> GSE Repeat/Action 的 spell 块
--   { kind = "item",  slot = "13" }          -> GSE item 块（饰品）
--
-- 所有暴雪 API 都走 pcall + 存在性判断，改名/移除只会降级，不会报错中断。
-- ==========================================================

local ADDON_NAME, ns = ...

-- 战斗等级常量（不同版本索引可能变，读不到就用兜底值）
local CR = {
    haste   = _G.CR_HASTE_SPELL or 20,
    crit    = _G.CR_CRIT_SPELL or 11,
    mastery = _G.CR_MASTERY or 24,
    vers    = _G.CR_VERSATILITY_DAMAGE_DONE or 29,
}

-- ---------------------- 小工具 ----------------------

local function PCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    return nil
end

-- ---------------------- 技能查询 ----------------------

--- 技能名：优先新 API，回退老 API，最后用 #id
function ns:SpellName(id)
    if not id then return "?" end
    if C_Spell and type(C_Spell.GetSpellName) == "function" then
        local n = PCall(C_Spell.GetSpellName, id)
        if type(n) == "string" and n ~= "" then return n end
    end
    if type(GetSpellInfo) == "function" then
        local n = PCall(GetSpellInfo, id)
        if type(n) == "string" and n ~= "" then return n end
    end
    return "#" .. tostring(id)
end

--- 会不会这个技能（含天赋给的）
-- 两个 API 都拿不到结果时返回 true（宁可保留，也不要把整条序列清空）
function ns:KnowsSpell(id)
    if not id then return false end
    if type(IsPlayerSpell) == "function" then
        local v = PCall(IsPlayerSpell, id)
        if v ~= nil then return v and true or false end
    end
    if type(IsSpellKnown) == "function" then
        local v = PCall(IsSpellKnown, id)
        if v ~= nil then return v and true or false end
    end
    return true
end

-- ---------------------- 角色快照 ----------------------

function ns:GetClassInfo()
    local _, classFile, classID = UnitClass("player")
    return classFile, classID
end

function ns:GetSpecID()
    if C_SpecializationInfo and type(C_SpecializationInfo.GetSpecialization) == "function" then
        local idx = PCall(C_SpecializationInfo.GetSpecialization)
        if idx then
            local info = PCall(C_SpecializationInfo.GetSpecializationInfo, idx)
            if type(info) == "table" and info.id then return info.id end
        end
    end
    if type(GetSpecialization) == "function" and type(GetSpecializationInfo) == "function" then
        local idx = PCall(GetSpecialization)
        if idx then
            local specID = PCall(GetSpecializationInfo, idx)
            if type(specID) == "number" then return specID end
        end
    end
    return nil
end

local function SafeRating(index)
    local v = PCall(GetCombatRatingBonus, index)
    -- 12.x：战斗中该接口可能返回 secret 值，做算术会炸 → 退回 0（按基础间隔生成）
    v = ns:Unsecret(v, 0)
    if type(v) == "number" then return v end
    return 0
end

local function GetItemSetID(link)
    local fn = (C_Item and C_Item.GetItemInfo) or (type(GetItemInfo) == "function" and GetItemInfo)
    if not fn then return nil end
    local sid = PCall(function() return select(16, fn(link)) end)
    if sid then return sid end
    return nil
end

--- 套装件数（同一 setID 出现最多的件数）
function ns:ScanTierSet()
    if type(GetInventoryItemLink) ~= "function" then return 0 end
    local counts, bestCount = {}, 0
    for slot = 1, 16 do
        local link = PCall(GetInventoryItemLink, "player", slot)
        if link then
            local sid = GetItemSetID(link)
            if sid and sid ~= 0 then
                counts[sid] = (counts[sid] or 0) + 1
                if counts[sid] > bestCount then bestCount = counts[sid] end
            end
        end
    end
    return bestCount
end

--- 饰品是不是"主动型"（有使用效果）
function ns:TrinketIsActive(slot)
    if type(GetInventoryItemLink) ~= "function" then return false end
    local link = PCall(GetInventoryItemLink, "player", slot)
    if not link then return false end
    local id = tonumber(link:match("item:(%d+)"))
    if not id then return false end
    local fn = (C_Item and C_Item.GetItemSpell) or (type(GetItemSpell) == "function" and GetItemSpell)
    if not fn then return false end
    local name = PCall(fn, id)
    return type(name) == "string" and name ~= ""
end

function ns:ScanCharacter()
    local scan = {}
    scan.spec = self:GetSpecID()
    local _, classID = self:GetClassInfo()
    scan.class = classID
    scan.haste = SafeRating(CR.haste)
    scan.crit = SafeRating(CR.crit)
    scan.mastery = SafeRating(CR.mastery)
    scan.vers = SafeRating(CR.vers)
    scan.tierCount = self:ScanTierSet()
    scan.trinket13 = self:TrinketIsActive(13)
    scan.trinket14 = self:TrinketIsActive(14)
    return scan
end

-- ---------------------- 急速 -> 填充间隔 ----------------------

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- 急速越高，同一个填充技能插得越密（rep 越小）
-- base 是 0% 急速时的间隔；haste 是百分比数值（25.4 = 25.4%）
local function FillerRep(base, minRep, maxRep, haste)
    local n = base / (1 + (haste or 0) / 100)
    return Clamp(math.floor(n + 0.5), minRep, maxRep)
end

-- ---------------------- 主入口 ----------------------

local function HasId(list, id)
    if type(list) ~= "table" then return false end
    for _, b in ipairs(list) do
        if b.id == id then return true end
    end
    return false
end

function ns:BuildSequence(specID, opts)
    opts = opts or {}
    local template = ns.TEMPLATES[specID]
    if not template then
        -- 文案不能写死版本号/职业（v1.7 那句"只做术士三系"早就过期，切职业时会误报）。
        -- 动态列出"当前实际有模板的专精"，一眼能看出缺哪个。
        return nil, "当前专精暂无模板：" .. ns:TemplateSpecList(specID)
    end

    -- AOE 变体：核心技能 + 多目标技能 +（可能换掉的）填充技能
    local isAoe = opts.aoe == true

    -- 学习适配：官方实测（Learner.lua 采样）样本够时，按实测频率重排 core、
    -- 自动补漏官方常推的技能。样本不足时原样返回，完全无感。
    local learnedInfo = nil
    if self.ApplyLearned then
        template, learnedInfo = self:ApplyLearned(specID, isAoe, template)
    end

    local aoeDef = isAoe and template.aoe or nil

    local scan = self:ScanCharacter()
    -- force = 给"不是当前专精"的模板兜底生成：不做技能过滤（法术书是当前的，查不准），
    -- 等玩家真切到那个专精时再重新精修一遍
    local forced = opts.force == true
    local blocks = {}
    local dropped, addedOptional = 0, 0
    local fillerDefUsed = nil

    -- 1. 核心循环：不会的技能直接丢掉
    --    v1.9.32：fb（off-GCD 兜底）/ guard（nochanneling 守卫）字段透传给 Writer，
    --    有任一字段的块会被渲染成"主技能 + 兜底行"的宏文本块（学自 AFFLIMULTI）
    local kept = 0
    for _, b in ipairs(template.core or {}) do
        local rep = (aoeDef and type(aoeDef.rep) == "table" and aoeDef.rep[b.id]) or b.rep
        if forced or self:KnowsSpell(b.id) then
            table.insert(blocks, { kind = "spell", id = b.id, rep = rep,
                                   fb = b.fb, guard = b.guard, cursor = b.cursor })
            kept = kept + 1
        else
            dropped = dropped + 1
        end
    end
    -- 安全网：如果核心一个都不认（API 行为变了），就全部保留，别生成空序列
    if kept == 0 and #(template.core or {}) > 0 then
        for _, b in ipairs(template.core) do
            local rep = (aoeDef and type(aoeDef.rep) == "table" and aoeDef.rep[b.id]) or b.rep
            table.insert(blocks, { kind = "spell", id = b.id, rep = rep,
                                   fb = b.fb, guard = b.guard, cursor = b.cursor })
        end
        dropped = 0
        scan.apiSuspect = true
    end

    -- 1.5 位移/接管技（v1.9.27）：目标型位移技能（如防护盾牌冲锋）插在 core 之后。
    -- 会了才加、序列里没有才加；单体外排 +AOE 两个变体都会带。CD 中点击不耗 GCD，插着无副作用。
    local mobilityUsed = 0
    for _, m in ipairs(ns.MOBILITY and ns.MOBILITY[specID] or {}) do
        if not HasId(blocks, m.id) and self:KnowsSpell(m.id) then
            table.insert(blocks, { kind = "spell", id = m.id, rep = m.rep or 3, role = "mobility" })
            mobilityUsed = mobilityUsed + 1
        end
    end

    -- 2. 可选技能：会了才加（兜底模式下一个都不加，保守）
    --    AOE 变体 = 基础 optional + aoe.add 的并集（按 id 去重）
    if not forced then
        local pool = {}
        for _, b in ipairs(template.optional or {}) do table.insert(pool, b) end
        if aoeDef then
            for _, b in ipairs(aoeDef.add or {}) do
                if not HasId(pool, b.id) then table.insert(pool, b) end
            end
            -- 通用候选池：补进"你会、且核心里还没有"的多目标技能
            for _, b in ipairs(ns.AOE_CANDIDATES or {}) do
                if not HasId(pool, b.id) and not HasId(blocks, b.id) then
                    table.insert(pool, b)
                end
            end
        end
        for _, b in ipairs(pool) do
            if self:KnowsSpell(b.id) then
                table.insert(blocks, { kind = "spell", id = b.id, rep = b.rep,
                                       fb = b.fb, guard = b.guard, cursor = b.cursor })
                addedOptional = addedOptional + 1
            end
        end
    end

    -- 3. 填充技能：间隔按急速缩放。AOE 变体优先用 aoe.filler（比如痛苦的腐蚀之种）
    --    v1.9.32：填充 def 支持 alt 链（吸取灵魂未学会自动退回暗影箭），
    --    以及 guard/fb（通道填充技带守卫进循环，见 Data.lua 265 模板）。
    local fillerRep = nil
    local fillerDef = (aoeDef and aoeDef.filler) or template.filler

    -- 在 def 的 id → alt 链里找第一个会的技能；找不到返回 nil
    local function PickFillerID(def)
        if type(def) ~= "table" then return nil end
        for _, cid in ipairs({ def.id, def.alt }) do
            if cid and self:KnowsSpell(cid) then return cid end
        end
        return nil
    end

    local fillerID = PickFillerID(fillerDef)
    if not fillerID and aoeDef and template.filler then
        -- AOE 填充没学会 → 退回单体填充（也走 alt 链），别让序列少一块
        fillerDef = template.filler
        fillerID = PickFillerID(fillerDef)
    end

    if fillerID then
        fillerRep = FillerRep(
            fillerDef.base or 4,
            fillerDef.min or 1,
            fillerDef.max or 8,
            scan.haste
        )
        table.insert(blocks, {
            kind = "spell",
            id = fillerID,
            rep = fillerRep,
            role = "filler",
            fb = fillerDef.fb,
            guard = fillerDef.guard,
            cursor = fillerDef.cursor,
        })
        fillerDefUsed = fillerDef
    end

    -- 4. 饰品：只插主动型（被动饰品触发不了，只会刷"物品未就绪"）
    --    兜底模式也插，反正装上去是什么就用什么
    local trinketUsed = 0
    if opts.trinket ~= false and template.trinkets then
        if scan.trinket13 then
            table.insert(blocks, { kind = "item", slot = "13" })
            trinketUsed = trinketUsed + 1
        end
        if scan.trinket14 then
            table.insert(blocks, { kind = "item", slot = "14" })
            trinketUsed = trinketUsed + 1
        end
    end

    -- 4.5 坦克防御层（v1.9.28，方向：坦克不是输出）：template.defense 固定编织层。
    -- 学习器只重排 core（输出层），防御层永不降级；插在序列最前，
    -- 让每圈先"盾挡→盾猛"成对（沉重反响：盾挡中盾猛加伤+延长盾挡）。
    -- 兜底模式（forced）不插，等玩家真切到该专精再精修。
    local defenseUsed = 0
    if not forced then
        local defs = {}
        for _, d in ipairs(template.defense or {}) do
            if self:KnowsSpell(d.id) then
                table.insert(defs, { kind = "spell", id = d.id, rep = d.rep or 2, role = "defense" })
                defenseUsed = defenseUsed + 1
            end
        end
        for i = #defs, 1, -1 do
            table.insert(blocks, 1, defs[i])   -- 倒序头插，保持 defense 表内顺序
        end
    end

    -- 4.8 off-GCD 兜底池（v1.9.32）：OGCD_FILLERS[classID] + 种族技。
    --     Writer 把 fb=true 的块渲染成"主技能 + 这些兜底行"——大招在 CD 时点击
    --     仍有反馈（学自论坛宏 AFFLIMULTI：命令恶魔/法术封锁/血性狂怒的用法）。
    local ogcd = {}
    local function AddOgcd(id)
        if not id then return end
        for _, x in ipairs(ogcd) do
            if x == id then return end
        end
        if self:KnowsSpell(id) then table.insert(ogcd, id) end
    end
    for _, id in ipairs(ns.OGCD_FILLERS and ns.OGCD_FILLERS[scan.class] or {}) do
        AddOgcd(id)
    end
    -- 种族 token：UnitRace 返回 (本地化名, 英文token, raceID)，取英文 token 查表
    local okRace, raceFile = pcall(function() return select(2, UnitRace("player")) end)
    if okRace and raceFile and ns.RACIAL_FILLERS then
        AddOgcd(ns.RACIAL_FILLERS[raceFile])
    end

    local maxBlocks = opts.max or 60
    while #blocks > maxBlocks do table.remove(blocks) end

    local baseLabel = template.label or tostring(specID)
    return {
        blocks = blocks,
        specID = specID,
        label = baseLabel .. (isAoe and " · AOE" or " · 单体"),
        seqName = ns:SeqName(specID, isAoe),
        dropped = dropped,
        optional = addedOptional,
        mobility = mobilityUsed,
        defense = defenseUsed,
        fillerRep = fillerRep,
        fillerID = fillerDefUsed and fillerDefUsed.id or nil,
        trinket = trinketUsed,
        ogcd = ogcd,
        forced = forced,
        aoe = isAoe,
        pet = ns.PET_SPELL and ns.PET_SPELL[specID] or nil,
        scan = scan,
        learned = learnedInfo,
    }
end

--- 一次算出单体 + AOE 两套（面板预览和批量生成都用它）
function ns:BuildBoth(specID, opts)
    opts = opts or {}
    local solo = self:BuildSequence(specID, opts)
    local a = {}
    for k, v in pairs(opts) do a[k] = v end
    a.aoe = true
    local aoe = self:BuildSequence(specID, a)
    return solo, aoe
end

--- 本职业所有有模板的专精（含当前专精）
function ns:AllTemplateSpecs()
    local out = {}
    for specID in pairs(ns.TEMPLATES) do
        table.insert(out, specID)
    end
    table.sort(out)
    return out
end

--- 「当前专精」没模板时的可读说明。
-- 关键：只列**本职业**已有的模板，绝不再冒出"别的职业"的专精名
-- （v1.7 那句写死的"只做术士三系"，在战士号上会误导成"这插件没做战士"）。
function ns:TemplateSpecList(specID)
    local _, classID = self:GetClassInfo()
    local className = (classID and ns.CLASS_NAMES and ns.CLASS_NAMES[classID]
        and ns.CLASS_NAMES[classID].cn) or "本职业"

    local names = {}
    -- ClassTemplateSpecs 只返回本职业的；职业识别不到时它会退回全部（安全兜底）
    for _, sid in ipairs(self:ClassTemplateSpecs()) do
        names[#names + 1] = (ns.SPEC_NAMES and ns.SPEC_NAMES[sid]) or tostring(sid)
    end

    -- 当前专精自己也要提示一下（它肯定不在 names 里，因为就是它没模板）
    local curName = (specID and ns.SPEC_NAMES and ns.SPEC_NAMES[specID])
        or (specID and tostring(specID)) or "当前专精"

    if #names == 0 then
        return className .. "「" .. curName .. "」还没做模板（后续版本补上）"
    end
    return className .. "「" .. curName .. "」暂无模板；" .. className .. "已有：" .. table.concat(names, "、")
end

--- 专精 -> 职业ID（用暴雪 API，取不到就靠内置表兜底）
local SPEC_CLASS = {
    [71]=1,[72]=1,[73]=1,
    [65]=2,[66]=2,[70]=2,
    [253]=3,[254]=3,[255]=3,
    [259]=4,[260]=4,[261]=4,
    [256]=5,[257]=5,[258]=5,
    [250]=6,[251]=6,[252]=6,
    [262]=7,[263]=7,[264]=7,
    [62]=8,[63]=8,[64]=8,
    [265]=9,[266]=9,[267]=9,
    [268]=10,[269]=10,[270]=10,
    [102]=11,[103]=11,[104]=11,[105]=11,
    [577]=12,[581]=12,
    [1447]=13,[1467]=13,[1468]=13,
}

function ns:SpecClassID(specID)
    if C_SpecializationInfo and type(C_SpecializationInfo.GetSpecializationInfo) == "function" then
        -- 反查：遍历 1..4 找 specID 对应的职业（贵，但很少调用）
        for i = 1, 4 do
            local info = C_SpecializationInfo.GetSpecializationInfo(i)
            if type(info) == "table" and info.id == specID and info.classID then
                return info.classID
            end
        end
    end
    return SPEC_CLASS[specID]
end

--- 只返回当前职业有模板的专精；取不到职业信息时退回全部（安全）
function ns:ClassTemplateSpecs()
    local _, classID = self:GetClassInfo()
    local out = {}
    for _, specID in ipairs(self:AllTemplateSpecs()) do
        if not classID or self:SpecClassID(specID) == classID then
            table.insert(out, specID)
        end
    end
    return out
end
