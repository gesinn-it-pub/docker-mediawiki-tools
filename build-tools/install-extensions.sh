#!/bin/bash
# Installs custom extensions defined in extensions.local.json.
#
# Expected JSON format:
#   {
#     "extensions": [
#       {
#         "name": "HeaderTabs",
#         "version": "2.4"
#       },
#       {
#         "name": "MyExt",
#         "version": "1.0",
#         "repo": "my-org/mediawiki-extensions-MyExt"
#       },
#       {
#         "name": "MyPrivateExt",
#         "version": "1.0",
#         "repo": "my-org/MyPrivateExt",
#         "private": true
#       },
#       {
#         "name": "MyComposerExt",
#         "composer": "vendor/my-ext",
#         "version": "^2.0"
#       }
#     ]
#   }
#
# Fields:
#   name      (required) Extension name, used as directory name under extensions/
#   version   (required) Tag, branch, or composer version constraint
#   composer  (optional) Composer package name — uses composer-require.sh instead of get-github-extension.sh
#   repo      (optional) GitHub path "org/repo", default: wikimedia/mediawiki-extensions-<name>
#   private   (optional) true → uses get-private-github-extension.sh (requires GH_API_TOKEN secret)

set -euo pipefail

CONFIG_FILE=${1:-extensions.local.json}

if [ ! -f "$CONFIG_FILE" ]; then
    echo "install-extensions.sh: $CONFIG_FILE not found, skipping."
    exit 0
fi

echo "install-extensions.sh: reading $CONFIG_FILE"

python3 - "$CONFIG_FILE" <<'EOF'
import json, subprocess, sys

config_file = sys.argv[1]
with open(config_file) as f:
    config = json.load(f)

extensions = config.get("extensions", [])
if not extensions:
    print("install-extensions.sh: no extensions defined, nothing to do.")
    sys.exit(0)

for ext in extensions:
    name    = ext["name"]
    version = ext["version"]
    composer_pkg = ext.get("composer")
    repo    = ext.get("repo")
    private = ext.get("private", False)

    if composer_pkg:
        print(f"\n=== Installing composer extension: {name} ({composer_pkg} {version}) ===")
        subprocess.run(["composer-require.sh", composer_pkg, version], check=True)
    elif private:
        repo_arg = repo or f"gesinn-it/{name}"
        print(f"\n=== Installing private GitHub extension: {name} {version} from {repo_arg} ===")
        subprocess.run(["get-private-github-extension.sh", name, version, repo_arg], check=True)
    else:
        args = ["get-github-extension.sh", name, version]
        if repo:
            args.append(repo)
        print(f"\n=== Installing GitHub extension: {name} {version} ===")
        subprocess.run(args, check=True)

    local_settings = ext.get("local_settings")
    if local_settings:
        entry = local_settings.rstrip("\n") + "\n"
    else:
        entry = f'wfLoadExtension( "{name}" );\n'

    with open("__setup_extension__", "a") as f:
        f.write(entry)

    print(f"Registered: {entry.strip()}")

print("\ninstall-extensions.sh: done.")
EOF
