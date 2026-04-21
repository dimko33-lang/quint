#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && echo "run as root" && exit 1
KEY="$1"
[ -z "$KEY" ] && echo "Usage: curl -s URL | sudo bash -s -- \"KEY\"" && exit 1

# Очистка
systemctl stop quint 2>/dev/null || true
rm -rf /opt/quint /etc/systemd/system/quint.service
userdel -r quint 2>/dev/null || true
systemctl daemon-reload

# Зависимости
apt update
apt install -y python3 python3-pip python3-venv

# Пользователь
useradd -m -s /bin/bash quint 2>/dev/null || true

# Структура
mkdir -p /opt/quint/{core,web,term,voids}
chown -R quint:quint /opt/quint

cd /opt/quint
echo "KIMI_API_KEY=$KEY" > .env
chown quint:quint .env && chmod 600 .env

python3 -m venv venv
chown -R quint:quint venv
sudo -u quint venv/bin/pip install --upgrade pip flask requests python-dotenv prompt_toolkit

# === ЯДРО ===
cat > core/agent.py << 'EOF'
import json, os, requests
from pathlib import Path
from datetime import datetime
from typing import List, Dict, Generator

class QuintCore:
    def __init__(self):
        self.voids = Path("/opt/quint/voids")
        self.voids.mkdir(exist_ok=True)
        self.history_file = self.voids / "history.json"
        self.css_file = self.voids / "current.css"
        self.api_key = os.getenv("KIMI_API_KEY", "").strip()
        self.url = "https://api.moonshot.ai/v1/chat/completions"
        self.thinking = False
        self.memory = False
        self.history = self._load()

    def _load(self):
        if self.history_file.exists():
            try: return json.loads(self.history_file.read_text())
            except: pass
        return []

    def _save(self):
        self.history_file.write_text(json.dumps(self.history, ensure_ascii=False, indent=2))

    def get_state(self):
        return {
            "thinking": self.thinking,
            "memory": self.memory,
            "history": self.history,
            "header": f"Quint · kimi-k2.5 (Moonshot) · thinking: {'on' if self.thinking else 'off'} · memory: {'on' if self.memory else 'off'} · {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
        }

    def toggle(self, what):
        if what == "thinking": self.thinking = not self.thinking
        elif what == "memory":
            self.memory = not self.memory
            if not self.memory: self.history = []; self._save()
        return self.get_state()

    def clear(self):
        self.history = []; self._save()
        return self.get_state()

    def chat(self, msg):
        self.history.append({"role": "user", "content": msg})
        if self.memory: self._save()
        msgs = self.history if self.memory else [{"role": "user", "content": msg}]
        headers = {"Authorization": f"Bearer {self.api_key}"}
        payload = {"model": "kimi-k2.5", "messages": msgs, "stream": True, "thinking": {"type": "enabled" if self.thinking else "disabled"}}
        full = ""
        try:
            with requests.post(self.url, headers=headers, json=payload, timeout=120, stream=True) as r:
                r.raise_for_status()
                for line in r.iter_lines(decode_unicode=True):
                    if line and line.startswith("data: "):
                        data = line[6:]
                        if data == "[DONE]": break
                        try:
                            c = json.loads(data).get("choices", [{}])[0].get("delta", {}).get("content", "")
                            if c:
                                try: c = c.encode('latin-1').decode('utf-8')
                                except: pass
                                full += c
                                yield c
                        except: continue
            if full:
                self.history.append({"role": "assistant", "content": full})
                if self.memory: self._save()
        except Exception as e:
            err = f"[error] {e}"
            self.history.append({"role": "assistant", "content": err})
            yield err
EOF

# === ВЕБ ===
cat > web/app.py << 'EOF'
import sys
sys.path.insert(0, '/opt/quint')
from core.agent import QuintCore
from flask import Flask, Response, jsonify, request, stream_with_context

core = QuintCore()
app = Flask(__name__)

