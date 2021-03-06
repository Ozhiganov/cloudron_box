#!/bin/bash

set -eu -o pipefail

echo "==> Cloudron Start"

readonly USER="yellowtent"
readonly HOME_DIR="/home/${USER}"
readonly BOX_SRC_DIR="${HOME_DIR}/box"
readonly OLD_DATA_DIR="${HOME_DIR}/data";
readonly PLATFORM_DATA_DIR="${HOME_DIR}/platformdata" # platform data
readonly APPS_DATA_DIR="${HOME_DIR}/appsdata" # app data
readonly BOX_DATA_DIR="${HOME_DIR}/boxdata" # box data
readonly CONFIG_DIR="${HOME_DIR}/configs"
readonly SETUP_PROGRESS_JSON="${HOME_DIR}/setup/website/progress.json"

readonly curl="curl --fail --connect-timeout 20 --retry 10 --retry-delay 2 --max-time 2400"

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${script_dir}/argparser.sh" "$@" # this injects the arg_* variables used below

set_progress() {
    local percent="$1"
    local message="$2"

    echo "==> ${percent} - ${message}"
    (echo "{ \"update\": { \"percent\": \"${percent}\", \"message\": \"${message}\" }, \"backup\": {} }" > "${SETUP_PROGRESS_JSON}") 2> /dev/null || true # as this will fail in non-update mode
}

set_progress "20" "Configuring host"
sed -e 's/^#NTP=/NTP=0.ubuntu.pool.ntp.org 1.ubuntu.pool.ntp.org 2.ubuntu.pool.ntp.org 3.ubuntu.pool.ntp.org/' -i /etc/systemd/timesyncd.conf
timedatectl set-ntp 1
timedatectl set-timezone UTC
hostnamectl set-hostname "${arg_fqdn}"

echo "==> Configuring docker"
cp "${script_dir}/start/docker-cloudron-app.apparmor" /etc/apparmor.d/docker-cloudron-app
systemctl enable apparmor
systemctl restart apparmor

usermod ${USER} -a -G docker
# preserve the existing storage driver (user might be using overlay2)
storage_driver=$(docker info | grep "Storage Driver" | sed 's/.*: //')
[[ -n "${storage_driver}" ]] || storage_driver="devicemapper" # if the above command fails

temp_file=$(mktemp)
# create systemd drop-in. some apps do not work with aufs
echo -e "[Service]\nExecStart=\nExecStart=/usr/bin/dockerd -H fd:// --log-driver=journald --exec-opt native.cgroupdriver=cgroupfs --storage-driver=${storage_driver}" > "${temp_file}"

systemctl enable docker
# restart docker if options changed
if [[ ! -f /etc/systemd/system/docker.service.d/cloudron.conf ]] || ! diff -q /etc/systemd/system/docker.service.d/cloudron.conf "${temp_file}" >/dev/null; then
    mkdir -p /etc/systemd/system/docker.service.d
    mv "${temp_file}" /etc/systemd/system/docker.service.d/cloudron.conf
    systemctl daemon-reload
    systemctl restart docker
fi
docker network create --subnet=172.18.0.0/16 cloudron || true

# caas has ssh on port 202 and we disable password login
if [[ "${arg_provider}" == "caas" ]]; then
    # https://stackoverflow.com/questions/4348166/using-with-sed on why ? must be escaped
    sed -e 's/^#\?PermitRootLogin .*/PermitRootLogin without-password/g' \
        -e 's/^#\?PermitEmptyPasswords .*/PermitEmptyPasswords no/g' \
        -e 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/g' \
        -e 's/^#\?Port .*/Port 202/g' \
        -i /etc/ssh/sshd_config

    # required so we can connect to this machine since port 22 is blocked by iptables by now
    systemctl reload sshd
fi

mkdir -p "${BOX_DATA_DIR}"
mkdir -p "${APPS_DATA_DIR}"
mkdir -p "${PLATFORM_DATA_DIR}"

