#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops"                     # псевдоним из ~/.ssh/config (ПР № 5, шаг 1.6)
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
LOCAL_DIR="$(git rev-parse --show-toplevel)/site/"

die() { echo "deploy: $*" >&2; exit 1; }

# 1. Разбор аргумента --dry-run
DRY_RUN=""
case "${1:-}" in
    "")        ;;
    --dry-run) DRY_RUN="--dry-run" ;;
    *)         die "неизвестный аргумент '$1'. Использование: scripts/deploy.sh [--dry-run]" ;;
esac

# rsync из macOS (openrsync) не поддерживает --chmod — нужен GNU rsync 3.x
rsync --version 2>/dev/null | head -1 | grep -q 'version 3' \
    || die "требуется GNU rsync 3.x (на macOS: brew install rsync)"

# 2. Проверки по требованиям 4 и 5
[[ -f "${LOCAL_DIR}index.html" ]] \
    || die "нет файла ${LOCAL_DIR}index.html — доставка отменена (--delete удалил бы главную страницу)"
[[ -z "$(git status --porcelain)" ]] \
    || die "в репозитории есть незафиксированные изменения — сначала выполните commit"

COMMIT="$(git rev-parse --short HEAD)"

# 3. Синхронизация: одно SSH-соединение, без интерактивного ввода пароля
rsync -az --delete --chmod=D755,F644 ${DRY_RUN} --itemize-changes \
    -e "ssh -o BatchMode=yes -o ConnectTimeout=5" \
    "${LOCAL_DIR}" "${REMOTE}:${REMOTE_DIR}/"

# 4. При --dry-run — завершение без проверки доступности
if [[ -n "${DRY_RUN}" ]]; then
    echo "dry-run: план выведен, сервер не изменён (коммит ${COMMIT})"
    exit 0
fi

# 5. Проверка доступности с проверкой сертификата
curl -fsS --max-time 5 --cacert "${CA_CERT}" -o /dev/null "${SITE_URL}/" \
    || die "ресурс ${SITE_URL} недоступен после доставки"

echo "deployed ${COMMIT}"
