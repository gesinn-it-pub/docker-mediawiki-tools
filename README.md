# docker-mediawiki-tools

Tools to support docker image creation for docker-mediawiki.

## Snippets

### Add tools to image

Dockerfile:
```
# add /build-tools and /tools
RUN curl -LJ https://github.com/gesinn-it-pub/docker-mediawiki-tools/tarball/Init -o /tools.tgz && \
    tar -xzf /tools.tgz -C / --strip-components 1 && rm /tools.tgz
# override by custom tools
COPY tools /tools
RUN chmod +x /build-tools/* /tools/*
ENV PATH="/tools:/build-tools:${PATH}"
```

### Override startup

./tools/startup-container.sh:
```
#!/bin/bash

set -euxo pipefail

service cron start
initialize-wiki.sh
apache2-foreground
```

## Job processing

### run-jobs.sh (one-shot)

`run-jobs.sh [--type=TYPE] [--quiet]` runs MediaWiki's `runJobs.php` once. It is meant to be
called periodically (e.g. by an Ofelia `job-exec`). While the lock file
(`RUN_JOBS_LOCK_FILE`, default `/tmp/run-jobs.lock`) exists, no jobs are run.

### Job runner (long-running)

`job-runner.php` is a long-running alternative to calling `run-jobs.sh` every few seconds. It
bootstraps MediaWiki once and then polls the job table with a single query (no process start per
tick), so waiting jobs are picked up within the poll interval or immediately after a wake-up.
`run-jobs-daemon.sh` keeps it alive (as `www-data`) and is safe to start repeatedly: a lock makes
a second instance with the same arguments exit at once.

```sh
run-jobs-daemon.sh --type=smw.update --then-all
```

* `--type=T` runs only jobs of type `T`; with `--then-all` the other types are run as well once
  `T` is drained (fairness: after `--fair-after` busy batches of `T` one batch of the others).
  Without `--type` all types are run.
* `--exclude-type=A,B` keeps the all-types part away from the given types. Together with a runner
  that runs only one type this gives two lanes with no job handled by both, for example when
  one worker must be the only one for `smw.update` and everything else must not wait behind it:

  ```sh
  run-jobs-daemon.sh --type=smw.update
  run-jobs-daemon.sh --exclude-type=smw.update
  ```

  In a scheduling test with 600 jobs of a priority type and 60 of another one (50 ms each, no
  database load), the other type's median wait was 2.4 s with two lanes against 25 to 40 s for
  a single `--type=T --then-all` worker, with the priority type finishing slightly earlier.
  The daemon's lock depends on the arguments, so the two commands run side by side. Only one
  of them can own the wake socket; the other one polls.
* Jobs of a type without a job class, or excluded from MediaWiki's default queue (for example
  `PublishStashedFile`), are never run by the all-types part and do not wake it.
* Other options: `--max-jobs` (batch size, 20), `--poll-ms` (500; 1000 while the wake socket is
  active), `--force-interval` (30 s; forces a runner call even if the queue looks empty, to
  recycle stale claims), `--max-runtime` (900 s) and `--memory-limit` (512 MB) after which the
  runner exits and is restarted, `--no-wake`, `--verbose`. Run with `--help` for the list.
* Runner and daemon exit cleanly on SIGTERM/SIGINT; the daemon restarts the runner immediately
  after a planned exit and after a 1 s pause on errors. If a child is working on a batch, it gets
  `--stop-grace` seconds (5) to finish, then SIGTERM, two seconds later SIGKILL. A job cut off this
  way stays claimed until MediaWiki recycles the claim and runs it again.

Ofelia example (replaces the frequent `run-jobs.sh` labels; the watchdog just makes sure one
runner is running):

```yaml
labels:
  ofelia.job-exec.run-jobs-smw-update.schedule: "@every 30s"
  ofelia.job-exec.run-jobs-smw-update.command: "run-jobs-daemon.sh --type=smw.update --then-all"
```

