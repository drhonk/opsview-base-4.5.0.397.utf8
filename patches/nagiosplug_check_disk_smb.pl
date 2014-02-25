#!/usr/bin/perl
#
#
# check_disk.pl <host> <share> <user> <pass> [warn] [critical] [port]
#
# Nagios host script to get the disk usage from a SMB share
#
# Changes and Modifications
# =========================
# 7-Aug-1999 - Michael Anthon
#  Created from check_disk.pl script provided with netsaint_statd (basically
#  cause I was too lazy (or is that smart?) to write it from scratch)
# 8-Aug-1999 - Michael Anthon
#  Modified [warn] and [critical] parameters to accept format of nnn[M|G] to
#  allow setting of limits in MBytes or GBytes.  Percentage settings for large
#  drives is a pain in the butt
# 2-May-2002 - SGhosh fix for embedded perl
# 13-Aug-2008 - Steve Huff
#  Rewrote using Nagios::Plugin
#
# $Id: check_disk_smb.pl,v 1.4 2008/08/13 19:08:20 shuff Exp $
#

require 5.004;
use POSIX;
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../perl/lib", "/usr/local/nagios/libexec";
use utils qw($TIMEOUT %ERRORS &print_revision &support &usage);

use Nagios::Plugin;
use Nagios::Plugin::Getopt;

my ($np) = Nagios::Plugin->new(
    shortname => 'check_disk_smb',
    timeout   => $TIMEOUT,
);

my ($ng) = Nagios::Plugin::Getopt->new(
    usage =>
        "Usage: %s -H <host> -s <share> -u <user> -p <password> -w <warn> -c <crit> [-W <workgroup>] [-P <port>] [--help] [--version]\n",
    version => '1.2',
    blurb   => 'Perl Check SMB Disk plugin for Nagios',
    extra =>
        "\nIf thresholds are followed by either a k, M, or G then check to see if that much disk space is available (kilobytes, Megabytes, Gigabytes)\n\nWarning percentage should be less than critical\nWarning (remaining) disk space should be greater than critical.",
    license => 'Copyright (c) 2000 Michael Anthon/Karl DeBisschop',
);

$ng->arg(
    spec     => 'hostname|H=s',
    help     => "NetBIOS name of the server",
    required => 1,
);

$ng->arg(
    spec     => 'share|s=s',
    help     => "Share name to be tested",
    required => 1,
);

$ng->arg(
    spec     => 'workgroup|W=s',
    help     => "Workgroup or Domain used (Defaults to \"WORKGROUP\")",
    required => 0,
    default  => 'WORKGROUP',
);

$ng->arg(
    spec     => 'user|u=s',
    help     => "Username to log in to server. (Defaults to \"guest\")",
    required => 0,
    default  => 'guest',
);

$ng->arg(
    spec => 'password|p=s',
    help => "Password to log in to server. (Defaults to an empty password)",
    required => 0,
    default  => '',
);

$ng->arg(
    spec => 'warning|w=s',
    help => [
        "Percent of used space at which a warning will be generated (Default: 85%)",
        "Amount of used space [k/M/G] at which a warning will be generated",
    ],
    required => 0,
    default  => '85',
    label    => [ 'PERCENT%', 'BYTES[kMG]', ],
);

$ng->arg(
    spec => 'critical|c=s',
    help => [
        "Percent of used space at which a critical will be generated (Default: 95%)",
        "Amount of used space [k/M/G] at which a critical will be generated",
    ],
    required => 0,
    default  => '95',
    label    => [ 'PERCENT%', 'BYTES[kMG]', ],
);

$ng->arg(
    spec => 'port|P=i',
    help =>
        "Port to be used to connect to. Some Windows boxes use 139, others 445 (Defaults to smbclient default)",
    required => 0,
);

$ng->getopts();

