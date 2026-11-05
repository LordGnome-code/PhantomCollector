local ADDON = ...
local PC = CreateFrame("Frame", "PhantomCollectorEventFrame")
local DB, ui, profile, selectedKey
local MAX_COPPER = 999999999999
local ICON = "Interface\\Icons\\INV_Misc_Bag_10"

local palettes = {
  {name="Phantom Purple", bg={0.095,0.075,0.14}, accent={0.68,0.45,0.96}},
  {name="Emerald", bg={0.055,0.12,0.11}, accent={0.21,0.82,0.54}},
  {name="Crimson", bg={0.14,0.065,0.075}, accent={0.92,0.32,0.38}},
  {name="Ocean", bg={0.055,0.09,0.16}, accent={0.30,0.67,0.97}},
  {name="Gold", bg={0.14,0.115,0.065}, accent={0.96,0.76,0.31}},
  {name="Slate", bg={0.085,0.095,0.11}, accent={0.72,0.78,0.85}},
}
local intervals = {
  {name="Hourly", seconds=3600},
  {name="Daily", seconds=86400},
  {name="Weekly", seconds=604800},
  {name="Biweekly", seconds=1209600},
  {name="Monthly (30 days)", seconds=2592000},
  {name="Custom (hours)", seconds=3600},
}

local function now() return time() end
local function clean(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function clampInt(v, low, high)
  local n = tonumber(v) or 0
  if n ~= n then n = 0 end
  n = math.floor(n)
  return math.max(low or 0, math.min(high or MAX_COPPER, n))
end
local function money(g, s, c)
  return clampInt(g,0,99999999)*10000 + clampInt(s,0,99)*100 + clampInt(c,0,99)
end
local function splitMoney(v)
  v = clampInt(v,0,MAX_COPPER)
  return math.floor(v/10000), math.floor(v/100)%100, v%100
end
local function moneyText(v)
  local g,s,c=splitMoney(v)
  return string.format("%dg %ds %dc",g,s,c)
end
local function me()
  return (UnitName("player") or "Unknown") .. "-" .. (GetRealmName() or "Realm")
end
local function fullName(name)
  name=clean(name)
  if name=="" then return nil end
  if not string.find(name,"-",1,true) then return name.."-"..(GetRealmName() or "Realm") end
  return name
end
local function shortName(name) return (name or ""):match("^([^-]+)") or name or "?" end
local function fmtDate(t)
  if not t then return "Never" end
  return date("%Y-%m-%d %H:%M", t)
end
local function whisper(s)
  if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffbb88ffPhantomCollector:|r "..s) end
end
local function periodSeconds(entry)
  local p=intervals[entry.period or 2] or intervals[2]
  if entry.period==6 then return clampInt(entry.customHours or 24,1,100000)*3600 end
  return p.seconds
end
-- Each debt stores its own interest type; DB.compound is only the default for new debts.
local function isCompound(entry)
  if entry and entry.compound~=nil then return entry.compound end
  return DB.compound~=false
end
local function typeName(compound) return compound and "Compound" or "Simple" end
local function accrue(entry)
  if not entry then return 0,0 end
  local principal=clampInt(entry.principal or 0,0,MAX_COPPER)
  local rate=math.max(0, math.min(1000, tonumber(entry.rate) or 0))/100
  local steps=math.max(0,math.floor((now()-(entry.started or now()))/periodSeconds(entry)))
  local raw
  if not isCompound(entry) then raw=principal*(1+rate*steps)
  else raw=principal*((1+rate)^steps) end
  if raw~=raw or raw==math.huge or raw>MAX_COPPER then raw=MAX_COPPER end
  return math.floor(raw+0.5),steps
end

local function ensure(name,fromTrade)
  local key=fullName(name)
  if not key then return nil end
  local c=DB.contacts[key]
  if not c then
    c={name=key, firstSeen=now(), lastSeen=now(), trader=false, tradeCount=0}
    DB.contacts[key]=c
  end
  c.name=key
  c.firstSeen=c.firstSeen or c.lastSeen or now()
  local isNewTrade=false
  if fromTrade then
    -- TRADE_SHOW also schedules a delayed recipient check: don't double count it.
    if not c.lastTradeAt or now()-c.lastTradeAt>=2 then
      isNewTrade=true
      c.tradeCount=(c.tradeCount or 0)+1
      c.lastTradeAt=now()
    end
    c.trader=true
    c.lastSeen=now()
  end
  return key, isNewTrade
end

local function historyFor(key)
  DB.history[key]=DB.history[key] or {}
  return DB.history[key]
end
local function logEvent(key,kind,amount,notes)
  local h=historyFor(key)
  table.insert(h,1,{at=now(),kind=kind,amount=clampInt(amount or 0,0,MAX_COPPER),notes=notes})
  while #h>40 do table.remove(h) end
end
local function statsFor(key)
  local s=DB.borrowers[key]
  if not s then
    s={borrowed=0,repaid=0,interestGenerated=0,forgiven=0,
      loans=0,payments=0,writeoffs=0}
    DB.borrowers[key]=s
    local old=DB.debts[key]
    if old then
      -- Version 1.0 saved only the latest principal, not earlier transactions.
      -- Import that as an opening loan, without inventing prior history.
      s.borrowed=clampInt(old.principal or 0,0,MAX_COPPER)
      s.loans=1
      s.firstLoan=old.started or now()
      s.lastLoan=old.started or now()
      s.imported=true
      logEvent(key,"Opening balance",s.borrowed,"Imported from v1.0")
    end
  end
  return s
end
local function theme(frame)
  if not frame then return end
  local p=palettes[DB.palette or 1] or palettes[1]
  frame.bg:SetColorTexture(p.bg[1],p.bg[2],p.bg[3],0.98)
  frame.head:SetColorTexture(p.accent[1],p.accent[2],p.accent[3],0.82)
  frame.title:SetTextColor(1,1,1)
  if frame.divider then frame.divider:SetColorTexture(p.accent[1],p.accent[2],p.accent[3],0.65) end
end
local function label(parent,text,x,y,width)
  local t=parent:CreateFontString(nil,"OVERLAY","GameFontNormal")
  t:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y)
  if width then t:SetWidth(width);t:SetJustifyH("LEFT") end
  t:SetText(text)
  return t
