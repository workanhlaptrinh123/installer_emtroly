#!/usr/bin/env bash
set -Eeuo pipefail
install -d -m 700 /root/.openclaw /root/.openclaw/workspace
ssh-keygen -A >/dev/null 2>&1 || true
service ssh start >/dev/null 2>&1 || /etc/init.d/ssh start >/dev/null 2>&1 || true
service nginx start >/dev/null 2>&1 || /etc/init.d/nginx start >/dev/null 2>&1 || true
if [[ -f /root/.openclaw/member-provider.env ]]; then
  set -a
  # shellcheck disable=SC1091
  . /root/.openclaw/member-provider.env
  set +a
fi
if [[ -f /root/.openclaw/openai-image.env ]]; then
  set -a
  # shellcheck disable=SC1091
  . /root/.openclaw/openai-image.env
  set +a
fi
cat > /usr/local/bin/openclaw-gateway-start <<'GATEWAY_WRAPPER'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -f /root/.openclaw/openai-image.env ]]; then
  set -a
  # shellcheck disable=SC1091
  . /root/.openclaw/openai-image.env
  set +a
fi
exec openclaw gateway run
GATEWAY_WRAPPER
chmod 755 /usr/local/bin/openclaw-gateway-start
member-install-modules
cat > /etc/supervisor/conf.d/openclaw.conf <<'EOF'
[program:openclaw-gateway]
command=/usr/local/bin/openclaw-gateway-start
directory=/root/.openclaw/workspace
user=root
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
stdout_logfile=/root/.openclaw/gateway.log
stderr_logfile=/root/.openclaw/gateway-error.log
stdout_logfile_maxbytes=5MB
stderr_logfile_maxbytes=5MB
stdout_logfile_backups=2
stderr_logfile_backups=2
environment=HOME="/root",OPENCLAW_CONFIG_PATH="/root/.openclaw/openclaw.json"
EOF
for config in /root/.openclaw/module-services/*.conf; do
  [[ ! -f "$config" ]] || cp "$config" /etc/supervisor/conf.d/
done
exec supervisord -n -c /etc/supervisor/supervisord.conf
