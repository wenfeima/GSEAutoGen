-- ==========================================================
-- GSEAutoGen - Learner.lua  (v1.9.31)
-- 官方优先级"后台学习器"：
--   1) 被动学习：战斗中每 0.15s 读一次 C_AssistedCombat.GetNextCastSpell()
--      （官方推荐什么就记什么），脱战时按 单体/多目标 分桶入库
--   2) 主动学习：/ags learn start（打木桩抓数据），/ags learn stop 结算
--   3) 应用：样本够（>=200）时，把实测频率用于重排模板 core + 自动补漏技能
--      （见 Engine.lua 的 ApplyLearned —— 由 BuildSequence 自动调用）
-- 注意：数据源是官方 Assisted Combat，需在游戏设置里保持"一键辅助"开启
-- ==========================================================

local ADDON_NAME, ns = ...

local TICK          = 0.15   -- 采样间隔（秒）
local MIN_APPLY     = 200    -- 应用到模板所需的最低累计样本
local MIN_MERGE     = 50     -- 单场战斗至少多少有效推荐才入库（过滤 1 秒拉怪的噪音）
local MIN_SHARE_ADD = 0.05   -- 官方推荐占比 >=5% 且模板没有的技能 → 自动补进 optional

-- ---------------------- 工具 ----------------------

local function Bucket(specID, kind)
    if not ns.db then ns:InitDB() end
    local db = ns.db
    if type(db.learned) ~= "table" then db.learned = {} end
    if type(db.learned[specID]) ~= "table" then db.learned[specID] = {} end
    local b = db.learned[specID][kind]
    if type(b) ~= "table" then
        b = { samples = 0, counts = {}, updated = nil }
        db.learned[specID][kind] = b
    end
    return b
end

local function VisibleEnemyCount()
    -- ⚠️ 名字条不只敌对单位：其他玩家/宝宝/小宠都有名字条。
    -- 之前不判断导致木桩场（周围一堆玩家）永远判定"3+目标"，
    -- 同一场战斗的样本被劈进 单体/多目标 两个桶。必须过滤成"我能攻击的活物"。
    local n = 0
    if C_NamePlate and C_NamePlate.GetNamePlates then
        local ok, plates = pcall(C_NamePlate.GetNamePlates)
        if ok and type(plates) == "table" then
            for _, plate in ipairs(plates) do
                local unit = plate.namePlateUnitToken
                if unit and UnitCanAttack("player", unit)
                    and not UnitIsDead(unit) and UnitHealth(unit) > 0 then
                    n = n + 1
                end
            end
        end
    end
    -- 目标超出名字条显示距离时兜底按 1 算
    if n == 0 and UnitExists("target") and UnitCanAttack("player", "target")
        and not UnitIsDead("target") then
        n = 1
    end
    return n
end

local function NewSession()
    return { total = 0, valid = 0, st = {}, aoe = {} }
end

-- 一次采样：读官方推荐，按目标数分桶
-- 12.x 坑：返回值在部分战斗情境下是 secret 值——不能当数字用、存进 SV 会在登出时被整键丢弃。
-- 所以：识别到 secret 就换「仅可见按钮」模式再试一次，还不行就放弃本 tick。
local function SampleOnce(sess)
    if not (C_AssistedCombat and type(C_AssistedCombat.GetNextCastSpell) == "function") then return end
    -- v1.9.31 关键守卫：没有"活的敌对目标"时官方推荐器只返回待补的首个技能，
    -- 拉怪跑路/怪死间隙的空窗样本会把桶污染成"鬼影缠身 97.7%"这种退化分布。
    if not (UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDead("target")) then
        return
    end
    sess.total = sess.total + 1
    local ok, id = pcall(C_AssistedCombat.GetNextCastSpell, false)
    if not ok or type(id) ~= "number" or id <= 0 then return end
    if ns:Unsecret(id) == nil then
        ok, id = pcall(C_AssistedCombat.GetNextCastSpell, true)
        if not ok or type(id) ~= "number" or id <= 0 then return end
        if ns:Unsecret(id) == nil then return end
    end
    sess.valid = sess.valid + 1
    local bucket = (VisibleEnemyCount() >= 3) and sess.aoe or sess.st
    bucket[id] = (bucket[id] or 0) + 1
end

local function MergeCounts(dest, src, valid)
    dest.samples = (dest.samples or 0) + valid
    for id, n in pairs(src) do
        -- 防御：secret 键（历史脏数据）绝不入库
        if type(id) == "number" and id > 0 and ns:Unsecret(id) ~= nil then
            dest.counts[id] = (dest.counts[id] or 0) + n
        end
    end
    dest.updated = date("%Y-%m-%d %H:%M")
