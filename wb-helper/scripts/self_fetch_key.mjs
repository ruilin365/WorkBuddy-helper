// WorkBuddy 零介入凭证自取（skill 标准组件）
// 流程：重启应用(带 --inspect) → CDP 取 atRestSecretKey → 内存中解密登录态信封
//       → 写入 skill config/（600）→ 写 logs/self_fetch_result.json（供应用重启后新会话接续）
//       → 恢复应用普通启动
// 安全约定：atRestSecretKey 与明文 token 全程只在内存；stdout 只输出结构验证结果
// 用法: node scripts/self_fetch_key.mjs [--config-dir <dir>]
import { createDecipheriv, createHash } from 'node:crypto';
import { execFileSync, spawn } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, chmodSync, existsSync, readdirSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import net from 'node:net';

const PORT = 9229;
const IS_WIN = process.platform === 'win32';
const HOME = os.homedir();
// 凭证文件候选路径：新版客户端把 Data 目录放在 %LOCALAPPDATA%（Roaming 下可能为空），两处都要试
const INFO_CANDIDATES = IS_WIN
  ? [
      path.join(process.env.LOCALAPPDATA || HOME, 'CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info'),
      path.join(process.env.APPDATA || HOME, 'CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info'),
    ]
  : [path.join(HOME, 'Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info')];
const INFO = INFO_CANDIDATES.find(p => existsSync(p)) || INFO_CANDIDATES[0];
const SKILL_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT_DIR = process.argv.includes('--config-dir')
  ? process.argv[process.argv.indexOf('--config-dir') + 1]
  : path.join(SKILL_DIR, 'config');
const RESULT_FILE = path.join(SKILL_DIR, 'logs', 'self_fetch_result.json');

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

function fail(obj) {
  const payload = Object.assign({ ok: false, time: new Date().toISOString() }, obj);
  console.log(JSON.stringify(payload));
  // 失败也要落盘：本脚本通常会杀掉 WorkBuddy，用户窗口里的报错随后就看不到了。
  // 落盘后重启的新会话可直接读 logs/self_fetch_result.json 判断卡在哪一步。
  try {
    mkdirSync(path.dirname(RESULT_FILE), { recursive: true, mode: 0o700 });
    writeFileSync(RESULT_FILE, JSON.stringify(payload, null, 2), { mode: 0o600 });
    chmodSync(RESULT_FILE, 0o600);
  } catch {}
  process.exitCode = 1;   // 逻辑失败必须是非 0 退出，否则调用方误判成功
}

function waitPort(port, timeoutMs) {
  return new Promise((resolve) => {
    const t0 = Date.now();
    const tryOnce = () => {
      const s = net.connect(port, '127.0.0.1');
      s.on('connect', () => { s.end(); resolve(true); });
      s.on('error', () => {
        s.destroy();
        if (Date.now() - t0 > timeoutMs) resolve(false);
        else setTimeout(tryOnce, 500);
      });
    };
    tryOnce();
  });
}

const b64d = (s) => Buffer.from(s + '='.repeat((-s.length) % 4), 'base64url');

function buildFieldAad(keyId) {
  const lp = (s) => {
    const b = Buffer.from(s, 'utf-8');
    const l = Buffer.alloc(4); l.writeUInt32BE(b.length);
    return Buffer.concat([l, b]);
  };
  const u32 = (v) => { const b = Buffer.alloc(4); b.writeUInt32BE(v); return b; };
  return Buffer.concat([
    Buffer.from('WB-AAD\x00', 'binary'), Buffer.from([1]),
    lp('WBEV1'), lp('sym-v1'), u32(1), lp(keyId),
    Buffer.from([2, 0, 0]),
  ]);
}

function gcmDecrypt(key, nonce, ct, tag, aad) {
  const d = createDecipheriv('aes-256-gcm', key, nonce);
  d.setAAD(aad);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(ct), d.final()]);
}

async function cdpEvaluate(ws, id, expression) {
  return new Promise((resolve) => {
    const onMsg = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id === id) { ws.removeEventListener('message', onMsg); resolve(m); }
    };
    ws.addEventListener('message', onMsg);
    ws.send(JSON.stringify({ id, method: 'Runtime.evaluate',
      params: { expression, returnByValue: true } }));
    setTimeout(() => resolve(null), 20000);
  });
}

