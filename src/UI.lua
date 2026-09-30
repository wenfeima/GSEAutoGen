-- ==========================================================
-- GSEAutoGen - UI.lua  (v1.6.0)
--
-- 游戏内图形面板 + 小地图图标。
-- 全部用暴雪原生 API 手写：GSE 只带了 AceEvent / AceLocale /
-- CallbackHandler / LibDataBroker，**没有 AceGUI**，不能依赖。
-- 模板 OptionsSliderTemplate / UICheckButtonTemplate / UIPanelButtonTemplate /
-- UIPanelScrollFrameTemplate / BackdropTemplate 都在 12.x 实测可用
-- （用户 AddOns 目录里其它插件正在用）。
--
-- 打开方式：/ags 空命令，或左键小地图图标。
-- ==========================================================

local ADDON_NAME, ns = ...

local W, H = 470, 700
local PAD  = 16

local panel
local specRows  = {}
local checkRows = {}
local blockRows = {}
local minimapIcon

-- ---------------------- 小工具 ----------------------

local function Text(parent, font, r, g, b)
    local t = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    t:SetJustifyH("LEFT")
    if r then t:SetTextColor(r, g, b) end
    return t
end

local function Divider(parent, y)
    local tex = parent:CreateTexture(nil, "ARTWORK")
    tex:SetHeight(1)
    tex:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, y)
    tex:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD, y)
    tex:SetColorTexture(1, 1, 1, 0.18)
    return y - 12
end

local function Header(parent, text, y)
    local t = Text(parent, "GameFontNormal", 1, 0.82, 0)
    t:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, y)
    t:SetText(text)
    return y - 23
end

local function Button(parent, label, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 24)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

--- 打开暴雪「按键设置」界面（EUI 等整合包把主菜单里的按键设置按钮吞了，这里兜底）
-- 多级尝试：设置面板按键分类 → 旧版 KeyBindingFrame → 设置面板本体 → 打不开就给提示
local function OpenKeybinds()
    if Settings and type(Settings.OpenToCategory) == "function" and SettingsPanel then
        local ids = {
            Settings.KEYBINDINGS_PANEL_ID,
            Settings.KEYBINDINGS_CATEGORY,
            "keybindings",
        }
        for _, id in ipairs(ids) do
            if id then
                local ok = pcall(Settings.OpenToCategory, id)
                if ok and SettingsPanel:IsVisible() then
                    ns:Print("在左侧「按键设置」里搜索 |cffFFD100GSE|r，把两个键拖到快捷键上即可")
                    return
                end
            end
        end
    end
    if KeyBindingFrame_LoadUI then pcall(KeyBindingFrame_LoadUI) end
    if KeyBindingFrame then
        KeyBindingFrame:Show()
        ns:Print("在分类「GSE自动序列」里把两个键拖到快捷键上即可")
        return
    end
    if SettingsPanel then
        if SettingsPanel.Toggle then SettingsPanel:Toggle()
        elseif SettingsPanel.Show then SettingsPanel:Show() end
        ns:Print("请在设置面板左侧点「按键设置」，搜索 |cffFFD100GSE|r")
        return
    end
    ns:Print("打不开按键设置：主菜单点「选项」，左侧列表找「按键设置」，搜索 GSE")
end

local function Check(parent, label, y, onChanged)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, y)
    local t = cb.Text
    if not t then
        t = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        t:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    end
    t:SetText(label)
    -- 用 HookScript 而不是 SetScript：UICheckButtonTemplate 自带 OnClick（播音效），
    -- 直接覆盖会把它顶掉
    cb:HookScript("OnClick", function(self)
        onChanged(self:GetChecked() and true or false)
    end)
    return cb
end

-- ---------------------- 数据 ----------------------

local function CurrentSpecID()
    return ns:GetSpecID()
end

--- 不写入，只算一遍：给面板显示"某专精现在会生成几块"
-- 返回 单体结果, AOE 结果
local function PreviewBlocks(specID)
    local cur = CurrentSpecID()
    return ns:BuildBoth(specID, {
        trinket = ns.db and ns.db.trinket,
        filter = ns.db and ns.db.filter,
        max = ns.db and ns.db.max,
        force = (specID ~= cur),
    })
end

-- ---------------------- 面板 ----------------------

