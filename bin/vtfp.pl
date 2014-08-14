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
use List::MoreUtils qw(any);
use Cwd qw(abs_path);
use File::Slurp;
use JSON;

use Carp;
use Readonly;

our $VERSION = '0';

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
@keys = split(/,/, join(',', @keys));
@vals = split(/,/, join(',', @vals));

my %subst_requests;
@subst_requests{@keys} = @vals;

$query_mode ||= 0;
$verbosity_level = 1 unless defined $verbosity_level;
my $logger = mklogger($verbosity_level, $logfile, q[vtfp]);
$logger->($VLMIN, 'vtfp.pl version '.($VERSION||q(unknown_not_deployed)).', running as '.$0);
my $vtf_name = $ARGV[0];

croak q[template file unspecified] unless($vtf_name);
$logger->($VLMED, 'Using template file '.$vtf_name);

my $out;
if($outname) { open $out, ">$outname" or croak "Failed to open $outname for output"; } else { $out = *STDOUT; }

my $cfg = read_the_vtf($vtf_name);
my $substitutable_params = walk($cfg, [], {});

if($query_mode) { print join("\t", qw[KeyID Req Id RawAttrib]), "\n"; }

do_substitutions($substitutable_params, \%subst_requests, $query_mode);

############################################################################
# now search the processed graph for subgraphs. Expand the subgraphs using
#  walk() and make_substitutions() as before
# Bear in mind that there may be nested subgraphs (beware of Russian dolls).
# Also a check should be made to avoid infinite recursion where A includes B
# and B includes A (however camouflaged).
# The issue of query_mode needs revisiting very soon.
############################################################################
my $arbitrary_prefix = 0;
my $vtf_nodes = [ (grep { $_->{type} eq q[VTFILE]; } @{$cfg->{nodes}}) ];
for my $vtnode (@$vtf_nodes) {
	$arbitrary_prefix++;

	my $subcfg = read_the_vtf($vtnode->{name});

	# perform any param substitutions in the the subgraph after adding/overriding any subst_request mappings specified via subst_map
	my $stash = { del_keys => [], store_vals => {}, };
	my $subst_map = {};
	if($subst_map = $vtnode->{subst_map}) {
		for my $smk (keys %$subst_map) {
			if(exists $subst_requests{$smk}) {
				$stash->{store_vals}->{$smk} = $subst_requests{$smk};   # check subst_map for multiple use of same key?
			}
			else {
				push @{$stash->{del_keys}}, $smk;
			}
			$subst_requests{$smk} = $subst_map->{$smk};
		}
	}


	my $substitutable_params = walk($subcfg, [], {});
	do_substitutions($substitutable_params, \%subst_requests, $query_mode);

	# add the new nodes and edges to the top-level graph (id alterations will be done first to ensure no clash with existing ids [WIP])
	$subcfg->{nodes} = [ (map { $_->{id} = sprintf "%03d_%s", $arbitrary_prefix, $_->{id}; $_; } @{$subcfg->{nodes}}) ];
	$subcfg->{edges} = [ (map { $_->{from} = sprintf "%03d_%s", $arbitrary_prefix, $_->{from}; $_->{to} = sprintf "%03d_%s", $arbitrary_prefix, $_->{to}; $_; } @{$subcfg->{edges}}) ];
	push @{$cfg->{nodes}}, @{$subcfg->{nodes}};
	push @{$cfg->{edges}}, @{$subcfg->{edges}};  # in the first instance, I'm assuming this subgraph has no subgraphs of its own

	# determine input node(s) in the subgraph
	my $subgraph_nodes_in = $subcfg->{subgraph_io}->{ports}->{inputs};
	my $subgraph_nodes_out = $subcfg->{subgraph_io}->{ports}->{outputs};

	# now fiddle the edges in the top-level cfg

	#  first inputs to the subgraph...
	my $in_edges = [ (grep { $_->{to} =~ /^$vtnode->{id}(:|$)/; } @{$cfg->{edges}}) ];
	if(@$in_edges and not $subgraph_nodes_in) { $logger->($VLFATAL, q[Cannot remap VTFILE node "], $vtnode->{id}, q[". No inputs specified in subgraph ], $vtnode->{name}); }
	for my $edge (@$in_edges) {
		if($edge->{to} =~ /^$vtnode->{id}:?(.*)$/) {
			my $portkey = $1;
			$portkey ||= q[_stdin_];

			my $port;
			unless(($port = $subgraph_nodes_in->{$portkey})) {
				$logger->($VLFATAL, q[Failed to map port in subgraph: ], $vtnode->{id}, q[:], $portkey);
			}

			# do check for existence of port in 
			$edge->{to} = sprintf "%03d_%s", $arbitrary_prefix, $port;
		}
		else {
			$logger->($VLMIN, q[Currently only edges to stdin processed when remapping VTFILE edges. Not processing: ], $edge->{to}, q[ in edge: ], $edge->{id});
			next;
		}
	}

	#  ...then outputs from the subgraph
	my $out_edges = [ (grep { $_->{from} =~ /^$vtnode->{id}(:|$)/; } @{$cfg->{edges}}) ];
	if(@$out_edges and not $subgraph_nodes_out) { $logger->($VLFATAL, q[Cannot remap VTFILE node "], $vtnode->{id}, q[". No outputs specified in subgraph ], $vtnode->{name}); }
	for my $edge (@$out_edges) {
		if($edge->{from} =~ /^$vtnode->{id}:?(.*)$/) {
			my $portkey = $1;
			$portkey ||= q[_stdout_];

			my $port;
			unless(($port = $subgraph_nodes_out->{$portkey})) {
				$logger->($VLFATAL, q[Failed to map port in subgraph: ], $vtnode->{id}, q[:], $portkey);
			}

			# do check for existence of port in 
			$edge->{from} = sprintf "%03d_%s", $arbitrary_prefix, $port;
		}
		else {
			$logger->($VLMIN, q[Currently only edges to stdin processed when remapping VTFILE edges. Not processing: ], $edge->{to}, q[ in edge: ], $edge->{id});
			next;
		}
	}

	# restore subst_request mappings to original state
	for my $smk (keys %{$stash->{store_vals}}) {
		$subst_requests{$smk} = $subst_map->{$smk};
	}
	for my $dk (@{$stash->{del_keys}}) {
		delete $subst_requests{$dk};
	}
}