end
local function button(parent,text,w,h,x,y,fn)
  local b=CreateFrame("Button",nil,parent,"UIPanelButtonTemplate")
  b:SetSize(w,h);b:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y);b:SetText(text)
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
  f:SetSize(w,h);f:SetPoint("CENTER");f:SetFrameStrata("DIALOG");f:SetClampedToScreen(true)
  f:SetMovable(true);f:EnableMouse(true);f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart",f.StartMoving);f:SetScript("OnDragStop",f.StopMovingOrSizing)
  local bg=f:CreateTexture(nil,"BACKGROUND");bg:SetAllPoints();f.bg=bg
  local head=f:CreateTexture(nil,"BORDER")
  head:SetPoint("TOPLEFT",1,-1);head:SetPoint("TOPRIGHT",-1,-1);head:SetHeight(32);f.head=head
  local icon=f:CreateTexture(nil,"ARTWORK")
  icon:SetTexture(ICON);icon:SetSize(24,24);icon:SetPoint("TOPLEFT",f,"TOPLEFT",7,-5);f.icon=icon
  f.title=label(f,"PhantomCollector",38,-9,w-90)
  local close=CreateFrame("Button",nil,f,"UIPanelCloseButton")
  close:SetPoint("TOPRIGHT",f,"TOPRIGHT",2,1)
  f:Hide()
  return f
end

