#!/usr/bin/perl
#
# SYNTAX:
my $usage = "upgradedb.pl -u user -p password -h hostname -d database";

#
# DESCRIPTION:
#	Runs upgrade scripts in this directory based on current level of database
#	Options as mysql's for authentication
#
# COPYRIGHT:
#	Copyright (C) 2003-2008 Opsview Limited. All rights reserved
#	Copyright is freely given to Ethan Galstad if included in the NDOUtils distribution
#
# LICENCE:
#	GNU GPLv2

use strict;
use FindBin qw($Bin);
use Getopt::Std;
use DBI;

sub usage {
    print $usage, $/, "\t", $_[0], $/;
    exit 1;
}

my $opts = {};
getopts( "u:p:h:d:", $opts ) or usage "Bad options";

my $database = $opts->{d} || usage "Must specify a database";
my $hostname = $opts->{h} || "localhost";
my $username = $opts->{u} || usage "Must specify a username";
my $password = $opts->{p};
usage "Must specify a password" unless defined $password;    # Could be blank

# Connect to database
my $dbh = DBI->connect( "DBI:mysql:database=$database;host=$hostname", $username, $password, { RaiseError => 1 }, )
    or die "Cannot connect to database";

# Get current database version
# Version in db table is the "last version applied" because the numbering of
# the update files do not completely correspond
eval { $dbh->do("SELECT * FROM nagios_database_version") };
my $version;
if ($@) {
    print "Can ignore above error",                 $/;
    print "Creating table nagios_database_version", $/;
    $dbh->do("CREATE TABLE nagios_database_version (version varchar(10))");
    $dbh->do("INSERT nagios_database_version VALUES ('1.3')");
    $version = "1.3";
}
else {
    $version = $dbh->selectrow_array("SELECT version FROM nagios_database_version");
}

# Read all upgrade scripts in the directory containing this script
# Must be of form mysql-upgrade-{version}.sql
my $upgrades = {};
opendir( SCRIPTDIR, $Bin ) or die "Cannot open dir $Bin";
foreach my $file ( readdir SCRIPTDIR ) {
    next unless $file =~ /^mysql-upgrade-(.*)\.sql/;
    $upgrades->{$1} = $file;
}
closedir SCRIPTDIR;

# Huge dependency that the version numbers are sorted "alphabetically"
# If below is not right, then the upgrade script could be applied in the wrong order
my @ordered_upgrades = sort keys %$upgrades;

my $changes = 0;
foreach my $script_version (@ordered_upgrades) {

    # This should be a "ge", but "gt" is used because the version in the db
    # does not completely match the schema version because of the perculiar
    # naming convention of the upgrade files
    if ( $script_version gt $version ) {
        my $file = $upgrades->{$script_version};
        print "Upgrade required for $script_version", $/;
        my $p = "-p$password" if $password;    # Not required if password is blank
        system("mysql -u $username $p -D$database -h$hostname < $Bin/$file") == 0 or die "Upgrade from $file failed";
        $dbh->do("UPDATE nagios_database_version SET version='$script_version'");
        $version = $script_version;
        $changes++;
    }
}

unless ($changes) {
    print "No database updates required. At version $version", $/;
}