# now remove all the VTFILE nodes (assumption: all remappings were sucessful and complete)
$cfg->{nodes} = [ (grep { $_->{type} ne q[VTFILE]; } @{$cfg->{nodes}}) ];

if($absolute_program_paths){
        foreach my $node_with_cmd ( grep {$_->{'cmd'}} @{$cfg->{'nodes'}}) {
                my $cmd_ref = \$node_with_cmd->{'cmd'};
                if(ref ${$cmd_ref} eq 'ARRAY') { $cmd_ref = \${${$cmd_ref}}[0]}
                ${$cmd_ref} =~ s/\A(\S+)/ abs_path( (-x $1 ? $1 : undef) || (which $1) || croak "cannot find program $1" )/e;
        }
}

unless($query_mode) { print $out to_json($cfg) };

#######################################################################
# walk: walk the config structure, identifying substitutable params and
#  add an entry for them in the substitutable_params hash
#######################################################################
sub walk {
	my ($node, $labels, $substitutable_params) = @_;

	my $r = ref $node;
	if(!$r) {
		return $substitutable_params;	# substitution only triggered by key names
	}
	elsif(ref $node eq q[HASH]) {
		for my $k (keys %$node) {
			if(ref $node->{$k} eq q[HASH] and my $param_name = $node->{$k}->{subst_param_name}) {
				my $parent_id = $node->{id};   # used for logging
				my $req_param = ($node->{$k}->{required} and $node->{$k}->{required} eq q[yes])? 1: 0;
				my $subst_constructor = $node->{$k}->{subst_constructor};  # I expect this will always be an ARRAY ref, though this will only be enforced by the caller
				my $default_value = $node->{$k}->{default};
				if(not defined $substitutable_params->{$param_name}) {
					$substitutable_params->{$param_name} = { param_name => $param_name, parent_info => [ { parent_node => $node, parent_id => $parent_id, attrib_name => $k, }, ], required => $req_param, subst_constructor => $subst_constructor, default_value => $default_value, depth => scalar @$labels, };
				}
				else {
					push @{$substitutable_params->{$param_name}->{parent_info}}, { parent_node => $node, parent_id => $parent_id, attrib_name => $k, };
				}
			}
			if(ref $node->{$k}) {
				push @$labels, $k;
				walk($node->{$k}, $labels, $substitutable_params);
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
				if(not defined $substitutable_params->{$param_name}) {
					$substitutable_params->{$param_name} = { param_name => $param_name, parent_info => [ { parent_node => $node, elem_index => $i, }, ], required => $req_param, subst_constructor => $subst_constructor, default_value => $default_value, depth => scalar @$labels, };
				}
				else {
					push @{$substitutable_params->{$param_name}->{parent_info}}, { parent_node => $node, elem_index => $i, };
				}
			}
			if(ref $node->[$i]) {
				push @$labels, $i;
				walk($node->[$i], $labels, $substitutable_params);   # index
				pop @$labels;
			}
			else {
				$logger->($VLMAX, "Non-ref element with ", join(q[_], @$labels));
			}
		}
	}
	elsif(ref $node eq q[JSON::XS::Boolean]) {
	}
	else {
		carp "REF TYPE $r currently not processable";
	}

	return $substitutable_params;
}

