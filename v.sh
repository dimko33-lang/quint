#!/bin/bash
set -e

[ "$EUID" -ne 0 ] && echo "run as root" && exit 1

KEY="$1"
[ -z "$KEY" ] && echo "Usage: curl -s URL | sudo bash -s -- \"KEY\"" && exit 1

# Очистка
systemctl stop quint 2>/dev/null || true
systemctl disable quint 2>/dev/null || true
rm -f /etc/systemd/system/quint.service
rm -rf /opt/quint
systemctl daemon-reload

# Зависимости
apt update
apt install -y python3 python3-pip python3-venv

# Структура
mkdir -p /opt/quint/{core,web,term,voids}
cd /opt/quint

# Ключ
echo "KIMI_API_KEY=$KEY" > .env
chmod 600 .env

# Python env
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask requests python-dotenv prompt_toolkit

# === ЯДРО ===
cat > core/__init__.py << 'EOF'
from .agent import QuintCore
EOF

cat > core/agent.py << 'EOF'
#!/usr/bin/env python3
import json
import os
import requests
from pathlib import Path
from typing import List, Dict, Generator

class QuintCore:
    def __init__(self, work_dir: str = "/opt/quint"):
        self.work_dir = Path(work_dir)
        self.voids_dir = self.work_dir / "voids"
        self.history_file = self.voids_dir / "history.json"
        self.css_file = self.voids_dir / "current.css"
        
        self.voids_dir.mkdir(parents=True, exist_ok=True)
        
        self.api_key = os.getenv("KIMI_API_KEY", "").strip()
        self.model = "kimi-k2.5"
        self.url = "https://api.moonshot.ai/v1/chat/completions"
        self.timeout = 120
        
        self.thinking_enabled = False
        self.memory_enabled = False
        self.conversation_history = self._load_history()
    
    def _load_history(self) -> List[Dict]:
        if self.history_file.exists():
            try:
                return json.loads(self.history_file.read_text(encoding='utf-8'))
            except:
                pass
        return []
    
    def _save_history(self):
        self.history_file.write_text(
            json.dumps(self.conversation_history, ensure_ascii=False, indent=2),
            encoding='utf-8'
        )
    
    def toggle_thinking(self) -> str:
        self.thinking_enabled = not self.thinking_enabled
        return "on" if self.thinking_enabled else "off"
    
    def toggle_memory(self) -> str:
        self.memory_enabled = not self.memory_enabled
        if not self.memory_enabled:
            self.conversation_history = []
            self._save_history()
        return "on" if self.memory_enabled else "off"
    
    def clear(self):
        self.conversation_history = []
        self._save_history()
    
    def chat_stream(self, message: str) -> Generator[str, None, None]:
        self.conversation_history.append({"role": "user", "content": message})
        if self.memory_enabled:
            self._save_history()
        
        messages = self.conversation_history if self.memory_enabled else [{"role": "user", "content": message}]
        
        headers = {"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"}
        payload = {
            "model": self.model,
            "messages": messages,
            "stream": True,
            "thinking": {"type": "enabled"} if self.thinking_enabled else {"type": "disabled"}
        }
        
        full_response = ""
        try:
            with requests.post(self.url, headers=headers, json=payload, timeout=self.timeout, stream=True) as resp:
                resp.raise_for_status()
                for line in resp.iter_lines(decode_unicode=True):
                    if line and line.startswith("data: "):
                        data = line[6:]
                        if data == "[DONE]":
                            break
                        try:
                            chunk = json.loads(data)
                            delta = chunk.get("choices", [{}])[0].get("delta", {})
                            content = delta.get("content", "")
                            if content:
                                try:
                                    content = content.encode('latin-1').decode('utf-8')
                                except:
                                    pass
                                full_response += content
                                yield content
                        except:
                            continue
            
            if full_response:
                self.conversation_history.append({"role": "assistant", "content": full_response})
                if self.memory_enabled:
                    self._save_history()
        except Exception as e:
            error_msg = f"[error] {str(e)}"
            self.conversation_history.append({"role": "assistant", "content": error_msg})
            if self.memory_enabled:
                self._save_history()
            yield error_msg
    
    def get_css(self) -> str:
        if self.css_file.exists():
            return self.css_file.read_text(encoding='utf-8')
        return ""
    
    def apply_css(self, css: str):
        self.css_file.write_text(css, encoding='utf-8')
    
    def reset_css(self):
        if self.css_file.exists():
            self.css_file.unlink()
EOF

# === ВЕБ-ИНТЕРФЕЙС ===
cat > web/app.py << 'EOF'
#!/usr/bin/env python3
import sys
sys.path.insert(0, '/opt/quint')
from core import QuintCore
from flask import Flask, Response, jsonify, request, stream_with_context
from datetime import datetime

core = QuintCore()
app = Flask(__name__)

MODEL_NAME = "kimi-k2.5"
PROVIDER = "Moonshot"

HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Quint</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500&display=swap');
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body { background: #0c0c0c; color: #d4d4d4; font-family: 'JetBrains Mono', monospace; font-size: 14px; line-height: 1.5; padding: 6px 12px; min-height: 100vh; }
#header { color: #4a4a4a; font-size: 10px; margin: 0; padding: 0; line-height: 1.3; user-select: text; }
#manuscript { margin: 0; padding: 0; user-select: text; }
.msg { margin: 0; padding: 0; line-height: 1.6; white-space: pre-wrap; word-break: break-word; user-select: text; }
.msg.user { color: #9a9a9a; }
.msg.assistant { color: #d4d4d4; }
.msg.system { color: #6a6a6a; font-style: italic; }
.msg .prefix { color: #5a5a5a; user-select: text; }
.separator { margin: 0; padding: 0; line-height: 1.5; color: transparent; user-select: text; font-size: 12px; }
#input-line { display: flex; align-items: center; margin: 0; padding: 0; color: #6a6a6a; }
.prompt { margin-right: 8px; user-select: none; color: #5a5a5a; }
#editable-input { background: transparent; border: none; color: #d4d4d4; font-family: inherit; font-size: 14px; flex-grow: 1; outline: none; caret-color: #a0a0a0; padding: 0; min-height: 1.5em; user-select: text; }
#editable-input:empty::before { content: attr(data-placeholder); color: #4a4a4a; }
</style>
<link rel="stylesheet" href="/css" id="dynamic-css">
</head>
<body>
<div id="header">Quint · """ + MODEL_NAME + """ (""" + PROVIDER + """) · <span id="thinking-status">thinking: off</span> · <span id="memory-status">memory: off</span> · """ + datetime.now().strftime('%Y-%m-%d %H:%M:%S') + """</div>
<div id="manuscript"><div class="separator">***</div></div>
<div id="input-line"><span class="prompt">></span><div id="editable-input" contenteditable="true" data-placeholder=" "></div></div>
<script>
const manuscript = document.getElementById('manuscript');
const editableInput = document.getElementById('editable-input');
let isSending = false;

async function loadHistory() {
    const res = await fetch('/history');
    const data = await res.json();
    manuscript.innerHTML = '<div class="separator">***</div>';
    data.history.forEach(msg => addMessageToUI(msg.role, msg.content, false));
    document.getElementById('thinking-status').textContent = `thinking: ${data.thinking ? 'on' : 'off'}`;
    document.getElementById('memory-status').textContent = `memory: ${data.memory ? 'on' : 'off'}`;
}

function addMessageToUI(role, content, scroll = true) {
    const msgDiv = document.createElement('div');
    msgDiv.className = `msg ${role}`;
    const prefixSpan = document.createElement('span');
    prefixSpan.className = 'prefix';
    prefixSpan.textContent = role === 'user' ? '> ' : '~ ';
    msgDiv.appendChild(prefixSpan);
    msgDiv.appendChild(document.createTextNode(content));
    manuscript.appendChild(msgDiv);
    const sep = document.createElement('div');
    sep.className = 'separator';
    sep.textContent = '***';
    manuscript.appendChild(sep);
    if (scroll) window.scrollTo(0, document.body.scrollHeight);
}

function refreshCSS() { document.getElementById('dynamic-css').href = '/css?' + Date.now(); }

async function sendMessage() {
    const text = editableInput.innerText.trim();
    if (!text || isSending) return;
    isSending = true;
    editableInput.innerText = '';
    
    if (text.startsWith('/')) {
        const res = await fetch('/command', { 
            method: 'POST', 
            headers: {'Content-Type': 'application/json'}, 
            body: JSON.stringify({command: text}) 
        });
        const data = await res.json();
        if (data.clear) manuscript.innerHTML = '<div class="separator">***</div>';
        else addMessageToUI('system', data.message);
        document.getElementById('thinking-status').textContent = `thinking: ${data.thinking ? 'on' : 'off'}`;
        document.getElementById('memory-status').textContent = `memory: ${data.memory ? 'on' : 'off'}`;
        isSending = false;
        editableInput.focus();
        return;
    }
    
    addMessageToUI('user', text);
    const assistantDiv = document.createElement('div');
    assistantDiv.className = 'msg assistant';
    const prefixSpan = document.createElement('span');
    prefixSpan.className = 'prefix';
    prefixSpan.textContent = '~ ';
    assistantDiv.appendChild(prefixSpan);
    manuscript.appendChild(assistantDiv);
    
    try {
        const res = await fetch('/chat', { 
            method: 'POST', 
            headers: {'Content-Type': 'application/json'}, 
            body: JSON.stringify({message: text}) 
        });
        if (!res.ok) throw new Error('Chat failed');
        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let fullResponse = '';
        while (true) {
            const {done, value} = await reader.read();
            if (done) break;
            const chunk = decoder.decode(value, {stream: true});
            fullResponse += chunk;
            assistantDiv.innerHTML = '<span class="prefix">~ </span>' + fullResponse;
            window.scrollTo(0, document.body.scrollHeight);
        }
        const sep = document.createElement('div');
        sep.className = 'separator';
        sep.textContent = '***';
        manuscript.appendChild(sep);
        refreshCSS();
    } catch (e) {
        assistantDiv.innerHTML = '<span class="prefix">~ </span>[error]';
    } finally {
        isSending = false;
        editableInput.focus();
    }
}

editableInput.addEventListener('keydown', e => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
});

document.addEventListener('click', e => {
    const isTextSelection = window.getSelection().toString().length > 0;
    if (!isTextSelection && !e.target.closest('.msg') && !e.target.closest('#editable-input') && !e.target.closest('#header')) {
        editableInput.focus();
    }
});

document.addEventListener('keydown', e => {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'a') {
        e.preventDefault();
        const selection = window.getSelection();
        const range = document.createRange();
        const header = document.getElementById('header');
        range.setStartBefore(header);
        range.setEndAfter(manuscript.lastChild || manuscript);
        selection.removeAllRanges();
        selection.addRange(range);
    }
});

document.addEventListener('copy', e => {
    const selection = window.getSelection();
    e.clipboardData.setData('text/plain', selection.toString());
    e.preventDefault();
});

loadHistory();
editableInput.focus();
</script>
</body>
</html>
"""

@app.route('/')
def index(): return HTML

@app.route('/css')
def get_css(): return core.get_css()

@app.route('/history')
def get_history():
    return jsonify({
        'history': core.conversation_history,
        'thinking': core.thinking_enabled,
        'memory': core.memory_enabled
    })

@app.route('/command', methods=['POST'])
def handle_command():
    data = request.get_json()
    cmd = data.get('command', '').lower().strip()
    
    if cmd == '/t':
        status = core.toggle_thinking()
        return jsonify({'thinking': core.thinking_enabled, 'memory': core.memory_enabled, 'message': f'thinking {status}'})
    elif cmd == '/m':
        status = core.toggle_memory()
        msg = f'memory {status}' + (' (cleared)' if status == 'off' else '')
        return jsonify({'thinking': core.thinking_enabled, 'memory': core.memory_enabled, 'message': msg})
    elif cmd == '/c':
        core.clear()
        return jsonify({'thinking': core.thinking_enabled, 'memory': core.memory_enabled, 'clear': True})
    else:
        return jsonify({'thinking': core.thinking_enabled, 'memory': core.memory_enabled, 'message': '?'})

@app.route('/chat', methods=['POST'])
def chat():
    data = request.get_json()
    msg = data.get('message', '').strip()
    if not msg: return jsonify({'error': 'empty'}), 400
    return Response(stream_with_context(core.chat_stream(msg)), mimetype='text/plain; charset=utf-8')

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=42424, debug=False, threaded=True)
EOF

# === ТЕРМИНАЛ ===
cat > term/v.py << 'EOF'
#!/usr/bin/env python3
import sys
sys.path.insert(0, '/opt/quint')
from core import QuintCore
from prompt_toolkit import PromptSession

core = QuintCore()
session = PromptSession()

def header():
    thinking = "on" if core.thinking_enabled else "off"
    memory = "on" if core.memory_enabled else "off"
    print("\033cQuint ⁰³ | kimi-k2.5 (Moonshot) | thinking: " + thinking + " | memory: " + memory + "\n")

def chat(p):
    print("\n~ ", end="", flush=True)
    for chunk in core.chat_stream(p):
        print(chunk, end="", flush=True)
    print("\n")

header()
while True:
    try:
        u = session.prompt("> ")
    except (EOFError, KeyboardInterrupt):
        break
    u = u.strip()
    if not u: continue
    if u == "/t":
        core.toggle_thinking()
        header()
        print("~ thinking: " + ("on" if core.thinking_enabled else "off") + "\n")
    elif u == "/m":
        status = core.toggle_memory()
        header()
        print("~ memory: " + status + (" (cleared)" if status == "off" else "") + "\n")
    elif u == "/c":
        core.clear()
        header()
    elif u in ["/exit", "/q"]:
        break
    else:
        chat(u)
EOF

chmod +x term/v.py

# === СЕРВИС ===
cat > /etc/systemd/system/quint.service << EOF
[Unit]
Description=Quint Web
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/quint
EnvironmentFile=/opt/quint/.env
ExecStart=/opt/quint/venv/bin/python3 /opt/quint/web/app.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable quint.service
systemctl start quint.service

sleep 2

if systemctl is-active --quiet quint.service; then
    IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo "=== Quint ==="
    echo "Web:  http://$IP:42424"
    echo "Term: cd /opt/quint && source venv/bin/activate && python term/v.py"
    echo ""
else
    journalctl -u quint.service -n 10 --no-pager
    exit 1
fi
