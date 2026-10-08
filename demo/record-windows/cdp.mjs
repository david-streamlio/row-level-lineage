// Drive the recorder's Chrome window over the DevTools protocol (the
// recorder starts its Chrome instance with --remote-debugging-port).
// Node 22+ (built-in fetch and WebSocket). Prints true / false (+ reason).
//
//   node cdp.mjs <port> scroll "<text>"              center the element whose text is exactly <text>
//   node cdp.mjs <port> login <id> <secret> <scope>  sign in to the Apache Polaris console
//   node cdp.mjs <port> minio-login <user> <pass>    sign in to the MinIO console (login API, session cookie)
//   node cdp.mjs <port> goto <path>                  in-app navigation (no reload: the Polaris
//                                                    console keeps its login token in memory only)
//   node cdp.mjs <port> open <url>                   load <url> in the same window (no relaunch,
//                                                    so the desktop never shows through)
const [port, command, ...args] = process.argv.slice(2);

const waitFor = (expr) => `(async () => {
  for (let i = 0; i < 60; i++) {
    const found = ${expr};
    if (found) return found;
    await new Promise((r) => setTimeout(r, 250));
  }
  return null;
})()`;

const scripts = {
  scroll: ([text]) => `(async () => {
    const el = await ${waitFor(`[...document.querySelectorAll('body *')]
      .find((e) => e.childElementCount === 0 && e.textContent.trim() === ${JSON.stringify(text)})`)};
    if (!el) return false;
    el.scrollIntoView({ block: 'center' });
    return true;
  })()`,
  login: ([id, secret, scope]) => `(async () => {
    const user = await ${waitFor(`document.querySelector('input[placeholder="Enter your username"]')`)};
    if (!user) return false;
    // React-controlled inputs: set through the native setter, then fire input
    const set = (el, v) => {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, v);
      el.dispatchEvent(new Event('input', { bubbles: true }));
    };
    set(user, ${JSON.stringify(id)});
    set(document.querySelector('input[placeholder="Enter your password"]'), ${JSON.stringify(secret)});
    const scope = document.querySelector('input[placeholder="Enter the scope"]');
    if (scope) set(scope, ${JSON.stringify(scope)});
    (document.querySelector('form button[type="submit"]') || document.querySelector('form button')).click();
    return !!(await ${waitFor(`location.pathname !== '/login'`)});
  })()`,
  // through the console's login API, not its form: Chrome never sees a password
  // typed into a form, so it can't flag minioadmin as leaked (that bubble took
  // the recorder's window moves in take 103248)
  'minio-login': ([user, pass]) => `(async () => {
    const r = await fetch('/api/v1/login', { method: 'POST', credentials: 'include',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ accessKey: ${JSON.stringify(user)}, secretKey: ${JSON.stringify(pass)} }) });
    return r.ok;
  })()`,
  goto: ([path]) => `(async () => {
    history.pushState({}, '', ${JSON.stringify(path)});
    window.dispatchEvent(new PopStateEvent('popstate'));
    return !!(await ${waitFor(`location.pathname === ${JSON.stringify(path)}`)});
  })()`,
};
if (!scripts[command] && command !== 'open') { console.log(`false (unknown command ${command})`); process.exit(2); }

let pages = [];
for (let i = 0; i < 20 && !pages.some((p) => p.type === 'page'); i++) {
  try {
    pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  } catch {
    await new Promise((r) => setTimeout(r, 500));   // Chrome still starting
  }
}
const page = pages.find((p) => p.type === 'page');
if (!page) { console.log('false (no page)'); process.exit(1); }

const ws = new WebSocket(page.webSocketDebuggerUrl);
// "open" uses Page.navigate, which answers once navigation starts (a page-side
// location change would take the evaluation down with the old page)
ws.onopen = () => ws.send(JSON.stringify(command === 'open'
  ? { id: 1, method: 'Page.navigate', params: { url: args[0] } }
  : { id: 1, method: 'Runtime.evaluate',
      params: { expression: scripts[command](args), awaitPromise: true, returnByValue: true } }));
ws.onmessage = (msg) => {
  const reply = JSON.parse(msg.data);
  if (reply.id !== 1) return;
  const ok = command === 'open'
    ? !!reply.result?.frameId && !reply.result?.errorText
    : reply.result?.result?.value === true;
  console.log(ok ? 'true' : `false (${reply.result?.errorText || reply.result?.exceptionDetails?.text || reply.error?.message || 'not found'})`);
  ws.close();
  process.exit(ok ? 0 : 1);
};
ws.onerror = () => { console.log('false (websocket error)'); process.exit(1); };
setTimeout(() => { console.log('false (timeout)'); process.exit(1); }, 25000);