end

-- ---------------------- 战斗被动学习 ----------------------

local ticker = nil
local sess = nil            -- 当前战斗的采样会话
local deliberate = nil      -- /ags learn start 的主动会话（跨多场战斗累积）

local function StopTicker()
    if ticker then
        pcall(function() ticker:Cancel() end)
        ticker = nil
    end
end

-- 战斗会话样本并入主动学习会话（v1.9.21 抽成独立函数：
-- 脱战结算和"战斗中点停止"都要用，否则整场没脱战时明细永远并不进去）
-- 把一场战斗的样本明细直接入库并汇报（v1.9.26 统一入口，主动/被动共用）
-- sessionValid：主动会话时传其累计计数（显示用）；quiet：登出兜底时静默
-- 注意每桶只加"自己桶里的明细总数"——两桶都加 s.valid 会虚报翻倍
local function DepositAndReport(s, specID, sessionValid, quiet)
    local function counted(t)
        local c = 0
        for _, n in pairs(t) do c = c + n end
        return c
    end
    local st = Bucket(specID, "st")
    local aoe = Bucket(specID, "aoe")
    local cSt, cAoe = counted(s.st), counted(s.aoe)
    local changed = false
    if cSt > 0 then MergeCounts(st, s.st, cSt); changed = true end
    if cAoe > 0 then MergeCounts(aoe, s.aoe, cAoe); changed = true end
    if not changed then return end
    if quiet then return end
    local applied = st.samples >= MIN_APPLY
    ns:Print(string.format(
        "[学习] 入库 +%d 次推荐%s | 单体累计 %d%s | 多目标累计 %d%s",
        cSt + cAoe,
        sessionValid and string.format("（会话累计 %d）", sessionValid) or "",
        st.samples, st.samples >= MIN_APPLY and "✓" or ("/" .. MIN_APPLY),
        aoe.samples, aoe.samples >= MIN_APPLY and "✓" or ("/" .. MIN_APPLY)))
    -- 样本首次够数 / 数据更新后 → 安静地重新生成（内容没变则完全静默）
    if applied and ns.db.auto ~= false and ns:HasGSE() then
        ns:SafeGenerate(true)
    end
end

-- 脱战结算：把本战斗样本入库
local function SettleSession()
    StopTicker()
    if not sess then return end
    local s = sess
    sess = nil

    local specID = ns.GetSpecID and ns:GetSpecID()
    -- v1.9.30：GetSpecID 极端时机（登录/切界面/职业API未就绪）会返回 0，
    -- 0 是 truthy 会骗过旧守卫，把整场数据写进 learned[0] 垃圾桶（实测踩过：1413 样本进了 [0]）
    if not specID or specID <= 0 then return end

    -- 主动会话进行中：v1.9.26 起每场脱战**直接入库**——
    -- 用户"停手"就算数，不用点停止；数据随每场战斗实时落盘，重载也不怕。
    -- （旧模型攒在内存会话里等 stop 结算，已三次坑丢整场数据）
    if deliberate then
        deliberate.total = deliberate.total + s.total
        DepositAndReport(s, specID, deliberate.valid)
        return
    end

    -- 普通被动学习：太短的战斗不算（噪音）
    if s.valid < MIN_MERGE then return end
    DepositAndReport(s, specID, nil)
end

local function StartTicker()
    if ticker then return end
    if not (C_Timer and C_Timer.NewTicker) then return end
    ticker = C_Timer.NewTicker(TICK, function()
        if not sess then return end
        if UnitAffectingCombat("player") then
            local before = sess.valid
            SampleOnce(sess)
            -- 主动会话进行中：实时累计（按钮上能显示"已采样 N 次"）
            if deliberate and sess.valid > before then
                deliberate.valid = deliberate.valid + (sess.valid - before)
            end
        end
    end)
end

-- ---------------------- 模板应用（Engine.BuildSequence 调用） ----------------------

