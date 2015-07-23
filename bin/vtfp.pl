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
use Hash::Merge qw( merge );

our $VERSION = '0';

Readonly::Scalar my $VLFATAL => -2;

Readonly::Scalar my $VLMIN => 1;
Readonly::Scalar my $VLMED => 2;
Readonly::Scalar my $VLMAX => 3;

Readonly::Scalar my $EWI_INFO => 1;
Readonly::Scalar my $EWI_WARNING => 2;
Readonly::Scalar my $EWI_ERROR => 3;

Readonly::Scalar my $MIN_TEMPLATE_VERSION => 1;

my $progname = (fileparse($0))[0];
my %opts;

my $help;
my $strict_checks;
my $outname;
my $export_param_vals; # file to export params_vals to
my $template_path;
my $logfile;
my $verbosity_level;
my $query_mode;
my $absolute_program_paths=1;
my @param_vals_fns = (); # a list of input file names containing JSON-formatted params_vals data
my @keys = ();
my @vals = ();
my @nullkeys = ();
GetOptions('help' => \$help, 'strict_checks!' => \$strict_checks, 'verbosity_level=i' => \$verbosity_level, 'template_path=s' => \$template_path, 'logfile=s' => \$logfile, 'outname:s' => \$outname, 'query_mode!' => \$query_mode, 'param_vals=s' => \@param_vals_fns, 'keys=s' => \@keys, 'values|vals=s' => \@vals, 'nullkeys=s' => \@nullkeys, 'export_param_vals:s' => \$export_param_vals, 'absolute_program_paths!' => \$absolute_program_paths);

if($help) {
	croak q[Usage: ], $progname, q{ [-h] [-q] [-s] [-l <log_file>] [-o <output_config_name>] [-v <verbose_level>] [-keys <key> -vals <val> ...]  <viv_template>};
}

# allow multiple options to be separated by commas
@keys = split(/,/, join(',', @keys));
@vals = split(/,/, join(',', @vals));
@param_vals_fns = split(/,/, join(',', @param_vals_fns));

my $params = initialise_params(\@keys, \@vals, \@nullkeys, \@param_vals_fns);

if($export_param_vals) {
	open my $epv, ">$export_param_vals" or croak "Failed to open $export_param_vals for export of param_vals";
	print $epv to_json($params);
	close $epv or croak q[closing params export file];
}

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

my $globals = { node_prefixes => { auto_node_prefix => 0, used_prefixes => {}}, vt_file_stack => [], vt_node_stack => [], processed_sp_files => {}, template_path => $template_path, };

my $node_tree = process_vtnode(q[], $vtf_name, q[], $params, $globals);    # recursively generate the vtnode tree

if(report_pv_ewi($node_tree, $logger)) { croak qq[Exiting after process_vtnode...\n]; }

my $flat_graph = flatten_tree($node_tree);

foreach my $node_with_cmd ( grep {$_->{'cmd'}} @{$flat_graph->{'nodes'}}) {

	$node_with_cmd->{cmd} = finalise_cmd($node_with_cmd->{cmd});
	if(not defined $node_with_cmd->{cmd} or (ref $node_with_cmd->{cmd} eq q[ARRAY] and @{$node_with_cmd->{cmd}} < 1)) {
		croak "command ", ($node_with_cmd->{id}? $node_with_cmd->{id}: q[NO ID]), " either empty or undefined";
	}

	if($absolute_program_paths) {
		my $cmd_ref = \$node_with_cmd->{'cmd'};
		if(ref ${$cmd_ref} eq 'ARRAY') { $cmd_ref = \${${$cmd_ref}}[0]}
		${$cmd_ref} =~ s/\A(\S+)/ abs_path( (-x $1 ? $1 : undef) || (which $1) || croak "cannot find program $1" )/e;
	}
}

print $out to_json($flat_graph);

########
# Done #
########

