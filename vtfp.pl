#!/usr/bin/env perl

########################################################################################################
# Utility to process viv template files. Has a query mode which reports available parameters and handles
#  replacement of substitutable parameters with specified values. Croaks when all required parameters
#  are not replaced with values.
########################################################################################################

use strict;

use Getopt::Long;
use Data::Dumper;
use File::Which qw(which);
use Cwd qw(abs_path);
use File::Slurp;
use JSON;

use Carp;
use Readonly;

Readonly::Scalar my $VLFATAL => -2;

Readonly::Scalar my $VLMIN => 1;
Readonly::Scalar my $VLMED => 2;
Readonly::Scalar my $VLMAX => 3;

my %opts;

my $help;
my $strict_checks;
my $outname;
my $logfile;
my $verbosity_level;
my $query_mode;
my $absolute_program_paths=1;
my @keys = ();
my @vals = ();
GetOptions('help' => \$help, 'strict_checks!' => \$strict_checks, 'verbosity_level=i' => \$verbosity_level, 'logfile=s' => \$logfile, 'outname:s' => \$outname, 'query_mode!' => \$query_mode, 'keys=s' => \@keys, 'values|vals=s' => \@vals, 'absolute_program_paths!' => \$absolute_program_paths);

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

croak q[template file unspecified] unless($vtf_name);

my $out;
if($outname) { open $out, ">$outname" or croak "Failed to open $outname for output"; } else { $out = *STDOUT; }

my $s = read_file($vtf_name);
my $cfg = from_json($s);

my $substitutable_params = {};
walk($cfg, []);

if($query_mode) { print join("\t", qw[KeyID Req Id RawAttrib]), "\n"; }
for my $subst_param (keys %$substitutable_params) {
	if(not $query_mode) {

		##############################################################################################
		# produce a candidate for substitution (using the subst_constructor specification if provided)
		##############################################################################################
		my $subst_constructor = $substitutable_params->{$subst_param}->{subst_constructor};
		my $subst_candidate = make_substitutions($substitutable_params->{$subst_param}, $substitutable_params, \%subst_requests);

		##############################################################################
		# now check the validity if the substitution candidate
		#  If it succeeded:
		#    plug it in
		#  If it failed:
		#    if substitution is required, report error and die
		#    if substitution is not required, substitute a default value if specified
		#############################################################################
		my $node = $substitutable_params->{$subst_param}->{parent_node};
		my $attrib_name = $substitutable_params->{$subst_param}->{attrib_name};
		my $elem_index = $substitutable_params->{$subst_param}->{elem_index};
		my $parent_id = $substitutable_params->{$subst_param}->{parent_id};
		$parent_id ||= q[NO_PARENT_ID];
		if(defined $subst_candidate) {
			if(defined $attrib_name) {
				$node->{$attrib_name} = $subst_candidate;
			}
			elsif(defined $elem_index) {
				$node->[$elem_index] = $subst_candidate;
			}
			else {
				$logger->($VLFATAL, q[Neither attrib_name nor elem_index found for substitution specified for required substitutable param (], $subst_param, q[ for ], $attrib_name, q[ in ], $parent_id, q[) - use -q for full list of substitutable parameters]);
			}
		}
		else {
			my $parent_id = $substitutable_params->{$subst_param}->{parent_id};
			$parent_id ||= q[NO_PARENT_ID];

			if($substitutable_params->{$subst_param}->{required}) {
				$logger->($VLFATAL, q[No substitution specified for required substitutable param (], $subst_param, q[ for ], $attrib_name, q[ in ], $parent_id, q[) - use -q for full list of substitutable parameters]);
			}

			my $default_value = $substitutable_params->{$subst_param}->{default_value};
			if(defined $default_value) {
				$node->{$attrib_name} = $default_value;  # what if default isn't specified?
			}
			else { # maybe this should be fatal
				$logger->($VLMIN, q[No default value specified for apparent substitutable param (], $subst_param, q[ for ], $attrib_name, q[ in ], $parent_id, q[)]);
			}
		}
	}
	else {
		print $out join(qq[\t], ($subst_param, ($substitutable_params->{$subst_param}->{required}? q[required]: q[not_required]), $substitutable_params->{$subst_param}->{parent_id}, $substitutable_params->{$subst_param,}->{attrib_name}, )), "\n";
	}
}

###########################################################
# This needs amending to cope with commands that are arrays
###########################################################
###if($absolute_program_paths){
###	foreach my $node_with_cmd ( grep {$_->{'cmd'}} @{$cfg->{'nodes'}}) {
###		$node_with_cmd->{'cmd'} =~ s/\A(\S+)/ abs_path( (-x $1 ? $1 : undef) || (which $1) || croak "cannot find program $1" )/e;
###	}
###}
###########################################################

unless($query_mode) { print $out to_json($cfg) };