**Isolation (`--isolation=fork|exit|none`).** Extensions may keep process-local state that
assumes every job run is a fresh PHP process (e.g. SemanticDependencyUpdater's
`$wgSDUTraversed`: after a page was traversed twice in one process, further dependency updates
for it are skipped silently).

| Mode | Behaviour |
|------|-----------|
| `fork` (default) | Each busy period runs in a forked child of the idle, bootstrapped parent: fresh state, no bootstrap cost. Needs `ext-pcntl`. |
| `exit` | The runner exits after a batch with jobs and the daemon restarts it (one bootstrap per batch). Automatic fallback without `pcntl`. |
| `none` (`--keep-process`) | One process for everything. **Not recommended**: breaks extensions that assume fresh processes (see above); diagnostics only. |

**Wake-up.** Without wake-up the runner reacts at its next poll. To start at once after a web
request, include the snippet in `LocalSettings.php`:

```php
if ( file_exists( '/tools/files/job-wake.php' ) ) {
	require_once '/tools/files/job-wake.php';
}
```

After every non-GET/HEAD/OPTIONS request, `job-wake.php` sends one byte to a unix datagram
socket owned by the runner (`RUN_JOBS_WAKE_SOCKET`, default `/tmp/run-jobs.wake`, mode 0600).
Without a runner nothing happens; jobs queued by CLI scripts or cron are still found by polling.
The web server and the runner must run as the same user (`www-data`).

The wake-up can never delay or break a request: the sender sets the socket to non-blocking and
swallows every error, and a full queue (`net.unix.max_dgram_qlen`, 10 by default) just drops the
byte, because a pending byte already means "wake up". (A blocking write to a full datagram socket
waits for `default_socket_timeout`, 60 s, and Apache holds the response open until then; in a
measurement this made POSTs hang and, with enough of them, also slowed down plain page views.)
The runner empties the socket before every poll of the job table, also while a child works and
while the lock file pauses it, so no wake-up is lost and the queue does not fill up. A runner does
not take over the socket of another live runner (for example a second daemon with other
arguments); it logs this and polls only.

**OPcache for the CLI.** The image has `opcache.enable_cli` off, which makes every CLI bootstrap
slow. `run-jobs-daemon.sh` therefore starts the runner with an OPcache file cache in
`/tmp/php-opcache-cli` (private to `www-data`, it holds executable code). Override the PHP options
with `RUN_JOBS_PHP_OPTS`; set it to the empty string to disable.

**Environment variables**

| Variable | Used by | Default | Meaning |
|----------|---------|---------|---------|
| `RUN_JOBS_LOCK_FILE` | run-jobs.sh, job-runner.php | `/tmp/run-jobs.lock` | Pause while this file exists |
| `RUN_JOBS_PHP_OPTS` | run-jobs-daemon.sh | OPcache file cache | PHP options for the runner; `""` disables |
| `RUN_JOBS_WAKE_SOCKET` | job-runner.php, job-wake.php | `/tmp/run-jobs.wake` | Wake-up socket path |
| `MW_INSTALL_PATH` | job-runner.php | `/var/www/html` | MediaWiki root |

Compatible with MediaWiki 1.39 and 1.43. In local measurements with SemanticDependencyUpdater 5.2.0
(SMW >= 7.4.0) the divergences seen with earlier versions did not occur again; the cause of the
earlier ones is not established, so this is an observation, not a guarantee.

### Tests

```sh
bash tests/test-run-jobs-daemon.sh   # daemon lock, TERM handling and restart, with stubbed sudo/php
php tests/test-job-wake.php            # wake-up sender: never blocks, never throws (no MediaWiki needed)
JOB_RUNNER_TEST_ALLOW_DESTRUCTIVE=1 bash tests/test-job-runner.sh <container>   # needs a running throw-away wiki
```

## Try it

```sh
> cp .env.sqlite-example .env
> docker-compose up
```

## Releasing

Set version in `tools\mediawiki-tools.version` and publish release at https://github.com/gesinn-it-pub/docker-mediawiki-tools/releases.
