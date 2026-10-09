#!/usr/bin/env bash
# Harden one WordPress document root on Plesk using separate runtime/deploy users.
# ACLs are required; unsupported ACLs fail closed instead of enabling group writes.
#
# © 2025 Reliable Penguin, Inc. All rights reserved.
# May be used and modified for your own hosting environments.
# Redistribution requires attribution to Reliable Penguin.

set -Eeuo pipefail
umask 022
WRITABLE_DIRS=("wp-content/uploads" "wp-content/cache")
VHOSTROOT=""
DOMAIN=""
RUNTIME_USER=""
DEPLOY_USER=""
PSA_GROUP="psacln"
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage:
  sudo bash wp_two_user_setup.sh [OPTIONS]
Required:
  -r, --runtime-user USER     Plesk subscription system user (runs PHP-FPM)
  -o, --deploy-user USER      Separate deploy user that owns the code
Target (choose one):
  -p, --domain DOMAIN         Uses /var/www/vhosts/DOMAIN/httpdocs
      --vhostroot PATH        Absolute document-root path below /var/www/vhosts
Optional:
  -w, --writable "DIRS"       Space-separated paths relative to the document root
                              (default: wp-content/uploads wp-content/cache)
  --dry-run                   Print planned commands without changing the system
  -h, --help                  Show this help and exit
