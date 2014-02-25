# $Id: NMIS.pm,v 1.73 2007/10/30 08:32:12 egreenwood Exp $
#
#
#    NMIS.pm - NMIS Perl Package - Network Mangement Information System
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
package NMIS;

use lib "/usr/local/rrdtool/lib/perl";

use BER;
use SNMP_Session;
use SNMP_Simple;
use SNMP_util;
use SNMP_MIB;
use strict;
use RRDs;
use Time::ParseDate;
use func;
use csv;
use notify;
use ip;

no warnings;

# added for authentication
use CGI::Pretty qw(:standard *table *Tr *td *Select *form);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";
push @CGI::Pretty::AS_IS, qw(p h1 h2 center b comment option span);


#require Data::Dumper;
#Data::Dumper->import();
#$Data::Dumper::Indent = 1;



use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

use Exporter;

#! this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);

$VERSION = "4.2.13";

@ISA = qw(Exporter);

@EXPORT = qw(	
		loadConfiguration
		loadInterfaceFile
		loadSystemFile
		loadLinkDetails
		loadNodeDetails
		loadRMENodes
		loadSlave
		writeNodesFile
		loadEventStateNoLock
		loadEventStateLock
		loadEventStateSlave
		runEventDebug
		eventHash
		eventExist
		checkEvent
		logEvent
		eventAdd
		eventAck
		notify
		writeEventStateLock
		summaryStats
		getGroupSummary
		getRRDFileName
		getGraphType
		colorHighGood
		colorPort
		colorLowGood
		colorResponseTime
		thresholdPolicy
		thresholdResponse
		thresholdLowPercent
		thresholdHighPercent
		thresholdHighPercentLoose
		thresholdMemory
		thresholdInterfaceUtil
		thresholdInterfaceAvail
		thresholdInterfaceNonUnicast
		loadInterfaceTypes
		eventLevel
		eventPolicy
		escalationPolicy
		overallNodeStatus
		statusNumber
		logMessage
		createInterfaceInfo
		loadInterfaceInfo
		outageAdd
		outageDelete
		outageLoad
		outageCheck
		outageCheckHash
		sendTrap
		eventToSMTPPri
		dutyTime
		userMenuDisplay
		runCAM
		get_localtime
		do_dash_banner
		do_footer
		cleanEvent
		setFileProt
		slaveConnect
		writeHashtoVar
		readVartoHash
	);

@EXPORT_OK = qw(	
			%config 
			%interfaceTable 
			%ifDescrTable 
			%systemTable 
			%eventTable
			%nodeTable
			%linkTable
			%slaveTable
			$eventCount
			$version
			$userMenu
		);

# Set the default file locations if not specified in configuration file.
my %config;

# Nice Variables for Interface Stuff
my %interfaceTable;
my $interfaceTableNum;
my %ifDescrTable;
my %ifTypeDefs;

my $eventCount;

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
our $debug = 0;

# Master/slave
my %slaveTable;

# preset kernel name
my $kernel = $^O; 

# Control display of menus based on calling ip address
# set to enable (true) unless otherwise changed.
my $userMenu = 1;

sub loadConfiguration {
	my $file = shift;

	my $name;
	my $value;
	my $key;

	$NMIS::config{file} = $file;

	sysopen(DATAFILE, "$file", O_RDONLY) or warn returnTime." loadConfiguration, Cannot open $file. $!\n";
	flock(DATAFILE, LOCK_SH)  or warn "loadConfiguration, can't lock filename: $!";
	while (<DATAFILE>) {
		chomp;
		# Line does not start with # must be configuration option
		if ( $_ !~ /^#|^ |^\t/ ) {
			s/#.*$//;          # Remove any trailing comments 
			($name,$value) = split /=/ , $_ , 2 ;	# make sure only the first = is split !! - allows urls in config file
		        $name =~ s/^\s+//;               # Strip leading
        		$name =~ s/\s+$//;               # and trailing spaces
        		$value =~ s/^\s+//;               # Strip leading
        		$value =~ s/\s+$//;               # and trailing spaces

			$name =~ s/;//g;
			$NMIS::config{$name} = $value;
		}
	}
	close(DATAFILE) or warn "loadConfiguration, can't close filename: $!";

	# check for config variables and process each config element again.
	foreach $key (%NMIS::config) {
		if ( $key =~ /^<.*>$/ ) {
			if ($NMIS::debug>8) { print returnTime." Found a key to change $key\n"; }
			foreach $value (%NMIS::config) {
				if ( defined $NMIS::config{$value} && $NMIS::config{$value} =~ /<.*>/ ) {
					if ($NMIS::debug==9) { print "\tabout to change $value to $NMIS::config{$value}, $key, $NMIS::config{$key}\n"; }
					$NMIS::config{$value} =~ s/$key/$NMIS::config{$key}/;
				}
			}
		}
	}
}

sub loadInterfaceFile {
	my $node = shift;

	my $interfaceFile="$NMIS::config{'<nmis_var>'}/$node-interface.dat";
	
	undef %NMIS::interfaceTable;
	if ( -f $interfaceFile ) {
		%NMIS::interfaceTable = &loadCSV($interfaceFile,"interface","\t");
	}
	else {
  		logMessage("loadInterfaceFile, $node, Cannot open interface file $interfaceFile");
  		print returnTime." $node Cannot open interface file=$interfaceFile, this may not be a bad thing.\n";
	}
	# Now we have a nicely populated Interface Table we can do other things
}

sub loadSystemFile {
	my $node = shift;
	my %nodeTable;

	undef %NMIS::systemTable;

	my $systemFile="$NMIS::config{'<nmis_var>'}/$node.dat";
	my ($name,$value);

	if ( -f $systemFile ) { 
		sysopen(DATAFILE, "$systemFile", O_RDONLY) or warn returnTime." loadSystemFile, Cannot open $systemFile. $!\n";
		flock(DATAFILE, LOCK_SH) or warn "loadSystemFile, can't lock filename: $!";
		while (<DATAFILE>) {
			chomp;
			# Does the line from configfile have a comment?
			if ( $_ !~ /^#/ ) {
				($name,$value) = split "=", $_;
				$NMIS::systemTable{$name} = $value;
			}
		}
		close(DATAFILE) or warn "loadSystemFile, can't close filename: $!";
	} else {
	##	logMessage("loadSystemFile, file $systemFile does not exists or readable\n");
	}
	# Now we have a nicely populated System Table we can do other things
}
			   
sub loadLinkDetails {
	%NMIS::linkTable = &loadCSV($NMIS::config{Links_Table},$NMIS::config{Links_Key},"\t");
} #sub loadLinkDetails

sub loadNodeDetails {
	my $node;
	my $nodeType;
	# Load the CSV first
	# add some debug around this...	
	if ( -r $NMIS::config{Nodes_Table} ) {
		if ( !(%NMIS::nodeTable = &loadCSV($NMIS::config{Nodes_Table},$NMIS::config{Nodes_Key},"\t")) ) {
			if ($NMIS::debug) { print "\t loadNodeDetails: could not find or read $NMIS::config{Nodes_Table} or empty node file\n"; }
		}
		if ($NMIS::debug) { print "\t loadNodeDetails: Loaded $NMIS::config{Nodes_Table}\n"; }
	}
	else {
		if ($NMIS::debug) { print "\t loadNodeDetails: could not find or read $NMIS::config{Nodes_Table}\n"; }
		return;
	}

	# Bit of quick post processing on the table.
	foreach $node (keys %NMIS::nodeTable) {
		$NMIS::groupTable{$NMIS::nodeTable{$node}{group}} = $NMIS::nodeTable{$node}{group};
		if ( $NMIS::nodeCount{run} ne "true" ) {
			++$NMIS::nodeCount{total};
			$nodeType = $NMIS::nodeTable{$node}{net}.$NMIS::nodeTable{$node}{role};
			++$NMIS::nodeCount{$nodeType};
			++$NMIS::nodeCount{$NMIS::nodeTable{$node}{group}};
		}
		if ( ! defined $NMIS::nodeTable{$node}{snmpport} ) { $NMIS::nodeTable{$node}{snmpport} = 161 }
		if ( ! defined $NMIS::nodeTable{$node}{community} ) { $NMIS::nodeTable{$node}{community} = "public" }
		### AS 28 Mar 2002 - Exception handling for bad node files.
		if ( ! defined $NMIS::nodeTable{$node}{node} or $NMIS::nodeTable{$node}{node} eq "") { 
			logMessage("loadNodeDetails, N/A, Bad node record in $NMIS::config{Nodes_Table}");
			delete $NMIS::nodeTable{$node};
		}
	}
	$NMIS::nodeCount{run} = "true";
	if ( $NMIS::config{master} eq 'true' ) { loadSlaveNodeDetails() }
	if ( $NMIS::config{master_dash} eq 'true' ) { loadSlaveNodeDetails2() }
}
	
sub loadSlaveNodeDetails {	
	# read in any slave node files and add to the nodetable with the field 'name' as a pointer.
	
	my %slave;
	my %H;
	my $name;
	my $node;
	my $nodeType;

	if ( -r $NMIS::config{Slave_Table} ) {
		if ( !(%slave = &loadCSV("$NMIS::config{Slave_Table}","$NMIS::config{Slave_Key}","\t")) ) {
			if ($NMIS::debug) { print "\t loadSlaveNodeDetails: could not find or read $NMIS::config{Slave_Table} - slave update aborted\n"; }
			return;
		}
	}
	else {
		if ($NMIS::debug) { print "\t loadSlaveNodeDetails: could not find or read $NMIS::config{Slave_Table} - slave update aborted\n"; }
		return;
	}
	if ($NMIS::debug) { print "\t loadSlaveNodeDetails: Loaded $NMIS::config{Slave_Table}\n"; }

	foreach $name ( keys %slave ) {
		if ( -r "$NMIS::config{'<nmis_conf>'}/$slave{$name}{Name}_nodes.csv" ) {
			if ( !(%H = &loadCSV("$NMIS::config{'<nmis_conf>'}/$slave{$name}{Name}_nodes.csv",'node',"\t")) ) { 	# key 'should' be read from the slave nmis.conf
				if ($NMIS::debug) { print "\t loadSlaveNodeDetails: could not find or read $NMIS::config{'<nmis_conf>'}/$slave{$name}{Name}_nodes.csv\n"; }
				next;
			}
		}
		else {
			if ($NMIS::debug) { print "\t loadNodeDetails: could not find or read $NMIS::config{'<nmis_conf>'}/$slave{$name}{Name}_nodes.csv\n"; }
			next;
		}
		print "\t loadSlaveNodeDetails: Loaded $NMIS::config{'<nmis_conf>'}/$slave{$name}{Name}_nodes.csv\n" if $NMIS::debug;
		# Bit of quick post processing on the table.
		foreach $node (keys %H) {
			# check for duplicated nodes..
			if ( $node eq $NMIS::nodeTable{$node}{node} ) {
				print "\t loadSlaveNodeDetails: Duplicate $node - skipping !!\n" if $NMIS::debug;
				delete $H{$node};
				next;
			}
			# mark as slave node - at this point the node hash is not squared - so dont write it back !
			# set the host pointer here - we may have multiple slaves...
			$H{$node}{slave} = $name;
			$NMIS::groupTable{$H{$node}{group}} = $H{$node}{group};
			if ( $NMIS::nodeCount{run} ne "true" ) {
				++$NMIS::nodeCount{total};
				$nodeType = $H{$node}{net}.$H{$node}{role};
				++$NMIS::nodeCount{$nodeType};
				++$NMIS::nodeCount{$H{$node}{group}};
			}
			### AS 28 Mar 2002 - Exception handling for bad node files.
			if ( ! defined $H{$node}{node} ) { 
				logMessage("loadSlaveNodeDetails, N/A, Bad node record in $slave{$name}{Name}_nodes.csv");
				delete $H{$node};
			}
			if ( ! defined $H{$node}{snmpport} ) { $H{$node}{snmpport} = 161 }
			if ( ! defined $H{$node}{community} ) { $H{$node}{community} = "public" }
		}
		# add the slave node hash to the NMIS nodetable
		%NMIS::nodeTable = ( %NMIS::nodeTable, %H );
	}
}

sub loadSlaveNodeDetails2 {	
	# read in any slave node files and add to the nodetable with the field 'name' as a pointer.
	
	my %H;
	my $name;
	my $node;
	my $nodeType;

	foreach $name ( keys %NMIS::slaveTable ) {
		# use a sempahore to lock
		my $datafile = "$NMIS::config{'<nmis_var>'}/$name-nodes.nmis";
		if ( -r $datafile ) {
			%H = readVartoHash("$name-nodes");
			# Bit of quick post processing on the table.
			foreach $node (keys %H) {
				# check for duplicated nodes..
				if ( $node eq $NMIS::nodeTable{$node}{node} ) {
					print returnTime." loadSlaveNodeDetails2: Duplicate $node - skipping !!\n" if $NMIS::debug;
					delete $H{$node};
					next;
				}
				# mark as slave node - at this point the node hash is not squared - so dont write it back !
				# set the host pointer here - we may have multiple slaves...
				$H{$node}{slave2} = $name;
				$NMIS::groupTable{$H{$node}{group}} = $H{$node}{group};
				if ( $NMIS::nodeCount{run} ne "true" ) {
					++$NMIS::nodeCount{total};
					$nodeType = $H{$node}{net}.$H{$node}{role};
					++$NMIS::nodeCount{$nodeType};
					++$NMIS::nodeCount{$H{$node}{group}};
				}
				### AS 28 Mar 2002 - Exception handling for bad node files.
				if ( not defined $H{$node}{node} or $H{$node}{node} eq "") { 
					logMessage("loadSlaveNodeDetails2, N/A, Bad node record in $datafile");
					delete $H{$node};
				}
			##	if ( ! exists $H{$node}{snmpport} ) { $H{$node}{snmpport} = 161 }
			##	if ( ! exists $H{$node}{community} ) { $H{$node}{community} = "public" }
			}
			# add the slave node hash to the NMIS nodetable
			%NMIS::nodeTable = ( %NMIS::nodeTable, %H );
			my $node_cnt = scalar keys %H;
			%H = ();
			print returnTime." loadSlaveNodeDetails2: Loaded $datafile $node_cnt entries\n" if $NMIS::debug;
		}
		else {
			if ($NMIS::debug) { print returnTime."\t loadSlaveNodeDetails2: ERROR, could not find or read $datafile\n"; }
		}
	}
}

sub loadRMENodes {

	my $file = shift;

	my $ciscoHeader = "Cisco Systems NM";
	my @nodedetails;
	my @statsSplit;
	my $nodeType;

	sysopen(DATAFILE, "$file", O_RDONLY) or warn returnTime." loadRMENodes, Cannot open $file. $!\n";
	flock(DATAFILE, LOCK_SH) or warn "loadRMENodes, can't lock filename: $!";
	while (<DATAFILE>) {
	        chomp;
		# Don't want comments 
	        if ( $_ !~ /^\;|^$ciscoHeader/ ) {
			# whack all the splits into an array
			(@nodedetails) = split ",", $_;
		
			# check that the device is to be included in STATS
			$nodedetails[4] =~ s/ //g;
			@statsSplit = split(":",$nodedetails[4]);
			if ( $statsSplit[0] =~ /t/ ) {
				# sopme defaults
				$NMIS::nodeTable{$nodedetails[0]}{depend} = "N/A";
				$NMIS::nodeTable{$nodedetails[0]}{runupdate} = "false";
				$NMIS::nodeTable{$nodedetails[0]}{snmpport} = "161";
				$NMIS::nodeTable{$nodedetails[0]}{active} = "true";
				$NMIS::nodeTable{$nodedetails[0]}{group} = "RME";

				$NMIS::nodeTable{$nodedetails[0]}{node} = $nodedetails[0];
				$NMIS::nodeTable{$nodedetails[0]}{community} = $nodedetails[1];
				$NMIS::nodeTable{$nodedetails[0]}{net} = $statsSplit[1];
				$NMIS::nodeTable{$nodedetails[0]}{devicetype} = $statsSplit[2];
				# Convert role c, d or a to core, distribution or access
				if ( $statsSplit[3] eq "c" ) { $NMIS::nodeTable{$nodedetails[0]}{role} = "core"; }
				elsif ( $statsSplit[3] eq "d" ) { $NMIS::nodeTable{$nodedetails[0]}{role} = "distribution"; }
				elsif ( $statsSplit[3] eq "a" ) { $NMIS::nodeTable{$nodedetails[0]}{role} = "access"; }
				# Convert collect t or f to  true or false
				if ( $statsSplit[4] eq "t" ) { $NMIS::nodeTable{$nodedetails[0]}{collect} = "true"; }
				elsif ( $statsSplit[4] eq "f" ) { $NMIS::nodeTable{$nodedetails[0]}{collect} = "false"; }
			}
		}
	}
	close(DATAFILE) or warn "loadRMENodes, can't close filename: $!";
}

# load slave info in %NMIS::slaveTable
sub loadSlave {

	if ( -r $NMIS::config{Slaves_Table} ) {
		if ( !(%NMIS::slaveTable = &loadCSV("$NMIS::config{Slaves_Table}","$NMIS::config{Slaves_Key}","\t")) ) {
			if ($NMIS::debug) { print returnTime." loadSlave: could not find or read $NMIS::config{Slaves_Table}\n"; }
		} else {
			if ($NMIS::debug) { print returnTime." loadSlave: loaded $NMIS::config{Slaves_Table}\n"; }
		}
	}
	else {
		if ($NMIS::debug) { print returnTime." loadSlave: could not find or read $NMIS::config{Slaves_Table}\n"; }
	}
}

sub writeNodesFile {
	my $file = shift;
	if ($NMIS::debug) { print returnTime." Writing the Nodes File\n"; }
	&writeCSV(%NMIS::nodeTable,$file,"\t");
}

# improved locking on event.dat
# !! this sub intended for write on event.dat only with a previously open filehandle !!
# The lock on the open file must be maintained while the hash is being updated
# to prevent another thread from opening and writing some other changes before we write our thread's hash copy back
# we also need to make sure that we process the hash quickly, to avoid multithreading becoming singlethreading,
# because of the lock being maintained on event.dat

