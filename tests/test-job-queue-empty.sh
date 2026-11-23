#!/bin/bash
## Functional test for tools/job-queue-empty.php (exit codes 0/1/2).
##
## Usage: bash tests/test-job-queue-empty.sh
## Cases that need a database run only when ext-mysqli and a MySQL/MariaDB
## server are available (without ext-mysqli the helper must answer 2): set TEST_DB_HOST, TEST_DB_USER, TEST_DB_PASS and
## TEST_DB_NAME (the test creates and drops the table "tjq_job").

# shellcheck disable=SC2016,SC2001  # PHP snippets are single-quoted on purpose
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/tools/job-queue-empty.php"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected exit $2, got $3"; fail=1; fi
}
run() { MW_PATH="$tmp" php "$HELPER" "$@" >/dev/null 2>&1; echo $?; }
# One statement per line, like a real LocalSettings.php (the helper parses line-wise).
settings() { { echo '<?php'; echo "$1" | sed 's/; /;\n/g'; } > "$tmp/LocalSettings.php"; }

rm -f "$tmp"/LocalSettings*.php
check "missing LocalSettings" 2 "$(run)"

settings '$wgDBtype = "sqlite";'
check "non-mysql database" 2 "$(run)"

settings '$wgDBtype = "mysql"; $wgDBserver = "127.0.0.1:1"; $wgDBname = "x"; $wgDBuser = "u"; $wgDBpassword = "p"; $wgJobTypeConf["default"] = [ "class" => "JobQueueRedis" ];'
check "wgJobTypeConf set" 2 "$(run)"

settings '$wgDBtype = "mysql"; $wgDBserver = "127.0.0.1"; $wgDBname = "x"; $wgDBuser = "u"; $wgDBpassword = "$secret";'
check "interpolated password" 2 "$(run)"

settings '$wgDBtype = "mysql"; $wgDBserver = "127.0.0.1"; $wgDBname = "x"; $wgDBuser = "u"; $wgDBpassword = "p"; $wgDBprefix = "a-b";'
check "invalid table prefix" 2 "$(run)"

settings '$wgDBtype = "mysql"; $wgDBserver = "127.0.0.1:1"; $wgDBname = "x"; $wgDBuser = "u"; $wgDBpassword = "p";'
check "unreachable server (or no mysqli)" 2 "$(run)"

if php -r 'exit(extension_loaded("mysqli")?0:1);' && [ -n "${TEST_DB_HOST:-}" ]; then
  q() {
    php -r '$d = new mysqli( ...array_slice( $argv, 1, 4 ) ); foreach ( explode( ";", $argv[5] ) as $s ) { $d->query( $s ); }' \
      "$TEST_DB_HOST" "$TEST_DB_USER" "$TEST_DB_PASS" "$TEST_DB_NAME" "$1"
  }
  q "DROP TABLE IF EXISTS tjq_job; CREATE TABLE tjq_job (job_id INT AUTO_INCREMENT PRIMARY KEY, job_cmd VARBINARY(60) NOT NULL)"
  conf() { settings "\$wgDBtype = 'mysql'; \$wgDBserver = '$TEST_DB_HOST'; \$wgDBname = '$TEST_DB_NAME'; \$wgDBuser = '$TEST_DB_USER'; \$wgDBpassword = '$1'; \$wgDBprefix = 'tjq_';"; }
  conf "$TEST_DB_PASS"
  check "empty table"                 0 "$(run)"
  check "empty table, typed"          0 "$(run smw.update)"
  q "INSERT INTO tjq_job (job_cmd) VALUES ('refreshLinks')"
  check "row of other type"           1 "$(run)"
  check "typed, no row of that type"  0 "$(run smw.update)"
  check "typed, row of that type"     1 "$(run refreshLinks)"
  conf "wrong-password"
  check "wrong password"              2 "$(run)"
  q "DROP TABLE tjq_job"
else
  echo "skip database cases (need ext-mysqli and TEST_DB_*)"
fi
exit $fail
