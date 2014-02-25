#
#    func.pm - func NMIS Perl Package - Network Mangement Information System
#    Copyright (C) 2000,2001 Sinclair InterNetworking Services Pty Ltd
#    <nmis@sins.com.au> http://www.sins.com.au
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
package func;

require 5;

use strict;
use Fcntl qw(:DEFAULT :flock);

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

use Exporter;

$VERSION = 1.00;

@ISA = qw(Exporter);

@EXPORT = qw(	
		getArguements
		getCGIForm
		setDebug
		convertIfName
		convertIfSpeed
		convertLineRate
		rmBadChars
		mediumInterface
		shortInterface
		returnDateStamp
		returnDate
		returnTime
		convertMonth
		convertSecsHours
		convertTime
		convertTimeLength
		convertUpTime
		eventNumberLevel
		colorTime
		colorStatus
		eventColor
		eventLevelSet
		checkHostName
		readPasswordFile
		readGroupFile
		
		alphanumerically
		backupFile

		$true
		$false
	);

@EXPORT_OK = qw(	
		@interfaceTable 
		%ifDescrTable 
		%systemTable 
		%eventTable
		%nodeTable
		%linkTable
		$eventCount
	);

# Set the default file locations if not specified in configuration file.
my %config;

# Nice Variables for Interface Stuff
my @interfaceTable;
my $interfaceTableNum;
my %ifDescrTable;
my %ifTypeDefs;
my $eventCount;
my $true = 1;
my $false = 0;

# System Info Hash
my %systemTable;

# Interface Information Table
my %interfaceInfo;

# Outage Table 
my %outageTable;

# A hash of all the node details
my %nodeTable;
my %nodeCount;
my %groupTable;

# Event table for groovy events
my %eventTable;

# A hash of all the link details
my %linkTable;

# Debug Option
my $debug = $false;

my $groupFile = "/etc/group";
my $passwdFile = "/etc/passwd";
my $shadowFile = "/etc/shadow";

sub getArguements {
	my @argue = @_;
	my (%nvp, $name, $value, $line, $i);
	for ($i=0; $i <= $#argue; ++$i) {
	        if ($argue[$i] =~ /.+=/) {
	                ($name,$value) = split("=",$argue[$i]);
	                $nvp{$name} = $value;
	        } 
	        else { print "Invalid command argument: $argue[$i]\n"; }
	}
	return %nvp;
}

sub getCGIForm {
	my $buffer = shift;
	my (%FORM, $name, $value, $pair, @pairs);
	@pairs = split(/&/, $buffer);
	foreach $pair (@pairs) {
	    ($name, $value) = split(/=/, $pair);
	    $value =~ tr/+/ /;
	    $value =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
	    $FORM{$name} = $value;
	}
	return %FORM;	
}

sub convertIfName {
	my $ifName = shift;
	return "" unless defined $ifName;
	$ifName =~ s/\W+/-/g;
	$ifName =~ s/\-$//g;
	$ifName = lc($ifName);
	return $ifName
}

sub rmBadChars {
	my $intf = shift;
	$intf =~ s/\x00//g;
	$intf =~ s/'//g;		# PIX interface descr need these removed
	$intf =~ s/,//g;		# all descr need "," removed else .csv will parse incorrectly.
	return $intf;
}

sub convertIfSpeed {
	my $ifSpeed = shift;

	if ( $ifSpeed eq "auto" ) { $ifSpeed = "auto" }
	elsif ( $ifSpeed == 1 ) { $ifSpeed = "auto" }
	elsif ( $ifSpeed eq "" ) { $ifSpeed = "N/A" }
	elsif ( $ifSpeed == 0 ) { $ifSpeed = "N/A" }
	elsif ( $ifSpeed < 2000000 ) { $ifSpeed = $ifSpeed / 1000 ." Kbps" }
	elsif ( $ifSpeed < 1000000000 ) { $ifSpeed = $ifSpeed / 1000000 ." Mbps" }
	elsif ( $ifSpeed >= 1000000000 ) { $ifSpeed = $ifSpeed / 1000000000 ." Gbps" }

	return $ifSpeed;
}

sub convertLineRate {
	my $bits = shift;

	if ( ! $bits ) { $bits = 0 }
	elsif ( $bits < 1000 ) { $bits = $bits ." bps" }
	elsif ( $bits < 2000000 ) { $bits = $bits / 1000 ." Kbps" }
	elsif ( $bits < 1000000000 ) { $bits = $bits / 1000000 ." Mbps" }
	elsif ( $bits >= 1000000000 ) { $bits = $bits / 1000000000 ." Gbps" }

	return $bits;
}

