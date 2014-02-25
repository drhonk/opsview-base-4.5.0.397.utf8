#!/usr/bin/perl
#
# $Id: nmiscgi.pl,v 1.110 2007/05/28 12:26:29 decologne Exp $
#
#    nmiscgi.pl - NMIS CGI Program - Network Mangement Information System
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
# Auto configure to the <nmis-base>/lib and <nmis-base>/files/nmis.conf
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "/usr/local/rrdtool/lib/perl";

#
#****** Shouldn't be anything else to customise below here *******************

require 5;
use Fcntl qw(:DEFAULT :flock);

use Time::ParseDate;
use RRDs;
use strict;
use web;
use csv;
use NMIS;
use func;
use rrdfunc;
use detail;
use ip;

# NMIS Authentication module
use NMIS::Users;
use NMIS::Auth;
use NMIS::Toolbar;
 
# Prefer to use CGI::Pretty for html processing
use CGI::Pretty qw(:standard *table *Tr *td *form *Select *div);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";
push @CGI::Pretty::AS_IS, qw(p h1 h2 center b comment option span);


my @name_value_array;
my @name_value_pair;
my $tname_value_pair;
my $tindex;
my $tname;
my $tvalue;
my %form_data;
my $form_data_key;

# declare holder for CGI objects
use vars qw($q);
$q = new CGI; # This processes all parameters passed via GET and POST

my $this_script = $q->url(-relative=>1);	# Use this instead of $this_script
my $this_script_full = $q->url(-absolute=>1);	# Use this instead of <cgi_url_base>

# variables used for the security mods
use vars qw(@cookies); @cookies = ();
use vars qw(%headeropts); %headeropts = ();


#my %FORM;

# Break the query up for the names
my $type = $q->param('type');
my $node = $q->param('node');
my $lnode = $q->param('lnode');
my $link = $q->param('link');
my $debug = $q->param('debug');
my $ack = $q->param('ack');
my $event = $q->param('event');
my $details = $q->param('details');
my $graphtype = $q->param('graphtype');
my $graphlength = $q->param('graphlength');
my $graphstart = $q->param('graphstart');
my $glamount = $q->param('glamount');
my $glunits = $q->param('glunits');
my $gsamount = $q->param('gsamount');
my $gsunits = $q->param('gsunits');
my $width = $q->param('width');
my $height = $q->param('height');
my $report = $q->param('report');
my $find = $q->param('find');
my $intf = $q->param('intf');
my $health = $q->param('health');
my $length = $q->param('length');
my $sort = $q->param('sort');
my $outage = $q->param('outage');
my $start = $q->param('start');
my $end = $q->param('end');
my $date_start = $q->param('date_start');
my $date_end = $q->param('date_end');
my $change = $q->param('change');
my $group = $q->param('group');
my $menu = $q->param('menu');
my $title = $q->param('title');
my $graphx = $q->param('graph.x');
my $graphy = $q->param('graph.y');
my $sort1 = $q->param('sort1');
my $sort2 = $q->param('sort2');
my $plugins = $q->param('plugins');
my $ddescr = $q->param('interface');
my $item = $q->param('item');
my $conf = $q->param('file');

my @event_group = $q->param('event_group');
my @event_ack = $q->param('event_ack');
my @node_list = $q->param('node_list');

my @my_data = $q->param(); # fetch all names
my $my_data;

my $Device_Syslog; 

# Allow program to use other configuration files
$conf = "nmis.conf" if $conf eq "" ;
my $configfile = "$FindBin::Bin/../conf/$conf";
if ( -f $configfile ) { loadConfiguration($configfile); }
else { die "Can't access configuration file $configfile.\n"; }

# Before going any further, check to see if we must handle
# an authentication login or logout request

$NMIS::config{auth_require} = 0 if ( ! defined $NMIS::config{auth_require} );
$NMIS::config{auth_require} =~ s/^[fn0].*/0/i;
$NMIS::config{auth_require} =~ s/^[ty1].*/1/i;

my $auth = ();
my $user = ();
my $tb = ();

# set minimal test for security and authorization used throughout
# code. Otherwise, if Auth.pm module is not available then
# create pseudo $auth object to put around auth code chunks
#
eval {
	require NMIS::Auth or die "NO_NAUTH module";
};
if ( $@ =~ /NO/ ) {
	$auth = \{ Require => 0 };	
} else {
	$auth = NMIS::Auth->new;  # NMIS::Auth::new will reap init values from $NMIS::config
	$user = NMIS::Users->new;   # NMIS::Users is dependent upon NMIS::Auth
}
 
# NMIS::Auth->new () and NMIS::User->new () may eventually do all this
#
if ( $auth->Require ) {
	if ( $type eq 'login') {
        	$auth->do_login;
		exit 0;
	} elsif ( $type eq 'logout' ) {
        	$auth->do_logout;
		exit 0;
	} elsif ( param('username') ) { # someone is trying to log in
        if( $auth->user_verify( param('username'), param('password') ) ) {
			$user->SetUser(param('username'));
        	} else { # bad login: force it again
			$auth->do_login("Invalid username/password combination");
			exit 0;
        }
	} else {
        	# check for username from other sources
		# either set by the web server or via a set cookie
        	$user->SetUser( $auth->verify_id() );
	}

	# $user should be set at this point, if not then redirect
	unless ( $user->user ) {
		$auth->do_force_login("Authentication is required. Please login.");
		exit 0;
	}

} else { # no authentication required -- redirect to main page if log* requested
	if ( $type eq 'login' or $type eq 'logout' ) { # redirect
		print redirect({uri=>url(-full=>1), status=>"302"});
	}
}

# generate the cookie if $user->user is set
#
if ( $auth->Require and $user->user ) {
        push @cookies, $auth->generate_cookie($user->user);
        $headeropts{-cookie} = [@cookies];
}

my ($graphret, $xs, $ys, $ERROR);

my %summaryHash;

# Set the debug to be on or off from the command line argument
if ( $debug eq "true" ) {
        $debug = "true";
        $NMIS::debug = "true";
}
elsif ( $debug eq "verbose" ) {
        $debug = "verbose";
        $NMIS::debug = "verbose";
}
else {
		$debug = "";
        $NMIS::debug = "";
}

# Find the kernel name
my $kernel;
if (defined $NMIS::config{kernelname}) {
	$kernel = $NMIS::config{kernelname};
} elsif ( $^O !~ /linux/i) {
	$kernel = $^O;
} else {
	$kernel = `uname -s`;
}
chomp $kernel; $kernel = lc $kernel;

# if master load slave table
if ($NMIS::config{master_dash} eq "true") { &loadSlave; }

# set the usermenu display switch based on calling address.
$NMIS::userMenu = &userMenuDisplay();

# patch for links based on ifIndex
my %intdd;
if ( $ddescr ne "" ) {
	%intdd = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-interface.dat","ifDescr","\t");
	$ddescr=lc($ddescr);
	$intf=$intdd{$ddescr}{ifIndex};
}
my $ddinf=$intf;
# end patch

# default graph length is 48 hours
# gl = graph length
# gs = graph start
if ( $glamount eq "" ) { $glamount = $NMIS::config{graph_amount}; }
if ( $glunits eq "" ) { $glunits = $NMIS::config{graph_unit}; }
if ( $gsamount eq "" ) { $gsamount = $NMIS::config{graph_amount}; }
if ( $gsunits eq "" ) { $gsunits = $NMIS::config{graph_unit}; }
my $win_width = $NMIS::config{graph_width} + 128;
my $win_height = $NMIS::config{graph_height} + 320;

#Global Time Stamp from when set date is.
my ($time,$datestamp,$datestamp_2, $adminCellColor, $operCellColor, $lastCellColor, $availCellColor, $operAvailability, $totalUtil, $totalCellColor, $intString);

# A couple of regular use variables
my ($line,$tmpifDescr,$graph);

# Global Interpreted Variables ie stuff we figured out.
my ($nodeType, $nodeVendor, $nodeModel, $index, $out);

# fast regex
my $qr_collect_rps_gen = qr/$NMIS::config{collect_rps_gen}/i;
my $qr_voice_stats = qr/$NMIS::config{voice_stats}/i;

my @CBQosNames; # Global table for policy and classmap names
my %CBQosValues;
my $CBQosActive = "false";
if ($type =~ /graph/) { &loadCBQos($node, $intf);} # load CBQoS values 

# Select function to be performed

### new - always load the key files and dont load them again anywhere else
loadNodeDetails;				# get this loaded too.
loadEventStateNoLock;			# populate the current events hash
loadEventStateSlave;			# and any slave 'Node Down' events, if they exist to colour nodeline


# make the default action to be info
# only do this stuff if $NMIS::userMenu==true.

if ( $find ne "" and $NMIS::userMenu==1) { &typeFind; }
	elsif ( $outage ne "" and $NMIS::userMenu==1) { &typeOutage; }
	elsif ( $type eq "" and $node ne "") { &typeInfo; }
	elsif ( $type eq "info" and $node ne "") { &typeInfo; }
	elsif (	$type eq "health" and $node ne "" ) { &typeHealth; }
	elsif (	$type eq "port" and $node ne "" ) { &typePort; }
	elsif (	$type eq "portpvc" and $node ne "" ) { &typePVC; }
	elsif (	$type eq "summary" and $node ne "" ) { &typeInfo; }
	elsif ( $type eq "link" ) { &typeLink; }
	elsif ( $type eq "dns" and $NMIS::userMenu==1) { &typeDNS; }
	elsif ( $type eq "event") { &typeEvent($node); }
	elsif ( $type eq "graph" ) { &typeGraph; }
	elsif ( $type eq "config" and $NMIS::userMenu==1) { &typeConfig; }
	elsif ( $type eq "nodes" and $NMIS::userMenu==1) { &typeNodes; }
	elsif ( $type eq "find" ) { &typeFind; }
	elsif ( $type eq "outage" and $NMIS::userMenu==1) { &typeOutage; }
	elsif ( $type eq "collectmsg" ) { &typeCollectMsg; }
	elsif ( $type eq "mack") { &ackEvent; }
	elsif ( $type eq "ack") {
		&eventAck(ack => $ack, node => $node, event =>$event, details => $details, ackuser => $user->user);
		&typeEvent();
	}
	elsif ( $type eq "drawgraph" ) {
		&rrdDraw( node => $node, type => $q->param('graph'), group => $group,
			glamount => $glamount, glunits => $glunits,
			start => $start, end => $end,
			width => $width, height => $height,
			intf => $ddinf,
			item => $item
	);
}
elsif ( $type eq "export" ) {

	##master/slave stuff ###
	##assume same directory structure / or addin as option - later..
	# if node is foreign to this box, redirect to slave box that has the data
	# $my_data has the original url.

	if ( exists $NMIS::nodeTable{$node}{slave} ) {
		print "Location: http://$NMIS::nodeTable{$node}{slave}/cgi-nmis/nmiscgi.pl?/$my_data\n\n";
	}
	else {
		&rrdExport( node => $node, type => $graphtype, group => $group,
			start => $start, end => $end, intf => $ddinf, item => $item );
	}
}
elsif ( $type eq "stats" ) {

	##master/slave stuff ###
	##assume same directory structure / or addin as option - later..
	# if node is foreign to this box, redirect to slave box that has the data
	# $my_data has the original url.

	if ( exists $NMIS::nodeTable{$node}{slave} ) {
		print "Location: http://$NMIS::nodeTable{$node}{slave}/cgi-nmis/nmiscgi.pl?/$my_data\n\n";
	}
	else {
		&rrdStats( node => $node, type => $graphtype, group => $group,
			start => $start, end => $end, intf => $ddinf, item => $item );
	}
}
else { &typeNMISMenu; }

exit 0;

sub conf { return $conf ;}

sub typeNMISMenu {

	pageStart("$NMIS::config{dash_title}","true",\%headeropts);
	print "<!-- typeNMISMenu begin -->\n";
	cssTableStart;
#	print "<tr><td class=\"dash\" colspan=\"1\">$NMIS::config{dash_title}</td></tr>\n";
	print start_Tr(),
		td({class=>"white"});
	do_dash_banner($auth->Require, $user->user),
	print	end_td(),
		end_Tr;
	if ( $group ne "" and $user->InGroup($group) ) { 
		&nmisGroupSummary($group); 
	}
	elsif ( $menu eq "large" && $type eq "summary" or $NMIS::config{show_large_menu} eq "true" && $type eq "summary" ) { 
		&nmisMenuLargeDetailed; 
	}
	elsif ( $menu eq "large" or $NMIS::config{show_large_menu} eq "true" ) { 
		&nmisMenuLarge; 
	}
	elsif ( $menu eq "small" or $NMIS::config{show_large_menu} eq "false" ) {
		&nmisMenuSmall;
		$NMIS::userMenu && &nmisMenuBar;
		&nmisSummary;
	}
	else {
		&nmisMenuSmall;
		$NMIS::userMenu && &nmisMenuBar;
		&nmisSummary;
	}
#	rowStart;
#	cssPrintCell("grey","<a href=\"http://ee-staff.ethz.ch/~oetiker/webtools/rrdtool/\"><img border=\"0\" alt=\"RRDTool\" src=\"$NMIS::config{'<url_base>'}/rrdtool.gif\"></a>",1);
#	rowEnd;
  	print Tr(td({class=>"white"}, &do_footer ));
	tableEnd;
	print "<!-- typeNMISMenu end -->\n";
	pageEnd;
}

sub typeConfig {

	my $out;
	# verify access to this command/tool bar/button
	#
	if ( $auth->Require ) {
		# CheckAccess will throw up a web page and stop if access is not allowed
		$auth->CheckAccess($user, "nmisconf") or die "Attempted unauthorized access";
 	}

	pageStart("View Configuration","false",\%headeropts);
	print "<!-- typeConfig begin -->\n";
	cssTableStart;
	&nmisMenuSmall;
	&nmisMenuBar;
	cssHeaderBar("View Configuration $configfile","grey");

	rowStart;
		cssCellStart("white",6);
		cssTableStart("white");
		rowStart;
			cellStart;
			preStart;

			if ( $ENV{REMOTE_USER} ne "" ) {
				$out = `/usr/bin/cat $configfile`;
			}
			else {
				# If you want authorised users then comment out this line
				# after configuring Apache authentication.
				$out = `/usr/bin/cat $configfile`;
				# and uncomment this one
			 	#$out = "Not allowed by this user";
			}

			print "$out";

			preEnd;
			cellEnd;
		rowEnd;
		tableEnd;
		cellEnd;
	rowEnd;
	tableEnd;
	print "<!-- typeConfig end -->\n";
	pageEnd;
}

sub typeGraph {
	my $graph_time;
	my $start_time;
	my $end_time;
	my $datestamp_start;
	my $datestamp_end;
	my $graphLink;
	my $random = rand 10000;
	my $heading;
	my $changed = $false;
	my $database;
	
	# verify access to this command/tool bar/button
	#
	if ( $auth->Require ) {
		# CheckAccess will throw up a web page and stop if access is not allowed
		# $auth->CheckAccess($user, "") or die "Attempted unauthorized access";
		if ( ! $user->user ) {
			do_force_login("Authentication is required to access this function. Please login.");
			exit 0;
		}
	}
	
	my $width = $NMIS::config{graph_width};
	my $height = $NMIS::config{graph_height};

	if ( $graphtype eq "metrics" and $group eq "" ) { 
		$group = "network";
		$node = "";
	}

	if ( $start eq "" ) { $start = time - convertTimeLength($gsamount,$gsunits); }
	if ( $end eq "" ) { $end = time; }

	# width by default is 800, height is varialble but always greater then 250
	if ( $q->param('graphdate') eq "true" ) {
		$start_time = parsedate($date_start);
		$end_time = parsedate($date_end);
		$start = parsedate($date_start);
		$end = parsedate($date_end);
	}
	#left
	elsif ( $graphx != 0 and $graphx < 150 ) {
		$gsamount = $gsamount + ( $glamount / $NMIS::config{graph_factor} );
		$end_time = $end - convertTimeLength($glamount / $NMIS::config{graph_factor},$glunits);
		$start_time = $end_time - convertTimeLength($glamount,$glunits);
	}
	#right
	elsif ( $graphx != 0 and $graphx > $width + 94 - 150 ) {
		$gsamount = $gsamount - ( $glamount / $NMIS::config{graph_factor} );
		$end_time = $end + convertTimeLength($glamount / $NMIS::config{graph_factor},$glunits);
		$start_time = $end_time - convertTimeLength($glamount,$glunits);
	}
	#zoom in
	elsif ( $graphx != 0 and ( $graphy != 0 and $graphy <= $height / 2 ) ) {
		$glamount = $glamount / $NMIS::config{graph_factor};
		$gsamount = $gsamount / $NMIS::config{graph_factor};
		$end_time = $end;
		$start_time = $end_time - convertTimeLength($glamount,$glunits);
	}
	#zoom out
	elsif ( $graphx != 0 and ( $graphy != 0 and $graphy > $height / 2 ) ) {
		$glamount = $glamount * $NMIS::config{graph_factor};
		$gsamount = $gsamount * $NMIS::config{graph_factor};
		$end_time = $end;
		$start_time = $end_time - convertTimeLength($glamount,$glunits);
	}
	else {
		$start_time = time - convertTimeLength($gsamount,$gsunits);
		$end_time = $start_time + convertTimeLength($glamount,$glunits);
	}
	$date_start = returnDateStamp($start_time);
	$date_end = returnDateStamp($end_time);

	# Stop from drilling into the future!
	if ( $end_time > time ) {
		$end_time = time;
		$start_time = $end_time - convertTimeLength($gsamount,$gsunits);
	}

	$datestamp_start = returnDateStamp($start_time);
	$datestamp_end = returnDateStamp($end_time);

	$heading = &graphHeading($graphtype);

	pageStart("Graph Drill In for $heading @ ".returnDateStamp,"true",\%headeropts);
	print "<!-- typeGraph begin -->\n";
	cssTableStart;
	#&nmisMenuSmall;

#	cssHeaderBar("$heading for $glamount $glunits","grey");

	# Get the System info from the file and whack it into the hash
	loadSystemFile($node);
 	# verify that user is authorized to view the node within the user's group list
	#

	if ( $node ) {
		if ( ! $user->InGroup($NMIS::nodeTable{$node}{group}) ) {
			cssHeaderBar("Not Authorized to view graphs on node '$node' in group '$NMIS::nodeTable{$node}{group}'.","grey");
			pageEnd;
			return 0;
		}
	} elsif ( $group ) {
		if ( ! $user->InGroup($group) ) {
			cssHeaderBar("Not Authorized to view graphs on nodes in group '$group'.","grey");
			pageEnd;
			return 0;
		}
	}

	cssHeaderBar("$heading for $glamount $glunits","grey");

	my %interfaceTable;
	if ( $NMIS::nodeTable{$node}{collect} eq "true" ) {
		%interfaceTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-interface.dat","ifIndex","\t");
	}

	# clean non existing choices
	if ( $node ne $lnode and $lnode ne "" ) {
		$intf = "";
		if ( $NMIS::systemTable{typedraw} !~ /$graphtype/ ) { $graphtype = "health"; } # preset node
	} elsif ( $NMIS::systemTable{"typedraw$intf"} != /$graphtype/ ) {
		$graphtype = $NMIS::config{portstats} ; # preset interface
	}
	if ( $graphtype eq "calls" and $NMIS::systemTable{'typedraw_calls'} !~ /,$intf/ ) { 
	##	$intf = (split /,/ , $NMIS::systemTable{'typedraw_calls'})[1]; 
		$intf = ""; 
	}

	rowStart;
	cssCellStart("white");
	cssTableStart("white");
	&graphMenu;

	my %node_button_table = (
			# typedraw		==	display #
			',health' 		=> 'Health' ,
			',response' 	=> 'Response' ,
			',cpu' 			=> 'CPU' ,
			',acpu' 		=> 'CPU' ,
			',ip' 			=> 'IP' ,
			',traffic'		=> 'Traffic' ,
			',mem-proc'		=> 'Memory' ,
			',pic-conn'		=> 'Connections' ,
			',a3bandwidth'	=> 'Bandwidth' ,
			',a3traffic'	=> 'Traffic' ,
			',a3errors'		=> 'Errors'
	);

	if ( getGraphType($graphtype) !~ /interface|pkts|cbqos/i or $intf eq "") {
		# display the most important NODE buttons
		print "<th class=\"menubar\" colspan=\"2\"><div class=\"as\">";
		
		foreach my $typedraw (sort keys %node_button_table) {
			if ($NMIS::systemTable{typedraw} =~ /$typedraw/ ) {
				my $graphtype = substr($typedraw,1);
				print "<a class=\"b\" href=\"$this_script?file=$conf&amp;type=graph&amp;graphtype=$graphtype&amp;node=$node&amp;glamount=$glamount&amp;glunits=$glunits&amp;gsamount=$gsamount&amp;gsunits=$gsunits&amp;intf=$intf\">$node_button_table{$typedraw}</a>\n";
			}
		}
		print <<EO_HTML;
		<a class=\"b\" href=\"$this_script?file=$conf&amp;type=export&amp;graphtype=$graphtype&amp;node=$node&amp;group=$group&amp;start=$start_time&amp;end=$end_time&amp;intf=$intf&amp;item=$item\">Export</a>
		<a class=\"b\" href=\"$this_script?file=$conf&amp;type=stats&amp;graphtype=$graphtype&amp;node=$node&amp;group=$group&amp;start=$start_time&amp;end=$end_time&amp;intf=$intf&amp;item=$item\">Stats</a>
		<a class=\"b\" href=\"$this_script?file=$conf&amp;type=graph&amp;graphtype=nmis&amp;node=&amp;group=network&amp;start=$start_time&amp;end=$end_time&amp;intf=&amp;item=\">NMIS</a>
		</div></th></tr>
		<tr>
		<tr>
		<td class="menubar" colspan="4">$heading</td>
		</tr>
EO_HTML

		# display service name buttons if there is more then one service for this node
		if ( $graphtype eq "service" and $NMIS::systemTable{typedraw} =~ /service/) {
			$NMIS::systemTable{service} =~ s/^,// ; # remove first comma
			if ( ($NMIS::systemTable{service} =~ s/,/,/g) gt 0) {
				# type service name buttons
				print <<EO_HTML;
				<tr><td colspan="4"><table class="plain" width="100%" summary="Display">
				<tr>
				<td class="menubar">Service</td>
				<th class="menubar"><div>
EO_HTML
				# buttons
				for my $srvc (split /,/ , $NMIS::systemTable{service}) {
					print "<a class=\"b\"  href=\"$this_script?file=$conf&amp;type=graph&amp;graphtype=service&amp;node=$node&amp;glamount=$glamount&amp;glunits=$glunits&amp;gsamount=$gsamount&amp;gsunits=$gsunits&amp;intf=$intf&amp;item=$srvc\">&nbsp;$srvc&nbsp;</a>";
					if ($item eq "") { $item = $srvc; } # preset default on first service
				}
				print "</div></th></tr></table></tr>";
			} else {
				$item = $NMIS::systemTable{service} ; # this is the only one
			}
		}
		# display Call buttons if there is more then one call port for this node
		if ( $graphtype eq "calls" and $NMIS::systemTable{typedraw} =~ /calls/) {
			$NMIS::systemTable{'typedraw_calls'} =~ s/^,// ; # remove first comma
			if ( ($NMIS::systemTable{'typedraw_calls'} =~ s/,/,/g) gt 0) {
				# type call interface name buttons
				print <<EO_HTML;
				<tr><td colspan="4"><table class="plain" width="100%" summary="Display">
				<tr>
				<th class="menubar"><div>Call port&nbsp;&nbsp;
EO_HTML
				# buttons
				for my $if (split /,/ , $NMIS::systemTable{'typedraw_calls'}) {
					print "<a class=\"b\"  href=\"$this_script?file=$conf&amp;type=graph&amp;graphtype=calls&amp;node=$node&amp;glamount=$glamount&amp;glunits=$glunits&amp;gsamount=$gsamount&amp;gsunits=$gsunits&amp;intf=$if\">&nbsp;$interfaceTable{$if}{ifDescr} &nbsp</a>&nbsp;";
				}
				print "</div></th></tr></table></tr>";
			}
		}
		print <<EO_HTML;
		<tr>
			<th colspan="4">Clickable graphs: Left -> Back; Right -> Forward; Top Middle -> Zoom In; Bottom Middle-> Zoom Out, in time</th>
		</tr>
EO_HTML

	} else {

		# it's an interface, get the lastupdate timestamp from RRD
		my $extName = $interfaceTable{$intf}{ifDescr};
		my $CBQosButton;
		if ( $NMIS::systemTable{"typedraw$intf"} =~ /cbqos/) {
			if ($NMIS::systemTable{"typedraw$intf"} =~ /cbqos-in/) {
				$CBQosButton = "<a class=\'b\' href=\'$this_script?file=$conf&amp;type=graph&amp;graphtype=cbqos-in&amp;node=$node&amp;glamount=$glamount&amp;glunits=$glunits&amp;gsamount=$gsamount&amp;gsunits=$gsunits&amp;intf=$intf&amp;item=\'>CBQoS In</a>";
			}
			if ($NMIS::systemTable{"typedraw$intf"} =~ /cbqos-out/) {
				$CBQosButton .= "<a class=\'b\' href=\'$this_script?file=$conf&amp;type=graph&amp;graphtype=cbqos-out&amp;node=$node&amp;glamount=$glamount&amp;glunits=$glunits&amp;gsamount=$gsamount&amp;gsunits=$gsunits&amp;intf=$intf&amp;item=\'>CBQoS Out</a>";
			}
			$database = getRRDFileName(type => $graphtype, node => $node, nodeType => $NMIS::systemTable{nodeType}, extName => $extName, item => $item);
		} else {

			$database = getRRDFileName(type => "interface", node => $node, nodeType => $NMIS::systemTable{nodeType}, extName => $extName);
		}
		$time = RRDs::last $database;
		my $lastUpdate = returnDateStamp($time);
		my $speed = &convertIfSpeed($interfaceTable{$intf}{ifSpeed});
		print <<EO_HTML;
		<th class="menubar" colspan="2">
			<div class="as">
				<a class=\"b\" href=\"$this_script?file=$conf&amp;type=graph&amp;graphtype=bits&amp;node=$node&amp;intf=$intf&amp;glamount=$glamount&amp;glunits=$glunits&amp;gsamount=$gsamount&amp;gsunits=$gsunits\">Bits</a>
				<a class=\"b\" href=\"$this_script?file=$conf&amp;type=graph&amp;graphtype=util&amp;node=$node&amp;intf=$intf&amp;glamount=$glamount&amp;glunits=$glunits&amp;gsamount=$gsamount&amp;gsunits=$gsunits\">Util</a>
				$CBQosButton
				<a class=\"b\" href=\"$this_script?file=$conf&amp;type=graph&amp;graphtype=response&amp;node=$node&amp;glamount=$glamount&amp;glunits=$glunits&amp;gsamount=$gsamount&amp;gsunits=$gsunits&amp;intf=$intf\">Response</a>
				<a class=\"b\" href=\"$this_script?file=$conf&amp;type=graph&amp;graphtype=cpu&amp;node=$node&amp;glamount=$glamount&amp;glunits=$glunits&amp;gsamount=$gsamount&amp;gsunits=$gsunits&amp;intf=$intf\">CPU</a>
				<a class=\"b\" href=\"$this_script?file=$conf&amp;type=graph&amp;graphtype=ip&amp;node=$node&amp;glamount=$glamount&amp;glunits=$glunits&amp;gsamount=$gsamount&amp;gsunits=$gsunits&amp;intf=$intf\">IP</a>
				<a class=\"b\" href=\"$this_script?file=$conf&amp;type=export&amp;graphtype=$graphtype&amp;node=$node&amp;start=$start_time&amp;end=$end_time&amp;intf=$intf&amp;item=$item\">Export</a>
				<a class=\"b\" href=\"$this_script?file=$conf&amp;type=stats&amp;graphtype=$graphtype&amp;node=$node&amp;start=$start_time&amp;end=$end_time&amp;intf=$intf&amp;item=$item\">Stats</a>
			</div>
		</th>
	</tr>
	<tr>
	<td colspan="4">
	<table class="plain" width="100%" summary="Display">
	<tr>
		<td class="menubar">Type</td>
		<td class="">&nbsp;$interfaceTable{$intf}{ifType}</td>
		<td class="menubar">Speed</td>
		<td class="">&nbsp;$speed</td>
	</tr>
	<tr>
		<td class="menubar">Last Updated</td>
		<td class="">&nbsp;$lastUpdate</td>
		<td class="menubar">Description</td>
		<td class="">&nbsp;$interfaceTable{$intf}{Description}</td>
	</tr>
	</table>
	</td>
	</tr>
	<tr>
		<td class="menubar" colspan="4">$heading</td>
	</tr>
EO_HTML
		if ( $graphtype =~ /cbqos/ and $CBQosActive eq "true") {
			# Classmap names
			print <<EO_HTML;
			<tr><td colspan="4"><table class="plain" width="100%" summary="Display">
			<tr>
			<td class="menubar">Policy name</td>
			<td class="">&nbsp;$CBQosNames[0]</td>
EO_HTML
#Jan,200406 popup menu added
			if ($#CBQosNames < 7) {
				# buttons
				print "<th class='menubar'><div>";
				for my $i (1..$#CBQosNames) {
				print <<EO_HTML;
					<a class="b" href="$this_script?file=$conf&amp;type=graph&amp;graphtype=$graphtype&amp;node=$node&amp;glamount=$glamount&amp;glunits=$glunits&amp;gsamount=$gsamount&amp;gsunits=$gsunits&amp;intf=$intf&amp;item=$CBQosNames[$i]">$CBQosNames[$i]</a>
EO_HTML
				}
			} else {
				#popup menu
				print <<EO_HTML;
				<td class="menubar">Select class name&nbsp;
				<select name="item" onChange=\"JavaScript:document.graph.submit()\">
            	<option value="$item">$item</option>
EO_HTML
				for my $i (1..$#CBQosNames) {
					print "<option value=\"$CBQosNames[$i]\">$CBQosNames[$i]</option>\n";
				}
				print "</select>\n";
			}

			print "</div></th></tr></table></tr>";
		}
# Jan,200406, end of form moved
	print <<EO_HTML;
	</form><tr>
		<th colspan="4">Clickable graphs: Left -> Back; Right -> Forward; Top Middle -> Zoom In; Bottom Middle-> Zoom Out, in time</th>
	</tr>
EO_HTML
	}

	# If the heading isn't blank then there must be a graph type for it.
	if ( $heading ne "" ) {
		### AS 11 Mar 2001 NEW Embedded graphics, none of this dump in a temp directory anymore
		### AS 3 Mar 2002 Nice clickable graphs now.
		$graphLink="$this_script?file=$conf&amp;type=drawgraph&amp;node=$node&amp;group=$group&amp;graph=$graphtype&amp;glamount=$glamount&amp;glunits=$glunits&amp;start=$start_time&amp;end=$end_time&amp;width=$width&amp;height=$height&amp;intf=$intf&amp;item=$item";
	}
	else {
	 	$graphLink="Other graph types not yet supported\n";
	}

	&graphImage($graphLink);

	### AS 2 June 2002 - Handy for debuging what the graph clicking is doing!
	#rowStart;
	#print "<th colspan=\"4\">graphx=$graphx graphy=$graphy node=$node lnode=$lnode datestamp_start=$datestamp_start datestamp_end=$datestamp_end intf=$intf ifDescr=$interfaceTable{$intf}{ifDescr} graph_factor=$NMIS::config{graph_factor} end_time=$end_time start_time=$start_time end=$end start=$start graphdate=$q->param('graphdate')</th>\n";
	#rowEnd;

	tableEnd;
	cellEnd;
	rowEnd;

	rowEnd;

	tableEnd;
	print "<!-- typeGraph end -->\n";
	pageEnd;

	sub graphHeading {
		$graphtype = shift;
		my $heading = "";

		my %type = ('util' => 		"$node Interface $interfaceTable{$intf}{ifDescr} Utilisation Including Availability",
					'autil' => 		"$node Interface $interfaceTable{$intf}{ifDescr} Utilisation Including Availability",
					'bits' => 		"$node Interface $interfaceTable{$intf}{ifDescr} Bits/Second Utilisation",
					'abits' => 		"$node Interface $interfaceTable{$intf}{ifDescr} Bits/Second Utilisation",
					'mbits' => 		"$node Interface $interfaceTable{$intf}{ifDescr} Max. Bits/Second Utilisation",
					'pkts' => 		"$node Interface Packets/Second Utilisation",
					'epkts' => 		"$node Interface Error packets in percentage",
					'cbqos' => 		"$node Class Based QoS",
					'cbqos-in' => 	"$node Class Based QoS for input",
					'cbqos-out' => 	"$node Class Based QoS for output",
					'calls' => 		"$node Call Port Stats",
					'health' => 	"$node Overall Reachability, Availability and Health",
					'metrics' => 	"$group Metrics",
					'response' =>	"$node Response Time in milliseconds",
					'cpu' =>		"$node CPU Utilisation",
					'modem' =>		"$node Modem Utilisation",
					'acpu' =>		"$node CPU Utilisation",
					'ip' =>			"$node IP Utilisation",
					'frag' =>		"$node IP Fragmentation/Reassembly (as a % of Packets Received)",
					'buffer' =>		"$node Buffer Utilisation",
					'mem-router' =>	"$node Router Memory Utilisation",
					'mem-switch' =>	"$node Switch Memory Utilisation",
					'mem-proc' =>	"$node Processor Memory Utilisation",
					'mem-io' =>		"$node IO Memory Utilisation",
					'mem-dram' =>	"$node DRAM Memory Utilisation",
					'mem-mbuf' =>	"$node mbuf Utilisation",
					'mem-cluster' => "$node cluster Memory Utilisation",
					'nmis' =>		"NMIS runtime",
					'traffic' =>	"$node System Traffic",
					'topo' =>		"$node Topology Changes",
					'pic-conn' =>	"$node Firewall Connections",
					'a3bandwidth' => "$node System Bandwidth",
					'a3traffic' =>	"$node System Traffic",
					'a3errors' =>	"$node System Errors",
					'degree' =>		"$node Server Temperature",
					'pvc' =>		"$node PVC Frame Relay Stats",
					'hrcpu' =>		"$node CPU Stats",
					'hrmem' =>		"$node Memory Stats",
					'hrvmem' =>		"$node Virtual Memory stats",
					'hrwincpu' =>	"$node CPU Utilisation",
					'hrwincpuint' => "$node CPU Interrupts",
					'hrwinmem' =>	"$node Memory Stats",
					'hrwinpps' =>	"$node Server Memory Pages per Sec",
					'hrwinproc' =>	"$node Number of Processes",
					'hrwinusers' => "$node Number of Users",
					'service' =>	"$node Service"
			);

		if ($graphtype =~ /hrsmpcpu/ ) { $heading = "$node CPU stats"; }
		elsif ( $graphtype =~ /hrdisk/ ) { $heading = "$node Disk stats"; }
		else { $heading = $type{$graphtype}; }

		return $heading;
	}

	sub graphImage {
    	my $graphLink = shift;
		print <<EO_HTML;
	<form action=\"$this_script\" method=\"get\">
	<tr>
		<th colspan=\"4\" width=\"600\"><input type=\"image\" name=\"graph\" src=\"$graphLink\"/></th>
		<input type=\"hidden\" name=\"file\" value=\"$conf\">
		<input type=\"hidden\" name=\"type\" value=\"graph\">
		<input type=\"hidden\" name=\"graphtype\" value=\"$graphtype\">
		<input type=\"hidden\" name=\"node\" value=\"$node\">
		<input type=\"hidden\" name=\"group\" value=\"$group\">
		<input type=\"hidden\" name=\"lnode\" value=\"$lnode\">
		<input type=\"hidden\" name=\"glamount\" value=\"$glamount\">
		<input type=\"hidden\" name=\"glunits\" value=\"$glunits\">
		<input type=\"hidden\" name=\"gsamount\" value=\"$gsamount\">
		<input type=\"hidden\" name=\"gsunits\" value=\"$gsunits\">
		<input type=\"hidden\" name=\"intf\" value=\"$intf\">
		<input type=\"hidden\" name=\"start\" value=\"$start_time\">
		<input type=\"hidden\" name=\"end\" value=\"$end_time\">
		<input type=\"hidden\" name=\"item\" value=\"$item"\">
	</tr>
	</form>
EO_HTML
	}

	sub graphMenu {
		print "<!-- graphMenu begin -->\n";
		my $checked;
		# THIS IS NOT XHTML COMPLIANT, NEED TO CHECK THE XHTML DTD
		if ( $q->param('graphdate') eq "true" ) { $checked = "checked"; }
		print <<EO_HTML;
<form name="graph" action="$this_script">
<input type="hidden" name="file" value="$conf">
<input type="hidden" name="lnode" value="$node">
<input type="hidden" name="group" value="$group">
<tr>
	<td colspan="4">
	<table class="plain" width="100%" summary="Display">
	<tr>
		<td class="menubar">Use Date <input type="checkbox" name="graphdate" value="true" $checked></td>
		<td class="menubar">Start <input type="text" name="date_start" size="20" value="$date_start"></td>
		<td class="menubar">End <input type="text" name="date_end" size="20" value="$date_end"></td>
	</tr>
	</table>
	</td>
</tr>
<tr>
	<td class="menubar">Length&nbsp;&nbsp;
 		<input type="text" name="glamount" size="1" value="$glamount">
 		<select name="glunits" SIZE="1">
 	            <option value="$glunits">$glunits</option>
 	            <option value=""></option>
 	            <option value="minutes">minutes</option>
 	            <option value="hours">hours</option>
 	            <option value="days">days</option>
 	            <option value="weeks">weeks</option>
 	            <option value="months">months</option>
 	            <option value="years">years</option>
		</select>
	</td>
	<td class="menubar">Node
		<select name="node" size="1" length="20" onChange=\"JavaScript:document.graph.submit()\">
            <option value="$node">$node</option>
EO_HTML
		#<input type="text" size="13" name="node" value="$node">
		foreach $node (sort { $NMIS::nodeTable{$a} <=> $NMIS::nodeTable{$b} } keys %NMIS::nodeTable)  {
			next unless $user->InGroup($NMIS::nodeTable{$node}{group}) ;
			if (exists $NMIS::nodeTable{$node}{slave} or exists $NMIS::nodeTable{$node}{slave2}) { next; }
			if ( $node ne "" ) {
				print "<option value=\"$node\">$node</option>\n";
			}
		}
		print <<EO_HTML;
		</select>
		</td>
		<td class="menubar">Type
		<select name="graphtype" size="1" onChange=\"JavaScript:document.graph.submit()\">
    	<option value="$graphtype">$graphtype</option>
EO_HTML
	# fill listbox with interface typedraw
	if ($intf ne "") {
		foreach my $opt ( split /,/ , substr($NMIS::systemTable{"typedraw$intf"},1) ) {
			print "<option value=\"$opt\">$opt</option>\n";
		}
	}
	# fill listbox with node typedraw
	foreach my $opt ( split /,/ , substr($NMIS::systemTable{typedraw},1) ) {
		print "<option value=\"$opt\">$opt</option>\n";
	}
	print <<EO_HTML;
    </select>
	</td>
	<input type="hidden" size="5" name="type" value="$type">
	<td class="grey"><input type="submit" value="GRAPH"></td>
	</tr>
	<tr>
	<td class="menubar">Starting&nbsp;
 		<input type="text" name="gsamount" size="1" value="$gsamount">
 		<select name="gsunits" SIZE="1">
 	            <option value="$gsunits">$gsunits</option>
 	            <option value=""></option>
 	            <option value="minutes">minutes</option>
 	            <option value="hours">hours</option>
 	            <option value="days">days</option>
 	            <option value="weeks">weeks</option>
 	            <option value="months">months</option>
 	            <option value="years">years</option>
		</select>
	</td>
EO_HTML

	if ( $graphtype eq "metrics" and $node eq "" ) {
		print <<EO_HTML;
		<td class="menubar">Group
		<select name="group" length="20" size="1">
            <option value="$group">$group</option>
            <option value="network">network</option>
EO_HTML
		foreach my $i (sort ( keys (%NMIS::groupTable) ) ) {
		next unless $user->InGroup($i) ;
			print "<option value=\"$i\">$NMIS::groupTable{$i}</option>\n";
		}
##Jan,200406		print "</select></td></form>\n";
		print "</select></td>\n";
		
	} else {
		print <<EO_HTML;
		<td class="menubar">Interface
		<select name="intf" length="20" size="1" onChange=\"JavaScript:document.graph.submit()\">
            <option value="$intf">$interfaceTable{$intf}{ifDescr}</option>
EO_HTML
		my %intfTable;
		foreach my $i (sort keys %interfaceTable) {
			if ( $interfaceTable{$i}{collect} eq "true" ) {
				$intfTable{$interfaceTable{$i}{ifDescr}} = $i;
			}
		}
		# now sort on description of interface
		foreach my $descr ( sort keys %intfTable) {
			print "<option value=\"$intfTable{$descr}\">$descr</option>\n";
		}

##Jan,200406		print "</select></td></form>\n";
		print "</select></td>\n";

		}
		print "<!-- graphMenu end -->\n";
	} # end graphMenu

} # end typeGraph

