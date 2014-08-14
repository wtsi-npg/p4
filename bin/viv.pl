#!/usr/bin/env perl

use strict;

use File::Slurp;
use JSON;

use POSIX;
use File::Temp qw/ tempdir /;
use Getopt::Std;
use Readonly;

use Carp;

use Data::Dumper;

our $VERSION = '0';

Readonly::Scalar my $FROM => 0;
Readonly::Scalar my $TO => 1;
Readonly::Scalar my $VLALWAYSLOG => 0;
Readonly::Scalar my $VLMIN => 1;
Readonly::Scalar my $VLMED => 2;
Readonly::Scalar my $VLMAX => 3;

my %opts;
getopts('xshv:o:r:t:', \%opts);

if($opts{h}) {
	die qq{viv.pl [-s] [-x] [-v <verbose_level>] [-o <logname>] <config.json>\n};
}

my $do_exec = $opts{x};
my $strict_status_checks = $opts{s};
my $logfile = $opts{o};
my $verbosity_level = $opts{v};
$verbosity_level = 1 unless defined $verbosity_level;
my $logger = mklogger($verbosity_level, $logfile, q[viv]);
$logger->($VLMIN, 'viv.pl version '.($VERSION||q(unknown_not_deployed)).', running as '.$0);
my $cfg_file_name = $ARGV[0];
$cfg_file_name ||= q[test_cfg.json];
my $raf_list = process_raf_list($opts{r});    # insert inline RAFILE nodes
my $tee_list = process_raf_list($opts{t});    # insert tee with branch to RAFILE

my $s = read_file($cfg_file_name);

my $cfg = from_json($s);

my %all_nodes = (map { $_->{id} => $_ } @{$cfg->{nodes}});
my %exec_nodes = (map { $_->{id} => $_ } (grep { $_->{type} eq q[EXEC]; } @{$cfg->{nodes}}));
my %filter_nodes = (map { $_->{id} => $_ } (grep { $_->{type} eq q[FILTER]; } @{$cfg->{nodes}}));
my %infile_nodes = (map { $_->{id} => $_ } (grep { $_->{type} eq q[INFILE]; } @{$cfg->{nodes}}));
my %outfile_nodes = (map { $_->{id} => $_ } (grep { $_->{type} eq q[OUTFILE]; } @{$cfg->{nodes}}));
my %rafile_nodes = (map { $_->{id} => $_ } (grep { $_->{type} eq q[RAFILE]; } @{$cfg->{nodes}}));

my $edges = $cfg->{edges};

$logger->($VLMAX, "==================================\nEXEC nodes(0):\n==================================\n", Dumper(%exec_nodes), "\n");

# Initial pass through RAFILE and OUTFILE nodes to mark the downstream EXEC node dependencies on upstream EXEC nodes
my %deps = ();
for my $file_node (values %rafile_nodes, values %outfile_nodes) {
	my $current_to_edges = _get_to_edges($file_node->{id}, $edges);
	my $current_from_edges = _get_from_edges($file_node->{id}, $edges);

	# produce list of id values for exec nodes immediately downstream from this node
	my @downstream_nodes = ();
	for my $edge (@$current_from_edges) {
		my $to_id = (split q{:}, $edge->{to})[0];
		push @downstream_nodes, $to_id;
	}

	for my $edge (@$current_to_edges) {
		my $from_id = (split q{:}, $edge->{from})[0];
		@{$deps{$from_id}}{(@downstream_nodes)} = (1) x @downstream_nodes;
	}
}

# now use the deps hash to update nodes, adding dependants and incrementing wait_counters as appropriate
for my $from_id (keys %deps) {
	my $from_node = $exec_nodes{$from_id};	# only EXEC nodes should feed into RAFILE and OUTFILE nodes

	my @downstream_nodes = (keys %{$deps{$from_id}});
	$from_node->{dependants} = \@downstream_nodes;
	for my $to_id (@downstream_nodes) {
		$exec_nodes{$to_id}->{wait_counter}++;
	}
}

$logger->($VLMAX, "\n==================================\nEXEC nodes(post RAFILE processing):\n==================================\n", Dumper(%exec_nodes), "\n");

