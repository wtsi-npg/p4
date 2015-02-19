#!/usr/bin/env perl

#################################################################################################
# vtfp.pl
# Updated utility to process viv template files.  Handles replacement of substitutable parameters
#  with specified values. Croaks when all required parameters are not replaced with values.
# Will have a query mode which reports available parameters
#################################################################################################

use strict;
use warnings;
use Carp;
use Readonly;
use Getopt::Long;
use File::Basename;
use File::Spec;
use File::Which qw(which);
use List::MoreUtils qw(any);
use Cwd qw(abs_path);
use File::Slurp;
use JSON;
use Storable 'dclone';

our $VERSION = '0';

Readonly::Scalar my $VLFATAL => -2;

Readonly::Scalar my $VLMIN => 1;
Readonly::Scalar my $VLMED => 2;
Readonly::Scalar my $VLMAX => 3;

Readonly::Scalar my $MIN_TEMPLATE_VERSION => 1;

my $progname = (fileparse($0))[0];
my %opts;

my $help;
my $strict_checks;
my $outname;
my $template_path;
my $logfile;
my $verbosity_level;
my $query_mode;
my $absolute_program_paths=1;
my @keys = ();
my @vals = ();
GetOptions('help' => \$help, 'strict_checks!' => \$strict_checks, 'verbosity_level=i' => \$verbosity_level, 'template_path=s' => \$template_path, 'logfile=s' => \$logfile, 'outname:s' => \$outname, 'query_mode!' => \$query_mode, 'keys=s' => \@keys, 'values|vals=s' => \@vals, 'absolute_program_paths!' => \$absolute_program_paths);

if($help) {
	croak q[Usage: ], $progname, q{ [-h] [-q] [-s] [-l <log_file>] [-o <output_config_name>] [-v <verbose_level>] [-keys <key> -vals <val> ...]  <viv_template>};
}

# allow multiple options to be separated by commas
@keys = split(/,/, join(',', @keys));
@vals = split(/,/, join(',', @vals));

my $subst_requests = initialise_subst_requests(\@keys, \@vals);

$query_mode ||= 0;
$verbosity_level = $VLMIN unless defined $verbosity_level;
my $logger = mklogger($verbosity_level, $logfile, $progname);
$logger->($VLMIN, $progname , ' version '.($VERSION||q(unknown_not_deployed)).', running as '.$0);
my $vtf_name = $ARGV[0];

croak q[template file unspecified] unless($vtf_name);
$logger->($VLMED, 'Using template file '.$vtf_name);

my $out;
if($outname) { open $out, ">$outname" or croak "Failed to open $outname for output"; } else { $out = *STDOUT; }

if($template_path) {
	$template_path = [ (split q[:], $template_path) ];
}
else {
	$template_path = [];
}

my $param_store;
my $globals = { node_prefixes => { auto_node_prefix => 0, used_prefixes => {}}, vt_file_stack => [], processed_sp_files => {}, template_path => $template_path, };

my $node_tree = process_vtnode(q[], $vtf_name, q[], $param_store, $subst_requests, $globals);    # recursively generate the vtnode tree
my $flat_graph = flatten_tree($node_tree);

if($absolute_program_paths) {
	foreach my $node_with_cmd ( grep {$_->{'cmd'}} @{$flat_graph->{'nodes'}}) {
		my $cmd_ref = \$node_with_cmd->{'cmd'};
		if(ref ${$cmd_ref} eq 'ARRAY') { $cmd_ref = \${${$cmd_ref}}[0]}
		${$cmd_ref} =~ s/\A(\S+)/ abs_path( (-x $1 ? $1 : undef) || (which $1) || croak "cannot find program $1" )/e;
	}
}

print $out to_json($flat_graph);

########
# Done #
########