### display the reason no collect of the interface
### Cologne 2005
###
sub typeCollectMsg {	

	my $regex = "";
	my %sysintf;
	my $msg;

	my %interfaceTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-interface.dat","ifIndex","\t");

	if ( -r $NMIS::config{SysInt_Table} ) {
		%sysintf = &loadCSV("$NMIS::config{SysInt_Table}","$NMIS::config{SysInt_Key}","\t");
	}

	if ( $sysintf{$node."_".$intf}{Description} ) {
		$interfaceTable{$intf}{Description} = $sysintf{$node."_".$intf}{Description};
		$msg = " Description replaced by sysInterface table\n";
	}



	if ( $interfaceTable{$intf}{nocollect} eq "no_collect_ifDescr_gen" ) {
		$regex = $NMIS::config{'no_collect_ifDescr_gen'} ;
	} elsif ( $interfaceTable{$intf}{nocollect} eq "no_collect_ifDescr_atm" ) {
		$regex = $NMIS::config{'no_collect_ifDescr_atm'} ;
	} elsif ( $interfaceTable{$intf}{nocollect} eq "no_collect_ifDescr_voice" ) {
		$regex = $NMIS::config{'no_collect_ifDescr_voice'} ;
	} elsif ( $interfaceTable{$intf}{nocollect} eq "no_collect_ifType_gen" ) {
		$regex = $NMIS::config{'no_collect_ifType_gen'} ;
	} elsif ( $interfaceTable{$intf}{nocollect} eq "no_collect_ifAlias_gen" ) {
		$regex = $NMIS::config{'no_collect_ifAlias_gen'} ;
	}

	if ($regex ne "") {	$regex = "\n Configuration file $conf contains the regex\n\n $regex \n"; }

	print <<EO_HTML;
Content-type: text/html\n
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html>
<head>
</head>
<body><pre>

 This interface will not be collected of the next reason

 Node        = $node

 Interface   = $interfaceTable{$intf}{ifDescr}
  (ifDescr)
 Type        = $interfaceTable{$intf}{ifType}
  (ifType)
 Description = $interfaceTable{$intf}{Description}
  (ifAlias)
$msg
 Reason      = $interfaceTable{$intf}{nocollect}

$regex
</body></html>
EO_HTML
}

###
###
###
sub typeEvent {
	my $node = shift;
	my $match = "false";
	my $start;
	my $last;
	my $button;
	my $style;
	my $name;
	my %slaveTable;

	# verify access to this command/tool bar/button
	#
	if ( $auth->Require ) {
		# CheckAccess will throw up a web page and stop if access is not allowed
		$auth->CheckAccess($user, "eventcur") or die "Attempted unauthorized access";
	}

	my $dateStamp = NMIS::returnDateStamp;
    my @dateTime = split " ", $dateStamp;

	# some master slave stuff - send page headers etc if not master calling...

	pageStart("Event List","true",\%headeropts);

	if ($q->param('request') ne 'master' ) {
		cssTableStart;
	print start_Tr(),
		start_td;
	&do_dash_banner($auth->Require, $user->user);
	print end_td(),
		end_Tr;
		&nmisMenuSmall;
		&nmisMenuBar;
	}
	
	$datestamp = returnDateStamp;
    if ( $NMIS::config{master} eq 'true' ) { cssHeaderBar("Master Event List at $datestamp","grey") }
    elsif ( $NMIS::config{slave} eq 'true' ) { cssHeaderBar("$NMIS::config{nmis_host} Event List at $datestamp","grey") }
    else { cssHeaderBar("Event List at $datestamp","grey") }

	print "<!-- typeEvent begin -->\n";
	rowStart;
	cssCellStart("white",12);

	# only display the table if there are any events.
	if ( !$NMIS::eventCount ) {
		printHeadRow("No Events Current @ $datestamp","#FFFFFF");
		print Tr(td({class=>'white'}, &do_footer ));
	}
	else {
		&displayEvents;
	}

	if ( $match eq "false" and $NMIS::eventCount ) {
		printHeadRow("No Events Current for $node @ $datestamp","#FFFFFF");
	}
	cellEnd;
	rowEnd;

	print "<!-- typeEvent end -->\n";

	# now - if a master - display the slave events !!!
	if ( $NMIS::config{master} eq 'true' ) {
		use LWP 5.64; # Loads all important LWP classes, and makes sure your version is reasonably recent.
		%slaveTable = &loadCSV("$NMIS::config{Slave_Table}","$NMIS::config{Slave_Key}","\t");
		foreach $name ( keys %slaveTable ) {
		
			my $browser = LWP::UserAgent->new;
			my $url = "http://$name$this_script_full?file=nmis.conf&type=event&request=master&master=$NMIS::config{hostname}";
			my $response = $browser->get( $url );
			die "Can't get $url -- ", $response->status_line unless $response->is_success;

			die "I was expecting HTML, not ", $response->content_type
			unless $response->content_type eq 'text/html';
			
			print "<!-- typeSlaveEvent start -->\n";

			my $content = $response->content;
			$content =~ s/^.*?<body>//s;			# strip the header
			print "$content\n";
			
			print "<!-- typeSlaveEvent end -->\n";
		}
	}

	if ( $q->param('request') ne 'master' ) {
		tableEnd;
		pageEnd;
	}

	sub displayEvents {
		my $self = shift;
		my $event_hash;
		my $color;
		my $outage;
	 	my $tempnode;
		my $nodehash;
		my $tempnodeack; 
		my %eventackcount;
		my %eventnoackcount;
		my %eventcount;
		my $cleanedSysLocation;

		my $lat;
		my $long;
		my $alt;
		my $loc;
		my $pichi=474;
		my $picwi=950;
		my $nodehi=10;
		my $nodewi=10;
		my $longfac=$picwi/360; #pixels in a degree longitude
		my $latfac=$pichi/180; #pixels in a degree latitude
		my $gmtlat=$pichi/2; #pixel location of gmt latitude
		my $gmtlong=$picwi/2; #pixel location of gmt longitude

		my $display_ack = scalar(@event_ack) ? (join ",", @event_ack) : "false";
		my $display_level = statusNumber( $q->param('level') ? $q->param('level') : "Fatal" );
		my $display_group = scalar(@event_group) ? (join ",", @event_group) : "group_all" ;

		# rip thru the table once and count all the events by node....helps heaps later.
		foreach $event_hash ( keys %NMIS::eventTable )  {
			if ( $NMIS::eventTable{$event_hash}{ack} eq 'true' ) {
				$eventackcount{$NMIS::eventTable{$event_hash}{node}} +=1;
			}
			else {
				$eventnoackcount{$NMIS::eventTable{$event_hash}{node}} +=1;
			}
			$eventcount{$NMIS::eventTable{$event_hash}{node}} +=1;
		}
		# set some html menu size formatting options here
		my $num_group_seen = 1 + scalar keys %NMIS::groupTable;

		# only print the Geostyle map if dnsLoc or sysLoc in nmis.conf are on...
		if ( $NMIS::config{DNSLoc} eq "on" or $NMIS::config{sysLoc} eq "on" ) {

		# print background map
		print <<EO_HTML;
			<center>
			<p>
			<div style="position:relative; left:0; top:0; z-index:10; width:$picwi; height:$pichi">
			<img  border="0" src="$NMIS::config{'<url_base>'}/worldmap.gif">
EO_HTML

			# cycle through the table and display the events on the map
			foreach $event_hash ( keys %NMIS::eventTable )  {
				next unless $user->InGroup($NMIS::nodeTable{$NMIS::eventTable{$event_hash}{node}}{group}) ;
				# Only display valid nodes! typeEvent could have been called with a specific node, else $node eq ""
				if ( $node eq "" or $node eq $NMIS::eventTable{$event_hash}{node} ) {
					
					loadSystemFile($NMIS::eventTable{$event_hash}{node});
					my $level = statusNumber($NMIS::eventTable{$event_hash}{event_level});

					if ( grep(m/$NMIS::eventTable{$event_hash}{ack}/,@event_ack) and 
						($display_group eq "group_all" or grep(m/$NMIS::systemTable{nodeGroup}/, @event_group) ) and
						$level <= $display_level 
					) {
						$cleanedSysLocation = $NMIS::systemTable{sysLocation};
                                         	if (($NMIS::systemTable{DNSloc} ne "unknown" or $NMIS::systemTable{DNSloc} ne "") and $NMIS::config{DNSLoc} eq "on") { # Node has a DNS LOC Record
                                                ( $lat, $long, $alt) = split(',',$NMIS::systemTable{DNSloc});
                                                } 
                                                if (($NMIS::systemTable{sysLocation}  =~/$NMIS::config{sysLoc_format}/ ) and $NMIS::config{sysLoc} eq "on" ) {  # Node has sysLocation that is formatted for Geo Data
                                                ( $lat, $long, $alt, $cleanedSysLocation) = split(',',$NMIS::systemTable{sysLocation});
                                                } 
						if ($lat ne  "" ) { # Got Geo Data from sysLocation or DNS LOC Record

							# if the nodename is an ip address, use the sysName field name
							if ( $NMIS::eventTable{$event_hash}{node} =~ /\d+\.\d+\.\d+\.\d+/ ) {
								if ( $NMIS::systemTable{sysName} ne "" ) {
									$loc = $NMIS::systemTable{sysName};
								}
							}
							else { 
								$loc = $NMIS::eventTable{$event_hash}{node};
							}
							print "\t\t\t<a href=\"$NMIS::config{logs}?log=Event_Log&amp;search=$NMIS::eventTable{$event_hash}{node}&amp;sort=descending\">";
							print "<img border=\"0\" src=\"$NMIS::config{'<url_base>'}/node$level.gif\" alt=\"$loc - $eventcount{$NMIS::eventTable{$event_hash}{node}} Event(s)\" style=\"position:absolute; left:";
							print int($gmtlong + ($long*$longfac)-($nodewi/2));
							print "px; top:";
							print int($gmtlat - ($lat*$latfac)-($nodehi/2));
							$level=100-$level+10;	# set the z-index so most severe alarm on top
							print "px; z-index:$level; width:$nodewi; height:$nodehi;\"></a>\n";
						}
					}
				}
			} # foreach $event_hash
			print <<EO_HTML;
			</div>
			</p></center>
EO_HTML

		# print a short menu of options to control whats on the map
		my $boxsize = $num_group_seen -1;
		print <<EO_HTML;
			<form name=formula action=\"$this_script\" method=get>
    	                <input type="hidden" name="file" value="$conf">
                        <input type="hidden" name="type" value="event">
   			<p>Display  
			<select size="5" name="level">
			<option
EO_HTML
			if ($q->param('level') eq "Warning") {print "selected ";}
			print "value=\"Warning\">Warning</option>\n<option ";
			if ($q->param('level') eq "Minor") {print "selected ";}
			print "value=\"Minor\">Minor</option>\n<option ";
			if ($q->param('level') eq "Major") {print "selected ";}
			print "value=\"Major\">Major</option>\n<option ";
			if ($q->param('level') eq "Critical") {print "selected ";}
			print "value=\"Critical\">Critical</option>\n<option ";
			if ($q->param('level') eq "Fatal") {print "selected ";}
			print "value=\"Fatal\">Fatal</option>\n";
			print <<EO_HTML;
			</select>
			Events, for Nodes in  
			<select size="$boxsize" multiple="true" name="event_group">
EO_HTML

		foreach my $tmpgroup ( sort keys %NMIS::groupTable ) {
			print "<option ";
			if (grep(m/$tmpgroup/,@event_group)) {print "selected ";} # Remember user selection to make them happy
			print " value=\"$tmpgroup\">$tmpgroup</option>";
		}
		print <<EO_HTML;
			</select>
			group(s), for Events that are  
			<select size="2" multiple="true" name="event_ack">
			<option 
EO_HTML
		if (grep(m/true/,@event_ack)) {print "selected ";} # Remember user selection to make them happy 
		print <<EO_HTML;
			value="true">InActive</option>
			<option 
EO_HTML
		if (grep(m/false/,@event_ack)) {print "selected ";} # Remember user selection to make them happy
                print <<EO_HTML;
			value="false">Active</option>
			</select>
			<input type="submit" value="Go!"></p>
			</form>
EO_HTML


		} # end of Geostyle map print based on dnsLoc or sysLoc being on


		# setup the java for the events display
		print <<EO_HTML;
		<script language=javascript>	
	
		/* Modified by Aaron Monfils (12/30/04) - document.all is a Microsoft IE-ism and not support on other browsers */
		function ExpandCollapse(bucket) {
		   var bucket_id = bucket;
		   var summary = bucket + "summary";
		   var img_src = bucket + "img";
		   var bucket_elem_id = document.getElementById(bucket);
		   var summary_elem_id = document.getElementById(summary);
		   var img_src_elem_id = document.getElementById(img_src);

		   innerTextvar = bucket_id.innerText;
			/*
		   alertText = "bucket=" + bucket_id + " bucket_elem_id=" +	bucket_elem_id + "\\n";
		   alertText = alertText + "summary=" + summary + " summary_elem_id = "	+ summary_elem_id + "\\n";
		   alertText = alertText + "img_src=" + img_src + " img_src_elem_id = "	+ img_src_elem_id;
		   alert (alertText);
		   */

		   if (summary_elem_id.style.display != "block") {
		      summary_elem_id.style.display = "block";
		      img_src_elem_id.src = "$NMIS::config{'<url_base>'}/sumup.gif";
		      img_src_elem_id.alt = "Hide Summary";
		      bucket_elem_id.title = "Hide Summary";
		   } else {
		      summary_elem_id.style.display = "none";
		      img_src_elem_id.src = "$NMIS::config{'<url_base>'}/sumdown.gif";
		      img_src_elem_id.alt = "Show Summary";
		      bucket_elem_id.title = "Show Summary";
		   }

		   /* the old code
		   if (document.all[summary].style.display != "block") {
		      document.all[summary].style.display = "block";
		      document.all[img_src].src = "$NMIS::config{'<url_base>'}/sumup.gif";
		      document.all[img_src].alt = "Hide Summary";
		      document.all[bucket].title = "Hide Summary";
		   } else {
		      document.all[summary].style.display = "none";
		      document.all[img_src].src = "$NMIS::config{'<url_base>'}/sumdown.gif";
		      document.all[img_src].alt = "Show Summary";
		      document.all[bucket].title = "Show Summary";
		   }
		   */
		}
		function checkBoxes(checkbox,name) {
			state = checkbox.checked;
			formcount = document.forms.length;
			for (j=0;j<formcount;j++)
				{
				elementcount = document.forms[j].elements.length;
				for (i=0;i<elementcount;i++)
					{
					if (document.forms[j].elements[i].name.substring(0,name.length)==name)
					document.forms[j].elements[i].checked = state; 
				}
			}
		}
		</script>
		<style>
		a.clsHeadline {
	          color: black;
	          cursor: hand;
	          font: 9pt arial, sans-serif;
	          text-decoration: none;
	     }
	     a.clsHeadline img {
	          margin-right:3px;
	          margin-left:3px;
	     }
	     a.clsHeadline:hover {
	          color: maroon; 
	          text-decoration: none;
	     }
	     .clsSummary td {
	          padding-left: 21px;
	          font: 10px arial, sans-serif;
	          color: black;
	     }     
	     </style>
EO_HTML
		# end of java init


		# always print the active event table header
		$tempnode='empty';
		$tempnodeack = 'false';

		# read toolset
		if (!$tb) {
			$tb = NMIS::Toolbar::new;
			$tb->SetLevel($user->privlevel);
			$tb->LoadButtons($NMIS::config{'<nmis_conf>'}."/toolset.csv");
		}
		# as this could be called remotely by the master, make sure the submit button come back to us.
		# that mean fq the submit action to us.
		my $event_cnt = 0; # index for update routine eventAck()
		print <<EO_HTML;
		<form action="http://$NMIS::config{nmis_host}$this_script_full?file=$conf&amp;type=event" method="post"><HR>Active Events. (Set All Events Inactive<input type="checkbox" onClick="checkBoxes(this,'$tempnodeack')">)<HR>
EO_HTML

		foreach $event_hash ( sort {
			$NMIS::eventTable{$a}{ack} cmp  $NMIS::eventTable{$b}{ack} or
			$NMIS::eventTable{$a}{node} cmp $NMIS::eventTable{$b}{node} or
			$NMIS::eventTable{$b}{startdate} cmp $NMIS::eventTable{$a}{startdate} or
			$NMIS::eventTable{$a}{escalate} cmp $NMIS::eventTable{$b}{escalate}
		} keys %NMIS::eventTable )  {
			next unless $user->InGroup($NMIS::nodeTable{$NMIS::eventTable{$event_hash}{node}}{group});
			# only display real master events here.
			if ( $NMIS::config{master} eq 'true' and $NMIS::nodeTable{$NMIS::eventTable{$event_hash}{node}}{slave} ) { next; }

			# Only display valid nodes!!!!!
			if ( $node eq "" or $node eq $NMIS::eventTable{$event_hash}{node} ) {
				if ( $match eq "false" ) { $match = "true"; } # used for displaying summary line at end.

				# print all events

				if ( $tempnode ne $NMIS::eventTable{$event_hash}{node} ) {
					if ( $tempnode ne "empty" ) {
						tableEnd;
						print "</div>";
					}
					$tempnode = $NMIS::eventTable{$event_hash}{node};

					# has the ack changed from true to false as well ?
					# drop in the inactive header if so.
					if ($tempnodeack ne $NMIS::eventTable{$event_hash}{ack}) { # should be when ack changes from false to true
						$tempnodeack = $NMIS::eventTable{$event_hash}{ack};
						print <<EO_HTML;
						<HR>Inactive Events. (Set All Events Active <input type="checkbox" onClick="checkBoxes(this,'$tempnodeack')">)<HR>
EO_HTML
					}
					active() if $NMIS::eventTable{$event_hash}{ack} eq 'false';
					inactive() if $NMIS::eventTable{$event_hash}{ack} eq 'true';
					cssTableStart("white");
				}

				# or - drop in the inactive events header when the ack type changes, and no node change
				elsif ($tempnodeack ne $NMIS::eventTable{$event_hash}{ack}) { # should be when ack changes from false to true
					$tempnodeack = $NMIS::eventTable{$event_hash}{ack};
					tableEnd;
					print "</div>";
					print <<EO_HTML;
						<HR>Inactive Events. (Set All Events Active <input type="checkbox" onClick="checkBoxes(this,'$tempnodeack')">)<HR>
EO_HTML

					active() if $NMIS::eventTable{$event_hash}{ack} eq 'false';
					inactive() if $NMIS::eventTable{$event_hash}{ack} eq 'true';
					cssTableStart("white");
				}

				# now write the events, hidden or not hidden based on the last <div> style
				if ( $NMIS::eventTable{$event_hash}{ack} eq "false" ) {
					$color = eventColor($NMIS::eventTable{$event_hash}{event_level});
					$style = "";
				}
				else {
					$color = "white";
					$style = "small";
				}
				$start = returnDateStamp($NMIS::eventTable{$event_hash}{startdate});
				$last = returnDateStamp($NMIS::eventTable{$event_hash}{lastchange});
				# User logic, hmmmm how will users interpret this!
				if ( $NMIS::eventTable{$event_hash}{ack} eq "false" ) {
					$button = "true";
					$outage = convertSecsHours(time - $NMIS::eventTable{$event_hash}{startdate});
				}
				else {
					$button = "false";	
					$outage = convertSecsHours($NMIS::eventTable{$event_hash}{lastchange} - $NMIS::eventTable{$event_hash}{startdate});
				}

				print "<tr><td class=\"$style\" bgcolor=\"$color\">";
				print $auth->CheckAccess($user,"eventlog","check") ? "<a href=\"$NMIS::config{logs}?log=Event_Log&amp;search=$NMIS::eventTable{$event_hash}{node}&amp;sort=descending\">$NMIS::eventTable{$event_hash}{node}</a></td>" : "$NMIS::eventTable{$event_hash}{node}</td>";
				print <<EO_HTML;
				<td class="small" bgcolor="$color">$outage hh:mm:ss</td>
				<td class="small" bgcolor="$color">$start</td>
				<td class="small" bgcolor="$color">$last</td>
				<td class="$style" bgcolor="$color">$NMIS::eventTable{$event_hash}{event}</td>
				<td class="$style" bgcolor="$color">$NMIS::eventTable{$event_hash}{event_level}</td>
				<td class="$style" bgcolor="$color">$NMIS::eventTable{$event_hash}{details}</td>
				<td class="$style" bgcolor="$color" align="center">
				<input type="hidden" name="node" value="$NMIS::eventTable{$event_hash}{node}">
				<input type="hidden" name="event" value="$NMIS::eventTable{$event_hash}{event}">
				<input type="hidden" name="details" value="$NMIS::eventTable{$event_hash}{details}">
				<input type="hidden" name="ack" value="$button">
				<input type="checkbox" name="$NMIS::eventTable{$event_hash}{ack}$tempnode" value="$event_cnt">
				</td>
				<td class="$style" bgcolor="$color" align="center">$NMIS::eventTable{$event_hash}{escalate}</td>
				</tr>
EO_HTML
				$event_cnt++;
			}
		} # foreach $event_hash

		tableEnd;
		print "</div>\n<HR>\n";
		print "<input type=\"hidden\" name=\"type\" value=\"mack\">\n";
		if ( $q->param('request') eq 'master' ) {
			print "<input type=\"hidden\" name=\"request\" value=\"masterupdate\">\n";
		}
		print "<input type=\"submit\" value='Submit Changes' style=\"float: right\" >\n";
		print "</form>\n";

		# java - ack=false event=active
		sub active {
			print <<EO_HTML;
				<div class="clsShowHide">
				<a onclick='javascript:ExpandCollapse("false$tempnode")'
				id="false$tempnode" CLASS="clsHeadline" TITLE="Hide Summary">
				$tempnode <img src=$NMIS::config{'<url_base>'}/sumup.gif
				id="false${tempnode}img" border=0 alt="Hide Summary"></a>
				&nbsp;$eventnoackcount{$tempnode} Event(s)
EO_HTML
			# print buttons
			$tb->{_vars} = { node => $tempnode };
			print $tb->DisplayButtons("tool",['ping','trace','mtr','lft','telnet']);
			print <<EO_HTML;
				&nbsp;(Set Events Inactive for $tempnode<input type="checkbox" onClick="checkBoxes(this,'$tempnodeack$tempnode')">)
				</div>
	        	<div class="clsSummary" id="false${tempnode}summary" style="display:block;">
EO_HTML
		} # sub active

		# java - ack=true event=inactive
		sub inactive {
			print <<EO_HTML; 
			<div class="clsShowHide">
				<a onclick='javascript:ExpandCollapse("true$tempnode")'
				id="true$tempnode" CLASS="clsHeadline" TITLE="Show Summary">
				$tempnode <img src=$NMIS::config{'<url_base>'}/sumdown.gif
				id="true${tempnode}img" border=0 alt="Show Summary"></a>
				&nbsp;$eventackcount{$tempnode} Event(s)
EO_HTML
			# print buttons
			$tb->{_vars} = { node => $tempnode };
			print $tb->DisplayButtons("tool",['ping','trace','mtr','lft','telnet']);
			print <<EO_HTML;
				&nbsp;(Set Events Active for $tempnode<input type="checkbox" onClick="checkBoxes(this,'$tempnodeack$tempnode')">)
				</div>
	        	<div class="clsSummary" id="true${tempnode}summary" style="display:none;">
EO_HTML

		} # sub inactive
	} # sub displayEvents
} # sub typeEvent	

# change ack from Event
sub ackEvent {

	my @par = $q->param(); # parameter names
	my @nm = $q->param('node'); # node names
	my @dtls = $q->param('details'); # event details
	my @ack = $q->param('ack'); # event ack status
	my @evnt = $q->param('event'); # event type
	my @evnt_cnt;
	# the value of the checkbox is equal to the index of arrays
	for my $boxnm (@par) { push @evnt_cnt,$q->param($boxnm) if $boxnm =~ /false|true/; } # false|true is part of the checkbox name
	for my $i ( 0..$#nm) {
		if ( grep $_ == $i , @evnt_cnt ) {
			&eventAck(ack=>$ack[$i],node=>$nm[$i],event=>$evnt[$i],details=>$dtls[$i],ackuser=>$user->user);
		}
	}
	# if we are a slave, and this came from the master, then update the events and go back to the master
	if ( $q->param('request') eq 'masterupdate' and $NMIS::config{slave} eq 'true' ) {
		# make sure redirect goes back to right caller, there could be more than one master...
		# master would have called us using LWP
		print "Location: http://$ENV{REMOTE_ADDR}/cgi-nmis/nmiscgi.pl?file=nmis.conf&type=event\n\n";
	} 
	else {
		&typeEvent();
	}
}

