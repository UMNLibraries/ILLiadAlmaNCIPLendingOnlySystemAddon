--About ALMA_NCIP_Lending_Client 1.4
--Author:  Bill Jones III, SUNY Geneseo, IDS Project, jonesw@geneseo.edu
--Modified by: Kurt Munson, Northwestern University, kmunson@northwestern.edu
--Modified further by: Matt Niehoff, Minitex - University of Minnesota, nieho003@umn.edu    
--API functionaltiy added by Robert Wilson, University of Minnesota. 
--System Addon used for ILLiad to communicate with Alma through the NCIP protocol to move
--Lending requests into the resource sharing libary in Alma when updated to filled and
--to return items to thier perment location upon return.
--
--Description of Registered Event Handlers for ILLiad
--
--LendingRequestCheckOut
--This will trigger whenever a transaction is processed from the Lending Update Stacks Searching form
--using the Mark Found or Mark Found Scan Now buttons. This will also work on the Lending Processing ribbon
--of the Request form for the Mark Found and Mark Found Scan Now buttons.
--
--LendingRequestCheckIn
--This will trigger whenever a transaction is processed from the Lending Returns batch processing form.
--
--Queue names have a limit of 40 characters (including spaces).


local Settings = {};

--NCIP Responder URL
Settings.NCIP_Responder_URL = GetSetting("NCIP_Responder_URL");

--Alma REST API Settings
Settings.Alma_API_URL = GetSetting("Alma_API_URL");
Settings.Alma_API_Key = GetSetting("Alma_API_Key");

--Cancel Hold Configuration
Settings.DoCancelHold = GetSetting("Cancel_Alma_Hold_Before_Checkout"); -- Returns boolean true/false
Settings.HoldIdField = GetSetting("Alma_Hold_ID_Field");

--NCIP Error Status Changes
Settings.LendingCheckOutItemFailQueue = GetSetting("LendingCheckOutItemFailQueue");
Settings.LendingCheckInItemFailQueue = GetSetting("LendingCheckInItemFailQueue");

--acceptItem settings
Settings.acceptItem_from_uniqueAgency_value = GetSetting("acceptItem_from_uniqueAgency_value");
Settings.acceptItem_Transaction_Prefix = GetSetting("checkInItem_Transaction_Prefix");

--checkInItem settings
Settings.ApplicationProfileType = GetSetting("ApplicationProfileType");
Settings.checkInItem_Transaction_Prefix = GetSetting("checkInItem_Transaction_Prefix");

--checkOutItem settings
Settings.checkOutItem_RequestIdentifierValue_Prefix = GetSetting("checkOutItem_RequestIdentifierValue_Prefix");

