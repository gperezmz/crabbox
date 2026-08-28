#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRABBOX_BIN="${CRABBOX_BIN:-$ROOT/bin/crabbox}"
server_type="${CRABBOX_IMAGE_TYPE:-}"
server_class="${CRABBOX_IMAGE_CLASS:-standard}"
image_name="${CRABBOX_IMAGE_NAME:-}"
log_dir="${CRABBOX_IMAGE_LOG_DIR:-.crabbox}"
ttl="${CRABBOX_IMAGE_TTL:-2h}"
idle_timeout="${CRABBOX_IMAGE_IDLE_TIMEOUT:-30m}"
wait_timeout="${CRABBOX_IMAGE_WAIT_TIMEOUT:-60m}"
run="${CRABBOX_IMAGE_RUN:-0}"
keep_lease="${CRABBOX_IMAGE_KEEP_LEASE:-0}"
desktop="${CRABBOX_IMAGE_DESKTOP:-auto}"
browser="${CRABBOX_IMAGE_BROWSER:-auto}"
prep_script="${CRABBOX_IMAGE_PREP_SCRIPT:-}"
promoted_proof="${CRABBOX_IMAGE_PROMOTED_PROOF:-}"

usage() {
  cat <<'USAGE'
Usage: scripts/mint-gcp-devtools-image.sh [flags]

Mint a GCP developer-tools disk snapshot for normal Crabbox leases. By default
this prints the plan and exits before paid work. Add --run to create the source
and candidate leases and the snapshot. The snapshot id is printed on the last
line as "snapshot=<id>".

Flags:
  --class CLASS         Crabbox machine class, default standard
  --type TYPE           GCP machine type
  --name NAME           snapshot name
  --run                 allow paid lease/snapshot work
  --promoted-proof ID   skip minting; warm one lease and prove it booted from ID
  --keep-lease          keep proof leases alive
  --desktop             request desktop bootstrap
  --no-desktop          do not request desktop bootstrap
  --no-browser          do not request browser bootstrap
  --prep-script PATH    override target prep script
  -h, --help            show this help

Useful env:
  CRABBOX_BIN
  CRABBOX_IMAGE_RUN
  CRABBOX_IMAGE_KEEP_LEASE
  CRABBOX_IMAGE_LOG_DIR
  CRABBOX_IMAGE_WAIT_TIMEOUT
  CRABBOX_IMAGE_PROMOTED_PROOF
USAGE
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --type)
      [[ "$#" -ge 2 ]] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
      server_type="$2"
      shift 2
      ;;
    --class)
      [[ "$#" -ge 2 ]] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
      server_class="$2"
      shift 2
      ;;
    --name)
      [[ "$#" -ge 2 ]] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
      image_name="$2"
      shift 2
      ;;
    --run)
      run=1
      shift
      ;;
    --promoted-proof)
      [[ "$#" -ge 2 ]] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
      promoted_proof="$2"
      shift 2
      ;;
    --keep-lease)
      keep_lease=1
      shift
      ;;
    --desktop)
      desktop=1
      shift
      ;;
    --no-desktop)
      desktop=0
      shift
      ;;
    --no-browser)
      browser=0
      shift
      ;;
    --prep-script)
      [[ "$#" -ge 2 ]] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
      prep_script="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

invocation_id="$(date -u +%Y%m%d-%H%M%S)-$$-${RANDOM}"
log_id="$(printf '%s' "$invocation_id" | tr -c 'A-Za-z0-9_.-' '_')"
if [[ -z "$image_name" ]]; then
  image_name="crabbox-linux-devtools-${log_id}"
fi
log_image_name="$(printf '%s' "$image_name" | tr -c 'A-Za-z0-9_.-' '_')"
if [[ -z "$prep_script" ]]; then
  prep_script="$ROOT/scripts/install-linux-developer-tools.sh"
fi
if [[ "$browser" == "auto" ]]; then
  browser=1
fi
if [[ "$desktop" == "auto" ]]; then
  desktop=1
fi

if [[ ! -x "$CRABBOX_BIN" ]]; then
  printf 'CRABBOX_BIN is not executable: %s\n' "$CRABBOX_BIN" >&2
  exit 2