sub writeEventStateLock {
	my $handle = shift;
	my $event_hash;

	if ($NMIS::debug==9) {
		print "Current Event State Table:\n";
		print "StartDate,LastChange,Node,Event,Event_Level,Details,Ack,Escalate,Notify\n";
	}
	# !!expect an open file handle here from a previous loadEventStateLock !!
	# rewind and clear the file, as we are going to write the whole event hash back.
	seek($handle,0,0) or warn "writeEventStateLock, can't seek filename: $!";
	truncate($handle, 0) or warn "writeEventStateLock, can't truncate filename: $!";

	foreach $event_hash (sort ( keys (%NMIS::eventTable) ) )  {
		# print STDERR "$NMIS::eventTable{$event_hash}{node} $NMIS::eventTable{$event_hash}{event} $NMIS::eventTable{$event_hash}{details} $NMIS::eventTable{$event_hash}{ack}\n";
		if ( ($NMIS::debug==9) and $NMIS::eventTable{$event_hash}{current} eq "true" ) {
			print "$event_hash,";
			print "current=$NMIS::eventTable{$event_hash}{current},";
			print &returnDateStamp($NMIS::eventTable{$event_hash}{startdate}).",";
			print &returnDateStamp($NMIS::eventTable{$event_hash}{lastchange}).",";
			print "$NMIS::eventTable{$event_hash}{node},";
			print "$NMIS::eventTable{$event_hash}{event},";
			print "$NMIS::eventTable{$event_hash}{event_level},";
			print "$NMIS::eventTable{$event_hash}{details},";
			print "$NMIS::eventTable{$event_hash}{ack},";
			print "$NMIS::eventTable{$event_hash}{escalate},";
			print "$NMIS::eventTable{$event_hash}{notify}\n";
	        }

		# make sure we have startdate, node, event, level, details so the hash can be constructed when read next time.
		if ( 	$NMIS::eventTable{$event_hash}{current} eq "true"
				and $NMIS::eventTable{$event_hash}{startdate} ne ""
				and $NMIS::eventTable{$event_hash}{node} ne "" 
				and $NMIS::eventTable{$event_hash}{event} ne "" 
				and $NMIS::eventTable{$event_hash}{event_level} ne ""
				and $NMIS::eventTable{$event_hash}{details} ne ""
		) {
			print $handle "$NMIS::eventTable{$event_hash}{startdate},$NMIS::eventTable{$event_hash}{lastchange},$NMIS::eventTable{$event_hash}{node},$NMIS::eventTable{$event_hash}{event},$NMIS::eventTable{$event_hash}{event_level},$NMIS::eventTable{$event_hash}{details},$NMIS::eventTable{$event_hash}{ack},$NMIS::eventTable{$event_hash}{escalate},$NMIS::eventTable{$event_hash}{notify}\n";
		}
	} # foreach $linkname
	close($handle) or warn "writeEventStateLock, can't close filename: $!";
	
	# set the permissions - so web updates work. Skip if not running as root
	NMIS::setFileProt($NMIS::config{event_file}); # set file owner/permission, default: nmis, 0775

	print "\t writeEventStateLock: Wrote $NMIS::config{event_file}\n" if $NMIS::debug;
}

# improved locking on event.dat
# this sub intended for read on event.dat only - do not expect to write the hash back to event.dat back from this call

sub loadEventStateNoLock {
	my @eventdetails;
	my $node;
	my $event;
	my $level;
	my $details;
	my $event_hash;

	sysopen(DATAFILE, "$NMIS::config{event_file}", O_RDONLY) 
		or warn returnTime." loadEventStateNoLock, Couldn't open file $NMIS::config{event_file}. $!\n";
	flock(DATAFILE, LOCK_SH) or warn "loadEventStateNoLock, can't lock filename: $!";

	undef %NMIS::eventTable;		# clear the hash once we have access granted
	$NMIS::eventCount = 0;

	# File format is StartDate,LastChange,Node,Event,Event_Level,Details,Ack,Escalate,Notify
	while (<DATAFILE>) {
	        chomp;
		++$NMIS::eventCount;

		# whack all the splits into an array
		@eventdetails = split ",", $_;

		# using temp variables for readability
		$node = $eventdetails[2];
		$event = $eventdetails[3];
		$level = $eventdetails[4];
		$details = $eventdetails[5];

		# define a hash index which uniquely identifies each event type for each event 
		# Lets try node_event_details!!
		$event_hash = &eventHash($node, $event, $details); 

		$NMIS::eventTable{$event_hash}{current} = "true";
		$NMIS::eventTable{$event_hash}{startdate} = $eventdetails[0];
		$NMIS::eventTable{$event_hash}{lastchange} = $eventdetails[1];
		$NMIS::eventTable{$event_hash}{node} = $node;
		$NMIS::eventTable{$event_hash}{event} = $event;
		$NMIS::eventTable{$event_hash}{event_level} = $level;
		$NMIS::eventTable{$event_hash}{details} = $details;
		$NMIS::eventTable{$event_hash}{ack} = $eventdetails[6];
		$NMIS::eventTable{$event_hash}{escalate} = $eventdetails[7];
		$NMIS::eventTable{$event_hash}{notify} = $eventdetails[8];
	}
	close(DATAFILE) or warn "loadEventStateNoLock, can't close filename: $!";
	print "\t loadEventStateNoLock: Loaded $NMIS::config{event_file}\n" if $NMIS::debug;

}

# improved locking on event.dat
# !!!this sub intended for read and LOCK on event.dat only - MUST use writeEventStateLock to write the hash back from this call!!!
# need to maintain a lock on the file while the event hash is being processed by this thread
# must pass our filehandle back to writeEventStateLock
sub loadEventStateLock {
	my @eventdetails;
	my $node;
	my $event;
	my $level;
	my $details;
	my $event_hash;
	my $handle;

	# open file with typeglob for perl 5.00 compatability
	local *FH;
	sysopen(*FH, "$NMIS::config{event_file}", O_RDWR ) 
		or warn returnTime." loadEventStateLock, Couldn't open file $NMIS::config{event_file}. $!\n";
	flock(*FH, LOCK_EX) or warn "loadEventStateLock, can't lock filename: $!";
	$handle = *FH;  # save it for later.


	undef %NMIS::eventTable;		# clear the hash once we have access granted.
	$NMIS::eventCount = 0;

	# File format is StartDate,LastChange,Node,Event,Event_Level,Details,Ack,Escalate,Notify
	while (<$handle>) {
	        chomp;
		++$NMIS::eventCount;

		# whack all the splits into an array
		@eventdetails = split ",", $_;

		# using temp variables for readability
		$node = $eventdetails[2];
		$event = $eventdetails[3];
		$level = $eventdetails[4];
		$details = $eventdetails[5];

		# define a hash index which uniquely identifies each event type for each event 
		# Lets try node_event_details!!
		$event_hash = &eventHash($node, $event, $details); 

		$NMIS::eventTable{$event_hash}{current} = "true";
		$NMIS::eventTable{$event_hash}{startdate} = $eventdetails[0];
		$NMIS::eventTable{$event_hash}{lastchange} = $eventdetails[1];
		$NMIS::eventTable{$event_hash}{node} = $node;
		$NMIS::eventTable{$event_hash}{event} = $event;
		$NMIS::eventTable{$event_hash}{event_level} = $level;
		$NMIS::eventTable{$event_hash}{details} = $details;
		$NMIS::eventTable{$event_hash}{ack} = $eventdetails[6];
		$NMIS::eventTable{$event_hash}{escalate} = $eventdetails[7];
		$NMIS::eventTable{$event_hash}{notify} = $eventdetails[8];

	}
	print "\t loadEventStateLock: Loaded $NMIS::config{event_file}\n" if $NMIS::debug;

	# leave the file opened and locked while we update the hash
	# this will prevent our changes being overwritten by another thread
	# writeEventStateLock will unlock after writing event.dat
	return($handle);
}

# this sub intended for read on slave event.dat only to colour main display for 'Node Down' events
# see masterslave.pm and master.pl for code that copies events from slave to master

sub loadEventStateSlave {
	my @eventdetails;
	my $node;
	my $event;
	my $level;
	my $details;
	my $event_hash;
	my %slave;

	# run thru the slaves and load each of their slave_event.dat files
	return unless $NMIS::config{master} eq 'true';  # dont even try this unless we are a master
	
	if ( -r $NMIS::config{Slave_Table} ) {
		if ( !(%slave = &loadCSV("$NMIS::config{Slave_Table}","$NMIS::config{Slave_Key}","\t")) ) {
			if ($NMIS::debug) { print "\t loadEventStateSlave: could not find or read $NMIS::config{Slave_Table}: $!\n"; }
			return;
		}
	}
	else {
		if ($NMIS::debug) { print "\t loadEventStateSlave: could not find or read $NMIS::config{Slave_Table}: $!\n"; }
		return;
	}
	print "\t loadEventStateSlave: Loaded $NMIS::config{Slave_Table}\n" if $NMIS::debug;

	foreach my $name ( keys %slave ) {
		my $file = "$NMIS::config{'<nmis_var>'}/".lc($name)."_event.dat";
		sysopen(DATAFILE, "$file", O_RDONLY) 
			or warn returnTime." loadEventStateSlave, Couldn't open file $file: $!\n";
		flock(DATAFILE, LOCK_SH) or warn "loadEventStateSlave, can't lock filename: $!";
		if ($NMIS::debug ) {print "\t loaded slave eventfile: $file\n"; }


		# File format is StartDate,LastChange,Node,Event,Event_Level,Details,Ack,Escalate,Notify
		while (<DATAFILE>) {
		    chomp;
			#++$NMIS::eventCount;		# dont need this - only display real master events in 'events' but color dashboard

			# whack all the splits into an array
			@eventdetails = split ",", $_;

			# using temp variables for readability
			$node = $eventdetails[2];
			$event = $eventdetails[3];
			$level = $eventdetails[4];
			$details = $eventdetails[5];

			# define a hash index which uniquely identifies each event type for each event 
			# Lets try node_event_details!!
			$event_hash = &eventHash($node, $event, $details); 

			$NMIS::eventTable{$event_hash}{current} = "true";
			$NMIS::eventTable{$event_hash}{startdate} = $eventdetails[0];
			$NMIS::eventTable{$event_hash}{lastchange} = $eventdetails[1];
			$NMIS::eventTable{$event_hash}{node} = $node;
			$NMIS::eventTable{$event_hash}{event} = $event;
			$NMIS::eventTable{$event_hash}{event_level} = $level;
			$NMIS::eventTable{$event_hash}{details} = $details;
			$NMIS::eventTable{$event_hash}{ack} = $eventdetails[6];
			$NMIS::eventTable{$event_hash}{escalate} = $eventdetails[7];
			$NMIS::eventTable{$event_hash}{notify} = $eventdetails[8];
		}
		close(DATAFILE) or warn "loadEventStateSlave, can't close filename: $!";
	} # next slave_event.dat
}

sub runEventDebug {
	my $handle = &loadEventStateLock;
	&writeEventStateLock($handle);
}

sub eventHash {
	# Calculate the event hash the same way everytime.
 	#build an event hash string
	my $hash_node = shift;
	my $hash_event = shift;
	my $hash_details = shift;
	
	if ( $hash_event =~ /proactive/i ) { $hash_details = ""; }

	if ( $hash_details eq "" ) { return "$hash_node-$hash_event"; }
	else { 
		return "$hash_node-$hash_event-$hash_details"; 
	}
}

sub eventExist {
	my $node = shift;
	my $event = shift;
	my $details = shift;

	my $event_hash = &eventHash($node,$event,$details);

	if ( $NMIS::eventTable{$event_hash}{node} eq $node ) {
		return "true";
	}
	else {
		return "false"; 
	} 
}

sub checkEvent {	
	# Check event is called after determining that something is up!
	# Check event sees if an event for this node/interface exists 
	# if it exists it deletes it from the event state table/log
	# and then calls notify with the Up event including the time of the outage
	my %args = @_;
	my $outage;

	my $event_hash = &eventHash($args{node},$args{event},$args{details});

	# re-load the event State for reading only.
	&loadEventStateNoLock;

	if ( &eventExist($args{node},$args{event},$args{details}) eq "true" ) {
		# The opposite of this event exists log an UP and delete the event

		# save some stuff, as we cant rely on the hash after the write 
		$args{notify} = $NMIS::eventTable{$event_hash}{notify};
		$args{escalate} = $NMIS::eventTable{$event_hash}{escalate};
		# the event length for logging
		$outage = convertSecsHours(time - $NMIS::eventTable{$event_hash}{startdate});

		# re-open the file with a lock, as we to wish to update
		my $handle = &loadEventStateLock;
		# make sure we still have a valid event
		if ( exists $NMIS::eventTable{$event_hash}{current} ) {
			# Delete the event!!!!!
			$NMIS::eventTable{$event_hash}{current} = "false";
		}
		&writeEventStateLock($handle);

		# Just log an up event now.
		if ( $args{event} eq "Node Down" ) {
			$args{event} = "Node Up";
			$args{details} = "Time=$outage secs";
		}
		elsif ( $args{event} eq "Interface Down" ) {
			$args{event} = "Interface Up";
			$args{details} = "$args{details} Time=$outage secs";
		}
		elsif ( $args{event} eq "SNMP Down" ) {
			$args{event} = "SNMP Up";
			$args{details} = "Time=$outage secs";
		}
		elsif ( $args{event} eq "RPS Fail" ) {
			$args{event} = "RPS Up";
			$args{details} = "Time=$outage secs";
		}
		elsif ( $args{event} =~ /down/i ) {
			$args{event} =~ s/down/Up/i;
			if ( $args{details} eq "" ) { $args{details} = "Time=$outage secs"; }
			else { $args{details} = "$args{details} Time=$outage secs"; }
		}
		elsif ( $args{event} =~ /Proactive/ ) {
			$args{event} = "$args{event} Closed";
			$args{details} = "$args{details} Time=$outage secs";
		}
		# check the notify field of this event and if not false, assume this is a key into the escalation.csv
		# to get back a list of contacts to send up events too
		if ( $args{notify} ne "false" and $args{notify} ne "" ) {
			&UpNotify( key => $args{notify}, node => $args{node}, event => $args{event}, escalate => $args{escalate}, age => $outage, details => $args{details} );
		}
		&notify(node => $args{node}, role => $args{role}, type => $args{type}, event => $args{event}, level => $args{level}, details => $args{details});
	}
}
# send UP events to all those contacts notified as part of the escalation procedure
sub UpNotify {
	my %args = @_;
	my %contact_table;
	my $target;
	my $contact;
	my %email_seen;
	my %ccopy_seen;
	my %pager_seen;
	my %net_seen;

	%contact_table = loadCSV($NMIS::config{Contacts_Table},$NMIS::config{Contacts_Key},"\t");
	my $time = &returnDateStamp;

	# add a full format time string for emails and message notifications
	# pull the system timezone and then the local time
	my $msgtime;	
	if ($^O =~ /win32/i) {
	# could add timezone code here
		$msgtime = scalar localtime;
	}
	else {
	# assume UNIX box - look up the timezone as well.
		if (uc((split " ",`date`)[4]) eq "CET") {
			my @time = split " ",(scalar localtime);
			$msgtime = returnDateStamp;
		} else {
			$msgtime=uc((split " ", `date`)[4]) . " " . (scalar localtime);
		}
	}

	# pull in the escalation table with the full length key
	my %esc_table = loadCSV($NMIS::config{Escalation_Table},$NMIS::config{Escalation_Key},"\t");

	foreach my $i ( 0 .. $args{escalate} ) {		# escalation level that we reached.

		# get the string of type email:contact1:contact2,netsend:contact1:contact2,pager:contact1:contact2,email:sysContact
		my $level = lc ($esc_table{$args{key}}{'Level'.$i});
		if ($NMIS::debug) { print "\tUpNotify: found $level at Level$i in Group:$esc_table{$args{key}}{Group} Role:$esc_table{$args{key}}{Role} Type:$esc_table{$args{key}}{Type} Event:$esc_table{$args{key}}{Event} Event_Node:$esc_table{$args{key}}{Event_Node} Event_Details:$esc_table{$args{key}}{Event_Details}\n"; }

		if ( $level ne "" ) {
			# Now we have a string, check for multiple notify types
			foreach my $field ( split "," , $level ) {
				$target = "";
				my @x = split /:/ , $field;
				my $type = shift @x;			# netsend, email, or pager ?
				if ( $type eq "email" ) {
					foreach $contact (@x) {

						# prevent duplicate up notification - which could happen with multiple escalation levels
						if ( exists $email_seen{$contact} ) { next; }
						else { $email_seen{$contact} = 1; }

						# if sysContact, use device syscontact as key into the contacts table hash
						if ( $contact eq "syscontact" ) {
							loadSystemFile($args{node});
							$contact = $NMIS::systemTable{sysContact};
							if ($NMIS::debug) { print "\tUsing node $args{node} sysContact $NMIS::systemTable{sysContact}\n";}
						}
						if ( exists $contact_table{$contact} ) {			
							if ( dutyTime(\%contact_table, $contact) ) {	# do we have a valid dutytime ??
								$target = $target ? $target.",".$contact_table{$contact}{Email} : $contact_table{$contact}{Email};
							}
						}
						else {
							if ($NMIS::debug) { print "\tContact $contact not found in Contacts table\n";}
						}
					} #foreach contact

					# no email targets found, and if default contact not found, assume we are not covering 24hr dutytime in this slot, so no mail.
					# maybe the next levelx escalation field will fill in the gap
					if ( !$target ) { 
						$target = $contact_table{default}{Email};
						if ($NMIS::debug) { print "\tNo email contact matched (maybe check DutyTime and TimeZone?) - looking for default contact $target\n"; }
					}
					if ( $target ) { 
						sendEmail(
							to => $target, 
							subject => "$args{node} UP Event Notification Normal $args{event} $args{details} at $msgtime", 
							body => "Node:\t$args{node}\nUP Event Notification\nEvent Elapsed Time:\t$args{age}\nEvent:\t$args{event}\nDetails:\t$args{details}\n",
							from => $NMIS::config{mail_from}, 
							server => $NMIS::config{mail_server}, 
							domain => $NMIS::config{mail_domain},
							priority => &eventToSMTPPri("Normal"),
							debug => $NMIS::debug
						);
						#log all emails in the EventLog.
						&logEvent("$args{node}", "Sendmail UP Event to $target", "$args{event_level}", "$args{details}");
						if ($NMIS::debug) { print "\tUP Event Notification node=$args{node} target=$target event=$args{event} details=$args{details}\n"; }
					}
				} # end email
				### Carbon copy notifications - no action required - FYI only.
				elsif ( $type eq "ccopy" ) {
					foreach $contact (@x) {

						# prevent duplicate up notification - which could happen with multiple escalation levels
						if ( exists $ccopy_seen{$contact} ) { next; }
						else { $ccopy_seen{$contact} = 1; }

						# if sysContact, use device syscontact as key into the contacts table hash
						if ( $contact eq "syscontact" ) {
							$contact = $NMIS::systemTable{sysContact};
							if ($NMIS::debug) { print "\tUsing node $args{node} sysContact $NMIS::systemTable{sysContact}\n";}
						}
						if ( exists $contact_table{$contact} ) {			
							if ( dutyTime(\%contact_table, $contact) ) {	# do we have a valid dutytime ??
								$target = $target ? $target.",".$contact_table{$contact}{Email} : $contact_table{$contact}{Email};
							}
						}
						else {
							if ($NMIS::debug) { print "\tContact $contact not found in Contacts table\n";}
						}
					} #foreach

					# no email targets found, and if default contact not found, assume we are not covering 24 time, so no mail.
					if ( !$target ) { 
						$target = $contact_table{default}{Email};
						if ($NMIS::debug) { print "\tNo ccopy contact matched (maybe check DutyTime and TimeZone?) - looking for default contact $target\n"; }
					}
					if ( $target ) { 
						sendEmail(
							to => $target, 
							subject => "Copy of UP Event Notification $args{node} $args{event} $args{details} at $msgtime", 
							body => "FYI only\n\nCopy of UP Event Notification\nEvent Elapsed Time:\t$args{age}\nNode:\t$args{node}\nEvent:\t$args{event}\nDetails:\t$args{details}\n",
							from => $NMIS::config{mail_from}, 
							server => $NMIS::config{mail_server}, 
							domain => $NMIS::config{mail_domain},
							priority => &eventToSMTPPri("Normal"),
							debug => $NMIS::debug
						);
						#log all emails in the EventLog.
						&logEvent("$args{node}", "Send ccopy mail UP Event to $target", "$args{event_level}", "$args{details}");
						if ($NMIS::debug) { print "\tUP Event Notification node=$args{node} target=$target level=Normal event=$args{event} details=$args{details}\n"; }
					}
				} # end ccopy
				# now the netsends
				elsif ( $type eq "netsend" ) {
					my $message = "UP Event Notification $args{node} Normal $args{event} $args{details} at $msgtime";
					foreach ( @x ) {

						# prevent duplicate up notification - which could happen with multiple escalation levels
						if ( exists $net_seen{$_} ) { next; }
						else { $net_seen{$_} = 1; }

						# read any stdout messages and throw them away
						if ($^O =~ /win32/i) {
							# win32 platform
							my $dump=`net send $_ $message`;
						}
						else {
							# Linux box
							my $dump=`echo $message|smbclient -M $_`;
						}
						if ($NMIS::debug) { print "\tNetSend $message to $_\n";}
						&logEvent("$args{node}", "NetSend $message to $_", "Normal", "$args{details}");
					} #foreach
				} # end netsend
				# now the pagers
				elsif ( $type =~ /pager./i ) {
					foreach $contact (@x) {

						# prevent duplicate up notification - which could happen with multiple escalation levels
						if ( exists $pager_seen{$contact} ) { next; }
						else { $pager_seen{$contact} = 1; }

						# if sysContact, use device syscontact as key into the contacts table hash
						if ( $contact eq "syscontact" ) {
							$contact = $NMIS::systemTable{sysContact};
							if ($NMIS::debug) { print "\tUsing node $args{node} sysContact $NMIS::systemTable{sysContact}\n";}
						}
						if ( exists $contact_table{$contact} ) {			
							if ( dutyTime(\%contact_table, $contact) ) {	# do we have a valid timezone ??
								$target = $target ? $target.",".$contact_table{$contact}{Pager} : $contact_table{$contact}{Pager};
							}
						}
						else {
							if ($NMIS::debug) { print "\tContact $contact not found in Contacts table\n";}
						}
					} #foreach
					if ( !$target ) { # no pager targets found, could set last resort pager target here.
						$target = $contact_table{default}{Pager}; 
						if ($NMIS::debug) { print "\tNo pager contact matched (maybe check DutyTime and TimeZone?) - using default contact $contact\n"; }
					}
					sendSNPP(
						server => $NMIS::config{snpp_server},
						pagerno => $target,
						message => "NMIS: UPNotify $args{node} Normal $args{event} $args{details}"
					);
					# log all pagers in the EventLog.
					&logEvent("$args{node}", "SendSNPP UP Event to $target", "Normal", "$args{details}");
					if ($NMIS::debug) { print "\t SendSNPP UP Event to $target Normal $args{details}\n"; }
				} # end pager

				else {
					if ($NMIS::debug) { print "\tERROR UpNotify problem with notify target unknown at level$args{escalate} $level type=$type\n";}
				} # type
			} # foreach field
		} # endif level
	}
}