# keep these in sync with paths.js
echo "==> Ensuring directories"
if [[ ! -d "${PLATFORM_DATA_DIR}/mail" ]]; then
    if [[ -d "${OLD_DATA_DIR}/mail" ]]; then
        echo "==> Migrate old mail data"
        # Migrate mail data to new format
        docker stop mail || true # otherwise the move below might fail if mail container writes in the middle
        mkdir -p "${PLATFORM_DATA_DIR}/mail"
        # we can't move the whole folder as it is a btrfs subvolume mount
        mv -f "${OLD_DATA_DIR}/mail/"* "${PLATFORM_DATA_DIR}/mail/" # this used to be mail container's run directory
    else
        echo "==> Create new mail data dir"
        mkdir -p "${PLATFORM_DATA_DIR}/mail"
    fi
fi

mkdir -p "${PLATFORM_DATA_DIR}/graphite"
mkdir -p "${PLATFORM_DATA_DIR}/mail/dkim"
mkdir -p "${PLATFORM_DATA_DIR}/mysql"
mkdir -p "${PLATFORM_DATA_DIR}/postgresql"
mkdir -p "${PLATFORM_DATA_DIR}/mongodb"
mkdir -p "${PLATFORM_DATA_DIR}/snapshots"
mkdir -p "${PLATFORM_DATA_DIR}/addons/mail"
mkdir -p "${PLATFORM_DATA_DIR}/collectd/collectd.conf.d"
mkdir -p "${PLATFORM_DATA_DIR}/acme"

mkdir -p "${BOX_DATA_DIR}/appicons"
mkdir -p "${BOX_DATA_DIR}/certs"
mkdir -p "${BOX_DATA_DIR}/acme" # acme keys

# ensure backups folder exists and is writeable
mkdir -p /var/backups
chmod 777 /var/backups

echo "==> Check for old btrfs volumes"
if mountpoint -q "${OLD_DATA_DIR}"; then
    echo "==> Cleanup btrfs volumes"
    # First stop all container to be able to unmount
    docker ps -q | xargs docker stop
    umount "${OLD_DATA_DIR}"
    rm -rf "/root/user_data.img"
else
    echo "==> No btrfs volumes found";
fi

echo "==> Configuring journald"
sed -e "s/^#SystemMaxUse=.*$/SystemMaxUse=100M/" \
    -e "s/^#ForwardToSyslog=.*$/ForwardToSyslog=no/" \
    -i /etc/systemd/journald.conf

# When rotating logs, systemd kills journald too soon sometimes
# See https://github.com/systemd/systemd/issues/1353 (this is upstream default)
sed -e "s/^WatchdogSec=.*$/WatchdogSec=3min/" \
    -i /lib/systemd/system/systemd-journald.service