fi
if [[ ! -f "$prep_script" ]]; then
  printf 'prep script not found: %s\n' "$prep_script" >&2
  exit 2
fi

source_lease=""
candidate_lease=""
promoted_lease=""

cleanup() {
  [[ "$keep_lease" == "1" ]] && return 0
  for lease in "$promoted_lease" "$candidate_lease" "$source_lease"; do
    [[ -n "$lease" ]] || continue
    "$CRABBOX_BIN" stop --provider gcp --target linux "$lease" || true
  done
}
trap cleanup EXIT

run_cmd() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

warmup_args() {
  printf '%s\0' warmup --provider gcp --target linux --class "$server_class" --market on-demand --ttl "$ttl" --idle-timeout "$idle_timeout" --timing-json
  [[ -n "$server_type" ]] && printf '%s\0' --type "$server_type"
  [[ "$desktop" == "1" ]] && printf '%s\0' --desktop
  [[ "$browser" == "1" ]] && printf '%s\0' --browser
}

lease_from_log() {
  node -e '
const fs = require("fs");
const text = fs.readFileSync(process.argv[1], "utf8");
for (const line of text.trim().split(/\n/).reverse()) {
  try {
    const json = JSON.parse(line);
    if (json.leaseId) {
      console.log(json.leaseId);
      process.exit(0);
    }
  } catch {}
}
process.exit(1);
' "$1"
}

assert_selected_image() {
  local log="$1"
  local image_id="$2"
  local source="$3"
  if ! grep -Fq "image selected id=$image_id source=$source" "$log"; then
    printf 'warmup did not prove image selection id=%s source=%s; log=%s\n' \
      "$image_id" "$source" "$log" >&2
    return 1
  fi
  printf '%s image selection proved: %s\n' "$source" "$image_id" >&2
}

warmup() {
  local label="$1"
  local log
  mkdir -p "$log_dir"
  log="$(mktemp "$log_dir/image-mint-${log_image_name}-${label}-${log_id}.log.XXXXXX")"
  local -a args
  while IFS= read -r -d '' arg; do args+=("$arg"); done < <(warmup_args)
  printf 'warming %s lease log=%s\n' "$label" "$log" >&2
  local warmup_status=0
  run_cmd "$CRABBOX_BIN" "${args[@]}" 2>&1 | tee "$log" >&2 || warmup_status=$?
  local lease
  lease="$(lease_from_log "$log" || true)"
  if [[ "$warmup_status" -ne 0 ]]; then
    if [[ -n "$lease" && "$keep_lease" != "1" ]]; then
      run_cmd "$CRABBOX_BIN" stop --provider gcp --target linux "$lease" >&2 || true
    fi
    return "$warmup_status"
  fi
  if [[ -z "$lease" ]]; then
    printf 'warmup did not return a lease id for %s\n' "$label" >&2
    return 1
  fi
  if [[ "$label" == "promoted" ]]; then
    if ! assert_selected_image "$log" "$snapshot_id" snapshot; then
      return 1
    fi
  fi
  printf '%s\n' "$lease"
}

smoke_script() {
  cat <<'SHELL'
set -euo pipefail
echo devtools-smoke-ok
uname -a
command -v git
command -v gh
command -v jq
command -v rg
command -v fd
command -v python3
command -v node
command -v npm
command -v corepack
command -v pnpm
command -v trufflehog
trufflehog --no-update --version
command -v docker
node --version
node -e 'if (Number(process.versions.node.split(".")[0]) < 24) throw new Error(`Node.js 24 or newer is required, found ${process.version}`)'
corepack --version
pnpm --version
docker_group_member() {
  if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    return 0
  fi
  local current_user docker_entry docker_members member
  current_user="$(whoami)"
  docker_entry="$(getent group docker 2>/dev/null || true)"
  [[ -n "$docker_entry" ]] || return 1
  docker_members="${docker_entry#*:*:*:}"
  local IFS=','
  local -a docker_member_list
  read -ra docker_member_list <<<"$docker_members"
  for member in "${docker_member_list[@]}"; do
    [[ "$member" == "$current_user" ]] && return 0
  done
  return 1
}
docker_probe='docker version && docker compose version && docker image inspect hello-world ubuntu:24.04 node:24-bookworm >/dev/null'
if ! sh -c "$docker_probe"; then
  if command -v sg >/dev/null 2>&1 && docker_group_member; then
    sg docker -c "$docker_probe"
  else
    sudo sh -c "$docker_probe"
  fi
fi
test -d /var/cache/crabbox/pnpm
test -f /var/lib/crabbox-readiness/linux.json
test -f /var/lib/crabbox/image-ready
SHELL
}