##########################################################################################
# process_vtnode:
#  vtnode_id - id of the VTFILE node; needed to resolve I/O connections
#  vtf_name - name of the file to read for this vtfile
#  node_prefix - if specified (note: zero-length string is "specified"), prefix all nodes
#                  from this vtfile with this string; otherwise auto-generate prefix
#  param_store - a list ref of maps of variable names to their values or constructor;
#                  supplies the values when subst directives are processed
#  subst_requests - a list ref of key/value pairs, keys are subst_param [var]names, values
#                    are string values; supplied at run time or via subst_map attributes
#                    in VTFILE nodes
#  globals - auxiliary items used for error checking/reporting (and final flattening, e.g.
#             node_prefix validation and generation for ensuring unique node ids in
#             subgraphs)
#
# Description:
#   1. read cfg for given vtf_name
#   2. process local subst_param section (if any), expanding SPFILE nodes and updating
#       param_store
#   3. process subst directives (just nodes and edges)
#   4. process nodes, expanding elements of type VTFILE (note: there will be param_store
#       and subst_request lists, containing as many entries as the current depth of VTFILE
#       nesting)
#
# Returns: root of tree of vtnodes (for later flattening)
##########################################################################################
sub process_vtnode {
	my ($vtnode_id, $vtf_name, $node_prefix, $param_store, $subst_requests, $globals) = @_;

	if(any { $_ eq $vtf_name} @{$globals->{vt_file_stack}}) {
		$logger->($VLFATAL, q[Nesting of VTFILE ], $vtf_name, q[ within itself: ], join(q[->], @{$globals->{vt_file_stack}}));
	}

	my $vtnode = { id => $vtnode_id, name => $vtf_name, cfg => {}, children => [], };
	$vtnode->{node_prefix} = get_node_prefix($node_prefix, $globals->{node_prefixes});
	$vtnode->{cfg} = read_vtf_version_check($vtf_name, $MIN_TEMPLATE_VERSION, $globals->{template_path}, );
	$param_store = process_subst_params($param_store, $subst_requests, $vtnode->{cfg}->{subst_params}, [ $vtf_name ], $globals);
	apply_subst($vtnode->{cfg}, $param_store, $subst_requests);   # process any subst directives in cfg (just nodes and edges)

	my @vtf_nodes = ();
	my @nonvtf_nodes = ();
	for my $e (@{$vtnode->{cfg}->{nodes}}) { # remove VTFILE nodes for expansion into children nodes
		if($e->{type} eq q[VTFILE]) { push @vtf_nodes, $e; }
		else { push @nonvtf_nodes, $e; }
	}
	$vtnode->{cfg}->{nodes} = [ @nonvtf_nodes ];

	push @{$globals->{vt_file_stack}}, $vtf_name;
	for my $vtf_node (@vtf_nodes) {

		# both subst_requests and param_stores have local components
		my $sr = $vtf_node->{subst_map};
		$sr ||= {};
		unshift @$subst_requests, $sr;
		my $ps = { varnames => {}, };
		unshift @$param_store, $ps;

		my $vtc = process_vtnode($vtf_node->{id}, $vtf_node->{name}, $vtf_node->{node_prefix}, $param_store, $subst_requests, $globals);

		shift @$param_store;
		shift @$subst_requests;

		push @{$vtnode->{children}}, $vtc;

	}
	pop @{$globals->{vt_file_stack}};

	return $vtnode;
}

##############################################################
# get_node_prefix:
#    validates requested node prefix.
#    If node_prefix is defined, just check to be sure
#       it is still unused and available.
#    If node_prefix is undefined, generate a new unique prefix
##############################################################
sub get_node_prefix {
	my ($node_prefix, $node_prefixes) = @_;

	if(defined $node_prefix) {
		if($node_prefixes->{used_prefixes}->{$node_prefix}) {
			$logger->($VLFATAL, q[Requested node prefix ], $node_prefix, q[ already used]);
		}
	}
	else {
		$node_prefix = sprintf "%03d_", $node_prefixes->{auto_node_prefix};
		++$node_prefixes->{auto_node_prefix};
	}

	$node_prefixes->{used_prefixes}->{$node_prefix} = 1;

	return $node_prefix;
}

