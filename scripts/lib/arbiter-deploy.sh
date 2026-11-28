#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
deploy_arbiter() {
        [[ -n "${ARBITER_IP:-}" ]] || return 0
        local edge_host file
        edge_host=$(resolve_current_active_ip || get_node_ip 1)
        local count
        count=$(get_node_count)
        local t_ne="" t_etcd="" t_pat="" t_swm="" t_swv="" t_swf="" t_sftp=""
        for i in $(seq 1 "${count}"); do
            local nip nname
            nip=$(get_node_ip "$i")
            nname=$(get_node_name "$i")
            [[ -n "${t_ne}" ]] && t_ne+=", " && t_pat+=", " && t_swv+=", " && t_swf+=", " && t_sftp+=", "
            t_ne+="\"${nip}:9100\""
            t_pat+="\"${nip}:${PATRONI_API_PORT:-8008}\""
            t_swv+="\"${nip}:${SWFS_VOLUME_METRICS_PORT:-9325}\""
            t_swf+="\"${nip}:${SWFS_FILER_METRICS_PORT:-9326}\""
            t_sftp+="\"${nip}:${SFTPGO_TELEMETRY_PORT:-10000}\""
            if is_quorum_node "$i" "${nname}"; then
                [[ -n "${t_swm}" ]] && t_swm+=", " && t_etcd+=", "
                t_swm+="\"${nip}:${SWFS_MASTER_METRICS_PORT:-9324}\""
                t_etcd+="\"${nip}:${ETCD_METRICS_PORT:-2381}\""
            fi
        done
        export PROM_TARGETS_NODE_EXPORTER="${t_ne}"
        export PROM_TARGETS_ETCD="${t_etcd}"
        export PROM_TARGETS_PATRONI="${t_pat}"
        export PROM_TARGETS_SWFS_MASTER="${t_swm}"
        export PROM_TARGETS_SWFS_VOLUME="${t_swv}"
        export PROM_TARGETS_SWFS_FILER="${t_swf}"
        export PROM_TARGETS_SFTPGO="${t_sftp}"
        export HTTPS_PORT="${HTTPS_PORT:-443}"
        export PROMETHEUS_IMAGE_REF ALERTMANAGER_IMAGE_REF BLACKBOX_IMAGE_REF
        PROMETHEUS_IMAGE_REF=$(resolve_image_ref "${PROMETHEUS_IMAGE}" "${PROMETHEUS_DIGEST:-}")
        ALERTMANAGER_IMAGE_REF=$(resolve_image_ref "${ALERTMANAGER_IMAGE}" "${ALERTMANAGER_DIGEST:-}")
        BLACKBOX_IMAGE_REF=$(resolve_image_ref "${BLACKBOX_EXPORTER_IMAGE}" "${BLACKBOX_EXPORTER_DIGEST:-}")
        export ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-http://127.0.0.1:9099/alerts}"

        local arb_out
        arb_out="$(state_root)/.rendered/arbiter"
        mkdir -p "${arb_out}"
        render_template "${SCRIPT_DIR}/configs/prometheus/prometheus.yml.tpl" "${arb_out}/prometheus.yml"
        render_template "${SCRIPT_DIR}/configs/prometheus/alertmanager.yml.tpl" "${arb_out}/alertmanager.yml"
        render_template "${SCRIPT_DIR}/configs/prometheus/arbiter-compose.yml.tpl" "${arb_out}/docker-compose.yml"

        local arb_pubkey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDryRunPlaceholderKey"
        if [[ "${DRY_RUN:-false}" != "true" ]]; then
            arb_pubkey=$(remote_exec_stdin "${ARBITER_IP}" "${ARBITER_BASE_DIR}" <<'REMOTE_ARB_KEY'
set -euo pipefail
ARB_DIR="$1"
mkdir -p "${ARB_DIR}/.ssh" && chmod 700 "${ARB_DIR}/.ssh"
if [[ ! -f "${ARB_DIR}/.ssh/id_ed25519" ]]; then
    ssh-keygen -t ed25519 -f "${ARB_DIR}/.ssh/id_ed25519" -N "" -C "arbiter" >/dev/null
fi
chmod 600 "${ARB_DIR}/.ssh/id_ed25519"
awk '{print $1 " " $2}' "${ARB_DIR}/.ssh/id_ed25519.pub"
REMOTE_ARB_KEY
            )
        fi
        if [[ "${DRY_RUN:-false}" != "true" ]]; then
            remote_exec "${edge_host}" "mkdir -p '${REMOTE_BASE_DIR}/scripts/ops'"
            remote_copy "${SCRIPT_DIR}/scripts/ops/edge_probe.py" "${edge_host}:${REMOTE_BASE_DIR}/scripts/ops/edge_probe.py"
            local opts known_hosts
            opts=$(_ssh_base_opts)
            known_hosts="${arb_out}/edge_known_hosts"
            awk '{print "vault-edge " $1 " " $2}' "$(state_root)/ssh-host-keys/id_ed25519.pub" > "${known_hosts}"
            remote_copy "${known_hosts}" "${ARBITER_IP}:${ARBITER_BASE_DIR}/.ssh/edge_known_hosts"
            # Stream the dedicated read-only credentials through SSH stdin. No password in argv.
            # shellcheck disable=SC2086
            python3 "${SCRIPT_DIR}/scripts/ops/edge_probe.py" credentials "$(state_root)" "${arb_pubkey}" | \
                ssh ${opts} -p "${ADMIN_SSH_PORT:-22}" "root@${edge_host}" "python3 '${REMOTE_BASE_DIR}/scripts/ops/edge_probe.py' configure"
        fi
        install_helper_cb() { install_arbiter_helper_on_node "$1" "${arb_pubkey}"; }
        for_each_node install_helper_cb

        remote_exec "${ARBITER_IP}" "mkdir -p '${ARBITER_BASE_DIR}/scripts/lib' '${ARBITER_BASE_DIR}/scripts/ops' '${ARBITER_BASE_DIR}/prometheus'"
        remote_copy "${arb_out}/docker-compose.yml" "${ARBITER_IP}:${ARBITER_BASE_DIR}/docker-compose.yml"
        remote_copy "${arb_out}/prometheus.yml" "${ARBITER_IP}:${ARBITER_BASE_DIR}/prometheus/prometheus.yml"
        remote_copy "${arb_out}/alertmanager.yml" "${ARBITER_IP}:${ARBITER_BASE_DIR}/prometheus/alertmanager.yml"
        remote_copy "${SCRIPT_DIR}/configs/prometheus/blackbox.yml" "${ARBITER_IP}:${ARBITER_BASE_DIR}/prometheus/blackbox.yml"
        remote_copy "${SCRIPT_DIR}/configs/prometheus/alerts.yml" "${ARBITER_IP}:${ARBITER_BASE_DIR}/prometheus/alerts.yml"
        sync_arbiter_edge_trust
        remote_copy "$(state_root)/.pki/ca/ca.crt" "${ARBITER_IP}:${ARBITER_BASE_DIR}/prometheus/ca.crt"
        remote_exec "${ARBITER_IP}" "mkdir -p '${ARBITER_BASE_DIR}/configs'; command -v age >/dev/null && command -v curl >/dev/null && command -v sftp >/dev/null || (apt-get update -qq && apt-get install -y -qq age curl openssh-client)"
        remote_copy "${SCRIPT_DIR}/configs/control-defaults.json" "${ARBITER_IP}:${ARBITER_BASE_DIR}/configs/control-defaults.json"
        for file in lib/config_db.py lib/node_address.py ops/edge_probe.py ops/arbiter_state.py; do
            remote_copy "${SCRIPT_DIR}/scripts/${file}" "${ARBITER_IP}:${ARBITER_BASE_DIR}/scripts/${file}"
        done
        if [[ "${DRY_RUN:-false}" != true ]]; then
            local arb_opts hook
            for hook in "${DNS_UPDATE_HOOK:-}" "${FLOATING_IP_HOOK:-}"; do
                if [[ -n "$hook" ]]; then
                    remote_exec "${ARBITER_IP}" "test -x $(_shell_quote_posix "$hook")" || { log_error "На арбитре отсутствует исполняемый hook $hook"; return 1; }
                fi
            done
            arb_opts=$(_ssh_base_opts)
            config_db arbiter-export | ssh ${arb_opts} -p "${ADMIN_SSH_PORT:-22}" "root@${ARBITER_IP}" \
                "python3 '${ARBITER_BASE_DIR}/scripts/lib/config_db.py' --root '${ARBITER_BASE_DIR}' arbiter-import"
        fi
        remote_copy "${SCRIPT_DIR}/scripts/lib/common.sh" "${ARBITER_IP}:${ARBITER_BASE_DIR}/scripts/lib/common.sh"
        remote_copy "${SCRIPT_DIR}/scripts/lib/deploy.sh" "${ARBITER_IP}:${ARBITER_BASE_DIR}/scripts/lib/deploy.sh"
        remote_copy "${SCRIPT_DIR}/scripts/ops/dns-failover-arbiter.sh" "${ARBITER_IP}:${ARBITER_BASE_DIR}/scripts/ops/dns-failover-arbiter.sh"

        ensure_remote_image "${ARBITER_IP}" "${PROMETHEUS_IMAGE_REF}"
        ensure_remote_image "${ARBITER_IP}" "${ALERTMANAGER_IMAGE_REF}"
        ensure_remote_image "${ARBITER_IP}" "${BLACKBOX_IMAGE_REF}"

        remote_exec_stdin "${ARBITER_IP}" "${ARBITER_BASE_DIR}" "${CLUSTER_SLUG}" <<'REMOTE_ARB'
set -euo pipefail
ARB_DIR="$1"; SLUG="$2"
chmod 600 "${ARB_DIR}/control.sqlite3"
chmod +x "${ARB_DIR}/scripts/ops/dns-failover-arbiter.sh"

cd "${ARB_DIR}" && docker compose up -d

cat > "/etc/systemd/system/${SLUG}-arbiter.service" <<UNIT
[Unit]
Description=Ligament Vault (${SLUG}) External Failover & 5-Gate Arbiter
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${ARB_DIR}
ExecStart=${ARB_DIR}/scripts/ops/dns-failover-arbiter.sh --daemon
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "${SLUG}-arbiter.service"
systemctl restart "${SLUG}-arbiter.service"
REMOTE_ARB
    }