# For each edge:
#  If both "from" and "to" nodes are of type EXEC, data transfer will be done via a named pipe,
#  otherwise via file whose name is determined by the non-EXEC node's name attribute (communication
#  between two non-EXEC nodes is of questionable value and is currently considered an error).
for my $edge (@{$edges}) {
	my ($from_node, $from_id, $from_port) = _get_node_info($edge->{from}, \%all_nodes);
	my ($to_node, $to_id, $to_port) = _get_node_info($edge->{to}, \%all_nodes);
	my $data_xfer_name;

	if($from_node->{type} eq q[EXEC]) {
		if($to_node->{type} eq q[EXEC]) {
			$data_xfer_name = _create_fifo($edge->{from});
		}
		elsif($to_node->{subtype} eq q[DUMMY]) {
			$data_xfer_name = q[];
		}
		else {
			$data_xfer_name = $to_node->{name};
		}
	}
	else {
		if($to_node->{type} eq q[EXEC]) {
			$data_xfer_name = $from_node->{name};
		}
		else {
			croak q[Edges must start or terminate in an EXEC node];
		}
	}

	_update_node_data_xfer($from_node, $from_port, $data_xfer_name, $FROM);
	_update_node_data_xfer($to_node, $to_port, $data_xfer_name, $TO);
}

$logger->($VLMAX, "\n==================================\nEXEC nodes(post edges preprocessing):\n==================================\n", Dumper(%exec_nodes), "\n");

$logger->($VLMAX, "EXEC nodes(post EXEC nodes preprocessing): ", Dumper(%exec_nodes), "\n");
setpgrp; # create new processgroup so signals can be fired easily in suitable way later
# kick off any unblocked EXEC nodes, noting their details for later release of any dependants
my %pid2id = ();
for my $node_id (keys %exec_nodes) {
	if($exec_nodes{$node_id}->{wait_counter} == 0 and not $exec_nodes{$node_id}->{pid}) { # green light - execute

		my $node = $exec_nodes{$node_id};
		if((my $pid=_fork_off($node, $do_exec))) {
			$node->{pid} = $pid;
			$pid2id{$pid} = $node_id;
		}
	}
}