local function sortedKeys()
  local keys={}
  for k in pairs(DB.contacts) do keys[#keys+1]=k end
  table.sort(keys,function(a,b) return a:lower()<b:lower() end)
  return keys
end
local function populate()
  if not ui then return end
  local contacts=sortedKeys()
  local debts=0
  for _ in pairs(DB.debts) do debts=debts+1 end
  ui.status:SetText(string.format("%d contacts | %d active debts",#contacts,debts))
  for i=1,#ui.rows do
    local key=contacts[i+ui.offset]
    local b=ui.rows[i]
    if key then
      local e=DB.debts[key]
      local caption=shortName(key)
      if e then caption=caption.."  |cffffd372"..moneyText(accrue(e)).."|r" end
      if key==selectedKey then caption="|cff82ffc5> |r"..caption end
      b:SetText(caption);b.key=key;b:Show()
    else b.key=nil;b:Hide() end
  end
  if #contacts==0 then ui.page:SetText("0 of 0")
  else ui.page:SetText(string.format("%d-%d of %d",math.min(#contacts,ui.offset+1),math.min(#contacts,ui.offset+#ui.rows),#contacts)) end
end

-- Editors are shared by the main ledger and the borrower profile.
-- Custom-hours controls are completely hidden unless Custom (hours) is selected.
local function setPeriod(editor,period)
  if editor.period==6 and editor.hours:GetText()~="" then
    editor.customHours=clampInt(editor.hours:GetText(),1,100000)
  end
  editor.period=period
  editor.periodBtn:SetText((intervals[period] or intervals[2]).name)
  if period==6 then
    editor.hoursLabel:Show();editor.hours:Show()
    editor.hours:SetText(tostring(editor.customHours or 24))
  else
    editor.hours:ClearFocus();editor.hours:SetText("")
    editor.hoursLabel:Hide();editor.hours:Hide()
  end
end
local function cyclePeriod(editor)
  setPeriod(editor,(editor.period % #intervals)+1)
end
local function setCompound(editor,compound)
  editor.compound=compound and true or false
  editor.compoundBtn:SetText(typeName(editor.compound))
end
local function fillEditor(editor,key)
  editor.loading=true
  local e=key and DB.debts[key]
  local balance=e and accrue(e) or 0
  local g,s,c=splitMoney(balance)
  editor.gold:SetText(tostring(g))
  editor.silver:SetText(tostring(s))
  editor.copper:SetText(tostring(c))
  editor.rate:SetText(tostring(e and e.rate or 0))
  editor.customHours=e and e.customHours or 24
  editor.period=0 -- do not import stale values from the previous selected borrower
  setPeriod(editor,e and e.period or 2)
  if e then setCompound(editor,isCompound(e)) else setCompound(editor,DB.compound~=false) end
  editor.loading=false
  editor.amountDirty=false
end
local function trackAmountEdits(editor)
  for _,name in ipairs({"gold","silver","copper"}) do
    editor[name]:SetScript("OnTextChanged",function()
      if not editor.loading then editor.amountDirty=true end
    end)
  end
end
local function readEditor(editor)
  local rate=tonumber(editor.rate:GetText())
  if not rate or rate~=rate or rate<0 or rate>1000 then
    whisper("Interest must be between 0 and 1000 percent.")
    return nil
  end
  local hours=editor.customHours or 24
  if editor.period==6 then
    local typed=tonumber(editor.hours:GetText())
    if not typed or typed<1 or typed>100000 or typed~=math.floor(typed) then
      whisper("Custom interval must be a whole number of hours between 1 and 100000.")
      return nil
    end
    hours=typed
  end
  local balance=money(editor.gold:GetText(),editor.silver:GetText(),editor.copper:GetText())
  -- An unedited balance may have gained interest while this window was open.
  -- Use its up-to-date accrued value when changing only interest settings.
  if not editor.amountDirty and selectedKey and DB.debts[selectedKey] then
    balance=accrue(DB.debts[selectedKey])
  end
  return balance,rate,editor.period,hours,editor.compound
end

local refreshProfileStats, setFields, confirmClearNoDebt
local function saveFrom(editor)
  if not selectedKey then whisper("Select or add a character first.");return end
  local balance,rate,period,hours,compound=readEditor(editor)
  if balance==nil then return end
  local key=selectedKey
  local previous=DB.debts[key]
  if balance==0 and not previous then whisper("Enter a positive amount to start a debt.");return end
  local stats=statsFor(key)
  local oldTotal=previous and accrue(previous) or 0
  local interest=previous and math.max(0,oldTotal-clampInt(previous.principal or 0,0,MAX_COPPER)) or 0
  if interest>0 then
    stats.interestGenerated=clampInt((stats.interestGenerated or 0)+interest,0,MAX_COPPER)
    logEvent(key,"Interest accrued",interest)
  end
  local diff=balance-oldTotal
  if diff>0 then
    stats.borrowed=clampInt((stats.borrowed or 0)+diff,0,MAX_COPPER)
    stats.loans=(stats.loans or 0)+1
    stats.firstLoan=stats.firstLoan or now();stats.lastLoan=now()
    logEvent(key,previous and "Loan increase" or "New loan",diff)
  elseif diff<0 then
    stats.repaid=clampInt((stats.repaid or 0)-diff,0,MAX_COPPER)
    stats.payments=(stats.payments or 0)+1
    stats.lastPayment=now()
    logEvent(key,"Balance reduction",-diff)
  elseif previous and (rate~=previous.rate or period~=previous.period or compound~=isCompound(previous)
      or (period==6 and hours~=(previous.customHours or 24))) then
    logEvent(key,"Interest terms changed",0,string.format("%s%% %s %s",tostring(rate),intervals[period].name,typeName(compound):lower()))
  end
  if balance>0 then
    DB.debts[key]={principal=balance,rate=rate,period=period,customHours=hours,compound=compound,
      started=now(),creditor=previous and previous.creditor or me()}
    whisper("Saved "..shortName(key)..". Current balance and interest start are updated.")
  else
    DB.debts[key]=nil
    whisper("Debt paid in full for "..shortName(key)..". Borrowing history retained.")
  end
  setFields(key)
  if profile and profile:IsShown() then
    fillEditor(profile,key)
    refreshProfileStats()
  end
end
local function forgiveDebt(key)
  key=key or selectedKey
  local e=key and DB.debts[key]
  if not e then whisper("This borrower has no active debt.");return end
  local s=statsFor(key)
  local total=accrue(e)
  local interest=math.max(0,total-clampInt(e.principal or 0,0,MAX_COPPER))
  s.interestGenerated=clampInt((s.interestGenerated or 0)+interest,0,MAX_COPPER)
  s.forgiven=clampInt((s.forgiven or 0)+total,0,MAX_COPPER)
  s.writeoffs=(s.writeoffs or 0)+1
  logEvent(key,"Debt forgiven",total)
  DB.debts[key]=nil
  whisper("Forgave "..moneyText(total).." for "..shortName(key)..". History retained (not counted as repaid).")
  setFields(key)
  if profile and profile:IsShown() then fillEditor(profile,key);refreshProfileStats() end
end
local function confirmForgive(btn)
  if not selectedKey or not DB.debts[selectedKey] then
    whisper("This borrower has no active debt.");return
  end
  if btn.confirmKey==selectedKey and now()-(btn.confirmAt or 0)<=10 then
    btn.confirmKey=nil;btn:SetText("Forgive Debt")
    forgiveDebt(selectedKey)
  else
    btn.confirmKey=selectedKey;btn.confirmAt=now()
    btn:SetText("Confirm Forgive")
    whisper("Click Confirm Forgive again within 10 seconds to close this debt without counting it as repaid.")
  end
end
local function announce(key)
  key=key or selectedKey
  local e=key and DB.debts[key]
  if not e then whisper("Select someone with a saved debt.");return end
  local total,steps=accrue(e)
  local p=(intervals[e.period or 2] or intervals[2]).name:lower()
  if e.period==6 then p="every "..tostring(e.customHours or 24).." hours" end
  local interestDue=math.max(0,total-clampInt(e.principal or 0,0,MAX_COPPER))
  local message=string.format("%s owes %s %s (base %s + %s accrued interest; %.2f%% %s %s; %d periods since %s).",
    shortName(key),shortName(e.creditor or me()),moneyText(total),moneyText(e.principal),moneyText(interestDue),e.rate or 0,typeName(isCompound(e)):lower(),p,steps,date("%Y-%m-%d",e.started or now()))
  local channel=DB.channel or "SAY"
  if channel=="PARTY" and (not IsInGroup or not IsInGroup()) then whisper("Not in a party.");return end
  if channel=="RAID" and (not IsInRaid or not IsInRaid()) then whisper("Not in a raid.");return end
  if channel=="GUILD" and (not IsInGuild or not IsInGuild()) then whisper("Not in a guild.");return end
  SendChatMessage(message,channel)
end

local function makeProfile()
  profile=makePanel("PhantomCollectorBorrowerProfile",640,616)
  profile:SetFrameStrata("FULLSCREEN_DIALOG")
  profile.title:SetText("PhantomCollector  |  Borrower Profile")
  profile.who=label(profile,"",18,-53,600)
  label(profile,"LIFETIME BORROWING",18,-82,280)
  label(profile,"ACCOUNT & TRADE ACTIVITY",348,-82,275)
  profile.borrowed=label(profile,"",18,-110,305)
  profile.repaid=label(profile,"",18,-135,305)
  profile.interest=label(profile,"",18,-160,305)
  profile.forgiven=label(profile,"",18,-185,305)
  profile.owed=label(profile,"",348,-110,275)
  profile.loanCount=label(profile,"",348,-135,275)
  profile.tradeCount=label(profile,"",348,-160,275)
  profile.lastTrade=label(profile,"",348,-185,275)
  profile.disclaimer=label(profile,"",18,-214,600)
  profile.disclaimer:SetTextColor(0.82,0.82,0.86)
  local sep=profile:CreateTexture(nil,"ARTWORK")
  sep:SetPoint("TOPLEFT",profile,"TOPLEFT",18,-245);sep:SetSize(603,2)
  profile.divider=sep
  label(profile,"EDIT CURRENT BALANCE & INTEREST",18,-256,400)
  label(profile,"Gold",18,-287);label(profile,"Silver",123,-287);label(profile,"Copper",228,-287)
  label(profile,"Interest %",335,-287);label(profile,"Interval",450,-287)
  profile.gold=edit(profile,83,18,-305,true)
  profile.silver=edit(profile,83,123,-305,true)
  profile.copper=edit(profile,83,228,-305,true)
  trackAmountEdits(profile)
  profile.rate=edit(profile,83,335,-305,false)
  profile.period=2
  profile.periodBtn=button(profile,"Daily",168,24,450,-305,function() cyclePeriod(profile) end)
  profile.hoursLabel=label(profile,"Custom hours",450,-340,100)
  profile.hours=edit(profile,70,548,-335,true)
  label(profile,"Interest type",18,-340)
  profile.compoundBtn=button(profile,"Compound",120,24,123,-335,function() setCompound(profile,not profile.compound) end)
  local note=label(profile,"Edit the amount currently owed. Saving restarts the interest period; changes are recorded in history.",18,-374,606)
  note:SetTextColor(0.82,0.82,0.88)
  button(profile,"Save Changes",142,28,18,-400,function() saveFrom(profile) end)
  button(profile,"Announce",142,28,178,-400,function() announce(selectedKey) end)
  profile.forgiveBtn=button(profile,"Forgive Debt",142,28,338,-400,function(self) confirmForgive(self) end)
  label(profile,"RECENT BORROWING HISTORY",18,-449,350)
  profile.history={}
  for i=1,5 do
    local t=label(profile,"",18,-471-(i-1)*25,604)
    t:SetTextColor(0.91,0.91,0.95)
    profile.history[i]=t
  end
  profile:SetScript("OnShow",function() theme(profile) end)
  local elapsed=0
  profile:SetScript("OnUpdate",function(self,dt)
    elapsed=elapsed+dt
    if elapsed>=15 then elapsed=0;refreshProfileStats() end
  end)
  return profile
end
refreshProfileStats=function()
  if not profile or not selectedKey or not profile:IsShown() then return end
  local key=selectedKey
  local s=statsFor(key)
  local e=DB.debts[key]
  local total=e and accrue(e) or 0
  local runningInterest=e and math.max(0,total-clampInt(e.principal or 0,0,MAX_COPPER)) or 0
  local c=DB.contacts[key] or {}
  profile.who:SetText("Borrower: "..key.."   |   Creditor: "..shortName(e and e.creditor or me()))
  profile.borrowed:SetText("Total borrowed: |cffffd372"..moneyText(s.borrowed or 0).."|r")
  profile.repaid:SetText("Total balance reductions: "..moneyText(s.repaid or 0))
  profile.interest:SetText("Interest generated: "..moneyText((s.interestGenerated or 0)+runningInterest))
  profile.forgiven:SetText("Debt forgiven: "..moneyText(s.forgiven or 0))
  profile.owed:SetText("Currently owed: |cffffd372"..moneyText(total).."|r")
  profile.loanCount:SetText(string.format("Loan additions: %d  |  Reductions: %d",s.loans or 0,s.payments or 0))
  profile.tradeCount:SetText(string.format("New trades recorded: %d",c.tradeCount or 0))
  profile.lastTrade:SetText("Last trade: "..fmtDate(c.lastTradeAt or (c.trader and c.lastSeen)))
  if s.imported then
    profile.disclaimer:SetText("Older debt imported as opening balance; earlier transactions cannot be recovered.")
  else
    profile.disclaimer:SetText("Tracked since: "..fmtDate(s.firstLoan or c.firstSeen).."   |   Last loan: "..fmtDate(s.lastLoan))
  end
  local h=historyFor(key)
  for i=1,#profile.history do
    local entry=h[i]
    if entry then
      local amount=(entry.amount or 0)>0 and "  "..moneyText(entry.amount) or ""
      profile.history[i]:SetText(date("%m/%d/%y %H:%M",entry.at or now()).."  "..(entry.kind or "Update")..amount)
    else profile.history[i]:SetText(i==1 and "No recorded changes yet." or "") end
  end
end
local function openProfile(key)
  if not key then return end
  if not profile then makeProfile() end
  profile:Show()
  fillEditor(profile,key)
  refreshProfileStats()
end
setFields=function(key)
  selectedKey=key
  if ui and ui.forgiveBtn then ui.forgiveBtn:SetText("Forgive Debt");ui.forgiveBtn.confirmKey=nil end
  if profile and profile.forgiveBtn then profile.forgiveBtn:SetText("Forgive Debt");profile.forgiveBtn.confirmKey=nil end
  if not ui then return end
  ui.contact:SetText(key and shortName(key) or "No contact selected")
  fillEditor(ui,key)
  local e=key and DB.debts[key]
  if e then
    local total,steps=accrue(e)
    ui.current:SetText("Current owed: "..moneyText(total).."  ("..steps.." periods)")
    ui.created:SetText("Interest started: "..fmtDate(e.started))
  else
    ui.current:SetText("Current owed: 0g 0s 0c")
    ui.created:SetText("No active debt")
  end
  populate()
end

-- Removes contacts with no active debt. Borrower stats/history are kept, so
-- re-adding a cleared player brings their profile back.
local function clearNoDebt()
  local removed=0
  for key in pairs(DB.contacts) do
    if not DB.debts[key] then DB.contacts[key]=nil;removed=removed+1 end
  end
  if ui then ui.offset=0 end
  if selectedKey and not DB.contacts[selectedKey] then
    if profile and profile:IsShown() then profile:Hide() end
    setFields(nil)
  else
    populate()
  end
  whisper(string.format("Cleared %d contact%s with no active debt.",removed,removed==1 and "" or "s"))
end
confirmClearNoDebt=function(btn)
  if btn.confirming and now()-(btn.confirmAt or 0)<=10 then
    btn.confirming=nil;btn:SetText("Clear No-Debt")
    clearNoDebt()
  else
    btn.confirming=true;btn.confirmAt=now()
    btn:SetText("Confirm Clear")
    whisper("Click Confirm Clear again within 10 seconds to remove every contact without an active debt.")
  end
end

local function makeSettings()
  local s=makePanel("PhantomCollectorSettings",365,350)
  s.title:SetText("PhantomCollector Settings")
  label(s,"Color palette",16,-52)
  s.themeBtn=button(s,"",185,25,155,-47,function()
    DB.palette=(DB.palette%#palettes)+1
    s.themeBtn:SetText(palettes[DB.palette].name)
    theme(ui);theme(profile);theme(s)
  end)
  label(s,"Announce channel",16,-90)
  s.channelBtn=button(s,"",185,25,155,-85,function()
    local order={"SAY","PARTY","RAID","GUILD"}
    local cur=1;for i,v in ipairs(order) do if DB.channel==v then cur=i end end
    DB.channel=order[cur%#order+1];s.channelBtn:SetText(DB.channel)
  end)
  label(s,"Default interest",16,-130)
  s.compoundBtn=button(s,"",185,25,155,-125,function()
    DB.compound=not DB.compound
    s.compoundBtn:SetText(DB.compound and "Compounding" or "Simple")
    -- Only changes the default for new debts; existing debts keep their own type.
    if not (selectedKey and DB.debts[selectedKey]) then
      setFields(selectedKey)
      if profile and profile:IsShown() then fillEditor(profile,selectedKey) end
    end
  end)
  label(s,"Trade reminders",16,-170)
  s.tradeBtn=button(s,"",185,25,155,-165,function()
    DB.tradeNotice=not DB.tradeNotice
    s.tradeBtn:SetText(DB.tradeNotice and "Enabled" or "Disabled")
  end)
  label(s,"Minimap button",16,-210)
  s.minimapBtn=button(s,"",185,25,155,-205,function()
    DB.minimap.hide=not DB.minimap.hide
    s.minimapBtn:SetText(DB.minimap.hide and "Hidden" or "Shown")
    if PC.updateMinimap then PC.updateMinimap() end
  end)
  local help=label(s,"Click a trade contact to open their borrower profile.\nDefault interest applies to new debts only; each\nborrower can be set to Compound or Simple.\nDrag the minimap button to move it.",16,-252,329)
  help:SetTextColor(0.85,0.85,0.9)
  s:SetScript("OnShow",function()
    s.themeBtn:SetText(palettes[DB.palette].name)
    s.channelBtn:SetText(DB.channel)
    s.compoundBtn:SetText(DB.compound and "Compounding" or "Simple")
    s.tradeBtn:SetText(DB.tradeNotice and "Enabled" or "Disabled")
    s.minimapBtn:SetText(DB.minimap.hide and "Hidden" or "Shown")
    theme(s)
  end)
  return s
end
local function makeMain()
  ui=makePanel("PhantomCollectorMain",700,479)
  ui.title:SetText("PhantomCollector  |  Debt Ledger")
  button(ui,"Settings",88,23,565,-40,function() PC.toggleSettings() end)
  ui.status=label(ui,"",15,-47,300)
  local d=ui:CreateTexture(nil,"ARTWORK")
  d:SetPoint("TOPLEFT",ui,"TOPLEFT",255,-77);d:SetSize(2,371);ui.divider=d
  label(ui,"Trade contacts",15,-87,110)
  ui.clearBtn=button(ui,"Clear No-Debt",110,22,126,-82,function(self) confirmClearNoDebt(self) end)
  ui.rows={};ui.offset=0
  for i=1,11 do
    local b=button(ui,"",224,25,12,-108-(i-1)*27,function(self)
      if self.key then setFields(self.key);openProfile(self.key) end
    end)
    local t=b:GetFontString();if t then t:SetJustifyH("LEFT") end
    ui.rows[#ui.rows+1]=b
  end
  button(ui,"Prev",60,22,13,-421,function()
    ui.offset=math.max(0,ui.offset-11);populate()
  end)
  button(ui,"Next",60,22,179,-421,function()
    ui.offset=math.min(math.max(0,#sortedKeys()-11),ui.offset+11);populate()
  end)
  ui.page=label(ui,"",80,-425,104)
  label(ui,"Add/select player",274,-91)
  ui.newName=edit(ui,160,397,-85)
  button(ui,"Add / Select",109,25,568,-85,function()
    local key=ensure(ui.newName:GetText(),false)
    if key then setFields(key);ui.newName:SetText("");openProfile(key)
    else whisper("Enter a player name.") end
  end)
  ui.contact=label(ui,"No contact selected",275,-130,382)
  label(ui,"Current balance (gold / silver / copper)",275,-157,383)
  label(ui,"Gold",275,-178);label(ui,"Silver",382,-178);label(ui,"Copper",489,-178)
  ui.gold=edit(ui,84,275,-197,true)
  ui.silver=edit(ui,84,382,-197,true)
  ui.copper=edit(ui,84,489,-197,true)
  trackAmountEdits(ui)
  label(ui,"Interest %",275,-237)
  ui.rate=edit(ui,76,360,-231,false)
  label(ui,"Interval",456,-237)
  ui.period=2
  ui.periodBtn=button(ui,"Daily",150,24,525,-231,function() cyclePeriod(ui) end)
  ui.hoursLabel=label(ui,"Custom hours",275,-274)
  ui.hours=edit(ui,78,381,-269,true)
  label(ui,"Type",480,-274)
  ui.compoundBtn=button(ui,"Compound",150,24,525,-269,function() setCompound(ui,not ui.compound) end)
  ui.created=label(ui,"No active debt",275,-310,374)
  ui.current=label(ui,"Current owed: 0g 0s 0c",275,-333,390)
  button(ui,"Save Debt",125,28,275,-365,function() saveFrom(ui) end)
  button(ui,"Announce",125,28,413,-365,function() announce(selectedKey) end)
  ui.forgiveBtn=button(ui,"Forgive Debt",125,28,550,-365,function(self) confirmForgive(self) end)
  label(ui,"Editing the owed balance restarts its interest period.",275,-413,390)
  local hint=label(ui,"/pc  |  /pc add NAME  |  /pc minimap  |  Click a name for stats",275,-443,406)
  hint:SetTextColor(0.75,0.75,0.8)
  ui:SetScript("OnShow",function() theme(ui);setFields(selectedKey) end)
  local elapsed=0
  ui:SetScript("OnUpdate",function(self,dt)
    elapsed=elapsed+dt
    if elapsed<15 then return end
    elapsed=0
    populate()
    local e=selectedKey and DB.debts[selectedKey]
    if e then
      local total,steps=accrue(e)
      ui.current:SetText("Current owed: "..moneyText(total).."  ("..steps.." periods)")
    end
    refreshProfileStats()
  end)
  return ui
end
local function toggleMain()
  if not ui then makeMain() end
  if ui:IsShown() then ui:Hide() else ui:Show() end
end
local function toggleSettings()
  if not PC.settings then PC.settings=makeSettings() end
  if PC.settings:IsShown() then PC.settings:Hide() else PC.settings:Show() end
end
PC.toggleSettings=toggleSettings

-- Minimap button: left-click opens the ledger, right-click opens settings,
-- drag to move it around the minimap edge (position is saved).
local minimapBtn
local function positionMinimap()
  local a=math.rad(DB.minimap.angle or 200)
  local r=(Minimap:GetWidth()/2)+10
  minimapBtn:ClearAllPoints()
  minimapBtn:SetPoint("CENTER",Minimap,"CENTER",math.cos(a)*r,math.sin(a)*r)
end
local function makeMinimapButton()
  if minimapBtn or not Minimap then return end
  local b=CreateFrame("Button","PhantomCollectorMinimapButton",Minimap)
  b:SetSize(31,31);b:SetFrameStrata("MEDIUM");b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp","RightButtonUp");b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local bg=b:CreateTexture(nil,"BACKGROUND")
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background");bg:SetSize(20,20)
  bg:SetPoint("TOPLEFT",b,"TOPLEFT",7,-5)
  local icon=b:CreateTexture(nil,"ARTWORK")
  icon:SetSize(20,20);icon:SetPoint("TOPLEFT",b,"TOPLEFT",7,-5)
  -- The Auctioneer tracking art is a gold money bag; fall back to a bag icon.
  if icon:SetTexture("Interface\\Minimap\\Tracking\\Auctioneer")==false then
    icon:SetTexture(ICON);icon:SetTexCoord(0.08,0.92,0.08,0.92)
  end
  b.icon=icon
  local border=b:CreateTexture(nil,"OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder");border:SetSize(53,53)
  border:SetPoint("TOPLEFT",b,"TOPLEFT",0,0)
  b:SetScript("OnClick",function(_,btn)
    if btn=="RightButton" then toggleSettings() else toggleMain() end
  end)
  b:SetScript("OnDragStart",function(self)
    self:SetScript("OnUpdate",function()
      local mx,my=Minimap:GetCenter()
      local cx,cy=GetCursorPosition()
      local scale=Minimap:GetEffectiveScale()
      DB.minimap.angle=math.deg(math.atan2(cy/scale-my,cx/scale-mx))
      positionMinimap()
    end)
  end)
  b:SetScript("OnDragStop",function(self) self:SetScript("OnUpdate",nil) end)
  b:SetScript("OnEnter",function(self)
    GameTooltip:SetOwner(self,"ANCHOR_LEFT")
    GameTooltip:AddLine("PhantomCollector")
    local n,total=0,0
    for _,e in pairs(DB.debts) do n=n+1;total=total+accrue(e) end
    GameTooltip:AddLine(string.format("%d active debts  |  %s owed",n,moneyText(total)),1,1,1)
    GameTooltip:AddLine("Left-click: open ledger",0.8,0.8,0.8)
    GameTooltip:AddLine("Right-click: settings",0.8,0.8,0.8)
    GameTooltip:AddLine("Drag: move button",0.8,0.8,0.8)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave",function() GameTooltip:Hide() end)
  minimapBtn=b
end
PC.updateMinimap=function()
  makeMinimapButton()
  if not minimapBtn then return end
  positionMinimap()
  if DB.minimap.hide then minimapBtn:Hide() else minimapBtn:Show() end
end
local function detectTrade()
  local targetName
  if TradeFrameRecipientNameText and TradeFrameRecipientNameText.GetText then
    targetName=TradeFrameRecipientNameText:GetText()
  end
  if (not targetName or targetName=="") and UnitExists("NPC") and UnitIsPlayer("NPC") then
    targetName=UnitName("NPC")
  end
  if (not targetName or targetName=="") and UnitExists("target") and UnitIsPlayer("target") then
    targetName=UnitName("target")
  end
  if not targetName or targetName=="" then return end
  local key,newTrade=ensure(targetName,true)
  if key and newTrade and DB.tradeNotice then whisper("Trade opened with "..shortName(key)..". Contact recorded; click them in /pc to see stats.") end
  if ui and ui:IsShown() then populate() end
  if profile and profile:IsShown() and key==selectedKey then refreshProfileStats() end
end
PC:RegisterEvent("ADDON_LOADED")
PC:RegisterEvent("PLAYER_LOGIN")
PC:RegisterEvent("TRADE_SHOW")
PC:SetScript("OnEvent",function(self,event,...)
  if event=="ADDON_LOADED" then
    if (...)~=ADDON then return end
    PhantomCollectorDB=PhantomCollectorDB or {}
    DB=PhantomCollectorDB
    DB.contacts=DB.contacts or {}
    DB.debts=DB.debts or {}
    DB.borrowers=DB.borrowers or {}
    DB.history=DB.history or {}
    DB.palette=clampInt(DB.palette or 1,1,#palettes)
    DB.channel=DB.channel or "SAY"
    if DB.compound==nil then DB.compound=true end
    if DB.tradeNotice==nil then DB.tradeNotice=true end
    DB.minimap=DB.minimap or {angle=200,hide=false}
    -- v3: lock existing debts to the interest type they used before interest
    -- type became per-borrower, so changing the default can't alter them.
    for _,e in pairs(DB.debts) do
      if e.compound==nil then e.compound=DB.compound~=false end
    end
    DB.version=3
  elseif event=="PLAYER_LOGIN" then
    SLASH_PHANTOMCOLLECTOR1="/pc"
    SLASH_PHANTOMCOLLECTOR2="/phantomcollector"
    SlashCmdList.PHANTOMCOLLECTOR=function(msg)
      local sub,arg=clean(msg):match("^(%S+)%s*(.-)%s*$")
      if sub=="add" and arg and arg~="" then
        local key=ensure(arg,false)
        if not ui then makeMain() end
        ui:Show();setFields(key);openProfile(key)
      elseif sub=="minimap" then
        DB.minimap.hide=not DB.minimap.hide
        PC.updateMinimap()
        whisper("Minimap button "..(DB.minimap.hide and "hidden" or "shown")..".")
      else toggleMain() end
    end
    PC.updateMinimap()
    whisper("Ready. /pc opens your ledger; click a trade contact for their borrower profile.")
  elseif event=="TRADE_SHOW" and DB then
    detectTrade()
    if C_Timer and C_Timer.After then C_Timer.After(0.2,detectTrade) end
  end
end)