sub mediumInterface {
	my $shortint = shift;
	
	# Change the Names of interfaces to shortnames
	$shortint =~ s/PortChannel/pc/gi;
	$shortint =~ s/TokenRing/tr/gi;
	$shortint =~ s/Ethernet/eth/gi;
	$shortint =~ s/FastEth/fa/gi;
	$shortint =~ s/GigabitEthernet/gig/gi;
	$shortint =~ s/Serial/ser/gi;
	$shortint =~ s/Loopback/lo/gi;
	$shortint =~ s/VLAN/vlan/gi;
	$shortint =~ s/BRI/bri/gi;
	$shortint =~ s/fddi/fddi/gi;
	$shortint =~ s/Async/as/gi;
	$shortint =~ s/ATM/atm/gi;
	$shortint =~ s/Port-channel/pchan/gi;
	$shortint =~ s/channel/chan/gi;
	$shortint =~ s/dialer/dial/gi;
	
	return($shortint);
}

sub shortInterface {
	my $shortint = shift;
	
	# Change the Names of interfaces to shortnames
	$shortint =~ s/FastEthernet/f/gi;
	$shortint =~ s/GigabitEthernet/g/gi;
	$shortint =~ s/Ethernet/e/gi;
	$shortint =~ s/PortChannel/pc/gi;
	$shortint =~ s/TokenRing/t/gi;
	$shortint =~ s/Serial/s/gi;
	$shortint =~ s/Loopback/l/gi;
	$shortint =~ s/VLAN/v/gi;
	$shortint =~ s/BRI/b/gi;
	$shortint =~ s/fddi/fddi/gi;
	$shortint =~ s/Async/as/gi;
	$shortint =~ s/ATM/atm/gi;
	$shortint =~ s/Port-channel/pc/gi;
	$shortint =~ s/channel/chan/gi;
	$shortint =~ s/dialer/d/gi;
	$shortint =~ s/-aal5 layer//gi;
	$shortint =~ s/ /_/gi;
	$shortint =~ s/\//-/gi;
	$shortint = lc($shortint);
	
	return($shortint);
}

#Function which returns the time
sub returnDateStamp {
	my $time = shift;
	if ( $time == 0 ) { $time = time; }
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	if ($year > 70) { $year=$year+1900; }
	        else { $year=$year+2000; }
	if ($hour<10) {$hour = "0$hour";}
	if ($min<10) {$min = "0$min";}
	if ($sec<10) {$sec = "0$sec";}
	# Do some sums to calculate the time date etc 2 days ago
	$wday=('Sun','Mon','Tue','Wed','Thu','Fri','Sat')[$wday];
	$mon=('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')[$mon];
	return "$mday-$mon-$year $hour:$min:$sec";
}

sub returnDate{
	my $time = shift;
	if ( $time == 0 ) { $time = time; }
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	if ($year > 70) { $year=$year+1900; }
        else { $year=$year+2000; }
	$mon=('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec')[$mon];
	return "$mday-$mon-$year";
}

sub returnTime{
	my $time = shift;
	if ( $time == 0 ) { $time = time; }
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime($time);
	if ($year > 70) { $year=$year+1900; }
	        else { $year=$year+2000; }
	if ($hour<10) {$hour = "0$hour";}
	if ($min<10) {$min = "0$min";}
	if ($sec<10) {$sec = "0$sec";}
	return "$hour:$min:$sec";
}

sub convertMonth {
	my $number = shift;

	$number =~ s/01/January/;
	$number =~ s/02/February/;
	$number =~ s/03/March/;
	$number =~ s/04/April/;
	$number =~ s/05/May/;
	$number =~ s/06/June/;
	$number =~ s/07/July/;
	$number =~ s/08/August/;
	$number =~ s/09/September/;
	$number =~ s/10/October/;
	$number =~ s/11/November/;
	$number =~ s/12/December/;

	return $number;
}

