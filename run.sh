#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

readonly NETWORK=marvelx
readonly GITLAB=marvelx-gitlab
readonly RUNNER=marvelx-runner
readonly CLUSTER=marvelx
readonly GITLAB_IMAGE=gitlab/gitlab-ce:19.5.3-ce.0
readonly RUNNER_IMAGE=gitlab/gitlab-runner:v19.5.3
readonly TOOLS_IMAGE=marvelx/ci-tools:local
readonly GITLAB_URL=http://127.0.0.1:8080
readonly PROJECT=root/marvelx
readonly LOCAL=.local

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: ./run.sh <command>

  doctor        check that the required tools are installed and Docker is running
  up            start GitLab and the runner, push this repo, run the pipeline
  status        show containers, the latest pipeline and the cluster
  down          remove the containers and the cluster, keep GitLab's data
  down --purge  also remove GitLab's data, the CI image and local credentials
USAGE
}

# ---------- doctor ----------

tool_version() {
  case "$1" in
    kubectl) kubectl version --client 2>/dev/null | head -1 ;;
    openssl) openssl version ;;
    *)       "$1" --version 2>/dev/null | head -1 ;;
  esac
}

doctor() {
  local missing=0 tool
  log "Checking tools"
  for tool in docker git curl jq openssl kubectl; do
    if command -v "$tool" > /dev/null; then
      printf '  %-8s %s\n' "$tool" "$(tool_version "$tool")"
    else
      printf '  %-8s missing\n' "$tool"
      missing=1
    fi
  done
  (( missing == 0 )) || die "install the missing tools, see README.md"

  docker info > /dev/null 2>&1 || die "Docker isn't running"
  local memory
  memory=$(docker info --format '{{.MemTotal}}')
  (( memory >= 6 * 1024 ** 3 )) || warn "Docker has $(( memory / 1024 ** 3 )) GiB of memory; GitLab needs at least 6"
  log "Ready"
}

# ---------- GitLab ----------

api() {
  local path=$1; shift
  curl -fsS -H @"$LOCAL/auth-header" "$GITLAB_URL/api/v4/$path" "$@"
}

start_gitlab() {
  docker network inspect "$NETWORK" > /dev/null 2>&1 || docker network create "$NETWORK" > /dev/null

  if docker container inspect "$GITLAB" > /dev/null 2>&1; then
    docker start "$GITLAB" > /dev/null
  else
    log "Starting GitLab (first boot takes 5 to 10 minutes)"
    docker run -d --name "$GITLAB" --hostname gitlab \
      --network "$NETWORK" --network-alias gitlab \
      --publish 127.0.0.1:8080:80 --shm-size 256m --restart unless-stopped \
      --env GITLAB_OMNIBUS_CONFIG="external_url 'http://localhost:8080'; nginx['listen_port'] = 80; prometheus_monitoring['enable'] = false; gitlab_rails['usage_ping_enabled'] = false" \
      --volume marvelx-gitlab-config:/etc/gitlab \
      --volume marvelx-gitlab-logs:/var/log/gitlab \
      --volume marvelx-gitlab-data:/var/opt/gitlab \
      "$GITLAB_IMAGE" > /dev/null
  fi

  log "Waiting for GitLab to be ready"
  local deadline=$(( SECONDS + 900 ))
  until docker exec "$GITLAB" curl -fsS http://localhost/-/readiness 2> /dev/null | jq -e '.status == "ok"' > /dev/null; do
    (( SECONDS < deadline )) || die "GitLab wasn't ready after 15 minutes; check: docker logs $GITLAB"
    sleep 10
  done
}

