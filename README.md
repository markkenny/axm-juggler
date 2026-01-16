# AXM-JUGGLER
Collection of script to manage API calls to multiple ABM and ASM servers

![I DID IT!](./images/api_juggling.jpg)

# IDEA
Taken from [AxM_API](https://github.com/cantscript/AxM_API) which is great for "Automation of creating and validing tokens when working with the AxM API based on the [script](https://github.com/bartreardon/macscripts/blob/master/ABM_create_client_assertion.sh) provided by [Bart Reardon](https://github.com/bartreardon)" but only works with single ABMs. 

In global enterpise, there may be more than one. And with [mergers and acquistions](https://adage.com/agencies/aa-omnicom-acquires-ipg-what-you-need-to-know/) there may be more ABMs to work with! 

I think I'm running into a hard limit for the Apple API at 21,000. 

-----

# CONCEPT
AxM (Acronym for Apple Business/School Manager) API access needs multiple tokens to work. The API account is created on the ABM server and a certificate is downloaded as .pem in /certs

The account is also managed and a CLIENT_ID (BUSINESSAPI.XXXX-XXXX-XXXX) and KEY ID (XXXX-XXXX-XXXX) are created. For multi-ABM use, these credentials are saved for /config/token_confg.env Format: TOKEN_NAME|PEM_PATH|CLIENT_ID|KEY_ID

This customisation "variable-ises" (I love that word! It's mine!) both scripts to read from the token_config.env with the ABM_tokenManager.sh which checks the JSON expiries and renews as needed.

## Client Assertion
The ABM_create_client_assertion.sh only deals with creating the `Client Assertion` just once from the Private Key File and the values obtained in AxM saved in /config/token_confg.env PEM_PATH|CLIENT_ID|KEY_ID. 

This is saved to /tokens/$TOKEN_NAME_client.json 

## Access Token
The ABM_create_access_token.sh only deals with creating the `Access Token` using the `Client Assertion` and is used for API called to AxM. This key expires hourly and needs renewal. 

This is saved to /tokens/$TOKEN_NAME_access.json 

## Token Manager
The ABM_tokenManager.sh is what loops through /config/token_confg.env creating both client and access tokens for all provided AxM xites.

## Folder Structure and credentials
The required folders and example credentials are provided as examples. My secret key is not really 123456789012345678901234567890 ;-)

-----

# USAGE
A few automations have been written, this is what we'll be building up on.

## API_GET_generic.sh
First attempt at working with single ABMs passed to a generic curl needing a $3 for the endpoint to pull against. Was used to testing.

## API_GET_MDMs.sh
First automated call! Goes through all ABMs in /config/token_confg.env and pulls all MDM servers and their IDs in each ABM. (IDs are needed for future pulls like all Macs assigned to an MDM server). 

Report saved to /REPORTS/ABM_MDMs_YYYYMMDD_HHMMSS.csv formatted as `TokenName,ServerName,Type,ID`

## API_GET_MacSerials.sh
Prompts to select a CSV from /REPORTS/ABM_MDMs_* (So cut this down if you do not want to search report EVERYTHING!)

It runs through the CSV, all ABMs and all MDM servers and reports all serial numbers. 

Report saved to /REPORTS/MacSerials_$TokenName $Servername_YYYYMMDD.csv formatted as `TokenName,ServerName,DeviceID`

## API_GET_DeviceInfo.sh
All detailed information for Macs. 

Prompts to select a CSV from /REPORTS/MacSerials_*.csv 

Report saved to /REPORTS/Devices_Details_$TOKEN$_YYYYMMDD as `TokenName,ServerName,InputDeviceID,ResponseID,ResponseType,addedToOrgDateTime,bluetoothMacAddress,color,deviceCapacity,deviceModel,eid,imei,meid,orderDateTime,orderNumber,partNumber,productFamily,productType,purchaseSourceId,purchaseSourceType,releasedFromOrgDateTime,serialNumber,status,updatedDateTime,wifiMacAddress`

## API_Generate_MDM_Assignment.sh
From a CSV of serials, search against all CSVs created by API_GET_MacSerials.sh Look up the serials against that ABM and show in Terminal all available MDMs prompting user to chose the MDM to re-assign to. It creates a file you can use to re-assign the Macs.

## API_POST_SerialMDM.sh
The Macs are reassigned between the MDM servers in an ABM server and verified as complete. 

Prompts to select a CSV from /REPORTS/MacSerials_*.csv but this time it needs a fourth column, new server name: `TokenName,ServerName,DeviceID,NewServerName`

## API_GET_MDMs_from_Serials_API.sh and API_GET_MDMs_from_Serials_Local.sh
I went down a rabbit hole here.

-----
# NOTES
Check the .gitignore ! certs, config, tokens, REPORTS are added so as not to sync credentials are big reports to Git. 

Although the scripts take care of keeping the `Access Token` valid, I didn't actually build in any "self renewal" of the `Client Assertion`. If this becomes invalid due to being over 180 days old, everything will just exit and error out. Clear old tokens.


# LINKS
If you haven't already created your .pem in ABM, go and read [Barts blog](https://bartreardon.github.io/2025/06/11/using-the-new-api-for-apple-business-school-manager.html) 

[ABM Endpoints Documentation](https://developer.apple.com/documentation/applebusinessmanagerapi)

To find out more about [the original project](https://github.com/cantscript/AxM_API) check out the post ["Automating Token Generation for Apple School Managers New API"](https://cantscript.com/posts/automating-token-generation-for-apple-school-managers-new-api/) on [CantScript.com](https://cantscript.com)

[Python Version](https://github.com/karthikeyan-mac/AppleBusinessANDSchoolManagerAPI)

[Unlocking Apple’s New Device Management API](https://the-sequence.com/unlocking-apples-new-device-management-api)

