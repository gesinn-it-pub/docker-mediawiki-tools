<?php
/**
 * job-wake.php - tells the long-running job runner (tools/job-runner.php)
 * that a web request may have queued jobs, so it starts working at once
 * instead of at its next poll.
 *
 * Include it once from LocalSettings.php of a wiki image, for example:
 *
 *   if ( file_exists( '/tools/files/job-wake.php' ) ) {
 *       require_once '/tools/files/job-wake.php';
 *   }
 *
 * Only requests that can change data (not GET/HEAD/OPTIONS) send a wake-up,
 * and only after the request has finished (shutdown function), i.e. after
 * MediaWiki pushed its post-send jobs. The wake-up is a single byte on a
 * unix datagram socket owned by the runner; it is fire-and-forget: without a
 * listening runner nothing happens, and the runner's own fallback poll still
 * finds every job (also those queued by CLI scripts or cron).
 *
 * Socket path: $RUN_JOBS_WAKE_SOCKET, default /tmp/run-jobs.wake.
 */

if (
	PHP_SAPI !== 'cli'
	&& !in_array( $_SERVER['REQUEST_METHOD'] ?? 'GET', [ 'GET', 'HEAD', 'OPTIONS' ], true )
) {
	register_shutdown_function( static function () {
		$path = getenv( 'RUN_JOBS_WAKE_SOCKET' ) ?: '/tmp/run-jobs.wake';
		if ( !file_exists( $path ) ) {
			return;
		}
		$client = @stream_socket_client( "udg://$path", $errno, $errstr, 0.05 );
		if ( $client ) {
			@fwrite( $client, '1' );
			fclose( $client );
		}
	} );
}
