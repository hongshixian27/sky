"""Set the AList base URL before startup while preserving existing configuration."""
import json
import os
import sys
from pathlib import Path


def prepare(path):
    path = Path(path)
    config = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    config["site_url"] = "https://koyeb.idkwhn.ccwu.cc/alist"
    temporary = path.with_name(path.name + ".prepare.tmp")
    with temporary.open("w", encoding="utf-8") as output:
        json.dump(config, output, ensure_ascii=False, indent=2)
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


if __name__ == "__main__":
    prepare(sys.argv[1])