// ---- 平台相关的应用控制 ----
// 这台机器上 WorkBuddy.exe 会同时存在 5 个"主进程"（GUI、daemon-app-server、codebuddy CLI、
// sidecar-entry），它们全部挂在 GUI 主进程的进程树下。只看进程名会导致两个错误：
//   ① 杀掉 GUI 后 daemon 仍在 → 误判"应用还在运行"，一直等到超时；
//   ② 直接 /IM 全杀，可能误伤非 GUI 实例。
// 因此精确定位"命令行不含 --type= / app.asar / optimize-for-size"的那个 GUI 主进程。
function guiPids() {
  try {
    const ps = "$ErrorActionPreference='SilentlyContinue';"
      + "Get-CimInstance Win32_Process -Filter \"Name='WorkBuddy.exe'\" | "
      + "Where-Object { $_.CommandLine -notmatch '--type=' -and $_.CommandLine -notmatch 'app.asar' -and $_.CommandLine -notmatch 'entry\\.js' -and $_.CommandLine -notmatch 'optimize-for-size' } | "
      + "ForEach-Object { $_.ProcessId }";
    const out = execFileSync('powershell',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', ps],
      { encoding: 'utf-8', windowsHide: true, timeout: 20000 });
    return out.split(/\r?\n/).map(s => s.trim()).filter(s => /^\d+$/.test(s)).map(Number);
  } catch { return null; }   // null = 查询不可用，调用方回退到 tasklist 粗判
}

function appRunning() {
  if (!IS_WIN) {
    try { execFileSync('pgrep', ['-f', 'WorkBuddy.app/Contents/MacOS/Electron']); return true; }
    catch { return false; }
  }
  const pids = guiPids();
  if (pids) return pids.length > 0;
  // 回退：拿不到命令行时只能按进程名粗判（可能因 daemon 残留而偏保守）
  try {
    const out = execFileSync('tasklist', ['/FI', 'IMAGENAME eq WorkBuddy.exe', '/NH'],
      { encoding: 'utf-8', windowsHide: true });
    return out.toUpperCase().includes('WORKBUDDY.EXE');
  } catch { return false; }
}

// 静默执行外部命令：不继承 stdio（避免 taskkill 的 "can only be terminated forcefully"
// 之类噪声刷屏，那是预期内的——不带 /F 关不掉 Electron 属正常现象）。
function runQuiet(cmd, args) {
  try {
    execFileSync(cmd, args, { stdio: 'ignore', windowsHide: true });
    return true;
  } catch { return false; }
}

function appQuit() {
  // 先优雅关闭（无 /F，发 WM_CLOSE）。Electron 通常不响应，失败由 appKill 兜底。
  if (!IS_WIN) return runQuiet('osascript', ['-e', 'tell application "WorkBuddy" to quit']);
  const pids = guiPids();
  if (!pids || !pids.length) return false;
  let ok = false;
  for (const pid of pids) {
    if (runQuiet('taskkill', ['/PID', String(pid), '/T'])) ok = true;
  }
  return ok;
}

function appKill() {
  // 强制结束 GUI 主进程树（/T 连带 daemon、sidecar、渲染进程——它们都在同一棵树下）。
  // 只作用于定位到的 GUI PID，不按进程名盲杀。
  if (!IS_WIN) return runQuiet('pkill', ['-KILL', '-f', 'WorkBuddy.app/Contents/MacOS/Electron']);
  const pids = guiPids();
  let anyOk = false;
  if (pids && pids.length) {
    for (const pid of pids) {
      if (runQuiet('taskkill', ['/F', '/T', '/PID', String(pid)])) anyOk = true;
    }
    if (anyOk) return true;
  }
  // 拿不到 GUI PID 或按 PID 失败时，退回按进程名强杀
  if (runQuiet('taskkill', ['/F', '/T', '/IM', 'WorkBuddy.exe'])) return true;
  return runQuiet('powershell', ['-NoProfile', '-NonInteractive', '-Command',
    'Get-Process -Name WorkBuddy -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue']);
}

function findWinExe() {
  // 安装布局不止一种，全都试一遍：
  //   ① NSIS/Electron 官方安装器：%LOCALAPPDATA%\Programs\WorkBuddy\WorkBuddy.exe（本机即此布局）
  //   ② Squirrel：%LOCALAPPDATA%\WorkBuddy\app-<version>\WorkBuddy.exe 或顶层 stub
  //   ③ 传统 Program Files 两处
  const roots = [
    path.join(process.env.LOCALAPPDATA || '', 'Programs', 'WorkBuddy'),
    path.join(process.env.LOCALAPPDATA || '', 'WorkBuddy'),
    path.join(process.env.PROGRAMFILES || '', 'WorkBuddy'),
    path.join(process.env['PROGRAMFILES(X86)'] || '', 'WorkBuddy'),
  ].filter(p => p && existsSync(p));
  for (const root of roots) {
    try {
      const stub = path.join(root, 'WorkBuddy.exe');
      if (existsSync(stub)) return stub;
      const dirs = readdirSync(root, { withFileTypes: true })
        .filter(d => d.isDirectory() && /^app-\d+\.\d+\.\d+/.test(d.name))
        .map(d => d.name).sort();
      for (let i = dirs.length - 1; i >= 0; i--) {
        const p = path.join(root, dirs[i], 'WorkBuddy.exe');
        if (existsSync(p)) return p;
      }
    } catch {}
  }
  return null;
}

