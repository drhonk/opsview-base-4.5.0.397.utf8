#!/usr/bin/perl
#
# DESCRIPTION:
#	Test nsca will switch from alternate to command file when available
#
# COPYRIGHT:
#	Copyright (C) 2003-2008 Opsview Limited. All rights reserved
#	Copyright is freely given to Ethan Galstad if included in the NSCA distribution
#
# LICENCE:
#	GNU GPLv2

use strict;
use NSCATest;
use Test::More;

plan tests => 8;

my $data1 = [ [ "hostname", "0", "Plugin output" ], [ "hostname-with-other-bits", "1", "More data to be read" ], [ "hostname.here", "2", "Check that ; are okay to receive" ], [ "host", "service", 0, "A good result here" ], ];

my $data2 = [ [ "host54", "service with spaces", 1, "Warning! My flies are undone!" ], [ "host-robin", "service with a :)", 2, "Critical? Alert! Alert!" ], [ "host-batman", "another service", 3, "Unknown - the only way to travel" ], ];

foreach my $config qw(basic aggregate) {
    foreach my $type qw(--single --daemon) {
        my $nsca = NSCATest->new( config => $config, suppress_cmd_file => 1 );

        $nsca->start($type);
        $nsca->send($data1);
        sleep 1;    # Need to wait for --daemon to finish processing
        $nsca->create_cmd;
        $nsca->send($data2);
        sleep 1;    # Need to wait for --daemon to finish processing

        my $output = $nsca->read_alternate;
        is_deeply( $data1, $output, "Got all data from alternate file" );

        $output = $nsca->read_cmd;
        is_deeply( $data2, $output, "Got all data from cmd file" );

        $nsca->stop;
    }
}
