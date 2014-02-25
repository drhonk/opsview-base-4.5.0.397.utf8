#!/usr/bin/perl
#
#    connect.pl - NMIS Program - Network Mangement Information System
#    Copyright (C) 2000,2001 Sinclair InterNetworking Services Pty Ltd
#    <nmis@sins.com.au> http://www.sins.com.au/nmis
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
#*****************************************************************************
# Auto configure to the <nmis-base>/lib 
use FindBin;
use lib "/usr/local/nagios/perl/lib";
use lib "$FindBin::Bin/../lib";
use lib "/usr/local/rrdtool/lib/perl";

#
#****** Shouldn't be anything else to customise below here *******************

require 5;
use Fcntl qw(:DEFAULT :flock);

use Data::Dumper;

use Time::ParseDate;
use RRDs;
use strict;
#use web;
use csv;
use NMIS;
use func;
use rrdfunc;
use detail;
#use ip;
# TV: Use CGI so that command line parameters work
use CGI qw(-oldstyle_urls);

$Data::Dumper::Indent = 1;

my $my_data;
my @name_value_array;
my @name_value_pair;
my $tname_value_pair;
my $tindex;
my $tname;
my $tvalue;
my %form_data;
my $form_data_key;
my $q = CGI->new;

# we now have multi-select box input !

# TV: This part doesn't look like it actually does anything
#if($q->request_method eq "GET"){
   $my_data = $q->query_string;
#}
#else {
#   my $bytes_read = read(STDIN, $my_data, $ENV{'CONTENT_LENGTH'});
#}

my %FORM;
my @event_group = ();		# events
my @event_ack = ();			# events
my @node_list = ();			# outages

my @pairs = split(/&/, $my_data);
foreach (@pairs) {
    my ($name, $value) = split(/=/, $_);
    $value =~ tr/+/ /;
    $value =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
	# handle the event group multiselect box
    if ($name eq "event_group") {
        push(@event_group, $value);
    } 
	elsif ($name eq "event_ack") {
        push(@event_ack, $value);
	}
	elsif ($name eq "node_list") {
        push(@node_list, $value);
	}
	else {
		$FORM{$name} = $value;
	}	
}

# Break the query up for the names
my $type = lc $FORM{type}; # type of execution
my $node = lc $FORM{node}; # node name
my $func = lc $FORM{func}; # what you will
my $com  = $FORM{com}; # community string
my $group = $FORM{group};
my $par0 = $FORM{par0};
my $par1 = $FORM{par1};
my $par2 = $FORM{par2};
my $par3 = $FORM{par3};
my $par4 = $FORM{par4};
my $par5 = $FORM{par5};
my $debug = $FORM{debug};
$NMIS::debug = $FORM{nmisdebug};

# Allow program to use other configuration files
my $conf;
if ( $FORM{file} ne "" ) { $conf = $FORM{file}; }
else { $conf = "nmis.conf"; }
my $configfile = "$FindBin::Bin/../conf/$conf";
if ( -f $configfile ) { loadConfiguration($configfile); }
else { die "Can't access configuration file $configfile.\n"; }


# Find kernel name
my $kernel;
if (defined $NMIS::config{kernelname}) {
	$kernel = $NMIS::config{kernelname};
} elsif ( $^O !~ /linux/i) {
	$kernel = $^O;
} else {
	$kernel = `uname -s`;
}
chomp $kernel; $kernel = lc $kernel;

####################################

# check privilege
if ( exists $NMIS::config{'slave_community'} and $NMIS::config{'slave_community'} ne "" and $NMIS::config{'slave_community'} ne $com) {
	&typeError("no privilege for attemp operation");
} else {
	# oke
	if ($type eq "send" ) { 
		&doSend; 
	} elsif ($type =~ /collect|update/i ) {
		&doExec;
	} else { &typeError("unknown type ($type) value"); }
}

exit 0;

####################################

sub printHead {
print <<EOHTML;
Content-type: text/html\n
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html>
<head>
</head>
<body><pre>
EOHTML
}

sub printTail {
	print "</body></html>\n";
}

