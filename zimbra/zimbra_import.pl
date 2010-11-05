#!/usr/bin/perl 
#
# zimbra_import 
#	- Import MAPI and ICS objects from exchange exporter into Zimbra.
#
# author: <greg@automagick.us>
#
# Copyright 2010 Greg Boyington.  All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without modification, are
# permitted provided that the following conditions are met:
# 
#    1. Redistributions of source code must retain the above copyright notice, this list of
#       conditions and the following disclaimer.
# 
#    2. Redistributions in binary form must reproduce the above copyright notice, this list
#       of conditions and the following disclaimer in the documentation and/or other materials
#       provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY GREG BOYINGTON ``AS IS'' AND ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
# FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
# ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
# ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# 
# The views and conclusions contained in the software and documentation are those of the
# authors and should not be interpreted as representing official policies, either expressed
# or implied, of Greg Boyington.
#

use strict;
use Data::Dumper;
use File::Find;
use LWP::UserAgent;
use HTTP::Request::Common qw/POST/;

my $count=0;
my $tmpdir='/tmp';

my $queued=0;
my $batchsize=0;

# used for importing email
my $zmmailbox_cmd 	= 'zmmailbox -z -m ';

# used for importing calendar entries and contacts
my $ua = LWP::UserAgent->new( agent => "ChiliPOST/0.1 " );
my $rest_url = 'https://mail:7071/home/';

sub flush_queue() {

	warn "Processing mail messages...\n";

	# process mail messages
	find sub {
		if ( -d ) {
			my ( $recipient,$folder ) = ( $File::Find::name =~ m,/spool/([^/]+)(.*), );
			next unless ( $recipient && $folder && $folder !~ m,^/Calendar, );

			$folder = 'Trash' 	if $folder =~ /^\/Deleted\s(Items|Messages)/;
			$folder = 'Sent' 	if $folder =~ /^\/Sent\s(Items|Messages)/;

			my $retried=0;
			my $res;
			do {
				# run zmmailbox to import messages in this folder
				warn "Executing: $zmmailbox_cmd $recipient addMessage -F a '$folder' '$File::Find::name'\n";
				$res = `$zmmailbox_cmd $recipient addMessage '$folder' '$File::Find::name' 2>&1`;
	
				if ( $res =~ /ERROR/ ) {
					if ( $res =~ /unknown folder/i ) {
						warn "Response ( $res ); trying to create folder...\n";
						`$zmmailbox_cmd $recipient createFolder '$folder'`
							or die "ERROR: zmmailbox_cmd had problems: $!";
					} else {
						$retried++;
					}
				} else {
					$res='';
				}

			} until ( $retried || !$res );
			die "ERROR: zmmailbox_cmd had problems: $res"
				if $res;
	
			# remove processed .msg files 
			find sub { -f && unlink $File::Find::name; }, $File::Find::name;
		}
	}, $tmpdir.'/spool/';

	warn "Processing calendar entries...\n";

	# process calendar entries
	find sub {
		if ( -f ) {
			my ( $recipient,$folder ) = ( $File::Find::name =~ m,/spool/([^/]+)(.*)/[^/]+$, );
			next unless ( $recipient && $folder =~ m,^/Calendar, );

			$folder =~ s/Calendar/Imported/;
			my $url = $rest_url . $recipient . $folder . '?fmt=ics';
		
			warn "POST: $File::Find::name to $url\n";

			{
				local $/=undef;
				open IN, $File::Find::name or die "Couldn't open $_: $!";

				my $req = HTTP::Request->new( post => $url );
				$req->content_type('application/x-www-form-urlencoded');
				$req->content( <IN> );
				$req->authorization_basic( 'administrator', 'sEcReTpAsSwOrD' );

				my $retried=0;
				my $res;
				do {
					$res = $ua->request($req);
					if ( $res->status_line =~ /404/ ) {
						warn "Response ( $res->status_line ); trying to create folder...\n";
						`$zmmailbox_cmd $recipient createFolder --view appointment '$folder'`
							or die "ERROR: zmmailbox_cmd had problems: $!";
					} else {
						$retried=1;
					}
				} until $retried;
				die $res->status_line unless $res->is_success;

				close IN;
			}

			unlink $File::Find::name
				or warn "Couldn't remove $File::Find::name: $!";
			
		}
	}, $tmpdir.'/spool/';
}

sub purge() {

	# remove the spool files
	warn "Cleaning up spool";
	find sub {
		-f && unlink $File::Find::name;	
	}, $tmpdir.'/spool/';

	# remove the tmp files
	my $pid = $$;
	find sub {
		if ( /mbox_$pid/ ) {
			unlink $File::Find::name
				or die "Couldn't unlink $File::Find::name: $!";
		}
	}, $tmpdir;

	warn "Queue flushed.\n";
}

&flush_queue();
&purge();
