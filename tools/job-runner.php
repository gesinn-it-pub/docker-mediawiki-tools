<?php
/**
 * job-runner.php [--type=TYPE] [--then-all] [options]
 *
 * Long-running job runner: bootstraps MediaWiki ONCE and then polls the job
 * queue in-process (one indexed SELECT per poll; no process start, no
 * docker exec). Replaces the per-tick "docker exec run-jobs.sh" pattern.
 *
 * Modes:
 *   --type=T            run only jobs of type T
 *   --type=T --then-all run type T with priority; when T is drained, also
 *                       run all other types (one process for both, replaces
 *                       a fast per-type cycle plus a generic cycle)
 *   (no --type)         run all types
 *
 * Behaviour:
 *  - Pauses while the lock file ($RUN_JOBS_LOCK_FILE, default
 *    /tmp/run-jobs.lock) exists; checked every iteration and between
 *    batches (batches are small: --max-jobs, default 20).
 *  - Fairness: with --then-all, after --fair-after consecutive busy batches
 *    of the priority type one batch of the other types is run.
 *  - Isolation (--isolation): extensions keep process-local state that
 *    assumes a job run is a fresh PHP process. Example:
 *    SemanticDependencyUpdater's $wgSDUTraversed silently skips dependency
 *    updates for a page after it was traversed twice in one process, and a
 *    self-update cycle then never ends. An idle runner holds no such state
 *    (only polling happens), so:
 *      fork (default)  every busy period (a batch of up to --max-jobs jobs)
 *                      runs in a forked child of the idle, bootstrapped
 *                      parent: fresh state per busy period exactly like the
 *                      former per-tick runJobs.php, but no bootstrap cost
 *                      and no restart gap. Needs ext-pcntl. (One child per
 *                      single job was measured slower: each child starts
 *                      with cold caches.)
 *      exit            the runner exits after a batch with jobs and
 *                      run-jobs-daemon.sh restarts it (pays one bootstrap
 *                      per batch; fallback without pcntl).
 *      none            one long-lived process (diagnostics only: breaks
 *                      SDU after a few edits).
 *  - Exits cleanly after --max-runtime seconds (bounds stale in-process
 *    state and memory growth), above --memory-limit MB, on SIGTERM/SIGINT
 *    (between batches), or on any error (exit 1). run-jobs-daemon.sh
 *    restarts it immediately.
 *  - Calls the runner at least every --force-interval seconds even if the
 *    cheap emptiness check says "empty", because that check only sees
 *    unclaimed rows: stale claims must be recycled by pop().
 *  - Uses MediaWiki's own configuration and DB layer: no credentials are
 *    read or copied by this script.
 *  - Note: JobQueueGroup::queuesHaveJobs() is NOT used, it caches for 15s.
 */

$IP = getenv( 'MW_INSTALL_PATH' ) ?: '/var/www/html';
require_once "$IP/maintenance/Maintenance.php";

use MediaWiki\MediaWikiServices;

class JobRunnerDaemon extends Maintenance {
	private bool $stop = false;

	public function __construct() {
		parent::__construct();
		$this->addDescription( 'Long-running job runner with in-process polling' );
		$this->addOption( 'type', 'Job type to run (with priority)', false, true );
		$this->addOption( 'then-all', 'After the type is drained also run all other types' );
		$this->addOption( 'poll-ms', 'Idle poll interval in ms (default 500; 1000 when the wake socket is active)', false, true );
		$this->addOption( 'no-wake', 'Do not listen on the wake socket (see tools/files/job-wake.php)' );
		$this->addOption( 'max-runtime', 'Exit after this many seconds (default 900)', false, true );
		$this->addOption( 'memory-limit', 'Exit above this many MB (default 512)', false, true );
		$this->addOption( 'max-jobs', 'Jobs per batch (default 20)', false, true );
		$this->addOption( 'force-interval', 'Seconds between forced runner calls (default 30)', false, true );
		$this->addOption( 'verbose', 'Log every batch to stderr' );
		$this->addOption( 'isolation', 'fork (default), exit or none - see file header', false, true );
		$this->addOption( 'keep-process', 'Same as --isolation=none (diagnostics only)' );
		$this->addOption( 'fair-after', 'Busy priority batches before one generic batch (default 5)', false, true );
	}

