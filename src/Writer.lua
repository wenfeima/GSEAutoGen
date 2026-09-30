-- ==========================================================
-- GSEAutoGen - Writer.lua  (v1.2)
--
-- 关键事实（都在本机 GSE 3.3.34 源码里核对过）：
--   1. GSE 3.3.x 移除了全局 GSE 表，只留一个公开代理
--      _G.GSE = { RegisterAddon, GetSequenceNamesFromLibrary, isEmpty, Statics }
--      （GSE/API/Plugins.lua:206-219，rawset(_G,"GSE",publicProxy)，写入被静默丢弃）
--      所以 CreateGSE3Button / AddSequenceToCollection 外部一律拿不到。
--   2. 序列存储格式（GSE/API/Serialisation.lua:6）：
--      GSESequences[classID][name] =
--          "!GSE3!" .. EncodeBase64(CompressString(SerializeCBOR({name, sequence})))
--      C_EncodingUtil 是暴雪原生 API，不依赖 GSE。
--   3. 唯一公开且能"当场生效"的入口是 GSE.RegisterAddon：
--      版本变化时会调用 GSE.LoadPluginSequences -> ImportSerialisedSequence
--      + PerformReloadSequences，所以不必 /reload。
--      （Plugins.lua:25-59）每次生成用新版本号即可触发。
--   4. 按钮名 == 序列名，所以 /click 后面直接写序列名（Storage.lua:1576）。
-- ==========================================================

local ADDON_NAME, ns = ...

local function PCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
    return nil
end

-- ---------------------- 环境检查 ----------------------

function ns:HasGSE()
    return type(_G.GSE) == "table"
        and type(_G.GSE.RegisterAddon) == "function"
end

--- GSE 的内部版本号：3.3.34 -> 3334（与 SCG 宏里的 3315/3316 同一套编码）
function ns:GSEVersionInfo()
    local get = C_AddOns and C_AddOns.GetAddOnMetadata
    local v = PCall(get, "GSE", "Version")
    if type(v) == "string" then
        local a, b, c = v:match("^(%d+)%.(%d+)%.?(%d*)")
        if a then
            return tonumber(a) * 1000 + tonumber(b) * 100 + tonumber(c ~= "" and c or 0)
        end
    end
    return 3334
end

function ns:TOCVersion()
    local v = PCall(GetBuildInfo)
    local toc = select(4, PCall(GetBuildInfo))
    if type(toc) == "number" then return toc end
    return 120100
end

-- ---------------------- 校验和（消掉"没有完整性校验和"警告） ----------------------
-- 算法抄自 GSE/API/Checksum.lua:9-51,171-179（v1：FNV-1a 32 位 + 环境盐）
-- 关键点：v1 是**纯哈希**，没有私钥签名，所以外部程序可以自己算出来。
-- （v2 是 Ed25519 真签名，需要 GSE 官方的私钥，外部不可能伪造 —— 但 v1 就够用了）

local FNV_OFFSET = 2166136261
local FNV_PRIME  = 16777619
local MOD32      = 2 ^ 32

local function fnv1a(str, seed)
    local hash = seed or FNV_OFFSET
    if type(bit) ~= "table" or type(bit.bxor) ~= "function" then return nil end
    for i = 1, #str do
        hash = bit.bxor(hash, str:byte(i))
        hash = (hash * FNV_PRIME) % MOD32
    end
    return hash
end

--- 与 GSE 的 canonicalize_v1 完全一致（长度前缀序列化，非 JSON）
local function canonicalize_v1(val, visited)
    visited = visited or {}
    local t = type(val)
    if t == "string" then
        return "s" .. #val .. ":" .. val
    elseif t == "number" then
        return "n" .. tostring(val)
    elseif t == "boolean" then
        return val and "b1" or "b0"
    elseif t == "nil" then
        return "z"
    elseif t == "table" then
        if visited[val] then return "c" end
        visited[val] = true
        local keys = {}
        for k in pairs(val) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            local ta, tb = type(a), type(b)
            if ta ~= tb then return ta == "number" end
            return tostring(a) < tostring(b)
        end)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = canonicalize_v1(k, visited) .. "=" .. canonicalize_v1(val[k], visited)
        end
        visited[val] = nil
        return "t{" .. table.concat(parts, ",") .. "}"
    end
    return "?"
end

--- 返回 "v1:<8位十六进制>"，失败返回 nil
function ns:ComputeChecksum(sequence)
    if type(sequence) ~= "table" or type(sequence.Versions) ~= "table" then return nil end

    local projectID = _G.WOW_PROJECT_ID or 1
    local expansion = _G.GetExpansionLevel and _G.GetExpansionLevel() or 0
    -- 盐：GSE\226\156\168<projectID>\31<expansion>
    local salt = string.format("GSE\226\156\168%d\31%d", projectID, expansion)

    local saltHash = fnv1a(salt)
    if not saltHash then return nil end
    local finalHash = fnv1a(canonicalize_v1(sequence.Versions), saltHash)
    if not finalHash then return nil end
    return string.format("v1:%08x", finalHash)
end

-- ---------------------- 编码 ----------------------

local function EncodeSequence(name, sequence)
    if not (C_EncodingUtil and C_EncodingUtil.SerializeCBOR) then
        return nil, "缺少 C_EncodingUtil，无法编码"
    end
    local ok, result = pcall(function()
        return "!GSE3!"
            .. C_EncodingUtil.EncodeBase64(
                C_EncodingUtil.CompressString(
                    C_EncodingUtil.SerializeCBOR({ name, sequence })
                )
            )
    end)
    if not ok or type(result) ~= "string" then
        return nil, "编码失败：" .. tostring(result)
    end
    return result
end

-- ---------------------- 块 -> GSE Action ----------------------
-- 与 SCG 一致的基础块用 spell / item 类型；
-- v1.9.32 起，带 fb（off-GCD 兜底）或 guard（nochanneling 守卫）字段的块
-- 渲染成 macro 文本块："/cast <主技能>" 失败时同一次点击落到 "/cast <兜底>"。
-- 已在 GSE 3.3.x 源码（Storage.lua PCallCreateGSE3Button / clickexecution）核实：
--   每一步会把 type 属性一起盖到安全按钮上，macrotext 步 → type="macro"，
--   与外层 "/click 序列名" 完全兼容（论坛宏 AFFLIMULTI 全块皆 macro，实证可用）。
-- 宏文本里一律写数字 spellID（AFFLIMULTI 同款）：语言无关，且不依赖 GSE 的
-- 名字翻译库，中文/英文客户端行为一致。