sub convertSecsHours {
	my $seconds = shift ;
	my $timestamp;
	my $hours;
	my $minutes;
	my $minutes2;
	my $seconds2;

	if ($seconds < 60) {
		$timestamp = "00:00:$seconds";
	}# Print Seconds
	elsif ($seconds < 3600) {
		$seconds2 = $seconds % 60;
		$minutes = ($seconds - $seconds2) / 60;
		$seconds2 =~ s/(^[0-9]$)/0$1/g;
		$minutes =~ s/(^[0-9]$)/0$1/g;
		$timestamp = "00:$minutes:$seconds2";
	}# Calculate and print minutes.
	else { 
		$seconds2 = $seconds % 60;
		$minutes = ($seconds - $seconds2) / 60;
		$minutes2 = $minutes % 60;
		$hours = ($minutes - $minutes2) / 60;
		$seconds2 =~ s/(^[0-9]$)/0$1/g;
		$minutes2 =~ s/(^[0-9]$)/0$1/g;
		if ( $hours < 10 ) { $hours = "0$hours"; }
		$timestamp = "$hours:$minutes2:$seconds2";
	}# Calculate and print hours.

	return $timestamp;

} # end convertSecsHours

# 3 Mar 02 - Integrating Trent O'Callaghan's changes for granular graphing.
sub convertTime {
	my $amount = shift;
	my $units = shift;
	my $timenow = time;
	my $newtime;

	if ( $units eq "" ) { $units = "days" }
	else { $units = $units }
	# convert length code into Graph start time
	if ( $units eq "minutes" ) { $newtime = $timenow - $amount * 60; }
	elsif ( $units eq "hours" ) { $newtime = $timenow - $amount * 60 * 60; }
	elsif ( $units eq "days" ) { $newtime = $timenow - $amount * 24 * 60 * 60; }
	elsif ( $units eq "weeks" ) { $newtime = $timenow - $amount * 7 * 24 * 60 * 60; }
	elsif ( $units eq "months" ) { $newtime = $timenow - $amount * 31 * 24 * 60 * 60; }
	elsif ( $units eq "years" ) { $newtime = $timenow - $amount * 365 * 24 * 60 * 60; }

	return $newtime;
}

# 3 Mar 02 - Integrating Trent O'Callaghan's changes for granular graphing.
sub convertTimeLength {
	my $amount = shift;
	my $units = shift;
	my $newtime;
	
	# convert length code into Graph start time
	if ( $units eq "minutes" ) { $newtime = $amount * 60; }
	elsif ( $units eq "hours" ) { $newtime = $amount * 60 * 60; }
	elsif ( $units eq "days" ) { $newtime = $amount * 24 * 60 * 60; }
	elsif ( $units eq "weeks" ) { $newtime = $amount * 7 * 24 * 60 * 60; }
	elsif ( $units eq "months" ) { $newtime = $amount * 31 * 24 * 60 * 60; }
	elsif ( $units eq "years" ) { $newtime = $amount * 365 * 24 * 60 * 60; }

	return $newtime;
}

sub convertUpTime {
	my $timeString = shift;
	my @x;
	my $days;
	my $hours;
	my $seconds;

	$timeString =~ s/  |, / /g;
	
	## KS 24/3/2001 minor problem when uptime is 1 day x hours.  Fixed now.
	if ( $timeString =~ /day/ ) {
		@x = split(/ days | day /,$timeString);
		$days = $x[0];
		$hours = $x[1];
	}
	else { $hours = $timeString; }
	# Now days are a number
	$seconds = $days * 24 * 60 * 60;
	
	# Work on Hours
	@x = split(":",$hours);
	$seconds = $seconds + ( $x[0] * 60 * 60 ) + ( $x[1] * 60 ) + $x[2];
	return $seconds;	
}

sub eventNumberLevel {
	my $number = shift;
	my $level;

	if ( $number == 1 ) { $level = "Normal"; }
	elsif ( $number == 2 ) { $level = "Warning"; }
	elsif ( $number == 3 ) { $level = "Minor"; }
	elsif ( $number == 4 ) { $level = "Major"; }
	elsif ( $number == 5 ) { $level = "Critical"; }
	elsif ( $number >= 6 ) { $level = "Fatal"; }
	else { $level = "Error"; }

	return $level;
}

sub colorTime {
	my $time = shift;
	my $color = "";
	my ($hours,$minutes,$seconds) = split(":",$time);

	if ( $hours == 0 and $minutes <= 4 )  { $color = "#FFFFFF"; }
	elsif ( $hours == 0 and $minutes <= 5 )  { $color = "#FFFF00"; }
	elsif ( $hours == 0 and $minutes <= 15 ) { $color = "#FFDD00"; }
	elsif ( $hours == 0 and $minutes <= 30 ) { $color = "#FFCC00"; }
	elsif ( $hours == 0 and $minutes <= 45 ) { $color = "#FFBB00"; }
	elsif ( $hours == 0 and $minutes <= 60 ) { $color = "#FFAA00"; }
	elsif ( $hours == 1 ) { $color = "#FF9900"; }
	elsif ( $hours <= 2 ) { $color = "#FF8800"; }
	elsif ( $hours <= 6 ) { $color = "#FF7700"; }
	elsif ( $hours <= 12 ) { $color = "#FF6600"; }
	elsif ( $hours <= 24 ) { $color = "#FF5500"; }
	elsif ( $hours > 24 ) { $color = "#FF0000"; }

	return $color;
}