ensure_token() {
  if [[ -s "$LOCAL/auth-header" ]] && api user > /dev/null 2>&1; then
    return
  fi

  log "Creating an API token for root"
  local token password=""
  token="glpat-$(openssl rand -hex 20)"
  if [[ ! -s "$LOCAL/root-password" ]]; then
    password=$(openssl rand -base64 24 | tr -d '/+=')
  fi

  docker exec --env TOKEN="$token" --env PASSWORD="$password" "$GITLAB" gitlab-rails runner '
    user = User.find_by_username("root")
    unless ENV["PASSWORD"].empty?
      user.password = ENV["PASSWORD"]
      user.password_confirmation = ENV["PASSWORD"]
      user.password_automatically_set = false
      user.save!
    end
    token = user.personal_access_tokens.create(name: "run.sh", scopes: ["api", "create_runner"], expires_at: 7.days.from_now)
    token.set_token(ENV["TOKEN"])
    token.save!
  '

  printf 'PRIVATE-TOKEN: %s\n' "$token" > "$LOCAL/auth-header"
  [[ -z "$password" ]] || printf '%s\n' "$password" > "$LOCAL/root-password"
}

ensure_project() {
  if ! api "projects/${PROJECT//\//%2F}" > /dev/null 2>&1; then
    log "Creating project $PROJECT"
    api projects --data name=marvelx --data visibility=private > /dev/null
  fi
  PROJECT_ID=$(api "projects/${PROJECT//\//%2F}" | jq -r .id)
}

ensure_variable() {
  local key=$1
  if api "projects/$PROJECT_ID/variables/$key" > /dev/null 2>&1; then
    return
  fi
  log "Generating CI variable $key"
  openssl rand -hex 32 | tr -d '\n' | api "projects/$PROJECT_ID/variables" \
    --data key="$key" --data-urlencode value@- \
    --data masked=true --data masked_and_hidden=true --data protected=true > /dev/null
}

ensure_runner() {
  if ! docker container inspect "$RUNNER" > /dev/null 2>&1; then
    log "Starting the runner"
    docker run -d --name "$RUNNER" --network "$NETWORK" --restart unless-stopped \
      --volume marvelx-runner-config:/etc/gitlab-runner \
      --volume /var/run/docker.sock:/var/run/docker.sock \
      "$RUNNER_IMAGE" > /dev/null
  fi
  docker start "$RUNNER" > /dev/null

  if docker exec "$RUNNER" grep -q '^\[\[runners\]\]' /etc/gitlab-runner/config.toml 2> /dev/null; then
    return
  fi

  log "Registering the runner"
  local token
  token=$(api user/runners --data runner_type=instance_type --data description=local-docker --data run_untagged=true | jq -r .token)
  docker exec --env CI_SERVER_TOKEN="$token" "$RUNNER" gitlab-runner register \
    --non-interactive \
    --url http://gitlab \
    --clone-url http://gitlab \
    --executor docker \
    --docker-image "$TOOLS_IMAGE" \
    --docker-pull-policy if-not-present \
    --docker-network-mode "$NETWORK" \
    --docker-volumes /var/run/docker.sock:/var/run/docker.sock \
    > /dev/null
}

build_tools_image() {
  log "Building the CI image"
  docker build --quiet --tag "$TOOLS_IMAGE" ci > /dev/null
}

# ---------- pipeline ----------

push_and_run() {
  [[ -z "$(git status --porcelain)" ]] || warn "uncommitted changes aren't pushed; the pipeline runs the last commit"
  git rev-parse --verify HEAD > /dev/null 2>&1 || die "commit the repository first"

  local sha basic output pipeline
  sha=$(git rev-parse HEAD)
  basic=$(printf 'root:%s' "$(cut -d' ' -f2 < "$LOCAL/auth-header")" | base64 | tr -d '\n')

  log "Pushing $(git rev-parse --short HEAD) to GitLab"
  output=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="Authorization: Basic $basic" \
    git push "$GITLAB_URL/$PROJECT.git" HEAD:refs/heads/main 2>&1) || die "push failed: $output"

  if [[ "$output" == *"Everything up-to-date"* ]]; then
    log "Nothing new to push, starting a new pipeline"
    pipeline=$(api "projects/$PROJECT_ID/pipeline" --data ref=main | jq -r .id)
  else
    local deadline=$(( SECONDS + 120 ))
    until pipeline=$(api "projects/$PROJECT_ID/pipelines?sha=$sha&ref=main&per_page=1" | jq -er '.[0].id'); do
      (( SECONDS < deadline )) || die "no pipeline was created for $sha"
      sleep 3
    done
  fi

  wait_for_pipeline "$pipeline"
}