#######################################################################################
# process_subst_params:
#  param_store - a list (ref) of maps of variable names to their values or constructor;
#                  supplies the values when subst directives are processed
#  subst_requests - a list (ref) of key/value pairs. Keys are subst_param varnames,
#                    values are string values; supplied at run time or via subst_map
#                    attributes in VTFILE nodes; used here to expand subst directives
#                    that appear in subst_param entries
#  unprocessed_subst_params - the list of subst_param entries to process; either of
#                    type PARAM (describes how to retrieve/construct the value for the
#                    specified varname) or SPFILE (specifies a file containing
#                    subst_params)
#  sp_file_stack - the list of file names leading to our current location, used for
#                    warning/error reporting
#  globals - used here to prevent multiple processing of SPFILE nodes and to pass the
#                  value of template_path
#
# Description:
#  process a subst_param section, adding any varnames declared in it to the "local"
#   param_store and recursively processing any included files specified by elements
#   of type SPFILE.
#
#  In other words, step through unprocessed subst_param entries:
#   a) if element is of type PARAM, add it to the "local" param_store
#   b) if element is of type SPFILE, [queue it up for] make a recursive call to
#       process_subst_params() to expand it
#
# A stack of spfile names is passed to recursive calls to allow construction of
#  error strings for later reporting (though initially just croak). Consider a slightly
#  more sophisticated structure for elements on this stack to improve error reporting
#######################################################################################
sub process_subst_params {
	my ($param_store, $subst_requests, $unprocessed_subst_params, $sp_file_stack, $globals) = @_;
	my @spfile_node_queue = ();

	$param_store ||= [ { varnames => {}, } ];

	for my $i (0..$#{$unprocessed_subst_params}) {

		my $sp = $unprocessed_subst_params->[$i];
		my $spname = $sp->{name}; 
		my $spid = $sp->{id}; 
		my $sptype = $sp->{type}; 
		$sptype ||= q[PARAM];

		if($sptype eq q[SPFILE]) {	# process recursively
			# SPFILE entries will be processed after all PARAM-type entries have been processed (for consistency in redeclaration behaviour)
			push @spfile_node_queue, $sp;
		}
		elsif($sptype eq q[PARAM]) {
			# all unprocessed_subst_params elements of type PARAM must have an id
			if(not $spid) {
				# it would be better to cache these errors and report as many as possible before exit (TBI)
				$logger->($VLFATAL, q[No id for PARAM element, entry ], $i, q[ (], , join(q[->], @$sp_file_stack), q[)]);
			}

			my $ips = in_param_store($param_store, $spid);
			if($ips->{errnum} != 0) { # multiply defined - OK unless explicitly declared multiple times at this level
				if($ips->{errnum} > 0) { # a previous declaration was made by an ancestor of the current vtnode
					$logger->($VLMED, qq[INFO: Duplicate subst_param definition for $spid (], join(q[->], @$sp_file_stack), q[); ], $ips->{ms});
				}
				else {
					# it would be better to cache these errors and report as many as possible before exit (TBI)
					$logger->($VLFATAL, qq[Fatal error: Duplicate (local) subst_param definition for $spid (], join(q[->], @$sp_file_stack), q[); ], $ips->{ms});
				}
			}

			$sp->{_declared_by} ||= [];
			push @{$sp->{_declared_by}}, join q[->], @$sp_file_stack;
			$param_store->[0]->{varnames}->{$spid} = $sp; # adding to the "local" variable store
		}
		else {
			$logger->($VLFATAL, q[Unrecognised type for subst_param element: ], $sptype, q[; entry ], $i, q[ (], , join(q[->], @$sp_file_stack), q[)]);
		}
	}

	################################
	# now process the SPFILE entries
	################################
	for my $spfile (@spfile_node_queue) {
		subst_walk($spfile, $param_store, $subst_requests, []);
		my $spname = $spfile->{name};
		if(not $spname) {
			# it would be better to cache these errors and report as many as possible before exit (TBI)
			$logger->($VLFATAL, q[No name for SPFILE element (], , join(q[->], @$sp_file_stack), q[)]);
		}

		if(not $globals->{processed_sp_files}->{$spname}) { # but only process a given SPFILE once
			$globals->{processed_sp_files}->{$spname} = 1;   # flag this SPFILE name as seen

			my $cfg = read_vtf_version_check($spname, $MIN_TEMPLATE_VERSION, $globals->{template_path},);

			# NOTE: no mixing of subst_param formats in a template set - in other words, included subst_param
			#  files must contain (new-style) subst_param sections to be useful
			if(defined $cfg->{subst_params}) {
				push @$sp_file_stack, $spname;
				process_subst_params($param_store, $subst_requests, $cfg->{subst_params}, $sp_file_stack, $globals);
				pop @$sp_file_stack;
			}
		}
		else {
			$logger->($VLMAX, qq[INFO: Not processing reoccurrence of SPFILE $spname (], join(q[->], @$sp_file_stack), q[)]);  # needs to be a high-verbosity warning
		}
	}

	return $param_store;
}

