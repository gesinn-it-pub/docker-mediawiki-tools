#!/bin/bash
## Integration test for tools/job-runner.php, tools/run-jobs-daemon.sh and tools/files/job-wake.php
## against a RUNNING MediaWiki container (needs the real runner, MediaWiki and a database).
##
## It deletes all rows of the job table, writes LocalSettings.TMP.php and starts and kills runners
## in the container. Run it ONLY against a throw-away wiki; it refuses to run without
## JOB_RUNNER_TEST_ALLOW_DESTRUCTIVE=1.
##
## Usage: JOB_RUNNER_TEST_ALLOW_DESTRUCTIVE=1 [TESTS="1 6"] bash tests/test-job-runner.sh <wiki-container> [wiki-host]
##   TESTS: run only these numbered checks (default all)
##   wiki-host: Host header the wiki answers to (default wiki.local)
##
## For the first check to prove anything, the container should run with a small datagram queue
## (docker run --sysctl net.unix.max_dgram_qlen=10, the kernel default), otherwise it only warns.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
C="${1:-}"
HOST="${2:-wiki.local}"
fail=0
want() { case " ${TESTS:-1 2 3 4 5 6} " in *" $1 "*) return 0 ;; esac; return 1; }
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }

[ "${JOB_RUNNER_TEST_ALLOW_DESTRUCTIVE:-}" = 1 ] || { echo "refusing: set JOB_RUNNER_TEST_ALLOW_DESTRUCTIVE=1 (throw-away wiki only)"; exit 2; }
[ -n "$C" ] && [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = true ] || { echo "usage: $0 <running wiki container>"; exit 2; }

dx() { docker exec -w /var/www/html "$C" bash -c "$1"; }
dxw() { docker exec -u www-data -w /var/www/html "$C" bash -c "$1"; }
runners() { dx "pgrep -u www-data -f '[j]ob-runner.php' | wc -l"; }
forks() { dx "grep -c 'child type=' $1 2>/dev/null || true"; }
queue() { dxw "php maintenance/run.php showJobs 2>/dev/null | head -1"; }

cleanup() {
  dx "pkill -TERM -f '[r]un-jobs-daemon.sh'; pkill -KILL -u www-data -f '[j]ob-runner.php'; rm -f /var/www/html/LocalSettings.TMP.php /tmp/run-jobs.wake /tmp/run-jobs-daemon.*.flock /tmp/it-runner*.log; rm -rf /tmp/it-tools" >/dev/null 2>&1
  dxw "php maintenance/run.php runJobs --maxjobs 0 >/dev/null 2>&1; true"
}
trap cleanup EXIT

# The files under test, not the ones baked into the image.
dx "rm -rf /tmp/it-tools && mkdir -p /tmp/it-tools/files"
for f in job-runner.php run-jobs-daemon.sh files/job-wake.php; do docker cp "$ROOT/tools/$f" "$C:/tmp/it-tools/$f" >/dev/null; done
dx "chmod +x /tmp/it-tools/run-jobs-daemon.sh; chmod -R a+rX /tmp/it-tools"
reset() {
  dx "pkill -TERM -f '[r]un-jobs-daemon.sh'; pkill -TERM -f '[j]ob-runner.php'; true" >/dev/null 2>&1
  for _ in $(seq 40); do [ "$(runners)" = 0 ] && break; sleep 0.5; done
  dx "pkill -KILL -u www-data -f '[j]ob-runner.php'; rm -f /tmp/run-jobs.wake /tmp/run-jobs.lock /tmp/run-jobs-daemon.*.flock"
  dxw "php maintenance/run.php sql --query='DELETE FROM job' >/dev/null 2>&1"
}
start() { # <log> <args...>
  local log=$1; shift
  docker exec -d "$C" bash -c "setsid /tmp/it-tools/run-jobs-daemon.sh $* >$log 2>&1"
}
push_null() { # <n> <usleep>
  dxw "echo '\$g=MediaWiki\\MediaWikiServices::getInstance()->getJobQueueGroup();\$k=0;while(\$k<$1){\$j=[];for(\$i=0;\$i<100&&\$k<$1;\$i++,\$k++){\$j[]=new NullJob([\"usleep\"=>$2,\"i\"=>\$k]);}\$g->push(\$j);}' | php maintenance/run.php eval >/dev/null"
}
wait_busy() { for _ in $(seq 60); do [ "$(runners)" -ge 2 ] && return 0; sleep 0.5; done; return 1; }

docker exec -i "$C" bash -c 'cat > /var/www/html/LocalSettings.TMP.php' <<'EOF'
<?php
require_once "/tmp/it-tools/files/job-wake.php";
// A job type of its own (besides the built-in "null"), to tell types apart.
class ItProbeJob extends Job implements GenericParameterJob {
	public function __construct( array $params ) { parent::__construct( 'itprobe', $params ); }
	public function run() { file_put_contents( '/tmp/it-probe.log', "1\n", FILE_APPEND | LOCK_EX ); return true; }
}
$wgJobClasses['itprobe'] = 'ItProbeJob';
EOF
qlen=$(dx "cat /proc/sys/net/unix/max_dgram_qlen")
[ "$qlen" -le 20 ] || echo "note: max_dgram_qlen=$qlen, the busy-writer check proves little (use --sysctl net.unix.max_dgram_qlen=10)"