#########################################################################
# walk: walk the config structure, identifying substitable params and add 
#  an entry for them in the substitutable_params hash
#########################################################################
sub walk {
	my ($node, my $labels) = @_;

	my $r = ref $node;
	if(!$r) {
		return;	# substitution only triggered by key names
	}
	elsif(ref $node eq q[HASH]) {
		for my $k (keys %$node) {
			if(ref $node->{$k} eq q[HASH] and my $param_name = $node->{$k}->{subst_param_name}) {
				my $parent_id = $node->{id};   # used for logging
				my $req_param = ($node->{$k}->{required} and $node->{$k}->{required} eq q[yes])? 1: 0;
				my $subst_constructor = $node->{$k}->{subst_constructor};  # I expect this will always be an ARRAY ref, though this will only be enforced by the caller
				my $default_value = $node->{$k}->{default};
				$default_value ||= q[NO_DEFAULT_SPECIFIED];
				$substitutable_params->{$param_name} = { param_name => $param_name, parent_node => $node, parent_id => $parent_id, attrib_name => $k, required => $req_param, subst_constructor => $subst_constructor, default_value => $default_value, };
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
			# if one of the elements is a subst_param hash, 
			if(ref $node->[$i] eq q[HASH] and my $param_name = $node->[$i]->{subst_param_name}) {
				my $req_param = ($node->[$i]->{required} and $node->[$i]->{required} eq q[yes])? 1: 0;
				my $subst_constructor = $node->[$i]->{subst_constructor};  # I expect this will always be an ARRAY ref, though this will only be enforced by the caller
				my $default_value = $node->[$i]->{default};
				$default_value ||= q[NO_DEFAULT_SPECIFIED];
				$substitutable_params->{$param_name} = { param_name => $param_name, parent_node => $node, elem_index => $i, required => $req_param, subst_constructor => $subst_constructor, default_value => $default_value, };
			}
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

#################################################################################################################
# make_substitutions:
# check the subst_constructor parameter which gives instructions on how to construct the value to be substituted.
# If defined, subst_constructor is a HASH ref with two attributes:
#   "vals": ARRAY ref; any elements which are subst_params will be recursively expanded
#   "postproc": (optional) HASH ref; specifies any post-processing on the "vals" ARRAY ref. Initially, this
#      will only be flavours of concatenation of the array elements
#
# If subst_constructor is not present, then the value to substitute should be available from the subst_requests
# (which are derived from the command line keys/vals flags); the subst_requests key will be the value given
# in the subst_param_name attribute
#################################################################################################################
sub make_substitutions {
	my ($subst_param, $substitutable_params, $subst_requests) = @_;
	my $subst_return; # return value

	my $subst_constructor = $subst_param->{subst_constructor};

	if(not defined $subst_constructor) {
		####################################################################################################
		# simple case, we should end up with a string which the caller will be responsible for substituting.
		####################################################################################################

		my $subst_param_name = $subst_param->{param_name};

		# decide if substitution was successful, die if not

		my $node = $subst_param->{parent_node};
		my $attrib_name = $subst_param->{attrib_name};
		my $elem_index = $subst_param->{elem_index};
		my $parent_id = $subst_param->{parent_id};

		if(defined $subst_requests{$subst_param_name}) {
			if(defined $attrib_name) {
				$subst_return = $subst_requests{$subst_param_name};
			}
			elsif(defined $elem_index) {
				$subst_return = $subst_requests{$subst_param_name};
			}
			else {
				$logger->($VLFATAL, q[Neither attrib_name nor elem_index found for substitution specified for required substitutable param (], $subst_param_name, q[ for ], $attrib_name, q[ in ], $parent_id, q[) - use -q for full list of substitutable parameters]);
			}
		}
		else {  # if substitution not required, use default value if supplied
			my $parent_id = $substitutable_params->{$subst_param_name}->{parent_id};
			$parent_id ||= q[NO_PARENT_ID];

			if($substitutable_params->{$subst_param_name}->{required}) {
				$logger->($VLFATAL, q[No substitution specified for required substitutable param (], $subst_param_name, q[ for ], $attrib_name, q[ in ], $parent_id, q[) - use -q for full list of substitutable parameters]);
			}

			my $default_value = $substitutable_params->{$subst_param_name}->{default_value};
			if(defined $default_value) {
				$subst_return = $default_value;
			}
			else { # maybe this should be fatal
				$logger->($VLMIN, q[No default value specified for apparent substitutable param (], $subst_param_name, q[ for ], $attrib_name, q[ in ], $parent_id, q[)]);
			}
		}
	}
	else {
		################################################################
		# "subst_constructor" must be a hash ref containing a "vals" key
		################################################################
		my $svrt = ref $subst_constructor;
		$svrt ||= q[non-ref];
		unless($svrt eq q[HASH]) {
			$logger->($VLFATAL, q[subst_constructor attribute in substitutable_params section must be an HASH ref, here it is: ], $svrt);
		}
		my $vals;
		unless($vals = $subst_constructor->{vals}) {
			$logger->($VLFATAL, q[subst_constructor attribute requires a vals attribute]);
		}

		###########################
		# expand the array elements
		###########################
		$vals = [ map { (ref $_ eq q[HASH] and $_->{subst_param_name})? make_substitutions($substitutable_params->{$_->{subst_param_name}}, $_, $substitutable_params, $subst_requests) : $_; } @$vals ];

		####################################
		# postprocess the ARRAY if requested
		####################################
		my $postproc = $subst_constructor->{postproc};
		$postproc ||= {op => q[noconcat]};
		if($postproc->{op} eq q[concat]) {
			my $pad = $postproc->{pad};
			$pad ||= q[];

			$vals = join($pad, @$vals);
		}
		else {
			unless($postproc->{op} eq q[noconcat]) {
				$logger->($VLFATAL, q[Unrecognised op "], $postproc->{op}, q[" in subst_constructor]);
			}
		}
			
		$subst_return = $vals;
	}

	return $subst_return;
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
		my $ms = join("", @ms);
		printf $logf "*** %d-%s-%d %02d:%02d:%02d (%d/%d) %s- %s ***\n", $lt[3], $mnthnames[$lt[4]], $lt[5]+1900, (reverse((localtime)[0..2])), $ms_level, $verbosity_level, $label, $ms;
		if($ms_level == $VLFATAL) {
			croak q[FATAL ERROR: ], $ms;
		}

		return;
	}
}