# Throw an Event to the event log
sub logEvent {	
	my @list = @_;
	grep { s/,/ /g } @list;		# strip any commas from the parameter list
	my $node = shift @list;
	my $event = shift @list;
	my $level = shift @list;
	my $details = shift @list;
	my $time = time;

	my $outage;

	if ( &outageCheck($node,time) eq "true" ) {
		$outage = &outageCheckHash($node,time);
		$details = "$details change=$NMIS::outageTable{$outage}{change}";
	}

	# Log the NEW event to the event log!!!
	sysopen(DATAFILE, "$NMIS::config{event_log}", O_WRONLY | O_APPEND | O_CREAT)
		 or warn returnTime." logEvent, Couldn't open file $NMIS::config{event_log}. $!\n";
	flock(DATAFILE, LOCK_EX) or warn "logEvent, can't lock filename: $!";
	print DATAFILE "$time,$node,$event,$level,$details\n";
	close(DATAFILE) or warn "logEvent, can't close filename: $!"; 
	#
	NMIS::setFileProt($NMIS::config{event_log}); # set file owner/permission, default: nmis, 0775
}

# Throw an Event to the current event state file
# improved event.dat file locking
sub eventAdd {	
	my $node = shift;
	my $event = shift;
	my $level = shift;
	my $details = shift;
	my $time = time;

	my $escalate = -1;
	my $event_hash = &eventHash($node,$event,$details);

	# before we log check the state table if there is currently an event outstanding.
	# re-load the event file into the event State Hash
	&loadEventStateNoLock;

	if ( &eventExist($node,$event,$details) eq "true" ) {
		# There exists an event of this type already.
		# Update the lastchange time with time now and write log outagain.

		# reopen the file with a lock
		my $handle = &loadEventStateLock;
		# make sure we still have a valid event
		if ( exists $NMIS::eventTable{$event_hash}{current} ) {
			$NMIS::eventTable{$event_hash}{lastchange} = time;
		}
		&writeEventStateLock($handle);
	}
	# Otherwise it is a new event so better log it out to the file
	else {
		# dont try and maintain state in the hash, just update the file.
		# the hash should be reloaded from the file wherever it is needed.
		if ( $event !~ /syslog|node reset|node failover|proactive|up/i or $event =~ /proactive/i ) {
			# Update the event file
			sysopen(DATAFILE, "$NMIS::config{event_file}", O_WRONLY | O_APPEND ) 
				or warn returnTime." eventAdd, Couldn't open file $NMIS::config{event_log}. $!\n";
			flock(DATAFILE, LOCK_EX) or warn "eventAdd, can't lock filename: $!";
			print DATAFILE "$time,$time,$node,$event,$level,$details,false,$escalate,false\n";
			close(DATAFILE) or warn "eventAdd, can't close filename: $!"; 
		}
	}
} # eventAdd

sub eventAck {
	my %args = @_;
	my $event_hash;

	my $handle = &loadEventStateLock;
	#print STDERR "eventAck\tnode=$args{node} event=$args{event} details=$args{details} ack=$args{ack}\n";
	$event_hash = &eventHash($args{node}, $args{event}, $args{details});
	# make sure we still have a valid event
	if ( exists $NMIS::eventTable{$event_hash}{current} ) {
		if ( $args{ack} eq "true" and $NMIS::eventTable{$event_hash}{ack} eq "false"  ) {

			### if a TRAP type event, then trash when ack. event record will be in event log if required
			if ( $NMIS::eventTable{$event_hash}{event} eq "TRAP" ) {
				&logEvent("$NMIS::eventTable{$event_hash}{node}", "deleted event: $NMIS::eventTable{$event_hash}{event}", "Normal", "$NMIS::eventTable{$event_hash}{details}");
				delete $NMIS::eventTable{$event_hash};
			}
			else {
				#&logEvent("$args{node}", "$args{event}", "Normal", "$args{details} acknowledge=true");
				&logEvent("$args{node}", "$args{event}", "Normal", "$args{details}acknowledge=true ($args{ackuser})");
				$NMIS::eventTable{$event_hash}{ack} = "true";
				$NMIS::eventTable{$event_hash}{lastchange} = time;
			}
		}
		elsif ( $args{ack} eq "false" and $NMIS::eventTable{$event_hash}{ack} eq "true"  ) {
			#&logEvent("$args{node}", "$args{event}", "$NMIS::eventTable{$event_hash}{event_level}", "$args{details} acknowledge=false");
			&logEvent("$args{node}", "$args{event}","$NMIS::eventTable{$event_hash}{event_level}", "$args{details}acknowledge=false ($args{ackuser})");
			$NMIS::eventTable{$event_hash}{ack} = "false";
			$NMIS::eventTable{$event_hash}{lastchange} = time;
		}
	}
	# close file and unlock
	&writeEventStateLock($handle);
} # eventAck


sub eventPolicy {
	### AS 16/4/01 event policy routine controls how events are handled
	### EHG set defaults for missing events

	# determines wether or not to do notify for given events.
	my %args = @_;
	my $event_key;
	my %event_result;
	my %event_table;
	if ( $args{role} eq "" ) { $args{role} = "access"; }
	if ( $args{type} eq "" ) { $args{type} = "router"; }
	
	if ( $args{event} =~ /Proactive/ ) {
		%event_table = loadCSV($NMIS::config{Events_Table},"Event:Level","\t");
		$event_key = lc($args{event}."_".$args{level});
	}
	else {
		%event_table = loadCSV($NMIS::config{Events_Table},$NMIS::config{Events_Key},"\t");
		$event_key = lc($args{event}."_".$args{role}."_".$args{type});
	}
	# if key not found, policy not in event hash and rekey to default policy
	if ( !exists $event_table{$event_key} ) { $event_key = "default_default_default";}

	#send back results
	#level,notify,log,pager,mail
	$event_result{level} = $event_table{$event_key}{Level};
	$event_result{notify} = $event_table{$event_key}{Notify};
	$event_result{log} = $event_table{$event_key}{Log};
	$event_result{pager} = $event_table{$event_key}{Pager};
	$event_result{mail} = $event_table{$event_key}{Mail};
	if ($NMIS::debug) { print returnTime." eventPolicy argEvent=$args{event} argLevel=$args{level} event=$event_table{$event_key}{Event} level=$event_table{$event_key}{Level} notify=$event_table{$event_key}{Notify}\n"; }
	#print STDERR returnTime." eventPolicy key=$event_key role=$args{role} type=$args{type} argEvent=$args{event} argLevel=$args{level} event=$event_table{$event_key}{Event} level=$event_table{$event_key}{Level} notify=$event_table{$event_key}{Notify}\n";
	#Ahhh the magic of hash's
	return(%event_result);
} # eventPolicy


# EG here only threshold sends us an eventlevel...

sub notify {
	###
	### EHG 28 28/8/02 - changed logic - these do not intersect !!!
	### log is log
	### notify is write to current event state table !!!!! regardless of outage status
	### email is send email to contact referenced by device sysContact
	### pager is send page to contact referenced by device sysContact
	#
	### AS 16/4/01 - Modified notify to implement event policy.
	# notify decides if/who/how anyone should be notified of an event.
	# and only notifies people once of an event by using the event table!
	my %args = @_;
	my $node = $args{node};
	my $role = $args{role};
	my $type = $args{type};
	my $event = $args{event};
	my $level = $args{level};
	my $details = $args{details};

	# Sets the default type and role for devices without entries in nodeTable
	if ( $role eq "" ) { $role = "access"; }
	if ( $type eq "" ) { $type = "router"; }

	my $outage;
	my $target;
	my $contact;
	my $message;
	my $notify = "false";
	my $mail = "false";
	my $pager = "false";
	my $log = "false";
	my $time = &returnDateStamp;
	my %event_result;
	my $pol_event;
	my $event_hash = &eventHash($node,$event,$details);

	# Before we notify etc check for duplicate events
	# reload the event state file
	&loadEventStateNoLock;

	if ( &eventExist($node,$event,$details) eq "false" ) {
		# Get the event policy and the rest is easy.
		if ( 	$event =~ /Proactive.*Closed/ ) { $pol_event = "Proactive Closed"; }
		elsif ( $event =~ /Proactive/ ) 	{ $pol_event = "Proactive"; }
		elsif ( $event =~ /down/i and $event !~ /SNMP|Node|Interface|Service/ ) { 
			$pol_event = "Generic Down";
		}
		elsif ( $event =~ /up/i and $event !~ /SNMP|Node|Interface|Service/ ) { 
			$pol_event = "Generic Up";
		}
		else 	{ $pol_event = $event; }
		%event_result = eventPolicy(event => $pol_event, role => $role, type => $type, level => $level);

		$notify = $event_result{notify};
		$mail = $event_result{mail};
		$pager = $event_result{pager};
		$level = $event_result{level};
		$log = $event_result{log};

		if ($NMIS::debug) { print returnTime." notify: node=$node event=$event role=$role level=$level details=$details\n"; }
	
		if ( $notify eq "" or $log eq "" ) { 
			$message = "Event type not defined: node=$node level=$level event=$event details=$details log=$log";
			logMessage("notify, $node, $message");
			if ($NMIS::debug) { print returnTime." notify $message\n"; }
		}

		if ( $notify eq "true" and $event !~ /Proactive.*Closed/ ) {	
			# Push the event onto the event table.
			&eventAdd("$node", "$event", "$level", "$details");
		}
		# first time thru, so do the mail and pager
		### not subject to dutytime check !!!
		#
		if ( &outageCheck($node,time) ne "true" ) {
			if ( $mail eq "true" ) {
				### AS 1/4/2001 - set target to be whatever the sysContact email is.
				my %contact_table = loadCSV($NMIS::config{Contacts_Table},$NMIS::config{Contacts_Key},"\t");
				$contact = $NMIS::systemTable{sysContact};
				$target = $contact_table{$contact}{Email};
				# quick test to make sure the the target is never blank.
				if ( $target eq "" and $contact ne "default" ) {
					$target = $contact_table{default}{Email};
				}
				else { $target = $contact_table{default}{Email}; }
			    if ($NMIS::debug) { print returnTime." notify: sendmail node=$node Contact=$contact and target=$target\n"; }
				sendEmail(
					to => $target,
					subject => "$time $args{node} $level $args{event} $args{details}", 
					body => "Node:\t$args{node}\nSeverity:\t$level\nEvent:\t$args{event}\nDetails:\t$args{details}\nhttp://$NMIS::config{nmis_host}$NMIS::config{nmis}?type=event&node=$args{node}",
					from => $NMIS::config{mail_from}, 
					server => $NMIS::config{mail_server}, 
					domain => $NMIS::config{mail_domain},
					priority => &eventToSMTPPri($NMIS::eventTable{$event_hash}{event_level}), 
					debug => $NMIS::debug
				);
				# save all emails in the eventlog for later tracing if required.
				&logEvent("$args{node}", "Sendmail to $target", "$level", "$args{details}");
			}
			# Now if we had pager type notification here we would have 
			# pager=true set previously by the relevent types
			if ( $pager eq "true" ) {
				#The method for email addresses using contacts could be used here to do paging.
				#&sendPagerMessage("$node", "$event", "$level", "$details");
			}
		}
	}
	# event must exist, so update the time as we have a new duplicate event.
	else {
		if ( $NMIS::eventTable{$event_hash}{ack} eq "false" ) {
			my $handle = &loadEventStateLock;
			# make sure we still have a valid event	
			if ( exists $NMIS::eventTable{$event_hash}{current} ) {
				$NMIS::eventTable{$event_hash}{lastchange} = time;
			}
			&writeEventStateLock($handle);
		}
	}
	# log all events - even flapping interfaces.
	if ( $log eq "true" ) {
		&logEvent("$node", "$event", "$level", "$details");
	}
} # end notify

