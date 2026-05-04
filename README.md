# ALMA_NCIP_Lending_Client Addon

## Description
This ILLiad System Addon enables communication between ILLiad and Alma using the NCIP protocol. It automates the process of moving Lending requests into the Alma resource sharing library when updated to 'Filled' and returns items to their permanent locations upon check-in. It also includes functionality to automatically cancel internal Alma holds before checkout to prevent NCIP conflicts.

## Files
- **ILLiad_Alma_NCIP_Lending.lua**: The main script containing the logic for NCIP messaging and Alma REST API interactions.
- **config.xml**: The configuration file where institution-specific settings, API keys, and URLs are defined.

## Key Features
- **Automated Lending Checkout**: Triggers during "Mark Found" or "Mark Found Scan Now" to check the item out in Alma.
- **Automated Lending Check-in**: Triggers during Lending Returns processing to return the item to its permanent location in Alma.
- **Hold Cancellation**: Optionally cancels internal Alma holds before checkout if a Request ID is found in the designated ILLiad field.
- **Error Handling**: Automatically routes transactions to specific error queues if NCIP or API calls fail.

## Setup & Configuration
The following settings must be configured in `config.xml`:

### Connection Settings
- **NCIP_Responder_URL**: Your institution's Alma NCIP Servlet URL.
- **Alma_API_URL**: The base URL for the Alma REST API (default is North America).
- **Alma_API_Key**: An Alma API Key with Read/Write permissions for Bibs and Requests.

### ILLiad Field Mapping
- **ILLiad_field_to_get_barcode**: The transaction field where the item barcode is stored (e.g., `ItemInfo3`).
- **Alma_Hold_ID_Field**: The transaction field where the Alma Request ID is stored for cancellation (e.g., `ItemInfo5`).

### Institution Codes
- **acceptItem_from_uniqueAgency_value**: Your institution's three-letter Alma code.
- **ApplicationProfileType**: The Resource Sharing Partner code used in Alma (often `ILL`).

## Registered Events
- **LendingRequestCheckOut**: Executes when an item is marked found.
- **LendingRequestCheckIn**: Executes when an item is returned via the Lending Returns batch form.

## Authors
- **Original Author**: Bill Jones III (SUNY Geneseo, IDS Project) & Kurt Munson (Northwestern University)
- **Modifications**: Matt Niehoff (Minitex), Robert Wilson (University of Minnesota)