#!/usr/bin/env bash
# Runs on the bos VM as dev, piped in by `bos-t3-up install`. Safe to rerun.
# usage: bash -s -- <t3 version | latest> <port>
set -euo pipefail
version=$1
port=$2
export PATH="$HOME/.local/bin:$PATH"
wrapper="$HOME/.local/bin/bos-claude-t3"
settings="$HOME/.t3/userdata/settings.json"
service_env="$HOME/.t3/service.env"
restart=0

chmod 755 "$wrapper"

installed=$(t3 --version 2>/dev/null | sed -n 's/^t3 v//p' || true)
if [ -z "$installed" ]; then
  if [ "$version" = latest ]; then
    curl -fsSL https://t3.codes/install.sh | sh
  else
    curl -fsSL https://t3.codes/install.sh | T3CODE_VERSION="$version" sh
  fi
elif [ "$version" != latest ] && [ "$installed" != "$version" ]; then
  t3 update "$version" --yes --allow-downgrade
fi

mkdir -p "${settings%/*}"
if [ -s "$settings" ]; then
  current=$(jq -r '.providerInstances.claudeAgent.config.binaryPath // ""' "$settings")
  if [ "$current" != "$wrapper" ]; then
    tmp=$(mktemp "$settings.XXXXXX")
    jq --arg w "$wrapper" '
      .providerInstances.claudeAgent =
        ((.providerInstances.claudeAgent // {driver: "claudeAgent", enabled: true})
         | .config.binaryPath = $w)' "$settings" > "$tmp"
    mv "$tmp" "$settings"
    restart=1
  fi
else
  jq -n --arg w "$wrapper" \
    '{providerInstances: {claudeAgent: {driver: "claudeAgent", enabled: true, config: {binaryPath: $w}}}}' \
    > "$settings"
fi

touch "$service_env"
# 0.0.0.0 so bos's URL proxy reaches it at https://<port>-<env>.<domain>. T3 pairing still gates it.
grep -q '^T3CODE_HOST=' "$service_env" || { echo "T3CODE_HOST=0.0.0.0" >> "$service_env"; restart=1; }
grep -q '^T3CODE_PORT=' "$service_env" || { echo "T3CODE_PORT=$port" >> "$service_env"; restart=1; }

if systemctl --user is-active --quiet t3code 2>/dev/null; then
  [ "$restart" = 0 ] || t3 service restart
else
  t3 service install
fi

ready=0
for _ in $(seq 1 60); do
  if curl -fs -o /dev/null "http://127.0.0.1:$port/.well-known/t3/environment"; then
    ready=1
    break
  fi
  sleep 1
done
[ "$ready" = 1 ] || { echo "install-t3: T3 did not answer on port $port within 60 s; see ~/.t3/userdata/logs/boot-service.log" >&2; exit 1; }

for dir in /workspace/*/; do
  dir=${dir%/}
  [ -d "$dir/.git" ] || continue
  if out=$(t3 project add "$dir" 2>&1); then
    echo "$out" | tail -1
  else
    case "$out" in
      *lready*) echo "Project at $dir already added." ;;
      *) echo "$out" >&2; exit 1 ;;
    esac
  fi
done

echo "T3 $(t3 --version | sed -n 's/^t3 v//p') runs on port $port."