--- 用学习数据重排模板（绝不改动 ns.TEMPLATES 原表，返回副本）
-- 返回 tpl, info；样本不足时原样返回
function ns:ApplyLearned(specID, isAoe, tpl)
    local db = self.db
    if type(db.learned) ~= "table" or type(db.learned[specID]) ~= "table" then
        return tpl, nil
    end
    -- v1.9.22：只入库过单侧桶时另一侧不存在（Bucket 按需创建），必须判空
    local aoeB = db.learned[specID].aoe
    local stB  = db.learned[specID].st
    if type(aoeB) ~= "table" then aoeB = nil end
    if type(stB) ~= "table" then stB = nil end
    -- AOE 序列优先用 AOE 桶；不够就退回单体桶排序（总比没数据强）
    local bucket = isAoe
        and ((aoeB and (aoeB.samples or 0) >= MIN_APPLY) and aoeB or stB)
        or stB
    if not bucket or (bucket.samples or 0) < MIN_APPLY then return tpl, nil end

    -- 数据健康守卫：samples 够但 counts 是空的（历史 secret 键被 SV 丢弃）→ 视为无效，
    -- 否则所有 core 都会因"频率为 0"被降级，生成出只有填充的残废序列
    local counted = 0
    for _, n in pairs(bucket.counts) do counted = counted + n end
    if counted < MIN_APPLY then return tpl, nil end

    local counts = bucket.counts
    local freq = function(id)
        if type(id) ~= "number" or ns:Unsecret(id) == nil then return 0 end
        return counts[id] or 0
    end

    local info = { samples = bucket.samples, kind = bucket == aoeB and "aoe" or "st",
                   reordered = 0, added = 0, demoted = 0 }

    -- 收集模板里已有的技能 id（core+optional+filler+aoe.add）
    local known = {}
    local function mark(b) if b and b.id then known[b.id] = true end end
    for _, b in ipairs(tpl.core or {}) do mark(b) end
    for _, b in ipairs(tpl.optional or {}) do mark(b) end
    if tpl.filler then mark(tpl.filler) end
    if tpl.aoe then
        if tpl.aoe.filler then mark(tpl.aoe.filler) end
        for _, b in ipairs(tpl.aoe.add or {}) do mark(b) end
    end

    -- 1) core 重排：按官方频率降序；样本里从未出现的 core 降级到 optional 末尾
    --    （例：位移技 SimC 说要打、官方从没推荐 → 降级，不删）
    local coreNew, demoted = {}, {}
    for _, b in ipairs(tpl.core or {}) do
        if freq(b.id) > 0 then table.insert(coreNew, b) else table.insert(demoted, b) end
    end
    table.sort(coreNew, function(a, c)
        local fa, fc = freq(a.id), freq(c.id)
        if fa ~= fc then return fa > fc end
        return (a.rep or 0) > (c.rep or 0)
    end)
    info.reordered = #coreNew
    info.demoted = #demoted

    -- 2) optional = 原 optional + 降级的 core
    local optNew = {}
    for _, b in ipairs(tpl.optional or {}) do table.insert(optNew, b) end
    for _, b in ipairs(demoted) do table.insert(optNew, b) end

    -- 3) 补漏：官方常推（share>=5%）但模板没有的技能 → 追加 optional
    -- v1.9.30：**通道法术一律不补**——连点宏里通道技会被下一次点击反复打断
    -- （吸取灵魂实测：28.3% 占比若补进循环，按住宏就变成"引导-打断-引导"抽搐）
    for id, n in pairs(counts) do
        if type(id) == "number" and id > 0 and ns:Unsecret(id) ~= nil
            and not known[id] and (n / counted) >= MIN_SHARE_ADD
            and not (ns.CHANNELLED and ns.CHANNELLED[id]) then
            -- v1.9.35：rep 3→6。补漏技能是"模板没配但官方常推"，多为 DoT/维护型；
            -- rep=3 会让 DoT 每 3 步狂刷一次（实测"一直打痛楚"的帮凶），6 起步保守
            table.insert(optNew, { id = id, rep = 6 })
            info.added = info.added + 1
            known[id] = true
        end
    end

    -- 组装副本（只换 core/optional，其余字段引用原表即可——下游只读）
    local newT = {}
    for k, v in pairs(tpl) do newT[k] = v end
    newT.core = coreNew
    newT.optional = optNew

    -- 4) AOE 序列：aoe.add 也按频率重排 + 补漏
    if isAoe and tpl.aoe then
        local aoeNew = {}
        for k, v in pairs(tpl.aoe) do aoeNew[k] = v end
        local addNew = {}
        for _, b in ipairs(tpl.aoe.add or {}) do
            if freq(b.id) > 0 then table.insert(addNew, b) end
        end
        table.sort(addNew, function(a, c) return freq(a.id) > freq(c.id) end)
        for _, b in ipairs(tpl.aoe.add or {}) do
            if freq(b.id) == 0 then table.insert(addNew, b) end  -- 没数据的不丢，排后面
        end
        for id, n in pairs(counts) do
            if type(id) == "number" and id > 0 and ns:Unsecret(id) ~= nil
                and not known[id] and (n / counted) >= MIN_SHARE_ADD then
                table.insert(addNew, { id = id, rep = 6 })  -- v1.9.35：同上，3→6
                known[id] = true
            end
        end
        aoeNew.add = addNew
        newT.aoe = aoeNew
    end

    return newT, info