sub summaryStats {
	my %args = @_;
	my $node = $args{node};
	my $type = $args{type};
	my $start = $args{start};
	my $end = $args{end};
	my $ifDescr = $args{ifDescr};
	my $speed = $args{speed};
	my $key = $args{key};

	my %summaryHash;

	my $ERROR;
	my ($graphret,$xs,$ys);

	my $database = getRRDFileName(type => $type, node => $node, nodeType => $NMIS::systemTable{nodeType}, extName => $ifDescr);
	if ( -r $database ) {
		if ( $type eq "health" ) { 
			($graphret,$xs,$ys) = RRDs::graph "/dev/null", 
			"--start", "$start", 
			"--end", "$end", 
			"DEF:reach=$database:reachability:AVERAGE", 
			"DEF:avail=$database:availability:AVERAGE", 
			"DEF:health=$database:health:AVERAGE", 
			"DEF:response=$database:responsetime:AVERAGE", 
			"DEF:loss=$database:loss:AVERAGE", 
			"PRINT:reach:AVERAGE:reachable=%1.3lf",
			"PRINT:avail:AVERAGE:available=%1.3lf",
			"PRINT:health:AVERAGE:health=%1.3lf",
			"PRINT:response:AVERAGE:response=%1.2lf",
			"PRINT:loss:AVERAGE:loss=%1.2lf"
			;
		}
		elsif ( $type eq "util" ) { 
			if ( $ifDescr ne "" and  $speed eq "" ) {
				logMessage("summaryStats, $node, need speed to do interface stats interface=$ifDescr");
			}
			($graphret,$xs,$ys) = RRDs::graph "/dev/null", 
			"--start", "$start", 
			"--end", "$end", 
			"DEF:input=$database:ifInOctets:AVERAGE", 
			"DEF:output=$database:ifOutOctets:AVERAGE", 
			"DEF:status=$database:ifOperStatus:AVERAGE", 
			"CDEF:inputUtil=input,8,*,$speed,/,100,*", 
			"CDEF:outputUtil=output,8,*,$speed,/,100,*", 
			"CDEF:totalUtil=outputUtil,inputUtil,+,2,/", 
			"PRINT:status:AVERAGE:availability=%1.2lf",
			"PRINT:inputUtil:AVERAGE:inputUtil=%1.2lf",
			"PRINT:outputUtil:AVERAGE:outputUtil=%1.2lf",
			"PRINT:totalUtil:AVERAGE:totalUtil=%1.2lf"
			;
		}
		elsif ( $type eq "pkts" ) {
			($graphret,$xs,$ys) = RRDs::graph "/dev/null", 
			"--start", "$start", 
			"--end", "$end", 
			"DEF:ifInUcastPkts=$database:ifInUcastPkts:AVERAGE", 
			"DEF:ifInNUcastPkts=$database:ifInNUcastPkts:AVERAGE", 
			"DEF:ifInDiscards=$database:ifInDiscards:AVERAGE", 
			"DEF:ifInErrors=$database:ifInErrors:AVERAGE", 
			"DEF:ifOutUcastPkts=$database:ifOutUcastPkts:AVERAGE", 
			"DEF:ifOutNUcastPkts=$database:ifOutNUcastPkts:AVERAGE", 
			"DEF:ifOutDiscards=$database:ifOutDiscards:AVERAGE", 
			"DEF:ifOutErrors=$database:ifOutErrors:AVERAGE", 
			"PRINT:ifInUcastPkts:AVERAGE:ifInUcastPkts=%1.2lf",
			"PRINT:ifInNUcastPkts:AVERAGE:ifInNUcastPkts=%1.2lf",
			"PRINT:ifInDiscards:AVERAGE:ifInDiscards=%1.2lf",
			"PRINT:ifInErrors:AVERAGE:ifInErrors=%1.2lf",
			"PRINT:ifOutUcastPkts:AVERAGE:ifOutUcastPkts=%1.2lf",
			"PRINT:ifOutNUcastPkts:AVERAGE:ifOutNUcastPkts=%1.2lf",
			"PRINT:ifOutDiscards:AVERAGE:ifOutDiscards=%1.2lf",
			"PRINT:ifOutErrors:AVERAGE:ifOutErrors=%1.2lf"
			;
		}
		elsif ( $type eq "bits" ) { 
			($graphret,$xs,$ys) = RRDs::graph "/dev/null", 
			"--start", "$start", 
			"--end", "$end", 
			"DEF:input=$database:ifInOctets:AVERAGE", 
			"DEF:output=$database:ifOutOctets:AVERAGE", 
			"DEF:status=$database:ifOperStatus:AVERAGE", 
			"CDEF:inputBits=input,8,*", 
			"CDEF:outputBits=output,8,*", 
			"PRINT:status:AVERAGE:Availability=%1.2lf",
			"PRINT:inputBits:AVERAGE:inputBits=%1.2lf",
			"PRINT:outputBits:AVERAGE:outputBits=%1.2lf"
			;
		}
		elsif ( $type eq "cpu" and $NMIS::systemTable{nodeModel} =~ /CiscoRouter|CatalystIOS|Riverstone/) { 
			($graphret,$xs,$ys) = RRDs::graph "/dev/null", 
			"--start", "$start", 
			"--end", "$end", 
			"DEF:avgBusy1=$database:avgBusy1:AVERAGE", 
			"DEF:avgBusy5=$database:avgBusy5:AVERAGE", 
			"DEF:MemPUsed=$database:MemoryUsedPROC:AVERAGE", 
			"DEF:MemPFree=$database:MemoryFreePROC:AVERAGE", 
			"DEF:MemIUsed=$database:MemoryUsedIO:AVERAGE", 
			"DEF:MemIFree=$database:MemoryFreeIO:AVERAGE", 
			"CDEF:totalPMem=MemPUsed,MemPFree,+",
			"CDEF:totalIMem=MemIUsed,MemIFree,+",
			"CDEF:perPUsedMem=MemPUsed,totalPMem,/,100,*",
			"CDEF:perPFreeMem=MemPFree,totalPMem,/,100,*",
			"CDEF:perIUsedMem=MemIUsed,totalIMem,/,100,*",
			"CDEF:perIFreeMem=MemIFree,totalIMem,/,100,*",
			"PRINT:avgBusy1:AVERAGE:avgBusy1min=%1.2lf",
			"PRINT:avgBusy5:AVERAGE:avgBusy5min=%1.2lf",
			"PRINT:perPUsedMem:AVERAGE:ProcMemUsed=%1.2lf",
			"PRINT:perPFreeMem:AVERAGE:ProcMemFree=%1.2lf",
			"PRINT:perIUsedMem:AVERAGE:IOMemUsed=%1.2lf",
			"PRINT:perIFreeMem:AVERAGE:IOMemFree=%1.2lf"
			;
		}
		elsif ( $type eq "cpu" and $NMIS::systemTable{nodeModel} =~ /Redback/) { 
			($graphret,$xs,$ys) = RRDs::graph "/dev/null", 
			"--start", "$start", 
			"--end", "$end", 
			"DEF:avgBusy1=$database:avgBusy1:AVERAGE", 
			"DEF:avgBusy5=$database:avgBusy5:AVERAGE", 
			"PRINT:avgBusy1:AVERAGE:avgBusy1min=%1.2lf",
			"PRINT:avgBusy5:AVERAGE:avgBusy5min=%1.2lf"
			;
		}
		elsif ( $type eq "cpu" and $NMIS::systemTable{nodeModel} =~ /FoundrySwitch/) { 
			($graphret,$xs,$ys) = RRDs::graph "/dev/null", 
			"--start", "$start", 
			"--end", "$end", 
			"DEF:avgBusy1=$database:avgBusy1:AVERAGE", 
			"DEF:MemPUsed=$database:MemoryUsedPROC:AVERAGE", 
			"DEF:MemPFree=$database:MemoryFreePROC:AVERAGE", 
			"CDEF:totalPMem=MemPUsed,MemPFree,+",
			"CDEF:perPUsedMem=MemPUsed,totalPMem,/,100,*",
			"CDEF:perPFreeMem=MemPFree,totalPMem,/,100,*",
			"PRINT:avgBusy1:AVERAGE:avgBusy1min=%1.2lf",
			"PRINT:perPUsedMem:AVERAGE:ProcMemUsed=%1.2lf",
			"PRINT:perPFreeMem:AVERAGE:ProcMemFree=%1.2lf"
			;
		}
		elsif ( $type eq "calls" and $NMIS::systemTable{nodeModel} =~ /CiscoRouter/) { 
			($graphret,$xs,$ys) = RRDs::graph "/dev/null", 
			"--start", "$start", 
			"--end", "$end", 
			"DEF:DS0CallType=$database:DS0CallType:AVERAGE", 
			"DEF:L2Encapsulation=$database:L2Encapsulation:AVERAGE", 
			"DEF:CallCount=$database:CallCount:AVERAGE", 
			"DEF:AvailableCallCount=$database:AvailableCallCount:AVERAGE", 
			"DEF:totalIdle=$database:totalIdle:AVERAGE", 
			"DEF:totalUnknown=$database:totalUnknown:AVERAGE", 
			"DEF:totalAnalog=$database:totalAnalog:AVERAGE", 
			"DEF:totalDigital=$database:totalDigital:AVERAGE", 
			"DEF:totalV110=$database:totalV110:AVERAGE", 
			"DEF:totalV120=$database:totalV120:AVERAGE", 
			"DEF:totalVoice=$database:totalVoice:AVERAGE", 
			"PRINT:DS0CallType:AVERAGE:DS0CallType=%1.2lf", 
			"PRINT:L2Encapsulation:AVERAGE:L2Encapsulation=%1.2lf", 
			"PRINT:CallCount:AVERAGE:CallCount=%1.0lf", 
			"PRINT:AvailableCallCount:AVERAGE:AvailableCallCount=%1.0lf", 
			"PRINT:totalIdle:AVERAGE:totalIdle=%1.0lf", 
			"PRINT:totalUnknown:AVERAGE:totalUnknown=%1.0lf", 
			"PRINT:totalAnalog:AVERAGE:totalAnalog=%1.0lf", 
			"PRINT:totalDigital:AVERAGE:totalDigital=%1.0lf", 
			"PRINT:totalV110:AVERAGE:totalV110=%1.0lf", 
			"PRINT:totalV120:AVERAGE:totalV120=%1.0lf", 
			"PRINT:totalVoice:AVERAGE:totalVoice=%1.0lf"
			;
		}
		## PIX only get proc mem  
      	elsif ( $type eq "cpu" and $NMIS::systemTable{nodeModel} =~ /CiscoPIX/) {
            ($graphret,$xs,$ys) = RRDs::graph "/dev/null",
            "--start", "$start",
            "--end", "$end",
            "DEF:avgBusy1=$database:avgBusy1:AVERAGE",
            "DEF:avgBusy5=$database:avgBusy5:AVERAGE",
            "DEF:MemPUsed=$database:MemoryUsedPROC:AVERAGE",
            "DEF:MemPFree=$database:MemoryFreePROC:AVERAGE",
            "CDEF:totalPMem=MemPUsed,MemPFree,+",
            "CDEF:perPUsedMem=MemPUsed,totalPMem,/,100,*",
            "CDEF:perPFreeMem=MemPFree,totalPMem,/,100,*",
            "PRINT:avgBusy1:AVERAGE:avgBusy1min=%1.2lf",
            "PRINT:avgBusy5:AVERAGE:avgBusy5min=%1.2lf",
            "PRINT:perPUsedMem:AVERAGE:ProcMemUsed=%1.2lf",
            "PRINT:perPFreeMem:AVERAGE:ProcMemFree=%1.2lf"
            ;
		} 
		### PVC
		elsif ( $type eq "pvc" ) {

           ($graphret,$xs,$ys) = RRDs::graph "/dev/null",
            "--start", "$start",
            "--end", "$end",
			"DEF:ReceivedBECNs=$database:ReceivedBECNs:AVERAGE",
			"DEF:ReceivedFECNs=$database:ReceivedFECNs:AVERAGE",
			"PRINT:ReceivedBECNs:AVERAGE:ReceivedBECNs=%1.2lf",
			"PRINT:ReceivedFECNs:AVERAGE:ReceivedFECNs=%1.2lf"
			;
		}

		### Catalyst type device rrd have MemoryUsedDRAM 
		elsif ( $type eq "cpu" and $NMIS::systemTable{nodeModel} =~ /Catalyst6000|Catalyst5000Sup3|Catalyst5005|Catalyst5000/) { 
			($graphret,$xs,$ys) = RRDs::graph "/dev/null", 
			"--start", "$start", 
			"--end", "$end", 
			"DEF:avgBusy1=$database:avgBusy1:AVERAGE", 
			"DEF:avgBusy5=$database:avgBusy5:AVERAGE", 
			"DEF:MemUsed=$database:MemoryUsedDRAM:AVERAGE", 
			"DEF:MemFree=$database:MemoryFreeDRAM:AVERAGE", 
			"CDEF:totalMem=MemUsed,MemFree,+",
			"CDEF:perUsedMem=MemUsed,totalMem,/,100,*",
			"CDEF:perFreeMem=MemFree,totalMem,/,100,*",
			"PRINT:avgBusy1:AVERAGE:avgBusy1min=%1.2lf",
			"PRINT:avgBusy5:AVERAGE:avgBusy5min=%1.2lf",
			"PRINT:perUsedMem:AVERAGE:ProcMemUsed=%1.2lf",
			"PRINT:perFreeMem:AVERAGE:ProcMemFree=%1.2lf"
			;
		}
		### AS 1 Apr 02 - Integrating Phil Reilly's Nortel changes
		elsif ( $type eq "acpu" ) { 
			($graphret,$xs,$ys) = RRDs::graph "/dev/null", 
			"--start", "$start", 
			"--end", "$end", 
			"DEF:rcSysCpuUtil=$database:rcSysCpuUtil:AVERAGE",
			"DEF:rcSysSwitchFabricUtil=$database:rcSysSwitchFabricUtil:AVERAGE",
			"DEF:rcSysBufferUtil=$database:rcSysBufferUtil:AVERAGE",
			"PRINT:rcSysCpuUtil:AVERAGE:rcSysCpuUtil=%1.2lf",
			"PRINT:rcSysSwitchFabricUtil:AVERAGE:rcSysSwitchFabricUtil=%1.2lf",
			"PRINT:rcSysBufferUtil:AVERAGE:rcSysBufferUtil=%1.2lf"
			;
		}
		
		elsif ( $type =~ /hrcpu/ ) {
			($graphret,$xs,$ys) = RRDs::graph "/dev/null",
			"--start", "$start",
			"--end", "$end",
			"DEF:hrCpuLoad=$database:hrCpuLoad:AVERAGE",
			"PRINT:hrCpuLoad:AVERAGE:hrCpuLoad=%1.2lf"
			;

		}
		# workaround to let hrcpu escalations
		elsif ( $type =~ /hrsmpcpu/ ) {
			($graphret,$xs,$ys) = RRDs::graph "/dev/null",
			"--start", "$start",
			"--end", "$end",
			"DEF:hrCpuLoad=$database:hrCpuLoad:AVERAGE",
			"PRINT:hrCpuLoad:AVERAGE:hrCpuLoad=%1.2lf"
			;

		}
		elsif ( $type eq "hrmem") {
			($graphret,$xs,$ys) = RRDs::graph "/dev/null",
			"--start", "$start",
			"--end", "$end",
			"DEF:hrMemSize=$database:hrMemSize:AVERAGE",		
			"DEF:hrMemUsed=$database:hrMemUsed:AVERAGE",
			"DEF:hrVMemSize=$database:hrVMemSize:AVERAGE",
			"DEF:hrVMemUsed=$database:hrVMemUsed:AVERAGE",
			"PRINT:hrMemSize:AVERAGE:hrMemSize=%1.2lf",
			"PRINT:hrMemSize:AVERAGE:hrMemSize=%1.2lf",
			"PRINT:hrVMemSize:AVERAGE:hrVMemSize=%1.2lf",
			"PRINT:hrVMemSize:AVERAGE:hrVMemSize=%1.2lf"
			;
		}
		elsif ( $type eq "hrdisk") {
			($graphret,$xs,$ys) = RRDs::graph "/dev/null",
			"--start", "$start",
			"--end", "$end",
			"DEF:hrDiskSize=$database:hrDiskSize:AVERAGE",
			"DEF:hrDiskUsed=$database:hrDiskUsed:AVERAGE",
			"PRINT:hrDiskSize:AVERAGE:hrDiskSize=%1.2lf",
			"PRINT:hrDiskUsed:AVERAGE:hrDiskUsed=%1.2lf"
			;
		}	
		elsif ( $type eq "modem" ) {
			($graphret,$xs,$ys) = RRDs::graph "/dev/null", 
			"--start", "$start", 
			"--end", "$end", 
			"DEF:TotalModems=$database:InstalledModem:AVERAGE", 
			"DEF:ModemsInUse=$database:ModemsInUse:AVERAGE", 
			"DEF:ModemsAvailable=$database:ModemsAvailable:AVERAGE", 
			"DEF:ModemsUnavailable=$database:ModemsUnavailable:AVERAGE", 
			"DEF:ModemsOffline=$database:ModemsOffline:AVERAGE", 
			"DEF:ModemsDead=$database:ModemsDead:AVERAGE", 
			"PRINT:TotalModems:AVERAGE:TotalModems=%1.2lf",
			"PRINT:ModemsInUse:AVERAGE:ModemsInUse=%1.2lf",
			"PRINT:ModemsAvailable:AVERAGE:ModemsAvailable=%1.2lf",
			"PRINT:ModemsUnavailable:AVERAGE:ModemsUnavailable=%1.2lf",
			"PRINT:ModemsOffline:AVERAGE:ModemsOffline=%1.2lf",
			"PRINT:ModemsDead:AVERAGE:ModemsDead=%1.2lf"
			;
		}
		else {
	  		logMessage("summaryStats, $node, type=$type is not a valid option");
			return;
		}
	}
	else { 
		logMessage("summaryStats, $node, type=$type has no database file $database"); 
		return;
	}

	if ($ERROR = RRDs::error) { 
  		logMessage("summaryStats, $node, RRD graph error database=$database: $ERROR");
	} else {
		# print "GRAPH: node=$node, $NMIS::systemTable{nodeType}, $database $graphret\n";   
		if ( scalar(@$graphret) ) {
			map { s/nan/NaN/g } @$graphret;			# make sure a NaN is returned !!
			foreach my $line ( @$graphret ) {
				(my $name, my $value) = split "=", $line;
				if ($key ne "") {
					$summaryHash{$key}{$name} = $value;
				} else {
					$summaryHash{$name} = $value;
				}
			}
			return %summaryHash;
		}
	}
}