USAGE
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}
get_home_dir() { getent passwd "$1" | awk -F: 'NR == 1 { print $6 }'; }
valid_user_name() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}
test_acl_on_path() {
  local path="$1" probe
  probe="$(mktemp -d -- "$path/.wp-two-user-acl-test.XXXXXX")" ||
    die "Cannot create an ACL preflight directory under $path"
  if ! setfacl -m "u:$RUNTIME_USER:rx" "$probe" ||
     ! setfacl -m "d:u:$RUNTIME_USER:rwX" "$probe"; then
    rm -rf -- "$probe" || true
    die "ACL preflight failed on $path. No ownership or permission changes were applied. Check filesystem/mount ACL support."
  fi
  rm -rf -- "$probe"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--domain) [[ $# -ge 2 ]] || die "Missing value for $1"; DOMAIN="$2"; shift 2 ;;
    -r|--runtime-user) [[ $# -ge 2 ]] || die "Missing value for $1"; RUNTIME_USER="$2"; shift 2 ;;
    -o|--owner-user|--deploy-user) [[ $# -ge 2 ]] || die "Missing value for $1"; DEPLOY_USER="$2"; shift 2 ;;
    -w|--writable) [[ $# -ge 2 ]] || die "Missing value for $1"; IFS=' ' read -r -a WRITABLE_DIRS <<< "$2"; shift 2 ;;
    -vhostroot|--vhost-root) [[ $# -ge 2 ]] || die "Missing value for $1"; VHOSTROOT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || die "Run as root"
[[ -n "$RUNTIME_USER" ]] || die "Missing -r/--runtime-user"
[[ -n "$DEPLOY_USER" ]] || die "Missing -o/--deploy-user"
valid_user_name "$RUNTIME_USER" || die "Invalid runtime username: $RUNTIME_USER"
valid_user_name "$DEPLOY_USER" || die "Invalid deploy username: $DEPLOY_USER"
[[ "$RUNTIME_USER" != "$DEPLOY_USER" ]] || die "Runtime and deploy users must be different"

if [[ -n "$DOMAIN" && -n "$VHOSTROOT" ]]; then die "Choose either --domain or --vhostroot, not both"; fi
if [[ -z "$VHOSTROOT" ]]; then
  [[ -n "$DOMAIN" ]] || die "Provide either -p/--domain or --vhostroot"
  valid_domain "$DOMAIN" || die "Invalid domain name: $DOMAIN"
  VHOSTROOT="/var/www/vhosts/$DOMAIN/httpdocs"
fi
[[ "$VHOSTROOT" = /* ]] || die "Document root must be an absolute path"
[[ -d "$VHOSTROOT" ]] || die "Document root not found: $VHOSTROOT"
VHOSTROOT="$(realpath -e -- "$VHOSTROOT")"
case "$VHOSTROOT" in /var/www/vhosts/*) ;; *) die "Document root must resolve below /var/www/vhosts" ;; esac
[[ "$VHOSTROOT" != "/var/www/vhosts" ]] || die "Refusing to operate on the vhosts parent directory"
[[ ! -L "$VHOSTROOT/wp-config.php" ]] || die "wp-config.php is a symlink. Review it manually before continuing."

id "$RUNTIME_USER" >/dev/null 2>&1 || die "Runtime user '$RUNTIME_USER' does not exist"
RUNTIME_HOME="$(get_home_dir "$RUNTIME_USER")"
[[ -n "$RUNTIME_HOME" && -d "$RUNTIME_HOME" ]] || die "Could not resolve runtime home for '$RUNTIME_USER'"
RUNTIME_HOME="$(realpath -e -- "$RUNTIME_HOME")"
case "$RUNTIME_HOME/" in /var/www/vhosts/*) ;; *) die "Runtime user's home must be below /var/www/vhosts" ;; esac
case "$VHOSTROOT/" in "$RUNTIME_HOME/"*) ;; *) die "Document root must be inside runtime home ($RUNTIME_HOME)" ;; esac
getent group "$PSA_GROUP" >/dev/null 2>&1 || die "Group '$PSA_GROUP' not found (is Plesk installed?)"
have_cmd setfacl && have_cmd getfacl && have_cmd realpath && have_cmd find || die "Required commands missing: setfacl, getfacl, realpath, and find"
[[ ${#WRITABLE_DIRS[@]} -gt 0 ]] || die "At least one writable directory is required"

WRITABLE_PATHS=()
for rel in "${WRITABLE_DIRS[@]}"; do
  [[ -n "$rel" ]] || die "Writable path cannot be empty"
  [[ "$rel" != /* ]] || die "Writable paths must be relative to the document root: $rel"
  IFS='/' read -r -a components <<< "$rel"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || die "Unsafe writable path: $rel"
  done
  path="$(realpath -m -- "$VHOSTROOT/$rel")"
  case "$path/" in "$VHOSTROOT/"*) ;; *) die "Writable path resolves outside the document root: $rel" ;; esac
  [[ "$path" != "$VHOSTROOT" ]] || die "The document root itself cannot be writable"
  WRITABLE_PATHS+=("$path")
done

DEPLOY_EXISTS=0
if id "$DEPLOY_USER" >/dev/null 2>&1; then
  DEPLOY_EXISTS=1
  DEPLOY_SHELL="$(getent passwd "$DEPLOY_USER" | awk -F: 'NR == 1 { print $7 }')"
  case "$DEPLOY_SHELL" in /bin/bash|/usr/bin/bash) ;; *) die "Existing deploy user has shell '$DEPLOY_SHELL'; review it and set an interactive shell explicitly if intended" ;; esac
fi

say "==> Plan"
say "  Document root: $VHOSTROOT"
say "  Runtime user:  $RUNTIME_USER"
say "  Runtime home:  $RUNTIME_HOME"
say "  Deploy user:   $DEPLOY_USER"
say "  Writable paths:"
printf '    %s\n' "${WRITABLE_PATHS[@]}"
say "  Dry run:       $DRY_RUN"
say "WARNING: This changes ownership, permissions, and ACLs under the document root."
say "Review the plan and take a backup before running without --dry-run."

# Create writable paths and test ACL support before creating an account or
# changing ownership/permissions. Only directory creation may occur on failure.
for path in "${WRITABLE_PATHS[@]}"; do run mkdir -p -- "$path"; done
if [[ "$DRY_RUN" -eq 0 ]]; then
  for path in "$RUNTIME_HOME" "${WRITABLE_PATHS[@]}"; do test_acl_on_path "$path"; done
fi

if [[ "$DEPLOY_EXISTS" -eq 0 ]]; then
  run useradd -m -d "/home/$DEPLOY_USER" -s /bin/bash "$DEPLOY_USER"
else
  say "Deploy user exists; leaving its home, shell, and supplementary groups unchanged."
fi

# Grant traversal through the subscription home only; do not add default ACLs.
run setfacl -m "u:$DEPLOY_USER:rx" -- "$RUNTIME_HOME"

# Normalize code ownership and remove existing ACL grants. -xdev avoids
# recursively changing nested mounts; each configured writable path is handled
# separately below.
run find -P "$VHOSTROOT" -xdev -exec chown -h "$DEPLOY_USER:$PSA_GROUP" {} +
run find -P "$VHOSTROOT" -xdev \( -type f -o -type d \) -exec setfacl -b {} +
run find -P "$VHOSTROOT" -xdev -type d -exec setfacl -k {} +
run find -P "$VHOSTROOT" -xdev -type d -exec chmod 0755 {} +
run find -P "$VHOSTROOT" -xdev -type f -exec chmod 0644 {} +
if [[ -f "$VHOSTROOT/wp-config.php" ]]; then
  run chmod 0600 -- "$VHOSTROOT/wp-config.php"
  run setfacl -m "u:$RUNTIME_USER:r--" -- "$VHOSTROOT/wp-config.php"
fi

# User-specific runtime ACLs keep the shared psacln group non-writable.
for path in "${WRITABLE_PATHS[@]}"; do
  run find -P "$path" -xdev -exec chown -h "$DEPLOY_USER:$PSA_GROUP" {} +
  run find -P "$path" -xdev \( -type f -o -type d \) -exec setfacl -b {} +
  run find -P "$path" -xdev -type d -exec setfacl -k {} +
  run find -P "$path" -xdev -type d -exec chmod 2755 {} +
  run find -P "$path" -xdev -type f -exec chmod 0644 {} +
  run find -P "$path" -xdev \( -type f -o -type d \) -exec setfacl -m "u:$RUNTIME_USER:rwX" {} +
  run find -P "$path" -xdev -type d -exec setfacl -m "d:u:$RUNTIME_USER:rwX,d:g::r-x,d:m::rwx,d:o::r-x" {} +
done

REPAIR_DIR="$RUNTIME_HOME/.wp-two-user"
REPAIR_NAME="repair_$(basename "$VHOSTROOT").sh"
[[ -n "$DOMAIN" ]] && REPAIR_NAME="repair_$DOMAIN.sh"
REPAIR="$REPAIR_DIR/$REPAIR_NAME"
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '[dry-run] generate root-only repair script at %q (contents omitted)\n' "$REPAIR"
else
  install -d -m 0700 -o root -g root -- "$REPAIR_DIR"
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\numask 022\n\n'
    printf 'VHOSTROOT=%q\n' "$VHOSTROOT"
    printf 'RUNTIME_HOME=%q\n' "$RUNTIME_HOME"
    printf 'RUNTIME_USER=%q\n' "$RUNTIME_USER"
    printf 'DEPLOY_USER=%q\n' "$DEPLOY_USER"
    printf 'PSA_GROUP=%q\n' "$PSA_GROUP"
    printf 'WRITABLE_PATHS=('
    for path in "${WRITABLE_PATHS[@]}"; do printf ' %q' "$path"; done
    printf ' )\n\n'
    cat <<'REPAIR_BODY'
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" -eq 0 ]] || die "Run this repair script as root"
for cmd in realpath find setfacl chown chmod; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
done
id "$RUNTIME_USER" >/dev/null 2>&1 || die "Runtime user no longer exists"
id "$DEPLOY_USER" >/dev/null 2>&1 || die "Deploy user no longer exists"
[[ -d "$VHOSTROOT" ]] || die "Document root no longer exists"
[[ "$(realpath -e -- "$VHOSTROOT")" == "$VHOSTROOT" ]] || die "Document root path changed"
for path in "${WRITABLE_PATHS[@]}"; do
  resolved="$(realpath -m -- "$path")"
  case "$resolved/" in "$VHOSTROOT/"*) ;; *) die "Writable path resolves outside the document root: $path" ;; esac
  [[ "$resolved" == "$path" ]] || die "Writable path changed through a symlink: $path"
  [[ -d "$path" ]] || die "Writable directory is missing: $path"
done
find -P "$VHOSTROOT" -xdev -exec chown -h "$DEPLOY_USER:$PSA_GROUP" {} +
find -P "$VHOSTROOT" -xdev \( -type f -o -type d \) -exec setfacl -b {} +
find -P "$VHOSTROOT" -xdev -type d -exec setfacl -k {} +
find -P "$VHOSTROOT" -xdev -type d -exec chmod 0755 {} +
find -P "$VHOSTROOT" -xdev -type f -exec chmod 0644 {} +
if [[ -L "$VHOSTROOT/wp-config.php" ]]; then die "wp-config.php is a symlink. Review it manually."; fi
if [[ -f "$VHOSTROOT/wp-config.php" ]]; then
  chmod 0600 -- "$VHOSTROOT/wp-config.php"
  setfacl -m "u:$RUNTIME_USER:r--" -- "$VHOSTROOT/wp-config.php"
fi
setfacl -m "u:$DEPLOY_USER:rx" -- "$RUNTIME_HOME"
for path in "${WRITABLE_PATHS[@]}"; do
  find -P "$path" -xdev -exec chown -h "$DEPLOY_USER:$PSA_GROUP" {} +
  find -P "$path" -xdev \( -type f -o -type d \) -exec setfacl -b {} +
  find -P "$path" -xdev -type d -exec setfacl -k {} +
  find -P "$path" -xdev -type d -exec chmod 2755 {} +
  find -P "$path" -xdev -type f -exec chmod 0644 {} +
  find -P "$path" -xdev \( -type f -o -type d \) -exec setfacl -m "u:$RUNTIME_USER:rwX" {} +
  find -P "$path" -xdev -type d -exec setfacl -m "d:u:$RUNTIME_USER:rwX,d:g::r-x,d:m::rwx,d:o::r-x" {} +
done
printf 'Permissions and ACLs restored for %s\n' "$VHOSTROOT"
REPAIR_BODY
  } > "$REPAIR"
  chown root:root "$REPAIR"
  chmod 0700 "$REPAIR"
fi
say ""
say "Completed."
say "Repair script: $REPAIR"
say "Run the repair script as root, only after reviewing its target:"
say "  sudo bash \"$REPAIR\""
say "No group-writable fallback is used; unsupported ACLs cause the setup to stop."
