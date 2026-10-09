# rp_wp_plesk_two_user

Harden a WordPress site on Plesk for Linux by separating the **runtime user** (PHP-FPM) from the **deploy user** (code owner).

> **Safety note:** Back up the site and review the dry run before applying changes. This script recursively changes ownership, permissions, and ACLs inside the selected document root.

## Security model

- The Plesk subscription system user runs PHP-FPM.
- A separate deploy user owns the WordPress document root and deploys code.
- PHP should not be able to modify WordPress core, plugins, or themes.
- By default, only `wp-content/uploads` and `wp-content/cache` are writable by the runtime user.
- Writable directories use a named-user ACL for the runtime account; the shared `psacln` group is not made writable.
- A regular `wp-config.php` inside the document root is set to mode `0600`, with read-only ACL access for the runtime user.
- The generated repair script is root-owned and root-only. Run it as root.

Dashboard updates, plugin/theme installs, and other operations that write code are intentionally incompatible with this model. Deploy updates as the deploy user instead.

## Requirements

- A Plesk Linux subscription already exists and the runtime user is its PHP-FPM user.
- Install `setfacl`, `getfacl`, `find`, and `realpath`.
- The runtime home and writable paths must support access and default ACLs.
- The document root must resolve below `/var/www/vhosts`, inside the runtime user's home.
- Take a filesystem/VPS backup before the first run.

Install ACL tools if needed:

```bash
# Debian / Ubuntu
sudo apt-get update && sudo apt-get install -y acl

# RHEL / Rocky / Alma / Amazon Linux
sudo dnf install -y acl || sudo yum install -y acl

# SUSE / SLES
sudo zypper install -y acl
```

## Quick start

Review the planned commands first:

```bash
sudo bash wp_two_user_setup.sh \
  --domain example.com \
  --runtime-user site_runtime \
  --deploy-user site_owner \
  --dry-run
```

After reviewing the plan and confirming you have a backup, apply it:

```bash
sudo bash wp_two_user_setup.sh \
  --domain example.com \
  --runtime-user site_runtime \
  --deploy-user site_owner
```

Custom document root:

```bash
sudo bash wp_two_user_setup.sh \
  --vhostroot /var/www/vhosts/example.com/httpdocs \
  --runtime-user site_runtime \
  --deploy-user site_owner
```

Add a writable path only when the application requires it:

```bash
sudo bash wp_two_user_setup.sh \
  --domain example.com \
  --runtime-user site_runtime \
  --deploy-user site_owner \
  --writable "wp-content/uploads wp-content/cache wp-content/media"
```

## Options

```
-r, --runtime-user USER     Plesk subscription system user (PHP-FPM)
-o, --deploy-user USER      Separate deploy user
-p, --domain DOMAIN         Use /var/www/vhosts/DOMAIN/httpdocs
    --vhostroot PATH        Absolute document root below /var/www/vhosts
-w, --writable "DIRS"       Space-separated paths relative to document root
    --dry-run               Print commands without changing the system
-h, --help                  Show usage
```

Runtime and deploy usernames must differ. Existing deploy accounts are not silently reconfigured; an existing account must already have an interactive Bash shell. The script does not add the deploy user to `psacln` or change an existing account's home directory.

## ACL failure policy

ACL support is required. The script tests ACL behavior before changing code ownership and permissions. If the preflight fails, it stops rather than falling back to group-writable directories.

This matters because `psacln` is a shared Plesk group: granting it write access can weaken isolation between subscriptions. Filesystems that cannot provide the required ACL behavior (including some NFS configurations) are not supported by this setup. Do not bypass ACL errors with permissive group modes.

## Repair script

The root-only repair script is created under:

```
/var/www/vhosts/DOMAIN/.wp-two-user/
```

Run it as root after reviewing the target:

```bash
sudo bash /var/www/vhosts/example.com/.wp-two-user/repair_example.com.sh
```

Do not run it as the deploy user: restoring ownership and permissions requires root privileges. The repair script rechecks that configured writable paths remain inside the selected document root.

## Verification checklist

Adapt the domain and usernames:

```bash
VHOSTROOT=/var/www/vhosts/example.com/httpdocs

# Code ownership and modes
ls -ld "$VHOSTROOT"
find "$VHOSTROOT" -maxdepth 1 -printf '%u:%g %m %p\\n'

# wp-config.php should not be world-readable
stat -c '%U:%G %a %n' "$VHOSTROOT/wp-config.php"
getfacl "$VHOSTROOT/wp-config.php"

# Test runtime writes to uploads
sudo -u site_runtime touch "$VHOSTROOT/wp-content/uploads/acl-test"
sudo -u site_runtime rm "$VHOSTROOT/wp-content/uploads/acl-test"
```

Also test a real deployment, page loads, media uploads, cache generation, backups, and plugins that create files. Confirm PHP cannot modify core, plugin, or theme files.

## Operational notes

- Test on one non-critical site before using this across a VPS.
- Plesk repair operations or WordPress Toolkit may reset ownership or permissions; validate the ongoing workflow.
- The script normalizes ordinary file modes under the document root. Review custom executable files, ACLs, symlinks, nested mounts, and non-standard WordPress layouts first.
- The script changes the selected document root and adds a traversal ACL on the runtime home. It no longer creates deploy-user shell configuration files in that shared home.
- The `wp-config.php` protection applies only when the file is directly inside the document root. Secure an external configuration path separately.
- Keep a tested rollback plan. Do not blindly restore all files to `0644`, as that may expose configuration secrets.

## License and attribution

© 2025 Reliable Penguin, Inc. All rights reserved.

You may use and modify this script in your hosting environments. Redistribution requires attribution to Reliable Penguin.