function appLaunch(inspect) {
  const extra = inspect ? [`--inspect=127.0.0.1:${PORT}`] : [];
  if (IS_WIN) {
    const exe = findWinExe();
    if (!exe) throw new Error('未找到 WorkBuddy.exe');
    // 直接用 spawn 拉起 exe：不经 cmd，规避 execFileSync 给含空格的参数二次加引号
    // 导致 `cmd /c "start "" "C:\..." "` 解析失败的问题。
    const child = spawn(exe, extra, {
      detached: true,
      stdio: 'ignore',
      windowsHide: false,
      cwd: path.dirname(exe),
    });
    let spawnErr = null;
    child.on('error', (e) => { spawnErr = e; });
    child.unref();
    if (spawnErr) throw spawnErr;
  } else {
    const args = ['-a', 'WorkBuddy'];
    if (inspect) args.push('--args', `--inspect=127.0.0.1:${PORT}`);
    spawn('open', args, { detached: true, stdio: 'ignore' }).unref();
  }
}

// 关闭 → 确认进程真的消失。返回 false 表示杀不掉（多半是权限问题）。
async function shutdownApp() {
  appQuit();
  for (let i = 0; i < 4 && appRunning(); i++) await sleep(1000);
  if (appRunning()) {
    appKill();
    for (let i = 0; i < 12 && appRunning(); i++) await sleep(1000);
  }
  // 进程退干净后仍需一点时间释放单实例锁 / 9229 端口
  if (!appRunning()) await sleep(1500);
  return !appRunning();
}