##########################################################################
# in_param_store:
#  return errnum of 0 if not in store, -1 if it was explicitly declared in
#  the "local" store, 1 otherwise (this is to allow presence in non-local
#  store to be legal)
##########################################################################
sub in_param_store {
	my ($param_store, $spid) = @_;

	for my $i (0..$#{$param_store}) {
		if($param_store->[$i]->{varnames}->{$spid}) {
			if($i == 0) {
				if(defined $param_store->[$i]->{varnames}->{$spid}->{_declared_by} and @{$param_store->[$i]->{varnames}->{$spid}->{_declared_by}} > 0) {
					return { errnum => -1, ms => q[duplicate local declaration of ] . $spid . q[, already declared in: ] . join q[, ], @{$param_store->[$i]->{varnames}->{$spid}->{_declared_by}}, };
				}
				else {
					return { errnum => 1, ms => q[already declared locally, but only implicitly], };
				}
			}
			else {
				return { errnum => 1, ms => q[already declared, but not locally; declarations in: ] . join q[, ], @{$param_store->[$i]->{varnames}->{$spid}->{_declared_by}} };
			}
		}
	}

	return { errnum => 0, ms => q[], };
}

#######################################
# apply_subst:
#  replace subst directives with values
#######################################
sub apply_subst {
	my ($cfg, $param_store, $subst_requests) = @_;   # process any subst directives in cfg (just nodes and edges?)

	for my $elem (@{$cfg->{nodes}}, @{$cfg->{edges}}) {
		subst_walk($elem, $param_store, $subst_requests, []);
	}
}

