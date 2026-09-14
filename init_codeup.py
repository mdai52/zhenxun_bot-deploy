"""通过一键包内置的 Codeup 配置初始化或更新仓库。"""

from __future__ import annotations

import argparse
import base64
import os
from pathlib import Path
import stat
import subprocess
import tempfile


ALIYUN_ORG_ID = "67a361cf556e6cdab537117a"
ALIYUN_REPO_MAPPING = {
    "zhenxun-bot-resources": "4957431",
    "zhenxun_bot_plugins_index": "4957418",
    "zhenxun_bot_plugins": "4957429",
    "zhenxun_docs": "4957426",
    "zhenxun_bot": "4957428",
}

# 与 Windows 一键包保持一致。Base64 仅用于编码，并不提供保密能力。
RDC_ACCESS_TOKEN_ENCODED = (
    "cHQtYXp0allnQWpub0FYZWpqZm1RWGtneHk0XzBlMmYzZTZmLWQwOWItNDE4Mi1iZWUx"
    "LTQ1ZTFkYjI0NGRlMg=="
)


def run_git(*args: str, env: dict[str, str] | None = None) -> None:
    subprocess.run(["git", *args], check=True, env=env)


def build_repository_url(repository: str) -> str:
    if repository not in ALIYUN_REPO_MAPPING:
        available = ", ".join(sorted(ALIYUN_REPO_MAPPING))
        raise ValueError(f"未知仓库 {repository!r}，可用值：{available}")
    return (
        f"https://codeup.aliyun.com/{ALIYUN_ORG_ID}/"
        f"zhenxun-org/{repository}.git"
    )


def authenticated_git_environment(token: str, askpass: Path) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "GIT_ASKPASS": str(askpass),
            "GIT_TERMINAL_PROMPT": "0",
            "ZHENXUN_CODEUP_TOKEN": token,
        }
    )
    return env


def write_askpass(directory: Path) -> Path:
    askpass = directory / "askpass.sh"
    askpass.write_text(
        "#!/bin/sh\n"
        "case \"$1\" in\n"
        "  *sername*) printf '%s\\n' 'oauth2' ;;\n"
        "  *assword*) printf '%s\\n' \"$ZHENXUN_CODEUP_TOKEN\" ;;\n"
        "  *) exit 1 ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    askpass.chmod(askpass.stat().st_mode | stat.S_IXUSR)
    return askpass


def ensure_remote(repository_url: str) -> None:
    remotes = subprocess.run(
        ["git", "remote"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.split()
    if "origin" in remotes:
        run_git("remote", "set-url", "origin", repository_url)
    else:
        run_git("remote", "add", "origin", repository_url)


def initialize_or_update(repository: str, *, update: bool) -> None:
    repository_url = build_repository_url(repository)
    token = base64.b64decode(RDC_ACCESS_TOKEN_ENCODED).decode("utf-8")

    if not Path(".git").is_dir():
        print("未检测到 Git 仓库，正在初始化...")
        run_git("init", "-b", "main")
        is_new = True
    else:
        is_new = False

    ensure_remote(repository_url)
    if not is_new and not update:
        print("Git 仓库已存在，跳过 Codeup 拉取。")
        return

    with tempfile.TemporaryDirectory(prefix="zhenxun-codeup-") as temp_dir:
        askpass = write_askpass(Path(temp_dir))
        env = authenticated_git_environment(token, askpass)
        if is_new:
            print(f"正在从阿里云 Codeup 拉取 {repository} ...")
            run_git(
                "pull",
                "origin",
                "main",
                "--allow-unrelated-histories",
                env=env,
            )
        else:
            print(f"正在从阿里云 Codeup 手动更新 {repository} ...")
            run_git("pull", "--ff-only", "origin", "main", env=env)

    print("Codeup 操作完成。")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("repository", nargs="?", default="zhenxun_bot")
    parser.add_argument(
        "--update",
        action="store_true",
        help="对已有仓库执行一次手动快进更新",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        initialize_or_update(args.repository, update=args.update)
    except (ValueError, UnicodeDecodeError, subprocess.CalledProcessError) as error:
        print(f"Codeup 操作失败：{error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
