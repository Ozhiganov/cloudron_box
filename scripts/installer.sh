#!/bin/bash

set -eu -o pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "This script should be run as root." > /dev/stderr
    exit 1
fi

readonly USER=yellowtent
readonly BOX_SRC_DIR=/home/${USER}/box
readonly CLOUDRON_CONF=/home/yellowtent/configs/cloudron.conf

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly box_src_tmp_dir="$(realpath ${script_dir}/..)"
readonly json="${script_dir}/../../node_modules/.bin/json"
readonly curl="curl --fail --connect-timeout 20 --retry 10 --retry-delay 2 --max-time 300"

readonly is_update=$([[ -f "${CLOUDRON_CONF}" ]] && echo "yes" || echo "no")

# create a provision file for testing. %q escapes args. %q is reused as much as necessary to satisfy $@
(echo -e "#!/bin/bash\n"; printf "%q " "${script_dir}/installer.sh" "$@") > /root/provision.sh
chmod +x /root/provision.sh

arg_data=""
arg_data_file=""

args=$(getopt -o "" -l "data:,data-file:" -n "$0" -- "$@")
eval set -- "${args}"

while true; do
    case "$1" in
    --data) arg_data="$2";;
    --data-file) arg_data_file="$2";;
    --) break;;
    *) echo "Unknown option $1"; exit 1;;
    esac

    shift 2
done

if [[ ! -z ${arg_data_file} ]]; then
    arg_data=$(cat "${arg_data_file}")
fi

# ensure ownership baked into the tarball is overwritten
chown -R root.root "${box_src_tmp_dir}"

for try in `seq 1 10`; do
    # for reasons unknown, the dtrace package will fail. but rebuilding second time will work

    # We need --unsafe-perm as we run as root and the folder is owned by root,
    # however by default npm drops privileges for npm rebuild
    # https://docs.npmjs.com/misc/config#unsafe-perm
    if cd "${box_src_tmp_dir}" && npm rebuild --unsafe-perm; then break; fi
    echo "Failed to rebuild, trying again"
    sleep 5
done

if [[ ${try} -eq 10 ]]; then
    echo "npm rebuild failed"
    exit 4
fi

if ! id "${USER}" 2>/dev/null; then
    useradd "${USER}" -m
fi

if [[ "${is_update}" == "yes" ]]; then
    echo "Setting up update splash screen"
    "${box_src_tmp_dir}/setup/splashpage.sh" --data "${arg_data}" # show splash from new code
    ${BOX_SRC_DIR}/setup/stop.sh # stop the old code
fi

# ensure we are not inside the source directory, which we will remove now
cd /root

# switch the codes
rm -rf "${BOX_SRC_DIR}"
mv "${box_src_tmp_dir}" "${BOX_SRC_DIR}"
chown -R "${USER}:${USER}" "${BOX_SRC_DIR}"

# create a start file for testing. %q escapes args
(echo -e "#!/bin/bash\n"; printf "%q " "${BOX_SRC_DIR}/setup/start.sh" --data "${arg_data}") > /home/yellowtent/setup_start.sh
chmod +x /home/yellowtent/setup_start.sh

echo "Calling box setup script"
"${BOX_SRC_DIR}/setup/start.sh" --data "${arg_data}"