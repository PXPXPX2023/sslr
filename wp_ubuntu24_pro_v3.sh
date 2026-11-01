#!/usr/bin/env bash
#
# wp_ubuntu24_pro_v3.sh
# WordPress one-click installer for Ubuntu 24.04 LTS minimal
# Stack: Nginx + PHP 8.3-FPM + MariaDB + Redis + WP-CLI + Let's Encrypt HTTPS
# v3: anti-abuse + portable backup/restore + wpctl manager
# License: MIT
#
# Recommended:
#   sudo bash wp_ubuntu24_pro_v3.sh --domain example.com --email admin@example.com --www --enable-ufw
#
# GitHub raw usage:
#   curl -fsSL https://raw.githubusercontent.com/YOUR_NAME/YOUR_REPO/main/wp_ubuntu24_pro_v3.sh -o wp_ubuntu24_pro_v3.sh
#   chmod +x wp_ubuntu24_pro_v3.sh
#   sudo ./wp_ubuntu24_pro_v3.sh --domain example.com --email admin@example.com --www --enable-ufw
#

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="3.0.0-backup-migrate"
PHP_VERSION="8.3"
DEFAULT_INSTALL_DIR="/var/www/wordpress"
DEFAULT_DB_NAME="wordpress"
DEFAULT_DB_USER="wpuser"
DEFAULT_LOCALE="zh_CN"
LOG_DIR="/var/log/wp-oneclick"
LOG_FILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
BACKUP_DIR="/root/wp-oneclick-backup"

DOMAIN=""
EMAIL=""
SITE_TITLE=""
ADMIN_USER=""
ADMIN_PASS=""
ADMIN_EMAIL=""
DB_NAME="$DEFAULT_DB_NAME"
DB_USER="$DEFAULT_DB_USER"
DB_PASS=""
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
LOCALE="$DEFAULT_LOCALE"
ENABLE_SSL=1
ENABLE_WWW=0
CANONICAL="apex"
ENABLE_REDIS=1
ENABLE_UFW=0
SKIP_DNS_CHECK=0
FORCE_INSTALL=0
NON_INTERACTIVE=0
CURRENT_PUBLIC_IP=""

# v2 hardening switches. Defaults are intentionally strict for public WordPress sites.
SECURITY_MODE="strict"
ENABLE_BOT_FILTER=1
DISABLE_XMLRPC=1
DISABLE_COMMENTS=1
DISABLE_EXTERNAL_WPCRON=1
ENABLE_FASTCGI_CACHE=1
ENABLE_HOTLINK_GUARD=1
ENABLE_STATIC_RATE_LIMIT=1
ENABLE_FAIL2BAN=1
ENABLE_HSTS=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

umask 077
mkdir -p "$LOG_DIR" "$BACKUP_DIR"
chmod 700 "$LOG_DIR" "$BACKUP_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'on_error $LINENO "$BASH_COMMAND"' ERR

on_error() {
  local line="$1"
  local cmd="$2"
  echo -e "\n${RED}[ERROR] Script failed at line ${line}: ${cmd}${NC}"
  echo -e "${YELLOW}Log file: ${LOG_FILE}${NC}"
  exit 1
}

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fatal() { echo -e "${RED}[FATAL]${NC} $*"; exit 1; }

usage() {
  cat <<USAGE
WordPress One-Click Installer for Ubuntu 24.04 LTS minimal v${SCRIPT_VERSION}

Usage:
  sudo bash $0 --domain example.com --email admin@example.com [options]

Basic options:
  --domain DOMAIN             Main domain, for example: example.com
  --email EMAIL               Email for Let's Encrypt and WordPress admin fallback
  --site-title TITLE          WordPress site title
  --admin-user USER           WordPress admin username
  --admin-pass PASS           WordPress admin password; random if omitted
  --admin-email EMAIL         WordPress admin email; defaults to --email
  --db-name NAME              Database name; default: wordpress
  --db-user USER              Database user; default: wpuser
  --db-pass PASS              Database password; random if omitted
  --install-dir DIR           Install path; default: /var/www/wordpress
  --locale LOCALE             WordPress locale; default: zh_CN
  --www                       Also configure www.DOMAIN
  --canonical MODE            apex|www. Default: apex; www automatically enables --www
  --no-ssl                    Skip Let's Encrypt HTTPS
  --no-redis                  Do not install/configure Redis object cache
  --enable-ufw                Enable UFW and allow 22/80/443
  --skip-dns-check            Skip IPv4 DNS check before SSL
  --force                     Overwrite non-WordPress leftover directory ONLY (never an installed WordPress)
  --non-interactive           Do not ask questions; missing values are auto-generated where possible

Anti-scan / anti-abuse options:
  --security-mode MODE        strict|balanced|relaxed. Default: strict
  --no-bot-filter             Disable Nginx bad-bot and sensitive-URI early return rules
  --allow-xmlrpc              Allow /xmlrpc.php. Default: disabled and returns 444
  --allow-comments            Allow comments endpoint. Default: disabled for company/blog brochure sites
  --allow-external-wpcron     Allow external /wp-cron.php hits. Default: disabled; system cron is used
  --no-fastcgi-cache          Disable Nginx FastCGI page cache
  --no-hotlink-guard          Disable media hotlink guard
  --no-static-rate-limit      Disable per-connection static file speed limit
  --no-fail2ban               Do not configure Fail2ban WordPress/Nginx jails
  --enable-hsts               Enable HSTS header after HTTPS is stable. Use carefully.
  --adopt-existing            Register a previously installed v2 site for wpctl; do NOT reinstall.

Operational commands after installation:
  wpctl                       Interactive management menu
  wpctl backup                Make one portable compressed archive
  wpctl backups               List local archives
  wpctl verify --archive FILE Verify archive checksums
  wpctl restore --archive FILE --yes [--target-domain DOMAIN] [--canonical apex|www]
  wpctl ssl                   Issue or expand TLS certificate after DNS cutover
  wpctl status                Display running services/site URLs
  -h, --help                  Show this help

Examples:
  sudo bash $0 --domain example.com --email admin@example.com --www --enable-ufw
  sudo bash $0 --domain example.com --email admin@example.com --security-mode balanced
  sudo bash $0 --domain example.com --email admin@example.com --allow-xmlrpc --allow-comments

Notes:
  v3 retains v2 anti-scan hardening and adds portable backups and wpctl management. If Jetpack, WordPress mobile app,
  remote publishing, or XML-RPC integrations are required, use --allow-xmlrpc.

USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) DOMAIN="${2:-}"; shift 2 ;;
      --email) EMAIL="${2:-}"; shift 2 ;;
      --site-title) SITE_TITLE="${2:-}"; shift 2 ;;
      --admin-user) ADMIN_USER="${2:-}"; shift 2 ;;
      --admin-pass) ADMIN_PASS="${2:-}"; shift 2 ;;
      --admin-email) ADMIN_EMAIL="${2:-}"; shift 2 ;;
      --db-name) DB_NAME="${2:-}"; shift 2 ;;
      --db-user) DB_USER="${2:-}"; shift 2 ;;
      --db-pass) DB_PASS="${2:-}"; shift 2 ;;
      --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
      --locale) LOCALE="${2:-}"; shift 2 ;;
      --www) ENABLE_WWW=1; shift ;;
      --canonical) CANONICAL="${2:-}"; shift 2 ;;
      --adopt-existing) ADOPT_EXISTING=1; shift ;;
      --no-ssl) ENABLE_SSL=0; shift ;;
      --no-redis) ENABLE_REDIS=0; shift ;;
      --enable-ufw) ENABLE_UFW=1; shift ;;
      --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
      --force) FORCE_INSTALL=1; shift ;;
      --non-interactive) NON_INTERACTIVE=1; shift ;;
      --security-mode) SECURITY_MODE="${2:-}"; shift 2 ;;
      --no-bot-filter) ENABLE_BOT_FILTER=0; shift ;;
      --allow-xmlrpc) DISABLE_XMLRPC=0; shift ;;
      --allow-comments) DISABLE_COMMENTS=0; shift ;;
      --allow-external-wpcron) DISABLE_EXTERNAL_WPCRON=0; shift ;;
      --no-fastcgi-cache) ENABLE_FASTCGI_CACHE=0; shift ;;
      --no-hotlink-guard) ENABLE_HOTLINK_GUARD=0; shift ;;
      --no-static-rate-limit) ENABLE_STATIC_RATE_LIMIT=0; shift ;;
      --no-fail2ban) ENABLE_FAIL2BAN=0; shift ;;
      --enable-hsts) ENABLE_HSTS=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fatal "Unknown option: $1" ;;
    esac
  done
}

apply_security_mode() {
  case "$SECURITY_MODE" in
    strict)
      # Defaults already strict.
      ;;
    balanced)
      # Keep XML-RPC closed, but be less aggressive on comments/static throttling.
      DISABLE_COMMENTS=0
      ENABLE_STATIC_RATE_LIMIT=0
      ;;
    relaxed)
      ENABLE_BOT_FILTER=1
      DISABLE_XMLRPC=0
      DISABLE_COMMENTS=0
      DISABLE_EXTERNAL_WPCRON=0
      ENABLE_FASTCGI_CACHE=1
      ENABLE_HOTLINK_GUARD=0
      ENABLE_STATIC_RATE_LIMIT=0
      ;;
    *) fatal "Invalid --security-mode. Use strict, balanced, or relaxed." ;;
  esac
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || fatal "Please run as root: sudo bash $0 ..."
}

