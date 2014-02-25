#
#    detail.pm - detail NMIS Perl Package - Network Mangement Information System
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
package detail;

use strict;
use web;
use csv;
use NMIS;


use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

use Exporter;

#! this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);

use CGI;
my $q = CGI->new;	# This is okay as CGI stuff is read-only

$VERSION = 1.00;

@ISA = qw(Exporter);

@EXPORT = qw(	
		nmisMenuLargeDetailed
		printNodeTypeDetailed
	);

@EXPORT_OK = qw( );

sub nmisMenuLargeDetailed {

        my $group;
        my $span = 10;

        print "<!-- nmisMenuLargeDetailed begin -->\n";
        loadEventStateNoLock;
        loadNodeDetails;

        rowStart;
        cssCellStart("white",$span);
        cssTableStart("white");

        rowStart;
        cssPrintCell("grey","Node List and Status",$span);
        rowEnd;

        foreach $group (sort ( keys (%NMIS::groupTable) ) ) {

                rowStart;
                cssPrintCell("grey","<A name=$group>$group Nodes</a>",$span);
                rowEnd;

                rowStart;
                cssCellStart("",$span);
          #      cssTableStart("white");
                printHeadRow("Node,Type,Location,System Uptime,Node Vendor,NodeModel:SystemName,S/N,Chassis,ProcMem,Version","");
                &printNodeTypeDetailed($group);
           #     tableEnd;
                cellEnd;
                rowEnd;

        }
        tableEnd;
        cellEnd;
        rowEnd;
        print "<!-- nmisMenuLargeDetailed end -->\n";
} # end nmisMenuLargeDetailed

sub printNodeTypeDetailed {
        my $group = shift;
        my $cell = "#aaaaaa";
        my $detailvar;
	my $node;
	my %summaryHash;
	my $conf;

        print "<!-- printNodeTypeDetailed begin -->\n";
 #       printCell("<div class=\"as\">",$cell,1);
        foreach $node (sort ( keys (%NMIS::nodeTable) ) ) {
			if ( exists $NMIS::nodeTable{$node}{slave2} and $NMIS::config{master_report} ne "true" ) { next; }
                if ( $NMIS::nodeTable{$node}{group} eq "$group" ) {
                        ## AS 16 Mar 02, implementing David Gay's requirement for deactiving
                        # a node, ie keep a node in nodes.csv but no collection done.
                        ### AS 10 June 2002 - If you don't want cell colored event status, un
                        if ( $NMIS::nodeTable{$node}{active} ne "false" ) {
                           $cell = "#ffffff";
                    #       $cell = $summaryHash{$node}{event_color};
                        } else {
                           $cell = "#aaaaaa";
                        }
                        rowStart;
                        # Load the system table for the node.
						if ( exists $NMIS::nodeTable{$node}{slave2} ) {
							%NMIS::systemTable = slaveConnect(host => $NMIS::nodeTable{$node}{slave2}, type => 'send', func => "loadSystemFile", node => $node);
 						} else {
	                       loadSystemFile($node);
						}

						my $slave_ref = $q->url(-absolute=>1)."?file=$conf";
						if ( exists $NMIS::nodeTable{$node}{slave} ) {
							$slave_ref = "http://$NMIS::nodeTable{$node}{slave}/cgi-nmis/nmiscgi.pl";
						}
						if ( exists $NMIS::nodeTable{$node}{slave2}) {
							$slave_ref = "http://$NMIS::slaveTable{$NMIS::nodeTable{$node}{slave2}}{Host}/cgi-nmis/nmiscgi.pl".
							"?file=$NMIS::slaveTable{$NMIS::nodeTable{$node}{slave2}}{Conf}";
						}
                        # display sysName if $node is a IPV4 address
                        if ( $node =~ /\d+\.\d+\.\d+\.\d+/      and $NMIS::systemTable{sysName} ne "" ) {
                           printCell("<a href=\"$slave_ref&amp;node=$node&amp;type=summary\">$NMIS::systemTable{sysName}</a><br>".
                            "<a href=\"$slave_ref&amp;node=$node&amp;type=health\">health</a>",$cell,1);
                        }
                        else {
                           printCell("<a href=\"$slave_ref&amp;node=$node&amp;type=summary\">$node</a><br>".
                            "<a href=\"$slave_ref&amp;node=$node&amp;type=health\">health</a>",$cell,1);
                        }
                        printCell("$NMIS::nodeTable{$node}{devicetype}",$cell);
                        printCell("$NMIS::systemTable{sysLocation}",$cell);
                        print <<EO_HTML;
                           <td class="sh_head" colspan="1" align="center">$NMIS::systemTable{sysUpTime}</td>
                           <td class="sh_body" colspan="1" align="center">$NMIS::systemTable{nodeVendor}</td>
                           <td class="sh_body" colspan="1" align="center">$NMIS::systemTable{nodeModel}:$NMIS::systemTable{sysObjectName}</td>
                           <td class="sh_body" align="center" width="8%">$NMIS::systemTable{serialNum}</td>
                           <td class="sh_body" align="center" width="8%">$NMIS::systemTable{chassisVer}</td>
                           <td class="sh_body" align="center" width="8%">$NMIS::systemTable{processorRam}</td>
EO_HTML
                        $detailvar = $NMIS::systemTable{sysDescr};
                        $detailvar =~ s/^.*WS/WS/g;
                        $detailvar =~ s/Cisco Catalyst Operating System Software/CatOS/g;
                        $detailvar =~ s/Copyright.*$//g;
                        $detailvar =~ s/TAC Support.*$//g;
                        $detailvar =~ s/RELEASE.*$//g;
                        $detailvar =~ s/Cisco.*tm\) //g;
                        print'<td class="sh_body" align="center" width="12%">';
                        print"$detailvar</td>";
                        print"</tr>";
                        rowEnd;
                }
        }
        print "</div>\n";
        print "<!-- printNodeTypeDetailed end -->\n";
}

1;
