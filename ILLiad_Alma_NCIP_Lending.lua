--About ALMA_NCIP_Lending_Client 1.4
--Author:  Bill Jones III, SUNY Geneseo, IDS Project, jonesw@geneseo.edu
--Modified by: Kurt Munson, Northwestern University, kmunson@northwestern.edu
--Modified further by: Matt Niehoff, Minitex - University of Minnesota, nieho003@umn.edu    
--Holds cancellation API functionaltiy added by Robert Wilson, University of Minnesota, wils3107@umn.edu
--System Addon used for ILLiad to communicate with Alma through the NCIP protocol to move
--Lending requests into the resource sharing libary in Alma when updated to filled and
--to return items to thier perment location upon return.

local Settings = {};

--NCIP Responder URL
Settings.NCIP_Responder_URL = GetSetting("NCIP_Responder_URL");

--Alma REST API Settings
Settings.Alma_API_URL = GetSetting("Alma_API_URL");
Settings.Alma_API_Key = GetSetting("Alma_API_Key");

--Cancel Hold Configuration
Settings.DoCancelHold = GetSetting("Cancel_Alma_Hold_Before_Checkout"); 
Settings.HoldIdField = GetSetting("Alma_Hold_ID_Field");

--NCIP Error Status Changes
Settings.LendingCheckOutItemFailQueue = GetSetting("LendingCheckOutItemFailQueue");
Settings.LendingCheckInItemFailQueue = GetSetting("LendingCheckInItemFailQueue");

--acceptItem settings
Settings.acceptItem_from_uniqueAgency_value = GetSetting("acceptItem_from_uniqueAgency_value");
Settings.ApplicationProfileType = GetSetting("ApplicationProfileType");
Settings.checkOutItem_RequestIdentifierValue_Prefix = GetSetting("checkOutItem_RequestIdentifierValue_Prefix") or "";
Settings.ILLiad_field_to_get_barcode = GetSetting("ILLiad_field_to_get_barcode");

function Init()	
    LogDebug("DEBUG -- In INIT");
    RegisterSystemEventHandler("LendingRequestCheckOut", "LendingCheckOutItem");
    RegisterSystemEventHandler("LendingRequestCheckIn", "LendingCheckInItem");
end

function hasValue(s)
    return s ~= nil and s:match("%S") ~= nil
end

-- =================================================================================
-- LENDING CHECKOUT (Mark Found)
-- =================================================================================
function LendingCheckOutItem(transactionProcessedEventArgs)
    LogDebug("DEBUG -- LendingCheckOutItem - start");
    luanet.load_assembly("System");
    luanet.load_assembly("System.Xml");
    local ncipAddress = Settings.NCIP_Responder_URL;

    local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
    local currentTN = luanet.import_type("System.Convert").ToDouble(currentTN_int);
    local refnumber = GetFieldValue("Transaction", Settings.ILLiad_field_to_get_barcode);
    
    -- PRE-CHECKOUT: Cancel internal Alma hold if enabled
    if Settings.DoCancelHold then
        local rawHoldInfo = GetFieldValue("Transaction", Settings.HoldIdField); 
        
        if hasValue(rawHoldInfo) and not string.find(rawHoldInfo:lower(), "cancelled") then
            local holdId = string.match(rawHoldInfo, "%d+");
            
            if holdId and hasValue(refnumber) then
                local barcode = refnumber:match("%S+");
                LogDebug("Attempting to cancel Alma Hold ID: " .. holdId);
                
                -- Pass Transaction Number as the cancellation note
                local success = AttemptCancelHold(barcode, holdId, "AdditionalReason05", tostring(currentTN_int));
                if success then
                    -- Note indicating reason and note sent to Alma
                    ExecuteCommand("AddNote", {currentTN, "Cancelled Hold Before NCIP CheckOut " .. holdId .. ". Note: TN" .. tostring(currentTN_int)});
                    SetFieldValue("Transaction", Settings.HoldIdField, "Cancelled " .. holdId);
                    SaveDataSource("Transaction");
                end
            end
        end
    end

    if not hasValue(refnumber) then
        ExecuteCommand("Route", {currentTN, "NCIP Error: LCheckOut-No Barcode"});
        ExecuteCommand("AddNote", {currentTN, "No barcode added before checkout. Not checked out in Alma."});
        SaveDataSource("Transaction");
        do return end
    end
    
    for barcode in refnumber:gmatch("%S+") do
        local LCOImessage = buildCheckOutItem(barcode);
        local WebClient = luanet.import_type("System.Net.WebClient");
        local myWebClient = WebClient();
        myWebClient.Headers:Add("Content-Type", "text/xml; charset=UTF-8");
        
        local LCOIresponseArray = myWebClient:UploadString(ncipAddress, LCOImessage);

        if string.find(LCOIresponseArray, "Problem") or string.find(LCOIresponseArray, "Ineligible") or string.find(LCOIresponseArray, "Unknown") then
            ExecuteCommand("Route", {currentTN, Settings.LendingCheckOutItemFailQueue});
            ExecuteCommand("AddNote", {currentTN, barcode .. " NCIP error: " .. LCOIresponseArray});
            SaveDataSource("Transaction");
            do return end
        end
    end
    
    ExecuteCommand("AddNote", {currentTN, "NCIP Response for LendingCheckOutItem received successfully"});
    SaveDataSource("Transaction");	
end

