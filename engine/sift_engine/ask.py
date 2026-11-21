"""Search from the terminal: python -m sift_engine.ask "halvorsen plural llm"   (or "--status")."""

import json
import socket
import sys
import time

from . import config


def ask(req: dict, wait: float = 0) -> dict:
    deadline = time.time() + wait
    while True:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.connect(str(config.SOCKET))
                s.sendall((json.dumps(req) + "\n").encode())
                data = b""
                while not data.endswith(b"\n"):
                    chunk = s.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                return json.loads(data)
        except (FileNotFoundError, ConnectionRefusedError):
            if time.time() > deadline:
                raise SystemExit("the engine isn't running")
            time.sleep(0.2)


def main():
    args = sys.argv[1:]
    if not args or args[0] == "--status":
        print(json.dumps(ask({"op": "status"}, wait=30), indent=1))
        return
    q = " ".join(args)
    r = ask({"op": "search", "q": q, "deep": True}, wait=30)
    home = str(config.HOME)
    print(f"{r.get('ms')} ms")
    for d in r.get("docs", []):
        where = f" p.{d['page']}" if d.get("page") else ""
        print(f"  [{d['score']:.2f} z={d['z']} w={d['words']}] {d['title'] or ''}\n      {d['path'].replace(home, '~')}{where}")
    for f in r.get("files", [])[:6]:
        print(f"  [{f['score']}] {f['path'].replace(home, '~')}")


if __name__ == "__main__":
    main()