sub typeInfo {

	my $port;
	my $reportStats;
	my @tmparray;
	my $ifLastChange;
	my $tmpurl;
	my %interfaceTable;
	my $int_desc;
	my %servicesTable;
	my %util;
	my $collectmsg;

	# verify access to this command/tool bar/button
	#
	if ( $auth->Require ) {
		# CheckAccess will throw up a web page and stop if access is not allowed
		# $auth->CheckAccess($user, "") or die "Attempted unauthorized access";
	}

	#if ( ! defined $sort1 ) { $sort1 = "totalUtil" }
	#if ( ! defined $sort2 ) { $sort2 = "intString" }
	if ( ! defined $sort1 ) { $sort1 = "totalUtil" }
	if ( ! defined $sort2 ) { $sort2 = "Description" }

	pageStart("Information about $node","true",\%headeropts);
	cssTableStart;
	print start_Tr(),
		start_td;
	&do_dash_banner($auth->Require, $user->user);
	print end_td(),
		end_Tr;
	&nmisMenuSmall;
	$NMIS::userMenu && &nmisMenuBar;
	$datestamp = returnDateStamp;
	print comment("Start typeInfo, node=$node, group=$group, at date=$datestamp");
#    cssHeaderBar("Information for $node at $datestamp","grey");
	# Compare the Up time to the last uptime? and check if unhealthy?

	# Get the System info from the file and whack it into the hash
	loadSystemFile($node);
	if ( ! $user->InGroup($NMIS::nodeTable{$node}{group}) ) {
		cssHeaderBar("Not authorized to view node '$node' in group '$NMIS::nodeTable{$node}{group}'.", "grey");
		goto END;
	}

	cssHeaderBar("Information for $node at $datestamp","grey");
	if ( $NMIS::nodeTable{$node}{collect} eq "true" ) {
		### update the dynamic CAM to IP table if requested from the user interface.
		if ( $NMIS::systemTable{nodeModel} =~ /Catalyst/i and $q->param('run') eq "runcam" ) { &runCAM($node, 'true') }
		%interfaceTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-interface.dat","ifIndex","\t");
	}

	$NMIS::userMenu && displaySystemHeader($node);

	# all nodes get basic health - reachability and response time charts
	print <<EO_HTML;
 <tr>
	<td class="white">
     <table class="white" summary="Display">
		<tr>
			<td class="white" align="center" colspan="11">
				<a href="$this_script?file=$conf&amp;type=graph&amp;graphtype=health&amp;glamount=$glamount&amp;glunits=$glunits&amp;node=$node"
				  target="ViewWindow" onMouseOver="window.status='Drill in to Device Health.';return true" onClick="viewdoc('$tmpurl',$win_width,$win_height)">
				  <img border="0" alt="Device Health" src="$this_script?file=$conf&amp;type=drawgraph&amp;node=$node&amp;graph=health&amp;glamount=$glamount&amp;glunits=$glunits&amp;start=0&amp;end=0&amp;width=500&amp;height=100">
				</a>
			</td>
		</tr>
		<tr>
			<td class="white" align="center" colspan="11">
				<a href="$this_script?file=$conf&amp;type=graph&amp;graphtype=response&amp;glamount=$glamount&amp;glunits=$glunits&amp;node=$node"
				  target="ViewWindow" onMouseOver="window.status='Drill in to Device Response Time.';return true" onClick="viewdoc('$tmpurl',$win_width,$win_height)">
				  <img border="0" alt="Device Response Time" src="$this_script?file=$conf&amp;type=drawgraph&amp;node=$node&amp;graph=response&amp;glamount=$glamount&amp;glunits=$glunits&amp;start=0&amp;end=0&amp;width=500&amp;height=100">
				</a>
			</td>
		</tr>
	</table>
EO_HTML

    print "<table class=\"white\" summary=\"Display\">";

	if ( $NMIS::nodeTable{$node}{collect} eq "true" and $NMIS::nodeTable{$node}{active} ne "false" ) {
		if ( $NMIS::systemTable{nodeModel} =~ /router|atm|catalyst|PIX|FreeBSD|SunSolaris|generic|MIB2|Windows|Accelar|BayStack|SSII 3Com|Redback|FoundrySwitch|Riverstone/i ) {
			# Extract the interface statics and summaries for display in a second.
			foreach $intf (keys %interfaceTable ) {
				#if ( $interfaceTable{$intf}{ifDescr} ne "" ) {
					# Set the standard interface name
		 			$tmpifDescr = convertIfName($interfaceTable{$intf}{ifDescr});

					# Don't do any stats cause the interface is not one we collect
					if ( $interfaceTable{$intf}{collect} ne "true" ) {
						$operAvailability = "N/A";
						$totalUtil = "-1";
						$adminCellColor="#ffffff";
						$availCellColor="#ffffff";
						$totalCellColor="#ffffff";
						$intString="$interfaceTable{$intf}{ifDescr}";

						$tmpurl = "$this_script?file=$conf&amp;node=$node&amp;type=collectmsg&amp;intf=$intf";
						$collectmsg="<a href=\"$tmpurl\" target=msgWindow \" onClick=\"viewmsg('$tmpurl',600,350)\">false</a>";

						if ( $interfaceTable{$intf}{ifOperStatus} eq "other" ) { $operCellColor="#ffff00"; }
						elsif ( $interfaceTable{$intf}{ifOperStatus} eq "ok" ) { $operCellColor="#00ff00"; }
						else { 	$operCellColor="#ffffff"; }

						$ifLastChange = $interfaceTable{$intf}{ifLastChange};
						$ifLastChange =~ s/(.*)days.*/$1/;
						if ( $ifLastChange >= 35 and $interfaceTable{$intf}{ifOperStatus} eq "other" ) { $lastCellColor = "#999900"; }
						elsif ( $ifLastChange >= 5 and $interfaceTable{$intf}{ifOperStatus} eq "other" ) { $lastCellColor = "#ffff00"; }
						else { $lastCellColor = "#ffffff"; }
					}
					else {
						# Reset the number!!!
						$operAvailability = 0;
						$totalUtil = 0;
						$collectmsg = "true";

						# Set the cell color to reflect the interface status
						# so if admin = down then oper irrelevent
						if ( 	( $interfaceTable{$intf}{ifAdminStatus} eq "down" ) ||
							( $interfaceTable{$intf}{ifAdminStatus} eq "testing" ) ||
							( $interfaceTable{$intf}{ifAdminStatus} eq "null" )
						) {
							$adminCellColor="#ffffff";
							$operCellColor="#ffffff";
							$operAvailability = "N/A";
							$availCellColor="#ffffff";
							$totalUtil = "N/A";
							$totalCellColor="#ffffff";
							$lastCellColor = "#ffffff";
							$intString="$interfaceTable{$intf}{ifDescr}";
						}
						# it is supposed to be up what the heck is going on!!!!
						# Set the opercolor to reflect the real status, according to the average.
						else {
							#$intString="<a href=\"$this_script?file=$conf&amp;node=$node&amp;type=interface#$interfaceTable{$intf}{ifDescr}\">$interfaceTable{$intf}{ifDescr}</a>";
							$tmpurl = "$this_script?file=$conf&amp;node=$node&amp;type=graph&amp;graphtype=$NMIS::config{portstats}&amp;glamount=$glamount&amp;glunits=$glunits&amp;intf=$intf";
							$intString="<a href=\"$tmpurl\" target=ViewWindow onMouseOver=\"window.status='Drill into $interfaceTable{$intf}{ifDescr}.';return true\" onClick=\"viewdoc('$tmpurl',$win_width,$win_height)\">$interfaceTable{$intf}{ifDescr}</a>";

							if ( $interfaceTable{$intf}{collect} eq "false" ) {
								$tmpurl = "$this_script?file=$conf&amp;node=$node&amp;type=message&amp;intf=$intf";
								$collectmsg="<a href=\"$tmpurl\" target=msgWindow \" onClick=\"viewdoc('$tmpurl',300,300)\">false</a>";
							} else { $collectmsg = "true"; }

							$adminCellColor="#00ff00";

							# need to add interface details if set in config switch
							### AS 17 Mar 02 - Request James Norris, Optionally include interface description in messages.
							if ( defined $interfaceTable{$intf}{Description}
								and $interfaceTable{$intf}{Description} ne "null"
								and $NMIS::config{send_description} eq "true"
							) {
								$int_desc = " description=$interfaceTable{$intf}{Description}";
							}

							my $event_status = eventExist($node,"Interface Down","interface=$interfaceTable{$intf}{ifDescr}$int_desc");
							if (	( $event_status eq "true" ) &&
								( $interfaceTable{$intf}{ifOperStatus} =~ /up|ok/ )
							) {
								# Red for down
								$operCellColor = "#ff0000";
								$interfaceTable{$intf}{ifOperStatus} = "down";
							}
							elsif (	( $event_status eq "false" ) &&
								( $interfaceTable{$intf}{ifOperStatus} =~ /up|ok/ )
							) {
								# Green for up
								$operCellColor = "#00ff00";
								$interfaceTable{$intf}{ifOperStatus} = "up";
							}
							elsif ( $interfaceTable{$intf}{ifOperStatus} eq "down" ) {
								# Red for down
								$operCellColor = "#ff0000";
							}
							elsif ( $interfaceTable{$intf}{ifOperStatus} eq "dormant" ) {
								# Red for down
								$operCellColor = "#ffff00";
							}
							else { $operCellColor = "#ffffff"; }

							$lastCellColor = "#ffffff";

							# Get the link availability from the local node!!!
				    		%util = summaryStats(node => $node,type => "util",start => "-6 hours",end => time,ifDescr => $interfaceTable{$intf}{ifDescr},speed => $interfaceTable{$intf}{ifSpeed});
							$operAvailability = $util{availability};
							$totalUtil = $util{totalUtil};

							$availCellColor = colorHighGood($util{availability});
							$totalCellColor = colorLowGood($util{totalUtil});

							if ( $interfaceTable{$intf}{ifOperStatus} eq "dormant" )  {
								$operAvailability = "N/A" ;
								$availCellColor = "#FFFFFF";
								$operCellColor = "#ffff00";
							}

						}  # ELSE
					} # if interface is loop contr etc.

					if ( $interfaceTable{$intf}{ifDescr} ne "null" ) {
						$interfaceTable{$intf}{ifDescr}=$interfaceTable{$intf}{ifDescr};
						$interfaceTable{$intf}{totalUtil}=$totalUtil;
						$interfaceTable{$intf}{operAvailability}=$operAvailability;
						$interfaceTable{$intf}{totalCellColor}=$totalCellColor;
						$interfaceTable{$intf}{availCellColor}=$availCellColor;
						$interfaceTable{$intf}{operCellColor}=$operCellColor;
						$interfaceTable{$intf}{lastCellColor}=$lastCellColor;
						$interfaceTable{$intf}{adminCellColor}=$adminCellColor;
						$interfaceTable{$intf}{intString}=$intString;
						$interfaceTable{$intf}{collectmsg}=$collectmsg;
					}
				#}
			} # FOR LOOP

			if ( $NMIS::systemTable{nodeModel} =~ /router|atm|generic|MIB2|PIX|FreeBSD|SunSolaris|Windows|Accelar|BayStack|SSII 3Com|Redback/i ) {
				cssPrintHeadRow("Interface Table","menubar",11);
				$tmpurl = "file=&amp;node=&amp;type=graph&amp;graphtype=$NMIS::config{portstats}&amp;glamount=$glamount&amp;glunits=$glunits&amp;intf=$intf";
				print "			<tr>";
				print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=ifDescr&amp;sort2=$sort1\">Name</a></td>";
				print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=ipAdEntAddr&amp;sort2=$sort1\">IP</a></td>";
				print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=Description&amp;sort2=$sort1\">Description</a></td>";
				print "<td class=\"menubar\">Admin Status</td>";
				print "<td class=\"menubar\">Oper Status</td>";
				print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=operAvailability&amp;sort2=$sort1\">Int. Avail.</a></td>";
				print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=totalUtil&amp;sort2=$sort1\">Util. 6hrs</a></td>";
				print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=collect&amp;sort2=$sort1\">Collect</a></td>";
				print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=ifType&amp;sort2=$sort1\">Type</a></td>";
				print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=ifSpeed&amp;sort2=$sort1\">Speed</a></td>";
				print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=ifIndex&amp;sort2=$sort1\">ifIndex</a></td>";
				print "</tr>\n";

				# So now I have a hash of interface utilsation!!!!
				# New sort method, create a hash of keys data = $intf which are 
				# what to sort on, then alpha sort the keys and map the $intf 
				# back to the data.
				foreach $intf ( sort sort2 ( keys %interfaceTable ) ) {
					# controls whether or not we see non collected interfaces
					if ( ( $NMIS::config{show_non_collected_interfaces} eq "true"
							and $interfaceTable{$intf}{ifDescr} ne ""
						)
						or
						( 	$NMIS::config{show_non_collected_interfaces} eq "false"
							and $interfaceTable{$intf}{collect} ne "false"
							and $interfaceTable{$intf}{ifDescr} ne ""
						)
					) {
						$interfaceTable{$intf}{ifSpeed} = convertIfSpeed($interfaceTable{$intf}{ifSpeed});

						if ( $interfaceTable{$intf}{totalUtil} == -1 ) { $interfaceTable{$intf}{totalUtil} = "N/A"; }

						rowStart;
						printCell("$interfaceTable{$intf}{intString}");
						if ( $interfaceTable{$intf}{ipAdEntAddr} ne "" and $interfaceTable{$intf}{ipAdEntNetMask} ne "" ) {
							printCell("$interfaceTable{$intf}{ipAdEntAddr}<br>$interfaceTable{$intf}{ipAdEntNetMask}<br><a href=\"$this_script?file=$conf&amp;type=find&amp;find=$interfaceTable{$intf}{ipSubnet}\">$interfaceTable{$intf}{ipSubnet}</a>");
						}
						elsif ( $interfaceTable{$intf}{ipAdEntAddr} ne "" ) {
							printCell("$interfaceTable{$intf}{ipAdEntAddr}");
						}
						else {
							printCell("");
						}
						printCell("<a href=\"$this_script?file=$conf&amp;type=find&amp;find=$interfaceTable{$intf}{Description}\">$interfaceTable{$intf}{Description}</a>");
						printCell("$interfaceTable{$intf}{ifAdminStatus}",$interfaceTable{$intf}{adminCellColor},1,"center");
						printCell("$interfaceTable{$intf}{ifOperStatus}",$interfaceTable{$intf}{operCellColor},1,"center");
						printCell("$interfaceTable{$intf}{operAvailability}",$interfaceTable{$intf}{availCellColor},1,"center");
						printCell("$interfaceTable{$intf}{totalUtil}",$interfaceTable{$intf}{totalCellColor},1,"center");
###	Cologne				printCell("$interfaceTable{$intf}{collect}","#FFFFFF",1,"center");
						printCell("$interfaceTable{$intf}{collectmsg}");
						printCell("$interfaceTable{$intf}{ifType}");
						printCell("$interfaceTable{$intf}{ifSpeed}","#FFFFFF",1,"center");
						printCell("$interfaceTable{$intf}{ifIndex} -> $intf","#FFFFFF",1,"center");
						rowEnd;
					}
				} # foreach loop
			}
			elsif ( $NMIS::systemTable{nodeModel} =~ /Catalyst|FoundrySwitch|Riverstone/i ) {

				cssPrintHeadRow("Interface Table","menubar",16);
				$tmpurl = "file=&amp;node=&amp;type=graph&amp;graphtype=$NMIS::config{portstats}&amp;glamount=$glamount&amp;glunits=$glunits&amp;intf=$intf";
				print "			<tr>";
				print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=ifDescr&amp;sort2=$sort1\">Name</a></td>";
				print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=ipAdEntAddr&amp;sort2=$sort1\">IP</a><br>
					<a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;run=runcam&amp;\"> Click here to update connected IP list</a></td>";
				print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=Description&amp;sort2=$sort1\">Description</a></td>";
				print "<td class=\"menubar\">Admin Status</td>";
				print "<td class=\"menubar\">Oper Status</td>";
				print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=operAvailability&amp;sort2=$sort1\">Int. Avail.</a></td>";
				print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=totalUtil&amp;sort2=$sort1\">Util. 6hrs</a></td>";
				print "<td class=\"menubar\">Collect</td>";
				print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=ifType&amp;sort2=$sort1\">Type</a></td>";
				print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=ifSpeed&amp;sort2=$sort1\">Speed</a></td>";
				print "<td class=\"menubar\">Admin Speed</td>";
				print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=ifIndex&amp;sort2=$sort1\">ifIndex</a></td>";
				print "<td class=\"menubar\">Last Change</td>";
				print "<td class=\"menubar\">Duplex</td>";
				print "<td class=\"menubar\">PortFast</td>";
				print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=vlanPortVlan&amp;sort2=$sort1\">Vlan</a></td>";
				print "</tr>\n";

				# So now I have a hash of interface utilsation!!!!
				foreach $intf ( sort sort2 ( keys %interfaceTable ) ) {
					if (  	( 	$NMIS::config{show_non_collected_interfaces} eq "true"
							and $interfaceTable{$intf}{ifDescr} ne ""
						)
						or
						( 	$NMIS::config{show_non_collected_interfaces} eq "false"
							and $interfaceTable{$intf}{collect} ne "false"
							and $interfaceTable{$intf}{ifDescr} ne ""
						)
					) {
						$interfaceTable{$intf}{ifSpeed} = convertIfSpeed($interfaceTable{$intf}{ifSpeed});
						$interfaceTable{$intf}{portAdminSpeed} = convertIfSpeed($interfaceTable{$intf}{portAdminSpeed});
						if ( $interfaceTable{$intf}{totalUtil} == -1 ) { $interfaceTable{$intf}{totalUtil} = "N/A"; }
						rowStart;
						printCell("$interfaceTable{$intf}{intString}");
						if ( $interfaceTable{$intf}{ipAdEntAddr} ne "" and $interfaceTable{$intf}{ipAdEntNetMask} ne "" ) {
							printCell("$interfaceTable{$intf}{ipAdEntAddr}<br>$interfaceTable{$intf}{ipAdEntNetMask}<br><a href=\"$this_script?file=$conf&amp;type=find&amp;find=$interfaceTable{$intf}{ipSubnet}\">$interfaceTable{$intf}{ipSubnet}</a>");
						}
						elsif ( $interfaceTable{$intf}{ipAdEntAddr} ne "" ) {
							printCell("$interfaceTable{$intf}{ipAdEntAddr}");
						}
						else {
							printCell("");
						}
						printCell("<a href=\"$this_script?file=$conf&amp;type=find&amp;find=$interfaceTable{$intf}{Description}\">$interfaceTable{$intf}{Description}</a>");
						printCell("$interfaceTable{$intf}{ifAdminStatus}",$interfaceTable{$intf}{adminCellColor},1,"center");
						printCell("$interfaceTable{$intf}{ifOperStatus}",$interfaceTable{$intf}{operCellColor},1,"center");
						printCell("$interfaceTable{$intf}{operAvailability}",$interfaceTable{$intf}{availCellColor},1,"center");
						printCell("$interfaceTable{$intf}{totalUtil}",$interfaceTable{$intf}{totalCellColor},1,"center");
### Cologne				printCell("$interfaceTable{$intf}{collect}","#FFFFFF",1,"center");
						printCell("$interfaceTable{$intf}{collectmsg}");
						printCell("$interfaceTable{$intf}{ifType}");
						printCell("$interfaceTable{$intf}{ifSpeed}","#FFFFFF",1,"center");
						printCell("$interfaceTable{$intf}{portAdminSpeed}","#FFFFFF",1,"center");
						printCell("$interfaceTable{$intf}{ifIndex}","#FFFFFF",1,"center");
						printCell("$interfaceTable{$intf}{ifLastChange}",$interfaceTable{$intf}{lastCellColor},1,"center");
						printCell("$interfaceTable{$intf}{portDuplex}","#FFFFFF",1,"center");
						printCell("$interfaceTable{$intf}{portSpantreeFastStart}","#FFFFFF",1,"center");
						printCell("<a href=\"$this_script?file=$conf&amp;type=find&amp;find=$interfaceTable{$intf}{vlanPortVlan}\">$interfaceTable{$intf}{vlanPortVlan}</a>","#FFFFFF",1,"center");
						rowEnd;
					}
				} # foreach loop
		 	}
	 	}
		else  {
			printHeadRow("No Interface Table Information Available","#FFFFFF",20);
		}
	} #ifcollect
	else  {
		printHeadRow("No Interface Table Information Available","#FFFFFF",20);
	}

	### How about some appplication poll stats - treat similar to interface stats.
	
	
	# first check if a service type has been enabled from nodesTable services field
	if ( exists $NMIS::nodeTable{$node}{services}
		and $NMIS::nodeTable{$node}{services} ne 'n/a'
		and $NMIS::nodeTable{$node}{services} ne 'N/A'
		and $NMIS::nodeTable{$node}{services} ne '' ) {

		# must have a service name to get here...
		# load the script table that matches service name in nodesTable to service poll details.
		my %scripts = loadCSV($NMIS::config{Services_Table},$NMIS::config{Services_Key},"\t");

		rowStart;
		print "<table class=\"white\" summary=\"Services Poll\">\n";

		cssPrintHeadRow("Application Services Poll Status","menubar",4);
		print "<tr>";
		print "<td class=\"menubar\">Service_Type</td>";
		print "<td class=\"menubar\">Service Name</td>";
		print "<td class=\"menubar\">Port</td>";
		print "<td class=\"menubar\">Status</td>";
		print "</tr>\n";


		foreach my $service ( split /,/ , lc($NMIS::nodeTable{$node}{services}) ) {
			if ( -f getRRDFileName(node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype}, type => 'service', extName => $service) ) {
				my ($CellColor, $status) = eventExist($node,"Service Down",$scripts{$service}{Name}) eq 'true' ? ('#FF0000','Down') : ('#00FF00','Up');
				rowStart;
				printCell($scripts{$service}{Service_Type},$CellColor,1,'center');
				printCell($scripts{$service}{Name},$CellColor,1,'center');
				printCell($scripts{$service}{Port},$CellColor,1,'center');
				printCell($status,$CellColor,1,'center');
				rowEnd;
			}
		}
		rowEnd; 
	}
	
	print comment("End typeInfo");
	tableEnd;
	print Tr(td({class=>'white'}, &do_footer));
	tableEnd;
	pageEnd();

	sub sort2 { return (alpha() || alpha2())  }

	sub alpha {
		local($&, $`, $', $1, $2, $3, $4);
		my ($f,$s); # first and second!
		# Do reverse order
		if ( $sort1 =~ /totalUtil|Description|ipAdEntAddr|ifSpeed|collect/ ) {
			$f = $interfaceTable{$b}{$sort1};
			$s = $interfaceTable{$a}{$sort1};
		} else {
			$f = $interfaceTable{$a}{$sort1};
			$s = $interfaceTable{$b}{$sort1};			
		}
		#print STDERR "f=$f s=$s sort1=$sort1\n";
		# Sort IP addresses numerically within each dotted quad
		if ($f =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/) {
			my($a1, $a2, $a3, $a4) = ($1, $2, $3, $4);
			if ($s =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/) {
				my($b1, $b2, $b3, $b4) = ($1, $2, $3, $4);
				return ($a1 <=> $b1) || ($a2 <=> $b2)
				|| ($a3 <=> $b3) || ($a4 <=> $b4);
			}
		}
		# Sort numbers numerically
		elsif ( $f !~ /[^0-9\.]/ && $s !~ /[^0-9\.]/ ) {
			return $f <=> $s;
		}
		# Handle things like Level1, ..., Level10
		if ($f =~ /^(.*\D)(\d+)$/) {
		    my($a1, $a2) = ($1, $2);
		    if ($s =~ /^(.*\D)(\d+)$/) {
				my($b1, $b2) = ($1, $2);
				return $a2 <=> $b2 if $a1 eq $b1;
		    }
		}
		# Default is to sort alphabetically
		return $f cmp $s;
	}

	sub alpha2 {
		local($&, $`, $', $1, $2, $3, $4);
		my ($f,$s); # first and second!
		# Do reverse order
		if ( $sort2 =~ /totalUtil|Description|ipAdEntAddr|ifSpeed|collect/ ) {
			$f = $interfaceTable{$b}{$sort2};
			$s = $interfaceTable{$a}{$sort2};
		} else {
			$f = $interfaceTable{$a}{$sort2};
			$s = $interfaceTable{$b}{$sort2};			
		}
		#print STDERR "f=$f s=$s sort2=$sort2\n";
		# Sort IP addresses numerically within each dotted quad
		if ($f =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/) {
			my($a1, $a2, $a3, $a4) = ($1, $2, $3, $4);
			if ($s =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/) {
				my($b1, $b2, $b3, $b4) = ($1, $2, $3, $4);
				return ($a1 <=> $b1) || ($a2 <=> $b2)
				|| ($a3 <=> $b3) || ($a4 <=> $b4);
			}
		}
		# Sort numbers numerically
		elsif ( $f !~ /[^0-9\.]/ && $s !~ /[^0-9\.]/ ) {
			return $f <=> $s;
		}
		# Handle things like Level1, ..., Level10
		if ($f =~ /^(.*\D)(\d+)$/) {
		    my($a1, $a2) = ($1, $2);
		    if ($s =~ /^(.*\D)(\d+)$/) {
				my($b1, $b2) = ($1, $2);
				return $a2 <=> $b2 if $a1 eq $b1;
		    }
		}
		# Default is to sort alphabetically
		return $f cmp $s;
	}

} # typeInfo