# Give user access to system logs
usermod -a -G systemd-journal ${USER}
mkdir -p /var/log/journal  # in some images, this directory is not created making system log to /run/systemd instead
chown root:systemd-journal /var/log/journal
systemctl daemon-reload
systemctl restart systemd-journald
setfacl -n -m u:${USER}:r /var/log/journal/*/system.journal

echo "==> Creating config directory"
rm -rf "${CONFIG_DIR}" && mkdir "${CONFIG_DIR}"

echo "==> Setting up unbound"
# DO uses Google nameservers by default. This causes RBL queries to fail (host 2.0.0.127.zen.spamhaus.org)
# We do not use dnsmasq because it is not a recursive resolver and defaults to the value in the interfaces file (which is Google DNS!)
# We listen on 0.0.0.0 because there is no way control ordering of docker (which creates the 172.18.0.0/16) and unbound
echo -e "server:\n\tinterface: 0.0.0.0\n\taccess-control: 127.0.0.1 allow\n\taccess-control: 172.18.0.1/16 allow\n\tcache-max-negative-ttl: 30\n\tcache-max-ttl: 300" > /etc/unbound/unbound.conf.d/cloudron-network.conf

echo "==> Adding systemd services"
cp -r "${script_dir}/start/systemd/." /etc/systemd/system/
systemctl daemon-reload
systemctl enable unbound
systemctl enable cloudron.target
systemctl enable cloudron-firewall

# update firewall rules
systemctl restart cloudron-firewall

# For logrotate
systemctl enable --now cron

# ensure unbound runs
systemctl restart unbound

echo "==> Configuring sudoers"
rm -f /etc/sudoers.d/${USER}
cp "${script_dir}/start/sudoers" /etc/sudoers.d/${USER}

echo "==> Configuring collectd"
rm -rf /etc/collectd
ln -sfF "${PLATFORM_DATA_DIR}/collectd" /etc/collectd
cp "${script_dir}/start/collectd.conf" "${PLATFORM_DATA_DIR}/collectd/collectd.conf"
systemctl restart collectd

echo "==> Configuring nginx"
# link nginx config to system config
unlink /etc/nginx 2>/dev/null || rm -rf /etc/nginx
ln -s "${PLATFORM_DATA_DIR}/nginx" /etc/nginx
mkdir -p "${PLATFORM_DATA_DIR}/nginx/applications"
mkdir -p "${PLATFORM_DATA_DIR}/nginx/cert"
cp "${script_dir}/start/nginx/nginx.conf" "${PLATFORM_DATA_DIR}/nginx/nginx.conf"
cp "${script_dir}/start/nginx/mime.types" "${PLATFORM_DATA_DIR}/nginx/mime.types"
if ! grep -q "^Restart=" /etc/systemd/system/multi-user.target.wants/nginx.service; then
    # default nginx service file does not restart on crash
    echo -e "\n[Service]\nRestart=always\n" >> /etc/systemd/system/multi-user.target.wants/nginx.service
    systemctl daemon-reload
fi
systemctl start nginx

# bookkeep the version as part of data
echo "{ \"version\": \"${arg_version}\", \"apiServerOrigin\": \"${arg_api_server_origin}\" }" > "${BOX_DATA_DIR}/version"

# restart mysql to make sure it has latest config
if [[ ! -f /etc/mysql/mysql.cnf ]] || ! diff -q "${script_dir}/start/mysql.cnf" /etc/mysql/mysql.cnf >/dev/null; then
    # wait for all running mysql jobs
    cp "${script_dir}/start/mysql.cnf" /etc/mysql/mysql.cnf
    while true; do
        if ! systemctl list-jobs | grep mysql; then break; fi
        echo "Waiting for mysql jobs..."
        sleep 1
    done
    systemctl restart mysql
else
    systemctl start mysql
fi

readonly mysql_root_password="password"
mysqladmin -u root -ppassword password password # reset default root password
mysql -u root -p${mysql_root_password} -e 'CREATE DATABASE IF NOT EXISTS box'

if [[ -n "${arg_restore_url}" ]]; then
    set_progress "30" "Downloading restore data"

    decrypt=""
    if [[ "${arg_restore_url}" == *.tar.gz.enc || -n "${arg_restore_key}" ]]; then
        echo "==> Downloading encrypted backup: ${arg_restore_url} and key: ${arg_restore_key}"
        decrypt=(openssl aes-256-cbc -d -nosalt -pass "pass:${arg_restore_key}")
    else
        echo "==> Downloading backup: ${arg_restore_url}"
        decrypt=(cat -)
    fi

    while true; do
        if $curl -L "${arg_restore_url}" | "${decrypt[@]}" \
        | tar -zxf - --overwrite --transform="s,^box/\?,boxdata/," --transform="s,^mail/\?,platformdata/mail/," --show-transformed-names -C "${HOME_DIR}"; then break; fi
        echo "Failed to download data, trying again"
    done

    set_progress "35" "Setting up MySQL"
    if [[ -f "${BOX_DATA_DIR}/box.mysqldump" ]]; then
        echo "==> Importing existing database into MySQL"
        mysql -u root -p${mysql_root_password} box < "${BOX_DATA_DIR}/box.mysqldump"
    fi
fi

set_progress "40" "Migrating data"
sudo -u "${USER}" -H bash <<EOF
set -eu
cd "${BOX_SRC_DIR}"
BOX_ENV=cloudron DATABASE_URL=mysql://root:${mysql_root_password}@localhost/box "${BOX_SRC_DIR}/node_modules/.bin/db-migrate" up
EOF

echo "==> Creating cloudron.conf"
cat > "${CONFIG_DIR}/cloudron.conf" <<CONF_END
{
    "version": "${arg_version}",
    "token": "${arg_token}",
    "apiServerOrigin": "${arg_api_server_origin}",
    "webServerOrigin": "${arg_web_server_origin}",
    "fqdn": "${arg_fqdn}",
    "zoneName": "${arg_zone_name}",
    "isCustomDomain": ${arg_is_custom_domain},
    "provider": "${arg_provider}",
    "isDemo": ${arg_is_demo},
    "database": {
        "hostname": "localhost",
        "username": "root",
        "password": "${mysql_root_password}",
        "port": 3306,
        "name": "box"
    },
    "appBundle": ${arg_app_bundle}
}
CONF_END
# pass these out-of-band because they have new lines which interfere with json
if [[ -n "${arg_tls_cert}" && -n "${arg_tls_key}" ]]; then
    echo "${arg_tls_cert}" > "${CONFIG_DIR}/host.cert"
    echo "${arg_tls_key}" > "${CONFIG_DIR}/host.key"
fi

echo "==> Creating config.json for webadmin"
cat > "${BOX_SRC_DIR}/webadmin/dist/config.json" <<CONF_END
{
    "webServerOrigin": "${arg_web_server_origin}"
}
CONF_END

echo "==> Changing ownership"
chown "${USER}:${USER}" -R "${CONFIG_DIR}"
chown "${USER}:${USER}" -R "${PLATFORM_DATA_DIR}/nginx" "${PLATFORM_DATA_DIR}/collectd" "${PLATFORM_DATA_DIR}/addons" "${PLATFORM_DATA_DIR}/acme"
chown "${USER}:${USER}" -R "${BOX_DATA_DIR}"
chown "${USER}:${USER}" -R "${PLATFORM_DATA_DIR}/mail/dkim" # this is owned by box currently since it generates the keys
chown "${USER}:${USER}" "${PLATFORM_DATA_DIR}/INFRA_VERSION" 2>/dev/null || true
chown "${USER}:${USER}" "${PLATFORM_DATA_DIR}"

echo "==> Adding automated configs"
if [[ ! -z "${arg_backup_config}" ]]; then
    mysql -u root -p${mysql_root_password} \
        -e "REPLACE INTO settings (name, value) VALUES (\"backup_config\", '$arg_backup_config')" box
fi

if [[ ! -z "${arg_dns_config}" ]]; then
    mysql -u root -p${mysql_root_password} \
        -e "REPLACE INTO settings (name, value) VALUES (\"dns_config\", '$arg_dns_config')" box
fi

if [[ ! -z "${arg_update_config}" ]]; then
    mysql -u root -p${mysql_root_password} \
        -e "REPLACE INTO settings (name, value) VALUES (\"update_config\", '$arg_update_config')" box
fi

if [[ ! -z "${arg_tls_config}" ]]; then
    mysql -u root -p${mysql_root_password} \
        -e "REPLACE INTO settings (name, value) VALUES (\"tls_config\", '$arg_tls_config')" box
fi

echo "==> Generating dhparams (takes forever)"
if [[ ! -f "${BOX_DATA_DIR}/dhparams.pem" ]]; then
    openssl dhparam -out "${BOX_DATA_DIR}/dhparams.pem" 2048
fi

set_progress "60" "Starting Cloudron"
systemctl start cloudron.target

sleep 2 # give systemd sometime to start the processes

set_progress "90" "Almost done"