#########################################################################################
# process_vtnode:
#  vtnode_id - id of the VTFILE node; needed to resolve I/O connections
#  vtf_name - name of the file to read for this vtfile
#  node_prefix - if specified (note: zero-length string is "specified"), prefix all nodes
#                  from this vtfile with this string; otherwise auto-generate prefix
#  params - a hash ref containing keys:
#     param_store - a stack of maps of variable names to their values or constructor;
#                  supplies the values when subst directives are processed
#     assign - a list ref of key/value pairs, keys are subst_param [var]names, values
#                    are string values or array refs of strings; supplied at run time or
#                    via subst_map attributes in VTFILE nodes
#     assign_local - a hash ref, keys are colon-separated node paths (node id values)
#                        specifying the place where the key/values stored in the keys
#                        should be applied to override or supplement any parameter values
#                        added to the initial local subst_request entry created for
#                        VTFILE node expansion
#  globals - auxiliary items used for error checking/reporting (and final flattening,
#             e.g. node_prefix validation and generation for ensuring unique node ids
#             in subgraphs)
#
# Description:
#   1. read cfg for given vtf_name
#   2. create and process local subst_param section (if any), expanding SPFILE nodes
#       and updating param_store
#   3. process subst directives (just nodes and edges)
#   4. process nodes, expanding elements of type VTFILE (note: there will be param_store
#       and subst_request lists, containing as many entries as the current depth of
#       VTFILE nesting)
#
# Returns: root of tree of vtnodes (for later flattening)
#########################################################################################
sub process_vtnode {
	my ($vtnode_id, $vtf_name, $node_prefix, $params, $globals) = @_;

	my $vtnode = {
		id => $vtnode_id,
		name => $vtf_name,
		cfg => {},
		children => [],
		ewi => mkewi(q[node:] . ($vtnode_id? $vtnode_id: q[TOP]) . q[ (name: ] . ($vtf_name? $vtf_name: q[unspec]) . q[)]) };

	unless(is_valid_name($vtf_name)) {
		$vtnode->{ewi}->{additem}->($EWI_ERROR, 0, q[Missing or invalid name for VTFILE element id: ], $vtnode_id, q[ (], , join(q[->], @{$globals->{vt_file_stack}}), q[)]);

		return $vtnode;
	}

	if(any { $_ eq $vtf_name} @{$globals->{vt_file_stack}}) {
		$vtnode->{ewi}->{additem}->($EWI_ERROR, 0, q[Nesting of VTFILE ], $vtf_name, q[ within itself: ], join(q[->], @{$globals->{vt_file_stack}}));

		return $vtnode;
	}

	$vtnode->{node_prefix} = get_node_prefix($node_prefix, $globals->{node_prefixes});
	$vtnode->{cfg} = read_vtf_version_check($vtf_name, $MIN_TEMPLATE_VERSION, $globals->{template_path}, );
	$params = process_subst_params($params, $vtnode->{cfg}->{subst_params}, [ $vtf_name ], $globals, $vtnode->{ewi});

	apply_subst($vtnode->{cfg}, $params, $vtnode->{ewi});   # process any subst directives in cfg (just nodes and edges)

	my @vtf_nodes = ();
	my @nonvtf_nodes = ();
	for my $e (@{$vtnode->{cfg}->{nodes}}) { # remove VTFILE nodes for expansion into children nodes
		if($e->{type} eq q[VTFILE]) { push @vtf_nodes, $e; }
		else { push @nonvtf_nodes, $e; }
	}
	$vtnode->{cfg}->{nodes} = [ @nonvtf_nodes ];

	push @{$globals->{vt_file_stack}}, $vtf_name;
	push @{$globals->{vt_node_stack}}, $vtnode_id;
	for my $vtf_node (@vtf_nodes) {

		# both subst_requests and param_stores have local components
		my $sr = $vtf_node->{subst_map};
		$sr ||= {};

		# now update with any "localised" subst_requests from the command-line (replace, not supplement)
		my $local_env_key = join(q[:], @{$globals->{vt_node_stack}}) . q{:} . $vtf_node->{id};
		$local_env_key = substr($local_env_key, 1); # remove initial :
		if(my $smo = $params->{assign_local}->{$local_env_key}) {
			@{$sr}{keys %{$smo}} = values %{$smo};
		}

		unshift @{$params->{assign}}, $sr;
		my $ps = { varnames => {}, };
		unshift @{$params->{param_store}}, $ps;

		my $vtc = process_vtnode($vtf_node->{id}, $vtf_node->{name}, $vtf_node->{node_prefix}, $params, $globals);

		shift @{$params->{param_store}};
		shift @{$params->{assign}};

		push @{$vtnode->{children}}, $vtc;

	}
	pop @{$globals->{vt_file_stack}};
	pop @{$globals->{vt_node_stack}};

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
#  params - a hash ref containing keys:
#     param_store - a stack of maps of variable names to their values or constructor;
#                  supplies the values when subst directives are processed
#     assign - a list ref of key/value pairs, keys are subst_param [var]names, values
#                    are string values or array refs of strings; supplied at run time or
#                    via subst_map attributes in VTFILE nodes
#     assign_local - a hash ref, keys are colon-separated node paths (node id values)
#                        specifying the place where the key/values stored in the keys
#                        should be applied to override or supplement any parameter values
#                        added to the initial local subst_request entry created for
#                        VTFILE node expansion
#  unprocessed_subst_params - the list of subst_param entries to process; either of
#                    type PARAM (describes how to retrieve/construct the value for the
#                    specified varname) or SPFILE (specifies a file containing
#                    subst_params)
#  sp_file_stack - the list of file names leading to our current location, used for
#                    warning/error reporting
#  globals - used here to prevent multiple processing of SPFILE nodes and to pass the
#                  value of template_path
#  ewi - record Error/Warning/Info messages here
#
# Description:
#  process a subst_param section, adding any varnames declared in it to the "local"
#   param_store (element 0 in the param_store stack) and recursively processing any
#   included files specified by elements of type SPFILE.
#
#  In other words, step through unprocessed subst_param entries:
#   a) if element is of type PARAM, add it to the "local" param_store
#   b) if element is of type SPFILE, [queue it up for] make a recursive call to
#       process_subst_params() to expand it
#
# A stack of spfile names is passed to recursive calls to allow construction of error
#  strings for later reporting.
#######################################################################################
sub process_subst_params {
	my ($params, $unprocessed_subst_params, $sp_file_stack, $globals, $ewi) = @_;
	my @spfile_node_queue = ();

	my $param_store = $params->{param_store};

	for my $i (0..$#{$unprocessed_subst_params}) {

		my $sp = $unprocessed_subst_params->[$i];
		my $spid = $sp->{id}; 
		my $sptype = $sp->{type}; 
		$sptype ||= q[PARAM];

		if($sptype eq q[SPFILE]) { # process recursively
			# SPFILE entries will be processed after all PARAM-type entries have been processed (for consistency in redeclaration behaviour)
			push @spfile_node_queue, $sp;
		}
		elsif($sptype eq q[PARAM]) {
			# all unprocessed_subst_params elements of type PARAM must have an id
			if(not $spid) {
				# cache errors so we can report as many as possible before exit
				$ewi->{additem}->($EWI_ERROR, 0, q[No id for PARAM element, entry ], $i, q[ (], , join(q[->], @$sp_file_stack), q[)]);
			}

			my $ips = in_param_store($param_store, $spid);
			if($ips->{errnum} != 0) { # multiply defined - OK unless explicitly declared multiple times at this level
				if($ips->{errnum} > 0) { # a previous declaration was made by an ancestor of the current vtnode
					$ewi->{additem}->($EWI_INFO, 2, qq[INFO: Duplicate subst_param definition for $spid (], join(q[->], @$sp_file_stack), q[); ], $ips->{ms});
				}
				else {
					# cache errors so we can report as many as possible before exit
					$ewi->{additem}->($EWI_ERROR, 0, qq[Fatal error: Duplicate (local) subst_param definition for $spid (], join(q[->], @$sp_file_stack), q[); ], $ips->{ms});
				}
			}

			$sp->{_declared_by} ||= [];
			push @{$sp->{_declared_by}}, join q[->], @$sp_file_stack;
			$param_store->[0]->{varnames}->{$spid} = $sp; # adding to the "local" variable store
		}
		else {
			$ewi->{additem}->($EWI_ERROR, 0, q[Unrecognised type for subst_param element: ], $sptype, q[; entry ], $i, q[ (], , join(q[->], @$sp_file_stack), q[)]);
		}
	}

	################################
	# now process the SPFILE entries
	################################
	for my $spfile (@spfile_node_queue) {
		my $ewi = mkewi(q[SPF]);
		subst_walk($spfile, $params, [], $ewi);
		my $spname = is_valid_name($spfile->{name});
		if(not $spname) {
			# it would be better to cache these errors and report as many as possible before exit (TBI)
			$ewi->{additem}->($EWI_ERROR, 0, q[Missing or invalid name for SPFILE element id], $spfile->{id}, q[ (], , join(q[->], @$sp_file_stack), q[)]);
		}
		elsif(not $globals->{processed_sp_files}->{$spname}) { # but only process a given SPFILE once
			$globals->{processed_sp_files}->{$spname} = 1;   # flag this SPFILE name as seen

			my $cfg = read_vtf_version_check($spname, $MIN_TEMPLATE_VERSION, $globals->{template_path},);

			# NOTE: no mixing of subst_param formats in a template set - in other words, included subst_param
			#  files must contain (new-style) subst_param sections to be useful
			if(defined $cfg->{subst_params}) {
				push @$sp_file_stack, $spname;
				process_subst_params($params, $cfg->{subst_params}, $sp_file_stack, $globals, $ewi);
				pop @$sp_file_stack;
			}
		}
		else {
			$ewi->{additem}->($EWI_INFO, 3, qq[INFO: Not processing reoccurrence of SPFILE $spname (], join(q[->], @$sp_file_stack), q[)]);
		}
	}

	return $params;
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
	my ($cfg, $params, $ewi) = @_;   # process any subst directives in cfg (just nodes and edges?)

	for my $elem (@{$cfg->{nodes}}, @{$cfg->{edges}}) {
		$ewi->{addlabel}->(q{assigning to id:[} . $elem->{id} . q{]});
		subst_walk($elem, $params, [], $ewi);
		$ewi->{removelabel}->();
	}

	return;
}

##############################################################################################
# subst_walk:
#  walk the given element, looking for "subst" directives. When found search params for value.
##############################################################################################
sub subst_walk {
	my ($elem, $params, $labels, $ewi) = @_;

	my $r = ref $elem;
	if(!$r) {
		next;	# hit the bottom
	}
	elsif(ref $elem eq q[HASH]) {
		for my $k (keys %$elem) {

			if(ref $elem->{$k} eq q[HASH] and my $param_name = $elem->{$k}->{subst}) {
				# value for a "subst" key must always be the name of a parameter
				if(ref $param_name) {
					$ewi->{additem}->($EWI_ERROR, 0, q[value for a subst directive must be a param (not a reference), key for subst is: ], $k);
				}

				$elem->{$k} = fetch_subst_value($elem->{$k}, $params, $ewi);

				unless(defined $elem->{$k}) { # this has been changed to INFO. If ERROR is wanted, required attribute should be set so that fetch_subst_value() flags it
					$ewi->{additem}->($EWI_INFO, 1, q[Failed to fetch subst value for parameter ], $param_name, q[ (key was ], $k, q[)]);
				}

				next;
			}

			if(ref $elem->{$k}) {
				push @$labels, $k;
				subst_walk($elem->{$k}, $params, $labels, $ewi);
				pop @$labels;
			}
		}
	}
	elsif(ref $elem eq q[ARRAY]) {
		for my $i (reverse (0 .. $#{$elem})) {
			# if one of the elements is a subst_param hash,
			if(ref $elem->[$i] eq q[HASH] and my $param_name = $elem->[$i]->{subst}) {
				# value for a "subst" key must always be the name of a parameter
				if(ref $param_name) {
					$ewi->{additem}->($EWI_ERROR, 0, q[value for a subst directive must be a param name (not a reference), index for subst is: ], $i);
				}

				my $sval = fetch_subst_value($elem->[$i], $params, $ewi);
				if(ref $sval eq q[ARRAY]) {
					splice @$elem, $i, 1, @$sval;
				}
				else {
					$elem->[$i] = $sval;
				}

				unless(defined $elem->[$i]) { # this has been changed to INFO. If ERROR is wanted, required attribute should be set so that fetch_subst_value() flags it
					$ewi->{additem}->($EWI_INFO, 1, q[Failed to fetch subst value for parameter ], $param_name, q[ (element index was ], $i, q[)],);
				}

				next;
			}

			if(ref $elem->[$i]) {
				push @$labels, sprintf(q[ArrayElem%03d], $i);
				subst_walk($elem->[$i], $params, $labels, $ewi);
				pop @$labels;
			}
		}
	}
	elsif(ref $elem eq q[JSON::XS::Boolean]) {
	}
	else {
		$ewi->{add_item}->($EWI_WARNING, 2, "REF TYPE $r currently not processable");
	}

	return;
}

##################################################################
# fetch_subst_value:
#  use the param_store and subst_requests to find or construct
#  a value for the given param_name. The _value attribute of a
#  param_entry caches successfully resolved values.
#
#   1. If the value has already been resolved in the local
#       param_store, return that value.
#   2. Search the param_store stack for an entry for this
#       param_name, working outwards from the local level0
#       param_store
#   3. if only a non-local entry is found, copy it to the local
#       param_store; if no entry is found, create one in the
#       local param_store
#   4. search the assign/subst_requests stack (from local outward)
#       for user-specified value assignment - these will override
#       any other assignments (e.g. defaults, subst_maps or
#       subst_constructors specified in the template). If a value
#       is found, return it.
#   5. If the parameter has a subst_constructor attribute, use
#       that to construct the value [and return it].
#   6. If the value is still undefined, evaluate the param_entry's
#	default attribute (if any) 
#   7. If the value is still undefined, evaluate the subst entry's
#	ifnull attribute (if any). Note: this value should not
#	be cached to the _value attribute of the param_entry.
#   8. If the value is still undefined, flag an error if the
#	substitution is flagged as required.
#   9. If the value is still undefined, flag an error if the
#	parameter is flagged as required.
##################################################################
sub fetch_subst_value {
	my ($subst, $params, $ewi, $irp) = @_;
	my $param_entry;
	my $retval;

	# check to see if an sp_expr needs evaluating
	if(ref $subst->{subst}) { # subst name is itself an expression which needs evaluation
		$subst->{subst} = fetch_sp_value($subst->{subst}, $params, $ewi, $irp);
	}

	if(ref $subst->{subst}) { # TODO - consider implications of allowing an array here
		$ewi->{additem}->($EWI_ERROR, 0, q[subst value cannot be a ref (type: ], ref $subst->{subst}, q[)]);
		return;
	}

	my $param_name = $subst->{subst};

	if(defined $irp and any { $_ eq $param_name} @{$irp}) { # infinite recursion prevention
		$ewi->{additem}->($EWI_ERROR, 0, q[infinite recursion detected resolving parameter ], $param_name, q[ (], join(q/=>/, (@{$irp}, $param_name)), q[)]);
		return;
	}

	my $param_store = $params->{param_store};

	if(defined $param_store->[0]->{varnames}->{$param_name} and exists $param_store->[0]->{varnames}->{$param_name}->{_value}) { # allow undef value

		if(not defined $param_store->[0]->{varnames}->{$param_name}->{_value} and defined $subst->{required} and $subst->{required} eq q[yes]) {
			$ewi->{additem}->($EWI_ERROR, 0, q[Undef value specified for required subst (param_name: ], $param_name, q[)]);
		}

		return $param_store->[0]->{varnames}->{$param_name}->{_value}; # already evaluated, return cached value
	}

	for my $ps (@$param_store) {
		if(exists $ps->{varnames}->{$param_name} and $ps->{varnames}->{$param_name}->{id} eq $param_name) {
			$param_entry = $ps->{varnames}->{$param_name};
			last;
		}
	}

	if(not defined $param_store->[0]->{varnames}->{$param_name}) {	# create a "writeable" param_store entry at local level
		my $new_param_entry = (not defined $param_entry)? { id => $param_name, _declared_by => [], }: dclone $param_entry;

		$param_store->[0]->{varnames}->{$param_name} = $new_param_entry; # adding to the "local" variable store

		$param_entry = $new_param_entry;
	}

	# at this point, we have either found or created the param_entry in the local param_store. (We don't want to write to
	#  a higher-level param_store entry)

	# before checking for a cached _value, see if there are local overrides (either via subst_map or from command-line)
	my $subst_requests = $params->{assign};
	for my $sr (@$subst_requests) {
		if(exists $sr->{$param_name}) { # allow undef value
			$param_entry->{_value} = $sr->{$param_name};

			if(not defined $param_entry->{_value} and defined $subst->{required} and $subst->{required} eq q[yes]) {
				$ewi->{additem}->($EWI_ERROR, 0, q[Undef value specified for required subst (param_name: ], $param_name, q[)]);
			}

			return $sr->{$param_name};
		}
	}

	if(defined $param_entry->{_value}) {
		return $param_entry->{_value};   # already evaluated, return cached value
	}

	$retval = resolve_subst_constructor($param_name, $param_entry->{subst_constructor}, $params, $ewi, $irp);
		
	if(not defined $retval) {
		$retval = resolve_param_default($param_name, $param_entry->{default}, $params, $ewi, $irp);
	}

	if(not defined $retval) {
		if($retval = resolve_ifnull($param_name, $subst->{ifnull}, $params, $ewi, $irp)) {
			return $retval; # note: result of ifnull evaluation not assigned to variable
		}
		elsif($subst->{required} and ($subst->{required} eq q[yes])) {
			$ewi->{additem}->($EWI_ERROR, 0, q[No value found for required subst (param_name: ], $param_name, q[)]);
			return;
		}
	}

	if(not defined $retval) {
		# caller should decide if undef is allowed, unless required is true
		my $severity = (defined $param_entry->{required} and $param_entry->{required} eq q[yes])? $EWI_ERROR: $EWI_INFO;
		$ewi->{additem}->($severity, 0, q[No value found for param_entry ], $param_name);
		return;
	}

	$param_entry->{_value} = $retval;

	return $retval;
}

sub fetch_sp_value {
	my ($sp_expr, $params, $ewi, $irp) = @_;
	my $param_entry;
	my $retval;

	my $sper = ref $sp_expr;
	if($sper) {
		if($sper eq q[HASH]) {
			if($sp_expr->{subst}) {
				# subst directive
				$retval = fetch_subst_value($sp_expr, $params, $ewi, $irp);
			}
			elsif($sp_expr->{subst_constructor}) {
				# solo subst_constructor
				$retval = resolve_subst_constructor(q[ID], $sp_expr->{subst_constructor}, $params, $ewi);
			}
			else {
				# ERROR - unrecognised hash ref type
			}
		}
		elsif($sper eq q[ARRAY]) {
			process_array($sp_expr, $params, $ewi, $irp);
		}
		else {
			# ERROR - unrecognised ref type
		}
	}
	else {
		return $sp_expr;
	}
}

sub resolve_subst_constructor {
	my ($id, $subst_constructor, $params, $ewi, $irp) = @_;

	if(not defined $subst_constructor) { return; }

	my $vals;
	unless($vals = $subst_constructor->{vals}) {
		$ewi->{additem}->($EWI_ERROR, 0, q[subst_constructor attribute requires a vals attribute, param_name: ], $id);
		return;
	}

	unless(ref $vals eq q[ARRAY]) {
		$ewi->{additem}->($EWI_ERROR, 0, q[subst_constructor vals attribute must be array, param_name: ], $id);
		return;
	}

	$vals = process_array($vals, $params, $ewi, $irp);
	if(not defined $vals) {
		$ewi->{additem}->($EWI_ERROR, 0, q[Error B processing subst_constructor, param_name: ], $id);
		return;
	}

	return postprocess_subst_array($id, $subst_constructor, $ewi);
}

##################################
# process_array
#  flatten any non-scalar elements
##################################
sub process_array {
	my ($arr, $params, $ewi, $irp) = @_;

	for my $i (reverse (0..$#$arr)) {
		if(ref $arr->[$i] eq q[HASH]) {
			if($arr->[$i]->{subst}) {
				$arr->[$i] = fetch_subst_value($arr->[$i], $params, $ewi, $irp);
			}
			else {
				$ewi->{additem}->($EWI_ERROR, 0, q[Non-subst hash ref not permitted in array, element ], $i);
				return;
			}
		}

		if(ref $arr->[$i] eq q[ARRAY]) {
			$arr->[$i] = process_array($arr->[$i], $params, $ewi, $irp); # in case the element was a simple array ref, not a subst directive
			splice(@$arr, $i, 1, (@{$arr->[$i]}));
		}
	}

	return $arr;
}

##################################################################################################
# postprocess_subst_array:
#   caller will have already flattened the array (i.e. no ref elements)
#   process as specified by op directives (pack, concat,...)
#   validate proposed substitution value. If it contains any undef elements, it is invalid (caller
#    determines severity of error)
##################################################################################################
sub postprocess_subst_array {
	my ($param_id, $subst_constructor, $ewi) = @_;

	my $subst_value=$subst_constructor->{vals};
	if(ref $subst_value ne q[ARRAY]) {
		$ewi->{additem}->($EWI_INFO, 0, q[vals attribute must be an array ref (param: ], $param_id, q[)]);
		return;
	}

	my $ops=$subst_constructor->{postproc}->{op};
	if(defined $ops) {
		my $ro = ref $ops;
		if(not $ro) {
			$ops = [ $ops ];
		}
		elsif($ro ne q[ARRAY]) {
			$ewi->{additem}->($EWI_INFO, 0, q[ops attribute must be either scalar or array ref (not ], $ro, q[ ref) - disregarding]);

			$ops = [];
		}
	}
	else {
		$ops = [];
	}

	# if (post-pack) array contains undefs, it is invalid
	if(any { ! defined($_) } @$subst_value) {
		if(grep { $_ eq q[pack] } @$ops) {
			$subst_value = [ (grep { defined($_) } @$subst_value) ];
		}
		else {
			# decision about fatality should be left to the caller
			$ewi->{additem}->($EWI_INFO, 0, q[INFO: Undefined elements in subst_param array: ], $param_id);
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
			$ewi->{additem}->($EWI_ERROR, 0, q[Unrecognised op: ], $op, q[ in subst_param: ], $param_id);
		}
	}

	return $subst_value;
}

sub resolve_param_default {
	my ($id, $default, $params, $ewi, $irp) = @_;

	if(not defined $default) { return; }

	return fetch_sp_value($default, $params, $ewi, $irp);
}

sub resolve_ifnull {
	my ($id, $ifnull, $params, $ewi, $irp) = @_;

	if(not defined $ifnull) { return; }

	return fetch_sp_value($ifnull, $params, $ewi, $irp);
}


sub report_pv_ewi {
	my ($tree_node, $logger) = @_; 
	my $fatality = 0;

	if($tree_node->{ewi}->{report}->(0, $logger)) { $fatality = 1; }

	# do the same recursively for any children
	for my $tn (@{$tree_node->{children}}) {
		if($tn->{ewi}->{report}->(0, $logger)) { $fatality = 1; }
	}

	return $fatality; # should return some kind of error indicator, I think
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

######################################################################
# initialise_params:
#  Record any parameter values set from the command line. A separate
#  store is used for "localised" parameter setting (ones applied when
#  subst_requests store for VTFILE expansion is set up).
#  If a key is specified more than once, its value becomes a list ref.
#  an empty initial param_store is added.
######################################################################
sub initialise_params {
	my ($keys, $vals, $nullkeys, $param_vals_fns) = @_;

	my $pv = {};

	$pv = construct_pv($keys, $vals, $nullkeys);

	return combine_pvs($param_vals_fns, $pv);
}

sub construct_pv {
	my ($keys, $vals, $nullkeys) = @_;
	my $pv;
	my $subst_requests = {};
	my $subst_map_overrides = {};

	if(@$keys != @$vals) {
		croak q[Mismatch between keys and vals];
	}

	for my $nullkey (@$nullkeys) {
		$subst_requests->{$nullkey} = undef;
	}

	if(@{$keys}) {
		for my $i (0..$#{$keys}) {
			my ($locality, $param_name) = _parse_localised_param_name($keys->[$i]);
			my $param_value = $vals->[$i];

			if($locality) {
				# put it in the subst_map_overrides
				if(defined $subst_map_overrides->{$locality}->{$param_name}) {
					if(ref $subst_map_overrides->{$locality}->{$param_name} ne q[ARRAY]) {
						$subst_map_overrides->{$locality}->{$param_name} = [ $subst_map_overrides->{$locality}->{$param_name} ];
					}

					push @{$subst_map_overrides->{$locality}->{$param_name}}, $param_value;
				}
				else {
					$subst_map_overrides->{$locality}->{$param_name} = $param_value;
				}
			}
			elsif(defined $subst_requests->{$param_name}) {
				if(ref $subst_requests->{$param_name} ne q[ARRAY]) {
					$subst_requests->{$param_name} = [ $subst_requests->{$param_name} ];
				}

				push @{$subst_requests->{$param_name}}, $param_value;
			}
			else {
				$subst_requests->{$param_name} = $param_value;
			}
		}

		$pv = { param_store =>  [], assign => [ $subst_requests ], assign_local => $subst_map_overrides, };
	}

	return $pv;
}

###################################################################################
# combine_pvs:
#  parameters:
#    param_vals_fns - ref to array of file names (JSON) containing parameter values
#    clpv - parameter value structure created from command-line (optional)
#
#  Combine a set of parameter value specifications, from files and/or command-line
###################################################################################
sub combine_pvs {
	my ($param_vals_fns, $clpv) = @_;
	my $target = {};
	my @all_pvs = ();

	# read the pv data from files, add to list
	for my $fn (@{$param_vals_fns}) {

		if(! -e ${fn}) {
			carp qq[Failed to find file $fn];
			next;
		}

		my $pv = from_json(read_file($fn));

		push @all_pvs, $pv;
	}
	if($clpv) {
		push @all_pvs, $clpv; # add parameter value structure created from command-line
	}

#	Hash::Merge::set_behavior( 'RIGHT_PRECEDENT' );
#	Hash::Merge::set_behavior( 'LEFT_PRECEDENT' );
	# merge user-supplied params files with slightly modified RIGHT_PRECEDENT behaviour
	Hash::Merge::specify_behavior(
		{
			'SCALAR' => {
				'SCALAR' => sub { $_[1] },
				'ARRAY'  => sub { $_[1] }, # differs from RIGHT_PRECEDENT
				'HASH'   => sub { $_[1] },
			},
			'ARRAY' => {
				'SCALAR' => sub { $_[1] },
				'ARRAY'  => sub { [ @{ $_[0] }, @{ $_[1] } ] },
				'HASH'   => sub { $_[1] },
			},
			'HASH' => {
				'SCALAR' => sub { $_[1] },
				'ARRAY'  => sub { $_[1] }, # differs from RIGHT_PRECEDENT
				'HASH'   => sub { Hash::Merge::_merge_hashes( $_[0], $_[1] ) },
			},
		},
		'My Behavior',
	);
	for my $pv (@all_pvs) {

		$target->{assign} = [ merge($target->{assign}->[0], $pv->{assign}->[0]) ];
		$target->{assign_local} = merge($target->{assign_local}, $pv->{assign_local});
	}

	$target->{assign} ||= [];
	$target->{assign_local} ||= {};
	$target->{param_store} ||= [];
	return $target;
}

#########################################################
# _parse_localised_param_name
#  this should allow for escaping of the delimiter (TODO)
#########################################################
sub _parse_localised_param_name {
	my ($full_param_name) = @_;

	my @a = split /:/, $full_param_name;
	my $param_name = pop @a;
	my $locality = join q{:}, @a;

	return ($locality, $param_name);
}

#############################################################################################
# is_valid_name:
#   valid names should be defined strings. Whether invalidity is fatal is left to the caller.
#############################################################################################
sub is_valid_name {
	my ($name, $id) = @_;

	if(defined $name and my $r = ref $name) {
		if($r eq q[ARRAY]) {
			$logger->($VLMIN, q{Element with id }, $id, q{ has name of type ARRAY ref, it should be a string. Elements: [ }, join(q[;], @$name), q{]});

			return;
		}
		elsif($r eq q[HASH]) {
			$logger->($VLMIN, q[Element with id ], $id, q[ has name of type HASH ref, it should be a string.]);

			return;
		}
	}

	return $name;
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

###############################################################
# finalise_cmd: the value of the cmd attribute of an EXEC node
#  must be either a string or an array ref of strings (no undef
#  elements). Convert an array of strings and array refs to an
#  array of strings using splice.
###############################################################
sub finalise_cmd {
	my ($cmd) = @_;

	if(ref $cmd eq q[ARRAY]) {
		$cmd = [ (grep { defined($_) } @$cmd) ]; # first remove any undefined elements

		for my $i (reverse (0..$#{$cmd})) {
			if(not defined $cmd->[$i]) {
				splice @{$cmd->[$i]}, $i, 1;
			}
			elsif(ref $cmd->[$i] eq q[ARRAY]) {
				$cmd->[$i] = finalise_cmd($cmd->[$i]);
				splice @{$cmd->[$i]}, $i, 1, @{$cmd->[$i]};
			}
		}
	}

	return $cmd;
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

################################################################
# for storing and reporting handling Error/Warning/Info messages
################################################################
sub mkewi {
	my ($init_label) = @_;

	my @labels = (); # list of strings which make up the message label
	if (defined $init_label) {
		push @labels, $init_label;
	}
	my @list = (); # list of messages

	return {
		additem => sub {
			my ($type, $subclass, @ms) = @_;

			my $label = join(":", @labels);
			my $ms = join("", @ms);

			my $full_ms = sprintf "(%s) - %s", $label, $ms;

			push @list, { type => $type, subclass => $subclass, ms => $full_ms };

			return scalar @list;
		},
		addlabel => sub {
			my (@label_elements) = @_;

			my $label = join("", @label_elements);

			push @labels, $label;

			return $label;
		},
		removelabel => sub {
			if(@labels > 0) {
				pop @labels;
			}

			return scalar @labels;
		},
		clearlabels => sub {
			@labels = ();

			return;
		},
		clearitems => sub {
			@list = ();

			return;
		},
		report => sub {
			my ($fatality_level, $logger) = @_;
			my $ewi_retstat = 0;
			my %ewi_type_names = ( $EWI_ERROR => q[Error], $EWI_WARNING => q[Warning], $EWI_INFO => q[Info], );

			for my $ewi_item (@list) {
				if($ewi_item->{type} == $EWI_ERROR and $ewi_item->{subclass} <= $fatality_level) { $ewi_retstat = 1; }

				$logger->($VLMIN, join("\t", ($ewi_type_names{$ewi_item->{type}}, $ewi_item->{subclass}, $ewi_item->{ms},)));
			}

			return $ewi_retstat;
		}
	}
}