### AS 9/4/01 added getGroupSummary for doing the metric stuff centrally!
### AS 24/5/01 fixed so that colors show for things which aren't complete
### also reweighted the metric to be reachability = %40, availability = %20
### and health = %40
### AS 16 Mar 02, implementing David Gay's requirement for deactiving
### a node, ie keep a node in nodes.csv but no collection done.
### AS 16 Mar 02, implemented configurable reachability, availability, health
### AS 3 Jun 02, fixed up blank dash, insert N/A for nasty things
### ehg 17 sep 02 add nan to the trap for nasty things
### ehg 17 sep 02 counted actual nodes down for summary display
sub getGroupSummary {
	my $group = shift || "";
	my $start_time = shift;
	my $end_time = shift;

	my @tmpsplit;
	my @tmparray;

	my %summaryHash;
	my $reportStats;
	my %nodecount;
	my $span;
	my $node;
	my $index;
	my $cache = 1;
	my $datafile;
	my $summary;

	my (@devicelist,$i,@nodedetails);
	# init the hash, so zero values display.
	$nodecount{total} = 0;
	$nodecount{down} = 0;
	
	if ( ! $start_time ) { $start_time = "-8 hours"; }
	if ( ! $end_time ) { $end_time = time; }

	#loadEventStateNoLock;		# surplus call
	#loadNodeDetails;			# surplus call

	if ( $start_time eq '-8 hours' ) {
		$summary = "summary8";
	}
	if ( $start_time eq '-16 hours' ) {
		$summary = "summary16";
	}

	# check if we have a valid cache file for the period asked for..
	# !!! big assumption here - that span = 8 hours !!!!
	# use a sempahore to lock, as 'do $file' probarly does not respect a file lock

	if ( $NMIS::config{SummaryCache} eq 'true' and $summary ne "") {

		$datafile = "$NMIS::config{'<nmis_var>'}/$summary.nmis";

		# check file modification time compared to us in days :-)
		my $timestamp = -M $datafile ;
		if ( $timestamp < .006 ) {

			%summaryHash = readVartoHash($summary);
			
			# sanity check - we expect number of records read to match number of nodes, else just fail it.
			# this may well happen during a master update
			my $node_cnt = 0 ;
			foreach my $node (keys %NMIS::nodeTable) {
				if ( exists $NMIS::nodeTable{$node}{slave} or exists $NMIS::nodeTable{$node}{slave2} ) { next; }
				$node_cnt++;
			}
			my $k = scalar keys %summaryHash;
			if ( $k ne $node_cnt ) {
				logMessage("getGroupSummary, couldn't do $datafile, got keys $k in cache, $node_cnt in nodeTable" );
				$cache = 0;
			}
		} else {
			logMessage("getGroupSummary, cgi cache file $datafile is old; timestamp $timestamp");
			$cache = 0;
		}
	} else { $cache = 0; }

	# this server
	unless ($cache) {
		%summaryHash = ();
		foreach $node ( keys %NMIS::nodeTable ) {
			if ( exists $NMIS::nodeTable{$node}{slave2} ){ next; }
			loadSystemFile($node);		# need this to get nodeType..
			%summaryHash = (%summaryHash,summaryStats(node => $node,type => "health",start => $start_time,end => $end_time,key => $node));
		}
	}

	# slave servers
	if ($NMIS::config{master_dash} eq "true") {
		foreach my $name ( keys %NMIS::slaveTable) {
			my %hash = ();
			if ($summary ne "") {
				# add hash with the slave info from disk
				%hash = readVartoHash("$name-$summary");
			} else {
				%hash = slaveConnect(host => $name, type => 'send', func => 'summary', group => $group,
					par1 => $start_time, par2 => $end_time );
			}
			if (%hash) { %summaryHash = (%summaryHash,%hash); }
		}
	}
			
	# Insert some nice status info about the devices for the summary menu.
NODE:
	foreach $node (sort ( keys (%NMIS::nodeTable) ) ) {
		# Only do the group - or everything if no group passed to us.
		if ( $group eq "" or $group eq $NMIS::nodeTable{$node}{group} ) {
			if ( $NMIS::nodeTable{$node}{active} ne "false" ) {
				# check local and slave server
				if ( eventExist($node,"Node Down","Ping failed") eq "true" or $NMIS::nodeTable{$node}{nodedown} eq "true" ) {
					($summaryHash{$node}{event_status},$summaryHash{$node}{event_color}) = eventLevel("Node Down",$NMIS::nodeTable{$node}{role});
					++$nodecount{down};
				}
				else {
					($summaryHash{$node}{event_status},$summaryHash{$node}{event_color}) = eventLevel("Node Up",$NMIS::nodeTable{$node}{role});
				}
					
				++$nodecount{total};
				if ( $summaryHash{$node}{reachable} !~ /nan|NaN|-1\.\#IO/	) {
					++$nodecount{reachable};
					$summaryHash{$node}{reachable_color} = colorHighGood($summaryHash{$node}{reachable});
					$summaryHash{total}{reachable} += $summaryHash{$node}{reachable};
				} else { $summaryHash{$node}{reachable} = "NaN" }

				if ( $summaryHash{$node}{available} !~ /nan|NaN|-1\.\#IO/ ) {
					++$nodecount{available};
					$summaryHash{$node}{available_color} = colorHighGood($summaryHash{$node}{available});
					$summaryHash{total}{available} += $summaryHash{$node}{available};
				} else { $summaryHash{$node}{available} = "NaN" }

				if ( $summaryHash{$node}{health} !~ /nan|NaN|-1\.\#IO/ ) {
					++$nodecount{health};
					$summaryHash{$node}{health_color} = colorHighGood($summaryHash{$node}{health});
					$summaryHash{total}{health} += $summaryHash{$node}{health};
				} else { $summaryHash{$node}{health} = "NaN" }

				if ( $summaryHash{$node}{response} !~ /nan|NaN|-1\.\#J/ ) {
					++$nodecount{response};
					$summaryHash{$node}{response_color} = colorResponseTime($summaryHash{$node}{response});
					$summaryHash{total}{response} += $summaryHash{$node}{response};
				} else { $summaryHash{$node}{response} = "NaN" }

				
				if ( $summaryHash{total}{reachable} > 0 ) {
					$summaryHash{average}{reachable} = sprintf("%.3f",$summaryHash{total}{reachable} / $nodecount{reachable} );
				}
				if ( $summaryHash{total}{available} > 0 ) {
					$summaryHash{average}{available} = sprintf("%.3f",$summaryHash{total}{available} / $nodecount{available} );
				}
				if ( $summaryHash{total}{health} > 0 ) {
					$summaryHash{average}{health} = sprintf("%.3f",$summaryHash{total}{health} / $nodecount{health} );
				}
				if ( $summaryHash{total}{response} > 0 ) {
					$summaryHash{average}{response} = sprintf("%.0f",$summaryHash{total}{response} / $nodecount{response} );
				}
	
				if ( $summaryHash{total}{reachable} > 0 and $summaryHash{total}{available} > 0 and $summaryHash{total}{health} > 0 ) {
					# new weighting for metric
					$summaryHash{average}{metric} = sprintf("%.3f",( 
						( $summaryHash{average}{reachable} * $NMIS::config{metric_reachability} ) +
						( $summaryHash{average}{available} * $NMIS::config{metric_availability} ) +
						( $summaryHash{average}{health} ) * $NMIS::config{metric_health} )
					);
				}
				# small sanity check
				if ( $nodecount{total} >= $nodecount{down} ) {
					$summaryHash{average}{count} = $nodecount{total} - $nodecount{down};
				}
				else {
					$summaryHash{average}{count} = 0;
				}
				$summaryHash{average}{countdown} = $nodecount{down};
			} else {
				$summaryHash{$node}{event_status} = "N/A";
				$summaryHash{$node}{reachable} = "N/A";
				$summaryHash{$node}{available} = "N/A";
				$summaryHash{$node}{health} = "N/A";				
				$summaryHash{$node}{response} = "N/A";
				$summaryHash{$node}{event_color} = "#aaaaaa";
				$summaryHash{$node}{reachable_color} = "#aaaaaa";
				$summaryHash{$node}{available_color} = "#aaaaaa";
				$summaryHash{$node}{health_color} = "#aaaaaa";				
				$summaryHash{$node}{response_color} = "#aaaaaa";
			}
		}
	}

	# Now the summaryHash is full, calc some colors and check for empty results.
	if ( $summaryHash{average}{reachable} ne "" ) {
		$summaryHash{average}{reachable_color} = colorHighGood($summaryHash{average}{reachable})
	} 
	else { 
		$summaryHash{average}{reachable_color} = "#aaaaaa";
		$summaryHash{average}{reachable} = "N/A";
	}

	if ( $summaryHash{average}{available} ne "" ) {
		$summaryHash{average}{available_color} = colorHighGood($summaryHash{average}{available});
	}
	else { 
		$summaryHash{average}{available_color} = "#aaaaaa";
		$summaryHash{average}{available} = "N/A";
	}

	if ( $summaryHash{average}{health} ne "" ) {
		$summaryHash{average}{health_color} = colorHighGood($summaryHash{average}{health});
	}
	else { 
		$summaryHash{average}{health_color} = "#aaaaaa";
		$summaryHash{average}{health} = "N/A";
	}

	if ( $summaryHash{average}{response} ne "" ) {
		$summaryHash{average}{response_color} = colorResponseTime($summaryHash{average}{response})
	}
	else { 
		$summaryHash{average}{response_color} = "#aaaaaa";
		$summaryHash{average}{response} = "N/A";
	}

	if ( $summaryHash{average}{metric} ne "" ) {
		$summaryHash{average}{metric_color} = colorHighGood($summaryHash{average}{metric})
	}
	else { 
		$summaryHash{average}{metric_color} = "#aaaaaa";
		$summaryHash{average}{metric} = "N/A";
	}

	return %summaryHash;
} # end getGroupSummary

sub colorHighGood {
	my $threshold = shift;
	my $color = "";

	if ( ( $threshold =~ /^[a-zA-Z]/ ) || ( $threshold eq "") )  { $color = "#FFFFFF"; }
	elsif ( $threshold eq "N/A" )  { $color = "#FFFFFF"; }
	elsif ( $threshold >= 100 ) { $color = "#00FF00"; }
	elsif ( $threshold >= 95 ) { $color = "#00EE00"; }
	elsif ( $threshold >= 90 ) { $color = "#00DD00"; }
	elsif ( $threshold >= 85 ) { $color = "#00CC00"; }
	elsif ( $threshold >= 80 ) { $color = "#00BB00"; }
	elsif ( $threshold >= 75 ) { $color = "#00AA00"; }
	elsif ( $threshold >= 70 ) { $color = "#009900"; }
	elsif ( $threshold >= 65 ) { $color = "#008800"; }
	elsif ( $threshold >= 60 ) { $color = "#FFFF00"; }
	elsif ( $threshold >= 55 ) { $color = "#FFEE00"; }
	elsif ( $threshold >= 50 ) { $color = "#FFDD00"; }
	elsif ( $threshold >= 45 ) { $color = "#FFCC00"; }
	elsif ( $threshold >= 40 ) { $color = "#FFBB00"; }
	elsif ( $threshold >= 35 ) { $color = "#FFAA00"; }
	elsif ( $threshold >= 30 ) { $color = "#FF9900"; }
	elsif ( $threshold >= 25 ) { $color = "#FF8800"; }
	elsif ( $threshold >= 20 ) { $color = "#FF7700"; }
	elsif ( $threshold >= 15 ) { $color = "#FF6600"; }
	elsif ( $threshold >= 10 ) { $color = "#FF5500"; }
	elsif ( $threshold >= 5 )  { $color = "#FF3300"; }
	elsif ( $threshold > 0 )   { $color = "#FF1100"; }
	elsif ( $threshold == 0 )  { $color = "#FF0000"; }
	elsif ( $threshold == 0 )  { $color = "#FF0000"; }

	return $color;
}

sub colorPort {
	my $threshold = shift;
	my $color = "";

	if ( $threshold >= 60 ) { $color = "#FFFF00"; }
	elsif ( $threshold < 60 ) { $color = "#00FF00"; }

	return $color;
}

sub colorLowGood {
	my $threshold = shift;
	my $color = "";

	if ( ( $threshold =~ /^[a-zA-Z]/ ) || ( $threshold eq "") )  { $color = "#FFFFFF"; }
	elsif ( $threshold == 0 ) { $color = "#00FF00"; }
	elsif ( $threshold <= 5 ) { $color = "#00EE00"; }
	elsif ( $threshold <= 10 ) { $color = "#00DD00"; }
	elsif ( $threshold <= 15 ) { $color = "#00CC00"; }
	elsif ( $threshold <= 20 ) { $color = "#00BB00"; }
	elsif ( $threshold <= 25 ) { $color = "#00AA00"; }
	elsif ( $threshold <= 30 ) { $color = "#009900"; }
	elsif ( $threshold <= 35 ) { $color = "#008800"; }
	elsif ( $threshold <= 40 ) { $color = "#FFFF00"; }
	elsif ( $threshold <= 45 ) { $color = "#FFEE00"; }
	elsif ( $threshold <= 50 ) { $color = "#FFDD00"; }
	elsif ( $threshold <= 55 ) { $color = "#FFCC00"; }
	elsif ( $threshold <= 60 ) { $color = "#FFBB00"; }
	elsif ( $threshold <= 65 ) { $color = "#FFAA00"; }
	elsif ( $threshold <= 70 ) { $color = "#FF9900"; }
	elsif ( $threshold <= 75 ) { $color = "#FF8800"; }
	elsif ( $threshold <= 80 ) { $color = "#FF7700"; }
	elsif ( $threshold <= 85 ) { $color = "#FF6600"; }
	elsif ( $threshold <= 90 ) { $color = "#FF5500"; }
	elsif ( $threshold <= 95 ) { $color = "#FF4400"; }
	elsif ( $threshold < 100 ) { $color = "#FF3300"; }
	elsif ( $threshold == 100 )  { $color = "#FF1100"; }
	elsif ( $threshold <= 110 )  { $color = "#FF0055"; }
	elsif ( $threshold <= 120 )  { $color = "#FF0066"; }
	elsif ( $threshold <= 130 )  { $color = "#FF0077"; }
	elsif ( $threshold <= 140 )  { $color = "#FF0088"; }
	elsif ( $threshold <= 150 )  { $color = "#FF0099"; }
	elsif ( $threshold <= 160 )  { $color = "#FF00AA"; }
	elsif ( $threshold <= 170 )  { $color = "#FF00BB"; }
	elsif ( $threshold <= 180 )  { $color = "#FF00CC"; }
	elsif ( $threshold <= 190 )  { $color = "#FF00DD"; }
	elsif ( $threshold <= 200 )  { $color = "#FF00EE"; }
	elsif ( $threshold > 200 )  { $color = "#FF00FF"; }

	return $color;
}

sub colorResponseTime {
	my $threshold = shift;
	my $color = "";

	if ( ( $threshold =~ /^[a-zA-Z]/ ) || ( $threshold eq "") )  { $color = "#FFFFFF"; }
	elsif ( $threshold <= 1 ) { $color = "#00FF00"; }
	elsif ( $threshold <= 20 ) { $color = "#00EE00"; }
	elsif ( $threshold <= 50 ) { $color = "#00DD00"; }
	elsif ( $threshold <= 100 ) { $color = "#00CC00"; }
	elsif ( $threshold <= 200 ) { $color = "#00BB00"; }
	elsif ( $threshold <= 250 ) { $color = "#00AA00"; }
	elsif ( $threshold <= 300 ) { $color = "#009900"; }
	elsif ( $threshold <= 350 ) { $color = "#FFFF00"; }
	elsif ( $threshold <= 400 ) { $color = "#FFEE00"; }
	elsif ( $threshold <= 450 ) { $color = "#FFDD00"; }
	elsif ( $threshold <= 500 ) { $color = "#FFCC00"; }
	elsif ( $threshold <= 550 ) { $color = "#FFBB00"; }
	elsif ( $threshold <= 600 ) { $color = "#FFAA00"; }
	elsif ( $threshold <= 650 ) { $color = "#FF9900"; }
	elsif ( $threshold <= 700 ) { $color = "#FF8800"; }
	elsif ( $threshold <= 750 ) { $color = "#FF7700"; }
	elsif ( $threshold <= 800 ) { $color = "#FF6600"; }
	elsif ( $threshold <= 850 ) { $color = "#FF5500"; }
	elsif ( $threshold <= 900 ) { $color = "#FF4400"; }
	elsif ( $threshold <= 950 )  { $color = "#FF3300"; }
	elsif ( $threshold < 1000 )   { $color = "#FF1100"; }
	elsif ( $threshold > 1000 )  { $color = "#FF0000"; }

	return $color;
}

### AS 1 April 02 - Threshold Policy!  Yah!
# logic is load csv with key eq "threshold, type, role, node, interface"
# Check a thresh entry against the specific, the node, then default for everything
# check each minor, major and critical against the reported level, 
# if less then minor cool
# if gt minor and lt major = Minor, etc.
# Thresholds can be as specific or as general as you like!
### AS 7 July 02 - Fixed policy order so most specific matches first.
sub thresholdPolicy {
	my %args = @_;
	my $thresholds = $args{thresholds};
	my $level;
	my %keys;
	my $policy = 0;
	if ($NMIS::debug) { print returnTime." thresholdPolicy threshold=$args{threshold} role=$args{role} type=$args{type} node=$args{node} interface=$args{interface} value=$args{value}\n"; }

	# Load a set of keys which define the possible matches to the policy
	# in order of processing for speeding up BIG policies.  hmmmm, little faster but not much
	# Processing 10 nodes in 1.2 seconds so pretty fast I guess.
	#! need to lowercase all here to get a match as the loadCSV that reads the threshold file defaults to lc !!!!

	$keys{1} = lc($args{threshold} ."_". $args{role} ."_". $args{type} ."_". $args{node} ."_". $args{interface});
	$keys{2} = lc($args{threshold} ."_". $args{role} ."_". $args{type} ."_". $args{node} ."_default");
	$keys{4} = lc($args{threshold} ."_". $args{role} ."_". $args{type} ."_default_default");
	$keys{5} = lc($args{threshold} ."_". $args{role} ."_default_default_default");
	$keys{3} = lc($args{threshold} ."_default_". $args{type} ."_default_default");
	$keys{6} = lc($args{threshold} ."_default_default_default_default");

	# Walk the possible keys looking for a threshold policy which matches.
	### ehg 13 sep 02 added 'do nothing' policy - set policy to all zeros to disable thresholding for a class of device.
	foreach my $t (sort { $a <=> $b } keys %keys) {
		if ($NMIS::debug>2) { print "    Threshold key $keys{$t} threshold=$thresholds->{$keys{$t}}{threshold} minor=$thresholds->{$keys{$t}}{minor} major=$thresholds->{$keys{$t}}{major} critical=$thresholds->{$keys{$t}}{critical}\n"; }
		# Thresholds for higher being good and lower being bad
		if ( $policy ) {
			# do nothing but make BIG policies run faster but not doing all these other if's
		}
			### all zeros policy to disable threholding - match and return 'normal'
		elsif ( $thresholds->{$keys{$t}}{warning} == 0
			and $thresholds->{$keys{$t}}{minor} == 0
			and $thresholds->{$keys{$t}}{major} == 0
			and $thresholds->{$keys{$t}}{critical} == 0
			and $thresholds->{$keys{$t}}{fatal} == 0
			and defined $thresholds->{$keys{$t}}{warning}
			and defined $thresholds->{$keys{$t}}{minor} 
			and defined $thresholds->{$keys{$t}}{major} 
			and defined $thresholds->{$keys{$t}}{critical}
			and defined $thresholds->{$keys{$t}}{fatal}
		) {
			$policy = 1;
			if ($NMIS::debug) { print "    Matched threshold key $keys{$t} threshold=$thresholds->{$keys{$t}}{threshold} minor=$thresholds->{$keys{$t}}{minor} major=$thresholds->{$keys{$t}}{major} critical=$thresholds->{$keys{$t}}{critical}\n"; }
			$level = "Normal";
		}
		elsif ( $thresholds->{$keys{$t}}{warning} > $thresholds->{$keys{$t}}{fatal}
			and defined $thresholds->{$keys{$t}}{warning}
			and defined $thresholds->{$keys{$t}}{minor} 
			and defined $thresholds->{$keys{$t}}{major} 
			and defined $thresholds->{$keys{$t}}{critical}
			and defined $thresholds->{$keys{$t}}{fatal}
		) {
			$policy = 1;
			if ($NMIS::debug) { print "    Matched threshold key $keys{$t} threshold=$thresholds->{$keys{$t}}{threshold} minor=$thresholds->{$keys{$t}}{minor} major=$thresholds->{$keys{$t}}{major} critical=$thresholds->{$keys{$t}}{critical}\n"; }
			if ( $args{value} <= $thresholds->{$keys{$t}}{fatal} 
			) { $level = "Fatal"; }
			elsif ( $args{value} <= $thresholds->{$keys{$t}}{critical} 
				and $args{value} > $thresholds->{$keys{$t}}{fatal} 
			) { $level = "Critical"; }
			elsif ( $args{value} <= $thresholds->{$keys{$t}}{major} 
				and $args{value} > $thresholds->{$keys{$t}}{critical} 
			) { $level = "Major"; }
			elsif ( $args{value} <= $thresholds->{$keys{$t}}{minor} 
				and $args{value} > $thresholds->{$keys{$t}}{major} 
			) { $level = "Minor"; }
			elsif ( $args{value} <= $thresholds->{$keys{$t}}{warning} 
				and $args{value} > $thresholds->{$keys{$t}}{minor} 
			) { $level = "Warning"; }
			elsif ( $args{value} > $thresholds->{$keys{$t}}{warning} ) 
			{ $level = "Normal"; }
		}
		# Thresholds for lower being good and higher being bad
		elsif ( $thresholds->{$keys{$t}}{warning} < $thresholds->{$keys{$t}}{fatal}
			and defined $thresholds->{$keys{$t}}{warning} 
			and defined $thresholds->{$keys{$t}}{minor} 
			and defined $thresholds->{$keys{$t}}{major} 
			and defined $thresholds->{$keys{$t}}{critical}
			and defined $thresholds->{$keys{$t}}{fatal}
		) {
			$policy = 1;
			if ($NMIS::debug) { print "    Matched threshold key $keys{$t} threshold=$thresholds->{$keys{$t}}{threshold} minor=$thresholds->{$keys{$t}}{minor} major=$thresholds->{$keys{$t}}{major} critical=$thresholds->{$keys{$t}}{critical}\n"; }
			if ( $args{value} < $thresholds->{$keys{$t}}{warning} 
			) { $level = "Normal"; }
			elsif ( $args{value} >= $thresholds->{$keys{$t}}{warning} 
				and $args{value} < $thresholds->{$keys{$t}}{minor} 
			) { $level = "Warning"; }
			elsif ( $args{value} >= $thresholds->{$keys{$t}}{minor} 
				and $args{value} < $thresholds->{$keys{$t}}{major} 
			) { $level = "Minor"; }
			elsif ( $args{value} >= $thresholds->{$keys{$t}}{major} 
				and $args{value} < $thresholds->{$keys{$t}}{critical} 
			) { $level = "Major"; }
			elsif ( $args{value} >= $thresholds->{$keys{$t}}{critical} 
				and $args{value} < $thresholds->{$keys{$t}}{fatal} 
			) { $level = "Critical"; }
			elsif ( $args{value} >= $thresholds->{$keys{$t}}{fatal} ) 
			{ $level = "Fatal"; }
		} 
	}
	if ( ! defined $level ) { $level = "ERROR" }
	if ( ! $policy) { 
		logMessage("thresholdPolicy, $args{node}, Error with thresholds no policy found. threshold=$args{threshold} type=$args{type} role=$args{role}");	
		if ($NMIS::debug) { print "    ERROR with thresholds no policy found. node=$args{node} threshold=$args{threshold} type=$args{type} role=$args{role}\n"; }
	}
	return $level;
} # thresholdPolicy

