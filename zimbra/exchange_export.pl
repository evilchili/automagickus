# exchange_export.pl
# 	-- export MAPI objects from an Exchange Server via Win32::OLE, 
#	   reconstruct them as MIME entities (for messsages) or ICS objects 
#	   (for calendar entries)and echo them to an instance of 
#	   zimbra_import.pl for import directly into zimbra.
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
use Win32::OLE; 
use Win32::OLE::Variant; 
use Win32::OLE::Const; 
use MIME::Parser;
use IO::String;
use IO::Socket::INET;
use Date::Calc qw/Decode_Date_US Day_of_Week_to_Text Day_of_Week Month_to_Text/;

# array of "Firstname Lastname" users to import
my @mailboxes = ("Greg Boyington");

my $start = time;

my $TEMP_DIR = q(C:\\\\Perl\\work);
my $MBOX_DIR = $TEMP_DIR . "\\mbox";
my $_DOMAIN = 'mydomain.com';

mkdir $TEMP_DIR unless -d $TEMP_DIR;
mkdir $MBOX_DIR unless -d $MBOX_DIR;

my $VERBOSE=1;
sub vprint { $VERBOSE && print @_ };

my $parser = new MIME::Parser;
$parser->output_to_core	( 1 );
$parser->tmp_to_core	( 1 );

# if the catcher isn't listening, we can't do anything.
my $import_host = 'mail';
my $zimbra_import = IO::Socket::INET->new( PeerHost => $import_host, PeerPort => 42425 )
	or die "Couldn't locate importer on $import_host:42425: $@\n";

# read the cache file, if any.  We cache results of previous runs so as to avoid
# exporting duplicated mailboxes.
#
my $CACHE;
if (  -f $TEMP_DIR.'\\cache' ) { 
	local $/=undef;
	open ( CACHE_FILE, "$TEMP_DIR\\cache" )
		or die "Couldn't open cache file: $!";
	my $VAR1;
	eval <CACHE_FILE>;
	close CACHE_FILE;
	$CACHE = $VAR1;
	$VAR1=undef;
}

# names listed on the command-line should be reimported regardless of cached data.
my %IGNORE_CACHE;
$IGNORE_CACHE{ lc $_ }++ foreach @ARGV;

# don't buffer output
$|=1;

my $ICS_TEMPLATE = <<EOF;
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Automagickus//Chili Exporter 1.0 MIMEDIR//EN
METHOD:PUBLISH
BEGIN:VTIMEZONE
TZID:(GMT-08.00) Pacific Time (US & Canada)
LAST-MODIFIED:20070209T005655Z
BEGIN:STANDARD
DTSTART:19710101T020000
TZOFFSETTO:-0800
TZOFFSETFROM:-0700
RRULE:FREQ=YEARLY;WKST=MO;INTERVAL=1;BYMONTH=11;BYDAY=1SU
END:STANDARD
BEGIN:DAYLIGHT
DTSTART:19710101T020000
TZOFFSETTO:-0700
TZOFFSETFROM:-0800
RRULE:FREQ=YEARLY;WKST=MO;INTERVAL=1;BYMONTH=3;BYDAY=2SU
END:DAYLIGHT
END:VTIMEZONE
BEGIN:VEVENT
DTSTART;TZID="(GMT-05.00) Eastern Time (US & Canada)":%s
DTEND;TZID="(GMT-05.00) Eastern Time (US & Canada)":%s
SUMMARY:%s
DESCRIPTION:%s
LOCATION:%s
ORGANIZER:%s
X-ZIMBRA-IMPORT-RECIPIENT:%s
X-ZIMBRA-IMPORT-FOLDER:%s
%s
END:VEVENT
END:VCALENDAR
EOF

# Necessary for MAPI component 
Win32::OLE->Initialize(Win32::OLE::COINIT_OLEINITIALIZE); 

# Do this rather than 'use' as that interferes with the OLE Initialize code 
my $CDO_CONST = Win32::OLE::Const->Load('Microsoft CDO.*Library'); 

# this doesn't help :/
my $CDOEX_CONST = Win32::OLE::Const->Load('Microsoft CDO For Exchange 2000 Library');


# create the new MAPI session
my $MAPI = Win32::OLE->new('MAPI.Session'); 
die "Couldn't instantiate MAPI Session: " . Win32::OLE::LastError() 
	unless defined($MAPI); 

# logon to the exchange server using the Migration Account credentials
$MAPI->logon( "Migration" );
die Win32::OLE::LastError() if Win32::OLE::LastError();

# create an interface to the global address less
my $GAL = &parse_address_book( $MAPI->AddressLists("Global Address List")->AddressEntries );

