-- ==========================================================
-- GSEAutoGen - Core.lua  (v1.8)
-- 术士三系：登录 / 切专精自动生成一套 GSE 输出序列，并建好 /click 宏
-- 命令：/ags gen | list | wipe | debug | diag | pet | cs | macro | legacy | cleanup
--       /ags 或 /ags ui 打开面板
-- ==========================================================

local ADDON_NAME, ns = ...

local DEFAULTS = {
    auto     = true,   -- 登录 / 切专精时自动生成
    trinket  = true,   -- 只插主动饰品
    filter   = true,   -- 过滤掉你没学会的技能
    makeMacro = true,  -- 顺手建一个可拖到动作条的宏
    quiet    = false,  -- 关掉自动生成时的提示
    max      = 60,     -- 块数上限
    aoe          = true,   -- 每个专精额外出一条 AOE 版（与单体是两条独立宏：AGS单体 / AGS_AOE）
    autoTarget   = true,   -- 宏自动选中最近的敌人
    petAttack    = true,   -- 宠物自动攻击（术士/猎人/DK）
    autoPet      = true,   -- 没宠物时自动召唤（上游 SCG 宏头同款）
    demonboltShift = true,  -- 恶魔学识：按住 Shift 手动放恶魔之箭（瞬发恶魔之核时用，外层宏头拦截）
    modKeys     = true,   -- 修饰键技能行写进外层宏头（Shift=打断 等，按职业配置，v1.9.27）
    startAttack  = true,   -- 自身自动攻击（近战 / 猎人有意义，法系无害）
    cleanedV17   = false,  -- 是否已清掉 v1.6 及以前的旧命名序列（只做一次）
    learnPassive = true,   -- 后台学习：平时战斗自动累积官方推荐数据（Learner.lua）
    learned = false,       -- 学习数据（按专精分桶的表）。⚠️ 必须列进白名单：
                           -- InitDB 会删除所有不在 DEFAULTS 里的键，v1.9.8~1.9.22
                           -- 因漏列导致学习数据每次 /reload 被整键清空（v1.9.23 修复）
                           -- false = 占位，Learner.Bucket 检测到非 table 会按需重建
    showMinimap  = true,      -- 小地图图标
    minimapAngle = 220,       -- 图标角度（度）
    posX     = 0,      -- 面板位置
    posY     = 60,
    anchorPoint = "CENTER",
    relPoint    = "CENTER",
}

-- ---------------------- 基础 ----------------------

