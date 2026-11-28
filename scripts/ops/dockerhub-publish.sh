#!/usr/bin/env bash
# ============================================================================
# dockerhub-publish.sh — Сборка (linux/amd64) и публикация образа Patroni в Docker Hub
# ============================================================================
# Вызов: ./ligactl publish-image [--repo aligorov/ligament_vault_patroni] [--tag 16] [--multiarch]
#
# Собирает Dockerfile.patroni, пушит в Docker Hub (:16, :latest, :git-sha) и
# автоматически фиксирует @sha256 дайджест в control.sqlite3!
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"

REPO="${DOCKERHUB_PATRONI_REPO:-aligorov/ligament_vault_patroni}"
TAG="16"
PLATFORMS="linux/amd64"

usage() {
    cat <<'EOF'
Использование: ./ligactl publish-image [опции]

Опции:
  --repo <user/name>   Репозиторий Docker Hub (по умолчанию aligorov/ligament_vault_patroni)
  --tag <tag>          Основной тег образа (по умолчанию 16)
  --multiarch          Собрать мультиархитектурный образ (linux/amd64,linux/arm64)
  --dry-run            Показать команды сборки и публикации без запуска
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)      REPO="$2"; shift 2 ;;
        --tag)       TAG="$2"; shift 2 ;;
        --multiarch) PLATFORMS="linux/amd64,linux/arm64"; shift ;;
        --help|-h)   usage; exit 0 ;;
        *)           log_error "Неизвестный параметр publish-image: $1"; usage; exit 1 ;;
    esac
done

GIT_SHA=$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d)

if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] docker buildx build --platform ${PLATFORMS} -f Dockerfile.patroni -t ${REPO}:${TAG} -t ${REPO}:${TAG}-${GIT_SHA} -t ${REPO}:latest --push ."
    exit 0
fi

check_command docker

# Неблокирующая проверка живого демона Docker с жестким таймаутом 4 сек (защита от зависания сокета на macOS!)
if ! python3 -c '
import subprocess, sys
try:
    r = subprocess.run(["docker", "version", "--format", "{{.Server.Version}}"], capture_output=True, text=True, timeout=4)
    sys.exit(0 if r.returncode == 0 and r.stdout.strip() else 1)
except Exception:
    sys.exit(1)
'; then
    log_error "Локальный демон Docker не отвечает (проверьте окно Docker Desktop на Mac — возможно висит диалог ошибки)."
    log_error "Перезапустите Docker Desktop и повторите './ligactl publish-image', либо используйте облачную сборку GitHub Actions (.github/workflows/dockerhub.yml)."
    exit 1
fi

log_step "Сборка и публикация ${REPO}:${TAG} (${PLATFORMS}) в Docker Hub"

BUILDER_NAME="ligament-builder"
if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
    docker buildx create --name "${BUILDER_NAME}" --use >/dev/null
else
    docker buildx use "${BUILDER_NAME}" >/dev/null
fi

METADATA_FILE=$(mktemp)
trap 'rm -f "${METADATA_FILE}"' EXIT

docker buildx build \
    --platform "${PLATFORMS}" \
    -f "${SCRIPT_DIR}/Dockerfile.patroni" \
    -t "${REPO}:${TAG}" \
    -t "${REPO}:${TAG}-${GIT_SHA}" \
    -t "${REPO}:latest" \
    --metadata-file "${METADATA_FILE}" \
    --push \
    "${SCRIPT_DIR}"

DIGEST=$(python3 - "${METADATA_FILE}" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(d.get("containerimage.digest", ""))
PYEOF
)

if [[ "${DIGEST}" == sha256:* ]]; then
    config_db_set_many PATRONI_PG_IMAGE "${REPO}:${TAG}" PATRONI_PG_DIGEST "${DIGEST}"
    log_info "✅ Опубликован в Docker Hub: ${REPO}:${TAG}@${DIGEST} (control.sqlite3 обновлен)"
else
    log_info "✅ Опубликован в Docker Hub: ${REPO}:${TAG}"
fi
