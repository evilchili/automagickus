package Soop;
=pod

=head1 NAME

Soop - Supervise any process, and make it behave like a daemon

=head1 SYNOPSIS

 use Soop;
 my $supervisor = Soop->new( %options_hash );
 $supervisor->begin();

=head1 DESCRIPTION

Soop is a process supervisor along the lines of djb's daemontools.  It will fork a child, 
execute the given process, and restart it whenever it exits.  Soop can also run 
user-defined tests at a preset interval to determine whether or not the child process 
should be stopped or restarted.  Logging is done to STDERR or syslog, user's choice. 

=head1 METHODS

=over

=item B<* new()>

Returns a new Soop object.  The I<process()> argument is required.

=item  B<* process()>

The process hashref defines the process the Soop object should supervise.  It must have 
two keys, I<cmd>, which defines the process executable, and I<args>, an optional arrayref 
of arguments to pass to the executable.

In addition to the process arg, any of the following may be supplied as arguments to the 
new() method, or called using instance methods on an existing Soop object (excluding the 
beghin() method; see below).

=item B<* daemonize()>

If true, the main process should become a daemon ( via fork() ) before spawning the 
process to monitor.  Suitable for starting Sooped processes from init scripts and the like. 
The default value is false (do not become a daemon).

=item B<* path()>

If specified, override the PATH environment variable of the spawned process.

=item B<* uid()> and B<gid()>

If specified, the process will drop the current user's permissions and set the effective UID and GID 
to the given values.  Useful for init scripts, which typically start as root.

=item B<*pid_file()>

If specified, attempt to write the Soop process's ID to this file.

=item B<* use_syslog()>

If true, redirect warnings and error messages to syslog.  The default is false (do not log to syslog).

=item B<* syslog_facility()>

The facility to use when logging to syslog.  The default is 'daemon'.

=item B<* syslog_ident()>

The ident to use when logging to syslog.  The default is 'sooper.'

=item B<* snoozetime()>

How long to sleep before executing tests, in seconds.  The default is 30.

=item B<* tests()>

An arrayref of code references that should be executed every I<snoozetime> seconds.  A test 
is must return true on success; a false return will skip the remaining tests, if any, send a 
HUP to the supervised process.  If a test dies, The supervisor process will send a TERM signal 
to the supervised process, then shut down (with appropriate dire complaints in the log).

=item B<* verbose()>

Turn on verbose logging.

=item B<* begin()>

Start the main program loop.  Calling this method will cause the Soop object 
to spawn the process to monitor and begin its loop.  The begin() method does not return!

=back


=head1 EXAMPLE

  my $supervisor = Soop->new(
    process => {
        cmd => '/usr/bin/ssh',
        args => [ '-N', '-L 2222:localhost:25', 'localhost' ]
    },

    verbose         => 1,
    daemonize       => 0,
    path            => '/bin',
    uid             => 1000,
    gid             => 1000,
    pid_file        => './sooptest.pid',    

    use_syslog      => 1,
    syslog_facility => 'daemon',
    syslog_ident    => 'sooptest',

    snoozetime      => 30,
    
    tests           => [
        sub {
            my $self = shift;
            print "This is a successful test.\n";
            return 1;
        },
        sub {
            my $self = shift;
			print "This test will always fail!\n";
            return 0;
        }
    ]
);
$supervisor->begin();


=head1 VERSION

This is verison 1.1 of Soop.pm

=head1 AUTHOR

Greg Boyington <greg@automagick.us>

=cut
use Moose;
use Symbol;
use Sys::Syslog;
use POSIX;
use POSIX qw/:sys_wait_h/;

require Exporter;

use vars qw/$VERSION $VERBOSE $NORESTART $PROC_PID @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $PROC $USE_SYSLOG $SYSLOG_IDENT $SYSLOG_FACILITY/;

# Set up the exporter rules.  We always export the %SIG hash and the 
# associated coderefs for signal handling.  The warn() and die() routines
# are optional exports, allowing the main:: namespace to redirect these 
# messages to syslog as we do here.j
@ISA = qw/Exporter/;
@EXPORT=qw/%SIG &REAPER &INT &HUP &TERM/;
@EXPORT_OK=qw/&warn &die :errors/;
%EXPORT_TAGS= ( errors => [ qw/&warn &die/ ] );