sub colorStatus {
	my $status = shift;
	my $color = "";

	if ( $status eq "up" ) { $color = "#00FF00"; }
	elsif ( $status eq "down" ) { $color = "#FF0000"; }
	elsif ( $status eq "testing" ) { $color = "#FFFF00"; }
	elsif ( $status eq "null" ) { $color = "#FFFF00"; }
	else { $color = "#FFFFFF"; }

	return $color;
}
# updated EHG2004
# see http://www.htmlhelp.com/icon/hexchart.gif
# these are also listed in nmis.css - class 'fatal' etc.
#
sub eventColor {
	my $event_level = shift;
	my $color;

 	if ( $event_level =~ /fatal|^0$/i ) { $color = "#FF0000" }
 	elsif ( $event_level =~ /critical|^1$/i ) { $color = "#CC3300" }
 	elsif ( $event_level =~ /major|traceback|^2$/i ) { $color = "#FF6600" }
 	elsif ( $event_level =~ /minor|^3$/i ) { $color = "#FF9900" }
 	elsif ( $event_level =~ /warning|^4$/i ) { $color = "#FFCC00" }
 	elsif ( $event_level =~ /error|^5$/i ) { $color = "#FFFF00" }
 	elsif ( $event_level =~ /normal|^[67]$/i ) { $color = "#00FF00" }
 	elsif ( $event_level =~ /up/i ) { $color = "#00FF00" }
 	elsif ( $event_level =~ /down/i ) { $color = "#FF0000" }
 	elsif ( $event_level =~ /unknown/i ) { $color = "#FFFFFF" }
 	else { $color = "#FFFFFF" }
	return $color;
} # end eventColor

sub eventLevelSet {
	my $event_level = shift;
	my $new_level;
	
 	if ( $event_level =~ /fatal/i or $event_level =~ /^0$/ ) { $new_level = "Fatal" }
 	elsif ( $event_level =~ /critical/i or $event_level == 1 ) { $new_level = "Critical" }
 	elsif ( $event_level =~ /major|traceback/i or $event_level == 2 ) { $new_level = "Major" }
 	elsif ( $event_level =~ /minor/i or $event_level == 3 ) { $new_level = "Minor" }
 	elsif ( $event_level =~ /warning/i or $event_level == 4 ) { $new_level = "Warning" }
 	elsif ( $event_level =~ /error/i or $event_level == 5 ) { $new_level = "Error" }
 	elsif ( $event_level =~ /normal/i or $event_level == 6 or $event_level == 7 ) { $new_level = "Normal" }
 	else { $new_level = "unknown" }

	return $new_level;
} # end eventLevel

sub checkHostName {
	my $node = shift;
	my @hostlookup = gethostbyname($node);
	if ( $hostlookup[0] =~ /$node/i or $hostlookup[1] =~ /$node/i ) { return "true"; }
	else { return "false"; }
}

sub readPasswordFile {

	my %passwdHash;
	my @splitline;

	#open (INFILE, "<$passwdFile")
	sysopen(INFILE, "$passwdFile", O_RDONLY) or die "Couln't open file $passwdFile";
	flock(INFILE, LOCK_SH) or warn "can't lock filename: $!";
	while (<INFILE>){
		chomp; 
		@splitline = split(":",$_);
		$passwdHash{$splitline[0]}{username} = $splitline[0];
     		$passwdHash{$splitline[0]}{uid} = $splitline[2];
     		$passwdHash{$splitline[0]}{gid} = $splitline[3];
     		$passwdHash{$splitline[0]}{descr} = $splitline[4];
     		$passwdHash{$splitline[0]}{home} = $splitline[5];
     		$passwdHash{$splitline[0]}{shell} = $splitline[6];
	}
	close(INFILE) or warn "can't close filename: $!";

	if ( -r $shadowFile ) {
		#open (INFILE, "<$shadowFile")
		sysopen(INFILE, "$shadowFile", O_RDONLY) or die "Couln't open file $shadowFile";
		flock(INFILE, LOCK_SH) or warn "can't lock filename: $!";
		while (<INFILE>){
			chomp; 
			@splitline = split(":",$_);
	     		$passwdHash{$splitline[0]}{password} = $splitline[1];
		}
		close(INFILE) or warn "can't close filename: $!";
	}

	return %passwdHash;
} # end readPasswdFile