sub typeError {
	my $msg = shift;

	printHead;
	print <<EOHTML;

	ERROR: <error>$msg</error>

	Input values are

	type  = $type
	func  = $func
	node  = $node
	group = $group
	par0  = $par0
	par1  = $par1
	par2  = $par2
	par3  = $par3
	par4  = $par4
	par5  = $par5

</body></html>
EOHTML
logMessage("Connect, ERROR $msg\n") if $NMIS::debug;
}

###################################

sub doSend{

	if ($func eq "loadsystemfile" ) {
		if ($node eq "") { typeError("missing node name"); exit 1; }
		printHead;
		loadSystemFile($node);
		print Data::Dumper->Dump([\%NMIS::systemTable], [qw(*hash)]);
		printTail;

	} elsif ($func eq "loadnodedetails") {
		loadNodeDetails;
		foreach my $nd (keys %NMIS::nodeTable) { 
			$NMIS::nodeTable{$nd}{'community'} = "";
			if (exists $NMIS::nodeTable{$nd}{'slave'} or exists $NMIS::nodeTable{$nd}{'slave2'}) { 
				delete $NMIS::nodeTable{$nd};
			}
		}
		printHead;
		print Data::Dumper->Dump([\%NMIS::nodeTable], [qw(*hash)]);
		printTail;

	} elsif ($func eq "sumnodetable") {
		loadNodeDetails;
		my %nodeTable;
		foreach my $nd (keys %NMIS::nodeTable) {
			# Altinity patch: ignore non-active nodes, otherwise a clustered setup would use the last state
			next unless $NMIS::nodeTable{$nd}{active} eq "true";

			if ( not exists $NMIS::nodeTable{$nd}{'slave'} and not exists $NMIS::nodeTable{$nd}{'slave2'}){
				loadSystemFile($nd);
				&loadEventStateNoLock;
				$nodeTable{$nd}{'node'} = $NMIS::nodeTable{$nd}{'node'} ;
				$nodeTable{$nd}{'net'} = $NMIS::nodeTable{$nd}{'net'} ;
				$nodeTable{$nd}{'group'} = $NMIS::nodeTable{$nd}{'group'} ;
				$nodeTable{$nd}{'role'} = $NMIS::nodeTable{$nd}{'role'} ;
				$nodeTable{$nd}{'active'} = $NMIS::nodeTable{$nd}{'active'} ;
				$nodeTable{$nd}{'devicetype'} = $NMIS::nodeTable{$nd}{'devicetype'} ;
				$nodeTable{$nd}{'collect'} = $NMIS::nodeTable{$nd}{'collect'} ;
				# last update of RRD
				my $database = getRRDFileName(type => "reach", node => $nd, nodeType => $NMIS::nodeTable{$nd}{devicetype});
				$nodeTable{$nd}{'lastupdate'} = RRDs::last $database;
				#
				$nodeTable{$nd}{'nodedown'} = eventExist($nd,"Node Down","Ping failed") ;
				my $event_hash = &eventHash($nd, "Node Down", "Ping failed");
				$nodeTable{$nd}{'escalate'} = $NMIS::eventTable{$event_hash}{escalate};
				$nodeTable{$nd}{'outage'} = outageCheck($nd,time) ;
				# If sysLocation is formatted for GeoStyle, then remove long, lat and alt to make display tidier
				my $sysLocation = $NMIS::systemTable{sysLocation};
				if (($NMIS::systemTable{sysLocation}  =~ /$NMIS::config{sysLoc_format}/ ) and $NMIS::config{sysLoc} eq "on") {  
					# Node has sysLocation that is formatted for Geo Data
					( my $lat, my $long, my $alt, $sysLocation) = split(',',$NMIS::systemTable{sysLocation});
				}
				$nodeTable{$nd}{'sysLocation'} = $sysLocation ;
				$nodeTable{$nd}{'sysName'} = $NMIS::systemTable{sysName} ;
			}
		}
		printHead;
		print Data::Dumper->Dump([\%nodeTable], [qw(*hash)]);
		printTail;

	} elsif ($func eq "eventtable") {
		loadEventStateNoLock;
		printHead;
		print Data::Dumper->Dump([\%NMIS::eventTable], [qw(*hash)]);
		printTail;

	} elsif ($func eq "summary") {
		#
		my %summaryHash = ();
		my $reportStats;
		my @tmparray;
		my @tmpsplit;

		loadNodeDetails;
		foreach my $nd ( keys %NMIS::nodeTable)  {
			if ( not exists $NMIS::nodeTable{$nd}{'slave'} and not exists $NMIS::nodeTable{$nd}{'slave2'}){
				if ( $group eq $NMIS::nodeTable{$nd}{group} or $group eq "") {
					loadSystemFile($nd);		# need this to get nodeType..
					# preload the hash, so number of records = number of nodes
					$summaryHash{$nd}{reachable} = 0;
					$summaryHash{$nd}{response} = 0;
					$summaryHash{$nd}{loss} = 0;
					$summaryHash{$nd}{health} = 0;
					$summaryHash{$nd}{available} = 0;

					%summaryHash = (%summaryHash,summaryStats(node => $nd,type => "health",start => $par1,end =>  $par2,key => $nd ));
				}
			}
		}
		#
		printHead;
		print Data::Dumper->Dump([\%summaryHash], [qw(*hash)]);
		printTail;

	} elsif ($func eq "summary8" or $func eq "summary16") {
		# get the file
		my $datafile = "$NMIS::config{'<nmis_var>'}/$func.nmis";
		if ( -r $datafile ) {
			my %summaryHash = readVartoHash($func);
			printHead;
			print Data::Dumper->Dump([\%summaryHash], [qw(*hash)]);
			printTail;
		} else {
			typeError("file $datafile not found");
		}

	} elsif ($func eq "summarystats") {
		loadSystemFile($node);
		my %summaryHash = summaryStats(node => $node,type => $par0,start => $par1,end => $par2,ifDescr => $par3,speed => $par4,key => $par5);
		printHead;
		print Data::Dumper->Dump([\%summaryHash], [qw(*hash)]);
		printTail;

	} elsif ($func eq "poll") {
		my %poll;
		$poll{'time'} = time;
		$poll{'datetime'} = returnDateStamp();
		# last update of RRD
		my $database = getRRDFileName(type => "metrics", group => "network");
		$poll{'lastupdate'} = RRDs::last $database;
		printHead;
		print Data::Dumper->Dump([\%poll], [qw(*hash)]);
		printTail;

	} elsif ($func eq "interfacetable") {
		if ($node eq "") { &typeError("missing node name"); exit 1; }
		my %interfaceTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-interface.dat","ifIndex","\t");
		printHead;
		print Data::Dumper->Dump([\%interfaceTable], [qw(*hash)]);
		printTail;

	} elsif ($func eq "loadinterfaceinfo") {
		loadInterfaceInfo;
		printHead;
		print Data::Dumper->Dump([\%NMIS::interfaceInfo], [qw(*hash)]);
		printTail;

	} elsif ($func eq "report_reporttable") {
		my %reportTable;
		loadNodeDetails;
		foreach my $reportnode ( keys %NMIS::nodeTable ) {
			if (exists $NMIS::nodeTable{$reportnode}{slave} or exists $NMIS::nodeTable{$reportnode}{slave2}) {
				next;
			}
			if ( $NMIS::nodeTable{$reportnode}{active} ne "false") {
				loadSystemFile($reportnode);
    			%reportTable = (%reportTable,summaryStats(node => $reportnode,type => "health",start => $par1,end => $par2,key => $reportnode));
			}
		}
		printHead;
		print Data::Dumper->Dump([\%reportTable], [qw(*hash)]);
		printTail;

	} elsif ($func eq "report_cputable") {
		my %cpuTable;
		loadNodeDetails;
		foreach my $reportnode ( keys %NMIS::nodeTable ) {
			if (exists $NMIS::nodeTable{$reportnode}{slave} or exists $NMIS::nodeTable{$reportnode}{slave2}) {
				next;
			}
			if ( $NMIS::nodeTable{$reportnode}{active} ne "false") {
				loadSystemFile($reportnode);
    			%cpuTable = (%cpuTable,summaryStats(node => $reportnode,type => "cpu",start => $par1,end => $par2,key => $reportnode));
			} 
		}
		printHead;
		print Data::Dumper->Dump([\%cpuTable], [qw(*hash)]);
		printTail;

	} elsif ($func eq "report_linktable") {
		my $prev_loadsystemfile;
		my %linkTable;
		loadInterfaceInfo;
		foreach my $int ( keys %NMIS::interfaceInfo ) {
			if ( $NMIS::interfaceInfo{$int}{collect} eq "true" ) {
				# availability, inputUtil, outputUtil, totalUtil
				my $tmpifDescr = convertIfName($NMIS::interfaceInfo{$int}{ifDescr});
				# we need the nodeType for summary stats to get the right directory
				if ($NMIS::interfaceInfo{$int}{node} ne $prev_loadsystemfile) {
					loadSystemFile($NMIS::interfaceInfo{$int}{node},$NMIS::config{master_report});
					$prev_loadsystemfile = $NMIS::interfaceInfo{$int}{node};
				}
			    %linkTable = (%linkTable,summaryStats(node => $NMIS::interfaceInfo{$int}{node},type => "util",start => $par1,end => $par2,ifDescr => $tmpifDescr,speed => $NMIS::interfaceInfo{$int}{ifSpeed},key => $int));

				# Availability, inputBits, outputBits
				my %hash = summaryStats(node => $NMIS::interfaceInfo{$int}{node},type => "bits",start => $par1,end => $par2,ifDescr => $tmpifDescr,speed => $NMIS::interfaceInfo{$int}{ifSpeed},key => $int);
				foreach my $k (keys %{$hash{$int}}) {
					$linkTable{$int}{$k} = $hash{$int}{$k};
				}
			}
		}
		printHead;
		print Data::Dumper->Dump([\%linkTable], [qw(*hash)]);
		printTail;

	} elsif ($func eq "report_pktstable") {
		my $prev_loadsystemfile;
		my %pktsTable;
		loadInterfaceInfo;
		foreach my $int ( keys %NMIS::interfaceInfo ) {
			if ( $NMIS::interfaceInfo{$int}{collect} eq "true" ) {
				# availability, inputUtil, outputUtil, totalUtil
				my $tmpifDescr = convertIfName($NMIS::interfaceInfo{$int}{ifDescr});
				# we need the nodeType for summary stats to get the right directory
				if ($NMIS::interfaceInfo{$int}{node} ne $prev_loadsystemfile) {
					loadSystemFile($NMIS::interfaceInfo{$int}{node},$NMIS::config{master_report});
					$prev_loadsystemfile = $NMIS::interfaceInfo{$int}{node};
				}
				%pktsTable = (%pktsTable,summaryStats(node => $NMIS::interfaceInfo{$int}{node},type => "pkts",start => $par1,end => $par2,ifDescr => $tmpifDescr,speed => $NMIS::interfaceInfo{$int}{ifSpeed},key => $int));
			}
		}
		printHead;
		print Data::Dumper->Dump([\%pktsTable], [qw(*hash)]);
		printTail;

	} elsif ($func eq "report_pvctable") {
		my $prev_loadsystemfile;
		my %pvcTable;
		loadInterfaceInfo;
		foreach my $int ( keys %NMIS::interfaceInfo ) {
			if ( $NMIS::interfaceInfo{$int}{collect} eq "true" ) {
				# availability, inputUtil, outputUtil, totalUtil
				my $tmpifDescr = convertIfName($NMIS::interfaceInfo{$int}{ifDescr});
				# we need the nodeType for summary stats to get the right directory
				if ($NMIS::interfaceInfo{$int}{node} ne $prev_loadsystemfile) {
					loadSystemFile($NMIS::interfaceInfo{$int}{node},$NMIS::config{master_report});
					$prev_loadsystemfile = $NMIS::interfaceInfo{$int}{node};
				}
				if ( -e "$NMIS::config{'<nmis_var>'}/$NMIS::interfaceInfo{$int}{node}-pvc.dat" ) {
					my 	%pvc = &loadCSV("$NMIS::config{'<nmis_var>'}/$NMIS::interfaceInfo{$int}{node}-pvc.dat","subifDescr","\t");
					if ( exists $pvc{lc($NMIS::interfaceInfo{$int}{ifDescr})} ) {
						%pvcTable = (%pvcTable,summaryStats(node => $NMIS::interfaceInfo{$int}{node},type => "pvc",start => $par1,end => $par2,ifDescr => $pvc{lc($NMIS::interfaceInfo{$int}{ifDescr})}{rrd},key => $int));
						foreach my $k (keys %{$pvcTable{$int}}) {
							$pvcTable{$int}{$k} =~ s/NaN/0/ ;
						}
						$pvcTable{$int}{totalECNS} = $pvcTable{$int}{ReceivedBECNs} + $pvcTable{$int}{ReceivedFECNs} ;
						$pvcTable{$int}{pvc} = $pvc{lc($NMIS::interfaceInfo{$int}{ifDescr})}{pvc} ;
						$pvcTable{$int}{node} = $NMIS::interfaceInfo{$int}{node} ;
					}
				}
			}
		}
		printHead;
		print Data::Dumper->Dump([\%pvcTable], [qw(*hash)]);
		printTail;

	} elsif ($func eq "report_outagetable") {
		my $index;
		my %logreport;
		my @logline;
		my $outageLength;
		my $outageColor;
		my $outageDetails;
		my $outageType;
		my $logfile;
		my @spacesplit;
		my $i = 0;
		my $timelog;
		my $sec;
	    my $min;
	    my $hour;
	    my $mday;
	    my $mon;
	    my $year;
	    my $wday;
	    my $yday;
	    my $isdst;
		my $level = $par2;
		
		# set the length if wanted...
		my $count;
		
		if ( $par1 eq "month" ) { $count=30}
		elsif ( $par1 eq "week" ) {$count=7}
		else {$count = 1}


		my %eventfile;
		my $dir = $NMIS::config{'<nmis_logs>'};
		# create a list of logfiles...
		opendir (DIR, "$dir");
		my @dirlist = readdir DIR;
		closedir DIR;
		
		if ($debug) { print "\tFound $#dirlist entries\n"; }
		
		foreach my $dir (@dirlist) {
			# grab file names that match the desired report type.
			# add back directory
			$dir = $NMIS::config{'<nmis_logs>'} . '/' . $dir ;
			if ( $dir =~ /^$NMIS::config{event_log}/ ) {
				$eventfile{$dir} = $dir;;
			}
		}
		# only get $count days worth of eventlog
		# init the date check variable
		($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,)=localtime;
		$timelog = time() - ($count*24*60*60);            # get the epoch time for $count days ago
	
		foreach $logfile ( sort keys %eventfile ) {
			if ( $logfile =~ /\.gz$/ ) {
				$logfile = "gzip -dc $logfile |";
			}
		 	# Open the file and store in table
			#open (DATA, $logfile)
			sysopen(DATA, "$logfile", O_RDONLY) or warn returnTime." typeReports, Cannot open the file $logfile. $!\n";
			flock(DATA, LOCK_SH) or warn "can't lock filename: $!";
			# find the line with the entry in and store in the array
			while (<DATA>) {
				chomp;
				my ( $time, $node, $event, $eventlevel, $details ) = split /,/, $_;
				
				# event log time is already in epoch time
				if ($time < $timelog ) {last;}           # nothing to do unless logtime is less than $count days ago.

			  	if ($event =~ /Node Up/i and $level eq 'node') {
					$logreport{$i}{time} = $time;
					$logreport{$i}{node} = $node;
					$logreport{$i}{outageType} = "Node Outage";

					# 'Time=00:00:34 secs change=512'
					$details =~ m/Time=(.*?) secs(?:\s+(change=.*))?/i;

					$logreport{$i}{outageLength} = $1;
					$logreport{$i}{outage} = $2;

				}
			  	elsif ($event =~ /Interface Up/i and $level eq 'interface') {
					$logreport{$i}{time} = $time;
					$logreport{$i}{node} = $node;
					$logreport{$i}{outageType} = "Interface Outage";

					# 'interface=ifDescr description=some text Time=00:00:4 secs'
					$details =~ m/(interface=.*?)\s+Time=(.*?) secs/i;

					$logreport{$i}{details} = $1;
					$logreport{$i}{outageLength} = $2;
				}
				$i++;
			}
			close (DATA) or warn "can't close filename: $!";
		} # end of file list
		printHead;
		print Data::Dumper->Dump([\%logreport], [qw(*hash)]);
		printTail;

	} else {
		typeError("Unknown func ($func) value");
		return;
	}

}

sub doExec{

	printHead;
	my @buffer = qx{$NMIS::config{'<nmis_bin>'}/nmis.pl type=$type debug=$debug node=$node} ;
	print @buffer;
	printTail;
}