$VERSION=1.1;

# If non-zero, the SIG_CHLD handler will not attempt to restart the child process.
# Used by other signal handlers to prevent an endless restart loop.
$NORESTART=0;

# Package variables set by their respecitve class methods, since the signal handlers 
# will be called directly (rather than through the Soop object).
$SYSLOG_IDENT 	 	= 'sooper';
$SYSLOG_FACILITY 	= 'daemon';
$USE_SYSLOG 		= 0;
$PROC_PID			= 0;
$VERBOSE			= 0;
$PROC				= '';

# get/set class methods, Moose-style
has 'uid' 			=> ( is => 'rw', isa => 'Int', required => 0 );
has 'gid' 			=> ( is => 'rw', isa => 'Int', required => 0 );
has 'path' 			=> ( is => 'rw', isa => 'Str', required => 0, default => '/bin:/usr/bin' );
has 'daemonize' 	=> ( is => 'rw', isa => 'Bool', required => 0, default => 0 );
has 'pid_file'		=> ( is => 'rw', isa => 'Str', required => 0 );
has 'tests'			=> ( is => 'rw', isa => 'ArrayRef', required => 0, default => sub { [] } );
has 'snoozetime'	=> ( is => 'rw', isa => 'Int', required => 0, default => 30 );

# get/set class methods, with triggers to update the package variable when a change is detected
has 'verbose' 		=> ( is => 'rw', isa => 'Bool', required => 0, default => 0,
	trigger => sub {
		my $self = shift;
		$VERBOSE = $self->verbose();
	} 
);
has 'use_syslog' => ( is => 'rw', isa => 'Bool', required => 0, default => 0, 
	trigger => sub {
		my $self = shift;
		$USE_SYSLOG = $self->use_syslog();
	}
 );
has 'syslog_facility' => ( is => 'rw', isa => 'Str', required => 0, default => 'daemon',
	trigger => sub {
		my $self = shift;
		$SYSLOG_FACILITY = $self->syslog_facility();
	}
);
has 'syslog_ident' => ( is => 'rw', isa => 'Str', required => 0, default => 'Soop',
	trigger => sub {
		my $self = shift;
		$SYSLOG_IDENT = $self->syslog_ident();
	} 
);
has 'process'	=> ( 
	is 			=> 'rw', 
	isa 		=> 'HashRef', 
	required 	=> 1, 
	trigger 	=> sub { 
		my $self = shift;
		$PROC = $self->process();
	}, 
);


# whenever the child process exits, start a new proc 
# (unless the child process exits because we told it to)
sub REAPER {
	1 until ( -1 == waitpid( -1, WNOHANG ) );
	$SIG{'CHLD'} = \&REAPER;
	unless ( $NORESTART ) {
		&warn("process $PROC_PID exited; restarting...\n");
		sleep 3;
		$PROC_PID = &_start_process( $PROC );
	}
}

# we handle signals in the supervisor process to ensure that 
# the child is started/stopped/restarted as required.  The 
# default signal handlers aren't overridden until begin() is
# called (see below).
sub INT {
	&warn("Interrupt detected; sending SIGINT to $PROC_PID\n");
	$NORESTART=1;
	kill 15, $PROC_PID;
	exit 1;
}

sub HUP {
	&warn("HUP detected; sending SIGTERM to $PROC_PID and restarting\n");
	$NORESTART=1;
	kill 15, $PROC_PID;
	exec $0;
}

sub TERM {
	&warn("$0 shutting down") if $VERBOSE;
	$NORESTART=1;
	kill 15, $PROC_PID;
	exit 1;
}

# override standard warn and die with syslog calls
sub warn {
	if ( $USE_SYSLOG ) {
		openlog ($SYSLOG_IDENT, 'pid,cons', $SYSLOG_FACILITY);
		syslog 'info', @_;
		closelog();
	}
	CORE::warn @_ if $VERBOSE;
	return 1;
}
sub die {
	if ( $USE_SYSLOG ){ 
		openlog ($SYSLOG_IDENT, 'pid,cons', $SYSLOG_FACILITY);
		syslog 'info', @_;
		syslog 'err', @_;
		closelog();
	}

	# make sure we kill the child process
	$NORESTART=1;
	kill 15, $PROC_PID;

	CORE::die @_;
}