--Change ILLiad field for grabbing the Barcode from ILLiad to send to Alma
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
    
    -- [NEW] PRE-CHECKOUT: Check configuration and cancel hold if enabled
    if Settings.DoCancelHold then
        local rawHoldInfo = GetFieldValue("Transaction", Settings.HoldIdField); 
        
        -- We only proceed if we have text in the field AND it doesn't say "Cancelled" already
        if hasValue(rawHoldInfo) and not string.find(rawHoldInfo, "Cancelled") then
            
            -- Extract the first sequence of digits (e.g. "Created 12345" -> "12345")
            local holdId = string.match(rawHoldInfo, "%d+");
            
            if holdId and hasValue(refnumber) then
                LogDebug("Found potential Internal Hold ID: " .. holdId .. " in field " .. Settings.HoldIdField);
                
                -- Loop through barcodes (usually just one)
                for barcode in refnumber:gmatch("%S+") do
                    local success = AttemptCancelHold(barcode, holdId);
                    if success then
                        LogDebug("Successfully cancelled Internal Hold " .. holdId);
                        ExecuteCommand("AddNote", {currentTN, "Auto-cancelled Internal Hold " .. holdId .. " to prepare for NCIP."});
                        
                        -- Update the field so we know it's done (preserves the ID but adds status)
                        SetFieldValue("Transaction", Settings.HoldIdField, "Cancelled " .. holdId);
                        SaveDataSource("Transaction");
                    else
                        LogDebug("Failed to cancel Internal Hold (or it was already gone). Proceeding with NCIP.");
                    end
                    break; -- Try only the first barcode found
                end
            else
                LogDebug("No numeric ID found in " .. Settings.HoldIdField .. ". Skipping cancel.");
            end
        end
    end
    -- [END NEW SECTION]

	if not hasValue(refnumber) then
			LogDebug("No Barcode Error: ReRouting Transaction");
			ExecuteCommand("Route", {currentTN, "NCIP Error: LCheckOut-User Ineligible"});
			ExecuteCommand("AddNote", {currentTN, "No barcode added to " .. Settings.ILLiad_field_to_get_barcode .. " before checkout. Not checked out in Alma."});
			SaveDataSource("Transaction");
		do return end
	end
	
	for barcode in refnumber:gmatch("%S+") do
			local LCOImessage = buildCheckOutItem(barcode);
			LogDebug("creating LendingCheckOutItem message[" .. LCOImessage .. "]");
			local WebClient = luanet.import_type("System.Net.WebClient");
			local myWebClient = WebClient();
			myWebClient.Headers:Add("Content-Type", "text/xml; charset=UTF-8");
			
            local LCOIresponseArray = myWebClient:UploadString(ncipAddress, LCOImessage);
			LogDebug("Upload response was[" .. LCOIresponseArray .. "]");

			if string.find(LCOIresponseArray, "Apply to circulation desk - Loan cannot be renewed (no change in due date)") then
                ExecuteCommand("Route", {currentTN, "NCIP Error: LCheckOut-No Change Due Date"});
                ExecuteCommand("AddNote", {currentTN, barcode .. " gave an NCIP error: " .. LCOIresponseArray});
                SaveDataSource("Transaction");
                do return end
			elseif string.find(LCOIresponseArray, "User Ineligible To Check Out This Item") then
                ExecuteCommand("Route", {currentTN, "NCIP Error: LCheckOut-User Ineligible"});
                ExecuteCommand("AddNote", {currentTN, barcode .. " gave an NCIP error: " .. LCOIresponseArray});
                SaveDataSource("Transaction");
                do return end
			elseif string.find(LCOIresponseArray, "User Unknown") then
                ExecuteCommand("Route", {currentTN, "NCIP Error: LCheckOut-User Unknown"});
                ExecuteCommand("AddNote", {currentTN, barcode .. " gave an NCIP error: " .. LCOIresponseArray});
                SaveDataSource("Transaction");
                do return end
			elseif string.find(LCOIresponseArray, "Problem") then
                ExecuteCommand("Route", {currentTN, Settings.LendingCheckOutItemFailQueue});
                ExecuteCommand("AddNote", {currentTN, barcode .. " gave an NCIP error: " .. LCOIresponseArray});
                SaveDataSource("Transaction");
                do return end
			end
	end
	
	LogDebug("No Problems found in NCIP Response.")
	ExecuteCommand("AddNote", {currentTN, "NCIP Response for LendingCheckOutItem received successfully"});
    SaveDataSource("Transaction");	
end

-- =================================================================================
-- LENDING CHECKIN (Returns)
-- =================================================================================
function LendingCheckInItem(transactionProcessedEventArgs)
	LogDebug("LendingCheckInItem - start");
	luanet.load_assembly("System");
	local ncipAddress = Settings.NCIP_Responder_URL;
	
	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local currentTN = luanet.import_type("System.Convert").ToDouble(currentTN_int);
	local refnumber = GetFieldValue("Transaction", Settings.ILLiad_field_to_get_barcode);
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
		
		if string.find(LCIIresponseArray, "Unknown Item") then
            ExecuteCommand("Route", {currentTN, "NCIP Error: LCheckIn-Unknown Item"});
            ExecuteCommand("AddNote", {currentTN, barcode .. " gave an NCIP error: " .. LCIIresponseArray});
            SaveDataSource("Transaction");
            do return end
		elseif string.find(LCIIresponseArray, "Item Not Checked Out") then
            ExecuteCommand("Route", {currentTN, "NCIP Error: LCheckIn-Not Checked Out"});
            ExecuteCommand("AddNote", {currentTN, barcode .. " gave an NCIP error: " .. LCIIresponseArray});
            SaveDataSource("Transaction");
            do return end
		elseif string.find(LCIIresponseArray, "Problem") then
            ExecuteCommand("Route", {currentTN, Settings.LendingCheckInItemFailQueue});
            ExecuteCommand("AddNote", {currentTN, barcode .. " gave an NCIP error: " .. LCIIresponseArray});
            SaveDataSource("Transaction");
            do return end
		end
	end
	
	LogDebug("No Problems found in NCIP Response.")
	ExecuteCommand("AddNote", {currentTN, "NCIP Response for LendingCheckInItem received successfully"});
    SaveDataSource("Transaction");	
end

-- =================================================================================
-- ALMA REST API HELPERS
-- =================================================================================

function AttemptCancelHold(barcode, requestId)
    -- 1. We must retrieve MMS/Holding/Item IDs first
    local mms, hold, pid = Rest_GetItemIds(barcode);
    if not mms then 
        LogDebug("Could not retrieve item IDs for barcode: " .. barcode);
        return false; 
    end

    -- 2. Send Delete Request
    local url = Settings.Alma_API_URL .. "bibs/" .. mms .. "/holdings/" .. hold .. "/items/" .. pid .. "/requests/" .. requestId .. "?apikey=" .. Settings.Alma_API_Key;
    
    local WebClient = luanet.import_type("System.Net.WebClient");
    local client = WebClient();
    
    local success, result = pcall(function() 
        return client:UploadString(url, "DELETE", "");
    end);

    if success then return true; else return false; end