end

-- ---------------------- 按键码 / 面板按钮（UI 调用） ----------------------

--- 学习开关键：按一下开始木桩采样，再按一下结算入库（免开聊天框）
function ns:LearnToggleKeybind()
    if deliberate then
        self:LearnCommand("stop")
    else
        self:LearnCommand("start")
    end
end

--- 面板按钮用的状态查询
function ns:LearnSessionActive()
    return deliberate ~= nil
end

function ns:LearnSessionCount()
    return deliberate and deliberate.valid or 0
end

--- 当前主动会话的类型（"st" / "aoe"），没有会话时返回 nil
function ns:LearnSessionKind()
    return deliberate and deliberate.kind or nil
end

--- 按类别切换学习会话（面板按钮用）：
--   点自己类型的按钮 = 开始/结束；点另一个类型 = 结束当前并开始新类型
function ns:LearnToggle(kind)
    kind = (kind == "aoe") and "aoe" or "st"
    if deliberate and deliberate.kind == kind then
        self:LearnCommand("stop")
        return
    end
    if deliberate then
        self:LearnCommand("stop")   -- 先结算当前（样本够会入库，不够会提示丢弃）
    end
    self:LearnCommand(kind == "aoe" and "start aoe" or "start")
end

-- ---------------------- 命令（/ags learn ...） ----------------------

local function FmtBucket(b)
    if not b or (b.samples or 0) == 0 then return "无数据" end
    local arr = {}
    for id, n in pairs(b.counts) do
        -- 跳过被 SV 丢弃/加密污染的键
        if type(id) == "number" and id > 0 and ns:Unsecret(id) ~= nil then
            table.insert(arr, { id = id, n = n })
        end
    end
    table.sort(arr, function(a, c) return a.n > c.n end)
    local parts = {}
    for i, e in ipairs(arr) do
        if i > 6 then break end
        local name = ns:SpellName(e.id)
        local label = (type(name) == "string" and name ~= "" and name:sub(1, 1) ~= "#")
            and name or ("ID" .. e.id)
        table.insert(parts, string.format("%s(%d) %.1f%%", label, e.id, e.n / b.samples * 100))
    end
    return string.format("%d 样本：%s", b.samples, table.concat(parts, " > "))
end