# now wait for the children
$logger->($VLMIN, "\n=========\nWaiting for the children\n=========\n");
while((my $pid=wait) > 0) {
	my $status = $?;
	my $wifexited = WIFEXITED($status);
	my $wexitstatus = $wifexited ? WEXITSTATUS($status) : undef;
	my $wifsignaled = WIFSIGNALED($status);
	my $wtermsig = $wifsignaled ? WTERMSIG($status) : undef;
	my $wifstopped = WIFSTOPPED($status);
	my $wstopsig = $wifstopped ? WSTOPSIG($status) : undef;
	my $sticky_end = ($wexitstatus || $wtermsig || $wstopsig);

	my $completed_node_id=$pid2id{$pid};
	my $completed_node = $exec_nodes{$completed_node_id};
	$completed_node->{done} = 1;
	my $dependants_list = $completed_node->{dependants};

	if($strict_status_checks and $sticky_end) {
		# These messages need tidying up (and undef values detected)
		$logger->($VLMIN, sprintf(qq[\n**********************************************\nPreparing exit due to abnormal return from child %s (pid: %d), return_status: %#04X, wifexited: %#04X, wexitstatus: %d (%#04X)\n**********************************************\n], $completed_node->{id}, $pid, $status, $wifexited, $wexitstatus, $wexitstatus), "\n");
		$logger->($VLMIN, sprintf(q[Child %s (pid: %d), wifsignaled: %#04X, wtermsig: %s], $exec_nodes{$pid2id{$pid}}->{id}, $pid, $wifsignaled, ($wifsignaled? $wtermsig: q{NA})), "\n");
		$logger->($VLMIN, sprintf(q[Child %s (pid: %d), wifstopped: %#04X, wstopsig: %s], $exec_nodes{$pid2id{$pid}}->{id}, $pid, $wifstopped, ($wifstopped? $wstopsig: q{NA})), "\n");

		$SIG{'ALRM'} ||= sub {
			######################################################################
			# kill the children
			######################################################################
			local $SIG{'TERM'} = 'IGNORE';
			kill TERM => 0;

			$logger->($VLMIN, sprintf(qq[\n**********************************************\nExiting due to abnormal return from child %s (pid: %d), return_status: %#04X, wifexited: %#04X, wexitstatus: %d (%#04X)\n**********************************************\n], $completed_node->{id}, $pid, $status, $wifexited, $wexitstatus, $wexitstatus), "\n");
			$logger->($VLMIN, sprintf(q[Child %s (pid: %d), wifsignaled: %#04X, wtermsig: %s], $completed_node->{id}, $pid, $wifsignaled, ($wifsignaled? $wtermsig: q{NA})), "\n");
			$logger->($VLMIN, sprintf(q[Child %s (pid: %d), wifstopped: %#04X, wstopsig: %s], $completed_node->{id}, $pid, $wifstopped, ($wifstopped? $wstopsig: q{NA})), "\n");

			croak sprintf(qq[\n**********************************************\nExiting due to abnormal status return from child %s (pid: %d), return_status: %#04X, wifexited: %#04X, wexitstatus: %#04X\n**********************************************\n], $completed_node->{id}, $pid, $status, $wifexited, $wexitstatus), "\n";
		};
		alarm 5;
	}else{

		$logger->($VLMED, sprintf(q[Child %s (pid: %d), return_status: %#04X, wifexited: %d (%#04X), wexitstatus: %s], $completed_node->{id}, $pid, $status, $wifexited, $wexitstatus, $wexitstatus), "\n");
		$logger->($VLMED, sprintf(q[Child %s (pid: %d), wifsignaled: %#04X, wtermsig: %s], $completed_node->{id}, $pid, $wifsignaled, $wtermsig), "\n");
		$logger->($VLMED, sprintf(q[Child %s (pid: %d), wifexited: %#04X, wexitstatus: %s], $completed_node->{id}, $pid, $wifexited, $wexitstatus), "\n");

		if($dependants_list and @$dependants_list) {
			for my $dep_node_id (@$dependants_list) {
				my $dependant_node = $exec_nodes{$dep_node_id};
				$logger->($VLMED, "\tFound dependant: $dep_node_id with wait_counter $dependant_node->{wait_counter}\n");
				$dependant_node->{wait_counter}--;
				if($dependant_node->{wait_counter} == 0) { # green light - execute
					if((my $pid=_fork_off($dependant_node, $do_exec))) {
						$dependant_node->{pid} = $pid;
						$pid2id{$pid} = $dep_node_id;
					}
				}
			}
		} else {
			$logger->($VLMED, q[No dependants for child ], $completed_node->{id}, q[, pid ], $pid, "\n");
		}
	}
}
&{$SIG{'ALRM'}||sub{}}(); # fire off bad exit if set

$logger->($VLMIN, "Done\n");

sub _get_node_info {
	my ($edge_id, $all_nodes) = @_;

	my $from = $edge_id;
	my ($id, $port);
	# slightly more concise regex usage might be good here
	if($edge_id =~ /^([^:]*):(.*)$/) {
		($id, $port) = ($1, $2);
	}
	else {
		$id = $edge_id;
	}
	my $node = $all_nodes{$id};

	return ($node, $id, $port);
}

sub _create_fifo {
	my ($basename) = @_;

	my $tmpdir = tempdir( CLEANUP => 1 );
	my $leaf = $basename . q[_out];
	my $output_name = join "/", ($tmpdir, $leaf);
	mkfifo($output_name, 0666) or croak "Failed to mkfifo $output_name: $@";

	return $output_name;
}

sub _update_node_data_xfer {
	my ($node, $port, $data_xfer_name, $edge_side) = @_;

	if($node->{type} eq q[EXEC] and $data_xfer_name ne q[]) {
		if(defined $port) {
			my $cmd = $node->{'cmd'};
			for my$cmd_part ( ref $cmd eq 'ARRAY' ? @{$cmd}[1..$#{$cmd}] : ($node->{'cmd'}) ){
				$cmd_part =~ s/\Q$port\E/$data_xfer_name/;
			}
		}
		else {
			my $node_edge_std = $edge_side == $FROM? q[STDOUT]: q[STDIN];
			if($node->{$node_edge_std}){
				croak "Cannot use $node_edge_std for node ".($node->{'id'}).' more than once';
				#TODO: allow multiple STDOUT with dup?
			}
			if(exists $node->{"use_$node_edge_std"}){
				croak 'Node '.($node->{'id'})." configured not to use $node_edge_std" unless $node->{"use_$node_edge_std"};
			}
			$node->{$node_edge_std} = $data_xfer_name;
		}
	}
	else {
		# do nothing
	}

	return;
}

sub _get_from_edges {
	my ($node_id, $edges) = @_;

	my @current_from_edges = ( grep { $_->{from} =~ /^$node_id:?/; } @{$edges} );

	return \@current_from_edges;
}

sub _get_to_edges {
	my ($node_id, $edges) = @_;

	my @current_to_edges = ( grep { $_->{to} =~ /^$node_id:?/; } @{$edges} );

	return \@current_to_edges;
}

sub _fork_off {
	my ($node, $do_exec) = @_;
	my $cmd = $node->{'cmd'};
	my @cmd = ($cmd);
	if ( ref $cmd eq 'ARRAY' ){
		@cmd = @{$cmd};
		$cmd = '[' . (join ',',@cmd)  . ']';
	}

	if(my $pid=fork) {     # parent - record the child's departure
		$logger->($VLMED, qq[*** Forked off pid $pid with cmd: $cmd\n]);

		return $pid;
	}
	elsif(defined $pid) { # child - note: one way or the other, we're not returning from here
		$logger->($VLMED, qq[Child $$ ; cmd: $cmd\n]);

		if($do_exec) {
			$0 .= q{ (pending }.$node->{'id'}.qq{: $cmd)}; #rename process so fork can be easily identified whilst open waits on fifo
			open STDERR, q(>), $node->{'id'}.q(.).$$.q(.err) or croak "Failed to reset STDERR, pid $$ with cmd: $cmd";
			select(STDERR);$|=1;
			$node->{'STDIN'} ||= '/dev/null';
			open STDIN,  q(<), $node->{'STDIN'} or croak "Failed to reset STDIN, pid $$ with cmd: $cmd";
			$node->{'STDOUT'} ||= '/dev/null';
			open STDOUT, q(>), $node->{'STDOUT'} or croak "Failed to reset STDOUT, pid $$ with cmd: $cmd";
			print STDERR "Process $$ for cmd $cmd:\n";
			print STDERR ' fileno(STDIN,'.(fileno STDIN).') reading from '.$node->{'STDIN'} ."\n";
			print STDERR ' fileno(STDOUT,'.(fileno STDOUT).') writing to '.$node->{'STDOUT'}."\n";
			print STDERR ' fileno(STDERR,'.(fileno STDERR).")\n";
			print STDERR " execing....\n";
			exec @cmd;
		}
		else {
			$logger->($VLMED, q[child exec not switched on], "\n");
			exit 0;
		}
	}else{
		$logger->($VLMED, qq[*** Failed to fork off with cmd: $cmd\n]);
		croak qq[Failed to fork off with cmd: $cmd\n];
	}
}

sub mklogger {
	my ($verbosity_level, $log, $label) = @_;
	my $logf;
	my @mnthnames = qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );

	# $log can be an open file handle, a string (file name) or undef (log to STDERR)
	if(ref $log eq 'GLOB') {
		$logf = $log;
	}
	elsif($log) {	# sorry, log file named "0" is not allowed
		open $logf, ">$log" or croak q[Failed to open log file: ], $log;
	}
	else {
		$logf = *STDERR;
	}

	if($label) {
		$label = "($label) ";
	}
	else {
		$label = '';
	}

	my @hlt = localtime;
	unless($verbosity_level == 0) { printf $logf "*** %d-%s-%d %02d:%02d:%02d - %s%s (%d) ***\n", $hlt[3], $mnthnames[$hlt[4]], $hlt[5]+1900, (reverse((@hlt)[0..2])), "created logger", $label, $verbosity_level; }

	return sub {
		my ($ms_level, @ms) = @_;

		return if ($ms_level > $verbosity_level);

		my @lt = localtime;
		printf $logf "*** %d-%s-%d %02d:%02d:%02d (%d/%d) %s- %s ***\n", $lt[3], $mnthnames[$lt[4]], $lt[5]+1900, (reverse((localtime)[0..2])), $ms_level, $verbosity_level, $label, join("", @ms);

		return;
	}
}

sub process_raf_list {
	my ($rafs) = @_;
	my $raf_map;

	if($rafs) {
		$raf_map = { (map {  (split '=', $_); } (split /;/, $rafs)) };
	}

	return $raf_map;
}

