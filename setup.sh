#!/usr/bin/env bash
# ============================================================================
# setup_reality_selfsteal.sh  v3
# Debian 12/13：Cloudflare 自动加 A 记录 + UFW + BBR + DNS 验证证书
#               + 博客(Nginx 127.0.0.1:8443) + 3x-ui(全自动安装) + 自检
#
# 一键运行（脚本放到公开网址后）
#   bash <(curl -fsSL 脚本网址)            # 安装：只会问 CF Token 和域名
#   bash <(curl -fsSL 脚本网址) check      # 自检，可随时重跑
#   PANEL_PORT=面板端口 bash <(curl -fsSL 脚本网址) harden   # 收紧防火墙
#   注意要用 bash <(...)，不要用 curl ... | bash
#
# 可选环境变量（设置后对应的提问会跳过）
#   CF_Token / CF_Zone_ID / DOMAIN   直接传入，不再询问
#   PANEL_PORT   安装时固定面板端口（默认随机）；harden 时也用它
#   BLOG_TITLE   博客标题（默认 My Notes）
#   EMAIL        Let's Encrypt 账号邮箱（可不填）
#   SERVER_IP    手动指定公网 IP（默认自动探测）
#   FORCE_XUI=1  已装过 3x-ui 也重新安装
#   SCRIPT_URL   脚本网址，仅用于让结尾提示显示完整命令
# ============================================================================
set -u -o pipefail

