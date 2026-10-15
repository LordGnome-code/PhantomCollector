local ADDON = ...
local PC = CreateFrame("Frame", "PhantomCollectorEventFrame")
local DB, ui, selectedKey
local palettes = {
  {name="Phantom Purple", bg={0.095,0.075,0.14}, accent={0.68,0.45,0.96}},
  {name="Emerald", bg={0.055,0.12,0.11}, accent={0.21,0.82,0.54}},
  {name="Crimson", bg={0.14,0.065,0.075}, accent={0.92,0.32,0.38}},
  {name="Ocean", bg={0.055,0.09,0.16}, accent={0.30,0.67,0.97}},
  {name="Gold", bg={0.14,0.115,0.065}, accent={0.96,0.76,0.31}},
  {name="Slate", bg={0.085,0.095,0.11}, accent={0.72,0.78,0.85}},
}
local intervals = { {name="Hourly", seconds=3600}, {name="Daily", seconds=86400}, {name="Weekly", seconds=604800}, {name="Biweekly", seconds=1209600}, {name="Monthly (30 days)", seconds=2592000}, {name="Custom (hours)", seconds=3600} }
local function now() return time() end
local function me()
  local n = UnitName("player") or "Unknown"
  local r = GetRealmName() or "Realm"
  return n .. "-" .. r
end
local function clean(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function number(v, lo, hi)
  local n = tonumber(v) or 0
  if n ~= n then n=0 end
  n = math.floor(n)
  return math.max(lo or 0, math.min(hi or 999999999, n))
end
local function money(g,s,c) return number(g,0,99999999)*10000 + number(s,0,99)*100 + number(c,0,99) end
local function splitMoney(v)
  v=math.max(0,math.floor(v or 0))
  return math.floor(v/10000), math.floor(v/100)%100, v%100
end
local function moneyText(v)
  local g,s,c = splitMoney(v)
  return string.format("%dg %ds %dc",g,s,c)
end
local function fullName(name)
  name=clean(name)
  if name == "" then return nil end
  if not string.find(name,"-",1,true) then return name .. "-" .. (GetRealmName() or "Realm") end
  return name
end
local function shortName(name) return (name or ""):match("^([^-]+)") or name or "?" end
local function whisper(s) DEFAULT_CHAT_FRAME:AddMessage("|cffbb88ffPhantomCollector:|r "..s) end
local function periodSeconds(entry)
  local p=intervals[entry.period or 2] or intervals[2]
  if entry.period == 6 then return number(entry.customHours or 24,1,100000)*3600 end
  return p.seconds
end
local function accrue(entry)
  local principal=number(entry.principal or 0,0,999999999999)
  local rate=math.max(0, math.min(1000,tonumber(entry.rate) or 0))/100
  local steps=math.max(0, math.floor((now()-(entry.started or now()))/periodSeconds(entry)))
  local raw
  if DB.compound == false then raw=principal * (1 + rate*steps)
  else raw=principal * ((1+rate)^steps) end
  if raw ~= raw or raw == math.huge or raw > 999999999999 then raw=999999999999 end
  return math.floor(raw+0.5),steps
end
local function ensure(name, fromTrade)
  local key=fullName(name)
  if not key then return end
  if not DB.contacts[key] then DB.contacts[key]={name=key, lastSeen=now(), trader=fromTrade or false} end
  if fromTrade then DB.contacts[key].lastSeen=now(); DB.contacts[key].trader=true end
  return key
end
local function theme(frame)
  if not frame then return end
  local p=palettes[DB.palette or 1] or palettes[1]
  frame.bg:SetColorTexture(p.bg[1],p.bg[2],p.bg[3],0.98)
  frame.head:SetColorTexture(p.accent[1],p.accent[2],p.accent[3],0.82)
  frame.title:SetTextColor(1,1,1)
  if frame.divider then frame.divider:SetColorTexture(p.accent[1],p.accent[2],p.accent[3],0.6) end
end
local function label(parent,text,x,y,width)
  local t=parent:CreateFontString(nil,"OVERLAY","GameFontNormal")
  t:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y)
  if width then t:SetWidth(width); t:SetJustifyH("LEFT") end
  t:SetText(text)
  return t
end
local function button(parent,text,w,h,x,y,fn)
  local b=CreateFrame("Button",nil,parent,"UIPanelButtonTemplate")
  b:SetSize(w,h); b:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y); b:SetText(text)
  b:SetScript("OnClick",fn)
  return b