sub typeLink {

	my $index;
	my %reportTable;
	my %reportTable2;
	my %summaryTable;
	my $summaryhash;
	my @tmparray;
	my @tmpsplit;
	my $cellColor;
	my %seen;

	 
	# verify access to this command/tool bar/button
	#
	if ( $auth->Require ) {
		# CheckAccess will throw up a web page and stop if access is not allowed
		$auth->CheckAccess($user, "links") or die "Attempted unauthorized access";
	}
	
	# Fill the data hashes with groovy information!!!!
	loadLinkDetails;

	if ( $link eq "" and $node eq "" ) { &linkMenu; }
	elsif ( $node ne "" ) { &linkNode; }
	else { &linkDetails; }

	sub linkMenu{
		my $linkname;
		my $reportStats;

		pageStart("Link Menu","false",\%headeropts);
		cssTableStart;
		print start_Tr(),
			start_td;
		&do_dash_banner($auth->Require, $user->user);
		print end_td(),
			end_Tr;
		&nmisMenuSmall;
		$NMIS::userMenu && &nmisMenuBar;
		cssHeaderBar("Link List (stats based on last 2 days)","grey");

		# Get each of the links and get some summary info!!!
	    foreach $linkname ( keys (%NMIS::linkTable) )   {
			# Get the response time from the remote node!!!
			if ( $NMIS::linkTable{$linkname}{node2} ne "" ) {
				loadSystemFile($NMIS::linkTable{$linkname}{node2});
	    		%reportTable = (%reportTable,summaryStats(node => $NMIS::linkTable{$linkname}{node2},type => "health",start => "-2 days",end => time,key => $linkname));
			}

			loadSystemFile($NMIS::linkTable{$linkname}{node1});
			loadInterfaceFile($NMIS::linkTable{$linkname}{node1});

			# Get the link availability from the local node!!!
			$tmpifDescr = convertIfName($NMIS::linkTable{$linkname}{interface1});
			if ( $NMIS::linkTable{$linkname}{node1} ne ""
				 and $NMIS::interfaceTable{$tmpifDescr}{collect} eq "true" ) {
	    		%reportTable2 = summaryStats(node => $NMIS::linkTable{$linkname}{node1},type => "util",start => "-2 days",end => time,
						ifDescr => $tmpifDescr,speed => $NMIS::interfaceTable{$tmpifDescr}{ifSpeed},key => $linkname);
				# add values reportTable2 in reportTable
				foreach (keys %{$reportTable2{$linkname}}) { $reportTable{$linkname}{$_} = $reportTable2{$linkname}{$_};}
			}
		} # foreach $linkname

		rowStart;
		cellStart ("white",12);

                %seen = ();
                foreach $linkname ( keys (%NMIS::linkTable) )   {
                        if ($seen{$NMIS::linkTable{$linkname}{ifType}} < 1){
                                cssTableStart("white");
                                printHeadRow("$NMIS::linkTable{$linkname}{ifType}Links","#FFFFFF",13);
                                &displayLinks($NMIS::linkTable{$linkname}{ifType});
                                tableEnd;
                                paragraph;
                                $seen{$NMIS::linkTable{$linkname}{ifType}}++;
                                }
                        }



		cellEnd;
		rowEnd;
		tableEnd;

		cellEnd;
		rowEnd;
		tableEnd;
		pageEnd;
	} # Link Menu

	sub linkNode{
		my $linkname;
		my $reportStats;

		pageStart("Link List for $node","false",\%headeropts);
		cssTableStart;
		print start_Tr(),
			start_td;
		&do_dash_banner($auth->Require, $user->user);
 		print end_td(),
			end_Tr;
		&nmisMenuSmall;
		$NMIS::userMenu && &nmisMenuBar;
		cssHeaderBar("Link List for $node (stats based on last 2 days)","grey");

		# Get each of the links and get some summary info!!!
		foreach $linkname ( keys (%NMIS::linkTable) )   {
			if ( $NMIS::linkTable{$linkname}{node1} eq $node
				 or $NMIS::linkTable{$linkname}{node2} eq $node
			) {
				# Get the response time from the remote node!!!
				if ( $NMIS::linkTable{$linkname}{node2} ne "" ) {
					loadSystemFile($NMIS::linkTable{$linkname}{node2});
		    		%reportTable = (%reportTable,summaryStats(node => $NMIS::linkTable{$linkname}{node2},type => "health",start => "-2 days",end => time,key => $linkname));
				}

				loadSystemFile($NMIS::linkTable{$linkname}{node1});
				loadInterfaceFile($NMIS::linkTable{$linkname}{node1});

				# Get the link availability from the local node!!!
				$tmpifDescr = convertIfName($NMIS::linkTable{$linkname}{interface1});
				if ( $NMIS::linkTable{$linkname}{node1} ne ""
						and $NMIS::interfaceTable{$tmpifDescr}{collect} eq "true" ) {
		    		%reportTable2 = summaryStats(node => $NMIS::linkTable{$linkname}{node1},type => "util",start => "-2 days",end => time,ifDescr => $tmpifDescr,speed => $NMIS::interfaceTable{$tmpifDescr}{ifSpeed},key => $linkname);
					# add values reportTable2 in reportTable
					foreach (keys %{$reportTable2{$linkname}}) { $reportTable{$linkname}{$_} = $reportTable2{$linkname}{$_};}
				}
			} # if $node = Node1
		} # foreach $linkname

		rowStart;
		cellStart ("white",12);

		%seen = ();
		foreach $linkname ( keys (%NMIS::linkTable) )   {
			if ($seen{$NMIS::linkTable{$linkname}{ifType}} < 1){
                		cssTableStart("white");
                		printHeadRow("$NMIS::linkTable{$linkname}{ifType}Links","#FFFFFF",13);
                		&displayLinks($NMIS::linkTable{$linkname}{ifType});
                		tableEnd;
                		paragraph;
                		$seen{$NMIS::linkTable{$linkname}{ifType}}++;
                		}
			}

		cellEnd;
		rowEnd;
		tableEnd;

		cellEnd;
		rowEnd;
		tableEnd;
		pageEnd;
	} # Link Node

	sub linkDetails{
		my @tmparray;
		my $index;

		my ($graphLinkUtil,$graphLinkBits);

		pageStart("$NMIS::linkTable{$link}{link} Link Details","true",\%headeropts);
		cssTableStart;
		print start_Tr(),
			start_td;
		&do_dash_banner($auth->Require, $user->user);
		print end_td(),
			end_Tr;
		&nmisMenuSmall;
		&nmisMenuBar;
	    	cssHeaderBar("$link Link Details","grey");

		rowStart;
		cellStart ("white",12);
		cssTableStart("white");

		rowStart;
		printHeadCell("Net");
		printCell("$NMIS::linkTable{$link}{net}");
		printHeadCell("Role");
		printCell("$NMIS::linkTable{$link}{role}");
		printHeadCell("Location");
		printCell("$NMIS::linkTable{$link}{location}");
		rowEnd;

		rowStart;
		printHeadCell("Primary Node","#FFFFFF",2);
		printCell("<a href=\"$this_script?file=$conf&amp;node=$NMIS::linkTable{$link}{node1}\">$NMIS::linkTable{$link}{node1}</a>","#FFFFFF",1);
		printHeadCell("Primary Interface","#FFFFFF",2);
		printCell("<a href=\"$this_script?file=$conf&amp;node=$NMIS::linkTable{$link}{node1}&amp;type=graph&amp;graphtype=$NMIS::config{portstats}&amp;glamount=$glamount&amp;glunits=$glunits&amp;intf=$NMIS::linkTable{$link}{ifIndex1}\">$NMIS::linkTable{$link}{interface1}</a>","#FFFFFF",1);
		rowEnd;

		if ( $NMIS::linkTable{$link}{location} ne "access" ) {
			rowStart;
			printHeadCell("Secondary Node","#FFFFFF",2);
			printCell("<a href=\"$this_script?file=$conf&amp;node=$NMIS::linkTable{$link}{node2}\">$NMIS::linkTable{$link}{node2}</a>","#FFFFFF",1);
			printHeadCell("Secondary Interface","#FFFFFF",2);
			printCell("<a href=\"$this_script?file=$conf&amp;node=$NMIS::linkTable{$link}{node2}&amp;type=graph&amp;graphtype=$NMIS::config{portstats}&amp;glamount=$glamount&amp;glunits=$glunits&amp;intf=$NMIS::linkTable{$link}{ifIndex2}\">$NMIS::linkTable{$link}{interface2}</a>","#FFFFFF",1);
			rowEnd;
		}

		if ( $NMIS::linkTable{$link}{depend} ne "none" ) {
			# Check if its daisy chain of links
			rowStart;
			if ( $NMIS::linkTable{$link}{depend} =~ /;/ ) {
				@tmparray = split ";", $NMIS::linkTable{$link}{depend};
				printHeadCell("Link Dependancies","#FFFFFF",3);
				cellStart("#FFFFFF",3);
				for ($index = 0; $index <= $#tmparray; ++$index) {
					print "<a href=\"$this_script?file=$conf&amp;type=link&amp;link=$tmparray[$index]\">$tmparray[$index]</a>";
					if ( $index != $#tmparray ) { print "; "; }
				}
				cellEnd;
			}
			else {
				printHeadCell("Link Dependancies","#FFFFFF",3);
				printCell("<a href=\"$this_script?file=$conf&amp;type=link&amp;link=$NMIS::linkTable{$link}{depend}\">$NMIS::linkTable{$link}{depend}</a>","#FFFFFF",3);
			}
			rowEnd;
		}
		rowStart;
 		cssPrintCell("menubar","<a href=\"$this_script?file=$conf&amp;type=graph&amp;graphtype=response&amp;glamount=$glamount&amp;glunits=$glunits&amp;node=$NMIS::linkTable{$link}{node2}\">Response Time</a>",2);
 		cssPrintCell("menubar","<a href=\"$this_script?file=$conf&amp;type=graph&amp;graphtype=util&amp;glamount=$glamount&amp;glunits=$glunits&amp;node=$NMIS::linkTable{$link}{node1}&amp;interface=$NMIS::linkTable{$link}{interface1}\">Util Graph</a>",2);
 		cssPrintCell("menubar","<a href=\"$this_script?file=$conf&amp;type=graph&amp;graphtype=bits&amp;glamount=$glamount&amp;glunits=$glunits&amp;node=$NMIS::linkTable{$link}{node1}&amp;interface=$NMIS::linkTable{$link}{interface1}\">Bits Per Second Graph</a>",2);
		rowEnd;

		if ( $NMIS::linkTable{$link}{node2} ne "" ) {
			$node = $NMIS::linkTable{$link}{node2};
			loadSystemFile($node);
			my $graphResponseUtil =
				"<a href=\"$this_script?file=$conf&amp;type=graph&amp;graphtype=response&amp;glamount=$glamount&amp;glunits=$glunits&amp;node=$node&amp;interface=$NMIS::interfaceTable{$intf}{ifDescr}\">"
				."<img border=\"0\" alt=\"Device Response Time\" src=\"$this_script?file=$conf&amp;type=drawgraph&amp;node=$node&amp;graph=response&amp;glamount=$glamount&amp;glunits=$glunits&amp;start=0&amp;end=0&amp;width=500&amp;height=100\"></a>"
				."";

			rowStart;
			cssPrintCell("grey","Response Time for Secondary Node $node</STRONG>",6);
			rowEnd;

			rowStart;
 	 		cssPrintCell("center","$graphResponseUtil",6);
			rowEnd;

		}
		# Display the Primary Node Details
		$node = $NMIS::linkTable{$link}{node1};
		$tmpifDescr = convertIfName($NMIS::linkTable{$link}{interface1});
		loadSystemFile($node);

		rowStart;
		cssPrintCell("grey","Primary Node Interface Stats for $node Interface: $NMIS::linkTable{$link}{interface1}",6);
		rowEnd;

		$graphLinkUtil =
			"<a href=\"$this_script?file=$conf&amp;type=graph&amp;graphtype=util&amp;glamount=$glamount&amp;glunits=$glunits&amp;node=$node&amp;interface=$NMIS::linkTable{$link}{interface1}\">"
			."<img alt=\"Interface Availability and Utilisation\" border=\"0\" src=\"$this_script?file=$conf&amp;type=drawgraph&amp;node=$node&amp;graph=bits&amp;glamount=$glamount&amp;glunits=$glunits&amp;start=0&amp;end=0&amp;width=500&amp;height=100&amp;interface=$NMIS::linkTable{$link}{interface1}\"></a>"
			;

		rowStart;

  		cssPrintCell("center","$graphLinkUtil",6);
		rowEnd;

		tableEnd;
		cellEnd;
		rowEnd;
		tableEnd;

		cellEnd;
		rowEnd;
		tableEnd;
		pageEnd;
	} # Link Details

	sub displayLinks {
	  	my $string = shift;

		my $linkname;
		my $cellColor;
		my @tmparray;
		my $index;
		my $tmpurl;

		if ( $string eq "access" ) {
			printHeadRow("Link Name,Net,Role,Node,Interface,Link Availability,% Total Util,% In Util,% Out Util","#FFFFFF");
		}
		else {
			printHeadRow("Link Name,Net,Role,Primary Node,Interface,Secondary Node,Interface,Link Availability,% Total Util,% In Util,% Out Util,Response Time,Dependancies","#FFFFFF");
		}
		#print each of the display groups in turn
		foreach $linkname ( keys (%NMIS::linkTable)  )  {
			if (
				( 	$node eq ""
					and $NMIS::linkTable{$linkname}{ifType} eq "$string"
				) or (
					$NMIS::linkTable{$linkname}{node1} eq $node
					or $NMIS::linkTable{$linkname}{node2} eq $node
				) and
					$NMIS::linkTable{$linkname}{ifType} eq "$string"
			) {
				#
				$tmpifDescr = convertIfName($NMIS::linkTable{$link}{interface1});
				rowStart;
				printCell("<a href=\"$this_script?file=$conf&amp;type=link&amp;link=$linkname\">$NMIS::linkTable{$linkname}{link}</a>");
				printCell("$NMIS::linkTable{$linkname}{net}");
				printCell("$NMIS::linkTable{$linkname}{role}");
				printCell("<a href=\"$this_script?file=$conf&amp;node=$NMIS::linkTable{$linkname}{node1}\">$NMIS::linkTable{$linkname}{node1}</a>");
				$tmpurl = "$this_script?file=$conf&amp;node=$NMIS::linkTable{$linkname}{node1}&amp;type=graph&amp;graphtype=$NMIS::config{portstats}&amp;glamount=$glamount&amp;glunits=$glunits&amp;intf=$NMIS::linkTable{$linkname}{ifIndex1}";
				printCell("<a href=\"$tmpurl\" target=ViewWindow onMouseOver=\"window.status='Drill into $NMIS::linkTable{$linkname}{interface1}.';return true\" onClick=\"viewdoc('$tmpurl',$win_width,$win_height)\">$NMIS::linkTable{$linkname}{interface1}</a>");
				if ( $string ne "access" ) {
					printCell("<a href=\"$this_script?file=$conf&amp;node=$NMIS::linkTable{$linkname}{node2}\">$NMIS::linkTable{$linkname}{node2}</a>");
					$tmpurl = "$this_script?file=$conf&amp;node=$NMIS::linkTable{$linkname}{node2}&amp;type=graph&amp;graphtype=$NMIS::config{portstats}&amp;glamount=$glamount&amp;glunits=$glunits&amp;intf=$NMIS::linkTable{$linkname}{ifIndex2}";
					printCell("<a href=\"$tmpurl\" target=ViewWindow onMouseOver=\"window.status='Drill into $NMIS::linkTable{$linkname}{interface2}.';return true\" onClick=\"viewdoc('$tmpurl',$win_width,$win_height)\">$NMIS::linkTable{$linkname}{interface2}</a>");
				}
				$cellColor = colorHighGood($reportTable{$linkname}{availability});
				printCellRight("$reportTable{$linkname}{availability}",$cellColor);

				$cellColor = colorLowGood($reportTable{$linkname}{totalUtil});
				printCellRight("$reportTable{$linkname}{totalUtil}",$cellColor);

				$cellColor = colorLowGood($reportTable{$linkname}{inputUtil});
				printCellRight("$reportTable{$linkname}{inputUtil}",$cellColor);

				$cellColor = colorLowGood($reportTable{$linkname}{outputUtil});
				printCellRight("$reportTable{$linkname}{outputUtil}",$cellColor);

				if ( $string ne "access" ) {
					if ( $reportTable{$linkname}{response} ne "" ) {
						$cellColor = colorResponseTime($reportTable{$linkname}{response});
						printCellRight("$reportTable{$linkname}{response}",$cellColor);
					}
					else { printCell(""); }
				}

				if ( $string ne "access" ) {
					if ( $NMIS::linkTable{$linkname}{depend} ne "none" ) {
						# Check if its daisy chain of links
						if ( $NMIS::linkTable{$linkname}{depend} =~ /;/ ) {
							@tmparray = split ";", $NMIS::linkTable{$linkname}{depend};
							cellStart("#FFFFFF");
							for ($index = 0; $index <= $#tmparray; ++$index) {
								print "<a href=\"$this_script?file=$conf&amp;type=link&amp;link=$tmparray[$index]\">$tmparray[$index]</a>";
								if ( $index != $#tmparray ) { print "<BR>"; }
							}
							cellEnd;
						}
						else {
							printCell("<a href=\"$this_script?file=$conf&amp;type=link&amp;link=$NMIS::linkTable{$linkname}{depend}\">$NMIS::linkTable{$linkname}{depend}</a>","#FFFFFF");
						}
					}
					else { printCell(""); }
				}

				rowEnd;
			} # if $location eq $string

	        } # foreach $linkname

	} # sub displayLinks

} # sub typeLink

sub typeHealth {
	my @pr;
	my $i;
	# verify access to this command/tool bar/button
	#
	if ( $auth->Require ) {
		# CheckAccess will throw up a web page and stop if access is not allowed
	 	# $auth->CheckAccess($user, "") or die "Attempted unauthorized access";
		if ( ! $user->user ) {
			do_force_login("Authentication is required to access this function. Please login.");
			exit 0;
		}
	}

	pageStart("Health Info","true",\%headeropts);
	cssTableStart;
	print start_Tr(),
		start_td;
	&do_dash_banner($auth->Require, $user->user);
	print end_td(),
		end_Tr;
	&nmisMenuSmall;
	$NMIS::userMenu && &nmisMenuBar;
	my $time = time;
	$datestamp = returnDateStamp;
	$datestamp_2 = returnDateStamp($time - 2 * 24 * 60 * 60);


	# Get the System info from the file and whack it into the hash
	loadSystemFile($node);

	if ( ! $user->InGroup($NMIS::nodeTable{$node}{group}) ) {
		cssHeaderBar("Not Authorized to view health statistics on node '$node' in group '$NMIS::nodeTable{$node}{group}'.",
			"grey");
		pageEnd;
		return 0;
	}

	cssHeaderBar("Health statistics for $node from $datestamp_2 to $datestamp","grey");
	$NMIS::userMenu && displaySystemHeader($node);

	### reach, avail, health, and response gets printed for all nodes
	### @pr = [name, label, graphtype],[..,...,..],...;
	@pr = (
		[ "Reach", "Reachability, Availability and Health", "health"],
		[ "Response", "Response Time", "response" ]
	);

	if ( $NMIS::nodeTable{$node}{collect} eq "true" and $NMIS::nodeTable{$node}{active} ne "false") {
		if ( $NMIS::systemTable{nodeModel} =~ /CiscoRouter|CatalystIOS/ ) {

			push @pr, ( [ "CPU", "CPU Utilisation", "cpu" ] );
			### KS 2 Jan 03 - Changing IP Routing to IP Statistics
			push @pr, ( [ "IP", "IP Statistics", "ip" ] );
			push @pr, ( [ "Frag", "IP Fragmentation", "frag" ] );
			push @pr, ( [ "Buffer", "Buffer", "buffer" ] );
			push @pr, ( [ "Mem", "Router Memory", "mem-router" ] );

			if ( $NMIS::systemTable{typedraw} =~ /modem/ ) {
				push @pr, ( [ "Modem", "Modems", "modem" ] );
			}
			if ( $NMIS::systemTable{typedraw} =~ /calls/ ) {
				push @pr, ( [ "Calls", "Calls", "calls" ] );
			}
		}

		elsif ( $NMIS::systemTable{nodeModel} =~ /Accelar/ ) {

			push @pr, ( [ "CPU", "CPU Utilisation", "acpu" ] );
			### KS 2 Jan 03 - Changing IP Routing to IP Statistics
			push @pr, ( [ "IP", "IP Statistics", "ip" ] );

		}
		elsif ( $NMIS::systemTable{nodeModel} =~ /Catalyst5005/ ) {

			push @pr, ( [ "Traffic", "System Traffic", "traffic" ] );
			push @pr, ( [ "Topology", "Topology Changes", "topo" ] );
			push @pr, ( [ "Mem", "Switch Memory Utilisation", "mem-switch" ] );

		}
		elsif ( $NMIS::systemTable{nodeModel} =~ /Catalyst6000|Catalyst5000Sup3|Catalyst5000/ ) {

			push @pr, ( [ "CPU", "CPU Utilisation", "cpu" ] );
			push @pr, ( [ "Traffic", "System Traffic", "traffic" ] );
			push @pr, ( [ "Topology", "Topology Changes", "topo" ] );
			push @pr, ( [ "Mem", "Switch Memory Utilisation", "mem-switch" ] );

		}
		### Cisco PIX
		elsif ( $NMIS::systemTable{nodeModel} =~ /CiscoPIX/ ) {

			push @pr, ( [ "CPU", "CPU Utilisation", "cpu" ] );
			push @pr, ( [ "Mem", "PIX Memory Utilisation", "mem-proc" ] );
			push @pr, ( [ "Connections", "PIX Connections", "pix-conn" ] );

		}
		### 3Com
		elsif ( $NMIS::systemTable{nodeModel} =~ /SSII 3Com/ ) {

			push @pr, ( [ "Bandwidth", "System Bandwidth", "a3bandwidth" ] );
			push @pr, ( [ "Traffic", "System Traffic", "a3traffic" ] );
			push @pr, ( [ "Errors", "System Errors", "a3errors" ] );

		}
		elsif ( $NMIS::systemTable{nodeModel} =~ /Redback/ ) {

			push @pr, ( [ "CPU", "CPU Utilisation", "cpu" ] );
			push @pr, ( [ "IP", "IP Statistics", "ip" ] );
			push @pr, ( [ "Frag", "IP Fragmentation", "frag" ] );

		}
		elsif ( $NMIS::systemTable{nodeModel} =~ /FoundrySwitch/ ) {

			push @pr, ( [ "CPU", "CPU Utilisation", "cpu" ] );
			push @pr, ( [ "IP", "IP Statistics", "ip" ] );
			push @pr, ( [ "Frag", "IP Fragmentation", "frag" ] );
			push @pr, ( [ "Buffer", "Buffer", "buffer" ] );
			push @pr, ( [ "Mem", "Router Memory", "mem-router" ] );

		}
		elsif ( $NMIS::systemTable{nodeModel} =~ /Riverstone/ ) {

			push @pr, ( [ "CPU", "CPU Utilisation", "cpu" ] );
			push @pr, ( [ "IP", "IP Statistics", "ip" ] );
			push @pr, ( [ "Frag", "IP Fragmentation", "frag" ] );
			push @pr, ( [ "Buffer", "Buffer", "buffer" ] );
			push @pr, ( [ "Mem", "Router Memory", "mem-router" ] );

		}
		### server type stuff
		elsif ( $NMIS::systemTable{nodeType} eq "server" ) {
			if ( $NMIS::systemTable{nodeVendor} =~ /microsoft/i ) {
				### IB 13 Jul 04 seems only windows 5.x has the correct hrProcessorTable
				if ( $NMIS::systemTable{sysDescr} =~ /ersion 5\./) {
                        		# multiple CPUs
                        		for ( $i=1; $i <= $NMIS::systemTable{hrNumCPU}; $i++ ) {
                                	push @pr, ( [ "CPU$i", "Server CPU #$i", "hrsmpcpu$i"] );
                        		}
				}
				else {
					push @pr, ( [ "CPU", "Server CPU", "hrwincpu"] );
				}
				push @pr, ( [ "Cpu Int", "Server CPU Interrupts", "hrwincpuint"] );
				push @pr, ( [ "IP", "IP Statistics", "ip" ] );
				
 				if ($NMIS::systemTable{nodeModel} =~ /Windows2003/) {
 					push @pr, ( [ "Mem", "Server Memory", "hrmem" ] );
                    push @pr, ( [ "VMem", "Server Virtual Memory", "hrvmem"] );
				}
				
 				push @pr, ( [ "WTCS Mem", "WTCS Server Memory", "hrwinmem" ] );
				push @pr, ( [ "MemPPS", "Server Memory Pages per Sec", "hrwinpps"] );
				push @pr, ( [ "Users", "# Users", "hrwinusers"] );
				push @pr, ( [ "Processes", "# Processes", "hrwinproc"] );

				#if ( $NMIS::systemTable{sysName} =~ /XXXX/ ) {		# only specific servers - should break out in models.csv
				#	push @pr, ( [ "Temp", "Server Temperature", "degree"] );
				#}	

			}
			else {

				push @pr, ( [ "CPU", "Server CPU", "hrcpu"] );
				push @pr, ( [ "Mem", "Server Memory", "hrmem" ] );
				push @pr, ( [ "MemPPS", "Server Virtual Memory", "hrvmem"] );
				push @pr, ( [ "Users", "# Users", "hrusers"] );
				push @pr, ( [ "Processes", "# Processes", "hrproc"] );

			}
			# and the disk1-x

			for ( $i=1; $i <= $NMIS::systemTable{hrNumDisk}; $i++ ) {
				push @pr, ( [ "Disk$i", "$NMIS::systemTable{'hrDiskLabel'.$i}", "hrdisk$i"] );
			}

		} #endif
	} # end ifcollect

	#### now print it
	hmenubar();
	foreach ( @pr ) { hprint( $_ ) }

	### end of prints, now close the table
	tableEnd;
	pageEnd;


	# an internal sub to print the menubar
	sub hmenubar {
		rowStart;
		cssCellStart("white");
		cssTableStart("white");
		rowStart;
		cssPrintCell("menubar","<a href=\"#INFO\">Info</a>");
		foreach ( @pr ) { cssPrintCell("menubar","<a href=\"#$_->[0]\">$_->[0]</a>") }
		rowEnd;
		tableEnd;
		cellEnd;
		rowEnd;
	}

	# an internal sub to print health stats
	sub hprint {
		my $aref = shift;
		my $tmpurl="$this_script?file=$conf&amp;type=graph&amp;graphtype=$aref->[2]&amp;glamount=$glamount&amp;glunits=$glunits&amp;node=$node";

		print <<EO_HTML;
		<tr>
			<td align="center" bgcolor="white"><A name="$aref->[0]"></A><b>
				<a href="#TOP">$aref->[1]</a><BR>
				<a href="$tmpurl"
				target=ViewWindow onMouseOver="window.status='Drill into $aref->[1].';return true" onClick="viewdoc('$tmpurl',$win_width,$win_height)">
				<img border="0" alt="$aref->[1]" src="$this_script?file=$conf&amp;type=drawgraph&amp;node=$node&amp;graph=$aref->[2]&amp;glamount=$glamount&amp;glunits=$glunits&amp;width=500&amp;height=100">
				</a>
			</b>
			</td>
		</tr>
EO_HTML
	} #end sub

} # typeHealth


# display summary port stats
# uses NMIS::config{portstats} to determine graph type to display

sub typePort {
 	my $port;
 	my $reportStats;
 	my @tmparray;
	my $ifLastChange;
	my $tmpurl;
	my %interfaceTable;
	my %util;
	my $int_desc;
	my $graph_width = 400;
	my $graph_height = 50;

	if ( $auth->Require ) {
		# CheckAccess will throw up a web page and stop if access is not allowed
		$auth->CheckAccess($user, "port") or die "Attempted unauthorized access";
	}

	if ( ! defined $sort1 ) { $sort1 = "totalUtil" }
	if ( ! defined $sort2 ) { $sort2 = "intString" }

	if ($graphtype eq "") { $graphtype = $NMIS::config{portstats}; }
	if ($graphtype eq "cbqos") { $graph_height = 70; }

	pageStart("Information about $node","true",\%headeropts);
	cssTableStart;
	print start_Tr(),
		start_td;
	do_dash_banner($auth->Require, $user->user);
	print end_td(),
		end_Tr;
	&nmisMenuSmall;
	$NMIS::userMenu && &nmisMenuBar;
	$datestamp = returnDateStamp;
	print comment("Start typePort, node=$node, group=$group, at date=$datestamp");
#    cssHeaderBar("Information for $node at $datestamp","grey");
	# Compare the Up time to the last uptime? and check if unhealthy?

	# Get the System info from the file and whack it into the hash
	loadSystemFile($node);
	if ( ! $user->InGroup($NMIS::nodeTable{$node}{group}) ) {
		cssHeaderBar("Not Authorized to view health statistics on node '$node' in group '$NMIS::nodeTable{$node}{group}'.","grey");
		goto END;
	}

	cssHeaderBar("Information for $node at $datestamp","grey");
	if ( $NMIS::nodeTable{$node}{collect} eq "true" ) {
		%interfaceTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-interface.dat","ifIndex","\t");
	}

	$NMIS::userMenu && displaySystemHeader($node);

	print &start_Tr,
		start_td({class=>"white"}),
		start_table({summary=>"Display", class=>"white"});
#print <<EO_HTML;
#	<tr>
#	<td class="white">
#    <table class="white" summary="Display">
	print "	<form name=\"graph\" action=\"$this_script\">";
#EO_HTML

	if ( $NMIS::systemTable{nodeModel} =~ /router|atm|Catalyst|PIX|FreeBSD|SunSolaris|generic|MIB2|Windows|Accelar|BayStack|SSII 3Com|Redback|FoundrySwitch|Riverstone/i ) {
		# Extract the interface statics and summaries for display in a second.
		foreach $intf (keys %interfaceTable ) {
			if ( $interfaceTable{$intf}{collect} eq "true" ) {
				# Set the standard interface name
	 			$tmpifDescr = convertIfName($interfaceTable{$intf}{ifDescr});

				# Set the cell color to reflect the interface status
				# so if admin = down then oper irrelevent
				if ( 	( $interfaceTable{$intf}{ifAdminStatus} eq "down" ) ||
					( $interfaceTable{$intf}{ifAdminStatus} eq "testing" ) ||
					( $interfaceTable{$intf}{ifAdminStatus} eq "null" )
				) {
					$adminCellColor="#ffffff";
					$operCellColor="#ffffff";
					$operAvailability = "N/A";
					$availCellColor="#ffffff";
					$totalUtil = "N/A";
					$totalCellColor="#ffffff";
					$lastCellColor = "#ffffff";
					$intString="$interfaceTable{$intf}{ifDescr}";
				}
				# admin up, Set the opercolor to reflect the real status
				else {
					$tmpurl = "$this_script?file=$conf&amp;node=$node&amp;type=graph&amp;graphtype=$NMIS::config{portstats}&amp;glamount=$glamount&amp;glunits=$glunits&amp;intf=$intf";
					$intString="<a href=\"$tmpurl\" target=ViewWindow onMouseOver=\"window.status='Drill into $interfaceTable{$intf}{ifDescr}.';return true\" onClick=\"viewdoc('$tmpurl',$win_width,$win_height)\">$interfaceTable{$intf}{ifDescr}</a>";

					$adminCellColor="#00ff00";

					# need to add interface details if set in config switch
					### AS 17 Mar 02 - Request James Norris, Optionally include interface description in messages.
					if ( defined $interfaceTable{$intf}{Description}
						and $interfaceTable{$intf}{Description} ne "null"
						and $NMIS::config{send_description} eq "true"
					) {
						$int_desc = " description=$interfaceTable{$intf}{Description}";
					}
					my $event_status = eventExist($node,"Interface Down","interface=$interfaceTable{$intf}{ifDescr}$int_desc");
					if (	( $event_status eq "true" ) &&
						( $interfaceTable{$intf}{ifOperStatus} =~ /up|ok/ )
					) {
						# Red for down
						$operCellColor = "#ff0000";
						$interfaceTable{$intf}{ifOperStatus} = "down";
					}
					elsif (	( $event_status eq "false" ) &&
						( $interfaceTable{$intf}{ifOperStatus} =~ /up|ok/ )
					) {
						# Green for up
						$operCellColor = "#00ff00";
						$interfaceTable{$intf}{ifOperStatus} = "up";
					}
					elsif ( $interfaceTable{$intf}{ifOperStatus} eq "down" ) {
						# Red for down
						$operCellColor = "#ff0000";
					}
					elsif ( $interfaceTable{$intf}{ifOperStatus} eq "dormant" ) {
						# Red for down
						$operCellColor = "#ffff00";
					}
					else { $operCellColor = "#ffffff"; }

					$lastCellColor = "#ffffff";

					# Get the link availability from the local node!!!
		    		%util = summaryStats(node => $node,type => "util",start => "-6 hours",end => time,ifDescr => $interfaceTable{$intf}{ifDescr},speed => $interfaceTable{$intf}{ifSpeed});

					$operAvailability = $util{availability};
					$totalUtil = $util{totalUtil};

					$availCellColor = colorHighGood($operAvailability);
					$totalCellColor = colorLowGood($totalUtil);

					if ( $interfaceTable{$intf}{ifOperStatus} eq "dormant" )  {
						$operAvailability = "N/A" ;
						$availCellColor = "#FFFFFF";
						$operCellColor = "#ffff00";
					}
				}
				# save what we got for printing
				$interfaceTable{$intf}{totalUtil}=$totalUtil;
				$interfaceTable{$intf}{operAvailability}=$operAvailability;
				$interfaceTable{$intf}{totalCellColor}=$totalCellColor;
				$interfaceTable{$intf}{availCellColor}=$availCellColor;
				$interfaceTable{$intf}{operCellColor}=$operCellColor;
				$interfaceTable{$intf}{lastCellColor}=$lastCellColor;
				$interfaceTable{$intf}{adminCellColor}=$adminCellColor;
				$interfaceTable{$intf}{intString}=$intString;
			} # if collect
		} # FOR LOOP

		# only show collected interface here...as only have rrd for collected interfaces.
		if ( $NMIS::systemTable{nodeModel} =~ /router|catalystios|atm|generic|MIB2|PIX|FreeBSD|SunSolaris|Windows|Accelar|BayStack|SSII 3Com|Redback/i ) {
			cssPrintHeadRow("Interface Table","menubar",11);
			print "			<tr>";
			print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=port&amp;sort1=ifDescr&amp;sort2=$sort1\">Name</a></td>";
			print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=port&amp;sort1=ipAdEntAddr&amp;sort2=$sort1\">IP</a></td>";
			print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=port&amp;sort1=Description&amp;sort2=$sort1\">Description</a></td>";
			print "<td class=\"menubar\">AdminStat</td>";
			print "<td class=\"menubar\">OperStat</td>";
			print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=port&amp;sort1=operAvailability&amp;sort2=$sort1\">Int. Avail.</a></td>";
			print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=port&amp;sort1=totalUtil&amp;sort2=$sort1\">Util. 6hrs</a></td>";
			print <<EO_HTML;
			<td class="menubar">Graph
			<select name="graphtype" size="1" length="30" onChange="JavaScript:document.graph.submit()">
   			<option value="$graphtype">$graphtype</option>
			<option value="util">util</option>
			<option value="autil">autil</option>
			<option value="bits">bits</option>
			<option value="abits">abits</option>
			<option value="pkts">pkts</option>
			<option value="epkts">epkts</option>
			<option value="cbqos-in">cbqos-in</option>
			<option value="cbqos-out">cbqos-out</option>
			</select>
			</td></tr>
EO_HTML
			# So now I have a hash of interface utilsation!!!!
			# New sort method, create a hash of keys data = $intf which are 
			# what to sort on, then alpha sort the keys and map the $intf 
			# back to the data.
			foreach $intf ( sort sort2 ( keys %interfaceTable ) ) {
				# controls whether or not we see non collected interfaces
				next unless $interfaceTable{$intf}{collect} eq "true";				

				if ($NMIS::systemTable{"typedraw$intf"} =~ /$graphtype/ ) {
					$interfaceTable{$intf}{ifSpeed} = convertIfSpeed($interfaceTable{$intf}{ifSpeed});

					if ( $interfaceTable{$intf}{totalUtil} == -1 ) { $interfaceTable{$intf}{totalUtil} = "N/A"; }
					rowStart;
					printCell("$interfaceTable{$intf}{intString}");
					if ( $interfaceTable{$intf}{ipAdEntAddr} ne "" and $interfaceTable{$intf}{ipAdEntNetMask} ne "" ) {
						printCell("$interfaceTable{$intf}{ipAdEntAddr}<br>$interfaceTable{$intf}{ipAdEntNetMask}<br><a href=\"$this_script?file=$conf&amp;type=find&amp;find=$interfaceTable{$intf}{ipSubnet}\">$interfaceTable{$intf}{ipSubnet}</a>");
					}
					else {
						printCell("&nbsp");
					}
					$tmpurl = "$this_script?file=$conf&amp;node=$node&amp;type=graph&amp;graphtype=$graphtype&amp;glamount=$glamount&amp;glunits=$glunits&amp;intf=$intf";
					$intString="<a href=\"$tmpurl\" target=ViewWindow onMouseOver=\"window.status='Drill into $interfaceTable{$intf}{ifDescr}.';return true\" onClick=\"viewdoc('$tmpurl',$win_width,$win_height)\">";

					printCell("<a href=\"$this_script?file=$conf&amp;type=find&amp;find=$interfaceTable{$intf}{Description}\">$interfaceTable{$intf}{Description}</a>");
					printCell("$interfaceTable{$intf}{ifAdminStatus}",$interfaceTable{$intf}{adminCellColor},1,"center");
					printCell("$interfaceTable{$intf}{ifOperStatus}",$interfaceTable{$intf}{operCellColor},1,"center");
					printCell("$interfaceTable{$intf}{operAvailability}",$interfaceTable{$intf}{availCellColor},1,"center");
					printCell("$interfaceTable{$intf}{totalUtil}",$interfaceTable{$intf}{totalCellColor},1,"center");
					printCell("$intString<img border=\"0\" alt=\"Device Port\" src=\"$this_script?file=$conf&amp;type=drawgraph&amp;node=$node&amp;graph=$graphtype&amp;glamount=$glamount&amp;glunits=$glunits&amp;start=0&amp;end=0&amp;width=$graph_width&amp;height=$graph_height&amp;title=short&amp;intf=$interfaceTable{$intf}{ifIndex}\"></a>");
					rowEnd;
				}
			} # foreach loop
		}
		elsif ( $NMIS::systemTable{nodeModel} =~ /Catalyst6000|Catalyst5/i ) {
			cssPrintHeadRow("Interface Table","menubar",7);
			print "			<tr>";
			print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=port&amp;sort1=ifDescr&amp;sort2=$sort1\">Name</a></td>";
			print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=port&amp;sort1=Description&amp;sort2=$sort1\">Description</a></td>";
			print "<td class=\"menubar\">AdminStat</td>";
			print "<td class=\"menubar\">OperStat</td>";
			print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=port&amp;sort1=operAvailability&amp;sort2=$sort1\">Int. Avail.</a></td>";
			print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=port&amp;sort1=totalUtil&amp;sort2=$sort1\">Util. 6hrs</a></td>";
			print <<EO_HTML;
			<td class="menubar">Graph
			<select name="graphtype" size="1" length="30" onChange="JavaScript:document.graph.submit()">
   			<option value="$graphtype">$graphtype</option>
			<option value="util">util</option>
			<option value="autil">autil</option>
			<option value="bits">bits</option>
			<option value="abits">abits</option>
			<option value="pkts">pkts</option>
			</select>
			</td></tr>
EO_HTML

			# So now I have a hash of interface utilsation!!!!
			foreach $intf ( sort alpha ( keys %interfaceTable ) ) {
				if ( $interfaceTable{$intf}{collect} eq "true"	) {
					$interfaceTable{$intf}{ifSpeed} = convertIfSpeed($interfaceTable{$intf}{ifSpeed});
					$interfaceTable{$intf}{portAdminSpeed} = convertIfSpeed($interfaceTable{$intf}{portAdminSpeed});
					if ( $interfaceTable{$intf}{totalUtil} == -1 ) { $interfaceTable{$intf}{totalUtil} = "N/A"; }
					rowStart;
					$tmpurl = "$this_script?file=$conf&amp;node=$node&amp;type=graph&amp;graphtype=$NMIS::config{portstats}&amp;glamount=$glamount&amp;glunits=$glunits&amp;intf=$intf";
					$intString="<a href=\"$tmpurl\" target=ViewWindow onMouseOver=\"window.status='Drill into $interfaceTable{$intf}{ifDescr}.';return true\" onClick=\"viewdoc('$tmpurl',$win_width,$win_height)\">";

					printCell("$interfaceTable{$intf}{intString}");
					printCell("<a href=\"$this_script?file=$conf&amp;type=find&amp;find=$interfaceTable{$intf}{Description}\">$interfaceTable{$intf}{Description}</a>");
					printCell("$interfaceTable{$intf}{ifAdminStatus}",$interfaceTable{$intf}{adminCellColor},1,"center");
					printCell("$interfaceTable{$intf}{ifOperStatus}",$interfaceTable{$intf}{operCellColor},1,"center");
					printCell("$interfaceTable{$intf}{operAvailability}",$interfaceTable{$intf}{availCellColor},1,"center");
					printCell("$interfaceTable{$intf}{totalUtil}",$interfaceTable{$intf}{totalCellColor},1,"center");
					printCell("$intString<img border=\"0\" alt=\"Device Port\" src=\"$this_script?file=$conf&amp;type=drawgraph&amp;node=$node&amp;graph=$NMIS::config{portstats}&amp;glamount=$glamount&amp;glunits=$glunits&amp;start=0&amp;end=0&amp;width=550&amp;height=40&amp;title=short&amp;intf=$interfaceTable{$intf}{ifIndex}\"></a>");
					rowEnd;
				}
			} # foreach loop
	 	}
		print <<EO_HTML;
		<input type="hidden" name="file" value="$conf">
		<input type="hidden" name="type" value="port">
		<input type="hidden" name="node" value="$node">
		<input type="hidden" name="glamount" value="$glamount">
		<input type="hidden" name="glunits" value="$glunits">
		<input type="hidden" name="gsamount" value="$gsamount">
		<input type="hidden" name="gsunits" value="$gsunits">
		</form>
EO_HTML
 	}
	else  {
		printHeadRow("No Interface Table Information Available","#FFFFFF",20);
	}

	tableEnd;
	cellEnd;
	rowEnd;
	print comment("End typePort");
	print Tr(td({class=>'white'}, &do_footer));

	tableEnd;
	pageEnd;

} # typePort


# display PVC port stats
sub typePVC {
 	my $port;
 	my $reportStats;
 	my @tmparray;
	my $ifLastChange;
	my $tmpurl;
	my %interfaceTable;
	my %util;
	my $seen;
	my $int_desc;
	my %pvcTable;
	# verify access to this command/tool bar/button
	#
	if ( $auth->Require ) {
		# CheckAccess will throw up a web page and stop if access is not allowed
		# $auth->CheckAccess($user, "") or die "Attempted unauthorized access";
		if ( ! $user->user ) {
			do_force_login("Authentication is required to access this function. Please login.");
			exit 0;
		}
	}

	if ( ! defined $sort1 ) { $sort1 = "totalUtil" }
	if ( ! defined $sort2 ) { $sort2 = "intString" }

	pageStart("Information about $node","true",\%headeropts);
	cssTableStart;
	&nmisMenuSmall;
	$NMIS::userMenu && &nmisMenuBar;
	$datestamp = returnDateStamp;

#    cssHeaderBar("Information for $node at $datestamp","grey");

	# Get the System info from the file and whack it into the hash
	loadSystemFile($node);

	if ( ! $user->InGroup($NMIS::nodeTable{$node}{group}) ) {
		cssHeaderBar("Not Authorized to view health statistics on node '$node' in group '$NMIS::nodeTable{$node}	{group}'.","grey");
		pageEnd;
		return 0;
	}

	%interfaceTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-interface.dat","ifIndex","\t");
	cssHeaderBar("Information for $node at $datestamp","grey");
	$NMIS::userMenu && displaySystemHeader($node);

	print <<EO_HTML;
<tr>
	<td class="white">
      		<table class="white" summary="Display">
EO_HTML

	# we may have pvc on primary ports too !
	if ( -e "$NMIS::config{'<nmis_var>'}/$node-pvc.dat" ) {
		%pvcTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-pvc.dat","subifDescr","\t");
	}

	if ( $NMIS::systemTable{nodeModel} =~ /router/i and %pvcTable ) { # router with frame ports only and valid pvcTable
		# Extract the interface statics and summaries for display in a second.
		foreach $intf (keys %interfaceTable ) {
			if ( $interfaceTable{$intf}{ifType} =~ /framerelay/i 
				and $interfaceTable{$intf}{collect} eq "true"
				and exists $pvcTable{lc($interfaceTable{$intf}{ifDescr})}
				) {

				# Set the standard interface name
	 			$tmpifDescr = convertIfName($interfaceTable{$intf}{ifDescr});

				# Set the cell color to reflect the interface status
				# so if admin = down then oper irrelevent
				if ( 	( $interfaceTable{$intf}{ifAdminStatus} eq "down" ) ||
					( $interfaceTable{$intf}{ifAdminStatus} eq "testing" ) ||
					( $interfaceTable{$intf}{ifAdminStatus} eq "null" )
					) {
					$adminCellColor="#ffffff";
					$operCellColor="#ffffff";
					$operAvailability = "N/A";
					$availCellColor="#ffffff";
					$totalUtil = "N/A";
					$totalCellColor="#ffffff";
					$lastCellColor = "#ffffff";
					$intString="$interfaceTable{$intf}{ifDescr}";
				}
				else {
					# admin up
					$tmpurl = "$this_script?file=$conf&amp;node=$node&amp;type=graph&amp;graphtype=$NMIS::config{portstats}&amp;glamount=$glamount&amp;glunits=$glunits&amp;intf=$intf";
					$intString="<a href=\"$tmpurl\" target=ViewWindow onMouseOver=\"window.status='Drill into $interfaceTable{$intf}{ifDescr}.';return true\" onClick=\"viewdoc('$tmpurl',$win_width,$win_height)\">$interfaceTable{$intf}{ifDescr}</a>";

					$adminCellColor="#00ff00";

					# need to add interface details if set in config switch
					### AS 17 Mar 02 - Request James Norris, Optionally include interface description in messages.
					if ( defined $interfaceTable{$intf}{Description}
						and $interfaceTable{$intf}{Description} ne "null"
						and $NMIS::config{send_description} eq "true"
					) {
						$int_desc = " description=$interfaceTable{$intf}{Description}";
					}

					my $event_status = eventExist($node,"Interface Down","interface=$interfaceTable{$intf}{ifDescr}$int_desc");
					if (	( $event_status eq "true" ) &&
						( $interfaceTable{$intf}{ifOperStatus} =~ /up|ok/ )
					) {
						# Red for down
						$operCellColor = "#ff0000";
						$interfaceTable{$intf}{ifOperStatus} = "down";
					}
					elsif (	( $event_status eq "false" ) &&
						( $interfaceTable{$intf}{ifOperStatus} =~ /up|ok/ )
					) {
						# Green for up
						$operCellColor = "#00ff00";
						$interfaceTable{$intf}{ifOperStatus} = "up";
					}
					elsif ( $interfaceTable{$intf}{ifOperStatus} eq "down" ) {
						# Red for down
						$operCellColor = "#ff0000";
					}
					elsif ( $interfaceTable{$intf}{ifOperStatus} eq "dormant" ) {
						# Red for down
						$operCellColor = "#ffff00";
					}
					else { $operCellColor = "#ffffff"; }

					$lastCellColor = "#ffffff";

					# Get the link availability from the local node!!!
		    		%util = summaryStats(node => $node,type => "util",start => "-6 hours",end => time,ifDescr => $interfaceTable{$intf}{ifDescr},speed => $interfaceTable{$intf}{ifSpeed});
					$operAvailability = $util{availability};
					$totalUtil = $util{totalUtil};

					$availCellColor = colorHighGood($operAvailability);
			       	$totalCellColor = colorLowGood($totalUtil);

					if ( $interfaceTable{$intf}{ifOperStatus} eq "dormant" )  {
						$operAvailability = "N/A" ;
						$availCellColor = "#FFFFFF";
						$operCellColor = "#ffff00";
					}
				}
				# save for printing
				$interfaceTable{$intf}{totalUtil}=$totalUtil;
				$interfaceTable{$intf}{operAvailability}=$operAvailability;
				$interfaceTable{$intf}{totalCellColor}=$totalCellColor;
				$interfaceTable{$intf}{availCellColor}=$availCellColor;
				$interfaceTable{$intf}{operCellColor}=$operCellColor;
				$interfaceTable{$intf}{lastCellColor}=$lastCellColor;
				$interfaceTable{$intf}{adminCellColor}=$adminCellColor;
				$interfaceTable{$intf}{intString}=$intString;
				$interfaceTable{$intf}{pvc}=$pvcTable{lc($interfaceTable{$intf}{ifDescr})}{pvc};
				$interfaceTable{$intf}{cir}=convertLineRate($pvcTable{lc($interfaceTable{$intf}{ifDescr})}{CIR});
				$interfaceTable{$intf}{eir}=convertLineRate($pvcTable{lc($interfaceTable{$intf}{ifDescr})}{EIR});
				$seen = 1;
			} # if frame
		} # foreach intf

		if ( $seen) {	# quick flag as to any frame sub-intf found or not
			cssPrintHeadRow("PVC Table","menubar",12);
			print "			<tr>";
			print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=ifDescr&amp;sort2=$sort1\">Name</a></td>";
			print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=ipAdEntAddr&amp;sort2=$sort1\">IP</a></td>";
			print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=Description&amp;sort2=$sort1\">Description</a></td>";
			print "<td class=\"menubar\">PVC</td>";
			print "<td class=\"menubar\">CIR</td>";
			print "<td class=\"menubar\">EIR</td>";
			print "<td class=\"menubar\">PIR</td>";
			print "<td class=\"menubar\">AdminStat</td>";
			print "<td class=\"menubar\">OperStat</td>";
			print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=operAvailability&amp;sort2=$sort1\">Int. Avail.</a></td>";
			print "<td class=\"menubar\"><a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary&amp;sort1=totalUtil&amp;sort2=$sort1\">Util. 6hrs</a></td>";
			print "<td class=\"menubar\">PVC Graph</td>";
			print "</tr>\n";

			# So now I have a hash of interface utilsation!!!!
			# New sort method, create a hash of keys data = $intf which are 
			# what to sort on, then alpha sort the keys and map the $intf 
			# back to the data.
			foreach $intf ( sort sort2 ( keys %interfaceTable ) ) {
				# controls whether or not we see non collected interfaces
				if ( $interfaceTable{$intf}{collect} eq "true"
					and $interfaceTable{$intf}{ifType} =~ /framerelay/i
					and exists $pvcTable{lc($interfaceTable{$intf}{ifDescr})}
					) {

					$interfaceTable{$intf}{ifSpeed} = convertLineRate($interfaceTable{$intf}{ifSpeed});
					if ( $interfaceTable{$intf}{totalUtil} == -1 ) { $interfaceTable{$intf}{totalUtil} = "N/A"; }
					rowStart;
					printCell("$interfaceTable{$intf}{intString}");
					if ( $interfaceTable{$intf}{ipAdEntAddr} ne "" and $interfaceTable{$intf}{ipAdEntNetMask} ne "" ) {
						printCell("$interfaceTable{$intf}{ipAdEntAddr}<br>$interfaceTable{$intf}{ipAdEntNetMask}<br><a href=\"$this_script?file=$conf&amp;type=find&amp;find=$interfaceTable{$intf}{ipSubnet}\">$interfaceTable{$intf}{ipSubnet}</a>");
					}
					else {
						printCell("");
					}
					$tmpurl = "$this_script?file=$conf&amp;node=$node&amp;type=graph&amp;graphtype=pvc&amp;glamount=$glamount&amp;glunits=$glunits&amp;intf=$intf";

					printCell("<a href=\"$this_script?file=$conf&amp;type=find&amp;find=$interfaceTable{$intf}{Description}\">$interfaceTable{$intf}{Description}</a>");
					printCell("$interfaceTable{$intf}{pvc}",$interfaceTable{$intf}{adminCellColor},1,"center");
					printCell("$interfaceTable{$intf}{cir}",$interfaceTable{$intf}{adminCellColor},1,"center");
					printCell("$interfaceTable{$intf}{eir}",$interfaceTable{$intf}{adminCellColor},1,"center");
					printCell("$interfaceTable{$intf}{ifSpeed}",$interfaceTable{$intf}{adminCellColor},1,"center");
					printCell("$interfaceTable{$intf}{ifAdminStatus}",$interfaceTable{$intf}{adminCellColor},1,"center");
					printCell("$interfaceTable{$intf}{ifOperStatus}",$interfaceTable{$intf}{operCellColor},1,"center");
					printCell("$interfaceTable{$intf}{operAvailability}",$interfaceTable{$intf}{availCellColor},1,"center");
					printCell("$interfaceTable{$intf}{totalUtil}",$interfaceTable{$intf}{totalCellColor},1,"center");
					printCell("<a href=\"$tmpurl\" ><img border=\"0\" alt=\"Device Port\" src=\"$this_script?file=$conf&amp;type=drawgraph&amp;node=$node&amp;graph=pvc&amp;glamount=$glamount&amp;glunits=$glunits&amp;start=0&amp;end=0&amp;width=500&amp;height=46&amp;title=short&amp;intf=$interfaceTable{$intf}{ifIndex}\"></a>");
					rowEnd;
				}
			} # foreach loop
		}
		else  {
			printHeadRow("No PVC Table Information Available","#FFFFFF",20);
		}
	} # if router
	else  {
		printHeadRow("No PVC Table Information Available","#FFFFFF",20);
	}

	tableEnd;
	cellEnd;
	rowEnd;

	rowEnd;
	tableEnd;
	pageEnd;

} # typePVC


sub typeFind {
	my $intHash;
	my $counter;
	my $tmpurl;

	# verify access to this command/tool bar/button
	#
	if ( $auth->Require ) {
		# CheckAccess will throw up a web page and stop if access is not allowed
		$auth->CheckAccess($user, "find") or die "Attempted unauthorized access";
	}

	pageStart("Find an Interface","false",\%headeropts);
	cssTableStart;
	print start_Tr(),
		start_td;
	&do_dash_banner($auth->Require, $user->user);
	print end_td(),
		end_Tr;	
	&nmisMenuSmall;
	$NMIS::userMenu && &nmisMenuBar;

	if ( $find eq "" ) {
		cssHeaderBar("Find an Interface","grey");
		&findMenu;
	}
	else {
		cssHeaderBar("Finding Interfaces with \"$find\"","grey");
		&findMenu;
	 	&findNodes;
	}
	rowEnd;
	tableEnd;
	pageEnd;

	sub findMenu {
		rowStart;
		cellStart("white",1);
		cssTableStart("menu");
			rowStart;
			print "<form ACTION=\"$this_script\">\n";
			printCell("<input type=submit value=\"GO\">");
			printCell("Find String <input name=find value=\"$find\">","#FFFFFF",6);
			print "</form>\n";
			rowEnd;
		tableEnd;
		cellEnd;
		rowEnd;
	}

	sub findNodes {

		# Remove nasty bad characters from $find
		$find =~ s/\(.*\)|\(|\)|#|\*//g;

		loadInterfaceInfo;

		rowStart;

		cellStart("white",1);
		cssTableStart("white");
		rowStart;
		printHeadCell("Node");
		printHeadCell("Name");
		printHeadCell("IP Address");
		printHeadCell("Subnet Mask");
		printHeadCell("Subnet");
		printHeadCell("Description");
		printHeadCell("ifIndex");
		printHeadCell("Collect");
		printHeadCell("Type");
		printHeadCell("Speed");
		printHeadCell("Admin Status");
		printHeadCell("Oper Status");
		printHeadCell("portDuplex");
		printHeadCell("PortFast");
		printHeadCell("VLAN");
		rowEnd;

		$counter = 0;
		# Get each of the nodes info in a HASH for playing with
		foreach $intHash (sort(keys(%NMIS::interfaceInfo))) {

			#$NMIS::interfaceInfo{$intHash}{Description} =~ s/\(.*\)|\(|\)|#|\*//g;

			if ( 	$NMIS::interfaceInfo{$intHash}{node} =~ /$find/i or
					$NMIS::interfaceInfo{$intHash}{Description} =~ /$find/i or
					$NMIS::interfaceInfo{$intHash}{ifDescr} =~ /$find/i or
					$NMIS::interfaceInfo{$intHash}{ifType} =~ /$find/i or
					$NMIS::interfaceInfo{$intHash}{ipAdEntAddr} =~ /$find/i or
					$NMIS::interfaceInfo{$intHash}{ipAdEntNetMask} =~ /$find/i or
					$NMIS::interfaceInfo{$intHash}{ipSubnet} =~ /$find/i or
					$NMIS::interfaceInfo{$intHash}{vlanPortVlan} =~ /$find/
			) {
				++$counter;

				$NMIS::interfaceInfo{$intHash}{ifSpeed} = convertIfSpeed($NMIS::interfaceInfo{$intHash}{ifSpeed});

				rowStart;
				printCell("<a href=\"$this_script?file=$conf&amp;type=summary&amp;node=$NMIS::interfaceInfo{$intHash}{node}\">$NMIS::interfaceInfo{$intHash}{node}</a>");

				### AS 16 July - Fixed bad link for interfaces
				if ( $NMIS::interfaceInfo{$intHash}{collect} eq "true" ) {
					$tmpurl="$this_script?file=$conf&amp;node=$NMIS::interfaceInfo{$intHash}{node}&amp;type=graph&amp;graphtype=$NMIS::config{portstats}&amp;glamount=$glamount&amp;glunits=$glunits&amp;intf=$NMIS::interfaceInfo{$intHash}{ifIndex}";
					#printCell("<a href=\"$this_script?file=$conf&amp;type=interface&amp;node=$NMIS::interfaceInfo{$intHash}{node}&amp;interface=$NMIS::interfaceInfo{$intHash}{ifDescr}\"></a>","#FFFFFF",1,"center");
					printCell("<a href=\"$tmpurl\" target=ViewWindow onMouseOver=\"window.status='Drill into $NMIS::interfaceInfo{$intHash}{ifDescr}.';return true\" onClick=\"viewdoc('$tmpurl',$win_width,$win_height)\">$NMIS::interfaceInfo{$intHash}{ifDescr}</a>","#FFFFFF",1,"center");
				}
				else { 	printCell("$NMIS::interfaceInfo{$intHash}{ifDescr}","#FFFFFF",1,"center"); }

				printCell("$NMIS::interfaceInfo{$intHash}{ipAdEntAddr}");
				printCell("$NMIS::interfaceInfo{$intHash}{ipAdEntNetMask}");
				printCell("<a href=\"$this_script?file=$conf&amp;type=find&amp;find=$NMIS::interfaceInfo{$intHash}{ipSubnet}\">$NMIS::interfaceInfo{$intHash}{ipSubnet}</a>");
				printCell("<a href=\"$this_script?file=$conf&amp;type=find&amp;find=$NMIS::interfaceInfo{$intHash}{Description}\">$NMIS::interfaceInfo{$intHash}{Description}</a>");
				printCell("$NMIS::interfaceInfo{$intHash}{ifIndex}");
				printCell("$NMIS::interfaceInfo{$intHash}{collect}");
				printCell("$NMIS::interfaceInfo{$intHash}{ifType}");
				printCell("$NMIS::interfaceInfo{$intHash}{ifSpeed}","#FFFFFF",1,"right");
				if ( $NMIS::interfaceInfo{$intHash}{ifAdminStatus} eq "up" ) {
					printCell("$NMIS::interfaceInfo{$intHash}{ifAdminStatus}","#00FF00",1,"center");
				}
				else {	printCell("$NMIS::interfaceInfo{$intHash}{ifAdminStatus}","#FFFFFF",1,"center"); }
				if ( $NMIS::interfaceInfo{$intHash}{ifOperStatus} =~ /up|ok/ ) {
					printCell("$NMIS::interfaceInfo{$intHash}{ifOperStatus}","#00FF00",1,"center");
				}
				else {	printCell("$NMIS::interfaceInfo{$intHash}{ifOperStatus}","#FFFFFF",1,"center"); }
				printCell("$NMIS::interfaceInfo{$intHash}{portDuplex}","#FFFFFF",1,"center");
				printCell("$NMIS::interfaceInfo{$intHash}{portSpantreeFastStart}");
				printCell("<a href=\"$this_script?file=$conf&amp;type=find&amp;find=$NMIS::interfaceInfo{$intHash}{vlanPortVlan}\">$NMIS::interfaceInfo{$intHash}{vlanPortVlan}</a>","#FFFFFF",1,"center");
				rowEnd;
			}
		}

		tableEnd;
		cellEnd;

		paragraph;
		printHeadRow("$counter matches of \"$find\" found in interface list","#FFFFFF",1);
	}
} # typeFind

sub typeDNS {
	my $intHash;
	my $shortInt;
	my $tmpurl;
	my @in_addr_arpa;
	my $node;
	my $location;
	my %location_data;

 	# verify access to this command/tool bar/button
	#
	if ( $auth->Require ) {
		# CheckAccess will throw up a web page and stop if access is not allowed
		$auth->CheckAccess($user, "dns") or die "Attempted unauthorized access";
	}

	pageStart("Host and DNS Records","false",\%headeropts);
	cssTableStart;
 	print start_Tr(),
		start_td;
	&do_dash_banner($auth->Require, $user->user);
	print end_td(),
		end_Tr;
	&nmisMenuSmall;
	&nmisMenuBar;

	#Load the Interface Information file
	loadInterfaceInfo;
	#Load the location data.
	%location_data = loadCSV($NMIS::config{Locations_Table},$NMIS::config{Locations_Key},"\t");

		rowStart;
		cellStart("white",1);
		cssTableStart("white");

		# Host Records
		rowStart;
		printHeadCell("Host Records");
		rowEnd;
		rowStart;
		print	"<td><pre>\n";
		foreach $intHash (sort(keys(%NMIS::interfaceInfo))) {
			next unless $user->InGroup($NMIS::nodeTable{$NMIS::interfaceInfo{$intHash}{node}}{group});

	       	if ( 	$NMIS::interfaceInfo{$intHash}{ipAdEntAddr} ne "" and
	       			$NMIS::interfaceInfo{$intHash}{ipAdEntAddr} ne "0.0.0.0" and
	       			$NMIS::interfaceInfo{$intHash}{ipAdEntAddr} !~ /^127/
			) {
				$NMIS::interfaceInfo{$intHash}{ifSpeed} = convertIfSpeed($NMIS::interfaceInfo{$intHash}{ifSpeed});
				$shortInt = shortInterface($NMIS::interfaceInfo{$intHash}{ifDescr});
				if ( $NMIS::interfaceInfo{$intHash}{node} =~ /\d+\.\d+\.\d+\.\d+/ 
					and $NMIS::interfaceInfo{$intHash}{sysName} ne ""
				) {
					$NMIS::interfaceInfo{$intHash}{node} = $NMIS::interfaceInfo{$intHash}{sysName};
				}
				elsif ( $NMIS::interfaceInfo{$intHash}{sysName} ne "" ) {
					$NMIS::interfaceInfo{$intHash}{node} = $NMIS::interfaceInfo{$intHash}{sysName};
				}
				print
				"$NMIS::interfaceInfo{$intHash}{ipAdEntAddr}\t\t".
				"$NMIS::interfaceInfo{$intHash}{node}--$shortInt\t".
				"#\"".
				"$NMIS::interfaceInfo{$intHash}{Description}\t".
				"$NMIS::interfaceInfo{$intHash}{ifDescr}\t".
				"$NMIS::interfaceInfo{$intHash}{ipSubnet}".
				"$NMIS::interfaceInfo{$intHash}{ipAdEntNetMask}\t".
				"$NMIS::interfaceInfo{$intHash}{ifSpeed}\t".
				"$NMIS::interfaceInfo{$intHash}{ifType}".
				"\"\n";
			}
		} # FOR
		print "</pre></td>\n";
		rowEnd;

		# DNS Records
		rowStart;
		printHeadCell("DNS Records");
		rowEnd;
		rowStart;
		print	"<td><pre>\n";
	       	foreach $intHash (sort(keys(%NMIS::interfaceInfo))) {
				next unless $user->InGroup($NMIS::nodeTable{$NMIS::interfaceInfo{$intHash}{node}}{group});
	       		if ( 	$NMIS::interfaceInfo{$intHash}{ipAdEntAddr} ne "" and
	       			$NMIS::interfaceInfo{$intHash}{ipAdEntAddr} ne "0.0.0.0" and
	       			$NMIS::interfaceInfo{$intHash}{ipAdEntAddr} !~ /^127/
	       		) {
				$shortInt = shortInterface($NMIS::interfaceInfo{$intHash}{ifDescr});
				print
				"$NMIS::interfaceInfo{$intHash}{node}--$shortInt\t\t".
				"IN\tA\t".
				"$NMIS::interfaceInfo{$intHash}{ipAdEntAddr}\n".
				"$NMIS::interfaceInfo{$intHash}{node}--$shortInt\t\t".
				"IN\tTXT\t".
				"\"$NMIS::interfaceInfo{$intHash}{Description} ".
				"$NMIS::interfaceInfo{$intHash}{ifDescr} ".
				"$NMIS::interfaceInfo{$intHash}{ipSubnet} ".
				"$NMIS::interfaceInfo{$intHash}{ipAdEntNetMask} ".
				"$NMIS::interfaceInfo{$intHash}{ifSpeed} ".
				"$NMIS::interfaceInfo{$intHash}{ifType}".
				"\"\n";
			}
		} # FOR
		print "</pre></td>\n";
		rowEnd;
		#0.19.64.10.in-addr.arpa.       IN      PTR     network.mosp.cisco.com.
		#1.19.64.10.in-addr.arpa.       IN      PTR     gw.mosp.cisco.com.

		# in-addr.arpa. Records
		rowStart;
		printHeadCell("in-addr.arpa. DNS Records");
		rowEnd;
		rowStart;
		print	"<td><pre>\n";
	       	foreach $intHash (sort(keys(%NMIS::interfaceInfo))) {
				next unless $user->InGroup($NMIS::nodeTable{$NMIS::interfaceInfo{$intHash}{node}}{group});	       		
				if ( 	$NMIS::interfaceInfo{$intHash}{ipAdEntAddr} ne "" and
	       			$NMIS::interfaceInfo{$intHash}{ipAdEntAddr} ne "0.0.0.0" and
	       			$NMIS::interfaceInfo{$intHash}{ipAdEntAddr} !~ /^127/
	       		) {
				$shortInt = shortInterface($NMIS::interfaceInfo{$intHash}{ifDescr});
				@in_addr_arpa = split (/\./,$NMIS::interfaceInfo{$intHash}{ipAdEntAddr});
				print
				"$in_addr_arpa[3].$in_addr_arpa[2].$in_addr_arpa[1].$in_addr_arpa[0].in-addr.arpa.\t".
				"IN\tPTR\t".
				"$NMIS::interfaceInfo{$intHash}{node}--$shortInt.$NMIS::config{domain_name}".
				"\n".
				"$in_addr_arpa[3].$in_addr_arpa[2].$in_addr_arpa[1].$in_addr_arpa[0].in-addr.arpa.\t".
				"IN\tA\t".
				"$NMIS::interfaceInfo{$intHash}{ipAdEntNetMask}".
				"\n";
			}
		} # FOR
		print "</pre></td>\n";
		rowEnd;
# Extract from RFC1876 A Means for Expressing Location Information in the Domain Name System
# This RFC specifies creates DNS LOC (location) records for visual traceroutes
#--snip--
#3. Master File Format
#   The LOC record is expressed in a master file in the following format:
#   <owner> <TTL> <class> LOC ( d1 [m1 [s1]] {"N"|"S"} d2 [m2 [s2]]
#                               {"E"|"W"} alt["m"] [siz["m"] [hp["m"]
#                               [vp["m"]]]] )
#   (The parentheses are used for multi-line data as specified in [RFC1035] section 5.1.)
#   where:
#       d1:     [0 .. 90]            (degrees latitude)
#       d2:     [0 .. 180]           (degrees longitude)
#       m1, m2: [0 .. 59]            (minutes latitude/longitude)
#       s1, s2: [0 .. 59.999]        (seconds latitude/longitude)
#       alt:    [-100000.00 .. 42849672.95] BY .01 (altitude in meters)
#       siz, hp, vp: [0 .. 90000000.00] (size/precision in meters)
#
#   If omitted, minutes and seconds default to zero, size defaults to 1m,
#   horizontal precision defaults to 10000m, and vertical precision
#   defaults to 10m.  These defaults are chosen to represent typical
#   ZIP/postal code area sizes, since it is often easy to find
#   approximate geographical location by ZIP/postal code.
#
#4. Example Data
#;;;
#;;; note that these data would not all appear in one zone file
#;;;
#;; network LOC RR derived from ZIP data.  note use of precision defaults
#cambridge-net.kei.com.        LOC   42 21 54 N 71 06 18 W -24m 30m
#;; higher-precision host LOC RR.  note use of vertical precision default
#loiosh.kei.com.               LOC   42 21 43.952 N 71 5 6.344 W -24m 1m 200m
#pipex.net.                    LOC   52 14 05 N 00 08 50 E 10m
#curtin.edu.au.                LOC   32 7 19 S 116 2 25 E 10m
#rwy04L.logan-airport.boston.  LOC   42 21 28.764 N 71 00 51.617 W -44m 2000m
#--end snip--
		# DNS LOC Records
		rowStart;
		printHeadCell("DNS LOC Records");
		rowEnd;
		rowStart;
		print	"<td><pre>\n";
	       	foreach $intHash (sort(keys(%NMIS::interfaceInfo))) {
				next unless $user->InGroup($NMIS::nodeTable{$NMIS::interfaceInfo{$intHash}{node}}{group});
	       		if ( $NMIS::interfaceInfo{$intHash}{ipAdEntAddr} ne "" ) {
	       			if ( $node ne $NMIS::interfaceInfo{$intHash}{node} ) {
		       			$node = $NMIS::interfaceInfo{$intHash}{node};
		       			loadSystemFile($node);
		       			$location = lc($NMIS::systemTable{sysLocation});
					if ( 	$location_data{$location}{Latitude} ne "" and
						$location_data{$location}{Longitude} ne "" and
						$location_data{$location}{Altitude} ne ""
					) {
						print
						"$NMIS::interfaceInfo{$intHash}{node}\t\t\t".
						"IN\tLOC\t".
						# Latitude from locations table
						"$location_data{$location}{Latitude} ".
						# Longitude from locations table
						"$location_data{$location}{Longitude} ".
						# Altidude from locations table
						"$location_data{$location}{Altitude} ".
						# Standard precision setting
						"1.00m 10000m 100m".
						"\n";
					}
		       		}
				if ( 	$location_data{$location}{Latitude} ne "" and
					$location_data{$location}{Longitude} ne "" and
					$location_data{$location}{Altitude} ne ""
				) {
					$shortInt = shortInterface($NMIS::interfaceInfo{$intHash}{ifDescr});
					print
					"$NMIS::interfaceInfo{$intHash}{node}--$shortInt\t\t".
					"IN\tLOC\t".
					# Latitude from locations table
					"$location_data{$location}{Latitude} ".
					# Longitude from locations table
					"$location_data{$location}{Longitude} ".
					# Altidude from locations table
					"$location_data{$location}{Altitude} ".
					# Standard precision setting
					"1.00m 10000m 100m".
					"\n";
				}
			}
		} # FOR
		print "</pre></td>\n";
		rowEnd;

		tableEnd;
		cellEnd;
		rowEnd;
	tableEnd;
	pageEnd;
} #typeDNS


### changed to allow multiple node select for adding outages.
sub typeOutage {
	my $intHash;
	my $counter;
	my $timeNow = time;
	my $start_seconds;
	my $error;
	my $stamp = returnDateStamp;

	 	
	# verify access to this command/tool bar/button
	#
	if ( $auth->Require ) {
		# CheckAccess will throw up a web page and stop if access is not allowed
		$auth->CheckAccess($user, "outages") or die "Attempted unauthorized access";
	}

	$start_seconds = parsedate("$start");

	pageStart("Scheduled Outages","false",\%headeropts);
	cssTableStart;
	print start_Tr(),
		start_td;
	&do_dash_banner($auth->Require, $user->user);
	print end_td(),
		end_Tr;	
	&nmisMenuSmall;
	&nmisMenuBar;

	if ( $outage eq "" or $outage eq "list" ) {
	    	cssHeaderBar("List the Outages @ $stamp","grey");
		&outageMenu;
		&outageList;
	}
	elsif ( $outage eq "add" ) {
	    cssHeaderBar("Adding an outage @ $stamp","grey");
		foreach $node ( @node_list ) {
 			next unless $user->InGroup($NMIS::nodeTable{$node}{group});
			$error = outageAdd($node,$start,$end,$change);
			next if $error eq "false";
		}
		$outage = "list";
		&outageMenu;
		if ( $error ne "false" ) {
			errorMessage($error,"#FFFF00",6);
		}
		&outageList;
	}
	elsif ( $outage eq "delete" ) {
	    	cssHeaderBar("Deleting an outage @ $stamp","grey");
		outageDelete($node,$start,$end,$change);
		$outage = "list";
		&outageMenu;
		&outageList;
	}
	rowEnd;
	tableEnd;
	pageEnd;

	sub outageMenu {
		# if end and start are blank set them to today!!!
		if ( $start eq "" or $start !~ / / ) { $start = returnDateStamp; }
		if ( $end eq "" or $end !~ / / ) { $end = returnDateStamp; }
		if ( $node ne "" and $outage eq "list" ) { $node = ""; }

		rowStart;
		cellStart("#FFFFFF",6);
		cssTableStart("white");

		rowStart;
		print "<form ACTION=\"$this_script\">\n";
		printCell("<input type=submit value=\"GO\">");
		cellStart;
		print "Action <select name=outage size=1>\n";
	        print "<option value=\"list\">list</option>\n";
	        print "<option value=\"add\">add</option>\n";
		print "</select>\n";
		cellEnd;

		cellStart;
		print "Node (multi-select)<br><select multiple name=node_list size=5>";
        print "		<option value=\"--LAN--\">----LAN----</option>\n";
	    foreach $node (sort ( keys (%NMIS::nodeTable) ) )  {
			next unless $user->InGroup($NMIS::nodeTable{$node}{group});
			if ( exists $NMIS::nodeTable{$node}{slave} or exists $NMIS::nodeTable{$node}{slave2}) { next; }
			if ( $NMIS::nodeTable{$node}{net} eq "lan" ) {
                print "<option value=\"$node\">$node</option>\n";
			}
		}
        print "<option value=\"--WAN--\">----WAN----</option>\n";
        foreach $node (sort ( keys (%NMIS::nodeTable) ) )  {
			next unless $user->InGroup($NMIS::nodeTable{$node}{group});
			if ( exists $NMIS::nodeTable{$node}{slave} or exists $NMIS::nodeTable{$node}{slave2}) { next; }	
			if ( $NMIS::nodeTable{$node}{net} eq "wan" ) {
                print "<option value=\"$node\">$node</option>\n";
			}
        }

		print "</select>";
		cellEnd;

		printCell("Start Date/Time <input name=start value=\"$start\">","#FFFFFF",1);
		printCell("End Date/Time <input name=end value=\"$end\">","#FFFFFF",1);
		printCell("Change Number <input name=change value=\"$change\">","#FFFFFF",1);

		print "</form>\n";
		rowEnd;

		tableEnd;
		cellEnd;
		rowEnd;
	}

	sub outageList {
		my $outage;
		my $current;
		my $startStamp;
		my $endStamp;
		my $color;

		outageLoad;

		rowStart;

		cellStart("white",6);
		cssTableStart("white");
		rowStart;
		printHeadCell("");
		printHeadCell("Node");
		printHeadCell("Start");
		printHeadCell("End");
		printHeadCell("Change");
		printHeadCell("Status");
		rowEnd;

		# Get each of the nodes info in a HASH for playing with
	       	foreach $outage (sort(keys(%NMIS::outageTable))) {
			next unless $user->InGroup($NMIS::nodeTable{$NMIS::outageTable{$outage}{node}}{group});
			if ( $NMIS::outageTable{$outage}{node} ne "" ) {
				$startStamp = returnDateStamp($NMIS::outageTable{$outage}{start});
				$endStamp = returnDateStamp($NMIS::outageTable{$outage}{end});
				$current = outageCheck($NMIS::outageTable{$outage}{node},time);

			  	if ( $current eq "true" ) {
					$color = "#00FF00";
					$current = "current";
				}
			  	elsif ( $current eq "pending" ) {
					$color = "#FFFF00";
				}
				else { $color = "#FFFFFF"; }

				rowStart;
				printCell(	"<a href=\"$this_script?file=$conf&amp;outage=delete".
							"&amp;node=$NMIS::outageTable{$outage}{node}".
							"&amp;start=$NMIS::outageTable{$outage}{start}".
							"&amp;end=$NMIS::outageTable{$outage}{end}&amp;".
							"change=$NMIS::outageTable{$outage}{change}\">Delete</a>"
							,$color);
				printCell("<a href=\"$this_script?file=$conf&amp;type=summary&amp;node=$NMIS::outageTable{$outage}{node}\">$NMIS::outageTable{$outage}{node}</a>",$color);
				printCell("$startStamp",$color);
				printCell("$endStamp",$color);
				printCell("$NMIS::outageTable{$outage}{change}",$color);
				printCell("$current",$color,1,"center");
				rowEnd;
			}
		}
		tableEnd;
		cellEnd;
	}
} # typeOutage

### ehg 16 sep 02 added Syslog and Syslog summary buttons

sub nmisMenuBar {
	my @output;
	print "<!-- nmisMenuBar begin -->\n";
 
	$tb = NMIS::Toolbar::new;
	$tb->SetLevel($user->privlevel);
	$tb->LoadButtons($NMIS::config{'<nmis_conf>'}."/toolset.csv");
	print &start_Tr,
		start_td({class=>"white"}),
		start_div({class=>"as"});
	print $tb->DisplayButtons("action");
	print &end_div;
	# display Table buttons if there are
	@output = $tb->DisplayButtons("table");
	if ( scalar @output ) {
		print start_div({class=>"as"}),
		"Tables -> ";
		print @output;
		print &end_div,
	}
	end_td,
	end_Tr;
	# display Plugin buttons if there are
	if (($NMIS::config{plugin_bar_status} eq "on") or ($plugins eq "on")) {
		@output = $tb->DisplayButtons("plugin");
		if ( scalar @output ) {
			print &start_Tr,
			start_td({class=>"white"}),
			start_div({class=>"as"});
			print @output;
			print &end_div,
			end_td,
			end_Tr;
		}
	}
	print "<!-- nmisMenuBar end -->\n";
}

sub nmisMenuSmall {

	#<td class="button"><a href="$this_script?file=$conf&amp;menu=small">Dash</a></td>
	#<td class="button"><a href="$this_script?file=$conf&amp;menu=large">Large Dash</a></td>
	#<td class="menugrey"><a href="$NMIS::config{'<url_base>'}/"><img alt=\"Help\" src=\"$NMIS::config{doc_icon}\" border=\"0\"></a>
	#<a href="$NMIS::config{help_file}#$type"><img alt=\"Help\" src=\"$NMIS::config{help_icon}\" border=\"0\"></a></td>

	# get localtime
	$time = &get_localtime;
	print "<!-- nmisMenuSmall begin -->\n";
	print <<EO_HTML;
<tr>
<td class="grey">
<form ACTION="$this_script">
<table class="menu1" summary="Display">
<tr>
	<td class="grey">$time</td>
	<td class="menugrey">
		<div class="asb">
          <a class="b" href="$this_script?file=$conf&amp;menu=small">Dash</a>
          <a class="b" href="$this_script?file=$conf&amp;menu=large">Large Dash</a>
          <a class="b" href="$NMIS::config{'<url_base>'}/">Doc</a>
          <a class="b" href="$NMIS::config{help_file}">Help</a>
		</div>
	</td>
	<td class="menugrey">
		Statistics Type
		<select name=type size=1>
          <option value="$type">$type</option>
          <option value="find">find</option>
          <option value="summary">summary</option>
          <option value="health">health</option>
          <option value="link">link</option>
          <option value="event">event</option>
		  <option value="port">port</option>
		</select>
	</td>
	<td class="menugrey">
		Node
		<select name=node size=1>
          <option value="$node">$node</option>
EO_HTML
	my ($i,$line,@nodedetails);

	print "<option value=\"--LAN--\">----LAN----</option>\n";

	foreach my $node (sort ( keys (%NMIS::nodeTable) ) )  {
		if ( exists $NMIS::nodeTable{$node}{slave} or exists $NMIS::nodeTable{$node}{slave2}) { next; }
		next unless $user->InGroup($NMIS::nodeTable{$node}{group});
		if ( $NMIS::nodeTable{$node}{net} eq "lan" ) {
			print "<option value=\"$node\">$node</option>\n";
		}
	}

	print "<option value=\"--WAN--\">----WAN----</option>\n";

	foreach my $node (sort ( keys (%NMIS::nodeTable) ) )  {
		if ( exists $NMIS::nodeTable{$node}{slave} or exists $NMIS::nodeTable{$node}{slave2}) { next; }
		next unless $user->InGroup($NMIS::nodeTable{$node}{group});
		if ( $NMIS::nodeTable{$node}{net} eq "wan" ) {
			print "          <option value=\"$node\">$node</option>\n";
		}
	}
	print "<option value=\"\"></option>\n";
	print <<EO_HTML;
	</select>
  	</td>
EO_HTML

	print <<EO_HTML;
	<td class="menugrey">
		Group
		<select name=group size=1>
		<option value="$group">$group</option>
EO_HTML

        foreach $node (sort ( keys (%NMIS::groupTable) ) )  {
				next unless $user->InGroup($node);
                print "          <option value=\"$node\">$node</option>\n";
        }
	print "          <option value=\"\"></option>\n";
	print <<EO_HTML;
	     	</select>
  	</td>
EO_HTML

	print <<EO_HTML;
	<td class="menugrey">Find <input type="text" size="20" name="find" value="$find"></td>
	<td class="menugrey"><input type=submit value="GO"></td>
	<td class="menugrey"><a href="http://www.sins.com.au/nmis">NMIS $NMIS::VERSION</a></td>
</tr>
</table>
</form>
</td>
</tr>
EO_HTML
	print "<!-- nmisMenuSmall end -->\n";

} # end nmisMenuSmall

sub nmisMenuLarge {

	my $group;
	my $span = 16;

	print "<!-- nmisMenuLarge begin -->\n";

	&nmisMenuSmall;
	$NMIS::userMenu && &nmisMenuBar;
	&nmisSummary;

	rowStart;
	cssCellStart("white",$span);
	cssTableStart("white");

	rowStart;
	cssPrintCell("grey","Node List and Status",$span);
	rowEnd;

    foreach $group (sort ( keys (%NMIS::groupTable) ) ) {

		next unless $user->InGroup($group);
		rowStart;
		cssPrintCell("grey","<A name=$group>$group Nodes</a>",$span);
		rowEnd;

		rowStart;
		cssCellStart("",$span);
#		cssTableStart("white");
		printHeadRow("Node,NMIS,Tools,Type,Net,Role,Group,Location,Outage,Status,Health,Reach,IntAvail,Response Time,Escalation,Last Update","");
		&printNodeType($group);
#		tableEnd;
		cellEnd;
		rowEnd;

	}
	tableEnd;
	cellEnd;
	rowEnd;
	print "<!-- nmisMenuLarge end -->\n";
} # end nmisMenuLarge

sub nmisGroupSummary {
	my $group = shift;
	my $tmpurl;

	my $span = 1;

	print "<!-- nmisGroupSummary begin -->\n";
	%summaryHash = &getGroupSummary($group);
	my %oldGroupSummary = &getGroupSummary($group,"-16 hours","-8 hours");
	my $overallStatus = overallNodeStatus($group);
	my $overallColor = eventColor($overallStatus);

	$oldGroupSummary{average}{metric_diff} = sprintf("%.3f",$summaryHash{average}{metric} - $oldGroupSummary{average}{metric});
	if ( $summaryHash{average}{metric} eq "N/A" ) {
		$summaryHash{average}{metric} = "Metric N/A";
		$oldGroupSummary{average}{metric_color} = "#aaaaaa";
		$summaryHash{average}{metric_icon} = "";
		$summaryHash{average}{metric_diff} = "was: $oldGroupSummary{average}{metric}";
	} else {
		if ( $oldGroupSummary{average}{metric_diff} <= -1 ) {
			$oldGroupSummary{average}{metric_color} = "red";
			$summaryHash{average}{metric_icon} = "<img alt=\"Down\" src=\"$NMIS::config{arrow_down_big}\" border=\"0\" width=\"11\" height=\"10\">";
		}
		elsif ( $oldGroupSummary{average}{metric_diff} < 0 ) {
			$oldGroupSummary{average}{metric_color} = "yellow";
			$summaryHash{average}{metric_icon} = "<img alt=\"Down\" src=\"$NMIS::config{arrow_down}\" border=\"0\" width=\"11\" height=\"10\">";
		}
		elsif ( $oldGroupSummary{average}{metric_diff} < 1 ) {
			$oldGroupSummary{average}{metric_color} = "#00FF00";
			$summaryHash{average}{metric_icon} = "<img alt=\"Up\" src=\"$NMIS::config{arrow_up}\" border=\"0\" width=\"11\" height=\"10\">";
		}
		elsif ( $oldGroupSummary{average}{metric_diff} >= 1 ) {
			$oldGroupSummary{average}{metric_color} = "#00FF00";
			$summaryHash{average}{metric_icon} = "<img alt=\"Up\" src=\"$NMIS::config{arrow_up_big}\" border=\"0\" width=\"11\" height=\"10\">";
		}
		$summaryHash{average}{metric_diff} = "was: $oldGroupSummary{average}{metric}<br>diff: $oldGroupSummary{average}{metric_diff}";
	}
	# Arrow Icons for all the bits!
	### AS 25 July 2002 - Fixing the N/A's when things are low.
	if ( $summaryHash{average}{reachable} =~ /N\/A|nan|NaN/ ) { $summaryHash{average}{reachable_icon} = "" }
	elsif ( $oldGroupSummary{average}{reachable} <= $summaryHash{average}{reachable} ) { $summaryHash{average}{reachable_icon} = "<img alt=\"Up\" src=\"$NMIS::config{arrow_up}\" border=\"0\" width=\"11\" height=\"10\">"; }
	else { $summaryHash{average}{reachable_icon} = "<img alt=\"Down\" src=\"$NMIS::config{arrow_down}\" border=\"0\" width=\"11\" height=\"10\">"; }

	if ( $summaryHash{average}{available} =~ /N\/A|nan|NaN/ ) { $summaryHash{average}{available_icon} = "" }
	elsif ( $oldGroupSummary{average}{available} <= $summaryHash{average}{available} ) { $summaryHash{average}{available_icon} = "<img alt=\"Up\" src=\"$NMIS::config{arrow_up}\" border=\"0\" width=\"11\" height=\"10\">"; }
	else { $summaryHash{average}{available_icon} = "<img alt=\"Down\" src=\"$NMIS::config{arrow_down}\" border=\"0\" width=\"11\" height=\"10\">"; }

	if ( $summaryHash{average}{health} =~ /N\/A|nan|NaN/ ) { $summaryHash{average}{health_icon} = "" }
	elsif ( $oldGroupSummary{average}{health} <= $summaryHash{average}{health} ) { $summaryHash{average}{health_icon} = "<img alt=\"Up\" src=\"$NMIS::config{arrow_up}\" border=\"0\" width=\"11\" height=\"10\">"; }
	else { $summaryHash{average}{health_icon} = "<img alt=\"Down\" src=\"$NMIS::config{arrow_down}\" border=\"0\" width=\"11\" height=\"10\">"; }

	### AS 10 June 2002 - Trent O'Callaghan trent.ocallaghan@wanews.com.au response time arrow changes
	if ( $summaryHash{average}{response} =~ /N\/A|nan|NaN/ ) { $summaryHash{average}{response_icon} = "" }
	elsif ( $oldGroupSummary{average}{response} < $summaryHash{average}{response} ) { $summaryHash{average}{response_icon} = "<img alt=\"Up\" src=\"$NMIS::config{arrow_up_red}\" border=\"0\" width=\"11\" height=\"10\">"; }
	else { $summaryHash{average}{response_icon} = "<img alt=\"Down\" src=\"$NMIS::config{arrow_down_green}\" border=\"0\" width=\"11\" height=\"10\">"; }

	if ( $summaryHash{average}{reachable} !~ /N\/A|nan|NaN/ ) {
		$summaryHash{average}{reachable_diff} = "was: $oldGroupSummary{average}{reachable} -> diff: ". sprintf("%.3f",$summaryHash{average}{reachable} - $oldGroupSummary{average}{reachable});
	} else { $summaryHash{average}{reachable_diff} = "N/A"; }

	if ( $summaryHash{average}{available} !~ /N\/A|nan|NaN/ ) {
		$summaryHash{average}{available_diff} = "was: $oldGroupSummary{average}{available} -> diff: ". sprintf("%.3f",$summaryHash{average}{available} - $oldGroupSummary{average}{available});
		#$summaryHash{average}{available_diff} = sprintf("%.3f",$summaryHash{average}{available} - $oldGroupSummary{average}{available});
	} else { $summaryHash{average}{available_diff} = "N/A"; }

	if ( $summaryHash{average}{health} !~ /N\/A|nan|NaN/ ) {
		$summaryHash{average}{health_diff} = "was: $oldGroupSummary{average}{health} -> diff: ". sprintf("%.3f",$summaryHash{average}{health} - $oldGroupSummary{average}{health});
		#$summaryHash{average}{health_diff} = sprintf("%.3f",$summaryHash{average}{health} - $oldGroupSummary{average}{health});
	} else { $summaryHash{average}{health_diff} = "N/A"; }

	if ( $summaryHash{average}{response} !~ /N\/A|nan|NaN/ ) {
		$summaryHash{average}{response_diff} = "was: $oldGroupSummary{average}{response} -> diff: ". sprintf("%.0f",$summaryHash{average}{response} - $oldGroupSummary{average}{response});
	} else { $summaryHash{average}{response_diff} = "N/A"; }

	&nmisMenuSmall;
	$NMIS::userMenu && &nmisMenuBar;

	### AS 8 June 2002 - Adding overall network metrics RRD's
	$tmpurl = "$this_script?file=$conf&amp;type=graph&amp;graphtype=metrics&amp;group=$group&amp;glamount=$glamount&amp;glunits=$glunits&amp;node=$node";
	print <<EO_HTML;
  <tr>
    <td class="grey" colspan="3">$group Network Metrics</td>
  </tr>
  <tr>
    <td width="50%" class="white" colspan="1">
      <table class="white" summary="Display">
        <tr>
          <td align="center" class="" rowspan="4" bgcolor="$overallColor">
            <font size="+1">$overallStatus</font>
          </td>
          <td align="center" class="" rowspan="4" bgcolor="$summaryHash{average}{metric_color}">
            <font size="+2">$summaryHash{average}{metric}</font> $summaryHash{average}{metric_icon}
          </td>
          <td align="center" class="" rowspan="4" bgcolor="$oldGroupSummary{average}{metric_color}">
            <font size="+1">$summaryHash{average}{metric_diff}</font>
          </td>
          <td bgcolor="$summaryHash{average}{reachable_color}">Reachablility</td>
          <td align="right" bgcolor="$summaryHash{average}{reachable_color}">$summaryHash{average}{reachable} $summaryHash{average}{reachable_icon}</td>
          <td align="right" bgcolor="$summaryHash{average}{reachable_color}">$summaryHash{average}{reachable_diff}</td>
          <td align="center" rowspan="4">
             <a href="$tmpurl"
               target="ViewWindow" onMouseOver="window.status='Drill in to Network Metrics.';return true" onClick="viewdoc('$tmpurl',$win_width,$win_height)">
               <img border="0" alt="Network Metrics" src="$this_script?file=$conf&amp;type=drawgraph&amp;group=$group&amp;graph=metrics&amp;glamount=$glamount&amp;glunits=$glunits&amp;start=0&amp;end=0&amp;width=250&amp;height=50">
             </a>
           </td>
        </tr>
        <tr>
          <td bgcolor="$summaryHash{average}{available_color}">Interface Availablility</td>
          <td bgcolor="$summaryHash{average}{available_color}" align="right">$summaryHash{average}{available} $summaryHash{average}{available_icon}</td>
          <td bgcolor="$summaryHash{average}{available_color}" align="right">$summaryHash{average}{available_diff}</td>
        </tr>
        <tr>
          <td bgcolor="$summaryHash{average}{health_color}">Health</td>
          <td bgcolor="$summaryHash{average}{health_color}" align="right">$summaryHash{average}{health} $summaryHash{average}{health_icon}</td>
          <td bgcolor="$summaryHash{average}{health_color}" align="right">$summaryHash{average}{health_diff}</td>
        </tr>
        <tr>
          <td bgcolor="$summaryHash{average}{response_color}" >Response Time</td>
          <td bgcolor="$summaryHash{average}{response_color}" align="right">$summaryHash{average}{response} ms $summaryHash{average}{response_icon}</td>
          <td bgcolor="$summaryHash{average}{response_color}" align="right">$summaryHash{average}{response_diff}</td>
        </tr>
      </table>
    </td>
  </tr>
  <tr>
    <td class="grey">$group Node List and Status</td>
  </tr>
  <tr>
EO_HTML
	cssCellStart("white",$span);
	cssTableStart("white");
	if ($NMIS::userMenu) {
		printHeadRow("Node,NMIS,Tools,Type,Net,Role,Group,Location,Outage,Status,Health,Reach,Interface<BR>Availability,Response Time,Escalation,Last Updated","#FFFFFF");
	}
	else {
		printHeadRow("Node,NMIS,Type,Net,Role,Group,Location,Outage,Status,Health,Reach,Interface<BR>Availability,Response Time,Escalation,Last Updated","#FFFFFF");
	}
	&printNodeType($group);
	tableEnd;
	cellEnd;
	rowEnd;
	print "<!-- nmisGroupSummary end -->\n";
} # end nmisGroupSummary

sub nmisSummary {
	my $overallStatus;
	my $overallColor;
	my $group;
	my $span = 1;
	my %groupSummary;
	my %oldGroupSummary;
	my $tmpurl;

	%summaryHash = &getGroupSummary();
	%oldGroupSummary = &getGroupSummary("","-16 hours","-8 hours");

	print "<!-- nmisSummary begin -->\n";
	$oldGroupSummary{average}{metric_diff} = sprintf("%.3f",$summaryHash{average}{metric} - $oldGroupSummary{average}{metric});
	if ( $oldGroupSummary{average}{metric_diff} <= -1 ) {
		$oldGroupSummary{average}{metric_color} = "red";
		$summaryHash{average}{metric_icon} = "<img alt=\"Down\" src=\"$NMIS::config{arrow_down_big}\" border=\"0\" width=\"11\" height=\"10\">";
	}
	elsif ( $oldGroupSummary{average}{metric_diff} < 0 ) {
		$oldGroupSummary{average}{metric_color} = "yellow";
		$summaryHash{average}{metric_icon} = "<img alt=\"Down\" src=\"$NMIS::config{arrow_down}\" border=\"0\" width=\"11\" height=\"10\">";
	}
	elsif ( $oldGroupSummary{average}{metric_diff} < 1 ) {
		$oldGroupSummary{average}{metric_color} = "#00FF00";
		$summaryHash{average}{metric_icon} = "<img alt=\"Up\" src=\"$NMIS::config{arrow_up}\" border=\"0\" width=\"11\" height=\"10\">";
	}
	elsif ( $oldGroupSummary{average}{metric_diff} >= 1 ) {
		$oldGroupSummary{average}{metric_color} = "#00FF00";
		$summaryHash{average}{metric_icon} = "<img alt=\"Up\" src=\"$NMIS::config{arrow_up_big}\" border=\"0\" width=\"11\" height=\"10\">";
	}
	# Arrow Icons for all the bits!
	if ( $oldGroupSummary{average}{reachable} <= $summaryHash{average}{reachable} ) { $summaryHash{average}{reachable_icon} = "<img alt=\"Up\" src=\"$NMIS::config{arrow_up}\" border=\"0\" width=\"11\" height=\"10\">"; }
	else { $summaryHash{average}{reachable_icon} = "<img alt=\"Down\" src=\"$NMIS::config{arrow_down}\" border=\"0\" width=\"11\" height=\"10\">"; }

	if ( $oldGroupSummary{average}{available} <= $summaryHash{average}{available} ) { $summaryHash{average}{available_icon} = "<img alt=\"Up\" src=\"$NMIS::config{arrow_up}\" border=\"0\" width=\"11\" height=\"10\">"; }
	else { $summaryHash{average}{available_icon} = "<img alt=\"Down\" src=\"$NMIS::config{arrow_down}\" border=\"0\" width=\"11\" height=\"10\">"; }

	if ( $oldGroupSummary{average}{health} <= $summaryHash{average}{health} ) { $summaryHash{average}{health_icon} = "<img alt=\"Up\" src=\"$NMIS::config{arrow_up}\" border=\"0\" width=\"11\" height=\"10\">"; }
	else { $summaryHash{average}{health_icon} = "<img alt=\"Down\" src=\"$NMIS::config{arrow_down}\" border=\"0\" width=\"11\" height=\"10\">"; }

	if ( $oldGroupSummary{average}{response} < $summaryHash{average}{response} ) { $summaryHash{average}{response_icon} = "<img alt=\"Up\" src=\"$NMIS::config{arrow_up_red}\" border=\"0\" width=\"11\" height=\"10\">"; }
	else { $summaryHash{average}{response_icon} = "<img alt=\"Down\" src=\"$NMIS::config{arrow_down_green}\" border=\"0\" width=\"11\" height=\"10\">"; }

        $overallStatus = overallNodeStatus;
        $overallColor = eventColor($overallStatus);
 
	## ehg 17 sep 02 add node down counter with colour
	if ( $summaryHash{average}{countdown} > 0) { $summaryHash{average}{countdown_color} = "red"; }
	else {  $summaryHash{average}{countdown_color} = "$overallColor"; }

	### AS 8 June 2002 - Adding overall network metrics RRD's
	print <<EO_HTML;
      <tr>
        <td width="100%" class="white" colspan="1">
          <table class="white" summary="Display">
            <tr>
EO_HTML
	## iab 20060207 exclude from menu the overall network if not allowed to
	if ($user->InGroup("network")) {
		print <<EO_HTML;
	              <td valign="top" width="24%" bgcolor="white" colspan="1">
               			<table class="white" summary="Display">
               				<tr>
               					<td class="grey" colspan="2">Network Metrics</td>
               				</tr>
               				<tr height="40">
               					<td align="center" bgcolor="$summaryHash{average}{metric_color}">
                 					<font size="+2">$summaryHash{average}{metric}</font> $summaryHash{average}{metric_icon}
                    				</td>
                    				<td align="center" bgcolor="$oldGroupSummary{average}{metric_color}">
                      				was: $oldGroupSummary{average}{metric}<br>diff: $oldGroupSummary{average}{metric_diff}
                    				</td>
       					</tr>
EO_HTML
				#rowStart;
				#printCell("Network Metric",$summaryHash{average}{metric_color},1);
				#printCell("$summaryHash{average}{metric}",$summaryHash{average}{metric_color},1,"right");
				#rowEnd;
				rowStart;
				printCell("Reachablility",$summaryHash{average}{reachable_color},1);
				printCell("$summaryHash{average}{reachable} $summaryHash{average}{reachable_icon}",$summaryHash{average}{reachable_color},1,"right");
				rowEnd;
				rowStart;
				printCell("Interface Availablility",$summaryHash{average}{available_color},1);
				printCell("$summaryHash{average}{available} $summaryHash{average}{available_icon}",$summaryHash{average}{available_color},1,"right");
					rowEnd;
				rowStart;
				printCell("Health",$summaryHash{average}{health_color},1);
				printCell("$summaryHash{average}{health} $summaryHash{average}{health_icon}",$summaryHash{average}{health_color},1,"right");
				rowEnd;
				rowStart;
				printCell("Response Time",$summaryHash{average}{response_color},1);
				printCell("$summaryHash{average}{response} ms $summaryHash{average}{response_icon}",$summaryHash{average}{response_color},1,"right");
				rowEnd;
			tableEnd;
		cellEnd;
	
		print "\t<td width=\"76%\" bgcolor=\"white\" colspan=\"1\">\n";
	} else {
		print "\t<td width=\"100%\" bgcolor=\"white\" colspan=\"1\">\n";
	}
			
	cssTableStart("white");
			print "<tr><td class=\"grey\" colspan=\"9\">Current Network Status</td></tr>";
			printHeadRow("Group,Status,NodeUp,NodeDn,Metric,Reach,IntAvail,Health,RT","white",1);
			## iab 20060207 exclude from menu the overall network if not allowed to
			if ($user->InGroup("network")) {
				rowStart;
				printCell("All Groups Status",$overallColor,1);
				printCell("$overallStatus",$overallColor,1,"center");
				printCell("$summaryHash{average}{count}",$overallColor,1,"center");
				printCell("$summaryHash{average}{countdown}",$summaryHash{average}{countdown_color},1,"center");
				printCell("$summaryHash{average}{metric} $summaryHash{average}{metric_icon}",$summaryHash{average}{metric_color},1,"right");
				printCell("$summaryHash{average}{reachable} $summaryHash{average}{reachable_icon}",$summaryHash{average}{reachable_color},1,"right");
				printCell("$summaryHash{average}{available} $summaryHash{average}{available_icon}",$summaryHash{average}{available_color},1,"right");
				printCell("$summaryHash{average}{health} $summaryHash{average}{health_icon}",$summaryHash{average}{health_color},1,"right");
				printCell("$summaryHash{average}{response} ms $summaryHash{average}{response_icon}",$summaryHash{average}{response_color},1,"right");
				rowEnd;
			}
			foreach $group (sort ( keys (%NMIS::groupTable) ) ) {
			#iab 20051011
				next unless $user->InGroup($group);
				%groupSummary = getGroupSummary($group);
				%oldGroupSummary = &getGroupSummary($group,"-16 hours","-8 hours");
				if ( $groupSummary{average}{metric} eq "N/A" ) { $groupSummary{average}{metric_icon} = "" }
				elsif ( $oldGroupSummary{average}{metric} <= $groupSummary{average}{metric} ) { $groupSummary{average}{metric_icon} = "<img alt=\"Up\" src=\"$NMIS::config{arrow_up}\" border=\"0\" width=\"11\" height=\"10\">"; }
				else { $groupSummary{average}{metric_icon} = "<img alt=\"Down\" src=\"$NMIS::config{arrow_down}\" border=\"0\" width=\"11\" height=\"10\">"; }

				if ( $groupSummary{average}{reachable} eq "N/A" ) { $groupSummary{average}{reachable_icon} = "" }
				elsif ( $oldGroupSummary{average}{reachable} <= $groupSummary{average}{reachable} ) { $groupSummary{average}{reachable_icon} = "<img alt=\"Up\" src=\"$NMIS::config{arrow_up}\" border=\"0\" width=\"11\" height=\"10\">"; }
				else { $groupSummary{average}{reachable_icon} = "<img alt=\"Down\" src=\"$NMIS::config{arrow_down}\" border=\"0\" width=\"11\" height=\"10\">"; }

				if ( $groupSummary{average}{available} eq "N/A" ) { $groupSummary{average}{available_icon} = "" }
				elsif ( $oldGroupSummary{average}{available} <= $groupSummary{average}{available} ) { $groupSummary{average}{available_icon} = "<img alt=\"Up\" src=\"$NMIS::config{arrow_up}\" border=\"0\" width=\"11\" height=\"10\">"; }
				else { $groupSummary{average}{available_icon} = "<img alt=\"Down\" src=\"$NMIS::config{arrow_down}\" border=\"0\" width=\"11\" height=\"10\">"; }

				if ( $groupSummary{average}{health} eq "N/A" ) { $groupSummary{average}{health_icon} = "" }
				elsif ( $oldGroupSummary{average}{health} <= $groupSummary{average}{health} ) { $groupSummary{average}{health_icon} = "<img alt=\"Up\" src=\"$NMIS::config{arrow_up}\" border=\"0\" width=\"11\" height=\"10\">"; }
				else { $groupSummary{average}{health_icon} = "<img alt=\"Down\" src=\"$NMIS::config{arrow_down}\" border=\"0\" width=\"11\" height=\"10\">"; }

				## AS 10 June 2002 - Trent O'Callaghan trent.ocallaghan@wanews.com.au response time arrow changes
				if ( $groupSummary{average}{response} eq "N/A" ) { $groupSummary{average}{response_icon} = "" }
				elsif ( $oldGroupSummary{average}{response} < $groupSummary{average}{response} ) { $groupSummary{average}{response_icon} = "<img alt=\"Up\" src=\"$NMIS::config{arrow_up_red}\" border=\"0\" width=\"11\" height=\"10\">"; }
				else { $groupSummary{average}{response_icon} = "<img alt=\"Down\" src=\"$NMIS::config{arrow_down_green}\" border=\"0\" width=\"11\" height=\"10\">"; }

				$overallStatus = overallNodeStatus($group);
				$overallColor = eventColor($overallStatus);

			        ## ehg 17 sep 02 add node down counter with colour
			        if ( $groupSummary{average}{countdown} > 0) { $groupSummary{average}{countdown_color} = "red"; }
			        else {  $groupSummary{average}{countdown_color} = "$overallColor"; }

				rowStart;
				if ( $user->InGroup($group) ) {
					printCell("<a href=\"$this_script?file=$conf&amp;group=$group\">$group</a>",$overallColor,1);
				} else {
					printCell("$group", $overallColor,1);
				}
				#printCell("<a href=\"$this_script?file=$conf&amp;group=$group\">$group</a>",$overallColor,1);
				printCell("$overallStatus",$overallColor,1,"center");
	                        printCell("$groupSummary{average}{count}",$overallColor,1,"center");
        	                printCell("$groupSummary{average}{countdown}",$groupSummary{average}{countdown_color},1,"center");
				printCell("$groupSummary{average}{metric} $groupSummary{average}{metric_icon}",$groupSummary{average}{metric_color},1,"right");
				printCell("$groupSummary{average}{reachable} $groupSummary{average}{reachable_icon}",$groupSummary{average}{reachable_color},1,"right");
				printCell("$groupSummary{average}{available} $groupSummary{average}{available_icon}",$groupSummary{average}{available_color},1,"right");
				printCell("$groupSummary{average}{health} $groupSummary{average}{health_icon}",$groupSummary{average}{health_color},1,"right");
				printCell("$groupSummary{average}{response} ms $groupSummary{average}{response_icon}",$groupSummary{average}{response_color},1,"right");
				rowEnd;
			}
	$tmpurl = "$this_script?file=$conf&amp;type=graph&amp;graphtype=metrics&amp;group=network&amp;glamount=$glamount&amp;glunits=$glunits&amp;node=$node";
	print "</table></td></tr>";
	if ( $user->InGroup("network") ) { 
		print <<EO_HTML;
            <tr>
              <td align="center" colspan="2">
                <a href="$tmpurl"
				  target="ViewWindow" onMouseOver="window.status='Drill in to Network Metrics.';return true" onClick="viewdoc('$tmpurl',$win_width,$win_height)">
                  <img border="0" alt="Network Metrics" src="$this_script?file=$conf&amp;type=drawgraph&amp;group=network&amp;graph=metrics&amp;glamount=$glamount&amp;glunits=$glunits&amp;start=0&amp;end=0&amp;width=750&amp;height=65">
                </a>
              </td>
            </tr>
EO_HTML
	}
	print "</table></td></tr>";
	print "<!-- nmisSummary end -->\n";
} # end nmisSummary

sub printNodeType {
	my $group = shift;
	my $cell = "#aaaaaa";
	my $outageExists;
	my $cleanedSysLocation;
    my $lat;
    my $long;
    my $alt;
    
	print "<!-- printNodeType begin -->\n";
	foreach $node (sort ( keys (%NMIS::nodeTable) ) ) {
		if ( $NMIS::nodeTable{$node}{group} eq "$group" ) {
			## AS 16 Mar 02, implementing David Gay's requirement for deactiving
			# a node, ie keep a node in nodes.csv but no collection done.
			### AS 10 June 2002 - If you don't want cell colored event status, un
			if ( $NMIS::nodeTable{$node}{active} ne "false" ) {
				#$cell = "#ffffff";
				$cell = $summaryHash{$node}{event_color};
			} else {
				$cell = "#aaaaaa";
			}
			$outageExists = outageCheck($node,time);
			if (  $outageExists eq "true" ) {
				$outage = outageCheckHash($node,time);
				$outage = "<BR>Ref.=$NMIS::outageTable{$outage}{change}";
			}
			else {
				$outage = "";
				$outageExists = "" if (exists $NMIS::nodeTable{$node}{slave2});
			}
			if (exists $NMIS::nodeTable{$node}{slave2}) { $outage = $NMIS::nodeTable{$node}{outage}; }

			rowStart;
			# Load the system table for the node.
			if (not exists $NMIS::nodeTable{$node}{slave2} ) {
				loadSystemFile($node);
			} else {
				# rws 20060223 -- systemTable needs to be undef'ed here
				undef %NMIS::systemTable;
			}
			# lets do some master/slave stuff.
			# if node is a slave - point the summary and health links at the remote node.
			my $slave_ref = "$this_script?file=$conf";
			if ( exists $NMIS::nodeTable{$node}{slave} ) {
				# TV: need to dereference the name to get the Host entry
				# Don't understand why some are slave2 and some are slave
				#$slave_ref = "http://$NMIS::nodeTable{$node}{slave}/cgi-nmis/nmiscgi.pl?file=$conf";
				$slave_ref = "http://".$NMIS::slaveTable{$NMIS::nodeTable{$node}{slave}}{Host}."/cgi-nmis/nmiscgi.pl?file=$conf";
			}
			if ( exists $NMIS::nodeTable{$node}{slave2}) {
				my $https = "s" if $NMIS::slaveTable{$NMIS::nodeTable{$node}{slave2}}{Secure} eq "true";
				$slave_ref = "http${https}://$NMIS::slaveTable{$NMIS::nodeTable{$node}{slave2}}{Host}/cgi-nmis/nmiscgi.pl".
					"?file=$NMIS::slaveTable{$NMIS::nodeTable{$node}{slave2}}{Conf}";
			}

	
			if (exists $NMIS::nodeTable{$node}{slave2} ) {
				$cleanedSysLocation = $NMIS::nodeTable{$node}{sysLocation};
			} else {
				# If sysLocation is formatted for GeoStyle, then remove long, lat and alt to make display tidier
				$cleanedSysLocation = $NMIS::systemTable{sysLocation};
				if (($NMIS::systemTable{sysLocation}  =~/$NMIS::config{sysLoc_format}/ ) and $NMIS::config{sysLoc} eq "on") {  
					# Node has sysLocation that is formatted for Geo Data
					( $lat, $long, $alt, $cleanedSysLocation) = split(',',$NMIS::systemTable{sysLocation});
				}
			} 

			# display sysName if $node is a IPV4 address
			my $sysName = exists $NMIS::nodeTable{$node}{slave2} ? $NMIS::nodeTable{$node}{sysName} : $NMIS::systemTable{sysName};
			if ( $node =~ /\d+\.\d+\.\d+\.\d+/ 	and $sysName ne "" ) {
				printCell("<a href=\"$slave_ref&amp;node=$node&amp;type=summary\">$sysName</a>",$cell,1);
			}
			else {
				printCell("<a href=\"$slave_ref&amp;node=$node&amp;type=summary\">$node</a>",$cell,1);
			}
			my $aref1 = "<a href=\"$slave_ref&amp;node=$node&amp;type=summary\">Summary</a> ";
			my $aref2 = "<a href=\"$slave_ref&amp;node=$node&amp;type=health\">Health</a> ";
			my $aref3 = (exists $NMIS::nodeTable{$node}{slave2} ) ? "server->$NMIS::nodeTable{$node}{slave2}" : "" ;
			printCell($aref1.$aref2.$aref3,$cell,1);
 			#
 			# Display Telnet, Ping and Trace buttons depending 
			# on authentication or userMenu settings
			#
			if (!$tb) {
				$tb = NMIS::Toolbar::new;
				$tb->SetLevel($user->privlevel);
				$tb->LoadButtons($NMIS::config{'<nmis_conf>'}."/toolset.csv");
			}
			# pass in needed vars as NVP hash
			$tb->{_vars} = { node => $node };
			print start_td({bgcolor=>$cell});
			print $tb->DisplayButtons("tool");
			print &end_td;
			printCell("$NMIS::nodeTable{$node}{devicetype}",$cell);
			printCell("$NMIS::nodeTable{$node}{net}",$cell);
			printCell("$NMIS::nodeTable{$node}{role}",$cell);
			if ($NMIS::userMenu) {
				# who uses locations ?? turn back on if you want it..
				#printCell("<a href=\"$NMIS::config{view}?file=$conf&amp;table=Locations&amp;name=$NMIS::nodeTable{$node}{group}\">$NMIS::nodeTable{$node}{group}</a>",$cell);
				#printCell("<a href=\"$NMIS::config{view}?file=$conf&amp;table=Locations&amp;name=$NMIS::systemTable{sysLocation}\">$cleanedSysLocation</a>",$cell);
				printCell($NMIS::nodeTable{$node}{group},$cell);
				printCell($cleanedSysLocation,$cell);

			}
			else {
				printCell("$NMIS::nodeTable{$node}{group}",$cell);
				printCell("$cleanedSysLocation",$cell);
			}
			printCell("$outageExists $outage",$cell);
			printCell("$summaryHash{$node}{event_status}",$summaryHash{$node}{event_color},1,"right");
			printCell("$summaryHash{$node}{health}",$summaryHash{$node}{health_color},1,"right");
			printCell("$summaryHash{$node}{reachable}",$summaryHash{$node}{reachable_color},1,"right");
			printCell("$summaryHash{$node}{available}",$summaryHash{$node}{available_color},1,"right");
			printCell("$summaryHash{$node}{response} ms",$summaryHash{$node}{response_color},1,"right");
			if ( exists $NMIS::nodeTable{$node}{slave2} ) {
				printCell($NMIS::nodeTable{$node}{escalate},$cell,1,"right");
			} else {
				my $event_hash = &eventHash($node, "Node Down", "Ping failed");
				if ( $NMIS::eventTable{$event_hash}{escalate} eq "" ) { $NMIS::eventTable{$event_hash}{escalate} = "&nbsp;" }
				printCell($NMIS::eventTable{$event_hash}{escalate},$cell,1,"right");
			}

			my $lastUpdate;
			my $time;
			my $cellx = $cell;
			if ( exists $NMIS::nodeTable{$node}{slave2} ) {
				$time = $NMIS::nodeTable{$node}{lastupdate} ;
			} else {
				my $database = getRRDFileName(type => "reach", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype});
			    $time = RRDs::last $database;
			}
			if ( $time ne "" ) { 
				$lastUpdate = returnDateStamp($time);
				if ($time < (time - 60*15)) { $cellx = "#ffcc00";} # to late
			} else { $lastUpdate = "N/A"; }
			printCell("$lastUpdate",$cellx,1,"right");

			rowEnd;
		}
	}
	print "<!-- printNodeType end -->\n";
}

sub displaySystemHeader {
	my $node = shift;

	my $event_status;
	my $event_color;
	my $configLink;
	my $outage;
	my $sup = "";
	my $Device_Syslog;
	my $Node_Syslog;

	my $database = getRRDFileName(type => "health", node => $node, nodeType => $NMIS::nodeTable{$node}{devicetype});
    my $time = RRDs::last $database;
    my $lastUpdate = returnDateStamp($time);

	if ( $NMIS::systemTable{supported} eq "false" or $NMIS::systemTable{supported} eq "" ) {
		#$NMIS::systemTable{sysName} = "Device Not Supported";
		#$sup = " Device Not Supported";
	}

	if ( $NMIS::systemTable{sysName} eq "" ) {
		$NMIS::systemTable{sysName} = $node;
	}
	if ( $NMIS::systemTable{nodeModel} eq "CiscoRouter" ) { $configLink = "Cisco_Router/$node.cfg"; }
	elsif ( $NMIS::systemTable{nodeModel} =~ /MSM|RSM/i ) { $configLink = "Cisco_Catalyst_L2L3_Switch/$node.cfg"; }
	elsif ( $NMIS::systemTable{nodeModel} =~ /1010/ ) { $configLink = "Cisco_LS1010_Switch/$node.cfg"; }
	elsif ( $NMIS::systemTable{nodeModel} =~ /Catalyst/ ) { $configLink = "Cisco_Catalyst_Switch/$node.cfg"; }
	elsif ( $NMIS::systemTable{nodeModel} =~ /FoundrySwitch/ ) { $configLink = "Foundry_Switch/$node.cfg"; }
	elsif ( $NMIS::systemTable{nodeModel} =~ /Redback/ ) { $configLink = "Redback/$node.cfg"; }
	elsif ( $NMIS::systemTable{nodeModel} =~ /Riverstone/ ) { $configLink = "Riverstone/$node.cfg"; }

	if ( -r "/var/adm/CSCOpx/files/archive/shadow/$configLink" ) {
		$configLink = "<a target=\"_blank\" href=\"/configs/$configLink\">View Config</a>";
	}
	elsif ( -r "../../rancid/$NMIS::systemTable{nodeGroup}" ) {
		$configLink = "<a target=\"_blank\" href=\"/cvsweb/cvsweb.cgi/$NMIS::systemTable{nodeGroup}/configs/$node\">View Config</a>";
	}
	else { $configLink = ""; }

	if ( eventExist($node,"Node Down","Ping failed") eq "true" ) {
		($event_status,$event_color) = eventLevel("Node Down",$NMIS::nodeTable{$node}{role});
	}
	elsif ( $NMIS::nodeTable{$node}{active} eq "false" ) {
		($event_status,$event_color) = ( "InActive", "#aaaaaa" );
	}
	else {
		($event_status,$event_color) = eventLevel("Node Up",$NMIS::nodeTable{$node}{role});
	}

	rowStart;
	cssCellStart("white");
	cssTableStart("white");
	rowStart;
	cssPrintCell("button","<a href=\"$this_script?file=$conf&amp;node=$node&amp;type=summary\">Summary</a>");

	if ( $NMIS::nodeTable{$node}{collect} eq "true" ) {
		cssPrintCell("button","<a href=\"$this_script?file=$conf&amp;node=$node&amp;type=health\">Health Statistics</a>");
		cssPrintCell("button","<a href=\"$this_script?file=$conf&amp;node=$node&amp;type=link\">Link List</a>");
		if ( -e "$NMIS::config{'<nmis_var>'}/$node-pvc.dat" ) {
			cssPrintCell("button","<a href=\"$this_script?file=$conf&amp;node=$node&amp;type=portpvc\">PVC Statistics</a>");
		}
		cssPrintCell("button","<a href=\"$this_script?file=$conf&amp;node=$node&amp;type=port\">Port Statistics</a>");

		if ( $NMIS::systemTable{typedrawactive} =~ /cbqos/ ) {
			cssPrintCell("button","<a href=\"$this_script?file=$conf&amp;node=$node&amp;type=port&amp;graphtype=cbqos-out\">CBQoS Statistics</a>");
		}
	}
	rowEnd;
	tableEnd;
	cellEnd;
	rowEnd;

	if ( outageCheck($node,time) eq "true" ) {
		$outage = outageCheckHash($node,time);
		$outage = "- Planned Outage change=$NMIS::outageTable{$outage}{change}";
	}
	# only works if models.csv has syslog file set for each modeltype
	$Device_Syslog = $NMIS::systemTable{syslog};
 ;
	# if a fqdn, strip the domain, so we search logs on hostname, not hostname.fqdn
	if ( $node =~ /$NMIS::config{domain_name}/i ) {
		($Node_Syslog) = split /\./ , $node;
	}
	else {
		$Node_Syslog = $node;
	}

	$tb = NMIS::Toolbar->new;
	$tb->SetLevel($user->privlevel);
	$tb->LoadButtons($NMIS::config{'<nmis_conf>'}."/toolset.csv");

	my $url = $q->url()."?file=$conf";

	print &start_Tr,
		start_td({class=>"white"}),
		start_table({class=>"white", summary=>"Display"});
 
	if ( $NMIS::nodeTable{$node}{collect} eq "true" ) {
		print &start_Tr;
		print td({class=>"sh_bold", colspan=>1, align=>"center"}, "Name"),
			td({class=>"sh_head", colspan=>2, bgcolor=>$event_color, align=>"center"},$NMIS::systemTable{sysName}.$sup),
			td({class=>"sh_bold", colspan=>1}, "UpTime"),
			td({class=>"sh_body", colspan=>1, align=>"center"}, $NMIS::systemTable{sysUpTime}),
			start_td({class=>"sh_body", colspan=>1});
		#
		# Display Telnet, Ping and Trace buttons depending 
		# on authentication or userMenu settings
		#
		# pass in needed vars as NVP hash
		$tb->{_vars} = { node => $node };
		print $tb->DisplayButtons("tool");
		print &end_td, &end_Tr;

		print 	Tr(td( { class=>"sh_bold", colspan=>"1"},b("Status")),
				td( { class=>"sh_head", colspan=>"2",bgcolor=>"$event_color"},
					$auth->CheckAccess($user,"eventcur","check") ? a({href=>"$url&type=event&node=$node"},"$event_status $outage"):"$event_status $outage"),
				td( { class=>"sh_body", colspan=>"1"},$configLink),
				td( { class=>"sh_body", colspan=>"1"},
					$auth->CheckAccess($user,"eventlog","check") ? a({href=>"$NMIS::config{logs}?log=Event_Log&search=$node&lines=100&level=normal"},"Event Log"):" "),
				td( { class=>"sh_body", colspan=>"1"},
					$auth->CheckAccess($user,"syslog","check") ? a({href=>"$NMIS::config{logs}?log=Device_Log&search=$Node_Syslog&lines=100&level=normal"},"Device Log"):" "));

		if ( exists $NMIS::config{collect_rps_gen} and $NMIS::systemTable{sysObjectName} =~ /$qr_collect_rps_gen/ ) {
			# display the RPS status for this modeModel
			# set the PSU status color
			my $psu_color1;
			my $psu_color2;
			if ( $NMIS::systemTable{SupplyState1} eq "unknown"
					or $NMIS::systemTable{SupplyDescr1} =~ /unknown|none/ ) { $psu_color1 = "#FFFFFF"; }
			elsif ( $NMIS::systemTable{SupplyState1} eq "normal" ) { $psu_color1 = "#00FF00"; }
			else { $psu_color1 = "#FF0000"; }
				if ( $NMIS::systemTable{SupplyState2} eq "unknown"
					or $NMIS::systemTable{SupplyDescr2} =~ /unknown|none/ ) { $psu_color2 = "#FFFFFF"; }
			elsif ( $NMIS::systemTable{SupplyState2} eq "normal" ) { $psu_color2 = "#00FF00"; }
			else { $psu_color2 = "#FF0000"; }

			print Tr(td({class=>"sh_bold",colspan=>"1"},b("PSU Status 1")),
					td({class=>"sh_body",colspan=>"2",bgcolor=>"$psu_color1",align=>"center"},"$NMIS::systemTable{SupplyDescr1}"),
					td({class=>"sh_bold",colspan=>"1"},b("Contact")),
					td({class=>"sh_body",colspan=>"2"},
						$auth->CheckAccess($user,"contacts","check") ? a({href=>"$NMIS::config{view}?file=$conf&table=Contacts&name=$NMIS::systemTable{sysContact}"},"$NMIS::systemTable{sysContact}"):"$NMIS::systemTable{sysContact}")
					);
			print Tr(td({class=>"sh_bold",colspan=>"1"},b("PSU Status 2")),
					td({class=>"sh_body",colspan=>"2",bgcolor=>"$psu_color2",align=>"center"},"$NMIS::systemTable{SupplyDescr1}"),
					td({class=>"sh_bold",colspan=>"1"},b("Location")),
					td({class=>"sh_body",colspan=>"2"},
						$auth->CheckAccess($user,"locations","check") ? a({href=>"$NMIS::config{view}?file=$conf&table=Locations&name=$NMIS::systemTable{sysLocation}"},"$NMIS::systemTable{sysLocation}"):"$NMIS::systemTable{sysLocation}")
					);
					
		} else {
			print	Tr(td({class=>"sh_bold",colspan=>"1"},b("Location")),
					td({class=>"sh_body",colspan=>"3"},
						$auth->CheckAccess($user,"locations","check") ? a({href=>"$NMIS::config{view}?file=$conf&table=Locations&name=$NMIS::systemTable{sysLocation}"},"$NMIS::systemTable{sysLocation}"):"$NMIS::systemTable{sysLocation}"),
					td({class=>"sh_bold",colspan=>"1"},b("Contact")),
					td({class=>"sh_body",colspan=>"1"},
						$auth->CheckAccess($user,"contacts","check") ? a({href=>"$NMIS::config{view}?file=$conf&table=Contacts&name=$NMIS::systemTable{sysContact}"},"$NMIS::systemTable{sysContact}"):"$NMIS::systemTable{sysContact}"),
					);
		}
		print 	Tr(td({class=>"sh_bold",colspan=>"1"},b("Node Type")),
				td({class=>"sh_body",colspan=>"1",align=>"center"},
					$auth->CheckAccess($user,"nodes","check") ? a({href=>"$NMIS::config{view}?file=$conf&table=Events&column=Type&value=$NMIS::systemTable{nodeType}"},"$NMIS::systemTable{nodeType}"):"$NMIS::systemTable{nodeType}"),
				td({class=>"sh_bold",colspan=>"1"},b("Node Vendor")),
				td({class=>"sh_body",colspan=>"1",align=>"center"},"$NMIS::systemTable{nodeVendor}"),
				td({class=>"sh_bold",colspan=>"1"},b("NodeModel:SystemName")),
				td({class=>"sh_body",colspan=>"1",align=>"center"},"$NMIS::systemTable{nodeModel}:$NMIS::systemTable{sysObjectName}")
				);
		print	Tr(td({class=>"sh_bold",colspan=>"1"},b("Description")),
				td({class=>"sh_body",colspan=>"3"},"$NMIS::systemTable{sysDescr}"),
				td({class=>"sh_bold",colspan=>"1"},b("Last Updated")),
				td({class=>"sh_body",colspan=>"1",align=>"center"},"$lastUpdate")
				);
		print	Tr(td({class=>"sh_bold",width=>"10%"},b("Net Type")),
				td({class=>"sh_body",width=>"13%",align=>"center"},"$NMIS::systemTable{netType}"),
				td({class=>"sh_bold",width=>"10%"},b("Role Type")),
				td({class=>"sh_body",width=>"13%",align=>"center"},
					$auth->CheckAccess($user,"events","check") ? a({href=>"$NMIS::config{view}?file=$conf&table=Events&column=Role&name=$NMIS::systemTable{roleType}"},"$NMIS::systemTable{roleType}"):"$NMIS::systemTable{roleType}"),
				td({class=>"sh_bold",width=>"10%"},b("Interfaces")),
				td({class=>"sh_body",width=>"13%",align=>"center"},
					$auth->CheckAccess($user,"events","check") ? a({href=>"$this_script?node=$node&amp;find=$node"},"$NMIS::systemTable{ifNumber}"):"$NMIS::systemTable{ifNumber}")
				);


		if ( $NMIS::systemTable{nodeVendor} =~ "Cisco"
				and $NMIS::systemTable{nodeType} eq "router"
				and $NMIS::systemTable{nodeModel} ne "CiscoPIX"	) {
			print	Tr(td({class=>"sh_bold",width=>"10%"},b("Serial Number")),
					td({class=>"sh_body",width=>"13%",align=>"center"},"$NMIS::systemTable{serialNum}"),
					td({class=>"sh_bold",width=>"10%"},b("Chassis Version")),
					td({class=>"sh_body",width=>"13%",align=>"center"},"$NMIS::systemTable{chassisVer}"),
					td({class=>"sh_bold",width=>"10%"},b("Processor Mem")),
					td({class=>"sh_body",width=>"13%",align=>"center"},"$NMIS::systemTable{processorRam}")
					);
		}
		elsif ( $NMIS::systemTable{nodeModel} eq "CiscoPIX" ) {
			my $failcolor = "#FFDD00";	#warning
			if ( $NMIS::systemTable{pixPrimary} eq "Failover Off" or $NMIS::systemTable{pixPrimary} eq "Active" ) {
				$failcolor = "#00FF00";	#normal
			}
            if ( $NMIS::systemTable{pixSecondary} eq "Failover Off" or $NMIS::systemTable{pixSecondary} eq "Standby" ) {
                 $failcolor = "#00FF00"; #normal
            }
 			print	Tr(td({class=>"sh_bold",width=>"10%"},b("Serial Number")),
					td({class=>"sh_body",width=>"13%",align=>"center"},"$NMIS::systemTable{serialNum}"),
					td({class=>"sh_bold",width=>"10%"},b("Failover Status")),
					td({class=>"sh_body",width=>"13%",align=>"center",bgcolor=>$failcolor},"Pri: $NMIS::systemTable{pixPrimary} Sec: $NMIS::systemTable{pixSecondary}"),
					td({class=>"sh_bold",width=>"10%"},b("Processor Mem")),
					td({class=>"sh_body",width=>"13%",align=>"center"},"$NMIS::systemTable{processorRam}")
					);
		}
		elsif ( $NMIS::systemTable{nodeVendor} =~ "Cisco"
				and $NMIS::systemTable{nodeType} eq "switch" ) {
 			print	Tr(td({class=>"sh_bold",width=>"10%"},b("Serial Number")),
					td({class=>"sh_body",width=>"13%",align=>"center"},"$NMIS::systemTable{serialNum}"),
					td({class=>"sh_bold",width=>"10%"},b("Traffic Peak")),
					td({class=>"sh_body",width=>"13%",align=>"center"},"$NMIS::systemTable{sysTrafficPeak}%"),
					td({class=>"sh_bold",width=>"10%"},b("Peak Time (ago)")),
					td({class=>"sh_body",width=>"13%",align=>"center"},"$NMIS::systemTable{sysTrafficPeakTime}")
					);
		}
	} else {
		print &start_Tr;
		print td({class=>"sh_bold", colspan=>1, align=>"center"}, "Name"),
			td({class=>"sh_head", colspan=>2, bgcolor=>$event_color, align=>"center"},$NMIS::systemTable{sysName}.$sup),
			td({class=>"sh_bold",colspan=>"1"},b("Last Updated")),
			td({class=>"sh_body",colspan=>"1",align=>"center"},"$lastUpdate");
		#
		# Display Telnet, Ping and Trace buttons depending 
		# on authentication or userMenu settings
		#
		# pass in needed vars as NVP hash
		$tb->{_vars} = { node => $node };
		print &start_td,$tb->DisplayButtons("tool"),&end_td;
		print &end_Tr;

		print 	Tr(td( { class=>"sh_bold", colspan=>"1"},b("Status")),
				td( { class=>"sh_head", colspan=>"2",bgcolor=>"$event_color"},
					$auth->CheckAccess($user,"eventcur","check") ? a({href=>"$url&type=event&node=$node"},"$event_status $outage"):"$event_status $outage"),
				td( { class=>"sh_body", colspan=>"1"},$configLink),
				td( { class=>"sh_body", colspan=>"1"},
					$auth->CheckAccess($user,"eventlog","check") ? a({href=>"$NMIS::config{logs}?log=Event_Log&search=$node&lines=100&level=normal"},"Event Log"):" "),
				td( { class=>"sh_body", colspan=>"1"},
					$auth->CheckAccess($user,"syslog","check") ? a({href=>"$NMIS::config{logs}?log=Device_Log&search=$Node_Syslog&lines=100&level=normal"},"Device Log"):" ")
				);

		print 	Tr(td({class=>"sh_bold",width=>"10%"},b("Node Type")),
				td({class=>"sh_body",width=>"13%",align=>"center"},
					$auth->CheckAccess($user,"nodes","check") ? a({href=>"$NMIS::config{view}?file=$conf&table=Events&column=Type&value=$NMIS::systemTable{nodeType}"},"$NMIS::systemTable{nodeType}"):"$NMIS::systemTable{nodeType}"),
				td({class=>"sh_bold",width=>"10%"},b("Net Type")),
				td({class=>"sh_body",width=>"13%",align=>"center"},"$NMIS::systemTable{netType}"),
				td({class=>"sh_bold",width=>"10%"},b("Role Type")),
				td({class=>"sh_body",width=>"13%",align=>"center"},
					$auth->CheckAccess($user,"events","check") ? a({href=>"$NMIS::config{view}?file=$conf&table=Events&column=Role&name=$NMIS::systemTable{roleType}"},"$NMIS::systemTable{roleType}"):"$NMIS::systemTable{roleType}")
				);

		print	Tr(td({class=>"sh_bold",colspan=>"1"},b("Location")),
				td({class=>"sh_body",colspan=>"2"},
					$auth->CheckAccess($user,"locations","check") ? a({href=>"$NMIS::config{view}?file=$conf&table=Locations&name=$NMIS::systemTable{sysLocation}"},"$NMIS::systemTable{sysLocation}"):"$NMIS::systemTable{sysLocation}"),
				td({class=>"sh_bold",colspan=>"1"},b("Contact")),
				td({class=>"sh_body",colspan=>"2"},
					$auth->CheckAccess($user,"contacts","check") ? a({href=>"$NMIS::config{view}?file=$conf&table=Contacts&name=$NMIS::systemTable{sysContact}"},"$NMIS::systemTable{sysContact}"):"$NMIS::systemTable{sysContact}")
				);

	} # collect

	print &end_table;
}

sub rrdStats {
	my %args = @_;
	my $type = $args{type};
	loadSystemFile($args{node});
	my %interfaceTable;
	my $database;
	my $extName;

	# verify access to this command/tool bar/button
	#
	if ( $auth->Require ) {
		# CheckAccess will throw up a web page and stop if access is not allowed
		# $auth->CheckAccess($user, "") or die "Attempted unauthorized access";
		if ( ! $user->user ) {
			do_force_login("Authentication is required to access this function. Please login.");
			exit 0;
		}
	}

	# load node details to verify group access
	&loadNodeDetails;

	# verify that user is authorized to view the node within the user's group list
	#
	if ( $args{node} ) {
		if ( ! $user->InGroup($NMIS::nodeTable{$node}{group}) ) {
			pageStart;
			cssHeaderBar("Not Authorized to export rrd data on node '$node' in group '$NMIS::nodeTable{$node}{group}'.","grey");
			pageEnd;
			return 0;
		}
	} elsif ( $args{group} ) {
		if ( ! $user->InGroup($group) ) {
			pageStart;
			cssHeaderBar("Not Authorized to export rrd data on nodes in group '$group'.","grey");
			pageEnd;
			return 0;
		}
	}

	if ( getGraphType($type) =~ /interface|pkts|cbqos|calls/ ) {
		%interfaceTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$args{node}-interface.dat","ifIndex","\t");
	}

	# define the RRD filename
	# lookup the pvc from the intf->ifDescr - will fail if pvc.dat does not have subifDescr entry
	if ( $type eq "pvc" ) {
		%interfaceTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-interface.dat","ifIndex","\t");
		my 	%pvcTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-pvc.dat","subifDescr","\t");
		$extName = $pvcTable{lc($interfaceTable{$intf}{ifDescr})}{rrd};
	} elsif ( $type =~ /hrsmpcpu/ or $type =~ /hrdisk/ ) {
		$extName = $type ;
	} else {
		$extName = $interfaceTable{$intf}{ifDescr} ; # default
	}

	$database = getRRDFileName(type => $args{type}, node => $args{node}, group => $args{group}, nodeType => $NMIS::systemTable{nodeType}, extName => $extName, item => $args{item});

	my $statval = &getRRDStats(rrd => $database, type => "AVERAGE", start => $args{start}, end => $args{end});
	my $f = 1;
	my $starttime = returnDateStamp($args{start});
	my $endtime = returnDateStamp($args{end});
	my $back_url = "<a href=\"$ENV{HTTP_REFERER}\"><img alt=\"Back\" src=\"$NMIS::config{back_icon}\" border=\"0\"></a>";
	pageStart("NMIS RRD Graph Stats","true",\%headeropts);
	cssTableStart;
	cssHeaderBar("$back_url NMIS RRD Graph Stats $args{node} $interfaceTable{$intf}{ifDescr} $item $starttime to $endtime","grey");
	print "<tr><td colspan=\"4\"><table class=\"plain\" summary=\"Display\">\n";
	foreach my $m (sort keys %{$statval}) {
		if ($f) {
			$f = 0;
			print "<tr><th>metric</th>\n";
			foreach my $s (sort keys %{$statval->{$m}}) {
				if ( $s ne "values" ) {
					print "<th>$s</th>\n";
				}
			}
			print "</tr>\n";
		}
		print "<tr><td>$m</td>\n";
		foreach my $s (sort keys %{$statval->{$m}}) {
			if ( $s ne "values" ) {
				#print "<td>$m</td><td>$s</td><td>$statval->{$m}{$s}</td>\n";
				print "<td>$statval->{$m}{$s}</td>\n";
			}
		}
		print "</tr>\n";
	}
	print "</table></td></tr>\n";
	tableEnd;
	pageEnd;
}

sub rrdExport {
	my %args = @_;
	my $type = $args{type};
	my $f = 1;
	my @line;
	my $row;
	my $content;
	loadSystemFile($args{node});
	my %interfaceTable;
	my $database;
	my $extName;
 	# verify access to this command/tool bar/button
	#
	if ( $auth->Require ) {
		# CheckAccess will throw up a web page and stop if access is not allowed
		# $auth->CheckAccess($user, "") or die "Attempted unauthorized access";
		if ( ! $user->user ) {
			do_force_login("Authentication is required to access this function. Please login.");
			exit 0;
		}
	}

	# load node details to verify group access
	&loadNodeDetails;

	# verify that user is authorized to view the node within the user's group list
	#
	if ( $args{node} ) {
		if ( ! $user->InGroup($NMIS::nodeTable{$node}{group}) ) {
			pageStart;
			cssHeaderBar("Not Authorized to export rrd data on node '$node' in group '$NMIS::nodeTable{$node}{group}'.","grey");
			pageEnd;
			return 0;
		}
	} elsif ( $args{group} ) {
		if ( ! $user->InGroup($group) ) {
			pageStart;
			cssHeaderBar("Not Authorized to export rrd data on nodes in group '$group'.","grey");
			pageEnd;
			return 0;
		}
	}

	if ( getGraphType($type) =~ /interface|pkts|cbqos|calls/ ) {
		%interfaceTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$args{node}-interface.dat","ifIndex","\t");
	}

	# define the RRD filename
	# lookup the pvc from the intf->ifDescr - will fail if pvc.dat does not have subifDescr entry
	if ( $type eq "pvc" ) {
		%interfaceTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-interface.dat","ifIndex","\t");
		my 	%pvcTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-pvc.dat","subifDescr","\t");
		$extName = $pvcTable{lc($interfaceTable{$intf}{ifDescr})}{rrd};
	} elsif ( $type =~ /hrsmpcpu/ or $type =~ /hrdisk/ ) {
		$extName = $type ;
	} else {
		$extName = $interfaceTable{$intf}{ifDescr} ; # default
	}

	$database = getRRDFileName(type => $args{type}, node => $args{node}, group => $args{group}, nodeType => $NMIS::systemTable{nodeType}, extName => $extName, item => $args{item});

	my ($statval,$head) = &getRRDasHash(rrd => $database, type => "AVERAGE", start => $args{start}, end => $args{end});
	my $filename = "$args{node}-$args{type}";
	if ( $args{node} eq "" ) { $filename = "$args{group}-$args{type}" }
	print "Content-type: text/plain;\n";
	print "Content-Disposition: attachment; filename=$filename.csv\n\n";

	foreach my $m (sort keys %{$statval}) {
		if ($f) {
			$f = 0;
			foreach my $h (@$head) {
				push(@line,$h);
				#print STDERR "@line\n";
			}
			#print STDERR "@line\n";
			$row = join("\t",@line);
			print "$row\n";
			@line = ();
		}
		$content = 0;
		foreach my $h (@$head) {
			if ( defined $statval->{$m}{$h}) {
				$content = 1;
			}
			push(@line,$statval->{$m}{$h});
		}
		if ( $content ) {
			$row = join("\t",@line);
			print "$row\n";
		}
		@line = ();
	}
}

sub rrdDraw {
	my %args = @_;
	my $node = $args{node};
	my $type = $args{type};
	my $group = $args{group};
	my $glamount = $args{glamount};
	my $glunits = $args{glunits};
	my $start = $args{start};
	my $end = $args{end};
	my $width = $args{width};
	my $height = $args{height};
	my $intf = $args{intf};
	my $item = $args{item};

	my $length = "$glamount $glunits";
	my @options;
	my $weight;
	my $tmpifDescr;
	my $ERROR;
	my $graphret;
	my $xs;
	my $ys;
	my $speed;
	my $database;
	my $extName;

	# verify access to this command/tool bar/button
	#
	if ( $auth->Require ) {
		# CheckAccess will throw up a web page and stop if access is not allowed
		# $auth->CheckAccess($user, "") or die "Attempted unauthorized access";
		if ( ! $user->user ) {
			do_force_login("Authentication is required to access this function. Please login.");
			exit 0;
		}
	}

	##master/slave stuff ###
	##assume same directory structure / or addin as option - later..
	# if node is foreign to this box, redirect to slave box that has the data
	# skip health and response as they are stored local to this box
	# $my_data has the original url.
	
	if ( $NMIS::nodeTable{$node}{slave} 
		and $type ne 'health'
		and $type ne 'response' ) {
			print "Location: http://$NMIS::nodeTable{$node}{slave}/cgi-nmis/nmiscgi.pl?/$my_data\n\n";
		return;
	}
	loadSystemFile($node);
	loadNodeDetails;
	# verify that user is authorized to view the node within the user's group list
	#
	if ( $node ) {
		if ( ! $user->InGroup($NMIS::nodeTable{$node}{group}) ) {
			cssHeaderBar("Not Authorized to view graph data on node '$node' in group '$NMIS::nodeTable{$node}{group}'.","grey");
			pageEnd;
			return 0;
		}
	} elsif ( $group ) {
		if ( ! $user->InGroup($group) ) {
			cssHeaderBar("Not Authorized to view graph data on nodes in group '$group'.","grey");
			pageEnd;
			return 0;
		}
	}	
	my %interfaceTable;
	if ( getGraphType($type) =~ /interface|pkts|cbqos|calls/ ) {
		%interfaceTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-interface.dat","ifIndex","\t");
		$speed = &convertIfSpeed($interfaceTable{$intf}{ifSpeed});
	}

	# define the RRD filename
	# lookup the pvc from the intf->ifDescr - will fail if pvc.dat does not have subifDescr entry
	if ( $type eq "pvc" ) {
		%interfaceTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-interface.dat","ifIndex","\t");
		$speed = &convertIfSpeed($interfaceTable{$intf}{ifSpeed});
		my 	%pvcTable = &loadCSV("$NMIS::config{'<nmis_var>'}/$node-pvc.dat","subifDescr","\t");
		$extName = $pvcTable{lc($interfaceTable{$intf}{ifDescr})}{rrd};
	} elsif ( $type =~ /hrsmpcpu/ or $type =~ /hrdisk/ ) {
		$extName = $type ;
	} else {
		$extName = $interfaceTable{$intf}{ifDescr} ; # default
	}

	$database = getRRDFileName(type => $type, node => $node, group => $group, nodeType => $NMIS::systemTable{nodeType}, extName => $extName, item => $item);

	if ( $end == 0 ) { $end = time; }
	if ( $start == 0 ) { $start = convertTime($glamount,$glunits); }

	my $datestamp_start = &returnDateStamp($start);
	my $datestamp_end = &returnDateStamp($end);
	my $datestamp = &returnDateStamp(time);

	# if the filename starts with / in it must be a absolute directory

	if ( $NMIS::debug eq "verbose" ) { print "Graphing: node=$node type=$type start=$start end=$end width=$width height=$height intf=$intf speed=$interfaceTable{$intf}{ifSpeed}\n";  }
	#logMessage("rrdDraw,$node,node=$node type=$type start=$start end=$end width=$width height=$height intf=$intf speed=$interfaceTable{$intf}{ifSpeed}");

	# Run the approiate graph subrouting
	if ( $type eq "util" ) {
		if ( $interfaceTable{$intf}{ifSpeed} eq "auto" ) {
			 $interfaceTable{$intf}{ifSpeed} = 10000000;
		}
		if ( $title eq "short" ) { $title = "$node: $interfaceTable{$intf}{ifDescr} - $length"; }
		else { $title = "$node: $interfaceTable{$intf}{ifDescr} - $length from $datestamp_start to $datestamp_end"; }

		@options = (
			"--title", $title,
			"--vertical-label", '% Avg Util',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			# Might be a good option on an active interface.
			#"--logarithmic",
			"DEF:input=$database:ifInOctets:AVERAGE",
			"DEF:output=$database:ifOutOctets:AVERAGE",
			"DEF:status=$database:ifOperStatus:AVERAGE",
			"CDEF:inputUtil=input,8,*,$interfaceTable{$intf}{ifSpeed},/,100,*",
			"CDEF:outputUtil=output,8,*,$interfaceTable{$intf}{ifSpeed},/,100,*",
			"CDEF:totalUtil=outputUtil,inputUtil,+,2,/",
			"LINE1:inputUtil#0033FF:In % Util",
			"LINE1:outputUtil#00AA00:Out % Util",
			"LINE2:totalUtil#000000:Total % Util",
			"LINE3:status#00FF00:Availability \\n",
			"GPRINT:inputUtil:AVERAGE:Avg In %1.2lf",
			"GPRINT:outputUtil:AVERAGE:Avg Out %1.2lf",
			"GPRINT:totalUtil:AVERAGE:Avg Total %1.2lf\\n",
			"GPRINT:status:AVERAGE:Avg Availability %1.2lf\\n",
			"COMMENT:Interface Speed $speed"
		);
	}
	### AS 23 Apr 02, second util graph without an avail line.
	if ( $type eq "autil" ) {
		if ( $interfaceTable{$intf}{ifSpeed} eq "auto" ) {
			 $interfaceTable{$intf}{ifSpeed} = 10000000;
		}
		if ( $title eq "short" ) { $title = "$node: $interfaceTable{$intf}{ifDescr} - $length"; }
		else { $title = "$node: $interfaceTable{$intf}{ifDescr} - $length from $datestamp_start to $datestamp_end"; }

		my $vlabel = $NMIS::config{graph_split} == 1 ? "% Avg Util" : "In(-) Out(+) % Avg Util" ;
		@options = (
			"--title", $title,
			"--vertical-label",$vlabel,
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			# Might be a good option on an active interface.
			#"--logarithmic",
			"DEF:input=$database:ifInOctets:AVERAGE",
			"DEF:output=$database:ifOutOctets:AVERAGE",
			"CDEF:inputUtil=input,8,*,$interfaceTable{$intf}{ifSpeed},/,100,*,$NMIS::config{graph_split},*",
			"CDEF:outputUtil=output,8,*,$interfaceTable{$intf}{ifSpeed},/,100,*",
			#"CDEF:totalUtil=outputUtil,inputUtil,+,2,/",
			"LINE1:inputUtil#0000ff:In % Util",
			"LINE1:outputUtil#00ff00:Out % Util",
			#"LINE2:totalUtil#000000:Total % Util\\n",
			"GPRINT:inputUtil:AVERAGE:Avg In %1.2lf",
			"GPRINT:outputUtil:AVERAGE:Avg Out %1.2lf",
			#"GPRINT:totalUtil:AVERAGE:Avg Total %1.2lf",
			"COMMENT:Interface Speed $speed"
		);
	}
	### Stephane Monnier - Packets stats Without Errors Stats - 25/11/2003
	elsif ( $type eq "pkts" ) {
		#ifInUcastPkts ifInNUcastPkts ifInDiscards ifInErrors
		#ifOutUcastPkts ifOutNUcastPkts ifOutDiscards ifOutErrors
		if ( $title eq "short" ) { $title = "$node: $interfaceTable{$intf}{ifDescr} - $length"; }
		else { $title = "$node: $interfaceTable{$intf}{ifDescr} - $length from $datestamp_start to $datestamp_end"; }

		@options = (
			"--title", $title,
			"--vertical-label", 'Packets/Second',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:ifInOctets=$database:ifInOctets:AVERAGE",
			"DEF:ifInUcastPkts=$database:ifInUcastPkts:AVERAGE",
			"DEF:ifInNUcastPkts=$database:ifInNUcastPkts:AVERAGE",
			"DEF:ifInDiscards=$database:ifInDiscards:AVERAGE",
			"DEF:ifInErrors=$database:ifInErrors:AVERAGE",
			"DEF:ifOutOctets=$database:ifOutOctets:AVERAGE",
			"DEF:ifOutUcastPkts=$database:ifOutUcastPkts:AVERAGE",
			"DEF:ifOutNUcastPkts=$database:ifOutNUcastPkts:AVERAGE",
			"DEF:ifOutDiscards=$database:ifOutDiscards:AVERAGE",
			"DEF:ifOutErrors=$database:ifOutErrors:AVERAGE",
			"DEF:MifInUcastPkts=$database:ifInUcastPkts:MAX",
			"DEF:MifInNUcastPkts=$database:ifInNUcastPkts:MAX",
			"DEF:MifOutUcastPkts=$database:ifOutUcastPkts:MAX",
			"DEF:MifOutNUcastPkts=$database:ifOutNUcastPkts:MAX",
			#Turn the ifxxOctets into Bits per second
			"CDEF:inputBits=ifInOctets,8,*",
			"CDEF:outputBits=ifOutOctets,8,*",
			#In packets should always include Discards and Errors as use bandwidth
			"CDEF:ifInPkts=ifInUcastPkts,ifInNUcastPkts,ifInDiscards,ifInErrors,+,+,+",
			#Out packets shouldn't as they don't leave the device
			"CDEF:ifOutPkts=ifOutUcastPkts,ifOutNUcastPkts,+",
			#Total Packets in and out.
			"CDEF:ifPkts=ifInPkts,ifOutPkts,+",
			#Max Packets
			"CDEF:MifInPkts=MifInUcastPkts,MifInNUcastPkts,+",
			"CDEF:MifOutPkts=MifOutUcastPkts,MifOutNUcastPkts,+",
			#Get average packet size stats
			"CDEF:avgInPkt=ifInOctets,ifInPkts,/",
			"CDEF:avgOutPkt=ifOutOctets,ifOutPkts,/",
			"CDEF:avgPkt=ifOutOctets,ifInOctets,+,ifPkts,/",
			#Draw some lines and stuff
			"AREA:ifInUcastPkts#0000aa:ifInUcastPkts/sec",
			"STACK:ifInNUcastPkts#0000ff:ifInNUcastPkts/sec\\n",
			"STACK:ifOutUcastPkts#00aa00:ifOutUcastPkts/sec",
			"STACK:ifOutNUcastPkts#00ff00:ifOutNUcastPkts/sec\\n",
			"LINE2:ifInPkts#0000ff:ifInPkts/sec",
			"LINE2:ifOutPkts#00ff00:ifOutPkts/sec",
			"LINE1:ifPkts#ff0000:ifPkts/sec\\n",
			"GPRINT:ifInUcastPkts:AVERAGE:Avg ifInUcastPkts %1.2lf",
			"GPRINT:ifInNUcastPkts:AVERAGE:Avg ifInNUcastPkts %1.2lf\\n",
			"GPRINT:ifOutUcastPkts:AVERAGE:Avg ifOutUcastPkts %1.2lf",
			"GPRINT:ifOutNUcastPkts:AVERAGE:Avg ifOutNUcastPkts %1.2lf\\n",
			#"COMMENT:\\\\l",
			"GPRINT:ifInPkts:AVERAGE:Avg ifInPkts %1.2lf",
			"GPRINT:ifOutPkts:AVERAGE:Avg ifOutPkts %1.2lf",
			"GPRINT:ifPkts:AVERAGE:Avg ifPkts %1.2lf",
			"GPRINT:MifInPkts:MAX:Max ifInPkts %1.2lf",
			"GPRINT:MifOutPkts:MAX:Max ifOutPkts %1.2lf\\n",
			"GPRINT:avgInPkt:AVERAGE:Avg In Packet Size %1.2lf",
			"GPRINT:avgOutPkt:AVERAGE:Avg Out Packet Size %1.2lf",
			"GPRINT:avgPkt:AVERAGE:Avg Packet Size %1.2lf\\n",
			"GPRINT:inputBits:AVERAGE:Avg In bits/sec %1.2lf",
			"GPRINT:outputBits:AVERAGE:Avg Out bits/sec %1.2lf",
			"GPRINT:ifInOctets:AVERAGE:Avg In bytes/sec %1.2lf",
			"GPRINT:ifOutOctets:AVERAGE:Avg Out bytes/sec %1.2lf"
		);
	}
	### Stephane Monnier - Error Packets stats - 25/11/2003
	elsif ( $type eq "epkts" ) {
        #ifOutUcastPkts ifOutNUcastPkts ifOutDiscards ifOutErrors
        @options = (
            "--title", "$node: $interfaceTable{$intf}{ifDescr} - $length from $datestamp_start to $datestamp_end",
            "--vertical-label", 'Percentage',
            "--start", "$start",
            "--end", "$end",
            "--width", "$width",
            "--height", "$height",
            "--imgformat", "PNG",
            "--interlace",
            "DEF:ifInUcastPkts=$database:ifInUcastPkts:AVERAGE",
            "DEF:ifInNUcastPkts=$database:ifInNUcastPkts:AVERAGE",
            "DEF:ifInDiscards=$database:ifInDiscards:AVERAGE",
            "DEF:ifOutUcastPkts=$database:ifOutUcastPkts:AVERAGE",
            "DEF:ifOutNUcastPkts=$database:ifOutNUcastPkts:AVERAGE",
            "DEF:ifInErrors=$database:ifInErrors:AVERAGE",
            "DEF:ifOutDiscards=$database:ifOutDiscards:AVERAGE",
            "DEF:ifOutErrors=$database:ifOutErrors:AVERAGE",
            #In packets should always include Discards and Errors as use bandwidth
            "CDEF:ifInPkts=ifInUcastPkts,ifInNUcastPkts,ifInDiscards,ifInErrors,+,+,+",
            #Out packets shouldn't as they don't leave the device
            "CDEF:ifOutPkts=ifOutUcastPkts,ifOutNUcastPkts,ifOutDiscards,ifOutErrors,+,+,+",
            # Percentage of In Error
            "CDEF:PInDiscards=ifInDiscards,ifInPkts,/,100,*",
            "CDEF:POutDiscards=ifOutDiscards,ifOutPkts,/,100,*",
            "CDEF:PInErrors=ifInErrors,ifInPkts,/,100,*",
            "CDEF:POutErrors=ifOutErrors,ifOutPkts,/,100,*",
            #Draw some lines and stuff
            "LINE2:PInDiscards#00cc00:ifInDiscards",
            "LINE2:POutDiscards#ffbb00:ifOutDiscards",
            "LINE2:PInErrors#aa00cc:ifInErrors",
            "LINE2:POutErrors#ff0000:ifOutErrors\\n",
            #"STACK:inputBits#aaaaaa:Agg In and Out bits/sec",
            "GPRINT:PInDiscards:AVERAGE:Percentage InDiscards %1.2lf %%",
            "GPRINT:PInErrors:AVERAGE:Percentage InErrors %1.2lf %%\\n",
            "GPRINT:POutDiscards:AVERAGE:Percentage OutDiscards %1.2lf %%",
            "GPRINT:POutErrors:AVERAGE:Percentage OutErrors %1.2lf %%"
		);
	}
	elsif ( $type eq "abits" ) {
		if ( $title eq "short" ) { $title = "$node: $interfaceTable{$intf}{ifDescr} - $length"; }
		else { $title = "$node: $interfaceTable{$intf}{ifDescr} - $length from $datestamp_start to $datestamp_end"; }

		my $vlabel = $NMIS::config{graph_split} == 1 ?  "% Avg bps" : "In(-) Out(+) % Avg bps" ;
		@options = (
			"--title", $title,
			"--vertical-label", $vlabel,
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:input=$database:ifInOctets:AVERAGE",
			"DEF:output=$database:ifOutOctets:AVERAGE",
			"DEF:status=$database:ifOperStatus:AVERAGE",
			"CDEF:inputBits=input,8,*,$NMIS::config{graph_split},*",
			"CDEF:outputBits=output,8,*",
			"LINE1:inputBits#0000ff:In bits/sec",
			"LINE1:outputBits#00ff00:Out bits/sec",
			#"STACK:inputBits#aaaaaa:Agg In and Out bits/sec\\n",
			"GPRINT:status:AVERAGE:Avg Availability %1.2lf",
			"GPRINT:inputBits:AVERAGE:Avg In bits/sec %1.2lf",
			"GPRINT:inputBits:MAX:Max In bits/sec %1.2lf",
			"GPRINT:outputBits:AVERAGE:Avg Out bits/sec %1.2lf",
			"GPRINT:outputBits:MAX:Max Out bits/sec %1.2lf",
			"HRULE:$interfaceTable{$intf}{ifSpeed}#ff0000",
			"COMMENT:Interface Speed $speed"
		);
		# draw a negative hrule if graphsplit says we should
		if ($NMIS::config{graph_split} == -1 ) {
			push ( @options, "HRULE:-$interfaceTable{$intf}{ifSpeed}#ff0000" );
		}
	}
	elsif ( $type eq "mbits" ) {
		if ( $title eq "short" ) { $title = "$node: $interfaceTable{$intf}{ifDescr} - $length"; }
		else { $title = "$node: $interfaceTable{$intf}{ifDescr} - $length from $datestamp_start to $datestamp_end"; }

		my $vlabel = $NMIS::config{graph_split} == 1 ?  "Max bps" : "In(-) Out(+) Max bps" ;
		@options = (
			"--title", $title,
			"--vertical-label", $vlabel,
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:input=$database:ifInOctets:MAX",
			"DEF:output=$database:ifOutOctets:MAX",
			"DEF:status=$database:ifOperStatus:AVERAGE",
			"CDEF:inputBits=input,8,*,$NMIS::config{graph_split},*",
			"CDEF:outputBits=output,8,*",
			"LINE1:inputBits#0000ff:In bits/sec",
			"LINE1:outputBits#00ff00:Out bits/sec",
			#"STACK:inputBits#aaaaaa:Agg In and Out bits/sec\\n",
			"GPRINT:status:AVERAGE:Avg Availability %1.2lf",
			#"GPRINT:inputBits:AVERAGE:Avg In bits/sec %1.2lf",
			"GPRINT:inputBits:MAX:Max In bits/sec %1.2lf",
			#"GPRINT:outputBits:AVERAGE:Avg Out bits/sec %1.2lf",
			"GPRINT:outputBits:MAX:Max Out bits/sec %1.2lf",
			"HRULE:$interfaceTable{$intf}{ifSpeed}#ff0000",
			"COMMENT:Interface Speed $speed"
		);
		# draw a negative hrule if graphsplit says we should
		if ($NMIS::config{graph_split} == -1 ) {
			push ( @options, "HRULE:-$interfaceTable{$intf}{ifSpeed}#ff0000" );
		}
	}
	### AS 23 Apr 02, removed aggregate bits line.
	elsif ( $type eq "bits" ) {
		#sample code for this came from Andres Kroonmaa [andre@online.ee]
		#new-mavg = ( (last-mavg - datasample) * weight + datasample
		#weight=0.983
		#rrdtool graph $png -a PNG \
		#  -h 400 \
		#  -w 1000 \
		#  --alt-y-grid  \
		#  --base 1000 \
		#  -s -7week     \
		#  DEF:max=$rrdfile:ds1:MAX     \
		#  CDEF:inp2=max,UN,1,max,IF      \
		#  CDEF:mavg=PREV,UN,inp2,PREV,IF,inp2,-,$weight,*,inp2,+      \
		#  "LINE1:inp2#FF0000:Max values\n"       \
		#  "LINE3:mavg#0000FF:Moving average, weight $weight"

		if ( $title eq "short" ) { $title = "$interfaceTable{$intf}{ifDescr} - $length"; }
		else { $title = "$node: $interfaceTable{$intf}{ifDescr} - $length from $datestamp_start to $datestamp_end"; }
		my $vlabel = $NMIS::config{graph_split} == 1 ? "% Avg bps" : "In(-) Out(+) % Avg bps" ;

		$weight=0.983;
		@options = (
			"--title", "$title",
			"--vertical-label", $vlabel,
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:input=$database:ifInOctets:AVERAGE",
			"DEF:output=$database:ifOutOctets:AVERAGE",
			"DEF:maxinput=$database:ifInOctets:MAX",
			"DEF:maxoutput=$database:ifOutOctets:MAX",
			"DEF:status=$database:ifOperStatus:AVERAGE",
			"CDEF:inputBits=input,8,*,$NMIS::config{graph_split},*",
			"CDEF:outputBits=output,8,*",
			"CDEF:maxin=maxinput,8,*,$NMIS::config{graph_split},*",
			"CDEF:maxout=maxoutput,8,*",
			# moving avg calcs should be on average in/out, not max values,as granularity is lost for bigger slices.
			#"CDEF:inp2in=maxin,UN,1,maxin,IF",
			#"CDEF:inp2out=maxout,UN,1,maxout,IF",
			"CDEF:inp2in=inputBits,UN,1,inputBits,IF",
			"CDEF:inp2out=outputBits,UN,1,outputBits,IF",
			"CDEF:mavgin=PREV,UN,inp2in,PREV,IF,inp2in,-,$weight,*,inp2in,+",
			"CDEF:mavgout=PREV,UN,inp2out,PREV,IF,inp2out,-,$weight,*,inp2out,+",
			"LINE2:inputBits#0000ff:In bits/sec",
			"LINE2:outputBits#00ff00:Out bits/sec",
			#"STACK:inputBits#aaaaaa:Agg In and Out bits/sec\\l",
			#"LINE1:inp2#FF0000:Max values\n",
			"LINE3:mavgin#0000AA:Input Moving average, weight $weight",
			"LINE2:mavgout#00AA00:Output Moving average, weight $weight\\l",
			"GPRINT:inputBits:AVERAGE:Avg In bits/sec %1.2lf",
			"GPRINT:inputBits:MAX:Max In bits/sec %1.2lf\\l",
			"GPRINT:outputBits:AVERAGE:Avg Out bits/sec %1.2lf",
			"GPRINT:outputBits:MAX:Max Out bits/sec %1.2lf\\l",
			"HRULE:$interfaceTable{$intf}{ifSpeed}#ff0000",
			"GPRINT:status:AVERAGE:Avg Availability %1.2lf",
			"COMMENT:Interface Speed $speed"
		);
		# draw a negative hrule if graphsplit says we should
		if ($NMIS::config{graph_split} == -1 ) {
			push ( @options, "HRULE:-$interfaceTable{$intf}{ifSpeed}#ff0000" );
		}
	}
	elsif ( $type eq "health" ) {
		if ( $title eq "short" ) { $title = "$node health $length"; }
		else { $title = "$node  - $length from $datestamp_start to $datestamp_end"; }
		@options = (
			"--title", "$title",
			"--vertical-label", '% Health Statistics',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:reach=$database:reachability:AVERAGE",
			"DEF:avail=$database:availability:AVERAGE",
			"DEF:health=$database:health:AVERAGE",
			"DEF:loss=$database:loss:AVERAGE",
			"LINE2:avail#00ff00:Availability",
			"LINE2:health#ff9900:Health",
			"LINE2:reach#0000ff:Reachability",
			"LINE2:loss#ff00ff:Ping_loss\\l",
			"GPRINT:reach:AVERAGE:Avg Reachable %1.2lf",
			"GPRINT:avail:AVERAGE:Avg Available %1.2lf",
			"GPRINT:health:AVERAGE:Avg Health %1.2lf",
			"GPRINT:loss:AVERAGE:Avg Ping loss %1.2lf"
		);
	}
	### AS 8 June 2002 - Adding overall network metrics RRD's
	elsif ( $type eq "metrics" and $width < 300 ) {
		if ( $title eq "short" ) { $title = "$group Metrics $length"; }
		else { $title = "$group  - $length from $datestamp_start to $datestamp_end"; }
		@options = (
			#"--title", "$title",
			"--vertical-label", 'Metrics',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:avail=$database:availability:AVERAGE",
			"DEF:health=$database:health:AVERAGE",
			"DEF:reach=$database:reachability:AVERAGE",
			"DEF:status=$database:status:AVERAGE",
			"LINE3:avail#00ff00:Availability",
			"LINE3:health#ff9900:Health",
			"LINE2:reach#0000ff:Reachability",
			"LINE2:status#ff0000:Status"
			#"GPRINT:reach:AVERAGE:Avg Reachable %1.2lf",
			#"GPRINT:avail:AVERAGE:Avg Available %1.2lf",
			#"GPRINT:health:AVERAGE:Avg Health %1.2lf",
			#"GPRINT:status:AVERAGE:Avg Status %1.2lf"
		);
	}
	elsif ( $type eq "metrics" ) {
		if ( $title eq "short" ) { $title = "$group Metrics $length"; }
		else { $title = "$group  - $length from $datestamp_start to $datestamp_end"; }
		my $nl = "\\l";
		if ( $height < 100 ) { 
			$nl = "";
			$title = "";
		}
		@options = (
			"--title", "$title",
			"--vertical-label", 'Network Metrics',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:avail=$database:availability:AVERAGE",
			"DEF:health=$database:health:AVERAGE",
			"DEF:reach=$database:reachability:AVERAGE",
			"DEF:status=$database:status:AVERAGE",
			"LINE3:avail#00ff00:Availability",
			"LINE3:health#ff9900:Health",
			"LINE2:reach#0000ff:Reachability",
			"LINE2:status#ff0000:Status",
			"GPRINT:avail:AVERAGE:Avg Available %1.2lf",
			"GPRINT:health:AVERAGE:Avg Health %1.2lf",
			"GPRINT:reach:AVERAGE:Avg Reachable %1.2lf",
			"GPRINT:status:AVERAGE:Avg Status %1.2lf"
		);
	}
	elsif ( $type eq "response" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", 'Response Time in ms',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:response=$database:responsetime:AVERAGE",
			"DEF:mresponse=$database:responsetime:MAX",
			"LINE1:response#0000ff:Response\\n",
			"HRULE:250#00ff00",
			"HRULE:500#0000ff",
			"HRULE:1000#ff0000",
			"GPRINT:mresponse:MAX:Max Response Time %1.2lf",
			"GPRINT:response:AVERAGE:Avg Response Time %1.2lf"
		);
	}
	elsif ( $type eq "cpu" ) {
		my $ttl = "$node - $length from $datestamp_start to $datestamp_end";
		if ( $title eq "small" ) { $ttl = "CPU util. $node"; }
		@options = (
			"--title", $ttl,
			"--vertical-label", "% CPU Util.",
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:avgBusy1=$database:avgBusy1:AVERAGE",
			"DEF:avgBusy5=$database:avgBusy5:AVERAGE",
			"LINE1:avgBusy1#00ff00:Avg Busy 1min",
			"LINE1:avgBusy5#0000ff:Avg Busy 5min"
		);
		if ($title ne "small") {
			push @options, "GPRINT:avgBusy1:AVERAGE:Avg Busy 1min %1.2lf %%";
			push @options, "GPRINT:avgBusy1:MAX:Max Busy 1min %1.2lf %%";
			push @options, "GPRINT:avgBusy5:AVERAGE:Avg Busy 5min %1.2lf %%";
			push @options, "GPRINT:avgBusy5:MAX:Max Busy 5min %1.2lf %%";
		}
	}
	### Cologne and Stephane CBQoS Support
	elsif ( $type =~ /cbqos/ ) {
		if ( $item eq "" ) {
			# display all class-maps in one graph
			my $i;
			my $avgppr;
			my $maxppr;
			my $avgdbr;
			my $maxdbr;
			my $direction = ($type eq "cbqos-in") ? "input" : "output" ;
			my $vlabel = "Avg Bits per Second";
			if ( $title eq "short" ) { 
				$title = "$node: $interfaceTable{$intf}{ifDescr} $direction - $CBQosNames[0]";
				$vlabel = "Avg bps";
			} else { 
				$title = "$node: $interfaceTable{$intf}{ifDescr} $direction - CBQoS - $length from $datestamp_start to $datestamp_end";
			}
			@options = (
				"--title", $title,
				"--vertical-label",$vlabel,
				"--start", "$start",
				"--end", "$end",
				"--width", "$width",
				"--height", "$height",
				"--imgformat", "PNG",
				"--interlace"
			);
			# calculate the sum (avg and max) of all Classmaps for PrePolicy and Drop
			$avgppr = "CDEF:avgPrePolicyBitrate=0";
			$maxppr = "CDEF:maxPrePolicyBitrate=0";
			$avgdbr = "CDEF:avgDropBitrate=0";
			$maxdbr = "CDEF:maxDropBitrate=0";
			for $i (1..$#CBQosNames) {
				$database = getRRDFileName(type => $type, node => $node, group => $group, nodeType => $NMIS::systemTable{nodeType}, extName => $interfaceTable{$intf}{ifDescr}, item => $CBQosNames[$i]);

				push(@options,"DEF:avgPPB$i=$database:PrePolicyByte:AVERAGE");
				push(@options,"DEF:maxPPB$i=$database:PrePolicyByte:MAX");
				push(@options,"DEF:avgDB$i=$database:DropByte:AVERAGE");
				push(@options,"DEF:maxDB$i=$database:DropByte:MAX");
				push(@options,"CDEF:avgPPR$i=avgPPB$i,8,*");
				push(@options,"CDEF:maxPPR$i=maxPPB$i,8,*");
				push(@options,"CDEF:avgDBR$i=avgDB$i,8,*");
				push(@options,"CDEF:maxDBR$i=maxDB$i,8,*");
				push(@options,"LINE1:avgPPR$i#$CBQosValues{$intf.$CBQosNames[$i]}{'Color'}:$CBQosNames[$i]");
				$avgppr = $avgppr.",avgPPR$i,+";
				$maxppr = $maxppr.",maxPPR$i,+";
				$avgdbr = $avgdbr.",avgDBR$i,+";
				$maxdbr = $maxdbr.",maxDBR$i,+";
			}
			push(@options,$avgppr);
			push(@options,$maxppr);
			push(@options,$avgdbr);
			push(@options,$maxdbr);
			push(@options,"COMMENT:\\l");
			push(@options,"GPRINT:avgPrePolicyBitrate:AVERAGE:Avg PrePolicyBitrate %1.0lf bps");
			push(@options,"GPRINT:maxPrePolicyBitrate:MAX:Max PrePolicyBitrate %1.0lf bps\\l");
			push(@options,"GPRINT:avgDropBitrate:AVERAGE:Avg DropBitrate %1.0lf bps");
			push(@options,"GPRINT:maxDropBitrate:MAX:Max DropBitrate %1.0lf bps");

			# reset $database so any errors reference the correct class-map
			$database = getRRDFileName(type => $type, node => $node, group => $group, nodeType => $NMIS::systemTable{nodeType}, extName => $interfaceTable{$intf}{ifDescr}, item => $CBQosNames[0]);

		} else {
			# display the selected class-map (push button)
			$speed = &convertIfSpeed($CBQosValues{$intf.$item}{'CfgRate'});
			my $direction = ($type eq "cbqos-in") ? "input" : "output" ;
			@options = (
				"--title", "$interfaceTable{$intf}{ifDescr} $direction - $item - $length from $datestamp_start to $datestamp_end",
				"--vertical-label", 'Avg Bits per Second',
				"--start", "$start",
				"--end", "$end",
				"--width", "$width",
				"--height", "$height",
				"--imgformat", "PNG",
				"--interlace",
				"DEF:PrePolicyByte=$database:PrePolicyByte:AVERAGE", 
				"DEF:maxPrePolicyByte=$database:PrePolicyByte:MAX", 
				"DEF:DropByte=$database:DropByte:AVERAGE", 
				"DEF:maxDropByte=$database:DropByte:MAX", 
				"DEF:PrePolicyPkt=$database:PrePolicyPkt:AVERAGE", 
				"DEF:DropPkt=$database:DropPkt:AVERAGE", 
				"DEF:NoBufDropPkt=$database:NoBufDropPkt:AVERAGE", 
				"CDEF:PrePolicyBitrate=PrePolicyByte,8,*",
				"CDEF:maxPrePolicyBitrate=maxPrePolicyByte,8,*",
				"CDEF:DropBitrate=DropByte,8,*",
				"LINE1:PrePolicyBitrate#$CBQosValues{$intf.$item}{'Color'}:PrePolicyBitrate",
				"LINE1:DropBitrate#ff0000:DropBitrate\\l",
				"GPRINT:PrePolicyBitrate:AVERAGE:Avg PrePolicyBitrate %1.0lf bps",
				"GPRINT:maxPrePolicyBitrate:MAX:Max PrePolicyBitrate %1.0lf bps",
				"GPRINT:PrePolicyByte:AVERAGE:Avg Bytes transfered %1.0lf",
				"GPRINT:PrePolicyPkt:AVERAGE:Avg Packets transfered %1.0lf\\l",
				"GPRINT:DropByte:AVERAGE:Avg Bytes dropped %1.0lf",
				"GPRINT:maxDropByte:MAX:Max Bytes dropped %1.0lf",
				"GPRINT:DropPkt:AVERAGE:Avg Packets dropped %1.0lf",
				"GPRINT:NoBufDropPkt:AVERAGE:Avg Packets No buffer dropped %1.0lf",
				"COMMENT:$CBQosValues{$intf.$item}{'CfgType'} $speed"
			);
		}
	}
	### Andrew Sargent Modem Support
	elsif ( $type eq "modem" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", '% Modem Utilisation',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:TotalModems=$database:InstalledModem:MAX", 
			"DEF:ModemsInUse=$database:ModemsInUse:MAX", 
			"DEF:ModemsAvailable=$database:ModemsAvailable:MAX", 
			"DEF:ModemsUnavailable=$database:ModemsUnavailable:MAX", 
			"DEF:ModemsOffline=$database:ModemsOffline:MAX", 
			"DEF:ModemsDead=$database:ModemsDead:MAX", 
			"AREA:ModemsDead#bbbbbb:Dead Modems",
			"STACK:ModemsOffline#aaaaaa:Modems Offline",
			"STACK:ModemsInUse#0000ff:Modems InUse",
			"LINE2:TotalModems#00ff00:Total Modems",
			"LINE2:ModemsAvailable#ff0000:Modems Available",
			"LINE1:ModemsOffline#555555:Modems Offline",
			"GPRINT:TotalModems:LAST:TotalModems %1.0lf",
			"GPRINT:ModemsInUse:LAST:ModemsInUse %1.0lf",
			"GPRINT:ModemsAvailable:LAST:ModemsAvailable %1.0lf",
			"GPRINT:ModemsUnavailable:LAST:ModemsUnavailable %1.0lf",
			"GPRINT:ModemsOffline:LAST:ModemsOffline %1.0lf",
			"GPRINT:ModemsDead:LAST:ModemsDead %1.0lf"
		);
	}
	### server temperature
	elsif ( $type eq "degree" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", 'Server Temperature',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:tempReading=$database:tempReading:AVERAGE",
			"DEF:tempMinWarn=$database:tempMinWarn:AVERAGE",
			"DEF:tempMaxWarn=$database:tempMaxWarn:AVERAGE",
			"CDEF:xtempReading=tempReading,10,/",
			"CDEF:xtempMinWarn=tempMinWarn,10,/",
			"CDEF:xtempMaxWarn=tempMaxWarn,10,/",
			"LINE2:xtempReading#00ff00:Avg Temp",
			"LINE2:xtempMinWarn#0000ff:Min Alarm Temp",
			"LINE2:xtempMaxWarn#ff0000:Max Alarm Temp",
			"GPRINT:xtempReading:AVERAGE:Avg Temp %1.2lf Deg.",
			"GPRINT:xtempReading:MAX:Max Temp %1.2lf Deg.",
		);
	}
	### PIX Connections
	elsif ( $type eq "pix-conn" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", 'PIX Connections',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:connectionsInUse=$database:connectionsInUse:AVERAGE",
			"DEF:connectionsHigh=$database:connectionsHigh:AVERAGE",
			"LINE1:connectionsInUse#00ff00:Connections In Use",
			"LINE1:connectionsHigh#0000ff:Connections High",
			"GPRINT:connectionsInUse:AVERAGE:Connections In Use %1.0lf",
			"GPRINT:connectionsHigh:AVERAGE:Connections High %1.0lf",
		);
	}
	### 3com
	elsif ( $type eq "a3bandwidth" ) {  
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end", 
			"--vertical-label", '% System Bandwidth', 
			"--start", "$start", 
			"--end", "$end", 
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:BandwidthUsed=$database:BandwidthUsed:AVERAGE", 
			#"DEF:ErrorsPerPackets=$database:ErrorsPerPackets:AVERAGE", 
			"LINE1:BandwidthUsed#0000ff:Avg Bandwidth",
			#"LINE1:ErrorsPerPackets#aa0000:Errors Per 10000 Packets",
			"GPRINT:BandwidthUsed:AVERAGE:Avg Bandwidth %1.2lf %%",
			"GPRINT:BandwidthUsed:MAX:Max Bandwidth %1.2lf %%",
			#"GPRINT:ErrorsPerPackets:AVERAGE:Avg Errors Per 10000 Packets %1.2lf",
			#"GPRINT:ErrorsPerPackets:MAX:MAX Errors Per 10000 Packets %1.2lf",
		);
	}
	elsif ( $type eq "a3traffic" ) {  
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end", 
			"--vertical-label", 'System Traffic Count', 
			"--start", "$start", 
			"--end", "$end", 
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			#"DEF:ReadableFrames=$database:ReadableFrames:AVERAGE", 
			#"DEF:UnicastFrames=$database:UnicastFrames:AVERAGE", 
			#"DEF:MulticastFrames=$database:MulticastFrames:AVERAGE", 
			#"DEF:BroadcastFrames=$database:BroadcastFrames:AVERAGE", 
			"DEF:ReadableOctets=$database:ReadableOctets:AVERAGE", 
			"DEF:UnicastOctets=$database:UnicastOctets:AVERAGE", 
			"DEF:MulticastOctets=$database:MulticastOctets:AVERAGE", 
			"DEF:BroadcastOctets=$database:BroadcastOctets:AVERAGE", 
			#"LINE1:ReadableFrames#0033ff:ReadableFrames", 
			#"LINE1:UnicastFrames#ff0000:UnicastFrames", 
			#"LINE1:MulticastFrames#33ff99:MulticastFrames", 
			#"LINE1:BroadcastFrames#00aa33:BroadcastFrames", 
			"LINE1:ReadableOctets#aa0000:ReadableOctets", 
			"LINE1:UnicastOctets#990099:UnicastOctets", 
			"LINE1:MulticastOctets#ff9933:MulticastOctets", 
			"LINE1:BroadcastOctets#888888:BroadcastOctets", 
			#"GPRINT:ReadableFrames:AVERAGE:ReadableFrames %1.0lf",
			#"GPRINT:UnicastFrames:AVERAGE:UnicastFrames %1.0lf",
			#"GPRINT:MulticastFrames:AVERAGE:MulticastFrames %1.0lf",
			#"GPRINT:BroadcastFrames:AVERAGE:BroadcastFrames %1.0lf",
			"GPRINT:ReadableOctets:AVERAGE:ReadableOctets %1.0lf",
			"GPRINT:UnicastOctets:AVERAGE:UnicastOctets %1.0lf",
			"GPRINT:MulticastOctets:AVERAGE:MulticastOctets %1.0lf",
			"GPRINT:BroadcastOctets:AVERAGE:BroadcastOctets %1.0lf",
		);
	}
	elsif ( $type eq "a3errors" ) {  
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end", 
			"--vertical-label", 'System Error Count', 
			"--start", "$start", 
			"--end", "$end", 
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:FCSErrors=$database:FCSErrors:AVERAGE", 
			"DEF:AlignmentErrors=$database:AlignmentErrors:AVERAGE", 
			"DEF:FrameTooLongs=$database:FrameTooLongs:AVERAGE", 
			"DEF:ShortEvents=$database:ShortEvents:AVERAGE", 
			"DEF:Runts=$database:Runts:AVERAGE", 
			"DEF:TxCollisions=$database:TxCollisions:AVERAGE", 
			"DEF:LateEvents=$database:LateEvents:AVERAGE", 
			"DEF:VeryLongEvents=$database:VeryLongEvents:AVERAGE", 
			"DEF:DataRateMismatches=$database:DataRateMismatches:AVERAGE", 
			"DEF:AutoPartitions=$database:AutoPartitions:AVERAGE", 
			"DEF:TotalErrors=$database:TotalErrors:AVERAGE", 
	        "DEF:ErrorsPerPackets=$database:ErrorsPerPackets:AVERAGE",
			"LINE1:FCSErrors#0033ff:FCSErrors", 
			"LINE1:AlignmentErrors#ff0000:AlignmentErrors", 
			"LINE1:FrameTooLongs#33ff99:FrameTooLongs", 
			"LINE1:ShortEvents#00aa33:ShortEvents", 
			"LINE1:Runts#0000aa:Runts", 
			"LINE1:TxCollisions#aa0000:TxCollisions", 
			"LINE1:LateEvents#990099:LateEvents", 
			"LINE1:VeryLongEvents#ff9933:VeryLongEvents", 
			"LINE1:DataRateMismatches#888888:DataRateMismatches", 
			"LINE1:AutoPartitions#ff00cc:AutoPartitions", 
			"LINE1:TotalErrors#3399cc:TotalErrors", 
	        "LINE1:ErrorsPerPackets#aa0000:Errors Per 10000 Packets",
	 		"GPRINT:FCSErrors:AVERAGE:FCSErrors %1.0lf",
			"GPRINT:AlignmentErrors:AVERAGE:AlignmentErrors %1.0lf",
			"GPRINT:FrameTooLongs:AVERAGE:FrameTooLongs %1.0lf",
			"GPRINT:ShortEvents:AVERAGE:ShortEvents %1.0lf",
			"GPRINT:Runts:AVERAGE:Runts %1.0lf",
			"GPRINT:TxCollisions:AVERAGE:TxCollisions %1.0lf",
			"GPRINT:LateEvents:AVERAGE:LateEvents %1.0lf",
			"GPRINT:VeryLongEvents:AVERAGE:VeryLongEvents %1.0lf",
			"GPRINT:DataRateMismatches:AVERAGE:DataRateMismatches %1.0lf",
			"GPRINT:AutoPartitions:AVERAGE:AutoPartitions %1.0lf",
			"GPRINT:TotalErrors:AVERAGE:TotalErrors %1.0lf",
	        "GPRINT:ErrorsPerPackets:AVERAGE:Avg Errors Per 10000 Packets %1.2lf",
	       	"GPRINT:ErrorsPerPackets:MAX:MAX Errors Per 10000 Packets %1.2lf",
		);
	}
	### AS 1 Apr 02 - Integrating Phil Reilly's Nortel changes
	elsif ( $type eq "acpu" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", '% CPU Utilisation',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:rcSysCpuUtil=$database:rcSysCpuUtil:AVERAGE",
			"DEF:rcSysSwitchFabricUtil=$database:rcSysSwitchFabricUtil:AVERAGE",
			"DEF:rcSysBufferUtil=$database:rcSysBufferUtil:AVERAGE",
			"LINE1:rcSysCpuUtil#00ff00:rcSysCpuUtil",
			"LINE1:rcSysSwitchFabricUtil#0000ff:rcSysSwitchFabricUtil",
			"LINE1:rcSysBufferUtil#00ffff:rcSysBufferUtil",
			"GPRINT:rcSysCpuUtil:AVERAGE:Avg rcSysCpuUtil %1.2lf",
			"GPRINT:rcSysCpuUtil:MAX:Max rcSysCpuUtil %1.2lf",
			"GPRINT:rcSysSwitchFabricUtil:AVERAGE:Avg rcSysSwitchFabricUtil %1.2lf",
			"GPRINT:rcSysSwitchFabricUtil:MAX:Max rcSysSwitchFabricUtil %1.2lf",
			"GPRINT:rcSysBufferUtil:AVERAGE:Avg rcSysBufferUtil %1.2lf",
			"GPRINT:rcSysBufferUtil:MAX:Max rcSysBufferUtil %1.2lf"
		);
	}
	elsif ( $type eq "traffic" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", '% System Traffic',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:sysTraffic=$database:sysTraffic:AVERAGE",
			"LINE1:sysTraffic#00ff00:Avg Traffic",
			"GPRINT:sysTraffic:AVERAGE:Avg Traffic %1.2lf %%",
			"GPRINT:sysTraffic:MAX:Max Traffic %1.2lf %%"
		);
	}
	elsif ( $type eq "pvc" ) {

		if ( $title eq "short" ) { $title = "$node PVC $length"; }
		else { $title = "$node - $length from $datestamp_start to $datestamp_end"; }

		@options = (
			"--title", $title,
			"--vertical-label", 'PVC Stats',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:ReceivedBECNs=$database:ReceivedBECNs:MAX",
			"DEF:ReceivedFECNs=$database:ReceivedFECNs:MAX",
			#"DEF:ReceivedOctets=$database:ReceivedOctets:AVERAGE",
			#"DEF:SentOctets=$database:SentOctets:AVERAGE",
			#"DEF:State=$database:State:AVERAGE",
			"LINE2:ReceivedBECNs#FF0000:ReceivedBECNs",
			"STACK:ReceivedFECNs#FF6600:ReceivedFECNs",
			#"LINE1:ReceivedOctets#00FF00:ReceivedOctets",
			#"LINE1:SentOctets#0000FF:SentOctets",
			#"LINE1:State#000000:State\\l",
			"GPRINT:ReceivedBECNs:AVERAGE:Avg Rcvd BECNs %1.2lf",
			"GPRINT:ReceivedBECNs:MAX:Max Rcvd BECNs %1.2lf",
			"GPRINT:ReceivedFECNs:AVERAGE:Avg Rcvd FECNs %1.2lf",
			"GPRINT:ReceivedFECNs:MAX:Max Rcvd FECNs %1.2lf"
		);
	}
	### Mike McHenry 2005
	elsif ( $type eq "calls" ) {

		my $device = ($intf eq "") ? "total" : $interfaceTable{$intf}{ifDescr};
		if ( $title eq "short" ) { $title = "$node Calls $length"; }
		else { $title = "$node - $device - $length from $datestamp_start to $datestamp_end"; }

		# display Calls summarized or only one port
		@options = (
			"--title", $title,
			"--vertical-label","Call Stats",
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace"
		);

		my $CallCount = "CDEF:CallCount=0";
		my $AvailableCallCount = "CDEF:AvailableCallCount=0";
		my $totalIdle = "CDEF:totalIdle=0";
		my $totalUnknown = "CDEF:totalUnknown=0";
		my $totalAnalog = "CDEF:totalAnalog=0";
		my $totalDigital = "CDEF:totalDigital=0";
		my $totalV110 = "CDEF:totalV110=0";
		my $totalV120 = "CDEF:totalV120=0";
		my $totalVoice = "CDEF:totalVoice=0";

		my @if = split /,/,$NMIS::systemTable{typedraw_calls};
		for my $i (1..$#if) {

			if ($intf eq "") { $extName = $interfaceTable{$if[$i]}{ifDescr}; } else { $extName = $interfaceTable{$intf}{ifDescr}; }
			$database = getRRDFileName(type => $type, node => $node, group => $group, nodeType => $NMIS::systemTable{nodeType}, extName => $extName);

			push(@options,"DEF:CallCount$i=$database:CallCount:MAX");
			push(@options,"DEF:AvailableCallCount$i=$database:AvailableCallCount:MAX");
			push(@options,"DEF:totalIdle$i=$database:totalIdle:MAX");
			push(@options,"DEF:totalUnknown$i=$database:totalUnknown:MAX");
			push(@options,"DEF:totalAnalog$i=$database:totalAnalog:MAX");
			push(@options,"DEF:totalDigital$i=$database:totalDigital:MAX");
			push(@options,"DEF:totalV110$i=$database:totalV110:MAX");
			push(@options,"DEF:totalV120$i=$database:totalV120:MAX");
			push(@options,"DEF:totalVoice$i=$database:totalVoice:MAX");

			$CallCount .= ",CallCount$i,+";
			$AvailableCallCount .= ",AvailableCallCount$i,+";
			$totalIdle .= ",totalIdle$i,+";
			$totalUnknown .= ",totalUnknown$i,+";
			$totalAnalog .= ",totalAnalog$i,+";
			$totalDigital .= ",totalDigital$i,+";
			$totalV110 .= ",totalV110$i,+";
			$totalV120 .= ",totalV120$i,+";
			$totalVoice .= ",totalVoice$i,+";
			if ($intf ne "") { last; }
		}

		push(@options,$CallCount);
		push(@options,$AvailableCallCount);
		push(@options,$totalIdle);
		push(@options,$totalUnknown);
		push(@options,$totalAnalog);
		push(@options,$totalDigital);
		push(@options,$totalV110);
		push(@options,$totalV120);
		push(@options,$totalVoice);

		push(@options,"LINE1:AvailableCallCount#FFFF00:AvailableCallCount");
		push(@options,"LINE2:totalIdle#000000:totalIdle");
		push(@options,"LINE2:totalUnknown#FF0000:totalUnknown");
		push(@options,"LINE2:totalAnalog#00FFFF:totalAnalog");
		push(@options,"LINE2:totalDigital#0000FF:totalDigital");
		push(@options,"LINE2:totalV110#FF0080:totalV110");
		push(@options,"LINE2:totalV120#800080:totalV120");
		push(@options,"LINE2:totalVoice#00FF00:totalVoice");
		push(@options,"COMMENT:\\l");
		push(@options,"GPRINT:AvailableCallCount:MAX:Available Call Count %1.2lf");
		push(@options,"GPRINT:CallCount:MAX:Total Call Count %1.0lf");

		# reset $database so any errors gives information
		$database = getRRDFileName(type => $type, node => $node, group => $group, nodeType => $NMIS::systemTable{nodeType}, extName => "dummy");

	}
	elsif ( $type eq "ip" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			### KS 2 Jan 03 - Changing IP Routing to IP Statistics
			"--vertical-label", 'IP Packet Statistics',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:ipInReceives=$database:ipInReceives:AVERAGE",
			"DEF:ipForwDatagrams=$database:ipForwDatagrams:AVERAGE",
			"DEF:ipInDelivers=$database:ipInDelivers:AVERAGE",
			"DEF:ipOutNoRoutes=$database:ipOutNoRoutes:AVERAGE",
			"AREA:ipInReceives#cccccc:IP Packets Received",
			"LINE1:ipForwDatagrams#0000ff:IP Packets Forwarded",
			"STACK:ipInDelivers#000000:IP Packets Local",
			"LINE2:ipOutNoRoutes#ff0000:IP No Routes",
			"GPRINT:ipInReceives:AVERAGE:Avg Received %1.2lf",
			"GPRINT:ipInReceives:MAX:Max Received %1.2lf",
			"GPRINT:ipForwDatagrams:AVERAGE:Avg Forwarded %1.2lf",
			"GPRINT:ipForwDatagrams:MAX:Max Forwarded %1.2lf",
			"GPRINT:ipInDelivers:AVERAGE:Avg Local %1.2lf",
			"GPRINT:ipInDelivers:MAX:Max Local %1.2lf",
			"GPRINT:ipOutNoRoutes:AVERAGE:Avg No Routes %1.2lf",
			"GPRINT:ipOutNoRoutes:MAX:Max No Routes %1.2lf"
		);
	}
	elsif ( $type eq "frag" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", 'Fragmentation/Reassembly',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:ipReasmReqds=$database:ipReasmReqds:AVERAGE",
			"DEF:ipReasmOKs=$database:ipReasmOKs:AVERAGE",
			"DEF:ipReasmFails=$database:ipReasmFails:AVERAGE",
			"DEF:ipFragOKs=$database:ipFragOKs:AVERAGE",
			"DEF:ipFragFails=$database:ipFragFails:AVERAGE",
			"DEF:ipFragCreates=$database:ipFragCreates:AVERAGE",
			"DEF:ipInDelivers=$database:ipInDelivers:AVERAGE",
			"DEF:MipReasmReqds=$database:ipReasmReqds:MAX",
			"DEF:MipReasmOKs=$database:ipReasmOKs:MAX",
			"DEF:MipReasmFails=$database:ipReasmFails:MAX",
			"DEF:MipFragOKs=$database:ipFragOKs:MAX",
			"DEF:MipFragFails=$database:ipFragFails:MAX",
			"DEF:MipFragCreates=$database:ipFragCreates:MAX",
			# express all as a % of ipInDelivers
			# averages
			"CDEF:ReasmReqds=ipReasmReqds,ipInDelivers,/,100,*",
			"CDEF:ReasmOKs=ipReasmOKs,ipInDelivers,/,100,*",
			"CDEF:ReasmFails=ipReasmFails,ipInDelivers,/,100,*",
			"CDEF:FragOKs=ipFragOKs,ipInDelivers,/,100,*",
			"CDEF:FragFails=ipFragFails,ipInDelivers,/,100,*",
			"CDEF:FragCreates=ipFragCreates,ipInDelivers,/,100,*",
			# maximums
			"CDEF:MReasmReqds=MipReasmReqds,ipInDelivers,/,100,*",
			"CDEF:MReasmOKs=MipReasmOKs,ipInDelivers,/,100,*",
			"CDEF:MReasmFails=MipReasmFails,ipInDelivers,/,100,*",
			"CDEF:MFragOKs=MipFragOKs,ipInDelivers,/,100,*",
			"CDEF:MFragFails=MipFragFails,ipInDelivers,/,100,*",
			"CDEF:MFragCreates=MipFragCreates,ipInDelivers,/,100,*",
			# print some lines, with fails stacked on top
			"LINE1:FragOKs#00ff00:Fragmentation OK",
			"LINE2:FragFails#ff0000:Fragmentation Fail",
			"LINE1:ReasmOKs#0033aa:Reassembly OK",
			"LINE2:ReasmFails#000000:Reassembly Fail",
			# print some summary numbers.
			"GPRINT:ReasmReqds:AVERAGE:Avg ReasmReqd %1.2lf %%",
			"GPRINT:MReasmReqds:MAX:Max ReasmReqd %1.2lf %%",
			"GPRINT:ReasmOKs:AVERAGE:Avg ReasmOK %1.2lf %%",
			"GPRINT:MReasmOKs:MAX:Max ReasmOK %1.2lf %%",
			"GPRINT:ReasmFails:AVERAGE:Avg ReasmFail %1.2lf %%",
			"GPRINT:MReasmFails:MAX:Max ReasmFail %1.2lf %%",
			"GPRINT:FragOKs:AVERAGE:Avg FragOK %1.2lf %%",
			"GPRINT:MFragOKs:MAX:Max FragOK %1.2lf %%",
			"GPRINT:FragFails:AVERAGE:Avg FragFail %1.2lf %%",
			"GPRINT:MFragFails:MAX:Max FragFail %1.2lf %%",
			"GPRINT:FragCreates:AVERAGE:Avg FragCreate %1.2lf %%",
			"GPRINT:MFragCreates:MAX:Max FragCreate %1.2lf %%",
			"COMMENT:   Calculated as a % of ipInDelivers"

		);
	}
	elsif ( $type eq "topo" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", 'SpanT Topo Changes',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:top=$database:TopChanges:AVERAGE",
			"LINE1:top#0000ff:Number Changes",
			"GPRINT:top:AVERAGE:Avg Topo Changes %1.2lf",
			"GPRINT:top:MAX:Max Topo Changes %1.2lf"
		);
	}
	elsif ( $type eq "buffer" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", 'Buffer Utilisation',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:bufferElFree=$database:bufferElFree:AVERAGE",
			"DEF:bufferElHit=$database:bufferElHit:AVERAGE",
			"DEF:bufferFail=$database:bufferFail:AVERAGE",
			"LINE2:bufferElFree#0000ff:Buffers Free",
			"LINE2:bufferElHit#00ff00:Buffers Hit",
			"LINE2:bufferFail#ff0000:Buffers Failed",
			"GPRINT:bufferElFree:AVERAGE:Avg Buffers Free %1.2lf",
			"GPRINT:bufferElFree:MAX:Max Buffers Free %1.2lf",
			"GPRINT:bufferElHit:AVERAGE:Avg Buffers Hit %1.2lf",
			"GPRINT:bufferElHit:MAX:Max Buffers Hit %1.2lf",
			"GPRINT:bufferFail:AVERAGE:Avg Buffers Fail %1.2lf",
			"GPRINT:bufferFail:MAX:Max Buffers Fail %1.2lf"
		);
	}
	elsif ( $type eq "mem-proc" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", '% Memory Utilisation',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:MemUsed=$database:MemoryUsedPROC:AVERAGE",
			"DEF:MemFree=$database:MemoryFreePROC:AVERAGE",
			"CDEF:totalMem=MemUsed,MemFree,+",
			"CDEF:perUsedMem=MemUsed,totalMem,/,100,*",
			"CDEF:perFreeMem=MemFree,totalMem,/,100,*",
			"AREA:perFreeMem#cccccc",
			"STACK:perUsedMem#cccccc",
			"LINE2:perFreeMem#0000ff:% Processor Mem Free",
			"LINE2:perUsedMem#000000:% Processor Mem Used\\n",
			"GPRINT:MemUsed:AVERAGE:Proc Mem Used %1.0lf bytes",
			"GPRINT:MemFree:AVERAGE:Proc Mem Free %1.0lf bytes",
			"GPRINT:totalMem:AVERAGE:Total Proc Mem %1.0lf bytes\\n",
			"GPRINT:perUsedMem:AVERAGE:Proc Mem Used %1.0lf %%",
			"GPRINT:perFreeMem:AVERAGE:Proc Mem Free %1.0lf %%"
		);
	}
	elsif ( $type eq "mem-io" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", '% Memory Utilisation',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:MemUsed=$database:MemoryUsedIO:AVERAGE",
			"DEF:MemFree=$database:MemoryFreeIO:AVERAGE",
			"CDEF:totalMem=MemUsed,MemFree,+",
			"CDEF:perUsedMem=MemUsed,totalMem,/,100,*",
			"CDEF:perFreeMem=MemFree,totalMem,/,100,*",
			"AREA:perFreeMem#cccccc",
			"STACK:perUsedMem#cccccc",
			"LINE2:perFreeMem#0000ff:% IO Mem Free",
			"LINE2:perUsedMem#000000:% IO Mem Used\\n",
			"GPRINT:MemUsed:AVERAGE:IO Mem Used %1.0lf bytes",
			"GPRINT:MemFree:AVERAGE:IO Mem Free %1.0lf bytes",
			"GPRINT:totalMem:AVERAGE:Total IO Mem %1.0lf bytes\\n",
			"GPRINT:perUsedMem:AVERAGE:IO Mem Used %1.2lf",
			"GPRINT:perFreeMem:AVERAGE:IO Mem Free %1.2lf"
		);
	}
	elsif ( $type eq "mem-dram" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", '% Memory Utilisation',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:MemUsed=$database:MemoryUsedDRAM:AVERAGE",
			"DEF:MemFree=$database:MemoryFreeDRAM:AVERAGE",
			"CDEF:totalMem=MemUsed,MemFree,+",
			"CDEF:perUsedMem=MemUsed,totalMem,/,100,*",
			"CDEF:perFreeMem=MemFree,totalMem,/,100,*",
			"AREA:perFreeMem#cccccc",
			"STACK:perUsedMem#cccccc",
			"LINE2:perFreeMem#0000ff:% DRAM Mem Free",
			"LINE2:perUsedMem#000000:% DRAM Mem Used\\n",
			"GPRINT:MemUsed:AVERAGE:DRAM Mem Used %1.0lf bytes",
			"GPRINT:MemFree:AVERAGE:DRAM Mem Free %1.0lf bytes",
			"GPRINT:totalMem:AVERAGE:Total DRAM Mem %1.0lf bytes\\n",
			"GPRINT:perUsedMem:AVERAGE:DRAM Mem Used %1.2lf %%",
			"GPRINT:perFreeMem:AVERAGE:DRAM Mem Free %1.2lf %%"
		);
	}
	elsif ( $type eq "mem-mbuf" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", '% Memory Utilisation',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:MemUsed=$database:MemoryUsedMBUF:AVERAGE",
			"DEF:MemFree=$database:MemoryFreeMBUF:AVERAGE",
			"CDEF:totalMem=MemUsed,MemFree,+",
			"CDEF:perUsedMem=MemUsed,totalMem,/,100,*",
			"CDEF:perFreeMem=MemFree,totalMem,/,100,*",
			"AREA:perFreeMem#cccccc",
			"STACK:perUsedMem#cccccc",
			"LINE2:perFreeMem#0000ff:% MBUF Mem Free",
			"LINE2:perUsedMem#000000:% MBUF Mem Used\\n",
			"GPRINT:MemUsed:AVERAGE:MBUF Mem Used %1.0lf bytes",
			"GPRINT:MemFree:AVERAGE:MBUF Mem Free %1.0lf bytes",
			"GPRINT:totalMem:AVERAGE:Total MBUF Mem %1.0lf bytes\\n",
			"GPRINT:perUsedMem:AVERAGE:MBUF Mem Used %1.2lf %%",
			"GPRINT:perFreeMem:AVERAGE:MBUF Mem Free %1.2lf %%"
		);
	}
	elsif ( $type eq "mem-cluster" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", '% Memory Utilisation',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:MemUsed=$database:MemoryUsedCLUSTER:AVERAGE",
			"DEF:MemFree=$database:MemoryFreeCLUSTER:AVERAGE",
			"CDEF:totalMem=MemUsed,MemFree,+",
			"CDEF:perUsedMem=MemUsed,totalMem,/,100,*",
			"CDEF:perFreeMem=MemFree,totalMem,/,100,*",
			"AREA:perFreeMem#cccccc",
			"STACK:perUsedMem#cccccc",
			"LINE2:perFreeMem#0000ff:% CLUSTER Mem Free",
			"LINE2:perUsedMem#000000:% CLUSTER Mem Used\\n",
			"GPRINT:MemUsed:AVERAGE:CLUSTER Mem Used %1.0lf bytes",
			"GPRINT:MemFree:AVERAGE:CLUSTER Mem Free %1.0lf bytes",
			"GPRINT:totalMem:AVERAGE:Total CLUSTER Mem %1.0lf bytes\\n",
			"GPRINT:perUsedMem:AVERAGE:CLUSTER Mem Used %1.2lf %%",
			"GPRINT:perFreeMem:AVERAGE:CLUSTER Mem Free %1.2lf %%"
		);
	}
	elsif ( $type eq "mem-switch" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", '% Mem. Util.',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:MemUsedD=$database:MemoryUsedDRAM:AVERAGE",
			"DEF:MemFreeD=$database:MemoryFreeDRAM:AVERAGE",
			"DEF:MemUsedM=$database:MemoryUsedMBUF:AVERAGE",
			"DEF:MemFreeM=$database:MemoryFreeMBUF:AVERAGE",
			"DEF:MemUsedC=$database:MemoryUsedCLUSTER:AVERAGE",
			"DEF:MemFreeC=$database:MemoryFreeCLUSTER:AVERAGE",
			"CDEF:totalMemD=MemUsedD,MemFreeD,+",
			"CDEF:perUsedMemD=MemUsedD,totalMemD,/,100,*",
			"CDEF:totalMemM=MemUsedM,MemFreeM,+",
			"CDEF:perUsedMemM=MemUsedM,totalMemM,/,100,*",
			"CDEF:totalMemC=MemUsedC,MemFreeC,+",
			"CDEF:perUsedMemC=MemUsedC,totalMemC,/,100,*",
			"LINE2:perUsedMemD#0000ff:% DRAM Mem Used",
			"LINE2:perUsedMemM#00ff00:% MBUF Mem Used",
			"LINE2:perUsedMemC#ffff00:% CLUSTER Mem Used",
			"GPRINT:perUsedMemD:AVERAGE:DRAM Mem Used %1.2lf",
			"GPRINT:perUsedMemM:AVERAGE:MBUF Mem Used %1.2lf",
			"GPRINT:perUsedMemC:AVERAGE:CLUSTER Mem Used %1.2lf",
			"GPRINT:MemUsedD:AVERAGE:DRAM Mem Used %1.0lf bytes",
			"GPRINT:MemFreeD:AVERAGE:DRAM Mem Free %1.0lf bytes",
			"GPRINT:totalMemD:AVERAGE:Total DRAM Mem %1.0lf bytes",
			"GPRINT:MemUsedM:AVERAGE:MBUF Mem Used %1.0lf bytes",
			"GPRINT:MemFreeM:AVERAGE:MBUF Mem Free %1.0lf bytes",
			"GPRINT:totalMemM:AVERAGE:Total MBUF Mem %1.0lf bytes",
			"GPRINT:MemUsedC:AVERAGE:CLUSTER Mem Used %1.0lf bytes",
			"GPRINT:MemFreeC:AVERAGE:CLUSTER Mem Free %1.0lf bytes",
			"GPRINT:totalMemC:AVERAGE:Total CLUSTER Mem %1.0lf bytes"
		);
	}
	elsif ( $type eq "mem-router" ) {
		my $ttl = "$node - $length from $datestamp_start to $datestamp_end";
		if ($title eq "small") {
			$ttl = "Memory util. $node";
		}
		@options = (
			"--title", $ttl,
			"--vertical-label", '% Mem. Util.',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:MemUsedD=$database:MemoryUsedPROC:AVERAGE",
			"DEF:MemFreeD=$database:MemoryFreePROC:AVERAGE",
			"DEF:MemUsedM=$database:MemoryUsedIO:AVERAGE",
			"DEF:MemFreeM=$database:MemoryFreeIO:AVERAGE",
			"CDEF:totalMemD=MemUsedD,MemFreeD,+",
			"CDEF:perUsedMemD=MemUsedD,totalMemD,/,100,*",
			"CDEF:totalMemM=MemUsedM,MemFreeM,+",
			"CDEF:perUsedMemM=MemUsedM,totalMemM,/,100,*",
			"LINE2:perUsedMemD#0000ff:% Proc Mem Used",
			"LINE2:perUsedMemM#00ff00:% IO Mem Used\\n"
		);
		if ($title ne "small") {
			push @options, "GPRINT:perUsedMemD:AVERAGE:Proc Mem Used %1.2lf %%";
			push @options, "GPRINT:perUsedMemM:AVERAGE:IO Mem Used %1.2lf %%\\n";
			push @options, "GPRINT:MemUsedD:AVERAGE:Proc Mem Used %1.0lf bytes";
			push @options, "GPRINT:MemFreeD:AVERAGE:Proc Mem Free %1.0lf bytes";
			push @options, "GPRINT:totalMemD:AVERAGE:Total Proc Mem %1.0lf bytes\\n";
			push @options, "GPRINT:MemUsedM:AVERAGE:IO Mem Used %1.0lf bytes";
			push @options, "GPRINT:MemFreeM:AVERAGE:IO Mem Free %1.0lf bytes";
			push @options, "GPRINT:totalMemM:AVERAGE:Total IO Mem %1.0lf bytes";
		}
	}
    elsif ( $type eq "hrwinusers" ) {
            @options = (
                    "--title", "$node - $length from $datestamp_start to $datestamp_end",
                    "--vertical-label", 'Num Users',
                    "--start", "$start",
                    "--end", "$end",
                    "--width", "$width",
                    "--height", "$height",
                    "--imgformat", "PNG",
                    "--interlace",
                    "DEF:hrNumUsers=$database:hrNumUsers:AVERAGE",
                    "LINE2:hrNumUsers#0000ff:Average Num Users\\n",
                    "GPRINT:hrNumUsers:MIN:Min Num Users %1.0lf",
                    "GPRINT:hrNumUsers:AVERAGE:Average Num Users %1.0lf",
                    "GPRINT:hrNumUsers:MAX:Max Num Users %1.0lf"
            );
    }
    elsif ( $type eq "hrwinproc" ) {
            @options = (
                    "--title", "$node - $length from $datestamp_start to $datestamp_end",
                    "--vertical-label", 'Memory Used',
                    "--start", "$start",
                    "--end", "$end",
                    "--width", "$width",
                    "--height", "$height",
                    "--imgformat", "PNG",
                    "--interlace",
                    "DEF:hrProcesses=$database:hrProcesses:AVERAGE",
                    "LINE2:hrProcesses#0000ff:Average Num Processes\\n",
                    "GPRINT:hrProcesses:MIN:Min Num Processes %1.0lf",
                    "GPRINT:hrProcesses:AVERAGE:Average Num Processes %1.0lf",
                    "GPRINT:hrProcesses:MAX:Max Num Processes %1.0lf"
            );
    }

	elsif ( $type eq "hrusers" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", 'Num Users',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:hrNumUsers=$database:hrNumUsers:AVERAGE",
			"LINE2:hrNumUsers#0000ff:Average Num Users\\n",
			"GPRINT:hrNumUsers:MIN:Min Num Users %1.0lf",
			"GPRINT:hrNumUsers:AVERAGE:Average Num Users %1.0lf",
			"GPRINT:hrNumUsers:MAX:Max Num Users %1.0lf"
		);
	}
	elsif ( $type eq "hrproc" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", 'Memory Used',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:hrProcesses=$database:hrProcesses:AVERAGE",
			"LINE2:hrProcesses#0000ff:Average Num Processes\\n",
			"GPRINT:hrProcesses:MIN:Min Num Processes %1.0lf",
			"GPRINT:hrProcesses:AVERAGE:Average Num Processes %1.0lf",
			"GPRINT:hrProcesses:MAX:Max Num Processes %1.0lf"
		);
	}
	elsif ( $type eq "hrcpu" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", '% Processor Time',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:laLoad5=$database:laLoad5:AVERAGE",
			"LINE2:laLoad5#0000ff:CPU Percent Time\\n",
			"GPRINT:laLoad5:MIN:Min CPU Percent Time %1.0lf",
			"GPRINT:laLoad5:AVERAGE:Average CPU Percent Time %1.0lf",
			"GPRINT:laLoad5:MAX:Max CPU Percent Time %1.0lf"
		);
	}

	elsif ( $type eq "hrmem" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", 'Memory Useage',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:hrMemSize=$database:hrMemSize:AVERAGE",
			"DEF:hrMemUsed=$database:hrMemUsed:AVERAGE",
			"LINE2:hrMemSize#000000:Average Memory Size",
			"AREA:hrMemUsed#000000:Average Memory Used\\n",
			"GPRINT:hrMemUsed:MIN:Min Mem Used %1.3lf %sb",
			"GPRINT:hrMemUsed:AVERAGE:Avg Mem Used %1.3lf %Sb",
			"GPRINT:hrMemUsed:MAX:Max Mem Used %1.3lf %Sb"
		);
	}
	elsif ( $type eq "hrvmem" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", 'Memory Useage',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:hrVMemSize=$database:hrVMemSize:AVERAGE",
			"DEF:hrVMemUsed=$database:hrVMemUsed:AVERAGE",
			"LINE2:hrVMemSize#000000:Average Virtual Memory Size",
			"AREA:hrVMemUsed#000000:Average Virtual Memory Used\\n",
			"GPRINT:hrVMemUsed:MIN:Min Virtual Mem Used %1.3lf %sb",
			"GPRINT:hrVMemUsed:AVERAGE:Avg Virtual Mem Used %1.3lf %Sb",
			"GPRINT:hrVMemUsed:MAX:Max Virtual Mem Used %1.3lf %Sb"
		);
	}
	elsif ( $type eq "hrwinmem" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", 'Available/Committed bytes',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:AvailableBytes=$database:AvailableBytes:AVERAGE",
			"DEF:CommittedBytes=$database:CommittedBytes:AVERAGE",
			"LINE2:AvailableBytes#0000ff:Available bytes",
			"LINE2:CommittedBytes#000000:Committed bytes\\n",
			"GPRINT:AvailableBytes:MIN:Min Available %1.3lf %sb",
			"GPRINT:AvailableBytes:AVERAGE:Avg Available %1.3lf %Sb",
			"GPRINT:AvailableBytes:MAX:Max Available %1.3lf %Sb\\n",
			"GPRINT:CommittedBytes:MIN:Min Committed %1.3lf %Sb",
			"GPRINT:CommittedBytes:AVERAGE:Avg Committed %1.3lf %Sb",
			"GPRINT:CommittedBytes:MAX:Max Committed %1.3lf %Sb"
		);
	}
	elsif ( $type eq "hrwinpps" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", 'Memory Pages/sec',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:PagesPerSec=$database:PagesPerSec:AVERAGE",
			"LINE2:PagesPerSec#0000ff:Pages per sec\\n",
			"GPRINT:PagesPerSec:MIN:Min Pages per sec %1.0lf",
			"GPRINT:PagesPerSec:AVERAGE:Average Pages per sec %1.0lf",
			"GPRINT:PagesPerSec:MAX:Max Pages per sec %1.0lf"
		);
	}
	elsif ( $type eq "hrwincpu" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", '% Processor Time',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:ProcessorTime=$database:ProcessorTime:AVERAGE",
			"DEF:UserTime=$database:UserTime:AVERAGE",
			"LINE2:ProcessorTime#0000ff:CPU Percent Time",
			"LINE2:UserTime#000000:CPU User Time\\n",
			"GPRINT:ProcessorTime:MIN:Min CPU Percent Time %1.0lf",
			"GPRINT:ProcessorTime:AVERAGE:Average CPU Percent Time %1.0lf",
			"GPRINT:ProcessorTime:MAX:Max CPU Percent Time %1.0lf \\n",
			"GPRINT:UserTime:MIN:Min CPU User Time %1.0lf",
			"GPRINT:UserTime:AVERAGE:Average CPU User Time %1.0lf",
			"GPRINT:UserTime:MAX:Max CPU User Time %1.0lf"
		);
	}
	elsif ( $type eq "hrwincpuint" ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", '% CPU interrupts per sec',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:InterruptsPerSec=$database:InterruptsPerSec:AVERAGE",
			"LINE2:InterruptsPerSec#0000ff:CPU interrupts per sec\\n",
			"GPRINT:InterruptsPerSec:MIN:Min CPU interrupts per sec %1.0lf",
			"GPRINT:InterruptsPerSec:AVERAGE:Average CPU interrupts per sec %1.0lf",
			"GPRINT:InterruptsPerSec:MAX:Max CPU interrupts per sec %1.0lf"
		);
	}

    elsif ( $type =~ /hrsmpcpu/ ) {
            @options = (
                    "--title", "$node - $length from $datestamp_start to $datestamp_end",
                    "--vertical-label", '% Processor Load',
                    "--start", "$start",
                    "--end", "$end",
                    "--width", "$width",
                    "--height", "$height",
                    "--imgformat", "PNG",
                    "--interlace",
                    "DEF:hrCpuLoad=$database:hrCpuLoad:MAX",
                    #"CDEF:NhrCpuLoad=hrCpuLoad,100,*",
		"LINE2:hrCpuLoad#0000ff:Cpu Load\\n",                        
		#"AREA:perUsedD#000000:% Disk Used",
                    #"GPRINT:perUsedD:MAX:Disk Used %1.0lf %%\\n",
                    #"GPRINT:hrDiskSize:MAX:Disk Size %1.3lf %sbytes",
                    "GPRINT:hrCpuLoad:MAX:Cpu Load %1.2lf",
		#"GPRINT:NhrCpuLoad:MAX:Cpu Load %1.2lf"
            );
    }

	elsif ( $type =~ /hrdisk/ ) {
		@options = (
			"--title", "$node - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", '% Disk Used',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:hrDiskSize=$database:hrDiskSize:MAX",
			"DEF:hrDiskUsed=$database:hrDiskUsed:MAX",
			"CDEF:perUsedD=hrDiskUsed,hrDiskSize,/,100,*",
			"AREA:perUsedD#000000:% Disk Used",
			"GPRINT:perUsedD:MAX:Disk Used %1.0lf %%\\n",
			"GPRINT:hrDiskSize:MAX:Disk Size %1.3lf %sbytes",
			"GPRINT:hrDiskUsed:MAX:Disk Used %1.3lf %Sbytes" 
		);
	}

	### nmis collect runtime
	elsif ( $type eq "nmis" ) {
		@options = (
			"--title", "NMIS system - $length from $datestamp_start to $datestamp_end",
			"--vertical-label", 'NMIS runtime seconds',
			"--start", "$start",
			"--end", "$end",
			"--width", "$width",
			"--height", "$height",
			"--imgformat", "PNG",
			"--interlace",
			"DEF:collect=$database:collect:AVERAGE",
			"LINE2:collect#00ff00:collect",
			"GPRINT:collect:AVERAGE:Avg collect runtime %1.2lf seconds"
		);
	}


	# Do the graph!

	# This works around a bug in RRDTool which doesn't like writing to STDOUT on Win32!
	# print STDERR "RRDTool Options: @options\n";
	if ( $^O eq "MSWin32" ) {
		my $buff;
		my $random = int(rand(1000)) + 25;
		my $tmpimg = "$NMIS::config{'<nmis_var>'}/rrdDraw-$random.png";

		print "Content-type: image/png\n\n";
		($graphret,$xs,$ys) = RRDs::graph($tmpimg, @options);
		if ( -f $tmpimg ) {
			open(IMG,$tmpimg) or logMessage("rrdDraw, $node, ERROR: problem with $tmpimg; $!");
			binmode(IMG);
			binmode(STDOUT);
			while (read(IMG, $buff, 8 * 2**10)) {
			    print STDOUT $buff;
			}
			close(IMG);
			unlink($tmpimg) or logMessage("$node, Can't delete $tmpimg: $!");
		}
	} else {
		# buffer stdout to avoid Apache timing out on the header tag while waiting for the PNG image stream from RRDs
		select((select(STDOUT), $| = 1)[0]);
		print "Content-type: image/png\n\n";
		($graphret,$xs,$ys) = RRDs::graph('-', @options);
		select((select(STDOUT), $| = 0)[0]);			# unbuffer stdout
	}

	if ($ERROR = RRDs::error) {
  		logMessage("rrdDraw,,RRDTool $database Graphing Error: $ERROR");

	} else {
		#return "GIF Size: ${xs}x${ys}\n";
		#print "Graph Return:\n",(join "\n", @$graphret),"\n\n";
	}
} # end graph