PASS=0; WARN=0; FAIL=0
ok()   { echo "  [ OK ] $*"; PASS=$((PASS+1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
step() { echo; echo "==> $*"; }
die()  { echo "错误: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行"

ACME=/root/.acme.sh/acme.sh
XUI_BIN=/usr/local/x-ui/x-ui
INFO_FILE=/root/3xui-info.txt
BLOG_TITLE="${BLOG_TITLE:-My Notes}"

if [ -n "${SCRIPT_URL:-}" ]; then
  SELF="bash <(curl -fsSL ${SCRIPT_URL})"
elif [ -f "$0" ]; then
  SELF="bash $0"
else
  SELF="bash <(curl -fsSL 你的脚本网址)"
fi

detect_ip() {
  local u ip
  for u in https://api.ipify.org https://ip.sb https://ifconfig.me; do
    ip="$(curl -4 -fsS --max-time 8 -A 'curl/8' "$u" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$ip"; return 0; fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Cloudflare
# ---------------------------------------------------------------------------
# 自动查 Zone ID（Token 没有 Zone 读取权限时会失败，调用方会改为询问）
cf_find_zone() {
  local d="$DOMAIN" r id
  while [[ "$d" == *.* ]]; do
    r="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${CF_Token}" \
         "https://api.cloudflare.com/client/v4/zones?name=${d}" 2>/dev/null)" || return 1
    id="$(echo "$r" | jq -r '.result[0].id // empty' 2>/dev/null)"
    if [ -n "$id" ]; then echo "$id"; return 0; fi
    d="${d#*.}"
  done
  return 1
}

# 创建或更新 A 记录（灰云，仅 DNS）
cf_upsert_a() {
  local api="https://api.cloudflare.com/client/v4/zones/${CF_Zone_ID}/dns_records"
  local resp id body
  resp="$(curl -fsS --max-time 20 -H "Authorization: Bearer ${CF_Token}" -H "Content-Type: application/json" \
          "${api}?type=A&name=${DOMAIN}")" \
    || die "Cloudflare 请求失败。请检查：①Token 是否正确 ②Zone ID 是否正确 ③Token 的「客户端 IP 过滤」是否包含 ${SERVER_IP}"
  [ "$(echo "$resp" | jq -r '.success')" = "true" ] || die "Cloudflare 返回错误：$(echo "$resp" | jq -r '.errors[0].message')"
  id="$(echo "$resp" | jq -r '.result[0].id // empty')"
  body="$(jq -n --arg n "$DOMAIN" --arg c "$SERVER_IP" '{type:"A",name:$n,content:$c,ttl:120,proxied:false}')"
  if [ -n "$id" ]; then
    resp="$(curl -fsS --max-time 20 -X PUT -H "Authorization: Bearer ${CF_Token}" -H "Content-Type: application/json" \
            "${api}/${id}" --data "$body")" || die "更新 A 记录失败"
    echo "  已更新 A 记录：${DOMAIN} -> ${SERVER_IP}（灰云）"
  else
    resp="$(curl -fsS --max-time 20 -X POST -H "Authorization: Bearer ${CF_Token}" -H "Content-Type: application/json" \
            "${api}" --data "$body")" || die "创建 A 记录失败（Token 需要这个域名的 DNS 编辑权限）"
    echo "  已创建 A 记录：${DOMAIN} -> ${SERVER_IP}（灰云）"
  fi
  [ "$(echo "$resp" | jq -r '.success')" = "true" ] || die "Cloudflare 返回错误：$(echo "$resp" | jq -r '.errors[0].message')"
}

# ---------------------------------------------------------------------------
# 开始前的提问：只问 CF Token 和域名（Zone ID 能自动获取就不问）
# ---------------------------------------------------------------------------
collect_inputs() {
  if [ -z "${CF_Token:-}" ] || [ -z "${DOMAIN:-}" ]; then
    [ -r /dev/tty ] || die "没有可用的终端，无法提问。请改用环境变量传入 CF_Token 和 DOMAIN"
  fi

  if [ -z "${SERVER_IP:-}" ]; then
    SERVER_IP="$(detect_ip)" || die "探测不到公网 IP，请设置 SERVER_IP=x.x.x.x 后重试"
  fi

  if [ -z "${CF_Token:-}" ]; then
    echo
    echo "------------------------------------------------------------"
    echo " ① Cloudflare API Token"
    echo
    echo "   ⚠ 请先确认：这个 Token 的「客户端 IP 地址过滤」里已经加入"
    echo "     本机公网 IP：${SERVER_IP}"
    echo "     没加的话，后面添加 A 记录和申请证书都会失败。"
    echo "   Token 权限：对应域名的 Zone - DNS - Edit"
    echo "------------------------------------------------------------"
    read -rsp "请粘贴 CF Token（输入时不显示）: " CF_Token </dev/tty
    echo
    [ -n "$CF_Token" ] || die "Token 不能为空"
  fi

  local re='^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$'
  if [ -z "${DOMAIN:-}" ]; then
    echo
    echo "------------------------------------------------------------"
    echo " ② 域名"
    echo
    echo "   ✔ 不用自己去 Cloudflare 添加 A 记录，脚本会自动添加"
    echo "     （指向 ${SERVER_IP}，固定为灰云「仅 DNS」）。"
    echo "   建议每台机器用不同的子域名，例如 lion2.example.com"
    echo "------------------------------------------------------------"
    while true; do
      read -rp "请输入域名: " DOMAIN </dev/tty
      DOMAIN="$(echo "$DOMAIN" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
      [[ "$DOMAIN" =~ $re ]] && break
      echo "  域名格式不对，请重新输入"
    done
  else
    DOMAIN="$(echo "$DOMAIN" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
    [[ "$DOMAIN" =~ $re ]] || die "DOMAIN 格式不对：${DOMAIN}"
  fi

  export CF_Token DOMAIN SERVER_IP
}

# ---------------------------------------------------------------------------
# 自检
# ---------------------------------------------------------------------------
cmd_check() {
  set +e
  PASS=0; WARN=0; FAIL=0
  if [ -z "${DOMAIN:-}" ] && [ -f /etc/nginx/conf.d/blog.conf ]; then
    DOMAIN="$(grep -m1 server_name /etc/nginx/conf.d/blog.conf | awk '{print $2}' | tr -d ';')"
  fi
  [ -n "${DOMAIN:-}" ] || die "请设置 DOMAIN"
  local ip out
  ip="${SERVER_IP:-$(detect_ip)}"

  step "自检：${DOMAIN}"

  out="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  [ "$out" = "bbr" ] && ok "BBR 已开启" || bad "BBR 未开启（当前：${out:-未知}）"
  systemctl is-active --quiet ssh && ok "sshd 运行中" || bad "sshd 没在运行：systemctl reset-failed ssh && systemctl start ssh"

  out="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
  if [ -z "$out" ]; then warn "域名暂时解析不到，DNS 可能还没生效"
  elif [ -n "$ip" ] && [ "$out" = "$ip " ]; then ok "域名解析到本机 ${ip}"
  else warn "域名解析结果 [${out}] 与本机 IP [${ip:-未知}] 不一致（检查是否开了小黄云）"; fi

  if [ -f /etc/nginx/ssl/cert.pem ]; then
    out="$(openssl x509 -in /etc/nginx/ssl/cert.pem -noout -enddate 2>/dev/null | cut -d= -f2)"
    if openssl x509 -in /etc/nginx/ssl/cert.pem -noout -checkend $((14*86400)) >/dev/null 2>&1; then
      ok "证书有效，到期：${out}"
    else bad "证书 14 天内到期或已失效：${out}"; fi
  else bad "找不到 /etc/nginx/ssl/cert.pem"; fi
  grep -q "dns_cf" "/root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.conf" 2>/dev/null \
    && ok "证书续期方式：Cloudflare DNS（不占 80 端口）" || warn "续期方式不是 dns_cf，请检查 ~/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.conf"

  out="$(ss -tlnpH 'sport = :8443' 2>/dev/null)"
  if echo "$out" | grep -q '127.0.0.1:8443' && echo "$out" | grep -q nginx; then ok "nginx 只监听 127.0.0.1:8443"
  elif [ -n "$out" ]; then bad "8443 的监听不对（应为 nginx 且仅 127.0.0.1）：$(echo "$out" | head -n1)"
  else bad "8443 没有任何监听"; fi
  ss -tlnpH 'sport = :80' 2>/dev/null | grep -q nginx && ok "80 端口：nginx（仅做 HTTPS 跳转）" || warn "80 端口没有 nginx 监听"
  out="$(curl -ksS --max-time 8 -o /dev/null -w '%{http_code}' --resolve "${DOMAIN}:8443:127.0.0.1" "https://${DOMAIN}:8443/")"
  [ "$out" = "200" ] && ok "本机博客 HTTP 200" || bad "本机博客返回 ${out}"

  out="$(ss -tlnpH 'sport = :443' 2>/dev/null)"
  if echo "$out" | grep -q xray; then
    ok "xray 监听 443"
    out="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/")"
    [ "$out" = "200" ] && ok "偷自己生效：443 回落到博客，证书校验通过" || bad "443 访问博客返回 ${out}（检查入站目标是否为 127.0.0.1:8443、SNI 是否为 ${DOMAIN}）"
  elif [ -n "$out" ]; then bad "443 被别的程序占用：$(echo "$out" | head -n1)"
  else warn "443 还没有程序监听，导入旧面板数据库并修改入站后再跑一次 check"; fi

  out="$(ufw status verbose 2>/dev/null | grep -i '^Default')"
  if echo "$out" | grep -qi 'deny (incoming)'; then ok "UFW 已收紧：${out}"
  elif echo "$out" | grep -qi 'allow (incoming)'; then warn "UFW 仍是全部放行（验证通过后执行 harden）"
  else warn "UFW 状态未知"; fi
  if command -v fail2ban-client >/dev/null 2>&1; then
    out="$(fail2ban-client status 2>/dev/null | grep 'Jail list' | sed 's/.*:\s*//')"
    echo "$out" | grep -q sshd && ok "fail2ban 已保护 SSH（jail：${out}）" || warn "fail2ban 已装但没有 sshd jail（jail：${out}）"
  else warn "未安装 fail2ban，SSH 没有爆破防护"; fi

  echo
  echo "结果：通过 ${PASS}，警告 ${WARN}，失败 ${FAIL}"
  [ "$FAIL" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 收紧 UFW
# ---------------------------------------------------------------------------
cmd_harden() {
  set -e
  local pp="${PANEL_PORT:-}"
  if [ -z "$pp" ] && [ -f "$INFO_FILE" ]; then
    pp="$(grep -m1 '^PANEL_PORT=' "$INFO_FILE" | cut -d= -f2- || true)"
  fi
  if [ -z "$pp" ] && [ -x "$XUI_BIN" ]; then
    pp="$("$XUI_BIN" setting -show true 2>/dev/null | grep -iE '^\s*port\s*:' | head -n1 | sed -E 's/^[^:]*:\s*//' | tr -d '[:space:]' || true)"
  fi
  [ -n "$pp" ] || die "请设置 PANEL_PORT，例如 PANEL_PORT=2128 ${SELF} harden"
  local ssh_port="${SSH_PORT:-22}"
  step "收紧 UFW：放行 ${ssh_port}/80/443/${pp}"
  ufw allow "${ssh_port}/tcp"
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow "${pp}/tcp"
  ufw default deny incoming
  ufw reload
  ufw status numbered
  echo
  echo "还要到商家后台把安全组改成只放行 ${ssh_port}/80/443/${pp} 和 ICMP，"
  echo "并删掉 all_tcp 1-65535、RDP 3389、UDP 22/3389。"
}

# ---------------------------------------------------------------------------
# 3x-ui 全自动安装：用 expect 按提示自动应答
#   数据库=SQLite(回车默认) / 面板端口=随机(n) / SSL=3(Custom) / 域名 / 证书路径
#   遇到认不出的提示，会交还给你手动输入
# ---------------------------------------------------------------------------
install_xui_auto() {
  local log=/root/.xui-install.log inst=/tmp/3xui-install.sh exp=/tmp/xui_auto.exp
  ( umask 077; : > "$log" )
  curl -fsSL -o "$inst" https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh \
    || die "下载 3x-ui 安装脚本失败"

  cat > "$exp" <<'EXPECT_EOF'
set timeout 120
set domain $env(XUI_DOMAIN)
set cert   $env(XUI_CERT)
set key    $env(XUI_KEY)
log_file -noappend $env(XUI_LOG)
spawn bash $env(XUI_INSTALLER)
expect {
  -re {(?i)choose[^\n]*\[1\][^\n]*:\s*$}   { send "1\r"; exp_continue }
  -re {(?i)customize[^\n]*port[^\n]*:\s*$} { send "n\r"; exp_continue }
  -re {(?i)choose an option[^\n]*:\s*$}    { send "3\r"; exp_continue }
  -re {(?i)domain name[^\n]*:\s*$}         { send "$domain\r"; exp_continue }
  -re {(?i)private[^\n]*:\s*$}             { send "$key\r"; exp_continue }
  -re {(?i)(public|certificate|fullchain|cert)[^\n]*(path|file|key)[^\n]*:\s*$} { send "$cert\r"; exp_continue }
  timeout {
    puts "\n\[自动应答\] 120 秒内没有识别到已知提示，请按上面的提示手动输入："
    interact
  }
  eof { }
}
catch wait result
exit [lindex $result 3]
EXPECT_EOF

  set +e
  XUI_DOMAIN="$DOMAIN" XUI_CERT=/etc/nginx/ssl/cert.pem XUI_KEY=/etc/nginx/ssl/key.pem \
  XUI_LOG="$log" XUI_INSTALLER="$inst" expect -f "$exp"
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || echo "  警告：3x-ui 安装脚本退出码 ${rc}，请检查上面的输出"
  rm -f "$exp" "$inst"
}

strip_ansi() { sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr -d '\r'; }

# 从安装日志里取字段： xui_field 日志 '标签正则'
xui_field() {
  strip_ansi < "$1" | grep -iE "^[[:space:]]*($2)[[:space:]]*:" | tail -n1 \
    | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]+$//'
}

print_panel_info() {
  local log=/root/.xui-install.log user="" pass="" port="" path="" show=""
  if [ -s "$log" ]; then
    user="$(xui_field "$log" 'username')"
    pass="$(xui_field "$log" 'password')"
    port="$(xui_field "$log" 'port')"
    path="$(xui_field "$log" 'webbasepath|web base path')"
  fi

  # 固定面板端口
  if [ -n "${PANEL_PORT:-}" ] && [ "${XUI_NEW:-0}" = "1" ] && [ -x "$XUI_BIN" ]; then
    if "$XUI_BIN" setting -port "$PANEL_PORT" >/dev/null 2>&1; then
      systemctl restart x-ui >/dev/null 2>&1 || true
      port="$PANEL_PORT"
    else
      echo "  警告：设置面板端口 ${PANEL_PORT} 失败，仍使用随机端口"
    fi
  fi

  # 日志里没取到的，从 x-ui 自身读取
  if { [ -z "$port" ] || [ -z "$path" ]; } && [ -x "$XUI_BIN" ]; then
    show="$("$XUI_BIN" setting -show true 2>/dev/null | strip_ansi || true)"
    [ -n "$port" ] || port="$(echo "$show" | grep -iE '^\s*port\s*:' | head -n1 | sed -E 's/^[^:]*:\s*//' | tr -d '[:space:]')"
    [ -n "$path" ] || path="$(echo "$show" | grep -iE 'webbasepath' | head -n1 | sed -E 's/^[^:]*:\s*//' | tr -d '[:space:]')"
  fi

  path="${path#/}"; path="${path%/}"
  local url="https://${DOMAIN}:${port}/${path:+${path}/}"

  echo
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║                    3x-ui 面板信息                        ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo "  面板地址      ${url}"
  echo "  面板端口      ${port:-（未取到，执行 x-ui 查看）}"
  echo "  用户名        ${user:-（未取到）}"
  echo "  密码          ${pass:-（未取到）}"
  echo "  WebBasePath   ${path:-（未取到）}"
  if [ -z "$user" ] || [ -z "$pass" ]; then
    echo
    echo "  没能从安装输出里取到账号密码（可能是 3x-ui 已安装过，或输出格式变了）。"
    echo "  执行 x-ui 进入菜单，用「重置用户名和密码」重新设置。"
    if [ -s "$log" ]; then
      echo "  安装输出的最后 15 行："
      strip_ansi < "$log" | tail -n 15 | sed 's/^/    | /'
    fi
  fi

  # 兜底：存一份只有 root 能读的文件，避免终端滚走后丢失
  ( umask 077
    {
      echo "DOMAIN=${DOMAIN}"
      echo "PANEL_PORT=${port}"
      echo "PANEL_USER=${user}"
      echo "PANEL_PASS=${pass}"
      echo "PANEL_PATH=${path}"
      echo "PANEL_URL=${url}"
    } > "$INFO_FILE" )
  rm -f "$log"
  echo
  echo "  已另存到 ${INFO_FILE}（仅 root 可读）。记好后建议删除：rm ${INFO_FILE}"
  echo "  注意：删掉之后 harden 就读不到面板端口，需要手动带上 PANEL_PORT=端口"
}

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
cmd_install() {
  set -e
  export DEBIAN_FRONTEND=noninteractive
  APT_OPTS=(-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)

  [ -r /etc/os-release ] && . /etc/os-release
  case "${ID:-}-${VERSION_ID:-}" in
    debian-12|debian-13) ;;
    *) echo "警告：本脚本只在 Debian 12/13 上验证过，当前是 ${PRETTY_NAME:-未知}" ;;
  esac

  # ---- 开始前的提问（只问 Token 和域名）----
  collect_inputs

  step "1/9 Cloudflare：验证 Token，自动添加 A 记录"
  apt-get update
  apt-get install -y curl jq ca-certificates
  if [ -z "${CF_Zone_ID:-}" ]; then
    CF_Zone_ID="$(cf_find_zone || true)"
    if [ -n "$CF_Zone_ID" ]; then
      echo "  已自动获取 Zone ID"
    else
      echo
      echo "  自动获取 Zone ID 失败（Token 没有读取 Zone 的权限，这是正常的）。"
      echo "  请在 Cloudflare 里打开这个域名的「概览」页，右下角复制「区域 ID」。"
      [ -r /dev/tty ] || die "没有终端，请用 CF_Zone_ID 环境变量传入"
      read -rp "请输入 Zone ID: " CF_Zone_ID </dev/tty
      [ -n "$CF_Zone_ID" ] || die "Zone ID 不能为空"
    fi
  fi
  export CF_Zone_ID
  echo "  本机公网 IP：${SERVER_IP}"
  cf_upsert_a

  step "2/9 更新系统并安装软件"
  apt-get upgrade -y "${APT_OPTS[@]}"
  apt-get install -y ufw nginx socat openssl expect
  apt-get install -y --no-install-recommends cron   # 不带推荐包，避免装上 exim4
  systemctl stop nginx || true

  step "3/9 检查 SSH 服务"
  if ! systemctl is-active --quiet ssh; then
    systemctl reset-failed ssh || true
    systemctl start ssh
  fi
  systemctl is-active --quiet ssh && echo "  sshd 运行中"

  step "4/9 UFW（先全部放行，避免锁住自己；收紧用 harden）"
  if ufw status | grep -q '^Status: active'; then
    echo "  UFW 已启用，保持现有策略不动"
    ufw allow 22/tcp >/dev/null
  else
    ufw default allow incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw --force enable
  fi

  step "5/9 开启 BBR"
  grep -q '^net.core.default_qdisc=fq' /etc/sysctl.conf || echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
  grep -q '^net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf || echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1 || true   # conntrack 相关的 Invalid argument 可以忽略
  sysctl net.ipv4.tcp_congestion_control

  step "6/9 申请证书（DNS 验证，不占 80 端口）"
  export CF_Token CF_Zone_ID
  if [ ! -x "$ACME" ]; then
    if [ -n "${EMAIL:-}" ]; then curl -fsSL https://get.acme.sh | sh -s email="$EMAIL"
    else curl -fsSL https://get.acme.sh | sh
    fi
  fi
  "$ACME" --set-default-ca --server letsencrypt
  rc=0
  "$ACME" --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256 || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || die "证书申请失败（退出码 ${rc}）"   # 2 = 证书还没到续期时间
  mkdir -p /etc/nginx/ssl
  "$ACME" --install-cert -d "$DOMAIN" --ecc \
    --key-file /etc/nginx/ssl/key.pem \
    --fullchain-file /etc/nginx/ssl/cert.pem \
    --reloadcmd "systemctl reload nginx 2>/dev/null || true; systemctl restart x-ui 2>/dev/null || true"

  step "7/9 博客 + Nginx（80 仅跳转，网站只监听 127.0.0.1:8443）"
  mkdir -p /var/www/blog
  if [ ! -f /var/www/blog/index.html ]; then
    cat > /var/www/blog/index.html <<EOF
<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8"><title>${BLOG_TITLE}</title></head>
<body style="max-width:720px;margin:40px auto;font-family:sans-serif">
<h1>${BLOG_TITLE}</h1>
<p>记录学习和生活。</p>
<h2>$(date +%F) · 第一篇</h2>
<p>博客开张了。</p>
</body></html>
EOF
  else
    echo "  /var/www/blog/index.html 已存在，保留不覆盖"
  fi

  # Nginx >= 1.25.1 用 "http2 on;"，旧版写在 listen 里
  NGX_VER="$(nginx -v 2>&1 | sed 's/.*nginx\///')"
  if [ "$(printf '%s\n1.25.1\n' "$NGX_VER" | sort -V | head -n1)" = "1.25.1" ]; then
    LISTEN_LINE="listen 127.0.0.1:8443 ssl;"; HTTP2_LINE="http2 on;"
  else
    LISTEN_LINE="listen 127.0.0.1:8443 ssl http2;"; HTTP2_LINE=""
  fi
  cat > /etc/nginx/conf.d/blog.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    ${LISTEN_LINE}
    ${HTTP2_LINE}
    server_name ${DOMAIN};
    ssl_certificate     /etc/nginx/ssl/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/blog;
    index index.html;
}
EOF
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx

  step "8/9 安装 3x-ui（全自动：SQLite / 随机面板端口 / SSL 选 3 / 填域名和证书路径）"
  XUI_NEW=0
  if [ -x "$XUI_BIN" ] && [ "${FORCE_XUI:-0}" != "1" ]; then
    echo "  检测到 3x-ui 已安装，跳过安装（需要重装请加 FORCE_XUI=1）"
  else
    XUI_NEW=1
    install_xui_auto
  fi
  print_panel_info

  step "9/9 自检"
  cmd_check || true

  cat <<EOF

========================= 接下来手动做 =========================
 1. 用上面的面板地址、用户名、密码登录
 2. 右上角「备份和恢复」：
      先点「备份」留一份当前数据库
      确认勾选「保留本机设置」，再点「恢复」，上传旧面板的 .db
 3. 编辑导入进来的 Reality 入站：
      端口 443 / 目标 127.0.0.1:8443 / SNI ${DOMAIN}
      点「获取新证书」重新生成密钥，Short IDs 重新生成
      客户端 Flow 确认是 xtls-rprx-vision
      备注里如果还有旧机器的名字，顺手改掉
 4. 客户端重新导入链接或更新订阅
 5. 重新自检：      ${SELF} check
 6. 全部通过后收紧： ${SELF} harden
 7. 商家后台安全组同步收紧（脚本管不到）
================================================================
EOF
}

case "${1:-install}" in
  install) cmd_install ;;
  check)   cmd_check ;;
  harden)  cmd_harden ;;
  *) echo "用法：${SELF} [install|check|harden]"; exit 1 ;;
esac
