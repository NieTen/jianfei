from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, Response

public_router = APIRouter(include_in_schema=False)


@public_router.get("/.well-known/apple-app-site-association")
def apple_association(request: Request):
    application = request.app.state.runtime.settings.ios_application_id
    details = [{"appIDs": [application], "components": [{"/": "/join"}]}] if application else []
    return {"applinks": {"details": details}}


@public_router.get("/join", response_class=HTMLResponse)
def invite_landing():
    # 邀请码留在 URL 片段中，网页预览与访问日志都无需读取或消费邀请码。
    return HTMLResponse("""<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>并肩 · 挑战邀请</title>
<style>
:root { color-scheme: light dark; font: 17px/1.6 -apple-system, system-ui, sans-serif; }
body { margin: 0; padding: 8vh 1.25rem; color: #192f2f; background: #eff6f6; }
main { max-width: 30rem; margin: auto; padding: 1.6rem; border-radius: 1.25rem; background: white; }
h1 { font-size: 1.6rem; margin: 0 0 .75rem; } p { margin: .8rem 0; }
a { display: inline-block; padding: .6rem 1rem; border-radius: .6rem; color: white; background: #116966; }
[hidden] { display: none; } output { overflow-wrap: anywhere; font-family: ui-monospace, monospace; }
@media (prefers-color-scheme: dark) { body { background: #122223; color: #edf5f4; } main { background: #203031; } }
</style><main><h1>加入并肩挑战</h1><p>在 iPhone 上打开并肩，登录后查看发起人和挑战规则，再决定是否加入。</p>
<p><a id="open" hidden>在并肩中打开邀请</a></p><p id="instruction">如果还没有安装，请向邀请人取得并肩的安装方式。安装后重新打开此链接，或在伙伴页面输入邀请码。</p>
<output id="code"></output></main><script src="/invite.js" defer></script></html>""",
                        headers={"Referrer-Policy": "no-referrer", "Cache-Control": "no-store",
                                 "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'"})


@public_router.get("/invite.js")
def invite_script():
    return Response("""const code = location.hash.slice(1);
const output = document.getElementById("code");
if (/^[A-Za-z0-9_-]{24}$/.test(code)) {
  const link = document.getElementById("open");
  link.href = "bingjian://join?" + new URLSearchParams({code, origin: location.origin});
  link.hidden = false;
  output.textContent = "邀请码 " + code;
} else { output.textContent = "链接缺少有效邀请码，请向发起人重新获取。"; }
""", media_type="application/javascript", headers={"X-Content-Type-Options": "nosniff"})
