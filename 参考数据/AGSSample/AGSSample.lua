-- ==========================================================
-- AGSSample - 官方 Assisted Combat 优先级采样器  (v1.0.0)
--
-- 目的：搞清楚暴雪官方在"实战"中到底优先推荐哪个技能。
--   背景（已实测证伪）：GetRotationSpells() 返回的是一个"可用技能全集"，
--   它的**数组顺序没有优先级含义**（官方自己都标注 list[1] != GetNextCastSpell）。
--   唯一真实的优先级信号是 GetNextCastSpell()，但它是"实时值"，每时每刻在变。
--   ⇒ 想拿到优先级，只能"高频采样 + 统计频率"。
--
-- 用法：
--   /agssample start   开始采样（战斗外也能开，但只有战斗中才有数据）
--   /agssample stop    停止采样
--   /agssample         打印统计结果
--   /agssample show    打印结果 + 每个技能的原始 spellID（方便抄进模板）
--   /agssample reset   清空数据
--   /agssample id      列出采到的技能 ID（纯 ID 列表，最方便复制）
--
-- 设计要点：
--   * 纯只读：只调 C_AssistedCombat 的查询接口，不做任何改动，绝不影响输出。
--   * 全部走 pcall + IsSecretValue 保护：12.x 的 secret values 会返回加密值，
--     读到就跳过，绝不把它当数字用（否则会报错或算出垃圾数据）。
--   * 采样频率 0.1 秒；只在"有效推荐"（返回 >0 的数字）时计数。
--   * 同时记录"本次会话见过的技能名"，方便肉眼对照。
-- ==========================================================

local ADDON = "AGSSample"
local SAMPLER_VERSION = "1.0.0"

-- 采样状态
local state = {
    running   = false,
    ticks     = 0,        -- 采样总次数
    hits      = 0,        -- 有效推荐次数
    counts    = {},       -- [spellID] = 被推荐次数
    firstSeen = {},       -- [spellID] = 第一次见到的 GetTime()
    startedAt = 0,
    lastTick  = 0,
}

local ticker  -- 自建 ticker（不依赖库）

-- ---------------------- 工具 ----------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff9fd6ff[AGS采样]|r " .. tostring(msg))
end

--- 是不是被 secret 保护的值（12.x）
local function IsSecret(v)
    return type(IsSecretValue) == "function" and IsSecretValue(v)
end

--- 取技能名（拿不到就 #id）
local function SpellName(id)
    if not id then return "?" end
    local n
    if C_Spell and type(C_Spell.GetSpellName) == "function" then
        local ok, v = pcall(C_Spell.GetSpellName, id)
        if ok and type(v) == "string" and v ~= "" then n = v end
    end
    if not n and type(GetSpellInfo) == "function" then
        local ok, v = pcall(GetSpellInfo, id)
        if ok and type(v) == "string" and v ~= "" then n = v end
    end
    return n or ("#" .. tostring(id))
end

--- 读一次官方实时推荐。返回 spellID 或 nil
local function GetLivePick()
    if not C_AssistedCombat or type(C_AssistedCombat.GetNextCastSpell) ~= "function" then
        return nil
    end
    -- checkForVisibleButton = false：把所有技能都算进来（含宏条件里的隐藏技能），
    -- 我们关心的是"官方想让你打什么"，不是"动作条上看得见什么"。
    local ok, result = pcall(C_AssistedCombat.GetNextCastSpell, false)
    if not ok then return nil end
    if IsSecret(result) then return nil end          -- secret 值直接丢弃
    if type(result) ~= "number" or result <= 0 then return nil end
    return result
end

