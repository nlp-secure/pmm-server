#!/bin/bash

set -o errexit

# Add logging
if [ -n "${ENABLE_DEBUG}" ]; then
    set -o xtrace
    exec > >(tee -a /var/log/$(basename $0).log) 2>&1
fi

# Perms fix for k8s
if [[ \
    "$(id -u pmm)" != "$(stat -c %u /opt/consul-data)" || \
    "$(id -u pmm)" != "$(stat -c %u /opt/prometheus/data)" || \
    "$(id -u mysql)" != "$(stat -c %u /var/lib/mysql)" || \
    "$(id -u grafana)" != "$(stat -c %u /var/lib/grafana)" \
]]; then
    chown -R pmm:pmm /opt/consul-data
    chown -R pmm:pmm /opt/prometheus/data
    chown -R mysql:mysql /var/lib/mysql
    chown -R grafana:grafana /var/lib/grafana
fi

if [ ! -f /var/lib/mysql/mysql ]; then
    cp -a /opt/consul-data.orig/{.[!.],}* /opt/consul-data/ || true
    cp -a /opt/prometheus/data.orig/{.[!.],}* /opt/prometheus/data/ || true
    cp -a /var/lib/mysql.orig/{.[!.],}* /var/lib/mysql/ || true
    cp -a /var/lib/grafana.orig/{.[!.],}* /var/lib/grafana/ || true
fi

# Prometheus
if [[ ! "${METRICS_RESOLUTION:-1s}" =~ ^[1-5]s$ ]]; then
    echo "METRICS_RESOLUTION takes only values from 1s to 5s."
    exit 1
fi
sed -i "s/1s/${METRICS_RESOLUTION:-1s}/" /etc/prometheus.yml
sed -i "s/ENV_METRICS_RETENTION/${METRICS_RETENTION:-720h}/" /etc/supervisord.d/pmm.ini
sed -i "s/ENV_MAX_CONNECTIONS/${MAX_CONNECTIONS:-15}/" /etc/supervisord.d/pmm.ini

if [ -n "$METRICS_MEMORY" ]; then
    # Preserve compatibility with existing METRICS_MEMORY variable.
    # https://jira.percona.com/browse/PMM-969
    METRICS_MEMORY_MULTIPLIED=$(( ${METRICS_MEMORY} * 1024 ))
else
    MEMORY_LIMIT=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes || :)
    TOTAL_MEMORY=$(( $(grep MemTotal /proc/meminfo | awk '{print$2}') * 1024 ))
    MEMORY_AVAIABLE=$(printf "%i\n%i\n" "$MEMORY_LIMIT" "$TOTAL_MEMORY" | sort -n | grep -v "^0$" | head -1)
    METRICS_MEMORY_MULTIPLIED=$(( (${MEMORY_AVAIABLE} - 256*1024*1024) / 100 * 15 ))
    if [[ $METRICS_MEMORY_MULTIPLIED -lt $((128*1024*1024)) ]]; then
        METRICS_MEMORY_MULTIPLIED=$((128*1024*1024))
    fi
fi
sed -i "s/ENV_METRICS_MEMORY_MULTIPLIED/${METRICS_MEMORY_MULTIPLIED}/" /etc/supervisord.d/pmm.ini

# Orchestrator
if [[ "${ORCHESTRATOR_ENABLED}" = "true" ]]; then
    sed -i "s/orc_client_user/${ORCHESTRATOR_USER:-orc_client_user}/" /etc/orchestrator.conf.json
    sed -i "s/orc_client_password/${ORCHESTRATOR_PASSWORD:-orc_client_password}/" /etc/orchestrator.conf.json
    sed -i "s/autostart = false/autostart = true/" /etc/supervisord.d/pmm.ini
fi

# Cron
sed -i "s/^INTERVAL=.*/INTERVAL=${QUERIES_RETENTION:-8}/" /etc/cron.daily/purge-qan-data

# HTTP basic auth
if [ -n "${SERVER_PASSWORD}" -a -z "${UPDATE_MODE}" ]; then
	SERVER_USER=${SERVER_USER:-pmm}
	cat > /srv/update/pmm-manage.yml <<-EOF
		users:
		- username: "${SERVER_USER//\"/\"}"
		  password: "${SERVER_PASSWORD//\"/\"}"
	EOF
	pmm-configure -skip-prometheus-reload true -grafana-db-path /var/lib/grafana/grafana.db || :
fi

# Hide update button
if [[ $DISABLE_UPDATES =~ ^(1|t|T|TRUE|true|True)$ ]] && [[ -f /usr/share/pmm-server/landing-page/index.html ]]; then
    sed -i "s/fa-refresh/fa-refresh hidden/" /usr/share/pmm-server/landing-page/index.html
fi

# Upgrade
if [ -f /var/lib/grafana/grafana.db ]; then
    chown -R pmm:pmm /opt/consul-data
    chown -R pmm:pmm /opt/prometheus/data
    chown -R mysql:mysql /var/lib/mysql
    chown -R grafana:grafana /var/lib/grafana
fi

# copy SSL, follow links
pushd /etc/nginx >/dev/null
    if [ -s ssl/server.crt ]; then
        cat ssl/server.crt  > /srv/nginx/certificate.crt
    fi
    if [ -s ssl/server.key ]; then
        cat ssl/server.key  > /srv/nginx/certificate.key
    fi
    if [ -s ssl/dhparam.pem ]; then
        cat ssl/dhparam.pem > /srv/nginx/dhparam.pem
    fi
popd >/dev/null

# Start supervisor in foreground
if [ -z "${UPDATE_MODE}" ]; then
    exec supervisord -n -c /etc/supervisord.conf
fi
