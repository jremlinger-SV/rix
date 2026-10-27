#!/usr/bin/env python3
"""Baut die eigenständige Web-App (index.html) aus der Spieldatei achtfeld.html.
Aufruf:  python3 build.py  [Pfad zu achtfeld.html]
Änderungen am Spiel werden in achtfeld.html gemacht und hier nur neu exportiert."""
import sys, re, pathlib, hashlib, time

HERE = pathlib.Path(__file__).resolve().parent
SRC = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / 'jemrix-source.html'
MASTER = HERE.parent / 'achtfeld.html'
if len(sys.argv) <= 1 and MASTER.exists() and MASTER.read_bytes() != SRC.read_bytes():
    sys.exit('jemrix-source.html ist veraltet – erst achtfeld.html hineinkopieren')
s = SRC.read_text(encoding='utf-8')

def rep(a, b, count=1):
    global s
    n = s.count(a)
    assert n == count, f'{n}x gefunden statt {count}: {a[:70]!r}'
    s = s.replace(a, b)

# 1) Kopf: Claude-spezifische Zeilen und Google-Fonts raus
rep('<title>Jemrix</title>\n<meta name="claude:viewport-fit-sides" content="cover">\n', '')
s = re.sub(r'<link rel="preconnect" href="https://fonts.googleapis.com">\n', '', s)
s = re.sub(r'<link rel="stylesheet" href="https://fonts.googleapis.com/[^"]*">\n', '', s)

# 2) Highscores: Claude-Datenbank durch eigene highscore.php ersetzen
a = s.index('/* Highscores: lokal sofort, online gemeinsam.')
b = s.index("const CROWN='")
s = s[:a] + r'''/* Highscores: lokal sofort, online gemeinsam über Supabase (EU-Server, Zugangsdaten in config.js).
   Ohne Internet landen Ergebnisse in einer Warteschlange und werden später automatisch übertragen. */
const CFG=window.JEMRIX_CONFIG||{};
const SB_URL=(CFG.supabaseUrl||'').replace(/\/$/,''), SB_KEY=CFG.supabaseKey||'', FAMILY_CODE=CFG.familyCode||'';
const ONLINE=!!(SB_URL && SB_KEY);
async function api(fn, body){
  const ac=new AbortController(), to=setTimeout(()=>ac.abort(),10000);   // hängende Verbindung nach 10 s abbrechen
  try{
  const r=await fetch(`${SB_URL}/rest/v1/rpc/${fn}`,{method:'POST',cache:'no-store',signal:ac.signal,
    headers:Object.assign({'Content-Type':'application/json','apikey':SB_KEY}, SB_KEY.startsWith('sb_')?{}:{'Authorization':'Bearer '+SB_KEY}),body:JSON.stringify(body||{})});
  if (!r.ok) throw new Error('http '+r.status);
  return await r.json();
  } finally { clearTimeout(to); }
}
let listSeq=0, listApplied=0;   // ältere Antworten dürfen eine neuere Liste nicht überschreiben
let pending=load('jemrix-pending',[]);
let sharedCache=load('jemrix-shared-cache',null); // letzte bekannte gemeinsame Liste
let syncing=false, netOk=null, fetching=false;
function recordScore(s){
  if (!player || s<=0) return;
  lastRun={name:player, score:s};
  localScores.push({name:player, score:s, at:Date.now()});
  localScores.sort((a,b)=>b.score-a.score); localScores=localScores.slice(0,20);
  save('jemrix-scores',localScores);
  pending.push({name:player, score:s, at:Date.now()}); save('jemrix-pending',pending);
  updateNet(); trySync(); renderTop2();
}
function takeList(j, seq){
  if (!j || !Array.isArray(j.players)) return false;
  if (seq!=null){ if (seq<listApplied) return false; listApplied=seq; }
  sharedRows=j.players.filter(p=>p && typeof p.score==='number').map(p=>({name:clean(p.name), score:p.score}));
  sharedCache=sharedRows; save('jemrix-shared-cache',sharedCache);
  if (typeof j.epoch==='number' && j.epoch>load('jemrix-server-epoch',0)){
    // Liste wurde auf dem Server zurückgesetzt: lokale Listen ebenfalls leeren
    save('jemrix-server-epoch',j.epoch);
    if (load('jemrix-server-epoch-seen',0)){ localScores=[]; save('jemrix-scores',localScores); best=0; save('jemrix-best',0); $('best').textContent=showPts(0); pending=[]; save('jemrix-pending',pending); }
    save('jemrix-server-epoch-seen',1);
  }
}
function refreshViews(){ updateNet(); if (!$('over').hidden) renderScores(); else renderTop2(); markLeader(); }
async function fetchScores(){
  if (!ONLINE){ refreshViews(); return; }
  if (fetching) return; fetching=true;
  try{
    const seq=++listSeq; takeList(await api('get_scores'), seq); netOk=true;
  }catch(e){ netOk=false; }
  finally{ fetching=false; refreshViews(); trySync(); }
}
async function trySync(){
  if (!ONLINE){ pending=[]; save('jemrix-pending',pending); return; }   // ohne Online-Liste nur lokal
  if (syncing || !pending.length || navigator.onLine===false) { updateNet(); return; }
  syncing=true;
  const batch=pending.slice(0,50);
  try{
    const seq=++listSeq;
    const j=await api('submit_scores',{p_code:FAMILY_CODE, p_entries:batch.map(e=>({name:e.name, score:Math.round(e.score)}))});
    // Antwort vom Server (auch eine Ablehnung): Stapel ist erledigt und blockiert die Warteschlange nicht
    pending=pending.slice(batch.length); save('jemrix-pending',pending);
    if (j && j.ok!==false){ if (takeList(j, seq)===false) setTimeout(fetchScores,300); }   // ältere Antwort verworfen: Liste frisch holen
    netOk=true;
  }catch(e){ netOk=false; }
  finally{ syncing=false; refreshViews(); if (pending.length && netOk) setTimeout(trySync,300); }
}
function updateNet(){
  if (!ONLINE){ $('netline').hidden=true; return; }
  const off = navigator.onLine===false || netOk===false;
  const n=pending.length;
  const el=$('netline');
  if (!n && !off){ el.hidden=true; return; }
  el.hidden=false;
  el.textContent = off ? (n ? `Offline · ${n} Ergebnis${n>1?'se':''} gespeichert, wird später übertragen` : 'Offline · Ergebnisse werden lokal gespeichert')
                       : `${n} Ergebnis${n>1?'se':''} wird übertragen …`;
}
function topList(){
  const base = sharedRows ? sharedRows : (sharedCache || null);
  if (base){
    const rows=base.slice();
    pending.forEach(e=>rows.push({name:e.name, score:e.score}));   // eigene, noch nicht übertragene Ergebnisse
    const bestBy=new Map(); rows.forEach(r=>{ const k=clean(r.name).toLowerCase(); if(!bestBy.has(k)||bestBy.get(k).score<r.score) bestBy.set(k,{name:clean(r.name),score:r.score}); });
    const t = sharedRows && netOk ? 'Highscores · Familie' : 'Highscores · zuletzt synchronisiert';
    return {title:t, rows:[...bestBy.values()].sort((a,b)=>b.score-a.score).slice(0,10)};
  }
  return {title:'Highscores · dieses Gerät', rows:localScores.slice(0,10)};
}
window.addEventListener('online',()=>{ netOk=null; fetchScores(); });
window.addEventListener('offline',updateNet);
document.addEventListener('visibilitychange',()=>{ if (!document.hidden) fetchScores(); });
setInterval(()=>{ if (!document.hidden) fetchScores(); },60000);
''' + s[b:]