HTML = """
<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Quint</title><style>
@import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500&display=swap');
*{box-sizing:border-box;margin:0;padding:0}
html,body{background:#0c0c0c;color:#d4d4d4;font-family:'JetBrains Mono',monospace;font-size:14px;line-height:1.5;padding:6px 12px;min-height:100vh}
#header{color:#4a4a4a;font-size:10px;line-height:1.3;user-select:text}
#manuscript{margin:0;padding:0;user-select:text}
.msg{margin:0;padding:0;line-height:1.6;white-space:pre-wrap;word-break:break-word}
.msg.user{color:#9a9a9a}
.msg.assistant{color:#d4d4d4}
.msg.system{color:#6a6a6a;font-style:italic}
.msg .prefix{color:#5a5a5a}
.separator{margin:0;padding:0;line-height:1.5;color:transparent;font-size:12px}
#input-line{display:flex;align-items:center;margin:0;padding:0;color:#6a6a6a}
.prompt{margin-right:8px;user-select:none;color:#5a5a5a}
#editable-input{background:transparent;border:none;color:#d4d4d4;font-family:inherit;font-size:14px;flex-grow:1;outline:none;caret-color:#a0a0a0;padding:0;min-height:1.5em}
#editable-input:empty::before{content:attr(data-placeholder);color:#4a4a4a}
</style><link rel="stylesheet" href="/css"></head><body>
<div id="header"></div><div id="manuscript"><div class="separator">***</div></div>
<div id="input-line"><span class="prompt">></span><div id="editable-input" contenteditable="true" data-placeholder=" "></div></div>
<script>
const manuscript=document.getElementById('manuscript'),editableInput=document.getElementById('editable-input'),headerEl=document.getElementById('header');
let isSending=false,lastLength=0;
async function load(){let r=await fetch('/state'),d=await r.json();manuscript.innerHTML='<div class="separator">***</div>';d.history.forEach(m=>add(m.role,m.content,false));lastLength=d.history.length;headerEl.textContent=d.header}
function add(role,content,scroll=true){let m=document.createElement('div');m.className=`msg ${role}`;let p=document.createElement('span');p.className='prefix';p.textContent=role==='user'?'&gt; ':'~ ';m.appendChild(p);m.appendChild(document.createTextNode(content));manuscript.appendChild(m);let s=document.createElement('div');s.className='separator';s.textContent='***';manuscript.appendChild(s);if(scroll)window.scrollTo(0,document.body.scrollHeight)}
async function check(){let r=await fetch('/state'),d=await r.json();if(d.history.length>lastLength){for(let i=lastLength;i<d.history.length;i++)add(d.history[i].role,d.history[i].content,true);lastLength=d.history.length}headerEl.textContent=d.header}
async function send(){let t=editableInput.innerText.trim();if(!t||isSending)return;isSending=true;editableInput.innerText='';
if(t.startsWith('/')){let r=await fetch('/cmd',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({cmd:t})}),d=await r.json();if(d.clear)manuscript.innerHTML='<div class="separator">***</div>',lastLength=0;else add('system',d.message);headerEl.textContent=d.header;isSending=false;editableInput.focus();return}
add('user',t);lastLength++;let a=document.createElement('div');a.className='msg assistant';a.innerHTML='<span class="prefix">~ </span>';manuscript.appendChild(a);
try{let r=await fetch('/chat',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({message:t})}),reader=r.body.getReader(),decoder=new TextDecoder(),full='';
while(true){let{done,value}=await reader.read();if(done)break;full+=decoder.decode(value,{stream:true});a.innerHTML='<span class="prefix">~ </span>'+full;window.scrollTo(0,document.body.scrollHeight)}
manuscript.appendChild(document.createElement('div')).className='separator';manuscript.lastChild.textContent='***';lastLength++;check()}catch(e){a.innerHTML='<span class="prefix">~ </span>[error]'}finally{isSending=false;editableInput.focus()}}
editableInput.addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();send()}});
document.addEventListener('click',e=>{if(!window.getSelection().toString()&&!e.target.closest('.msg')&&!e.target.closest('#editable-input'))editableInput.focus()});
load();editableInput.focus();setInterval(check,2000);
</script></body></html>"""

@app.route('/')          # ВОТ ЗДЕСЬ БЫЛА ОШИБКА - НЕ ХВАТАЛО def!
def index(): return HTML

@app.route('/css')
def css():
    if core.css_file.exists(): return core.css_file.read_text()
    return ''

@app.route('/state')
def state(): return jsonify(core.get_state())

@app.route('/cmd', methods=['POST'])
def cmd():
    c = request.json.get('cmd', '').strip()
    if c == '/t': return jsonify(core.toggle('thinking'))
    if c == '/m': return jsonify(core.toggle('memory'))
    if c == '/c': return jsonify(core.clear())
    return jsonify(core.get_state())

@app.route('/chat', methods=['POST'])
def chat():
    msg = request.json.get('message', '').strip()
    if not msg: return jsonify({'error': 'empty'}), 400
    return Response(stream_with_context(core.chat(msg)), mimetype='text/plain; charset=utf-8')

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=42424, debug=False, threaded=True)
EOF

# === ТЕРМИНАЛ (тонкий клиент) ===
cat > term/v.py << 'EOF'
#!/usr/bin/env python3
import requests, json, sys
from prompt_toolkit import PromptSession

URL = "http://localhost:42424"
session = PromptSession()

def req(endpoint, data=None):
    try:
        r = requests.post(f"{URL}/{endpoint}", json=data) if data else requests.get(f"{URL}/{endpoint}")
        return r.json() if r.ok else {}
    except: return {}

def header(): print("\n" + req("state").get("header", "Quint") + "\n")

def chat(msg):
    print("\n~ ", end="", flush=True)
    with requests.post(f"{URL}/chat", json={"message": msg}, stream=True) as r:
        for chunk in r.iter_content(chunk_size=None, decode_unicode=True):
            if chunk: print(chunk, end="", flush=True)
    print("\n")

header()
while True:
    try: u = session.prompt("> ")
    except: break
    u = u.strip()
    if not u: continue
    if u in ["/t", "/m", "/c"]:
        d = req("cmd", {"cmd": u})
        header()
        if not d.get("clear"): print(f"~ {d.get('message', '?')}\n")
    elif u in ["/exit", "/q"]: break
    else: chat(u)
EOF

chown quint:quint term/v.py && chmod +x term/v.py

# === СЕРВИС ===
cat > /etc/systemd/system/quint.service << 'EOF'
[Unit]
Description=Quint
After=network.target

[Service]
Type=simple
User=quint
WorkingDirectory=/opt/quint
EnvironmentFile=/opt/quint/.env
ExecStart=/opt/quint/venv/bin/python3 /opt/quint/web/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable quint && systemctl start quint

# === АЛИАС ===
sed -i '/alias v=/d' ~/.bashrc 2>/dev/null || true
echo "alias v='cd /opt/quint && sudo -u quint venv/bin/python term/v.py 2>/dev/null'" >> ~/.bashrc

sleep 2
IP=$(hostname -I | awk '{print $1}')
echo ""
echo "http://$IP:42424"
echo "v"
EOF