# this sets the colour in the dashboards - afaik today.

sub eventLevel {
	my $event = shift;
	my $role = shift;

	my $event_level;
	my $event_color;

	if ( $event eq 'Node Down' ) {
	 	if ( $role eq "core" ) { $event_level = "Critical"; }
	 	elsif ( $role eq "distribution" ) { $event_level = "Major"; }
	 	elsif ( $role eq "access" ) { $event_level = "Minor"; }
	}
	elsif ( $event =~ /up/i ) {
		$event_level = "Normal";
	}
	# colour all other events the same, based on role, to get some consistency across the network
	else {
	 	if ( $role eq "core" ) { $event_level = "Major"; }
	 	elsif ( $role eq "distribution" ) { $event_level = "Minor"; }
	 	elsif ( $role eq "access" ) { $event_level = "Warning";	}
	}
	$event_color = eventColor($event_level);
	return ($event_level,$event_color);
} # eventLevel

# clean all events for a node - used if editing or deleting nodes via view.pl
sub cleanEvent {

	my $node=shift;
	my $caller=shift;

	my $handle = &loadEventStateLock;

	foreach my $event_hash ( sort keys %NMIS::eventTable )  {
	if ( $NMIS::eventTable{$event_hash}{node} eq "$node" ) {
		&logEvent("$NMIS::eventTable{$event_hash}{node}", "$caller, deleted event: $NMIS::eventTable{$event_hash}{event}", "Normal", "$NMIS::eventTable{$event_hash}{details}");
		delete $NMIS::eventTable{$event_hash};
		}
	}
	writeEventStateLock($handle);
}


sub overallNodeStatus {
	my $netType = shift;
	my $roleType = shift;
	
	my $node;
	my $event_status;
	my $overall_status;
	my $status_number;
	my $total_status;
	my $multiplier;
	my $group;
	my $status;

	my %statusHash;

	#print STDERR &returnDateStamp." overallNodeStatus: netType=$netType roleType=$roleType\n";
	#&loadEventStateNoLock;				# surplus call
	#loadEventStateSlave;				# surplus call

	if ( $netType eq "" and $roleType eq "" ) {
		foreach $node (sort ( keys (%NMIS::nodeTable) ) ) {
			if ( &eventExist($node,"Node Down","Ping failed") eq "true" ) {
				($event_status) = &eventLevel("Node Down",$NMIS::nodeTable{$node}{role});
			}
			else {
				($event_status) = &eventLevel("Node Up",$NMIS::nodeTable{$node}{role});
			}
			++$statusHash{$event_status};
			++$statusHash{count};
		}	
	}
	elsif ( $netType ne "" and $roleType ne "" ) {
	        foreach $node (sort ( keys (%NMIS::nodeTable) ) ) {
			if (	( $NMIS::nodeTable{$node}{net} eq "$netType" &&
				$NMIS::nodeTable{$node}{role} eq "$roleType" )
				
			) {
				if ( &eventExist($node,"Node Down","Ping failed") eq "true" ) {
					($event_status) = &eventLevel("Node Down",$NMIS::nodeTable{$node}{role});
				}
				else {
					($event_status) = &eventLevel("Node Up",$NMIS::nodeTable{$node}{role});
				}
				++$statusHash{$event_status};
				++$statusHash{count};
			}
	        }
	}
	elsif ( $netType ne "" and $roleType eq "" ) {
		$group = $netType;
		foreach $node (sort ( keys (%NMIS::nodeTable) ) ) {
			if ( $NMIS::nodeTable{$node}{group} eq $group ) {
				if ( &eventExist($node,"Node Down","Ping failed") eq "true" ) {
					($event_status) = &eventLevel("Node Down",$NMIS::nodeTable{$node}{role});
				}
				else {
					($event_status) = &eventLevel("Node Up",$NMIS::nodeTable{$node}{role});
				}
				++$statusHash{$event_status};
				++$statusHash{count};
				#print STDERR &returnDateStamp." overallNodeStatus: $node $group $event_status event=$statusHash{$event_status} count=$statusHash{count}\n";
			}
		}
	}

	$status_number = 100 * $statusHash{Normal};
	$status_number = $status_number + ( 90 * $statusHash{Warning} );
	$status_number = $status_number + ( 75 * $statusHash{Minor} );
	$status_number = $status_number + ( 60 * $statusHash{Major} );
	$status_number = $status_number + ( 50 * $statusHash{Critical} );
	$status_number = $status_number + ( 40 * $statusHash{Fatal} );
	if ( $status_number != 0 and $statusHash{count} != 0 ) {
		$status_number = $status_number / $statusHash{count};
	}
	#print STDERR "New CALC: status_number=$status_number count=$statusHash{count}\n";

	### AS 11/4/01 - Fixed up status for single node groups.
	# if the node count is one we do not require weighting.
	if ( $statusHash{count} == 1 ) {
		delete ($statusHash{count});
		foreach $status (keys %statusHash) {
			if ( $statusHash{$status} ne "" and $statusHash{$status} ne "count" ) {
				$overall_status = $status;
				#print STDERR returnDateStamp." overallNodeStatus netType=$netType status=$status hash=$statusHash{$status}\n";
			}
		}
	}
	elsif ( $status_number != 0  ) {
		if ( $status_number == 100 ) { $overall_status = "Normal"; }
		elsif ( $status_number >= 95 ) { $overall_status = "Warning"; }
		elsif ( $status_number >= 90 ) { $overall_status = "Minor"; }
		elsif ( $status_number >= 70 ) { $overall_status = "Major"; }
		elsif ( $status_number >= 50 ) { $overall_status = "Critical"; }
		elsif ( $status_number <= 40 ) { $overall_status = "Fatal"; }
		elsif ( $status_number >= 30 ) { $overall_status = "Disaster"; }
		elsif ( $status_number < 30 ) { $overall_status = "Catastrophic"; }
	}
	else {
		$overall_status = "Unknown";
	}

	return $overall_status;
} # end overallNodeStatus

### AS 8 June 2002 - Converts status level to a number for metrics
sub statusNumber {
	my $status = shift;
	my $level;
	if ( $status eq "Normal" ) { $level = 100 }
	elsif ( $status eq "Warning" ) { $level = 95 }
	elsif ( $status eq "Minor" ) { $level = 90 }
	elsif ( $status eq "Major" ) { $level = 80 }
	elsif ( $status eq "Critical" ) { $level = 60 }
	elsif ( $status eq "Fatal" ) { $level = 40 }
	elsif ( $status eq "Disaster" ) { $level = 20 }
	elsif ( $status eq "Catastrophic" ) { $level = 0 }
	elsif ( $status eq "Unknown" ) { $level = "U" }
	return $level;
}

# 24 Feb 2002 - A suggestion from someone? to remove \n from $string.
# this also prints the message if debug, remove concurrent debug prints in code...

sub logMessage {
	my $string = shift;
	$string =~ s/\n+/ /g;      #remove all embedded newlines
	sysopen(DATAFILE, "$NMIS::config{nmis_log}", O_WRONLY | O_APPEND | O_CREAT)
		 or warn returnTime." logMessage, Couldn't open log file $NMIS::config{nmis_log}. $!\n";
	flock(DATAFILE, LOCK_EX) or warn "logMessage, can't lock filename: $!";
	print DATAFILE &returnDateStamp.",$string\n";
	close(DATAFILE) or warn "logMessage, can't close filename: $!";
	if ( $NMIS::debug ) { print "\t $string\n" }		# all messages to debug console as well.
} # end logMessage

sub createInterfaceInfo {
	my $node;
	my $index;
	my $tmpDesc;
	my $intHash;
	my %interfaceInfo;
	my %interfaceTable;
	
	&loadNodeDetails;

	if ($NMIS::debug) { print returnTime." Getting Interface Info from all nodes.\n"; }

	# Write a node entry for each node
	foreach $node (sort( keys(%NMIS::nodeTable) ) )  {

		if ( $NMIS::nodeTable{$node}{collect} eq "true" 
			and $NMIS::nodeTable{$node}{active} ne "false" 
		) {
			if ($NMIS::debug>7) { print "\tgetting $node interface information\n"; }
			loadSystemFile($node);
			if ( -f "$NMIS::config{'<nmis_var>'}/$node-interface.dat" ) {
				%interfaceTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-interface.dat","ifIndex","\t");
				foreach my $intf (keys %interfaceTable) {
		
					$tmpDesc = &convertIfName($interfaceTable{$intf}{ifDescr});
		
					$intHash = "$node-$tmpDesc";
					
					if ($NMIS::debug==9) { print "\t\t$node $tmpDesc hash=$intHash $interfaceTable{$intf}{ifDescr}\n"; }
		
					if ( $interfaceTable{$intf}{ifDescr} ne "" ) { 
			  			$interfaceInfo{$intHash}{node} = $node;
			  			$interfaceInfo{$intHash}{sysName} = $NMIS::systemTable{sysName};
			  			$interfaceInfo{$intHash}{ifIndex} = $interfaceTable{$intf}{ifIndex};
						$interfaceInfo{$intHash}{ifDescr} = $interfaceTable{$intf}{ifDescr};
						$interfaceInfo{$intHash}{collect} = $interfaceTable{$intf}{collect};
						$interfaceInfo{$intHash}{ifType} = $interfaceTable{$intf}{ifType};
						$interfaceInfo{$intHash}{ifSpeed} = $interfaceTable{$intf}{ifSpeed};
						$interfaceInfo{$intHash}{ifAdminStatus} = $interfaceTable{$intf}{ifAdminStatus};
						$interfaceInfo{$intHash}{ifOperStatus} = $interfaceTable{$intf}{ifOperStatus};
						$interfaceInfo{$intHash}{ifLastChange} = $interfaceTable{$intf}{ifLastChange};
						$interfaceInfo{$intHash}{Description} = $interfaceTable{$intf}{Description};
						$interfaceInfo{$intHash}{portModuleIndex} = $interfaceTable{$intf}{portModuleIndex};
						$interfaceInfo{$intHash}{portIndex} = $interfaceTable{$intf}{portIndex};
						$interfaceInfo{$intHash}{portDuplex} = $interfaceTable{$intf}{portDuplex};
						$interfaceInfo{$intHash}{portIfIndex} = $interfaceTable{$intf}{portIfIndex};
						$interfaceInfo{$intHash}{portSpantreeFastStart} = $interfaceTable{$intf}{portSpantreeFastStart};
						$interfaceInfo{$intHash}{vlanPortVlan} = $interfaceTable{$intf}{vlanPortVlan};
						$interfaceInfo{$intHash}{portAdminSpeed} = $interfaceTable{$intf}{portAdminSpeed};
						$interfaceInfo{$intHash}{ipAdEntAddr} = $interfaceTable{$intf}{ipAdEntAddr};
						$interfaceInfo{$intHash}{ipAdEntNetMask} = $interfaceTable{$intf}{ipAdEntNetMask};
						$interfaceInfo{$intHash}{ipSubnet} = $interfaceTable{$intf}{ipSubnet};
						$interfaceInfo{$intHash}{ipSubnetBits} = $interfaceTable{$intf}{ipSubnetBits};
					}
				}
			}
		}
	} # foreach $linkname
	# Write the interface table out.
	if ($NMIS::debug) { print returnTime." Writing Interface Info from all nodes.\n"; }
	&writeCSV(%interfaceInfo,$NMIS::config{Interface_Table},"\t");
}

sub loadInterfaceInfo {

	%NMIS::interfaceInfo = &loadCSV($NMIS::config{Interface_Table},$NMIS::config{Interface_Key},"\t");

}

sub outageAdd {
	# Outage add inserts an entry into the outage table 
	# Start must be before "now" and Change Number must equal to something.

	my $node = shift;
	my $start = shift;
	my $end = shift;
	my $change = shift;
	my $error = "false";

	# Convert nasty adhoc date entry into seconds
	$start = parsedate("$start");
	$end = parsedate("$end");

	# Now - 5 minutes
	if ( $start < time - (60 * 5) ) {
		$error = "Cannot add Planned Outage with time less than \"now\" ".&returnDateStamp.".";
	}
	if ( $start >= $end ) {
		$error = "Cannot add start time less then or equal to end time.";
	}
	if ( $change eq "" ) {
		$error = "Change number must be included with changes.";
	}
	if ( $node eq "" ) {
		$error = "Node name must be provided.";
	}

	if ( $error eq "false" ) {
		sysopen(DATAFILE, "$NMIS::config{outage_file}", O_WRONLY | O_APPEND | O_CREAT) 
			or warn returnTime." outageAdd, Couldn't open interface file $NMIS::config{outage_file}. $!\n";
		flock(DATAFILE, LOCK_EX) or warn "outageAdd, can't lock filename: $!";
		print DATAFILE "$node,";
		print DATAFILE "$start,";
		print DATAFILE "$end,";
		print DATAFILE "$change";
		print DATAFILE "\n";
		close(DATAFILE) or warn "outageAdd, can't close filename: $!";
	}
	return $error;
}

sub outageDelete {

	my $node = shift;
	my $start = shift;
	my $end = shift;
	my $change = shift;

	my $outage;
	my $outageHash;

	&outageLoad;
	$outageHash = "$node-$start-$end-$change";

	# change to secure sysopen with truncate after the lock
	sysopen(DATAFILE, "$NMIS::config{outage_file}", O_WRONLY | O_CREAT)
		 or warn returnTime." outageDelete, Couldn't open Outage file $NMIS::config{outage_file}. $!\n";
	flock(DATAFILE, LOCK_EX) or warn "outageDelete, can't lock filename: $!";
	truncate(DATAFILE, 0) or warn "outageDelete, can't truncate filename: $!";

	foreach $outage (keys(%NMIS::outageTable)) {
		# if is doesn't match write to the file
		if ( $outage ne $outageHash and $NMIS::outageTable{$outage}{node} ne "" ) {
			print DATAFILE "$NMIS::outageTable{$outage}{node},";
			print DATAFILE "$NMIS::outageTable{$outage}{start},";
			print DATAFILE "$NMIS::outageTable{$outage}{end},";
			print DATAFILE "$NMIS::outageTable{$outage}{change}";
			print DATAFILE "\n";
		}
		# it matches so zero the hash for that value
		else {
		 	#$NMIS::outageTable{$outage} = "";
		 	$NMIS::outageTable{$outage}{node} = "";
		}
	}
	close (DATAFILE) or warn "outageDelete, can't close filename: $!";
}

sub outageLoad {
	
	my $outage;
  	my @entry;

	sysopen(DATAFILE, "$NMIS::config{outage_file}", O_RDONLY)
		 or warn returnTime." outageLoad, Cannot open Outage file $NMIS::config{outage_file}. $!\n";
	flock(DATAFILE, LOCK_SH) or warn "outageLoad, can't lock filename: $!";
	while (<DATAFILE>) {
	chomp;
	# Does the line from configfile have a comment?
		if ( $_ !~ /^#|^;/) {
			@entry = split(",", $_);
			
			$outage = "$entry[0]-$entry[1]-$entry[2]-$entry[3]";
			
			$NMIS::outageTable{$outage}{node} = $entry[0];
			$NMIS::outageTable{$outage}{start} = $entry[1];
			$NMIS::outageTable{$outage}{end} = $entry[2];
			$NMIS::outageTable{$outage}{change} = $entry[3];
		}
	}
	close(DATAFILE) or warn "outageLoad, can't close filename: $!";
}

sub outageCheck {
	my $node = shift;
	my $time = shift;

	my $outageCurrent = "false";
	my $outage;

	&outageLoad;

	# Get each of the nodes info in a HASH for playing with
       	foreach $outage (keys(%NMIS::outageTable)) {
		if ( 	$node eq $NMIS::outageTable{$outage}{node} and 
			$time >= $NMIS::outageTable{$outage}{start} and 
			$time <= $NMIS::outageTable{$outage}{end} and
			# Seems blanks match scheduled outage stuff lets make sure they aren't blank too.
			$NMIS::outageTable{$outage}{start} > 9000 and 
			$NMIS::outageTable{$outage}{end} > 9000 
		) {
			$outageCurrent = "true";
		}
		elsif ( $node eq $NMIS::outageTable{$outage}{node} and 
			$time < $NMIS::outageTable{$outage}{start} 
		) {
			$outageCurrent = "pending";
		}
		elsif ( $node eq $NMIS::outageTable{$outage}{node} and 
			$time > $NMIS::outageTable{$outage}{end} 
		) {
			$outageCurrent = "closed";
		}
	}

	return "$outageCurrent";
}

sub outageCheckHash {
	# This function returns the hash key of an outage if an outage exists for it.
	my $node = shift;
	my $time = shift;

	my $outageCurrent = "false";
	my $outage;

	&outageLoad;

	# Get each of the nodes info in a HASH for playing with
       	foreach $outage (keys(%NMIS::outageTable)) {
		if ( 	$node eq $NMIS::outageTable{$outage}{node} and 
			$time >= $NMIS::outageTable{$outage}{start} and 
			$time <= $NMIS::outageTable{$outage}{end} 
		) {
			$outageCurrent = $outage;
		}
	}

	return "$outageCurrent";
}