my ($host)      = $ng->hostname;
my ($share)     = $ng->share;
my ($port)      = $ng->port;
my ($user)      = $ng->user;
my ($pass)      = $ng->password;
my ($workgroup) = $ng->workgroup;
my ($warning)   = $ng->warning;
my ($critical)  = $ng->critical;

my ( $verbose, $warn, $crit );

$ENV{'PATH'}     = '';
$ENV{'BASH_ENV'} = '';
$ENV{'ENV'}      = '';

my $smbclient = "$utils::PATH_TO_SMBCLIENT";
my $smbclientoptions = $port ? "-p $port " : "";

if ( !$smbclient || !-x $smbclient ) {
    $np->nagios_die("Path to smbclient not configured correctly in utils.pm");
}

# Options checking

( $host =~ /^([-_.A-Za-z0-9]+\$?)$/ )
    or usage("Invalid host: $host\n");

( $share =~ /^([-_.A-Za-z0-9]+\$?)$/ )
    or usage("Invalid share: $share\n");

( $user =~ /^([-_.A-Za-z0-9\\]+)$/ )
    or usage("Invalid user: $user\n");

( $warning =~ /^([0-9]{1,2}\%?|100\%?|[0-9]+[kMG])$/ )
    or usage("Invalid warning threshold: $warning\n");

( $critical =~ /^([0-9]{1,2}\%?|100\%?|[0-9]+[kMG])$/ )
    or usage("Invalid critical threshold: $critical\n");

# split the type from the unit value
#Check $warn and $crit for type (%/M/G) and set up for tests
#P = Percent, K = KBytes
my $warn_type;
my $crit_type;

if ( $warning =~ /^([0-9]+)\%?$/ ) {
    $warn      = "$1";
    $warn_type = "P";
}
elsif ( $warning =~ /^([0-9]+)k$/ ) {
    $warn_type = "K";
    $warn      = $1;
}
elsif ( $warning =~ /^([0-9]+)M$/ ) {
    $warn_type = "K";
    $warn      = $1 * 1024;
}
elsif ( $warning =~ /^([0-9]+)G$/ ) {
    $warn_type = "K";
    $warn      = $1 * 1048576;
}
if ( $critical =~ /^([0-9]+)\%?$/ ) {
    $crit      = "$1";
    $crit_type = "P";
}
elsif ( $critical =~ /^([0-9]+)k$/ ) {
    $crit_type = "K";
    $crit      = $1;
}
elsif ( $critical =~ /^([0-9]+)M$/ ) {
    $crit_type = "K";
    $crit      = $1 * 1024;
}
elsif ( $critical =~ /^([0-9]+)G$/ ) {
    $crit_type = "K";
    $crit      = $1 * 1048576;
}

# check if both warning and critical are percentage or size
unless ( ( $warn_type eq "P" && $crit_type eq "P" )
    || ( $warn_type ne "P" && $crit_type ne "P" ) )
{
    $warning  =~ s/\%/\%\%/g;
    $critical =~ s/\%/\%\%/g;
    usage(
        "Both warning and critical should be same type- warning: $warning critical: $critical \n"
    );
}

# verify warning is less than critical
if ( $warn_type eq "K" ) {
    unless ( $warn > $crit ) {
        usage(
            "Disk size: warning ($warning) should be greater than critical ($critical) \n"
        );
    }
}
else {
    unless ( $warn < $crit ) {
        $warning  =~ s/\%/\%\%/g;
        $critical =~ s/\%/\%\%/g;
        usage(
            "Percentage: warning ($warning) should be less than critical ($critical) \n"
        );
    }
}

#$workgroup = $1 if (defined($workgroup) && $workgroup =~ /(.*)/);

# sanitize options that will be passed to shell
my ($hostname)  = $host;
my ($sharename) = $share;
$host             = quotemeta($host);
$share            = quotemeta($share);
$workgroup        = quotemeta($workgroup);
$user             = quotemeta($user);
$pass             = quotemeta($pass);
$smbclientoptions = quotemeta($smbclientoptions);

# end of options checking

my $state  = "OK";
my $answer = undef;
my $res    = undef;
my @lines  = undef;