sub readGroupFile {
	my %groupHash;

	my @splitline;
	#open (INFILE, "<$groupFile")
	sysopen(INFILE, "$groupFile", O_RDONLY) or die "Couln't open file $groupFile";
	flock(INFILE, LOCK_SH) or warn "can't lock filename: $!";
	while (<INFILE>){
		chomp; 
		@splitline = split(":",$_);
		$groupHash{$splitline[0]}{gid} = $splitline[2];
		$groupHash{$splitline[0]}{groupname} = $splitline[0];
     		$groupHash{$splitline[0]}{members} = $splitline[3];
	}
	close (INFILE) or warn "can't close filename: $!";

	return %groupHash;
} # end readGroupFile

sub setDebug {
	my $string = shift;
	my $debug = $false;
	if ( $string eq "true" ) { $debug = $true; }	
	elsif (  $string eq "verbose" ) { $debug = 9; }	
	elsif ( $string =~ /\d+/ ) { $debug = $string; }	
	else { $debug = $false; }	
	return $debug;
}

## KS 17 Mar 2002 performs a binary copy of a file, used for backup of files.
sub backupFile {
	my %arg = @_;
	my $buff;
	if ( -r $arg{file} ) {
		sysopen(IN, "$arg{file}", O_RDONLY) or warn ("ERROR: problem with file $arg{file}; $!");
		flock(IN, LOCK_SH) or warn "can't lock filename: $!";

		# change to secure sysopen with truncate after we got the lock
		sysopen(OUT, "$arg{backup}", O_WRONLY | O_CREAT) or warn ("ERROR: problem with file $arg{backup}; $!");
		flock(OUT, LOCK_EX) or warn "can't lock filename: $!";
		truncate(OUT, 0) or warn "can't truncate filename: $!";

		binmode(IN);
		binmode(OUT);		
		while (read(IN, $buff, 8 * 2**10)) {
		    print OUT $buff;
		}
		close(IN) or warn "can't close filename: $!";
		close(OUT) or warn "can't close filename: $!";
		return 1;
	} else {
		print STDERR "ERROR, backupFile file $arg{file} not readable.\n";
		return 0;
	}	
}

# AS 14.05.02 Adding Ambrose Li's sort patch
sub alphanumerically {
	#my $a = shift;
	#my $b = shift;
	local($&, $`, $', $1, $2, $3, $4);
	# Sort numbers numerically
	return $a <=> $b if $a !~ /\D/ && $b !~ /\D/;
	# Sort IP addresses numerically within each dotted quad
	if ($a =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/) {
		my($a1, $a2, $a3, $a4) = ($1, $2, $3, $4);
		if ($b =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/) {
			my($b1, $b2, $b3, $b4) = ($1, $2, $3, $4);
			return ($a1 <=> $b1) || ($a2 <=> $b2)
			|| ($a3 <=> $b3) || ($a4 <=> $b4);
		}
	}
	# Handle things like Level1, ..., Level10
	if ($a =~ /^(.*\D)(\d+)$/) {
	    my($a1, $a2) = ($1, $2);
	    if ($b =~ /^(.*\D)(\d+)$/) {
			my($b1, $b2) = ($1, $2);
			return $a2 <=> $b2 if $a1 eq $b1;
	    }
	}
	# Default is to sort alphabetically
	return $a cmp $b;
}

sub alpha {
	my $a = shift;
	my $b = shift;
	local($&, $`, $', $1, $2, $3, $4);
	# Sort numbers numerically
	return $a <=> $b if $a !~ /\D/ && $b !~ /\D/;
	# Sort IP addresses numerically within each dotted quad
	if ($a =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/) {
		my($a1, $a2, $a3, $a4) = ($1, $2, $3, $4);
		if ($b =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/) {
			my($b1, $b2, $b3, $b4) = ($1, $2, $3, $4);
			return ($a1 <=> $b1) || ($a2 <=> $b2)
			|| ($a3 <=> $b3) || ($a4 <=> $b4);
		}
	}
	# Handle things like Level1, ..., Level10
	if ($a =~ /^(.*\D)(\d+)$/) {
	    my($a1, $a2) = ($1, $2);
	    if ($b =~ /^(.*\D)(\d+)$/) {
			my($b1, $b2) = ($1, $2);
			return $a2 <=> $b2 if $a1 eq $b1;
	    }
	}
	# Default is to sort alphabetically
	return $a cmp $b;
}

1;
