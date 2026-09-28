#!/usr/bin/env python3
"""Mac Studio などで画像生成を待ち受ける、小さなサーバー。

mflux（MLX 版の画像生成）を呼び出して、PNG を返すだけ。
社内 LAN の中だけで使う前提で、認証は合言葉（トークン）1つにしている。

    uv tool install --upgrade mflux        # 先に mflux を入れる
    python3 image-server.py                 # 既定では 8770 番で待ち受ける

    環境変数
      IMAGE_SERVER_PORT   待ち受けるポート（既定 8770）
      IMAGE_SERVER_TOKEN  合言葉。設定すると Authorization ヘッダーで確認する
      IMAGE_MODEL         qwen-2.1（既定） / qwen / schnell / dev
      IMAGE_QUANTIZE      4 または 8（既定 8）。小さいほど省メモリで速いが粗くなる

使い方（アプリ側はこれを叩く）:

    POST /generate  {"prompt": "夜空を見上げる青年", "steps": 20, "width": 1024, "height": 1024}
    → PNG を返す
"""

import base64
import json
import os
import shutil
import subprocess
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.environ.get("IMAGE_SERVER_PORT", "8770"))
TOKEN = os.environ.get("IMAGE_SERVER_TOKEN", "")
MODEL = os.environ.get("IMAGE_MODEL", "qwen-2.1")
QUANTIZE = os.environ.get("IMAGE_QUANTIZE", "8")

# モデルごとの呼び出しコマンド（mflux が入れてくれる）
COMMANDS = {
    "qwen-2.1": "mflux-generate-qwen-2.1",
    "qwen": "mflux-generate-qwen",
    "schnell": "mflux-generate",
    "dev": "mflux-generate",
}


def command_for(model):
    name = COMMANDS.get(model)
    if not name or not shutil.which(name):
        raise RuntimeError(f"{name or model} が見つかりません。`uv tool install --upgrade mflux` を実行してください")
    args = [name]
    if model in ("schnell", "dev"):
        args += ["--model", model]
    return args


def generate(prompt, steps, width, height, seed):
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "out.png"
        args = command_for(MODEL) + [
            "--prompt", prompt,
            "--steps", str(steps),
            "--width", str(width),
            "--height", str(height),
            "--quantize", QUANTIZE,
            "--output", str(out),
        ]
        if seed is not None:
            args += ["--seed", str(seed)]
        started = time.time()
        result = subprocess.run(args, capture_output=True, text=True, timeout=900)
        if result.returncode != 0 or not out.exists():
            message = (result.stderr or result.stdout).strip().splitlines()
            raise RuntimeError("生成に失敗しました: " + (message[-1] if message else "原因不明"))
        print(f"生成 {time.time() - started:.0f}秒: {prompt[:40]}", flush=True)
        return out.read_bytes()


class Handler(BaseHTTPRequestHandler):
    def _deny(self, code, message):
        body = json.dumps({"error": message}, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802  動作確認用
        if self.path == "/health":
            self._deny(200, f"ok（モデル {MODEL}）")
        else:
            self._deny(404, "見つかりません")

    def do_POST(self):  # noqa: N802
        if self.path != "/generate":
            return self._deny(404, "見つかりません")
        if TOKEN and self.headers.get("Authorization") != f"Bearer {TOKEN}":
            return self._deny(401, "合言葉が違います")
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
            prompt = (payload.get("prompt") or "").strip()
            if not prompt:
                return self._deny(400, "prompt がありません")
            png = generate(
                prompt=prompt,
                steps=int(payload.get("steps", 20)),
                width=int(payload.get("width", 1024)),
                height=int(payload.get("height", 1024)),
                seed=payload.get("seed"),
            )
        except Exception as error:  # noqa: BLE001  失敗の理由をそのまま返す
            return self._deny(500, str(error))
        if payload.get("base64"):
            body = json.dumps({"image": base64.b64encode(png).decode()}).encode()
            content_type = "application/json"
        else:
            body = png
            content_type = "image/png"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass  # 既定のアクセスログは出さない（生成のログだけ出す）


if __name__ == "__main__":
    print(f"画像生成サーバー: http://0.0.0.0:{PORT}/generate（モデル {MODEL}、量子化 {QUANTIZE}ビット）")
    if not TOKEN:
        print("※ 合言葉が未設定です。社内 LAN の外に出さないでください（IMAGE_SERVER_TOKEN で設定できます）")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