######################################################################
#
# sub begin()
#	- set up signal handlers, drop privileges, daemonize, and 
#	  call _start_process() to start up the process we're to 
#	  supervise.
#
######################################################################
sub begin {
	my $self = shift;

	# Note: We call $self->SUPER::die() in this routine to ensure that 
	# we call the appropriate die() routine; if our warn and die 
	# routines are exported into the main:: namespace, they will be 
	# called, otherwise the default (presumably CORE::*) will be.


	# Intercept signals to make sure we handle the child process properly. 
	# This works because the %SIG hash, as well as the handler coderefs, 
	# are exported into the main:: namespace.
	#
	$SIG{'CHLD'} = \&REAPER;
	$SIG{'INT'}  = 'INT';
	$SIG{'HUP'}  = 'HUP';
	$SIG{'TERM'} = 'TERM';

	# drop privileges as required
	if ( $self->uid() || $self->gid() ) {
		$main::EUID = $self->uid() if $self->uid();
		$main::EGID = $self->gid() if $self->gid();
		$self->SUPER::die( "Cannot drop privileges!" )
			unless $self->uid() == $main::EUID && $self->gid() eq $main::EGID;
		$ENV{'PATH'} = $self->path();
	}

	# daemonize, if requested
	if ( $self->daemonize() ) { 
		$self->SUPER::warn("Becoming a daemon...\n") if $VERBOSE;
		fork && exit;
	}

	# write the pid file
	if ( $self->pid_file() ) {
		open (OUT, '>' . $self->pid_file() )
			or $self->SUPER::die( "EUID $main::EUID Couldn't open pid file for writing: $!" );
		print OUT $$
			or $self->SUPER::die( "Couldn't write pid file: $!" );
		close OUT;
	}

	# start the process we're supervising.
	$PROC_PID = &_start_process( $self->process() );

	# the main loop -- sleep however long we're supposed to, 
	# then run the tests (if any).
	while (1) {
		sleep $self->snoozetime();
		$self->run_tests() if $self->tests();
	}

}

######################################################################
#
# run_tests()
#
# evaluate the code blocks defined in $self->tests(), and &die if
# any fail.
#
######################################################################
sub run_tests() {
	my $self = shift;
	for ( my $i=0; $i < scalar @{ $self->tests() }; $i++ ) {
		my $coderef = $self->tests()->[$i];
		eval { 
			unless ( my $ret = &$coderef($self) ) {
				&warn("Test $i failed! Restarting process...\n");
				kill 15, $PROC_PID;
				last;
			}
		};
		&die( $@ ) if $@;
	}
}

######################################################################
#
# _start_process()
#	- fork a child process and exec the process to supervise
#
#	parent process returns child process id; child exits
#
######################################################################
sub _start_process() {
	my $proc = shift;
	my $pid;
	my $sigset;

	# block SIGINT from killing our fork
	$sigset = POSIX::SigSet->new(SIGINT);
	sigprocmask( SIG_BLOCK, $sigset );

	# fork the child process
	&die( "fork: $!" ) unless defined( $pid = fork() );

	# unblock sigints
	$SIG{'INT'} = 'INT';
	sigprocmask(SIG_UNBLOCK, $sigset)
		or &die( "Couldn't unblock SIGINT for fork: $!\n" ) ;
		
	# parent is all done
	return $pid if $pid;

	# child execs the process
	exec $proc->{'cmd'}, @{ $proc->{'args'} };
	exit 0;
}

######################################################################
#
# sub DEMOLISH()
#	- unlink the pid file before the object is destroyed.
#
######################################################################
sub DEMOLISH () {
	my $self = shift;
	unlink $self->pid_file() or &warn("Couldn't remove pid file: $!");
}


no Moose;
__PACKAGE__->meta->make_immutable;

1;
