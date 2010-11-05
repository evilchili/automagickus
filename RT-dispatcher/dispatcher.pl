#!/usr/bin/perl
=head1 NAME

dispatcher.pl - mail preprocessor for RT

=head1 DESCRIPTION

Parses mail on STDIN for delivery to the appropriate RT queue, based on addresses
recognized in To, CC and BCC fields.  

=head1 USAGE

=over

=item procmail: 

:0 h b w {
	| /path/to/dispatcher.pl
}

=item manually:

/path/to/dispatch.pl < mbox_file

=back

=cut

use strict;
use Email::Filter;
use Email::Address;
use Getopt::Long;
use Data::Dumper;

=head1 OPTIONS

=over

=item $DEBUG (true/false)

print diagnostic messages if true

=cut
my $DEBUG=1;

=item $FAILURE ('discard'/'bounce'/'store'/'redirect')

specify how to handle messages not delivered to any queue; the default is discard.
setting 'store' will cause dispatcher to save the incoming email to the mbox file 
'dispatch_failure' in the invoking user's home directory; 'redirect' will cause 
all otherwise-unroutable mail to be sent to the 'general' queue.

=cut
my $FAILURE='bounce';

=item $REDIRECT_QUEUE

Specify the queue name that undeliverable mail should be sent to when $FAILURE eq 'redirect'

=cut
my $REDIRECT_QUEUE = 'general';

=item $RT_MAILGATE, $RT_URL

Specify the details of your RT installation here.

=cut
my $RT_MAILGATE = '/usr/local/rt/bin/rt-mailgate';
my $RT_URL		= 'http://localhost';
my $CONF_FILE	= '/usr/local/rt/etc/dispatcher_queues.conf';

# the list of domains this dispatcher supports (configured in dispatcher_queues.conf)
my %domains;

# the queue configuration
my @queue_map;

open ( IN, $CONF_FILE ) or die "Couldn't open $CONF_FILE: $!";
{
	local $/=undef;
	$_ = <IN>;
	eval($_);
	die $@ if $@;
}
close IN;

my %opts;
GetOptions( \%opts, "regexp" );
if ( $opts{'regexp'} ) {
	print q/Set($RTAddressRegexp , '/;
	print &build_RTAddressRegexp();
	print "');\n";
	exit;
}

my $failure_mbox = "~/dispatch_failure";
my $mail = Email::Filter->new( emergency => $failure_mbox );

my @queue;

# if the message has been marked as spam, push it to the spam queue immediately
if ( $mail->header("X-Spam-Flag") =~ /YES/i ) {
	warn "Spam headers detected; routed to _SPAM_ queue\n" if $DEBUG;
	push @queue, [ '_SPAM_','correspond' ];

# parse the to, cc and bcc headers to determine destination queue
} else {

	foreach ( $mail->to, $mail->cc, $mail->bcc ) {
	
		# for every recipient found in each of the headers,
		foreach my $recipient ( map { lc $_->address } Email::Address->parse($_) ) {
			
			# compare them to the pattern defined by the queue map, 
			# and remember to which queues this message should be delivered
			foreach my $qm ( @queue_map ) {
				$qm->{'regex'} ||= &queue_map_to_pattern( %$qm );			
				if ( $recipient =~ /$qm->{'regex'}/i ) {
					my $action  = $recipient =~ /-comment\@/ ? 'comment' : 'correspond';
					warn "Recipient $recipient routed to queue: $qm->{'queue'} (action: $action)\n" if $DEBUG;
					push @queue, [ $qm->{'queue'}, $action ];
				}
			}
		}
	}
}

# remove leading prefices from the subject line, to prevent new tickets being created?
#$mail->subject( $mail->subject =~ s/^(re|fwd):// );

# If no recipient addresses matched any of our queues, we have ERROR
if ( ! @queue ) {
	warn "Cannot deliver message: no identifiable recipients!\n" if $DEBUG;
	exit 1;

	if ( $FAILURE eq 'bounce' ) {
		warn "Bounced message.\n" if $DEBUG;
		$mail->reject("Your message was undeliverable.  Please verify the recipient address and resend.");

	} elsif ( $FAILURE eq 'store' ) {
		warn "Stored message in $failure_mbox\n" if $DEBUG;
		$mail->accept( $failure_mbox );

	} elsif ( $FAILURE eq 'redirect' ) {
		warn "Redirecting to $REDIRECT_QUEUE\n" if $DEBUG;
		@queue = ( [ $REDIRECT_QUEUE, 'correspond' ] );

	} else {
		warn "Discarding message\n" if $DEBUG;
		$mail->ignore;
	}

	# bye-bye
	exit(1)  unless @queue;
}

# pipe the message to rt-mailgate for every destination queue
$mail->exit(0);
foreach ( @queue ) {
	warn "Accepting to local mbox dispatch_debug\n" if $DEBUG;
	$mail->accept('~/dispatch_debug') if $DEBUG;
	my @cmd = ( $RT_MAILGATE, '--debug', '--queue', $_->[0], '--action', $_->[1], '--url', $RT_URL );
	warn "Invoking " . join (' ', @cmd) . "\n" if $DEBUG;
	$mail->pipe( @cmd );
}

exit 0;

=back

=head1 SUB-ROUTINES

=over

=item queue_map_to_pattern()

Builds a regular expression matching all possible combinations of 
email addresses as specified by an entry in the @queue_map array.  Eg:

	queue_map_to_pattern( 
		mailbox		=> 'general',
		domain		=> [ 'mydomain.com', 'myotherdomain.com' ],
		subdomains	=> 1,
		queue		=> 'general'
	)

	returns: general(?:-comment)?@(?:.*\.)?(?:mydomain\.com|myotherdomain\.com)

=cut
sub queue_map_to_pattern {
	my %args = @_;
	my $regex = $args{'mailbox'}.'(?:-comment)?';
	my $sub = '(?:.*\.)?' if $args{'subdomains'};
	my $domain .= ref $args{'domain'} eq 'ARRAY' ? 
		'(?:' . join ( '|', @{ $args{'domain'} } ) . ')' 
		: $args{'domain'};
	$domain =~ s/\./\\./g;
	return $regex . '@' . $sub . $domain;	
}

=item build_RTAddressRegexp()

Returns a regular expression suitable for the value of $RTAddressRegexp in the 
RT configuration based on the configuration in dispatcher_queues.  Useful for 
ensuring that changes to your queue configuration aren't clobbered by a stale 
RT configuration.

=cut
sub build_RTAddressRegexp() {
	return '^(?:rtdispatcher|(?:' . 
		   join ( '|', map { $_->{'mailbox'} } @queue_map ) .
		   ')(?:-comment)?)\@(?:.*\.)?(' . 
			join( '|', map { s/\./\\\./g; $_ } values %domains ) . 
		   '$';
}

=back

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
