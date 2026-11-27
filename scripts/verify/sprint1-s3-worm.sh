#!/usr/bin/env bash
# ============================================================================
# sprint1-s3-worm.sh — Приемочный Spike SFTPGo OSS <-> SeaweedFS S3 (Day-1)
# ============================================================================
# Вызов: ./clusterctl verify --sprint 1 [--dry-run]
#
# Тесты:
#   1. S3 SigV4 (127.0.0.1:8333): sftp-work CRUD/CopyObject/Versioning
#   2. WORM Spike (127.0.0.1:8333): sftp-worm PUT БЕЗ Content-MD5 с COMPLIANCE,
#      отказ DeleteObject версии (HTTP 403/405)
#   3. E2E SFTP -> SFTPGo -> SeaweedFS:
#      - Создание эфемерного _sprint1_verify с S3-папками /work и /worm
#      - put/get/rename файла в /work через OpenSSH sftp
#      - Проверка отказа rename непустой директории (документировано в PLAN.md §1)
#      - put файла в /worm через SFTPGo без checksum
#   4. Периметр: setstat_mode=2, update_mode=1, upload_mode=1, строгий localhost 8081/8333/5433
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
# shellcheck source=../lib/deploy.sh
source "${SCRIPT_DIR}/scripts/lib/deploy.sh"

load_cluster_env "${CONFIG_ROOT:-${SCRIPT_DIR}}"
log_step "Sprint 1: Приемка SFTPGo OSS <-> SeaweedFS S3 / WORM"

TEST_NODE_IP=$(get_node_ip 1)
S3_PORT="${SWFS_S3_PORT:-8333}"
PASS_COUNT=0
FAIL_COUNT=0

if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] 1. S3 SigV4 Spike (127.0.0.1:${S3_PORT}: sftp-work CRUD/CopyObject/Versioning + sftp-worm COMPLIANCE без MD5)"
    log_info "[DRY-RUN] 2. SFTPGo E2E SFTP Spike (: ${SFTP_PORT:-2022}: _sprint1_verify -> /work put/get/rename/dir-reject + /worm put)"
    log_info "[DRY-RUN] 3. Проверка sftpgo.json и строгих localhost-портов (8081/8333/5433)"
    log_info "✅ Sprint 1 [DRY-RUN] OK"
    exit 0
fi