-- =================================================================================
-- LENDING CHECKIN (Returns)
-- =================================================================================
function LendingCheckInItem(transactionProcessedEventArgs)
    luanet.load_assembly("System");
    local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
    local currentTN = luanet.import_type("System.Convert").ToDouble(currentTN_int);
    local refnumber = GetFieldValue("Transaction", Settings.ILLiad_field_to_get_barcode);
    local ncipAddress = Settings.NCIP_Responder_URL;

    if not hasValue(refnumber) then
        ExecuteCommand("AddNote", {currentTN, "No value in NCIP Barcode Field, NCIP not executed on CheckIn."});
        SaveDataSource("Transaction");
        do return end
    end

    for barcode in refnumber:gmatch("%S+") do
        local LCIImessage = buildCheckInItemLending(barcode);
        local WebClient = luanet.import_type("System.Net.WebClient");
        local myWebClient = WebClient();
        myWebClient.Headers:Add("Content-Type", "text/xml; charset=UTF-8");
        local LCIIresponseArray = myWebClient:UploadString(ncipAddress, LCIImessage);
        
        if string.find(LCIIresponseArray, "Problem") or string.find(LCIIresponseArray, "Unknown") then
            ExecuteCommand("Route", {currentTN, Settings.LendingCheckInItemFailQueue});
            ExecuteCommand("AddNote", {currentTN, barcode .. " NCIP error: " .. LCIIresponseArray});
            SaveDataSource("Transaction");
            do return end
        end
    end
    
    ExecuteCommand("AddNote", {currentTN, "NCIP Response for LendingCheckInItem received successfully"});
    SaveDataSource("Transaction");	
end

-- =================================================================================
-- ALMA REST API HELPERS
-- =================================================================================

function AttemptCancelHold(barcode, requestId, reason, note)
    local mms, hold, pid = Rest_GetItemIds(barcode);
    if not mms then return false end

    -- Correct URL formatting with Reason and Note
    local url = Settings.Alma_API_URL .. "bibs/" .. mms .. "/holdings/" .. hold .. "/items/" .. pid .. "/requests/" .. requestId .. 
                "?reason=" .. reason .. "&note=" .. note .. "&apikey=" .. Settings.Alma_API_Key;
    
    local WebClient = luanet.import_type("System.Net.WebClient");
    local client = WebClient();
    
    local success, result = pcall(function() 
        return client:UploadString(url, "DELETE", "");
    end);

    return success;
end

function Rest_GetItemIds(barcode)
    local url = Settings.Alma_API_URL .. "items?item_barcode=" .. barcode .. "&apikey=" .. Settings.Alma_API_Key;
    local WebClient = luanet.import_type("System.Net.WebClient");
    local client = WebClient();
    client.Headers:Add("Accept", "application/xml");
    
    local success, result = pcall(function() return client:DownloadString(url) end);
    if not success then return nil end
    
    local XmlDocument = luanet.import_type("System.Xml.XmlDocument");
    local doc = XmlDocument();
    doc:LoadXml(result);
    
    local mms = doc:SelectSingleNode("//bib_data/mms_id");
    local hold = doc:SelectSingleNode("//holding_data/holding_id");
    local pid = doc:SelectSingleNode("//item_data/pid");
    
    if mms and hold and pid then
        return mms.InnerText, hold.InnerText, pid.InnerText;
    end
    return nil;
end

-- =================================================================================
-- NCIP XML BUILDERS
-- =================================================================================

function buildCheckInItemLending(barcode)
    return '<?xml version="1.0" encoding="ISO-8859-1"?>' ..
    '<NCIPMessage xmlns="http://www.niso.org/2008/ncip" version="http://www.niso.org/schemas/ncip/v2_02/ncip_v2_02.xsd">' ..
    '<CheckInItem><InitiationHeader><FromAgencyId><AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId></FromAgencyId>' ..
    '<ToAgencyId><AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId></ToAgencyId>' ..
    '<ApplicationProfileType>' .. Settings.ApplicationProfileType .. '</ApplicationProfileType></InitiationHeader>' ..
    '<ItemId><AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId><ItemIdentifierValue>' .. barcode .. '</ItemIdentifierValue></ItemId>' ..
    '</CheckInItem></NCIPMessage>';
end

function buildCheckOutItem(barcode)
    local dr = tostring(GetFieldValue("Transaction", "DueDate"));
    local df = string.match(dr, "%d+/%d+/%d+");
    local mn, dy, yr = string.match(df, "(%d+)/(%d+)/(%d+)");
    local tn = Settings.checkOutItem_RequestIdentifierValue_Prefix .. GetFieldValue("Transaction", "TransactionNumber");
    
    return '<?xml version="1.0" encoding="ISO-8859-1"?>' ..
    '<NCIPMessage xmlns="http://www.niso.org/2008/ncip" version="http://www.niso.org/schemas/ncip/v2_02/ncip_v2_02.xsd">' ..
    '<CheckOutItem><InitiationHeader><FromAgencyId><AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId></FromAgencyId>' ..
    '<ToAgencyId><AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId></ToAgencyId>' ..
    '<ApplicationProfileType>' .. Settings.ApplicationProfileType .. '</ApplicationProfileType></InitiationHeader>' ..
    '<UserId><UserIdentifierValue>pseudopatron</UserIdentifierValue></UserId>' ..
    '<ItemId><AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId><ItemIdentifierValue>' .. barcode .. '</ItemIdentifierValue></ItemId>' ..
    '<RequestId><AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId><RequestIdentifierValue>' .. tn .. '</RequestIdentifierValue></RequestId>' ..
    '<DesiredDateDue>' .. yr .. '-' .. string.format("%02d",mn) .. '-' .. string.format("%02d",dy) .. 'T23:59:00' .. '</DesiredDateDue>' ..
    '</CheckOutItem></NCIPMessage>';
end