a = s.index("(async()=>{\n  try{\n    if (!window.claude || !window.claude.use) return;")
b = s.index("})();\n", a) + len("})();\n")
s = s[:a] + "fetchScores();\n" + s[b:]
rep('let shared=null, sharedRows=null, myId=null, myDoc={};', 'let sharedRows=null;')

# 3) Offline-Speicher registrieren
rep('\nplayCine(()=>showModes(', """
if ('serviceWorker' in navigator && location.protocol!=='file:'){
  // Updates zuverlässig holen: bei jeder Rückkehr in die App nach neuer Version fragen
  window.addEventListener('load',()=>{ navigator.serviceWorker.register('sw.js',{updateViaCache:'none'}).then(reg=>{
    document.addEventListener('visibilitychange',()=>{ if (!document.hidden) reg.update().catch(()=>{}); });
  }).catch(()=>{}); });
  let hadCtl=!!navigator.serviceWorker.controller;
  navigator.serviceWorker.addEventListener('controllerchange',()=>{
    if (!hadCtl){ hadCtl=true; return; }          // erste Installation: nichts tun
    window.__jemrixUpdate=true;                     // neue Version: beim nächsten Start-Bildschirm neu laden
    if (document.getElementById('cine')) location.reload();
  });
}
playCine(()=>showModes(""")

# 3b) Versionsstempel (deutsche Zeit) für die Anzeige auf der Modusauswahl
try:
    from zoneinfo import ZoneInfo; import datetime
    STAMP = datetime.datetime.now(ZoneInfo('Europe/Berlin')).strftime('%d.%m.%Y, %H:%M')