function ns:LearnCommand(arg)
    arg = (arg or ""):lower()
    local verb, what = arg:match("^(%S*)%s*(%S*)$")
    local specID = ns:GetSpecID()
    if specID and specID <= 0 then specID = nil end   -- v1.9.30：0 = 职业API未就绪，别当有效专精用
    local specLabel = specID and (ns.SPEC_NAMES and ns.SPEC_NAMES[specID]) or tostring(specID or "?")

    if verb == "start" then
        if deliberate then
            self:Print("[学习] 木桩会话已在进行中（累计 " .. deliberate.valid .. "），先 /ags learn stop")
            return
        end
        local kind = (what == "aoe") and "aoe" or "st"
        deliberate = { valid = 0, total = 0, st = {}, aoe = {}, kind = kind }
        -- 若已在战斗中点的开始：本战斗之前的样本不属于"木桩会话"，
        -- 重开一个战斗会话保证计数一致（否则结算会把整场样本并进来、计数却只有开始后的，
        -- 造成"本场 +1025 / 会话累计 75"那种对不上的账）
        if sess then
            sess = NewSession()
            StartTicker()   -- 幂等；万一战斗会话存在但 ticker 没跑也能补上
            self:Print("[学习] 检测到正在战斗中：从现在开始计数（之前的样本不计入本会话）")
        end
        if what == "aoe" then
            self:Print("[学习] 主动会话开始（AOE）：拉 3+ 只怪打 2-3 分钟，结束后 /ags learn stop")
        else
            self:Print("[学习] 主动会话开始（单体）：打木桩 2-3 分钟（爆发技能照常开），结束后 /ags learn stop")
        end
        self:Print("[学习] 官方推荐会随战斗实时记录；不用刻意改打法，正常输出即可。每场脱战自动入库（v1.9.26），打完点一下停止结束会话。")
        return
    elseif verb == "stop" then
        if not deliberate then
            self:Print("[学习] 没有进行中的木桩会话")
            return
        end
        StopTicker()
        local d = deliberate
        deliberate = nil
        -- v1.9.26：数据已随每场脱战实时入库，stop 只是结束会话。
        -- 战斗中点停止时，当前战斗样本还没结算，补一次直接入库。
        if sess and specID then
            local s = sess
            sess = nil
            DepositAndReport(s, specID, d.valid)
        end
        self:Print(string.format("[学习] 会话结束（%s，共采样 %d 次）。样本已随每场战斗实时入库",
            d.kind == "aoe" and "AOE" or "单体", d.valid))
        return
    elseif verb == "show" or verb == "" then
        if not specID then self:Print("读不到当前专精"); return end
        self:Print("—— 「" .. specLabel .. "」学习数据 ——")
        -- 会话进行中先说明：数据随每场脱战自动入库（v1.9.26）
        if deliberate then
            self:Print(string.format(
                "[学习] 会话进行中（%s，已实时采样 %d）——每场脱战自动入库，打完点一下停止即可",
                deliberate.kind == "aoe" and "AOE" or "单体", deliberate.valid))
        end
        self:Print(" 单体：" .. FmtBucket(Bucket(specID, "st")))
        self:Print(" 多目标：" .. FmtBucket(Bucket(specID, "aoe")))
        local applied = (Bucket(specID, "st").samples or 0) >= MIN_APPLY
        local hasTpl = (ns.TEMPLATES and ns.TEMPLATES[specID]) ~= nil
        if applied and not hasTpl then
            self:Print(" 状态：|cffffaa00数据已够，但当前专精暂无模板|r——生成时还用不上（模板上线后自动生效）")
        else
            self:Print(applied and " 状态：|cff00ff00已生效|r（生成时按实测重排 core）"
                or string.format(" 状态：累积中（%d/%d 生效）", Bucket(specID, "st").samples, MIN_APPLY))
        end
        return
    elseif verb == "reset" then
        if not self.db.learned then self:Print("没有学习数据"); return end
        if what == "all" then
            self.db.learned = {}
            self:Print("已清空全部专精的学习数据")
        else
            if self.db.learned[specID] then self.db.learned[specID] = nil end
            self:Print("已清空「" .. specLabel .. "」的学习数据")
        end
        return
    elseif verb == "auto" then
        self.db.learnPassive = not (self.db.learnPassive ~= false)
        self:Print("被动学习（平时战斗自动累积）：" ..
            (self.db.learnPassive and "|cff00ff00开|r" or "|cff888888关|r"))
        return
    else
        self:Print("用法：learn start [aoe] | stop | show | reset [all] | auto")
        self:Print("  start       打木桩主动采样（单体，2-3 分钟后 stop）")
        self:Print("  start aoe   拉群主动采样（多目标）")
        self:Print("  stop        结算木桩会话并入库")
        self:Print("  show        看当前专精的学习数据与生效状态")
        self:Print("  auto        开关被动学习（平时战斗自动累积，默认开）")
        return
    end
end

-- ---------------------- 事件 ----------------------

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
f:RegisterEvent("PLAYER_LOGOUT")
f:SetScript("OnEvent", function(_, event)
    if not ns.db then ns:InitDB() end
    if event == "PLAYER_REGEN_DISABLED" then
        if ns.db.learnPassive == false and not deliberate then return end
        sess = NewSession()
        StartTicker()
    elseif event == "PLAYER_REGEN_ENABLED" then
        SettleSession()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- v1.9.30：清掉历史遗留的 [0] 垃圾桶（GetSpecID 返 0 时写入的，永远不该存在）
        if type(ns.db.learned) == "table" and ns.db.learned[0] then
            ns.db.learned[0] = nil
        end
        -- 进游戏就在战斗中（极少见）：补开会话
        if UnitAffectingCombat("player") and not sess then
            sess = NewSession()
            StartTicker()
        end
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- 切专精：正在进行的战斗样本归属会乱，直接丢弃
        if sess then
            sess = nil
            StopTicker()
        end
    elseif event == "PLAYER_LOGOUT" then
        -- v1.9.25/26：登出 //reload 时若学习会话还开着，把未结算的当前战斗样本
        -- 直接入库（PLAYER_LOGOUT 在存档保存前触发，此刻写 db 能落盘）。
        -- 静默：登出时聊天框不可靠，也不该触发生成。
        local specID = ns.GetSpecID and ns:GetSpecID()
        if specID and specID <= 0 then specID = nil end   -- v1.9.30：0 会写进 learned[0] 垃圾桶
        if deliberate and specID and sess then
            local s = sess
            sess = nil
            DepositAndReport(s, specID, nil, true)
            deliberate = nil
        end
    end
end)
