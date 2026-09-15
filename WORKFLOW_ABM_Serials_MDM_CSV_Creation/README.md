# DESCRIPTION
Works through all ABM servers listed /config/token_config.env with certs and downloads serials and MDM server assignments.

Builds a single CSV of all serials, ABM server and MDM assignment for lookups and managing. This allows a local cache of serials and their ABM servers for lookups.

Also uploads as a script to install the CSV in /tmp/Axm/ALL_ABM_MacSerials_YYYYMMDD.csv" for use in Jamf policies.

And there's more! Uploads to a SharePoint, if you have a webhook, for providing an Excel lookup tool. Doesn't need a Mac to look up serials for depots, agencies, customers.

And finally posts posts to email and Teams. But a clever person could replace this with a Slack post.

We run this every 12 hours, takes about 20 mins to download, script and post results for 50,000 Macs. I've excluded mobiles as we do't manange those.

We run the Janf script as a before script on policies so lookups and MDM assignments always have latest data.
