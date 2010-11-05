#!/usr/bin/perl  -I .
#
# rsync-backup.pl
# 	- use rsync to manage remote backups
#
# Author: Greg Boyington <greg@dautomagick.us>.
# Based on the mirror bash script by Stu Sheldon <stu@actusa.net>.
#

use strict;
use File::Rsync;
use File::stat;
use Getopt::Std;
use Sys::Syslog;
use POSIX qw/:sys_wait_h/;
if ( $^O =~ /bsd|darwin/i ) {
	require Proc::ProcessTable;
}

$|=1;

my %ARGS;
my $TODAY;
my $HOUR;
my $CURRENT_LABEL;

my %spawn;

# where to find things
#
my $cp_cmd     = '/bin/cp -alf';
my $touch_cmd  = '/usr/bin/touch';
my $ssh_cmd    = '/usr/bin/ssh';
my $mount_cmd  = '/bin/mount';
my $umount_cmd = '/bin/umount';
my $tar_cmd    = '/bin/tar';
my $find_cmd   = '/usr/bin/find';

# Set this to non-zero if your copy command cannot 
# intelligently deal with symlinks (if it can, please 
# email me and tell me about it! :P)
#
my $recreate_symlinks = 1;

# format today's date.
my ($sec,$min,$h,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
$TODAY = sprintf('%04d-%02d-%02d',$year+=1900,++$mon,$mday);
$HOUR = $h;

# log output to syslog
sub log() {
	my $ident = shift;
	openlog("rsync-backup.pl", "ndelay,perror", "error");
	syslog( $ident, join( " ", @_) );
	closelog();
}

# log output to a filehandle, if given, syslog, if in debug mode, and 
# STDOUT if in verbose or debug mode.
sub notify {

	# if we were handed a filehandle, direct the output there first
	my $fh;
	if ( ref $_[0] ) {
		$fh = shift @_;
		print $fh @_;
	}

	# if the debug flag is set, echo to syslog
	&log("LOG_NOTICE", @_)
		if $ARGS{'D'};

	# finally, send it to STDOUT for verbose logging
	print @_ if $ARGS{'v'};
}

# log errors to a filehandle, if any, and syslog, and STDERR.
sub fail {

	# if we were handed a filehandle, direct the output there first
	my $fh;
	if ( ref $_[0] ) {
		$fh = shift @_;
		print $fh @_;
	}

	# now log the error to syslog and exit.
	&log("LOG_ERR", @_ );

	warn "ERROR: " . join "\n",@_;
	exit 1;
}

# set up a zombie reaper to clean up after children and 
# clear up a slot for a new child to be spawned.
$SIG{CHLD} = \&REAPER;
sub REAPER {
	my $pid;
	while ( ( $pid = waitpid(-1, &WNOHANG) ) > 0 ) {
		notify "Child process $pid has exited.\n"
			if delete $spawn{ $pid } && $ARGS{'v'};
	}
	$SIG{CHLD} = \&REAPER;
}

# an INT to the parent process should reap the children.
$SIG{INT} = $SIG{TERM} = sub {
	$SIG{CHLD} = 'IGNORE';
	fail "Interrupt detected! Terminating all child processes...";
	kill('TERM',$_) foreach keys %spawn;
};

# parse command-line arguments
getopts ('n:htvDf:',\%ARGS);
if ( $ARGS{'D'} && ! $ARGS{'v'} ) {
	$ARGS{'v'}++;
}
if ( $ARGS{'v'} ) {
	print "rsync-backup.pl Copyright (c) 2003-2009 Gold & Appel Development.\n";
	print "Beginning test run as UID $>...\n" if $ARGS{'t'};
}
if ( $ARGS{'h'} ) {
	die "Usage: $0 [-v | -D ] [ -t ] [ -h ] [ -n num ] [ -f config_file ] [ label... ]\nperldoc $0 for detailed help.\n";
}

# how many processes will we fork by default?
my $max_children;
if (! defined $ARGS{'n'} ) {
	$max_children = 5;
} elsif ( $ARGS{'n'} == 1 ) {
	warn "Warning: Refusing to spawn one child process at a time. Increase -n to 2 or more.\n";
	$max_children = 0;
} else {	
	$max_children = $ARGS{'n'};
}

if ( $max_children && $ARGS{'t'} ) {
	warn "Warning: Threaded mode is disabled for test runs.\n";
	$max_children=0;
}

# read the configuration file
my $config_file = $ARGS{'f'}||'rsync-targets';
print "Parsing configuration file '$config_file'...\n" if $ARGS{'v'};
my $conf = &readConfig($config_file);

foreach (@ARGV) {
	die "Error: unknown config block '$_'\n" unless exists $conf->{$_};
}

# do we have something to do?
die "$config_file contains no valid config blocks; exiting.\n"
	unless keys %$conf;

# ensure the executables exist and are executable
print "Checking for required executables...\n" if $ARGS{'v'};
foreach ( $cp_cmd, $touch_cmd, $ssh_cmd, $mount_cmd, $umount_cmd, $tar_cmd, $find_cmd ) {
	/(.+?)(?:\s+[\-\w]+)?$/;
	die "Required executable $1 doesn't exist or isn't executable!" unless -e $1;
}
# create an rsync object
my $rsync = File::Rsync->new( { 
#	'rsh' 			=> "trickle -s -d 500 -u 500 $ssh_cmd",
	'archive' 		=> 1, 
	'compress'		=> 1,
	'relative' 		=> 1, 
	'delete'		=> 1,
	'quiet' 		=> 0,
} ); 

my @tarballs_to_make;
my @umounts_to_do;

my @labels = @ARGV ? @ARGV : sort keys %$conf;

$max_children = scalar @labels unless $max_children < scalar @labels;
$max_children = 0 if $max_children == 1;

# if we're not going to spawn children, step through each label
# and perform the requested backup operation.
if ( $max_children==0 ) {
	&launch_backup( $_ ) while ( $_ = shift @labels );
	print "Done!\n" if $ARGS{'v'};

# If we are spawning children, we'll fork $max_children times 
# and then sleep until a child exits.  When it does, we'll spawn 
# a new process, and continue until all backup operations have 
# completed.
} else {

	while ( @labels ) {

		# spawn a new child process if we have space for another
		if ( keys %spawn < $max_children ) {
	
			my $label = shift @labels;
			chomp $label;	
			my $pid;
			if ( !defined( $pid = fork() ) ) {

				fail "Couldn't spawn a child process! ARRGH!";
	
			# child process executes the backup
			} elsif ( ! $pid ) {
				$0 = "rsync-backup.pl [$label]";
				$SIG{INT} = 'DEFAULT';
				&launch_backup( $label );	
				exit;

			# parent remembers how many children have spawned
			} else {
				$spawn{ $pid }++;
				print "spawned child $pid " . ( scalar keys %spawn ) . " of $max_children for $label.\n"
					if $ARGS{'v'};
			}

		# maximum number of processes have been spawned, so try again later.
		} else {
			sleep 1;
		}
	}

	while (scalar keys %spawn ) {
		sleep 1;
	}
	print "Done!\n"
		if $ARGS{'v'};
}
exit;


######################################################################
#
# sub roll_tarball( %args )
#	- create an archive in tar format of the given directory, 
#	  automatically splitting it into chunks as needed.
#
# %args - hash containing the following keys:
#			label	 - the config block's label
#			c		 - the config block hashref
#			wdir 	 - the working directory
#			cmd		 - the tar command to execute
#			destname - the archive's filename
#
# XXX: This whole routine is crufty and should be rewritten.
#	
######################################################################
sub roll_tarball() {
	my %args = @_;

	my $pwd = `pwd`;
	my $label = $args{'c'}->{'label'};
	if ( $ARGS{'t'} ) {
		notify "[$label] Would create a tarball of $args{'wdir'}" if $ARGS{'v'};
		next;
	}
	unless ( chdir $args{'wdir'} ) {
		notify "[$label] Couldn't change to $args{'wdir'}; skipping this tarball.";
	}

	# execute the tar and split
	system $args{cmd};

	# did we create only one file?  If so, remove the split extension
	my $tar_dir = $args{'c'}->{'snapshot-path'}.'/'.$args{'label'}.'/tarballs';
	if ( ! -e $tar_dir.'/'.$args{'destname'}.'aab' ) {
		my $tgt = $tar_dir.'/'.$args{'destname'};
		chop $tgt;
		rename $tar_dir.'/'.$args{'destname'}.'aaa', $tgt
			or notify "[$label] Couldn't rename $tar_dir/$args{'destname'}aaa $tgt: $!";
	}
	
	chdir $pwd;
}

print "Done!\n" if $ARGS{'v'};

# Time for Jell-O(tm)
exit;


######################################################################
#
# launch_backup( $label ) 
#	- perform a complete backup operation for the given config block.
#
# $label	- the config block for which to execute a backup.
#
######################################################################
sub launch_backup() {
	my $label = shift;

	$CURRENT_LABEL = $label;

	my $c = $conf->{ $label };

	my $lockfile    = $c->{'snapshot-path'}.'/'.$label.'/syncing_now';
	my $lastrunfile = $c->{'snapshot-path'}.'/'.$label.'/last_run';

	my $backupconfigfile = $c->{'snapshot-path'}.'/'.$label.'/backup.config';

	# create the directory hierarchy if need be.
	foreach my $d ( $c->{'snapshot-path'},
			  		$c->{'snapshot-path'}.'/'.$label,
				  	$c->{'snapshot-path'}.'/'.$label.'/working',
				  	$c->{'snapshot-path'}.'/'.$label.'/hourly',
				  	$c->{'snapshot-path'}.'/'.$label.'/daily',
				  	$c->{'snapshot-path'}.'/'.$label.'/weekly',
				  	$c->{'snapshot-path'}.'/'.$label.'/monthly',
				  	$c->{'snapshot-path'}.'/'.$label.'/tarballs' ) {

		if ( ! -d $d ) {
			mkdir $d or die( "[$label] Couldn't create $d: $!");
		}
	}

	my $logfile = $c->{'snapshot-path'} . '/' . $label . '/backup.log';

	open (LOG, '>' . $logfile)
		or fail "[$label] Couldn't open $logfile for writing: $!";

	my $isMounted=0;

	# We do the work in an eval {} block so that if there's 
	# an unrecoverable error on one block, we don't lose them all.
	# 
	eval { 

		# if we have mount-* options, verify the specified mount exists.
		if ($c->{'mount-point'} && $c->{'mount-dev'} ) {

			notify \*LOG, "[$label] Checking mount-* options...\n";

			$isMounted = &isMounted( $c->{'mount-dev'}, $c->{'mount-point'}, $c->{'mount-type'} );

			# If we also have mount-on-startup, try to mount the filesystem ourselves.
			if ( $c->{'mount-on-startup'} eq 'yes' && ! $isMounted ) {

				fail (\*LOG, "[$label] Cannot mount on startup without a mount-type.")
					unless $c->{'mount-type'};

				if ( $c->{'mount-flags'} ) {
					system $mount_cmd, $c->{'mount-flags'}, '-t', $c->{'mount-type'}, $c->{'mount-dev'}, $c->{'mount-point'};
				} else {
					system $mount_cmd, '-t', $c->{'mount-type'}, $c->{'mount-dev'}, $c->{'mount-point'};
				}
				if ( $@ ) {
					fail \*LOG, "[$label] Couldn't mount $c->{'mount-dev'} on $c->{'mount-point'}: $@";
				}
	
				# make sure the mount actually succeeded -- sometimes mount exits with success 
				# even though some sort of error occurred (eg. with BSD vfs.usermount).
				#
				$isMounted = &isMounted( $c->{'mount-dev'}, $c->{'mount-point'}, $c->{'mount-type'} );
				fail ( \*LOG, "[$label] Mount of $c->{'mount-dev'} failed!" ) unless $isMounted;
			}

			# squawk if we don't see our mount point.
			#
			fail ( \*LOG, "[$label] $c->{'mount-dev'} is not mounted on $c->{'mount-point'}, or is the wrong FS type." )
				unless $isMounted;

		}

		if ( $c->{'use-rsyncd'} eq 'yes' ) {
			foreach my $d ( split /:/, $c->{'path'} ) {
				my $dir = join '/', $c->{'snapshot-path'}, $label, 'working', $d;
				if ( ! -d $dir ) {
					mkdir $dir or fail ( \*LOG, "[$label] Couldn't create $dir: $!" );
				}
			}
		}

		# check for an existing lock file, and create one if necessary.
		unless ( $ARGS{'t'} ) {
			notify \*LOG, "[$label] Checking lock file $lockfile...\n";
			system ( $touch_cmd, $lockfile ) unless -e $lockfile;
			fail ( \*LOG, "[$label] Unable to create $lockfile!" ) unless -e $lockfile;
	
			# open up the lockfile and look for a process id.
			open (LOCKFILE, "+<".$lockfile) or fail ( \*LOG, "[$label] Couldn't open existing lockfile: $!" );
			flock(LOCKFILE,2)
				or fail ( \*LOG, "[$label] Couldn't flock $lockfile: $!" );
			my $pid = <LOCKFILE>;
			chomp $pid;
	
			# if we have a process id, check the process table to see if it's running.
			if ( $pid ) {

				# BSD systems can use Proc::ProcessTable 
				#
				if ( $^O =~ /bsd|darwin/i ) {
					my $t = new Proc::ProcessTable;
					foreach ( @{$t->table} ) {
						if ( $_->pid == $pid ) {
							fail ( \*LOG, "[$label] Lockfile exists for running process $pid: ".$_->cmndline );
						}
					}
				} else {
					my $running = `ps --no-heading --pid $pid`;
					fail ( \*LOG, "[$label] Lockfile existws for running process $pid: $running" )
						if $running;
				}
			}
				
			# we didn't find the old pid in the process table, so we can steal the lock.
			seek(LOCKFILE,0,0);
			print LOCKFILE $$;
			close LOCKFILE;
		}

		# back up our config block
		notify \*LOG, "[$label] Checking that $backupconfigfile is writable...\n";
		fail ( \*LOG, "[$label] $backupconfigfile is not writable by uid $>!") unless ( ! -e $backupconfigfile || -w _ );
		if ( ! $ARGS{'t'} ) {
			notify \*LOG, "[$label] Backing up config to $backupconfigfile...\n";
			open (BACKUPCONFIG, '>'.$backupconfigfile)
				or fail "[$label] Couldn't open $backupconfigfile for output: $!";
			print BACKUPCONFIG $c->{__CONFIG_BLOCK};
			close(BACKUPCONFIG);
		}
		
		# do the sync, unless we're in test mode
		notify \*LOG, "[$label] Beginning rsync transfer...\n" if ! $ARGS{'t'};
		unless ( $ARGS{'t'} ) {
			my @excludes = split(/:/,$c->{'excludes'});
			foreach my $p ( split( /:/, $c->{'path'} ) ) {
				notify \*LOG, "[$label] source: " . $c->{'hostname'}. ( $c->{'use-rsyncd'} eq 'yes' ? '::' : ':' ) . $p . "\n";
				notify \*LOG, "[$label] dest: " . $c->{'snapshot-path'}.'/'.$label.'/working' . ( $c->{'use-rsyncd'} eq 'yes' ? '/' . $p : '' ) . "\n";
				$rsync->exec( { 
					( $c->{'bandwidth-limit'} ? ( bwlimit => $c->{'bandwidth-limit'} ) : () ),
					source		=> $c->{'hostname'}. ( $c->{'use-rsyncd'} eq 'yes' ? '::' : ':' ) . $p,
					destination	=> $c->{'snapshot-path'}.'/'.$label.'/working' . ( $c->{'use-rsyncd'} eq 'yes' ? '/' . $p : '' ),
					exclude	=> \@excludes,
				} );
				my $err = &parse_rsync_errors( $rsync->err );
				fail (\*LOG, "[$label] " . $err) if $err;
			}
		}	
		notify \*LOG, "[$label] rsync transfer OK.\n" if ! $ARGS{'t'};

		notify \*LOG, "[$label] Beginning snapshot rotations...\n";

		# figure out if we've already run today.
		my $lastruntime;
		my $lastrunday;
		my $stat = stat($lastrunfile);
		if ( -e _ ) {
			# get the day of the year of the modification time of lastrunfile.
			$lastrunday = (localtime($stat->mtime))[7]; 
		}

		# if it's the first run on the first of the month, do a monthly rotation.
		if ( $mday==1 && $lastrunday != $yday ) {
			if ( $ARGS{'t'} ) {
				notify \*LOG, "[$label] Would do monthly rotation.\n";
			} else {
				&rotate_snapshot('monthly',$label,$c, \*LOG) 
			}
		}

		# if it's the first run on sunday, do a weekly rotation.
		if ( $wday==0 && $lastrunday != $yday ) {
			if ( $ARGS{'t'} ) {
				notify \*LOG, "[$label] Would do a weekly rotation.\n";
			} else {
				&rotate_snapshot('weekly',$label,$c, \*LOG);
			}
		}

		# if it's the first run on a new day, create a daily snapshot.
		if ( $lastrunday != $yday ) {
			if ( $ARGS{'t'} ) {
				notify \*LOG, "[$label] Would do a daily rotation.\n";
			} else {
				&rotate_snapshot('daily',$label,$c, \*LOG);
			}
		}	
		notify \*LOG, "[$label] Snapshot rotations OK.\n";

		# create the hourly snapshot
		unless ( $ARGS{'t'} ) {
			notify \*LOG, "[$label] Creating an hourly snapshot...\n";
			&rotate_snapshot('hourly',$label,$c, \*LOG);
		}

		# remember when we completed this run
		unless ( $ARGS{'t'} ) {
			notify \*LOG, "[$label] Updating last_run date...\n";
			system $touch_cmd, '-t', sprintf('%04d%02d%02d%02d%02d',$year,$mon,$mday,$HOUR,$min), $lastrunfile;
			if ( $@ ) {
				fail \*LOG, "[$label] Couldn't touch -t $year$mon$mday$HOUR$min $lastrunfile: $!";
			}
		}

	};

	if ($@) {
		notify \*LOG, "[$label] Backup of '$label' encountered errors:\n$@";
	}	

	# remove the lock file
	notify \*LOG, "[$label] Removing lock file...\n";
	if ( -e $lockfile ) {
		unlink $lockfile or fail( \*LOG, "[$label] Couldn't remove $lockfile!" );
	}

	# unmount the filesystem, if need be.
	if ( $c->{'umount-on-shutdown'} eq 'yes' && $isMounted ) {
		fail ( \*LOG, "[$label] Cannot unmount without a mount point; how did this happen?" )
			unless $c->{'mount-point'};
		notify \*LOG, "[$label] Unmounting $c->{'mount-point'}...\n";
		system $umount_cmd, $c->{'mount-point'};
		if ( $@ ) {
			fail \*LOG, "[$label] Couldn't unmount $c->{'mount-point'}: $@";
		}
	}

	# If we're in test mode, the final thing we test is that the backups 
	# are uptodate.  We do this by looking at the last_run file, and making 
	# sure that a successful run of this config block has happened within 
	# the allotted timespan.  If it hasn't, we immediately raise the alarm.
	#
	if ( $ARGS{'t'} ) {
		notify \*LOG, "[$label] Comparing last run date to backup schedule...\n";
		my $stat = stat($lastrunfile);
		if ( -e _ ) {

			my $hdir = $c->{'snapshot-path'}.'/'.$label.'/hourly';
			opendir ( HDIR, $hdir )
				or fail "[$label] Couldn't open hourly dir: $!";
			my $count = grep { !/^\./ } readdir(HDIR);
			closedir(DIR);
			if ( $count < $c->{'snapshot-hourly'} ) {
				my $max_time = 3600 * 24 / $c->{'snapshot-hourly'};
				fail "[$label] backup is out-of-date!" if ( time - $stat->mtime ) > $max_time;
			}			
		}
	}
	
	notify \*LOG, "[$label] " . ( $ARGS{'t'} ? 'Test run' : 'Backup' ) . " complete!\n";
	close(LOG);
}

######################################################################
#
# sub isMounted( $dev, $point, $type )
#
# determine if a given device is mounted on the specified mount point
#
######################################################################
sub isMounted() {
	my ($dev,$point,$type) = @_;
	return 0, "Must have a device and a mount point!"
		unless $dev && $point;
	my @mounts = `$mount_cmd`;
	my $m=0;
	foreach ( @mounts ) {
		if ( /^$dev on $point/ ) {
			next if ( $type && ! /\($type\b/ );
			$m=1;
			last;
		}
	}
	return $m;
}

######################################################################
#
# sub rotate_snapshot( $type, $label, $c, LOG )
#
# uses hardlinks to move around snapshots of the working directory 
# 
# $type  - must be one of 'hourly','daily','weekly', or 'monthly'
# $label - name of the config block we're working with
# $c     - the config block itself
# LOG	 - filehandle of log to write to
#
# dies on error
#
######################################################################
sub rotate_snapshot() {
	my $type  = shift;
	my $label = shift;
	my $c     = shift;
	my $LOG	  = shift;
	my ($src,@dirs);

	# create the snapshot
	# 
	if ( $type eq 'hourly' ) {

		my $wdir = $c->{'snapshot-path'}.'/'.$label.'/working';
		my $hourly_dir = sprintf('%s/%s/%s/%s_%02d/', $c->{'snapshot-path'},$label,$type,$TODAY,$HOUR);

		my $err = `$cp_cmd "$wdir" "$hourly_dir" 2>&1 |grep -vi "operation not permitted"`;
		#my $err = `$cp_cmd "$wdir" "$hourly_dir" 2>&1`;
		fail ( $LOG, "[$label] $cp_cmd failed? $err" ) if $err;

		# Since we can't create a hard link of a symlink, the cp command above will fail 
		# We therefore use rsync to copy the symlinks into the snapshot dir.
		#
		if ( $recreate_symlinks ) {

			# this is the sneaky bit.  the 'infun' coderef 
			# will use $find_cmd to locate all the symbolic links 
			# in the working directory and return them as a 
			# null-delimited list.  We remove the $wdir from the 
			# pathname of each symlink and print the list, for use  
			# as input to the files-from option of rsync.  See 
			# perldoc File::Rsync and man rsync for details.
			#
			my $symlinker = File::Rsync->new( { 
				'archive' 		=> 1, 
				'relative' 		=> 1, 
				'quiet' 		=> 1,
				'from0'			=> 1,
				'files-from'	=> '-',
				'infun'			=> sub { print map { s[$wdir][]g; $_ } `$find_cmd $wdir -type l -print0` },
			} ); 
			$symlinker->exec( {
				source 		=> $wdir,
				destination	=> $hourly_dir
			} ) or fail ( $LOG, "[$label] symlink failed:\n".join("\n",$symlinker->err) );
			
		}
		

	# if we're creating a daily snapshot, take the newest hourly snapshot
	# and move it into the daily/ directory.
	#
	} elsif ( $type eq 'daily' ) {

		opendir(DIR,$c->{'snapshot-path'}.'/'.$label.'/hourly')
			or fail ( $LOG, "[$label] Couldn't open hourly: $!" );
		@dirs = grep { !/^\./ } sort readdir(DIR);
		closedir(DIR);	
		$src = pop @dirs;

		if ( $src ) {
			rename "$c->{'snapshot-path'}/$label/hourly/$src", "$c->{'snapshot-path'}/$label/daily/$src"
				or fail ( $LOG, "[$label] Couldn't move $c->{'snapshot-path'}/$label/hourly/$src to $c->{'snapshot-path'}/$label/daily/$src: $!");
		} else {
			notify "[$label] No hourly snapshots found for $label." if $ARGS{'v'};
		}

	# if we're creating a weekly snapshot, take the newest daily snapshot
	# and move it into the weekly/ directory.
	#
	} elsif ( $type eq 'weekly' ) {

		opendir(DIR,$c->{'snapshot-path'}.'/'.$label.'/daily')
			or fail $LOG, "[$label] Couldn't open daily: $!";
		@dirs = grep { !/^\./ } sort readdir(DIR);
		closedir(DIR);	
		$src = pop @dirs;

		if ( $src ) {
			rename "$c->{'snapshot-path'}/$label/daily/$src", "$c->{'snapshot-path'}/$label/weekly/$src"
				or fail $LOG, "[$label] Couldn't move $label/daily/$src to $label/weekly/: $!";
		} else {
			notify "[$label] No daily snapshots found for $label." if $ARGS{'v'};
		}

	# if we're creating a monthly snapshot, take the newest weekly snapshot
	# and move it into the monthly/ directory.
	#
	} elsif ( $type eq 'monthly' ) {

		opendir(DIR,$c->{'snapshot-path'}.'/'.$label.'/weekly')
			or fail $LOG, "[$label] Couldn't open weekly: $!";
		@dirs = grep { !/^\./ } sort readdir(DIR);
		closedir(DIR);	
		$src = pop @dirs;

		if ( $src ) {
			rename "$c->{'snapshot-path'}/$label/weekly/$src", "$c->{'snapshot-path'}/$label/monthly/$src"
				or fail $LOG, "[$label] Couldn't move $label/weekly/$src to $label/monthly/: $!";

			# do we need to create a tarball?
			if ( lc $c->{'create-tarballs'} eq 'yes' ) {

				# create an appropriate file name for the slices
				my ($src_y,$src_m,$src_d) = ( $src =~ /(\d{4})-(\d\d)-(\d\d)/ );
				my $destname = sprintf('%s_%04d-%02d-%02d.tgz_',$label,$src_y,$src_m,$src_d);
				$destname =~ s/\//_/g;

				my $wdir = "$c->{'snapshot-path'}/$label/monthly";

				# what we're actually going to do.
				my $cmd = sprintf( '%s --preserve -czvf - %s | split -a3 -b %s - %s/%s',
                    				$tar_cmd, 
									$src, 
									$c->{'tarball-size'}, 
									$c->{'snapshot-path'}.'/'.$label.'/tarballs', 
									$destname );

				# now do it
				&roll_tarball( 
					{
						label	 => $label,
						c		 => $c,
						destname => $destname, 
						wdir 	 => $wdir, 
						cmd 	 => $cmd
				 	} 
				);
			
			}

		} else {
			notify "[$label] No weekly snapshots found for $label.\n" if $ARGS{'v'};
		}

	}
	
	# count the number of snapshots in the directory.
	#
	opendir(DIR,$c->{'snapshot-path'}.'/'.$label.'/'.$type)
		or fail $LOG, "[$label] Couldn't open $type: $!";
	@dirs = grep { !/^\./ } sort readdir(DIR);
	my $count = scalar @dirs;
	closedir(DIR);	

	# if we now have too many snapshots, 
	# delete the oldest until we're within the limit.
	#
	while ( scalar(@dirs) > $c->{'snapshots-'.$type} ) {
		my $d = shift @dirs;
		system "rm", '-rf', $c->{'snapshot-path'}.'/'.$label.'/'.$type.'/'.$d;
		fail ( $LOG, "[$label] Couldn't remove stale $type snapshot $d: $!" ) if $@;
	}

}

######################################################################
#
# sub parse_rsync_errors()
#
# Step through the errors generated by rsync and determine if any of 
# them should be considered fatal.  Errors treated as non-fatal 
# include:
#
# 	- device busy
#	- file vanished
#
######################################################################
sub parse_rsync_errors() {
	my @lines = @_;
	my @err;
	foreach ( @lines ) {
		chomp;
		next unless $_;
		next if /\(16\)$/; # 16 - device or resource busy
		next if /^file has vanished:/;
		push @err, $_;
	}
	pop @err;
	return @err ?  "rsync failed:\n" . join (" ", @err) : "";
}

######################################################################
#
# sub readConfig( $config_file )
#
# Parses the named configuration file.  dies if errors encountered.
# Returns a hashref of config blocks from the file.
#
######################################################################
sub readConfig {
	my $file = shift;
	fail "Couldn't read config file $file: $!" 
		unless -f $file;

	my %valid;
	$valid{ "$_" } = 1 
		foreach qw/
			hostname
			path
			use-rsyncd
			snapshots-hourly
			snapshots-daily
			snapshots-weekly
			snapshots-monthly
			snapshot-path
			mount-dev
			mount-point
			mount-type
			mount-flags
			mount-on-startup
			umount-on-shutdown
			excludes
			create-tarballs
			tarball-size
			bandwidth-limit
		/;

	open (CONF,$file)
		or fail "Couldn't open config file for reading: $!";

	my $label='';
	my $conf;
	my $line=0;
	my @config_block;
	while ( <CONF> ) {
		push(@config_block,$_);
		chomp;
		$line++;

		# skip blank lines and comments
		next if ( /^\s*(?:\#.*)?$/ );

		# start of a new config block
		#
		if ( /([\.\w]+)\s*\{/ ) {

			# and we haven't closed the last one, stop now.
			fail "syntax error on line $line of $file: '$label' block missing curly brace?\n"
				if $label;

			# no errors? then we're all good.
			$label = $1;

		# end of the current config block; check for required values
		} elsif ( /\s*\}/ ) {

			fail "Syntax error on line $line of $file: $label block missing required definition: 'hostname'\n" 
				unless exists $conf->{$label}->{ 'hostname' };

			fail "Syntax error on line $line of $file: $label block missing required definition: 'snapshots-hourly'\n" 
				unless exists $conf->{$label}->{ 'snapshots-hourly' };

			fail "Syntax error on line $line of $file: $label block missing required definition: 'snapshots-daily'\n" 
				unless exists $conf->{$label}->{ 'snapshots-daily' };

			fail "Syntax error on line $line of $file: $label block missing required definition: 'snapshots-weekly'\n" 
				unless exists $conf->{$label}->{ 'snapshots-weekly' };

			fail "Syntax error on line $line of $file: $label block missing required definition: 'snapshots-monthly'\n" 
				unless exists $conf->{$label}->{ 'snapshots-monthly' };

			notify "No tarball-size for $label specified; tarballs will not be created!\n"
				if lc $conf->{$label}->{'create-tarballs'} eq 'yes' && ! $conf->{$label}->{'tarball-size'};

			$conf->{$label}->{__CONFIG_BLOCK} = join("",@config_block);
			@config_block=();
			
			$label='';

		# everything else is considered to be an option line
		} elsif ( my ($key,$val) = /\s*(\S+)\s+['"]?(\S+)['"]?/ ) {

			# make sure it's in a config block.
			fail "syntax error on line $line of $file: option not inside a config block.\n"
				unless $label;

			fail "syntax error on line $line of $file: unrecognized option '$key'\n"
				unless exists $valid{ lc $key };

			# remember this option
			$conf->{$label}->{$1}=$2;
		}
	}

	# if we still have a label at this point, we didn't close the last block
	fail "syntax error on line $line of $file: '$label' block missing curly brace?\n"
		if $label;

	close CONF;
	return $conf;
}


__END__

=head1 NAME

rsync-backup.pl  --  manage backups of remote systems via rsync

=head1 SYNOPSIS

rsync-backup.pl [ SWITCHES ] [ -f /path/to/config_file ] [ label label... ]

=head1 DESCRIPTION

rsync-backup.pl uses rsync over ssh to perform backups of remote systems.  
It supports multiple host definitions, allowing you to specify unique 
remote paths, exclusions, local backup targets and so on.  You can even 
mount a filesystem before starting the backup, and unmount it upon 
completion (dangerous for multiuser environments, but handy for toasters).

rsync-backup.pl is designed to be run from cron, for multiple daily
backups and optional archiving of daily, weekly and monthly snapshots.
Snapshots are done via hard links, so disk usage is minimal, and since
rsync only transfers changes since the last run, and uses compression to
boot, bandwidth requirements are light too.

=head1 PREREQUISITES

This script requires the following packages:

=over

=item * rsync, available from http://rsync.samba.org/

=item * perl 5.x

=item * File::Rsync

=item * Proc::ProcessTable (for BSD systems)

=item * Sys::Syslog

=item * gnu cp 

=item * gnu tar 

=back

Note: On BSD systems, install the coreutils port to get gnu cp and tar.

=head1 COMMAND-LINE SWITCHES

The following switches are supported:

=over

=item B<-h>      Display short help summary

=item B<-f>      Path to the configuration file

=item B<-v>      Enable verbose logging

=item B<-D>      Enable debug logging (implies -v)

=item B<-t>      Run configuration tests; no transfers

=item B<-n>      The number of backup operations to perform at once

=item B<labels>  Execute only the named backup configurations

=back

=head1 CONFIGURATION

rsync-backup.pl requires a configuration file containing one or more 
"config blocks", which define a remote host targeted for backup.  Here's a 
sample config block:

=over

=item example {

	hostname            eg.mydomain.com
	path                /

	snapshots-hourly    4	
	snapshots-daily     7	
	snapshots-weekly    4	
	snapshots-monthly   1	

	snapshot-path       /mnt/backups

	excludes /backups/:/proc/:/dev/:tmp/:/usr/src/:/var/db/mysql/

	mount-dev           /dev/da0s1a
	mount-point         /mnt/backups
	mount-type          ufs
	mount-flags         -fu
	mount-on-startup	yes
	umount-on-shutdown	yes

	create-tarballs     yes
	tarball-size        4000m

}

=back

This block tells rsync-backup.pl to backup the entire contents of host
'eg.mydomain.com' 4 times daily.  This configuration would preseve one 
monthly backup, plus the most recent 4 weeks and the last 7 days.  It
would be advisable with this setup to archive the monthly backup to
permanent media, before it is overwritten the following month. :)  If
your snapshots are small (or your disks are large), you might save 12  
monthly backups, giving you a year's history at a glance.

You may have as many such config blocks in your config file as you like; 
rsync-backup.pl will process each one in turn.  Note that each block must 
begin with a label, used to identify this backup configuration.  

A description of the configuration options follow:

=over

=item B<* hostname>

The fully-qualified domain name, or IP address, of the host to backup.  
The host must have rsync installed, and be configuration to allow the
ssh user to run rsync.  See I<SSH Configuration>, below.

=item B<* path>

The path on the remote host you wish to back up.  You may specify multiple 
paths with a colon-separated list; one rsync call will be made for each 
path in the list.

=item B<* snapshots-hourly>

Save at most this many snapshots of the remote host in the hourly/  
directory.  You must run rsync-backup.pl at least this many times per
day.  If you run it more times than you've specified here, the oldest
hourly snapshot will be removed.

=item B<* snapshots-daily>

The number of daily snapshots to retain.  Each time the script runs, it
checks to see when it last ran -- if it was any day other than today, 
the most recent hourly snapshot is moved into the daily/ directory.  If
more than snapshots-daily snapshots already exist, the oldest is removed.

=item B<* snapshots-weekly>

The number of weekly snapshots to retain.  Weekly snapshots are created
by the first run of the script on sundays, by moving the newest existing 
daily snapshot into the weekly/ directory.  If more than snapshots-weekly 
snapshots already exist, the oldest is removed.

=item B<* snapshots-monthly>

The number of monthly snapshots to retain.  Monthly snapshots are created
on the first of the month, by moving the newest weekly snapshot into the
monthly/ directory.  If more than snapshots-monthly snapshots already
exist, the oldest is removed.


=item  B<* snapshot-path>

The local path where snapshots will be stored.  The backups for each 
host will be created as subdirectories inside snapshot-path, using the 
label from the config block.  So in the example above, the backups for
eg.mydomain.com would be created in S</mnt/backups/example>.

=item B<* excludes>

A colon (:)-separated list of path names rsync should not attempt to
backup.  Sensible things to include on this list are things like open
database files, tmp directories, and so forth.

=item B<* mount-dev, mount-point>

If values are given for both, rsync-backup.pl will try to verify that
the specified device is mounted on the specified mount point before
beginning the backup sequence.  

=item B<* mount-type>

Optional; if specified along with B<mount-dev> and B<mount-point>,
rsync-backup.pl will only launch the backup sequence if the specified
mount's filesystem matches B<mount-type>.  

This value is also passed to I<mount(1)> when attempting to mount
filesystems (see B<mount-on-startup>).

=item B<* mount-flags>

Optional additional flags to pass to I<mount(1)> eg., C<-u>.

=item B<* mount-on-startup>

Optional; if set to C<yes>, try to mount B<mount-dev> on B<mount-point>, 
using the B<mount-type> and B<mount-flags>, if specified, before 
launching rsync.  This attempt is only done if the filesystem in
question isn't already mounted.

Ignored unless both B<mount-dev> and B<mount-point> are defined.

=item B<* umount-on-shutdown>

Optional; if set to C<yes>, rsync-backup.pl will unmount the filesystem
specified by B<mount-point> when the backup sequence is complete.

=item B<* create-tarballs>

Optional; if set to C<yes>, when rsync-backup creates a monthly snapshot, 
it will also create a gzipped tar file of that snapshot, and place it in 
the tarballs/ directory.  If the resulting archive is greater in size
than the value of tarball-size, the archive will be split into chunks 
of tarball-size size.  See I<split(1)>.

=item B<* tarball-size>

The size of the files, in bytes, a tarball should be split into.  If a
'k' is appended to the value, tarball-size is interpretted as kilobytes.
If an 'm' is appended to the value, tarball-size is interpretted as
megabytes.  

Note: A tarball-size of 4000m would be a good size for writing DVD-Rs. :)

=item B<* use-rsyncd>

Optional; if set to C<yes>, rsync-backup.pl will attempt to contact the 
hose via rsyncd on the default port (879), rather than using SSH to 
initiate the connection.

=back

=head1 USAGE NOTES

=head2 Local Configuration

Before running rsync-backup.pl, edit the script and alter the values 
of the *_cmd variables to match your specific system layout.  The 
defaults should work for most systems, but was only tested on a standard
FreeBSD 6.0 installation:

=over

=item my $cp_cmd        = '/usr/local/bin/cp -alf';

=item my $touch_cmd     = '/usr/bin/touch';

=item my $ssh_cmd       = '/usr/bin/ssh';

=item my $mount_cmd     = '/sbin/mount';

=item my $umount_cmd    = '/sbin/umount';

=item my $tar_cmd       = '/usr/local/bin/bin/tar';

=item my $find_cmd      = '/usr/bin/find';

=back

=head2 cron

rsync-backup.pl is designed to run from cron.  Furthermore, to properly 
manage weekly and monthly snapshots, the script needs to run at least on
sundays, and on the first of every month.  Thus it is recommended that
you create a cron job to run the script daily, as many times as is needed
by the highest value of snapshots-daily in your config file.  For
example, the config block shown above would suggest the following crontab
entry:

=over

=item 0 0,6,12,18 * * *  /path/to/rsync-backups.pl -f conf_file

=back 

See I<crontab(5)> for details. 

=head2 Logging

As of version 2.0, a seperate log file (called backup.log) is created in 
the snapshot directory for each host.  The log files are truncated at each 
run, so no rotating is necessary.

By default no output is sent to STDOUT.  You may override this behaviour 
by specifying the -v switch; this will cause a copy of entries in each 
host's log file to be echoed to STDOUT.

Also new with version 2.0 is support for logging to syslog via Sys::Syslog.  
By default only errors are directed there; this can be overridden by enabling 
debug output (via the -D switch).  Doing so will cause all output to be 
copied to syslog in addition to STDOUT/STDERR and the host log files, as well 
as enabling various debug-only messages.

Fatal errors are always sent to syslog and to STDERR.

=head2 SSH and rsync

Unless you want to hang around and enter a password every time
rsync-backups.pl launches rsync to back up a remote host, you're going to
want to use certificate-based authentication for the ssh user.  

Additionally, if you want to do full system backups with rsync, you're
probably going to need to run rsync-backup.pl as root, and allow root to
ssh into the remote host and run rsync.  Allowing remote logins by root
can be dangerous, however.  What follows is an overview of my solution 
to this problem; B<I strongly recommend you familiarize yourself with the
security implications of this setup before blindly charging forth>.  The
author will accept no responsibility for your being foolish, yadda yadda
yadda.

=over 

=item B<1. Allow root SSH for authorized commands only>

To do this, simply set C<PermitRootLogin> to C<forced-commands-only> in
your remote host's F<sshd_config>.  Now the root user will be permitted
to login via SSH, but may only execute the command you specify in the
F<authorized_keys file>.

=item B<2. Configure root's authorized commands>

Edit root's F<authorized_keys> file on the remote host, and modify the
line containing your backup host's key thusly:

command="/root/bin/ssh_allowed.sh", ssh-dss  ...  root@backup-host

This will force every root login from backup-host to run the shell script
F<ssh_allowed.sh>.  By interrogating the C<$SSH_ORIGINAL_COMMAND>
environment variable in this script, we can decide whether or not to
permit the command to be executed.  Here's a simple F<ssh_allowed.sh>:

  #!/bin/sh 
  # 
  # spawned by ssh to execute valid commands remotely 
  # 
  case "$SSH_ORIGINAL_COMMAND" in 
      *\&*) 
          echo "Rejected" 
      ;; 
      *\;*) 
          echo "Rejected" 
      ;; 
      rsync\ --server\ --sender\ -logDtprRz\ .\ /*) 
          $SSH_ORIGINAL_COMMAND 
      ;; 
      *) 
          echo "$SSH_ORIGINAL_COMMAND" >> /var/log/root_ssh_rejected.log 
          echo "Rejected"
      ;; 
  esac 

Note: depending on your calling parameters and rsync version, the exact
sequence of arguments on the C<rsync --server> line may or may not match
this example; if your rsyncs are failing, check the rejected log to see
what args are bing passed and modify the script accordingly.

And of course, ensure your F<ssh_allowed.sh>'s permissions are set to 500 :)

=back

=head2 Restoring a split tarball

If you find yourself in the position of needing to restore a backup from
a tarball which has been split into chunks, simply copy all the pieces of
the tarball into a directory, and execute:

     % cat tarball.tgz_* | gnu-tar --preserve -xzf -

=head2 Backing up mysql databases

Trying to rsync mysql databases while mysql is running on the remote host
will result in broken tables (and kvetching lusers).  It is recommended
the remote host run mysqlhotcopy from a cron job some time before the
rsync backup is scheduled, such that rsync can backup copies of the
databases rather than the databases themselves.  Such a crontab entry
might look like this:

    2  3 * * * mysqlhotcopy --addtodest -u user --password=... dbname  \
		/path/to/backups

Consult the mysql documentation for details.  


=head1 CAVEATS

At this time, rsync-backup.pl has no brains for checking disk space
before engaging in possibly-dangerous things like creating multiple
gigantic tarballs of whole filesystems.  Be thou therefore careful with
thine tars.

=head1 VERSION

This is version 2.1 of rsync-backup.pl.

=head1 CHANGES SINCE 2.0

=over

=item -- fixed a bug where log was attempted before logfile's path existed.

=back

=head1 CHANGES SINCE 1.7

=over 

=item -- rsync-backup now forks to execute multiple backups simultaneously.

=item -- only tries to load Proc::ProcessTable on bsd-like systems.

=item -- tarball creation and unmounts now happen per-label, to play nice with threads.

=item -- verbose/debug logging reimplemented, including syslog support

=item -- added -n switch to limit number of child processes

=item -- added -D switch to enable debug output

=back

=head1 CHANGES SINCE 1.6

=over

=item -- Added support for multiple paths.

=item -- Added support for rsyncd servers with the use-rsyncd flag.

=item -- Added support for the bandwidth-limit flag.

=back

=head1 CHANGES SINCE 1.5

=over

=item -- Fixed a bug where args in the *_cmd variables would be stripped

=item -- Improved rsync error message parsing

=back

=head1 CHANGES SINCE 1.4

=over

=item -- The recreate-symlinks business introduced in 1.3 was slow (!) 
and prone to breakage; we now use rsync to copy symbolic links 
from the working directory to the snapshot directory.

=item -- Added test mode and the -v switch

=back

=head1 CHANGES SINCE 1.3

Modified behaviour of the mount options.  We can now:

=over

=item -- mount a filesystem, do the backup, then umount the filesystem;

=item -- verify a filesystem is mounted before the backup;

=item -- mount a filesystem if it isn't already mounted;

=item -- unmount a filesystem when the backup is complete, regardless of whether or not we mounted it.

=back

=head1 CHANGES SINCE 1.2

=over

=item -- Since one cannot create a hard link of a symlink, snapshots 
contained none of the symlinks in the working directory.  To resolve 
this, rsync-backup.pl now does a find of all symlinks in the working 
directory and recreates them in the newly-created hourly snapshot.  
The mtime, modes and ownership of the symlinks are all preserved.

=back

=head1 CHANGES SINCE 1.1

=over

=item -- Changed the aging scheme to move the newest snapshot from daily 
to weekly, and weekly to monthly.  Prior versions moved the oldest, which 
seems dumb.

=back

=head1 CHANGES SINCE 1.0

=over

=item -- Added support for labels on the command-line

=item -- Minor additions to documentation

=item -- Removed unused '$date' variable

=back

=head1 TO DO

=over

=item -- bandwidth-aware threading

=item -- automagick writing of monthly tarballs to cd/dvd would rock

=back

=head1 AUTHOR

rsync-backup.pl was written by Greg Boyington <greg@regex.ca>.

=head1 ACKNOWLEDGEMENTS

The basic structure of the backup scheme isn't mine; it belongs to Stu
Sheldon, <stu@actusa.net>, whose C<mirror> script I found linked on 
Mike Rubel's excellent article, "Easy Automated Snapshot-Style Backups
with Linux And Rsync."  You can read the article here:

http://www.mikerubel.org/computers/rsync_snapshots/

=head1 LICENSE AND COPYRIGHT

Copyright 2010 Greg Boyington.  All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are
permitted provided that the following conditions are met:

   1. Redistributions of source code must retain the above copyright notice, this list of
      conditions and the following disclaimer.

   2. Redistributions in binary form must reproduce the above copyright notice, this list
      of conditions and the following disclaimer in the documentation and/or other materials
      provided with the distribution.

THIS SOFTWARE IS PROVIDED BY GREG BOYINGTON ``AS IS'' AND ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

The views and conclusions contained in the software and documentation are those of the
authors and should not be interpreted as representing official policies, either expressed
or implied, of Greg Boyington.