	public function execute() {
		$type = (string)$this->getOption( 'type', '' );
		$thenAll = $this->hasOption( 'then-all' ) && $type !== '';
		$pollGiven = $this->hasOption( 'poll-ms' );
		$pollUs = (int)$this->getOption( 'poll-ms', 500 ) * 1000;
		$deadline = time() + (int)$this->getOption( 'max-runtime', 900 );
		$memLimit = (int)$this->getOption( 'memory-limit', 512 ) * 1024 * 1024;
		$maxJobs = (int)$this->getOption( 'max-jobs', 20 );
		$forceEvery = (int)$this->getOption( 'force-interval', 30 );
		$fairAfter = max( 1, (int)$this->getOption( 'fair-after', 5 ) );
		$lockFile = getenv( 'RUN_JOBS_LOCK_FILE' ) ?: '/tmp/run-jobs.lock';

		if ( function_exists( 'pcntl_async_signals' ) ) {
			pcntl_async_signals( true );
			$handler = function () {
				$this->stop = true;
			};
			pcntl_signal( SIGTERM, $handler );
			pcntl_signal( SIGINT, $handler );
		}

		$services = MediaWikiServices::getInstance();
		$group = $services->getJobQueueGroup();
		$runner = $services->getJobRunner();
		$lbFactory = $services->getDBLoadBalancerFactory();
		$dbQueue = ( $services->getMainConfig()->get( 'JobTypeConf' )['default']['class'] ?? '' )
			=== JobQueueDB::class;

		// Job types that have at least one unclaimed job: ONE indexed query per
		// poll answers "anything for the priority type?" and "anything at all?".
		$pendingTypes = static function () use ( $lbFactory, $group, $dbQueue ): array {
			if ( $dbQueue ) {
				// 1.39: main LB; 1.41+: IConnectionProvider on the factory.
				$dbr = method_exists( $lbFactory, 'getReplicaDatabase' )
					? $lbFactory->getReplicaDatabase()
					: $lbFactory->getMainLB()->getConnectionRef( DB_REPLICA );
				return $dbr->newSelectQueryBuilder()
					->select( 'job_cmd' )->from( 'job' )->where( [ 'job_token' => '' ] )
					->groupBy( 'job_cmd' )->caller( __METHOD__ )->fetchFieldValues();
			}
			return $group->getQueuesWithJobs();
		};

		// Wake-up socket: a unix datagram socket the web side pings after a
		// request that may have queued jobs (tools/files/job-wake.php).
		$wake = null;
		$wakePath = getenv( 'RUN_JOBS_WAKE_SOCKET' ) ?: '/tmp/run-jobs.wake';
		if ( !$this->hasOption( 'no-wake' ) ) {
			@unlink( $wakePath );
			$wake = @stream_socket_server( "udg://$wakePath", $errno, $errstr, STREAM_SERVER_BIND );
			if ( $wake ) {
				@chmod( $wakePath, 0600 );
				stream_set_blocking( $wake, false );
				if ( !$pollGiven ) {
					$pollUs = 1000000; // wake-ups carry the latency, the poll is the safety net
				}
			} else {
				$wake = null;
			}
		}
		$idle = static function ( int $us ) use ( &$wake ): void {
			if ( $wake === null ) {
				usleep( $us );
				return;
			}
			$r = [ $wake ];
			$w = $e = null;
			if ( @stream_select( $r, $w, $e, intdiv( $us, 1000000 ), $us % 1000000 ) > 0 ) {
				for ( $i = 0; $i < 100; $i++ ) { // drain
					$d = @stream_socket_recvfrom( $wake, 64 );
					if ( $d === false || $d === '' ) {
						break;
					}
				}
			}
		};

		$verbose = $this->hasOption( 'verbose' );
		$mode = $this->hasOption( 'keep-process' ) ? 'none' : (string)$this->getOption( 'isolation', '' );
		if ( !in_array( $mode, [ 'fork', 'exit', 'none' ], true ) ) {
			$mode = function_exists( 'pcntl_fork' ) ? 'fork' : 'exit';
		}
		if ( $mode === 'fork' && !function_exists( 'pcntl_fork' ) ) {
			$mode = 'exit';
		}
		$log = static function ( string $msg ) use ( $verbose ) {
			if ( $verbose ) {
				fwrite( STDERR, "job-runner: $msg\n" );
			}
		};
		$log( "isolation=$mode wake=" . ( $wake ? 'on' : 'off' ) . " poll-ms=" . intdiv( $pollUs, 1000 ) );

		$batch = function ( $jobType ) use ( $runner, $maxJobs, $mode, $lbFactory, $log, &$wake ): array {
			$opts = [
				'type' => $jobType !== '' ? $jobType : false,
				'maxJobs' => $maxJobs,
				'maxTime' => 60,
				'throttle' => true,
			];
			if ( $mode !== 'fork' ) {
				$res = $runner->run( $opts );
				$log( sprintf( 'batch type=%s reached=%s jobs=%d',
					$jobType !== '' ? $jobType : '*', $res['reached'], count( $res['jobs'] ) ) );
				return $res;
			}
			// One forked child per busy period: it starts from the clean
			// post-bootstrap state of this parent (like a fresh process, which
			// is what the former per-tick runJobs.php was), without paying
			// the bootstrap, and works off the queue until it is empty or a
			// limit is reached (caches stay warm across the passes of one
			// self-update cycle, as they did within one runJobs.php process).
			// The parent must not share a DB connection with the child, so
			// close it first; both sides reconnect lazily.
			$lbFactory->closeAll( __METHOD__ );
			$pid = pcntl_fork();
			if ( $pid === -1 ) {
				throw new RuntimeException( 'pcntl_fork failed' );
			}
			if ( $pid === 0 ) {
				if ( $wake ) {
					fclose( $wake );
				}
				pcntl_signal( SIGTERM, SIG_DFL );
				pcntl_signal( SIGINT, SIG_DFL );
				try {
					$res = $runner->run( $opts );
					exit( in_array( $res['reached'], [ 'memory-limit', 'exception' ], true )
						? 1 : ( $res['jobs'] === [] ? 3 : 0 ) );
				} catch ( Throwable $e ) {
					fwrite( STDERR, "job-runner child: " . get_class( $e ) . ': ' . $e->getMessage() . "\n" );
					exit( 1 );
				}
			}
			do {
				$r = pcntl_waitpid( $pid, $status );
			} while ( $r === -1 && pcntl_get_last_error() === PCNTL_EINTR );
			$code = pcntl_wifexited( $status ) ? pcntl_wexitstatus( $status ) : 1;
			$log( sprintf( 'child type=%s exit=%d', $jobType !== '' ? $jobType : '*', $code ) );
			return [ 'reached' => $code === 1 ? 'exception' : 'none-ready', 'jobs' => $code === 0 ? [ 1 ] : [] ];
		};

		$lastForce = 0;
		$streak = 0;
		try {
			while ( !$this->stop ) {
				if ( time() >= $deadline || memory_get_usage( true ) > $memLimit ) {
					return;
				}
				if ( file_exists( $lockFile ) ) {
					sleep( 1 );
					continue;
				}
				// Drop any snapshot so the polls see committed rows.
				$lbFactory->flushReplicaSnapshots( __METHOD__ );

				$force = ( time() - $lastForce ) >= $forceEvery;
				$busy = false;

				// Fairness: let the other types have a turn now and then.
				$otherTurn = $thenAll && $streak >= $fairAfter;

				$types = $force ? [] : $pendingTypes();
				if ( !$otherTurn && ( $force || ( $type !== '' ? in_array( $type, $types, true ) : $types !== [] ) ) ) {
					$res = $batch( $type );
					if ( in_array( $res['reached'], [ 'memory-limit', 'exception' ], true ) ) {
						return;
					}
					$busy = $res['jobs'] !== [];
					$streak = $busy ? $streak + 1 : 0;
				}
				if ( !$busy && $thenAll && !file_exists( $lockFile ) && ( $force || $types !== [] || $otherTurn ) ) {
					$res = $batch( '' );
					if ( in_array( $res['reached'], [ 'memory-limit', 'exception' ], true ) ) {
						return;
					}
					$busy = $res['jobs'] !== [];
					$streak = 0;
				}
				if ( $busy && $mode === 'exit' ) {
					return; // planned exit: the wrapper starts a fresh process
				}
				if ( $force ) {
					$lastForce = time();
				}
				if ( !$busy ) {
					$idle( $pollUs );
				}
			}
		} catch ( Throwable $e ) {
			fwrite( STDERR, "job-runner: " . get_class( $e ) . ': ' . $e->getMessage() . "\n" );
			exit( 1 );
		}
	}
}

$maintClass = JobRunnerDaemon::class;
require_once RUN_MAINTENANCE_IF_MAIN;