### HIGHLY EXPERIMENTAL!
sub sendTrap {
	my %arg = @_;
	use SNMP_util;
	my @servers = split(",",$arg{server});
	foreach my $server (@servers) {
		print "Sending trap to $server\n";
		#my($host, $ent, $agent, $gen, $spec, @vars) = @_;
		snmptrap(
			$server, 
			".1.3.6.1.4.1.4818", 
			"127.0.0.1", 
			6, 
			1000, 
	        ".1.3.6.1.4.1.4818.1.1000", 
	        "int",
	        "2448816"
	    );
    }
}
### setup for V4 XML template
### returns the rrdfilename
sub getRRDFileName {
	my %arg = @_;

	my $extName = &convertIfName($arg{extName});
	my $item = &convertIfName($arg{item});

	my %rrdfile = (	'interface' => 	"/interface/$arg{nodeType}/$arg{node}/$arg{node}-$extName.rrd",
					'pvc' => "/interface/$arg{nodeType}/$arg{node}/$arg{node}-pvc-$arg{extName}.rrd",
					'calls' => "/interface/$arg{nodeType}/$arg{node}/$arg{node}-$extName-calls.rrd",
					'pkts' => "/interface/$arg{nodeType}/$arg{node}/$arg{node}-$extName-pkts.rrd",
					'metrics' => "/metrics/$arg{group}.rrd",
					'health' => "/health/$arg{nodeType}/$arg{node}-health.rrd",
					'mib2ip' => "/health/$arg{nodeType}/$arg{node}-mib2ip.rrd",
					'reach' => "/health/$arg{nodeType}/$arg{node}-reach.rrd",
					'modem' => "/health/$arg{nodeType}/$arg{node}-modem.rrd",
					'hr' => "/health/$arg{nodeType}/$arg{node}-hr.rrd",
					'hrwin' => "/health/$arg{nodeType}/$arg{node}-hrwin.rrd",
					'cbqos' => "/interface/$arg{nodeType}/$arg{node}/$arg{node}-$extName-$item.rrd",
					'cbqos-in' => "/interface/$arg{nodeType}/$arg{node}/$arg{node}-$extName-in-$item.rrd",
					'cbqos-out' => "/interface/$arg{nodeType}/$arg{node}/$arg{node}-$extName-$item.rrd",
					'nmis' => "/metrics/nmis-system.rrd"
				);

###	'service' => "/health/$arg{nodeType}/$arg{node}-$item.rrd" ##$item not used here yet

	my $type = &getGraphType($arg{type});

	if ( !exists $rrdfile{$type} ) {
		# just return the root and the passed in extension, as 'serverRun' may call lots of rrd for disk1, disk2 etc.
		# also for runservices - one rrd for each service application port polled.
		return "$NMIS::config{database_root}/health/$arg{nodeType}/$arg{node}-$extName.rrd";
	}
	else {
		return $NMIS::config{database_root}.$rrdfile{$type};
	}	
}

### setup for V4 XML template
### returns the base collect type for each graphtype
sub getGraphType {

	$_ = shift;

	my %type = ( 	'interface' => 'interface',
					'util' => 'interface',
					'autil' => 'interface',
					'abits' => 'interface',
					'mbits' => 'interface',
					'bits' => 'interface',

					'pkts' =>	'pkts',
					'epkts' =>	'pkts',
					'packets' => 'pkts',

					'cbqos' => 'cbqos',
					'cbqos-in' => 'cbqos-in',
					'cbqos-out' => 'cbqos-out',

					'mib2ip' => 'mib2ip',
					'ip' => 'mib2ip',
					'frag' => 'mib2ip',

					'metrics' => 'metrics',

					'nodehealth' => 'health',
					'cpu' => 'health',
					'acpu' => 'health',
					'mem-proc' => 'health',
					'mem-io' => 'health',
					'mem-dram' => 'health',
					'mem-mbuf' => 'health',
					'mem-cluster' => 'health',
					'mem-switch' => 'health',
					'mem-router' => 'health',
					'traffic' => 'health',
					'topo' => 'health',
					'buffer' => 'health',
					'pix-conn' => 'health',
					'a3bandwidth' => 'health',
					'a3traffic' => 'health',
					'a3errors' => 'health',
					'degree' => 'health',

					'modem' => 'modem',

					'nmis' => 'nmis',

					'reach' => 'reach',
					'health' => 'reach',
					'response' => 'reach',

					'pvc' => 'pvc',		
					'calls' => 'calls',		

					'hrwin' => 'hrwin',
					'hrwinproc' => 'hrwin',
					'hrwinusers' => 'hrwin',
					'hrwincpu' => 'hrwin',
					'hrwincpuint' => 'hrwin',
					'hrwinmem' => 'hrwin',
					'hrwinpps' => 'hrwin',

					'hr' => 'hr',
					'hrproc' => 'hr',
					'hrusers' => 'hr',
					'hrcpu' => 'hr',
					'hrsmpcpu' => 'hrsmpcpu',
					'hrmem' => 'hr',
					'hrvmem' => 'hr',
					'hrdisk' => 'hrdisk',

					'service' => 'service'

			);	

	return $type{$_};
}

# CAN BE DELETED LATER
sub thresholdLowPercent {
	my $node = shift;
	my $role = shift;
	my $threshold = shift;

	my $level;

	if ( $threshold <= 30 ) { $level = "1"; }
	elsif ( $threshold <= 50 ) { $level = "2"; }
	elsif ( $threshold <= 75 ) { $level = "3"; }
	elsif ( $threshold <= 90 )   { $level = "4"; }
	elsif ( $threshold <= 95 )  { $level = "5"; }
	elsif ( $threshold <= 100 )  { $level = "6"; }

	if ( $level == 1 ) { $level = 1; }
	elsif ( $role eq "core" ) { $level = $level + 2; }
	elsif ( $role eq "distribution" ) { $level = $level + 1; }
	
	$level = &eventNumberLevel($level);

	return $level;
}

sub thresholdHighPercent {
	my $node = shift;
	my $role = shift;
	my $threshold = shift;

	my $level;

	if ( $threshold == 100 ) { $level = "1"; }
	elsif ( $threshold >= 95 ) { $level = "2"; }
	elsif ( $threshold >= 90 ) { $level = "3"; }
	elsif ( $threshold >= 75 )   { $level = "4"; }
	elsif ( $threshold >= 50 )  { $level = "5"; }
	elsif ( $threshold < 50 )  { $level = "6"; }

	if ( $level == 1 ) { $level = 1; }
	elsif ( $role eq "core" ) { $level = $level + 2; }
	elsif ( $role eq "distribution" ) { $level = $level + 1; }
	
	$level = &eventNumberLevel($level);

	return $level;
}

sub thresholdHighPercentLoose {
	my $node = shift;
	my $role = shift;
	my $threshold = shift;

	my $level;

	if ( $threshold >= 85 ) { $level = "1"; }
	elsif ( $threshold >= 70 ) { $level = "2"; }
	elsif ( $threshold >= 60 ) { $level = "3"; }
	elsif ( $threshold >= 50 )   { $level = "4"; }
	elsif ( $threshold >= 40 )  { $level = "5"; }
	elsif ( $threshold < 40 )  { $level = "6"; }

	if ( $level == 1 ) { $level = 1; }
	elsif ( $role eq "core" ) { $level = $level + 2; }
	elsif ( $role eq "distribution" ) { $level = $level + 1; }
	
	$level = &eventNumberLevel($level);

	return $level;
}

sub thresholdMemory {
	my $node = shift;
	my $role = shift;
	my $threshold = shift;

	my $level;

	if    ( $threshold >= 40 ) { $level = "1"; }
	elsif ( $threshold >= 30 ) { $level = "2"; }
	elsif ( $threshold >= 20 ) { $level = "3"; }
	elsif ( $threshold >= 15 ) { $level = "4"; }
	elsif ( $threshold >= 10 ) { $level = "5"; }
	elsif ( $threshold >= 0 ) { $level = "6"; }

	if ( $level == 1 ) { $level = 1; }
	elsif ( $role eq "distribution" ) { $level = $level + 1; }
	elsif ( $role eq "core" ) { $level = $level + 2; }
	
	$level = &eventNumberLevel($level);

	return $level;
}

sub thresholdInterfaceUtil {
	my $node = shift;
	my $role = shift;
	my $threshold = shift;

	my $level;

	# for testing the thresholding! don't get much utilisation here!
	#if    ( $threshold == 0 ) { $level = "1"; }
	#elsif ( $threshold > 0 ) { $level = "4"; }
	if ( $threshold < 60 ) { $level = "1"; }
	elsif ( $threshold >= 60 ) { $level = "2"; }
	elsif ( $threshold >= 70 ) { $level = "3"; }
	elsif ( $threshold >= 80 ) { $level = "4"; }
	elsif ( $threshold >= 90 ) { $level = "5"; }
	elsif ( $threshold >= 95 ) { $level = "6"; }

	if ( $level == 1 ) { $level = 1; }
	elsif ( $role eq "distribution" ) { $level = $level + 1; }
	elsif ( $role eq "core" ) { $level = $level + 2; }
	
	$level = &eventNumberLevel($level);

	return $level;
}

sub thresholdInterfaceAvail {
	my $node = shift;
	my $role = shift;
	my $threshold = shift;

	my $level;
	
	### AS 12/4/01 - Tweaked the thresholds a bit, little less dramatic.
	if    ( $threshold >= 99 ) { $level = "1"; }
	elsif ( $threshold >= 95 ) { $level = "1"; }
	elsif ( $threshold >= 80 ) { $level = "2"; }
	elsif ( $threshold >= 70 ) { $level = "3"; }
	elsif ( $threshold >= 60 ) { $level = "4"; }
	elsif ( $threshold >= 50 ) { $level = "5"; }
	elsif ( $threshold < 50 ) { $level = "6"; }

	if ( $level == 1 ) { $level = 1; }
	elsif ( $role eq "distribution" ) { $level = $level + 1; }
	elsif ( $role eq "core" ) { $level = $level + 2; }
	
	$level = &eventNumberLevel($level);

	return $level;
}

sub thresholdInterfaceNonUnicast {
	my $node = shift;
	my $role = shift;
	my $threshold = shift;

	my $level;

	# for testing the thresholding! don't get much utilisation here!
	#if    ( $threshold == 0 ) { $level = "1"; }
	#elsif ( $threshold > 0 ) { $level = "4"; }
	if ( $threshold < 50 ) { $level = "1"; }
	elsif ( $threshold >= 60 ) { $level = "2"; }
	elsif ( $threshold >= 70 ) { $level = "3"; }
	elsif ( $threshold >= 80 ) { $level = "4"; }
	elsif ( $threshold >= 100 ) { $level = "5"; }
	elsif ( $threshold >= 200 ) { $level = "6"; }

	if ( $level == 1 ) { $level = 1; }
	elsif ( $role eq "distribution" ) { $level = $level + 1; }
	elsif ( $role eq "core" ) { $level = $level + 2; }
	
	$level = &eventNumberLevel($level);

	return $level;
}

# 24 Feb 2002 - Suggestion from Eric
sub thresholdResponse {
	my $node = shift;
	my $role = shift;
	my $threshold = shift;

	my $level;

	if ( $threshold <= 500 ) { $level = "1"; }
	elsif ( $threshold <= 750 ) { $level = "2"; }
	elsif ( $threshold <= 1000 ) { $level = "3"; }
	elsif ( $threshold <= 1500 )   { $level = "4"; }
	elsif ( $threshold > 1500 )  { $level = "5"; }

	if ( $level == 1 ) { $level = 1; }
	elsif ( $role eq "core" ) { $level = $level + 2; }
	elsif ( $role eq "distribution" ) { $level = $level + 1; }	

	$level = &eventNumberLevel($level);

	return $level;
}

## EHG 28 Aug for Net::SMTP priority setting on email
##
sub eventToSMTPPri {
	my $level = shift;
	# More granularity might be possible there are 5 numbers but
	# can only find word to number mappings for L, N, H
	if ( $level eq "Normal" ) { return "Normal" }
	elsif ( $level eq "Warning" ) { return "Normal" }
	elsif ( $level eq "Minor" ) { return "Normal" }
	elsif ( $level eq "Major" ) { return "High" }
	elsif ( $level eq "Critical" ) { return "High" }
	elsif ( $level eq "Fatal" ) { return "High" }
	elsif ( $level eq "Disaster" ) { return "High" }
	elsif ( $level eq "Catastrophic" ) { return "High" }
	elsif ( $level eq "Unknown" ) { return "Low" }
}

# test the dutytime of the given contact.
# return true if OK to notify
# expect a reference to %contact_table, and a contact name to lookup
sub dutyTime {
	my ($table , $contact) = @_;
	my $today;
	my $days;
	my $start_time;
	my $finish_time;

	if ( $$table{$contact}{DutyTime} ) {
	    # dutytime has some values, so assume TZ offset to localtime has as well
		my @ltime = localtime( time() + ($$table{$contact}{TimeZone}*60*60));
		if ($NMIS::debug) { printf "\tUsing corrected time %s for Contact:$contact, localtime:%s, offset:$$table{$contact}{TimeZone}\n", scalar localtime(time()+($$table{$contact}{TimeZone}*60*60)), scalar localtime();}

		( $start_time, $finish_time, $days) = split /:/, $$table{$contact}{DutyTime}, 3;
		$today = ("Sun","Mon","Tue","Wed","Thu","Fri","Sat")[$ltime[6]];
		if ( $days =~ /$today/i ) {
			if ( $ltime[2] >= $start_time && $ltime[2] < $finish_time ) {
				if ($NMIS::debug) { print "\treturning success on dutytime test for $contact\n";}
				return 1;
			}
			elsif ( $finish_time < $start_time ) { 
				if ( $ltime[2] >= $start_time || $ltime[2] < $finish_time ) {
					if ($NMIS::debug) { print "\treturning success on dutytime test for $contact\n";}
					return 1;
				}
			}
		}
	}
	# dutytime blank or undefined so treat as 24x7 days a week..
	else {
		if ($NMIS::debug) { print "\tNo dutytime defined - returning success assuming $contact is 24x7\n";}
		return 1;
	}
	if ($NMIS::debug) { print "\treturning fail on dutytime test for $contact\n";}
	return;		# dutytime was valid, but no timezone match, return false.
}

# set userMenu switch based on calling browser address
# mgmt address now in cidr notation as a comma seperated list, can use workstation names.
# result is 'true' if address matches.

sub userMenuDisplay {

	my $mgmt=0;
	my $cidr;
	if ( defined $NMIS::config{mgmt_lan} ) {
		MGMT: foreach $cidr ( split /,/ , $NMIS::config{mgmt_lan} ) {
			if ( $cidr =~ /\d+\.\d+\.\d+\.\d+/ ) {
				$mgmt = ipContainsAddr( ipaddr => $ENV{REMOTE_ADDR} , cidr => $cidr ); # returns true or false
				last MGMT if $mgmt ==1;
			}
			elsif ( $NMIS::netDNS ) {
				# lookup the ip and test the ptr record returned
				my $res = Net::DNS::Resolver->new;
				my $tmphostname;
				my $query = $res->query("$ENV{REMOTE_ADDR}","PTR");
				my $rr;
				if ($query) {
					foreach $rr ($query->answer) {
						next unless $rr->type eq "PTR";
						$tmphostname = $rr->ptrdname;
					}
					$mgmt = ( $tmphostname =~ /$cidr/i ) ? 1 : 0;
					last MGMT if $mgmt ==1;
				}
			}
		}
		return $mgmt;		# return true or false based on test.
	}
	else {
		return 1;		# no definition in config file, so set to enable all displays
	}
}

### get dynamic cam information and match up with ip addressing from MIB2 atTable
### here so can be called from nmis.pl or nmiscgi.pl, as an 'on-demand' update.
### assume systemTable and nodeTable loaded - safe bet as called from runSummary....