end
local function edit(parent,w,x,y,onlyNumeric)
  local e=CreateFrame("EditBox",nil,parent,"InputBoxTemplate")
  e:SetSize(w,24);e:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y);e:SetAutoFocus(false)
  if onlyNumeric then e:SetNumeric(true) end
  e:SetScript("OnEscapePressed",function(self) self:ClearFocus() end)
  e:SetScript("OnEnterPressed",function(self) self:ClearFocus() end)
  return e
end
local function makePanel(name,w,h)
  local f=CreateFrame("Frame",name,UIParent,"BackdropTemplate")
  f:SetSize(w,h); f:SetPoint("CENTER"); f:SetFrameStrata("DIALOG");f:SetClampedToScreen(true)
  f:SetMovable(true);f:EnableMouse(true);f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart",f.StartMoving);f:SetScript("OnDragStop",f.StopMovingOrSizing)
  local bg=f:CreateTexture(nil,"BACKGROUND");bg:SetAllPoints();f.bg=bg
  local head=f:CreateTexture(nil,"BORDER");head:SetPoint("TOPLEFT",1,-1);head:SetPoint("TOPRIGHT",-1,-1);head:SetHeight(32);f.head=head
  local title=label(f,"PhantomCollector",12,-9,280);f.title=title
  local close=CreateFrame("Button",nil,f,"UIPanelCloseButton")
  close:SetPoint("TOPRIGHT",f,"TOPRIGHT",2,1)
  f:Hide()
  return f