###
### Load the CBQoS static values in tables
###
sub loadCBQos {

	my $node = shift;
	my $intf = shift;
	my $PMName;
	my @CMNames;
	my %cbQosTable;
	if ($NMIS::config{CBQoS_collect} eq "true") {
		# define line color of the graph
	##	my @colors = ("00FF00","0000FF","FF00FF","555555","00FFFF","12B4c6","FF9900","996633");
		my @colors = ("888888","00CC00","0000CC","CC00CC","FFCC00","00CCCC",
					"444444","440000","004400","000044","BBBB00","BB00BB","00BBBB",
					"888800","880088","008888","444400","440044","004444");
		my $qosfile = "$NMIS::config{'<nmis_var>'}/$node-qos.nmis";
		if ( -r $qosfile ) {	
			# Read the QoS file of this node
			%cbQosTable = readVartoHash("${node}-qos");;

			my $direction = (($type eq "graph" and $graphtype eq "cbqos-in") or
					($type eq "drawgraph" and $q->param('graph') eq "cbqos-in")) ? "in" : "out" ;

			foreach my $if (keys %cbQosTable) {
				if ( $if eq $intf ) {
					$PMName = $cbQosTable{$intf}{$direction}{'PolicyMap'}{'Name'};
					foreach my $key (keys %{$cbQosTable{$intf}{$direction}{'ClassMap'}}) {
						my $CMName = $cbQosTable{$intf}{$direction}{'ClassMap'}{$key}{'Name'};
						push @CMNames , $CMName;
						$CBQosValues{$intf.$CMName}{'CfgType'} = $cbQosTable{$intf}{$direction}{'ClassMap'}{$key}{'BW'}{'Descr'};
						$CBQosValues{$intf.$CMName}{'CfgRate'} = $cbQosTable{$intf}{$direction}{'ClassMap'}{$key}{'BW'}{'Value'};
					}
				}
			}

			# order the buttons of the classmap names for the Web page
			@CMNames = sort {uc($a) cmp uc($b)} @CMNames;
			my @qNames;
			my @confNames = split(',', $NMIS::config{'CBQoS_order_CM_buttons'});
			foreach my $Name (@confNames) {
				for (my $i=0; $i<=$#CMNames; $i++) {
					if ($Name eq $CMNames[$i] ) {
						push @qNames, $CMNames[$i] ; # move entry
						splice (@CMNames,$i,1);
						last;
					}
				}
			}
			@CBQosNames = ($PMName,@qNames,@CMNames); #policy name, classmap names sorted, classmap names unsorted
			if ($#CBQosNames) { 
				$CBQosActive = "true";
				# colors of the graph in the same order
				for my $i (1..$#CBQosNames) {
					if ($i < $#colors ) {
						$CBQosValues{$intf.$CBQosNames[$i]}{'Color'} = $colors[$i-1];
					} else {
						$CBQosValues{$intf.$CBQosNames[$i]}{'Color'} = "000000";
					}
				}
			}
		}
	}
} # end loadCBQos

