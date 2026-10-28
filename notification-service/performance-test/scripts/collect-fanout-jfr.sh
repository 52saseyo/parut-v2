#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./performance-test/scripts/collect-fanout-jfr.sh start <scenario>
  ./performance-test/scripts/collect-fanout-jfr.sh stop <scenario> <output-file>

Optional environment variables:
  NOTIFICATION_CONTAINER  Container name, default notification-service
  JAVA_PID                JVM process id in the container, default 1
EOF
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage >&2
  exit 2
fi

action="$1"
scenario="$2"
output_file="${3:-}"
container="${NOTIFICATION_CONTAINER:-notification-service}"
java_pid="${JAVA_PID:-1}"
recording_name="fanout-${scenario}"
container_file="/tmp/${recording_name}.jfr"

case "${action}" in
  start)
    docker exec "${container}" \
      jcmd "${java_pid}" JFR.start \
      name="${recording_name}" settings=profile disk=true
    ;;
  stop)
    if [[ -z "${output_file}" ]]; then
      usage >&2
      exit 2
    fi

    mkdir -p "$(dirname "${output_file}")"
    docker exec "${container}" \
      jcmd "${java_pid}" JFR.stop \
      name="${recording_name}" filename="${container_file}"
    docker cp "${container}:${container_file}" "${output_file}"
    docker exec "${container}" rm -f "${container_file}"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