end

function Rest_GetItemIds(barcode)
    local url = Settings.Alma_API_URL .. "items?item_barcode=" .. barcode .. "&apikey=" .. Settings.Alma_API_Key;
    local WebClient = luanet.import_type("System.Net.WebClient");
    local client = WebClient();
    client.Headers:Add("Accept", "application/xml");
    
    local success, result = pcall(function() return client:DownloadString(url) end);
    if not success then return nil, nil, nil end
    
    -- Simple XML Parsing
    local XmlDocument = luanet.import_type("System.Xml.XmlDocument");
    local doc = XmlDocument();
    doc:LoadXml(result);
    
    local mms = doc:SelectSingleNode("//bib_data/mms_id");
    local hold = doc:SelectSingleNode("//holding_data/holding_id");
    local pid = doc:SelectSingleNode("//item_data/pid");
    
    if mms and hold and pid then
        return mms.InnerText, hold.InnerText, pid.InnerText;
    end
    return nil, nil, nil;
end

-- =================================================================================
-- NCIP XML BUILDERS
-- =================================================================================

function buildCheckInItemLending(barcode)
    local ttype = "";
    local user = GetFieldValue("Transaction", "Username");
    local trantype = GetFieldValue("Transaction", "ProcessType");
    if trantype == "Borrowing" then
        ttype = Settings.checkInItem_Transaction_Prefix .. GetFieldValue("Transaction", "TransactionNumber");
    elseif trantype == "Lending" then
        ttype = barcode;
    else
        ttype = Settings.checkInItem_Transaction_Prefix .. GetFieldValue("Transaction", "TransactionNumber");
    end

    local cil = '<?xml version="1.0" encoding="ISO-8859-1"?>' ..
    '<NCIPMessage xmlns="http://www.niso.org/2008/ncip" version="http://www.niso.org/schemas/ncip/v2_02/ncip_v2_02.xsd">' ..
    '<CheckInItem><InitiationHeader><FromAgencyId><AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId></FromAgencyId>' ..
    '<ToAgencyId><AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId></ToAgencyId>' ..
    '<ApplicationProfileType>' .. Settings.ApplicationProfileType .. '</ApplicationProfileType></InitiationHeader>' ..
    '<UserId><UserIdentifierValue>' .. user .. '</UserIdentifierValue></UserId>' ..
    '<ItemId><AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId><ItemIdentifierValue>' .. barcode .. '</ItemIdentifierValue></ItemId>' ..
    '<RequestId><AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId><RequestIdentifierValue>' .. ttype .. '</RequestIdentifierValue></RequestId>' ..
    '</CheckInItem></NCIPMessage>';
    return cil;
end

function buildCheckOutItem(barcode)
    local dr = tostring(GetFieldValue("Transaction", "DueDate"));
    local df = string.match(dr, "%d+/%d+/%d+");
    local mn, dy, yr = string.match(df, "(%d+)/(%d+)/(%d+)");
    local mnt = string.format("%02d",mn);
    local dya = string.format("%02d",dy);
    local pseudopatron = 'pseudopatron';
    local tn = Settings.checkOutItem_RequestIdentifierValue_Prefix .. GetFieldValue("Transaction", "TransactionNumber");
    
    local coi = '<?xml version="1.0" encoding="ISO-8859-1"?>' ..
    '<NCIPMessage xmlns="http://www.niso.org/2008/ncip" version="http://www.niso.org/schemas/ncip/v2_02/ncip_v2_02.xsd">' ..
    '<CheckOutItem><InitiationHeader><FromAgencyId><AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId></FromAgencyId>' ..
    '<ToAgencyId><AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId></ToAgencyId>' ..
    '<ApplicationProfileType>' .. Settings.ApplicationProfileType .. '</ApplicationProfileType></InitiationHeader>' ..
    '<UserId><UserIdentifierValue>' .. pseudopatron .. '</UserIdentifierValue></UserId>' ..
    '<ItemId><AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId><ItemIdentifierValue>' .. barcode .. '</ItemIdentifierValue></ItemId>' ..
    '<RequestId><AgencyId>' .. Settings.acceptItem_from_uniqueAgency_value .. '</AgencyId><RequestIdentifierValue>' .. tn .. '</RequestIdentifierValue></RequestId>' ..
    '<DesiredDateDue>' .. yr .. '-' .. mnt .. '-' .. dya .. 'T23:59:00' .. '</DesiredDateDue>' ..
    '</CheckOutItem></NCIPMessage>';
    return coi;
end