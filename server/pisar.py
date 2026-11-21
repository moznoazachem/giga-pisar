#!/usr/bin/env python
"""Гига Писарь — распознавание русской речи через GigaAM v3 (ONNX, процессор).

    pisar запись.ogg              распознать файл, вывести текст
    pisar a.m4a b.wav c.mp3       несколько файлов подряд
    pisar --serve                 поднять сервер распознавания
    pisar --model-dir DIR ...     указать папку с моделью явно

Режим сервера держит модель в памяти и принимает записи по сети:

    POST /v1/audio/transcriptions   multipart, поле file → {"text": "..."}
    GET  /health                    проверка, что сервер жив

Обращение к нему совместимо с OpenAI, поэтому годится и для маковского
приложения, и для чужих программ вроде MacWhisper. По умолчанию слушает
127.0.0.1:8737 — только свою машину, наружу ничего не торчит.

Принимает любой формат, который понимает ffmpeg. Записи длиннее 25 секунд
режет по паузам между фразами, а не посреди слова, и склеивает результат.
Работает целиком на своей машине — в сеть ничего не уходит.

Папка с моделью берётся из PISAR_MODEL_DIR, иначе из /opt/gigaam/onnx_int8,
иначе из папки model рядом со скриптом.
"""
import contextlib
import json
import os
import sys
import tempfile
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import giga_core

HOST = "127.0.0.1"
PORT = 8737
MAX_REQUEST = 100 * 1024 * 1024   # a larger body is not read: the answer is 413


# ─────────────────────────── режим сервера ───────────────────────────

def _разобрать_multipart(тело: bytes, content_type: str) -> bytes:
    """Достаёт содержимое поля file. Свой разбор — чтобы не тянуть fastapi."""
    маркер = "boundary="
    if маркер not in content_type:
        raise ValueError("в запросе нет границы multipart")
    граница = content_type.split(маркер, 1)[1].strip().strip('"')
    разделитель = b"--" + граница.encode()

    for часть in тело.split(разделитель):
        if b"\r\n\r\n" not in часть:
            continue
        шапка, содержимое = часть.split(b"\r\n\r\n", 1)
        if b'name="file"' not in шапка:
            continue
        # у последней части в хвосте остаются CRLF и «--»
        return содержимое.rstrip(b"-").rstrip(b"\r\n")
    raise ValueError("в запросе нет поля file")


def serve(model_dir: str, host: str = HOST, port: int = PORT) -> None:
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    print(f"[писарь] загружаю модель...", file=sys.stderr, flush=True)
    engine = giga_core.Engine(model_dir)
    замок = threading.Lock()
    print(f"[писарь] готов: http://{host}:{port}  (модель: {engine.model_dir})",
          file=sys.stderr, flush=True)

    class Обработчик(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):      # без шума в консоли
            pass

        def _ответ(self, код: int, данные: dict) -> None:
            тело = json.dumps(данные, ensure_ascii=False).encode()
            self.send_response(код)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(тело)))
            self.end_headers()
            self.wfile.write(тело)

        def do_GET(self):
            if self.path.rstrip("/") in ("/health", "/v1/health"):
                self._ответ(200, {"status": "ok", "model": giga_core.MODEL_NAME})
            else:
                self._ответ(404, {"error": "нет такого адреса"})

        def do_POST(self):
            if not self.path.rstrip("/").endswith("/audio/transcriptions"):
                self._ответ(404, {"error": "нет такого адреса"})
                return
            try:
                длина = int(self.headers.get("Content-Length", 0))
            except ValueError:
                длина = -1
            if длина < 0:
                self.close_connection = True
                self._ответ(400, {"error": "нет длины запроса"})
                return
            if длина > MAX_REQUEST:
                self.close_connection = True      # the body stays unread
                self._ответ(413, {"error": "запись больше 100 МБ"})
                return
            try:
                запись = _разобрать_multipart(
                    self.rfile.read(длина), self.headers.get("Content-Type", ""))
            except Exception as e:
                self.close_connection = True      # the body may be half-read
                self._ответ(400, {"error": f"не разобрал запрос: {e}"})
                return

            try:
                with tempfile.TemporaryDirectory() as tmp:
                    путь = os.path.join(tmp, "запись")
                    with open(путь, "wb") as f:
                        f.write(запись)
                    with замок:                 # модель одна, пускаем по очереди
                        текст = engine.transcribe(путь)
                self._ответ(200, {"text": текст})
            except Exception as e:
                print(f"[писарь] сбой распознавания: {e}", file=sys.stderr, flush=True)
                self._ответ(500, {"error": str(e)})

    Обработчик.timeout = 30                       # a slow client must not hold a thread forever
    ThreadingHTTPServer((host, port), Обработчик).serve_forever()


# ─────────────────────────── командная строка ───────────────────────────

def main() -> None:
    args = sys.argv[1:]

    def взять(флаг, по_умолчанию=None):
        if флаг in args:
            i = args.index(флаг)
            значение = args[i + 1]
            del args[i:i + 2]
            return значение
        return по_умолчанию

    model_dir = взять("--model-dir", "") or ""
    host = взять("--host", HOST)
    port = int(взять("--port", PORT))
    режим_сервера = "--serve" in args
    if режим_сервера:
        args.remove("--serve")

    if режим_сервера:
        serve(model_dir, host, port)
        return

    if not args or args[0] in ("-h", "--help"):
        print(__doc__, file=sys.stderr)
        sys.exit(0 if args else 1)

    real_stdout = sys.stdout
    # служебное — в stderr, чтобы вызывающему достался только чистый текст
    with contextlib.redirect_stdout(sys.stderr):
        engine = giga_core.Engine(model_dir)
        результаты = [(путь, engine.transcribe(путь)) for путь in args]

    for путь, текст in результаты:
        if len(args) > 1:
            print(f"── {os.path.basename(путь)}", file=sys.stderr)
        print(текст, file=real_stdout)


if __name__ == "__main__":
    main()