function ns:Print(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[GSE自动序列]|r " .. tostring(msg))
    end
end

--- 12.x secret values 防护：被加密的数值不能做算术/不能存 SavedVariables。
-- 注意底层全局是小写 issecretvalue（大写 IsSecretValue 不存在，曾因此防护失效）。
function ns:Unsecret(v, fallback)
    if v == nil then return fallback end
    if _G.issecretvalue and issecretvalue(v) then return fallback end
    return v
end

function ns:InitDB()
    if type(GSEAutoGenDB) ~= "table" then GSEAutoGenDB = {} end
    local db = GSEAutoGenDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    for k in pairs(db) do
        if DEFAULTS[k] == nil then db[k] = nil end
    end
    self.db = db
end

-- ---------------------- 生成 ----------------------

function ns:Generate(quiet)
    if not self.db then self:InitDB() end

    if not ns:HasGSE() then
        if not quiet then
            self:Print("|cffff5555GSE 还没就绪|r（公开接口拿不到），请确认 GSE 已启用并勾选加载")
        end
        return false
    end

    local specID = ns:GetSpecID()
    if not specID then
        if not quiet then self:Print("读不到当前专精，进游戏后再试") end
        return false
    end

    local opts = {
        trinket = self.db.trinket,
        filter = self.db.filter,
        max = self.db.max,
    }
    local result, why = ns:BuildSequence(specID, opts)
    if not result then
        if not quiet then self:Print(why or "该专精暂无模板") end
        return false
    end

    if not ns:WriteToGSE(result.seqName, result) then return false end
    ns.lastResult = result

    -- 一次性迁移：v1.6 及以前的 AGS_AFF / AGS_DEM / AGS_DES 已经没人引用，
    -- 清掉它们（只删不带 _SOLO / _AOE 后缀的，绝不碰新序列）
    if self.db.cleanedV17 ~= true then
        self.db.cleanedV17 = true
        local removed = ns:WipeLegacySequences()
        if removed > 0 then
            self:Print(string.format(
                "已清理 %d 条旧命名序列（AGS_AFF / AGS_DEM / AGS_DES），现统一用 %s / %s 后缀",
                removed, ns.SOLO_SUFFIX, ns.AOE_SUFFIX
            ))
        end
    end

    -- AOE 变体：同一套模板 + 多目标技能，名字带 _AOE
    ns.lastAoeResult = nil
    if self.db.aoe ~= false then
        local a = {}
        for k, v in pairs(opts) do a[k] = v end
        a.aoe = true
        local aoeRes = ns:BuildSequence(specID, a)
        if aoeRes then
            ns:WriteToGSE(aoeRes.seqName, aoeRes)
            ns.lastAoeResult = aoeRes
        end
    end

    -- 顺手把本职业其它专精的序列也补齐（兜底生成，真切过去会再精修一次），
    -- 这样单一宏里的 [spec:N] 分流三系都有东西可点
    local prefilled = ns:PrefillOtherSpecs(specID)

    -- 只维护"一个"宏：已存在就改内容，绝不重复建
    if self.db.makeMacro then
        local made, cover, created, why = ns:UpdateMacro()
        if not quiet then
            if made then
                if created then
                    self:Print(string.format(
                        "已建宏 |cffFFD100%s|r（覆盖 %d 个专精），拖到动作条即可",
                        ns.MACRO_NAME, cover
                    ))
                end
            elseif why then
                self:Print("|cffffaa00宏未更新|r：" .. why .. "，脱战后输入 /ags macro 补建")
            end
        end
    end

    if not quiet then
        local s = result.scan or {}
        self:Print(string.format(
            "已生成 |cffFFD100%s|r（%s）：共 %d 块",
            result.seqName, result.label, #result.blocks
        ))
        if ns.lastAoeResult then
            self:Print(string.format(
                "       |cffFFD100%s|r（%s）：共 %d 块 —— 单体 / AOE 是两条独立宏（AGS单体 / AGS_AOE），各拖一个到动作条",
                ns.lastAoeResult.seqName, ns.lastAoeResult.label, #ns.lastAoeResult.blocks
            ))
        end
        if prefilled > 0 then
            self:Print(string.format("同时补齐了其它 %d 个专精的序列（切过去会自动精修）", prefilled))
        end

        if result.fillerRep then
            self:Print(string.format(
                "急速 %.1f%% → 填充「%s」每 %d 步一次",
                s.haste or 0, ns:SpellName(result.fillerID), result.fillerRep
            ))
        else
            self:Print(string.format(
                "属性：急速 %.1f%% | 暴击 %.1f%% | 精通 %.1f%% | 全能 %.1f%%",
                s.haste or 0, s.crit or 0, s.mastery or 0, s.vers or 0
            ))
        end

        local bits = {}
        if (s.tierCount or 0) >= 2 then
            table.insert(bits, string.format("套装 %d 件", s.tierCount))
        end
        if result.trinket > 0 then
            table.insert(bits, string.format("主动饰品 %d 个", result.trinket))
        end
        if result.optional > 0 then
            table.insert(bits, string.format("天赋技能 +%d", result.optional))
        end
        if (result.mobility or 0) > 0 then
            table.insert(bits, string.format("位移技 +%d", result.mobility))
        end
        if (result.defense or 0) > 0 then
            table.insert(bits, string.format("防御编织 %d 项常驻", result.defense))
        end
        if type(result.ogcd) == "table" and #result.ogcd > 0 then
            local names = {}
            for _, id in ipairs(result.ogcd) do
                names[#names + 1] = ns:SpellName(id)
            end
            table.insert(bits, "off-GCD 兜底行：" .. table.concat(names, "/"))
        end
        if result.learned then
            table.insert(bits, string.format(
                "官方实测适配（%d 样本，core 重排 %d，自动补 %d）",
                result.learned.samples or 0,
                result.learned.reordered or 0,
                result.learned.added or 0))
        end
        if #bits > 0 then
            self:Print("适配：" .. table.concat(bits, " | "))
        end

        -- 修饰键行说明（v1.9.27）：外层宏头里"按住即发"的技能，避免用户不知道有这些行
        if self.db.modKeys ~= false then
            local _, _, classID2 = UnitClass("player")
            local rows = ns.MODKEY_ROWS and ns.MODKEY_ROWS[classID2] or nil
            if rows and #rows > 0 then
                local parts = {}
                for _, row in ipairs(rows) do
                    if ns:KnowsSpell(row.id) then
                        local key = row.mod:sub(1, 1):upper() .. row.mod:sub(2)
                        local what = row.note or ns:SpellName(row.id)
                        parts[#parts + 1] = key .. "=" .. what
                    end
                end
                if #parts > 0 then
                    self:Print("修饰键（按住即发，不占循环）：" .. table.concat(parts, " | "))
                end
            end
        end

        if result.dropped > 0 then
            self:Print(string.format("已跳过 %d 个你没学会的技能", result.dropped))
        end
        if s.apiSuspect then
            self:Print("|cffffaa00技能查询接口返回异常|r，已按原样保留全部技能")
        end

        ns:EnsureReloadHint()
    end

    self.lastSpecID = specID
    if ns.RefreshUI then ns:RefreshUI() end
    return true
end

--- 面板上"某专精单独生成"用：非当前专精走 force 兜底
function ns:GenerateSpec(specID)
    if not ns.db then ns:InitDB() end
    if not ns:HasGSE() then
        ns:Print("|cffff5555GSE 还没就绪|r，进游戏后再试")
        return false
    end
    local result, why = ns:BuildSequence(specID, {
        trinket = ns.db.trinket,
        filter = ns.db.filter,
        max = ns.db.max,
        force = (specID ~= ns:GetSpecID()),
    })
    if not result then
        ns:Print(why or "该专精暂无模板")
        return false
    end
    if not ns:WriteToGSE(result.seqName, result) then return false end
    ns.lastResult = result

    ns.lastAoeResult = nil
    if ns.db.aoe ~= false then
        local aoeRes = ns:BuildSequence(specID, {
            trinket = ns.db.trinket, filter = ns.db.filter, max = ns.db.max,
            force = (specID ~= ns:GetSpecID()), aoe = true,
        })
        if aoeRes then
            ns:WriteToGSE(aoeRes.seqName, aoeRes)
            ns.lastAoeResult = aoeRes
        end
    end

    if ns.db.makeMacro then ns:UpdateMacro() end
    ns:Print(string.format("已生成 %s（%s）：共 %d 块%s",
        result.seqName, result.label, #result.blocks,
        result.forced and "（非当前专精，兜底生成）" or ""))
    if ns.lastAoeResult then
        ns:Print(string.format("       %s：共 %d 块", ns.lastAoeResult.seqName, #ns.lastAoeResult.blocks))
    end
    ns:EnsureReloadHint()
    if ns.RefreshUI then ns:RefreshUI() end
    return true
end

--- 给还没有序列的其它专精兜底生成一份（force 模式，不做技能过滤）
-- 注意：只补**本职业**的专精。以前遍历 AllTemplateSpecs()（全局），
-- 会拿术士/战士等"别的职业"的模板去 force 生成，还可能触发无模板分支的误导提示。
function ns:PrefillOtherSpecs(currentSpecID)
    local _, _, classID = UnitClass("player")
    if not classID then return 0 end
    if type(GSESequences) ~= "table" then return 0 end
    if type(GSESequences[classID]) ~= "table" then GSESequences[classID] = {} end

    local n = 0
    local wantAoe = (self.db and self.db.aoe) ~= false
    -- ClassTemplateSpecs 只返回本职业有模板的专精（职业识别不到时退回全部，安全）
    for _, specID in ipairs(ns:ClassTemplateSpecs()) do
        if specID ~= currentSpecID then
            local base = {
                force = true,
                trinket = self.db and self.db.trinket,
                max = self.db and self.db.max,
            }
            local variants = { false }
            if wantAoe then variants = { false, true } end
            for _, isAoe in ipairs(variants) do
                local name = ns:SeqName(specID, isAoe)
                if name and not GSESequences[classID][name] then
                    local o = {}
                    for k, v in pairs(base) do o[k] = v end
                    o.aoe = isAoe
                    local r = ns:BuildSequence(specID, o)
                    if r and ns:WriteToGSE(name, r) then n = n + 1 end
                end
            end
        end
    end
    return n
end

--- 对外统一入口：任何异常都兜住并打到聊天框，绝不再出现"什么都不显示"
function ns:SafeGenerate(quiet)
    local ok, err = pcall(ns.Generate, ns, quiet)
    if not ok then
        self.lastError = tostring(err)
        self:Print("|cffff5555生成出错|r：" .. self.lastError)
        return false
    end
    return err -- Generate 的返回值
end

-- ---------------------- 等待 GSE 就绪 ----------------------
-- GSE 在 PLAYER_ENTERING_WORLD 才把序列装载起来（Events.lua:1356），
-- 比 ADDON_LOADED 晚得多，所以不能用 ADDON_LOADED 当就绪信号。
local pendingQuiet = true

local function TryGenerateWithRetry(attempt)
    if not ns.db or not ns.db.auto then return end
    if ns:HasGSE() then
        ns:SafeGenerate(pendingQuiet)
        return
    end
    if not ns.retryAnnounced then
        ns.retryAnnounced = true
        if not pendingQuiet then ns:Print("正在等 GSE 加载完成…") end
    end
    if attempt < 30 then
        C_Timer.After(1, function() TryGenerateWithRetry(attempt + 1) end)
    elseif not pendingQuiet then
        ns:Print("|cffff5555等了 30 秒仍未检测到 GSE|r，输入 /ags debug 看详情")
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("UNIT_POWER_FREQUENT")

frame:SetScript("OnEvent", function(_, event, ...)
    -- 先把变参接出来：pcall 里的匿名函数不是变参函数，里面用不了 "..."
    local arg1 = ...
    local ok, err = pcall(function()
        if event == "ADDON_LOADED" then
            if arg1 == ADDON_NAME then ns:InitDB() end
            return
        end

        if event == "PLAYER_ENTERING_WORLD" then
            if not ns.db then ns:InitDB() end
            ns:MigrateClassKeyGroups()
            if ns.db.auto then
                ns.retryAnnounced = nil
                pendingQuiet = ns.db.quiet
                TryGenerateWithRetry(1)
            end
            return
        end

        if event == "PLAYER_SPECIALIZATION_CHANGED" then
            if ns.db and ns.db.auto then
                local specID = ns:GetSpecID()
                if specID and specID ~= ns.lastSpecID then
                    pendingQuiet = ns.db.quiet
                    TryGenerateWithRetry(1)
                end
            end
            return
        end

        if event == "UNIT_POWER_FREQUENT" then
            -- v1.9.42：低蓝提醒。宏系统没有蓝量数值条件（现版本宏条件表无 mana 判断，
            -- GSE 也不做资源判断），"蓝少自动分流"在宏层面做不到；插件侧监控是唯一
            -- 可靠路径：战斗中蓝 < 25% 且该职业有 MANA_TAP 分流技时，每 8 秒提醒一次
            if arg1 == "player" and InCombatLockdown() and ns.MANA_TAP then
                local _, _, cid = UnitClass("player")
                if ns.MANA_TAP[cid] then
                    -- v1.9.44：UnitPower/UnitPowerMax 在受污染上下文可能返回 secret value
                    -- （12.x 资源保密机制，直接算术即报错），先过 Unsecret 防护：
                    -- 保密期间本次跳过提醒，不参与算术
                    local cur = ns:Unsecret(UnitPower("player"), nil)
                    local mx = ns:Unsecret(UnitPowerMax("player"), nil)
                    if cur and mx and mx > 0 and cur / mx < 0.25 then
                        local now = GetTime()
                        if now - (ns.lastManaWarn or 0) > 8 then
                            ns.lastManaWarn = now
                            UIErrorsFrame:AddMessage("法力不足！按住 Alt 点击输出宏 = 生命分流", 1, 0.3, 0.3, 1)
                            ns:Print("|cffff5555法力不足 25%|r——按住 |cffffd100Alt|r 点击输出宏即可生命分流")
                        end
                    end
                end
            end
            return
        end

        if event == "PLAYER_REGEN_ENABLED" then
            -- 战斗中没能建宏 / 没能即时导入的，脱战后补上
            if ns.needReload and ns.lastSpecID then
                ns.needReload = nil
                ns:SafeGenerate(ns.db and ns.db.quiet or false)
            end
            return
        end
    end)
    if not ok then
        ns.lastError = tostring(err)
        ns:Print("|cffff5555事件处理出错|r：" .. ns.lastError)
    end
end)

-- ---------------------- 斜杠命令 ----------------------

local function Toggle(key, label)
    ns.db[key] = not ns.db[key]
    ns:Print(label .. "：" .. (ns.db[key] and "|cff00ff00开|r" or "|cff888888关|r"))
    ns:SafeGenerate(true)
end

SLASH_GSEAUTOGEN1 = "/ags"
SLASH_GSEAUTOGEN2 = "/gseautogen"
--- 自检：报告"没宠物自动召唤"到底会写成什么
-- 不用去法术书 hover，插件自己把解析到的技能名报出来
function ns:PetDiag()
    self:Print("—— 宠物召唤自检 ——")
    if not (ns.BuildPetSummonLines and ns.SpecIDByIndex) then
        self:Print("|cffff5555Data/Writer 还没加载|r")
        return
    end

    local cur = ns:GetSpecID()
    for i = 1, 4 do
        local specID = ns.SpecIDByIndex(i)
        if specID then
            local petID = ns.PET_SPELL and ns.PET_SPELL[specID]
            local name = petID and ns:SpellName(petID) or nil
            local okName = type(name) == "string" and name ~= "" and name:sub(1, 1) ~= "#"
            self:Print(string.format("  专精%d spec=%d%s 宠物：%s",
                i, specID, (specID == cur) and "（当前）" or "",
                okName and ("|cff00ff00" .. name .. "|r（ID " .. tostring(petID) .. "）")
                    or "|cffffaa00未配 / ID 解析失败（这一行不会写进宏）|r"))
        end
    end

    local lines = ns.BuildPetSummonLines(self.db or {})
    if #lines == 0 then
        self:Print("结论：宏里|cffffaa00不会|r写召唤行" ..
            ((self.db and self.db.autoPet == false) and "（autoPet 开关已关）" or "（没有可用的宠物 ID）"))
    else
        self:Print("结论：宏头会写入以下 " .. #lines .. " 行")
        for _, l in ipairs(lines) do self:Print("  |cff88ff88" .. l .. "|r") end
    end
end

SlashCmdList["GSEAUTOGEN"] = function(msg)
    if not ns.db then ns:InitDB() end
    msg = (msg or ""):match("^%s*(.-)%s*$")
    local cmd = msg:lower()

    if cmd == "" or cmd == "ui" then
        -- 空命令直接开面板；UI.lua 没加载时退回打印帮助
        if ns.ToggleUI then
            ns:ToggleUI()
        else
            ns:Print("界面没加载（UI.lua 缺失），请用 gen / debug 等命令")
        end
        return
    elseif cmd == "help" then
        ns:Print("命令：ui 打开面板 | gen 立即生成 | list 已生成 | wipe 清除 | debug 诊断 | cs 校验和自检")
        ns:Print("       macro 重建宏 | legacy 清旧命名序列 | cleanup 删旧宏 | diag 写入路径 | pet 宠物召唤自检")
        ns:Print("       str [aoe] 弹出GSE3导入串（手动）")
        ns:Print("       learn 官方优先级学习（start [aoe] / stop / show / reset / auto）")
        ns:Print("       auto/trinket/filter/quiet/reset")
        return
    elseif cmd == "pet" then
        ns:PetDiag()
        return
    elseif cmd:match("^learn") then
        ns:LearnCommand(msg:match("^learn%s*(.-)%s*$") or "")
        return
    elseif cmd == "diag" then
        ns:ImportDiag()
        return
    elseif cmd == "str" or cmd:match("^str%s") then
        -- /ags str [aoe]：按需弹出 GSE3 导入串（gen 不再自动弹，v1.9.34）
        ns:ShowImportStringFor(cmd:find("aoe", 1, true) ~= nil)
        return
    elseif cmd == "cs" then
        if ns.ChecksumSelfTest then ns.ChecksumSelfTest() end
        return
    elseif cmd == "macro" then
        local ok, cover, created, why = ns:UpdateMacro()
        if ok then
            ns:Print(string.format("宏 |cffFFD100%s|r 已%s，覆盖 %d 个专精",
                ns.MACRO_NAME, created and "新建" or "更新", cover))
            if cover < 3 then
                ns:Print("还有专精没生成序列，切过去一次就会补齐")
            end
        else
            ns:Print("|cffff5555宏更新失败|r：" .. tostring(why or "未知"))
        end
        return
    elseif cmd == "legacy" then
        local n = ns:WipeLegacySequences()
        ns:Print(n == 0 and "没有旧命名的 AGS 序列" or
            ("已清理 " .. n .. " 条旧命名序列（/reload 后彻底消失）"))
        return
    elseif cmd == "cleanup" then
        local n = ns:CleanupLegacyMacros()
        if n == 0 then
            ns:Print("没有发现旧版按专精建的 AGS 宏")
        else
            ns:Print(string.format("已删除 %d 个旧宏（只删了正文含 /click AGS_ 的），现统一用 %s", n, ns.MACRO_NAME))
        end
        return
    elseif cmd == "gen" then
        pendingQuiet = false
        ns.retryAnnounced = nil
        if ns:HasGSE() then
            ns:SafeGenerate(false)
        else
            TryGenerateWithRetry(1)
        end
        return
    elseif cmd == "debug" then
        local _, _, classID = UnitClass("player")
        ns:Print("—— 诊断 ——")
        ns:Print("GSE 公开接口：" .. (ns:HasGSE() and "|cff00ff00可用|r" or "|cffff5555不可用|r"))
        ns:Print("_G.GSE 类型：" .. type(_G.GSE)
            .. "，RegisterAddon：" .. type(_G.GSE and _G.GSE.RegisterAddon))
        ns:Print(string.format("职业 ID=%s  专精 ID=%s", tostring(classID), tostring(ns:GetSpecID())))
        ns:Print("GSE 内部版本号：" .. tostring(ns:GSEVersionInfo()) .. "  TOC：" .. tostring(ns:TOCVersion()))
        ns:Print("C_EncodingUtil.SerializeCBOR：" .. type(C_EncodingUtil and C_EncodingUtil.SerializeCBOR))
        local specID = ns:GetSpecID()
        ns:Print("该专精模板：" .. (specID and ns.TEMPLATES[specID] and "|cff00ff00有|r" or "|cffff5555无|r"))
        ns:Print("上次错误：" .. tostring(ns.lastError or "无"))
        ns:Print("上次写入路径：" .. tostring(ns.importPath or "无") ..
            "（private=静默替换；proxy-noop=内容未变；proxy-reload=需重载；均不弹窗）")
        return
    elseif cmd == "list" then
        local list = ns:ListGenerated()
        if #list == 0 then
            ns:Print("还没有生成任何序列，输入 /ags gen")
        else
            for _, n in ipairs(list) do ns:Print("已生成：" .. n) end
        end
        return
    elseif cmd == "wipe" then
        local n = ns:WipeGenerated()
        ns:Print("已清除 " .. n .. " 条 AGS_ 序列（/reload 后彻底消失）")
        return
    elseif cmd == "auto" then
        ns.db.auto = not ns.db.auto
        ns:Print("自动生成：" .. (ns.db.auto and "开" or "关"))
        return
    elseif cmd == "trinket" then
        Toggle("trinket", "包含主动饰品")
        return
    elseif cmd == "filter" then
        Toggle("filter", "过滤未学会技能")
        return
    elseif cmd == "quiet" then
        ns.db.quiet = not ns.db.quiet
        ns:Print("自动生成提示：" .. (ns.db.quiet and "关" or "开"))
        return
    elseif cmd == "reset" then
        GSEAutoGenDB = nil
        ns:InitDB()
        ns:Print("已恢复默认设置")
        return
    end

    ns:Print("未知命令：" .. msg .. "，输入 /ags 看帮助")
end

-- ==========================================================
-- 按键绑定（Bindings.xml）：设置 → 按键设置 → 插件 → GSE自动序列 → "生成序列"
-- 绑个键就等于手动输 /ags gen（对当前专精立即生成，并重修宏）。
-- ==========================================================
_G.BINDING_HEADER_GSEAutoGen = "GSE自动序列"
_G.BINDING_NAME_GSEAUTOGEN_GEN = "生成序列（当前专精）"
_G.BINDING_NAME_GSEAUTOGEN_LEARN = "学习采样 开始/停止（木桩）"

function GSEAutoGen_GenKeybind()
    if not ns.db then ns:InitDB() end
    ns:SafeGenerate(false)
end

function GSEAutoGen_LearnKeybind()
    if not ns.db then ns:InitDB() end
    if ns.LearnToggleKeybind then
        ns:LearnToggleKeybind()
    else
        ns:Print("|cffff5555学习模块没加载|r（Learner.lua 缺失）")
    end
end