wait_for_pipeline() {
  local id=$1 status last="" url
  url=$(api "projects/$PROJECT_ID/pipelines/$id" | jq -r .web_url)
  log "Pipeline $url"

  while true; do
    status=$(api "projects/$PROJECT_ID/pipelines/$id/jobs?per_page=50" \
      | jq -r 'sort_by(.id) | map("\(.name)=\(.status)") | join("  ")')
    if [[ "$status" != "$last" ]]; then
      printf '    %s\n' "$status"
      last=$status
    fi
    case $(api "projects/$PROJECT_ID/pipelines/$id" | jq -r .status) in
      success) log "Pipeline passed"; return ;;
      failed|canceled) die "pipeline failed, see $url" ;;
      manual) log "Pipeline passed (cluster:destroy is a manual job)"; return ;;
    esac
    sleep 10
  done
}

# ---------- cluster access ----------

write_kubeconfig() {
  docker container inspect "$CLUSTER-control-plane" > /dev/null 2>&1 || return 0
  local port name
  port=$(docker port "$CLUSTER-control-plane" 6443/tcp | head -1 | awk -F: '{print $NF}')
  docker exec "$CLUSTER-control-plane" cat /etc/kubernetes/admin.conf > "$LOCAL/kubeconfig"
  name=$(kubectl --kubeconfig "$LOCAL/kubeconfig" config view -o jsonpath='{.clusters[0].name}')
  kubectl --kubeconfig "$LOCAL/kubeconfig" config set-cluster "$name" --server "https://127.0.0.1:$port" > /dev/null
  log "Cluster access: export KUBECONFIG=$PWD/$LOCAL/kubeconfig"
}

# ---------- commands ----------

up() {
  doctor
  mkdir -p "$LOCAL" && chmod 700 "$LOCAL"
  umask 077
  start_gitlab
  ensure_token
  ensure_project
  ensure_variable APP_SECRET
  ensure_variable TOFU_STATE_PASSPHRASE
  build_tools_image
  ensure_runner
  push_and_run
  write_kubeconfig
  kubectl --kubeconfig "$LOCAL/kubeconfig" --namespace app get pods
  log "GitLab: http://localhost:8080 (root, password in $LOCAL/root-password)"
}

status() {
  docker ps --filter "network=$NETWORK" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
  if [[ -s "$LOCAL/auth-header" ]] && api user > /dev/null 2>&1; then
    ensure_project
    api "projects/$PROJECT_ID/pipelines?per_page=1" | jq -r '.[0] | "\nLatest pipeline: \(.status)  \(.web_url)"'
  fi
  if [[ -s "$LOCAL/kubeconfig" ]]; then
    echo
    kubectl --kubeconfig "$LOCAL/kubeconfig" get nodes
    kubectl --kubeconfig "$LOCAL/kubeconfig" --namespace app get pods
  fi
}

down() {
  log "Removing the cluster, the runner and GitLab"
  local nodes
  nodes=$(docker ps -aq --filter "label=io.x-k8s.kind.cluster=$CLUSTER")
  [[ -z "$nodes" ]] || docker rm -f $nodes > /dev/null
  docker rm -f "$RUNNER" "$GITLAB" > /dev/null 2>&1 || true
  rm -f "$LOCAL/kubeconfig"

  if [[ "${1:-}" == "--purge" ]]; then
    log "Removing GitLab's data, the CI image and local credentials"
    docker volume rm marvelx-gitlab-config marvelx-gitlab-logs marvelx-gitlab-data marvelx-runner-config > /dev/null 2>&1 || true
    docker image rm "$TOOLS_IMAGE" > /dev/null 2>&1 || true
    docker network rm "$NETWORK" > /dev/null 2>&1 || true
    rm -rf "$LOCAL"
  fi
}

case "${1:-}" in
  doctor) doctor ;;
  up)     up ;;
  status) status ;;
  down)   shift; down "$@" ;;
  *)      usage; exit 1 ;;
esac