end
local function sortedKeys()
  local result={}
  for k in pairs(DB.contacts) do result[#result+1]=k end
  table.sort(result,function(a,b) return a:lower()<b:lower() end)
  return result
end
local function populate()
  if not ui then return end
  local contacts=sortedKeys()
  ui.status:SetText(string.format("%d contacts | %d debts",#contacts,(function() local n=0 for _ in pairs(DB.debts) do n=n+1 end return n end)()))
  for i=1,#ui.rows do
    local idx=i+ui.offset
    local key=contacts[idx]
    local b=ui.rows[i]
    if key then
      local e=DB.debts[key]
      local text=shortName(key)
      if e then text=text.."  |cffffd372"..moneyText(accrue(e)).."|r" end
      if key==selectedKey then text="|cff82ffc5> |r"..text end
      b:SetText(text);b.key=key;b:Show()
    else b.key=nil;b:Hide() end
  end
  ui.page:SetText(string.format("%d - %d of %d",math.min(#contacts,ui.offset+1),math.min(#contacts,ui.offset+#ui.rows),#contacts))
end
local function setFields(key)
  selectedKey=key
  if not ui then return end
  local e=key and DB.debts[key]
  ui.contact:SetText(key and shortName(key) or "No contact selected")
  if e then
    local g,s,c=splitMoney(e.principal)
    ui.gold:SetText(tostring(g));ui.silver:SetText(tostring(s));ui.copper:SetText(tostring(c))
    ui.rate:SetText(tostring(e.rate or 0));ui.period=e.period or 2;ui.hours:SetText(tostring(e.customHours or 24))
    ui.periodBtn:SetText(intervals[ui.period].name)
    local total, steps=accrue(e)
    ui.current:SetText("Current: "..moneyText(total).."  ("..steps.." periods)")
    ui.created:SetText("Started: "..date("%Y-%m-%d %H:%M",e.started or now()))
  else
    ui.gold:SetText("0");ui.silver:SetText("0");ui.copper:SetText("0");ui.rate:SetText("0");ui.period=2
    ui.periodBtn:SetText(intervals[2].name);ui.hours:SetText("24")
    ui.current:SetText("Current: 0g 0s 0c");ui.created:SetText("No active debt")
  end
  populate()
end
local function selectPeriod(btn)
  if not ui then return end
  ui.period=(ui.period % #intervals)+1
  btn:SetText(intervals[ui.period].name)
end
local function saveDebt()
  if not selectedKey then whisper("Select or add a character first.");return end
  local principal=money(ui.gold:GetText(),ui.silver:GetText(),ui.copper:GetText())
  local rate=tonumber(ui.rate:GetText()) or 0
  if rate<0 or rate>1000 then whisper("Interest must be between 0 and 1000 percent.");return end
  if principal<=0 then whisper("Enter a positive debt amount.");return end
  DB.debts[selectedKey]={principal=principal,rate=rate,period=ui.period,customHours=number(ui.hours:GetText(),1,100000),started=now(),creditor=me()}
  whisper("Saved debt for "..shortName(selectedKey)..". Interest timer restarted.")
  setFields(selectedKey)
end
local function announce()
  local e=selectedKey and DB.debts[selectedKey]
  if not e then whisper("Select a contact with a saved debt.");return end
  local total,steps=accrue(e)
  local p=(intervals[e.period or 2] or intervals[2]).name:lower()
  if e.period==6 then p="every "..tostring(e.customHours or 24).." hours" end
  local message=string.format("%s owes %s %s (original debt %s, %.2f%% interest %s, %d completed periods since %s).",shortName(selectedKey),shortName(e.creditor or me()),moneyText(total),moneyText(e.principal),e.rate or 0,p,steps,date("%Y-%m-%d",e.started or now()))
  local channel=DB.channel or "SAY"
  if channel=="PARTY" and not IsInGroup() then whisper("Not in a party.");return end
  if channel=="RAID" and not IsInRaid() then whisper("Not in a raid.");return end
  if channel=="GUILD" and not IsInGuild() then whisper("Not in a guild.");return end
  SendChatMessage(message,channel)
end
local function confirmDelete()
  if not selectedKey then return end
  DB.debts[selectedKey]=nil
  whisper("Cleared debt for "..shortName(selectedKey)..". Contact retained.")
  setFields(selectedKey)
end
local function makeSettings()
  local s=makePanel("PhantomCollectorSettings",360,330);s.title:SetText("PhantomCollector Settings")
  label(s,"Color palette",16,-52)
  s.themeBtn=button(s,"",185,25,150,-47,function()
    DB.palette=(DB.palette % #palettes)+1
    s.themeBtn:SetText(palettes[DB.palette].name)
    theme(ui);theme(s)
  end)
  label(s,"Announce channel",16,-90)
  s.channelBtn=button(s,"",185,25,150,-85,function()
    local order={"SAY","PARTY","RAID","GUILD"}
    local current=1 for i,v in ipairs(order) do if DB.channel==v then current=i end end
    DB.channel=order[(current%#order)+1];s.channelBtn:SetText(DB.channel)
  end)
  label(s,"Interest calculation",16,-130)
  s.compoundBtn=button(s,"",185,25,150,-125,function()
    DB.compound=not DB.compound
    s.compoundBtn:SetText(DB.compound and "Compounding" or "Simple")
    setFields(selectedKey)
  end)
  label(s,"Trade reminders",16,-170)
  s.tradeBtn=button(s,"",185,25,150,-165,function()
    DB.tradeNotice=not DB.tradeNotice
    s.tradeBtn:SetText(DB.tradeNotice and "Enabled" or "Disabled")
  end)
  local help=label(s,"A saved debt restarts its interest clock when edited.\nInterest advances once per complete period.\nCustom period is specified in hours.\nMonthly = 30 days.",16,-218,327)
  help:SetTextColor(0.85,0.85,0.9)
  s:SetScript("OnShow",function()
    s.themeBtn:SetText(palettes[DB.palette].name)
    s.channelBtn:SetText(DB.channel)
    s.compoundBtn:SetText(DB.compound and "Compounding" or "Simple")
    s.tradeBtn:SetText(DB.tradeNotice and "Enabled" or "Disabled")
    theme(s)
  end)
  return s
end
local function makeMain()
  ui=makePanel("PhantomCollectorMain",700,468)
  ui.title:SetText("PhantomCollector  |  Debt Ledger")
  button(ui,"Settings",88,23,565,-40,function() if not PC.settings then PC.settings=makeSettings() end if PC.settings:IsShown() then PC.settings:Hide() else PC.settings:Show() end end)
  ui.status=label(ui,"",15,-47,300)
  local d=ui:CreateTexture(nil,"ARTWORK");d:SetPoint("TOPLEFT",ui,"TOPLEFT",255,-77);d:SetSize(2,365);ui.divider=d
  label(ui,"Trade contacts",15,-87)
  ui.rows={};ui.offset=0
  for i=1,11 do
    local b=button(ui,"",224,25,12,-105-(i-1)*27,function(self) setFields(self.key) end)
    local text=b:GetFontString();if text then text:SetJustifyH("LEFT") end
    ui.rows[#ui.rows+1]=b
  end
  button(ui,"Prev",60,22,13,-414,function() ui.offset=math.max(0,ui.offset-11);populate() end)
  button(ui,"Next",60,22,179,-414,function() ui.offset=math.min(math.max(0,#sortedKeys()-11),ui.offset+11);populate() end)
  ui.page=label(ui,"",80,-418,104)
  label(ui,"Add/select player",274,-91)
  ui.newName=edit(ui,160,397,-85)
  button(ui,"Add / Select",109,25,568,-85,function()
    local key=ensure(ui.newName:GetText(),false)
    if key then setFields(key);ui.newName:SetText("") else whisper("Enter a player name.") end
  end)
  ui.contact=label(ui,"No contact selected",275,-130,382)
  label(ui,"Gold",275,-164); label(ui,"Silver",382,-164);label(ui,"Copper",489,-164)
  ui.gold=edit(ui,84,275,-181,true);ui.silver=edit(ui,84,382,-181,true);ui.copper=edit(ui,84,489,-181,true)
  label(ui,"Interest %",275,-222)
  ui.rate=edit(ui,76,360,-216,false)
  label(ui,"Interval",456,-222)
  ui.period=2
  ui.periodBtn=button(ui,intervals[2].name,150,24,525,-215,function(self) selectPeriod(self) end)
  label(ui,"Custom hours",275,-261)
  ui.hours=edit(ui,78,381,-255,true)
  ui.created=label(ui,"No active debt",275,-297,374)
  ui.current=label(ui,"Current: 0g 0s 0c",275,-321,390)
  button(ui,"Save Debt",125,28,275,-356,saveDebt)
  button(ui,"Announce",125,28,413,-356,announce)
  button(ui,"Clear Debt",125,28,550,-356,confirmDelete)
  label(ui,"Editing a debt restarts its interest timer.",275,-405,370)
  local hint=label(ui,"/pc  to toggle  |  /pc add NAME  to add a contact",275,-428,399)
  hint:SetTextColor(0.75,0.75,0.8)
  ui:SetScript("OnShow",function() theme(ui);setFields(selectedKey) end)
  return ui
end
local function open()
  if not ui then makeMain() end
  if ui:IsShown() then ui:Hide() else ui:Show() end
end
local function detectTrade()
  local targetName
  if TradeFrameRecipientNameText and TradeFrameRecipientNameText.GetText then
    targetName=TradeFrameRecipientNameText:GetText()
  end
  if (not targetName or targetName=="") and UnitExists("NPC") and UnitIsPlayer("NPC") then targetName=UnitName("NPC") end
  if (not targetName or targetName=="") and UnitExists("target") and UnitIsPlayer("target") then targetName=UnitName("target") end
  if not targetName or targetName=="" then return end
  local key=ensure(targetName,true)
  if key and DB.tradeNotice then whisper("Trade opened with "..shortName(key)..". Contact recorded; use /pc to assign a debt.") end
  if ui and ui:IsShown() then populate() end
end
PC:RegisterEvent("ADDON_LOADED")
PC:RegisterEvent("PLAYER_LOGIN")
PC:RegisterEvent("TRADE_SHOW")
PC:SetScript("OnEvent",function(self,event,...)
  if event=="ADDON_LOADED" then
    if (...)~=ADDON then return end
    PhantomCollectorDB=PhantomCollectorDB or {}
    DB=PhantomCollectorDB
    DB.contacts=DB.contacts or {};DB.debts=DB.debts or {}
    DB.palette=DB.palette or 1;DB.channel=DB.channel or "SAY"
    if DB.compound==nil then DB.compound=true end
    if DB.tradeNotice==nil then DB.tradeNotice=true end
  elseif event=="PLAYER_LOGIN" then
    SLASH_PHANTOMCOLLECTOR1="/pc";SLASH_PHANTOMCOLLECTOR2="/phantomcollector"
    SlashCmdList.PHANTOMCOLLECTOR=function(msg)
      local sub,arg=clean(msg):match("^(%S+)%s*(.-)%s*$")
      if sub=="add" and arg and arg~="" then
        local key=ensure(arg,false)
        if not ui then makeMain() end
        ui:Show();setFields(key)
      else open() end
    end
    whisper("Ready. Use /pc to open the ledger.")
  elseif event=="TRADE_SHOW" and DB then
    detectTrade()
    -- On some client builds the trade recipient UI populates on the following frame.
    if C_Timer and C_Timer.After then C_Timer.After(0.2,detectTrade) end
  end
end)
