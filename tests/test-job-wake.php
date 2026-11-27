<?php
/**
 * Test for tools/files/job-wake.php (jobWakeSend), no MediaWiki needed.
 *
 * The wake-up must never be able to delay or break a web request:
 *  - it does not block when the runner's datagram queue is full and nobody reads,
 *  - it does not throw (also not under an error handler that turns warnings into exceptions),
 *  - a missing, stale or unusable socket just means "not sent".
 *
 * Usage: php tests/test-job-wake.php
 */

require __DIR__ . '/../tools/files/job-wake.php'; // in CLI this only defines jobWakeSend()

$fail = 0;
function check( string $name, bool $ok, string $detail = '' ): void {
	global $fail;
	echo ( $ok ? 'ok   ' : 'FAIL ' ) . $name . ( $ok || $detail === '' ? '' : " ($detail)" ) . "\n";
	$fail |= $ok ? 0 : 1;
}

$dir = sys_get_temp_dir() . '/jobwake-test-' . getmypid();
mkdir( $dir, 0700 );
$path = "$dir/wake.sock";
register_shutdown_function( static function () use ( $dir, $path ) {
	@unlink( $path );
	@rmdir( "$dir/sub" );
	@rmdir( $dir );
} );

check( 'no socket file: not sent, no error', jobWakeSend( $path ) === false );

$srv = stream_socket_server( "udg://$path", $errno, $errstr, STREAM_SERVER_BIND );
stream_set_blocking( $srv, false );
check( 'listening runner: byte is sent', jobWakeSend( $path ) === true );
check( 'the byte arrives', stream_socket_recvfrom( $srv, 64 ) === '1' );

// Nobody reads any more: the queue fills up. The sender must neither block nor fail loudly.
$sent = 0;
$dropped = 0;
$start = hrtime( true );
for ( $i = 0; $i < 5000; $i++ ) {
	jobWakeSend( $path ) ? $sent++ : $dropped++;
	if ( ( hrtime( true ) - $start ) / 1e6 > 1000 ) {
		break; // blocking sender: fail below instead of hanging the test
	}
}
$ms = ( hrtime( true ) - $start ) / 1e6;
check( "5000 wake-ups against a full queue take < 1000 ms (took " . round( $ms ) . " ms)", $ms < 1000 );
check( "the queue was really full (sent $sent, dropped $dropped)", $dropped > 0,
	'raise the loop count or lower net.unix.max_dgram_qlen, otherwise this test proves nothing' );

// Draining makes room again: a wake-up is never lost for good.
$n = 0;
while ( stream_socket_recvfrom( $srv, 64 ) !== false && $n < 100000 ) {
	$n++;
}
check( 'after draining, sending works again', jobWakeSend( $path ) === true );

// An error handler that converts warnings into exceptions must not leak anything.
set_error_handler( static function ( $no, $str ) {
	throw new ErrorException( $str, 0, $no );
} );
fclose( $srv ); // the socket file stays, but nobody listens: stale
$threw = false;
try {
	$res = jobWakeSend( $path );
} catch ( Throwable $e ) {
	$threw = true;
}
check( 'stale socket under a strict error handler: false, no exception', !$threw && $res === false );

mkdir( "$dir/sub" );
$threw = false;
try {
	$res = jobWakeSend( "$dir/sub" ); // exists, but is a directory
} catch ( Throwable $e ) {
	$threw = true;
}
check( 'unusable path (directory): false, no exception', !$threw && $res === false );
restore_error_handler();

exit( $fail );