if want 1; then
## 1. Writers are not held up while the runner works (the queue of the wake socket is full).
reset
start /tmp/it-runner1.log --type=smw.update --then-all
sleep 3
push_null 3000 100000
wait_busy; check "runner is busy (child running)" 0 $?
max=0
t_start=$(date +%s)
for i in $(seq 30); do
  [ $(( $(date +%s) - t_start )) -gt 40 ] && break # a blocked writer must fail the check, not stall the test
  t=$(dx "curl -s -o /dev/null -m 90 -w '%{time_total}' -H 'Host: $HOST' -X POST -d 'action=query&meta=siteinfo&format=json' http://localhost/api.php")
  max=$(awk -v a="$t" -v b="$max" 'BEGIN{print (a>b)?a:b}')
done
check "30 POSTs while the runner works, slowest < 1 s (slowest $max s)" yes "$(awk -v m="$max" 'BEGIN{print (m<1)?"yes":"no"}')"

fi

if want 2; then
## 2. A second daemon with other arguments must not take over the wake socket of the first.
ino1=$(dx "stat -c %i /tmp/run-jobs.wake")
start /tmp/it-runner2.log --type=refreshLinks --then-all
sleep 6
check "wake socket is still the first runner's" "$ino1" "$(dx "stat -c %i /tmp/run-jobs.wake")"
check "second runner says it polls only" 1 "$(dx "grep -c 'in use by another runner' /tmp/it-runner2.log")"

fi

if want 3; then
## 3. SIGTERM while a child works on a long job: everything ends within the grace period.
reset
start /tmp/it-runner3.log --type=smw.update --then-all --stop-grace=3
sleep 3
push_null 5 30000000
wait_busy
dx "pkill -TERM -f '[r]un-jobs-daemon.sh'"
t0=$(date +%s)
for _ in $(seq 120); do [ "$(runners)" = 0 ] && break; sleep 0.25; done
el=$(( $(date +%s) - t0 ))
check "runner and child gone within grace+kill margin, <= 8 s (took $el s)" yes "$([ "$el" -le 8 ] && echo yes || echo no)"

fi

if want 4; then
## 4. No lost wake-up: with a poll interval of 30 s only the wake-up can start the job.
reset
start /tmp/it-runner4.log --type=smw.update --then-all --poll-ms=30000 --force-interval=3600
sleep 4
lost=0
for i in $(seq 15); do
  dxw "echo '\$g=MediaWiki\\MediaWikiServices::getInstance()->getJobQueueGroup();\$g->push(new NullJob([\"usleep\"=>0,\"i\"=>$i]));\$c=@stream_socket_client(\"udg:///tmp/run-jobs.wake\");fwrite(\$c,\"1\");' | php maintenance/run.php eval >/dev/null"
  ok=0
  for _ in $(seq 30); do [ "$(queue)" = 0 ] && { ok=1; break; }; sleep 0.1; done
  [ $ok = 1 ] || lost=$((lost + 1))
done
check "15 jobs started by the wake-up alone (poll 30 s), none left waiting 3 s" 0 "$lost"


fi

if want 5; then
## 5. --exclude-type: this runner leaves the excluded type to another runner and does not start
##    children for it; the other runner takes it.
reset
dx "rm -f /tmp/it-probe.log"
start /tmp/it-runner5.log --exclude-type=null --poll-ms=200 --force-interval=3600 --verbose
sleep 3
push_null 50 0
dxw "echo '\$g=MediaWiki\\MediaWikiServices::getInstance()->getJobQueueGroup();\$j=[];for(\$i=0;\$i<20;\$i++){\$j[]=new ItProbeJob([\"i\"=>\$i]);}\$g->push(\$j);' | php maintenance/run.php eval >/dev/null"
for _ in $(seq 60); do [ "$(dx "cat /tmp/it-probe.log 2>/dev/null | wc -l")" -ge 20 ] && break; sleep 0.25; done
check "other types run (20 of 20 itprobe jobs)" 20 "$(dx "cat /tmp/it-probe.log 2>/dev/null | wc -l")"
check "excluded type is left alone (50 null jobs still queued)" 50 "$(queue)"
f1=$(forks /tmp/it-runner5.log); sleep 4; f2=$(forks /tmp/it-runner5.log)
check "no child is started while only the excluded type waits ($f1 -> $f2 forks)" "$f1" "$f2"
start /tmp/it-runner5b.log --type=null
for _ in $(seq 60); do [ "$(queue)" = 0 ] && break; sleep 0.25; done
check "the runner for the excluded type takes it (queue empty)" 0 "$(queue)"

fi

if want 6; then
## 6. Jobs of a type without job class (stale rows) must not make every poll start a child.
reset
start /tmp/it-runner6.log --poll-ms=200 --force-interval=3600 --verbose
sleep 3
dxw "php maintenance/run.php sql --query=\"INSERT INTO job (job_cmd,job_namespace,job_title,job_timestamp,job_params,job_random,job_attempts,job_token,job_token_timestamp,job_sha1) VALUES ('bogustype',0,'X','20260101000000','a:0:{}',0,0,'',NULL,'')\" >/dev/null"
check "precondition: the stale row is in the job table" 1 "$(dxw "php maintenance/run.php sql --query=\"SELECT COUNT(*) AS c FROM job WHERE job_cmd='bogustype'\" | grep -o '=> [0-9]*' | grep -o '[0-9]*'")"
sleep 1
f1=$(forks /tmp/it-runner6.log); sleep 4; f2=$(forks /tmp/it-runner6.log)
check "no child per poll for a row nobody can run ($f1 -> $f2 forks in 4 s)" "$f1" "$f2"

fi

exit $fail