sub runCAM {
	## have a go at some dynamic cam entries, and match up with ip addressing, so we can report attached device ip address's by ifindex.
	## updated 1/1/05 to display mac if no ip available, for L2 Cat switches.

	my $node=shift;
	my $loadmibs = shift;		# set to true to load mibs - required if called from web.
	my $session;
	my $var;
	my $snmpcmd;
	my @vlan;
	my %bridgeTable;
	my %dotTable;
	my %camTable;
	my @ret;
	my $message;
	my %interfaceTable;
	my %seen;
	my $timeout=3;		# this should be taken out to nmis.conf at some point.

	if ( $NMIS::systemTable{snmpVer} ne "SNMPv2" ) { return }		# use snmpv2 only here for quick results !
	if ($NMIS::debug) { print "\t Getting the Dynamic CAM Information with IP Address\n" }

	# true if called from web.....
	if ( $loadmibs eq 'true' ) {
		$SNMP_Simple::suppress_warnings=2;
		$SNMP_Session::suppress_warnings=2;
		$SNMP_MIB::suppress_warnings=2;
		$SNMP_Simple::errmsg = "";

		if ($NMIS::debug) { print "\t Loading mib list\n"; }
		foreach ( split /,/ , $NMIS::config{full_mib} ) {
			if ( ! -r "$NMIS::config{mib_root}/$_" ) { 
				 warn returnTime." nmis.pl, mib file $NMIS::config{mib_root}/$_ not found.\n";
			}
			else {
				SNMP_MIB::loadoids_file( $NMIS::config{mib_root}, $_ );
				if ($debug) { print "\t Loaded mib $NMIS::config{mib_root}/$_\n"; }
				if ( $SNMP_Simple::errmsg ) {
					warn returnTime." nmis.pl, SNMP error. errmsg=$SNMP_Simple::errmsg\n";
					$SNMP_Simple::errmsg = "";
				}
			}
		}
	}

	($session) = SNMPv2c_Session->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
	if ( not defined($session) ) { 
		warn returnTime." runCAM, Session is not Defined Goodly to $node.\n"; 
		return;
	}

	# get the mac to ip address table first, keyed by mac address.
	# note: this will not work for L2 catos swithces - they dont have ip address information,
	# only a configured mgmt address
	# buts let display mac address if no ip address found
	# could then use nbstat on server to match to ip address.

	my $atPhysAddress = [1,3,6,1,2,1,3,1,1,2];
	my $atNetAddress = [1,3,6,1,2,1,3,1,1,3];

	$session->map_table ([$atPhysAddress, $atNetAddress],
			     \&atTable);


	if ( $SNMP_Session::errmsg =~ /No answer from/ ) {
		$message = "$node, SNMP error. errmsg=$SNMP_Session::errmsg";
		$SNMP_Session::errmsg = "";
		logMessage("runCAM atTable, $message");
		if ($NMIS::debug) { print returnTime." runCAM atTable, $message\n"; }
		return;
	}

		sub atTable {
			my ($index, $mac, $net) = @_;
			grep (defined $_ && ($_=pretty_print $_),	($mac, $net));
			my $macp;
			map { $macp .= sprintf("%02X",$_) } unpack "CCCCCC", $mac;
			# indexed by mac address of form '0001E6764760'.
			$camTable{$macp} = $net;
		}

	# Get the list of VLANs. Use snmpwalk on the vtpVlanState object (.1.3.6.1.4.1.9.9.46.1.3.1.1.2 ):

	$snmpcmd = "$NMIS::nodeTable{$node}{community}\@$node:$NMIS::nodeTable{$node}{snmpport}:$timeout:1:1:2";
	$var = 'vtpVlanState';

	@ret = &snmpwalk( $snmpcmd, { 'default_max_repetitions' => 4 }, SNMP_MIB::name2oid($var) );
	if (  ! $ret[0] ) {
		if ($NMIS::debug) { print "\t runCAM vtpVlanState: snmpwalk did not answer - CAM collection aborted\n"; }
		return;
	}
	else {
		foreach ( @ret ) {
			my ($inst, $value) = split /:/, $_, 2 ;
			my $textoid = SNMP_MIB::oid2name(SNMP_MIB::name2oid($var).".".$inst);
			( $textoid, $inst, my $vlan ) = split /\./, $textoid, 3;
			next if $value != 1;		# skip if vlan not operational
			next if $vlan >= 1000;		# skip the 1001,1002,1003 system defined vlans
			push @vlan, ( $vlan );
		}
	}

	# For each VLAN, Get the bridge port to ifIndex (1.3.6.1.2.1.2.2.1.1) mapping (using community string indexing!), dot1dBasePortIfIndex (.1.3.6.1.2.1.17.1.4.1.2):

	foreach ( @vlan) {
		$var = 'dot1dBasePortIfIndex';
		$snmpcmd = "$NMIS::nodeTable{$node}{community}\@$_\@$node:$NMIS::nodeTable{$node}{snmpport}:$timeout:1:1:2";
		@ret = &snmpwalk( $snmpcmd, { 'default_max_repetitions' => 12 }, SNMP_MIB::name2oid($var) );
		if (  ! $ret[0] ) {
			if ($NMIS::debug) { print "\t runCAM vlan$_ dot1dBasePortIfIndex: snmpwalk did not answer - CAM collection aborted\n"; }
			return;
		}
		else {
			foreach ( @ret ) {
				my ($inst, $value) = split /:/, $_, 2 ;
				my $textoid = SNMP_MIB::oid2name(SNMP_MIB::name2oid($var).".".$inst);
				( $textoid, $inst ) = split /\./, $textoid, 2;
				$bridgeTable{$inst} = $value;
			}
		}
	}

	# For each VLAN, get the MAC address table (using community string indexing!) dot1dTpFdbAddress (.1.3.6.1.2.1.17.4.3.1.1)

	$var = 'dot1dTpFdbAddress';
	foreach ( @vlan) {
		$snmpcmd = "$NMIS::nodeTable{$node}{community}\@$_\@$node:$NMIS::nodeTable{$node}{snmpport}:$timeout:1:1:2";
		@ret = &snmpwalk( $snmpcmd, { 'default_max_repetitions' => 12 }, SNMP_MIB::name2oid($var) );
		if (  ! $ret[0] ) {
			if ($NMIS::debug) { print "\t runCAM vlan$_ dot1dTpFdbAddress: snmpwalk did not answer - CAM collection aborted\n"; }
		return;
		}
		else {
			foreach ( @ret ) {
				my ($inst, $value) = split /:/, $_, 2 ;
				my $textoid = SNMP_MIB::oid2name(SNMP_MIB::name2oid($var).".".$inst);
				( $textoid, $inst ) = split /\./, $textoid, 2;
				my $mac;
				map { $mac .= sprintf("%02X",$_) } unpack "CCCCCC", $value;
				if ( exists $camTable{$mac} ) {
					$dotTable{$inst}{ipaddr} = $camTable{$mac};			# if an ip addr, subst the ipaddr for the mac here.
				}
				else {
					$dotTable{$inst}{ipaddr} = $mac;			# just save the mac - no ip available.
				}
			}
		}
	}
	# For each VLAN, get the bridge port number (using community string indexing!), dot1dTpFdbPort (.1.3.6.1.2.1.17.4.3.1.2):

	$var = 'dot1dTpFdbPort';
	foreach ( @vlan) {
		$snmpcmd = "$NMIS::nodeTable{$node}{community}\@$_\@$node:$NMIS::nodeTable{$node}{snmpport}:$timeout:1:1:2";
		@ret = &snmpwalk( $snmpcmd, { 'default_max_repetitions' => 12 }, SNMP_MIB::name2oid($var) );
		if (  ! $ret[0] ) {
			if ($NMIS::debug) { print "\t runCAM vlan$_ dot1dTpFdbPort: snmpwalk did not answer - CAM collection aborted\n"; }
		return;
		}
		else {
			foreach ( @ret ) {
				my ($inst, $value) = split /:/, $_, 2 ;
				my $textoid = SNMP_MIB::oid2name(SNMP_MIB::name2oid($var).".".$inst);
				( $textoid, $inst ) = split /\./, $textoid, 2;
				$dotTable{$inst}{ifIndex} = $bridgeTable{$value};		# subst the ifIndex for the bridgeport
			}
		}
	}

	# now process the results - note that if a hub is connected, we may have more than 1 ipaddr per port !

	my $interfacefile = "$NMIS::config{'<nmis_var>'}/$node-interface.dat";
	# See if an interface definition file exists
	if ( -r $interfacefile ) {
		%interfaceTable = &loadCSV($interfacefile,"ifIndex","\t");
	}
	else { return }		# no interface file ??

	foreach ( keys %dotTable ) {
		if ( $dotTable{$_}{ipaddr} and $dotTable{$_}{ifIndex} ) {
			if ( exists $seen{$dotTable{$_}{ifIndex}} ) {
				$interfaceTable{$dotTable{$_}{ifIndex}}{ipAdEntAddr} .= " >$dotTable{$_}{ipaddr}";		# concatenate
			}
			else {
				$interfaceTable{$dotTable{$_}{ifIndex}}{ipAdEntAddr} = ">$dotTable{$_}{ipaddr}";		# initialise
				$seen{$dotTable{$_}{ifIndex}} = 1;
			}
			if ($NMIS::debug) {
				print "\t $interfaceTable{$dotTable{$_}{ifIndex}}{ifDescr} has connected ip $dotTable{$_}{ipaddr}\n";
			}
		}
	}
	# write back the update.
	&writeCSV(%interfaceTable,$interfacefile,"\t");
} # end dynamic cam lookups	


### get the system time
### Original code from Robert Smith 2005
### Ported to NMIS version 4, Ivan Brunello 2005-2006
###

sub get_localtime {
	my $time;
	# pull the system timezone and then the local time
	if ($^O =~ /win32/i) { # could add timezone code here
		$time = scalar localtime;
	} else { 
		# assume UNIX box - look up the timezone as well.
		my $zone = uc((split " ", `date`)[4]);
		if ($zone =~ /CET|CEST/) {
			$time = returnDateStamp;
		} else {
			$time = (scalar localtime)." ".$zone;
		}
	}
	return $time;
}


### create the dashboard
### Original code from Robert Smith 2005
### Ported to NMIS version 4, Ivan Brunello 2005-2006
###
sub do_dash_banner {
      my $withAuth = shift;
      my $user = shift if $withAuth;
      my @banner = ();
      my $C = \%NMIS::config;

        print  comment("dash banner start");

        print start_table({width=>"100%", class=>"dash"}), start_Tr;

      if ( defined $C->{'banner_image'} ) {
              print td({width=>"15%", align=>"left", nowrap=>undef, class=>"menugrey"},
                       img({src=>$NMIS::config{'banner_image'}, alt=>$C->{banner_img_alt}, border=>"0"})) ;
      }
        print td({align=>"center", class=>"dash"}, $C->{dash_title});
        if ( $withAuth ) {
                print td({width=>"15%", align=>"right", nowrap=>undef, class=>"grey2"},
                        div({align=>"left"}, "User: ".$user."<br>", 
                        a({href=>url(-absolute=>1)."?type=logout", class=>"c"}, "Logout")));
        } else { print td({width=>"15%", class=>"grey2"},""); }
        print end_Tr, end_table;

        print  comment("dash banner end");

        return "\n";
}


### insert footer
### Original code from Robert Smith 2005
### Ported to NMIS version 4, Ivan Brunello 2005-2006
###
sub do_footer {
        my @footer = ();
      my $C = \%NMIS::config;

        push @footer, "\n" . comment("dash footer start") . "\n";
        push @footer, start_table({width=>'100%', align=>'center', class=>'white'});
        push @footer, Tr(td({align=>'center', valign=>"center",class=>'menugrey'},
#                a({href=>'http://www.kernel.org/'},
#                             img({border=>"0", alt=>"Penguin Powered", src=>"$C->{'<url_base>'}/images/penglogo.png"})),
#             a({href=>"http://www.apache.org/", id=>0, t=>"66"},
#                    img({border=>0, alt=>"Powered by Apache", title=>"Powered by Apache",
#                               src=>"http://httpd.apache.org/apache_pb.gif"})),
#               a({href=>"http://www.spreadfirefox.com/?q=affiliates", id=>0, t=>"66"},
#                       img({border=>0, alt=>"Get Firefox!", title=>"Get Firefox!",
#                               src=>"http://sfx-images.mozilla.org/affiliates/Buttons/110x32/rediscover.gif"})),
                 a({href=>'http://ee-staff.ethz.ch/~oetiker/webtools/rrdtool/'},
                               img({border=>"0", alt=>"RRDTool", src=>"$C->{'<url_base>'}/rrdtool.gif"})),
#               span("&nbsp;&nbsp"),
#               a({href=>"http://www.sins.com.au/nmis"},
#                       span({style=>"font-size:larger"},"NMIS $NMIS::VERSION")),
#               span("&nbsp")
               ));
 
         push @footer, Tr(td({align=>"center", class=>"menugrey"},
               $C->{footer_text} )) ;
         push @footer, end_table . "\n";
         push @footer,  comment("dash footer end") . "\n";
         return @footer;
}


#
# set file owner and permission, default nmis and 0775.
# change the default by conf/nmis.conf parameters "username" and "fileperm".
# Cologne, Jan 2005.
#
sub setFileProt {
	my $filename = shift;
	my $username;
	my $permission;
	my $login;
	my $pass;
	my $uid;
	my $gid;

	if ( not -r $filename ) {
		print returnTime." setFileProt: file $filename does not exist\n";
		return ;
	}
	if ( $kernel !~ /win32/i ) {
		# set the permissions. Skip if not running as root
		if ( ! $< ) {
			if ( defined $NMIS::config{username} and $NMIS::config{username} ne "" ) {
				$username = $NMIS::config{username} ;
			} else {
				$username = "nmis"; # default
			}
			if ( defined $NMIS::config{fileperm} and $NMIS::config{fileperm} ne "" ) {
				$permission = $NMIS::config{fileperm} ;
			} else {
				$permission = "0775"; # default
			}
			print returnTime." setFileProt: set file owner/permission of $filename to $username, $permission\n" if ($NMIS::debug > 3);
			if (!(($login,$pass,$uid,$gid) = getpwnam($username))) {
				logMessage("setFileProt, getpwnam, ERROR, unknown username $username");
				print returnTime." setFileProt: ERROR, unknown username $username\n" if $NMIS::debug;
			} else {
				if (!chown($uid,$gid,$filename)) {
					logMessage("setFileProt, chown, ERROR, could not change ownership $filename to $username, $!");
					print returnTime." setFileProt: ERROR, could not change ownership $filename to $username, $!\n" if $NMIS::debug;
				}
				if (!chmod(oct($permission), $filename)) {
					logMessage("setFileProt, chmod, ERROR, could not change $filename permissions to $permission, $!");
					print returnTime." setFileProt: ERROR, could not change $filename permissions to $permission, $!\n" if $NMIS::debug;
				}
			}
		}
	}
}

# connect slave by hhtp or https (SSL) and send a document request to the slave
# at the slave side the request will be processed by cgi-bin/connect.pl
# Cologne 2005
sub slaveConnect {


	my %args = @_;
	my $host = $args{host};
	my $type = $args{type};
	my $func = $args{func};
	my $node = $args{node};
	my $group = $args{group};
	my $par0 = $args{par0};
	my $par1 = $args{par1};
	my $par2 = $args{par2};
	my $par3 = $args{par3};
	my $par4 = $args{par4};
	my $par5 = $args{par5};
	my $body;
	my %hash;
	my @array;
	my $scalar;
	my $error;

	my @params = ("file=$NMIS::slaveTable{$host}{Conf}", "com=$NMIS::slaveTable{$host}{Community}");
	my $process = "/cgi-nmis/connect.pl";
	my $EOL = "\015\012";
	my $BLANK = $EOL x 2;
	my $line = "";
	my $remote;

	push @params, "type=$type", "func=$func";
	if ($node ne "") { push @params, "node=$node"; }
	if ($group ne "") { push @params, "group=$group"; }
	if ($par0 ne "") { push @params, "par0=$par0"; }
	if ($par1 ne "") { push @params, "par1=$par1"; }
	if ($par2 ne "") { push @params, "par2=$par2"; }
	if ($par3 ne "") { push @params, "par3=$par3"; }
	if ($par4 ne "") { push @params, "par4=$par4"; }
	if ($par5 ne "") { push @params, "par5=$par5"; }

	my $url = "$process?".join("&", @params);
	print returnTime." slaveConnect: GET $url\n" if $NMIS::debug;
	$url =~ s/ /%20/g;


=begin transport

	$remote = ($NMIS::slaveTable{$host}{Secure} eq "true") ? openSlaveSSL($host) : openSlave($host);

	unless ($remote) { 
		logMessage"slaveConnect, ERROR, cannot connect to http daemon on $host ($NMIS::slaveTable{$host}{Host})\n";
		print returnTime." slaveConnect: ERROR, cannot connect to http daemon on $host ($NMIS::slaveTable{$host}{Host})\n" if $NMIS::debug;
		return; 
	}
	$remote->autoflush(1);
	print $remote "GET $url HTTP/1.0" . $BLANK;
	while ( <$remote> ) { $line .= $_ ; }
	close $remote;

=cut transport

	use lib "/usr/local/nagios/lib", "/usr/local/nagios/etc";
	# This has to be a require because a slave will not have O::C
	require Opsview::Connections;
	my %slaves = map { ( lc($_->name), $_ ) } Opsview::Connections->slaves;
	my $slave_connection = $slaves{$host};
	unless ($slave_connection) { 
		logMessage "slaveConnect, ERROR, cannot find slave in connections.dat\n";
		print returnTime." slaveConnect: ERROR, cannot find slave in connections.dat\n" if $NMIS::debug;
		return; 
	}
	my @cmd = $slave_connection->ssh_command("/usr/local/nagios/nmis/cgi-bin/connect.pl '".join("' '",@params)."'");
	my $pid = open F, "-|", @cmd;
	while ( <F> ) { $line .= $_ ; }
	close F;

	if ( ($body) = ($line =~ m/<body><pre>(.*)<\/body>/s)) { 
##	print $body if $debug;
		$body =~ m/(\w+).*/s ;
		if ( $1 eq "hash" )	{
			%hash = eval $body;
			return (%hash);
		} elsif ($1 eq "array") {
			@array = eval $body;
			return (@array);
		} elsif ($1 eq "scalar") {
			$scalar = eval $body;
			return ($scalar);
		} else {
			# error
			if (  ($error) = ($line =~ m/<error>(.*)<\/error>/s)) { 
				logMessage"slaveConnect, ERROR msg from $host - $error\n";
				print returnTime." slaveConnect: ERROR msg from $host - $error\n" if $NMIS::debug;
			} else {
				logMessage"slaveConnect: ERROR, unknown data format $1\n" if $NMIS::debug;
				print returnTime." slaveConnect: ERROR, unknown data format $1\n" if $NMIS::debug;
			}
		}
	} else {
		logMessage"slaveConnect, ERROR, no data received from slave (see http errlog on $host)\n" if $NMIS::debug; 
		print returnTime." slaveConnect: ERROR, no data received from slave(see http errlog on $host)\n" if $NMIS::debug; 
	}

	return;

	sub openSlaveSSL {
		my $host = shift;
		require IO::Socket::SSL;

		print returnTime." slaveConnect: using SSL call to $host ($NMIS::slaveTable{$host}{Host})\n" if $NMIS::debug; 
		my $remote =  IO::Socket::SSL->new(
						PeerAddr => $NMIS::slaveTable{$host}{Host},
						PeerPort => "https(443)",
						Proto => "tcp",
						Timeout => 15);
		return $remote;
	}

	sub openSlave {
		my $host = shift;

		print returnTime." slaveConnect: call to $host ($NMIS::slaveTable{$host}{Host}:$NMIS::slaveTable{$host}{Port})\n" if $NMIS::debug; 
		my $remote =  IO::Socket::INET->new(
						PeerAddr  => $NMIS::slaveTable{$host}{Host},
						PeerPort  => $NMIS::slaveTable{$host}{Port},
						Proto => "tcp",
						Timeout => 15);
		return $remote;
	}

}

### write hash to file using Data::Dumper
### Cologne 2005
###
sub writeHashtoVar {
	my $file = shift; # filename
	my $data = shift; # address of hash
	my $handle;

	my $datafile = "$NMIS::config{'<nmis_var>'}/$file.nmis";

	print returnTime." writeHashtoVar: write data to $datafile\n" if $NMIS::debug;

	open DB, ">$datafile" or warn returnTime." writeHashtoVar: cannot open $datafile: $!\n";
	flock(DB, LOCK_EX) or warn returnTime." writeHashtoVar: can't lock file $datafile, $!\n";
	print DB Data::Dumper->Dump([$data], [qw(*hash)]);
	close DB;

	setFileProt($datafile);
}

### read file with lock containing data generated by Data::Dumper
### Cologne 2005
###
sub readVartoHash {
	my $file = shift; # primairy part of filename to read
	my %hash;
	my $handle;
	my $line;

	my $datafile = "$NMIS::config{'<nmis_var>'}/$file.nmis";

	if ( -r $datafile ) {
		sysopen($handle, $datafile, O_RDONLY ) 
			or warn returnTime." readVartoHash: cannot open $datafile, $!\n";
		flock($handle, LOCK_SH) or warn returnTime." readVartoHash: can't lock file $datafile, $!\n";
		while (<$handle>) { $line .= $_; }
		close $handle;

		# convert data to hash
		%hash = eval $line;
	} else {
		print returnTime." readVartoHash: file $datafile does not exist\n" if $NMIS::debug;
	}

	return %hash;
}


1;