smoke() {
  local lease="$1"
  local script
  script="$(smoke_script)"
  run_cmd "$CRABBOX_BIN" run --provider gcp --target linux --id "$lease" --no-sync --shell -- "$script"
}

run_prep() {
  local lease="$1"
  run_cmd "$CRABBOX_BIN" run --provider gcp --target linux --id "$lease" --no-sync --script "$prep_script"
}

stage_linux_readiness_producer() {
  local lease="$1"
  run_cmd "$CRABBOX_BIN" run --provider gcp --target linux --id "$lease" --no-sync \
    --script "$ROOT/scripts/linux-readiness.generated.sh" -- --install
}

verify_linux_image_readiness() {
  local lease="$1"
  run_cmd "$CRABBOX_BIN" run --provider gcp --target linux --id "$lease" --no-sync \
    --shell -- /usr/local/libexec/crabbox/linux-readiness.generated.sh
}

if [[ -n "$promoted_proof" ]]; then
  snapshot_id="$promoted_proof"
  promoted_lease="$(warmup promoted)"
  smoke "$promoted_lease"
  printf 'promoted linux developer image passed: %s\n' "$snapshot_id"
  exit 0
fi

cat >&2 <<EOF
GCP devtools image mint
  target: linux
  image:  $image_name
  class:  $server_class
  type:   ${server_type:-auto}
  prep:   $prep_script
  proof:  desktop=$desktop browser=$browser
  paid:   run=$run keep_lease=$keep_lease
EOF

if [[ "$run" != "1" ]]; then
  printf 'dry plan only; add --run to create source/candidate leases and snapshots.\n'
  exit 0
fi

source_lease="$(warmup source)"
stage_linux_readiness_producer "$source_lease"
run_prep "$source_lease"
verify_linux_image_readiness "$source_lease"
smoke "$source_lease"

image_output="$("$CRABBOX_BIN" checkpoint create \
  --provider gcp --target linux --id "$source_lease" --name "$image_name" \
  --mode native --strategy disk-snapshot --wait --wait-timeout "$wait_timeout")"
printf '%s\n' "$image_output"
snapshot_id="$(printf '%s\n' "$image_output" | sed -nE 's/.* resource=([^[:space:]]+).*/\1/p' | tail -n 1)"
checkpoint_id="$(printf '%s\n' "$image_output" | sed -nE 's/.*checkpoint created id=([^[:space:]]+).*/\1/p' | tail -n 1)"
if [[ -z "$snapshot_id" || -z "$checkpoint_id" ]]; then
  printf 'checkpoint create did not return a snapshot id\n' >&2
  exit 1
fi

if [[ "$keep_lease" != "1" ]]; then
  run_cmd "$CRABBOX_BIN" stop --provider gcp --target linux "$source_lease"
  source_lease=""
fi

fork_output="$(run_cmd "$CRABBOX_BIN" checkpoint fork "$checkpoint_id" \
  --provider gcp --target linux --ttl 30m --idle-timeout 15m)"
printf '%s\n' "$fork_output"
candidate_lease="$(printf '%s\n' "$fork_output" | sed -nE 's/.* lease=([^[:space:]]+).*/\1/p' | tail -n 1)"
if [[ -z "$candidate_lease" ]]; then
  printf 'checkpoint fork did not return a lease id\n' >&2
  exit 1
fi
smoke "$candidate_lease"
printf 'candidate snapshot smoke passed: %s\n' "$snapshot_id"

printf 'snapshot=%s\n' "$snapshot_id"
