#!/bin/bash

# Centrally distribute, collect, or remove files for workstation student seats.
set -euo pipefail

usage() {
    cat <<EOF
Usage:
  $0 push   --host <host> [--host <host> ...] --source <local-path> --path <relative-path> [options]
  $0 pull   --host <host> [--host <host> ...] --path <relative-path> --destination <local-directory> [options]
  $0 remove --host <host> [--host <host> ...] --path <relative-path> --yes [options]

Options:
  --host <host>           Public DNS name or IP; repeat for multiple workstations
  --seats <number>        Override the detected number of student accounts
  --source <path>         Local file or directory to distribute (push only)
  --path <path>           Path relative to each student home, for example lab-01 or .aws
  --destination <path>    Local directory for collected evidence (pull only)
  --key <path>            SSH private key; defaults to the active SSH configuration
  --user <name>           SSH administrator account (default: ubuntu)
  --port <number>         SSH port (default: 22)
  --region <region>       AWS Region for Session Manager fallback (default: us-east-1)
  --transport <mode>      Connection mode: auto, ssh, or ssm (default: auto)
  --dry-run               Display planned actions without changing remote files
  --yes                   Required for remove
  -h, --help              Show this help message

The tool operates on /home/student1 through /home/studentN. It accepts exact
paths, including hidden directories such as .aws; do not use shell globs.
In auto mode, direct SSH is tried first. If it is unavailable, the tool finds
the running EC2 instance for --host and uses AWS Systems Manager over HTTPS.
EOF
}

if [ "$#" -eq 0 ]; then
    usage
    exit 1
fi

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    exit 0
fi

ACTION="$1"
shift

HOSTS=()
SEAT_COUNT=""
SOURCE_PATH=""
REMOTE_PATH=""
DESTINATION=""
SSH_KEY=""
SSH_USER="ubuntu"
SSH_PORT="22"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
TRANSPORT="auto"
DRY_RUN=false
CONFIRMED=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "ERROR: --host requires a value"; exit 1; }
            HOSTS+=("$2")
            shift 2
            ;;
        --seats)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "ERROR: --seats requires a value"; exit 1; }
            SEAT_COUNT="$2"
            shift 2
            ;;
        --source)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "ERROR: --source requires a path"; exit 1; }
            SOURCE_PATH="$2"
            shift 2
            ;;
        --path)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "ERROR: --path requires a relative path"; exit 1; }
            REMOTE_PATH="$2"
            shift 2
            ;;
        --destination)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "ERROR: --destination requires a path"; exit 1; }
            DESTINATION="$2"
            shift 2
            ;;
        --key)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "ERROR: --key requires a path"; exit 1; }
            SSH_KEY="$2"
            shift 2
            ;;
        --user)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "ERROR: --user requires a name"; exit 1; }
            SSH_USER="$2"
            shift 2
            ;;
        --port)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "ERROR: --port requires a number"; exit 1; }
            SSH_PORT="$2"
            shift 2
            ;;
        --region)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "ERROR: --region requires an AWS Region"; exit 1; }
            REGION="$2"
            shift 2
            ;;
        --transport)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "ERROR: --transport requires auto, ssh, or ssm"; exit 1; }
            TRANSPORT="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --yes)
            CONFIRMED=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

case "${ACTION}" in
    push|pull|remove) ;;
    *) echo "ERROR: Action must be push, pull, or remove"; usage; exit 1 ;;
esac

if [ "${#HOSTS[@]}" -eq 0 ]; then
    echo "ERROR: Provide at least one --host"
    exit 1
fi