local function BuildPanel()
    local f = CreateFrame("Frame", "GSEAutoGenPanel", UIParent, "BackdropTemplate")
    f:SetSize(W, H)
    f:SetPoint("CENTER", UIParent, "CENTER", (ns.db and ns.db.posX) or 0, (ns.db and ns.db.posY) or 60)
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:SetBackdropColor(0.06, 0.07, 0.10, 0.97)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint(1)
        if ns.db then
            ns.db.posX = x or 0
            ns.db.posY = y or 60
            ns.db.anchorPoint = p
            ns.db.relPoint = rp
        end
    end)
    f:Hide()

    -- 标题
    local title = Text(f, "GameFontNormalLarge", 0.40, 0.80, 1)
    title:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -14)
    title:SetText("GSE 自动序列生成器")

    local ver = Text(f, "GameFontDisableSmall", 0.55, 0.55, 0.55)
    ver:SetPoint("LEFT", title, "RIGHT", 8, 0)
    ver:SetText("v" .. tostring(C_AddOns and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "?"))

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() f:Hide() end)

    -- 「绑键」：直接打开暴雪按键设置（EUI 整合包主菜单里没有这个入口）
    Button(f, "绑键", 52, function() OpenKeybinds() end)
        :SetPoint("TOPRIGHT", f, "TOPRIGHT", -38, -10)

    local y = -40

    -- 状态条
    f.status = Text(f, "GameFontHighlight", 0.85, 0.85, 0.85)
    f.status:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
    f.status:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, y)
    f.status:SetText("—")
    y = y - 22

    f.path = Text(f, "GameFontDisableSmall", 0.55, 0.60, 0.70)
    f.path:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
    f.path:SetText("")
    y = Divider(f, y - 8)

    -- v1.9.31 重构：专精行 / 选项 / 滑块 / 块预览全部装进滚动区。
    -- 旧版是绝对坐标排版，专精加到 7 行 + 选项 11 个后总高度超出面板，
    -- 「技能块预览」标题被挤进底部按钮区、滚动框上下锚点倒挂收成 0 高（界面全挤在下面）。
    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y - 6)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD - 20, 74)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(W - PAD * 2 - 20, 1200)
    scroll:SetScrollChild(child)

    -- 以下内容全部相对 child 排版（cy 从 child 顶往下走，与面板高度解耦）
    local cy = 0

    -- 序列
    cy = Header(child, "序列", cy)
    for i, specID in ipairs(ns:AllTemplateSpecs()) do
        local row = CreateFrame("Frame", nil, child)
        row:SetSize(W - PAD * 2, 26)
        row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, cy)

        local name = Text(row, "GameFontHighlight")
        name:SetPoint("LEFT", row, "LEFT", 0, 0)
        name:SetWidth(230)

        local info = Text(row, "GameFontHighlightSmall", 0.65, 0.70, 0.80)
        info:SetPoint("LEFT", name, "RIGHT", 0, 0)
        info:SetWidth(150)

        local btn = Button(row, "生成", 58, function()
            ns:GenerateSpec(specID)
        end)
        btn:SetPoint("RIGHT", row, "RIGHT", 0, 0)

        specRows[i] = { row = row, name = name, info = info, btn = btn, specID = specID }
        cy = cy - 27
    end
    -- 本职业无模板时的占位提示（与第一行同位置，两态互斥显示）
    f.specEmpty = Text(child, "GameFontDisableSmall")
    f.specEmpty:SetPoint("TOPLEFT", child, "TOPLEFT", 0, cy + 27 * (#specRows) - 4)
    f.specEmpty:SetText("当前职业暂无模板（已有：术士三系 / 战士三系 / 圣骑·防护）")
    f.specEmpty:Hide()
    cy = Divider(child, cy - 4)

    -- 选项
    cy = Header(child, "选项", cy)
    local opt = {
        { key = "auto",     label = "登录 / 切专精时自动生成" },
        { key = "trinket",  label = "只插主动饰品" },
        { key = "filter",   label = "过滤掉没学会的技能" },
        { key = "makeMacro", label = "自动维护宏 " .. tostring(ns.MACRO_NAME) },
        { key = "aoe",      label = "额外生成 AOE 版（独立按键 AGS_AOE）" },
        { key = "autoTarget",  label = "宏自动选中最近的敌人" },
        { key = "alwaysRetarget", label = "始终就近选怪（目标活着也切，AOE 跳怪用）" },
        { key = "petAttack",   label = "宠物自动攻击（术士 / 猎人 / DK）" },
        { key = "autoPet",     label = "没宠物时自动召唤（术士三系）" },
        { key = "startAttack", label = "自身自动攻击（近战 / 猎人有用）" },
        { key = "quiet",    label = "自动生成时不弹提示" },
        { key = "showMinimap", label = "显示小地图图标" },
    }
    for i, o in ipairs(opt) do
        checkRows[i] = Check(child, o.label, cy, function(v)
            if not ns.db then return end
            ns.db[o.key] = v
            if o.key == "showMinimap" then
                ns:UpdateMinimapIcon()
            else
                local ok = ns:SafeGenerate(true)
                -- v1.9.45：alwaysRetarget 切换后必须给生效状态反馈——旧版静默 gen，
                --   静默导入失败（需 /reload）时用户不知道执行层还是旧宏，
                --   表现为"取消勾选后仍不停换目标"（旧裸 /targetenemy 一直在跑）
                if o.key == "alwaysRetarget" then
                    if ok then
                        ns:Print(v and "已开启「始终就近选怪」" or "已关闭「始终就近选怪」")
                        if ns.needReload then
                            ns:Print("|cffffd100执行层还是旧宏，请 /reload（或点「生成并重载」按钮）生效|r")
                        end
                    else
                        ns:Print("|cffff5555重新生成失败|r——开关已保存，点「生成并重载」应用")
                    end
                end
            end
            ns:RefreshUI()
        end)
        checkRows[i].key = o.key
        cy = cy - 25
    end

    -- 块数上限
    local slider = CreateFrame("Slider", nil, child, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", child, "TOPLEFT", PAD + 4, cy - 4)
    slider:SetWidth(240)
    slider:SetMinMaxValues(20, 80)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    if slider.Low then slider.Low:SetText("20") end
    if slider.High then slider.High:SetText("80") end
    local sLabel = Text(child, "GameFontHighlight", 0.85, 0.85, 0.85)
    sLabel:SetPoint("LEFT", slider, "RIGHT", 14, 0)
    sLabel:SetText("块数上限")
    local sVal = Text(child, "GameFontHighlight", 0.40, 0.80, 1)
    sVal:SetPoint("LEFT", sLabel, "RIGHT", 6, 0)
    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        sVal:SetText(tostring(value))
        if ns.db and ns.db.max ~= value then
            ns.db.max = value
            ns:SafeGenerate(true)
            ns:RefreshUI()
        end
    end)
    f.slider = slider
    f.sliderVal = sVal
    cy = cy - 40
    cy = Divider(child, cy)

    -- 上次生成的块预览
    cy = Header(child, "技能块预览", cy)
    f.blockHead = Text(child, "GameFontHighlightSmall", 0.65, 0.70, 0.80)
    f.blockHead:SetPoint("TOPLEFT", child, "TOPLEFT", PAD, cy)
    f.blockHead:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, cy)
    f.blockHead:SetText("（还没生成）")
    cy = cy - 16

    for i = 1, 32 do
        local t = Text(child, "GameFontHighlightSmall")
        t:SetPoint("TOPLEFT", child, "TOPLEFT", 0, cy - ((i - 1) * 15))
        t:SetPoint("RIGHT", child, "RIGHT", 0, 0)
        t:Hide()
        blockRows[i] = t
    end

    -- 底部按钮（v1.9.40 起 5 个，宽度 81：5×81+4×8=437 ≤ 面板可用宽 438）
    local bw = 81
    local bx = PAD
    Button(f, "立即生成", bw, function() ns:SafeGenerate(false) end):SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", bx, 16)
    Button(f, "重建宏", bw, function()
        local ok, cover, created, why = ns:UpdateMacro()
        if ok then
            ns:Print(string.format("宏 %s 已%s，覆盖 %d 个专精", ns.MACRO_NAME, created and "新建" or "更新", cover))
        else
            ns:Print("宏更新失败：" .. tostring(why or "未知"))
        end
    end):SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", bx + bw + 8, 16)
    Button(f, "清理旧宏", bw, function()
        local n = ns:CleanupLegacyMacros()
        ns:Print(n == 0 and "没有发现旧版 AGS 宏" or ("已删除 " .. n .. " 个旧宏"))
    end):SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", bx + (bw + 8) * 2, 16)
    Button(f, "清除全部", bw, function()
        local n = ns:WipeGenerated()
        ns:Print("已清除 " .. n .. " 条 AGS_ 序列（/reload 后彻底消失）")
        ns:RefreshUI()
    end):SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", bx + (bw + 8) * 3, 16)
    -- v1.9.40：一键「生成并重载」——用户高频操作 /ags gen → /reload 合成一次点击
    Button(f, "生成并重载", bw, function()
        local ok = ns:SafeGenerate(false)
        if not ok then return end -- 生成失败（含无模板），停在面板看日志，不要重载
        if InCombatLockdown() then
            ns:Print("|cffff5555战斗中无法重载界面|r——脱战后手动 /reload")
            return
        end
        ReloadUI()
    end):SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", bx + (bw + 8) * 4, 16)

    -- 学习行 ×4：单体 / AOE / 数据 / 重置（重置带二次确认，防误清）
    local resetPending = false
    local learnBtn = Button(f, "学习:单体", 96, function()
        if ns.LearnToggle then ns:LearnToggle("st") end
        ns:RefreshUI()
    end)
    learnBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, 48)
    local aoeBtn = Button(f, "学习:AOE", 84, function()
        if ns.LearnToggle then ns:LearnToggle("aoe") end
        ns:RefreshUI()
    end)
    aoeBtn:SetPoint("LEFT", learnBtn, "RIGHT", 8, 0)
    local showBtn = Button(f, "学习数据", 84, function() ns:LearnCommand("show") end)
    showBtn:SetPoint("LEFT", aoeBtn, "RIGHT", 8, 0)
    local resetBtn
    resetBtn = Button(f, "重置学习", 84, function()
        if resetPending then
            resetPending = false
            ns:LearnCommand("reset")   -- v1.9.31：只清当前专精（reset all 会把其它职业的数据也清掉）
            ns:RefreshUI()
        else
            resetPending = true
            resetBtn:SetText("确定清空?")
            if C_Timer and C_Timer.After then
                C_Timer.After(3, function()
                    if resetPending then
                        resetPending = false
                        resetBtn:SetText("重置学习")
                    end
                end)
            end
        end
    end)
    resetBtn:SetPoint("LEFT", showBtn, "RIGHT", 8, 0)

    -- 按钮文字实时跟随采样状态（0.5s 节流，文字没变不重设）
    local function learnLabel(kind)
        local active = ns.LearnSessionActive and ns:LearnSessionActive()
        local count = ns.LearnSessionCount and ns:LearnSessionCount() or 0
        if active and ns.LearnSessionKind and ns:LearnSessionKind() == kind then
            return string.format("停止(%d)", count)
        end
        return kind == "aoe" and "学习:AOE" or "学习:单体"
    end
    local lastSt, lastAoe, acc = "", "", 0
    learnBtn:SetScript("OnUpdate", function(_, dt)
        acc = acc + dt
        if acc < 0.5 then return end
        acc = 0
        if resetPending then return end   -- 重置确认显示中，别覆盖它的文字
        local l1, l2 = learnLabel("st"), learnLabel("aoe")
        if l1 ~= lastSt then lastSt = l1; learnBtn:SetText(l1) end
        if l2 ~= lastAoe then lastAoe = l2; aoeBtn:SetText(l2) end
    end)

    panel = f
    return f