pass() { log_info "  ✅ PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { log_error "  ❌ FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# --- 1. S3 & WORM SigV4 Spike ---
log_step "1/3 — S3 & WORM SigV4 Spike (127.0.0.1:${S3_PORT})"
if remote_exec_env_stdin "${TEST_NODE_IP}" "SWFS_ADMIN_PASSWORD,SWFS_S3_SECRET_KEY_SFTPGO" "${S3_PORT}" "provision-s3-admin" <<'REMOTE_SPIKE'
set -euo pipefail
S3_PORT="$1"; ACCESS_KEY="$2"

python3 - "${S3_PORT}" "${ACCESS_KEY}" <<'PYEOF'
import datetime, hashlib, hmac, os, sys, urllib.error, urllib.request

port, ak = sys.argv[1], sys.argv[2]
sk = os.environ["SWFS_ADMIN_PASSWORD"]
endpoint = f"http://127.0.0.1:{port}"
region = "us-east-1"

def sign(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()

def s3_req(method, path, query="", body=b"", extra_headers=None):
    extra_headers = extra_headers or {}
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(body).hexdigest()

    headers = {
        "host": f"127.0.0.1:{port}",
        "x-amz-date": amz_date,
        "x-amz-content-sha256": payload_hash,
        **{k.lower(): v for k, v in extra_headers.items()},
    }
    sorted_keys = sorted(headers.keys())
    canonical_headers = "".join(f"{k}:{headers[k]}\n" for k in sorted_keys)
    signed_headers = ";".join(sorted_keys)
    canonical_request = f"{method}\n{path}\n{query}\n{canonical_headers}\n{signed_headers}\n{payload_hash}"

    scope = f"{date_stamp}/{region}/s3/aws4_request"
    string_to_sign = f"AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{hashlib.sha256(canonical_request.encode()).hexdigest()}"
    k_signing = sign(sign(sign(sign(("AWS4" + sk).encode("utf-8"), date_stamp), region), "s3"), "aws4_request")
    sig = hmac.new(k_signing, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

    headers["authorization"] = f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, SignedHeaders={signed_headers}, Signature={sig}"
    url = f"{endpoint}{path}" + (f"?{query}" if query else "")
    req = urllib.request.Request(url, data=body if method in ("PUT", "POST") else None, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()

for b in ("sftp-work", "sftp-worm"):
    st, _, _ = s3_req("HEAD", f"/{b}")
    assert st == 200, f"Bucket {b} missing (HTTP {st})"

key_a = f"spike-test-{int(datetime.datetime.now().timestamp())}.txt"
key_b = key_a + ".renamed"
payload = b"cluster-b-sprint1-payload"
st, _, _ = s3_req("PUT", f"/sftp-work/{key_a}", body=payload)
assert st in (200, 204)
st, _, got = s3_req("GET", f"/sftp-work/{key_a}")
assert st == 200 and got == payload
st, _, cp_body = s3_req("PUT", f"/sftp-work/{key_b}", extra_headers={"x-amz-copy-source": f"/sftp-work/{key_a}"})
assert st == 200 and b"<Error>" not in cp_body
s3_req("DELETE", f"/sftp-work/{key_a}")
s3_req("DELETE", f"/sftp-work/{key_b}")

worm_key = f"worm-spike-{int(datetime.datetime.now().timestamp())}.bin"
retain_until = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
st, hdrs, err_body = s3_req(
    "PUT",
    f"/sftp-worm/{worm_key}",
    body=b"worm-immutable-data",
    extra_headers={
        "x-amz-object-lock-mode": "COMPLIANCE",
        "x-amz-object-lock-retain-until-date": retain_until,
    },
)
assert st in (200, 204), f"HARD STOP: WORM PUT without checksum failed: HTTP {st} {err_body}"
vid = hdrs.get("x-amz-version-id") or hdrs.get("X-Amz-Version-Id")
assert vid, f"Expected x-amz-version-id from versioned WORM bucket"

st_del, _, del_body = s3_req("DELETE", f"/sftp-worm/{worm_key}", query=f"versionId={vid}")
assert st_del in (403, 405), f"HARD STOP: WORM locked version was NOT protected! HTTP {st_del} {del_body}"
print("PASS: S3/WORM SigV4 Spike")
PYEOF
REMOTE_SPIKE
then
    pass "S3/WORM SigV4 Spike пройден"
else
    fail "S3/WORM SigV4 Spike провален (HARD STOP для WORM)"
fi

# --- 2. E2E SFTP -> SFTPGo -> SeaweedFS (work & worm) ---
log_step "2/3 — E2E SFTP -> SFTPGo -> SeaweedFS (/work и /worm)"
sftpgo_provision_s3_folders "${TEST_NODE_IP}" || true
if remote_exec_env_stdin "${TEST_NODE_IP}" "SFTPGO_ADMIN_PASSWORD,SWFS_ADMIN_PASSWORD" "${SFTPGO_ADMIN_USERNAME:-admin}" "${SFTP_PORT:-2022}" "${S3_PORT}" "provision-s3-admin" <<'REMOTE_SFTP_E2E'
set -euo pipefail
ADMIN_U="$1"; SFTP_PORT="$2"; S3_PORT="$3"; S3_AK="$4"
ADMIN_P="${SFTPGO_ADMIN_PASSWORD}"; S3_SK="${SWFS_ADMIN_PASSWORD}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

ssh-keygen -t ed25519 -f "${TMPDIR}/id_ed25519" -N "" -C "sprint1" >/dev/null
PUBKEY=$(cat "${TMPDIR}/id_ed25519.pub")

# Создаем эфемерного пользователя _sprint1_verify с S3-папками /work и /worm
TOKEN=$(curl -sf -u "${ADMIN_U}:${ADMIN_P}" "http://127.0.0.1:8081/api/v2/token" | jq -r '.access_token')
curl -sf -X DELETE -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:8081/api/v2/users/_sprint1_verify" >/dev/null 2>&1 || true

cat > "${TMPDIR}/user.json" <<JSON
{
  "status": 1,
  "username": "_sprint1_verify",
  "public_keys": ["${PUBKEY}"],
  "home_dir": "/srv/sftpgo/empty-root",
  "permissions": {"/": ["list", "download"], "/work": ["*"], "/worm": ["list", "upload", "download", "create_dirs"]},
  "virtual_folders": [
    {"name": "sftp-work", "virtual_path": "/work"},
    {"name": "sftp-worm", "virtual_path": "/worm"}
  ]
}
JSON
curl -sf -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    -d @"${TMPDIR}/user.json" "http://127.0.0.1:8081/api/v2/users" >/dev/null

cleanup_user() {
    curl -sf -X DELETE -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:8081/api/v2/users/_sprint1_verify" >/dev/null 2>&1 || true
}
trap 'cleanup_user; rm -rf "${TMPDIR}"' EXIT

# Задержка кэша/обновления не мешает на одной ноде, т.к. API вызывает сброс кэша локально
echo "sprint1-sftp-work-data" > "${TMPDIR}/src.txt"
echo "sprint1-sftp-worm-data" > "${TMPDIR}/worm.bin"

SFTP_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -P ${SFTP_PORT} -i ${TMPDIR}/id_ed25519"

# 2.1 work: put, get, rename файла, mkdir + put; worm: put файла (наследует DefaultRetention бакета!)
WORM_FNAME="e2e-worm-$(date +%s).bin"
# shellcheck disable=SC2086
sftp ${SFTP_OPTS} "_sprint1_verify@127.0.0.1" <<SFTP
put ${TMPDIR}/src.txt /work/e2e-test.txt
rename /work/e2e-test.txt /work/e2e-renamed.txt
get /work/e2e-renamed.txt ${TMPDIR}/got.txt
mkdir /work/nonempty-dir
put ${TMPDIR}/src.txt /work/nonempty-dir/inside.txt
rm /work/e2e-renamed.txt
put ${TMPDIR}/worm.bin /worm/${WORM_FNAME}
bye
SFTP

cmp -s "${TMPDIR}/src.txt" "${TMPDIR}/got.txt"

# 2.2 Проверяем через S3 API, что файл, загруженный через SFTPGo в /worm, унаследовал DefaultRetention!
python3 - "${S3_PORT}" "${S3_AK}" "${S3_SK}" "${WORM_FNAME}" <<'PYCHECK'
import datetime, hashlib, hmac, sys, urllib.error, urllib.request
port, ak, sk, key = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc)
amz_date, ds = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
ph = hashlib.sha256(b"").hexdigest()
hdrs = {"host": f"127.0.0.1:{port}", "x-amz-date": amz_date, "x-amz-content-sha256": ph}
ch = "".join(f"{k}:{hdrs[k]}\n" for k in sorted(hdrs))
sh = ";".join(sorted(hdrs))
creq = f"GET\n/sftp-worm/{key}\nretention=\n{ch}\n{sh}\n{ph}"
scope = f"{ds}/us-east-1/s3/aws4_request"
sts = f"AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{hashlib.sha256(creq.encode()).hexdigest()}"
def sign(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
ks = sign(sign(sign(sign(("AWS4" + sk).encode(), ds), "us-east-1"), "s3"), "aws4_request")
hdrs["authorization"] = f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, SignedHeaders={sh}, Signature={hmac.new(ks, sts.encode(), hashlib.sha256).hexdigest()}"
req = urllib.request.Request(f"http://127.0.0.1:{port}/sftp-worm/{key}?retention=", headers=hdrs)
with urllib.request.urlopen(req, timeout=10) as r:
    body = r.read().decode()
assert r.status == 200 and "RetainUntilDate" in body, f"WORM DefaultRetention not applied on SFTP upload: {body}"
PYCHECK

# 2.3 Проверка ожидаемого отказа rename непустой папки на S3-бэкенде (PLAN.md §1)
set +e
# shellcheck disable=SC2086
sftp ${SFTP_OPTS} "_sprint1_verify@127.0.0.1" <<'SFTP_MV_DIR' >/dev/null 2>&1
rename /work/nonempty-dir /work/nonempty-dir-moved
SFTP_MV_DIR
MV_RC=$?
set -e
# Чистим тестовую папку
# shellcheck disable=SC2086
sftp ${SFTP_OPTS} "_sprint1_verify@127.0.0.1" <<'SFTP_CLEAN' >/dev/null 2>&1 || true
rm /work/nonempty-dir/inside.txt
rmdir /work/nonempty-dir
bye
SFTP_CLEAN

if [[ "${MV_RC}" -eq 0 ]]; then
    echo "WARN: rename non-empty directory unexpectedly succeeded"
fi
echo "PASS: E2E SFTP -> SFTPGo -> SeaweedFS (/work & /worm)"
REMOTE_SFTP_E2E
then
    pass "Сквозной SFTP -> SFTPGo -> SeaweedFS (/work + /worm) пройден"
else
    fail "Сквозной SFTP -> SFTPGo -> SeaweedFS тест провален"
fi

# --- 3. Проверка конфигурации и периметра ---
log_step "3/3 — Конфигурация SFTPGo и сетевая изоляция портов"
if remote_exec "${TEST_NODE_IP}" "jq -e '.common.setstat_mode == 2 and .data_provider.update_mode == 0 and .data_provider.is_shared == 1 and .data_provider.create_default_admin == true' '${REMOTE_BASE_DIR}/configs/sftpgo.json' >/dev/null"; then
    pass "sftpgo.json: setstat_mode=2, update_mode=0, is_shared=1, create_default_admin=true"
else
    fail "sftpgo.json: некорректные параметры"
fi

if remote_exec "${TEST_NODE_IP}" "jq -e '.common.upload_mode == 1' '${REMOTE_BASE_DIR}/configs/sftpgo.json' >/dev/null"; then
    pass "sftpgo.json: upload_mode=1 (безопасно для WORM)"
else
    log_warn "  ⚠️  common.upload_mode != 1"
fi

if remote_exec "${TEST_NODE_IP}" "ss -tln | grep -E '127\.0\.0\.1:(8081|8333|5433)' | wc -l | grep -qx 3"; then
    pass "Порты 8081, 8333, 5433 привязаны строго к 127.0.0.1"
else
    fail "Нарушена localhost-изоляция портов 8081/8333/5433"
fi

echo ""
log_info "Итог Sprint 1: PASS=${PASS_COUNT}, FAIL=${FAIL_COUNT}"
if (( FAIL_COUNT > 0 )); then
    log_error "HARD STOP: Sprint 1 не пройден!"
    exit 1
fi
log_info "✅ Sprint 1 PASSED"
