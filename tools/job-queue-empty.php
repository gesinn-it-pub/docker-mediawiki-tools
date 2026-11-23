<?php
/**
 * job-queue-empty.php [JOB_TYPE]
 *
 * Cheap pre-check for run-jobs.sh: answers "is the job table empty (for this
 * type)?" WITHOUT bootstrapping MediaWiki (a MediaWiki bootstrap costs
 * several hundred ms per call; this costs a few ms).
 *
 * Exit codes:
 *   0  the job table definitely holds no row (for JOB_TYPE, if given)
 *      -> run-jobs.sh may skip showJobs.php/runJobs.php
 *   1  at least one row exists (queued, delayed or claimed)
 *   2  unknown (no usable settings, non-default job queue, DB error, ...)
 *
 * run-jobs.sh only skips on exit code 0; every other outcome (including
 * errors of any kind) falls back to the full showJobs.php check, i.e. the
 * pre-existing behaviour (fail-open).
 *
 * Any row at all counts as "not empty" on purpose: delayed rows and claimed
 * rows (job_token set) must still reach runJobs.php, which releases
 * delayed jobs and recycles stale claims.
 */

if ( !extension_loaded( 'mysqli' ) ) {
	exit( 2 );
}
mysqli_report( MYSQLI_REPORT_OFF );

$mwPath = getenv( 'MW_PATH' ) ?: '/var/www/html';
$type = $argv[1] ?? '';

$settings = '';
foreach ( glob( "$mwPath/LocalSettings*.php" ) ?: [] as $f ) {
	$settings .= (string)@file_get_contents( $f ) . "\n";
}
if ( $settings === '' ) {
	exit( 2 );
}

// A non-default job queue (Redis, ...) means the table says nothing.
if ( strpos( $settings, 'wgJobTypeConf' ) !== false ) {
	exit( 2 );
}

$get = static function ( string $name ) use ( $settings ) {
	$re = '/^\s*\$wg' . $name . '\s*=\s*(?:"((?:[^"\\\\]|\\\\.)*)"|\'((?:[^\'\\\\]|\\\\.)*)\')\s*;/m';
	if ( !preg_match_all( $re, $settings, $m, PREG_SET_ORDER ) ) {
		return null;
	}
	$last = end( $m ); // later assignment wins
	$v = $last[2] ?? ( $last[1] ?? '' );
	if ( ( $last[1] ?? '' ) !== '' && strpos( $last[1], '$' ) !== false ) {
		return null; // interpolation, cannot evaluate safely
	}
	return stripcslashes( $v );
};

if ( $get( 'DBtype' ) !== 'mysql' ) {
	exit( 2 );
}
$server = $get( 'DBserver' );
$name = $get( 'DBname' );
$user = $get( 'DBuser' );
$pass = $get( 'DBpassword' );
$prefix = $get( 'DBprefix' ) ?? '';
if ( $server === null || $name === null || $user === null || $pass === null
	|| !preg_match( '/^[A-Za-z0-9_$]*$/', $prefix ) ) {
	exit( 2 );
}

$port = 3306;
if ( preg_match( '/^(.+):(\d+)$/', $server, $m ) ) {
	[ , $server, $port ] = $m;
}

$db = mysqli_init();
$db->options( MYSQLI_OPT_CONNECT_TIMEOUT, 2 );
if ( !@$db->real_connect( $server, $user, $pass, $name, (int)$port ) ) {
	exit( 2 );
}

if ( $type !== '' ) {
	$stmt = $db->prepare( "SELECT 1 FROM `{$prefix}job` WHERE job_cmd = ? LIMIT 1" );
	if ( !$stmt || !$stmt->bind_param( 's', $type ) || !$stmt->execute() ) {
		exit( 2 );
	}
	$res = $stmt->get_result();
} else {
	$res = $db->query( "SELECT 1 FROM `{$prefix}job` LIMIT 1" );
}
if ( $res === false || $res === null ) {
	exit( 2 );
}
exit( $res->num_rows === 0 ? 0 : 1 );