check_os() {
  [[ -f /etc/os-release ]] || fatal "Cannot detect OS. /etc/os-release not found."
  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    fatal "This installer requires Ubuntu 24.04 LTS. Detected: ${PRETTY_NAME:-unknown}. The --force flag cannot bypass this safeguard."
  fi
  success "OS check passed: ${PRETTY_NAME:-Ubuntu 24.04}"
}

valid_domain() {
  local d="$1"
  [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

valid_email() {
  local e="$1"
  [[ "$e" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

random_password() {
  openssl rand -base64 48 | tr -d '=+/[:space:]' | cut -c1-28
}

validate_inputs() {
  [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || fatal "Invalid --db-name. Use letters, numbers, underscore only."
  [[ "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || fatal "Invalid --db-user. Use letters, numbers, underscore only."
  [[ "$ADMIN_USER" =~ ^[A-Za-z0-9_@.-]+$ ]] || fatal "Invalid --admin-user. Use letters, numbers, underscore, @, dot, hyphen only."
  if [[ -n "$DB_PASS" && "$DB_PASS" == *"'"* ]]; then
    fatal "DB password must not contain single quote. Omit --db-pass to auto-generate a safe password."
  fi
  case "$INSTALL_DIR" in
    /|/root|/etc|/usr|/var|/var/www) fatal "Unsafe --install-dir: $INSTALL_DIR" ;;
  esac
}

prompt_if_needed() {
  if [[ -z "$DOMAIN" && "$NON_INTERACTIVE" -ne 1 ]]; then
    read -rp "Enter domain, e.g. example.com: " DOMAIN
  fi
  [[ -n "$DOMAIN" ]] || fatal "--domain is required."
  valid_domain "$DOMAIN" || fatal "Invalid domain: $DOMAIN"
  [[ "$CANONICAL" == "apex" || "$CANONICAL" == "www" ]] || fatal "--canonical expects apex or www"
  [[ "$CANONICAL" == "www" ]] && ENABLE_WWW=1

  if [[ -z "$EMAIL" && "$NON_INTERACTIVE" -ne 1 ]]; then
    read -rp "Enter email for SSL/admin, e.g. admin@example.com: " EMAIL
  fi
  [[ -n "$EMAIL" ]] || EMAIL="admin@$DOMAIN"
  valid_email "$EMAIL" || fatal "Invalid email: $EMAIL"

  [[ -n "$ADMIN_EMAIL" ]] || ADMIN_EMAIL="$EMAIL"
  valid_email "$ADMIN_EMAIL" || fatal "Invalid admin email: $ADMIN_EMAIL"

  [[ -n "$SITE_TITLE" ]] || SITE_TITLE="$DOMAIN"
  [[ -n "$ADMIN_USER" ]] || ADMIN_USER="wpadmin"
  [[ -n "$ADMIN_PASS" ]] || ADMIN_PASS="$(random_password)"
  [[ -n "$DB_PASS" ]] || DB_PASS="$(random_password)"

  [[ "$INSTALL_DIR" == /* ]] || fatal "--install-dir must be an absolute path."
  validate_inputs

  info "Install settings:"
  echo "  Script:        $SCRIPT_VERSION"
  echo "  Domain:        $DOMAIN"
  [[ "$ENABLE_WWW" -eq 1 ]] && echo "  WWW alias:     www.$DOMAIN" || true
  echo "  Canonical:     $CANONICAL"
  echo "  Install dir:   $INSTALL_DIR"
  echo "  Site title:    $SITE_TITLE"
  echo "  Admin user:    $ADMIN_USER"
  echo "  Admin email:   $ADMIN_EMAIL"
  echo "  Database:      $DB_NAME"
  echo "  DB user:       $DB_USER"
  echo "  HTTPS:         $([[ "$ENABLE_SSL" -eq 1 ]] && echo enabled || echo disabled)"
  echo "  Redis:         $([[ "$ENABLE_REDIS" -eq 1 ]] && echo enabled || echo disabled)"
  echo "  Security mode: $SECURITY_MODE"
  echo "  Bot filter:    $([[ "$ENABLE_BOT_FILTER" -eq 1 ]] && echo enabled || echo disabled)"
  echo "  XML-RPC:       $([[ "$DISABLE_XMLRPC" -eq 1 ]] && echo disabled || echo allowed)"
  echo "  Comments:      $([[ "$DISABLE_COMMENTS" -eq 1 ]] && echo disabled || echo allowed)"
  echo "  External cron: $([[ "$DISABLE_EXTERNAL_WPCRON" -eq 1 ]] && echo disabled || echo allowed)"
  echo "  FastCGI cache: $([[ "$ENABLE_FASTCGI_CACHE" -eq 1 ]] && echo enabled || echo disabled)"
  echo "  Fail2ban:      $([[ "$ENABLE_FAIL2BAN" -eq 1 ]] && echo enabled || echo disabled)"

  if [[ "$NON_INTERACTIVE" -ne 1 ]]; then
    echo
    read -rp "Continue installation? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || fatal "Cancelled by user."
  fi
}

install_base_packages() {
  info "Updating apt and installing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    ca-certificates curl wget gnupg lsb-release apt-transport-https \
    software-properties-common unzip zip tar rsync cron logrotate \
    nginx mariadb-server mariadb-client \
    php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-mysql \
    php${PHP_VERSION}-curl php${PHP_VERSION}-gd php${PHP_VERSION}-mbstring \
    php${PHP_VERSION}-xml php${PHP_VERSION}-zip php${PHP_VERSION}-intl \
    php${PHP_VERSION}-bcmath php${PHP_VERSION}-imagick php${PHP_VERSION}-opcache \
    certbot python3-certbot-nginx \
    openssl dnsutils ufw fail2ban zstd

  if [[ "$ENABLE_REDIS" -eq 1 ]]; then
    apt-get install -y redis-server php${PHP_VERSION}-redis
  fi

  systemctl enable --now nginx
  systemctl enable --now mariadb
  systemctl enable --now php${PHP_VERSION}-fpm
  [[ "$ENABLE_REDIS" -eq 1 ]] && systemctl enable --now redis-server || true
  success "Packages installed."
}

configure_ufw() {
  if [[ "$ENABLE_UFW" -ne 1 ]]; then
    warn "UFW not enabled by default. Use --enable-ufw if you want the script to manage firewall rules."
    return 0
  fi

  info "Configuring UFW..."
  ufw allow OpenSSH || ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
  ufw status verbose || true
  success "UFW configured."
}

get_public_ip() {
  local ip=""
  ip="$(curl -4fsS --max-time 8 https://api.ipify.org || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4fsS --max-time 8 https://ifconfig.me/ip || true)"
  fi
  CURRENT_PUBLIC_IP="$ip"
  [[ -n "$CURRENT_PUBLIC_IP" ]] || warn "Could not detect public IPv4. DNS check may be incomplete."
}

check_dns() {
  if [[ "$SKIP_DNS_CHECK" -eq 1 || "$ENABLE_SSL" -ne 1 ]]; then
    warn "DNS check skipped."
    return 0
  fi

  get_public_ip
  [[ -n "$CURRENT_PUBLIC_IP" ]] || return 0

  info "Checking DNS A record for $DOMAIN ..."
  local resolved_ips
  resolved_ips="$(dig +short A "$DOMAIN" 2>/dev/null | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | tr '\n' ' ' || true)"

  if [[ -z "$resolved_ips" ]]; then
    fatal "No A record found for $DOMAIN. Please point your domain to this VPS IP: $CURRENT_PUBLIC_IP"
  fi

  if ! grep -qw "$CURRENT_PUBLIC_IP" <<< "$resolved_ips"; then
    fatal "DNS A record mismatch. $DOMAIN resolves to [$resolved_ips], but VPS public IPv4 is [$CURRENT_PUBLIC_IP]. Fix DNS or use --skip-dns-check."
  fi

  if [[ "$ENABLE_WWW" -eq 1 ]]; then
    local www_ips
    www_ips="$(dig +short A "www.$DOMAIN" 2>/dev/null | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | tr '\n' ' ' || true)"
    if [[ -z "$www_ips" ]]; then
      fatal "No A record found for www.$DOMAIN. Add A/CNAME record or remove --www. VPS IP: $CURRENT_PUBLIC_IP"
    fi
    if ! grep -qw "$CURRENT_PUBLIC_IP" <<< "$www_ips"; then
      warn "www.$DOMAIN does not resolve to this VPS IPv4. Current: [$www_ips], VPS: [$CURRENT_PUBLIC_IP]"
      fatal "Fix www DNS or remove --www."
    fi
  fi

  success "DNS A record points to this VPS: $CURRENT_PUBLIC_IP"
}

backup_existing() {
  info "Checking existing files..."
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"

  if [[ -d "$INSTALL_DIR" && -n "$(ls -A "$INSTALL_DIR" 2>/dev/null || true)" ]]; then
    if [[ -f "$INSTALL_DIR/wp-config.php" ]]; then
      fatal "Existing WordPress found at $INSTALL_DIR. Refusing destructive reinstall. Use --adopt-existing to add wpctl, or reinstall VPS OS after exporting a portable backup."
    fi
    if [[ "$FORCE_INSTALL" -ne 1 ]]; then
      fatal "$INSTALL_DIR is not empty. Use --force only for leftover NON-WordPress files."
    fi
    local dst="$BACKUP_DIR/wordpress-files-$stamp"
    info "Backing up existing install dir to $dst ..."
    mkdir -p "$dst"
    rsync -a "$INSTALL_DIR/" "$dst/"
    rm -rf "$INSTALL_DIR"
  fi

  if [[ -f "/etc/nginx/sites-available/$DOMAIN" ]]; then
    cp -a "/etc/nginx/sites-available/$DOMAIN" "$BACKUP_DIR/nginx-$DOMAIN-$stamp.conf"
  fi
}

secure_mariadb_minimal() {
  info "Applying minimal MariaDB hardening..."
  mysql -uroot <<SQL
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
  success "MariaDB minimal hardening done."
}

create_database() {
  info "Creating MariaDB database and user..."
  mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
  success "Database ready."
}

install_wp_cli() {
  if command -v wp >/dev/null 2>&1; then
    success "WP-CLI already installed: $(wp --version --allow-root 2>/dev/null || wp --version 2>/dev/null || true)"
    return 0
  fi

  info "Installing WP-CLI..."
  curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
  chmod +x /usr/local/bin/wp
  wp --info --allow-root >/dev/null
  success "WP-CLI installed: $(wp --version --allow-root)"
}

configure_php() {
  info "Configuring PHP ${PHP_VERSION}..."
  local fpm_ini="/etc/php/${PHP_VERSION}/fpm/php.ini"
  local cli_ini="/etc/php/${PHP_VERSION}/cli/php.ini"
  local pool_conf="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
  local opcache_ini="/etc/php/${PHP_VERSION}/mods-available/opcache.ini"

  cp -a "$fpm_ini" "$BACKUP_DIR/php-fpm-php.ini.$(date +%Y%m%d-%H%M%S)" || true

  sed -i \
    -e 's/^upload_max_filesize = .*/upload_max_filesize = 128M/' \
    -e 's/^post_max_size = .*/post_max_size = 128M/' \
    -e 's/^memory_limit = .*/memory_limit = 256M/' \
    -e 's/^max_execution_time = .*/max_execution_time = 300/' \
    -e 's/^max_input_time = .*/max_input_time = 300/' \
    -e 's/^;cgi.fix_pathinfo=.*/cgi.fix_pathinfo=0/' \
    -e 's/^expose_php = .*/expose_php = Off/' \
    "$fpm_ini"

  sed -i \
    -e 's/^memory_limit = .*/memory_limit = 256M/' \
    -e 's/^max_execution_time = .*/max_execution_time = 300/' \
    "$cli_ini"

  cat > "$opcache_ini" <<OPCACHE
zend_extension=opcache.so
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=192
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=1
opcache.revalidate_freq=60
opcache.jit=0
OPCACHE

  sed -i \
    -e 's/^pm = .*/pm = dynamic/' \
    -e 's/^pm.max_children = .*/pm.max_children = 16/' \
    -e 's/^pm.start_servers = .*/pm.start_servers = 3/' \
    -e 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 2/' \
    -e 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 5/' \
    -e 's/^;pm.max_requests = .*/pm.max_requests = 500/' \
    "$pool_conf"

  systemctl restart php${PHP_VERSION}-fpm
  success "PHP configured."
}

write_security_headers() {
  local conf="/etc/nginx/snippets/wp-security-headers.conf"
  cat > "$conf" <<HEADERS
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
HEADERS
  if [[ "$ENABLE_HSTS" -eq 1 && "$ENABLE_SSL" -eq 1 ]]; then
    cat >> "$conf" <<'HEADERS'
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
HEADERS
  else
    cat >> "$conf" <<'HEADERS'
# HSTS is intentionally disabled by default. Enable only after HTTPS is confirmed stable.
# add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
HEADERS
  fi
}

write_nginx_global_hardening() {
  info "Writing Nginx global anti-scan rules..."
  mkdir -p /var/cache/nginx/wp-fastcgi
  chown -R www-data:www-data /var/cache/nginx || true

  cat > /etc/nginx/conf.d/wp-oneclick-hardening.conf <<'NGINX'
# WordPress OneClick v3 global hardening.
# This file is included in Nginx http{} context by default Ubuntu nginx.conf.

server_tokens off;

log_format wp_oneclick_ext '$remote_addr - $remote_user [$time_local] '
                           '"$request" $status $body_bytes_sent '
                           '"$http_referer" "$http_user_agent" '
                           'rt=$request_time urt=$upstream_response_time';

limit_req_status 429;
limit_conn_status 429;
limit_req_zone $binary_remote_addr zone=wp_global:30m rate=8r/s;
limit_req_zone $binary_remote_addr zone=wp_php:30m rate=2r/s;
limit_req_zone $binary_remote_addr zone=wp_login:20m rate=3r/m;
limit_req_zone $binary_remote_addr zone=wp_ajax:20m rate=8r/s;
limit_req_zone $binary_remote_addr zone=wp_static:30m rate=20r/s;
limit_conn_zone $binary_remote_addr zone=wp_conn:30m;

fastcgi_cache_path /var/cache/nginx/wp-fastcgi levels=1:2 keys_zone=wp_fastcgi_cache:100m inactive=60m max_size=1024m use_temp_path=off;
fastcgi_cache_key "$scheme$request_method$host$request_uri";

map $request_method $wp_skip_cache_method {
    default 1;
    GET 0;
    HEAD 0;
}

map $query_string $wp_skip_cache_query {
    default 1;
    "" 0;
}

map $http_cookie $wp_skip_cache_cookie {
    default 0;
    ~*wordpress_logged_in 1;
    ~*wordpress_sec 1;
    ~*comment_author 1;
    ~*wp-postpass 1;
    ~*woocommerce_items_in_cart 1;
    ~*wp_woocommerce_session 1;
}

map $request_uri $wp_skip_cache_uri {
    default 0;
    ~*^/wp-admin/ 1;
    ~*^/wp-login\.php 1;
    ~*^/wp-json/ 1;
    ~*^/xmlrpc\.php 1;
    ~*^/wp-cron\.php 1;
    ~*preview=true 1;
    ~*customize_changeset_uuid 1;
}

map $http_user_agent $wp_bad_bot {
    default 0;
    "" 1;
    ~*(?:acunetix|ahrefsbot|alexibot|blexbot|bytespider|censysinspect|crawler4j|dataforseo|dirbuster|dotbot|emailcollector|evil|gobuster|go-http-client|harvest|httrack|masscan|mj12bot|morfeus|nikto|nmap|openvas|petalbot|python-requests|semrushbot|sqlmap|turnitinbot|wpscan|zgrab|zoomeye) 1;
}

map $request_uri $wp_bad_uri {
    default 0;
    ~*^/\.well-known/acme-challenge/ 0;
    ~*^/\. 1;
    ~*^/(?:phpmyadmin|pma|adminer|mysql|dbadmin|myadmin|sql|database)(?:/|$) 1;
    ~*^/(?:backup|backups|old|new|test|temp|tmp|bak|dev|staging)(?:/|$) 1;
    ~*(?:\.env|wp-config\.php|composer\.(?:json|lock)|package(?:-lock)?\.json|yarn\.lock|\.sql|\.bak|\.old|\.swp)$ 1;
    ~*vendor/phpunit 1;
    ~*eval-stdin\.php 1;
    ~*/(?:cgi-bin|boaform|HNAP1|_ignition|laravel|actuator|solr|jenkins|wp-admin/setup-config\.php) 1;
}
NGINX
  success "Nginx global hardening rules written."
}

configure_nginx_http() {
  info "Writing hardened Nginx HTTP vhost..."
  mkdir -p "$INSTALL_DIR"
  chown -R www-data:www-data "$INSTALL_DIR"

  local server_names="$DOMAIN"
  [[ "$ENABLE_WWW" -eq 1 ]] && server_names="$server_names www.$DOMAIN"

  local bot_filter_block=""
  if [[ "$ENABLE_BOT_FILTER" -eq 1 ]]; then
    bot_filter_block='    if ($wp_bad_bot) { return 444; }
    if ($wp_bad_uri) { return 444; }
    if ($args ~* "(^|&)author=[0-9]+") { return 444; }'
  fi

  local cache_directives=""
  if [[ "$ENABLE_FASTCGI_CACHE" -eq 1 ]]; then
    cache_directives='        fastcgi_cache wp_fastcgi_cache;
        fastcgi_cache_valid 200 10m;
        fastcgi_cache_valid 404 1m;
        fastcgi_cache_bypass $wp_skip_cache_method $wp_skip_cache_query $wp_skip_cache_cookie $wp_skip_cache_uri;
        fastcgi_no_cache $wp_skip_cache_method $wp_skip_cache_query $wp_skip_cache_cookie $wp_skip_cache_uri;
        add_header X-FastCGI-Cache $upstream_cache_status always;'
  fi

  local xmlrpc_location=""
  if [[ "$DISABLE_XMLRPC" -eq 1 ]]; then
    xmlrpc_location='    location = /xmlrpc.php {
        access_log /var/log/nginx/'"$DOMAIN"'.blocked.log wp_oneclick_ext;
        return 444;
    }'
  else
    xmlrpc_location='    location = /xmlrpc.php {
        limit_req zone=wp_login burst=2 nodelay;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php'"${PHP_VERSION}"'-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }'
  fi

  local comments_location=""
  if [[ "$DISABLE_COMMENTS" -eq 1 ]]; then
    comments_location='    location = /wp-comments-post.php {
        access_log /var/log/nginx/'"$DOMAIN"'.blocked.log wp_oneclick_ext;
        return 444;
    }'
  else
    comments_location='    location = /wp-comments-post.php {
        limit_req zone=wp_login burst=5 nodelay;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php'"${PHP_VERSION}"'-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }'
  fi

  local wpcron_location=""
  if [[ "$DISABLE_EXTERNAL_WPCRON" -eq 1 ]]; then
    wpcron_location='    location = /wp-cron.php {
        allow 127.0.0.1;
        allow ::1;
        deny all;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php'"${PHP_VERSION}"'-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }'
  else
    wpcron_location='    location = /wp-cron.php {
        limit_req zone=wp_php burst=5 nodelay;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php'"${PHP_VERSION}"'-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }'
  fi

  local hotlink_guard=""
  if [[ "$ENABLE_HOTLINK_GUARD" -eq 1 ]]; then
    hotlink_guard='        valid_referers none blocked server_names ~\.google\. ~\.bing\. ~\.baidu\. ~\.yandex\. ~\.duckduckgo\. ~\.sogou\. ~\.so\.com;
        if ($invalid_referer) { return 403; }'
  fi

  local static_rate=""
  if [[ "$ENABLE_STATIC_RATE_LIMIT" -eq 1 ]]; then
    static_rate='        limit_rate_after 2m;
        limit_rate 768k;'
  fi

  cat > "/etc/nginx/sites-available/$DOMAIN" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${server_names};

    root ${INSTALL_DIR};
    index index.php index.html index.htm;

    access_log /var/log/nginx/${DOMAIN}.access.log wp_oneclick_ext;
    error_log  /var/log/nginx/${DOMAIN}.error.log warn;

    client_max_body_size 128M;
    client_body_timeout 15s;
    client_header_timeout 15s;
    keepalive_timeout 20s;
    send_timeout 30s;
    reset_timedout_connection on;

    include /etc/nginx/snippets/wp-security-headers.conf;

${bot_filter_block}

    limit_conn wp_conn 30;
    limit_req zone=wp_global burst=80 nodelay;

    location ^~ /.well-known/acme-challenge/ {
        root ${INSTALL_DIR};
        allow all;
        access_log off;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    location ~* ^/wp-json/wp/v2/users {
        access_log /var/log/nginx/${DOMAIN}.blocked.log wp_oneclick_ext;
        return 444;
    }

    location ~* ^/(?:readme\.html|license\.txt|wp-config\.php|wp-config-sample\.php|xmlrpc\.php~)$ {
        access_log /var/log/nginx/${DOMAIN}.blocked.log wp_oneclick_ext;
        return 444;
    }

    location ~* /(?:uploads|files)/.*\.php$ {
        access_log /var/log/nginx/${DOMAIN}.blocked.log wp_oneclick_ext;
        return 444;
    }

    location ~* ^/wp-admin/(?:install|setup-config)\.php$ {
        access_log /var/log/nginx/${DOMAIN}.blocked.log wp_oneclick_ext;
        return 444;
    }

${xmlrpc_location}

${comments_location}

${wpcron_location}

    location = /wp-login.php {
        limit_req zone=wp_login burst=3 nodelay;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }

    location = /wp-admin/admin-ajax.php {
        limit_req zone=wp_ajax burst=40 nodelay;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        limit_req zone=wp_php burst=20 nodelay;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
${cache_directives}
    }

    location ~* \.(?:jpg|jpeg|gif|png|webp|avif|svg|ico|mp4|m4v|mov|webm|pdf|zip|rar|7z)$ {
${hotlink_guard}
        limit_req zone=wp_static burst=120 nodelay;
${static_rate}
        expires 30d;
        access_log off;
        log_not_found off;
        add_header Cache-Control "public, max-age=2592000, immutable";
        try_files \$uri =404;
    }

    location ~* \.(?:css|js|ttf|otf|woff|woff2)$ {
        limit_req zone=wp_static burst=180 nodelay;
        expires 30d;
        access_log off;
        log_not_found off;
        add_header Cache-Control "public, max-age=2592000, immutable";
        try_files \$uri =404;
    }

    location ~ /\. {
        access_log /var/log/nginx/${DOMAIN}.blocked.log wp_oneclick_ext;
        return 444;
    }
}
NGINX

  ln -sfn "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl reload nginx
  success "Nginx hardened HTTP vhost ready."
}

install_wordpress() {
  info "Downloading and installing WordPress..."
  mkdir -p "$INSTALL_DIR"
  chown -R www-data:www-data "$INSTALL_DIR"

  wp core download --path="$INSTALL_DIR" --locale="$LOCALE" --allow-root --force

  if [[ ! -f "$INSTALL_DIR/wp-config.php" ]]; then
    wp config create \
      --path="$INSTALL_DIR" \
      --dbname="$DB_NAME" \
      --dbuser="$DB_USER" \
      --dbpass="$DB_PASS" \
      --dbhost="localhost" \
      --dbcharset="utf8mb4" \
      --dbcollate="utf8mb4_unicode_ci" \
      --allow-root \
      --force
  fi

  local canonical_host="$DOMAIN"
  [[ "$CANONICAL" == "www" ]] && canonical_host="www.$DOMAIN"
  local url="http://$canonical_host"

  if ! wp core is-installed --path="$INSTALL_DIR" --allow-root >/dev/null 2>&1; then
    wp core install \
      --path="$INSTALL_DIR" \
      --url="$url" \
      --title="$SITE_TITLE" \
      --admin_user="$ADMIN_USER" \
      --admin_password="$ADMIN_PASS" \
      --admin_email="$ADMIN_EMAIL" \
      --skip-email \
      --allow-root
  else
    warn "WordPress already installed in $INSTALL_DIR. Skipping core install."
  fi

  wp option update permalink_structure '/%postname%/' --path="$INSTALL_DIR" --allow-root >/dev/null
  wp rewrite flush --path="$INSTALL_DIR" --allow-root >/dev/null || true

  # Basic wp-config hardening and performance constants.
  wp config set DISALLOW_FILE_EDIT true --raw --type=constant --path="$INSTALL_DIR" --allow-root >/dev/null || true
  wp config set WP_MEMORY_LIMIT '256M' --type=constant --path="$INSTALL_DIR" --allow-root >/dev/null || true
  wp config set WP_MAX_MEMORY_LIMIT '512M' --type=constant --path="$INSTALL_DIR" --allow-root >/dev/null || true
  wp config set FS_METHOD 'direct' --type=constant --path="$INSTALL_DIR" --allow-root >/dev/null || true
  wp config set WP_POST_REVISIONS 10 --raw --type=constant --path="$INSTALL_DIR" --allow-root >/dev/null || true
  wp config set AUTOSAVE_INTERVAL 120 --raw --type=constant --path="$INSTALL_DIR" --allow-root >/dev/null || true
  wp config set WP_AUTO_UPDATE_CORE 'minor' --type=constant --path="$INSTALL_DIR" --allow-root >/dev/null || true

  if [[ "$DISABLE_EXTERNAL_WPCRON" -eq 1 ]]; then
    wp config set DISABLE_WP_CRON true --raw --type=constant --path="$INSTALL_DIR" --allow-root >/dev/null || true
  fi

  if [[ "$DISABLE_COMMENTS" -eq 1 ]]; then
    wp option update default_comment_status closed --path="$INSTALL_DIR" --allow-root >/dev/null || true
    wp option update default_ping_status closed --path="$INSTALL_DIR" --allow-root >/dev/null || true
    wp option update close_comments_for_old_posts 1 --path="$INSTALL_DIR" --allow-root >/dev/null || true
  fi

  wp option update users_can_register 0 --path="$INSTALL_DIR" --allow-root >/dev/null || true
  wp option update blog_public 1 --path="$INSTALL_DIR" --allow-root >/dev/null || true

  rm -f "$INSTALL_DIR/readme.html" "$INSTALL_DIR/license.txt" "$INSTALL_DIR/wp-config-sample.php" || true
  mkdir -p "$INSTALL_DIR/wp-content/uploads"
  touch "$INSTALL_DIR/wp-content/uploads/index.php" "$INSTALL_DIR/wp-content/index.php" || true

  chown -R www-data:www-data "$INSTALL_DIR"
  find "$INSTALL_DIR" -type d -exec chmod 755 {} \;
  find "$INSTALL_DIR" -type f -exec chmod 644 {} \;
  chmod 640 "$INSTALL_DIR/wp-config.php"

  success "WordPress installed and hardened."
}

configure_redis_wordpress() {
  if [[ "$ENABLE_REDIS" -ne 1 ]]; then
    return 0
  fi

  info "Configuring Redis object cache for WordPress..."
  systemctl restart redis-server || true
  wp config set WP_CACHE true --raw --type=constant --path="$INSTALL_DIR" --allow-root >/dev/null || true
  wp config set WP_REDIS_HOST '127.0.0.1' --type=constant --path="$INSTALL_DIR" --allow-root >/dev/null || true
  wp config set WP_REDIS_PORT 6379 --raw --type=constant --path="$INSTALL_DIR" --allow-root >/dev/null || true
  wp plugin install redis-cache --activate --path="$INSTALL_DIR" --allow-root || true
  wp redis enable --path="$INSTALL_DIR" --allow-root || true
  chown -R www-data:www-data "$INSTALL_DIR/wp-content" || true
  success "Redis object cache configured."
}

configure_wp_cron_system() {
  if [[ "$DISABLE_EXTERNAL_WPCRON" -ne 1 ]]; then
    return 0
  fi
  info "Creating system cron for WordPress cron..."
  cat > "/etc/cron.d/wp-cron-$DOMAIN" <<CRON
# WordPress internal cron for $DOMAIN. External /wp-cron.php is blocked by Nginx.
*/10 * * * * www-data /usr/bin/php ${INSTALL_DIR}/wp-cron.php >/dev/null 2>&1
CRON
  chmod 644 "/etc/cron.d/wp-cron-$DOMAIN"
  success "System cron created: /etc/cron.d/wp-cron-$DOMAIN"
}

obtain_ssl() {
  if [[ "$ENABLE_SSL" -ne 1 ]]; then
    warn "SSL disabled by --no-ssl."
    return 0
  fi

  info "Requesting Let's Encrypt certificate..."
  local domains_args=( -d "$DOMAIN" )
  if [[ "$ENABLE_WWW" -eq 1 ]]; then
    domains_args+=( -d "www.$DOMAIN" )
  fi

  certbot --nginx \
    "${domains_args[@]}" \
    --non-interactive \
    --agree-tos \
    --email "$EMAIL" \
    --redirect \
    --keep-until-expiring

  local canonical_host="$DOMAIN"
  [[ "$CANONICAL" == "www" ]] && canonical_host="www.$DOMAIN"
  wp option update home "https://$canonical_host" --path="$INSTALL_DIR" --allow-root >/dev/null
  wp option update siteurl "https://$canonical_host" --path="$INSTALL_DIR" --allow-root >/dev/null
  wp search-replace "http://$canonical_host" "https://$canonical_host" --path="$INSTALL_DIR" --skip-columns=guid --all-tables-with-prefix --allow-root || true

  systemctl reload nginx
  certbot renew --dry-run || warn "Certbot dry-run failed. Certificate may still be installed, but check renew manually."
  success "HTTPS enabled for $canonical_host."
}

configure_fail2ban() {
  if [[ "$ENABLE_FAIL2BAN" -ne 1 ]]; then
    warn "Fail2ban config skipped by --no-fail2ban."
    return 0
  fi

  info "Configuring Fail2ban WordPress/Nginx anti-scan jails..."
  # Fail2ban requires these paths to exist even before the first scan request.
  touch "/var/log/nginx/${DOMAIN}.access.log" "/var/log/nginx/${DOMAIN}.blocked.log" "/var/log/nginx/${DOMAIN}.error.log"
  chmod 640 "/var/log/nginx/${DOMAIN}.access.log" "/var/log/nginx/${DOMAIN}.blocked.log" "/var/log/nginx/${DOMAIN}.error.log"
  cat > /etc/fail2ban/filter.d/wp-oneclick-scan.conf <<'FILTER'
[Definition]
failregex = ^<HOST> - .* "(?:GET|POST|HEAD) /(?:xmlrpc\.php|wp-login\.php|wp-comments-post\.php|wp-json/wp/v2/users|wp-admin/setup-config\.php|wp-admin/install\.php|\.env|wp-config\.php|readme\.html|license\.txt|phpmyadmin|pma|adminer|vendor/phpunit|cgi-bin|HNAP1|_ignition).*" (?:200|301|302|400|401|403|404|429|444) .*$
            ^<HOST> - .* "(?:GET|POST|HEAD) /.*(?:author=[0-9]+|\.sql|\.bak|\.old|\.swp).*" (?:200|301|302|400|401|403|404|429|444) .*$
ignoreregex =
FILTER

  cat > /etc/fail2ban/jail.d/wp-oneclick.conf <<JAIL
[wp-oneclick-scan]
enabled = true
filter = wp-oneclick-scan
port = http,https
logpath = /var/log/nginx/${DOMAIN}.access.log
          /var/log/nginx/${DOMAIN}.blocked.log
maxretry = 8
findtime = 600
bantime = 86400
action = %(action_mwl)s

[nginx-limit-req]
enabled = true
port = http,https
filter = nginx-limit-req
logpath = /var/log/nginx/${DOMAIN}.error.log
maxretry = 20
findtime = 600
bantime = 86400
action = %(action_mwl)s
JAIL

  systemctl enable --now fail2ban
  systemctl restart fail2ban
  fail2ban-client status || true
  success "Fail2ban configured."
}

create_backup_script() {
  info "Creating v3 automatic portable backup schedule..."
  cat > "/etc/cron.d/wp-backup-$DOMAIN" <<CRON
# v3 daily portable backup, retention 14 days. Store copies off this VPS!
17 3 * * * root /usr/local/bin/wpctl backup --retention 14 >>/var/log/wp-oneclick/backup-$DOMAIN.log 2>&1
CRON
  chmod 644 "/etc/cron.d/wp-backup-$DOMAIN"
  success "Backup cron ready: /etc/cron.d/wp-backup-$DOMAIN"
}

create_traffic_tool() {
  info "Creating traffic analysis helper..."
  local helper="/usr/local/sbin/wp-traffic-$DOMAIN.sh"
  cat > "$helper" <<TRAFFIC
#!/usr/bin/env bash
set -Eeuo pipefail
LOG="/var/log/nginx/${DOMAIN}.access.log"
BLOCKED="/var/log/nginx/${DOMAIN}.blocked.log"
ERR="/var/log/nginx/${DOMAIN}.error.log"

echo "======================================================================"
echo " WordPress Traffic Report: ${DOMAIN}"
echo " Generated: \$(date -Is)"
echo "======================================================================"

if [[ -f "\$LOG" ]]; then
  echo
  echo "Top IPs:"
  awk '{print \$1}' "\$LOG" | sort | uniq -c | sort -nr | head -20 || true

  echo
  echo "Top URLs:"
  awk -F'"' '{print \$2}' "\$LOG" | awk '{print \$2}' | sort | uniq -c | sort -nr | head -30 || true

  echo
  echo "Top User-Agents:"
  awk -F'"' '{print \$6}' "\$LOG" | sed 's/^\$/EMPTY-UA/' | sort | uniq -c | sort -nr | head -20 || true

  echo
  echo "Top status codes:"
  awk '{print \$9}' "\$LOG" | sort | uniq -c | sort -nr | head -20 || true
fi

if [[ -f "\$BLOCKED" ]]; then
  echo
  echo "Blocked requests by IP:"
  awk '{print \$1}' "\$BLOCKED" | sort | uniq -c | sort -nr | head -20 || true
fi

if [[ -f "\$ERR" ]]; then
  echo
  echo "Recent Nginx rate-limit events:"
  grep -i "limiting requests" "\$ERR" | tail -30 || true
fi

echo
command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client status wp-oneclick-scan 2>/dev/null || true
TRAFFIC
  chmod +x "$helper"
  ln -sfn "$helper" "/usr/local/bin/wptraffic-$DOMAIN"
  success "Traffic helper created: $helper"
}

write_summary() {
  local scheme="http"
  [[ "$ENABLE_SSL" -eq 1 ]] && scheme="https"
  local canonical_host="$DOMAIN"
  [[ "$CANONICAL" == "www" ]] && canonical_host="www.$DOMAIN"

  local summary_file="/root/wp-oneclick-$DOMAIN.txt"
  cat > "$summary_file" <<SUMMARY
WordPress One-Click Install Summary
Generated: $(date -Is)
Script version: $SCRIPT_VERSION

Site URL:      ${scheme}://${canonical_host}
Admin URL:     ${scheme}://${canonical_host}/wp-admin/
Install dir:   ${INSTALL_DIR}
Nginx config:  /etc/nginx/sites-available/${DOMAIN}
Nginx global:  /etc/nginx/conf.d/wp-oneclick-hardening.conf
Log file:      ${LOG_FILE}

WordPress admin user:     ${ADMIN_USER}
WordPress admin password: ${ADMIN_PASS}
WordPress admin email:    ${ADMIN_EMAIL}

Database name: ${DB_NAME}
Database user: ${DB_USER}
Database pass: ${DB_PASS}

Security mode:             ${SECURITY_MODE}
Bot filter enabled:        ${ENABLE_BOT_FILTER}
XML-RPC disabled:          ${DISABLE_XMLRPC}
Comments disabled:         ${DISABLE_COMMENTS}
External wp-cron disabled: ${DISABLE_EXTERNAL_WPCRON}
FastCGI cache enabled:     ${ENABLE_FASTCGI_CACHE}
Hotlink guard enabled:     ${ENABLE_HOTLINK_GUARD}
Static rate limit enabled: ${ENABLE_STATIC_RATE_LIMIT}
Fail2ban enabled:          ${ENABLE_FAIL2BAN}

Backup command: wpctl backup
Restore:        wpctl restore --archive FILE --yes
Manager:        wpctl (or wpmenu)
Backup cron:    /etc/cron.d/wp-backup-${DOMAIN}
Backup dir:     /root/wp-backups/${DOMAIN}
Traffic helper: /usr/local/sbin/wp-traffic-${DOMAIN}.sh
Traffic alias:  wptraffic-${DOMAIN}

Useful commands:
  nginx -t && systemctl reload nginx
  systemctl status nginx php${PHP_VERSION}-fpm mariadb fail2ban
  certbot certificates
  certbot renew --dry-run
  fail2ban-client status
  fail2ban-client status wp-oneclick-scan
  /usr/local/sbin/wp-traffic-${DOMAIN}.sh
  wp core update --path=${INSTALL_DIR} --allow-root
  wp plugin update --all --path=${INSTALL_DIR} --allow-root
  wp theme update --all --path=${INSTALL_DIR} --allow-root
  wpctl cache-clear
  wpctl backup
  wpctl status
SUMMARY
  chmod 600 "$summary_file"

  echo
  success "Installation completed."
  echo -e "${GREEN}Site:${NC}      ${scheme}://${canonical_host}"
  echo -e "${GREEN}Admin:${NC}     ${scheme}://${canonical_host}/wp-admin/"
  echo -e "${GREEN}User:${NC}      ${ADMIN_USER}"
  echo -e "${GREEN}Password:${NC}  saved in the root-only summary file"
  echo -e "${GREEN}Summary:${NC}   ${summary_file}"
  echo -e "${GREEN}Log:${NC}       ${LOG_FILE}"
  echo -e "${GREEN}Manager:${NC}   wpctl   (or wpmenu)"
  echo -e "${GREEN}Backup:${NC}    wpctl backup"
  echo
  warn "Please save the admin/database passwords from: $summary_file"
  warn "v3 strict mode blocks XML-RPC, comments, REST user enumeration, and external WP-Cron. Adjust if integrations require them."
}

main() {
  parse_args "$@"
  apply_security_mode
  require_root
  check_os
  prompt_if_needed
  install_base_packages
  configure_ufw
  check_dns
  backup_existing
  secure_mariadb_minimal
  create_database
  install_wp_cli
  configure_php
  write_security_headers
  write_nginx_global_hardening
  configure_nginx_http
  install_wordpress
  configure_redis_wordpress
  configure_wp_cron_system
  configure_fail2ban
  install_manager
  # Record a usable HTTP manager state before certificate provisioning, so a
  # failed DNS/Let's Encrypt validation can later be repaired with `wpctl ssl`.
  local requested_ssl="$ENABLE_SSL"
  ENABLE_SSL=0
  save_site_config
  ENABLE_SSL="$requested_ssl"
  create_backup_script
  create_traffic_tool
  obtain_ssl
  save_site_config
  write_summary
}

# ================================================================
# WordPress OneClick v3: self-contained operations / manager
# ================================================================
OPS_CONFIG="/etc/wp-oneclick/site.conf"
OPS_MANAGER="/usr/local/libexec/wp-oneclick/wp_ubuntu24_pro_v3.sh"
ADOPT_EXISTING="${ADOPT_EXISTING:-0}"

install_manager() {
  local source_script
  source_script="$(readlink -f "${BASH_SOURCE[0]}")"
  mkdir -p /usr/local/libexec/wp-oneclick /etc/wp-oneclick
  [[ -f "$source_script" ]] || fatal "Cannot locate v3 installer source"
  [[ "$source_script" == "$OPS_MANAGER" ]] || install -m 0755 "$source_script" "$OPS_MANAGER"
  cat > /usr/local/bin/wpctl <<'WRAPPER'
#!/usr/bin/env bash
exec /usr/local/libexec/wp-oneclick/wp_ubuntu24_pro_v3.sh __wpctl "$@"
WRAPPER
  chmod 755 /usr/local/bin/wpctl
  ln -sfn /usr/local/bin/wpctl /usr/local/bin/wpmenu
  success "Manager: wpctl and wpmenu (WP-CLI still uses 'wp')"
}

save_site_config() {
  [[ -n "$DOMAIN" && -n "$INSTALL_DIR" ]] || fatal "Missing site configuration"
  mkdir -p /etc/wp-oneclick
  umask 077
  {
    printf 'DOMAIN=%q\n' "$DOMAIN"
    printf 'INSTALL_DIR=%q\n' "$INSTALL_DIR"
    printf 'DB_NAME=%q\n' "$DB_NAME"
    printf 'DB_USER=%q\n' "$DB_USER"
    printf 'CANONICAL=%q\n' "$CANONICAL"
    printf 'ENABLE_WWW=%q\n' "$ENABLE_WWW"
    printf 'ENABLE_SSL=%q\n' "$ENABLE_SSL"
    printf 'EMAIL=%q\n' "$EMAIL"
  } > "$OPS_CONFIG"
  chmod 600 "$OPS_CONFIG"
}

ops_load_config() {
  [[ -f "$OPS_CONFIG" ]] || fatal "No configured site. Install v3 or use --adopt-existing"
  [[ "$(stat -c %u "$OPS_CONFIG")" == 0 ]] || fatal "site.conf must be owned by root"
  [[ "$(stat -c %a "$OPS_CONFIG")" == 600 ]] || fatal "site.conf must have mode 600"
  # shellcheck disable=SC1090
  source "$OPS_CONFIG"
  valid_domain "$DOMAIN" || fatal "Invalid configured domain"
  [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || fatal "Invalid configured DB_NAME"
  [[ "$INSTALL_DIR" == /* && "$INSTALL_DIR" != / && "$INSTALL_DIR" != /var/www ]] || fatal "Unsafe install path"
  [[ "$CANONICAL" == apex || "$CANONICAL" == www ]] || fatal "Invalid canonical setting"
  OPS_BACKUPS="/root/wp-backups/$DOMAIN"
  umask 077
}

ops_url() {
  local scheme="https" host="$DOMAIN"
  [[ "${ENABLE_SSL:-1}" == 0 ]] && scheme="http"
  [[ "$CANONICAL" == www ]] && host="www.$DOMAIN"
  printf '%s://%s' "$scheme" "$host"
}
ops_wp() { wp --path="$INSTALL_DIR" --allow-root "$@"; }
ops_require_software() {
  for cmd in wp mariadb mariadb-dump tar zstd sha256sum python3 gzip rsync flock; do
    command -v "$cmd" >/dev/null 2>&1 || fatal "Missing dependency: $cmd"
  done
}

ops_backup() {
  ops_load_config
  ops_require_software
  local online=0 out="" retention=14
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --online) online=1; shift ;;
      --output) [[ $# -ge 2 ]] || fatal "--output needs a file"; out="$2"; shift 2 ;;
      --retention) [[ $# -ge 2 ]] || fatal "--retention needs days"; retention="$2"; shift 2 ;;
      *) fatal "Unknown backup option: $1" ;;
    esac
  done
  [[ "$retention" =~ ^[0-9]{1,4}$ ]] || fatal "Retention must be integer days"
  [[ -f "$INSTALL_DIR/wp-config.php" ]] || fatal "WordPress wp-config.php missing"
  mkdir -p "$OPS_BACKUPS"; chmod 700 "$OPS_BACKUPS"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  [[ -n "$out" ]] || out="$OPS_BACKUPS/wpbackup-$DOMAIN-$stamp.tar.zst"
  [[ "$out" == /* && "$out" == *.tar.zst ]] || fatal "Output must be an absolute .tar.zst path"
  [[ ! -e "$out" && ! -e "$out.partial" ]] || fatal "Backup file already exists: $out"
  mkdir -p "$(dirname "$out")"

  (
    flock -n 9 || fatal "Another wpctl backup/restore is running"
    local tmp activated=0 prefix source_url
    tmp="$(mktemp -d "$OPS_BACKUPS/.stage.XXXXXXXX")"
    backup_cleanup() {
      local rc=$?
      if [[ "$activated" == 1 ]]; then ops_wp maintenance-mode deactivate >/dev/null 2>&1 || true; fi
      rm -rf -- "$tmp"
      if [[ "$rc" -ne 0 ]]; then rm -f -- "$out.partial"; fi
      return "$rc"
    }
    trap backup_cleanup EXIT

    if [[ "$online" == 0 ]]; then
      if ops_wp maintenance-mode is-active >/dev/null 2>&1; then
        warn "Site was already in maintenance mode; it will remain enabled"
      else
        ops_wp maintenance-mode activate >/dev/null
        activated=1
      fi
    fi
    prefix="$(ops_wp db prefix)"
    [[ "$prefix" =~ ^[A-Za-z0-9_]+$ ]] || fatal "Unsupported table prefix"
    source_url="$(ops_wp option get home)"
    [[ "$source_url" =~ ^https?://[A-Za-z0-9.-]+/?$ ]] || fatal "Unexpected WordPress home URL"
    info "Exporting database $DB_NAME ..."
    mariadb-dump --single-transaction --quick --routines --triggers --events \
      --default-character-set=utf8mb4 "$DB_NAME" | gzip -1 > "$tmp/database.sql.gz"
    gzip -t "$tmp/database.sql.gz"
    info "Compressing WordPress site ..."
    if [[ -n "$(find "$INSTALL_DIR" -type l -print -quit)" ]]; then
      fatal "Site has symlinks; portable backup requires real files (no symlinks)"
    fi
    tar -C "$INSTALL_DIR" \
      --exclude='./.maintenance' --exclude='./wp-content/cache' \
      --exclude='./wp-content/uploads/cache' --exclude='./wp-content/updraft' \
      --exclude='./wp-content/backup*' \
      -I 'zstd -6 -T0' -cf "$tmp/site.tar.zst" .
    zstd -tq "$tmp/site.tar.zst"
    cat > "$tmp/manifest.txt" <<MANIFEST
format=wp-oneclick-v3
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
source_domain=$DOMAIN
source_url=$source_url
table_prefix=$prefix
source_php=$PHP_VERSION
source_path=$INSTALL_DIR
MANIFEST
    if [[ -f "/etc/nginx/sites-available/$DOMAIN" ]]; then
      cp -a "/etc/nginx/sites-available/$DOMAIN" "$tmp/nginx.conf"
    else
      : > "$tmp/nginx.conf"
    fi
    ( cd "$tmp" && sha256sum manifest.txt database.sql.gz site.tar.zst nginx.conf > sha256sums.txt )
    info "Writing portable archive..."
    tar -C "$tmp" -I 'zstd -6 -T0' -cf "$out.partial" \
      manifest.txt database.sql.gz site.tar.zst nginx.conf sha256sums.txt
    chmod 600 "$out.partial"
    mv -- "$out.partial" "$out"
    ( cd "$(dirname "$out")" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )
    chmod 600 "$out.sha256"
    success "Backup complete: $out ($(du -h "$out" | cut -f1))"
    warn "Copy this archive OFF the VPS. Local-only backups cannot survive provider shutdown."
    if [[ "$retention" -gt 0 ]]; then
      find "$OPS_BACKUPS" -maxdepth 1 -type f -name "wpbackup-$DOMAIN-*.tar.zst" -mtime "+$retention" -print0 |
      while IFS= read -r -d '' old; do rm -f -- "$old" "$old.sha256"; done
    fi
  ) 9>"/run/wpctl-$DOMAIN.lock"
}

ops_check_safe_inner_tar() {
  # Validate names and file types before extraction: no symlinks, devices or ../ paths.
  zstd -dc "$1" | python3 -c '
import sys, tarfile, pathlib
with tarfile.open(fileobj=sys.stdin.buffer, mode="r|*") as tf:
    count=0
    for m in tf:
        count += 1
        p=pathlib.PurePosixPath(m.name)
        if not m.name or p.is_absolute() or ".." in p.parts or not (m.isfile() or m.isdir()):
            sys.exit("UNSAFE archive entry: "+repr(m.name))
        if count > 2000000:
            sys.exit("Too many archived files")
'
}

ops_extract_verified() {
  local archive="$1" stage="$2" fmt
  [[ -s "$archive" ]] || fatal "Archive missing or empty: $archive"
  zstd -tq "$archive" || fatal "Invalid outer zstd stream"
  if [[ -f "$archive.sha256" ]]; then
    (cd "$(dirname "$archive")" && sha256sum -c "$(basename "$archive").sha256") || fatal "Archive checksum mismatch"
  fi
  # Outer package may contain only 5 well-known regular files.
  zstd -dc "$archive" | python3 -c '
import sys,tarfile
allowed={"manifest.txt","database.sql.gz","site.tar.zst","nginx.conf","sha256sums.txt"}
with tarfile.open(fileobj=sys.stdin.buffer, mode="r|*") as tf:
    found=set()
    for m in tf:
        if m.name not in allowed or not m.isfile() or m.name in found:
            sys.exit("UNSAFE outer archive member: "+repr(m.name))
        found.add(m.name)
    if found != allowed:
        sys.exit("Missing archive files: "+repr(allowed-found))
' || fatal "Malformed or unsafe outer backup archive"
  mkdir -p "$stage/pkg"
  tar -C "$stage/pkg" -I zstd --no-same-owner --no-same-permissions -xf "$archive"
  ( cd "$stage/pkg" && sha256sum -c sha256sums.txt ) || fatal "Backup internal checksums failed"
  gzip -t "$stage/pkg/database.sql.gz" || fatal "Corrupt database gzip"
  zstd -tq "$stage/pkg/site.tar.zst" || fatal "Corrupt WordPress file archive"
  ops_check_safe_inner_tar "$stage/pkg/site.tar.zst" || fatal "Unsafe site archive"
  fmt="$(sed -n 's/^format=//p' "$stage/pkg/manifest.txt" | head -n1)"
  [[ "$fmt" == wp-oneclick-v3 ]] || fatal "Unsupported archive format: $fmt"
}

ops_verify() {
  local archive=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --archive) [[ $# -ge 2 ]] || fatal "--archive needs a file"; archive="$2"; shift 2 ;;
      *) fatal "Unknown verify option $1" ;;
    esac
  done
  [[ -n "$archive" ]] || fatal "Usage: wpctl verify --archive FILE"
  local stage
  stage="$(mktemp -d /tmp/wpctl-verify.XXXXXXXX)"
  # Subshell ensures cleanup even when checksum verification exits with an error.
  (
    trap 'rm -rf -- "$stage"' EXIT
    ops_extract_verified "$archive" "$stage"
    success "Verified: $archive"
    cat "$stage/pkg/manifest.txt"
  )
}

ops_restore() {
  ops_load_config
  ops_require_software
  local archive="" yes=0 target_domain="$DOMAIN" canonical="$CANONICAL"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --archive) [[ $# -ge 2 ]] || fatal "--archive needs a file"; archive="$2"; shift 2 ;;
      --target-domain) [[ $# -ge 2 ]] || fatal "--target-domain needs a domain"; target_domain="$2"; shift 2 ;;
      --canonical) [[ $# -ge 2 ]] || fatal "--canonical needs apex|www"; canonical="$2"; shift 2 ;;
      --yes) yes=1; shift ;;
      *) fatal "Unknown restore option $1" ;;
    esac
  done
  [[ -n "$archive" ]] || fatal "Usage: wpctl restore --archive FILE --yes"
  [[ "$target_domain" == "$DOMAIN" ]] || fatal "Target domain must match installed site $DOMAIN; install v3 for target domain first"
  [[ "$canonical" == apex || "$canonical" == www ]] || fatal "--canonical must be apex|www"
  [[ "$canonical" != www || "$ENABLE_WWW" == 1 ]] || fatal "www canonical requires --www at installation"
  [[ "$yes" == 1 ]] || fatal "Restore OVERWRITES files and DB. Re-run with --yes to confirm"
  [[ -f "$INSTALL_DIR/wp-config.php" ]] || fatal "Install v3 on target VPS before restore (use --no-ssl before DNS cutover)"
  local stage stamp source_url prefix canonical_host target_url pre_restore
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$OPS_BACKUPS"; chmod 700 "$OPS_BACKUPS"
  stage="$(mktemp -d "$OPS_BACKUPS/.restore.XXXXXXXX")"
  (
    trap 'rm -rf -- "$stage"' EXIT
    info "Verifying archive BEFORE any changes..."
    ops_extract_verified "$archive" "$stage"
    source_url="$(sed -n 's/^source_url=//p' "$stage/pkg/manifest.txt" | head -n1)"
    prefix="$(sed -n 's/^table_prefix=//p' "$stage/pkg/manifest.txt" | head -n1)"
    [[ "$source_url" =~ ^https?://[A-Za-z0-9.-]+/?$ ]] || fatal "Unsafe source URL"
    [[ "$prefix" =~ ^[A-Za-z0-9_]+$ ]] || fatal "Unsafe source DB table prefix"
    canonical_host="$DOMAIN"
    [[ "$canonical" == www ]] && canonical_host="www.$DOMAIN"
    target_url="https://$canonical_host"
    [[ "$ENABLE_SSL" == 0 ]] && target_url="http://$canonical_host"
    info "Source: $source_url  Target: $target_url"
    warn "Existing files and MariaDB database will be replaced"

    # Make an independent pre-restore snapshot; the user can restore it if needed.
    pre_restore="$OPS_BACKUPS/pre-restore-$DOMAIN-$stamp.tar.zst"
    info "Saving mandatory pre-restore rollback archive..."
    ops_backup --online --output "$pre_restore" --retention 0
    info "Rollback archive: $pre_restore"

    (
      flock -n 9 || fatal "Another backup/restore operation is active"
      mkdir -p "$stage/site"
      tar -C "$stage/site" -I zstd --no-same-owner --no-same-permissions -xf "$stage/pkg/site.tar.zst"
      [[ -f "$stage/site/wp-settings.php" ]] || fatal "Missing wp-settings.php in backup"

      # Stop serving dynamic requests during the destructive SQL/file phase.
      # PHP CLI remains available for wp-cli. Always re-start FPM, even on failure.
      systemctl stop "php${PHP_VERSION}-fpm"
      trap 'systemctl start "php${PHP_VERSION}-fpm" >/dev/null 2>&1 || true' EXIT
      info "Restoring files, preserving target wp-config.php DB credentials..."
      rsync -a --delete --exclude='/wp-config.php' "$stage/site/" "$INSTALL_DIR/"
      chown -R www-data:www-data "$INSTALL_DIR"
      find "$INSTALL_DIR" -type d -exec chmod 755 {} +
      find "$INSTALL_DIR" -type f -exec chmod 644 {} +
      chmod 640 "$INSTALL_DIR/wp-config.php"

      info "Recreating target MariaDB database..."
      mariadb -uroot -e "DROP DATABASE IF EXISTS \`$DB_NAME\`; CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
      gzip -dc "$stage/pkg/database.sql.gz" | mariadb -uroot "$DB_NAME"

      # WordPress table prefix can differ between source and target VPS.
      ops_wp config set table_prefix "$prefix" --type=variable >/dev/null
      info "Rewriting original site URL using serialized-data-safe WP-CLI..."
      local source_base old_candidate
      source_base="$(sed -n 's/^source_domain=//p' "$stage/pkg/manifest.txt" | head -n1)"
      valid_domain "$source_base" || fatal "Unsafe original site domain in manifest"
      # Replace all four plausible combinations (www/apex and http/https) in
      # serialized-safe WP-CLI, preserving GUIDs. Also cover changed domains.
      for old_candidate in           "https://www.$source_base" "http://www.$source_base"           "https://$source_base" "http://$source_base"; do
        if [[ "$old_candidate" != "$target_url" ]]; then
          ops_wp search-replace "$old_candidate" "$target_url"             --skip-columns=guid --all-tables-with-prefix
        fi
      done
      ops_wp option update home "$target_url" >/dev/null
      ops_wp option update siteurl "$target_url" >/dev/null
      ops_wp rewrite flush >/dev/null || true
      ops_wp cache flush >/dev/null || true
      CANONICAL="$canonical"
      save_site_config
      ops_cache_clear
      systemctl restart "php${PHP_VERSION}-fpm" || true
      nginx -t && systemctl reload nginx
      success "Restore finished: $target_url"
      warn "Check custom wp-config.php settings: old-server custom defines were not transplanted"
      warn "If this is a new VPS, update DNS, then run 'wpctl ssl' to issue certificates"
    ) 9>"/run/wpctl-$DOMAIN.lock"
  )
}

ops_backups() {
  ops_load_config
  mkdir -p "$OPS_BACKUPS"
  printf 'Portable backup archives at %s:\n' "$OPS_BACKUPS"
  find "$OPS_BACKUPS" -maxdepth 1 -type f -name '*.tar.zst' -printf '%TY-%Tm-%Td %TH:%TM  %10s bytes  %p\n' | sort -r || true
}

ops_cache_clear() {
  if [[ -d /var/cache/nginx/wp-fastcgi ]]; then
    find /var/cache/nginx/wp-fastcgi -type f -delete
  fi
  if command -v wp >/dev/null 2>&1 && [[ -f "$INSTALL_DIR/wp-config.php" ]]; then
    ops_wp cache flush >/dev/null 2>&1 || true
  fi
  success "FastCGI and WordPress object cache cleared"
}

ops_status() {
  ops_load_config
  printf '\nWordPress OneClick v3 | %s\n' "$DOMAIN"
  printf 'Site URL:     %s\n' "$(ops_url)"
  printf 'Web root:     %s\n' "$INSTALL_DIR"
  printf 'Backup dir:   %s\n' "$OPS_BACKUPS"
  printf 'Manager:      /usr/local/bin/wpctl\n'
  for service in nginx php8.3-fpm mariadb redis-server fail2ban; do
    printf '%-14s %s\n' "$service" "$(systemctl is-active "$service" 2>/dev/null || true)"
  done
  nginx -t 2>&1 || true
  if command -v certbot >/dev/null; then certbot certificates 2>/dev/null || true; fi
  if command -v wp >/dev/null && [[ -f "$INSTALL_DIR/wp-config.php" ]]; then
    printf 'WP version: '; ops_wp core version 2>/dev/null || true
    printf 'WP home:    '; ops_wp option get home 2>/dev/null || true
  fi
}

ops_ssl() {
  ops_load_config
  [[ -n "$EMAIL" ]] || fatal "SSL email missing in site.conf"
  command -v certbot >/dev/null || fatal "Certbot not installed"
  local args=(-d "$DOMAIN") host="$DOMAIN" old_url
  [[ "$ENABLE_WWW" == 1 ]] && args+=(-d "www.$DOMAIN")
  [[ "$CANONICAL" == www ]] && host="www.$DOMAIN"
  old_url="$(ops_wp option get home)"
  info "Requesting SSL. DNS A records must already resolve to this VPS..."
  certbot --nginx "${args[@]}" --non-interactive --agree-tos \
    --email "$EMAIL" --redirect --keep-until-expiring
  if [[ "$old_url" == "http://$host" ]]; then
    ops_wp search-replace "$old_url" "https://$host" --skip-columns=guid --all-tables-with-prefix || true
  fi
  ops_wp option update home "https://$host" >/dev/null
  ops_wp option update siteurl "https://$host" >/dev/null
  ENABLE_SSL=1
  save_site_config
  nginx -t && systemctl reload nginx
  success "HTTPS configured: https://$host"
}

ops_menu() {
  local choice archive
  while :; do
    cat <<'MENU'

==============================================================
 WordPress OneClick v3 | wpctl interactive manager
==============================================================
 1) Status / services
 2) Make portable backup now
 3) List local backups
 4) Verify a backup archive
 5) Restore/migrate from backup (overwrites current site)
 6) Issue / expand HTTPS certificate
 7) Clear Nginx / WP caches
 8) Show traffic report (if installed)
 9) Exit
==============================================================
MENU
    read -rp 'Select [1-9]: ' choice || return 0
    case "$choice" in
      1) ops_status ;;
      2) ops_backup ;;
      3) ops_backups ;;
      4) read -rp 'Absolute archive path: ' archive; ops_verify --archive "$archive" ;;
      5) read -rp 'Absolute archive path: ' archive
         echo 'WARNING: Current WordPress FILES and DATABASE will be replaced!'
         read -rp 'Type RESTORE to continue: ' choice
         if [[ "$choice" == RESTORE ]]; then ops_restore --archive "$archive" --yes; else warn 'Cancelled'; fi ;;
      6) ops_ssl ;;
      7) ops_load_config; ops_cache_clear ;;
      8) ops_load_config; if [[ -x "/usr/local/sbin/wp-traffic-$DOMAIN.sh" ]]; then "/usr/local/sbin/wp-traffic-$DOMAIN.sh"; else warn 'Traffic helper missing'; fi ;;
      9) return 0 ;;
      *) warn 'Select 1 through 9' ;;
    esac
  done
}

ops_main() {
  require_root
  local action="${1:-menu}"
  [[ $# -eq 0 ]] || shift
  case "$action" in
    menu) ops_menu ;;
    status) ops_status ;;
    backup) ops_backup "$@" ;;
    backups|list-backups) ops_backups ;;
    verify) ops_verify "$@" ;;
    restore|migrate) ops_restore "$@" ;;
    ssl) ops_ssl ;;
    cache-clear) ops_load_config; ops_cache_clear ;;
    help|-h|--help) cat <<'HELP'
wpctl                      Open interactive manager
wpctl status               Website and services
wpctl backup               Portable compressed WordPress backup
wpctl backup --online      No maintenance banner (lower consistency)
wpctl backups              List backups stored on this VPS
wpctl verify --archive F   Verify portable backup checksums
wpctl restore --archive F --yes [--canonical apex|www]
wpctl ssl                  Issue/expand HTTPS after DNS cutover
wpctl cache-clear          Clear Nginx FastCGI and WP object cache
HELP
      ;;
    *) fatal "Unknown wpctl command: $action. Run wpctl help" ;;
  esac
}

adopt_existing_site() {
  require_root
  check_os
  [[ -n "$DOMAIN" ]] || fatal "Use --adopt-existing --domain example.com"
  valid_domain "$DOMAIN" || fatal "Invalid --domain"
  [[ -f "$INSTALL_DIR/wp-config.php" ]] || fatal "Missing existing WP config: $INSTALL_DIR/wp-config.php"
  command -v wp >/dev/null || fatal "WP-CLI is required"
  DB_NAME="$(wp config get DB_NAME --path="$INSTALL_DIR" --allow-root)"
  DB_USER="$(wp config get DB_USER --path="$INSTALL_DIR" --allow-root)"
  [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ && "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || fatal "Unsupported DB name/user"
  local url
  url="$(wp option get home --path="$INSTALL_DIR" --allow-root)"
  if [[ "$url" == "https://www.$DOMAIN" || "$url" == "http://www.$DOMAIN" ]]; then
    CANONICAL=www; ENABLE_WWW=1
  else
    CANONICAL=apex
    [[ "$url" == "https://$DOMAIN" || "$url" == "http://$DOMAIN" ]] || warn "WordPress home URL differs: $url"
  fi
  [[ "$url" == https://* ]] && ENABLE_SSL=1 || ENABLE_SSL=0
  [[ -n "$EMAIL" ]] || EMAIL="$(wp option get admin_email --path="$INSTALL_DIR" --allow-root)"
  valid_email "$EMAIL" || fatal "Valid --email is needed for SSL management"
  install_manager
  save_site_config
  create_backup_script
  success "Existing WordPress v2 site registered. Run: wpctl"
  warn "No WordPress files, database, or Nginx rules were overwritten by adoption"
}

# One single .sh file acts as installer and later as wpctl operations engine.
if [[ "${1:-}" == "__wpctl" ]]; then
  shift
  ops_main "$@"
elif [[ " ${*:-} " == *" --adopt-existing "* ]]; then
  parse_args "$@"
  adopt_existing_site
else
  main "$@"
fi
