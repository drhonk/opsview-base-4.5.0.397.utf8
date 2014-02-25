#!/usr/bin/perl
# Tests for autossh
# using perl's Test::More
#

package Autossh::Test;

use strict;
use FindBin qw($Bin);
use Class::Struct;

struct "Autossh::Test" => {
	autossh_pid => '$',
	ssh_pid => '$',
	logfile => '$',
	last_log_message => '$',
	};

sub run {
	my ($class, $cmd, $envvars) = @_;

	my $self = $class->new;

	# Delete all AUTOSSH_* env vars
	foreach my $v (keys %ENV) {
		if ($v =~ /^AUTOSSH_/) {
			delete $ENV{$v};
		}
	}

	my $pidfile = "$Bin/test.pid";
	$ENV{AUTOSSH_PIDFILE} = $pidfile;

	my $logfile = "$Bin/test.log";
	$ENV{AUTOSSH_LOGFILE} = $logfile;
	$ENV{AUTOSSH_LOGLEVEL} = 7;

	$ENV{AUTOSSH_GATETIME} = 0;	# Must be disabled because most tests run within 5 seconds, but autossh will treat differently by default

	# Add any envvars requested, possibly overriding
	foreach my $v (keys %$envvars) {
		$DB::single=1;
		$ENV{$v} = $envvars->{$v};
	}


	unlink $logfile;
	$self->logfile($logfile);

	system($cmd);
	sleep 1;	# Allow startup time

	open F, "$pidfile" or die "Cannot read pidfile $pidfile";
	my $pid = <F>;
	close F;
	chomp $pid;
	$self->autossh_pid( $pid );

	$self->scan_ssh_pid;

	unless ($self->ssh_pid) {
		die "Error starting autossh. Last message in log: ".$self->last_log_message.$/;
	}

	return $self;
}

sub scan_ssh_pid {
	my $self = shift;
	my $last;
	my $logfile = $self->logfile;
	open F, "$logfile" or die "Cannot read logfile $logfile";
	@_ = <F>;
	foreach $_ (reverse @_) {
		$last = $_ unless defined $last;
		if (/ssh child pid is (\d+)/) {
			$self->ssh_pid($1);
			last;
		}
	}
	$self->last_log_message($last);
	close F;
}

sub kill {
	my $self = shift;
	kill 'INT', $self->autossh_pid;
	sleep 1;
	if (kill 0, $self->autossh_pid) {
		die "Error: not killed";
	}
}

sub DESTROY {
	# Kill autossh if still running
	my $self = shift;
	if (kill 0, $self->autossh_pid) {
		print STDERR "autossh still running - killing now\n";
		kill 'INT', $self->autossh_pid;
		sleep 1;
	}
}

package Main;

use strict;
use Test::More;

my $host = $ENV{AUTOSSH_TEST_HOST};

die 'Need autossh binary to test' unless (-x "./autossh");
die 'Need to set AUTOSSH_TEST_HOST environment variable as "user@host" to test' unless $host;

plan tests => 16;

my $obj;

foreach my $port (qw(0 20000)) {
	$obj = Autossh::Test->run("./autossh -M $port -f $host sleep 5");
	ok( $obj->autossh_pid, "autossh started with pid=".$obj->autossh_pid." and -M $port");
	ok( $obj->ssh_pid, "ssh pid is ".$obj->ssh_pid );
	sleep 5;
	is( kill(0, $obj->autossh_pid), 0, "autossh stopped normally after 5 seconds" );


	$obj = Autossh::Test->run("./autossh -M $port -f $host sleep 555");
	diag( "autossh is ".$obj->autossh_pid );
	my $child = $obj->ssh_pid;
	diag( "child is $child" );
	kill 'ABRT', $child;	# INT, TERM, KILL will be processed as a deliberate exit. QUIT seems to force ssh to die without signal
	sleep 1;		# Allow time for ssh to process kill and autossh to start new one
	ok( ! is_alive($child), "ssh stopped after an ABRT signal");
	$obj->scan_ssh_pid;
	isnt( $child, $obj->ssh_pid, "New ssh command started");
	ok( is_alive($obj->ssh_pid), "And is currently running" );

	$child = $obj->ssh_pid;
	kill 'TERM', $child;	# This will kill ssh in a way that will stop autossh
	sleep 1;
	ok( ! is_alive($child), "ssh stopped after a TERM signal");
	ok( ! is_alive($obj->autossh_pid), "autossh also stopped");
}

sub is_alive {
	kill(0, shift) == 0 ? 0 : 1;
}
