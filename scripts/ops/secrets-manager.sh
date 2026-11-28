#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/scripts/lib/common.sh"
case "${1:-status}" in
    init)
        [[ "${DRY_RUN:-false}" == true ]] || config_db init
        ;;
    encrypt)
        [[ "${DRY_RUN:-false}" == true ]] && exit 0
        config_db init
        plain="${CONFIG_ROOT:-${SCRIPT_DIR}}/.pki/ca/ca.key"
        if [[ -f "$plain" ]]; then
            key=$(resolve_age_key_file)
            recipient=$(age-keygen -y "$key")
            age -r "$recipient" -o "$plain.age.new" "$plain"
            age -d -i "$key" "$plain.age.new" | cmp -s - "$plain"
            mv "$plain.age.new" "$plain.age"
            secure_wipe_file "$plain"
        fi
        ;;
    status)
        config_db get PANEL_ADMIN_PASSWORD >/dev/null
        log_info "База управления открывается, секреты расшифрованы."
        ;;
    *) echo "ligactl secrets init|encrypt|status. Значение параметра передайте через stdin в ligactl config set КЛЮЧ." >&2; exit 2 ;;
esac