except Exception:
    STAMP = time.strftime('%d.%m.%Y, %H:%M')
rep("const APP_VERSION='';", f"const APP_VERSION='{STAMP}';")

# 4) Vollständiges Dokument
FONTS = '''@font-face{font-family:"Fredoka";font-style:normal;font-weight:500;font-display:swap;src:url(fonts/fredoka-latin-500-normal.woff2) format("woff2")}
@font-face{font-family:"Fredoka";font-style:normal;font-weight:600;font-display:swap;src:url(fonts/fredoka-latin-600-normal.woff2) format("woff2")}
@font-face{font-family:"Fredoka";font-style:normal;font-weight:700;font-display:swap;src:url(fonts/fredoka-latin-700-normal.woff2) format("woff2")}
@font-face{font-family:"Nunito";font-style:normal;font-weight:500;font-display:swap;src:url(fonts/nunito-latin-500-normal.woff2) format("woff2")}
@font-face{font-family:"Nunito";font-style:normal;font-weight:700;font-display:swap;src:url(fonts/nunito-latin-700-normal.woff2) format("woff2")}
@font-face{font-family:"Lilita One";font-style:normal;font-weight:400;font-display:swap;src:url(fonts/lilita-one-latin-400-normal.woff2) format("woff2")}
@font-face{font-family:"Unbounded";font-style:normal;font-weight:200 900;font-display:swap;src:url(fonts/unbounded-latin-wght-normal.woff2) format("woff2")}'''
SPLASH = '\n'.join(
    f'<link rel="apple-touch-startup-image" media="(device-width: {w}px) and (device-height: {h}px) and (-webkit-device-pixel-ratio: 3) and (orientation: portrait)" href="icons/splash-{w*3}x{h*3}.png">'
    for w, h in [(393, 852), (402, 874), (430, 932), (440, 956)])
HEAD = f'''<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<title>Jemrix</title>
<meta name="description" content="Jemrix – das Block-Puzzle nur für die Remlingers">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="Jemrix">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="theme-color" content="#0c1328">
<meta name="format-detection" content="telephone=no">
<meta name="robots" content="noindex,nofollow">
<link rel="manifest" href="manifest.webmanifest">
<script src="config.js"></script>
<link rel="icon" type="image/png" sizes="192x192" href="icons/icon-192.png">
<link rel="apple-touch-icon" href="icons/apple-touch-icon.png">
{SPLASH}
<link rel="preload" href="fonts/fredoka-latin-700-normal.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="fonts/unbounded-latin-wght-normal.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="fonts/lilita-one-latin-400-normal.woff2" as="font" type="font/woff2" crossorigin>
<style>
{FONTS}
:root{{color-scheme:light;padding-top:env(safe-area-inset-top);padding-bottom:env(safe-area-inset-bottom)}}
body{{margin:0;font:14px system-ui,-apple-system,sans-serif;overscroll-behavior:none;-webkit-tap-highlight-color:transparent;-webkit-touch-callout:none}}
/* Statusleiste: weiße Uhr/Akku-Symbole brauchen dunklen Grund, auch im hellen Modus */
@media (display-mode: standalone){{
  body::before{{content:"";position:fixed;inset:0 0 auto;height:env(safe-area-inset-top,0px);background:#0c1328;z-index:400;pointer-events:none}}
}}
img{{max-width:100%}}
[hidden]{{display:none!important}}
</style>
</head>
<body>
'''
s = HEAD + s.rstrip() + '\n</body>\n</html>\n'

assert 'window.claude' not in s, 'Claude-Laufzeitaufruf übrig'
assert 'fonts.googleapis' not in s
(HERE / 'index.html').write_text(s, encoding='utf-8')

# 5) Service Worker mit Versionsstempel (neue Version = neuer Cache)
h = hashlib.sha1(s.encode())
for f in sorted([*(HERE/'fonts').glob('*'), *(HERE/'icons').glob('*'), HERE/'config.js', HERE/'manifest.webmanifest', HERE/'sw.template.js']):
    h.update(f.name.encode()); h.update(f.read_bytes())
ver = h.hexdigest()[:10]
sw = (HERE / 'sw.template.js').read_text(encoding='utf-8').replace('__VERSION__', ver)
for f in re.findall(r"'([^']+\.(?:html|js|webmanifest|png|woff2))'", sw.split('];')[0]):
    assert (HERE / f).exists(), f'Offline-Datei fehlt: {f}'
(HERE / 'sw.js').write_text(sw, encoding='utf-8')
print('index.html und sw.js gebaut, Version', ver)
