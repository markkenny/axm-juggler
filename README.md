# AXM-JUGGLER
Collection of script to manage API calls to multiple ABM and ASM servers

![I DID IT!](./images/api_juggling.jpg)

# IDEA
Taken from [AxM_API](https://github.com/cantscript/AxM_API) which is great for "Automation of creating and validing tokens when working with the AxM API based on the [script](https://github.com/bartreardon/macscripts/blob/master/ABM_create_client_assertion.sh) provided by [Bart Reardon](https://github.com/bartreardon)" but only works with single ABMs. 

In global enterpise, there may be more than one. And with [mergers and acquistions](https://adage.com/agencies/aa-omnicom-acquires-ipg-what-you-need-to-know/) there may be more ABMs to work with! 

I think I'm running into a hard limit for the Apple API at 21,000.

Nope, just API limits, so I've added lots more cooling.

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

## WORKFLOW_ABM_Serials_MDM_CSV_Creation
Managing a large number of ABMs and providing reporting is this workflow. It works through all ABM servers in your /config/token_config.env and downloads all Mac serials (I skip mobile and iPads as we don't manage them) and their assigned MDM servers. It builds a consolidated CSV of all and uploads to Jamf as a script that installs the csv to /tmp/Axm/ALL_ABM_MacSerials_YYYYMMDD.csv so that can be used in lookup and assignment scripts. It will also upload to SharePoint and notify via a Teams post and email.

We run this twice daily in about 30 mins for 50,000 serials.

## WORKFLOW_JAMF_ABM_Lookup_Tool
The simplest tool, checks for the /tmp/Axm/ALL_ABM_MacSerials_YYYYMMDD.csv and runs a Jamf policy to install if missing, takes a single serial, or CSV or serials and reports ABM server and MDM assignment. By working with a CSV, this is much faster than most other tools that will hit up ABM at very search.

## WORKFLOW_MDM_Manager
The ABM Manager  will change MDM assignments, individually or in bulk, and at speed. Many Jamf parameters have been added so this script can become part of a building block. 

**DEBUG** of course, keeps all the temp and logging files. 

**CONFIRM** will process all serials, and run a second call to confirm. Takes longer, but if you have to be sure. 

**BULK_MODE** When using osascript to prompt user for a serial, or CSV of serials. Maybe you want to offer your service desk a tool to change MDM assignments, but make sure they're not changing the entire fleet! But if you're managing your fleet, you can be trusted.

**DRY-RUN** Of course. Go through all the steps. This is was my early stages, I used it a lot during testing.

**SILENT** runs everything, but does does not prompt the user with the report afterwards. Purpose is to allow a second script to run and read the output from the assign/unassign process. Maybe you want to add those serials to a static group, or update and extension attribute or add to a policy. In our case, we change the MDM assignment, then add to a policy to run the Jamf Migrate tool to migrate the device to the new MDM server. It's like Apple ABMs Migrate policy, but in full Jamf control with pre and post migration policies. 

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

