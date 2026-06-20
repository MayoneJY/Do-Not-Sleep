#!/usr/bin/env python3
import json
import shutil
from datetime import datetime
from pathlib import Path

HOOK_URL = "http://127.0.0.1:17643/event"
HOOK_COMMAND = f'curl -s -X POST -H "Content-Type: application/json" --data-binary @- {HOOK_URL}'


def backup(path: Path) -> None:
    if path.exists():
        stamp = datetime.now().strftime("%Y%m%d%H%M%S")
        shutil.copy2(path, path.with_suffix(path.suffix + f".before-do-not-sleep-{stamp}"))


def hook_entry(timeout: int = 5) -> dict:
    return {
        "matcher": "",
        "hooks": [
            {
                "type": "command",
                "command": HOOK_COMMAND,
                "timeout": timeout,
                "statusMessage": "Do Not Sleep 훅 등록 세션 동기화",
            }
        ],
    }


def has_command(entries: list) -> bool:
    for entry in entries:
        for hook in entry.get("hooks", []):
            if hook.get("command") == HOOK_COMMAND:
                return True
    return False


def add_hook(data: dict, event: str) -> None:
    hooks = data.setdefault("hooks", {})
    entries = hooks.setdefault(event, [])
    if not has_command(entries):
        entries.append(hook_entry())


def load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def save_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as file:
        json.dump(data, file, ensure_ascii=False, indent=2)
        file.write("\n")


def install_claude() -> None:
    path = Path.home() / ".claude" / "settings.json"
    data = load_json(path)
    backup(path)
    for event in ("SessionStart", "SessionEnd", "SubagentStart", "SubagentStop"):
        add_hook(data, event)
    save_json(path, data)
    print(f"Claude 훅 설정 완료: {path}")


def install_codex() -> None:
    path = Path.home() / ".codex" / "hooks.json"
    data = load_json(path)
    backup(path)
    for event in ("UserPromptSubmit", "PostToolUse", "Stop", "SubagentStart", "SubagentStop"):
        add_hook(data, event)
    save_json(path, data)
    print(f"Codex 훅 설정 완료: {path}")
    print("Codex에서 /hooks를 열어 새 command hook을 신뢰 처리해야 실행됩니다.")


def main() -> None:
    install_codex()
    install_claude()
    print(f"Do Not Sleep 훅 수신 주소: {HOOK_URL}")


if __name__ == "__main__":
    main()