if [ -n "${SEAT_COUNT}" ] && ! [[ "${SEAT_COUNT}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: --seats must be a positive whole number"
    exit 1
fi

if ! [[ "${SSH_PORT}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: --port must be a positive whole number"
    exit 1
fi

if ! [[ "${REGION}" =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "ERROR: --region contains unsupported characters"
    exit 1
fi

if [[ "${TRANSPORT}" != "auto" && "${TRANSPORT}" != "ssh" && "${TRANSPORT}" != "ssm" ]]; then
    echo "ERROR: --transport must be auto, ssh, or ssm"
    exit 1
fi

if ! [[ "${REMOTE_PATH}" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ "${REMOTE_PATH}" = /* ]]; then
    echo "ERROR: --path must be a safe path relative to each student home"
    exit 1
fi

IFS='/' read -r -a PATH_PARTS <<< "${REMOTE_PATH}"
for path_part in "${PATH_PARTS[@]}"; do
    if [ -z "${path_part}" ] || [ "${path_part}" = "." ] || [ "${path_part}" = ".." ]; then
        echo "ERROR: --path cannot contain empty, . , or .. path components"
        exit 1
    fi
done

if [ -n "${SSH_KEY}" ] && [ ! -f "${SSH_KEY}" ]; then
    echo "ERROR: SSH key not found: ${SSH_KEY}"
    exit 1
fi

for required_command in ssh rsync; do
    if ! command -v "${required_command}" >/dev/null 2>&1; then
        echo "ERROR: Required command is not installed: ${required_command}"
        exit 1
    fi
done

case "${ACTION}" in
    push)
        if [ -z "${SOURCE_PATH}" ] || [ ! -e "${SOURCE_PATH}" ]; then
            echo "ERROR: --source must name an existing local file or directory"
            exit 1
        fi
        ;;
    pull)
        if [ -z "${DESTINATION}" ]; then
            echo "ERROR: --destination is required for pull"
            exit 1
        fi
        ;;
    remove)
        if [ "${DRY_RUN}" = false ] && [ "${CONFIRMED}" = false ]; then
            echo "ERROR: remove requires --yes (or use --dry-run to preview)"
            exit 1
        fi
        ;;
esac

SSH_OPTIONS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -p "${SSH_PORT}")
if [ -n "${SSH_KEY}" ]; then
    SSH_OPTIONS+=(-i "${SSH_KEY}")
fi

resolve_instance_id() {
    local host="$1"
    local candidate
    local instance_id=""
    local candidates=("${host}")

    if [[ "${host}" =~ ^i-[a-zA-Z0-9]+$ ]]; then
        printf '%s\n' "${host}"
        return 0
    fi

    while read -r candidate; do
        [ -n "${candidate}" ] && candidates+=("${candidate}")
    done < <(getent ahostsv4 "${host}" 2>/dev/null | awk '{print $1}' | sort -u)

    for candidate in "${candidates[@]}"; do
        instance_id=$(aws ec2 describe-instances --region "${REGION}" \
            --filters "Name=ip-address,Values=${candidate}" "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)
        if [[ "${instance_id}" =~ ^i-[a-zA-Z0-9]+$ ]]; then
            printf '%s\n' "${instance_id}"
            return 0
        fi
    done

    return 1
}

configure_ssm_transport() {
    local host="$1"
    local instance_id

    for required_command in aws session-manager-plugin; do
        if ! command -v "${required_command}" >/dev/null 2>&1; then
            echo "ERROR: Session Manager fallback requires: ${required_command}"
            exit 1
        fi
    done

    instance_id=$(resolve_instance_id "${host}") || {
        echo "ERROR: Could not find a running EC2 instance for ${host} in ${REGION}."
        echo "Use --transport ssh for a non-EC2 host, or provide its public IP or instance ID."
        exit 1
    }
    HOST_SSH_OPTIONS+=( -o "ProxyCommand=aws ssm start-session --region ${REGION} --target ${instance_id} --document-name AWS-StartSSHSession --parameters portNumber=${SSH_PORT}" )
    echo "Using Session Manager for ${host} (${instance_id})"
}

configure_transport() {
    local host="$1"
    HOST_SSH_OPTIONS=("${SSH_OPTIONS[@]}")

    case "${TRANSPORT}" in
        ssh)
            echo "Using direct SSH for ${host}"
            ;;
        ssm)
            configure_ssm_transport "${host}"
            ;;
        auto)
            if ssh "${HOST_SSH_OPTIONS[@]}" "${SSH_USER}@${host}" true >/dev/null 2>&1; then
                echo "Using direct SSH for ${host}"
            else
                echo "Direct SSH unavailable for ${host}; falling back to Session Manager"
                configure_ssm_transport "${host}"
            fi
            ;;
    esac
}

rsync_ssh_command() {
    local argument
    local option
    local index

    printf '%s' ssh
    for ((index = 0; index < ${#HOST_SSH_OPTIONS[@]}; index++)); do
        argument="${HOST_SSH_OPTIONS[${index}]}"
        if [ "${argument}" = "-o" ]; then
            ((index++))
            option="${HOST_SSH_OPTIONS[${index}]}"
            # rsync parses -e itself rather than through a shell. Keep the
            # space-containing ProxyCommand together as one SSH option.
            if [[ "${option}" == ProxyCommand=* ]]; then
                printf ' -o "%s"' "${option}"
            else
                printf ' -o %q' "${option}"
            fi
            continue
        fi
        # rsync parses -e itself rather than through a shell. Keep the
        # space-containing ProxyCommand together as one SSH option.
        printf ' %q' "${argument}"
    done
}

for host in "${HOSTS[@]}"; do
    configure_transport "${host}"
    host_label=$(printf '%s' "${host}" | tr -c 'A-Za-z0-9._-' '_')
    host_seat_count="${SEAT_COUNT}"
    if [ -z "${host_seat_count}" ]; then
        seat_config=$(ssh "${HOST_SSH_OPTIONS[@]}" "${SSH_USER}@${host}" \
            "sudo cat /etc/workstation-seats" 2>/dev/null || true)
        host_seat_count=$(printf '%s\n' "${seat_config}" | awk -F= '/^SEAT_COUNT=/{print $2; exit}')
    fi

    if ! [[ "${host_seat_count}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: Could not detect seats for ${host}."
        echo "Use --seats <number> for workstations created before seat detection."
        exit 1
    fi

    for seat_number in $(seq 1 "${host_seat_count}"); do
        student="student${seat_number}"
        remote_target="/home/${student}/${REMOTE_PATH}"
        remote_host="${SSH_USER}@${host}"

        case "${ACTION}" in
            push)
                if [ "${DRY_RUN}" = true ]; then
                    echo "Would copy ${SOURCE_PATH} to ${remote_host}:${remote_target}"
                else
                    ssh "${HOST_SSH_OPTIONS[@]}" "${remote_host}" \
                        "sudo install -d -m 700 -o ${student} -g ${student} -- ${remote_target}"
                    if [ -d "${SOURCE_PATH}" ]; then
                        rsync -a -e "$(rsync_ssh_command)" --chown="${student}:${student}" --rsync-path="sudo rsync" \
                            "${SOURCE_PATH%/}/" "${remote_host}:${remote_target}/"
                    else
                        rsync -a -e "$(rsync_ssh_command)" --chown="${student}:${student}" --rsync-path="sudo rsync" \
                            "${SOURCE_PATH}" "${remote_host}:${remote_target}/"
                    fi
                fi
                ;;
            pull)
                local_target="${DESTINATION%/}/${host_label}/${student}"
                if [ "${DRY_RUN}" = true ]; then
                    echo "Would collect ${remote_host}:${remote_target} into ${local_target}"
                else
                    mkdir -p "${local_target}"
                    rsync -a -e "$(rsync_ssh_command)" --rsync-path="sudo rsync" \
                        "${remote_host}:${remote_target}" "${local_target}/"
                fi
                ;;
            remove)
                if [ "${DRY_RUN}" = true ]; then
                    echo "Would remove ${remote_host}:${remote_target}"
                else
                    ssh "${HOST_SSH_OPTIONS[@]}" "${remote_host}" \
                        "sudo rm -rf -- ${remote_target}"
                fi
                ;;
        esac
    done
done
