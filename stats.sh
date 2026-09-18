#!/bin/zsh
# Сводка: сколько скачали Гига Писаря. Всё считает GitHub, нужен только gh.
#   ./stats.sh            коротко
#   ./stats.sh --all      плюс каждая версия по отдельности
set -e
R=moznoazachem/giga-pisar
CLI=moznoazachem/giga-pisar-cli
REL=$(gh api "repos/$R/releases?per_page=100")
CLIREL=$(gh api "repos/$CLI/releases?per_page=20")

echo "Гига Писарь: сводка на $(date '+%d.%m.%Y %H:%M')"
echo
python3 - "$REL" "$CLIREL" "${1:-}" <<'PY'
import json, sys
rel, clirel, mode = json.loads(sys.argv[1]), json.loads(sys.argv[2]), sys.argv[3]
app = model_mac = 0
rows = []
for r in rel:
    tag = r["tag_name"]; date = (r.get("published_at") or "")[:10]
    parts = []
    for a in r["assets"]:
        n, c = a["name"], a["download_count"]
        if n.endswith(".zip") or n.endswith(".dmg"):
            app += c; parts.append(f"{'образ' if n.endswith('.dmg') else 'архив'} {c}")
        elif "gigaam" in n:
            model_mac += c
    rows.append((tag, date, ", ".join(parts) or "—"))
model_cli = sum(a["download_count"] for r in clirel for a in r["assets"] if "gigaam" in a["name"])
installs = model_mac + model_cli
print(f"Приложение скачано:        {app}")
print(f"Модель скачана (1 раз на установку): {installs}  (из мак-релизов {model_mac}, из консольных {model_cli})")
print(f"Живых установок, оценка:   около {installs}")
print()
newest = rows[:5] if mode != "--all" else rows
print("По версиям" + ("" if mode == "--all" else " (последние пять, полный список: --all)") + ":")
for tag, date, parts in newest:
    print(f"  {tag:8} {date}  {parts}")
PY
echo
echo "Вокруг репозитория:"
gh api repos/$R -q '"  звёзды \(.stargazers_count), форки \(.forks_count)"'
gh api repos/$R/traffic/views -q '"  просмотры за 14 дней: \(.count) от \(.uniques) человек"'
gh api repos/$R/traffic/clones -q '"  клонов кода за 14 дней: \(.count) от \(.uniques) человек"'
echo
echo "Не считаются: скачивания с GitFlic и заходы на сайт (у GitHub Pages нет статистики)."