sub do_substitutions {
	my ($substitutable_params, $subst_requests, $query_mode) = @_;

	for my $subst_param_name (sort { $substitutable_params->{$a}->{depth} <=> $substitutable_params->{$b}->{depth} } (keys %$substitutable_params)) {

		if(not $query_mode and $substitutable_params->{$subst_param_name}->{processed}) {
			next;
		}

		my $subst_value = make_substitutions($subst_param_name, $substitutable_params, \%subst_requests, $query_mode);

		if($query_mode) {
			print $out join(qq[\t], ($subst_param_name, ($substitutable_params->{$subst_param_name}->{required}? q[required]: q[not_required]), $substitutable_params->{$subst_param_name}->{parent_id}, $substitutable_params->{$subst_param_name,}->{attrib_name}, )), "\n";
		}
	}

	return $substitutable_params;
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
# (which are derived from the command line keys/vals flags) or from a specified default value; the subst_requests
# key will be the value given in the subst_param_name attribute
#
# When query_mode is true, substitutions aren't done, but any nested substitutions are flagged as processed.
#  If, when working through nested substitutions, an explicit value has been specified via the command-line
#  flags, query_mode is switched on so that any inner substitutions are simply flagged as processed so they will
#  be skipped by the top-level processing loop.
#################################################################################################################
sub make_substitutions {
	my ($subst_param_name, $substitutable_params, $subst_requests, $query_mode) = @_;
	my $subst_value;

	#################################################################################################################
	# first check to see if the value for this subst section has been explicitly set on the command line; if it has,
	#  that value takes precedence over any nested subst sections, so set query_mode on after making the substitution
	#################################################################################################################
	$subst_value = $subst_requests->{$subst_param_name};
	if(defined $subst_value and not $query_mode) {
		# on transition to query_mode, the current substitution should be done, but none in any nested substitutions
		do_subst($substitutable_params->{$subst_param_name}, $subst_value);
		$query_mode = 1;
	}

	my $subst_param = $substitutable_params->{$subst_param_name};
	my $subst_constructor = $subst_param->{subst_constructor};

	if(not defined $subst_constructor) {
		#####################
		# simple substitution
		#####################
		if(not $query_mode) {
			$subst_value = resolve_subst_to_string($subst_param, $subst_value, $query_mode);
		}
	}
	else {
		#######################################################################################
		# existence of a subst_constructor section means that an array of values, some of which
		#  may themselves be subst sections, needs to be processed recursively
		#######################################################################################

		#############################################################################
		# validate the subst_constructor - must be a hash ref containing a "vals" key
		#############################################################################
		my $svrt = ref $subst_constructor;
		$svrt ||= q[non-ref];
		unless($svrt eq q[HASH]) {
			$logger->($VLFATAL, q[subst_constructor attribute in substitutable_params section must be an HASH ref, here it is: ], $svrt);
		}
		my $vals;
		unless($vals = $subst_constructor->{vals}) {
			$logger->($VLFATAL, q[subst_constructor attribute requires a vals attribute]);
		}

		########################################
		# recursively process the array elements
		########################################
		$vals = [ map { (ref $_ eq q[HASH] and $_->{subst_param_name})? make_substitutions($_->{subst_param_name}, $substitutable_params, $subst_requests, $query_mode) : $_; } @$vals ];

		if(not $query_mode) {
			$subst_value = resolve_subst_array($subst_param, $vals);
		}
	}

	if(not $query_mode and defined $subst_value) {
		do_subst($subst_param, $subst_value);
	}

	$substitutable_params->{$subst_param_name}->{processed} = 1;

	return $subst_value;
}

############################################################################################################
# resolve_subst_to_string
#   validate proposed substitution value: if it is undefined, decide if a supplied default value can be used
#   NOTE: this will return undef if no subst_value is given, the sustitution isn't required, and there
#    is no default
############################################################################################################
sub resolve_subst_to_string {
	my ($subst_param, $subst_value, $query_mode) = @_;

	if(not defined $subst_value) {
		# do a little unpacking for readability
		my $attrib_name = $subst_param->{attrib_name};
		my $elem_index = $subst_param->{elem_index};
		$attrib_name ||= "element $elem_index";
		my $subst_param_name = $subst_param->{param_name};
		my $parent_id = $subst_param->{parent_id};
		my $parent_id = $subst_param->{parent_id};
		$parent_id ||= q[NO_PARENT_ID];   # should be ARRAY?

		if($subst_param->{required} and not $query_mode) { # required means "must be specified by the caller", so default value is disregarded
#			$logger->($VLFATAL, q[No substitution specified for required substitutable param (], $subst_param_name, q[ for ], $attrib_name, q[ in ], $parent_id, q[) - use -q for full list of substitutable parameters]);
			# NOTE: the decision to fail can only be decided at the top level of the subst_param structure
			$logger->($VLMIN, q[No substitution specified for required substitutable param ], $subst_param_name, q[ for ], $attrib_name, q[ in ], $parent_id);
			return;
		}

		$subst_value = $subst_param->{default_value};
		if(not defined $subst_value) {
			$logger->($VLMIN, q[No default value specified for apparent substitutable param (], $subst_param_name, q[ for ], $attrib_name, q[ in ], $parent_id, q[)]);
		}
	}

	return $subst_value;
}

############################################################################################################
# resolve_subst_array
#   caller will have already flattened the array (i.e. no ref elements)
#   process as specified by op directives (pack, concat,...)
#   validate proposed substitution value
#      1. if it contains any undef elements, it is invalid.
#      2. if it contains any null string elements but no allow_null_strings opt, it is invalid.
#
#   if invalid and a default is supplied, substition value becomes default (without further validation)
#   if undef and required, fatal error
#   return substitution value
#
#   NOTE: this will return undef if no subst_value is given, the sustitution isn't required, and there
#    is no default
############################################################################################################
sub resolve_subst_array {
	my ($subst_param, $subst_value, $query_mode) = @_;

	if(ref $subst_value ne q[ARRAY]) {
		$logger->($VLMIN, q[Attempt to substitute array for non-array in substitutable param (],
				$subst_param->{param_name},
				q[ for ], $subst_param->{attrib_name},
				q[ in ], ($subst_param->{parent_id}? $subst_param->{parent_id}: q[UNNAMED_PARENT]), q[)]);
		return;
	}

	my $subst_constructor = $subst_param->{subst_constructor};
	my $ops=$subst_constructor->{postproc}->{op};
	if(defined $ops and ref $ops ne q[ARRAY]) { $ops = [ $ops ]; }

	# if (post-pack) array contains nulls, it is invalid
	if(any { ! defined($_) } @$subst_value) {
		if(grep { $_ eq q[pack] } @$ops) {
			$subst_value = [ (grep { defined($_) } @$subst_value) ];
		}
		else {
			if($subst_param->{required}) {
				$logger->($VLFATAL, q[No substitution specified for required substitutable param (],
						$subst_param->{param_name},
						q[ for ], $subst_param->{attrib_name},
						q[ in ], ($subst_param->{parent_id}? $subst_param->{parent_id}: q[UNNAMED_PARENT]),
						q[) - use -q for full list of substitutable parameters]);
			}
			else {
				$logger->($VLMIN, q[No default value specified for apparent substitutable param (],
						$subst_param->{param_name},
						q[ for ], $subst_param->{attrib_name},
						q[ in ], ($subst_param->{parent_id}? $subst_param->{parent_id}: q[UNNAMED_PARENT]), q[)]);
				return;
			}
		}
	}

	for my $op (@$ops) {
		if($op eq q[pack]) {
			# already done
			next;
		}

		if($op eq q[noconcat]) {
			# noop
			next;
		}

		if($op eq q[concat]) {
			my $pad = $subst_constructor->{postproc}->{pad};
			$pad ||= q[];
			$subst_value = join $pad, @$subst_value;
		}
		else {
			$logger->($VLFATAL, q[Unrecognised op: ], $op, q[ in subst_param: ], $subst_param->{param_name});
		}
	}

	return $subst_value;
}

###############################################################
# do_subst:
#  Do the substitution of the primitive value into the cfg tree
###############################################################
sub do_subst {
	my ($subst_param, $subst_value) = @_;


	if(defined $subst_value) {
		for my $parent_info (@{$subst_param->{parent_info}}) {
			my $node = $parent_info->{parent_node};
			my $attrib_name = $parent_info->{attrib_name};
			my $elem_index = $parent_info->{elem_index};

			if(defined $attrib_name) {
				$node->{$attrib_name} = $subst_value;
			}
			elsif(defined $elem_index) {
				$node->[$elem_index] = $subst_value;
			}
			else {
				my $subst_param_name = $subst_param->{param_name};
				my $parent_id = $parent_info->{parent_id};
				$parent_id ||= q[NO_PARENT_ID];

				$logger->($VLFATAL, q[Neither attrib_name nor elem_index found for substitution specified for required substitutable param (], $subst_param_name, q[ for ], $attrib_name, q[ in ], $parent_id, q[) - use -q for full list of substitutable parameters]);
			}
		}
	}

	return $subst_value;
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

######################################################################
# read_the_vtf:
#  Open the file, read the JSON content, convert to hash and return it
######################################################################
sub read_the_vtf {
	my ($vtf_name) = @_;

	if(! -e $vtf_name) {
		$logger->($VLFATAL, q[Failed to find vtf file: ], $vtf_name);
	}

	my $s = read_file($vtf_name);
	my $cfg = from_json($s);

	return $cfg;
}