# Just in case of problems, let's not hang Nagios
$SIG{'ALRM'} = sub {
    $np->nagios_exit( $ERRORS{'CRITICAL'}, "No answer from client" );
};
alarm($TIMEOUT);

# Execute an "ls" on the share using smbclient program
# get the results into $res
if ( defined($workgroup) ) {
    $res
        = qx/$smbclient \/\/$host\/$share -W $workgroup -U $user%$pass $smbclientoptions -c ls/;
}
else {
    print "$smbclient "
        . "\/\/$host\/$share"
        . " $pass -U $user $smbclientoptions -c ls\n"
        if ($verbose);
    $res
        = qx/$smbclient \/\/$host\/$share -U $user%$pass $smbclientoptions -c ls/;
}

#Turn off alarm
alarm(0);

#Split $res into an array of lines
@lines = split /\n/, $res;

#Get the last line into $_
$_ = $lines[$#lines];
($verbose) && ( print "$_\n" );

#Process the last line to get free space.
#If line does not match required regexp, return an UNKNOWN error
if (/\s*(\d*) blocks of size (\d*)\. (\d*) blocks available/) {

    my ($avail)       = ( $3 * $2 ) / 1024;
    my ($avail_bytes) = $avail;
    my ($capper)      = int( ( $3 / $1 ) * 100 );
    my ($mountpt)     = "\\\\$hostname\\$sharename";

    if ( int( $avail / 1024 ) > 0 ) {
        $avail = int( $avail / 1024 );
        if ( int( $avail / 1024 ) > 0 ) {
            $avail = ( int( ( $avail / 1024 ) * 100 ) ) / 100;
            $avail = $avail . "G";
        }
        else {
            $avail = $avail . "M";
        }
    }
    else {
        $avail = $avail . "K";
    }

    ($verbose) && ( print ":$warn:$warn_type:\n" );
    ($verbose) && ( print ":$crit:$crit_type:\n" );
    ($verbose) && ( print ":$avail:$avail_bytes:$capper:$mountpt:\n" );

    # set thresholds
    my ( $value, $uom );

    if ( ( $warn_type eq 'P' ) && ( $crit_type eq 'P' ) ) {

        # we're using percentages
        $np->set_thresholds(
            warning  => 100 - $warn . ':',
            critical => 100 - $crit . ':'
        );
        $value = $capper;
        $uom   = '%';
    }
    else {

        # we're using bytes
        $np->set_thresholds(
            warning  => $warn . ':',
            critical => $crit . ':'
        );
        $value = $avail_bytes;
        $uom   = 'B';
    }

    # check thresholds
    $state = $np->check_threshold($value);

    if ( $state > 0 ) {

        # a problem
        $answer = "Only $avail ($capper%) free on $mountpt\n";
    }
    else {

        # ok
        $answer = "$avail ($capper%) free on $mountpt\n";
    }

    # add performance data
    $np->add_perfdata(
        label     => 'free',
        value     => $value,
        uom       => $uom,
        threshold => $np->threshold,
    );
}
else {
    $answer = "Result from smbclient not suitable\n";
    $state  = "UNKNOWN";
    foreach (@lines) {
        if (/(Access denied|NT_STATUS_LOGON_FAILURE)/) {
            $answer = "Access Denied\n";
            $state  = "CRITICAL";
            last;
        }
        if (/(Unknown host \w*|Connection.*failed)/) {
            $answer = "$1\n";
            $state  = "CRITICAL";
            last;
        }
        if (/(You specified an invalid share name|NT_STATUS_BAD_NETWORK_NAME)/
            )
        {
            $answer = "Invalid share name \\\\$host\\$share\n";
            $state  = "CRITICAL";
            last;
        }
    }
}

# did we get a number back or a string?
my ($EXIT) = ( $state =~ /^\d$/ ) ? $state : $ERRORS{$state};

$np->nagios_exit( $EXIT, $answer );
