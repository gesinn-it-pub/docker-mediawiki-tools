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

**Empty-queue pre-check.** Before every run `run-jobs.sh` asks `job-queue-empty.php` whether the
job table holds any row (for the type). That check does not bootstrap MediaWiki (a few ms instead
of several hundred ms) and skips `showJobs.php`/`runJobs.php` when the table is provably empty.
It reads the DB settings from `LocalSettings*.php` with a regular expression and therefore only
handles literal `$wgDBserver/$wgDBname/$wgDBuser/$wgDBpassword/$wgDBprefix` assignments, one per
line, with `$wgDBtype = 'mysql'`. In every other case (SQLite, `$wgJobTypeConf` set, interpolated
values, no `mysqli`, wrong credentials, DB unreachable) it answers "unknown" and `run-jobs.sh`
falls back to the full check (fail-open). Disable with `RUN_JOBS_SKIP_PRECHECK=1`.

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
* Other options: `--max-jobs` (batch size, 20), `--poll-ms` (500; 1000 while the wake socket is
  active), `--force-interval` (30 s; forces a runner call even if the queue looks empty, to
  recycle stale claims), `--max-runtime` (900 s) and `--memory-limit` (512 MB) after which the
  runner exits and is restarted, `--no-wake`, `--verbose`. Run with `--help` for the list.
* Runner and daemon exit cleanly on SIGTERM/SIGINT; the daemon restarts the runner immediately
  after a planned exit and after a 1 s pause on errors.

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

**OPcache for the CLI.** The image has `opcache.enable_cli` off, which makes every CLI bootstrap
slow. `run-jobs-daemon.sh` therefore starts the runner with an OPcache file cache in
`/tmp/php-opcache-cli` (private to `www-data`, it holds executable code). Override the PHP options
with `RUN_JOBS_PHP_OPTS`; set it to the empty string to disable.

**Environment variables**

| Variable | Used by | Default | Meaning |
|----------|---------|---------|---------|
| `RUN_JOBS_LOCK_FILE` | run-jobs.sh, job-runner.php | `/tmp/run-jobs.lock` | Pause while this file exists |
| `RUN_JOBS_SKIP_PRECHECK` | run-jobs.sh | unset | `1` disables the empty-queue pre-check |
| `RUN_JOBS_PHP_OPTS` | run-jobs-daemon.sh | OPcache file cache | PHP options for the runner; `""` disables |
| `RUN_JOBS_WAKE_SOCKET` | job-runner.php, job-wake.php | `/tmp/run-jobs.wake` | Wake-up socket path |
| `MW_INSTALL_PATH` | job-runner.php | `/var/www/html` | MediaWiki root |
| `MW_PATH` | job-queue-empty.php | `/var/www/html` | MediaWiki root (settings lookup) |

Compatible with MediaWiki 1.39 and 1.43. In local measurements with SemanticDependencyUpdater 5.2.0
(SMW >= 7.4.0) the divergences seen with earlier versions did not occur again; the cause of the
earlier ones is not established, so this is an observation, not a guarantee.

### Tests

```sh
bash tests/test-job-queue-empty.sh   # add TEST_DB_HOST/USER/PASS/NAME (+ ext-mysqli) for the DB cases
```

## Try it

```sh
> cp .env.sqlite-example .env
> docker-compose up
```

## Releasing

Set version in `tools\mediawiki-tools.version` and publish release at https://github.com/gesinn-it-pub/docker-mediawiki-tools/releases.