-- 会召唤战斗宠物的职业：猎人(3) / 死亡骑士(6) / 术士(9)
-- 只给这几个职业发 /petattack，否则法系每次点都会刷"你没有宠物"
local PET_CLASSES = { [3] = true, [6] = true, [9] = true }

-- v1.9.37：宏块内的宠物兜底链（AFFLIMULTI 实证套路）。
-- 外层点击宏虽然有 /petattack，但用户可能拖的是旧宏或直接点序列按钮——
-- 把"补宠 + 指挥攻击"直接写进每个宏块头部，任何点击路径都覆盖：
--   /cast [nopet,nomounted][@pet,dead,nomounted] <邪能统御>   ← 术士：下一个召唤瞬发
--   /cast [nopet,nomounted][@pet,dead,nomounted] <本专精宝宝>
--   /petattack [harm]
-- 条件保证宠物健在时这几行全部空转，一个 GCD 都不占。
local function BuildPetBlockLines(classID, petID, db)
    if not PET_CLASSES[classID] then return nil end
    if db and db.petAttack == false then return nil end
    local lines = {}
    local boost = ns.PET_BOOST and ns.PET_BOOST[classID]
    if boost and petID then
        lines[#lines + 1] = "/cast [nopet,nomounted][@pet,dead,nomounted] " .. tostring(boost)
    end
    if petID then
        lines[#lines + 1] = "/cast [nopet,nomounted][@pet,dead,nomounted] " .. tostring(petID)
    end
    lines[#lines + 1] = "/petattack [harm]"
    return lines
end

local function BuildMacroText(b, ogcd, petLines)
    local lines = {}
    -- v1.9.37：块头宠物兜底链（补宠 + 指挥攻击），宠物健在时条件全部空转
    if type(petLines) == "table" then
        for _, l in ipairs(petLines) do
            lines[#lines + 1] = l
        end
    end
    -- v1.9.46：cursor=true → 渲染 [@cursor,combat]，地面指示器法术（火焰之雨/大灾变）
    --   在连点宏里必须直接落点光标，否则会卡在选点模式吞点击
    local conds = {}
    if b.cursor then conds[#conds + 1] = "@cursor" end
    if type(b.guard) == "string" and b.guard ~= "" then conds[#conds + 1] = b.guard end
    local cond = ""
    if #conds > 0 then cond = "[" .. table.concat(conds, ",") .. ",combat] " end
    lines[#lines + 1] = "/cast " .. cond .. tostring(b.id)
    if b.fb and type(ogcd) == "table" then
        for _, id in ipairs(ogcd) do
            lines[#lines + 1] = "/cast " .. tostring(id)
        end
    end
    return table.concat(lines, "\n")
end

local function BlockToAction(b, ogcd, petLines)
    if b.kind == "item" then
        return {
            Type = "Action",
            type = "item",
            item = tostring(b.slot or "13"),
            unit = "player",
        }
    end
    if b.guard or b.fb or b.cursor then
        local act = {
            Type = b.rep and "Repeat" or "Action",
            type = "macro",
            macro = BuildMacroText(b, ogcd, petLines),
        }
        if b.rep then
            act.Interval = tostring(b.rep)
        end
        return act
    end
    if b.rep then
        return {
            Type = "Repeat",
            type = "spell",
            spell = b.id,
            Interval = tostring(b.rep),
        }
    end
    return {
        Type = "Action",
        type = "spell",
        spell = b.id,
    }
end

function ns:BuildSequenceTable(name, result)
    local _, _, classID = UnitClass("player")
    local actions = {}
    -- v1.9.37：块内宠物兜底链（/petattack + 没宝宝先补），任何点击路径都覆盖
    -- v1.9.38：块头再加 /targetenemy [noharm][dead]（AFFLIMULTI 同款）——
    --   即使走 GSE 序列按钮直点、不经过外层宏，AOE 跳怪也不用手动 retarget
    local db = ns.db or {}
    local headLines = nil
    if db.autoTarget ~= false then
        -- v1.9.38：块头换目标与外层宏同款语义——默认只在"没目标/目标死"时切，
        -- 面板勾"始终就近选怪"(alwaysRetarget) 后每次点击都切最近的怪
        if db.alwaysRetarget then
            headLines = { "/targetenemy" }
        else
            headLines = { "/targetenemy [noharm][dead]" }
        end
    end
    local petPart = BuildPetBlockLines(classID, result.pet, db)
    if petPart then
        headLines = headLines or {}
        for _, l in ipairs(petPart) do
            headLines[#headLines + 1] = l
        end
    end
    -- v1.9.41：Alt+点击 = 回蓝（术士生命分流）。宏系统无蓝量条件（现版本条件表
    -- 无 mana 数值判断），只能修饰键门控：按住 Alt 点宏即分流，平时该行空转
    local tapID = ns.MANA_TAP and ns.MANA_TAP[classID]
    if tapID and ns:KnowsSpell(tapID) then
        headLines = headLines or {}
        headLines[#headLines + 1] = string.format("/cast [mod:alt,@player] %d", tapID)
    end
    for _, b in ipairs(result.blocks) do
        table.insert(actions, BlockToAction(b, result.ogcd, headLines))
    end

    local player = UnitName("player") or "Unknown"
    local realm = type(GetRealmName) == "function" and GetRealmName() or ""

    local meta = {
        Name = name,
        SpecID = result.specID,
        ClassID = classID,
        Author = player .. (realm ~= "" and ("-" .. realm) or ""),
        Default = 1,
        GSEVersion = self:GSEVersionInfo(),
        TOC = self:TOCVersion(),
        Helplink = "",
        Help = "",
        ManualIntervention = false,
        EnforceCompatability = false,
        Dependencies = { Variables = {}, Macros = {}, Sequences = {} },
        WeakAuras = {},
    }

    local sequence = {
        MetaData = meta,
        WeakAuras = {},
        LastUpdated = date("%Y%m%d%H%M%S"),
        Versions = {
            [1] = {
                Actions = actions,
                InbuiltVariables = {},
            },
        },
    }

    -- 关键顺序：Checksum 只覆盖 Versions，而 MetaData 里存着 Checksum 本身，
    -- 所以必须先算完 Versions 再回填，避免自引用
    local checksum = self:ComputeChecksum(sequence)
    if checksum then
        meta.Checksum = checksum
    end
    sequence.MetaData = meta

    return sequence
end

-- ---------------------- 拿到 GSE 的"真身" ----------------------
--
-- 为什么要绕这一圈：
--   GSE 3.3.x 把 _G.GSE 换成了一个只有 4 个函数的只读代理
--   （API/Plugins.lua:206-219，写入被静默丢弃、__metatable 还锁了）。
--   公开路径上唯一能"当场生效"的入口是 RegisterAddon，而它内部是写死的
--       GSE.LoadPluginSequences -> GSE.ImportSerialisedSequence(seq, false)
--   （API/Plugins.lua:66）forcereplace 恒为 false，于是走到
--   AddSequenceToCollection -> OOCAddSequenceToCollection，里面判断
--       if not GSE.isEmpty(GSE.Library[classid][sequenceName]) then found = true
--       if found then GSE.GUIShowCompareWindow(...)   -- Utils.lua:114-127
--   只要同名序列已经存在，就会弹「合并 / 替换 / 重命名 / 忽略」比较窗。
--   这就是"已有的宏再用同名覆盖就显示异常"的根因，而且版本号每次都变
--   （我们原来传 tostring(time())）会让 updateflag 恒为 true，次次都弹。
--
--   真身上有 ImportSerialisedSequence(str, forcereplace, skipDialogs)，
--   传 (true, true) 会直接 PerformMergeAction("REPLACE")，版本窗、校验和窗、
--   比较窗一个都不出（Utils.lua:684-717）。
--
-- 怎么拿到真身（三条路，全都 pcall + 特征校验，取不到就退回公开代理）：
--
--   路1（主力，不需要 debug）：API/Init.lua:3 调过
--       LibStub("AceEvent-3.0"):Embed(GSE)
--   而 AceEvent-3.0.lua:99-103 的 Embed 里是 `self.embeds[target] = true`，
--   AceEvent.embeds 是一张普通表（第 24 行，非弱表、非 local），外部能枚举。
--   里面塞着所有嵌入过 AceEvent 的插件，按特征筛出 GSE 即可。
--   备用：AceEvent.events / AceEvent.messages 是 CallbackHandler 注册表，
--   结构是 events[事件名][target] = 回调，同样能遍历到 GSE。
--
--   路2：暴力扫一遍 _G。只要 GSE 的私有表有任何一处漏到全局就抓得到。
--
--   路3：debug.getupvalue —— **本机实测不可用**（/ags diag 输出
--   "debug.getupvalue：不可用"，暴雪把 debug 库砍了）。保留是为了将来放开时能用。

local function LooksLikeGSE(t)
    if type(t) ~= "table" or type(t.Library) ~= "table" then return false end
    -- 关键坑：GSE 3.3.x 把 ImportSerialisedSequence 等函数经 metatable __index 动态解析，
    -- 静态判定（type(...)=="function"）在扫描那一刻往往拿不到，导致一直 "GSE 真身：未拿到"。
    -- 改用 GSE 的"稳定静态标记"来认人：Library(表) 必存在，再凑够 2 个已知导出方法即可。
    local markers = 0
    if type(t.RegisterAddon) == "function" then markers = markers + 1 end            -- Plugins.lua:25
    if type(t.PerformMergeAction) == "function" then markers = markers + 1 end        -- Storage.lua:610
    if type(t.LoadPluginSequences) == "function" then markers = markers + 1 end       -- Plugins.lua:64
    if type(t.ImportSerialisedSequence) == "function" then markers = markers + 1 end   -- 运行时才解析出来
    return markers >= 2
end

--- 在候选容器里找 GSE。
-- 关键坑：AceEvent:Embed 写的是 self.embeds[target] = true（AceEvent-3.0.lua:103），
-- 即 GSE 表本身是 **key**，value 只是 true；CallbackHandler 的 events[事件名][target]=回调
-- 同理，target 也是 key。所以必须同时检查 k 和 v，只看 v 永远抓不到 GSE 真身
-- （这正是一直 "GSE 真身：未拿到" 的根因）。
local function ScanForGSE(tbl)
    if type(tbl) ~= "table" then return nil end
    for k, v in pairs(tbl) do
        -- GSE 表作为 key（AceEvent.embeds / events[名][target]）
        if type(k) == "table" and k ~= tbl then
            if LooksLikeGSE(k) then return k end
            if LooksLikeGSE(k.GSE) then return k.GSE end
        end
        -- GSE 表作为 value（极少数情况）
        if type(v) == "table" and v ~= tbl then
            if LooksLikeGSE(v) then return v end
            if LooksLikeGSE(v.GSE) then return v.GSE end
        end
    end
    return nil
end

function ns:GetPrivateGSE()
    if type(self._gse) == "table" then return self._gse end
    -- 全失败时也不无限重试：扫 _G 不便宜，试几次就停
    if self._gseTries and self._gseTries > 5 then return nil end
    self._gseTries = (self._gseTries or 0) + 1

    local found, via

    -- 路1：AceEvent-3.0
    if type(_G.LibStub) == "function" then
        local ok, lib = pcall(_G.LibStub, "AceEvent-3.0")
        if ok and type(lib) == "table" then
            found = ScanForGSE(lib.embeds)
            if found then
                via = "AceEvent.embeds"
            else
                for _, pair in ipairs({
                    { lib.events, "AceEvent.events" },
                    { lib.messages, "AceEvent.messages" },
                }) do
                    local src, tag = pair[1], pair[2]
                    if type(src) == "table" and type(src.events) == "table" then
                        for _, byTarget in pairs(src.events) do
                            found = ScanForGSE(byTarget)
                            if found then break end
                        end
                    end
                    if found then
                        via = tag
                        break
                    end
                end
            end
        end
    end

    -- 路2：暴力扫 _G
    if not found then
        found = ScanForGSE(_G)
        if found then via = "_G 扫描" end
    end

    -- 路3：debug（本机不可用，留作兜底）
    if not found and type(debug) == "table" and type(debug.getupvalue) == "function" then
        for _, fname in ipairs({
            "GSE_Utils_Initialize", "GSE_GUI_Initialize",
            "GSE_Options_Initialize", "GSE_LDB_Initialize",
        }) do
            local init = _G[fname]
            if type(init) == "function" then
                pcall(function()
                    for i = 1, 20 do
                        local n, v = debug.getupvalue(init, i)
                        if n == nil then break end
                        if LooksLikeGSE(v) then
                            found = v
                            return
                        end
                        if LooksLikeGSE(v.GSE) then
                            found = v.GSE
                            return
                        end
                    end
                end)
                if found then
                    via = "debug:" .. fname
                    break
                end
            end
        end
    end

    if found then
        self._gse = found
        self._gseVia = via
    end
    return found
end

--- 让刚写进去的序列当场生效，且**不弹任何 GSE 窗口**
--
-- ⚠️ 重要教训（v1.9.2）：旧版每次 gen 都递增版本号调 RegisterAddon，想借
--   「版本变化 → LoadPluginSequences」实现免重载。但 GSE 的 RegisterAddon 内部
--   写死 ImportSerialisedSequence(seq, false)，forcereplace 恒 false —— 只要库里
--   已有**同名**序列就弹「GSE: 序列比较」窗（Local vs Updated）。因 4 条事件路径
--   都会调用，表现为"每次都弹同一个窗"。
--   由于 GSE 真身（GSE.Library / DeleteSequence）在本环境不可达、无法"先删再导"，
--   改为：内容没变 -> 完全不碰 GSE（静默）；内容变了 -> 只落盘 + 提示 /reload。
--   两者都不弹窗。真身可达时仍走 forcereplace=true 的静默替换，无窗且免重载。
--
-- changed: 本次内容与上次是否不同（false 时跳过导入，彻底静默）
function ns:LiveApply(seqName, encoded, sequence, classID, changed)
    local g = self:GetPrivateGSE()

    if g then
        -- 真身路径：强制替换 + 关掉版本窗/校验和窗（forcereplace=true，不弹比较窗）
        g.ImportSerialisedSequence(encoded, true, true, nil)

        -- REPLACE 分支只改 Library 和存档，不会重建按钮，延后补一次按钮重建
        local version = sequence.Versions[sequence.MetaData.Default or 1]
        local function refresh()
            if InCombatLockdown and InCombatLockdown() then
                if type(g.UpdateSequence) == "function" then
                    g.UpdateSequence(seqName, version)
                end
                return
            end
            if type(g.OOCUpdateSequence) == "function" then
                g.OOCUpdateSequence(seqName, version)
            end
        end
        if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            C_Timer.After(0.6, function() pcall(refresh) end)
            C_Timer.After(2.0, function() pcall(refresh) end)
        end

        self.importPath = "private"
        self.liveImported = true
        self.needReload = false
        return true
    end

    -- 兜底：拿不到真身。
    -- 内容没变 -> 完全不碰 GSE（既不导入也不弹窗）；内容变了 -> 只落盘，提示 /reload。
    if not changed then
        self.importPath = "proxy-noop"
        self.liveImported = true          -- 内容本就已在库里，无需任何操作
        self.needReload = false
        return true
    end

    self.importPath = "proxy-reload"
    self.liveImported = false             -- 需要 /reload 才生效（避免弹比较窗）
    self.needReload = true
    return true
end

-- ---------------------- v1.9.33 存量迁移 ----------------------
-- v1.9.32 及以前的致命 bug：`local _, classID = UnitClass("player")` 拿到的
-- 是第二个返回值（英文类名字符串 "WARLOCK"），不是第三个（数字 9）。
-- 序列全写进了 GSESequences["WARLOCK"] 字符串键组，而 GSE 加载只按
-- 数字键 loadOneClass(currentClass) 读 —— 所以 /reload 后列表里永远没有。
-- 这里启动时把字符串键组的存量搬到数字组（同名的以数字组为准），搬完删除。
local CLASS_FILE_TO_ID = {}
do
    for id = 1, 20 do
        local ok, _, classFile = pcall(GetClassInfo, id)
        if ok and type(classFile) == "string" then
            CLASS_FILE_TO_ID[classFile] = id
        end
    end
end

function ns:MigrateClassKeyGroups()
    if type(GSESequences) ~= "table" then return 0 end
    local moved = 0
    local strKeys = {}
    for key, group in pairs(GSESequences) do
        if type(key) == "string" and type(group) == "table" then
            strKeys[#strKeys + 1] = key
        end
    end
    for _, key in ipairs(strKeys) do
        local numID = CLASS_FILE_TO_ID[key]
        if numID then
            local group = GSESequences[key]
            if type(GSESequences[numID]) ~= "table" then GSESequences[numID] = {} end
            for name, blob in pairs(group) do
                if GSESequences[numID][name] == nil then
                    GSESequences[numID][name] = blob
                    moved = moved + 1
                end
            end
        end
        -- 不管搬没搬，字符串组都是垃圾数据，删掉（无法识别的类名同样清掉）
        GSESequences[key] = nil
    end
    if moved > 0 then
        self:Print(string.format(
            "|cffFFD100已迁移 %d 条序列到正确分组|r（修复旧版写入 bug，输入 /reload 后 GSE 列表可见）", moved))
    end
    return moved
end

-- ---------------------- v1.9.33 导入串直出 ----------------------
-- gen 时把 GSE3 导出串直接弹到可复制的输入框（用户 2026-09-29 要求，
-- 参考 tools.wowlazymacros.com 的 GSE Builder）：
--   ① 存档写入异常时的备用通道；② 可粘进 GSE 导入窗人工验证结构。
StaticPopupDialogs["GSEAUTOGEN_IMPORTSTRING"] = {
    text = "|cffFFD100GSE3 导入串（%s）|r\nCtrl+A 全选 → Ctrl+C 复制 → 粘进 GSE 导入窗",
    button1 = ACCEPT,
    hasEditBox = true,
    editBoxWidth = 520,
    OnShow = function(self, data)
        data = data or self.data
        if data then
            self.editBox:SetText(data)
            self.editBox:HighlightText()
        end
    end,
    EditBoxOnEnterPressed = function(self) self:GetParent():Hide() end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function ns:ShowImportString(seqName, encoded)
    if type(StaticPopup_Show) == "function" then
        StaticPopup_Show("GSEAUTOGEN_IMPORTSTRING", seqName, nil, encoded)
    end
end

--- 按需弹出当前专精的导入串（/ags str [aoe]，v1.9.34 起不再随 gen 自动弹）
function ns:ShowImportStringFor(isAoe)
    local _, _, classID = UnitClass("player")
    local specID = type(self.GetSpecID) == "function" and self:GetSpecID() or nil
    if not specID then
        self:Print("|cffff5555读不到当前专精|r")
        return
    end
    local name = type(self.SeqName) == "function" and self:SeqName(specID, isAoe) or nil
    if not name then
        self:Print("|cffff5555当前专精没有序列名定义|r")
        return
    end
    local enc = type(GSESequences) == "table"
        and type(GSESequences[classID]) == "table"
        and GSESequences[classID][name] or nil
    if not enc then
        self:Print(string.format("|cffffaa00%s 还没生成|r，先 /ags gen", name))
        return
    end
    self:ShowImportString(name, enc)
end

-- ---------------------- 写入 ----------------------

function ns:WriteToGSE(seqName, result)
    if not self:HasGSE() then
        self:Print("|cffff5555未检测到 GSE|r（公开接口不可用），请确认 GSE 已启用")
        return false
    end
    if not (C_EncodingUtil and C_EncodingUtil.SerializeCBOR) then
        self:Print("|cffff5555当前客户端缺少序列化接口|r，无法写入")
        return false
    end
    local _, _, classID = UnitClass("player")
    if not classID then
        self:Print("读不到职业信息，稍后重试")
        return false
    end

    local sequence = self:BuildSequenceTable(seqName, result)
    local encoded, err = EncodeSequence(seqName, sequence)
    if not encoded then
        self:Print("|cffff5555" .. tostring(err) .. "|r")
        return false
    end

    -- 内容指纹：与上次写入的同名序列比对，决定是否需要触发 GSE 重新导入。
    -- 没变 -> 完全静默（不导入、不弹窗）；变了 -> 只落盘 + 提示 /reload（也不弹窗）。
    if type(GSEAutoGenDB) ~= "table" then GSEAutoGenDB = {} end
    if type(GSEAutoGenDB.sig) ~= "table" then GSEAutoGenDB.sig = {} end
    local prevSig = GSEAutoGenDB.sig[seqName]
    local changed = (prevSig ~= encoded)
    GSEAutoGenDB.sig[seqName] = encoded

    -- 1) 落盘：写进 GSE 的 SavedVariables（下次登录自动还在）
    local ok, writeErr = pcall(function()
        if type(GSESequences) ~= "table" then GSESequences = {} end
        if type(GSESequences[classID]) ~= "table" then GSESequences[classID] = {} end
        GSESequences[classID][seqName] = encoded
    end)
    if not ok then
        self:Print("|cffff5555写入失败|r：" .. tostring(writeErr))
        return false
    end

    -- 2) 当场生效：真身可达则强制替换（无窗）；不可达则按 changed 决定是否提示重载
    self.liveImported = false
    self.registerError = nil
    self.importPath = nil
    if not (InCombatLockdown and InCombatLockdown()) then
        local ok2, regErr = pcall(self.LiveApply, self, seqName, encoded, sequence, classID, changed)
        if not ok2 then
            self.registerError = tostring(regErr)
        end
    end

    self.lastWritten = seqName
    self.needReload = not self.liveImported
    return true
end

function ns:EnsureReloadHint()
    if self.liveImported then
        if self.importPath == "private" then
            self:Print("已静默替换同名序列，|cffFFD100无需重载|r，也不会弹 GSE 比较窗")
        elseif self.importPath == "proxy-noop" then
            -- 内容与上次完全一致：什么都不用做，也就不会有任何弹窗
            self:Print("序列内容未变化，|cffFFD100已是最新|r，无需重载")
        else
            self:Print("已即时导入 GSE，|cffFFD100无需重载|r，直接把宏拖到动作条即可")
        end
        return
    end
    if self.registerError then
        self:Print("|cffff5555即时导入失败|r：" .. self.registerError)
    end
    if self.importPath == "proxy-reload" then
        self:Print("序列已写入（|cffFFD100输入 /reload 生效|r）。为避免 GSE 弹「序列比较」窗，已跳过即时导入")
        return
    end
    self:Print("|cffFFD100序列已写入，输入 /reload 生效|r（战斗中不能建按钮，脱战或重载后可用）")
end

--- 诊断：报告当前走的是哪条写入路径
function ns:ImportDiag()
    local g = self:GetPrivateGSE()
    self:Print("—— 写入路径诊断 ——")
    self:Print("debug.getupvalue：" ..
        ((type(debug) == "table" and type(debug.getupvalue) == "function") and "|cff00ff00可用|r" or "|cffff5555不可用|r"))
    self:Print("_G.GSE_Utils_Initialize：" .. type(_G.GSE_Utils_Initialize))
    self:Print("GSE 真身：" .. (g and "|cff00ff00已拿到|r（静默替换路径）" or "|cffffaa00未拿到|r（只读代理不可达；改为「内容不变则静默、变了则提示 /reload」，均不弹比较窗）"))
    if g then self:Print("拿到方式：" .. tostring(self._gseVia or "?")) end
    if g then
        local _, _, classID = UnitClass("player")
        local lib = type(g.Library) == "table" and g.Library[classID] or nil
        local n = 0
        if type(lib) == "table" then
            for name in pairs(lib) do
                if type(name) == "string" and name:find("^AGS_") then n = n + 1 end
            end
        end
        self:Print(string.format("GSE 库里现有 %d 条 AGS_ 序列", n))
    end
    self:Print("上次写入路径：" .. tostring(self.importPath or "无"))
end

-- ---------------------- 外部 /click 宏（单体 / AOE 两条独立宏） ----------------------
--
-- 教训：早先按专精名各建一个宏（AGS痛苦/AGS恶魔学识/AGS毁灭），宏位很快堆满；
-- 后来改成"单宏 + [mod:shift] 切 AOE"。用户 2026-09-28 要求「单体 / AOE 分两个按键」，
-- 现在出两条独立宏，各自拖到动作条、各自绑键，互不干扰：
--     AGS单体  -> /click [nochanneling,spec:N] AGS_XXX_SOLO
--     AGS_AOE  -> /click [nochanneling,spec:N] AGS_XXX_AOE
-- 不管当前什么专精，只有匹配的那一行会执行；之后永远只 EditMacro，不再重复 CreateMacro。

local MACRO_SOLO  = "AGS单体"
local MACRO_AOE   = "AGS_AOE"
local MACRO_ICON  = "INV_Misc_QuestionMark"
-- 旧版单一宏（v1.2~v1.7.0），已废弃，升级时自动删掉
local MACRO_LEGACY = "AGS输出"

ns.MACRO_NAME = MACRO_SOLO .. " / " .. MACRO_AOE

local function IsKeyDownMode()
    if C_CVar and type(C_CVar.GetCVar) == "function" then
        local v = PCall(C_CVar.GetCVar, "ActionButtonUseKeyDown")
        return v == "1"
    end
    return false
end

-- （PET_CLASSES 已上移到宏块渲染段，v1.9.37 供 BuildPetBlockLines 使用）

local function SpecIDByIndex(i)
    if C_SpecializationInfo and type(C_SpecializationInfo.GetSpecializationInfo) == "function" then
        local info = PCall(C_SpecializationInfo.GetSpecializationInfo, i)
        if type(info) == "table" then return info.id end
        if type(info) == "number" then return info end
    end
    if type(GetSpecializationInfo) == "function" then
        local id = PCall(GetSpecializationInfo, i)
        if type(id) == "number" then return id end
    end
    return nil
end

--- 没宠物时自动召唤（上游 SCG 三条宏头都这么写）
--
-- 产出形如：
--     /cast [nopet,nomounted,spec:1,spec:3] 召唤地狱猎犬
--     /cast [nopet,nomounted,spec:2] 召唤恶魔卫士
-- 同名宠物合并成一行（术士的痛苦 / 毁灭都是地狱猎犬）。
--
-- 三个安全设计：
--   1) [nopet]     —— 只有"完全没有宠物"才触发，绝不会顶掉你手动选的宠物；
--   2) [nomounted] —— 骑坐骑时不去折腾；
--   3) 名字取不到（ID 对不上 / 客户端语言异常）就整行不写，绝不写一条会报错的 /cast。
-- 玩"牺牲魔典"这类故意不带宠物流派的，把面板上的开关关掉即可。
local function BuildPetSummonLines(db)
    local out = {}
    if db.autoPet == false then return out end

    -- 按宠物 ID 归并专精序号，避免同一种宠物写好几行
    local byPet, order = {}, {}
    for i = 1, 4 do
        local specID = SpecIDByIndex(i)
        local petID = specID and ns.PET_SPELL and ns.PET_SPELL[specID]
        if petID then
            if not byPet[petID] then
                byPet[petID] = {}
                order[#order + 1] = petID
            end
            local t = byPet[petID]
            t[#t + 1] = i
        end
    end

    for _, petID in ipairs(order) do
        local name = ns:SpellName(petID)
        -- ns:SpellName 取不到名字时返回 "#<id>"，那种情况直接跳过
        if type(name) == "string" and name ~= "" and name:sub(1, 1) ~= "#" then
            local conds = { "nopet", "nomounted" }
            for _, i in ipairs(byPet[petID]) do
                conds[#conds + 1] = "spec:" .. i
            end
            out[#out + 1] = "/cast [" .. table.concat(conds, ",") .. "] " .. name
        end
    end
    return out
end

-- 给 Core 的 /ags pet 自检用：把"实际会写进宏的那几行"暴露出去，
-- 省得用户去法术书里一个个 hover 核对
ns.BuildPetSummonLines = BuildPetSummonLines
ns.SpecIDByIndex = SpecIDByIndex

--- 当前职业各专精序号(1..4) -> 单体序列表 / AOE 序列表
-- 返回两个表，元素是已经写进 GSESequences 的序列名
function ns:CollectAGSBySpecIndex()
    local _, _, classID = UnitClass("player")
    local solo, aoe = {}, {}
    if type(GSESequences) ~= "table" or type(GSESequences[classID]) ~= "table" then
        return solo, aoe
    end
    local have = GSESequences[classID]

    for i = 1, 4 do
        local specID = SpecIDByIndex(i)
        if specID and ns.SEQ_NAME[specID] then
            local s = ns:SeqName(specID, false)
            local a = ns:SeqName(specID, true)
            if have[s] then solo[i] = s end
            if have[a] then aoe[i] = a end
        end
    end
    return solo, aoe
end

local function ClickLine(down, cond, seq)
    if down then
        -- 开了 ActionButtonUseKeyDown 必须带 LeftButton t，否则按了不触发
        return "/click " .. cond .. ",button:1] " .. seq .. " LeftButton t; " .. cond .. "] " .. seq
    end
    return "/click " .. cond .. "] " .. seq
end

--- 生成某条宏（单体/aoe 由 isAoe 决定）的正文；返回 正文, 覆盖的专精数
--
-- 为什么 AOE 只能靠"另一条独立宏"而不是战斗中自动判断敌人数：
--   1) GSE 的 If 块在 CompileTemplate 里求值一次就写进 GSE.SequencesExec，运行时不重新计算；
--   2) 暴雪宏条件里根本没有"敌人数"这一项（没有 [aoe] / [enemies>=N]）；
--   3) 战斗中改安全按钮属性是受保护操作，绕不过去。
local function BuildBodyFor(isAoe)
    local solo, aoe = ns:CollectAGSBySpecIndex()
    local _, _, classID = UnitClass("player")
    local db = ns.db or {}

    local lines = { "#showtooltip" }

    -- 没宠物先召唤：上游 SCG 三条宏都把这行放在 #showtooltip 后面第一句。
    -- 顺序很重要——它在 /click 之前，才能在序列技能还都在冷却时先把宠物叫出来。
    local petLines = BuildPetSummonLines(db)
    for _, l in ipairs(petLines) do lines[#lines + 1] = l end

    -- 修饰键技能行（v1.9.27，学自 ORBALISK_PW_4.3）：打断/泄怒/位移不占循环步数，
    -- 每次点宏都会重新执行宏头 → 按住修饰键随时生效，不管循环走到哪一步。
    -- 与恶魔之箭同款 [mod] + /stopmacro 模式：按住的那一下只放修饰键技能，不动循环。
    -- 没配的职业 / 面板关掉 / 没学会 / 名字取不到 → 整段不写，绝不写会报错的行。
    if db.modKeys ~= false then
        for _, row in ipairs(ns.MODKEY_ROWS and ns.MODKEY_ROWS[classID] or {}) do
            if ns:KnowsSpell(row.id) then
                local mname = ns:SpellName(row.id)
                if type(mname) == "string" and mname:sub(1, 1) ~= "#" then
                    lines[#lines + 1] = "/cast [mod:" .. row.mod .. "] " .. mname
                    lines[#lines + 1] = "/stopmacro [mod:" .. row.mod .. "]"
                end
            end
        end
    end

    -- 恶魔之箭（264178）：恶魔学识按住 Shift 手动放（图标高亮 = 恶魔之核触发、可瞬发时）。
    -- 放在外层 /click 宏头，用 [mod:shift] + /stopmacro 拦截，绝不占用 GSE 序列步数，
    -- 不会打乱 GCD 节奏；与上游 SCG_DEM 原文宏头一致。
    -- 只对恶魔学识生效（按 spec 索引过滤），其它专精/职业（含痛苦/毁灭）按条件自然不触发。
    if db.demonboltShift ~= false and classID == 9 then
        local demIdx = nil
        for i = 1, 4 do
            if SpecIDByIndex(i) == 266 then demIdx = i; break end
        end
        if demIdx then
            local dbName = ns:SpellName(264178)
            if type(dbName) == "string" and dbName:sub(1, 1) ~= "#" then
                lines[#lines + 1] = "/cast [mod:shift,spec:" .. demIdx .. "] " .. dbName
                lines[#lines + 1] = "/stopmacro [mod:shift,spec:" .. demIdx .. "]"
            end
        end
    end

    -- 自动选中最近的敌人：只在"当前目标不是敌人 / 已死亡"时才换目标
    if db.autoTarget ~= false then
        if db.alwaysRetarget then
            lines[#lines + 1] = "/targetenemy"
        else
            lines[#lines + 1] = "/targetenemy [noharm][dead]"
        end
    end

    -- 宠物自动攻击（只发宠物职业）
    if db.petAttack ~= false and PET_CLASSES[classID] then
        lines[#lines + 1] = "/petattack [harm]"
    end

    -- 自身自动攻击：近战 / 猎人是实打实的白字伤害，法系无害
    if db.startAttack ~= false then
        lines[#lines + 1] = "/startattack [@target,harm]"
    end

    local down = IsKeyDownMode()
    local tbl = isAoe and aoe or solo
    local n = 0
    for i = 1, 4 do
        local seq = tbl[i]
        if seq then
            n = n + 1
            lines[#lines + 1] = ClickLine(down, "[nochanneling,spec:" .. i .. "]", seq)
        end
    end

    -- 一条都没有时给个不会报错的占位，避免宏是空的
    if n == 0 then
        lines[#lines + 1] = "/run print('AGS: 还没生成" .. (isAoe and "AOE" or "单体") .. "序列，输入 /ags gen')"
    end
    return table.concat(lines, "\n"), n
end

local function MacroIndex(name)
    if type(GetMacroIndexByName) == "function" then
        return GetMacroIndexByName(name) or 0
    end
    return 0
end

--- 是否还能再建宏。返回 ok, 说明文案
-- 关键：CreateMacro 在"宏位已满"时会触发暴雪系统弹窗（"宏数量已达上限"）。
-- 我们的 UpdateMacro 有 4 条事件路径会调用，若不管住就会反复弹。这里先探测再决定，
-- 满了直接放弃创建（只打一行聊天提示），绝不触发系统窗。
local function CanCreateMoreMacros()
    if type(GetNumMacros) ~= "function" then return true, nil end
    local numAccount, numChar = GetNumMacros()
    numAccount, numChar = numAccount or 0, numChar or 0
    local maxAccount = _G.MAX_ACCOUNT_MACROS or 120
    local maxChar = _G.MAX_CHARACTER_MACROS or 18
    if numAccount >= maxAccount then
        return false, string.format("账号宏位已满（%d/%d）", numAccount, maxAccount)
    end
    if numChar >= maxChar then
        return false, string.format("角色宏位已满（%d/%d）", numChar, maxChar)
    end
    return true, nil
end

local function RemoveMacroIfExists(name)
    local idx = MacroIndex(name)
    if idx > 0 and type(DeleteMacro) == "function" then
        pcall(DeleteMacro, idx)
    end
end

--- 新建或更新一条宏（不重复建）。返回 ok, 覆盖数, 是否新建
function ns:WriteOneMacro(name, isAoe)
    if InCombatLockdown and InCombatLockdown() then return false, 0, false end
    if type(CreateMacro) ~= "function" then return false, 0, false end

    local body, n = BuildBodyFor(isAoe)
    local idx = MacroIndex(name)

    -- 已存在 -> 只改内容，绝不新建（永不消耗宏位）
    if idx > 0 and type(EditMacro) == "function" then
        local ok = pcall(EditMacro, idx, name, MACRO_ICON, body, 1)
        return ok == true, n, false
    end

    -- 不存在 -> 先确认还有宏位，再创建；满了直接放弃（不弹系统窗）
    local canCreate, why = CanCreateMoreMacros()
    if not canCreate then
        ns.macroFullReason = why
        return false, n, false
    end

    local ok = pcall(CreateMacro, name, MACRO_ICON, body, 1)
    if not ok then
        ok = pcall(CreateMacro, name, MACRO_ICON, body, nil)
    end
    return ok == true, n, true
end

--- 往宏里写一段"占位正文"（不删宏！）。
-- 用途：某条宏当前没有内容可写时（例如 AOE 开关关掉、或该专精还没生成 AOE 序列），
-- 早期做法是 DeleteMacro 把宏删掉；但宏一旦被删，玩家绑在动作条上的**键位就变空**，
-- 而且不会自动恢复（暴雪把按键绑定记在动作条槽位上，删宏等于把槽位内容清空）。
-- 所以这里改成"保留宏对象、只换正文"：EditMacro 保持同一个宏，键位不受任何影响。
-- 返回值与 WriteOneMacro 对齐：ok, n(=0), 是否新建
function ns:WritePlaceholderMacro(name, hint)
    if InCombatLockdown and InCombatLockdown() then return false, 0, false end
    if type(CreateMacro) ~= "function" then return false, 0, false end

    hint = hint or "暂无内容"
    -- 用 #showtooltip 保证图标/提示正常，正文只做一次安全打印，不含任何 /click，绝不会误触发
    -- 注意：hint 里可能含单引号，Lua 长括号 [[ ]] 里也不能出现 ]]，这里统一做转义保护
    local safe = tostring(hint):gsub("'", "\\'"):gsub("%]%]", "] ]")
    local body = "#showtooltip\n/run print('AGS: " .. safe .. "')"

    local idx = MacroIndex(name)

    -- 已存在 -> 只改正文，绝不删除、绝不新建（键位 100% 保住）
    if idx > 0 and type(EditMacro) == "function" then
        local ok = pcall(EditMacro, idx, name, MACRO_ICON, body, 1)
        return ok == true, 0, false
    end

    -- 不存在 -> 这时才需要新建，同样先确认宏位
    local canCreate, why = CanCreateMoreMacros()
    if not canCreate then
        ns.macroFullReason = why
        return false, 0, false
    end

    local ok = pcall(CreateMacro, name, MACRO_ICON, body, 1)
    if not ok then
        ok = pcall(CreateMacro, name, MACRO_ICON, body, nil)
    end
    return ok == true, 0, true
end

--- 维护两条宏：**两条都永不删除**（保证你绑在动作条上的键位永不失效）。
-- 没有 AOE 序列 / 关了 AOE 开关时，AGS_AOE 写一段占位内容，而不是删宏。
-- （旧版会 RemoveMacroIfExists(MACRO_AOE)，一旦删宏，绑定的键位就变空且不会自动恢复。）
-- 返回 ok, 覆盖专精数, 是否新建过任一宏, why
function ns:UpdateMacro()
    if InCombatLockdown and InCombatLockdown() then return false, 0, false, "战斗中" end
    if type(CreateMacro) ~= "function" then return false, 0, false, "无 CreateMacro" end

    local db = ns.db or {}

    -- 旧版单宏（AGS输出）已废弃，删掉（它曾含 /click AGS_，会被 CleanupLegacyMacros 识别，
    -- 但升级当次还没跑到 cleanup，这里直接兜底删，确保不残留一个空壳按键）
    RemoveMacroIfExists(MACRO_LEGACY)

    local solo, aoe = self:CollectAGSBySpecIndex()
    local covered = 0
    for i = 1, 4 do
        if solo[i] or aoe[i] then covered = covered + 1 end
    end

    local okS, _, madeS = self:WriteOneMacro(MACRO_SOLO, false)
    local madeA = false

    local hasAoe = false
    for i = 1, 4 do if aoe[i] then hasAoe = true; break end end

    if db.aoe ~= false and hasAoe then
        local _, _, madeA2 = self:WriteOneMacro(MACRO_AOE, true)
        madeA = madeA2
    else
        -- 不删宏！改成写占位，保住用户的键位
        local _, _, madeA2 = self:WritePlaceholderMacro(MACRO_AOE,
            (db.aoe == false)
                and "AOE 版已在面板关闭（开关打开后重新生成即可）"
                or "还没生成 AOE 序列（当前专精切过去会自动补齐）")
        madeA = madeA2
    end

    -- 宏位满时只在聊天框提示一次（4 条事件路径都会走 UpdateMacro，避免刷屏）
    if not okS and self.macroFullReason then
        if not self.macroFullWarned then
            self.macroFullWarned = true
            self:Print("|cffffaa00宏位已满，无法新建|r（" .. self.macroFullReason ..
                "）。删掉几个不用的宏后输入 /ags macro 重试；序列本身已生成，可手动 /click 使用")
        end
        return false, covered, false, "宏位已满：" .. self.macroFullReason
    end

    return okS == true, covered, (madeS or madeA), nil
end

--- 清掉 v1.2 及以前按专精建的旧宏（只删我们自己造的：正文含 "/click AGS_"）
-- 注意：角色宏索引是 1..numChar，账号宏是另一个独立池（索引 1..numAccount），
-- 二者不能用同一个下标混读。旧版写成 `maxAccount + numChar` 当上界会大量越界，
-- 既可能读到别人的宏、也可能误删。这里严格只扫角色宏池，且以实际数量为界。
function ns:CleanupLegacyMacros()
    if type(GetNumMacros) ~= "function" or type(DeleteMacro) ~= "function" then return 0 end
    local numAccount, numChar = GetNumMacros()
    numChar = numChar or 0
    local maxChar = _G.MAX_CHARACTER_MACROS or 18
    if numChar > maxChar then numChar = maxChar end
    if numChar <= 0 then return 0 end

    local victims = {}
    -- 只扫角色宏：索引 1..numChar（GetMacroInfo 的 index 就是角色宏索引）
    for i = 1, numChar do
        local name, _, body = GetMacroInfo(i)
        if type(name) == "string"
            and name ~= MACRO_SOLO and name ~= MACRO_AOE
            and name:sub(1, 3) == "AGS"
            and type(body) == "string" and body:find("/click AGS_", 1, true) then
            table.insert(victims, i)
        end
    end
    local n = 0
    for k = #victims, 1, -1 do
        if pcall(DeleteMacro, victims[k]) then n = n + 1 end
    end
    return n
end

-- ---------------------- 校验和自检 ----------------------
-- 不依赖任何外部样本：自己造一条序列算出校验和，再让 GSE 的官方函数验一遍。
-- 结论直接打聊天框，用来确认算法抄得对不对。

function ns:ChecksumSelfTest()
    self:Print("—— 校验和自检 ——")
    local projectID = _G.WOW_PROJECT_ID or 1
    local expansion = _G.GetExpansionLevel and _G.GetExpansionLevel() or 0
    self:Print(string.format("WOW_PROJECT_ID=%s  GetExpansionLevel()=%s", tostring(projectID), tostring(expansion)))
    self:Print("bit 库：" .. (type(bit) == "table" and type(bit.bxor) == "function" and "|cff00ff00可用|r" or "|cffff5555不可用|r"))

    local probe = {
        Versions = {
            [1] = {
                Actions = {
                    { Type = "Action", type = "spell", spell = 686 },
                    { Type = "Repeat", type = "spell", spell = 172, Interval = "5" },
                },
                InbuiltVariables = {},
            },
        },
    }
    local mine = self:ComputeChecksum(probe)
    if not mine then
        self:Print("|cffff5555本地算法跑不通|r（多半是 bit 库不可用），校验和会留空让 GSE 正常提示")
        return
    end
    self:Print("本地算出：" .. mine)

    local inner = _G.GSE
    local official
    for _, name in ipairs({ "GSE", "GSE_GUI", "GSE_Utils" }) do
        local t = _C and _C[name]
        if type(t) == "table" and type(t.ComputeSequenceChecksum) == "function" then
            official = t
            self:Print("找到官方算法来源：" .. name)
            break
        end
    end

    if not official then
        self:Print("|cffffaa00拿不到 GSE 的官方算法做对拍|r（代理表不含它）")
        self:Print("请去游戏里把它导出的序列 Checksum 值发我，即可反推验证")
        return
    end

    local theirs = official.ComputeSequenceChecksum(probe)
    self:Print("GSE 官方：" .. tostring(theirs))
    if theirs == mine then
        self:Print("|cff00ff00一致！|r 生成的序列不会再弹校验和警告")
    else
        self:Print("|cffff5555不一致|r，需要按官方值修正盐值/序列化方式")
    end
end

-- ---------------------- 查询 / 清理 ----------------------

function ns:ListGenerated()
    local out = {}
    if type(GSESequences) ~= "table" then return out end
    for classID, seqs in pairs(GSESequences) do
        if type(seqs) == "table" then
            for name in pairs(seqs) do
                if type(name) == "string" and name:find("^AGS_") then
                    table.insert(out, string.format("%s（职业 %s）", name, tostring(classID)))
                end
            end
        end
    end
    table.sort(out)
    return out
end

function ns:WipeGenerated()
    local n = 0
    if type(GSESequences) == "table" then
        for _, seqs in pairs(GSESequences) do
            if type(seqs) == "table" then
                for name in pairs(seqs) do
                    if type(name) == "string" and name:find("^AGS_") then
                        seqs[name] = nil
                        n = n + 1
                    end
                end
            end
        end
    end
    return n
end

--- 只清 v1.6 及以前的旧命名（AGS_AFF / AGS_DEM / AGS_DES），
-- 保留带 _SOLO / _AOE 后缀的新序列。/ags wipe 会连新的一起删，别乱用。
function ns:WipeLegacySequences()
    local n = 0
    if type(GSESequences) ~= "table" then return 0 end
    for _, seqs in pairs(GSESequences) do
        if type(seqs) == "table" then
            local victims = {}
            for name in pairs(seqs) do
                if type(name) == "string"
                    and name:find("^AGS_")
                    and not name:find(ns.SOLO_SUFFIX .. "$")
                    and not name:find(ns.AOE_SUFFIX .. "$") then
                    table.insert(victims, name)
                end
            end
            for _, name in ipairs(victims) do
                seqs[name] = nil
                n = n + 1
            end
        end
    end
    return n
end
