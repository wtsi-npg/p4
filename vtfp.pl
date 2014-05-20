#!/usr/bin/env perl

########################################################################################################
# Utility to process viv template files. Has a query mode which reports available parameters and handles
#  replacement of substitutable parameters with specified values. Croaks when all required parameters
#  are not replaced with values.
########################################################################################################

use strict;

use Getopt::Long;
use Data::Dumper;

use File::Slurp;
use JSON;

use Carp;
use Readonly;

Readonly::Scalar my $VLMIN => 1;
Readonly::Scalar my $VLMED => 2;
Readonly::Scalar my $VLMAX => 3;

my %opts;
#getopts('hsv:l:o:r:q', \%opts);

if($opts{h}) {
	die qq{vtfp.pl [-h] [-q] [-s] [-l <log_file>] [-o <output_config_name>] [-v <verbose_level>] [-keys <key> -vals <val> ...]  <viv_template>\n};
}

my $help;
my $strict_checks;
my $outname;
my $logfile;
my $verbosity_level;
my $query_mode;
my @keys = ();
my @vals = ();
GetOptions('h' => \$help, 's!' => \$strict_checks, 'v=i' => \$verbosity_level, 'l=s' => \$logfile, 'o:s' => \$outname, 'q!' => \$query_mode, 'keys=s' => \@keys, 'vals=s' => \@vals);

if($help) {
	croak qq{vtfp.pl [-h] [-q] [-s] [-l <log_file>] [-o <output_config_name>] [-v <verbose_level>] [-keys <key> -vals <val> ...]  <viv_template>\n};
}

# allow multiple options to be separated by commas
my @keys = split(/,/, join(',', @keys));
my @vals = split(/,/, join(',', @vals));
my %subst_requests;
@subst_requests{@keys} = @vals;
$query_mode ||= 0;
$verbosity_level = 1 unless defined $verbosity_level;
my $logger = mklogger($verbosity_level, $logfile, q[vtfp]);
my $vtf_name = $ARGV[0];

croak q[vtf unspecified] unless($vtf_name);

my $out;
if($outname) { open $out, ">$outname" or croak "Failed to open $outname for output"; } else { $out = *STDOUT; }

my $s = read_file($vtf_name);
my $cfg = from_json($s);

my $substitutable_params = {};
walk($cfg, []);

if($query_mode) { print join("\t", qw[KeyID AttribName Req Id RawAttrib]), "\n"; }
for my $k (keys %$substitutable_params) {
	if(!$query_mode) {
		my $node = $substitutable_params->{$k}->{target_node};
		my $new_key = $substitutable_params->{$k}->{param_name};
		my $old_key = $substitutable_params->{$k}->{old_key};

		if($subst_requests{$k}) {
			$node->{$new_key} = $subst_requests{$k};
		}
		else {
			if($substitutable_params->{$k}->{required}) {
				croak q[No substitution specified for required key ], $k, q[ (], $old_key, q[) - use -q for full list of substitutable parameters];
			}
			$node->{$new_key} = $node->{$old_key};
		}
		delete $node->{$old_key}
	}
	else {
		print $out join(qq[\t], ($k, $substitutable_params->{$k}->{param_name}, ($substitutable_params->{$k}->{required}? q[required]: q[not_required]), $substitutable_params->{$k}->{id}, $substitutable_params->{$k}->{old_key}, )), "\n";
	}
}

unless($query_mode) { print $out to_json($cfg) };

#######################################################################
# walk: walk the config structure, identifying substitable keys and add 
#  an entry for them in the substitutable_params hash
#######################################################################
sub walk {
	my ($node, my $labels) = @_;

	my $r = ref $node;
	if(!$r) {
		return;	# substitution only triggered by key names
	}
	elsif(ref $node eq q[HASH]) {
		for my $k (keys %$node) {
			if($k =~ /^:(.*):$/) {
				my $pname = $1;
				my $req_param = 0;
				if($pname =~ /^:(.*):$/) {
					$pname = $1;
					$req_param = 1;
				}
				my $id = $node->{id};
				$id ||= q[noid];  # or croak? Should IDs be require here?
				my $label = join(q[_], (@$labels, $id, $pname));
				$logger->($VLMED, ">>> label: $label, param name: $pname");
				$substitutable_params->{$label} = { param_name => $pname, target_node => $node, old_key => $k, required => $req_param, id => $id, };
			}
			if(ref $node->{$k}) {
				push @$labels, $k;
				walk($node->{$k}, $labels);
				pop @$labels;
			}
			else {
				$logger->($VLMAX, "Scalar value with ", join(q[_], @$labels), ", key $k");
			}
		}
	}
	elsif(ref $node eq q[ARRAY]) {
		for my $i (0 .. $#{$node}) {
			if(ref $node->[$i]) {
				push @$labels, $i;
				walk($node->[$i], $labels);   # index
				pop @$labels;
			}
			else {
				$logger->($VLMAX, "Non-ref element with ", join(q[_], @$labels));
			}
		}
	}
	else {
		carp "REF TYPE $r currently not processable";
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
	elsif($log) {   # sorry, log file named "0" is not allowed
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