# get the list of available mailboxes in this MAPI profile
my $i=1;
my $INFOSTORES;
$INFOSTORES->{ lc $_->DisplayName } = $_
		while $_ = $MAPI->InfoStores->Item($i++);

vprint "Found $i mailboxes.\n";

eval { 
	# you're going to need this if you're dumping MAPI objects!
	local $Data::Dumper::Maxdepth = 2;

	my $count=0;
	#while ( <STDIN> ) {
	vprint qq(Processing mailboxes: ) . join (', ', @mailboxes ) . "\n";
	foreach ( @mailboxes ) {
		my ( $displayname ) = /[\s'"]*(.+?)[\s'"\r\n]*$/;
		$displayname = lc $displayname;	

		# make sure we have an infostore for the requested display name
		vprint qq(ERROR: Mailbox "$displayname" not found; skipping.\n), next unless 
			exists $INFOSTORES->{ 'mailbox - ' . $displayname };
	
		my $mailbox = $INFOSTORES->{ 'mailbox - ' . $displayname };

		my $owner = $GAL->{ $displayname }
			or vprint qq(ERROR: Couldn't find GAL entry for $displayname; skipping\n), next;

		# get the recipient account
		my $recipient = &smtp_address( $owner );

		# walk the infostore and locate all the folders therein
		vprint "Parsing " . $mailbox->DisplayName . " <$recipient>:\n";
		foreach my $folder ( &get_folders( $mailbox->RootFolder ) ) {

			my $parent = $folder;
			my @path;
			while (1) {
				last if ! $parent->Name;

				unshift @path, $parent->Name;

				# retrieve the parent folder, if any
				my $pfolder_id = $parent->Fields( $CDO_CONST->{'CdoPR_PARENT_ENTRYID'} )->Value
					or last;
				$parent = $MAPI->GetFolder( $pfolder_id, $mailbox->Id )
					or last;
				last if $parent->Name eq 'Top of Information Store';
			}
			my $folder_path = '/' . join '/', @path;

			# we're not importing contacts this way
			next if $folder_path =~ /\/(?:RSS|Junk E-Mail|Contacts|Tasks)/i;

			vprint "  - Parsing folder '$folder_path'\n";
			my $fcount = &parse_folder($folder->Id, $mailbox->Id, $recipient, $folder_path, $IGNORE_CACHE{ lc $folder_path });

			# remember how many messages we parsed in this mailbox
			$CACHE->{ $recipient }->{ 'COUNT' }->{ $mailbox->Id } = $fcount;

			vprint "  - parsed $fcount messages.\n";
			$count += $fcount;
		}
	}
	vprint "Done; exported $count messages."; };
vprint "ERROR: " . $@ if $@;

vprint "Run completed in " . ( time - $start ) . "s.\n";

# clean up after MIME::Parser
$parser->filer->purge;

# write the cache to disk, in preparation for our next run
open OUT,  '>'.$TEMP_DIR.'\\cache' 
	or die "ERROR: Couldn't open cache file for writing: $!";
print OUT Dumper($CACHE)
	or die "ERROR: Couldn't write to cache file: $!";
close OUT;

vprint "Cache updated.\n";

# Time for Jell-O(tm)
exit;

# parse_address_book()
#
# returns a hashref of AddressBookEntries for a given AddrssBook object, indexed
# by lower-case Name
sub parse_address_book() {

	my $book = shift;

	# I couldn't get the Filter() method to behave sanely, so we have to iterate :/
	my %lookup;
	for ( my $i=1; $i <= $book->Count; $i++ ) {
		my $entry = $book->Item($i);
		$lookup{ lc $entry->Name } = $entry;
	}
	return \%lookup;
}

# sub get_folders()
#
# Recursively walk a folder structure in an infostore, and return an array of 
# folder objects to be parsed.
#
sub get_folders() {
	my $folder 	= shift;
	my $indent  = shift || 0;

	$indent++;

	# the array we'll return
	my @ret = ( $folder );

	# if this folder has sub-folders, call get_folders() on them as well
	my $i=0;
	push @ret, &get_folders( $_, $indent )
		while $_ = $folder->Folders(++$i);

	return @ret;
}

# sub parse_folder()
#
# recursively parse messages found in a given folder, and return a count.
sub parse_folder() {
	my $folder_id = shift;
	my $infostore_id = shift;
	my $recipient = shift;
	my $folder_path = shift;
	my $ignore_cache = shift;
	
	# get the folder object
	my $target = $MAPI->GetFolder( $folder_id, $infostore_id );

	# step through the list of messages and hand them off to parse_message(),
	# which will turn the MAPI object into perly hash.
	#my $i= $CACHE->{ $recipient }->{ 'COUNT' }->{ $infostore_id } || 1;
	my $i=1;
	while ( $_ = $target->Messages($i++) ) {

		my $cache_key = $target->Id . ':' . $_->Id;
		next if ( ! $ignore_cache ) && exists $CACHE->{ $recipient }->{'PARSED_MESSAGES'}->{ $cache_key };

		my $msg = &parse_message( $MAPI->GetMessage( $_->Id ), $target, $recipient, $folder_path );

		&export_msg( $msg ) if $msg;

		# remember that we've parsed this message, so we can ignore it on the next run
		$CACHE->{ $recipient }->{'PARSED_MESSAGES'}->{ $cache_key }++;
	}

	return $i-2;
}

sub build_mime() {
	my $mapi_msg = shift;
	my $nofatal = shift;

	my $msg;

	# So uh... the HTML-encoded body shows up, at least on my system, in varying fields from 
	# message to message, and never anywhere sensible; often in the CdoTmz* addresses.  I can 
	# only assume this is because I'm not interrogating the Fields collection correctly, but 
	# since I can't find any documentation for this, and it's taken me several days to get this 
	# far...well, fsck it.  We iterate over the entirely of the defined constants and look for 
	# HTML.
	#
	# Note that, at least with Exchange Server 2007, you can access:
	#
	#	$mapi_msg->Fields->Item( $CDO_CONST->{ 'CdoPR_RTF_COMPRESSED' } )
	#
	# But you'll have to find your own way of decompressing it.  Good luck with that.
	#
	my $html = &find_html_body( $mapi_msg );

	# create an email message object by parsing the headers
	my $headers	= &get_prop( $mapi_msg, 'CdoPR_TRANSPORT_MESSAGE_HEADERS' );
	if ( $headers ) {
		$headers =~ s/^Microsoft Mail.+?\r?\n//si;
	} else {

		# RFC822 headers are missing, so cobble together the bare minimum
		my $to = $mapi_msg->Recipients ? $mapi_msg->Recipients->Name : '';
		$to ||= &get_prop($mapi_msg, 'CdoPR_DISPLAY_TO' );
		my $from = $mapi_msg->Sender ? $mapi_msg->Sender->Name . ' <' . $mapi_msg->Sender->EmailAddress . '>' : '';

		# Convert the date from 9/16/2008 7:59:32 AM format
		# to Thu, 16 Sep 2008 7:59:32
		my $date = $mapi_msg->TimeSent || &get_prop($mapi_msg, 'CdoPR_CLIENT_SUBMIT_TIME' );
		my ( $mm,$dd,$yyyy,$time ) = ( $date =~ /(\d+)\/(\d+)\/(\d+)\s(\d+:\d+:\d+\s.+)/ );
		$date = sprintf("%.3s, %02d %.3s %04d %s", 
			Day_of_Week_to_Text( Day_of_Week($yyyy,$mm,$dd) ),
			$dd,
			Month_to_Text( $mm ),
			$yyyy,
			$time
		) if ( $mm && $dd && $yyyy );
		$headers = join "\n", 
					'From: ' 	. $from, 
					'To: ' 		. $to,
					'Cc: '		. ( &get_prop($mapi_msg, 'CdoPR_DISPLAY_CC' ) ),
					'Bcc: '		. ( &get_prop($mapi_msg, 'CdoPR_DISPLAY_BCC' ) ),
					'Subject: ' . ( $mapi_msg->Subject || &get_prop($mapi_msg,  'CdoPR_CONVERSATION_TOPIC' ) ),
					'Date: ' 	. $date;
	}
				
	my $io = IO::String->new( $headers );
	$io->binmode();
	$msg = $parser->parse($io);

	# If we located the HTML-encoded body, we'll create a proper multipart message
	# and attach the html as a separate part.  
	if ( $html ) {
		$msg->make_multipart;
		$msg->parts([]);
		$msg->attach( 
			Data	=> $html->Value,
			Type	=> "text/html",
		);

	# If there's no HTML, then we need to force message into plaintext.  Since 
	# the content-type is probably multipart/alternative, or application/ms-tnef, 
	# it's only going to confuse MIME::Entity since we're going to attach the plain 
	# text from $mapi_msg.  So we strip out the content headers, attach a text/plain 
	# part, and then collapse the whole thing into a properly-encoded singlepart message.
	#
	# What could be simpler?
	} else {
		$msg->head->replace("Content-Type","text/plain");
		$msg->attach( Data => $mapi_msg->Text, Type => "text/plain" );
		$msg->make_singlepart;
	}
	
	$msg->head->set("To", q/"Unknown (Exchange Server Data Missing)"/ )
		unless $msg->head->get("To");

	unless ( $nofatal ) {
		foreach my $h (qw/From To Date/) {
			die "Missing $h\n" . &dump_properties($mapi_msg) . "\n" . $msg->as_string
				unless $msg->head->get($h);
		}
	}

	return $msg;
}

# sub parse_message() 
#
# Transform a MAPI message object into a MIME entity and write the results to disk
#
sub parse_message() {
	my $mapi_msg = shift;
	my $folder =  shift;
	my $recipient = shift;
	my $folder_path = shift;

	my $msg;

	if ( ! $mapi_msg ) {

		warn "MAPI object isn't defined -- WTF?!";
		return;

	# parse calendar entries create ICS versions
	} elsif ( $mapi_msg->Type =~ /Appointment|Meeting/ ) {

		$msg = &build_ics( $mapi_msg, $folder, $recipient );
	
	} elsif ( $mapi_msg->Type =~ /Contact$/ ) {

		#vprint "Skipping contact data.\n";

	# treat everything else as an email 
	} else {

		#build a MIME version
		$msg = &build_mime( $mapi_msg, ( $folder_path =~ /Drafts|Deleted/ ? "nofatal" : "" ) );

		warn "Cannot export '" . $mapi_msg->Subject . "'; no From address found in headers?\n", next
			unless $msg->head->get('From');

		# add any attachments
		$msg = &parse_attachments( $mapi_msg, $msg )
			if $mapi_msg->Attachments->Count;

		# zmmailbox requires this to properly set the date on the imported message
		$msg->head->add( "X-Zimbra-Received", $msg->head->get("Date",0) );
	
		# our parser requires the following headers to properly invoke zmmailbox
		$msg->head->add( "X-Zimbra-Import-Recipient", $recipient );
		
		$msg->head->add( "X-Zimbra-Import-Folder", $folder_path );


		# progress report
		chomp( my $from = $msg->head->get('From') );
		chomp( my $subj = $msg->head->get('Subject') );
		vprint "    - $from\n";
	}

	return $msg;
}


# sub build_ics()
#
# Create an ICS scalar from a calendar appointment
#
sub build_ics() {
	my $mapi_msg = shift;
	my $folder = shift;
	my $recipient = shift;

	my $fldr = $folder->Name;

	my $startdate	= &usdate2ical( &get_prop( $mapi_msg, 'CdoPR_START_DATE' ) );
	my $enddate		= &usdate2ical( &get_prop( $mapi_msg, 'CdoPR_END_DATE' ) );
	my $importance	= $mapi_msg->Importance;
	my $subject		= $mapi_msg->Subject;
	my $organizer	= 'MAILTO:' . &smtp_address( $mapi_msg->Sender || $mapi_msg );
	my $desc		= $mapi_msg->Text;
	$desc =~ s/\r?\n/\\n/sig;

	my $location = &get_prop( $mapi_msg, 'CdoPR_LOCATION' );
	( $location ) = ( $desc =~ /Where:.s*(\.+)\\n/s )
		unless $location;

	# build the list of attendees, making some glib assumptions
	my $i=0;
	my @a;

	while ( my $recip = $mapi_msg->Recipients->Item(++$i)) {

		my $rsvp = $recip->meetingResponseStatus ? 'TRUE' : 'FALSE';

		my $smtp = &smtp_address( $recip->AddressEntry || $recip );
		die "NO ADDRESS found for " . $recip->DisplayName. ": ".Dumper($recip)
			unless $smtp;

		push @a, q(ATTENDEE;ROLE=REQ-PARTICIPANT;RSVP=).$rsvp.q(;CN=") . $recip->DisplayName . q(";) . 
				 q(PARTSTAT=NEEDS-ACTION:MAILTO:) . $smtp;
	}			
	my $attendees= join "\n", @a;

	# progress report
	my $sd = &get_prop( $mapi_msg, 'CdoPR_START_DATE' ) || "";
	vprint "    - $sd: $subject\n";

	return sprintf($ICS_TEMPLATE,$startdate,$enddate,$subject,$desc,$location,$organizer,$recipient,$fldr,$attendees);
}


# sub parse_attachments()
#
# Download attachments for  given message and add them to the MIME version.
#
sub parse_attachments() {
	my $mapi_msg = shift;
	my $msg = shift;

	# Download attachments
	my $i=0;
	while ( my $a = $mapi_msg->Attachments->Item( ++$i ) ) {

		# download the attachment
		my $f = sprintf('%s\\attach_%d_%03d', $TEMP_DIR, $$, $i );
		vprint "      - Downloading attachment " . $a->Name . "...\n";

		eval {
			$a->WriteToFile( $f );
			die Win32::OLE::LastError() if Win32::OLE::LastError();
		};
		if ( ! $@ ) {

			$msg->attach(
				Path		=> $f,
				Filename	=> $a->Name,
				Type		=> 'application/octet-stream',
			);

		# if the Attachment object doesn't have a WriteToFile method, it's probably
		# some awesome encapsulated meeting invite or .eml or something.
		} elsif ( $@ =~ /MAPI_E_NO_SUPPORT/ ) {

			my $newmsg = &build_mime( $a->Source, "nofatal" );
			$msg->add_part( $_ ) foreach $newmsg->parts();
			$msg->head->add('X-From-EML-Attachment',"yes");
			next;

		} else {
			warn $@;
		}
	}
	return $msg;
}

# export the message as an mbox file, with additional headers required for 
# zimbra to correctly import the message.
sub export_msg() {
	my $msg = shift;
	print $zimbra_import ( ref $msg ? $msg->as_string : $msg ) . chr(0) . "\n"
		or die "Couldn't export message to catcher: $!";
}


# sub smtp_address() 
#
# return the smtp address for a given AddressEntry object
#
sub smtp_address() {
	my $ae = shift or return;

	# Return the cached value if we've processed this addressentry before
	if ( ! exists ( $CACHE->{'SMTP'}->{ $ae->Id  } ) ) {

		# if the entry as the PR_SMTP_ADDRESS field, use that...
		my $smtp = $ae->Fields->Item( $CDO_CONST->{'CdoPR_SMTP_ADDRESS'} ) || $ae->Address;

		# ...extract the user portion from the x500 address if the addy is in that format.
		$smtp =~ s/.*\/cn=(.+)(?:\@.*)?$/$1/ig;
		$smtp =~ s/_username07//i;	# this is the account name that runs your hosted exchange instance
		
		# or munge the display name, to which ->Address seems to default,
		# into the user portion.
		$smtp ||= $ae->Address;
		$smtp =~ s/\s/\./;

		# append the domain, if we don't have it yet.
		$smtp .= '@' . $_DOMAIN
			unless $smtp =~ /\@/;

		# handle legacy aliases
		$smtp =~ s/RaumPalacios/raum\.palacios/;
		$smtp =~ s/MarkMacVicar/mark\.macvicar/;
		$smtp =~ s/AndrewRWhalley/andrew\.whalley/;
		$smtp =~ s/AaronDwyer/aaron\.dwyer/;
		$smtp =~ s/BillLeetham/bill\.leetham/;

		$CACHE->{'SMTP'}->{ $ae->Id } = $smtp;
	}

	return $CACHE->{'SMTP'}->{ $ae->Id };
}

sub infostore2account() {
	my $i = shift;
	return { 
		address		=> &smtp_address( $i->AddressEntry ),
		password	=> '',
		displayName	=> $i->DisplayName,
		givenName	=> $i->Displayname,
		surname		=> ''	
	}
}

sub usdate2ical () {
	my ( $mm,$dd,$yyyy, $hh,$min,$sec,$pm ) = ( $_[0] =~ m[(\d+)/(\d+)/(\d+) (\d+):(\d+):(\d+)\s*(\w\w)] );
	$hh += 12 if $pm eq 'PM';

	return sprintf( '%04d%02d%02dT%02d%02d%02d', $yyyy, $mm, $dd, $hh, $min, $sec );
}

sub find_html_body() {
	my $mapi_msg = shift;
	my $html;
	foreach my $k ( keys %$CDO_CONST ) {
		$html = $mapi_msg->Fields->Item( $CDO_CONST->{ $k } )
			or next;
		last if $html->Value =~ /<br\s*\/?>/si;
	}
	return $html;
}
	
sub get_prop() {
	warn "Unknown constant: $_[1]", return undef 
		unless exists $CDO_CONST->{ $_[1] };
	return undef unless $_[0]->Fields->Item( $CDO_CONST->{ $_[1] } );
	return  $_[0]->Fields->Item( $CDO_CONST->{ $_[1] } )->Value;
}

sub dump_properties() {
	my $obj = shift;
	die "No Fields collection found: ".Dumper($obj) unless ref $obj->Fields;
	die "Fields collection is empty." unless $obj->Fields->Count;
	foreach my $k ( grep { /^CdoPR_/ } keys %$CDO_CONST ) {
		my $v = $obj->Fields->Item( $CDO_CONST->{ $k } ) or next;
		print "$k => " . $v->Value . "\n";
	}
}