##############################################################################################################
# subst_walk:
#  walk the given element, looking for "subst" directives. When found search the param_store and subst_request
#   lists for the desired key/value pair
##############################################################################################################
sub subst_walk {
	my ($elem, $param_store, $subst_requests, $labels) = @_;

	my $r = ref $elem;
	if(!$r) {
		next;	# hit the bottom
	}
	elsif(ref $elem eq q[HASH]) {
		for my $k (keys %$elem) {

			if(ref $elem->{$k} eq q[HASH] and my $param_name = $elem->{$k}->{subst}) {
				# value for a "subst" key must always be the name of a parameter
				if(ref $param_name) {
					$logger->($VLFATAL, q[value for a subst directive must be a param (not a reference), key for subst is: ], $k);
				}

				$elem->{$k} = fetch_subst_value($param_name, $param_store, $subst_requests);

				unless(defined $elem->{$k}) {
					$logger->($VLFATAL, croak q[Failed to fetch subst value for parameter ], $param_name, q[ (key was ], $k, q[)]);
				}

				next;
			}

			if(ref $elem->{$k}) {
				push @$labels, $k;
				subst_walk($elem->{$k}, $param_store, $subst_requests, $labels);
				pop @$labels;
			}
		}
	}
	elsif(ref $elem eq q[ARRAY]) {
		for my $i (0 .. $#{$elem}) {
			# if one of the elements is a subst_param hash,
			if(ref $elem->[$i] eq q[HASH] and my $param_name = $elem->[$i]->{subst}) {
				# value for a "subst" key must always be the name of a parameter
				if(ref $param_name) {
					$logger->($VLFATAL, q[value for a subst directive must be a param name (not a reference), index for subst is: ], $i);
				}

#				$elem->[$i] = fetch_subst_value($param_name, $param_store, $subst_requests);
				my $sval = fetch_subst_value($param_name, $param_store, $subst_requests);
				if(ref $sval eq q[ARRAY]) {
					splice @$elem, $i, 1, @$sval;
				}
				else {
					$elem->[$i] = $sval;
				}

				unless(defined $elem->[$i]) {
					$logger->($VLFATAL, q[Failed to fetch subst value for parameter ], $param_name, q[ (element index was ], $i);
				}

				next;
			}

			if(ref $elem->[$i]) {
				push @$labels, sprintf(q[ArrayElem%03d], $i);
				subst_walk($elem->[$i], $param_store, $subst_requests, $labels);
				pop @$labels;
			}
		}
	}
	elsif(ref $elem eq q[JSON::XS::Boolean]) {
	}
	else {
		$logger->($VLMED, "REF TYPE $r currently not processable");
	}

	return;
}

##################################################################
# fetch_subst_value:
#  use the param_store and subst_requests to find or construct
#  a value for the given param_name. The _value attribute of a
#  param_entry caches successfully resolved values.
#
#   1. Search the param_store for an entry for this param_name.
#   2. If there isn't a param_store entry, add [an unset] one.
#   3. If the param_entry _value attribute is set, return that.
#   4. Search subst_requests for a value for this param_name. If
#       one is found, return it.
#   5. Try evaluating the param_entry. If it resolves, return that
#       value.
#   6. If a default value value was specified in the param_entry,
#       return that.
#   7. If the required attribute of the param_entry is true,
#       it is a fatal error; otherwise return undef
##################################################################
sub fetch_subst_value {
	my ($param_name, $param_store, $subst_requests) = @_;
	my $param_entry;
	my $retval;

	for my $ps (@$param_store) {
		$param_entry = $ps->{varnames}->{$param_name};
		if($param_entry) { last; }
	}

	if(not defined $param_store->[0]->{varnames}->{$param_name}) {	# create a "writeable" param_store entry at local level
		my $new_param_entry = (not defined $param_entry)? { name => $param_name, }: dclone $param_entry;

		$param_store->[0]->{varnames}->{$param_name} = $new_param_entry; # adding to the "local" variable store

		$param_entry = $new_param_entry;
	}

	if(defined $param_entry->{_value}) {
		return $param_entry->{_value};   # already evaluated, no need to do again
	}

	for my $sr (@$subst_requests) {
		$retval = $sr->{$param_name};
		if(defined $retval) { last; }
	}

	if(defined $retval) {
		$param_entry->{_value} = $retval;
		return $retval;
	}

	if($param_entry->{subst_constructor}) {
		my $vals;
		unless($vals = $param_entry->{subst_constructor}->{vals}) {
			$logger->($VLFATAL, q[subst_constructor attribute requires a vals attribute, param_name: ], $param_name);
		}

		unless(ref $vals eq q[ARRAY]) {
			$logger->($VLFATAL, q[subst_constructor vals attribute must be array, param_name: ], $param_name);
		}

		for my $i (0..$#$vals) {
			if(ref $vals->[$i] eq q[HASH] and $vals->[$i]->{subst}) {
				$vals->[$i] = fetch_subst_value($vals->[$i]->{subst}, $param_store, $subst_requests);
				if(ref $vals->[$i] eq q[ARRAY]) {
					splice(@$vals, $i, 1, (@{$vals->[$i]}));
				}
			}
		}

		$retval = resolve_subst_array($param_entry, $vals);

		if(not defined $retval) {
			$retval = $param_entry->{default};
		} 
		if(not defined $retval) {
			# caller should decide if undef is allowed, unless required is true
			my $severity = (defined $param_entry->{required} and $param_entry->{required} eq q[yes])? $VLFATAL: $VLMED;
			$logger->($severity, q[INFO: Undefined elements in subst_param array: ], $param_entry->{id});
			return;
		}
	}
	elsif(defined $param_entry->{default}) {
		$param_entry->{_value} = $param_entry->{default}; # be careful here - don't set _value for a higher-level param_store
		return $param_entry->{default};
	}
	else {
		# caller should decide if undef is allowed, unless required is true
		my $severity = (defined $param_entry->{required} and $param_entry->{required} eq q[yes])? $VLFATAL: $VLMED;
		$logger->($severity, q[No value found for param_entry ], $param_name);
		return;
	}

	$param_entry->{_value} = $retval; # be careful here - don't set _value for a higher-level param_store

	return $retval;
}

#######################################################################################################
# resolve_subst_array:
#   caller will have already flattened the array (i.e. no ref elements)
#   process as specified by op directives (pack, concat,...)
#   validate proposed substitution value
#      1. if it contains any undef elements, it is invalid.
#      2. if it contains any null string elements but no allow_null_strings opt, it is invalid. (TBI)
#######################################################################################################
sub resolve_subst_array {
	my ($subst_param, $subst_value) = @_;

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

	# if (post-pack) array contains undefs, it is invalid
	if(any { ! defined($_) } @$subst_value) {
		if(grep { $_ eq q[pack] } @$ops) {
			$subst_value = [ (grep { defined($_) } @$subst_value) ];
		}
		else {
			# decision about fatality should be left to the caller
			$logger->($VLMED, q[INFO: Undefined elements in subst_param array: ], $subst_param->{id});
			return;
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

#######################################################################################
# flatten_tree:
#
# Take the node_tree produced by process_vtnode() and flatten it into one graph. Main
#  tasks are to update node ids with prefixes (to ensure uniqueness) and remap edges to
#  subgraph nodes.
#
# Note: at the moment, only the nodes and edges are being transferred to the final flat
#         graph. In other words, any comments, descriptions, etc which appear outside
#         of these sections will be discarded. Is this a problem? (Consider review of
#         the resulting graph with one of the visualisation tools.)
#######################################################################################
sub flatten_tree {
	my ($tree_node, $flat_graph) = @_; 

	$flat_graph ||= {};

	# insert edges and nodes from current tree_node to $flat_graph
	subgraph_to_flat_graph($tree_node, $flat_graph);

	# do the same recursively for any children
	for my $tn (@{$tree_node->{children}}) {
		flatten_tree($tn, $flat_graph);
	}

	return $flat_graph;
}

#########################################################################################
# subgraph_to_flat_graph:
#  losing everything except nodes and edges is a possibly undesirable side-effect of this
#########################################################################################
sub subgraph_to_flat_graph {
	my ($tree_node, $flat_graph) = @_;

	my $vtnode_id = $tree_node->{id};
	my $vt_name = $tree_node->{name};

	my $subcfg = $tree_node->{cfg};

	###################################################################################
	# prefix the nodes in this subgraph with a prefix to ensure uniqueness of id values
	###################################################################################
	$subcfg->{nodes} = [ (map { $_->{id} = sprintf "%s%s", $tree_node->{node_prefix}, $_->{id}; $_; } @{$subcfg->{nodes}}) ];

	########################################################################
	# any edges which refer to nodes in this subgraph should also be updated
	########################################################################
	for my $edge (@{$subcfg->{edges}}) {
		if(not get_child_prefix($tree_node->{children}, $edge->{from})) { # if there is a child prefix, this belongs to a subgraph - don't prefix it
			$edge->{from} = sprintf "%s%s", $tree_node->{node_prefix}, $edge->{from};
		}
		if(not get_child_prefix($tree_node->{children}, $edge->{to})) { # if there is a child prefix, this belongs to a subgraph - don't prefix it
			$edge->{to} = sprintf "%s%s", $tree_node->{node_prefix}, $edge->{to};
		}
	}

	##########################################################
	# add the new nodes and edges to the flat graph structure.
	##########################################################
	push @{$flat_graph->{nodes}}, @{$subcfg->{nodes}};
	push @{$flat_graph->{edges}}, @{$subcfg->{edges}};

	# determine input/output node(s) in the subgraph
	my $subgraph_nodes_in = $subcfg->{subgraph_io}->{ports}->{inputs};
	my $subgraph_nodes_out = $subcfg->{subgraph_io}->{ports}->{outputs};

	# now fiddle the edges in the flattened graph (maybe "fiddle" should be defined)

	# first inputs to the subgraph... (identify edges in the flat graph which terminate in nodes of this subgraph; use the subgraph_io section of the subgraph to remap these edge destinations)
	my $in_edges = [ (grep { $_->{to} =~ /^$vtnode_id(:|$)/; } @{$flat_graph->{edges}}) ];
	if(@$in_edges and not $subgraph_nodes_in) { $logger->($VLFATAL, q[Cannot remap VTFILE node "], $vtnode_id, q[". No inputs specified in subgraph ], $vt_name); }
	for my $edge (@$in_edges) {
		if($edge->{to} =~ /^$vtnode_id:?(.*)$/) {
			my $portkey = $1;
			$portkey ||= q[_stdin_];

			my $ports = $subgraph_nodes_in->{$portkey};
			unless($ports) {
				$logger->($VLFATAL, q[Failed to map port in subgraph: ], $vtnode_id, q[:], $portkey);
			}
			my $pt = ref $ports;
			if($pt) {
				if($pt ne q[ARRAY]) {
					$logger->($VLFATAL, q[Input ports specification values in subgraphs must be string or array ref. Type ], $pt, q[ not allowed]);
				}
			}
			else {
				$ports = [ $ports ];
			}

			# do check for existence of port in 
			for my $i (0..$#$ports) {
				my $mod_edge;
				if($i > 0) {
					$mod_edge = dclone $edge;
					push @{$flat_graph->{edges}}, $mod_edge;
				}
				else {
					$mod_edge = $edge;
				}
				if(get_child_prefix($tree_node->{children}, $ports->[$i])) { # if there is a child prefix, this belongs to a subgraph - don't prefix it
					$mod_edge->{to} = $ports->[$i];
				}
				else {
					$mod_edge->{to} = sprintf "%s%s", $tree_node->{node_prefix}, $ports->[$i];
				}
			}
		}
		else {
			$logger->($VLMIN, q[Currently only edges to stdin processed when remapping VTFILE edges. Not processing: ], $edge->{to}, q[ in edge: ], $edge->{id});
			next;
		}
	}

	#  ...then outputs from the subgraph (identify edges in the flat graph which originate in nodes of the subgraph; use the subgraph_io section of the subgraph to remap these edge destinations)
	my $out_edges = [ (grep { $_->{from} =~ /^$vtnode_id(:|$)/; } @{$flat_graph->{edges}}) ];
	if(@$out_edges and not $subgraph_nodes_out) { $logger->($VLFATAL, q[Cannot remap VTFILE node "], $vtnode_id, q[". No outputs specified in subgraph ], $vt_name); }
	for my $edge (@$out_edges) {
		if($edge->{from} =~ /^$vtnode_id:?(.*)$/) {
			my $portkey = $1;
			$portkey ||= q[_stdout_];

			my $port;
			unless(($port = $subgraph_nodes_out->{$portkey})) {
				$logger->($VLFATAL, q[Failed to map port in subgraph: ], $vtnode_id, q[:], $portkey);
			}

			# do check for existence of port in 
			if(get_child_prefix($tree_node->{children}, $port)) { # if there is a child prefix, this belongs to a subgraph - don't prefix it
				$edge->{from} = $port;
			}
			else {
				$edge->{from} = sprintf "%s%s", $tree_node->{node_prefix}, $port;
			}
		}
		else {
			$logger->($VLMIN, q[Currently only edges to stdin processed when remapping VTFILE edges. Not processing: ], $edge->{to}, q[ in edge: ], $edge->{id});
			next;
		}
	}

	return $flat_graph;
}

sub get_child_prefix {
	my ($children, $edge_to) = @_;

	my $child = (grep { $edge_to =~ /^$_->{id}:?(.*)$/} @$children)[0];

	return $child? $child->{node_prefix}: q[];
}

#####################################################################
# initialise_subst_requests:
#  if a key is specified more than once, its value becomes a list ref
#####################################################################
sub initialise_subst_requests {
	my ($keys, $vals) = @_;
	my %subst_requests = ();

	if(@$keys != @$vals) {
		croak q[Mismatch between keys and vals];
	}

	for my $i (0..$#{$keys}) {
		if(defined $subst_requests{$keys->[$i]}) {
			if(ref $subst_requests{$keys->[$i]} ne q[ARRAY]) {
				$subst_requests{$keys->[$i]} = [ $subst_requests{$keys->[$i]} ];
			}

			push @{$subst_requests{$keys->[$i]}}, $vals->[$i];
		}
		else {
			$subst_requests{$keys->[$i]} = $vals->[$i];
		}
	}

	return [ \%subst_requests ];  # note: the return value is a ref to a list of hash refs
}

sub read_vtf_version_check {
	my ($vtf_name, $version_minimum, $template_path) = @_;

	my $cfg = read_the_vtf($vtf_name, $template_path);
	my $version = $cfg->{version};
	$version ||= -1;
	if($version < $version_minimum) { 
		$logger->($VLMED, q[Warning: minimum template version requested for template ], $vtf_name, q[ was ], $version_minimum, q[, template version is ], ($version>=0?$version:q[UNSPECIFIED]));
	}

	return $cfg;
}

######################################################################
# read_the_vtf:
#  Open the file, read the JSON content, convert to hash and return it
######################################################################
sub read_the_vtf {
	my ($vtf_name, $template_path) = @_;

	my $vtf_fullname = find_vtf($vtf_name, $template_path);

	my $s = read_file($vtf_fullname);
	my $cfg = from_json($s);

	return $cfg;
}

########################################################
# prepend appropriate template_path element if necessary
########################################################
sub find_vtf {
	my ($vtf_fullname, $template_path) = @_;

	if(-e $vtf_fullname) {
		return $vtf_fullname;
	}

	my ($vtf_name, $directories) = fileparse($vtf_fullname);

	if($vtf_name eq $vtf_fullname) {  # path to file not specified, try template_path
		for my $path (@$template_path) {
			my $candidate = File::Spec->catfile($path, $vtf_name);
			if(-e $candidate) {
				return $candidate;
			}
		}
	}

	# if we haven't found this file anywhere on the path, bomb out
	$logger->($VLFATAL, q[Failed to find vtf file: ], $vtf_fullname, q[ locally or on template_path: ], join q[:], @$template_path);
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


