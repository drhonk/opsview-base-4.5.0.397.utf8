#!/usr/bin/perl
#
# $Id: nmis.pl,v 1.139 2007/10/30 08:32:09 egreenwood Exp $
#
#    nmis.pl - NMIS Perl Program - Network Mangement Information System
#    Copyright (C) 2000 Sinclair InterNetworking Services Pty Ltd
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
# *****************************************************************************
# Check if there are any arguements
if ( $#ARGV < 0 ) {
	&checkArgs;
	exit(0);
}

# Auto configure to the <nmis-base>/lib and <nmis-base>/files/nmis.conf
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "/usr/local/rrdtool/lib/perl"; 
# 
# ****** Shouldn't be anything else to customise below here *******************
# best to customise in the nmis.conf file.
#
require 5.008_000;

use Time::HiRes;
my $startTime = Time::HiRes::time();

use strict;
use csv;
use BER;
use SNMP_Session;
use SNMP_MIB;
use SNMP_Simple;
use SNMPv2c_Simple;
use SNMP_util;
use RRDs 1.000.490;
use rrdfunc;
use NMIS;
use func;
use ip;
use ping;
use notify;
use sapi;
use masterslave;
use Tie::RegexpHash;		# new - for hash keyed on a regex

require IO::Socket;

use Data::Dumper; 
Data::Dumper->import();
$Data::Dumper::Indent = 1;

# this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);
use Errno qw(EAGAIN ESRCH EPERM);

# Global Interpreted Variables ie stuff we figured out. 
my $sysObjectName;
my $ifIndex;
my $ifSpeed;

# Variable used to control writing the system file to ensure that it doesn't get blanked.
my $writeSystem = "false";

# Time Variables
my $time;
my $datestamp;
my $datestamp_2;
my $endTime;
# Global SNMP Variables once we get em keep em global
my %snmpTable;

# Variables for command line munging
my %nvp = getArguements(@ARGV);

# See if customised config file required.
my $conf;
if ( $nvp{file} ne "" ) { $conf = $nvp{file}; }
else { $conf = "nmis.conf"; }
my $configfile = "$FindBin::Bin/../conf/$conf";
if ( -r $configfile ) { loadConfiguration($configfile); }
# the following should be conformant to Linux FHS
elsif ( -e "/etc/nmis/$conf") { loadConfiguration ("/etc/nmis/$conf");}
else { die "Can't access neither configuration file $configfile, nor /etc/nmis/$conf \n"; }

# check for global collection off or on 
# useful for disabling nmis poll for server maintenance
if ($NMIS::config{global_collect} eq "false") { print "\n!!Global Collect set to false !!\n"; exit(0); }

# all arguments are now stored in nvp (name value pairs)
my $type=$nvp{type};
my $graph=$nvp{graph};
my $collect=$nvp{collect};
my $node_search=lc($nvp{node});
my $rmefile=$nvp{rmefile};
my $runGroup=$nvp{group};
# store multithreading arguments in nvp
my $mthread=($nvp{mthread} eq "true") ? 1 :0;
my $mthreadDebug=($nvp{mthreaddebug} eq "true") ? 1 :0;
my $maxThreads=$nvp{maxthreads};

# Set debugging level.
my $debug = setDebug($nvp{debug});
$NMIS::debug = $debug;

# if no type given, just run the command line options
if ( $type eq "" ) {
	print "No runtime option type= on command line\n\n";
	&checkArgs();
	exit(1);
}

print returnTime." NMIS version $NMIS::VERSION\n" if $debug;

### test if we are still running, or zombied, and cron will email somebody if we are
### not for updates - they can run past 5 mins
### collects should not run past 5mins - if they do we have a problem
### crontab should mail us if we just print the fact that we ran overtime last time thru
###
my $PIDFILE;
my $pid;
if ( $type eq 'collect' and !$debug and !$mthreadDebug ) {

	$PIDFILE = "$NMIS::config{'<nmis_var>'}/nmis.pid";
	if (-f $PIDFILE) {
	  open(F, "<$PIDFILE");
	  $pid = <F>;
	  close(F);
	  chomp $pid;
	  if ($pid != $$) {
	    print "Error: nmis.pl, previous pidfile exists, killing the process $pid check your process run-time\n";
	    kill 15, $pid;
	    unlink($PIDFILE);
	    print "\t pidfile $PIDFILE deleted\n" if $debug;
	  }
	}
	# Announce our presence via a PID file
	open(PID, ">$PIDFILE") or warn "\t Could not create $PIDFILE: $!\n";
	print PID $$; close(PID);
	print "\t pidfile $PIDFILE created\n" if $debug;

	# Perform a sanity check. If the current PID file is not the same as
	# our PID then we have become detached somehow, so just exit
	open(PID, "<$PIDFILE") or warn "\t Could not open $PIDFILE: $!\n";
	$pid = <PID>; close(PID);
	chomp $pid;
	if ( $pid != $$ ) {
		errorQuit(" we have detached somehow - exiting\n");
	}
}

# setup up a shared memory cache to return values from each forked process
###!! make sure buckets exceed your nodecount !!
###!! and if you change these - delete the cache file !!!
my $cache;
# only run this for collect and slave=true
if ( $type eq 'collect' and $NMIS::config{slave} eq 'true' ) {
	use Cache::Mmap;
	my %options = (	'buckets' => 900,
					'bucketsize' => '1024',
	               	'writethrough' => 1,
	               	'expiry' => 600
	               	);
	my $cacheFilename = "$NMIS::config{'<nmis_var>'}/cache.nmis";
	$cache=Cache::Mmap->new($cacheFilename,\%options) or die( "Cache::Mmap: Couldn't instantiate SharedMemoryCache" );
}

# used for plotting major events on world map in 'Current Events' display
$NMIS::netDNS = 0;
if ( $NMIS::config{DNSLoc} ne "off" ) {
	# decide if Net::DNS is available to us or not
	if ( eval "require Net::DNS") {
        $NMIS::netDNS = 1;
        require Net::DNS;
	}
	else {
		print "Perl Module Net::DNS not found, Can't use DNS LOC records for Geo info, will try sysLocation\n" if $debug;
	}
}

# Create a hash for storing runReachability stats
my %reach;

# Create a hash for storing interface stats
my %ifStats;
my %pvcStats;

# An array of Interface Status for AdminStatus and OperStatus
my @interfaceStatus = ("null","up","down","testing","unknown","dormant","notPresent","lowerLayerDown");

# Set the default collect option
if ($collect eq "") { $collect = "true"; }

# Set the default graph option
if ($graph eq "") { $graph = "false"; }

# Set the default maxThread option. This controlls the maximum numbers of threads nmis will create.
if ($maxThreads eq "") { $maxThreads = 2; }

# Other Global Variables
my @interfaceTable;
my $timeout = 10;
my $snmpresult;
my $run;
my $statsDir;
my $onenode;
my $index;
my $nodecount;
my $ping_min;
my $ping_avg;
my $ping_max;
my $ping_loss;

# Find kernel name
my $kernel;
if (defined $NMIS::config{kernelname} and $NMIS::config{kernelname} ne "") {
	$kernel = $NMIS::config{kernelname};
} elsif ($^O !~ /linux/i) {
	$kernel = $^O;
} else {
	chomp($kernel = lc `uname -s`);
}
$NMIS::kernel = $kernel; # global
print returnTime." Kernel name is $kernel\n" if $debug;

# if master load slave table
if ($NMIS::config{master_dash} eq "true") { &loadSlave; }

# The node to turn on debugging for no matter what
my $debug_watch = "";
my $debug_global = $debug;

# ******************************************************************
# ** multithreading variables and ipc stuff
# ******************************************************************
#
if ($^O =~ /win32/i) { $mthread = 0; }		# force mthread off for Win32 systems
#
# *****************************************

# check OS for the next system commands
my $ps = "ps -ec"; # default linux
$ps = "ps -ax" if ($kernel eq "???"); # for ???

# some master/slave work, and required coprocesses.
# if we are a master, then check that master.pl is running as a daemon - if not, start it.

if ( $NMIS::config{master} eq 'true' ) {
	if ( ! `$ps | grep master.pl`) {
		`$NMIS::config{'<nmis_bin>'}/master.pl`;
		logMessage("\t nmis.pl,master=true, launched master.pl as daemon") if $debug;
	}
}
# also check if enabled that our logWatch for tunnel up/downs is running
if ( $NMIS::config{logwatch} eq 'true' ) {
	if ( ! `$ps | grep logwatch.pl`) {
		`$NMIS::config{'<nmis_bin>'}/logwatch.pl`;
		logMessage("\t nmis.pl, logwatch=true, launched logwatch.pl as daemon") if $debug;
	}
}
# and if we are a slave, we want rsync --daemon to be running - edit /etc/rsyncd.conf
if ( $NMIS::config{slave} eq 'true' ) {
	if ( ! `$ps | grep rsync`) {
		`rsync --daemon`;
		logMessage("\t nmis.pl,slave=true, launched rsync as daemon") if $debug;
	}
}
if ( -r "$NMIS::config{'<nmis_bin>'}/nbarpdd.pl" and $NMIS::config{daemon_nbarpd} eq "true" ) {
	if ( ! `$ps | grep nbarpdd`) {
		`$NMIS::config{'<nmis_bin>'}/nbarpdd.pl`;
		logMessage("\t nmis.pl, launched nbarpdd.pl as daemon") if $debug;
	}
}
if ( -r "$NMIS::config{'<nmis_bin>'}/rttmond.pl" and $NMIS::config{daemon_rttmon} eq "true" ) {
	if ( ! `$ps | grep rttmond`) {
		`$NMIS::config{'<nmis_bin>'}/rttmond.pl`;
		logMessage("\t nmis.pl, launched rttmond.pl as daemon") if $debug;
	}
}

#
# for now IPC::Shareable is **NOT** compatible with Win32 O/S
# so we will check for the O/S and force mthread to false if on Win32
# using the interprocess shareable.pm (can be downloaded from www.cpan.org)
# will need to make the mthread variables global
my $currentThreads;
my $handle;
my $success;
# use this var for setting the process level. 0 is the normal user process. >0 is more polite. <0 is more impolite.
#  multithreading process priority controll
# set to 2 less than the parent (usually 0) so as allow the web service to get some time.
# use getpriority to check our own process settings, as we may have been 'niced' from the cmdline
# !!these values are incremental to the parent process !!
my $MAIN_PROCESS_PRIO = 2;		# two more polite than our parent - as we may have been 'niced' already
my $CHILD_PROCESS_PRIO = 1;		# childs one more polite than their father
# define the constant PRIO_PROCESS as 0, comment out to use the BSD::Resource declaration for platform compatibility
use constant PRIO_PROCESS => 0;

# initialise the shared memory, setup a POSIX compliant child signal handler and change our priority
if ($mthread) {
	require IPC::Shareable;
	# POSIX signal handler for RH9
	use POSIX ":sys_wait_h";		# imports WNOHANG
	# RH9 requires this for reaping zombies, older systems may work better with the autoreap flag
	if ( $NMIS::config{posix} eq 'true' ) {
		$SIG{CHLD} = sub { while( waitpid(-1,WNOHANG) > 0 ) {} };
	}
	else {
		$SIG{CHLD} ='IGNORE';
	}

	# if your hit ctrl+c druring multithreading, the childs will die and produce some output
	sub catch_zap {
		my $signame = shift;
		IPC::Shareable->clean_up;
		print "Somebody sent me a SIG$signame PID $$ is dying\n";
		exit 1;
	} 
	$SIG{INT} = \&catch_zap;
	$SIG{TERM} = \&catch_zap;

	# creating a global variable in shared memory. All processes can access this
	# variable (even the childs). See IPC::Shareable documentation.
	$handle = tie $currentThreads, 'IPC::Shareable', undef, { destroy => 1 } or die " mthread: tie failed\n";
	# you should use BSD::Resource module for priority setting (can be downloaded from www.cpan.org)
	require BSD::Resource;
	# set process priority
	# PRIO_PROCESS -> the current process
	# $$ -> the processID (PID) of this parent process
	$success = setpriority(PRIO_PROCESS,$$,getpriority(PRIO_PROCESS,$$) + $MAIN_PROCESS_PRIO);
}

# How long to run for in seconds thus 30 * 60 is 1800 seconds
my $start_time = time;
if ($debug) { print returnTime ." Starting $0 $NMIS::VERSION: type=$type file=$configfile node=$node_search\n"; }

# Load the node file ! ( and any slave node records !!)
# load all the files we need here , and dont reload them later !!
loadNodeDetails;
loadEventStateNoLock;
loadEventStateSlave;

# if group given, but not valid group, exit with message
if ( $runGroup ne "" and !exists $NMIS::groupTable{$runGroup} ) {
	print "Group $runGroup not found in Nodes table\n\n";
	&checkArgs();
	exit(1);
}

# qr creates FAST REGEX for patterns used all the time.
my $qr_int_stats = qr/$NMIS::config{int_stats}/i;
my $qr_hc_model = qr/$NMIS::config{hc_model}/i;
my $qr_ignore_up_down_ifDescr = qr/$NMIS::config{ignore_up_down_ifDescr}/i;
my $qr_ignore_up_down_ifType = qr/$NMIS::config{ignore_up_down_ifType}/i;
my $qr_no_collect_ifDescr_gen = qr/$NMIS::config{no_collect_ifDescr_gen}/i;
my $qr_no_collect_ifDescr_atm = qr/$NMIS::config{no_collect_ifDescr_atm}/i;
my $qr_no_collect_ifDescr_voice = qr/$NMIS::config{no_collect_ifDescr_voice}/i;
my $qr_no_collect_ifType_gen = qr/$NMIS::config{no_collect_ifType_gen}/i;
my $qr_no_collect_ifAlias_gen = qr/$NMIS::config{no_collect_ifAlias_gen}/i;
my $qr_link_ifType = qr/$NMIS::config{link_ifType}/i;
my $qr_sysLoc_format = qr/$NMIS::config{sysLoc_format}/i;
my $qr_collect_rps_gen = qr/$NMIS::config{collect_rps_gen}/i;
my $qr_no_collect_ifDescr_switch = qr/$NMIS::config{no_collect_ifDescr_switch}/i;

##############################################################
# SNMP Setup, debug options, load base mibs etc.
##############################################################
# set snmp debug on or not depending on global debug 
if ($debug) {
	#You can turn off SNMP debug but still leave debug 
	#messages on just comment the following line for no 
	#SNMP debug at all
	#$SNMP_Simple::debug=1;
	#$SNMP_util::Debug = 1;
	
	# If you want SNMP warnings during debug comment these lines ( module defaults are '0' for warnings enabled )
	#$SNMP_Simple::suppress_warnings=2;
	#$SNMP_Session::suppress_warnings=2;
}
else {
	#no debug - turn off all snmp warnings
	#note that snmp_util::suppress_warnings > 1
	$SNMP_Simple::suppress_warnings=2;
	$SNMP_Session::suppress_warnings=2;
	$SNMP_MIB::suppress_warnings=2;
}

# initalizes the OID mappings for the SNMP_Simple library.
# loadoids file will accept a list of MIBS
# $NMIS::config{full_mib} has a list of all the mibs.....
$SNMP_Simple::errmsg = "";

if ($debug) { print "\t Loading mib list from $configfile\n"; }
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

# If this is an update, check the config and report any errors
if ( $type eq "update" ) { &checkConfig; }

# if called from the cmd line 'type=master' and nmis.conf 'master =true', then copy up the slave nmis.conf and var directory
# really only here for debugging.
if ( $type eq 'master' and $NMIS::config{master} eq 'true' ) { &runMaster }

# If this is an escalation run, do it
if ( $type eq "escalate" ) { &runEscalate; }
# If this is an config run, do it
elsif ( $type eq "config" ) { &checkConfig("fix"); }
# If this is an config run, do it
elsif ( $type eq "links" ) { &runLinks; }
# If this is an apache run, do it
elsif ( $type eq "apache" ) { &printApache; }
elsif ( $type eq "services" ) { &runServices($node_search); }

# If this is a threshold run, do it
elsif ( $type eq "threshold" ) {
	#######################################################################
	# Do the threshold thing
	#######################################################################
	if ( $node_search eq "" ) {
		# multithreading
		# currentthreads should be 0....
		if ($mthread) {
			# shlock will lock the shared memory var $currentThreads so that no other
			#process will write something in it.
			# all other processes will be queued! So nothing will get lost.
			$handle->shlock();
			$currentThreads=0;
			# unlocks the var
			$handle->shunlock();
			if ($mthreadDebug) {
				print "FATHER $$-> running threshold in multithreading mode\n";
				print "FATHER $$-> My priority is ";print getpriority(PRIO_PROCESS,$$); print "\n";
			}
		}

		foreach $onenode ( keys %NMIS::nodeTable ) {
			# skip nodes that are set active=false and slave=<name of slave host>
			if ( $NMIS::nodeTable{$onenode}{active} ne 'false'
				and not exists $NMIS::nodeTable{$onenode}{slave} and not exists $NMIS::nodeTable{$onenode}{slave2}) {

				++$nodecount;
				# One thread for each node until maxThreads is reached.
				# This loop is entered only if the commandlinevariable mthread=true is used!
				if ($mthread) {
					# incrementing the currentThread value for each thread which is startet.
					#This incrementation will be done in the
					# father process because it can take a time until the child is borne and
					#running
					$handle->shlock();
					$currentThreads++;
					$handle->shunlock();

					# starting new child process
				FORK:
					if ($pid=fork) {
					# this will be run only by the father process
						if ($mthreadDebug) {
							print "FATHER $$-> starting a thread for node $onenode\n";
							print "FATHER $$-> currently there are $currentThreads threads running\n";
						}
					}
					# this will be run only by the child
					elsif (defined $pid) {	# $pid is copy of father here if defined

						# changing process prio
						# PRIO_PROCESS -> the current process
						# $$ -> the processID (PID) of this child process
						$success = setpriority(PRIO_PROCESS,$$,getpriority(PRIO_PROCESS,$$) + $CHILD_PROCESS_PRIO) ? "yes" : "no";
						if ($mthreadDebug) {
							print "CHILD $$-> I am a CHILD with the PID $$ processing $onenode\n";
							print "CHILD $$-> My father's PID is ";print getppid();print "\n";
							print "CHILD $$-> Process priority has been changed. Really? $success My new priority is ";print getpriority(PRIO_PROCESS,$$);print "\n";
						}

						# lets change our name, so a ps will report who we are
						$0 = "nmis.pl.$type.$onenode";

						&runThreshold($onenode);

						# all the work in this thread is done
						# now this child will die. But before it must decrement the
						#currentThreads var
						if ($mthreadDebug) {
							print "CHILD $$-> currently there are $currentThreads running\n";
						}

						$handle->shlock();
						$currentThreads=$currentThreads-1;
						$handle->shunlock();

						if ($mthreadDebug) {
							print "CHILD $$-> $onenode WiLl DiE nOw aRgHhHhHhHhH\n";
							print "CHILD $$-> now there are $currentThreads running\n";
						}

						# killing child
						exit 0;
					} # end of child
					elsif ($! == EAGAIN) {
						# EAGAIN is the supposedly recoverable fork error
						sleep 5;
						redo FORK;
					}
					else {
						# weird fork error
						errorQuit( "Can't fork: $!\n");
					} #fork
				} #if mthread
				# will be run if mthread is false (no multithreading)
				else {
					
					&runThreshold($onenode);
				}

				# Check how much threads are running.
				if ($mthread) {
					if ($currentThreads == $maxThreads) {
						if ($mthreadDebug) {
							print "FATHER $$-> maximum number of concurrent threads is reached!\n";
							print "FATHER $$-> there are $currentThreads Threads\n";
						}

						# wait until one or more childs are dead....
						while ($currentThreads >= $maxThreads) {
							if ($mthreadDebug) {
								print "FATHER $$-> must wait until one or more childs are dead. Currently there are $currentThreads Threads\n";
							}

							# sleep a while. is good for the cpu....
							select(undef, undef, undef, 0.3);
						}

						if ($mthreadDebug) {
							print "FATHER $$-> One or more Childs are dead now. So I can fork some new ones.\n";
							print "FATHER $$-> currently there are $currentThreads Threads\n";
						}
					}
				} #ifmthread
			} #ifactive
			else {
				 print "\t Skipping as $onenode is a slave or marked 'inactive'\n" if $debug;
			}
		}	#foreach - go fork anaother one if we can
	}# if ($node_search eq)
	else {
		if ( $node_search eq lc($NMIS::nodeTable{$node_search}{node})
			and not exists $NMIS::nodeTable{$node_search}{slave} and not exists $NMIS::nodeTable{$node_search}{slave2}) {

			if ( $NMIS::nodeTable{$node_search}{active} ne 'false' ) {
				++$nodecount;
				&runThreshold($node_search);
			}
			else {
				 print "\t Skipping as $node_search is a slave or marked 'inactive'\n" if $debug;
			}
		}
		else {
			errorQuit( "Invalid node $node_search: No node of that name!\n");
		}
	}
} #elsif threshold
      
# Read a Cisco Works file and produce an NMIS Nodes file
elsif ( $type eq "rme" ) {
	if ( $rmefile eq "" ) {
		errorQuit ("$0 the type=rme option requires a file arguement for source rme CSV file\ni.e. $0 type=rme rmefile=/data/file/rme.csv\n");
	}
	else {
		loadRMENodes($rmefile);
		writeNodesFile("$NMIS::config{Nodes_Table}.new");
	}
}
# Must be a collect run or something on one node
elsif ( $node_search ne "" ) {
	if ( $node_search eq lc($NMIS::nodeTable{$node_search}{node})
			and not exists $NMIS::nodeTable{$node_search}{slave} and not exists $NMIS::nodeTable{$node_search}{slave2}) {

		if ( $NMIS::nodeTable{$node_search}{active} ne 'false' ) {

			++$nodecount;
			&runNodeStats($node_search);
		}
		else {
			 print "\t Skipping as $node_search is a slave or marked 'inactive'\n" if $debug;
		}
	}
	else {
		errorQuit( "Invalid node $node_search: No node of that name!\n");
	}
}
# Must be a collect run or update so do all the nodes
elsif ( $type eq 'collect' or $type eq 'update' ) {
	##############################################################
	# Processing Loop for all nodes
	##############################################################	
	$index = 0;

	# multithreading
	# currentthreads should be 0....
	if ($mthread) {
		# shlock will lock the shared memory var $currentThreads so that no other
		# process will write something in it.
		# all other processes will be queued! So nothing will get lost.
		$handle->shlock();
		$currentThreads=0;
		# unlocks the var
		$handle->shunlock();
		if ($mthreadDebug) {
			print "FATHER $$-> running threshold in multithreading mode\n";
			print "FATHER $$-> My priority is ";print getpriority(PRIO_PROCESS,$$); print "\n";
		}
	}
	foreach $onenode ( keys %NMIS::nodeTable ) {
		
		# This will allow debugging to be turned on for a  
		# specific node where there is a problem
		if ( $onenode eq "$debug_watch" ) { $debug = "true"; }
		else { $debug = $debug_global; }

		# KS 16 Mar 02, implementing David Gay's requirement for deactiving
		# a node, ie keep a node in nodes.csv but no collection done.
		# also if $runGroup set, only do the nodes for that group.
		if ( $runGroup eq "" or $NMIS::nodeTable{$onenode}{group} eq $runGroup ) {
			if ( $NMIS::nodeTable{$onenode}{active} ne 'false'
				and not exists $NMIS::nodeTable{$onenode}{slave} and not exists $NMIS::nodeTable{$onenode}{slave2}) {
				undef %reach;
				++$nodecount;
				
				# One thread for each node until maxThreads is reached.
				# This loop is entered only if the commandlinevariable mthread=true is used!
				if ($mthread) {
					# incrementing the currentThread value for each thread which is startet.
					#This incrementation will be done in the
					# father process because it can take a time until the child is borne and
					#running
					$handle->shlock();
					$currentThreads++;
					$handle->shunlock();

					# starting new child process
				FORK1:
					if ($pid=fork) {
						# this will be run only by the father process
						if ($mthreadDebug) {
							print "FATHER $$-> starting a thread for node $onenode\n";
							print "FATHER $$-> currently there are $currentThreads threads running\n";
						}
					}
					# this will be run only by the child
					elsif (defined $pid) {	# $pid is copy of father here if defined
						# changing process prio
						# PRIO_PROCESS -> the current process
						# $$ -> the processID (PID) of this child process
						$success = setpriority(PRIO_PROCESS,$$,getpriority(PRIO_PROCESS,$$) + $CHILD_PROCESS_PRIO) ? "yes" : "no";
						if ($mthreadDebug) {
							print "CHILD $$-> I am a CHILD with the PID $$ processing $onenode\n";
							print "CHILD $$-> My father's PID is ";print getppid();print "\n";
							print "CHILD $$-> Process priority has been changed. Really? $success My new priority is ";print getpriority(PRIO_PROCESS,$$);print "\n";
						}
						# lets change our name, so a ps will report who we are
						$0 = "nmis.pl.$type.$onenode";

						&runNodeStats($onenode);

						# all the work in this thread is done
						# now this child will die. But before it must decrement the currentThreads
						#var
						if ($mthreadDebug) {
							print "CHILD $$-> currently there are $currentThreads running\n";
						}

						$handle->shlock();
						$currentThreads=$currentThreads-1;
						$handle->shunlock();

						if ($mthreadDebug) {
							print "CHILD $$-> $onenode WiLl DiE nOw aRgHhHhHhHhH\n";
							print "CHILD $$-> now there are $currentThreads running\n";
						}

						# killing child
						exit 0;
					} # end of child
					elsif ($! == EAGAIN) {
						# EAGAIN is the supposedly recoverable fork error
						sleep 5;
						redo FORK1;
					}
					else {
						# weird fork error
						errorQuit( "Can't fork: $!\n");
					} #fork
				} # if mthread
				# will be run if mthread is false (no multithreading)
				else {
					&runNodeStats($onenode);
				}

				# Check how much threads are running.
				if ($mthread) { 
					if ($currentThreads == $maxThreads) {
						if ($mthreadDebug) {
							print "FATHER $$-> maximum number of concurrent threads is reached!\n";
							print "FATHER $$-> there are $currentThreads Threads\n";
						}

						# wait until one or more childs are dead....
						while ($currentThreads >= $maxThreads) {
							if ($mthreadDebug) {
								print "FATHER $$-> must wait until one or more childs are dead. Currently there are $currentThreads Threads\n";
							}

							# sleep a while. is good for the cpu....
							select(undef, undef, undef, 0.3);
						}

						if ($mthreadDebug) {
							print "FATHER $$-> One or more Childs are dead now. So I can fork some new ones.\n";
							print "FATHER $$-> currently there are $currentThreads Threads\n";
						}
					}
				} #if mthread
				++$index;
			} #if active
			else {
				 print "\t Skipping as $onenode is a slave or marked 'inactive'\n" if $debug;
			}
		} #if runGroup
	} # foreach $onenode
} # end of elsif on type=xxxx


# only do the cleanup if we have mthread enabled 
if ($mthread) {
	if ($mthreadDebug) {
		print "FATHER $$-> All Threads are running.\n";
		print "FATHER $$-> Must wait now for $currentThreads childs to finish.\n";
	}

	# Wait for all childs POSIX style
	my $kid;
	do { $kid = waitpid(-1, WNOHANG); } until $kid == -1;

	if ($mthreadDebug) {
		print "FATHER $$-> All Threads are dead.\n";
		print "FATHER $$-> Will now continue without multithreading.\n";
	}
	
	# removing all shared memory created by nmis
	$handle->remove;
	IPC::Shareable->clean_up_all();				# !! note change June2004
}
# continue normally

# write the slave info to master
if ( $type eq 'collect' and $NMIS::config{slave} eq 'true' ) {
	# pull the cached data into a local share, so we can pass by reference to tellmaster.
	my %share;
	my $data;
	foreach ( keys %NMIS::nodeTable ) {		# all nodes copied up - could be improved....
		$data = $cache->read($_);
		$share{$_} = $data if $data;		# only save defined values.
	}
	# lets also copy the Node Down events to the master, so the master display shows red/green whatever 

	foreach my $key ( keys %NMIS::eventTable ) {
		next unless $NMIS::eventTable{$key}{event} eq 'Node Down';
		# copy the whole event line up
		foreach my $val ( keys %{ $NMIS::eventTable{$key} } ) {
			$share{$NMIS::eventTable{$key}{node}}{event}{$val} = $NMIS::eventTable{$key}{$val};
		}
	}
	#print Dumper(\%share);
	# master neeeds to know which slave host this update came from
	# the hostnmae here should match the one defined in slave.csv
	$share{hostname} = $NMIS::config{nmis_host};
	tellMaster(\%share);
	$cache->quick_clear();			# clean it before the next run of nmis.pl
}

# Couple of post processing things.
if ( $type eq "collect" ) {

	nmisSummary() if $NMIS::config{SummaryCache} eq 'true';			# cache the summary stats
	&httpMaster;
	&runMetrics; 
	&runEscalate; 			# this locks the event state file, but we are finished with threading, so OK.
}

# before we quit, if we are a master update, pull the slave /var directory to us (master)
# only run the master update if no node specified on cmd line
# use type=master if master only update required - no node update
if ($type eq 'update' and $NMIS::config{master} eq 'true' and !$node_search) { &runMaster }

# if an update, concatencate all the node interface.dat files in <nmis_var>/interface.csv
elsif ( $type eq "update" ) { &createInterfaceInfo; &createNBARPDInfo; }


# normal exit
cleanPID();
exit 0;

# preload all summary stats - for metric update and dashboard display.
sub nmisSummary {

	my $k;
	print returnTime." nmisSummary: Calculating NMIS network stats for cgi cache\n" if $debug;

	summaryCache( 'summary8', '-8 hours', time() );
	$k = summaryCache( 'summary16', '-16 hours', '-8 hours' );

	print returnTime." nmisSummary: Finished calculating NMIS network stats for cgi cache - wrote $k nodes\n" if $debug;

	sub summaryCache {

		my $file = shift;
		my $start = shift;
		my $end = shift;

		my $reportStats;
		my @tmparray;
		my @tmpsplit;
		my $node;
		my %summaryHash = ();

		foreach $node ( keys %NMIS::nodeTable)  {
			if ( not exists $NMIS::nodeTable{$node}{'slave'} and not exists $NMIS::nodeTable{$node}{'slave2'}){
				loadSystemFile($node);		# need this to get nodeType..
				# preload the hash, so number of records = number of nodes
				$summaryHash{$node}{reachable} = 0;
				$summaryHash{$node}{response} = 0;
				$summaryHash{$node}{loss} = 0;
				$summaryHash{$node}{health} = 0;
				$summaryHash{$node}{available} = 0;

				%summaryHash = (%summaryHash, summaryStats(node => $node,type => "health",start => $start, end => $end, key => $node ));
			}
		}

		&writeHashtoVar( $file, \%summaryHash );
		
		return (scalar keys %summaryHash);
	}
}

sub httpMaster {

	my $num_keys;

	return if ( $NMIS::config{master_dash} ne "true" );

	print returnTime." httpMaster: Started\n" if $debug;

	# get the data from slave by http get
	foreach my $name ( keys %NMIS::slaveTable ) {
		my %summaryHash8 = ();
		my %summaryHash16 = ();
		# get nodeTable from slave with addition values
		my %nodeTable = slaveConnect(host => $name, type => 'send', func => 'sumnodeTable');
		$num_keys = scalar keys %nodeTable;
		print returnTime." httpMaster: node table from $name contains $num_keys keys\n" if $debug;
		if (%nodeTable) {
			# get summary info
			my %summary8 = slaveConnect(host => $name, type => 'send', func => 'summary8');
			$num_keys = scalar keys %summary8;
			print returnTime." httpMaster: summary8 from $name contains $num_keys keys\n" if $debug;
			my %summary16 = slaveConnect(host => $name, type => 'send', func => 'summary16');
			$num_keys = scalar keys %summary16;
			print returnTime." httpMaster: summary16 from $name contains $num_keys keys\n" if $debug;
			foreach my $node ( keys %nodeTable)  {
				$summaryHash8{$node}{reachable} = (exists $summary8{$node}{reachable}) ? $summary8{$node}{reachable} : 0;
				$summaryHash8{$node}{response} = (exists $summary8{$node}{response}) ? $summary8{$node}{response} : 0;
				$summaryHash8{$node}{loss} = (exists $summary8{$node}{loss}) ? $summary8{$node}{loss} : 0;
				$summaryHash8{$node}{health} = (exists $summary8{$node}{health}) ? $summary8{$node}{health} : 0;
				$summaryHash8{$node}{available} = (exists $summary8{$node}{available}) ? $summary8{$node}{available} : 0;
				$summaryHash16{$node}{reachable} = (exists $summary16{$node}{reachable}) ? $summary16{$node}{reachable} : 0;
				$summaryHash16{$node}{response} = (exists $summary16{$node}{response}) ? $summary16{$node}{response} : 0;
				$summaryHash16{$node}{loss} = (exists $summary16{$node}{loss}) ? $summary16{$node}{loss} : 0;
				$summaryHash16{$node}{health} = (exists $summary16{$node}{health}) ? $summary16{$node}{health} : 0;
				$summaryHash16{$node}{available} = (exists $summary16{$node}{available}) ? $summary16{$node}{available} : 0;
			}
			writeHashtoVar("$name-nodes",\%nodeTable);
			writeHashtoVar("$name-summary8",\%summaryHash8);
			writeHashtoVar("$name-summary16",\%summaryHash16);
		}
	}
	print returnTime." httpMaster: Finished\n" if $debug;
}


# Handle some simple debuging
sub errorQuit {
	my $string = shift;
	$string =~ s/\n+/ /g;      			# remove all embedded newlines
	print returnTime." $string\n";		# crontab should mail this string to us...
	cleanPID();
	exit -1;
}

# delete the PID file if collect run
sub cleanPID {
	if ( $type eq 'collect' and !$debug and !$mthreadDebug) {
		unlink($PIDFILE);
		print "\t pidfile $PIDFILE deleted\n" if $debug;
	}

	# nmis collect runtime
	if ( $type eq "collect" ) {
		my $data;
		$data->{collect} = sprintf( "%.0f", Time::HiRes::tv_interval([$startTime]));
		&updateRRDDB(type => "nmis",group => "nmis-system", data => $data);
	}

	if ($debug or $mthreadDebug) {
		$endTime = sprintf( "%.2f", Time::HiRes::tv_interval([$startTime]));
		print "\n".returnTime ." End of $0 Processed $nodecount nodes ran for $endTime seconds.\n\n";
	}
}

#
sub runNodeStats {
	my $runnode = shift;

	my $pingresult;
	my $nodeCollect;

	# test our arguments
	if ( $runnode eq "" or $type eq "" or $type !~ /update|collect/	) {
		errorQuit("ERROR: no node or bad type, node=$runnode type=$type");
	}

	undef %reach;
	$snmpresult = 100;


	### AS 1/4/2001 - Load the node file if it exists.
	if ( -r "$NMIS::config{'<nmis_var>'}/$runnode.dat" ) {
		loadSystemFile($runnode);
		foreach (keys %NMIS::systemTable) {
			if ( $_ =~ /typedraw/ ) { $NMIS::systemTable{$_} = (); } # clear this type of info
		}
	}
	if ($debug) { 
		print returnTime." node=$runnode role=$NMIS::systemTable{roleType} type=$NMIS::systemTable{nodeType}\n";
		if ( $NMIS::systemTable{nodeVendor} ne ""
			and $NMIS::systemTable{nodeModel} ne ""
			and $NMIS::systemTable{ifNumber} ne ""			
		) {
			print "\t vendor=$NMIS::systemTable{nodeVendor} model=$NMIS::systemTable{nodeModel} interfaces=$NMIS::systemTable{ifNumber}\n";
		}
	}

	#######################################################################
	# Lets do a ping to see if the device is reachable or not
	#######################################################################

	### added node dependancy check
	### added userid test - if  not root, we may have been called from the www interface, so skip the ping!!

	if ($debug) { print returnTime." Starting Pinging with timeout=$NMIS::config{ping_timeout} retries=$NMIS::config{ping_retries} packet=$NMIS::config{ping_packet}\n"; }

	if ( $< and $type eq "update" and $kernel !~ /linux/ ) { # not root and update, assume called from www interface
		$pingresult = 100;
		if ($debug) { print "\n".returnTime."!!!SKIPPING Pinging as we are NOT running with root priviliges!!!\n\n"; }
	}	
	else {
		#### new ping code as of Feb26 2004 ####
		( $ping_min, $ping_avg, $ping_max, $ping_loss) = ext_ping($runnode, $NMIS::config{ping_packet}, $NMIS::config{ping_retries}, $NMIS::config{ping_timeout} );
		$pingresult = defined $ping_min ? 100 : 0;		# ping_min is undef if unreachable.
	}	

	if ( $pingresult != 100 ) {
		# Device is down
		$ping_loss = 100;
		if ( $debug ) { print returnTime." Pinging Failed $runnode is NOT REACHABLE\n"; }
		notify(node => $runnode, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => "Node Down", details => "Ping failed");
	} else {
		# Device is UP!
		if ( $debug ) { print returnTime." $runnode is PINGABLE min/avg/max = $ping_min/$ping_avg/$ping_max ms loss=$ping_loss%\n";}
		checkEvent(node => $runnode, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => "Node Down", level => "Normal", details => "Ping failed");
	}

	#######################################################################
	# Are we supposed to collect on this node set a temp boolean for this
	#######################################################################
	if ( $collect eq "true" and $NMIS::nodeTable{$runnode}{collect} eq "true" and $pingresult == 100 ) { 
		$nodeCollect = "true"; 
	}
	else { $nodeCollect = "false"; }
	 
	#######################################################################
	# Load the system info which is kept on file if it exists otherwise create it.
	#######################################################################
	if ( -r "$NMIS::config{'<nmis_var>'}/$runnode.dat" 
		and $NMIS::nodeTable{$runnode}{collect} eq "true" 
		and $pingresult == 100 
		and $type ne "update"
	) {
## twice		loadSystemFile($runnode);
		&updateUptime($runnode, $pingresult);
	}
	elsif ( not -r "$NMIS::config{'<nmis_var>'}/$runnode.dat" ) {
		if ($debug) { print returnTime." No system file exists creating one.\n"; }
		&createSystemFile($runnode, $pingresult);
	}
	
	if ($debug>2) { &runEventDebug; }
	
	#######################################################################
	# If there is a problem talking to node with SNMP or ICMP
	#######################################################################
	if ( $snmpresult != 100 
		and $pingresult == 100 
		and $NMIS::nodeTable{$runnode}{collect} eq "true"
	) {
		if ($debug) { print returnTime." $runnode SNMP is not responding skipping to next node\n"; }
		&runReachability($runnode, $pingresult);
	}
	elsif ( $pingresult != 100 ) {
		if ($debug) { print returnTime." $runnode is down not collecting skipping to next node\n"; }
		&runReachability($runnode, $pingresult);
	}

	#######################################################################
	# No collect on Node only do Reachabillity
	#######################################################################
	elsif ( $NMIS::systemTable{supported} eq "false" 
		or $NMIS::nodeTable{$runnode}{collect} eq "false" 
	) {
		&runReachability($runnode, $pingresult);
		# run service avail even if no collect
		&runServices($runnode);
		### Cologne, store the typedraw parameters
		&writeSystemFile($runnode);
	} 
	
	#######################################################################
	# update the system table and interface table
	#######################################################################
	elsif ( $type eq "update" ) {
		&runUpdate($runnode, $pingresult);

		### dynamic CAM and connected IP address collection - uncomment to sample every update - will slow collection times.
		### bit pointless to enable as information is so dynamic - see link on summary view to snapshot this data.
		#if ( $NMIS::systemTable{nodeModel} =~ /Catalyst/i ) { &runCAM($runnode, 'false') }
	}

	#######################################################################
	# type = collect so do health interface and reachability
	#######################################################################
	### AS 8 June 2002 - Removing legacy interface and health types
	elsif ( $type eq "collect" 
		and $NMIS::nodeTable{$runnode}{collect} eq "true" 
		#and $NMIS::systemTable{supported} eq "true" 
		and $pingresult == 100 
		and $snmpresult == 100
	) {

		if ($debug) { print returnTime." $runnode running collect for interface and health and mib2ip\n"; }
		if ( $nodeCollect eq "true" ) {
			&runHealth($runnode);
			&runMib2ip($runnode);
		}
		
		&runInterface($runnode, $pingresult);
		&runReachability($runnode, $pingresult);

		# add additional collects here....
		### Andrew Sargent Modem Support
		if ( $NMIS::systemTable{InstalledModems} gt 0 ) {
			&runModem($runnode);
		}

		&runCBQoS($runnode);
		&runCalls($runnode);
		&runPVC($runnode);
		
		### server collection
		&runServer($runnode) if $NMIS::systemTable{nodeType} eq 'server';
		# run services availability monitor
		&runServices($runnode);

		### Cologne, store the typedraw parameters
		&writeSystemFile($runnode);

	} # end type eq collect
	else {
		errorQuit( "Unknown ERROR. node=$runnode type=$type nodeCollect=$nodeCollect collect=$NMIS::nodeTable{$runnode}{collect} ping=$pingresult snmp=$snmpresult supported=$NMIS::systemTable{supported}\n");
	}
} # end runNodeStats

### Andrew Sargent's Modem Enquiry
sub runModem {
	my $node = shift;
	my $session;
	my $intf;
	my $message;

	undef %snmpTable;
	
	if ($debug) { print returnTime." Starting Modem Stats\n"; }

	# OPEN the SNMP Session 
	if ( $NMIS::systemTable{snmpVer} eq "SNMPv2" ) {
		($session) = SNMPv2c_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
	}
	else {
		($session) = SNMP_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
	}
	if ( not defined($session) ) { 
		warn returnTime." runModem, Session is not Defined Goodly to $node.\n"; 
		goto END_runModem;
	}

	# Now depending on the node type do different things.

	if ( $NMIS::systemTable{nodeModel} =~ /CiscoRouter/ ) {
		# Get all the Cisco Health Stuff unless not doing collection
		if ($collect eq "true") {
			(	$snmpTable{InstalledModem},
				$snmpTable{ModemsInUse},
				$snmpTable{ModemsAvailable},
				$snmpTable{ModemsUnavailable},
				$snmpTable{ModemsOffline},
				$snmpTable{ModemsDead}	
			) = $session->snmpget(  
				'cmSystemInstalledModem'.".0",
				'cmSystemModemsInUse'.".0",
				'cmSystemModemsAvailable'.".0",
				'cmSystemModemsUnavailable'.".0",
				'cmSystemModemsOffline'.".0",		
				'cmSystemModemsDead'.".0"
			);
			if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
				logMessage( "runModem, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				goto END_runModem;
			}
			if ($debug) { 
				print returnTime." Modem Stats Summary, ";
				print "Installed=$snmpTable{InstalledModem}, InUse=$snmpTable{ModemsInUse}, Avail=$snmpTable{ModemsAvailable}, UnAvail=$snmpTable{ModemsUnavailable}, Offline=$snmpTable{ModemsOffline}, Dead=$snmpTable{ModemsDead}\n";			
				}
						
			# update RRD Database
			&updateRRDDB(type => "modem", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype});
			$NMIS::systemTable{typedraw} .= ",modem" ;
		} # collect eq true

	} # nodeModel eq CiscoRouter
	
	# Finished with the SNMP
	END_runModem:
	if (defined $session) { $session->close(); }
} # end runModem

# collect the frame PVC stats, if a frame relay exists and collect=true.
# %pvcStats is a global hash
sub runPVC {

	# quick exit if not a device supporting frame type interfaces !
	if ( $NMIS::systemTable{nodeType} ne "router" ) { return; }

	my $node = shift;
	my %interfaceTable;
	my %pvcTable;
	my $port;
	my $pvc;
	my $mibname;
	my %seen;
	my @ret;

	undef %pvcStats;		# start this new every time

	if ($debug) { print returnTime." runPVC: Starting frame relay PVC collection\n"; }

	# as we do a v2c bulkwalk, only continue if snmpv2c
	if ( $NMIS::systemTable{snmpVer} ne "SNMPv2" ) {
		if ($debug) { print "\t runPVC: $node is not SNMPv2 - PVC collection aborted\n"; }
		return;
	}

	my $interfacefile = "$NMIS::config{'<nmis_var>'}/$node-interface.dat";
	if ( -r $interfacefile ) {
		if ( !(%interfaceTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-interface.dat","ifIndex","\t")) ) {
			if ($debug) { print "\t runPVC: could not find or read $node-interface.dat - PVC collection aborted\n"; }
			return;
		}
	if ($debug) { print "\t runPVC: Loaded the Interface File with $NMIS::systemTable{ifNumber} entries\n"; }
	}
	# double check if any frame relay interfaces on this node.
	# cycle thru each ifindex and check the ifType, and save the ifIndex for matching later
	# only collect on interfaces that are defined, with collection turned on globally
	# and for that interface and that are Admin UP
	foreach ( keys %interfaceTable ) {
		if ( $interfaceTable{$_}{ifType} =~ /framerelay/i
			and $collect eq "true"
			and $interfaceTable{$_}{ifAdminStatus} eq "up" and 
			$interfaceTable{$_}{collect} eq "true"
		) {
			$seen{$_} = $_;
			if ( $NMIS::systemTable{"typedraw$_"} !~ /pvc/ ) { $NMIS::systemTable{"typedraw$_"} .= ",pvc"; }
		}
	}
	if ( ! %seen ) {	# empty hash
		if ($debug) { print "\t runPVC: $node does not have any frame ports or no collect or port down - PVC collection aborted\n"; }
		return;
	}

	# should now be good to go....
	# this uses the snmp tablewalk forced to v2c getbulk in SNMP_utils.pm, from SNMP_Session
	# only use the Cisco private mib for cisco routers

	# add in the walk root for the cisco interface table entry for pvc to intf mapping
	&snmpmapOID("cfrExtCircuitIfName", "1.3.6.1.4.1.9.9.49.1.2.2.1.1");

	# snmpwalk(community@host:port:timeout:retries:backoff:version, OID, [OID...])
	# 'default_max_repetitions' => 10 # set the number of responses bulked into a packet.
	# no retries here. set timeout to 3 - could take this to conf variable sometime.

	my $host = "$NMIS::nodeTable{$node}{community}\@$node:$NMIS::nodeTable{$node}{snmpport}:3:1:1:2c";

	@ret = &snmpwalk( $host, { 'default_max_repetitions' => 14 }, 'frCircuitEntry' );
	if ( ! $ret[0] ) {
		if ($debug) { print "\t runPVC: snmpwalk on $node:frCircuitEntry did not answer or SNMPv2 problem or no PVC found - PVC collection aborted\n"; }
	}
	else {
		foreach my $desc ( @ret ) {
			my ($inst, $value) = split /:/, $desc, 2 ;
			my ($oid, $port, $pvc) = split /\./, $inst, 3 ;
			my $textoid = SNMP_MIB::oid2name("1.3.6.1.2.1.10.32.2.1.$oid");
			$pvcStats{$port}{$pvc}{$textoid} = $value;
		}

		if ( $NMIS::systemTable{nodeModel} =~ /CiscoRouter/ ) {
			# only get this for CiscoRouters
			@ret = &snmpwalk( $host, { 'default_max_repetitions' => 4 }, 'cfrExtCircuitIfName' );
			if ( ! $ret[0] ) {
				if ($debug) { print "\t runPVC: snmpwalk on $node:cfrExtCircuitIfName did not answer or SNMPv2 problem or no PVC found - PVC collection aborted\n"; }
			}
			else {
				# put into a hash
				foreach my $desc ( @ret ) {
					my ($inst, $value) = split /:/, $desc, 2 ;
					my ($port, $pvc ) = split /\./, $inst, 2 ;
					$pvcStats{$port}{$pvc}{'cfrExtCircuitIfName'} = $value;
				}
			}
		}
	}
	# we now have a hash of port:pvc:mibname=value - or an empty hash if no reply....
	# put away to a rrd.
	# Check if the RRD Database exists already if not create it
	# rrd file = database/interface/nodetype/node/node-pvc-$port-$pvc.rrd

	foreach $port ( keys %pvcStats ) {

		# check if parent port was seen before and OK to collect on.
		if ( !exists $seen{$port} ) {
			if ($debug) { print "\t runPVC: snmp frame port $port is not collected or down - skipping\n"; }
			next;
		}

		foreach $pvc ( keys %{ $pvcStats{$port} } ) {
			
			if ( &createRRDDB(type => "pvc", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype}, extName => "$port-$pvc" ) ) {

				# massage some values
				# frCircuitState = 2 for active
				# could set an alarm here on PVC down ?? 
				if ( $pvcStats{$port}{$pvc}{frCircuitState} eq 2 ) {
					$pvcStats{$port}{$pvc}{frCircuitState} = 100;
				}
				else {
					$pvcStats{$port}{$pvc}{frCircuitState} = 0;
				}
				&updateRRDDB(type => "pvc", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype}, extName => "$port-$pvc");
			}
		}
	}		

	# save a list of PVC numbers to an interface style dat file, with ifindex mappings, so we can use this to read and graph the rrd via the web ui.
	# save the cisco interface ifDescr if we have it.
	foreach $port ( keys %pvcStats ) {
		foreach $pvc ( keys %{ $pvcStats{$port} } ) {
			my $key = "$port-$pvc";
			$pvcTable{$key}{subifDescr} = rmBadChars($pvcStats{$port}{$pvc}{cfrExtCircuitIfName});		# if not cisco, will not exist.
			$pvcTable{$key}{pvc} = $pvc;
			$pvcTable{$key}{port} = $port;			# should be ifIndex of parent frame relay interface
			$pvcTable{$key}{LastTimeChange} = $pvcStats{$port}{$pvc}{frCircuitLastTimeChange};
			$pvcTable{$key}{rrd} = $key;		# save this for filename lookups
			$pvcTable{$key}{CIR} = $pvcStats{$port}{$pvc}{frCircuitCommittedBurst};
			$pvcTable{$key}{EIR} = $pvcStats{$port}{$pvc}{frCircuitExcessBurst};
			$pvcTable{$key}{subifIndex} = $pvcStats{$port}{$pvc}{frCircuitLogicalIfIndex}; # non-cisco may support this - to be verified.
		}
	}
	if ( %pvcTable) {
		# pvcTable has some values, so write it out
		&writeCSV(%pvcTable,"$NMIS::config{'<nmis_var>'}/$node-pvc.dat","\t");
		if ($debug) { print "\t runPVC: writing pvc interface file $NMIS::config{'<nmis_var>'}/$node-pvc.dat\n"; }
	}	
}
# get some server stats.
sub runServer {

	my $node = shift;
	my %stats;
	my $timeout = 3;
	my $snmpcmd;
	my @ret;
	my $var;
	my $i;
	my %services;
	my $key;
	my $write=0;

	undef %snmpTable;	# this is a global.

	my @snmpvars = qw( hrSystem hrStorage hrDevice );

	if ($debug) { print returnTime." runServer: Starting server stats collection\n"; }

	# snmpwalk(community@host:port:timeout:retries:backoff:version, OID, [OID...])
	# no retries here.
	if ( $NMIS::systemTable{snmpVer} eq "SNMPv1" ) {
		$snmpcmd = "$NMIS::nodeTable{$node}{community}\@$node:$NMIS::nodeTable{$node}{snmpport}:$timeout:1:1:1"
	}
	else {
		$snmpcmd = "$NMIS::nodeTable{$node}{community}\@$node:$NMIS::nodeTable{$node}{snmpport}:$timeout:1:1:2"
	}

	# 'default_max_repetitions' => 10 # set the number of responses bulked into a packet.
	foreach $var ( @snmpvars ) {
		undef @ret;
		@ret = &snmpwalk( $snmpcmd, { 'default_max_repetitions' => 14 }, SNMP_MIB::name2oid($var) );
		if ( ! $ret[0] ) {
			if ($debug) { print "\t runServer: snmpwalk on $node:$var did not answer - Server collection aborted\n"; }
			last;	
		}
		else {
			$write=1;
			foreach ( @ret ) {
				my ($inst, $value) = split /:/, $_, 2 ;
				my $textoid = SNMP_MIB::oid2name(SNMP_MIB::name2oid($var).".".$inst);
				if ( $textoid =~ /date\./i ) { $value = snmp2date($value) }
				( $textoid, $inst ) = split /\./, $textoid, 2;
				$snmpTable{$textoid}{$inst} = $value;
			}
		}
	} #end foreach

	### KS 3 Jan 03 - Moved this if/elsif block out of the foreach loop
	# add some additional windows stuff in here...
	### KS 2 Jan 03 - Using model here in place of vendor
	if ( $NMIS::systemTable{nodeModel} =~ /Windows/ ) {
		( 	$snmpTable{AvailableBytes},
			$snmpTable{CommittedBytes},
			$snmpTable{PagesPerSec},
			$snmpTable{ProcessorTime},
			$snmpTable{UserTime},
			$snmpTable{InterruptsPerSec} )
		 = &snmpget( $snmpcmd,
			'1.3.6.1.4.1.311.1.1.3.1.1.1.1.0',
			'1.3.6.1.4.1.311.1.1.3.1.1.1.2.0',
			'1.3.6.1.4.1.311.1.1.3.1.1.1.9.0',
			'1.3.6.1.4.1.311.1.1.3.1.1.2.1.3.0',
			'1.3.6.1.4.1.311.1.1.3.1.1.2.1.4.0',
			'1.3.6.1.4.1.311.1.1.3.1.1.2.1.6.0' );
	}
	# add some additional net-snmp stuff in here...
	# net-snmp mibs will report sysobject as 'net-snmp'
	# net-snmp 5min loadaverage.
	elsif ( $NMIS::systemTable{nodeVendor} =~ /net-snmp/i or $NMIS::systemTable{nodeModel} =~ /FreeBSD/i) {
		( 	$snmpTable{laLoad5} )
		 = &snmpget( $snmpcmd,
			'1.3.6.1.4.1.2021.10.1.3.2' );

	}
	
	# we now have a big hash of everything we asked for - lets save it away
	if ( $write ) {
		### KS 2 Jan 03 - Using model here in place of vendor
		if ( $NMIS::systemTable{nodeModel} =~ /Windows/ ) {
			# System type stuff, Users, processes, memory
			# *** hrNumUsers:hrProcesses:AvailableBytes:CommittedBytes:PagesPerSec:ProcessorTime:UserTime:InterruptsPerSec already in table***
			# 
			&updateRRDDB(type => "hrWin", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype}, extName => "hrwin");
		}	
		# partially duplicating the above match
		# in the long run, hrwin will be just a special sub-case of hr
		# windows 2000 seems not to support hrStorageRam; investigating.
		if ( $NMIS::systemTable{nodeVendor} !~ /icrosoft/ or $NMIS::systemTable{nodeModel} =~ /Windows2003/)  {
			# System type stuff, Users, processes, fixed and virtual memory
			# *** hrNumUsers:hrProcesses:laLoad5 already in table***
			foreach $var ( keys %{ $snmpTable{hrStorageType} } ) {
				# use a dummy var here.
				if ( $snmpTable{hrStorageType}{$var} eq '1.3.6.1.2.1.25.2.1.2' ) { # hrStorageRam
					$snmpTable{hrMemSize} = $snmpTable{hrStorageAllocationUnits}{$var} * $snmpTable{hrStorageSize}{$var};
					$snmpTable{hrMemUsed} = $snmpTable{hrStorageAllocationUnits}{$var} * $snmpTable{hrStorageUsed}{$var};
				}
				if ( $snmpTable{hrStorageType}{$var} eq '1.3.6.1.2.1.25.2.1.3' ) { # hrStorageVirtualMemory
					$snmpTable{hrVMemSize} = $snmpTable{hrStorageAllocationUnits}{$var} * $snmpTable{hrStorageSize}{$var};
					$snmpTable{hrVMemUsed} = $snmpTable{hrStorageAllocationUnits}{$var} * $snmpTable{hrStorageUsed}{$var};
				}
			}
			&updateRRDDB(type => "hr", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype}, extName => "hr");
		}

		# CPU 1-x maximum 32 for now.
		# this check is performed only on well behaved SNMP hrProcessorTable implementation (at this time, only win 200x)
		if ($NMIS::systemTable{nodeModel} =~ /Windows200/ )  { 
			$i = 0;
			foreach $var ( keys %{ $snmpTable{hrDeviceType} } ) {
				# use a dummy var here.
				next unless $snmpTable{hrDeviceType}{$var} eq '1.3.6.1.2.1.25.3.1.3'; # hrDeviceProcessor
				$i++;
				$snmpTable{hrCpuLoad} = $snmpTable{hrProcessorLoad}{$var};
				&updateRRDDB(type => "hrsmpcpu", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype}, extName => "hrsmpcpu$i");
			$NMIS::systemTable{hrNumCPU} = $i;                     # save a counter so we know how many rrd files to display later....
			last if $i >= 31; # failsafe counter
			}
		}

		# disk 1-x maximum 20 for now.
		$i = 0;
		foreach $var ( keys %{ $snmpTable{hrStorageType} } ) {
			# use a dummy var here.
			next unless $snmpTable{hrStorageType}{$var} eq '1.3.6.1.2.1.25.2.1.4'; # hrStorageFixedDisk
			next unless $snmpTable{hrStorageSize}{$var} > 0;		# skip 0 length disks.
			$i++;
			$snmpTable{hrDiskSize} = $snmpTable{hrStorageAllocationUnits}{$var} * $snmpTable{hrStorageSize}{$var};
			$snmpTable{hrDiskUsed} = $snmpTable{hrStorageAllocationUnits}{$var} * $snmpTable{hrStorageUsed}{$var};
			&updateRRDDB(type => "hrDisk", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype}, extName => "hrdisk$i");
			#
			$NMIS::systemTable{'hrDiskLabel'.$i} = $snmpTable{hrStorageDescr}{$var};	# save a label here for display later....
			$NMIS::systemTable{'hrDiskLabel'.$i} =~ s/,/ /g;						# lose any commas.
			$NMIS::systemTable{hrNumDisk} = $i; 			# save a counter so we know how many rrd files to display later....
			last if $i >= 19; # failsafe counter
		}

		# and update the system file !!!
		writeSystemFile( $node );

	} #ifwrite

	# convert date value to readable string
	sub snmp2date {
		my @tt = unpack("C*", shift );
		return eval((@tt[0] *256) + @tt[1]) . "-" . @tt[2] . "-" . @tt[3] . "," . @tt[4] . ":" . @tt[5] . ":" . @tt[6] . "." . @tt[7];
	}
}

sub runServices {

	my $node = shift;
	my $service;
	my %scripts;
	my $ret;
	my $msg;
	my $servicePoll = 0;
	my %services;		# hash to hold snmp gathered service status.

	%scripts = loadCSV($NMIS::config{Services_Table},$NMIS::config{Services_Key},"\t");
	# services to be polled are saved in a list
	foreach $service ( split /,/ , lc($NMIS::nodeTable{$node}{services}) ) {
		# check for invalid service table
		next if $service =~ /n\/a/i;
		next if $scripts{$service}{Service_Type} =~ /n\/a/i;
		next if $service eq '';
		if ($debug) { print returnTime." runServices: Checking $scripts{$service}{Service_Type} $scripts{$service}{Name} $scripts{$service}{Service_Name}\n"; }

		# clear global hash each time around as this is used to pass results to rrd update
		undef %snmpTable;
		$ret = 0;

		# DNS gets treated simply ! just lookup our own domain name.
		if ( $scripts{$service}{Service_Type} eq "dns" ) {

			my $res;
			my $packet;
			my $rr;

			# resolve $node to an IP address first so Net::DNS points at the remote server
			if ( my $packed_ip = inet_aton($node)) {
				my $ip = inet_ntoa($packed_ip);

				use Net::DNS;
				$res = Net::DNS::Resolver->new;
					$res->nameservers($ip);
					$res->recurse(0);
					$res->retry(2);
					$res->usevc(0);			# force to udp (default)
					$res->debug(1) if $debug >3;			# set this to 1 for debug

				if ( !$@ ) {
					$packet = $res->query($node);		# lookup its own nodename on itself, should always work..?
					if (!$packet) {
						$ret = 0;
						print "\t Failed: Unable to lookup data for $node from $ip\[$node\]\n" if $debug;
					}
					else {
						# stores the last RR we receive
						foreach $rr ($packet->answer) {
							$ret = 1;
							my $tmp = $rr->address;
							print "\t Success: RR data for $node from $ip\[$node\] was $tmp\n" if $debug;
						}
					}
				}
				else {
					print "\t Failed: Net::DNS error $@\n" if $debug >3;
					$ret = 0;
				}
			} else { print "\t Failed: Could not resolve $node to ip\n" if $debug; }
		} # end DNS

		# now the 'port' 
		elsif ( $scripts{$service}{Service_Type} eq "port" ) {
			$msg = '';
			my $nmap;
			
			my ( $scan, $port) = split ':' , $scripts{$service}{Port};
		
			if ( $scan =~ /udp/ ) {
				$nmap = "nmap -sU --host_timeout 3000 -p $port -oG -  $node";
			}
			else {
				$nmap = "nmap -sT --host_timeout 3000 -p $port -oG -  $node";
			}
			# now run it, need to use the open() syntax here, else we may not get the response in a multithread env.
			unless ( open(NMAP, "$nmap 2>&1 |")) {
				print STDERR "\t runServices: FATAL: Can't open nmap: $!\n";
			}
			while (<NMAP>) {
				$msg .= $_;
			}
			close(NMAP);

			if ( $msg =~ /Ports: $port\/open/ ) {
				$ret = 1;
				print "\t Success: $msg\n" if $debug >3;
			}
			else {
				$ret = 0;
				print "\t Failed: $msg\n" if $debug >3;
			}
		}
		# now the services !
		elsif ( $scripts{$service}{Service_Type} eq "service" and $NMIS::nodeTable{$node}{devicetype} eq 'server') {

			if ( ! $servicePoll ) {
				
				my $timeout = 3;
				my $snmpcmd;
				my @ret;
				my $var;
				my $i;
				my $key;
				my $write=0;

				$servicePoll = 1;	# set flag so snmpwalk happens only once.

				my @snmpvars = qw( hrSWRunName hrSWRunStatus );

				# snmpwalk(community@host:port:timeout:retries:backoff:version, OID, [OID...])
				# no retries here.
				if ( $NMIS::systemTable{snmpVer} eq "SNMPv1" ) {
					$snmpcmd = "$NMIS::nodeTable{$node}{community}\@$node:$NMIS::nodeTable{$node}{snmpport}:$timeout:1:1:1"
				}
				else {
					$snmpcmd = "$NMIS::nodeTable{$node}{community}\@$node:$NMIS::nodeTable{$node}{snmpport}:$timeout:1:1:2"
				}

				# 'default_max_repetitions' => 10 # set the number of responses bulked into a packet.
				foreach $var ( @snmpvars ) {
					undef @ret;
					@ret = &snmpwalk( $snmpcmd, { 'default_max_repetitions' => 14 }, SNMP_MIB::name2oid($var) );
					if ( ! $ret[0] ) {
						if ($debug) { print "\t runServices: snmpwalk on $node:$var did not answer - Services collection aborted\n"; }
						last;	
					}
					else {
						foreach ( @ret ) {
							my ($inst, $value) = split /:/, $_, 2 ;
							my $textoid = SNMP_MIB::oid2name(SNMP_MIB::name2oid($var).".".$inst);
							if ( $textoid =~ /date\./i ) { $value = snmp2date($value) }
							( $textoid, $inst ) = split /\./, $textoid, 2;
							$snmpTable{$textoid}{$inst} = $value;
						}
					}
				} #end foreach

				foreach (sort keys %{ $snmpTable{hrSWRunName} } ) {
					# key services by name_pid
					$key = $snmpTable{hrSWRunName}{$_}.':'.$_;
					$services{$key}{hrSWRunName} = $key;
					$services{$key}{hrSWRunType} = ( '', 'unknown', 'operatingSystem', 'deviceDriver', 'application' )[$snmpTable{hrSWRunType}{$_}];
					$services{$key}{hrSWRunStatus} = ( '', 'running', 'runnable', 'notRunnable', 'invalid' )[$snmpTable{hrSWRunStatus}{$_}];

					if ( $debug >3) {	print "\t\t $services{$key}{hrSWRunName} status=$services{$key}{hrSWRunStatus}\n"; }
				}

			} #servicePoll
			
			# lets check the service status
			# NB - may have multiple services with same name on box.
			# so keep looking if up, last if one down
			# look for an exact match here on service name as read from snmp poll

			foreach ( sort keys %services ) {
				my ($svc) = split ':', $services{$_}{hrSWRunName};
				if ( $svc eq $scripts{$service}{Service_Name} ) {
					if ( $services{$_}{hrSWRunStatus} =~ /running|runnable/i ) {
						$ret = 1;
						print "\t service $scripts{$service}{Name} is up, status is $services{$_}{hrSWRunStatus}\n" if $debug >3;
					}
					else {
						$ret = 0;
						print "\t service $scripts{$service}{Name} is down, status is $services{$_}{hrSWRunStatus}\n" if $debug >3;
						last;
					}
				}					
			}
		}	
		# now the scripts !
		elsif ( $scripts{$service}{Service_Type} eq "script" ) {

			# lets do the user defined scripts
			# ($ret,$msg) = &sapi($ip,$port,$script,$ScriptTimeout);

			($ret,$msg) = &sapi($node,$scripts{$service}{Port},"$NMIS::config{script_root}/$service",3);
			print "\t Results: $msg\n" if $debug >3;
		}
		else {
			# no service type found

			$ret = 0;
			$msg = '';
			next;			# just do the next one - no alarms
		}

		# lets raise or clear an event 
		if ( $ret ) {
			# Service is UP!
			print "\t $scripts{$service}{Service_Type} $scripts{$service}{Name} is available\n" if $debug;
			checkEvent(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => "Service Down", level => "Normal", details => $scripts{$service}{Name} );
		} else {
			# Service is down
			print "\t $scripts{$service}{Service_Type} $scripts{$service}{Name} is unavailable\n" if $debug;
			notify(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => "Service Down", details => $scripts{$service}{Name} );
		}

		# save result for availability history - one file per service per node
		$snmpTable{service} = $ret*100;
		updateRRDDB(type => "service", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype}, extName => lc($scripts{$service}{Name}) );
	} # foreach
}

sub runInterface {
	my $node = shift;
	my $session;
	my $snmpError;
	my $message;
	my $intf;
	my %interfaceTable;
	my $createdone = "false";
	my $int_type;
	my $create1;
	my $create2;
	
	my $interfacefile = "$NMIS::config{'<nmis_var>'}/$node-interface.dat";
	
	if ( $NMIS::systemTable{snmpVer} eq "SNMPv2" ) {
		($session) = SNMPv2c_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
	}
	else {
		($session) = SNMP_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
	}
	if ( not defined($session) ) { 
		warn returnTime." runInterface, Session is not Defined Goodly to $node.\n"; 
		goto END_runInterface;
	}
	
	# See if an interface definition file exists
	if ( -r $interfacefile ) {
		#Interface file exists load the definitions
	
		if ($debug) { print returnTime." Loading the Interface File with $NMIS::systemTable{ifNumber} entries\n"; }
		%interfaceTable = &loadCSV($interfacefile,"ifIndex","\t");
	
		# This bit makes sure that the device wasn't down the last time it refreshed its interface files
		if ( not defined %interfaceTable ) {
			$message = "$node, interface file empty regenerating: $interfacefile";
			logMessage("runInterface, $message");
		    if ($debug) { print returnTime." $message\n"; }
			&createInterfaceFile($node); 
			%interfaceTable = &loadCSV($interfacefile,"ifIndex","\t");
		}
	}
	else {
		# Interface file does not exist or we can't read it better create it better not be owned by someone else
		&createInterfaceFile($node); 

		# if not a valid model or snmp down, interface file still may not exist.
		if ( -e $interfacefile ) {
			%interfaceTable = &loadCSV($interfacefile,"ifIndex","\t");
		}
		else {
			if ( $debug) { print "\t File $interfacefile not created - skipping Interface\n"; }
		}
	}
	
	# Start a loop which go through the interface table

	### AS 9/4/01 Various changes to handle interfaces which get shutdown
	## during the day.
	
	#for ( $index = 1; $index <= $#interfaceTable; ++$index ) {
	# it would be nice to do some parallell interface processing here ie snmp 2 or 3 interfaces each hit.
	foreach $intf ( sort {$a <=> $b} keys %interfaceTable ) {
		# only collect on interfaces that are defined, with collection turned on globally
		# and for that interface and that are Admin UP
		if (    $collect eq "true" and 
			$interfaceTable{$intf}{ifAdminStatus} eq "up" and 
			$interfaceTable{$intf}{collect} eq "true"
			#and ( $NMIS::config{bad_interfaces} !~ /$interfaceTable{$intf}{Description}/ )
		) {
			undef %ifStats;

			# Check if the RRD Database exists already if not create it
			# set the database name to be the stats directory with the router name 
			# and the interface name which should have been passed in by runstats
			$create1 = &createRRDDB(type => "interface", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype}, extName => $interfaceTable{$intf}{ifDescr}, ifType => $interfaceTable{$intf}{ifType}, ifIndex => $interfaceTable{$intf}{ifIndex}, ifSpeed => $interfaceTable{$intf}{ifSpeed});

			### ehg 18 sep 2002 need models.csv config switch for MIBII support here - fudge it for now.
			if ( $interfaceTable{$intf}{ifType} =~ /$qr_int_stats/i 
					# also flagged later in summary stats call
					and $NMIS::systemTable{nodeType} =~ /router|switch/ 	# exclude server and generic for now - need MIB-II switch here !
					and $NMIS::systemTable{nodeModel} !~ /SSII 3Com|generic|PIX|MIB2/i 		# and exclude PIX and 3Com as well - should handle with models.csv MIBII switch
				) {
				$int_type="full";
				$create2 = &createRRDDB(type => "pkts", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype}, extName => $interfaceTable{$intf}{ifDescr}, ifType => $interfaceTable{$intf}{ifType}, ifIndex => $interfaceTable{$intf}{ifIndex}, ifSpeed => $interfaceTable{$intf}{ifSpeed});
			} else {
				$int_type="less";
				$create2 = 1;
			}
			if ( $create1 and $create2 ) {

				# Handle the HC counters for devices which support them.
				# use systemName to select devices
				my $ifInOctets = 'ifInOctets';
				my $ifOutOctets = 'ifOutOctets';
				my $ifInUcastPkts = 'ifInUcastPkts';
				my $ifOutUcastPkts = 'ifOutUcastPkts';
				if ( $NMIS::systemTable{snmpVer} eq "SNMPv2" 
					and $NMIS::systemTable{sysObjectName} =~ /$qr_hc_model/i
					and $interfaceTable{$intf}{ifSpeed} > 10000000
				) {
					$ifInOctets = 'ifHCInOctets';
					$ifOutOctets = 'ifHCOutOctets';
					$ifInUcastPkts = 'ifHCInUcastPkts';
					$ifOutUcastPkts = 'ifHCOutUcastPkts';
					# lets confirm with a message that we are polling HC counters
					if ($debug) { print "\tPolling HC Counters for index $interfaceTable{$intf}{ifIndex} on $NMIS::systemTable{sysObjectName}\n"; }

				}
				if ( $int_type eq "full"	) {
					# full MIB-II ifTable interface group
					(	$ifStats{ifDescr},
						$ifStats{ifOperStatus},
						$ifStats{ifAdminStatus},
						$ifStats{ifInOctets},
						$ifStats{ifInUcastPkts},
						$ifStats{ifInNUcastPkts},
						$ifStats{ifInDiscards},
						$ifStats{ifInErrors},
						$ifStats{ifOutOctets},
						$ifStats{ifOutUcastPkts},
						$ifStats{ifOutNUcastPkts},
						$ifStats{ifOutDiscards},
						$ifStats{ifOutErrors}
					) = $session->snmpget(  
						'ifDescr'.".$interfaceTable{$intf}{ifIndex}",
						'ifOperStatus'.".$interfaceTable{$intf}{ifIndex}",
						'ifAdminStatus'.".$interfaceTable{$intf}{ifIndex}",
						$ifInOctets.".$interfaceTable{$intf}{ifIndex}",
						$ifInUcastPkts.".$interfaceTable{$intf}{ifIndex}",
						'ifInNUcastPkts'.".$interfaceTable{$intf}{ifIndex}",
						'ifInDiscards'.".$interfaceTable{$intf}{ifIndex}",
						'ifInErrors'.".$interfaceTable{$intf}{ifIndex}",
						$ifOutOctets.".$interfaceTable{$intf}{ifIndex}",
						$ifOutUcastPkts.".$interfaceTable{$intf}{ifIndex}",
						'ifOutNUcastPkts'.".$interfaceTable{$intf}{ifIndex}",
						'ifOutDiscards'.".$interfaceTable{$intf}{ifIndex}",
						'ifOutErrors'.".$interfaceTable{$intf}{ifIndex}"
					);
				} else {	
					# less -
					(	$ifStats{ifDescr},
						$ifStats{ifOperStatus},
						$ifStats{ifAdminStatus},
						$ifStats{ifInOctets},
						$ifStats{ifOutOctets}
					) = $session->snmpget(  
						'ifDescr'.".$interfaceTable{$intf}{ifIndex}",
						'ifOperStatus'.".$interfaceTable{$intf}{ifIndex}",
						'ifAdminStatus'.".$interfaceTable{$intf}{ifIndex}",
						$ifInOctets.".$interfaceTable{$intf}{ifIndex}",
						$ifOutOctets.".$interfaceTable{$intf}{ifIndex}"
					);				
				}

				if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
					logMessage( "runInterface, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
					$SNMP_Simple::errmsg = "";
					goto END_runInterface;
				}
				$ifStats{ifDescr} = rmBadChars($ifStats{ifDescr});

				# add ifIndex number to ifDescr to differentiate interfaces for devices that do not have unique ifDescr.
				if ( $NMIS::systemTable{sysObjectName} =~ /$NMIS::config{int_extend}/  ) {
					$ifStats{ifDescr} = $ifStats{ifDescr} . "$interfaceTable{$intf}{ifIndex}";
				}

				if ($debug) { print returnTime." Interface: $interfaceTable{$intf}{ifDescr}: type=$int_type, ifIndex=$interfaceTable{$intf}{ifIndex}, OperStatus=$ifStats{ifOperStatus}, ifAdminStatus=$interfaceTable{$intf}{ifAdminStatus}, Interface Collect=$interfaceTable{$intf}{collect}\n"; }

				if  ( $ifStats{ifInOctets} eq "" and $ifStats{ifOutOctets} eq "" ) {
					$message = "$node, interface $interfaceTable{$intf}{ifDescr} ifIn and Out Octets are blank; maybe be an interface which does not collect stats or bad SNMP configuration or access control on the router";
					logMessage("runInterface, $message");
					if ($debug) { print returnTime." $message\n"; }
					$snmpError = "true";
				}
				else {
					$snmpError = "false";
				}
		
				if ($debug) { 
					print "\t $interfaceTable{$intf}{ifDescr} Stats:";
					for $index ( sort keys %ifStats ) {
						print " $index=$ifStats{$index}";
					}
					print "\n";
				}
			


				### AS 17 Mar 02 - Request James Norris, Optionally include interface description in messages.
				my $int_desc ;
				if ( defined $interfaceTable{$intf}{Description}
					and $interfaceTable{$intf}{Description} ne "null"
					and $NMIS::config{send_description} eq "true"
				) {
					$int_desc = " description=$interfaceTable{$intf}{Description}";
				}
				
				if ( $snmpError eq "false" ) {
					# Now Compare Real Admin Status to old Admin Status if different Log
					# Interface is admin down but was up
					if ( 	( 	$ifStats{ifOperStatus} == 2 
								and $ifStats{ifAdminStatus} == 2 
								and $interfaceTable{$intf}{ifAdminStatus} eq "up" 
						) or (
								# Interface is now up, was admin down
								$ifStats{ifOperStatus} == 1 
								and $interfaceTable{$intf}{ifAdminStatus} eq "down" 
						)
					) {
						# This interface has changed admin state, so recreate the interface file.
						if ($debug) { print "\t Creating an Interface file as $interfaceTable{$intf}{ifDescr} has changed ifAdminStatus.\n"; }
						# Reload the interface config won't get that one right but should get the next one right
						logEvent("$node", "Interface ".$interfaceStatus[$ifStats{ifAdminStatus}], "Warning", "$interfaceTable{$intf}{ifDescr} has changed ifAdminStatus, was $interfaceTable{$intf}{ifAdminStatus}, now $interfaceStatus[$ifStats{ifAdminStatus}]"); 
						if ( $createdone eq "false" ) {
							&createInterfaceFile($node); 
							$createdone = "true";
						}
						# if now up, check and clear any outstanding events.
						if ( $ifStats{ifOperStatus} == 1 ) {
							checkEvent(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => "Interface Down", level => "Normal", details => "interface=$interfaceTable{$intf}{ifDescr}$int_desc");
						}
						# could also perform a notify here if you wanted to.
					}
					# now down, was up ! dormant also a valid state
					elsif ( $ifStats{ifOperStatus} != 1 
							and	$ifStats{ifOperStatus} != 5
							and $interfaceTable{$intf}{ifAdminStatus} eq "up" ) {
						# ignore up/down events for these interfaces.
						if ( 	$interfaceTable{$intf}{ifDescr} !~ /$qr_ignore_up_down_ifDescr/i and
							$interfaceTable{$intf}{ifType} !~ /$qr_ignore_up_down_ifType/i
						) {
							notify(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => "Interface Down", details =>"interface=$interfaceTable{$intf}{ifDescr}$int_desc");
						}
					}
					# must be up !
					else {
						# Check if interface was down before
						checkEvent(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => "Interface Down", level => "Normal", details => "interface=$interfaceTable{$intf}{ifDescr}$int_desc");
					}
				
					# If new ifDescr is different from old ifDescr and its a cisco router
					# run createInterfaceFile and loadInterfaceFile and everything is back to date.
					# this handles auto discovery etc on the fly. 
					### AS 1 Apr 02 - Integrating Phil Reilly's Nortel changes
					if (    $NMIS::systemTable{nodeModel} !~ /Catalyst|Accelar|BayStack|FoundrySwitch|Riverstone/ and 
						$ifStats{ifDescr} ne $interfaceTable{$intf}{ifDescr} and 
						$ifStats{ifDescr} ne "" 
					) {
						if ($debug) { print "Creating an Interface file\n"; }
						# Reload the interface config won't get that one right but should get the next one right
						logMessage("runInterface, $node, ifIndex to ifDescr has Changed bad updating Interface File"); 
						&createInterfaceFile($node); 
						undef %interfaceTable;
						%interfaceTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-interface.dat","interface","\t");
	
						# Maybe issue and alert for reboot and possibly other bad things like config change etc
					}

					# RRD Database Exists so update it
					&updateRRDDB(type => "interface", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype}, extName => $interfaceTable{$intf}{ifDescr}, ifType => $interfaceTable{$intf}{ifType}, ifIndex => $interfaceTable{$intf}{ifIndex}, ifSpeed => $interfaceTable{$intf}{ifSpeed});
					if ( $NMIS::systemTable{"typedraw$intf"} !~ /bits/ ) { $NMIS::systemTable{"typedraw$intf"} .= ",bits,abits,mbits,util,autil"; }
					if ( $int_type eq "full" ) {
						&updateRRDDB(type => "pkts", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype}, extName => $interfaceTable{$intf}{ifDescr}, ifType => $interfaceTable{$intf}{ifType}, ifIndex => $interfaceTable{$intf}{ifIndex}, ifSpeed => $interfaceTable{$intf}{ifSpeed});
						if ( $NMIS::systemTable{"typedraw$intf"} !~ /pkts/ ) { $NMIS::systemTable{"typedraw$intf"} .= ",pkts,epkts"; }
					}
				}
			} # create true!
		} # collect eq true
		else {
			#if ($debug) { print returnTime." NOT Interface:  $interfaceTable{$intf}{ifDescr}: ifAdminStatus=$interfaceTable{$intf}{ifAdminStatus}, Interface Collect=$interfaceTable{$intf}{collect}\n"; }
			if ($debug) { print returnTime." NOT Interface: $interfaceTable{$intf}{ifDescr}: type=$int_type, ifIndex=$interfaceTable{$intf}{ifIndex}, OperStatus=$ifStats{ifOperStatus}, ifAdminStatus=$interfaceTable{$intf}{ifAdminStatus}, Interface Collect=$interfaceTable{$intf}{collect}\n"; }

		}
	        END_runInterface:
	} # FOR LOOP
	# Finished with the SNMP
	if (defined $session) { $session->close(); }
	if ($debug) { print returnTime." Finished getting Interface stats\n"; }
} # runInterface

###
### Class Based Qos handling
### written by Cologne
###
sub runCBQoS {
	my $node = shift;
	my $session;
	my $snmpError;
	my %interfaceTable;

	
	if ($NMIS::config{CBQoS_collect} eq "true" and $NMIS::systemTable{nodeModel} =~ /CiscoRouter/) {

		if (not exists $NMIS::nodeTable{$node}{cbqos}) {
			&addColumn("Nodes","cbqos","false");
			loadNodeDetails; # reload with new column
			return;
		} else {
			if ($NMIS::nodeTable{$node}{cbqos} !~ /true|input|output|both/) {
				print returnTime." CBQoS: no collect for node $node\n" if $debug;
				return;
			}
		}

		print returnTime." CBQoS: Start collect for node $node\n" if ($debug);
		if ( $NMIS::systemTable{snmpVer} eq "SNMPv2" ) {
			($session) = SNMPv2c_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
		}
		else {
			($session) = SNMP_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
		}
		if ( not defined($session) ) { 
			warn returnTime." CBQoS: Session is not Defined Goodly to $node.\n"; 
			return;
		}

		my $interfacefile = "$NMIS::config{'<nmis_var>'}/$node-interface.dat";
		if ( -r $interfacefile ) {
			#Interface file exists load the definitions
			%interfaceTable = &loadCSV($interfacefile,"ifIndex","\t");
		} else { warn returnTime." CBQoS: error loading interface values\n"; return; }

		## oke,lets go

		if (!runCBQoSdata($session,$node,\%interfaceTable)) {
			&runCBQoSwalk($session,$node,\%interfaceTable); # get indexes
			&runCBQoSdata($session,$node,\%interfaceTable); # get data
		}

		print returnTime." CBQoS: Finished\n" if ($debug); 
	}

	# Finished with the SNMP
	if (defined $session) { $session->close(); }

	return;

#===
	sub runCBQoSdata {
		my $session = shift;
		my $node = shift;
		my $interfaceTable = shift;

		my %qosIntfTable;
		my @arrOID;
		my %cbQosTable;
		my $qosfile = "$NMIS::config{'<nmis_var>'}/$node-qos.nmis";
		# get the old index values
		if ( -r $qosfile ) {
			%cbQosTable = readVartoHash("$node-qos"); # read hash
			# oke, we have get now the PolicyIndex and ObjectsIndex directly
			foreach my $intf (keys %cbQosTable) {
				foreach my $direction ("in","out") {
					if (exists $cbQosTable{$intf}{$direction}{'PolicyMap'}{'Name'}) {
						# check if Policymap name contains no collect info
						if ($cbQosTable{$intf}{$direction}{'PolicyMap'}{'Name'} =~ /$NMIS::config{'CBQoS_no_collect'}/i) {
							print returnTime." CBQoS: no collect for interface $intf $direction ($cbQosTable{$intf}{$direction}{'Interface'}{'Descr'}) by CBQoS_no_collect ($NMIS::config{'CBQoS_no_collect'}) at Policymap $cbQosTable{$intf}{$direction}{'PolicyMap'}{'Name'}\n" if $debug;
						} else {
							my $PIndex = $cbQosTable{$intf}{$direction}{'PolicyMap'}{'Index'};
							foreach my $key (keys %{$cbQosTable{$intf}{$direction}{'ClassMap'}}) {
								my $CMName = $cbQosTable{$intf}{$direction}{'ClassMap'}{$key}{'Name'};
								my $OIndex = $cbQosTable{$intf}{$direction}{'ClassMap'}{$key}{'Index'};
								if ($debug) {print returnTime." CBQoS: Interface $intf, ClassMap $CMName, PolicyIndex $PIndex, ObjectsIndex $OIndex\n";}

								# get the number of bytes/packets transfered and dropped
								($snmpTable{'cbQosCMPrePolicyByte'},$snmpTable{'cbQosCMDropByte'},
									$snmpTable{'cbQosCMPrePolicyPkt'},$snmpTable{'cbQosCMDropPkt'},$snmpTable{'cbQosCMNoBufDropPkt'}) 
								  = $session->snmpget("cbQosCMPrePolicyByte64.$PIndex.$OIndex","cbQosCMDropByte64.$PIndex.$OIndex",
									"cbQosCMPrePolicyPkt64.$PIndex.$OIndex","cbQosCMDropPkt64.$PIndex.$OIndex",
										'cbQosCMNoBufDropPkt64'.".$PIndex.$OIndex");
								# are the old indexes oke ?
								if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/  or
									$snmpTable{'cbQosCMPrePolicyByte'} eq "" or
									$snmpTable{'cbQosCMDropByte'} eq ""
									) {
									# error, walk through the table again
									print returnTime." CBQoS: previous object indexes are not valid, $SNMP_Simple::errmsg\n" if ($debug);
									$SNMP_Simple::errmsg = "";
									return undef; # leave and walk again
								}

								# oke, store the data
								print returnTime." CBQoS: bytes transfered  $snmpTable{'cbQosCMPrePolicyByte'}, bytes dropped  $snmpTable{'cbQosCMDropByte'}\n" if ($debug);
								print returnTime." CBQoS: packets transfered  $snmpTable{'cbQosCMPrePolicyPkt'}, packets dropped $snmpTable{'cbQosCMDropPkt'}\n" if ($debug);
								print returnTime." CBQoS: packets dropped no buffer $snmpTable{'cbQosCMNoBufDropPkt'}\n" if ($debug);
								#
								my $extName = lc ($$interfaceTable{$intf}{'ifDescr'});
								if ($direction eq "in") { $extName .= "-in"; }
								# update RRD
								&updateRRDDB(type => "cbqos", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype}, ifSpeed => $$interfaceTable{$intf}{'ifSpeed'}, extName => $extName, item => $CMName);
								if ( $NMIS::systemTable{"typedraw$intf"} !~ /cbqos-$direction/ ) { $NMIS::systemTable{"typedraw$intf"} .= ",cbqos-$direction"; }
								if ( $NMIS::systemTable{"typedrawactive"} !~ /cbqos/ ) { $NMIS::systemTable{"typedrawactive"} .= ",cbqos"; }
							}
						}
					}
				}
			}
		} else {
			return undef;
		}
	return 1;
	}

#====
	sub runCBQoSwalk {
		my $session = shift;
		my $node = shift;
		my $interfaceTable = shift;

		my $message;
		my %qosIntfTable;
		my @arrOID;
		my %cbQosTable;

		# get the interface indexes and objects from the snmp table

		print returnTime." CBQoS: start table scanning\n" if ($debug);

		%cbQosTable = ();
		# read qos interface table
		my %ifIndexTable = $session->snmpgettablea('cbQosIfIndex');
		if ( $SNMP_Simple::errmsg =~ /No answer from/ ) {
			$message = "$node, SNMP error. errmsg=$SNMP_Simple::errmsg";
			logMessage("runCBQoS, $message") if $debug;
			print returnTime." CBQoS: $message\n" if $debug;
			$SNMP_Simple::errmsg = "";
		} elsif ( $SNMP_Simple::errmsg =~ /Unknown/ ) {
			# fatal error
			$message = "$node, SNMP error. errmsg=$SNMP_Simple::errmsg";
			logMessage("runCBQoS, $message");
			print returnTime." CBQoS: $message\n";
			$SNMP_Simple::errmsg = "";
		} else {
			foreach my $ifOID (keys %ifIndexTable) {
				my $intf = $ifIndexTable{$ifOID}; # the interface number from de snmp qos table
				print returnTime." CBQoS: scan interface $intf\n" if ($debug);
				# is this an active interface 
				if ( exists $$interfaceTable{$intf}) {
					# oke, go
					@arrOID = split(/\./,$ifOID);
					my $PIndex = @arrOID[14]; # the policy object index
					my $answer;
					my %CMValues;
					my $direction;
					# check direction of qos with node table
					($answer->{'cbQosPolicyDirection'}) = $session->snmpget("cbQosPolicyDirection.$PIndex") ;
					if( ($answer->{'cbQosPolicyDirection'} == 1 and $NMIS::nodeTable{$node}{cbqos} =~ /input|both/) or
						 	($answer->{'cbQosPolicyDirection'} == 2 and $NMIS::nodeTable{$node}{cbqos} =~ /output|true|both/) ) {
						# interface found with QoS input or output configured
						$direction = ($answer->{'cbQosPolicyDirection'} == 1) ? "in" : "out";
						print returnTime." CBQoS: Interface $intf found, direction $direction, PolicyIndex $PIndex\n" if ($debug);
						# get the policy config table for this interface
						my %qosIndexTable = $session->snmpgettablea("cbQosConfigIndex.$PIndex");
						# the OID will be 1.3.6.1.4.1.9.9.166.1.5.1.1.2.$PIndex.$OIndex = Gauge
						BLOCK2:
						foreach my $qosOID (keys %qosIndexTable) {
							# look for the Object type for each
							@arrOID = split(/\./,$qosOID);
							my $OIndex = @arrOID[15]; 
							($answer->{'cbQosObjectsType'}) = $session->snmpget("cbQosObjectsType.$PIndex.$OIndex");
							print returnTime." CBQoS: look for object at $PIndex.$OIndex, type $answer->{'cbQosObjectsType'}\n" if ($debug);
							if($answer->{'cbQosObjectsType'} eq 1) {
								# it's a policy-map object, is it the primairy
								($answer->{'cbQosParentObjectsIndex'}) = 
									$session->snmpget("cbQosParentObjectsIndex.$PIndex.$OIndex");
								if ($answer->{'cbQosParentObjectsIndex'} eq 0){
									# this is the primairy policy-map object, get the name
									($answer->{'cbQosPolicyMapName'}) = 
										$session->snmpget("cbQosPolicyMapName.$qosIndexTable{$qosOID}");
									print returnTime." CBQoS: policymap - name is $answer->{'cbQosPolicyMapName'}, parent ID $answer->{'cbQosParentObjectsIndex'}\n" if ($debug);
								}
							} elsif ($answer->{'cbQosObjectsType'} eq 2) {
								# it's a classmap, ask the name and the parent ID
								($answer->{'cbQosCMName'},$answer->{'cbQosParentObjectsIndex'}) = 
									$session->snmpget("cbQosCMName.$qosIndexTable{$qosOID}","cbQosParentObjectsIndex.$PIndex.$OIndex");
								print returnTime." CBQoS: classmap - name is $answer->{'cbQosCMName'}, parent ID $answer->{'cbQosParentObjectsIndex'}\n" if ($debug);

								$answer->{'cbQosParentObjectsIndex2'} = $answer->{'cbQosParentObjectsIndex'} ;
								my $cnt = 0;
								while ($NMIS::config{'CBQoS_CM_collect_all'} eq "true" and $answer->{'cbQosParentObjectsIndex2'} ne 0 and $answer->{'cbQosParentObjectsIndex2'} ne $PIndex and $cnt++ lt 5) {
									($answer->{'cbQosConfigIndex'}) = $session->snmpget("cbQosConfigIndex.$PIndex.$answer->{'cbQosParentObjectsIndex2'}");
									# it is not the first level, get the parent names
									($answer->{'cbQosObjectsType2'}) = $session->snmpget("cbQosObjectsType.$PIndex.$answer->{'cbQosParentObjectsIndex2'}");
									print returnTime." CBQoS: look for parent of ObjectsType $answer->{'cbQosObjectsType2'}\n" if ($debug);
									if ($answer->{'cbQosObjectsType2'} eq 1) {
										# it is a policymap name
										($answer->{'cbQosName'},$answer->{'cbQosParentObjectsIndex2'}) = 
											$session->snmpget("cbQosPolicyMapName.$answer->{'cbQosConfigIndex'}","cbQosParentObjectsIndex.$PIndex.$answer->{'cbQosParentObjectsIndex2'}");
										print returnTime." CBQoS: parent policymap - name is $answer->{'cbQosName'}, parent ID $answer->{'cbQosParentObjectsIndex2'}\n" if ($debug);
									} elsif ($answer->{'cbQosObjectsType2'} eq 2) {
										# it is a classmap name
										($answer->{'cbQosName'},$answer->{'cbQosParentObjectsIndex2'}) = 
											$session->snmpget("cbQosCMName.$answer->{'cbQosConfigIndex'}","cbQosParentObjectsIndex.$PIndex.$answer->{'cbQosParentObjectsIndex2'}");
										print returnTime." CBQoS: parent classmap - name is $answer->{'cbQosName'}, parent ID $answer->{'cbQosParentObjectsIndex2'}\n" if ($debug);
									} elsif ($answer->{'cbQosObjectsType2'} eq 3) {
										print returnTime." CBQoS: skip - this class-map is part of a match statement\n" if ($debug);
										next BLOCK2; # skip this class-map, is part of a match statement
									}
									# concatenate names
									if ($answer->{'cbQosParentObjectsIndex2'} ne 0) {
										$answer->{'cbQosCMName'} = "$answer->{'cbQosName'}/$answer->{'cbQosCMName'}";
									}
								}

								# collect all levels of classmaps or only the first level
								if (($NMIS::config{'CBQoS_CM_collect_all'} eq "true" or $answer->{'cbQosParentObjectsIndex'} eq $PIndex)) {
									#
									$CMValues{"H".$OIndex}{'CMName'} = $answer->{'cbQosCMName'} ;
									$CMValues{"H".$OIndex}{'CMIndex'} = $OIndex ;
								}
							} elsif ($answer->{'cbQosObjectsType'} eq 4) {
								my $CMRate;
								# it's a queueing object, look for the bandwidth
								($answer->{'cbQosQueueingCfgBandwidth'},$answer->{'cbQosQueueingCfgBandwidthUnits'},$answer->{'cbQosParentObjectsIndex'})
									= $session->snmpget("cbQosQueueingCfgBandwidth.$qosIndexTable{$qosOID}","cbQosQueueingCfgBandwidthUnits.$qosIndexTable{$qosOID}",
										"cbQosParentObjectsIndex.$PIndex.$OIndex");
								if ($answer->{'cbQosQueueingCfgBandwidthUnits'} eq 1) {
									$CMRate = $answer->{'cbQosQueueingCfgBandwidth'}*1000;
								} elsif ($answer->{'cbQosQueueingCfgBandwidthUnits'} eq 2 or $answer->{'cbQosQueueingCfgBandwidthUnits'} eq 3 ) {
									$CMRate = $answer->{'cbQosQueueingCfgBandwidth'} * $$interfaceTable{$intf}{'ifSpeed'}/100;
								}
								if ($CMRate eq 0) { $CMRate = "undef"; }
								if ($debug) {print returnTime." CBQoS: queueing - bandwidth $answer->{'cbQosQueueingCfgBandwidth'}, units $answer->{'cbQosQueueingCfgBandwidthUnits'},".
									"rate $CMRate, parent ID $answer->{'cbQosParentObjectsIndex'}\n";}
								$CMValues{"H".$answer->{'cbQosParentObjectsIndex'}}{'CMCfgRate'} = $CMRate ;
							} elsif ($answer->{'cbQosObjectsType'} eq 6) {
								# traffic shaping
								($answer->{'cbQosTSCfgRate'},$answer->{'cbQosParentObjectsIndex'})
									= $session->snmpget("cbQosTSCfgRate.$qosIndexTable{$qosOID}","cbQosParentObjectsIndex.$PIndex.$OIndex");
								if ($debug) {print returnTime." CBQoS: shaping - rate $answer->{'cbQosTSCfgRate'}, parent ID $answer->{'cbQosParentObjectsIndex'}\n";}
									$CMValues{"H".$answer->{'cbQosParentObjectsIndex'}}{'CMTSCfgRate'} = $answer->{'cbQosPoliceCfgRate'};

							} elsif ($answer->{'cbQosObjectsType'} eq 7) {
								# police
								($answer->{'cbQosPoliceCfgRate'},$answer->{'cbQosParentObjectsIndex'})
									= $session->snmpget("cbQosPoliceCfgRate.$qosIndexTable{$qosOID}","cbQosParentObjectsIndex.$PIndex.$OIndex");
								if ($debug) {print returnTime." CBQoS: police - rate $answer->{'cbQosPoliceCfgRate'}, parent ID $answer->{'cbQosParentObjectsIndex'}\n";}
								$CMValues{"H".$answer->{'cbQosParentObjectsIndex'}}{'CMPoliceCfgRate'} = $answer->{'cbQosPoliceCfgRate'};
							}
						}

						$cbQosTable{$intf}{$direction}{'Interface'}{'Descr'} = $$interfaceTable{$intf}{'ifDescr'} ;

						$cbQosTable{$intf}{$direction}{'PolicyMap'}{'Name'} = $answer->{'cbQosPolicyMapName'} ;
						$cbQosTable{$intf}{$direction}{'PolicyMap'}{'Index'} = $PIndex ;

						# combine CM name and bandwidth
						foreach my $index (keys %CMValues ) { 
							# check if CM name does exist
							if (exists $CMValues{$index}{'CMName'}) {

								$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'Name'} = $CMValues{$index}{'CMName'};
								$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'Index'} = $CMValues{$index}{'CMIndex'};

								# lets print the just type
								if (exists $CMValues{$index}{'CMCfgRate'}) {
									$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Descr'} = "Bandwidth" ;
									$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Value'} = $CMValues{$index}{'CMCfgRate'} ;
								} elsif (exists $CMValues{$index}{'CMTSCfgRate'}) {
									$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Descr'} = "Traffic shaping" ;
									$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Value'} = $CMValues{$index}{'CMTSCfgRate'} ;
								} elsif (exists $CMValues{$index}{'CMPoliceCfgRate'}) {
									$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Descr'} = "Police" ;
									$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Value'} = $CMValues{$index}{'CMPoliceCfgRate'} ;
								} else {
									$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Descr'} = "Bandwidth" ;
									$cbQosTable{$intf}{$direction}{'ClassMap'}{$index}{'BW'}{'Value'} = "undef" ;
								}

							}
						}
					} else {
						print returnTime." CBQoS: No collect requested in Node table\n" if $debug;
					}
				} else {
					print returnTime." CBQoS: Interface $intf does not exitst in interfaceTable\n" if $debug;
				}
			}
 
			if (scalar (keys %ifIndexTable) ) {
				# Finished with SNMP QoS, store object index values for the next run and CM names for WWW
				writeHashtoVar("$node-qos",\%cbQosTable) ;
			} else {
				print returnTime." CBQoS: no entries found in QoS table of node $node\n" if $debug;
			}
		}
	}

} # runCBQos

###
### Cisco Call based handling
### Mike McHenry 2005
###
sub runCalls {
	my $node = shift;
	my $session;
	my $snmpError;
	my $message;
	my $intf;
	my %interfaceTable;
	my %callsIntfTable;
	my %callsIndexTable;
	my @arrOID;
	my %callsTable;
	my $doWalk = "true";
	my %totalsTable;
	my @ret;
	my %callsStats;
	my $parentintfindex;
	my %seen;
	my $session;
	my %mappingTable;

	
	if ($NMIS::systemTable{nodeModel} =~ /CiscoRouter/) {

		if (not exists $NMIS::nodeTable{$node}{calls}) {
			&addColumn("Nodes","calls","false");
			loadNodeDetails; # reload with new column
			return;
		} else {
			if ($NMIS::nodeTable{$node}{calls} ne "true") {
				print returnTime." Calls: no collecting for node $node\n" if $debug;
				return;
			}
		}

		print returnTime." Calls: Start collecting for node $node\n" if ($debug);
		if ( $NMIS::systemTable{snmpVer} eq "SNMPv2" ) {
			($session) = SNMPv2c_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
		}
		else {
			($session) = SNMP_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
		}
		if ( not defined($session) ) { 
			warn returnTime." Calls: Session is not Defined Goodly to $node.\n"; 
			return;
		}
		my $interfacefile = "$NMIS::config{'<nmis_var>'}/$node-interface.dat";
		if ( -r $interfacefile ) {
			#Interface file exists load the definitions
			%interfaceTable = &loadCSV($interfacefile,"ifIndex","\t");
		} else { warn returnTime." Calls: error loading interface values\n"; return; }

		## oke,lets go

		my $callsfile = "$NMIS::config{'<nmis_var>'}/$node-calls.nmis";
		# get the old index values
		# the layout of the record is: channel intf intfDescr intfindex parentintfDescr parentintfindex port slot
		if ( -r $callsfile ) {	
			# Read the Calls file of this node
			%callsTable = readVartoHash("$node-calls"); # read hash
			# oke, we have get now the objectindexes of calltable values directly
			$doWalk = "false";
			BLOCK1: 
			foreach my $intfindex (keys %callsTable) {
				($snmpTable{'cpmDS0CallType'},$snmpTable{'cpmL2Encapsulation'},$snmpTable{'cpmCallCount'}) = $session->snmpget('cpmDS0CallType'.".$callsTable{$intfindex}{'intfoid'}",'cpmL2Encapsulation'.".$callsTable{$intfindex}{'intfoid'}",'cpmCallCount'.".$callsTable{$intfindex}{'intfoid'}");
				if ( $snmpTable{'cpmCallCount'} eq "" ) { $snmpTable{'cpmCallCount'} = 0 ;}
				# are the old indexes oke ?

				if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/  or
					$snmpTable{'cpmDS0CallType'} eq "" or
					$snmpTable{'cpmL2Encapsulation'} eq ""
					) {
					# error, walk through the table again
					print returnTime." Calls: previous object indexes are not valid, $SNMP_Simple::errmsg\n" if ($debug);
					$doWalk = "true";
					$SNMP_Simple::errmsg = "";
					last BLOCK1;
				}

				# calculate totals for physical interfaces and dump them into totalsTable hash
				if ( $snmpTable{'cpmDS0CallType'} != "" ) {
#					$snmpTable{'cpmAvailableCallCount'} = 1;	# calculate individual available DS0 ports no matter what their current state
					$totalsTable{$callsTable{$intfindex}{'parentintfIndex'}}{'TotalDS0'} += 1 ;	# calculate total available DS0 ports no matter what their current state
				}
				$totalsTable{$callsTable{$intfindex}{'parentintfIndex'}}{'TotalCallCount'} += $snmpTable{'cpmCallCount'};
				$totalsTable{$callsTable{$intfindex}{'parentintfIndex'}}{'parentintfIndex'} = $callsTable{$intfindex}{'parentintfIndex'};
				$totalsTable{$callsTable{$intfindex}{'parentintfIndex'}}{'parentintfDescr'} = $callsTable{$intfindex}{'parentintfDescr'};
				# populate totals for DS0 call types
				# total idle ports
				if ( $snmpTable{'cpmDS0CallType'} eq "1" ) { 
					$totalsTable{$callsTable{$intfindex}{'parentintfIndex'}}{'totalIdle'} += 1 ;
				}
				# total unknown ports
				if ( $snmpTable{'cpmDS0CallType'} eq "2" ) { 
						$totalsTable{$callsTable{$intfindex}{'parentintfIndex'}}{'totalUnknown'} += 1;
				}
				# total analog ports
				if ( $snmpTable{'cpmDS0CallType'} eq "3" ) { 
					$totalsTable{$callsTable{$intfindex}{'parentintfIndex'}}{'totalAnalog'} += 1 ;
				}
				# total digital ports
				if ( $snmpTable{'cpmDS0CallType'} eq "4" ) { 
					$totalsTable{$callsTable{$intfindex}{'parentintfIndex'}}{'totalDigital'} += 1 ;
				}
				# total v110 ports
				if ( $snmpTable{'cpmDS0CallType'} eq "5" ) { 
					$totalsTable{$callsTable{$intfindex}{'parentintfIndex'}}{'totalV110'} += 1 ;
				}
				# total v120 ports
				if ( $snmpTable{'cpmDS0CallType'} eq "6" ) { 
					$totalsTable{$callsTable{$intfindex}{'parentintfIndex'}}{'totalV120'} += 1 ;
				}
				# total voice ports
				if ( $snmpTable{'cpmDS0CallType'} eq "7" ) { 
					$totalsTable{$callsTable{$intfindex}{'parentintfIndex'}}{'totalVoice'} += 1 ;
				}
				if ( $snmpTable{'cpmAvailableCallCount'} eq "" ) { $snmpTable{'cpmAvailableCallCount'} = 0 ;}
				if ( $snmpTable{'cpmCallCount'} eq "" ) { $snmpTable{'cpmCallCount'} = 0 ;}
			}
			#
			# Second loop to populate RRD tables for totals
			BLOCK2: 
			foreach my $intfindex (keys %totalsTable) {
				
				if ($debug) {print returnTime." Calls: Total intf $totalsTable{$intfindex}{'parentintfIndex'}, PortName $totalsTable{$intfindex}{'parentintfDescr'}\n";}
				if ( $totalsTable{'TotalCallCount'} eq "" ) { $totalsTable{'TotalCallCount'} = 0 ;}

				print returnTime." Calls: Total idle DS0 ports  $totalsTable{$intfindex}{'totalIdle'}\n" if ($debug);
				print returnTime." Calls: Total unknown DS0 ports  $totalsTable{$intfindex}{'totalUnknown'}\n" if ($debug);
				print returnTime." Calls: Total analog DS0 ports  $totalsTable{$intfindex}{'totalAnalog'}\n" if ($debug);
				print returnTime." Calls: Total digital DS0 ports  $totalsTable{$intfindex}{'totalDigital'}\n" if ($debug);
				print returnTime." Calls: Total v110 DS0 ports  $totalsTable{$intfindex}{'totalV110'}\n" if ($debug);
				print returnTime." Calls: Total v120 DS0 ports  $totalsTable{$intfindex}{'totalV120'}\n" if ($debug);
				print returnTime." Calls: Total voice DS0 ports  $totalsTable{$intfindex}{'totalVoice'}\n" if ($debug);
				print returnTime." Calls: Total DS0 ports available  $totalsTable{$intfindex}{'TotalDS0'}\n" if ($debug);
				print returnTime." Calls: Total DS0 calls  $totalsTable{$intfindex}{'TotalCallCount'}\n" if ($debug);
				$snmpTable{'totalIdle'} = $totalsTable{$intfindex}{'totalIdle'};
				$snmpTable{'totalUnknown'} = $totalsTable{$intfindex}{'totalUnknown'};
				$snmpTable{'totalAnalog'} = $totalsTable{$intfindex}{'totalAnalog'};
				$snmpTable{'totalDigital'} = $totalsTable{$intfindex}{'totalDigital'};
				$snmpTable{'totalV110'} = $totalsTable{$intfindex}{'totalV110'};
				$snmpTable{'totalV120'} = $totalsTable{$intfindex}{'totalV120'};
				$snmpTable{'totalVoice'} = $totalsTable{$intfindex}{'totalVoice'};
				$snmpTable{'cpmAvailableCallCount'} = $totalsTable{$intfindex}{'TotalDS0'};
				$snmpTable{'cpmCallCount'} = $totalsTable{$intfindex}{'TotalCallCount'};
					
				if ( $snmpTable{'cpmAvailableCallCount'} eq "" ) { $snmpTable{'cpmAvailableCallCount'} = 0 ;}
				if ( $snmpTable{'cpmCallCount'} eq "" ) { $snmpTable{'cpmCallCount'} = 0 ;}

				#
				# Store data
				my $extName = $totalsTable{$intfindex}{'parentintfDescr'};
				&updateRRDDB(type => "calls", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype}, ifSpeed => $interfaceTable{$intf}{'ifSpeed'}, extName => $extName) ;
				if ( $NMIS::systemTable{"typedraw"} !~ /calls/ ) { $NMIS::systemTable{"typedraw"} .= ",calls"; }
				$NMIS::systemTable{'typedraw_calls'} .= ",$intfindex";
				}
			}
		
		if ($doWalk eq "true") {

			# quick exit if not a device supporting frame type interfaces !
			if ( $NMIS::systemTable{nodeType} ne "router" ) { return; }


			if ($debug) { print returnTime." Calls: Starting Calls ports collection\n"; }

			# as we do a v2c bulkwalk, only continue if snmpv2c
			if ( $NMIS::systemTable{snmpVer} ne "SNMPv2" ) {
				if ($debug) { print "\t Calls: $node is not SNMPv2 - Calls ports collection aborted\n"; }
				return;
			}

			# double check if any call interfaces on this node.
			# cycle thru each ifindex and check the ifType, and save the ifIndex for matching later
			# only collect on interfaces that are defined and that are Admin UP
			foreach ( keys %interfaceTable ) {
				if ( $interfaceTable{$_}{ifAdminStatus} eq "up"	) {
					$seen{$_} = $_; 
				}
			}
			if ( ! %seen ) {	# empty hash
				if ($debug) { print "\t Calls: $node does not have any call ports or no collect or port down - Call ports collection aborted\n"; }
				return;
			}

			# should now be good to go....
			# this uses the snmp tablewalk forced to v2c getbulk in SNMP_utils.pm, from SNMP_Session
			# only use the Cisco private mib for cisco routers

			# add in the walk root for the cisco interface table entry for port to intf mapping
			&snmpmapOID("cpmDS0InterfaceIndex", "1.3.6.1.4.1.9.10.19.1.5.2.1.8");
			&snmpmapOID("ifStackStatus", "1.3.6.1.2.1.31.1.2.1.3");
			
			# snmpwalk the cpmDS0InterfaceIndex oid to populate $callsTable hash with such as interface indexes, ports, slots	
			if ($debug) { print "\t Calls: building callsTable hash from cpmDS0InterfaceIndex snmpwalk\n"; }
			my $host = "$NMIS::nodeTable{$node}{community}\@$node:$NMIS::nodeTable{$node}{snmpport}:3:1:1:2c";

			@ret = &snmpwalk( $host, { 'default_max_repetitions' => 14 }, 'cpmDS0InterfaceIndex' );
			if ( ! $ret[0] ) {
				if ($debug) { print "\t Calls: snmpwalk on $node:cpmDS0InterfaceIndex did not answer or SNMPv2 problem or no call ports port found - Call ports collection aborted\n"; }
			}
			else {
				foreach my $desc ( @ret ) {
					my ($intfoid, $intfindex) = split /:/, $desc, 2 ;
					my ($slot, $port, $channel) = split /\./, $intfoid, 3 ;
					# check if parent port was seen before and OK to collect on.
					if ( !exists $seen{$intfindex} ) {
						if ($debug) { print "\t Calls: snmp call port $intfindex is not collected or down - skipping\n"; }
						next;
					}

					$callsTable{$intfindex}{'intfoid'} = $intfoid;
					$callsTable{$intfindex}{'intfindex'} = $intfindex;
					$callsTable{$intfindex}{'slot'} = $slot;
					$callsTable{$intfindex}{'port'} = $port;
					$callsTable{$intfindex}{'channel'} = $channel;
				}
			}		
	
			# snmpwalk the ifStackStatus oid to populate $mappingTable hash with ifindex to parent mappings
			if ($debug) { print "\t Calls: building mappingTable hash from ifStackStatus snmpwalk\n"; }
			my $host = "$NMIS::nodeTable{$node}{community}\@$node:$NMIS::nodeTable{$node}{snmpport}:3:1:1:2c";

			@ret = &snmpwalk( $host, { 'default_max_repetitions' => 14 }, 'ifStackStatus' );
			if ( ! $ret[0] ) {
				if ($debug) { print "\t Calls: snmpwalk on $node:ifStackStatus did not answer or SNMPv2 problem or no call ports port found - Call ports collection aborted\n"; }
			}
			else {
				foreach my $desc ( @ret ) {
					my ($inst, $value) = split /:/, $desc, 2 ;
					my ($intfindex, $parentintfIndex, $pvc) = split /\./, $inst, 3 ;
					$mappingTable{$intfindex}{'intfindex'} = $intfindex;
					$mappingTable{$intfindex}{'parentintfIndex'} = $parentintfIndex;
				}

			}		
			# traverse the callsTable and mappingTable hashes to match call ports with their physical parent ports
			if ($debug) { print "\t Calls: matching virtual interfaces with physical parent ports\n"; }
			foreach my $callsintf ( keys %callsTable ) {
				foreach my $mapintf ( keys %mappingTable ) {
					if ( $callsintf == $mapintf ) {
					# if parent interface has been reached stop
						if ( $mappingTable{$mappingTable{$mapintf}{'parentintfIndex'}}{'parentintfIndex'} eq "0" ) {
							$callsTable{$callsintf}{'parentintfIndex'} = $mappingTable{$mapintf}{'parentintfIndex'};
						} # endif

						# assume only one level of nesting in physical interfaces 
						# (may need to increase for larger Cisco chassis)
						else {
							$callsTable{$callsintf}{'parentintfIndex'} = $mappingTable{$mappingTable{$mapintf}{'parentintfIndex'}}{'parentintfIndex'};
						} #end else
					} #end if
				} #end foreach
				# check if parent interface is also up
				if ( $interfaceTable{$callsTable{$callsintf}{'parentintfIndex'}}{ifAdminStatus} ne "up" ) {
				##	print returnTime." Calls: parent interface $interfaceTable{$callsTable{$callsintf}{'parentintfIndex'}}{ifDescr} is not up\n" if $debug;
					delete $callsTable{$callsintf} ;
				}
			} #end foreach

			# traverse the callsTable hash one last time and populate descriptive fields; also count total voice ports
			if ($debug) { print "\t Calls: populating callsTable with descriptive fields\n"; }
			my $InstalledVoice;
			foreach my $callsintf ( keys %callsTable ) {
				(      $callsTable{$callsintf}{'intfDescr'},
	                        $callsTable{$callsintf}{'parentintfDescr'},
	    	        ) = $session->snmpget(
	            	        'ifDescr'.".$callsTable{$callsintf}{'intfindex'}",
	                    	'ifDescr'.".$callsTable{$callsintf}{'parentintfIndex'}",
	           		);
				$InstalledVoice++;
			} #end foreach
			
			# create $nodes-calls.nmis file which contains interface mapping and descrption data	
			if ( %callsTable) {
				# callsTable has some values, so write it out
				writeHashtoVar("$node-calls",\%callsTable);
				$NMIS::systemTable{InstalledVoice} = "$InstalledVoice";
				if ($debug) { print "\t Calls: writing InstalledVoice variable to $NMIS::config{'<nmis_var>'}/$node.dat\n"; }
			}
		}
	}

	# Finished with the SNMP
	if (defined $session) { $session->close(); }
	print returnTime." Calls: Finished\n" if ($debug); 

} # runCalls

### health stats is now extra device health stuff only
### IP stats have been moved to runMib2ip for MIB2 compliant device support.
### added in server temperature monitoring.
sub runHealth {
	my $node = shift;
	my $session;
	my $intf;
	my $message;

	undef %snmpTable;
	
	if ($debug) { print returnTime." Starting Health Stats\n"; }

	# OPEN the SNMP Session 
	if ( $NMIS::systemTable{snmpVer} eq "SNMPv2" ) {
		($session) = SNMPv2c_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
	}
	else {
		($session) = SNMP_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
	}
	if ( not defined($session) ) { 
		warn returnTime." runHealth, Session is not Defined Goodly to $node.\n"; 
		goto END_runHealth;
	}

	# Now depending on the node type do different things.
	if ( $NMIS::systemTable{nodeModel} =~ /Catalyst6000|Catalyst5000Sup3|Catalyst5005|Catalyst5000/ ) {
		# Get all the Cisco Health Stuff unless not doing collection
		if ($collect eq "true") {
			(	$snmpTable{avgBusy1},
				$snmpTable{avgBusy5},
				$snmpTable{MemoryUsedDRAM},
				$snmpTable{MemoryFreeDRAM},
				$snmpTable{MemoryUsedMBUF},
				$snmpTable{MemoryFreeMBUF},
				$snmpTable{MemoryUsedCLUSTER},
				$snmpTable{MemoryFreeCLUSTER},
				$snmpTable{sysTraffic},
				$snmpTable{TopChanges}
			) = $session->snmpget(  
				'cpmCPUTotal1min'.".9", 
				'cpmCPUTotal5min'.".9",
				'ciscoMemoryPoolUsed'.".1",
				'ciscoMemoryPoolFree'.".1",
				'ciscoMemoryPoolUsed'.".8",
				'ciscoMemoryPoolFree'.".8",
				'ciscoMemoryPoolUsed'.".9",
				'ciscoMemoryPoolFree'.".9",
				'sysTraffic',
				'dot1dStpTopChanges'
			);
			if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
				logMessage( "runHealth, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				goto END_runHealth;
			}

			$reach{cpu} = $snmpTable{avgBusy5}; 
						if ( $snmpTable{MemoryFreeDRAM} > 0 and $snmpTable{MemoryUsedDRAM} > 0 ) {
							$reach{mem} = ( $snmpTable{MemoryFreeDRAM} * 100 ) / ($snmpTable{MemoryUsedDRAM} + $snmpTable{MemoryFreeDRAM}) ;
						}	
						else {	
							$reach{mem} = "U";	
						}

			if ($debug) { 
				print returnTime." Health Stats Summary\n";
				for $index ( sort keys %snmpTable ) {
					print "\t $index=$snmpTable{$index}\n";
				}
			}

			&updateRRDDB(type => "nodehealth",node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype});
			$NMIS::systemTable{typedraw} .= ",mem-cluster,mem-dram,mem-mbuf,topo,traffic";
			#
		} # collect eq true
	} # nodeModel eq Catalyst6000
	elsif ( $NMIS::systemTable{nodeModel} =~ /CiscoRouter|CatalystIOS/ ) {
		# Get all the Cisco Health Stuff unless not doing collection
		# moved ip stats to its own MIB2 rrd collection routine 
		if ($collect eq "true") {
			(	$snmpTable{avgBusy1},
				$snmpTable{avgBusy5},
				$snmpTable{MemoryUsedPROC},
				$snmpTable{MemoryFreePROC},
				$snmpTable{MemoryUsedIO},
				$snmpTable{MemoryFreeIO},
				$snmpTable{bufferElFree},
				$snmpTable{bufferElHit},
				$snmpTable{bufferFail}
			) = $session->snmpget(  
				'avgBusy1',
				'avgBusy5',
				'ciscoMemoryPoolUsed'.".1",
				'ciscoMemoryPoolFree'.".1",
				'ciscoMemoryPoolUsed'.".2",
				'ciscoMemoryPoolFree'.".2",
				'bufferElFree',
				'bufferElHit',
				'bufferFail'
			);
			if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
				logMessage( "runHealth, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				goto END_runHealth;
			}
			if ($debug) { 
				print returnTime." Health Stats Summary\n";
				for $index ( sort keys %snmpTable ) {
					print "\t $index=$snmpTable{$index}\n";
				}
			}
			# take care of negative values from 6509 MSCF
			if ($snmpTable{bufferElHit} < 0) {$snmpTable{bufferElHit} = sprintf("%u",$snmpTable{bufferElHit})}
			
			$reach{cpu} = $snmpTable{avgBusy5}; 

			if ( $snmpTable{MemoryUsedPROC} == 0 or $snmpTable{MemoryFreePROC} == 0 ) {
				$reach{mem} = 100;
			}
			else {
				$reach{mem} = ( $snmpTable{MemoryFreePROC} * 100 ) / ($snmpTable{MemoryUsedPROC} + $snmpTable{MemoryFreePROC}) ; 
			}

			# update RRD Database
			&updateRRDDB(type => "nodehealth", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype});
			$NMIS::systemTable{typedraw} .= ",buffer,cpu,mem-io,mem-proc,mem-router";
			#
		} # collect eq true

	} # nodeModel eq CiscoRouter
	### Mike McHenry 2005
	elsif ( $NMIS::systemTable{nodeModel} =~ /Redback/ ) {
		if ($collect eq "true") {
			(	$snmpTable{avgBusy1},
				$snmpTable{avgBusy5},
			) = $session->snmpget(  
				'rbnCpuMeterOneMinuteAvg'.".0",
				'rbnCpuMeterFiveMinuteAvg'.".0",
			);
			if ( $SNMP_Simple::errmsg =~ /No answer from/ ) {
				$message = "$node, SNMP error. errmsg=$SNMP_Simple::errmsg";
				$SNMP_Simple::errmsg = "";
				logMessage("runHealth, $message");
				if ($debug) { print returnTime." runHealth, $message\n"; }
				$SNMP_Simple::errmsg = "";
				goto END_runHealth;
			}
			if ($debug) { 
				print returnTime." Health Stats Summary\n";
				for $index ( sort keys %snmpTable ) {
					print "\t $index=$snmpTable{$index}\n";
				}
			}
			$reach{cpu} = $snmpTable{avgBusy5}; 

			# Check if the RRD Database Exists
			if ( &createRRDDB(type => "nodehealth", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype}) ) { 
				&updateRRDDB(type => "nodehealth", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype});
			}
		} # collect eq true

	} # nodeModel eq Redback
	### Mike McHenry 2005
	elsif ( $NMIS::systemTable{nodeModel} =~ /FoundrySwitch/ ) {
		# moved ip stats to its own MIB2 rrd collection routine 
		if ($collect eq "true") {
			(	$snmpTable{avgBusy1},
				$snmpTable{MemoryUsedPROC},
				$snmpTable{MemoryFreePROC},
				$snmpTable{bufferElFree},
				$snmpTable{bufferElHit},
				$snmpTable{bufferFail}
			) = $session->snmpget(  
				'snAgGblCpuUtil1MinAvg',
				'snAgGblDynMemTotal',
				'snAgGblDynMemFree',
				'bufferElFree',
				'bufferElHit',
				'bufferFail'
			);

			# Math hackery to convert Foundry CPU memory usage into appropriate values
			$snmpTable{MemoryUsedPROC} = ($snmpTable{MemoryUsedPROC} - $snmpTable{MemoryFreePROC});

			if ( $SNMP_Simple::errmsg =~ /No answer from/ ) {
				$message = "$node, SNMP error. errmsg=$SNMP_Simple::errmsg";
				$SNMP_Simple::errmsg = "";
				logMessage("runHealth, $message");
				if ($debug) { print returnTime." runHealth, $message\n"; }
				$SNMP_Simple::errmsg = "";
				goto END_runHealth;
			}
			if ($debug) { 
				print returnTime." Health Stats Summary\n";
				for $index ( sort keys %snmpTable ) {
					print "\t $index=$snmpTable{$index}\n";
				}
			}
			$reach{cpu} = $snmpTable{avgBusy1}; 

			if ( $snmpTable{MemoryUsedPROC} == 0 or $snmpTable{MemoryFreePROC} == 0 ) {
				$reach{mem} = 100;
			}
			else {
				$reach{mem} = ($snmpTable{MemoryUsedPROC} / ($snmpTable{MemoryUsedPROC} + $snmpTable{MemoryFreePROC}) * 100);
			}

			# Check if the RRD Database Exists
			if ( &createRRDDB(type => "nodehealth", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype}) ) { 
				&updateRRDDB(type => "nodehealth", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype});
			}
		} # collect eq true

	} # nodeModel eq FoundrySwitch
	### Mike McHenry 2005
	elsif ( $NMIS::systemTable{nodeModel} =~ /Riverstone/ ) {
		# moved ip stats to its own MIB2 rrd collection routine 
		if ($collect eq "true") {
			(
				$snmpTable{avgBusy1},
				$snmpTable{MemoryUsedPROC},
				$snmpTable{MemoryFreePROC},
			) = $session->snmpget(  
				'capCPUCurrentUtilization',
				'capMemoryUsed'.".1.1",
				'capMemorySize'.".1.1",
			);

			# Math hackery to convert Riverstone CPU memory usage into appropriate values
			$snmpTable{MemoryFreePROC} = ($snmpTable{MemoryFreePROC} - $snmpTable{MemoryUsedPROC});
			$snmpTable{MemoryUsedPROC} = $snmpTable{MemoryUsedPROC} * 16;
			$snmpTable{MemoryFreePROC} = $snmpTable{MemoryFreePROC} * 16;

			if ( $SNMP_Simple::errmsg =~ /No answer from/ ) {
				$message = "$node, SNMP error. errmsg=$SNMP_Simple::errmsg";
				$SNMP_Simple::errmsg = "";
				logMessage("runHealth, $message");
				if ($debug) { print returnTime." runHealth, $message\n"; }
				$SNMP_Simple::errmsg = "";
				goto END_runHealth;
			}
			if ($debug) { 
				print returnTime." Health Stats Summary\n";
				for $index ( sort keys %snmpTable ) {
					print "\t $index=$snmpTable{$index}\n";
				}
			}
			$reach{cpu} = $snmpTable{avgBusy1}; 

			if ( $snmpTable{MemoryUsedPROC} == 0 or $snmpTable{MemoryFreePROC} == 0 ) {
				$reach{mem} = 100;
			}
			else {
				$reach{mem} = ($snmpTable{MemoryUsedPROC} / ($snmpTable{MemoryUsedPROC} + $snmpTable{MemoryFreePROC}) * 100);
			}

			# Check if the RRD Database Exists
			if ( &createRRDDB(type => "nodehealth", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype}) ) { 
				&updateRRDDB(type => "nodehealth", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype});
			}
		} # collect eq true

	} # nodeModel eq Riverstone

	### AS 1 Apr 02 - Integrating Phil Reilly's Nortel changes
	### Ehg 16oct02 moved ip stats to mib2ip
	elsif ( $NMIS::systemTable{nodeModel} =~ /Accelar/ ) {
		# Get all the Accelar Health Stuff unless not doing collection
		if ($collect eq "true") {
			(	$snmpTable{rcSysCpuUtil},
				$snmpTable{rcSysSwitchFabricUtil},
				$snmpTable{rcSysBufferUtil}
			) = $session->snmpget(  
				'rcSysCpuUtil'.".0",
				'rcSysSwitchFabricUtil'.".0",
				'rcSysBufferUtil'.".0"
			);
			if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
				logMessage( "runHealth, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				goto END_runHealth;
			}
			if ($debug) { 
				print returnTime." Health Stats Summary\n";
				for $index ( sort keys %snmpTable ) {
					print "\t $index=$snmpTable{$index}\n";
				}
			}
			
			$reach{cpu} = $snmpTable{rcSysCpuUtil}; 

			# update RRD Database
			&updateRRDDB(type => "nodehealth", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype});
			$NMIS::systemTable{typedraw} .= ",acpu";
			#
		} # collect eq true
	} # nodeModel eq Accelar
	elsif ( $NMIS::systemTable{nodeModel} =~ /PIX/ ) {
		
		# Get all the Cisco PIX Stuff unless not doing collection
		# only collect cpu for software 6.2 and above

		if ($collect eq "true") {
			if ( $NMIS::systemTable{sysDescr} =~ /6\.(\d+)/ && $1 > 1  ) {
				(  	$snmpTable{avgBusy1},
					$snmpTable{avgBusy5}
				) = $session->snmpget(
					'cpmCPUTotal1min'.".1",							# CISCO-PROCESS-MIB.my (PIX version 6.2 or greater only)
					'cpmCPUTotal5min'.".1"  
				);
				if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
					logMessage( "runHealth, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
					$SNMP_Simple::errmsg = "";
					goto END_runHealth;
				}
				$reach{cpu} = $snmpTable{avgBusy5};
			}
			else {
				$snmpTable{avgBusy1} = 0;
				$snmpTable{avgBusy5} = 0;
				$reach{cpu} = 0;
			}
			# get the rest
			(  	$snmpTable{MemoryUsedPROC},
				$snmpTable{MemoryFreePROC},
				$snmpTable{connectionsInUse},
				$snmpTable{connectionsHigh}
			) = $session->snmpget(
				'ciscoMemoryPoolUsed'.".1",					# CISCO-MEMORY-POOL-MIB.my 
				'ciscoMemoryPoolFree'.".1",
				'cfwConnectionStatValue'.".40".".6",		# CISCO-FIREWALL-MIB.my cfwConnectionStatValue.protoIp.currentInUse = Gauge32:
				'cfwConnectionStatValue'.".40".".7"		# CISCO-FIREWALL-MIB.my cfwConnectionStatValue.protoIp.high = Gauge32:
			);
			if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
				logMessage( "runHealth, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				goto END_runHealth;
			}
			if ($debug) { 
				print returnTime." Health Stats Summary\n";
				for $index ( sort keys %snmpTable ) {
					print "\t $index=$snmpTable{$index}\n";
				}
			}
			if ( $snmpTable{MemoryUsedPROC} == 0 or $snmpTable{MemoryFreePROC} == 0 ) {
				$reach{mem} = 100;
			}
			else {
				$reach{mem} = ( $snmpTable{MemoryFreePROC} * 100 ) / ($snmpTable{MemoryUsedPROC} + $snmpTable{MemoryFreePROC}) ; 
			}
			# update RRD Database
			&updateRRDDB(type => "nodehealth", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype});
			$NMIS::systemTable{typedraw} .= ",cpu,mem-proc,mem-router,pix-conn";
			#
		} # collect eq true
	} # nodeModel eq CiscoPIX
	### 3com
	elsif ( $NMIS::systemTable{nodeModel} =~ /SSII 3Com/ ) {
		# Get all the a3com Stuff unless not doing collection
		if ($collect eq "true") {
			(   $snmpTable{BandwidthUsed},
				$snmpTable{ErrorsPerPackets},
				$snmpTable{ReadableFrames},
				$snmpTable{UnicastFrames},
				$snmpTable{MulticastFrames},
				$snmpTable{BroadcastFrames},
				$snmpTable{ReadableOctets},
				$snmpTable{UnicastOctets},
				$snmpTable{MulticastOctets},
				$snmpTable{BroadcastOctets},
				$snmpTable{FCSErrors},
				$snmpTable{AlignmentErrors},
				$snmpTable{FrameTooLongs},
				$snmpTable{ShortEvents},
				$snmpTable{Runts},
				$snmpTable{TxCollisions},
				$snmpTable{LateEvents},
				$snmpTable{VeryLongEvents},
				$snmpTable{DataRateMismatches},
				$snmpTable{AutoPartitions},
				$snmpTable{TotalErrors}
			) = $session->snmpget(  
				'mrmMonRepBandwidthUsed'.".1001",
				'mrmMonRepErrorsPer10000Packets'.".1001",
				'mrmMonRepReadableFrames'.".1001",
				'mrmMonRepUnicastFrames'.".1001",
				'mrmMonRepMulticastFrames'.".1001",
				'mrmMonRepBroadcastFrames'.".1001",
				'mrmMonRepReadableOctets'.".1001",
				'mrmMonRepUnicastOctets'.".1001",
				'mrmMonRepMulticastOctets'.".1001",
				'mrmMonRepBroadcastOctets'.".1001",
				'mrmMonRepFCSErrors'.".1001",
				'mrmMonRepAlignmentErrors'.".1001",
				'mrmMonRepFrameTooLongs'.".1001",
				'mrmMonRepShortEvents'.".1001",
				'mrmMonRepRunts'.".1001",
				'mrmMonRepTxCollisions'.".1001",
				'mrmMonRepLateEvents'.".1001",
				'mrmMonRepVeryLongEvents'.".1001",
				'mrmMonRepDataRateMismatches'.".1001",
				'mrmMonRepAutoPartitions'.".1001",
				'mrmMonRepTotalErrors'.".1001"
			);
				
			if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
				logMessage( "runHealth, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				goto END_runHealth;
			}
			if ($debug) { 
				print returnTime." Health Stats Summary\n";
				for $index ( sort keys %snmpTable ) {
					print "\t $index=$snmpTable{$index}\n";
				}
			}
			$reach{mem} = 100;

			# update RRD Database
			&updateRRDDB(type => "nodehealth", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype});
			$NMIS::systemTable{typedraw} .= ",a3bandwidth,a3traffic,a3errors";
			#
		} # collect eq true
	} # nodeModel eq a3com
	### DellServer
	elsif ( $NMIS::systemTable{nodeType} eq "server" and $NMIS::systemTable{sysName} eq "XXXX" ) {
		# Get the dell temperature readings
		if ($collect eq "true") {
			(  $snmpTable{tempStatus},
				$snmpTable{tempReading},
				$snmpTable{tempMinWarn},
				$snmpTable{tempMaxWarn}
			) = $session->snmpget(  
				'tempStatusAtt4'.".9.2.1.1",
				'tempReadingAtt5'.".9.2.1.1",
				'tempMinWarnAtt6'.".9.2.1.1",
				'tempMaxWarnAtt7'.".9.2.1.1"
			);
				
			if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
				logMessage( "runHealth, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				goto END_runHealth;
			}
			$snmpTable{tempStatus} = $snmpTable{tempStatus} == 3 ? "ok" : "fail";
			# dellboy kludge as system min/max seem too high for safety
			$snmpTable{tempMinWarn} = 100;
			$snmpTable{tempMaxWarn} = 450;

			if ($debug) { 
				print returnTime." Health Stats Summary\n";
				for $index ( sort keys %snmpTable ) {
					print "\t $index=$snmpTable{$index}\n";
				}
			}
			# log an event if the temperature is not "ok"
			# treat as a Node Down event for event escalation purposes
			if ( $snmpTable{tempStatus} ne "ok" or
					$snmpTable{tempReading} > $snmpTable{tempMaxWarn} or
					$snmpTable{tempReading} < $snmpTable{tempMinWarn} ) {
				# Device is hot or maybe cold
				if ($debug) { print returnTime." Temperature failed $node Temp is: $snmpTable{tempReading}\n"; }
				notify(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => "Node Down", details => "Temperature Exceeded");
			} else {
				# Device is OK
				checkEvent(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => "Node Down", level => "Normal", details => "Temperature Exceeded");
			}
			# update RRD Database
			&updateRRDDB(type => "nodehealth", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype});
			$NMIS::systemTable{typedraw} .= ",degree";
			#
		} # collect eq true
	} # nodeModel eq Dellserver
	
	# Finished with the SNMP
	END_runHealth:
	if (defined $session) { $session->close(); }
} # end runHealth

### new MIB-II created by eric.greenwood@imlnetwork.com to handle MIB-II IP table objects
# removed IP stuff from nodeHealth and extended in here with fragmentation stats
# will allow us to have standard MIB2 support as a device class.
sub runMib2ip {
	my $node = shift;
	my $session;
	my $index;
	my $message;

	undef %snmpTable;
	
	if ($debug) { print returnTime." Starting MIB2 IP Stats\n"; }

	# OPEN the SNMP Session 
	if ( $NMIS::systemTable{snmpVer} eq "SNMPv2" ) {
		($session) = SNMPv2c_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
	}
	else {
		($session) = SNMP_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
	}
	if ( not defined($session) ) { 
		warn returnTime." runMib2ip, Session is not Defined Goodly to $node.\n"; 
		goto END_runMib2ip;
	}
	### KS 2 Jan 03 - Adding Windows servers for mib2ip stats
	if ( $NMIS::systemTable{nodeModel} =~ /CiscoRouter|CatalystIOS|Accelar|Windows|Redback|FoundrySwitch|Riverstone|MIB2/i ) { # expand to MIB2 flag in models.csv ??
		if ($collect eq "true") {
			(	$snmpTable{ipInReceives},
				$snmpTable{ipInHdrErrors},
				$snmpTable{ipInAddrErrors},
				$snmpTable{ipForwDatagrams},
				$snmpTable{ipInUnknownProtos},
				$snmpTable{ipInDiscards},
				$snmpTable{ipInDelivers},
				$snmpTable{ipOutRequests},
				$snmpTable{ipOutDiscards},
				$snmpTable{ipOutNoRoutes},
				$snmpTable{ipReasmReqds},
				$snmpTable{ipReasmOKs},
				$snmpTable{ipReasmFails},
				$snmpTable{ipFragOKs},
				$snmpTable{ipFragFails},
				$snmpTable{ipFragCreates}
			) = $session->snmpget(  
				'ipInReceives',
				'ipInHdrErrors',
				'ipInAddrErrors',
				'ipForwDatagrams',
				'ipInUnknownProtos',
				'ipInDiscards',
				'ipInDelivers',
				'ipOutRequests',
				'ipOutDiscards',
				'ipOutNoRoutes',
				'ipReasmReqds',
				'ipReasmOKs',
				'ipReasmFails',
				'ipFragOKs',
				'ipFragFails',
				'ipFragCreates'
			);
			if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
				logMessage( "runMib2ip, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				goto END_runMib2ip;
			}
			if ($debug) { 
				print returnTime." MIB2 IP Stats Summary\n";
				for $index ( sort keys %snmpTable ) {
					print "\t $index=$snmpTable{$index}\n";
				}
			}
			
			# update RRD Database
			&updateRRDDB(type => "mib2ip", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype});
			$NMIS::systemTable{typedraw} .= ",ip,frag";
			#
		} # collect eq true

	}	
	# Finished with the SNMP
	END_runMib2ip:
	if (defined $session) { $session->close(); }
} # end runMib2ip

sub thresholdProcess {
	### AS 16/4/01 - used by runThreshold.
	### ehg 13 sep 2002 allowed zero values to pass
	my %args = @_;
	if ( $args{value} =~ /^\d+$|^\d+\.\d+$/ ) {
		if ($debug) { print returnTime." Threshold: $args{event} level=$args{level} value=$args{value}\n"; }
		if ( $args{value} !~ /NaN/i ) {
			if ( $args{level} =~ /Normal/ ) { 
				checkEvent(node => $args{node}, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => $args{event}, level => $args{level}, details => "Threshold=$args{value}");
			}
			else {
				notify(node => $args{node}, role => $args{role}, type => $args{type}, event => $args{event}, level => $args{level}, details => "Threshold=$args{value}");
			}
		}
	}
}

### AS 1 April 02 - Implemented Thresholds Policy
sub runThreshold {
	my $node = shift;

	my %threshold;
	my $reportStats;
	my @tmparray;
	my @tmpsplit;
	my $level;
	my $event;
	my $operAvailability;
	my $totalUtil;
	my $inputUtil;
	my $outputUtil;
	my $reportStats;
	my @tmparray;
	my $intf;
	my $parentInterfaceIndex;
	my %interfaceTable;
	my $index;

	#available
	#response
	#reachable

	#util
	#cpu
	#mem
	#nonucast

	if ($debug) { 
		print "\n";
		print returnTime." Starting Thresholding node=$node collect=$NMIS::nodeTable{$node}{collect}\n"; 
	}
	
	loadSystemFile($node);
	foreach (keys %NMIS::systemTable) {
		if ( $_ =~ /typedraw/ ) { $NMIS::systemTable{$_} = (); } # clear this type of info
	}

	my %thresholds = loadCSV($NMIS::config{Thresholds_Table},$NMIS::config{Thresholds_Key},"\t");

	# Get the device health thresholds
	%threshold = summaryStats(node => $node,type => "health",start => "-15 minutes",end => time);
	
	# Now we have a nicely populated threshold table, lets compare them and issue some alerts
	$level = thresholdPolicy(threshold => "response", value =>$threshold{response}, node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, thresholds => \%thresholds);
	$event = "Proactive Response Time Threshold";
	thresholdProcess(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => $event, level => $level, value => $threshold{response});

	$level = thresholdPolicy(threshold => "reachable", value =>$threshold{reachable}, node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, thresholds => \%thresholds);
	$event = "Proactive Reachability Threshold";
	thresholdProcess(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => $event, level => $level, value => $threshold{reachable});

	$level = thresholdPolicy(threshold => "available", value =>$threshold{available}, node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, thresholds => \%thresholds);
	$event = "Proactive Interface Availability Threshold";
	thresholdProcess(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => $event, level => $level, value => $threshold{available});

	# there is extra stuff to threshold!
	# Will need to add something to summary stats to threshold switch stats
	if ( 	$NMIS::systemTable{nodeModel} =~ /CiscoRouter|CatalystIOS|CiscoATM|PIX|Redback|FoundrySwitch|Riverstone/ 
		and $NMIS::nodeTable{$node}{collect} eq "true" ) {
		%threshold = summaryStats(node => $node,type => "cpu",start => "-15 minutes",end => time);
	
		$level = thresholdPolicy(threshold => "cpu", value =>$threshold{avgBusy5min}, node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, thresholds => \%thresholds);
		$event = "Proactive CPU Threshold";
		thresholdProcess(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => $event, level => $level, value => $threshold{avgBusy5min});
	
		$level = thresholdPolicy(threshold => "mem", value =>$threshold{ProcMemFree}, node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, thresholds => \%thresholds);
		$event = "Proactive Memory Threshold";
		thresholdProcess(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => $event, level => $level, value => $threshold{ProcMemFree});
	}
	### AS 1 Apr 02 - Integrating Phil Reilly's Nortel changes
	elsif ( 	$NMIS::systemTable{nodeModel} =~ /Accelar/ 
		and $NMIS::nodeTable{$node}{collect} eq "true" ) {
		%threshold = summaryStats(node => $node,type => "acpu",start => "-15 minutes",end => time);
	
		$level = thresholdPolicy(threshold => "cpu", value =>$threshold{avgBusy5min}, node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, thresholds => \%thresholds);
		$event = "Proactive CPU Threshold";
		thresholdProcess(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => $event, level => $level, value => $threshold{rcSysCpuUtil});
	
	}
	# Win CPU server threshold
	elsif ( $NMIS::systemTable{nodeType} eq "server" and $NMIS::nodeTable{$node}{collect} eq "true") {
		if	( $NMIS::systemTable{nodeModel} =~ /Windows200/ ) {
			if ($NMIS::systemTable{hrNumCPU} != "") {
				for ( my $j=1; $j<= $NMIS::systemTable{hrNumCPU}; $j++) {
					%threshold = ();
					%threshold = summaryStats(node => $node,type => "hrsmpcpu",start => "-15 minutes",end => time,ifDescr => "hrsmpcpu$j");
					$level = thresholdPolicy(threshold => "hrsmpcpu", value => $threshold{hrCpuLoad}, node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, thresholds => \%thresholds);
					$event = "Proactive CPU $j Threshold";
					thresholdProcess(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType},event => $event, level => $level, value => $threshold{hrCpuLoad});
				}

			}
			else {
				if ($debug) { print returnTime. " Problem with Health Stats on $node.\n";}
			}
		}
		# hrmem are available only on net-snmp & windows2003
		if ( $NMIS::systemTable{nodeModel} eq "Windows2003" or $NMIS::systemTable{nodeVendor} eq "net-snmp") {
			%threshold = summaryStats(node => $node,type => "hrmem",start => "-15 minutes",end => time);
			if ( $threshold{hrMemSize} > 0 ) { # avoid divide by zero errors
				$threshold{hrMemUsed} = ($threshold{hrMemUsed} / $threshold{hrMemSize}) * 100;
				$level = thresholdPolicy(threshold => "hrmem", value =>$threshold{hrMemUsed}, node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, thresholds => \%thresholds);
				$event = "Proactive Memory Threshold";
				thresholdProcess(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => $event, level => $level, value => $threshold{hrMemUsed});
			}
			if ($threshold{hrVMemSize} > 0) {
				$threshold{hrVMemUsed} = ($threshold{hrVMemUsed} / $threshold{hrVMemSize}) * 100;
				$level = thresholdPolicy(threshold => "hrmem", value =>$threshold{hrVMemUsed}, node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, thresholds => \%thresholds);
				$event = "Proactive Virtual Memory Threshold";
				thresholdProcess(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => $event, level => $level, value => $threshold{hrVMemUsed});
			}
		}	
		if ($NMIS::systemTable{hrNumDisk} != "") {
			for ( my $j=1; $j<= $NMIS::systemTable{hrNumDisk}; $j++) {
				%threshold = summaryStats(node => $node,type => "hrdisk",start => "-15 minutes",end => time,ifDescr => "hrdisk$j");
				if ( $threshold{hrDiskSize} > 0 ) { # avoid divide by zero errors
					$threshold{hrDiskUsed} = ($threshold{hrDiskUsed} / $threshold{hrDiskSize}) * 100;
					$level = thresholdPolicy(threshold => "hrdisk", value =>$threshold{hrDiskUsed}, node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, thresholds => \%thresholds);
					$event = "Proactive Disk $j Threshold";
					thresholdProcess(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => $event, level => $level, value => $threshold{hrDiskUsed});
				}
			}	
		}
	} # end of type=server
	### Andrew Sargent - Modem Threshold
	if ( 	$NMIS::systemTable{nodeModel} =~ /CiscoRouter/ 
		and $NMIS::nodeTable{$node}{collect} eq "true"
		and $NMIS::systemTable{InstalledModems} gt 0
	) {
		%threshold = summaryStats(node => $node,type => "modem",start => "-15 minutes",end => time);
		# avoid divide by zero errors
		if ( $threshold{TotalModems} > 0 ) {
			$threshold{ModemsDead} = ($threshold{ModemsDead} / $threshold{TotalModems}) * 100;
			$threshold{ModemsUnavailable} = ($threshold{ModemsUnavailable} / $threshold{TotalModems}) * 100;
			$level = thresholdPolicy(threshold => "modem", value =>$threshold{ModemsDead}, node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, thresholds => \%thresholds);
			$event = "Proactive Dead Modem Threshold";
			thresholdProcess(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => $event, level => $level, value => $threshold{ModemsDead});
			$level = thresholdPolicy(threshold => "modem_util", value =>$threshold{ModemsUnavailable}, node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, thresholds => \%thresholds);
			$event = "Proactive Modem Utilisation Threshold";
			thresholdProcess(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => $event, level => $level, value => $threshold{ModemsUnavailable});
		}
	}
	### Call Threshold
	### Mike McHenry 2005
	if ( 	$NMIS::systemTable{nodeModel} =~ /CiscoRouter/
		and $NMIS::nodeTable{$node}{collect} eq "true"
		and $NMIS::systemTable{InstalledVoice} > 0
	) {
		%interfaceTable = ();
		my %hash = readVartoHash("$node-calls");
		foreach my $key (keys %hash) {
			$interfaceTable{$hash{$key}{'parentintfIndex'}}{'parentintfDescr'} = $hash{$key}{'parentintfDescr'} ;
		}
		# Extract the interface statics and summaries for display in a second.
		foreach my $intf (keys %interfaceTable) {
			my $ifDescr = $interfaceTable{$intf}{'parentintfDescr'};

			%threshold = summaryStats(node => $node,type => "calls",start => "-15 minutes",end => time,ifDescr => $ifDescr);

			my $AvailableCallCount = $threshold{AvailableCallCount} ;
			my $totalIdle = $threshold{totalIdle} ;
				# avoid divide by zero errors
			if ( $AvailableCallCount > 0 ) {
				$totalIdle = ( 100 - ( $totalIdle / $AvailableCallCount) * 100);
				my $rounded = sprintf "%.2f", $totalIdle;
				$level = thresholdPolicy(threshold => "calls_util", value => $rounded, node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, interface => $ifDescr, thresholds => \%thresholds);
				$event = "Proactive Calls Utilisation Threshold Interface=$ifDescr";
				thresholdProcess(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => $event, level => $level, value => $rounded);
			}
			else {
				if ($debug) { print returnTime." Threshold: Problem with Call Stats on $node, intf $intf.\n"; }
			}
		} # FOR LOOP
	}

	# Threshold interface utilisation!  Easy to do, just take an hour or so.
	# hmmmm I was wrong, about 20mins plus some testing. (I love reusable code)
	### KS 2 Jan 03 - Changing check for Win2000 to Windows
	if ( 	$NMIS::systemTable{nodeModel} =~ /Catalyst6000|Catalyst5000Sup3|Catalyst5005|Catalyst5000|CiscoRouter|CatalystIOS|CiscoATM|generic|PIX|FreeBSD|SunSolaris|Windows|Accelar|BayStack|Redback|FoundrySwitch|Riverstone|MIB2/i
		and $NMIS::nodeTable{$node}{collect} eq "true"
	) {
		%interfaceTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-interface.dat","ifIndex","\t");
		# Extract the interface statics and summaries for display in a second.
		foreach $intf (keys %interfaceTable) {
			# Don't do any stats cause the interface is not one we collect
			if ( $interfaceTable{$intf}{collect} eq "true" ) { 
				%threshold = ();
				# Get the link availability from the local node!!!
				### EHG 28/8/02
				### if a framerelay-subinterface, fudge the ifspeed (CIR) to the parent interface ifspeed (PIR) to prevent utilisation threshold alarms on CIR exceeded
				if ( $interfaceTable{$intf}{ifType} eq "frameRelay-subinterface" and $NMIS::config{frame_parent_thresholding} eq "true" ) {
					$interfaceTable{$intf}{interface} =~ /(.*)-/;  # capture everything upto the last '-' to get serialx-x from serialx-x-xxx
					# as interfaceTable is now keyed by ifIndex, need to look in table for interface match and pull the index
					foreach $index (keys %interfaceTable ) {
						if ( $interfaceTable{$index}{interface} eq $1 ) {
							$parentInterfaceIndex = $index;
						}
					}
					if ($debug) {
						print "\t $node $intf $interfaceTable{$intf}{ifType} CIR=$interfaceTable{$intf}{ifSpeed} PIR=$interfaceTable{$parentInterfaceIndex}{ifSpeed} Using PIR for interface utilisation threshold\n";
					}
					%threshold = summaryStats(node => $node,type => "util",start => "-15 minutes",end => time,ifDescr => $interfaceTable{$intf}{ifDescr},speed => $interfaceTable{$parentInterfaceIndex}{ifSpeed});
				}
				else {				
					%threshold = summaryStats(node => $node,type => "util",start => "-15 minutes",end => time,ifDescr => $interfaceTable{$intf}{ifDescr},speed => $interfaceTable{$intf}{ifSpeed});
				}

				# Interface Input Utilisation
				$level = thresholdPolicy(threshold => "util", value => $threshold{inputUtil}, node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, interface => $interfaceTable{$intf}{ifDescr}, thresholds => \%thresholds);
				$event = "Proactive Interface Input Utilisation Threshold Interface=$interfaceTable{$intf}{ifDescr}";
				thresholdProcess(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => $event, level => $level, value => $threshold{inputUtil});

				# Interface Output Utilisation
				$level = thresholdPolicy(threshold => "util", value => $threshold{outputUtil}, node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, interface => $interfaceTable{$intf}{ifDescr}, thresholds => \%thresholds);
				$event = "Proactive Interface Output Utilisation Threshold Interface=$interfaceTable{$intf}{ifDescr}";
				thresholdProcess(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => $event, level => $level, value => $threshold{outputUtil});

				# Interface Availability
				$level = thresholdPolicy(threshold => "int_avail", value => $threshold{availability}, node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, interface => $interfaceTable{$intf}{ifDescr}, thresholds => \%thresholds);
				$event = "Proactive Availability Threshold Interface Interface=$interfaceTable{$intf}{ifDescr}";
				thresholdProcess(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => $event, level => $level, value => $threshold{availability});
				
				# Non Unicast traffic (broadcast/multicast)
				if ( $interfaceTable{$intf}{ifType} =~ /$qr_int_stats/i 
					and $NMIS::systemTable{nodeType} =~ /router|switch/ 	# exclude server and generic for now - need MIB-II switch here !
					and $NMIS::systemTable{nodeModel} !~ /SSII 3Com|generic|PIX|MIB2/i 		# and exclude 3Com as well - should handle with models.csv MIBII switch
				) {
					%threshold = summaryStats(node => $node,type => "pkts",start => "-15 minutes",end => time,ifDescr => $interfaceTable{$intf}{ifDescr},speed => $interfaceTable{$intf}{ifSpeed});

					$level = thresholdPolicy(threshold => "nonucast", value => $threshold{ifInNUcastPkts}, node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, interface => $interfaceTable{$intf}{ifDescr}, thresholds => \%thresholds);
					$event = "Proactive Interface Input NonUnicast Threshold Interface=$interfaceTable{$intf}{ifDescr}";
					thresholdProcess(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => $event, level => $level, value => $threshold{ifInNUcastPkts});

					$level = thresholdPolicy(threshold => "nonucast", value => $threshold{ifOutNUcastPkts}, node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, interface => $interfaceTable{$intf}{ifDescr}, thresholds => \%thresholds);
					$event = "Proactive Interface Output NonUnicast Threshold Interface=$interfaceTable{$intf}{ifDescr}";
					thresholdProcess(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => $event, level => $level, value => $threshold{ifOutNUcastPkts});
				}
			}
		} # FOR LOOP
	}
} # end runThreshold

#
# structure of the hash:
# device name => email, ccopy, netsend, pager
#	target
#  		serial
#			subject
#			message
#			priority
# Cologne.

sub sendMSG {

	my $msgTable = shift;
	my $device;
	my $target;
	my $serial;

	foreach $device (keys %$msgTable) {
		if ($device eq "email") {
			foreach $target (keys %{%$msgTable->{$device}}) {
				foreach $serial (keys %{%$msgTable->{$device}{$target}}) {
					sendEmail(
						to => $target, 
						subject => $$msgTable{$device}{$target}{$serial}{subject},
						body => $$msgTable{$device}{$target}{$serial}{message},
						from => $NMIS::config{mail_from}, 
						server => $NMIS::config{mail_server}, 
						domain => $NMIS::config{mail_domain},
						priority => $$msgTable{$device}{$target}{$serial}{priority},
						debug => $NMIS::debug
					);
					if ($debug) { print returnTime." sendMSG, Escalation Email Notification sent to $target\n"; }
				}
			}
		} # end email
		### Carbon copy notifications - no action required - FYI only.
		elsif ( $device eq "ccopy" ) {
			foreach $target (keys %{%$msgTable->{$device}}) {
				foreach $serial (keys %{%$msgTable->{$device}{$target}}) {
					sendEmail(
						to => $target, 
						subject => $$msgTable{$device}{$target}{$serial}{subject}, 
						body => $$msgTable{$device}{$target}{$serial}{message},
						from => $NMIS::config{mail_from}, 
						server => $NMIS::config{mail_server}, 
						domain => $NMIS::config{mail_domain},
						priority => $$msgTable{$device}{$target}{$serial}{priority},
						debug => $NMIS::debug
					);
					if ($debug) { print returnTime." sendMSG, Escalation CC Email Notification sent to $target\n"; }
				}
			}
		} # end ccopy
		# now the netsends
		elsif ( $device eq "netsend" ) {
			foreach $target (keys %{%$msgTable->{$device}}) {
				foreach $serial (keys %{%$msgTable->{$device}{$target}}) {
					# read any stdout messages and throw them away
					if ($^O =~ /win32/i) {
						# win32 platform
						my $dump=`net send $target $$msgTable{$device}{$target}{$serial}{message}`;
						}
					else {
						# Linux box
						my $dump=`echo $$msgTable{$device}{$target}{$serial}{message}|smbclient -M $target`;
						}
					if ($debug) { print returnTime." sendMSG, $$msgTable{$device}{$target}{$serial}{message} to $target\n";}
				} # end netsend
			}
		}
		# now the pagers
		elsif ( $type eq "pager" ) {
			foreach $target (keys %{%$msgTable->{$device}}) {
				foreach $serial (keys %{%$msgTable->{$device}{$target}}) {
					sendSNPP(
						server => $NMIS::config{snpp_server},
						pagerno => $target,
						message => $$msgTable{$device}{$target}{$serial}{message}
					);
					if ($debug) { print returnTime." sendMSG, SendSNPP to $target\n"; }
				}
			} # end pager
		}
		else {
			if ($debug) { print returnTime." sendMSG, ERROR unknown device $device\n";}
		}
	}
}


### AS 6 June 2002 - Added escalate 0, to allow fast escalation and to implement 
### consistent policies for notification.  This also helps to get rid of flapping
### things, ie if escalate0 = 5 then an interface goes down, no alert sent, next 
### poll interface goes up and event cancelled!  Downside is a little longer before
### receiving first notification, so it depends on what the support SLA is.
sub runEscalate {

	my $outage_time;
	my $planned_outage;
	my $event_hash;
	my %location_data;
	my $time;
	my $escalate;
	my $event_age;
	my %contact_table;
	my %esc_table;
	my $esc_key;
	my $event;
	my $index;
	my $group;
	my $role;
	my $type;
	my $details;
	my @x;
	my $k;
	my $level;
	my $contact;
	my $target;
	my $field;
	my %keyhash;
	my $ifDescr;
	my %msgTable;
	my $serial = 0;
	my $serial_ns = 0;
	
	if ($debug) { print "\n".returnTime." Running escalate...\n"; }
	
	%contact_table = loadCSV($NMIS::config{Contacts_Table},$NMIS::config{Contacts_Key},"\t");
	# load the escalation policy table
	#%esc_table = loadCSV($NMIS::config{Escalation_Table},$NMIS::config{Escalation_Key},"\t");
	# pull in the table as a HoA, as we are keying by a lessor number of fields than we wrote it with in view.pl
	%esc_table = loadCSVarray($NMIS::config{Escalation_Table},"Group:Role:Type:Event","\t");

	# Load the event table into the hash
	# have to maintain a lock over all of this
	# we are out of threading code now, so no great problem with holding the lock while we send emails etc.
	my $handle = &loadEventStateLock;

 	# load the interface file to later check interface collect status.
	loadInterfaceInfo;

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


LABEL_ESC:	foreach $event_hash ( sort keys %NMIS::eventTable )  {

		# lets start with checking that we have a valid node -the node may have been deleted.
		if ( !exists $NMIS::nodeTable{$NMIS::eventTable{$event_hash}{node}}{node} ) {
			print "\t runEscalate: deleted event record $NMIS::eventTable{$event_hash}{node} $NMIS::eventTable{$event_hash}{event} no matching node found\n" if $debug;
			&logEvent("$NMIS::eventTable{$event_hash}{node}", "Deleted Event: $NMIS::eventTable{$event_hash}{event}", "Normal", "$NMIS::eventTable{$event_hash}{details}");
			delete $NMIS::eventTable{$event_hash}{node};
			next LABEL_ESC;
		}

		# and checking that we have a valid collectable interface -since the event the interface may have been deleted, or set to no collect.
		# NMIS::interfaceInfo is keyed by node_ifdescr
		# get the ifdescr out.
		if ( $NMIS::eventTable{$event_hash}{event} =~ /interface=(.+?)(?:\s|$)/i ) { $ifDescr = lc $1 }
		elsif ( $NMIS::eventTable{$event_hash}{details} =~ /interface=(.+?)(?:\s|$)/i ) { $ifDescr = lc $1 }
		else { $ifDescr = "" }

		if ( $NMIS::interfaceInfo{"$NMIS::eventTable{$event_hash}{node}_$ifDescr"}{collect} eq 'false' ) {
			print "\t runEscalate: deleted event record $NMIS::eventTable{$event_hash}{node} $NMIS::eventTable{$event_hash}{event} no matching interface or no collect $ifDescr\n" if $debug;
			&logEvent("$NMIS::eventTable{$event_hash}{node}", "Deleted Event: $NMIS::eventTable{$event_hash}{event}", "Normal", " no matching interface or no collect ifDescr=$ifDescr $NMIS::eventTable{$event_hash}{details}");
			delete $NMIS::eventTable{$event_hash}{node};
			next LABEL_ESC;
		}

		# if an planned outage is in force, keep writing the start time of any unack event to the current start time
		# so when the outage expires, and the event is still current, we escalate as if the event had just occured
	    if ( outageCheck($NMIS::eventTable{$event_hash}{node},time) eq "true" and $NMIS::eventTable{$event_hash}{ack} eq "false" ) {
			$NMIS::eventTable{$event_hash}{startdate} = time;
		}
		# set the current event time
		$outage_time = time - $NMIS::eventTable{$event_hash}{startdate};

	    # if we are to escalate, this event must not be part of a planned outage and un-ack.
	    if ( 	outageCheck($NMIS::eventTable{$event_hash}{node},time) ne "true" 
	    		and $NMIS::eventTable{$event_hash}{ack} eq "false"
	    ) {

			# we have list of nodes that this node depends on in $NMIS::nodeTable{$runnode}{depend}
			# if any of those have a current Node Down alarm, then lets just move on with a debug message
			# should we log that we have done this - maybe not....

			if ( exists $NMIS::nodeTable{$NMIS::eventTable{$event_hash}{node}}{depend} ) {
				foreach my $node_depend ( split /,/ , lc($NMIS::nodeTable{$NMIS::eventTable{$event_hash}{node}}{depend}) ) {
					next if $node_depend eq "N/A" ;		# default setting
					next if $node_depend eq $NMIS::eventTable{$event_hash}{node};	# remove the catch22 of self dependancy.
					if ( &eventExist($node_depend, "Node Down", "Ping failed" ) eq "true" ) {
						if ($debug) { print "\t runEscalate: NOT escalating $NMIS::eventTable{$event_hash}{node} $NMIS::eventTable{$event_hash}{event} as dependant $node_depend is reported as down\n"; }
						next LABEL_ESC;
					}
				}
			}

			undef %keyhash;		# clear this every loop
			$escalate = $NMIS::eventTable{$event_hash}{escalate};	# save this as a flag

			# now depending on the event escalate the event up a level or so depending on how long it has been active
			# now would be the time to notify as to the event. node down every 15 minutes, interface down every 4 hours?
			# maybe a deccreasing run 15,30,60,2,4,etc
			# proactive events would be escalated daily
			# when escalation hits 10 they could auto delete?
			# core, distrib and access could escalate at different rates.

			# note - all sent to lowercase here to get a match - as loadCVS sets all to lc
			loadSystemFile($NMIS::eventTable{$event_hash}{node});
			$group = lc($NMIS::nodeTable{$NMIS::eventTable{$event_hash}{node}}{group});
			$role = lc($NMIS::systemTable{roleType});
			$type = lc($NMIS::systemTable{nodeType});

			# trim the (proactive) event down to the first 4 keywords or less.
			$event = "";
			my $i = 0;
			foreach $index ( split /( )/ , lc($NMIS::eventTable{$event_hash}{event}) ) {		# the () will pull the spaces as well into the list, handy !
				$event .= $index;
				last if $i++ == 6;				# max of 4 splits, with no trailing space.
			}

			if ($debug) { print "\t Looking for Event to Escalation Table match for Event[ Node:$NMIS::eventTable{$event_hash}{node} Event:$event Details:$NMIS::eventTable{$event_hash}{details} ]\n"; }
			# Escalation_Key=Group:Role:Type:Event
			my @keylist = (
						$group."_".$role."_".$type."_".$event ,
						$group."_".$role."_".$type."_"."default",
						$group."_".$role."_"."default"."_".$event ,
						$group."_".$role."_"."default"."_"."default",
						$group."_"."default"."_".$type."_".$event ,
						$group."_"."default"."_".$type."_"."default",
						$group."_"."default"."_"."default"."_".$event ,
						$group."_"."default"."_"."default"."_"."default",
						"default"."_".$role."_".$type."_".$event ,
						"default"."_".$role."_".$type."_"."default",
						"default"."_".$role."_"."default"."_".$event ,
						"default"."_".$role."_"."default"."_"."default",
						"default"."_"."default"."_".$type."_".$event ,
						"default"."_"."default"."_".$type."_"."default",
						"default"."_"."default"."_"."default"."_".$event ,
						"default"."_"."default"."_"."default"."_"."default"
			);

			# lets allow all possible keys to match !
			# so one event could match two or more escalation rules
			# can have specific notifies to one group, and a 'catch all' to manager for example.

			foreach ( @keylist ) {
				if  ( exists $esc_table{$_} and defined ($k=testNode($event_hash, $_)) ) { $keyhash{$_} = $k; }
			}

			foreach $esc_key ( keys %keyhash ) {
				# have a matching escalation record for the hash key, and an index into the array.
				$k = $keyhash{$esc_key};	# readability				
				if ($debug) { print "\t Matched Escalation Table Group:$esc_table{$esc_key}{Group}[$k] Role:$esc_table{$esc_key}{Role}[$k] Type:$esc_table{$esc_key}{Type}[$k] Event:$esc_table{$esc_key}{Event}[$k] Event_Node:$esc_table{$esc_key}{Event_Node}[$k] Event_Details:$esc_table{$esc_key}{Event_Details}[$k]\n"; }
				if ($debug) { print "\t Pre Escalation : $NMIS::eventTable{$event_hash}{node} Event $NMIS::eventTable{$event_hash}{event} is $outage_time seconds old escalation is $NMIS::eventTable{$event_hash}{escalate}\n"; }

				# default escalation for events
				# 28 apr 2003 moved times to nmis.conf
				if (    $outage_time >= $NMIS::config{escalate10} ) { $NMIS::eventTable{$event_hash}{escalate} = 10; }
				elsif ( $outage_time >= $NMIS::config{escalate9} ) { $NMIS::eventTable{$event_hash}{escalate} = 9; }
				elsif ( $outage_time >= $NMIS::config{escalate8} ) { $NMIS::eventTable{$event_hash}{escalate} = 8; }
				elsif ( $outage_time >= $NMIS::config{escalate7} ) { $NMIS::eventTable{$event_hash}{escalate} = 7; }
				elsif ( $outage_time >= $NMIS::config{escalate6} ) { $NMIS::eventTable{$event_hash}{escalate} = 6; }
				elsif ( $outage_time >= $NMIS::config{escalate5} ) { $NMIS::eventTable{$event_hash}{escalate} = 5; }
				elsif ( $outage_time >= $NMIS::config{escalate4} ) { $NMIS::eventTable{$event_hash}{escalate} = 4; }
				elsif ( $outage_time >= $NMIS::config{escalate3} ) { $NMIS::eventTable{$event_hash}{escalate} = 3; }
				elsif ( $outage_time >= $NMIS::config{escalate2} ) { $NMIS::eventTable{$event_hash}{escalate} = 2; }
				elsif ( $outage_time >= $NMIS::config{escalate1} ) { $NMIS::eventTable{$event_hash}{escalate} = 1; }
				elsif ( $outage_time >= $NMIS::config{escalate0} ) { $NMIS::eventTable{$event_hash}{escalate} = 0; }

				if ($debug) { print "\t Post Escalation: $NMIS::eventTable{$event_hash}{node} Event $NMIS::eventTable{$event_hash}{event} is $outage_time seconds old escalation is $NMIS::eventTable{$event_hash}{escalate}\n"; }
				if ($debug and $escalate == $NMIS::eventTable{$event_hash}{escalate}) {
					print "\t Next Notification Target would be Level";
					printf "%d", $NMIS::eventTable{$event_hash}{escalate} + 1;
					print " Contact: $esc_table{$esc_key}{'Level'.($NMIS::eventTable{$event_hash}{escalate}+1)}[$k]\n";
				} 

				# parse the HoA looking for a match against the regex expression in Escalation Table:Event_Node and Event_Details fields
				# can assume that array is linear for both these fields.
				sub testNode {
					my $hash = shift;
					my $esc_key = shift;
					foreach my $i ( 0 .. $#{ $esc_table{$esc_key}{Event_Node} } ) {
						if ( $NMIS::eventTable{$hash}{node} =~ /$esc_table{$esc_key}{Event_Node}[$i]/ and $NMIS::eventTable{$hash}{details} =~ /$esc_table{$esc_key}{Event_Details}[$i]/ ) { 
							#print "$NMIS::eventTable{$hash}{node} matches $esc_table{$esc_key}{Event_Node}[$i] and $NMIS::eventTable{$hash}{details} matches $esc_table{$esc_key}{Event_Details}[$i]\n";
							return $i;
						}
					}
					return undef;
				}

				# send a new email message as the escalation again.
				# ehg 25oct02 added win32 netsend message type (requires SAMBA on this host)
				if ( $escalate != $NMIS::eventTable{$event_hash}{escalate} ) {
					$event_age = convertSecsHours(time - $NMIS::eventTable{$event_hash}{startdate});
					$time = &returnDateStamp;

					# check if UpNotify is true, and save with this event, a unique key into the escalation.csv table so we can lookup the escalation hash
					# and send all the up event notifies when the event is cleared.
					if ( $esc_table{$esc_key}{UpNotify}[$k] eq "true" ) {
						$NMIS::eventTable{$event_hash}{notify} = $esc_key."_".$esc_table{$esc_key}{Event_Node}[$k]."_".$esc_table{$esc_key}{Event_Details}[$k];
					}

					# get the string of type email:contact1:contact2,netsend:contact1:contact2,pager:contact1:contact2,email:sysContact
					$level = lc($esc_table{$esc_key}{'Level'.$NMIS::eventTable{$event_hash}{escalate}}[$k]);

					if ( $level ne "" ) {
						# Now we have a string, check for multiple notify types
						foreach $field ( split "," , $level ) {
							$target = "";
							@x = split /:/ , $field;
							$type = shift @x;			# first entry is email, ccopy, netsend or pager
							if ( $type =~ /email|ccopy|pager/ ) {
								foreach $contact (@x) {
									# if sysContact, use device syscontact as key into the contacts table hash
									if ( $contact eq "syscontact" ) {
										$contact = $NMIS::systemTable{sysContact};
										if ($debug) { print "\t Using node $NMIS::eventTable{$event_hash}{node} sysContact $NMIS::systemTable{sysContact}\n";}
									}
									if ( exists $contact_table{$contact} ) {			
										if ( dutyTime(\%contact_table, $contact) ) {	# do we have a valid dutytime ??
											if ($type eq "pager") {
												$target = $target ? $target.",".$contact_table{$contact}{Pager} : $contact_table{$contact}{Pager};
											} else {
												$target = $target ? $target.",".$contact_table{$contact}{Email} : $contact_table{$contact}{Email};
											}
										}
									}
									else {
										if ($debug) { print "\t Contact $contact not found in Contacts table\n";}
									}
								} #foreach

								# no email targets found, and if default contact not found, assume we are not covering 24hr dutytime in this slot, so no mail.
								# maybe the next levelx escalation field will fill in the gap
								if ( !$target ) { 
									if ( $type eq "pager" ) {
										$target = $contact_table{default}{Pager};
									} else { 
										$target = $contact_table{default}{Email};
									}
									if ($debug) { print "\t No $type contact matched (maybe check DutyTime and TimeZone?) - looking for default contact $target\n"; }
								}
								if ( $target ) {
									foreach my $trgt ( split /,/, $target ) {
										my $message;
										my $priority;
										if ( $type eq "pager" ) {
											$msgTable{$type}{$trgt}{$serial_ns}{message} = "NMIS: Esc. $NMIS::eventTable{$event_hash}{escalate} $event_age $NMIS::eventTable{$event_hash}{node} $NMIS::eventTable{$event_hash}{event_level} $NMIS::eventTable{$event_hash}{event} $NMIS::eventTable{$event_hash}{details}";
											$serial_ns++ ;
										} else {
											if ($type eq "ccopy") { 
												$message = "FOR INFORMATION ONLY\n";
												$priority = &eventToSMTPPri("Normal");
											} else {
												$priority = &eventToSMTPPri($NMIS::eventTable{$event_hash}{event_level}) ;
											}

											$message .= "Node:\t$NMIS::eventTable{$event_hash}{node}\nNotification at Level$NMIS::eventTable{$event_hash}{escalate}\nEvent Elapsed Time:\t$event_age\nSeverity:\t$NMIS::eventTable{$event_hash}{event_level}\nEvent:\t$NMIS::eventTable{$event_hash}{event}\nDetails:\t$NMIS::eventTable{$event_hash}{details}\nhttp://$NMIS::config{nmis_host}$NMIS::config{nmis}?type=event&node=$NMIS::eventTable{$event_hash}{node}\n\n";
											if ($NMIS::config{mail_combine} eq "true" ) {
												$msgTable{$type}{$trgt}{$serial}{count}++;
												$msgTable{$type}{$trgt}{$serial}{subject} = "NMIS Escalation Message, contains $msgTable{$type}{$trgt}{$serial}{count} message(s), $msgtime";
												$msgTable{$type}{$trgt}{$serial}{message} .= $message ;
												if ( $priority gt $msgTable{$type}{$trgt}{$serial}{priority} ){
													$msgTable{$type}{$trgt}{$serial}{priority} = $priority ;
												}
											} else {
												$msgTable{$type}{$trgt}{$serial}{subject} = "$NMIS::eventTable{$event_hash}{node} $NMIS::eventTable{$event_hash}{event} - $NMIS::eventTable{$event_hash}{details} at $msgtime" ;
												$msgTable{$type}{$trgt}{$serial}{message} = $message ;
												$msgTable{$type}{$trgt}{$serial}{priority} = $priority ;
												$msgTable{$type}{$trgt}{$serial}{count} = 1;
												$serial++;
											}
										}
									}
									&logEvent("$NMIS::eventTable{$event_hash}{node}", "Email/Pager to $target", "$NMIS::eventTable{$event_hash}{event_level}", "$NMIS::eventTable{$event_hash}{details}");
									if ($debug) { print "\t runEsc, Escalation $type Notification node=$NMIS::eventTable{$event_hash}{node} target=$target level=$NMIS::eventTable{$event_hash}{event_level} event=$NMIS::eventTable{$event_hash}{event} details=$NMIS::eventTable{$event_hash}{details} group=$NMIS::nodeTable{$NMIS::eventTable{$event_hash}{node}}{group}\n"; }
								}
							} # end email,ccopy,pager
							# now the netsends
							elsif ( $type eq "netsend" ) {
								my $message = "Escalation $NMIS::eventTable{$event_hash}{escalate} $NMIS::eventTable{$event_hash}{node} $NMIS::eventTable{$event_hash}{event_level} $NMIS::eventTable{$event_hash}{event} $NMIS::eventTable{$event_hash}{details} at $msgtime";
								foreach my $trgt ( @x ) {
									$msgTable{$type}{$trgt}{$serial_ns}{message} = $message ;
									$serial_ns++;
									if ($debug) { print "\t NetSend $message to $trgt\n";}
									&logEvent("$NMIS::eventTable{$event_hash}{node}", "NetSend $message to $trgt", "$NMIS::eventTable{$event_hash}{event_level}", "$NMIS::eventTable{$event_hash}{details}");
								} #foreach
							} # end netsend
							else {
								if ($debug) { print "\t ERROR runEscalate problem with escalation target unknown at level$NMIS::eventTable{$event_hash}{escalate} $level type=$type\n";}
							}
						} # foreach field
					} # endif $level
				} # if escalate
			} # foreach esc_key
		} # end of outage check
	} # foreach $event_hash
	# now write the hash back and release the lock
	writeEventStateLock($handle);
	# Cologne, send the messages now
	&sendMSG(\%msgTable);
} # end runEscalate

sub runUpdate {
	# assuming that nothing with collect eq to false has been sent here.
	my $node = shift;
	my $pingresult = shift;
	
	if ($debug) { print returnTime." Running an Update for node=$node, type=$NMIS::systemTable{nodeType}\n"; }
		
	# Update supported by all devices
	&createSystemFile($node, $pingresult);
	&createInterfaceFile($node);
	# CBQoS
	my $qosfile = "$NMIS::config{'<nmis_var>'}/$node-qos.dat";
	if ( -r $qosfile ) { unlink $qosfile; } # delete this file
	$qosfile = "$NMIS::config{'<nmis_var>'}/$node-qos.nmis";
	if ( -r $qosfile ) { unlink $qosfile; } # delete this file, sub runCBQoS create this again with new values
	# Calls
	my $callsfile = "$NMIS::config{'<nmis_var>'}/$node-calls.nmis";
	if ( -r $callsfile ) { unlink $callsfile; } # delete this file, sub runCalls create this again
}

sub runReachability {
	my $node = shift;
	my $pingresult = shift;
	
	my $cpuWeight;
	my $memWeight;
	my $responseWeight;
	my $interfaceWeight;
	my %interfaceTable;
	my $intf;
	my $inputUtil;
	my $outputUtil;
	my $totalUtil;
	my $index;
	my $reportStats;
	my @tmparray;
	my @tmpsplit;
	my %util;
	my $intcount;
	my $intsummary;
	my $intWeight;
	my $index;
	
	if ($debug) { print returnTime." Running Reachability node=$node type=$NMIS::nodeTable{$node}{devicetype}\n"; }
	
	# Things which don't do collect get 100 for availability
	if ( $reach{availability} eq "" and $collect eq "false" ) { 
		$reach{availability} = "100"; 
	}
	elsif ( $reach{availability} eq "" ) { $reach{availability} = "U"; }
	
	# Health should actually reflect a combination of these values
	# ie if response time is high health should be decremented.
	if ( $pingresult == 100 and $snmpresult == 100 ) {
		$reach{reachability} = 100;
		if ( $reach{operCount} > 0 ) {
			$reach{availability} = $reach{operStatus} / $reach{operCount}; 
		}

		#### new ping code as of Feb26 2004 ####
		$reach{responsetime}= $ping_min;		# use the best response time we got from the previous ping test.

		($reach{responsetime},$responseWeight) = weightResponseTime($reach{responsetime});
		
		### KS 2 Jan 03 - Changing check for Win2000 to Windows
		if ( $NMIS::nodeTable{$node}{collect} eq "true" and $NMIS::systemTable{nodeModel} !~ /generic|MIB2|FreeBSD|SunSolaris|Windows/i ) {
			if    ( $reach{cpu} <= 10 ) { $cpuWeight = 100; }
			elsif ( $reach{cpu} <= 20 ) { $cpuWeight = 90; }
			elsif ( $reach{cpu} <= 30 ) { $cpuWeight = 80; }
			elsif ( $reach{cpu} <= 40 ) { $cpuWeight = 70; }
			elsif ( $reach{cpu} <= 50 ) { $cpuWeight = 60; }
			elsif ( $reach{cpu} <= 60 ) { $cpuWeight = 50; }
			elsif ( $reach{cpu} <= 70 ) { $cpuWeight = 40; }
			elsif ( $reach{cpu} <= 80 ) { $cpuWeight = 30; }
			elsif ( $reach{cpu} <= 90 ) { $cpuWeight = 20; }
			elsif ( $reach{cpu} <= 100 ) { $cpuWeight = 10; }
			
			if    ( $reach{mem} >= 40 ) { $memWeight = 100; }
			elsif ( $reach{mem} >= 35 ) { $memWeight = 90; }
			elsif ( $reach{mem} >= 30 ) { $memWeight = 80; }
			elsif ( $reach{mem} >= 25 ) { $memWeight = 70; }
			elsif ( $reach{mem} >= 20 ) { $memWeight = 60; }
			elsif ( $reach{mem} >= 15 ) { $memWeight = 50; }
			elsif ( $reach{mem} >= 10 ) { $memWeight = 40; }
			elsif ( $reach{mem} >= 5 )  { $memWeight = 25; }
			elsif ( $reach{mem} >= 0 )  { $memWeight = 0; }
		}
		elsif ( $NMIS::nodeTable{$node}{collect} eq "true" and $NMIS::systemTable{nodeModel} eq "generic" ) {
			$cpuWeight = 100;
			$memWeight = 100;
			### ehg 16 sep 2002 also make interface aavilability 100% - I dont care about generic switches interface health !
			$reach{availability} = 100;
		}
		else {
			$cpuWeight = 100;
			$memWeight = 100;
			$reach{availability} = 100;
		}
		
		### AS 13/4/01 - Added little fix for when no interfaces are collected.
		if ( $reach{availability} !~ /\d+/ ) {
			$reach{availability} = "100";
		}

		### ehg 13 sep 02 - Makes 3Com memory health weighting always 100, and CPU, and Interface availibility
		if ( $NMIS::systemTable{nodeModel} =~ /SSII 3Com/i ) {
			$cpuWeight = 100;
			$memWeight = 100;
			$reach{availability} = 100;

		}

		### AS 1/5/01 - Makes CatalystIOS memory health weighting always 100.
		## PR 11/11/01 - Add Baystack and Accelar
		if ( $NMIS::systemTable{nodeModel} =~ /CatalystIOS|Accelar|BayStack|Redback|FoundrySwitch|Riverstone/i ) {
			$memWeight = 100;
		}
		
		if ( $NMIS::nodeTable{$node}{collect} eq "true" ) {
			if ($debug) { print "\t Getting Interface Utilisation Health\n"; }
			$intcount = 0;
			$intsummary = 0;
			# check if interface file exists - node may not be updated as yet....
			if ( -e "$NMIS::config{'<nmis_var>'}/$node-interface.dat") {
				%interfaceTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-interface.dat","interface","\t");
				foreach $intf (keys %interfaceTable) {
					# Don't do any stats cause the interface is not one we collect
					if ( $interfaceTable{$intf}{collect} eq "true" ) { 
						# Get the link availability from the local node!!!
						%util = summaryStats(node => $node,type => "util",start => "-15 minutes",end => time,ifDescr => $interfaceTable{$intf}{ifDescr},speed => $interfaceTable{$intf}{ifSpeed});
						$intsummary = $intsummary + ( 100 - $util{inputUtil} ) + ( 100 - $util{outputUtil} );
						++$intcount;
						#print "in=$util{inputUtil} out=$util{outputUtil} intsumm=$intsummary count=$intcount\n";
					}
				} # FOR LOOP
			} else {
				if ( $debug ) { print "\t File $NMIS::config{'<nmis_var>'}/$node-interface.dat does not exist as yet - skipping Health\n";}
			}
			if ( $intsummary != 0 ) {
				$intWeight = sprintf( "%.2f", $intsummary / ( $intcount * 2 ));
			} else {
				$intWeight = "NaN"
			}
		}
		else {
			$intWeight = 100;	
		}
		
		# if the interfaces are unhealthy and lost stats, whack a 100 in there
		if ( $intWeight eq "NaN" or $intWeight > 100 ) { $intWeight = 100; }
		
		# Would be cool to collect some interface utilisation bits here.
		# Maybe thresholds are the best way to handle that though.  That
		# would pickup the peaks better.
		
		# Health is made up of a weighted values:
		### AS 16 Mar 02, implemented weights in nmis.conf
		$reach{health} = 	($reach{reachability} * $NMIS::config{weight_reachability}) + 
							($intWeight * $NMIS::config{weight_int}) +
							($responseWeight * $NMIS::config{weight_response}) + 
							($reach{availability} * $NMIS::config{weight_availability}) + 
							($cpuWeight * $NMIS::config{weight_cpu}) + 
							($memWeight * $NMIS::config{weight_mem})
							;
	}
	elsif ( $NMIS::nodeTable{$node}{collect} eq "false"
		and $pingresult == 100 
	) {
		$reach{reachability} = 100; 
		$reach{availability} = 100; 
		$reach{responsetime}= $ping_min;
		($reach{responsetime},$responseWeight) = weightResponseTime($reach{responsetime});
		$reach{health} = ($reach{reachability} * 0.9) + ( $responseWeight * 0.1);
	}
	elsif ( $pingresult == 0 and NMIS::outageCheck($node,time) eq "true" ) {
		$reach{reachability} = "U"; 
		$reach{availability} = "U"; 
		$reach{responsetime} = "U"; 
		$reach{health} = "U"; 
	} 
	elsif ( $pingresult == 100 and $snmpresult == 0 ) {
		$reach{reachability} = 100; 
		$reach{availability} = "U";  
		$reach{responsetime}= $ping_min;
		$reach{health} = "U"; 
	}
	else {
		$reach{reachability} = 0; 
		$reach{availability} = "U"; 
		$reach{responsetime} = "U"; 
		$reach{health} = 0;
	}

	$reach{loss} = $ping_loss; # added 04-12-04

	# lets put a debug on the outage state - so we know what is going on
	if ($debug) { print "\t Outage Check: Outage for $node is @{[NMIS::outageCheck($node,time)]}\n"; }
	
	#if ($debug) { print returnTime." Health: collect=$NMIS::nodeTable{$node}{collect} ping=$pingresult reach=$reach{reachability} avail=$reach{availability} rt=$reach{responsetime} cpu=$cpuWeight mem=$memWeight int=$intWeight health=$reach{health}\n"; }
	if ($debug) { 
		print returnTime." Reachability and Metric Stats Summary\n";
		print "\t collect=$NMIS::nodeTable{$node}{collect}\n";
		print "\t ping=$pingresult (normalised)\n";
		print "\t cpuWeight=$cpuWeight (normalised)\n";
		print "\t memWeight=$memWeight (normalised)\n";
		print "\t intWeight=$intWeight (100 less the actual total interface utilisation)\n";
		print "\t responseWeight=$responseWeight (normalised)\n";
		for $index ( sort keys %reach ) {
			print "\t $index=$reach{$index}\n";
		}
	}
	#if ($debug) { print returnTime." Doing Reachability database stuff!\n"; }

	&updateRRDDB(type => "reach",node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype});
	$NMIS::systemTable{typedraw} .= ",health,response";
	#
	# if a slave box, post the reachability stats to the shared hash
	# this assumes all reach stats for all nodes on the box to be copied up, if that is not what we want, need a flag in the nodetable.
	# only do this on collect
	if ( $NMIS::config{slave} eq 'true' and $type eq 'collect' ) {
		# indexed by $node - so no need to lock it.
		$cache->write($node, {
					reachability => $reach{reachability}, 
					availability => $reach{availability},  
					responsetime => $reach{responsetime},
					health => $reach{health},
					devicetype => $NMIS::nodeTable{$node}{devicetype},
					option => 'RRDDB',
					rrd => 'reach',
					node => $node,
					time => time()		# toss the time in - may be used at master to sync rrd.
					} );	
	}
}

sub createSystemFile {
	my $node = shift;
	my $pingresult = shift;
	my %sysnode;
	
	undef %NMIS::systemTable;
	if ( $NMIS::nodeTable{$node}{collect} eq "true" and $pingresult == 100 ) {
		&getNodeInfo($node);
	}
	else {
		$writeSystem = "true"	
	}
	#This makes the nodes file overwrite the getNodeInfo bits.
	$NMIS::systemTable{netType} = $NMIS::nodeTable{$node}{net};
	$NMIS::systemTable{roleType} = $NMIS::nodeTable{$node}{role};
	$NMIS::systemTable{nodeType} = $NMIS::nodeTable{$node}{devicetype};

	# add in the group as well - saves time later
	$NMIS::systemTable{nodeGroup} = $NMIS::nodeTable{$node}{group};

	### add in anything we find from sysnode.csv - allows manual updating of system variables
	### warning - will overwrite what we got from the device - be warned !!!
	if ( -r $NMIS::config{SysNode_Table} ) {
		if ( %sysnode = &loadCSV("$NMIS::config{SysNode_Table}","$NMIS::config{SysNode_Key}","\t")) {
			if ( $sysnode{$node}{sysContact} ) { $NMIS::systemTable{sysContact} = $sysnode{$node}{sysContact} }
			if ( $sysnode{$node}{sysName} ) { $NMIS::systemTable{sysName} = $sysnode{$node}{sysName} }
			if ( $sysnode{$node}{sysLocation} ) { $NMIS::systemTable{sysLocation} = $sysnode{$node}{sysLocation} }
			if ($debug) { print "\t createSystemFile: Updated systemTable from $NMIS::config{SysNode_Table}\n" }
		}
	}
	&writeSystemFile($node);
}

sub getNodeInfo {
	my $node = shift;
	my $message;
	
	my $session;
	my %enterprise = loadCSV($NMIS::config{Enterprise_Table},$NMIS::config{Enterprise_Key},"\t");
	my %models = loadCSV($NMIS::config{Model_Table},$NMIS::config{Model_Key},"\t");
	my $OID;
	my $oid_key;
	my @x;	

	if ($debug) { print returnTime." Getting Node Info using SNMP Ver: $NMIS::systemTable{snmpVer}\n"; }
	
	# only test for SNMPv2 support the first time the device is discovered
	# delete the system file or edit the snmpVer attribute to rediscover SNMP support.
	if ( $NMIS::systemTable{snmpVer} eq "" ) {
		# now open SNMPv2 and see if the device talks that!
		if ($debug) { print returnTime." Testing for SNMPv2 support\n"; }
		($session) = SNMPv2c_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
		if ( not defined($session) ) { 
			logMessage(" getNodeInfo, $node, Session is not Defined") if $debug; 
			goto END_getNodeInfo;
		}

		(	$NMIS::systemTable{sysObjectID},
			$NMIS::systemTable{sysUpTime}
		) = $session->snmpget (
			'sysObjectID', 
			'sysUpTime'
		);		
		if ( $SNMP_Simple::errmsg !~ /No answer|Unknown/ ) {
			$NMIS::systemTable{snmpVer} = "SNMPv2";
			if (defined $session) { $session->close(); }
			$SNMP_Simple::errmsg = "";
		}
		else {
			if (defined $session) { $session->close(); }
			print "\t SNMPv2 doesn't work. errmsg=$SNMP_Simple::errmsg\n" if $debug;
			$SNMP_Simple::errmsg = "";
			print returnTime." Testing for SNMPv1 support\n" if $debug;
			($session) = SNMP_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
			if ( not defined($session) ) { 
				warn returnTime." getNodeInfo, Session is not Defined Goodly to $node.\n"; 
				goto END_getNodeInfo;
			}
			(	$NMIS::systemTable{sysObjectID},
				$NMIS::systemTable{sysUpTime}
			) = $session->snmpget (
				'sysObjectID', 
				'sysUpTime'
			);
			
			if ( $SNMP_Simple::errmsg !~ /No answer|Unknown/ ) {
				if (defined $session) { $session->close(); }
				$NMIS::systemTable{snmpVer} = "SNMPv1";
				$SNMP_Simple::errmsg = "";
			}
			else {
				print "\t SNMPv1 doesn't work. errmsg=$SNMP_Simple::errmsg\n" if $debug;
				logMessage("getNodeInfo, $node, SNMP Error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				$NMIS::systemTable{snmpVer} = "none";
				goto END_getNodeInfo;
			}
		}
		if ($debug) { print returnTime." $node supports $NMIS::systemTable{snmpVer} version.\n"; }
	}

	if ($debug) { print returnTime." getNodeInfo opening SNMP Ver: $NMIS::systemTable{snmpVer}\n"; }
	if ( $NMIS::systemTable{snmpVer} eq "SNMPv2" ) {
		($session) = SNMPv2c_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
	}
	elsif ( $NMIS::systemTable{snmpVer} eq "SNMPv1" ) {
		($session) = SNMP_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
	}
	if ( not defined($session) ) { 
		logMessage("getNodeInfo, $node, Session is not Defined") if $debug;
		goto END_getNodeInfo;
	}
	
	(	$NMIS::systemTable{sysDescr},
		$NMIS::systemTable{sysObjectID},
		$NMIS::systemTable{sysUpTime},
		$NMIS::systemTable{sysContact},
		$NMIS::systemTable{sysName},
		$NMIS::systemTable{sysLocation},
		$NMIS::systemTable{ifNumber}
	)
	= $session->snmpget(
		'sysDescr', 
		'sysObjectID', 
		'sysUpTime', 
		'sysContact', 
		'sysName', 
		'sysLocation', 
		'ifNumber'
	);
	
	if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
		logMessage( " getNodeInfo, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
		$SNMP_Simple::errmsg = "";
		goto END_getNodeInfo;
	}
	elsif ( $NMIS::systemTable{sysObjectID} =~ /unprintable BER type/ 
			or $NMIS::systemTable{sysUpTime} =~ /unprintable BER type/ 
			or $NMIS::systemTable{ifNumber} =~ /unprintable BER type/
	) {
		$snmpresult = 0;
		logMessage("getNodeInfo, $node, SNMP ERROR: sysObjectID=$snmpTable{sysObjectID} sysUpTime=$snmpTable{sysUpTime} ifNumber=$snmpTable{ifNumber}") if $debug;
		$writeSystem = "true";
		goto END_getNodeInfo;
	}
	elsif ( $NMIS::systemTable{sysObjectID} eq "" 
			and $NMIS::systemTable{sysUpTime} eq "" 
			and $NMIS::systemTable{ifNumber} eq "" 
	) {
		$snmpresult = 0;
		logMessage("getNodeInfo, $node, SNMP elements empty sysObjectID=$snmpTable{sysObjectID} sysUpTime=$snmpTable{sysUpTime} ifNumber=$snmpTable{ifNumber}") if $debug;
		goto END_getNodeInfo;
	}
	
	### AS 1/4/01 - Added this for to support default contacts and locations.
	if ( $NMIS::systemTable{sysContact} eq "" ) { $NMIS::systemTable{sysContact} = "default"; }
	if ( $NMIS::systemTable{sysLocation} eq "" ) { $NMIS::systemTable{sysLocation} = "default"; }

	# Only continue processing if at least a couple of entries are valid.
	if (    $NMIS::systemTable{sysDescr} ne "" and $NMIS::systemTable{sysObjectID} ne "" ) {	      
		$writeSystem = "true";
		
		### ehg 11 Sep 02 pull / from VPN3002 system descr
		$NMIS::systemTable{sysDescr} =~ s/\// /g;

		# if the vendors product oid file is loaded, this will give product name.
		$NMIS::systemTable{sysObjectName} = SNMP_MIB::oid2name($NMIS::systemTable{sysObjectID});

		# Decide on vendor name.
		@x = split(/\./,$NMIS::systemTable{sysObjectID});
		$OID = $x[6];
		if ( $enterprise{$OID}{Enterprise} ne "" ) {
			$NMIS::systemTable{nodeVendor} = $enterprise{$OID}{Enterprise};
		}
		else { $NMIS::systemTable{nodeVendor} =  "Unknown"; }
		

		my $match = 0;
		if ($debug) { print returnTime." $node sysDescr=$NMIS::systemTable{sysDescr}\n"; }
		foreach my $model (sort { $a <=> $b } keys %models) {
			if ($debug>1) { print "  key=$model pattern=$models{$model}{sysDescr}\n"; }
			if ( ! $match 
				and $NMIS::systemTable{nodeVendor} eq $models{$model}{nodeVendor} 
				and $NMIS::systemTable{sysDescr} =~ /$models{$model}{sysDescr}/
			) {
				if ($debug) { print returnTime." $node Found a Model, $models{$model}{nodeModel}\n"; }
				if ($debug) { print "  pattern=$models{$model}{sysDescr} sysDescr=$NMIS::systemTable{sysDescr}\n"; }
				$match = 1;
				$NMIS::systemTable{nodeModel} = $models{$model}{nodeModel};
				$NMIS::systemTable{nodeType} = $models{$model}{nodeType};
				$NMIS::systemTable{netType} = $models{$model}{netType};
				$NMIS::systemTable{supported} = $models{$model}{supported};
				
				# now have syslog file set by model for granularity
				print "\t Syslog file set to $models{$model}{syslog}\n" if $debug;
				$NMIS::systemTable{syslog} = "$models{$model}{syslog}";

				last;
			}
		}
		if ( ! $match ) {
			$NMIS::systemTable{nodeModel} = $models{default}{nodeModel};
			#$NMIS::systemTable{nodeType} = $models{default}{nodeType};
			#$NMIS::systemTable{netType} = $models{default}{netType};
			$NMIS::systemTable{supported} = $models{default}{supported};
			
			# now have syslog file set by model for granularity
			print "\t Syslog file set to $models{default}{syslog}\n" if $debug;
			$NMIS::systemTable{syslog} = "$models{default}{syslog}";

		}
		
		# collect DNS location info. Update this info every update pass.
		$NMIS::systemTable{DNSloc} = "unknown";
		my $tmphostname = $node;
		if ( $NMIS::config{DNSLoc} eq "on" and $NMIS::netDNS == 1 ) {
			my ($rr, $lat, $lon);
			my $res   = Net::DNS::Resolver->new;
			if ($node =~ /\d+\.\d+\.\d+\.\d+/) {
				# find reverse lookup as this is an ip
				my $query = $res->query("$tmphostname","PTR");
				if ($query) {
					foreach $rr ($query->answer) {
						next unless $rr->type eq "PTR";
						$tmphostname = $rr->ptrdname;
						if ($debug) {
							print "\t DNS Reverse query $tmphostname\n" ;
						}
					}
				}
				else  {
					if ($debug) {
						print "\t DNS Reverse query failed: ", $res->errorstring, "\n" ;
					}
				}
			}
			#look up loc for hostname
			my $query = $res->query("$tmphostname","LOC");
			if ($query) {
				foreach $rr ($query->answer) {
					next unless $rr->type eq "LOC";
					($lat, $lon) = $rr->latlon;
					$NMIS::systemTable{DNSloc} = $lat . ",". $lon . ",". $rr->altitude;
					if ($debug) {
						print "\t Location from DNS LOC query is: $NMIS::systemTable{DNSloc}\n" ;
					}
				}
			}
			else  {
				if ($debug) {
					print "\t DNS Loc query failed: ", $res->errorstring, "\n" ;
				}
			}
		} # end DNSLoc
		# if no DNS based location information found - look at sysLocation in router.....
		# longitude,latitude,altitude,location-text
		if ( $NMIS::config{sysLoc} eq "on" and $NMIS::systemTable{DNSloc} eq "unknown"  ) {
			if ($NMIS::systemTable{sysLocation} =~ /$qr_sysLoc_format/ ) {
				$NMIS::systemTable{DNSloc} = $NMIS::systemTable{sysLocation};
				if ($debug) {
					print "\t Location from device sysLocation is $NMIS::systemTable{DNSloc}\n";
				}
			}
		} # end sysLoc

		# if the device is a cisco router or IOS based switch do collect some extra system info
		if (    ( $NMIS::systemTable{nodeModel} =~ /CiscoRouter|CatalystIOS/ ) &&
			( $NMIS::systemTable{nodeVendor} eq "Cisco Systems" )
		){
			if ($debug)  { print returnTime." Getting Cisco IOS Serial Number\n"; }
			( 
				$NMIS::systemTable{chassisVer},
				$NMIS::systemTable{serialNum},
				$NMIS::systemTable{processorRam},
				$NMIS::systemTable{InstalledModems} ### Andrew Sargent Modem Support
			) = $session->snmpget( 
				'chassisVersion',
				'chassisId',
				'processorRam',
				'cmSystemInstalledModem'.".0"  ### Andrew Sargent Modem Support
			);
			if ( $NMIS::systemTable{InstalledModems} eq "" or $NMIS::systemTable{InstalledModems} =~ /unprintable BER type/) { $NMIS::systemTable{InstalledModems} = "0"; }  ### Andrew Sargent Modem Support
			if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
				logMessage( " getNodeInfo, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				goto END_getNodeInfo;
			}
			# check if nbarpd available
			if (SNMP_MIB::name2oid('cnpdStatusTable')) {
				my %tmptable = $session->snmpgettablean( 'cnpdStatusTable' );
				$NMIS::systemTable{nbarpd} = scalar(keys %tmptable) > 0 ? "true" : "false" ;
				$SNMP_Simple::errmsg = "";
				if ($debug) { print returnTime." NBARPD is $NMIS::systemTable{nbarpd} on this node\n"; }
			}
		}
		elsif ( ( $NMIS::systemTable{nodeModel} =~ /Catalyst/ ) &&
			( $NMIS::systemTable{nodeVendor} eq "Cisco Systems" )
		){
			if ($debug)  { print returnTime." Getting Cisco CAT5 Serial Number\n"; }
			( 
				$NMIS::systemTable{serialNum},
				$NMIS::systemTable{sysTrafficPeak},
				$NMIS::systemTable{sysTrafficPeakTime}
			) = $session->snmpget( 
				'chassisSerialNumberString',
				'sysTrafficPeak',
				'sysTrafficPeakTime'
			);
			if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
				logMessage( " getNodeInfo, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				goto END_getNodeInfo;
			}
		}

		# PIX failover test
		# table has six values
		# primary.cfwHardwareInformation, secondary.cfwHardwareInformation
		# primary.HardwareStatusValue, secondary.HardwareStatusValue
		# primary.HardwareStatusDetail, secondary.HardwareStatusDetail
		# if HardwareStatusDetail is blank ( ne Failover Off ) then
		# HardwareStatusValue will have active or standby, else 0

		elsif ( $NMIS::systemTable{nodeModel} eq "CiscoPIX" ) {
			if ($debug)  { print returnTime." Getting Cisco PIX Failover Status\n"; }

			(       $NMIS::systemTable{pixPrimary},
				$NMIS::systemTable{pixSecondary}
			) = $session->snmpget(
				'cfwHardwareStatusValue'.".6",
				'cfwHardwareStatusValue'.".7"
			);
			if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
				logMessage( " getNodeInfo, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				goto END_getNodeInfo;
			}

			if ( $NMIS::systemTable{pixPrimary} == 0 ) { $NMIS::systemTable{pixPrimary} = "Failover Off"; }
			elsif ( $NMIS::systemTable{pixPrimary} == 9 ) { $NMIS::systemTable{pixPrimary} = "Active"; }
			elsif ( $NMIS::systemTable{pixPrimary} == 10 ) { $NMIS::systemTable{pixPrimary} = "Standby"; }
			else { $NMIS::systemTable{pixPrimary} = "Unknown"; }

			if ( $NMIS::systemTable{pixSecondary} == 0 ) { $NMIS::systemTable{pixSecondary} = "Failover Off"; }
			elsif ( $NMIS::systemTable{pixSecondary} == 9 ) { $NMIS::systemTable{pixSecondary} = "Active"; }
			elsif ( $NMIS::systemTable{pixSecondary} == 10 ) { $NMIS::systemTable{pixSecondary} = "Standby"; }
			else { $NMIS::systemTable{pixSecondary} = "Unknown"; }
			
		}
	} # must have SNMP eq something.
	else {
		$writeSystem = "false";
	}
	
	# Finished with the SNMP
	END_getNodeInfo:
	if (defined $session) { $session->close(); }
} # end getNodeInfo

# Put all the good SNMP info into a file for caching and also test SNMP for use.
sub updateUptime {
	my $node = shift;
	my $pingresult = shift;
	my $newUpTime;
	my $oldUpTime;
	my $session;

    if ($debug)  { print returnTime." Updating UPTIME Info\n"; }
	
	# OPEN the SNMP Session 
	if ( $NMIS::systemTable{snmpVer} eq "SNMPv2" ) {
		($session) = SNMPv2c_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
	}
	else {
		($session) = SNMP_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
	}
	if ( not defined($session) ) { 
		logMessage(" updateUptime, $node, Session is not Defined") if $debug; 
		goto END_updateUptime;
	}
	else {
		(	$snmpTable{sysObjectID},
			$snmpTable{sysUpTime},
			$snmpTable{ifNumber}
		) = $session->snmpget (
			'sysObjectID', 
			'sysUpTime', 
			'ifNumber'
		);
		if ($debug)  { print "\t sysObjectID=$snmpTable{sysObjectID}\n\t ifNumber=$snmpTable{ifNumber}\n\t sysUpTime=$snmpTable{sysUpTime}\n"; }
	
		# Check if SNMP returned anything at all.
		if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
			$snmpresult = 0;
			logMessage( " updateUptime, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
			$SNMP_Simple::errmsg = "";
			# rely on event system to tell us about snmp down during normal run
			# if unsure or newbie, debug run will show all...
			notify(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => "SNMP Down", details => "SNMP error");
			goto END_updateUptime;
		}
		elsif ( $snmpTable{sysObjectID} =~ /unprintable BER type/ 
				or $snmpTable{sysUpTime} =~ /unprintable BER type/ 
				or $snmpTable{ifNumber} =~ /unprintable BER type/
		) {
			$snmpresult = 0;
			logMessage(" updateUptime, $node, SNMP ERROR sysObjectID=$snmpTable{sysObjectID} sysUpTime=$snmpTable{sysUpTime} ifNumber=$snmpTable{ifNumber}") if $debug;
			$SNMP_Simple::errmsg = "";
			goto END_updateUptime;
		}
		elsif ( $snmpTable{sysObjectID} eq "" 
				and $snmpTable{sysUpTime} eq "" 
				and $snmpTable{ifNumber} eq "" 
		) {
			$snmpresult = 0;
			logMessage(" updateUptime, $node, SNMP elements empty sysObjectID=$snmpTable{sysObjectID} sysUpTime=$snmpTable{sysUpTime} ifNumber=$snmpTable{ifNumber}") if $debug;
			$SNMP_Simple::errmsg = "";
			goto END_updateUptime;
		}
		# check if SNMP matches cached stuff but only if the bugger is up ie did the SNMP return something.
		elsif ( ( $snmpTable{sysObjectID} ne $NMIS::systemTable{sysObjectID}
				or $snmpTable{ifNumber} ne $NMIS::systemTable{ifNumber} 
			) and ( 
				$snmpTable{sysObjectID} ne "" 
				and $snmpTable{ifNumber} ne "" 
		) ) {
			$snmpresult = 100;
			checkEvent(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => "SNMP Down", level => "Normal", details => "SNMP error");
		    if ( $snmpTable{ifNumber} ne $NMIS::systemTable{ifNumber} ) {
				logMessage("updateUptime, $node, Number of interfaces changed previously $NMIS::systemTable{ifNumber} now $snmpTable{ifNumber}");
			}
			if ( $snmpTable{sysObjectID} ne $NMIS::systemTable{sysObjectID} ) {
				logMessage("updateUptime, $node, Device type/model changed $NMIS::systemTable{sysObjectID} now $snmpTable{sysObjectID}");
			}
			&createSystemFile($node, $pingresult);
			&createInterfaceFile($node); 
		}
		# SNMP returned some stuff so store and update etc.
		else { 
			$snmpresult = 100;
			checkEvent(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => "SNMP Down", level => "Normal", details => "SNMP error");
		    # Read the uptime from the system info file from the last time it was polled
		    $snmpTable{sysUpTime} =~ s/,/ /g;
		    $snmpTable{sysUpTime} =~ s/  / /g;
			$newUpTime = convertUpTime($snmpTable{sysUpTime});
			$oldUpTime = convertUpTime($NMIS::systemTable{sysUpTime});
		
			if ($debug)  { print returnTime." sysUpTime: Old=$NMIS::systemTable{sysUpTime} New=$snmpTable{sysUpTime}\n"; }
		
			if ( $newUpTime < $oldUpTime and $newUpTime ne "" ) {		
				if ($debug)  { print returnTime." NODE RESET: Old sysUpTime=$oldUpTime: New sysUpTime=$newUpTime\n"; }
				notify(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => "Node Reset", details => "Old_sysUpTime=$NMIS::systemTable{sysUpTime} New_sysUpTime=$snmpTable{sysUpTime}");
			}
		
			$NMIS::systemTable{oldsysUpTime} = $NMIS::systemTable{sysUpTime};
			$NMIS::systemTable{sysUpTime} = $snmpTable{sysUpTime};
			### AS 16/4/2001 - Found that if any details change in nodes.dat not updating system
			$NMIS::systemTable{netType} = $NMIS::nodeTable{$node}{net};
			$NMIS::systemTable{roleType} = $NMIS::nodeTable{$node}{role};
			$NMIS::systemTable{nodeType} = $NMIS::nodeTable{$node}{devicetype};

			# lets check the Power supply status !!
			#
			# FIXME maybe should really switch on this capability in models.csv
			# for now, use regex collect_rps_gen in nmis.conf and list sysObjectName - aka 6509|7206 etc.
			# CISCO-ENVMON-MIB::ciscoEnvMonSupplyStatusDescr.1 = STRING: Power Supply 1, WS-CAC-1300W
			# CISCO-ENVMON-MIB::ciscoEnvMonSupplyStatusDescr.2 = STRING: Power Supply 2, WS-CAC-1300W
			# CISCO-ENVMON-MIB::ciscoEnvMonSupplyState.1 = INTEGER: normal(1)
			# CISCO-ENVMON-MIB::ciscoEnvMonSupplyState.2 = INTEGER: normal(1)
			# normal(1), warning(2), critical(3), shutdown(4), notPresent(5), notFunctioning(6)
			# CISCO-ENVMON-MIB::ciscoEnvMonSupplySource.1 = INTEGER: internalRedundant(5)
			# CISCO-ENVMON-MIB::ciscoEnvMonSupplySource.2 = INTEGER: internalRedundant(5)
			# unknown(1), ac(2), dc(3), externalPowerSupply(4), internalRedundant(5)

			# altiga VPN3000
			# alHardwarePs1Type		none(1), -- no power supply detected in slot
			#						ac(2)    -- AC power supply detected in slot
			# alHardwarePs1Voltage5vAlarm	Truthvalue	the alarm status for PS1 5v voltage. true=1, false=2

			if ( exists $NMIS::config{collect_rps_gen} and $NMIS::systemTable{sysObjectName} =~ /$qr_collect_rps_gen/ ) {
				if ($debug)  { print returnTime." Getting RPS Status\n"; }
				# special for VPN3000 RPS.
				if ( $NMIS::systemTable{sysObjectName} =~ /altiga/i ) {
				    (      $snmpTable{SupplyDescr1},
	                        $snmpTable{SupplyDescr2},
	                        $snmpTable{SupplyState1},
	                        $snmpTable{SupplyState2}
	    	        ) = $session->snmpget(
	            	        'alHardwarePs1Type'.".0",
	                    	'alHardwarePs2Type'.".0",
	            	        'alHardwarePs1Voltage5vAlarm'.".0",
	            	        'alHardwarePs2Voltage5vAlarm'.".0"
	           		);

					if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
						logMessage( " updateUptime, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
						$SNMP_Simple::errmsg = "";
						goto END_updateUptime;
					}

					$NMIS::systemTable{SupplyDescr1} = ( "unknown", "none", "ac")[$snmpTable{SupplyDescr1}];
					$NMIS::systemTable{SupplyDescr2} = ( "unknown", "none", "ac")[$snmpTable{SupplyDescr2}];
					$NMIS::systemTable{SupplyState1} = ( "unknown", "Alarm", "normal")[$snmpTable{SupplyState1}];
					$NMIS::systemTable{SupplyState2} = ( "unknown", "Alarm", "normal")[$snmpTable{SupplyState2}];
				}
				# Redback power supply
				# Mike McHenry 2005
				if ( $NMIS::systemTable{sysObjectName} =~ /^rbn/i ) {
				    (      $snmpTable{SupplyDescr1},
	                        $snmpTable{SupplyDescr2},
	                        $snmpTable{SupplyState1},
	                        $snmpTable{SupplyState2}
	    	        ) = $session->snmpget(
	            	        'rbnPowerDescr'.".1",
	                    	'rbnPowerDescr'.".2",
	            	        'rbnPowerFail'.".1",
	            	        'rbnPowerFail'.".2"
	           		);

					if ( $SNMP_Simple::errmsg =~ /No answer from/ ) {
						if ($debug)  { print "\t $node, SNMP ERROR, errmsg=$SNMP_Simple::errmsg\n"; }
						logMessage("updateUptime, $node, SNMP ERROR errmsg=$SNMP_Simple::errmsg");
						$SNMP_Simple::errmsg = "";
						goto END_updateUptime;
					}

					$NMIS::systemTable{SupplyDescr1} = $snmpTable{SupplyDescr1};
					$NMIS::systemTable{SupplyDescr2} = $snmpTable{SupplyDescr2};
					$NMIS::systemTable{SupplyState1} = ( "unknown", "Alarm", "normal")[$snmpTable{SupplyState1}];
					$NMIS::systemTable{SupplyState2} = ( "unknown", "Alarm", "normal")[$snmpTable{SupplyState2}];
				}
				else {
				     (      $snmpTable{SupplySource1},
	                        $snmpTable{SupplySource2},
	                        $snmpTable{SupplyState1},
	                        $snmpTable{SupplyState2}
 
	    	        ) = $session->snmpget(
	            	        'ciscoEnvMonSupplySource'.".1",
	                    	'ciscoEnvMonSupplySource'.".2",
	            	        'ciscoEnvMonSupplyState'.".1",
	            	        'ciscoEnvMonSupplyState'.".2"
	           		);

					if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
						logMessage( " updateUptime, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
						$SNMP_Simple::errmsg = "";
						goto END_updateUptime;
					}
					$NMIS::systemTable{SupplyDescr1} = ( "unknown", "unknown", "ac", "dc", "externalPowerSupply", "internalRedundant")[$snmpTable{SupplySource1}];
					$NMIS::systemTable{SupplyDescr2} = ( "unknown", "unknown", "ac", "dc", "externalPowerSupply", "internalRedundant")[$snmpTable{SupplySource2}];
					$NMIS::systemTable{SupplyState1} = ( "unknown", "normal", "warning", "critical", "shutdown", "notPresent", "notFunctioning")[$snmpTable{SupplyState1}];
					$NMIS::systemTable{SupplyState2} = ( "unknown", "normal", "warning", "critical", "shutdown", "notPresent", "notFunctioning")[$snmpTable{SupplyState2}];
				}

				# check status and set/clear alarms
				# use event details to differentiate between RPS1 and RPS2 on same node.

				if ( $NMIS::systemTable{SupplyState1} =~ /normal|unknown|notPresent/ ) { 
					checkEvent(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => "RPS Fail", level => "Normal", details => "RPS1 failed");
				}
				else {
					notify(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => "RPS Fail", details => "RPS1 failed");
				}
				if ( $NMIS::systemTable{SupplyState2} =~ /normal|unknown|notPresent/ ) { 
					checkEvent(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => "RPS Fail", level => "Normal", details => "RPS2 failed");
				}
				else {
					notify(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => "RPS Fail", details => "RPS2 failed");
				}
			}

			# before we go, lets check the PIX failover status !

			# PIX failover test
			# table has six values
			# [0] primary.cfwHardwareInformation, [1] secondary.cfwHardwareInformation
			# [2] primary.HardwareStatusValue, [3] secondary.HardwareStatusValue
			# [4] primary.HardwareStatusDetail, [5] secondary.HardwareStatusDetail
			# if HardwareStatusDetail is blank ( ne 'Failover Off' ) then
			# HardwareStatusValue will have 'active' or 'standby'

			if ( $NMIS::systemTable{nodeModel} eq "CiscoPIX" ) {
				if ($debug)  { print returnTime." Getting Cisco PIX Failover Status\n"; }

	                        (       $snmpTable{pixPrimary},
        	                        $snmpTable{pixSecondary}
                	        ) = $session->snmpget(
                        	        'cfwHardwareStatusValue'.".6",
                                	'cfwHardwareStatusValue'.".7"
                       		);

				if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
					logMessage( " updateUptime, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
					$SNMP_Simple::errmsg = "";
					goto END_updateUptime;
				}

				if ( $snmpTable{pixPrimary} == 0 ) { $snmpTable{pixPrimary} = "Failover Off"; }
				elsif ( $snmpTable{pixPrimary} == 9 ) { $snmpTable{pixPrimary} = "Active"; }
				elsif ( $snmpTable{pixPrimary} == 10 ) { $snmpTable{pixPrimary} = "Standby"; }
				else { $snmpTable{pixPrimary} = "Unknown"; }

				if ( $snmpTable{pixSecondary} == 0 ) { $snmpTable{pixSecondary} = "Failover Off"; }
				elsif ( $snmpTable{pixSecondary} == 9 ) { $snmpTable{pixSecondary} = "Active"; }
				elsif ( $snmpTable{pixSecondary} == 10 ) { $snmpTable{pixSecondary} = "Standby"; }
				else { $snmpTable{pixSecondary} = "Unknown"; }

				if ( $snmpTable{pixPrimary} ne $NMIS::systemTable{pixPrimary} or $snmpTable{pixSecondary} ne $NMIS::systemTable{pixSecondary} )
					{
					if ($debug)  {
						print "\t $node: PIX failover occurred\n"; 
						print "\t $node: Primary was $NMIS::systemTable{pixPrimary} now $snmpTable{pixPrimary}, Secondary was $NMIS::systemTable{pixSecondary} now $snmpTable{pixSecondary}\n";
					}
					# As this is not stateful, alarm not sent to state table in sub eventAdd
					notify(node => $node, role => $NMIS::systemTable{roleType}, type => $NMIS::systemTable{nodeType}, event => "Node Failover", details =>"Primary now: $snmpTable{pixPrimary}  Secondary now: $snmpTable{pixSecondary}");
					$NMIS::systemTable{pixPrimary} = $snmpTable{pixPrimary};
					$NMIS::systemTable{pixSecondary} = $snmpTable{pixSecondary};
				}

			}
			
			$writeSystem = "true";
##			&writeSystemFile($node);
		}
		# Finished with the SNMP
	}
	END_updateUptime:
	if (defined $session) { $session->close(); }
} # end updateUptime

sub writeSystemFile {
	my $node = shift;
	my $key;

	if ( $writeSystem eq "true" ) {
		# Deal with the nasty \n \r im sysdescr just remove the \n to be put back later.
		$NMIS::systemTable{sysDescr} =~ s/,/ /g;
		$NMIS::systemTable{sysDescr} =~ s/\n/ /g;
		$NMIS::systemTable{sysDescr} =~ s/\r/ /g;
		
		# get damn comma's out:
		$NMIS::systemTable{sysUpTime} =~ s/,/ /g;
		$NMIS::systemTable{sysUpTime} =~ s/\n/ /g;
		$NMIS::systemTable{sysUpTime} =~ s/\r/ /g;
		
		### AS 1/5/01 Made a little more flexible.
		#open(OUTFILE, ">$NMIS::config{'<nmis_var>'}/$node.dat")
		# changed to secure sysopen with truncate after we have got the lock
		sysopen(OUTFILE, "$NMIS::config{'<nmis_var>'}/$node.dat", O_WRONLY | O_CREAT)
			 or warn returnTime." writeSystemFile, Couldn't open file $NMIS::config{'<nmis_var>'}/$node.dat for writing. $!\n";
		flock(OUTFILE, LOCK_EX)  or warn "can't lock filename: $!";
		truncate(OUTFILE, 0) or warn "can't truncate filename: $!";
		foreach $key (keys %NMIS::systemTable) {
			print OUTFILE "$key=$NMIS::systemTable{$key}\n";
		}
		close(OUTFILE) or warn "can't close filename: $!";
		
		# set the permissions
		setFileProt("$NMIS::config{'<nmis_var>'}/$node.dat");
		
		# ehg 20 sep 02 add debug to write exactly what we found !!
		if ($debug) {
			print returnTime." Writing the System File $NMIS::config{'<nmis_var>'}/$node.dat\n";
			for $index ( sort keys %NMIS::systemTable ) {
				print "\t $index=$NMIS::systemTable{$index}\n";
			}
		}
	}
	else {
	# only print message if supposed to collect and no SNMP available.
		if ( $NMIS::nodeTable{$node}{collect} eq "true" ) {
			logMessage("writeSystemFile, $node, not writing system file writeSystem=$writeSystem as no SNMP to cache");
		}
	}
}

sub updateRRDDB {
	my %arg = @_;
	my $type = $arg{type};
	my $node = $arg{node};
	my $nodeType = $arg{nodeType}; 
	my $group = $arg{group};
	my $extName = $arg{extName}; 
	my $ifType = $arg{ifType};
	my $ifIndex = $arg{ifIndex};
	my $ifSpeed = $arg{ifSpeed};
	my $item = $arg{item};
	my $data = $arg{data};
	my $i;
	my @label;
	my @value;

	# check if RRD database exist, else create
	if ( not &createRRDDB(type => $type, node => $node, nodeType => $nodeType, group => $group, extName => $extName,
			ifType => $ifType, ifIndex => $ifIndex, ifSpeed => $ifSpeed, item => $item ) ) {
		return;
	}

	my $database = getRRDFileName(node => $node, group => $group, nodeType => $nodeType, type => $type, extName => $extName, item => $item);

	my $time  = 30*int(time/30);
	my @options;
	my $ERROR;
	my $operStatus;
	my $index;

	if ($debug) { print returnTime." updateRRD: Starting Update Process type=$type\n"; }

	if ( $type eq "pvc" ) {
		# get the key into the hash
		my ( $port, $pvc ) = split /-/ , $extName;

		@options = (
			"-t", "ReceivedBECNs:ReceivedFECNs:ReceivedFrames:ReceivedOctets:SentFrames:SentOctets:State",
			"N:$pvcStats{$port}{$pvc}{frCircuitReceivedBECNs}:$pvcStats{$port}{$pvc}{frCircuitReceivedFECNs}:$pvcStats{$port}{$pvc}{frCircuitReceivedFrames}:$pvcStats{$port}{$pvc}{frCircuitReceivedOctets}:$pvcStats{$port}{$pvc}{frCircuitSentFrames}:$pvcStats{$port}{$pvc}{frCircuitSentOctets}:$pvcStats{$port}{$pvc}{frCircuitState}"
		);
	} # if pvc is true
	elsif ( $type eq "reach" ) {
		@options = (
			"-t", "reachability:availability:responsetime:health:loss",
			"N:$reach{reachability}:$reach{availability}:$reach{responsetime}:$reach{health}:$reach{loss}"
		);
	} # if reach is true baby
	### AS 8 June 2002 - Adding overall network metrics RRD's
	elsif ( $type eq "metrics" ) {
		@options = (
			"-t", "reachability:availability:responsetime:health:status",
			"N:$data->{reachability}:$data->{availability}:$data->{responsetime}:$data->{health}:$data->{status}"
		);
	} # if metrics is true baby
	# Is it a Cisco Router Health
	elsif ( $type eq "interface" ) {		
		# Calculate Operational Status
		if (	$ifStats{ifOperStatus} == 1 
				or $ifStats{ifOperStatus} == 5 
		) { $operStatus = 100; }
		else { $operStatus = 0; }

		# While updating start calculating the total availability of the device
		$reach{operStatus} = $reach{operStatus} + $operStatus;
		$reach{operCount} = $reach{operCount} + 1;

		if ( $ifStats{ifInOctets} eq "" ) { $ifStats{ifInOctets} = 0 }
		if ( $ifStats{ifOutOctets} eq "" ) { $ifStats{ifOutOctets} = 0 }

		@options = (
			"-t", "ifInOctets:ifOutOctets:ifOperStatus",
			"N:$ifStats{ifInOctets}:$ifStats{ifOutOctets}:$operStatus"
		);
	}
	elsif ( $type eq "pkts" ) {
		if ( $ifStats{ifInOctets} eq "" ) { $ifStats{ifInOctets} = 0 }
		if ( $ifStats{ifOutOctets} eq "" ) { $ifStats{ifOutOctets} = 0 }
		if ( $ifStats{ifInUcastPkts} eq "" ) { $ifStats{ifInUcastPkts} = 0 }
		if ( $ifStats{ifInNUcastPkts} eq "" ) { $ifStats{ifInNUcastPkts} = 0 }
		if ( $ifStats{ifInDiscards} eq "" ) { $ifStats{ifInDiscards} = 0 }
		if ( $ifStats{ifInErrors} eq "" ) { $ifStats{ifInErrors} = 0 }
		if ( $ifStats{ifOutUcastPkts} eq "" ) { $ifStats{ifOutUcastPkts} = 0 }
		if ( $ifStats{ifOutNUcastPkts} eq "" ) { $ifStats{ifOutNUcastPkts} = 0 }
		if ( $ifStats{ifOutDiscards} eq "" ) { $ifStats{ifOutDiscards} = 0 }
		if ( $ifStats{ifOutErrors} eq "" ) { $ifStats{ifOutErrors} = 0 }
		@options = (
			"-t", "ifInOctets:ifOutOctets:ifInUcastPkts:ifInNUcastPkts:ifInDiscards:ifInErrors:ifOutUcastPkts:ifOutNUcastPkts:ifOutDiscards:ifOutErrors",
			"N:$ifStats{ifInOctets}:$ifStats{ifOutOctets}:$ifStats{ifInUcastPkts}:$ifStats{ifInNUcastPkts}:$ifStats{ifInDiscards}:$ifStats{ifInErrors}:$ifStats{ifOutUcastPkts}:$ifStats{ifOutNUcastPkts}:$ifStats{ifOutDiscards}:$ifStats{ifOutErrors}"
		);
	}
	#
	elsif ( $type eq "mib2ip" ) {
		if ( $snmpTable{ipInReceives} eq "" ) { $snmpTable{ipInReceives} = 0 }
		if ( $snmpTable{ipInHdrErrors} eq "" ) { $snmpTable{ipInHdrErrors} = 0 }
		if ( $snmpTable{ipInAddrErrors} eq "" ) { $snmpTable{ipInAddrErrors} = 0 }
		if ( $snmpTable{ipForwDatagrams} eq "" ) { $snmpTable{ipForwDatagrams} = 0 }
		if ( $snmpTable{ipInUnknownProtos} eq "" ) { $snmpTable{ipInUnknownProtos} = 0 }
		if ( $snmpTable{ipInDiscards} eq "" ) { $snmpTable{ipInDiscards} = 0 }
		if ( $snmpTable{ipInDelivers} eq "" ) { $snmpTable{ipInDelivers} = 0 }
		if ( $snmpTable{ipOutRequests} eq "" ) { $snmpTable{ipOutRequests} = 0 }
		if ( $snmpTable{ipOutDiscards} eq "" ) { $snmpTable{ipOutDiscards} = 0 }
		if ( $snmpTable{ipOutNoRoutes} eq "" ) { $snmpTable{ipOutNoRoutes} = 0 }
		if ( $snmpTable{ipReasmReqds} eq "" ) { $snmpTable{ipReasmReqds} = 0 }
		if ( $snmpTable{ipReasmOKs} eq "" ) { $snmpTable{ipReasmOKs} = 0 }
		if ( $snmpTable{ipReasmFails} eq "" ) { $snmpTable{ipReasmFails} = 0 }
		if ( $snmpTable{ipFragOKs} eq "" ) { $snmpTable{ipFragOKs} = 0 }
		if ( $snmpTable{ipFragFails} eq "" ) { $snmpTable{ipFragFails} = 0 }
		if ( $snmpTable{ipFragCreates} eq "" ) { $snmpTable{ipFragCreates} = 0 }
		@options = (
			"-t", "ipInReceives:ipInHdrErrors:ipInAddrErrors:ipForwDatagrams:ipInUnknownProtos:ipInDiscards:ipInDelivers:ipOutRequests:ipOutDiscards:ipOutNoRoutes:ipReasmReqds:ipReasmOKs:ipReasmFails:ipFragOKs:ipFragFails:ipFragCreates",
			"N:$snmpTable{ipInReceives}:$snmpTable{ipInHdrErrors}:$snmpTable{ipInAddrErrors}:$snmpTable{ipForwDatagrams}:$snmpTable{ipInUnknownProtos}:$snmpTable{ipInDiscards}:$snmpTable{ipInDelivers}:$snmpTable{ipOutRequests}:$snmpTable{ipOutDiscards}:$snmpTable{ipOutNoRoutes}:$snmpTable{ipReasmReqds}:$snmpTable{ipReasmOKs}:$snmpTable{ipReasmFails}:$snmpTable{ipFragOKs}:$snmpTable{ipFragFails}:$snmpTable{ipFragCreates}"
		);
	}
	# ip stats moved to mib2ip
	elsif ( $type eq "nodehealth" and $NMIS::systemTable{nodeModel} =~ /CiscoRouter|CatalystIOS|Redback|FoundrySwitch|Riverstone/ ) {
		if ( $snmpTable{avgBusy1} eq "" ) { $snmpTable{avgBusy1} = 0 }
		if ( $snmpTable{avgBusy5} eq "" ) { $snmpTable{avgBusy5} = 0 }
		if ( $snmpTable{MemoryUsedPROC} eq "" ) { $snmpTable{MemoryUsedPROC} = 0 }
		if ( $snmpTable{MemoryFreePROC} eq "" ) { $snmpTable{MemoryFreePROC} = 0 }
		if ( $snmpTable{MemoryUsedIO} eq "" ) { $snmpTable{MemoryUsedIO} = 0 }
		if ( $snmpTable{MemoryFreeIO} eq "" ) { $snmpTable{MemoryFreeIO} = 0 }
		if ( $snmpTable{bufferElFree} eq "" ) { $snmpTable{bufferElFree} = 0 }
		if ( $snmpTable{bufferElHit} eq "" ) { $snmpTable{bufferElHit} = 0 }
		if ( $snmpTable{bufferFail} eq "" ) { $snmpTable{bufferFail} = 0 }
		@options = (
			"-t", "avgBusy1:avgBusy5:MemoryUsedPROC:MemoryFreePROC:MemoryUsedIO:MemoryFreeIO:bufferElFree:bufferElHit:bufferFail",
			"N:$snmpTable{avgBusy1}:$snmpTable{avgBusy5}:$snmpTable{MemoryUsedPROC}:$snmpTable{MemoryFreePROC}:$snmpTable{MemoryUsedIO}:$snmpTable{MemoryFreeIO}:$snmpTable{bufferElFree}:$snmpTable{bufferElHit}:$snmpTable{bufferFail}"
		);
	}
	### Andrew Sargent Modem Support
	elsif ( $type eq "modem" and $NMIS::systemTable{nodeModel} =~ /CiscoRouter/ ) {
		@options = (
			"-t", "InstalledModem:ModemsInUse:ModemsAvailable:ModemsUnavailable:ModemsOffline:ModemsDead", 
			"N:$snmpTable{InstalledModem}:$snmpTable{ModemsInUse}:$snmpTable{ModemsAvailable}:$snmpTable{ModemsUnavailable}:$snmpTable{ModemsOffline}:$snmpTable{ModemsDead}"  ###AS
		);
	}
	### CBQoS Support
	elsif ( $type eq "cbqos" and $NMIS::systemTable{nodeModel} =~ /CiscoRouter/ ) {
		@options = (
			"-t", "PrePolicyByte:DropByte:PrePolicyPkt:DropPkt:NoBufDropPkt", 
			"N:$snmpTable{cbQosCMPrePolicyByte}:$snmpTable{cbQosCMDropByte}:$snmpTable{cbQosCMPrePolicyPkt}:$snmpTable{cbQosCMDropPkt}:$snmpTable{cbQosCMNoBufDropPkt}"
		);
	}
	### Calls Support
	### Mike McHenry 2005
	elsif ( $type eq "calls" and $NMIS::systemTable{nodeModel} =~ /CiscoRouter/ ) {
		@options = (
			"-t", "DS0CallType:L2Encapsulation:CallCount:AvailableCallCount:totalIdle:totalUnknown:totalAnalog:totalDigital:totalV110:totalV120:totalVoice", 
			"N:$snmpTable{cpmDS0CallType}:$snmpTable{cpmL2Encapsulation}:$snmpTable{cpmCallCount}:$snmpTable{cpmAvailableCallCount}:$snmpTable{totalIdle}:$snmpTable{totalUnknown}:$snmpTable{totalAnalog}:$snmpTable{totalDigital}:$snmpTable{totalV110}:$snmpTable{totalV120}:$snmpTable{totalVoice}"
		);
		if ($debug) {
			@label = split /:/, $options[1];
			@value = split /:/, $options[2];
			print " database=$database\n\t";
			for ( $i=0; $i < @label; $i++ ) {
				print " $label[$i]=$value[$i+1]";
			}
		print "\n";
		}
	}
	elsif ( $type eq "nodehealth" and $NMIS::systemTable{nodeModel} =~ /Catalyst6000|Catalyst5000Sup3|Catalyst5005|Catalyst5000/ ) {
		@options = (
			"-t", "avgBusy1:avgBusy5:MemoryUsedDRAM:MemoryFreeDRAM:MemoryUsedMBUF:MemoryFreeMBUF:MemoryUsedCLUSTER:MemoryFreeCLUSTER:sysTraffic:TopChanges",
			"N:$snmpTable{avgBusy1}:$snmpTable{avgBusy5}:$snmpTable{MemoryUsedDRAM}:$snmpTable{MemoryFreeDRAM}:$snmpTable{MemoryUsedMBUF}:$snmpTable{MemoryFreeMBUF}:$snmpTable{MemoryUsedCLUSTER}:$snmpTable{MemoryFreeCLUSTER}:$snmpTable{sysTraffic}:$snmpTable{TopChanges}"
		);
	}
	# ip stats moved to mib2ip
	elsif ( $type eq "nodehealth" and $NMIS::systemTable{nodeModel} =~ /Accelar/ ) {
		@options = (
			"-t", "rcSysCpuUtil:rcSysSwitchFabricUtil:rcSysBufferUtil",
			"N:$snmpTable{rcSysCpuUtil}:$snmpTable{rcSysSwitchFabricUtil}:$snmpTable{rcSysBufferUtil}"
		);
	}
	elsif ( $type eq "nodehealth" and $NMIS::systemTable{nodeModel} =~ /CiscoPIX/ ) {
		@options = (
			"-t", "avgBusy1:avgBusy5:MemoryUsedPROC:MemoryFreePROC:connectionsInUse:connectionsHigh",
			"N:$snmpTable{avgBusy1}:$snmpTable{avgBusy5}:$snmpTable{MemoryUsedPROC}:$snmpTable{MemoryFreePROC}:$snmpTable{connectionsInUse}:$snmpTable{connectionsHigh}"
		);
	}
    elsif ( $type eq "nodehealth" and $NMIS::systemTable{nodeModel} =~ /SSII 3Com/ ) {
        @options = (
            "-t", "BandwidthUsed:ErrorsPerPackets:ReadableFrames:UnicastFrames:MulticastFrames:BroadcastFrames:ReadableOctets:UnicastOctets:MulticastOctets:BroadcastOctets:FCSErrors:AlignmentErrors:FrameTooLongs:ShortEvents:Runts:TxCollisions:LateEvents:VeryLongEvents:DataRateMismatches:AutoPartitions:TotalErrors",
            "N:$snmpTable{BandwidthUsed}:$snmpTable{ErrorsPerPackets}:$snmpTable{ReadableFrames}:$snmpTable{UnicastFrames}:$snmpTable{MulticastFrames}:$snmpTable{BroadcastFrames}:$snmpTable{ReadableOctets}:$snmpTable{UnicastOctets}:$snmpTable{MulticastOctets}:$snmpTable{BroadcastOctets}:$snmpTable{FCSErrors}:$snmpTable{AlignmentErrors}:$snmpTable{FrameTooLongs}:$snmpTable{ShortEvents}:$snmpTable{Runts}:$snmpTable{TxCollisions}:$snmpTable{LateEvents}:$snmpTable{VeryLongEvents}:$snmpTable{DataRateMismatches}:$snmpTable{AutoPartitions}:$snmpTable{TotalErrors}"
        );
    }
	elsif ( $type eq "nodehealth" and $NMIS::systemTable{nodeType} eq "server" ) {
		@options = (
			"-t", "tempReading:tempMinWarn:tempMaxWarn",
			"N:$snmpTable{tempReading}:$snmpTable{tempMinWarn}:$snmpTable{tempMaxWarn}"
		);
	}
	elsif ( $type eq "hr" ) {
		@options = (
			"-t", "hrNumUsers:hrProcesses:laLoad5:hrMemSize:hrMemUsed:hrVMemSize:hrVMemUsed",
			"N:$snmpTable{hrSystemNumUsers}{0}:$snmpTable{hrSystemProcesses}{0}:$snmpTable{laLoad5}:$snmpTable{hrMemSize}:$snmpTable{hrMemUsed}:$snmpTable{hrVMemSize}:$snmpTable{hrVMemUsed}"
		);
	}
	elsif ( $type eq "hrWin" ) {
		@options = (
			"-t", "hrNumUsers:hrProcesses:AvailableBytes:CommittedBytes:PagesPerSec:ProcessorTime:UserTime:InterruptsPerSec",
			"N:$snmpTable{hrSystemNumUsers}{0}:$snmpTable{hrSystemProcesses}{0}:$snmpTable{AvailableBytes}:$snmpTable{CommittedBytes}:$snmpTable{PagesPerSec}:$snmpTable{ProcessorTime}:$snmpTable{UserTime}:$snmpTable{InterruptsPerSec}"
		);
	}
    elsif ( $type eq "hrsmpcpu" ) {
        @options = (
             "-t", "hrCpuLoad",
            "N:$snmpTable{hrCpuLoad}"
        );
    }
	elsif ( $type eq "hrDisk" ) {
		@options = (
			"-t", "hrDiskSize:hrDiskUsed",
			"N:$snmpTable{hrDiskSize}:$snmpTable{hrDiskUsed}"
		);
	}
	# application service poll
	elsif ( $type eq 'service' ) {
		@options = (
			"-t", "service",
			"N:$snmpTable{service}"
		);
	}

	# application service poll
	elsif ( $type eq 'nmis' ) {
		@options = (
			"-t", "collect",
			"N:$data->{collect}"
		);
	}

	if ( @options) {
		if ($debug) {
			@label = split /:/, $options[1];
			@value = split /:/, $options[2];
			print returnTime." updateRRD: database=$database\n\t";
			for ( $i=0; $i < @label; $i++ ) {
				print " $label[$i]=$value[$i+1]";
			}
		print "\n";
		}

		# update RRD
		RRDs::update($database,@options);
		if ($ERROR = RRDs::error) {
			if ($ERROR !~ /Template contains more DS/) {
				logMessage("updateRRD, $node, update ERROR database=$database: $ERROR: options = @options");
				print returnTime." updateRRD: ERROR database=$database: $ERROR: options = @options\n" if $debug;
			} else {
				print returnTime." updateRRD: missing DataSource in $database, try to update\n" if $debug;
				# find the DS names in the existing database (format ds[name].* )
				my $info = RRDs::info($database);
				my $names = ":";
				foreach my $key (keys %$info) {
					if ( $key =~ /^ds\[([a-zA-Z0-9_]{1,19})\].+/) { $names .= "$1:";}
				}
				# find the missing DS name (format DS:name:type:hearthbeat:min:max)
				my @options_db = &optionsRRD(type => $type, ifType => $ifType, ifIndex => $ifIndex, ifSpeed => $ifSpeed);
				foreach my $ds (@options_db) {
					my @opt = split /:/, $ds;
					if ( $opt[0] eq "DS" and $names !~ /:$opt[1]:/ ) {
						&addDStoRRD($database,$ds); # sub in rrdfunc
					}
				}
			}
		}
	}
	else {
		logMessage("updateRRD, $node, unknown type=$type\n");
		if ($debug) { print returnTime." updateRRD: unknown type=$type\n"; }
	}
} # end updateRRDDB

#
# define the DataSource configuration for RRD 
#
sub optionsRRD {
	my %arg = @_;
	my $type = $arg{type};
	my $ifType = $arg{ifType}; 
	my $ifIndex = $arg{ifIndex}; 
	my $ifSpeed = $arg{ifSpeed}; 

	my $time  = 30*int(time/30);
	my @options;
	my $START = $time;

	if ( $ifSpeed <= 0 ) { $ifSpeed = 1000000000; }

	# Check what type of database to create
	# Is it a Generic Interface Type
	if ( $type eq "interface" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:ifInOctets:COUNTER:$NMIS::config{RRD_hbeat}:0:$ifSpeed", 
				"DS:ifOutOctets:COUNTER:$NMIS::config{RRD_hbeat}:0:$ifSpeed", 
				"DS:ifOperStatus:GAUGE:$NMIS::config{RRD_hbeat}:0:100", 
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_int_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_int_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_int_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_int_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_int_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_int_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_int_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_int_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_int_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_int_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_int_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_int_year}"
			);
		}
		elsif ( $type eq "pvc" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
                "DS:ReceivedBECNs:COUNTER:$NMIS::config{RRD_hbeat}:0:U",
                "DS:ReceivedFECNs:COUNTER:$NMIS::config{RRD_hbeat}:0:U",
                "DS:ReceivedFrames:COUNTER:$NMIS::config{RRD_hbeat}:0:U",
                "DS:ReceivedOctets:COUNTER:$NMIS::config{RRD_hbeat}:0:U",
                "DS:SentFrames:COUNTER:$NMIS::config{RRD_hbeat}:0:U",
                "DS:SentOctets:COUNTER:$NMIS::config{RRD_hbeat}:0:U",
                "DS:State:GAUGE:$NMIS::config{RRD_hbeat}:0:100",
                "RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_int_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_int_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_int_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_int_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_int_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_int_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_int_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_int_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_int_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_int_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_int_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_int_year}"
			);
		}
		elsif ( $type eq "pkts" ) {
			# If we can collect extra packet stats Nike!  Make an extra RRD for this interface
			# create a max pps number 10000000 / 14880 = approx 600
			my $maxpackets = $ifSpeed / 600;
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:ifOperStatus:GAUGE:$NMIS::config{RRD_hbeat}:0:100",
				"DS:ifInOctets:COUNTER:$NMIS::config{RRD_hbeat}:0:$ifSpeed", 
				"DS:ifInUcastPkts:COUNTER:$NMIS::config{RRD_hbeat}:0:$maxpackets", 
				"DS:ifInNUcastPkts:COUNTER:$NMIS::config{RRD_hbeat}:0:$maxpackets", 
				"DS:ifInDiscards:COUNTER:$NMIS::config{RRD_hbeat}:0:$maxpackets", 
				"DS:ifInErrors:COUNTER:$NMIS::config{RRD_hbeat}:0:$maxpackets", 
				"DS:ifOutOctets:COUNTER:$NMIS::config{RRD_hbeat}:0:$ifSpeed",
				"DS:ifOutUcastPkts:COUNTER:$NMIS::config{RRD_hbeat}:0:$maxpackets", 
				"DS:ifOutNUcastPkts:COUNTER:$NMIS::config{RRD_hbeat}:0:$maxpackets", 
				"DS:ifOutDiscards:COUNTER:$NMIS::config{RRD_hbeat}:0:$maxpackets", 
				"DS:ifOutErrors:COUNTER:$NMIS::config{RRD_hbeat}:0:$maxpackets", 
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_int_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_int_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_int_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_int_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_int_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_int_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_int_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_int_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_int_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_int_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_int_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_int_year}"
			);
		}
		# Is it a Reachability Type
		elsif ( $type eq "reach" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:reachability:GAUGE:$NMIS::config{RRD_hbeat}:0:100", 
				"DS:availability:GAUGE:$NMIS::config{RRD_hbeat}:0:100", 
				"DS:responsetime:GAUGE:$NMIS::config{RRD_hbeat}:0:U", 
				"DS:health:GAUGE:$NMIS::config{RRD_hbeat}:0:100", 
				"DS:loss:GAUGE:$NMIS::config{RRD_hbeat}:0:100", 
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_rch_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_rch_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_rch_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_rch_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_rch_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_rch_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_rch_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_rch_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_rch_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_rch_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_rch_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_rch_year}"
			);
		} # Reachability
		### AS 8 June 2002 - Adding overall network metrics RRD's
		elsif ( $type eq "metrics" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:reachability:GAUGE:$NMIS::config{RRD_hbeat}:0:100", 
				"DS:availability:GAUGE:$NMIS::config{RRD_hbeat}:0:100", 
				"DS:responsetime:GAUGE:$NMIS::config{RRD_hbeat}:0:U", 
				"DS:health:GAUGE:$NMIS::config{RRD_hbeat}:0:100", 
				"DS:status:GAUGE:$NMIS::config{RRD_hbeat}:0:100", 
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_met_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_met_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_met_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_met_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_met_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_met_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_met_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_met_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_met_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_met_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_met_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_met_year}"
			);
		} # metric
		# Is it a MIB2 IP Stats ??
		elsif ( $type eq "mib2ip" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:ipInReceives:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:ipInHdrErrors:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:ipInAddrErrors:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:ipForwDatagrams:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:ipInUnknownProtos:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:ipInDiscards:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:ipInDelivers:COUNTER:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:ipOutRequests:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:ipOutDiscards:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:ipOutNoRoutes:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:ipReasmReqds:COUNTER:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:ipReasmOKs:COUNTER:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:ipReasmFails:COUNTER:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:ipFragOKs:COUNTER:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:ipFragFails:COUNTER:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:ipFragCreates:COUNTER:$NMIS::config{RRD_hbeat}:U:U", 
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}"
			);
		} #end mib2ip
		# Is it a Cisco Router Health
		elsif ( $NMIS::systemTable{nodeModel} =~ /CiscoRouter|CatalystIOS|FoundrySwitch|Riverstone/ and $type eq "nodehealth" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:avgBusy1:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:avgBusy5:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:MemoryUsedPROC:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:MemoryFreePROC:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:MemoryUsedIO:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:MemoryFreeIO:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:bufferElFree:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:bufferElHit:COUNTER:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:bufferFail:COUNTER:$NMIS::config{RRD_hbeat}:U:U", 
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}"
			);
		}
		# Is it a Redback
		# Mike McHenry 2005
		elsif ( $NMIS::systemTable{nodeModel} =~ /Redback/ and $type eq "nodehealth" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:avgBusy1:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:avgBusy5:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}"
			);
		}
		### Andrew Sargent Modem Support
		elsif ( $NMIS::systemTable{nodeModel} =~ /CiscoRouter/ and $type eq "modem" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:InstalledModem:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:ModemsInUse:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:ModemsAvailable:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:ModemsUnavailable:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:ModemsOffline:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:ModemsDead:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}"
			);
		}
		### CBQoS Support 
		elsif ( $NMIS::systemTable{nodeModel} =~ /CiscoRouter/ and $type eq "cbqos" ) {
			my $maxbytes = $ifSpeed/4;
			my $maxpackets = $maxbytes/50;
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:PrePolicyByte:COUNTER:$NMIS::config{RRD_hbeat}:U:$maxbytes", 
				"DS:DropByte:COUNTER:$NMIS::config{RRD_hbeat}:U:$maxbytes", 
				"DS:PrePolicyPkt:COUNTER:$NMIS::config{RRD_hbeat}:U:$maxpackets", 
				"DS:DropPkt:COUNTER:$NMIS::config{RRD_hbeat}:U:$maxpackets", 
				"DS:NoBufDropPkt:COUNTER:$NMIS::config{RRD_hbeat}:U:$maxpackets", 
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}"
			);
		}
		### Calls Support 
		### Mike McHenry 2005
		elsif ( $NMIS::systemTable{nodeModel} =~ /CiscoRouter/ and $type eq "calls" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:DS0CallType:GAUGE:$NMIS::config{RRD_hbeat}:0:10", 
				"DS:L2Encapsulation:GAUGE:$NMIS::config{RRD_hbeat}:0:10", 
				"DS:CallCount:GAUGE:$NMIS::config{RRD_hbeat}:0:U", 
				"DS:AvailableCallCount:GAUGE:$NMIS::config{RRD_hbeat}:0:200", 
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"DS:totalIdle:GAUGE:$NMIS::config{RRD_hbeat}:0:200", 
				"DS:totalUnknown:GAUGE:$NMIS::config{RRD_hbeat}:0:200", 
				"DS:totalAnalog:GAUGE:$NMIS::config{RRD_hbeat}:0:200", 
				"DS:totalDigital:GAUGE:$NMIS::config{RRD_hbeat}:0:200", 
				"DS:totalV110:GAUGE:$NMIS::config{RRD_hbeat}:0:200", 
				"DS:totalV120:GAUGE:$NMIS::config{RRD_hbeat}:0:200", 
				"DS:totalVoice:GAUGE:$NMIS::config{RRD_hbeat}:0:200", 
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}"
			);
		}
		# Is it a Cisco Catalyst 6000 Switch Health Stats
		elsif ( $NMIS::systemTable{nodeModel} =~ /Catalyst6000|Catalyst5000Sup3|Catalyst5005|Catalyst5000/ and $type eq "nodehealth" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:avgBusy1:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:avgBusy5:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:MemoryUsedDRAM:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:MemoryFreeDRAM:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:MemoryUsedMBUF:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:MemoryFreeMBUF:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:MemoryUsedCLUSTER:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:MemoryFreeCLUSTER:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:sysTraffic:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:TopChanges:COUNTER:$NMIS::config{RRD_hbeat}:U:U", 
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}"
			);
		}
		### AS 1 Apr 02 - Integrating Phil Reilly's Nortel changes
		#Our good old Accelar
		elsif ( $NMIS::systemTable{nodeModel} =~ /Accelar/ and $type eq "nodehealth" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:rcSysCpuUtil:GAUGE:$NMIS::config{RRD_hbeat}:U:100", 
				"DS:rcSysSwitchFabricUtil:GAUGE:$NMIS::config{RRD_hbeat}:U:100", 
				"DS:rcSysBufferUtil:GAUGE:$NMIS::config{RRD_hbeat}:U:100", 
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}"
			);
		}
		# Is it a Cisco PIX Firewall
		elsif ( $NMIS::systemTable{nodeModel} =~ /CiscoPIX/ and $type eq "nodehealth" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:avgBusy1:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:avgBusy5:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:MemoryUsedPROC:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:MemoryFreePROC:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:connectionsInUse:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"DS:connectionsHigh:GAUGE:$NMIS::config{RRD_hbeat}:U:U", 
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}"
			);
		}
		# server temperature
		elsif ( $NMIS::systemTable{nodeType} eq "server" and $type eq "nodehealth" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll}, 
				"DS:tempReading:GAUGE:$NMIS::config{RRD_hbeat}:0:900", 
				"DS:tempMinWarn:GAUGE:$NMIS::config{RRD_hbeat}:0:900", 
				"DS:tempMaxWarn:GAUGE:$NMIS::config{RRD_hbeat}:0:900", 
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}"
			);
		} # end server temperature
		# is it a 3com switch
		elsif ( $NMIS::systemTable{nodeModel} =~ /SSII 3Com/ and $type eq "nodehealth" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:BandwidthUsed:GAUGE:$NMIS::config{RRD_hbeat}:0:100",
				"DS:ErrorsPerPackets:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"DS:ReadableFrames:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:UnicastFrames:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:MulticastFrames:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:BroadcastFrames:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:ReadableOctets:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:UnicastOctets:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:MulticastOctets:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:BroadcastOctets:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:FCSErrors:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:AlignmentErrors:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:FrameTooLongs:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:ShortEvents:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:Runts:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:TxCollisions:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:LateEvents:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:VeryLongEvents:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:DataRateMismatches:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:AutoPartitions:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"DS:TotalErrors:COUNTER:$NMIS::config{RRD_hbeat}:U:U",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}"
			);
		}
		elsif ( $type eq "hr" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:hrNumUsers:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"DS:hrProcesses:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"DS:laLoad5:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"DS:hrMemSize:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"DS:hrMemUsed:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"DS:hrVMemSize:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"DS:hrVMemUsed:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}"
			);
		} #endhr
		elsif ( $type eq "hrWin" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:hrNumUsers:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"DS:hrProcesses:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"DS:AvailableBytes:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"DS:CommittedBytes:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"DS:PagesPerSec:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"DS:ProcessorTime:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"DS:UserTime:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"DS:InterruptsPerSec:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}"
			);
		} #endhrWin
		elsif ( $type eq "hrDisk" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:hrDiskSize:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"DS:hrDiskUsed:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}"
			);
		} #endhrDisk
		elsif ( $type eq "hrsmpcpu" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:hrCpuLoad:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
                "RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
                "RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
                "RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
                "RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
                "RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
                "RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
                "RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
                "RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
                "RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
                "RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
                "RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
                "RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}"
			);
		} #endhrsmpcpu
		elsif ( $type eq "service" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:service:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}"
			);
		} #endservice
		elsif ( $type eq "nmis" ) {
			@options = (
				"-b", $START, "-s", $NMIS::config{RRD_poll},
				"DS:collect:GAUGE:$NMIS::config{RRD_hbeat}:U:U",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:AVERAGE:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MAX:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_day}:$NMIS::config{RRA_rows_hlt_day}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_week}:$NMIS::config{RRA_rows_hlt_week}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_month}:$NMIS::config{RRA_rows_hlt_month}",
				"RRA:MIN:0.5:$NMIS::config{RRA_step_int_year}:$NMIS::config{RRA_rows_hlt_year}"
			);
		} #endnmis
	return (@options);
} # end optionsRRD


### AS 2 June 2002 - createRRRDB now checks if RRD exists and only creates if doesn't exist.
### EG 1 July 2003 - also add node directory create for node directories, if rrd is not found
sub createRRDDB {
	my %arg = @_;
	my $type = $arg{type};
	my $node = $arg{node};
	my $nodeType = $arg{nodeType}; 
	my $group = $arg{group};
	my $extName = $arg{extName}; 
	my $ifType = $arg{ifType}; 
	my $ifIndex = $arg{ifIndex}; 
	my $ifSpeed = $arg{ifSpeed}; 
	my $item =$arg{item};

	my $database = getRRDFileName(node => $node, group => $group, nodeType => $nodeType, type => $type, extName=> $extName, item => $item);
	# Does the database exist already?
	if ( -f $database and -r $database and -w $database ) { 
		# nothing to do!
		if ($debug>1) { print "\t Database $database already exists and is read write for you!\n"; }
		return 1;
	}
	# Check if the RRD Database Exists but is ReadOnly
	# Maybe this should check for valid directory or not.
	elsif ( -f $database and not -w $database ) { 
		print "ERROR: Database $database Exists but is readonly to you!\n";
		return 0;
	}
	# It doesn't so create it
	else {
		# let check if the node directory exists as well, create if not.
		if (    not -d "$NMIS::config{database_root}/interface/$nodeType/$node" 
			and not -r "$NMIS::config{database_root}/interface/$nodeType/$node" 
			and -w "$NMIS::config{database_root}/interface/$nodeType" 
		) { 
			if ($debug) { print returnTime." createRRDDB: creating interface database directory $NMIS::config{database_root}/interface/$nodeType/$node\n"; }
			createDir("$NMIS::config{database_root}/interface/$nodeType/$node");
		}

		my @options = &optionsRRD(type => $type, ifType => $ifType, ifIndex => $ifIndex, ifSpeed => $ifSpeed);
		my $time  = 30*int(time/30);

		if ( @options ) {
			RRDs::create("$database",@options);
			my $ERROR = RRDs::error;
			if ($ERROR) {
				logMessage("createRRDDB, $node, unable to create $database: $ERROR");
				if ($debug) { print returnTime." createRRDDB: ERROR unable to create $database: $ERROR\n"; }
				return 0;
			}
			# set file owner and permission, default: nmis, 0775.
			setFileProt($database); # Cologne, Jan 2005
			# Double check created OK for this user
			if ( -f $database and -r $database and -w $database ) { 
				if ($debug) { print returnTime." Created RRD $database starting at $time.\n"; }
				logMessage("createRRDDB, $node, Created RRD $database starting at $time");
				sleep 1;		# wait at least 1 sec to avoid rrd 1 sec step errors as next call is RRDBupdate
				return 1;
			}
			else {
				if ($debug) { print returnTime." Could not create RRD $database - check directory permissions\n"; }
				logMessage("createRRDDB, $node, Could not create RRD $database - check directory permissions");
				return 0;
			}
		}
		else {
			logMessage("createRRDDB, $node, unknown type=$type\n");
			if ($debug) { print returnTime." createRRDDB: unknown type=$type\n"; }
			return 0;
		}
	} # else
} # end createRRDDB

# Create the Interface configuration from SNMP Stuff!!!!!
sub createInterfaceFile {
	my $node = shift;
	my $interfacefile = "$NMIS::config{'<nmis_var>'}/$node-interface.dat";
	if ($debug) { print returnTime." Creating the interface file: $interfacefile\n"; }
	if ($debug) { print "\t Note the MIB variable 1.3.6.1.2.1.31.1.1.1.1 is the ifName MIB which is not supported by older SNMP agents.\n"; }
	
	# Create a means to maintain which devices are supported so far.
	my $validModel = "false";
	my @ifNames;
	my $ifIndex;
	my $ourPortName;
	my $ourPortNumber;
	my @intTable;
	my $interfaces;
	my $intf;
	my $ifIndex;
	my %interfaceTable;
	my $session;
	my $message;
	my %ifTypeDefs;
	my %sysint;
	
	my $numInterfaces = $NMIS::systemTable{ifNumber};
	
	#NMIS::loadInterfaceTypes;
	%ifTypeDefs = &loadCSV($NMIS::config{ifTypes_Table},$NMIS::config{ifTypes_Key},"\t");
	
	if ( $NMIS::systemTable{snmpVer} eq "SNMPv2" ) {
		($session) = SNMPv2c_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
	}
	else {
		($session) = SNMP_Simple->open($node, $NMIS::nodeTable{$node}{community}, $NMIS::nodeTable{$node}{snmpport});
	}
	if ( not defined($session) ) { 
		warn returnTime." createInterfaceFile, Session is not Defined Goodly to $node.\n"; 
		goto END_createInterfaceFile;
	}
	
	# An SNMP session exists already and we know the node type
	# Depending on the node type get different information
	# CiscoRouter/ATM
	if ( $NMIS::systemTable{nodeModel} =~ /CiscoRouter|CiscoATM/ ) {
		if ($debug) { print "\t Collecting $NMIS::systemTable{ifNumber} Interfaces \n"; }
		$validModel = "true";
		# Loop to get interface information for Cisco router
		my %ifIndexTable = $session->snmpgettablean('ifIndex');
		foreach $index ( sort {$a <=> $b} keys %ifIndexTable) {
			# Get Interface Information
			(	$interfaces->{$index}{ifDescr},
				$interfaces->{$index}{ifType},
				$interfaces->{$index}{ifSpeed},
				$interfaces->{$index}{ifAdminStatus},
				$interfaces->{$index}{ifOperStatus},
				$interfaces->{$index}{ifLastChange},
				$interfaces->{$index}{Description}
			) = $session->snmpget(  
				'ifDescr'.".$index",
				'ifType'.".$index",
				'ifSpeed'.".$index",
				'ifAdminStatus'.".$index",
				'ifOperStatus'.".$index",
				'ifLastChange'.".$index",
				'ifAlias'.".$index"
			); 
			if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
				logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				goto END_createInterfaceFile;
			}
			if ( $interfaces->{$index}{ifDescr} eq "" ) { 
				$interfaces->{$index}{ifDescr} = "null";
				++$numInterfaces; 
			}	
			# ehg 3 Dec 2002 removed bad chars from interface descriptions
			$interfaces->{$index}{ifDescr} = rmBadChars($interfaces->{$index}{ifDescr});
			$interfaces->{$index}{Description} = rmBadChars($interfaces->{$index}{Description});
 
			if ($debug) { print "\t ifIndex=$index descr=$interfaces->{$index}{ifDescr} admin=$interfaces->{$index}{ifAdminStatus} oper=$interfaces->{$index}{ifOperStatus} speed=$interfaces->{$index}{ifSpeed}\n"; }
			
			# Set the ifType to be something meaningful!!!!
			$interfaces->{$index}{ifType} = $ifTypeDefs{$interfaces->{$index}{ifType}}{ifType};
			
			# Set AdminStatus and OperStatus to be a word!!
			$interfaces->{$index}{ifAdminStatus} = $interfaceStatus[$interfaces->{$index}{ifAdminStatus}];
			$interfaces->{$index}{ifOperStatus} = $interfaceStatus[$interfaces->{$index}{ifOperStatus}];
			
			# Just check if it is an Frame Relay sub-interface
			if ( ( $interfaces->{$index}{ifType} eq "frameRelay" and $interfaces->{$index}{ifDescr} =~ /\./ ) ) {
				$interfaces->{$index}{ifType} = "frameRelay-subinterface";
			}
			# get 'ifHighSpeed' if 'ifSpeed' = 4,294,967,295 - refer RFC2863 HC interfaces.
			if ( $interfaces->{$index}{ifSpeed} == 4294967295 ) {
				(	$interfaces->{$index}{ifSpeed}
					) = $session->snmpget(  
					'ifHighSpeed'.".$index",
				); 
				if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
					logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
					$SNMP_Simple::errmsg = "";
					goto END_createInterfaceFile;
				}
				$interfaces->{$index}{ifSpeed} *= 1000000;
			}
		}
	} # ( $NMIS::systemTable{nodeModel} eq "CiscoRouter" or CiscoATM)
	### Catalyst IOS
	elsif ( $NMIS::systemTable{nodeModel} =~ /CatalystIOS/ ) {

		if ($debug) { print "\t Collecting $NMIS::systemTable{ifNumber} Interfaces \n"; }
		$validModel = "true";

		my 	$nativevlan;
		my $trunkencaptype;
		my @ENUMportSpantreeFastStart = ("null","enabled","disabled");
		my @ENUMportDuplex = ("null","half","full","disagree","auto");
		my @ENUMportTrunkEncapsulationType = ("null","isl","dot10","lane","dot1q","negotiate");

		# Loop to get interface information for CatIOS
		my %ifIndexTable = $session->snmpgettablean('ifIndex');
		foreach $index (sort {$a <=> $b} keys %ifIndexTable) {
			# Get Interface Information
  
	           ( 	$interfaces->{$index}{ifDescr},
                    $interfaces->{$index}{ifType},
                    $interfaces->{$index}{ifSpeed},
                    $interfaces->{$index}{ifAdminStatus},
                    $interfaces->{$index}{ifOperStatus},
                    $interfaces->{$index}{ifLastChange},
                    $interfaces->{$index}{Description},
                    $interfaces->{$index}{ldescr}
	             ) = $session->snmpget(
                    'ifDescr'.".$index",
                    'ifType'.".$index",
                    'ifSpeed'.".$index",
                    'ifAdminStatus'.".$index",
                    'ifOperStatus'.".$index",
                    'ifLastChange'.".$index",
                    'ifAlias'.".$index",
                    "enterprises.9.2.2.1.1.28.$index"
             );

			if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
				logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				goto END_createInterfaceFile;
			}

			if ( $interfaces->{$index}{ifDescr} eq "" ) { 
				$interfaces->{$index}{ifDescr} = "null";
				++$numInterfaces; 
			}

			# use the Cisco private description if the standard one didn't reply.
			if ( $interfaces->{$index}{Description} eq "" ) {
				$interfaces->{$index}{Description} = $interfaces->{$index}{ldescr};
			}
			# ehg 3 Dec 2002 removed bad chars from interface descriptions
			$interfaces->{$index}{ifDescr} = rmBadChars($interfaces->{$index}{ifDescr});
			$interfaces->{$index}{Description} = rmBadChars($interfaces->{$index}{Description});
 
			if ($debug) { print "\t ifIndex=$index descr=$interfaces->{$index}{ifDescr} admin=$interfaces->{$index}{ifAdminStatus} oper=$interfaces->{$index}{ifOperStatus} speed=$interfaces->{$index}{ifSpeed}\n"; }
			
			# Set the ifType to be something meaningful!!!!
			$interfaces->{$index}{ifType} = $ifTypeDefs{$interfaces->{$index}{ifType}}{ifType};
			
			# Set AdminStatus and OperStatus to be a word!!
			$interfaces->{$index}{ifAdminStatus} = $interfaceStatus[$interfaces->{$index}{ifAdminStatus}];
			$interfaces->{$index}{ifOperStatus} = $interfaceStatus[$interfaces->{$index}{ifOperStatus}];
			
			# get 'ifHighSpeed' if 'ifSpeed' = 4,294,967,295 - refer RFC2863 HC interfaces.
			if ( $interfaces->{$index}{ifSpeed} == 4294967295 ) {
				(	$interfaces->{$index}{ifSpeed}
					) = $session->snmpget(  
					'ifHighSpeed'.".$index",
				); 
				if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
					logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
					$SNMP_Simple::errmsg = "";
					goto END_createInterfaceFile;
				}
				$interfaces->{$index}{ifSpeed} *= 1000000;
			}

		}
		# now get the vlan stuff - if supported...
		foreach $index (sort {$a <=> $b} keys %ifIndexTable) {
 			# get the VLAN info: table is indexed by port.portnumber
			if ( $interfaces->{$index}{ifDescr} =~ /\d{1,2}\/(\d{1,2})$/ ) { # FastEthernet0/1
				$ourPortNumber = '1.' . $1;
				if ( $interfaces->{$index}{ifDescr} =~ /(\d{1,2})\/\d{1,2}\/(\d{1,2})$/ ) { # FastEthernet1/0/0
					$ourPortNumber = $1. '.' . $2;
				}
	           (       $interfaces->{$index}{portDuplex},
	                    $interfaces->{$index}{portSpantreeFastStart},
	                    $interfaces->{$index}{vlanPortVlan},
	                    $interfaces->{$index}{portAdminSpeed},
						$nativevlan,
						$trunkencaptype
	            ) = $session->snmpget(
	                    'portDuplex'.".$ourPortNumber",
	                    'portSpantreeFastStart'.".$ourPortNumber",
	                    'vlanPortVlan'.".$ourPortNumber",
	                    'portAdminSpeed'.".$ourPortNumber",
						'vlanTrunkPortNativeVlan'.".$index",
						'vlanTrunkPortEncapsulationType'.".$index"
	            );

				if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
					logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
					$SNMP_Simple::errmsg = "";
					goto END_createInterfaceFile;
				}
				last if $interfaces->{$index}{vlanPortVlan} eq "";	# model does not support CISCO-STACK-MIB
				if ($debug) { print "\t get VLAN details: index=$index\tifDescr=$interfaces->{$index}{ifDescr}\n"; }

				# portDuplex ENUMs
				$interfaces->{$index}{portDuplex} = $ENUMportDuplex[$interfaces->{$index}{portDuplex}];
				# portSpantreeFastStart ENUMs
				$interfaces->{$index}{portSpantreeFastStart} = $ENUMportSpantreeFastStart[$interfaces->{$index}{portSpantreeFastStart}];
				# set the trunk native VLAN
				if ( $trunkencaptype > 0) {
					$interfaces->{$index}{vlanPortVlan}	= @ENUMportTrunkEncapsulationType[$trunkencaptype] . " n(" . $nativevlan . ")";
				}
				# Because auto is shown as a speed of 1 make it change.
				# portAdminSpeed ENUMs
				if ( $interfaces->{$index}{portAdminSpeed} == 1 ) {
				        $interfaces->{$index}{portAdminSpeed} = "auto";
				}
				if ($debug) { 
					print "\t ourportNumber: $ourPortNumber\t\tVLan: $interfaces->{$index}{vlanPortVlan}\tDescription: $interfaces->{$index}{portAdminSpeed}\n";
				}
			} # end of VLAN
		}
	} # CatIOS
	### Riverstone
	### Mike McHenry 2005
	elsif ( $NMIS::systemTable{nodeModel} =~ /Riverstone|FoundrySwitch/i ) {

		if ($debug) { print "\t Collecting $NMIS::systemTable{ifNumber} Interfaces \n"; }
		$validModel = "true";

		my 	$nativevlan;
		my $trunkencaptype;
		my @ENUMportDuplex = ("null","unknown","half","full");

		# Loop to get interface information for ROS
		my %ifIndexTable = $session->snmpgettablean('ifIndex');
		foreach $index (sort {$a <=> $b} keys %ifIndexTable) {
			# Get Interface Information
  
	           ( 	$interfaces->{$index}{ifDescr},
                    $interfaces->{$index}{ifType},
                    $interfaces->{$index}{ifSpeed},
                    $interfaces->{$index}{ifAdminStatus},
                    $interfaces->{$index}{ifOperStatus},
                    $interfaces->{$index}{ifLastChange},
                    $interfaces->{$index}{Description},
                    $interfaces->{$index}{ldescr}
	             ) = $session->snmpget(
                    'ifDescr'.".$index",
                    'ifType'.".$index",
                    'ifSpeed'.".$index",
                    'ifAdminStatus'.".$index",
                    'ifOperStatus'.".$index",
                    'ifLastChange'.".$index",
                    'ifAlias'.".$index",
                    "enterprises.9.2.2.1.1.28.$index"
             );


			if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
				logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				goto END_createInterfaceFile;
			}

			if ( $interfaces->{$index}{ifDescr} eq "" ) { 
				$interfaces->{$index}{ifDescr} = "null";
				++$numInterfaces; 
			}

			# use the Cisco private description if the standard one didn't reply.
			if ( $interfaces->{$index}{Description} eq "" ) {
				$interfaces->{$index}{Description} = $interfaces->{$index}{ldescr};
			}
			# ehg 3 Dec 2002 removed bad chars from interface descriptions
			$interfaces->{$index}{ifDescr} = rmBadChars($interfaces->{$index}{ifDescr});
			$interfaces->{$index}{Description} = rmBadChars($interfaces->{$index}{Description});
 
			if ($debug) { print "\t ifIndex=$index descr=$interfaces->{$index}{ifDescr} admin=$interfaces->{$index}{ifAdminStatus} oper=$interfaces->{$index}{ifOperStatus} speed=$interfaces->{$index}{ifSpeed}\n"; }
			
			# Set the ifType to be something meaningful!!!!
			$interfaces->{$index}{ifType} = $ifTypeDefs{$interfaces->{$index}{ifType}}{ifType};
			
			# Set AdminStatus and OperStatus to be a word!!
			$interfaces->{$index}{ifAdminStatus} = $interfaceStatus[$interfaces->{$index}{ifAdminStatus}];
			$interfaces->{$index}{ifOperStatus} = $interfaceStatus[$interfaces->{$index}{ifOperStatus}];
			
			# get 'ifHighSpeed' if 'ifSpeed' = 4,294,967,295 - refer RFC2863 HC interfaces.
			if ( $interfaces->{$index}{ifSpeed} == 4294967295 ) {
				(	$interfaces->{$index}{ifSpeed}
					) = $session->snmpget(  
					'ifHighSpeed'.".$index",
				); 
				if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
					logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
					$SNMP_Simple::errmsg = "";
					goto END_createInterfaceFile;
				}
				$interfaces->{$index}{ifSpeed} *= 1000000;
			}

		}
		# now get the vlan stuff - if supported...
		foreach $index (sort {$a <=> $b} keys %ifIndexTable) {
 			# get the VLAN info: table is indexed by port.portnumber
	           (       $interfaces->{$index}{portDuplex},
	                    $interfaces->{$index}{portAdminSpeed},
	            ) = $session->snmpget(
	                    'dot3StatsDuplexStatus'.".$index",
	                    'portAdminSpeed'.".$index",
	            );

				if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
					logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
					$SNMP_Simple::errmsg = "";
					goto END_createInterfaceFile;
				}

				# portDuplex ENUMs
				$interfaces->{$index}{portDuplex} = $ENUMportDuplex[$interfaces->{$index}{portDuplex}];
				# portAdminSpeed ENUMs
				if ( $interfaces->{$index}{portAdminSpeed} == 1 ) {
				        $interfaces->{$index}{portAdminSpeed} = "auto";
				}
				if ($debug) { 
					print "\t ourportNumber: $index\t\tVlan: $interfaces->{$index}{vlanPortVlan}\tDescription: $interfaces->{$index}{portAdminSpeed}\tDuplex: $interfaces->{$index}{portDuplex}\n";
				}
		}
	} # Riverstone

	### CAT5K etc.
	elsif (	$NMIS::systemTable{nodeModel} =~ /Catalyst6000|Catalyst5000Sup3|Catalyst5005|Catalyst5000/
	) {
		$validModel = "true";
		my @ENUMportType;
		$ENUMportType[8] = "10BaseT";
		$ENUMportType[13] = "100BaseFX MM";
		$ENUMportType[18] = "10/100BaseTX";
		$ENUMportType[20] = "Route Switch";
		$ENUMportType[27] = "1000BaseLX";
		$ENUMportType[28] = "1000BaseSX";
		$ENUMportType[30] = "Net Analysis";
		$ENUMportType[31] = "No Connector";
		$ENUMportType[32] = "1000BaseLH";
		$ENUMportType[33] = "1000BaseT";
		$ENUMportType[61] = "10/100/1000";
		$ENUMportType[65] = "e10GBaseLR";
		$ENUMportType[70] = "e10GBaseSX4";
		$ENUMportType[71] = "e10GBaseER";
		$ENUMportType[72] = "contentEngine";
		$ENUMportType[73] = "ssl";
		$ENUMportType[74] = "firewall";
		$ENUMportType[75] = "vpnIpSec";
		$ENUMportType[76] = "ct3";
		$ENUMportType[85] = "e1000BaseBT";
		$ENUMportType[88] = "mcr";
		$ENUMportType[89] = "coe";
		$ENUMportType[90] = "mwa";
		$ENUMportType[91] = "psd";
		$ENUMportType[92] = "e100BaseLX";
		$ENUMportType[93] = "e10GBaseSR";
		$ENUMportType[94] = "e10GBaseCX4";
		$ENUMportType[95] = "e10GBaseWdm1550";
		$ENUMportType[96] = "e10GBaseEdc1310";
		$ENUMportType[97] = "e10GBaseSW";
		$ENUMportType[98] = "e10GBaseLW";
		$ENUMportType[99] = "e10GBaseEW";
		$ENUMportType[100] = "lwa";
		$ENUMportType[101] = "aons";
		$ENUMportType[102] = "sslVpn";
		$ENUMportType[103] = "e100BaseEmpty";
		$ENUMportType[104] = "adsm";
		$ENUMportType[105] = "agsm";
		$ENUMportType[106] = "aces";

		my @ENUMportSpantreeFastStart = ("null","enabled","disabled");
		my @ENUMportOperStatus = ("null","other","ok","minorFault","majorFault");
		my @ENUMportDuplex = ("null","half","full","disagree","auto");
		
		# Get a list of interface ifIndexes and ifName mappings
		@intTable = $session->snmpgettablek('ifIndex', 'ifName', 'ifAdminStatus', 'ifLastChange', 'ifSpeed');
		if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
			logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
			$SNMP_Simple::errmsg = "";
			goto END_createInterfaceFile;
		}
		if ($debug) { print "\t Catalyst Found $#intTable interfaces\n"; }
		
		foreach $ifIndex (1 .. $#intTable) {
			if ($intTable[$ifIndex]->{'ifName'} ne "" ) {
				if ($debug) { print "\t index=$ifIndex, ifIndex=$intTable[$ifIndex]->{'ifIndex'}, ifName=$intTable[$ifIndex]->{'ifName'}\n"; }

				$intTable[$ifIndex]->{'ifName'} =~ s/,/:/g;
				# Assign table into normalised interfaceTable 
				$interfaces->{$ifIndex}{ifIndex} = $intTable[$ifIndex]->{'ifIndex'};
				$interfaces->{$ifIndex}{ifDescr} = $intTable[$ifIndex]->{'ifName'};
				$interfaces->{$ifIndex}{ifAdminStatus} = $intTable[$ifIndex]->{'ifAdminStatus'};
				$interfaces->{$ifIndex}{ifSpeed} = $intTable[$ifIndex]->{'ifSpeed'};
				$interfaces->{$ifIndex}{ifLastChange} = $intTable[$ifIndex]->{'ifLastChange'};
	
			# if the Interface is a num/num ie a catalyst port then get additional stats
				if ($intTable[$ifIndex]->{ifName} =~ /^\d{1,2}\/\d{1,2}/ ) {
			    if ($debug) { print "\t get more details: index=$ifIndex\tifName=$intTable[$ifIndex]->{'ifName'}\tifDescr=$interfaces->{$ifIndex}{ifDescr}\n"; }
					$ourPortNumber =  $intTable[$ifIndex]->{ifName};
					$ourPortNumber =~ s/\//\./;
					
					(       
						$interfaces->{$ifIndex}{Description}, 
						$interfaces->{$ifIndex}{ifType}, 
						$interfaces->{$ifIndex}{ifOperStatus}, 
						$interfaces->{$ifIndex}{portDuplex},
						$interfaces->{$ifIndex}{portSpantreeFastStart},
						$interfaces->{$ifIndex}{vlanPortVlan},
						$interfaces->{$ifIndex}{portAdminSpeed}
					) = $session->snmpget(
						'portName'.".$ourPortNumber", 
						'portType'.".$ourPortNumber", 
						'portOperStatus'.".$ourPortNumber", 
						'portDuplex'.".$ourPortNumber",
						'portSpantreeFastStart'.".$ourPortNumber",
						'vlanPortVlan'.".$ourPortNumber",
						'portAdminSpeed'.".$ourPortNumber"
					);
					if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
						logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
						$SNMP_Simple::errmsg = "";
						goto END_createInterfaceFile;
					}
					
					if ($debug) { 
						print "\t ourportNumber: $ourPortNumber\t\tType: $interfaces->{$ifIndex}{ifType}\tDescription: $interfaces->{$ifIndex}{Description}\n ";
					}

					# Turn Enumerated types into words for each value
					# portOperStatus ENUMs
					$interfaces->{$ifIndex}{ifOperStatus} = $ENUMportOperStatus[$interfaces->{$ifIndex}{ifOperStatus}];
					
					# portDuplex ENUMs
					$interfaces->{$ifIndex}{portDuplex} = $ENUMportDuplex[$interfaces->{$ifIndex}{portDuplex}];
					
					# portSpantreeFastStart ENUMs
					$interfaces->{$ifIndex}{portSpantreeFastStart} = $ENUMportSpantreeFastStart[$interfaces->{$ifIndex}{portSpantreeFastStart}]; 
					
					# portType ENUMs
					$interfaces->{$ifIndex}{ifType} = $ENUMportType[$interfaces->{$ifIndex}{ifType}];
					# Because auto is shown as a speed of 1 make it change.
					# portAdminSpeed ENUMs
					if ( $interfaces->{$ifIndex}{portAdminSpeed} == 1 ) {
						$interfaces->{$ifIndex}{portAdminSpeed} = "auto"; 
					}
				} # if interface is num/num
				# must be a vlan or GEC or something else.
				else {
					if ( 	$interfaces->{$ifIndex}{ifDescr} =~ /vlan/i ) {
						$interfaces->{$ifIndex}{ifType} = "VLAN";
						$interfaces->{$ifIndex}{ifSpeed} = "1000000000";
					}
					elsif ( $interfaces->{$ifIndex}{ifDescr} =~ /fec|gec/i ) {
						$interfaces->{$ifIndex}{ifType} = "EtherChannel";
					}
					elsif ( $interfaces->{$ifIndex}{ifDescr} =~ /sl0/i ) {
						$interfaces->{$ifIndex}{ifType} = "SLIP";
					}
					elsif ( $interfaces->{$ifIndex}{ifDescr} =~ /sc0|me1/i ) {
						$interfaces->{$ifIndex}{ifType} = "Management";
					}
					$interfaces->{$ifIndex}{ifSpeed} = $intTable[$ifIndex]->{'ifSpeed'};
					$interfaces->{$ifIndex}{ifOperStatus} = $intTable[$ifIndex]->{'ifOperStatus'};
					
					$interfaces->{$ifIndex}{ifOperStatus} = $interfaceStatus[$interfaces->{$ifIndex}{ifOperStatus}];
				} # else other
				$interfaces->{$ifIndex}{ifAdminStatus} = $interfaceStatus[$interfaces->{$ifIndex}{ifAdminStatus}];
		    } # if name is not ""
		} # Foreach loop
	}
	### KS 2 Jan 03 - Changing check for Win2000 to Windows
	elsif ( $NMIS::systemTable{nodeModel} =~ /FreeBSD|SunSolaris|Windows|PIX|Redback|generic|MIB2/i ) {
		if ($debug) { print "Collecting $NMIS::systemTable{ifNumber} Interfaces \n"; }
		$validModel = "true";
		
		# Loop to get interface information from SNMP
		my %ifIndexTable = $session->snmpgettablean('ifIndex');
		foreach $index ( sort {$a <=> $b} keys %ifIndexTable) {
			if ($debug) { print "\t Getting $index, ". 'ifDescr'.".$index" . "\n"; }
			# Get Interface Information
			(   $interfaces->{$index}{ifDescr},
				$interfaces->{$index}{ifType},
				$interfaces->{$index}{ifSpeed},
				$interfaces->{$index}{ifAdminStatus},
				$interfaces->{$index}{ifOperStatus},
				$interfaces->{$index}{ifLastChange}
			) = $session->snmpget(  
				'ifDescr'.".$index",
				'ifType'.".$index",
				'ifSpeed'.".$index",
				'ifAdminStatus'.".$index",
				'ifOperStatus'.".$index",
				'ifLastChange'.".$index"
			);

			# trap ifdescr 'noSuchName' error and fudge an ifdescr
			if ( $SNMP_Simple::errmsg =~ /noSuchName/ ) {
				$SNMP_Simple::errmsg = "";
				$interfaces->{$index}{ifDescr} = 'ifDescr_'.$index.'_' if $interfaces->{$index}{ifDescr} = "";
			}
			if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
				logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				goto END_createInterfaceFile;
			}
			if ( $interfaces->{$index}{ifDescr} eq "" ) { 
				$interfaces->{$index}{ifDescr} = "null";
				++$numInterfaces; 
			}

			# ehg 3 Dec 2002 removed bad chars from interface descriptions
			$interfaces->{$index}{ifDescr} = rmBadChars($interfaces->{$index}{ifDescr});

			# add ifindex number to ifdescr to differentiate interfaces for devices that do not have unique ifDescr
				if ( $NMIS::systemTable{sysObjectName} =~ /$NMIS::config{int_extend}/  ) {
				$interfaces->{$index}{ifDescr} = $interfaces->{$index}{ifDescr} . "$index";
			}
			 
			if ($debug) { print "\t ifIndex=$index descr=$interfaces->{$index}{ifDescr} admin=$interfaces->{$index}{ifAdminStatus} oper=$interfaces->{$index}{ifOperStatus} speed=$interfaces->{$index}{ifSpeed}\n"; }
			
			# Set the ifType to be something meaningful!!!!
			$interfaces->{$index}{ifType} = $ifTypeDefs{$interfaces->{$index}{ifType}}{ifType};
	
			# Interfaces with N/A in them are bad!
			if ( $interfaces->{$index}{ifSpeed} eq "0" and $interfaces->{$index}{ifType} =~ /ethernet/i ) {
				$interfaces->{$index}{ifSpeed} = 10000000;
			}
			# Set AdminStatus and OperStatus to be a word!!
			$interfaces->{$index}{ifAdminStatus} = $interfaceStatus[$interfaces->{$index}{ifAdminStatus}];
			$interfaces->{$index}{ifOperStatus} = $interfaceStatus[$interfaces->{$index}{ifOperStatus}];

			# get 'ifHighSpeed' if 'ifSpeed' = 4,294,967,295 - refer RFC2863 HC interfaces.
			if ( $interfaces->{$index}{ifSpeed} == 4294967295 ) {
				(	$interfaces->{$index}{ifSpeed}
					) = $session->snmpget(  
					'ifHighSpeed'.".$index",
				); 
				if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
					logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
					$SNMP_Simple::errmsg = "";
					goto END_createInterfaceFile;
				}
				$interfaces->{$index}{ifSpeed} *= 1000000;
			}
		} # FOR LOOP
	} # Sun or generic
	### AS 1 Apr 02 - Integrating Phil Reilly's Nortel changes
	elsif ( $NMIS::systemTable{nodeModel} =~ /Accelar/ ) {
		if ($debug) { print "Collecting $NMIS::systemTable{ifNumber} Interfaces \n"; }
		$validModel = "true";
		
		# Loop to get interface information from SNMP
		my %ifIndexTable = $session->snmpgettablean('ifIndex');
		foreach $index ( sort {$a <=> $b} keys %ifIndexTable) {
			# Get Interface Information
			(       $interfaces->{$index}{ifDescr},
				$interfaces->{$index}{ifType},
				$interfaces->{$index}{ifSpeed},
				$interfaces->{$index}{ifAdminStatus},
				$interfaces->{$index}{ifOperStatus},
				$interfaces->{$index}{ifLastChange},
				$interfaces->{$index}{rcPortType}
			) = $session->snmpget(  
				'ifDescr'.".$index",
				'ifType'.".$index",
				'ifSpeed'.".$index",
				'ifAdminStatus'.".$index",
				'ifOperStatus'.".$index",
				'ifLastChange'.".$index",
				'rcPortType'.".$index"
			); 
			if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
				logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				goto END_createInterfaceFile;
			};

			# ehg 3 Dec 2002 removed bad chars from interface descriptions
			$interfaces->{$index}{ifDescr} = rmBadChars($interfaces->{$index}{ifDescr});
 
			if ( $interfaces->{$index}{ifDescr} eq "" ) { 
				$interfaces->{$index}{ifDescr} = "null";
				++$numInterfaces; 
			}else{
				SWITCH:{
					($index <=31) && do { 
						my $AccelarPort= $index-15;
						$interfaces->{$index}{ifDescr} = "Slot 1 Port $AccelarPort";
						++$numInterfaces;
						last SWITCH;};
					(($index >=32) && ($index <= 47)) && do  {
						my $AccelarPort= $index-31;
						$interfaces->{$index}{ifDescr} = "Slot 2 Port $AccelarPort";
						++$numInterfaces;
						last SWITCH;};
					(($index >=48) && ($index <=63 )) && do {
						my $AccelarPort= $index-47;
						$interfaces->{$index}{ifDescr} = "Slot 3 Port $AccelarPort";
						++$numInterfaces;
						last SWITCH;};
					(($index >=64) && ($index <=79)) && do {
						my $AccelarPort= $index-64;
						$interfaces->{$index}{ifDescr} = "Slot 4 Port $AccelarPort";
						++$numInterfaces;
						last SWITCH;};
					(($index >=80) && ($index <= 95)) && do {
						my $AccelarPort= $index-79;
						$interfaces->{$index}{ifDescr} = "Slot 5 Port $AccelarPort";
						++$numInterfaces;
						last SWITCH;};
					(($index >=96) && ($index <= 111)) && do {
						my $AccelarPort= $index-95;
						$interfaces->{$index}{ifDescr} = "Slot 6 Port $AccelarPort";
						++$numInterfaces;
						last SWITCH;};
					(($index >=112) && ($index <= 127)) && do {
						my $AccelarPort= $index-111;
						$interfaces->{$index}{ifDescr} = "Slot 7 Port $AccelarPort";
						++$numInterfaces;
						last SWITCH;};
					(($index >=128) && ($index <= 143)) && do {
						my $AccelarPort= $index-127;
						$interfaces->{$index}{ifDescr} = "Slot 8 Port $AccelarPort";
						++$numInterfaces;
						last SWITCH;};
					$interfaces->{$index}{ifDescr} = "IfIndex $index";
					++$numInterfaces; 
					};
				};
			
			# Set the ifType to be something meaningful!!!! 
			# This is special for Accelars
			SWITCH: {
	  			($interfaces->{$index}{rcPortType} == 6) && do { 
					$interfaces->{$index}{ifType}="10BaseF(mm)";
                        		last SWITCH; };
	  			($interfaces->{$index}{rcPortType} == 5) && do { 
					$interfaces->{$index}{ifType}="1000BaseF(Dual Connector)";
                        		last SWITCH; };
	  			($interfaces->{$index}{rcPortType} == 4) && do { 
					$interfaces->{$index}{ifType}="1000BaseF(mm)";
                        		last SWITCH; };
	  			($interfaces->{$index}{rcPortType} == 3) && do { 
					$interfaces->{$index}{ifType}="100BaseF(mm)";
                        		last SWITCH; };
	  			($interfaces->{$index}{rcPortType} == 2) && do { 
					$interfaces->{$index}{ifType}="100BaseT2(cat3)";
                        		last SWITCH; };
	  			($interfaces->{$index}{rcPortType} == 1) && do { 
					$interfaces->{$index}{ifType}="100BaseTX(cat5)";
                        		last SWITCH; };
				$interfaces->{$index}{ifType}="null"; #else null
				};
			if ($debug) { print "\t ifIndex=$index descr=$interfaces->{$index}{ifDescr} admin=$interfaces->{$index}{ifAdminStatus} oper=$interfaces->{$index}{ifOperStatus} speed=$interfaces->{$index}{ifSpeed} rcPortType=$interfaces->{$index}{rcPortType} ($interfaces->{$index}{ifType})\n"; }
			# Interfaces with N/A in them are bad!
			if ( $interfaces->{$index}{ifSpeed} eq "0" and $interfaces->{$index}{ifType} =~ /ethernet/i ) {
				$interfaces->{$index}{ifSpeed} = 10000000;
			};
			# Set AdminStatus and OperStatus to be a word!!
			$interfaces->{$index}{ifAdminStatus} = $interfaceStatus[$interfaces->{$index}{ifAdminStatus}];
			$interfaces->{$index}{ifOperStatus} = $interfaceStatus[$interfaces->{$index}{ifOperStatus}];

			# get 'ifHighSpeed' if 'ifSpeed' = 4,294,967,295 - refer RFC2863 HC interfaces.
			if ( $interfaces->{$index}{ifSpeed} == 4294967295 ) {
				(	$interfaces->{$index}{ifSpeed}
					) = $session->snmpget(  
					'ifHighSpeed'.".$index",
				); 
				if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
					logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
					$SNMP_Simple::errmsg = "";
					goto END_createInterfaceFile;
				}
				$interfaces->{$index}{ifSpeed} *= 1000000;
			}
		} # FOR LOOP
	} # Accelar or Nortel
	elsif ( $NMIS::systemTable{nodeModel} =~ /BayStack/ ) {
		if ($debug) { print "Collecting $NMIS::systemTable{ifNumber} Interfaces \n"; }
		$validModel = "true";
		
		# Loop to get interface information from SNMP
		my %ifIndexTable = $session->snmpgettablean('ifIndex');
		foreach $index ( sort {$a <=> $b} keys %ifIndexTable) {
			# Get Interface Information
			(       $interfaces->{$index}{ifDescr},
				$interfaces->{$index}{ifType},
				$interfaces->{$index}{ifSpeed},
				$interfaces->{$index}{ifAdminStatus},
				$interfaces->{$index}{ifOperStatus},
				$interfaces->{$index}{ifLastChange}
			) = $session->snmpget(  
				'ifDescr'.".$index",
				'ifType'.".$index",
				'ifSpeed'.".$index",
				'ifAdminStatus'.".$index",
				'ifOperStatus'.".$index",
				'ifLastChange'.".$index"
			); 
			if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
				logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				goto END_createInterfaceFile;
			}

			# ehg 3 Dec 2002 removed bad chars from interface descriptions
			$interfaces->{$index}{ifDescr} = rmBadChars($interfaces->{$index}{ifDescr});
 
			if (($interfaces->{$index}{ifDescr} eq "") || ($interfaces->{$index}{ifDescr} =~ /not present/i)){ 
				$interfaces->{$index}{ifDescr} = "null";
				++$numInterfaces; 
			}elsif ($NMIS::systemTable{nodeModel} =~ /303|304|310|Generic/) {
				$interfaces->{$index}{ifDescr} = "Port $index";
				++$numInterfaces;
			}
			 
			if ($debug) { print "\t ifIndex=$index descr=$interfaces->{$index}{ifDescr} admin=$interfaces->{$index}{ifAdminStatus} oper=$interfaces->{$index}{ifOperStatus} speed=$interfaces->{$index}{ifSpeed}\n"; }
			
			# Set the ifType to be something meaningful!!!!
			$interfaces->{$index}{ifType} = $ifTypeDefs{$interfaces->{$index}{ifType}}{ifType};
	
			# Interfaces with N/A in them are bad!
			#Also Speed of 200Mb are usually 100FDX.
			if ( $interfaces->{$index}{ifSpeed} eq "200000000"){
				$interfaces->{$index}{ifSpeed} = 100000000;}
			if ( $interfaces->{$index}{ifSpeed} eq "0" and $interfaces->{$index}{ifType} =~ /ethernet/i ) {
				$interfaces->{$index}{ifSpeed} = 10000000;
			}
			# Set AdminStatus and OperStatus to be a word!!
			$interfaces->{$index}{ifAdminStatus} = $interfaceStatus[$interfaces->{$index}{ifAdminStatus}];
			$interfaces->{$index}{ifOperStatus} = $interfaceStatus[$interfaces->{$index}{ifOperStatus}];

			# get 'ifHighSpeed' if 'ifSpeed' = 4,294,967,295 - refer RFC2863 HC interfaces.
			if ( $interfaces->{$index}{ifSpeed} == 4294967295 ) {
				(	$interfaces->{$index}{ifSpeed}
					) = $session->snmpget(  
					'ifHighSpeed'.".$index",
				); 
				if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
					logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
					$SNMP_Simple::errmsg = "";
					goto END_createInterfaceFile;
				}
				$interfaces->{$index}{ifSpeed} *= 1000000;
			}
		} # FOR LOOP
	} # BayStack
	# a3com nodemodel=SSII 3Com
	elsif ( $NMIS::systemTable{nodeModel} =~ /SSII 3Com/ ) {
		if ($debug) { print "Collecting $NMIS::systemTable{ifNumber} Interfaces \n"; }
		$validModel = "true";
		
		# Loop to get interface information from SNMP
		my %ifIndexTable = $session->snmpgettablean('ifIndex');
		foreach $index ( sort {$a <=> $b} keys %ifIndexTable) {
			# Get Interface Information
			(   $interfaces->{$index}{ifDescr},
				$interfaces->{$index}{ifType},
				$interfaces->{$index}{ifSpeed},
				$interfaces->{$index}{ifAdminStatus},
				$interfaces->{$index}{ifOperStatus},
				$interfaces->{$index}{ifLastChange}
			) = $session->snmpget(  
				'ifDescr'.".$index",
				'ifType'.".$index",
				'ifSpeed'.".$index",
				'ifAdminStatus'.".$index",
				'ifOperStatus'.".$index",
				'ifLastChange'.".$index"
			); 
			if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
				logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
				$SNMP_Simple::errmsg = "";
				goto END_createInterfaceFile;
			}

			# ehg 3 Dec 2002 removed bad chars from interface descriptions
			$interfaces->{$index}{ifDescr} = rmBadChars($interfaces->{$index}{ifDescr});

			if ( $interfaces->{$index}{ifDescr} eq "" ) { 
				$interfaces->{$index}{ifDescr} = "null";
				++$numInterfaces; 
			}
			 
			if ($debug) { print "\t ifIndex=$index descr=$interfaces->{$index}{ifDescr} admin=$interfaces->{$index}{ifAdminStatus} oper=$interfaces->{$index}{ifOperStatus} speed=$interfaces->{$index}{ifSpeed}\n"; }
			
			# Set the ifType to be something meaningful!!!!
			$interfaces->{$index}{ifType} = $ifTypeDefs{$interfaces->{$index}{ifType}}{ifType};
	
			# Interfaces with N/A in them are bad!
			if ( $interfaces->{$index}{ifSpeed} eq "0" and $interfaces->{$index}{ifType} =~ /ethernet/i ) {
				$interfaces->{$index}{ifSpeed} = 10000000;
			}
			# Set AdminStatus and OperStatus to be a word!!
			$interfaces->{$index}{ifAdminStatus} = $interfaceStatus[$interfaces->{$index}{ifAdminStatus}];
			$interfaces->{$index}{ifOperStatus} = $interfaceStatus[$interfaces->{$index}{ifOperStatus}];

			# get 'ifHighSpeed' if 'ifSpeed' = 4,294,967,295 - refer RFC2863 HC interfaces.
			if ( $interfaces->{$index}{ifSpeed} == 4294967295 ) {
				(	$interfaces->{$index}{ifSpeed}
					) = $session->snmpget(  
					'ifHighSpeed'.".$index",
				); 
				if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
					logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
					$SNMP_Simple::errmsg = "";
					goto END_createInterfaceFile;
				}
				$interfaces->{$index}{ifSpeed} *= 1000000;
			}
		} # FOR LOOP
	} # a3com nodemodel=SSII 3Com
	else {
		$validModel eq "false"; 
	}
	# IP Address Table
	#ip.ipAddrTable.ipAddrEntry.ipAdEntAddr.10.64.100.145 = ipAdEntAddr: 10.64.100.145
	#ip.ipAddrTable.ipAddrEntry.ipAdEntIfIndex.10.64.100.145 = 4
	#ip.ipAddrTable.ipAddrEntry.ipAdEntNetMask.10.64.100.145 = ipAdEntAddr: 255.255.255.248
	#get the IP addressing stuff
	if ( $validModel eq "true") {
		my %ifIndexTable = $session->snmpgettablean('ipAdEntIfIndex');
		my %ifMaskTable = $session->snmpgettablean('ipAdEntNetMask');
		if ( $SNMP_Simple::errmsg =~ /No answer|Unknown/ ) {
			logMessage( " createInterfaceFile, $node, SNMP error: $SNMP_Simple::errmsg") if $debug;
			$SNMP_Simple::errmsg = "";
			goto END_createInterfaceFile;
		}
		if ($debug) { print "\t Getting Device IP Address Table\n"; } 
		foreach $index (keys %ifIndexTable) {
			if ($debug) { 	
				print "\t ip addresses: index=$index ifIndex=$ifIndexTable{$index} mask=$ifMaskTable{$index}\n";	
			}
			$interfaces->{$ifIndexTable{$index}}{ipAdEntAddr} = $index;
			$interfaces->{$ifIndexTable{$index}}{ipAdEntNetMask} = $ifMaskTable{$index};
			($interfaces->{$ifIndexTable{$index}}{ipSubnet},$interfaces->{$ifIndexTable{$index}}{ipSubnetBits}) = ipSubnet(address => $index, mask => $ifMaskTable{$index});
		}
	} # valid model
	
	# Process the table and make any changes necessary
	if ( $validModel eq "true") {
		# Now we have a nicely populated Interface Table lets write it out to a file
		if ($debug) { print returnTime." Interface List for $node\n"; }

		### add in anything we find from sysinterface.csv - allows manual updating of interface variables
		### warning - will overwrite what we got from the device - be warned !!!
		if ( -r $NMIS::config{SysInt_Table} ) {
			%sysint = &loadCSV("$NMIS::config{SysInt_Table}","$NMIS::config{SysInt_Key}","\t");
		}
	
   	    foreach $index ( sort {$a <=> $b} keys %$interfaces) {
			if ($debug) { print "\t Checking $index, ifDescr=$interfaces->{$index}{ifDescr}, ifAlias=\"$interfaces->{$index}{'Description'}\"\n"; }

			### add in anything we find from sysinterface.csv - allows manual updating of interface variables
			### warning - will overwrite what we got from the device - be warned !!!
			# build a new hash using Tie::RegexpHash hash with Regexps as keys that match against fetches
			my $hreg = Tie::RegexpHash->new();		# nodes 
			my $k;
			my $ix;
			my $n;
			foreach $k ( keys %sysint ) {
				( $n , undef ) = split /_/ , $k;
				$hreg->add( qr/$n/, $k );			# keep a reference back  to the original hash
			}

			# look for a match on actual node, ifIndex
			# there maybe more than one match, just match on first

			if ( $k = $hreg->match( $node ) ) {		# string $node matches a regex in sysinterface->Node
				if ( $index =~ qr/$sysint{$k}{ifIndex}/ ) {				# and string $index matches a regex in sysinterface->ifIndex
					# yes -a match , update values
					# overwrite with configured ifspeed, which may be ''
					$interfaces->{$index}{ifSpeed} = $sysint{$k}{ifSpeed} if $sysint{$k}{ifSpeed} ne "";
					# overwrite ifAlias with configured descr, but if that is '#', append old descr, so we have it displayed, but collect=false.
					$interfaces->{$index}{Description} = $sysint{$k}{Description} eq '\#' ?  '# ' . $interfaces->{$index}{Description} : $sysint{$k}{Description};
					print "\t Manual update of Description:$interfaces->{$index}{Description} and ifSpeed:$interfaces->{$index}{ifSpeed} from $NMIS::config{SysInt_Table} Node:$sysint{$k}{Node} ifIndex:$sysint{$k}{ifIndex}\n" if $debug;
				}
			}

			if ( $interfaces->{$index}{ifDescr} ne "" ) {
				# preset collect is true
				$interfaces->{$index}{collect} = "true";
				#
				#Decide if the interface is one that we can do stats on or not based on Description and ifType and AdminStatus
				# If the interface is admin down no stats
				if (	$interfaces->{$index}{ifAdminStatus} eq "down" or
						$interfaces->{$index}{ifAdminStatus} eq "testing" or
						$interfaces->{$index}{ifAdminStatus} eq "null" or
						$interfaces->{$index}{ifDescr} eq "null" or
						$collect eq "false" 
				) {
					$interfaces->{$index}{collect} = "false";
					$interfaces->{$index}{nocollect} = "ifAdminStatus eq down|testing|null or ifDescr eq null"; # reason
					print "\t collect=false: Admin down or null ifDescr\n" if $debug;
				} 
				# if it is a router and the interface name has any of these strings
				elsif ( $NMIS::systemTable{nodeModel} =~ /router|ciscoatm/i ) {
					if ( $interfaces->{$index}{ifDescr} =~ /$qr_no_collect_ifDescr_gen/i ) {
						$interfaces->{$index}{collect} = "false";
						$interfaces->{$index}{nocollect} = "no_collect_ifDescr_gen"; # reason
						print "\t collect=false: no_collect_ifDescr_gen\n" if $debug; }
					elsif (
						# Found problems with Cisco ATM interfaces on new IOS
						$interfaces->{$index}{ifDescr} =~ /$qr_no_collect_ifDescr_atm/i ) { 
						$interfaces->{$index}{collect} = "false";
						$interfaces->{$index}{nocollect} = "no_collect_ifDescr_atm"; # reason
						print "\t collect=false: no_collect_ifDescr_atm\n" if $debug; }
					elsif (
						# Nothing to collect on Voice interfaces
						$interfaces->{$index}{ifDescr} =~ /$qr_no_collect_ifDescr_voice/i ) {
						$interfaces->{$index}{collect} = "false";
						$interfaces->{$index}{nocollect} = "collect_ifDescr_voice"; # reason
						print "\t collect=false: collect_ifDescr_voice\n" if $debug; }
					elsif (
						# or if the interface is of this type
						$interfaces->{$index}{ifType} =~ /$qr_no_collect_ifType_gen/i ) {
						$interfaces->{$index}{collect} = "false";
						$interfaces->{$index}{nocollect} = "no_collect_ifType_gen"; # reason
						print "\t collect=false: no_collect_ifType_gen\n" if $debug; }
					elsif (
						# or if the interface is of this name - description
						$interfaces->{$index}{Description} =~ /$qr_no_collect_ifAlias_gen/i ) {
						$interfaces->{$index}{collect} = "false";
						$interfaces->{$index}{nocollect} = "no_collect_ifAlias_gen"; # reason
						print "\t collect=false: no_collect_ifAlias_gen\n" if $debug; }
					elsif (
						# no collect for interfaces with no description
                        $interfaces->{$index}{Description} eq "" ) {
                        $interfaces->{$index}{collect} = "false";
						$interfaces->{$index}{nocollect} = "no Description (ifAlias)"; # reason
                        print "\t collect=false: no Description (ifAlias)\n" if $debug; }
                       
				}
				elsif ( $NMIS::systemTable{nodeModel} =~ /CatalystIOS|Riverstone/ ) {
					if (	
						$interfaces->{$index}{Description} eq "" ) {
						$interfaces->{$index}{collect} = "false";
						$interfaces->{$index}{nocollect} = "no Description (ifAlias)"; # reason
                        print "\t collect=false: no Description (ifAlias)\n" if $debug; }
                    elsif (
						# or if the interface is of this name - description
						$interfaces->{$index}{Description} =~ /$qr_no_collect_ifAlias_gen/i ) {
						$interfaces->{$index}{collect} = "false";
 						$interfaces->{$index}{nocollect} = "no_collect_ifAlias_gen"; # reason
                       print "\t collect=false: no_collect_ifAlias_gen\n" if $debug; }
                    elsif (
						$interfaces->{$index}{ifDescr} =~ /$qr_no_collect_ifDescr_switch/i ) {
						$interfaces->{$index}{collect} = "false";
						$interfaces->{$index}{nocollect} = "no_collect_ifDescr_switch"; # reason
                        print "\t collect=false: no_collect_ifDescr_switch\n" if $debug; }
                     elsif (
						$interfaces->{$index}{ifType} !~ /ethernet|propVirtual/i ) {
						$interfaces->{$index}{collect} = "false";
						$interfaces->{$index}{nocollect} = "ifType not ethernet|propVirtual"; # reason
                        print "\t collect=false: ifType not 'ethernet|propVirtual'\n" if $debug; }
				}
				# Foundry Mike McHenry 2005
				elsif ( $NMIS::systemTable{nodeModel} =~ /FoundrySwitch/i ) {
					if (
						$interfaces->{$index}{ifDescr} =~ /$qr_no_collect_ifDescr_switch/i
						# or if the interface is of this name - description
						or $interfaces->{$index}{Description} =~ /$qr_no_collect_ifAlias_gen/i
						or $interfaces->{$index}{ifType} !~ /ethernet/i
						and $interfaces->{$index}{ifType} !~ /iso88023Csmacd/i
						and $interfaces->{$index}{ifType} !~ /fastEther/i ) { 
						$interfaces->{$index}{collect} = "false"; 
						$interfaces->{$index}{nocollect} = "no_collect_ifAlias_gen"; # reason
                        print "\t collect=false: qr_no_collect_ifAlias_gen\n" if $debug; }
				}
				elsif ( $NMIS::systemTable{nodeModel} =~ /SSII 3Com/i ) {
					if (
						$interfaces->{$index}{ifDescr}  =~ /Encapsulation|VLAN|trunk|slip|Switch/i ) {
						$interfaces->{$index}{collect} = "false";
						$interfaces->{$index}{nocollect} = "ifDescr is Encapsulation|VLAN|trunk|slip|Switch"; # reason
                        print "\t collect=false: ifDescr is 'Encapsulation|VLAN|trunk|slip|Switch'\n" if $debug; }
				} 
				# if it is a catalyst and the interface name has any of these strings
				elsif ( $NMIS::systemTable{nodeModel} =~ /Catalyst5000Sup3|Catalyst6000|Catalyst5005|Catalyst5000/ ) {
					if (    
						# has to have the port up at the time, this will get rid of PC's and servers that have moved
						$interfaces->{$index}{ifOperStatus} eq "other" ) {
						$interfaces->{$index}{collect} = "false";
						$interfaces->{$index}{nocollect} = "ifOperStatus eq other"; # reason
                        print "\t collect=false: ifOperStatus eq 'other'\n" if $debug; }
                    elsif (	
                    	# or if the interface is of this name - description					
						$interfaces->{$index}{Description} eq "" ) {
						$interfaces->{$index}{collect} = "false";
 						$interfaces->{$index}{nocollect} = "no Description (ifAlias)"; # reason
						print "\t collect=false: no Description (ifAlias)\n" if $debug; }
                    elsif (						
						$interfaces->{$index}{Description} =~ /$qr_no_collect_ifAlias_gen/i ) {
						$interfaces->{$index}{collect} = "false";
 						$interfaces->{$index}{nocollect} = "no_collect_ifAlias_gen"; # reason
						print "\t collect=false: no_collect_ifAlias_gen\n" if $debug; }
				}
				### KS 2 Jan 03 - Changing check for Win2000 to Windows
				elsif ( $NMIS::systemTable{nodeModel} =~ /FreeBSD|SunSolaris|Windows|generic/i ) {
					if (
						$interfaces->{$index}{ifDescr} =~ /$qr_no_collect_ifDescr_gen/i ) {
						$interfaces->{$index}{collect} = "false";
  						$interfaces->{$index}{nocollect} = "no_collect_ifDescr_gen"; # reason
                       print "\t collect=false: no_collect_ifDescr_gen\n" if $debug; }
                       elsif (	
                    	# or if the interface is of this name - description					
						$interfaces->{$index}{Description} eq "" ) {
						$interfaces->{$index}{collect} = "false";
 						$interfaces->{$index}{nocollect} = "no Description (ifAlias)"; # reason
						print "\t collect=false: no Description (ifAlias)\n" if $debug; }
                    elsif (
						$interfaces->{$index}{ifType} =~ /loopback/i ) {
						$interfaces->{$index}{collect} = "false";
  						$interfaces->{$index}{nocollect} = "ifType eq loopback"; # reason
                       print "\t collect=false: ifType eq 'loopback'\n" if $debug; }
				} 
				### Redback Mike McHenry 2005
				elsif ( $NMIS::systemTable{nodeModel} =~ /Redback/ ) {
					if ( $interfaces->{$index}{ifType}  =~ /propVirtual|aal5|ds3|sonet|ppp/i
					) { $interfaces->{$index}{collect} = "false"; 
 						$interfaces->{$index}{nocollect} = "ifType eq propVirtual|aal5|ds3|sonet|ppp"; # reason
                       print "\t collect=false: ifType eq 'propVirtual|aal5|ds3|sonet|ppp'\n" if $debug; }
				} 
				### MIB2
				elsif ( $NMIS::systemTable{nodeModel} =~ /MIB2/i ) {
					if (
						$interfaces->{$index}{ifDescr} =~ /$qr_no_collect_ifDescr_gen/i ) {
						$interfaces->{$index}{collect} = "false";
 						$interfaces->{$index}{nocollect} = "no_collect_ifDescr_gen"; # reason
                         print "\t collect=false: no_collect_ifDescr_gen\n" if $debug; }
   					elsif (
						$interfaces->{$index}{Description} eq "" ) {
						$interfaces->{$index}{collect} = 'false';
  						$interfaces->{$index}{nocollect} = "no Description (ifAlias)"; # reason
                        print "\t collect=false: no Description (ifAlias)\n" if $debug; }
                     elsif (
						$interfaces->{$index}{ifType} =~ /loopback/i ) {
						$interfaces->{$index}{collect} = "false";
  						$interfaces->{$index}{nocollect} = "ifType eq loopback"; # reason
						print "\t collect=false: ifType eq 'loopback'\n" if $debug; }
 				} 
				
				# drop server interfaces that dont have an ip address configured.
				#if (  $NMIS::systemTable{nodeType} eq 'server' and ! $interfaces->{$index}{ipAdEntAddr}  ) {
				#	$interfaces->{$index}{collect} = "false";
				#	print "\t collect=false: no ipAdEntAddr defined ( no ip address configured)\n" if $debug;
				#}
			
				# Remove Nasty comma's from Interface Last Change!
				$interfaces->{$index}{ifLastChange} =~ s/,/ /g;

				if ($debug) { print "\t $index collect=$interfaces->{$index}{'collect'}, ifType=$interfaces->{$index}{'ifType'}, Speed=$interfaces->{$index}{'ifSpeed'}, $interfaces->{$index}{'ifAdminStatus'}, $interfaces->{$index}{'ifOperStatus'}, ifLC=$interfaces->{$index}{'ifLastChange'}\n"; }
	
				$intf = convertIfName($interfaces->{$index}{ifDescr});
				$ifIndex = $index;
				$interfaceTable{$ifIndex}{interface} = $intf;
				$interfaceTable{$ifIndex}{ifIndex} = $ifIndex;
				$interfaceTable{$ifIndex}{ifDescr} = rmBadChars($interfaces->{$index}{ifDescr});
				$interfaceTable{$ifIndex}{collect} = $interfaces->{$index}{collect};
				$interfaceTable{$ifIndex}{ifType} = $interfaces->{$index}{ifType};
				$interfaceTable{$ifIndex}{ifSpeed} = $interfaces->{$index}{ifSpeed};
				$interfaceTable{$ifIndex}{ifAdminStatus} = $interfaces->{$index}{ifAdminStatus};
				$interfaceTable{$ifIndex}{ifOperStatus} = $interfaces->{$index}{ifOperStatus};
				$interfaceTable{$ifIndex}{ifLastChange} = $interfaces->{$index}{ifLastChange};
				$interfaceTable{$ifIndex}{Description} = $interfaces->{$index}{Description};
				$interfaceTable{$ifIndex}{portDuplex} = $interfaces->{$index}{portDuplex};
				$interfaceTable{$ifIndex}{portSpantreeFastStart} = $interfaces->{$index}{portSpantreeFastStart};
				$interfaceTable{$ifIndex}{vlanPortVlan} = $interfaces->{$index}{vlanPortVlan};
				$interfaceTable{$ifIndex}{portAdminSpeed} = $interfaces->{$index}{portAdminSpeed};
				$interfaceTable{$ifIndex}{ipAdEntAddr} = $interfaces->{$index}{ipAdEntAddr};
				$interfaceTable{$ifIndex}{ipAdEntNetMask} = $interfaces->{$index}{ipAdEntNetMask};
				$interfaceTable{$ifIndex}{ipSubnet} = $interfaces->{$index}{ipSubnet};
				$interfaceTable{$ifIndex}{ipSubnetBits} = $interfaces->{$index}{ipSubnetBits};
				$interfaceTable{$ifIndex}{nocollect} = $interfaces->{$index}{nocollect};
			} # if ifdescr not ""
		} # FOR LOOP

		# Write the interface table out.
		&writeCSV(%interfaceTable,$interfacefile,"\t");
	    #foreach $intf (keys %interfaceTable ) {
		#	print "$intf: $interfaceTable{$intf}{ifDescr} $interfaceTable{$intf}{ifType} $interfaceTable{$intf}{ifAdminStatus}\n";
		#}
	} # if validModel
	else {
		if ($debug) { print returnTime." createInterfaceFile - Node is not a valid model $node\n"; }
		logMessage("createInterfaceFile, $node, createInterfaceFile - Node is not a valid model $node");
	}
	# Finished with the SNMP
	END_createInterfaceFile:
	if (defined $session) { $session->close(); }
} # end createInterfaceFile

sub checkConfig {
	my $check = shift;
	my $change = 0;
	my $conf_key;
	my $file;
	my $conf_count = 0;
	my $weight = 0;
	my $metric = 0;
	
	if ($debug>3) { print returnTime." Config Checking - this will validate the NMIS config file=$conf\n"; }
	if ( $check eq "check" ) { $change = 0;  }	
	else { $change = 1; }
	
	foreach $conf_key ( sort keys %NMIS::config ) {
		++$conf_count;
		if ($debug > 3) { print "  config item: $conf_key = $NMIS::config{$conf_key}\n"; }
		# Check files in htdocs stuff
		### AS 23/6/01 Removed map for deprecated map icon check.
		#if ( $conf_key =~ /icon|arrow_|map|styles|help_file/ ) {
		if ( $conf_key =~ /icon|arrow_|styles|help_file|plugin_file/ ) {
			# check if file exists
			$file = $NMIS::config{$conf_key};
			$file =~ s/$NMIS::config{'<url_base>'}/$NMIS::config{web_root}/;
			if ( not -r $file ) {
				warn "  ". returnTime." checkConfig, config item \"$conf_key=$NMIS::config{$conf_key}\" is a file expanded is $file.  The file doesn't exist, check config items \"web_root=$NMIS::config{web_root}\" and \"<url_base>=$NMIS::config{'<url_base>'}\".\n"; }	
			else { 
				if ($type eq "config") { print "    $conf_key=$NMIS::config{$conf_key} - OK\n"; } 
				if ($debug > 3) { print "  $conf_key = $NMIS::config{$conf_key} - expanded $file - this is a file and the file exists.\n"; } 
			}
		}
		# Check files in htdocs stuff
		elsif ( $conf_key =~ /web_.*_root/ ) {
			# check if file exists
			$file = $NMIS::config{$conf_key};
			$file =~ s/$NMIS::config{web_report_root}/$NMIS::config{web_root}/;
			if ( not -d $file ) {
				if ($type eq "config") { createDir($file); }
				else { "  ". warn returnTime." checkConfig, config item \"$conf_key=$NMIS::config{$conf_key}\" is a directory expanded is $file.  The directory doesn't exist, check config items \"web_root=$NMIS::config{web_root}\" and \"web_reports_root=$NMIS::config{web_report_root}\".\n"; }
			}	
			else { 
				if ($type eq "config") { print "    $conf_key=$NMIS::config{$conf_key} - OK\n"; } 
				if ($debug > 3) { print "  $conf_key = $NMIS::config{$conf_key} - expanded $file - this is a directory and the file exists.\n"; } 
			}
		}
		# Check base directories for <> config variables
		elsif ( $conf_key =~ /_root|nmis_|<.*>/ and $conf_key !~ /url|_log$|_host/ ) {
			# check if directory exists
			if ( not -d $NMIS::config{$conf_key} ) {
				if ($type eq "config") { createDir($NMIS::config{$conf_key}); }
				else { "  ". warn returnTime." checkConfig, config item \"$conf_key=$NMIS::config{$conf_key}\" is a directory and the directory doesn't exist\n"; }
			}	
			else { 
				if ($type eq "config") { print "    $conf_key=$NMIS::config{$conf_key} - OK\n"; } 
				if ($debug > 3) { print "  $conf_key = $NMIS::config{$conf_key} - this is a directory and the directory exists.\n"; } 
			}
		}
		# Check files in cgi-bin stuff
		elsif ( $conf_key =~ /^nmis$|^logs$|^admin$|^ip$|^map$|^view$/ ) {
			# check if file exists
			$file = $NMIS::config{$conf_key};
			$file =~ s/$NMIS::config{'<cgi_url_base>'}/$NMIS::config{'<nmis_cgi>'}/;
			if ( not -r $file ) {
				warn "  ". returnTime." checkConfig, config item \"$conf_key=$NMIS::config{$conf_key}\" is a file expanded is $file.  The file doesn't exist, check config items \"cgi_url_base=$NMIS::config{'<cgi_url_base>'}\" and \"<nmis_cgi>=$NMIS::config{'<nmis_cgi>'}\".\n"; }	
			else { 
				if ($type eq "config") { print "    $conf_key=$NMIS::config{$conf_key} - OK\n"; } 
				if ($debug > 3) { print "  $conf_key = $NMIS::config{$conf_key} - expanded $file - this is a file and the file exists.\n"; } 
			}
		}
		# Check straight files 
		elsif ( $conf_key =~ /Table|_file|_log|_conf|AuthUserFile/ or $conf_key eq "file" ) {
			# check if file exists
			if ( not -r $NMIS::config{$conf_key} 
				and $conf_key !~ /Interface_Table|event_log/
			) {
				warn "  ". returnTime." checkConfig, config item \"$conf_key=$NMIS::config{$conf_key}\" is a file and the file doesn't exist\n";
			}	
			else { 
				if ($type eq "config") { print "    $conf_key=$NMIS::config{$conf_key} - OK\n"; } 
				if ($debug > 3) { print "  $conf_key = $NMIS::config{$conf_key} - this is a file and the file exists.\n"; } 
				# set file owner and permission, default: nmis, 0775
				setFileProt($NMIS::config{$conf_key});
			}
		}
		elsif ( $conf_key =~ /_mib$/ ) {

			# !!! check if file exists - this is a list of mibs !!!
			foreach ( split /,/ , $NMIS::config{$conf_key} ) {
				if ( not -r "$NMIS::config{mib_root}/$_" ) {
					warn "  ". returnTime." checkConfig, config item \"$conf_key=$_\" is a OID file and the file doesn't exist in directory $NMIS::config{mib_root}\n";
				}	
				else { 
					if ($type eq "config") { print "    $conf_key=$_ - OK\n"; } 
					if ($debug > 3) { print "  $conf_key = $_ - this is a file and the file exists.\n"; } 
					# set file owner and permission, default: nmis, 0775
					setFileProt("$NMIS::config{mib_root}/$_");
				}
			}
		}
		elsif ( $conf_key =~ /^weight_/ ) {
			if ( $NMIS::config{$conf_key} =~ /^\d+\.\d+$/ ) {
				if ($type eq "config") { print "    $conf_key=$NMIS::config{$conf_key} - OK\n"; }
				$weight = $weight + $NMIS::config{$conf_key};
			} else {
				warn "  ". returnTime." checkConfig, config item \"$conf_key=$NMIS::config{$conf_key}\" is supposed to be a number.\n";
			}
		}
		elsif ( $conf_key =~ /^metric_/ ) {
			if ( $NMIS::config{$conf_key} =~ /^\d+\.\d+$/ ) {
				if ($type eq "config") { print "    $conf_key=$NMIS::config{$conf_key} - OK\n"; }
				$metric = $metric + $NMIS::config{$conf_key};
			} else {
				warn "  ". returnTime." checkConfig, config item \"$conf_key=$NMIS::config{$conf_key}\" is supposed to be a number.\n";
			}
		}
		# things which should be a number
		elsif ( $conf_key =~ /^ping_|^conf_count|graph_amount|graph_height|graph_factor|graph_width|escalate|RR/ ) {
			if ( $NMIS::config{$conf_key} =~ /^\d+$/ ) {
				if ($type eq "config") { print "    $conf_key=$NMIS::config{$conf_key} - OK\n"; }
			} else {
				warn "  ". returnTime." checkConfig, config item \"$conf_key=$NMIS::config{$conf_key}\" is supposed to be a number.\n";
			}
		}
		# things which don't require tests
		elsif ( $NMIS::config{$conf_key} =~ /true|false/
			or $conf_key =~ /_Title|_Key|domain_name|url_base|view_tables|trap_server|snpp_server|nmis_host|dash_title|mgmt_lan|^link_|^mail_|^graph_unit|^no_collect_|^ignore_up_down|int_stats|hc_model|^plugin|^sysLoc/
		) { 
				if ($type eq "config") { print "    $conf_key=$NMIS::config{$conf_key} - OK\n"; } 
		}
		else {
			if ($type eq "config") { print "    $conf_key=$NMIS::config{$conf_key} - NO TEST AVAILABLE\n"; } 
			if ($debug > 3) { print "      no test for config item $conf_key\n"; }
		}
	}
	
	if ( $conf_count ne $NMIS::config{conf_count} ) {
		print "ERROR: NMIS Config file problem; found $conf_count items should be $NMIS::config{conf_count}. Check config against sample config.\n";
	}
	
	if ( $weight != 1 ) {
		warn "  ". returnTime." checkConfig, weight_.* config items do not add up to 1 ( is $weight )which represents 100%\n";
	}
	if ( $metric != 1 ) {
		warn "  ". returnTime." checkConfig, metric_.* config items do not add up to 1 ( is $metric )which represents 100%\n"; 
	}

	# Do the database directories exist if not make them?
	my $dir;
	if ($debug > 3) { print returnTime." Config Checking - Checking database directories\n"; }
	if ( -d "$NMIS::config{database_root}" ) {
		if ($type eq "config") { 
			createDir("$NMIS::config{database_root}/health");
			createDir("$NMIS::config{database_root}/metrics");
			createDir("$NMIS::config{database_root}/health/generic");
			createDir("$NMIS::config{database_root}/health/router");
			createDir("$NMIS::config{database_root}/health/switch");
			createDir("$NMIS::config{database_root}/health/server");
			createDir("$NMIS::config{database_root}/interface");
			createDir("$NMIS::config{database_root}/interface/generic");
			createDir("$NMIS::config{database_root}/interface/router");
			createDir("$NMIS::config{database_root}/interface/switch");
			createDir("$NMIS::config{database_root}/interface/server"); 
		}
	}
	#######################################################################
	# make sure that the interface directories exist
	#######################################################################
	foreach my $node ( keys (%NMIS::nodeTable) ) {
		if ( $NMIS::nodeTable{$node}{active} ne "false" 
			and $NMIS::nodeTable{$node}{collect} eq "true" 
		) {
			# if the directory for interface don't exist create it 
			if (    not -d "$NMIS::config{database_root}/interface/$NMIS::nodeTable{$node}{devicetype}/$node" 
				and not -r "$NMIS::config{database_root}/interface/$NMIS::nodeTable{$node}{devicetype}/$node" 
				and -w "$NMIS::config{database_root}/interface/$NMIS::nodeTable{$node}{devicetype}" 
			) { 
				logMessage("runNodeStats, $node, creating interface database directory");
				createDir("$NMIS::config{database_root}/interface/$NMIS::nodeTable{$node}{devicetype}/$node");
			}
		}
	}
}

sub runLinks {
	my %subnets;
	my %links;
	loadInterfaceInfo;


	if ( -r $NMIS::config{Links_Table} ) {
		if ( !(%links = &loadCSV("$NMIS::config{Links_Table}","$NMIS::config{Links_Key}","\t")) ) {
			if ($debug) { print "\t runLinks: could not find or read $NMIS::config{Links_Table} - links update aborted\n"; }
			return;
		}
	if ($debug) { print "\t runLinks: Loaded $NMIS::config{Links_Table}\n"; }
	}

	if ($debug) { print returnTime." Auto Generating Links file\n"; }
	foreach my $intHash (sort(keys(%NMIS::interfaceInfo))) {
       	if ( 	$NMIS::interfaceInfo{$intHash}{ipAdEntAddr} ne "" and
       			$NMIS::interfaceInfo{$intHash}{ipAdEntAddr} ne "0.0.0.0" and
       			$NMIS::interfaceInfo{$intHash}{ipAdEntAddr} !~ /^127/  
		) {
			my $subnet = $NMIS::interfaceInfo{$intHash}{ipSubnet};
			if ( ! defined $subnets{$subnet}{subnet} 
				and $NMIS::interfaceInfo{$intHash}{collect} eq "true" 
				#and $NMIS::interfaceInfo{$intHash}{ifType} =~ /$qr_link_ifType/
			) {
				loadSystemFile($NMIS::interfaceInfo{$intHash}{node});
				$subnets{$subnet}{subnet} = $subnet;
				$subnets{$subnet}{count} = 1;
				$subnets{$subnet}{description} = $NMIS::interfaceInfo{$intHash}{Description};
				$subnets{$subnet}{mask} = $NMIS::interfaceInfo{$intHash}{ipAdEntNetMask};
				$subnets{$subnet}{ifSpeed} = $NMIS::interfaceInfo{$intHash}{ifSpeed};
				$subnets{$subnet}{ifType} = $NMIS::interfaceInfo{$intHash}{ifType};
				$subnets{$subnet}{address1} = $NMIS::interfaceInfo{$intHash}{ipAdEntAddr};
				$subnets{$subnet}{node1} = $NMIS::interfaceInfo{$intHash}{node};
				$subnets{$subnet}{interface1} = $NMIS::interfaceInfo{$intHash}{ifDescr};
				$subnets{$subnet}{net1} = $NMIS::nodeTable{$NMIS::interfaceInfo{$intHash}{node}}{net};
				$subnets{$subnet}{role1} = $NMIS::nodeTable{$NMIS::interfaceInfo{$intHash}{node}}{role};
				$subnets{$subnet}{location1} = $NMIS::systemTable{sysLocation};
				$subnets{$subnet}{ifIndex1} = $NMIS::interfaceInfo{$intHash}{ifIndex};
			}
			elsif ( defined $subnets{$subnet}{subnet} 
				and $NMIS::interfaceInfo{$intHash}{collect} eq "true" 
				#and $NMIS::interfaceInfo{$intHash}{ifType} =~ /$qr_link_ifType/
			) {
				loadSystemFile($NMIS::interfaceInfo{$intHash}{node});
				++$subnets{$subnet}{count};
				if ( ! defined $subnets{$subnet}{description} ) {	# use node2 description if node1 description did not exist.
					$subnets{$subnet}{description} = $NMIS::interfaceInfo{$intHash}{Description};
				}
				$subnets{$subnet}{address2} = $NMIS::interfaceInfo{$intHash}{ipAdEntAddr};
				$subnets{$subnet}{node2} = $NMIS::interfaceInfo{$intHash}{node};
				$subnets{$subnet}{interface2} = $NMIS::interfaceInfo{$intHash}{ifDescr};				
				$subnets{$subnet}{net2} = $NMIS::nodeTable{$NMIS::interfaceInfo{$intHash}{node}}{net};
				$subnets{$subnet}{role2} = $NMIS::nodeTable{$NMIS::interfaceInfo{$intHash}{node}}{role};
				$subnets{$subnet}{location2} = $NMIS::systemTable{sysLocation};
				$subnets{$subnet}{ifIndex2} = $NMIS::interfaceInfo{$intHash}{ifIndex};

			} 
			if ( $debug>2 ) {
				for my $i ( keys %{ $subnets{$subnet} } ) {
					print " $i=$subnets{$subnet}{$i}";
				}
			print "\n";
			}
		}
	} # foreach
	foreach my $subnet (sort keys %subnets ) {
		if ( $subnets{$subnet}{count} == 2 ) {
			# form a key - use subnet as the unique key, same as read in, so will update any links with new information
			if ( defined $subnets{$subnet}{description} 
				and $subnets{$subnet}{description} ne ""
				) {
				$links{$subnet}{link} = $subnets{$subnet}{description};
			} else {
				# label the link as the subnet if no description
				$links{$subnet}{link} = $subnet;	
			}
			$links{$subnet}{subnet} = $subnets{$subnet}{subnet};
			$links{$subnet}{mask} = $subnets{$subnet}{mask};
			$links{$subnet}{ifSpeed} = $subnets{$subnet}{ifSpeed};
			$links{$subnet}{ifType} = $subnets{$subnet}{ifType};
			$links{$subnet}{net} = $subnets{$subnet}{net1};
			$links{$subnet}{role} = $subnets{$subnet}{role1};
			$links{$subnet}{node1} = $subnets{$subnet}{node1};
			$links{$subnet}{interface1} = $subnets{$subnet}{interface1};
			$links{$subnet}{ifIndex1} = $subnets{$subnet}{ifIndex1};
			$links{$subnet}{node2} = $subnets{$subnet}{node2};
			$links{$subnet}{interface2} = $subnets{$subnet}{interface2};
			$links{$subnet}{ifIndex2} = $subnets{$subnet}{ifIndex2};
			# dont overwrite any manually configured dependancies.
			if ( !exists $links{$subnet}{depend} ) { $links{$subnet}{depend} = "N/A" } 

			# reformat the name
			$links{$subnet}{link} =~ s/ /_/g;

			if ($debug) { print "   Adding link $links{$subnet}{link} for $subnet to links.\n"; }
		}
	}
	&writeCSV(%links,$NMIS::config{Links_Table},"\t");
	logMessage("runLinks: Check file $NMIS::config{Links_Table} and update link names and other entries.\n");
}

### AS 8 June 2002 - Adding overall network metrics collection and updates
sub runMetrics {
	my %groupSummary;
	my $data;
	my $group;
	my $status;

	if ($debug) { print "\n".returnTime." Running metrics!\n"; }

	# re-load the event files here.
	loadEventStateNoLock;
	loadEventStateSlave;				# we need this to display a global up/down on the master

	# Doing the whole network - this defaults to -8 hours span
	my %groupSummary = &getGroupSummary();
	$status = overallNodeStatus;
	$status = statusNumber($status);
	$data->{reachability} = $groupSummary{average}{reachable};
	$data->{availability} = $groupSummary{average}{available};
	$data->{responsetime} = $groupSummary{average}{response};
	$data->{health} = $groupSummary{average}{health};
	$data->{status} = $status;
	#if ($debug) { print returnTime." Doing Network Metrics database! r=$data->{reachability} a=$data->{availability} rt=$data->{responsetime} h=$data->{health} s=$data->{status}\n"; }
	#
	&updateRRDDB(type => "metrics",group => "network", data => $data);
	$NMIS::systemTable{typedraw} .= ",metrics";
	#
	foreach $group (sort ( keys (%NMIS::groupTable) ) ) {
		%groupSummary = getGroupSummary($group);
		$status = overallNodeStatus($group);
		$status = statusNumber($status);
		$data->{reachability} = $groupSummary{average}{reachable};
		$data->{availability} = $groupSummary{average}{available};
		$data->{responsetime} = $groupSummary{average}{response};
		$data->{health} = $groupSummary{average}{health};
		$data->{status} = $status;
		
		#if ($debug) { print returnTime." Doing $group Metrics database! r=$data->{reachability} a=$data->{availability} rt=$data->{responsetime} h=$data->{health} s=$data->{status}\n"; }
		#
		&updateRRDDB(type => "metrics",group => $group, data => $data);
		#
	}
	
} # end runMetrics

sub createDir {
	my $dir = shift;
	if ( $kernel =~ /win32/i ) {
		mkpath $dir;
	} else {
		if ( not -d $dir ) { 
			logMessage("Creating directory $dir\n");
			mkdir($dir,0775) or warn "ERROR: cannot mkdir $dir: $!\n"; 
		}
		# set dir owner and permission, default: nmis, 0775
		setFileProt($dir);
	}
}

sub printApache {
	my $check = shift;
	my $change = 0;
	my $conf_key;
	my $file;
	my @cgi = (
		"nmis",
		"logs",
		"admin",
		"view"
	);
	
	if ($debug > 3) { print returnTime." Apache HTTPD Config for NMIS for config file=$conf\n"; }
	if ( $check eq "check" ) { $change = 0;  }	
	else { $change = 1; }

	print <<EO_TEXT;
## For more information on the listed Apache features read:
## Alias directive:        http://httpd.apache.org/docs/mod/mod_alias.html#alias
## ScriptAlias directive:  http://httpd.apache.org/docs/mod/mod_alias.html#scriptalias
## Order directive:        http://httpd.apache.org/docs/mod/mod_access.html#order
## Allow directive:        http://httpd.apache.org/docs/mod/mod_access.html#allow
## Deny directive:         http://httpd.apache.org/docs/mod/mod_access.html#deny
## AuthType directive:     http://httpd.apache.org/docs/mod/core.html#authtype
## AuthName directive:     http://httpd.apache.org/docs/mod/core.html#authname
## AuthUserFile directive: http://httpd.apache.org/docs/mod/mod_auth.html#authuserfile
## Require directive:      http://httpd.apache.org/docs/mod/core.html#require

# Usual Apache Config File!
#<apache_root>/conf/httpd.conf

# add a password to the users.dat file!
#<apache_root>/bin/htpasswd /usr/local/nmis/conf/users.dat nmis

# restart the daemon!
#<apache_root>/bin/apachectl restart 
#
# NOTE:
# <apache_root> is normally /usr/local/apache
# the "bin" directory might be "sbin"
# the "conf" directory might be "etc"
# the httpd.conf might be split across httpd.conf, access.conf and srm.conf

# NMIS Aliases

Alias $NMIS::config{'<url_base>'}/ "$NMIS::config{web_root}/"
<Directory "$NMIS::config{web_root}">
    Options Indexes FollowSymLinks MultiViews
    AllowOverride None
    Order allow,deny
    Allow from all
</Directory>

ScriptAlias $NMIS::config{'<cgi_url_base>'}/ "$NMIS::config{'<nmis_cgi>'}/"
<Directory "$NMIS::config{'<nmis_cgi>'}">
    Options +ExecCGI
    Order allow,deny
    Allow from all
</Directory>

*** URL required in browser ***
http://$NMIS::config{'nmis_host'}$NMIS::config{'<cgi_url_base>'}/nmiscgi.pl
***

EO_TEXT

}	

sub weightResponseTime {
	my $rt = shift;
	my $responseWeight = 0;

	if ( $rt eq "" ) { 
		$rt = "U";
		$responseWeight = 0; 
	}
	elsif ( $rt !~ /^[0-9]/ ) { 
		$rt = "U";
		$responseWeight = 0; 
	}
	elsif ( $rt == 0 ) { 
		$rt = 1; 
		$responseWeight = 100; 
	}
	elsif ( $rt >= 1500 ) { $responseWeight = 0; }
	elsif ( $rt >= 1000 ) { $responseWeight = 10; }
	elsif ( $rt >= 900 ) { $responseWeight = 20; }
	elsif ( $rt >= 800 ) { $responseWeight = 30; }
	elsif ( $rt >= 700 ) { $responseWeight = 40; }
	elsif ( $rt >= 600 ) { $responseWeight = 50; }
	elsif ( $rt >= 500 ) { $responseWeight = 60; }
	elsif ( $rt >= 400 ) { $responseWeight = 70; }
	elsif ( $rt >= 300 ) { $responseWeight = 80; }
	elsif ( $rt >= 200 ) { $responseWeight = 90; }
	elsif ( $rt >= 0 ) { $responseWeight = 100; }
	return ($rt,$responseWeight);
}

### add column to an existing NMIS table
### Cologne 2005
###
sub addColumn {
	my $table = shift;	# name of table, example => Nodes
	my $column = shift;	# name of column
	my $value = shift;

	print returnTime." addColumn: add column $column, value $value to table $table\n" if $debug;

	my $table_file = $table."_Table";
	my $key = $table."_Key";
	my %table_data = loadCSV($NMIS::config{$table_file},$NMIS::config{$key});
	if ( exists $NMIS::config{$table_file} ) {
		foreach my $key( keys %table_data ) { 
			if ( not exists $table_data{$key}{$column} ) { $table_data{$key}{$column} = $value; }
		}
		&writeCSV( %table_data, $NMIS::config{$table_file},"\t" );
	} else {
		print returnTime." addColumn: table $table not declared in configuration file $conf\n" if $debug;
	}
}

### create hash for nbarpd/rttmon and write to /var for speeding up NBARPD/RTTMON plugin
### Cologne 2005
###
sub createNBARPDInfo {
	my $node;
	my %NBARPDInfo;
	
	&loadNodeDetails;

	print returnTime." createNBARPDInfo: Getting Info from all NBARPD/RTTMON nodes.\n" if $debug;

	# Write a node entry for each nbarpd/rttmon node
	foreach $node (sort( keys(%NMIS::nodeTable) ) )  {
		if ( $NMIS::nodeTable{$node}{active} ne "false" ) {
			loadSystemFile($node);
			if ( $NMIS::systemTable{nbarpd} eq "true") {
	  			$NBARPDInfo{$node}{node} = $node;
			}
			# RTTMON is using this info
			$NBARPDInfo{$node}{nodeModel} = $NMIS::systemTable{nodeModel};
		}
	}
	# write to disk
	writeHashtoVar("nbarpdinfo",\%NBARPDInfo) ;
}

sub checkArgs {
	print <<EO_TEXT;
$0 NMIS Polling Engine - Network Management Information System
Copyright (C) 2000 Sinclair InterNetworking Services Pty Ltd
Version $NMIS::VERSION

command line options are:
  type=<option>          Where <option> is one of the following:
                           collect   NMIS will collect all statistics;
                           update    Update all the dynamic NMIS configuration
                           threshold Check collected stats for thresholds
                           escalate  Run the escalation routine only ( debug use only)
                           config    Validate the chosen configuration file
                           apache    Produce Apache configuration for NMIS
                           links     Generate the links.csv file.
                           rme       Read and generate a node.csv file from a Ciscoworks RME file
  [file=<file name>]     Optional alternate configuation files;
  [node=<node name>]     Run operations on a single node;
  [group=<group name>]   Run operations on all nodes in the names group;
  [debug=true|false|0-9] default=false - Show debuging information, handy;
  [collect=true|false]   default=true - Do the SNMP collection or not;
  [rmefile=<file name>]  RME file to import.
  [mthread=true|false]   default=false - Enable Multithreading or not;
  [mthreaddebug=true|false] default=false - Enable Multithreading debug or not;
  [maxthreads=<1..XX>]  default=2 - How many threads should nmis create;

EO_TEXT
}