--- 读官方技能全集（用于"你没采到但有"的技能也列出来做对照）
local function GetPool()
    if not C_AssistedCombat or type(C_AssistedCombat.GetRotationSpells) ~= "function" then
        return nil
    end
    local ok, result = pcall(C_AssistedCombat.GetRotationSpells)
    if not ok or type(result) ~= "table" then return nil end
    local out = {}
    for i = 1, #result do
        local v = result[i]
        if not IsSecret(v) and type(v) == "number" and v > 0 then
            out[#out + 1] = v
        end
    end
    if #out == 0 then return nil end
    return out
end

-- ---------------------- 采样核心 ----------------------

local function Tick()
    if not state.running then return end
    state.ticks = state.ticks + 1
    state.lastTick = GetTime()

    local id = GetLivePick()
    if id then
        state.hits = state.hits + 1
        state.counts[id] = (state.counts[id] or 0) + 1
        if not state.firstSeen[id] then
            state.firstSeen[id] = GetTime()
        end
    end
end

local function StartSampling()
    if state.running then
        Print("已经在采样了。用 |cffFFD100/agssample stop|r 停止，|cffFFD100/agssample|r 看结果。")
        return
    end
    state.running = true
    if not state.startedAt or state.startedAt == 0 then
        state.startedAt = GetTime()
    end

    -- 优先用 C_Timer（精确、零开销）；没有就退化成 OnUpdate 累加
    if not ticker and C_Timer and type(C_Timer.NewTicker) == "function" then
        ticker = C_Timer.NewTicker(0.1, Tick)
    end
    if not ticker and CreateFrame then
        local f = CreateFrame("Frame")
        local acc = 0
        f:SetScript("OnUpdate", function(_, dt)
            if not state.running then acc = 0; return end
            acc = acc + dt
            if acc >= 0.1 then
                acc = acc - 0.1
                Tick()
            end
        end)
        ticker = { Cancel = function() end }   -- 占位：OnUpdate 帧不用主动取消
        Print("|cffffaa00C_Timer 不可用|r，已切换为 OnUpdate 采样（性能略低但能用）。")
    end

    Print("|cff00ff00开始采样|r（每 0.1 秒记录一次官方推荐）。")
    Print("现在去打架——|cffffaa00一定要在战斗中|r（有目标、有敌对行为）才会采到数据。")
    Print("打完后用 |cffFFD100/agssample|r 看统计。")
end

local function StopSampling()
    if not state.running then
        Print("当前没有在采样。")
        return
    end
    state.running = false
    if ticker and ticker.Cancel then pcall(function() ticker.Cancel() end) end
    ticker = nil
    Print("|cffffaa00已停止采样|r。用 |cffFFD100/agssample|r 查看统计结果。")
end

-- ---------------------- 报告 ----------------------

local function Elapsed()
    if not state.startedAt or state.startedAt == 0 then return 0 end
    local endT = state.running and GetTime() or (state.lastTick or GetTime())
    return math.max(0, endT - state.startedAt)
end

local function HumanTime(sec)
    sec = math.floor(sec or 0)
    return string.format("%d 分 %02d 秒", math.floor(sec / 60), sec % 60)
end

local function Report(showIds)
    if state.hits == 0 then
        Print("|cffffaa00还没有采到任何数据|r。")
        Print("可能原因：① 没在战斗中（必须打怪/木桩）；② 官方助手没开启；")
        Print("         ③ 当前职业/专精官方还没配 Assisted Combat。")
        Print(string.format("（采样点 %d 次，全部无效）", state.ticks))
        return
    end

    -- 排序：次数多的在前
    local list = {}
    for id, n in pairs(state.counts) do
        list[#list + 1] = { id = id, n = n }
    end
    table.sort(list, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.id < b.id
    end)

    Print("|cffFFD100=== AGS 官方优先级采样结果 ===|r")
    Print(string.format("时长 %s | 采样点 %d 次 | 有效推荐 %d 次（%.1f%%）",
        HumanTime(Elapsed()), state.ticks, state.hits,
        state.ticks > 0 and (state.hits / state.ticks * 100) or 0))
    Print("|cffaaaaaa（频率越高 = 官方认为越该优先打）|r")

    for i, e in ipairs(list) do
        local pct = e.n / state.hits * 100
        local bar = string.rep("|", math.max(1, math.floor(pct / 2)))
        local line = string.format("%2d. %-12s %7d 次  %5.1f%%  |cff00ff00%s|r",
            i, SpellName(e.id), e.n, pct, bar)
        if showIds then
            line = line .. string.format("  |cffffaa00[%d]|r", e.id)
        end
        Print(line)
    end

    -- 官方池里有、但一次都没被推荐过的技能（说明"可用但不优先"）
    local pool = GetPool()
    if pool then
        local never = {}
        for _, id in ipairs(pool) do
            if not state.counts[id] then never[#never + 1] = id end
        end
        if #never > 0 then
            local names = {}
            for _, id in ipairs(never) do
                names[#names + 1] = SpellName(id) .. (showIds and ("(" .. id .. ")") or "")
            end
            Print("|cffaaaaaa官方池有、但没被推荐过（可用但不优先）：|r" .. table.concat(names, "、"))
        end
    end

    Print("|cffaaaaaa提示：多打几场不同场景（单体/AOE/爆发期）再综合看。|r")
end

--- 纯 ID 列表（方便直接复制进模板代码）
local function ReportIds()
    if state.hits == 0 then
        Print("还没有数据。")
        return
    end
    local list = {}
    for id, n in pairs(state.counts) do list[#list + 1] = { id = id, n = n } end
    table.sort(list, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.id < b.id
    end)

    local ids, details = {}, {}
    for i, e in ipairs(list) do
        ids[#ids + 1] = tostring(e.id)
        details[#details + 1] = string.format("%d=%s(%d次)", e.id, SpellName(e.id), e.n)
    end
    Print("按频率排序的 ID：")
    Print("  " .. table.concat(ids, ", "))
    Print("对照：")
    Print("  " .. table.concat(details, "  |  "))
    Print("|cffaaaaaa可直接复制上面第一行 IDs 发给我。|r")
end

local function ResetData()
    state.ticks, state.hits = 0, 0
    state.counts, state.firstSeen = {}, {}
    state.startedAt, state.lastTick = 0, 0
    Print("数据已清空。")
end

-- ---------------------- 命令入口 ----------------------

local function Handle(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local cmd = msg:match("^(%S+)") or ""

    if cmd == "start" then
        StartSampling()
    elseif cmd == "stop" then
        StopSampling()
    elseif cmd == "reset" then
        ResetData()
    elseif cmd == "show" then
        Report(true)
    elseif cmd == "id" or cmd == "ids" then
        ReportIds()
    elseif cmd == "" then
        Report(false)
    elseif cmd == "help" then
        Print("用法：|cffFFD100/agssample start|r 开始 |cffFFD100stop|r 停止 |cffFFD100reset|r 清空")
        Print("      |cffFFD100/agssample|r 看统计 |cffFFD100show|r 带ID |cffFFD100id|r 纯ID列表")
    else
        Print("未知命令：" .. cmd .. "，输入 |cffFFD100/agssample help|r 看用法。")
    end
end

SLASH_AGSSAMPLE1 = "/agssample"
SLASH_AGSSAMPLE2 = "/agsp"
SlashCmdList["AGSSAMPLE"] = Handle

Print("|cff00ff00已加载 v" .. SAMPLER_VERSION .. "|r。输入 |cffFFD100/agssample help|r 看用法。")