async function main() {
  // 接管模式（--attach）：假定用户已经手动把 WorkBuddy 以 --inspect 启动好了，
  // 本进程只连 9229 取凭证，绝不杀进程、绝不重启。用于自动重启失败时的人工兜底。
  const ATTACH = process.argv.includes('--attach');

  // 0.1 凭证文件必须先存在：否则重启完再失败，白丢一次未保存的内容
  if (!existsSync(INFO)) {
    fail({ stage: 'precheck', err: `未找到凭证文件，已尝试：${INFO_CANDIDATES.join(' ; ')}` });
    return;
  }

  if (ATTACH) {
    console.log(`==> 接管模式：等待 127.0.0.1:${PORT}（不杀进程、不重启）`);
    if (!(await waitPort(PORT, 120000))) {
      fail({ stage: 'attach-port', err: `120 秒内 ${PORT} 未就绪，请确认应用是以 --inspect=127.0.0.1:${PORT} 启动的` });
      return;
    }
  } else {
    // 0. 确保应用在运行（未运行则没有意义——密钥只驻留客户端内存）
    if (!appRunning()) {
      fail({ stage: 'precheck', err: 'WorkBuddy 未运行，请先登录' });
      return;
    }
    // 0.2 主程序必须能定位：否则杀掉应用后拉不起来（比直接失败更糟）
    if (IS_WIN && !findWinExe()) {
      fail({ stage: 'precheck', err: '未定位到 WorkBuddy.exe，为避免应用被杀后无法重启，已中止' });
      return;
    }

    // 1. 重启（带 --inspect）
    //    必须确认进程真的死透再启动，否则新实例会因单实例锁直接把参数丢掉、瞬间退出。
    if (!(await shutdownApp())) {
      fail({ stage: 'kill', err: 'WorkBuddy 进程未能结束（可能需管理员权限）。应用仍在运行，未做改动。' });
      return;
    }
    try {
      appLaunch(true);
    } catch (e) {
      fail({ stage: 'launch', err: String(e.message || e) });
      return;
    }
    // spawn 返回成功不代表进程活着——等它出现
    for (let i = 0; i < 10 && !appRunning(); i++) await sleep(500);
    if (!appRunning()) {
      try { appLaunch(false); } catch {}
      fail({ stage: 'launch', err: 'WorkBuddy 启动后立即退出，已尝试以普通模式重新打开' });
      return;
    }
    if (!(await waitPort(PORT, 60000))) {
      // --inspect 没被接受：先把应用恢复成普通模式，别让用户面对一个调试端口都没开的客户端
      try { await shutdownApp(); appLaunch(false); } catch {}
      fail({ stage: 'inspect-port', err: '9229 未就绪，应用已恢复为普通模式启动' });
      return;
    }
  }

  try {
    // 2. CDP 连接
    const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
    const target = list.find(t => t.type === 'node') || list[0];
    const ws = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });

    // 3. 取 atRestSecretKey（值只存在于本变量，绝不输出）
    const r = await cdpEvaluate(ws, 1, `process.getBuiltinModule('node:module').createRequire('/')('electron').workbuddyStorage.loggerGet()`);
    ws.close();
    const payloadStr = r && r.result && r.result.result && r.result.result.value;
    if (!payloadStr) { fail({ stage: 'loggerGet', err: '无返回' }); return; }
    const payload = JSON.parse(payloadStr);
    const secret = payload.atRestSecretKey;
    if (!/^[A-Za-z0-9+/]{43}=$/.test(secret)) {
      fail({ stage: 'key-format', err: 'atRestSecretKey 形态不符' });
      return;
    }

    // 4. 内存中解密（key 指纹自校验 → 解信封）
    const key = createHash('sha256').update(secret, 'utf-8').digest();
    const keyId = createHash('sha256').update(key).digest('hex').slice(0, 16);

    const info = JSON.parse(readFileSync(INFO, 'utf-8'));
    const auth = info.auth || {};
    const uid = (info.account || {}).uid || '';
    const out = {};
    for (const field of ['accessToken', 'refreshToken']) {
      const v = auth[field];
      if (typeof v === 'string') { out[field] = v; continue; }
      const env = JSON.parse(b64d(v.envelope).toString('utf-8'));
      if (env.keyId !== keyId) {
        fail({ stage: 'fingerprint', field, err: `keyId ${keyId} != 信封 ${env.keyId}` });
        return;
      }
      out[field] = gcmDecrypt(key, b64d(env.nonce), b64d(env.ciphertext), b64d(env.authTag),
        buildFieldAad(env.keyId)).toString('utf-8');
    }

    // 5. 写入目标 config（600）
    mkdirSync(OUT_DIR, { recursive: true, mode: 0o700 });
    writeFileSync(path.join(OUT_DIR, 'token'), out.accessToken, { mode: 0o600 });
    writeFileSync(path.join(OUT_DIR, 'user_id'), uid, { mode: 0o600 });
    writeFileSync(path.join(OUT_DIR, 'refresh_token'), out.refreshToken, { mode: 0o600 });
    for (const f of ['token', 'user_id', 'refresh_token']) chmodSync(path.join(OUT_DIR, f), 0o600);

    // 6. 写结果文件（供应用重启后新会话的 Agent 接续）+ 结构验证输出（不含任何凭证值）
    const p = out.accessToken.split('.')[1];
    const claims = JSON.parse(b64d(p).toString('utf-8'));
    const result = {
      ok: true,
      time: new Date().toISOString(),
      uid_match_existing: null,
      token_three_segment: out.accessToken.split('.').length === 3,
      token_exp: new Date(claims.exp * 1000).toISOString().slice(0, 10),
      secret_keyId: keyId,
    };
    try {
      const prevUid = existsSync(path.join(OUT_DIR, 'user_id'))
        ? readFileSync(path.join(OUT_DIR, 'user_id'), 'utf-8').trim() : null;
      result.uid_match_existing = prevUid === null ? 'n/a(全新)' : prevUid === uid;
    } catch { result.uid_match_existing = 'unknown'; }
    try {
      mkdirSync(path.dirname(RESULT_FILE), { recursive: true, mode: 0o700 });
      writeFileSync(RESULT_FILE, JSON.stringify(result, null, 2), { mode: 0o600 });
      chmodSync(RESULT_FILE, 0o600);
    } catch {}
    console.log(JSON.stringify(result));
  } finally {
    // 7. 恢复普通启动（接管模式下应用是用户自己的，不动它）
    if (ATTACH) {
      console.log(`==> 接管模式结束。当前实例仍是调试模式，请退出后正常重新打开 WorkBuddy。`);
    } else try {
      // 这一步绝不能失败——否则用户的应用停在关闭状态。
      await shutdownApp();
      appLaunch(false);
      for (let i = 0; i < 12 && !appRunning(); i++) await sleep(500);
      if (!appRunning()) console.error('==> 警告：WorkBuddy 未能自动重新打开，请手动启动');
    } catch (e) { console.error('==> 恢复普通启动失败：' + (e.message || e)); }
  }
}

// --dry-run：只做前置体检（不杀进程、不重启、不读凭证），供重启前确认环境
if (process.argv.includes('--dry-run')) {
  console.log(JSON.stringify({
    platform: process.platform,
    running: appRunning(),
    info_file: INFO,
    info_found: existsSync(INFO),
    info_candidates: INFO_CANDIDATES,
    exe: IS_WIN ? findWinExe() : 'n/a(macOS)',
    port: PORT,
  }, null, 2));
} else {
  main().catch(e => fail({ stage: 'exception', err: String(e) }));
}
