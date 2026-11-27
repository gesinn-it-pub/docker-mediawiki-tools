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
 * The wake-up must never be able to delay or break a request. Therefore the
 * socket is set to non-blocking right after the connect (a blocking write to
 * a datagram socket whose queue is full - net.unix.max_dgram_qlen is 10 by
 * default - waits until default_socket_timeout, 60 s, and Apache holds the
 * response open until the script ends), every failure is swallowed, and a
 * full queue simply drops the byte: a full queue means a wake-up is pending
 * anyway, and the runner drains it before its next poll.
 *
 * Socket path: $RUN_JOBS_WAKE_SOCKET, default /tmp/run-jobs.wake.
 */

if ( !function_exists( 'jobWakeSend' ) ) {
	/**
	 * Send one wake-up byte to the runner. Never blocks, never throws, never
	 * emits a warning.
	 *
	 * @param string $path Path of the runner's unix datagram socket
	 * @return bool Whether the byte was handed to the socket
	 */
	function jobWakeSend( string $path ): bool {
		try {
			if ( !file_exists( $path ) ) {
				return false;
			}
			$client = @stream_socket_client( "udg://$path", $errno, $errstr );
			if ( !$client ) {
				return false;
			}
			stream_set_blocking( $client, false );
			$sent = @fwrite( $client, '1' );
			fclose( $client );
			return $sent === 1;
		} catch ( \Throwable $e ) {
			return false;
		}
	}
}

if (
	PHP_SAPI !== 'cli'
	&& !in_array( $_SERVER['REQUEST_METHOD'] ?? 'GET', [ 'GET', 'HEAD', 'OPTIONS' ], true )
) {
	register_shutdown_function( static function () {
		jobWakeSend( getenv( 'RUN_JOBS_WAKE_SOCKET' ) ?: '/tmp/run-jobs.wake' );
	} );
}