end

-- ---------------------- 刷新 ----------------------

local function SetCheck(cb, value)
    if cb then cb:SetChecked(value and true or false) end
end

function ns:RefreshUI()
    if not panel or not panel:IsShown() then return end
    if not ns.db then return end

    -- 状态条
    local scan = ns:ScanCharacter()
    local specID = CurrentSpecID()
    local _, _, classID = UnitClass("player")
    local label = (specID and ns.SPEC_NAMES[specID]) or "未知专精"
    panel.status:SetText(string.format(
        "%s · 急速 %.1f%% · 套装 %d 件 · 主动饰品 %d 个",
        label, scan.haste or 0, scan.tierCount or 0,
        (scan.trinket13 and 1 or 0) + (scan.trinket14 and 1 or 0)
    ))
    local g = ns.GetPrivateGSE and ns:GetPrivateGSE()
    panel.path:SetText(g and "|cff66ccff写入方式|r 静默替换（免重载）"
        or "|cffffaa00写入方式|r 仅落盘（需 /reload）")

    -- 序列行：只显示当前职业的专精，其它职业的行隐藏（存档里仍保留，切回去还能用）
    local visCount = 0
    for _, r in ipairs(specRows) do
        if ns:SpecClassID(r.specID) == classID then
            visCount = visCount + 1
            r.row:Show()
            local solo, aoe = PreviewBlocks(r.specID)
            local isCur = (r.specID == specID)
            r.name:SetText(string.format("%s  %s%s",
                ns.SPEC_NAMES[r.specID] or "?", ns.SEQ_NAME[r.specID] or "?",
                isCur and "  |cffFFD100（当前）|r" or ""))
            if solo then
                local txt = string.format("单体 %d", #solo.blocks)
                if aoe then txt = txt .. string.format(" · |cffFFD100AOE %d|r", #aoe.blocks) end
                if solo.forced then txt = txt .. " · 兜底" end
                r.info:SetText(txt)
            else
                r.info:SetText("无模板")
            end
        else
            r.row:Hide()
        end
    end
    -- 本职业没有模板时给个提示（避免"序列"下面空一片）
    if visCount == 0 and panel.specEmpty then
        panel.specEmpty:Show()
    elseif panel.specEmpty then
        panel.specEmpty:Hide()
    end

    -- 开关
    for _, cb in ipairs(checkRows) do
        if cb.key then SetCheck(cb, ns.db[cb.key]) end
    end
    if panel.slider then
        panel.slider:SetValue(ns.db.max or 60)
        panel.sliderVal:SetText(tostring(ns.db.max or 60))
    end

    -- 块预览
    local res = ns.lastResult
    if not res then
        panel.blockHead:SetText("（还没生成，点上面的「生成」或底部「立即生成」）")
        for _, t in ipairs(blockRows) do t:Hide() end
        return
    end
    panel.blockHead:SetText(string.format("上次生成 %s（%s）共 %d 块%s",
        res.seqName or "?", res.label or "?", #res.blocks,
        ns.lastAoeResult and string.format(" ｜ AOE 版 %s 共 %d 块",
            ns.lastAoeResult.seqName or "?", #ns.lastAoeResult.blocks) or ""))

    local filler = res.fillerRep and res.fillerID or nil
    for i, b in ipairs(res.blocks) do
        local t = blockRows[i]
        if not t then break end
        if b.kind == "item" then
            t:SetText(string.format("%2d  |cffFFD100饰品 %s|r", i, b.slot or "?"))
        elseif b.rep then
            t:SetText(string.format("%2d  %s   |cff888888每 %d 步|r", i, ns:SpellName(b.id), b.rep))
        else
            t:SetText(string.format("%2d  %s", i, ns:SpellName(b.id)))
        end
        t:Show()
    end
    for i = #res.blocks + 1, #blockRows do blockRows[i]:Hide() end
end

function ns:ToggleUI()
    if not panel then BuildPanel() end
    if panel:IsShown() then
        panel:Hide()
    else
        panel:Show()
        ns:RefreshUI()
    end
end

-- ---------------------- 小地图图标 ----------------------

local function MinimapAngle()
    return (ns.db and ns.db.minimapAngle) or 220
end

local function PlaceIcon(icon)
    local a = math.rad(MinimapAngle())
    local r = (Minimap:GetWidth() / 2) + 6
    icon:ClearAllPoints()
    icon:SetPoint("CENTER", Minimap, "CENTER", r * math.cos(a), r * math.sin(a))
end

function ns:UpdateMinimapIcon()
    if not minimapIcon then return end
    if ns.db and ns.db.showMinimap == false then
        minimapIcon:Hide()
    else
        minimapIcon:Show()
        PlaceIcon(minimapIcon)
    end
end

local function BuildMinimapIcon()
    local icon = CreateFrame("Button", "GSEAutoGenMinimapIcon", Minimap, "BackdropTemplate")
    icon:SetSize(30, 30)
    icon:SetFrameStrata("MEDIUM")
    icon:SetFrameLevel(8)
    icon:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    icon:SetBackdropColor(0.05, 0.06, 0.09, 0.92)
    icon:SetBackdropBorderColor(0.40, 0.80, 1, 0.95)

    local t = icon:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    t:SetPoint("CENTER")
    t:SetText("AGS")
    t:SetTextColor(0.40, 0.80, 1)

    icon:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    icon:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            ns:SafeGenerate(false)
        else
            ns:ToggleUI()
        end
    end)
    icon:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("GSE 自动序列生成器", 0.40, 0.80, 1)
        GameTooltip:AddLine("左键  打开面板", 1, 1, 1)
        GameTooltip:AddLine("右键  立即生成", 1, 1, 1)
        GameTooltip:AddLine("拖动  移动图标", 0.65, 0.65, 0.65)
        GameTooltip:Show()
    end)
    icon:SetScript("OnLeave", function() GameTooltip:Hide() end)

    icon:RegisterForDrag("LeftButton")
    icon:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function(s)
            if not Minimap then return end
            local mx, my = Minimap:GetCenter()
            if not mx then return end
            local px, py = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale()
            px, py = px / scale, py / scale
            local a = math.atan2(py - my, px - mx)
            if ns.db then ns.db.minimapAngle = math.deg(a) end
            PlaceIcon(s)
        end)
    end)
    icon:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    minimapIcon = icon
    return icon
end

-- ---------------------- 初始化 ----------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    local ok, err = pcall(function()
        if not ns.db then ns:InitDB() end
        if type(Minimap) == "table" and Minimap.GetWidth then
            BuildMinimapIcon()
            ns:UpdateMinimapIcon()
        end
    end)
    if not ok then ns.lastError = tostring(err) end
end)
