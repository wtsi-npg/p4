#!/usr/bin/env perl

#################################################################################################
# vtfp.pl
# Updated utility to process viv template files.  Handles replacement of substitutable parameters
#  with specified values. Croaks when all required parameters are not replaced with values.
# Will have a query mode which reports available parameters
#################################################################################################

use strict;
use warnings;
use FindBin qw($Bin);
use lib ( -d "$Bin/../lib/perl5" ? "$Bin/../lib/perl5" : "$Bin/../lib" );

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

Readonly::Scalar my $SPLICE => 0;
Readonly::Scalar my $PRUNE => 1;
Readonly::Scalar my $SRC => 0;
Readonly::Scalar my $DST => 1;

Readonly::Scalar my $MIN_TEMPLATE_VERSION => 1;
my $TEMPLATE_VERSION_DEFAULT = 2;

my $progname = (fileparse($0))[0];
my %opts;

my $help;
my $strict_checks;
my $outname;
my $export_param_vals; # file to export params_vals to
my $splice_list;
my $prune_list;
my $template_path;
my $logfile;
my $verbosity_level;
my $query_mode;
my $absolute_program_paths=1;
my @param_vals_fns = (); # a list of input file names containing JSON-formatted params_vals data
my @keys = ();
my @vals = ();
my @nullkeys = ();
GetOptions('help' => \$help, 'strict_checks!' => \$strict_checks, 'verbosity_level=i' => \$verbosity_level, 'template_path=s' => \$template_path, 'logfile=s' => \$logfile, 'outname:s' => \$outname, 'query_mode!' => \$query_mode, 'param_vals=s' => \@param_vals_fns, 'keys=s' => \@keys, 'values|vals=s' => \@vals, 'nullkeys=s' => \@nullkeys, 'export_param_vals:s' => \$export_param_vals, 'splice_nodes=s' => \$splice_list, 'prune_nodes=s' => \$prune_list, 'absolute_program_paths!' => \$absolute_program_paths);

if($help) {
	croak q[Usage: ], $progname, q{ [-h] [-q] [-s] [-l <log_file>] [-o <output_config_name>] [-v <verbose_level>] [-keys <key> -vals <val> ...]  <viv_template>};
}

# allow multiple options to be separated by commas
@keys = map { split_csl($_); } @keys;
@vals = map { split_csl($_); } @vals;
@param_vals_fns = map { split_csl($_); } @param_vals_fns;

my $params = initialise_params(\@keys, \@vals, \@nullkeys, $splice_list, $prune_list, \@param_vals_fns);

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

my $tver_default = ($node_tree->{cfg}->{version} or $TEMPLATE_VERSION_DEFAULT);
my $flat_graph = flatten_tree($node_tree, $tver_default);
$flat_graph->{version} = $tver_default;

my $cull_node_ids = []; # used to detect (and disregard) parameter substitution errors in nodes which have been removed
if(@{$params->{ops}->{splice}} or @{$params->{ops}->{prune}}) {
	($flat_graph, $cull_node_ids) = splice_nodes($flat_graph, $params->{ops});
}

# parameter substitution errors are reported late, so errors in pruned or spliced nodes can be ignored
if(report_pv_ewi($node_tree, $logger, $cull_node_ids)) { croak qq[Exiting after fatal error(s) detected...\n]; }

foreach my $node_with_cmd ( grep {$_->{'cmd'}} @{$flat_graph->{'nodes'}}) {

	$node_with_cmd = finalise_cmd($node_with_cmd);
	if(not defined $node_with_cmd->{cmd} or (ref $node_with_cmd->{cmd} eq q[ARRAY] and @{$node_with_cmd->{cmd}} < 1)) {
		croak "command ", ($node_with_cmd->{id}? $node_with_cmd->{id}: q[NO ID]), " either empty or undefined";
	}

	if($absolute_program_paths) {
		my $cmd_ref = \$node_with_cmd->{'cmd'};
		if(ref ${$cmd_ref} eq 'ARRAY') { $cmd_ref = \${${$cmd_ref}}[0]}
		${$cmd_ref} =~ s/\A(\S+)/ abs_path( (-x $1 ? $1 : undef) || (which $1) || croak "cannot find program $1" )/e;
	}
}
if($flat_graph->{'edges'}) {
	$flat_graph->{'edges'} = finalise_array($flat_graph->{'edges'});
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
		ewi => mkewi(q[vtnode:] . ($vtnode_id? $vtnode_id: q[TOP]) . q[ (name: ] . ($vtf_name? $vtf_name: q[unspec]) . q[)]) };

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

	apply_subst($vtnode->{cfg}, $params, $vtnode->{ewi}, $vtnode->{node_prefix});   # process any subst directives in cfg (just nodes and edges)

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

		my $sps = $unprocessed_subst_params->[$i];
		$sps = subst_walk($sps, $params, $ewi, { irp => [], select_opts => { select => 1, }, } ); # preprocess any select directives in the subst_params section

		if(not defined $sps) { next; }
		# subst_walk may return an array of entries, so make that always the case.
		if(ref $sps ne q[ARRAY]) {
			$sps = [ $sps ];
		}

		for my $sp (@{$sps}) {
			if(not $sp or ref $sp ne q[HASH] or not $sp->{id}) {
				$ewi->{additem}->($EWI_ERROR, 0, q[Failed to resolve subst_params element ], $i, q[ (], , join(q[->], @$sp_file_stack), q[)]);
				next;
			}
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
	}

	################################
	# now process the SPFILE entries
	################################
	for my $spfile (@spfile_node_queue) {
		my $ewi = mkewi(q[SPF]);
		$spfile = subst_walk($spfile, $params, $ewi);
		my $spname = is_valid_name($spfile->{name});
		if(not $spname) {
			# cache these errors and report as many as possible before exit
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

#############################################################
# apply_subst:
#  replace subst/subst_constructor/... directives with values
#############################################################
sub apply_subst {
	my ($cfg, $params, $ewi, $vtnode_prefix) = @_;   # process any subst directives in cfg (just nodes and edges?)

	for my $elem (@{$cfg->{nodes}}) {
		# it is possible that we can't determine the id value for the node until after parameter values are resolved. So a scalar ref is passed down via settag
		#  and the id value is filled in after return from subst_walk. (the tag is attached to error/warning/info messages and is used to disregard errors connected
		#  to elements which are later pruned/spliced away. See use of $cull_node_ids list returned by splice_nodes() in report_pv_ewi() for how this is done.)
		my $id = q[PREID];
		$ewi->{settag}->(\$id);
		my $elem_id = (exists $elem->{id} and $elem->{id})? $elem->{id} : q[NOID];

		$ewi->{addlabel}->(q{assigning to id:[} . $elem_id . q{]});
		$elem = subst_walk($elem, $params, $ewi);
		$id = $vtnode_prefix . $elem_id;
		$ewi->{removelabel}->();

	}
	$ewi->{removetag}->();

	for my $elem (@{$cfg->{edges}}) {
		my $id = $elem->{id};
		$id ||= q[NOID];
		$ewi->{addlabel}->(q{assigning to id:[} . $id . q{]});
		$elem = subst_walk($elem, $params, $ewi);
		$ewi->{removelabel}->();
	}

	return;
}

##################################################################################################
# subst_walk:
#  walk the given element, looking for subst/subst_constructor/... directives. When found, resolve
#   the value(s) and perform any necessary substitutions. Return the (possibly) updated element
#   to caller
##################################################################################################
sub subst_walk {
	my ($elem, $params, $ewi, $aux) = @_;

	# first check if elem itself needs resolution (is itself a subst/subst_constructor/select directive)
	$elem = fetch_sp_value($elem, $params, $ewi, $aux);

	my $r = ref $elem;
	if(!$r) {
		# hit the bottom, nothing to do
	}
	elsif(ref $elem eq q[HASH]) {
			for my $k (keys %$elem) {
				$elem->{$k} = fetch_sp_value($elem->{$k}, $params, $ewi, $aux);

				if(defined $elem->{$k}) {
					$elem->{$k} = subst_walk($elem->{$k}, $params, $ewi, $aux);
				}
			}
	}
	elsif(ref $elem eq q[ARRAY]) {
		for my $i (reverse (0 .. $#{$elem})) {
			$elem->[$i] = fetch_sp_value($elem->[$i], $params, $ewi, $aux);

			if(defined $elem->[$i]) {
				$elem->[$i] = subst_walk($elem->[$i], $params, $ewi, $aux);
			}
		}
	}
	elsif(ref $elem eq q[JSON::XS::Boolean] or ref $elem eq q[JSON::PP::Boolean]) {
	}
	else {
		$ewi->{additem}->($EWI_WARNING, 2, "REF TYPE $r currently not processable");
	}

	return $elem;
}

#############################################################################################
# fetch_sp_value:
#  determine if $element requires resolution (i.e, it is a subst, subst_constructor or select
#   directive). If so pass it to the appropriate resolver and return the result
#############################################################################################
sub fetch_sp_value {
	my ($elem, $params, $ewi, $aux) = @_;
	my $retval;

	my $select_opts = { subst =>1, subst_constructor => 1, select => 1, }; # default to parse all directives;
	if($aux and defined $aux->{select_opts}) {
		$select_opts = $aux->{select_opts}
	}

	my $ref_type = ref $elem;
	if($ref_type) {
		if($ref_type eq q[HASH]) {
			if($select_opts->{subst} and $elem->{subst}) {
				# subst directive
				$retval = resolve_subst($elem, $params, $ewi, $aux);
			}
			elsif($select_opts->{subst_constructor} and $elem->{subst_constructor}) {
				# solo subst_constructor
				$retval = resolve_subst_constructor(q[ANON], $elem->{subst_constructor}, $params, $ewi, $aux);
			}
			elsif($select_opts->{select} and $elem->{select}) {
				# select directive
				$retval = resolve_select_value($elem, $params, $ewi, $aux);
			}
			else {
				$retval = $elem;
			}
		}
		elsif($ref_type eq q[ARRAY]) {
			$retval = $elem;
		}
		elsif($ref_type eq q[JSON::XS::Boolean] or $ref_type eq q[JSON::PP::Boolean]) {
			$retval = $elem;
		}
		else {
			# ERROR - unrecognised ref type
			$ewi->{additem}->($EWI_INFO, 1, q[unrecognised ref type ], $ref_type, q[ (not HASH or ARRAY) when seeking parameter value; unable to resolve to string ],);
			$retval = $elem; # caller's responsibility to determine seriousness of this
		}
	}
	else {
		$retval = $elem;
	}

	return $retval;
}

############################################################
# resolve_subst:
#  determine the value of the given subst directive element.
#  If no result can be obtained from parameter values in the
#  param_store, resolve the ifnull attribute (if present).
#  If still no result and the subst directive is flagged as
#  required, flag an error.
#
#  Note that results of subst directive resolution are local:
#  that is, subst directives in the same (set of) template(s)
#  referring to the same parameter name may be assigned
#  different values (as opposed to assignment of values to
#  parameters via the parameter default values, keys/vals
#  flags or import_params mechanism).
############################################################
sub resolve_subst {
	my ($subst, $params, $ewi, $aux) = @_;
	my $retval;

	# check to see if an sp_expr needs evaluating
	if(ref $subst->{subst}) { # subst name is itself an expression which needs evaluation
		$subst->{subst} = subst_walk($subst->{subst}, $params, $ewi, $aux);
	}

	if(ref $subst->{subst}) { # TODO - consider implications of allowing an array here
		$ewi->{additem}->($EWI_ERROR, 0, q[subst value cannot be a ref (type: ], ref $subst->{subst}, q[)]);
		return;
	}

	my $param_name = $subst->{subst};

	##################################################
	# fetch the param_store element for the param_name
	##################################################
	my $param_entry = fetch_param_entry($param_name, $params, $ewi, $aux);
	if(exists $param_entry->{_value}) { # allow undef value
		if(not defined $param_entry->{_value} and $subst->{required} and $subst->{required} !~ /\A(false|no|off)\Z/i) { # explicitly set to undef
			$ewi->{additem}->($EWI_ERROR, 0, q[Undef value specified for required subst (param_name: ], $param_name, q[)]);
		}
		return $param_entry->{_value};
	}

	#######################################################################################################
	# no value retrieved from param_store, try to construct one from the subst directive's ifnull attribute
	#######################################################################################################
	if($retval = resolve_ifnull($param_name, $subst->{ifnull}, $params, $ewi, $aux)) {
		return $retval; # note: result of ifnull evaluation not assigned to variable
	}
	elsif($subst->{required} and $subst->{required} and $subst->{required} !~ /\A(false|no|off)\Z/i) {
		$ewi->{additem}->($EWI_ERROR, 0, q[No value found for required subst (param_name: ], $param_name, q[)]);
		return;
	}

	return $retval;
}

########################################A##########################
# fetch_param_entry:
#  search param_store stack for an existing entry for the given 
#   parameter name. If found in a param_store other than the local
#   one (zero-level), make a copy to zero-level (i.e. inherit it,
#   but avoid writing to another level's param_entry). If no value
#   found, resolve the subst_constructor attribute (if present);
#   if still no value, resolve the default attribute (if present).
#   If still no value, flag an error if the required attribute is
#   set.
#   Cache a resolved value to the parameter_entry.
#
#   Returns: the param_entry in the local param_store for the
#   requested param_name.
###################################################################
sub fetch_param_entry {
	my ($param_name, $params, $ewi, $aux) = @_;
	my $param_entry;
	my $retval;

	$aux ||= { irp => [], };
	$aux->{irp} ||= [];
	if(any { $_ eq $param_name} @{$aux->{irp}}) { # infinite recursion prevention
		$ewi->{additem}->($EWI_ERROR, 0, q[infinite recursion detected resolving parameter ], $param_name, q[ (], join(q/=>/, (@{$aux->{irp}}, $param_name)), q[)]);
		return;
	}

	my $param_store = $params->{param_store};

	if(defined $param_store->[0]->{varnames}->{$param_name} and exists $param_store->[0]->{varnames}->{$param_name}->{_value}) { # allow undef value
		return $param_store->[0]->{varnames}->{$param_name}; # already evaluated, return cached value
	}

	for my $ps (@$param_store) {
		if(exists $ps->{varnames}->{$param_name} and $ps->{varnames}->{$param_name}->{id} eq $param_name) {
			$param_entry = $ps->{varnames}->{$param_name};
			last;
		}
	}

	#####################################################################
	# if necessary, create a "writeable" param_store entry at local level
	#####################################################################
	if(not defined $param_store->[0]->{varnames}->{$param_name}) {
		my $new_param_entry = (not defined $param_entry)? { id => $param_name, _declared_by => [], }: dclone $param_entry;
		delete $new_param_entry->{_value}; # force re-evaluation at this level

		$param_store->[0]->{varnames}->{$param_name} = $new_param_entry; # adding to the "local" variable store

		$param_entry = $new_param_entry;
	}

	# at this point, we have either found or created the param_entry in the local param_store. (We don't want to write to
	#  a higher-level param_store entry)

	###########################################################################################################################
	# search the assign/subst_requests stack (from local outward) for user-specified value assignment (from either command-line
	#  keys/vals or flags/import_params mechanism) - these will override any other assignments (e.g. defaults, subst_maps
	#  or subst_constructors specified in the template).
	###########################################################################################################################
	my $subst_requests = $params->{assign};
	if(exists $subst_requests->[0]->{$param_name}) { # this local assignment will override anything else, so return
		$param_entry->{_value} = $subst_requests->[0]->{$param_name};
		return $param_entry;
		
	}
	for my $sr (@$subst_requests) {
		if(exists $sr->{$param_name}) { # allow undef value
			$param_entry->{_value} = $sr->{$param_name};
			last;
		}
	}

	my $candidate;
	if(exists $param_entry->{_value}) {
		$candidate = $param_entry;   # already evaluated, return cached value (allowing undef)
	}

	push @{$aux->{irp}}, $param_name;
	$retval = resolve_subst_constructor($param_name, $param_entry->{subst_constructor}, $params, $ewi, $aux);

	if(not $retval and $candidate) {
		$retval = $candidate->{_value};
	}

	if(defined $retval) {
		$param_entry->{_value} = $retval;
	}
	else {
		$retval = resolve_param_default($param_name, $param_entry->{default}, $params, $ewi, $aux);
		if(defined $retval) {
			$param_entry->{_value} = $retval;
		}
	}
	pop @{$aux->{irp}};

	if(not defined $retval) {
		# caller should decide if undef is allowed, unless required is true
		my $severity = (defined $param_entry->{required} and $param_entry->{required} and $param_entry->{required} !~ /\A(false|no|off)\Z/i)? $EWI_ERROR: $EWI_INFO;
		$ewi->{additem}->($severity, 0, q[No value found for param_entry ], $param_name);
	}

	return $param_entry;
}

sub resolve_subst_constructor {
	my ($id, $subst_constructor, $params, $ewi, $aux) = @_;

	if(not defined $subst_constructor) { return; }

	my $value = (ref $subst_constructor->{vals})? dclone $subst_constructor->{vals} : $subst_constructor->{vals};
	unless($value) {
		$ewi->{additem}->($EWI_ERROR, 0, q[subst_constructor attribute requires a vals attribute, param_name: ], $id);
		return;
	}

	$value = subst_walk($value, $params, $ewi, $aux);

	if(not defined $value) {
		$ewi->{additem}->($EWI_ERROR, 0, q[Error processing subst_constructor value, param_name: ], $id);
		return;
	}

	unless(ref $value eq q[ARRAY]) {
		$ewi->{additem}->($EWI_ERROR, 0, q[subst_constructor vals attribute must be array, param_name: ], $id);
		return;
	}


	$subst_constructor->{_value} = $value;

	return postprocess_subst_array($id, $subst_constructor, $ewi);
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

	my $subst_value=$subst_constructor->{_value};
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

sub resolve_select_value {
	my ($select, $params, $ewi, $aux) = @_;
	my $param_entry;
	my $retval;

	# check to see if select value is an expression which needs evaluating
	my $indexes = subst_walk($select->{select}, $params, $ewi, $aux);
	if(ref $indexes and ref $indexes ne q[ARRAY]) { # only scalar or array (of scalars) allowed here
		$ewi->{additem}->($EWI_ERROR, 0, q[select key can only be a scalar or array, not ref (type: ], ref $indexes, q[)]);
		return;
	}
	if(not ref $indexes) { $indexes = [ $indexes ]; }
	my $id_string = join(q/;/, @{$indexes}); # for error logging
	if(not defined ($indexes = _resolve_indexes($indexes, $params, $ewi, $aux))) {
		return;
	}

	my $cases = _preproc_cases($select->{cases}, $id_string, $params, $ewi, $aux);
	if(not $cases) {
		return;
	}

	# this approach means that default will always apply when no select indexes are found (so cannot be switched off using -nullkeys)
	if(scalar @{$indexes} == 0) {
		# all valid but nothing selected - evaluate default attribute (if exists), revalidate as select_range
		my $default;
		if(defined $select->{default}) {
			$default = subst_walk($select->{default}, $params, $ewi, $aux);
		}

		if(not defined $default or (ref $default eq q[ARRAY] and not @{$default})) { return; }

		$indexes = $default;
		if(not ref $indexes) { $indexes = [ $indexes ]; }
	}

	$indexes = finalise_array($indexes); # do this after default check

	# validate indices - numerics for array cases, existing keys for hash cases
	if(not $select->{allow_unspec_keys} and not defined ($indexes = _validate_indexes($indexes, $select->{cases}, $params, $ewi))) { # array indices numeric and in range? hash keys exist in hash?
		$ewi->{additem}->($EWI_ERROR, 0, q[select directive without valid indexes (select on: ], $id_string, q[)]);
		return;
	}

	if(defined $select->{select_range} and not _valid_select_range($select->{select_range}, $indexes, $ewi, $id_string, q[select_range])) {
		return;
	}

	if(@{$indexes} == 0) { # check again, maybe only an array of undefs before
		return;
	}

	if(ref $cases eq q[ARRAY]) {
		if(@{$indexes} > 1) {
			$retval = [ @{$cases}[@{$indexes}] ];
		}
		else {
			$retval = $cases->[$indexes->[0]];
		}
	}
	else {
		if(@{$indexes} > 1) {
			$retval = [ @{$cases}{@{$indexes}} ]; # slice the hash
		}
		else {
			$retval = $cases->{$indexes->[0]};
		}
	}

	return $retval;
}

sub _resolve_indexes {
	my ($indexes, $params, $ewi, $aux) = @_;

	if(ref $indexes ne q[ARRAY]) {
		$ewi->{additem}->($EWI_ERROR, 0, q[indexes attribute must be array]);
		return;
	}

	for my $i (0 .. $#{$indexes}) {
		my $param_entry = fetch_param_entry($indexes->[$i], $params, $ewi, $aux);
		if(exists $param_entry->{_value}) {
			$indexes->[$i] = $param_entry->{_value};
		}
		else {
			splice @{$indexes}, $i, 1;
		}
	}

	return $indexes;
}

sub _preproc_cases {
	my ($cases, $id_string, $params, $ewi, $aux) = @_;

	if(not (defined $cases)) {
		$ewi->{additem}->($EWI_ERROR, 0, q[select directive with undefine or missing cases attribute (select on: ], $id_string, q[)]);
		return;
	}
	if(not ($cases = subst_walk($cases, $params, $ewi, $aux))) { # resolve what needs to be resolved
		$ewi->{additem}->($EWI_ERROR, 0, q[select directive case atttribute resolves to undef (select on: ], $id_string, q[)]);
		return;
	}
	my $rt = ref $cases;
	if(not any { /\A$rt\Z/ } qw(ARRAY HASH)) {
		$ewi->{additem}->($EWI_ERROR, 0, q[cases attribute must be array or hash (select on: ], $id_string, q[)]);
		return;
	}

	return $cases;
}

sub _validate_indexes {
	my ($indexes, $cases, $params, $ewi) = @_;

	if(ref $indexes ne q[ARRAY]) {
		$ewi->{additem}->($EWI_ERROR, 0, q[indexes attribute must be array]);
		return; # should this be fatal or just informational?
	}

	my $def_indexes = [ (grep { defined } @{$indexes}) ]; # undefined values are allowed
	my $cases_type = ref $cases;
	my @outsiders;
	if($cases_type eq q[ARRAY]) {
		my $maxidx = scalar @{$cases};

		@outsiders = grep { $_ > $maxidx; } @{$def_indexes};
		if(@outsiders) {
			$ewi->{additem}->($EWI_ERROR, 0, q[index values out of range for array of cases: ], join(',', @outsiders));
			return; # should this be fatal or just informational?
		}
		@outsiders = grep { /\D/ } @{$def_indexes};
		if(@outsiders) {
			$ewi->{additem}->($EWI_ERROR, 0, q[non-numeric index values for array of cases: ], join(',', @outsiders));
			return; # should this be fatal or just informational?
		}
	}
	elsif($cases_type eq q[HASH]) {
		@outsiders = grep { not exists $cases->{$_} } @{$def_indexes};
		if(@outsiders) {
			$ewi->{additem}->($EWI_ERROR, 0, q[keys don't exist in cases: ], join(',', @outsiders));
			return; # should this be fatal or just informational?
		}
	}
	else {
		$ewi->{additem}->($EWI_ERROR, 0, q[cases attribute must be array or hash, not ], ($cases_type)? $cases_type : q[scalar]);
		return;
	}

	return $indexes;
}

sub _valid_select_range {
	my ($select_range, $indexes, $ewi, $id_string, $type) = @_;

	if(ref $select_range ne q[ARRAY] or @{$select_range} < 1 or @{$select_range} > 2) {
		$ewi->{additem}->($EWI_ERROR, 0, q[select_range attribute of a ], $type, q[ must be an array with one or two elements (select on: ], $id_string, q[)]);
		return;
	}

	my ($min, $max) = sort { $a <=> $b }  @{$select_range};
	$max ||= $min;

	my $n = @{$indexes};
	if($n < $min or $n > $max) {
		$ewi->{additem}->($EWI_ERROR, 0, q[number of indexes in ], $type , q[ is incorrect, should be >= ], $min, q[ and <= ], $max, q[, is ], $n, q[ (select on: ], $id_string, q[)]);
		return;
	}

	return $select_range;
}

sub resolve_param_default {
	my ($id, $default, $params, $ewi, $aux) = @_;

	if(not defined $default) { return; }

	return subst_walk($default, $params, $ewi, $aux);
}

sub resolve_ifnull {
	my ($id, $ifnull, $params, $ewi, $aux) = @_;

	if(not defined $ifnull) { return; }

	return subst_walk($ifnull, $params, $ewi, $aux);
}


sub report_pv_ewi {
	my ($tree_node, $logger, $cull_node_ids) = @_; 
	my $fatality = 0;

	if($tree_node->{ewi}->{report}->(0, $logger, $cull_node_ids)) { $fatality = 1; }

	# do the same recursively for any children
	for my $tn (@{$tree_node->{children}}) {
		if(report_pv_ewi($tn, $logger, $cull_node_ids)) { $fatality = 1; }
	}

	return $fatality;
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
	my ($tree_node, $tver_default, $flat_graph, $ancestor_prefixes) = @_; 

	$flat_graph ||= {};
	$ancestor_prefixes ||= [];

	# insert edges and nodes from current tree_node to $flat_graph
	subgraph_to_flat_graph($tree_node, $tver_default, $flat_graph, $ancestor_prefixes);

	# do the same recursively for any children
	push @{$ancestor_prefixes}, ($tree_node->{node_prefix} || q[]);
	for my $tn (@{$tree_node->{children}}) {
		flatten_tree($tn, $tver_default, $flat_graph, $ancestor_prefixes);
	}
	pop @{$ancestor_prefixes};

	return $flat_graph;
}

#########################################################################################
# subgraph_to_flat_graph:
#  losing everything except nodes and edges is a possibly undesirable side-effect of this
#########################################################################################
sub subgraph_to_flat_graph {
	my ($tree_node, $tver_default, $flat_graph, $ancestor_prefixes) = @_;

	my $vtnode_id = $tree_node->{id};
	my $vt_name = $tree_node->{name};

	my $subcfg = $tree_node->{cfg};

	my $ancestor_prefix = join(q//, @{$ancestor_prefixes});

	###################################################################################
	# prefix the nodes in this subgraph with a prefix to ensure uniqueness of id values
	###################################################################################
	my $tver = ($subcfg->{version} or $tver_default);
	$subcfg->{nodes} = [ (map { $_->{id} = sprintf "%s%s%s", $ancestor_prefix, $tree_node->{node_prefix}, $_->{id}; if($_->{type} eq q[EXEC] and not $_->{tver} and $tver ne $tver_default) { $_->{tver} = $tver; }  $_; } @{$subcfg->{nodes}}) ];

	########################################################################
	# any edges which refer to nodes in this subgraph should also be updated
	########################################################################
	for my $edge (@{$subcfg->{edges}}) {
		if($edge->{from}) {
			$edge->{from} = sprintf "%s%s%s", $ancestor_prefix, $tree_node->{node_prefix}, $edge->{from};
		}
		if($edge->{to}) {
			$edge->{to} = sprintf "%s%s%s", $ancestor_prefix, $tree_node->{node_prefix}, $edge->{to};
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
	my $in_edges = [ (grep { $_->{to} and $_->{to} =~ /^$ancestor_prefix$vtnode_id(:|$)/; } @{$flat_graph->{edges}}) ];
	if(@$in_edges and not $subgraph_nodes_in) { $logger->($VLFATAL, q[Cannot remap VTFILE node "], $vtnode_id, q[". No inputs specified in subgraph ], $vt_name); }
	for my $edge (@$in_edges) {
		if($edge->{to} =~ /^$ancestor_prefix$vtnode_id:?(.*)$/) {
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
				$mod_edge->{to} = sprintf "%s%s%s", $ancestor_prefix, $tree_node->{node_prefix}, $ports->[$i];
			}
		}
		else {
			$logger->($VLMIN, q[Currently only edges to stdin processed when remapping VTFILE edges. Not processing: ], $edge->{to}, q[ in edge: ], $edge->{id});
			next;
		}
	}

	#  ...then outputs from the subgraph (identify edges in the flat graph which originate in nodes of the subgraph; use the subgraph_io section of the subgraph to remap these edge destinations)
	my $out_edges = [ (grep { $_->{from} and $_->{from} =~ /^$ancestor_prefix$vtnode_id(:|$)/; } @{$flat_graph->{edges}}) ];
	if(@$out_edges and not $subgraph_nodes_out) { $logger->($VLFATAL, q[Cannot remap VTFILE node "], $vtnode_id, q[". No outputs specified in subgraph ], $vt_name); }
	for my $edge (@$out_edges) {
		if($edge->{from} =~ /^$ancestor_prefix$vtnode_id:?(.*)$/) {
			my $portkey = $1;
			$portkey ||= q[_stdout_];

			my $port;
			unless(($port = $subgraph_nodes_out->{$portkey})) {
				$logger->($VLFATAL, q[Failed to map port in subgraph: ], $vtnode_id, q[:], $portkey);
			}

			$edge->{from} = sprintf "%s%s%s", $ancestor_prefix, $tree_node->{node_prefix}, $port;
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


sub splice_nodes {
	my ($flat_graph, $ops) = @_;
	my ($splice_nodes, $prune_nodes);
	$splice_nodes = $ops->{splice};
	$prune_nodes = $ops->{prune};

	my $splice_candidates = { cull_nodes => {}, cull_edges => {}, preserve_nodes => {}, replacement_edges => [], prune_edges => [], frontier => [], new_nodes => [], stdio_gen => { in => mk_stdio_node_generator($SRC), out => mk_stdio_node_generator($DST), }, };

	if(@{$splice_nodes}) {
		$splice_candidates = register_splice_pairs($flat_graph, $splice_nodes, $SPLICE, $splice_candidates);
	}
	if(@{$prune_nodes}) {
		$splice_candidates = register_splice_pairs($flat_graph, $prune_nodes, $PRUNE, $splice_candidates);
	}

	$splice_candidates = prepare_cull($flat_graph, $splice_candidates);
	my @cull_node_ids = keys %{$splice_candidates->{cull_nodes}}; # this list of removed nodes is used to suppress irrelevant error messages

	if(validate_splice_candidates($splice_candidates, $flat_graph)) {
		$flat_graph = final_splice($flat_graph, $splice_candidates);
	}
	else {
		$logger->($VLFATAL, q[ERROR: proposed splice/prune specification was not valid]);
	}

	return ($flat_graph, \@cull_node_ids);
}

###################################################################################################
# register_splice_pairs_process_pass1:
#  Initial processing of splice/prune node[:port] pairs. Identify set of src/dst nodes and edges to
#   be removed, and create new edges. The new edges will later be added to the graph (splice) or
#   used to identify input/output node ports to be removed (prune).
#
#   splice_nodes entry: [src_node[:src_port]][-[dst_node[:dst_port]]]
###################################################################################################
sub register_splice_pairs {
	my ($flat_graph, $splice_nodes, $splice_type, $splice_candidates) = @_;

	# generators of new stdin or stdout nodes
	my $stdin_node = $splice_candidates->{stdio_gen}->{in};
	my $stdout_node = $splice_candidates->{stdio_gen}->{out};

	# initialise splice_candidates attributes if required (already done?)
	$splice_candidates->{$_} ||= {} for qw{cull_nodes cull_edges preserve_nodes};
	$splice_candidates->{$_} ||= [] for qw{replacement_edges prune_edges frontier};

	my $edge_list = ($splice_type == $SPLICE)? $splice_candidates->{replacement_edges} : $splice_candidates->{prune_edges};
	my $frontier = $splice_candidates->{frontier};
	my $preserve_nodes = $splice_candidates->{preserve_nodes};
	my $cull_edges = $splice_candidates->{cull_edges};

	for my $splice_pair (@{$splice_nodes}) {
		# resolve ports
		my $frsps = resolve_ports($splice_pair, $flat_graph);
		for my $frsp (@{$frsps}) {

			# note: entries in splice_nodes should be fully resolved to port-level (for src at least)

			# create candidate edge or pruning edge as appropriate
			#  Note: we should never create replacement_edges with unclear "from" (pruning should cope by ignoring). If needed, create 
			#   a new STDIN node and make it the data source (from)
			my $from = q[];
			if($frsp->{src} and exists $frsp->{src}->{node}) {
				$from = $frsp->{src}->{node}->{id} . ($frsp->{src}->{port} ? ":$frsp->{src}->{port}" : "");
			}
			my $to = q[];
			if(exists $frsp->{dst} and exists $frsp->{dst}->{node}) {
				$to = $frsp->{dst}->{node}->{id} . ($frsp->{dst}->{port} ? ":$frsp->{dst}->{port}" : "");
			}

			# if splicing, generate a STDIN node for an empty from, and a STDOUT node for an empty to
			if($splice_type == $SPLICE) {
				next if(any { $_->{from} eq $from and $_->{to} eq $to} @{$flat_graph->{edges}}); # NOOP request

				if(not $from) { my $from_node = $stdin_node->($flat_graph); push @{$splice_candidates->{new_nodes}}, $from_node; $from = $from_node->{id}; }
				if(not $to) { my $to_node = $stdout_node->($flat_graph); push @{$splice_candidates->{new_nodes}}, $to_node; $to = $to_node->{id}; }
			}

			my $eid = (($frsp->{src} and exists $frsp->{src}->{node}->{id})? $frsp->{src}->{node}->{id}: q[STDIN]) . q[_to_] . (($frsp->{dst} and exists $frsp->{dst}->{node}) ? $frsp->{dst}->{node}->{id} : q[STDOUT]);
			push @{$edge_list}, { id => $eid, from => $from, to => $to};
				
			if($frsp->{src} and exists $frsp->{src}->{node}) { $preserve_nodes->{$frsp->{src}->{node}->{id}} = 1; }
			if($frsp->{dst} and exists $frsp->{dst}->{node}) { $preserve_nodes->{$frsp->{dst}->{node}->{id}} = 1; }

			if(not any { $_->{node_info}->{node}->{id} eq $frsp->{pioneer}->{node}->{id} } @{$frontier}) { # avoid duplicate node entries in frontier stack
				push @{$frontier}, { node_info => $frsp->{pioneer}, };
			}

			# the relevant input/output edge to/from each pioneer node should be marked for culling
			my $pioneer_edge = $frsp->{pioneer_edge};
			my $edge_label = $pioneer_edge->{id} = join q/_/, ($pioneer_edge->{from}, $pioneer_edge->{to});
			$cull_edges->{$edge_label} = $pioneer_edge;
		}
	}

	return $splice_candidates;
}

#####################################
# mk_stdio_node_generator:
#  generate unique stdin/stdout nodes
#####################################
sub mk_stdio_node_generator {
	my ($type) = @_;

	Readonly::Scalar my $MAX_N => 99999;
	Readonly::Scalar my $label => ($type == $SRC)? q[STDIN]: q[STDOUT];
	Readonly::Scalar my $io => ($type == $SRC)? q[/dev/stdin]: q[/dev/stdout];
	Readonly::Scalar my $file_type => ($type == $SRC)? q[INFILE]: q[OUTFILE];

	my $n=0;

	return sub {
		my ($graph) = @_;

		my $node_id = sprintf q[%s_%05d], $label, $n++;

		while(any { $_->{id} eq $node_id } @{$graph->{nodes}}) {
			$node_id = sprintf q[%s_%05d], $label, $n++;

			if($n > $MAX_N) { croak q[unable to generate unique node id for autogenerated STDIN/STDOUT node]; }
		}

		return { id => $node_id, type => $file_type, name => $io, };
	}
}

#############################################################################################
# prepare_cull:
#  Using start/end nodes specified by splice_candidates, traverse relevant parts of the graph
#   to identify nodes and edges to be removed
#############################################################################################
sub prepare_cull {
	my ($flat_graph, $splice_candidates) = @_;

	my @frontier = @{$splice_candidates->{frontier}}; # this sub consumes frontier
	my $cull_nodes = $splice_candidates->{cull_nodes};
	my $cull_edges = $splice_candidates->{cull_edges};
	my $preserve_nodes = $splice_candidates->{preserve_nodes};

	while(@frontier) {
		my $pioneer = pop @frontier;

		my $node_info = $pioneer->{node_info};
		my $node_id = $node_info->{node}->{id};

		next if ($cull_nodes->{$node_id} or $preserve_nodes->{$node_id}); # this node already traversed or is marked for preservation

		$cull_nodes->{$node_id} = $node_info;

		for my $out_edge (@{$node_info->{all_edges}->{out}}) {
			# add edge to cull_edges
			my $edge_label = $out_edge->{id};
			$edge_label = $out_edge->{id} = join q/_/, ($out_edge->{from}, $out_edge->{to}); # probably a general requirement for unique edge IDs should be generally enforced
			$cull_edges->{$edge_label} = $out_edge;

			# add edge.to to frontier (if not in preserve_nodes [???])
			my ($to_node) = (split q[:], $out_edge->{to});
			push @frontier, { node_info => get_node_info($to_node, $flat_graph), };
		}

		for my $in_edge (@{$node_info->{all_edges}->{in}}) {
			# add edge to cull_edges
			my $edge_label = $in_edge->{id};
			$edge_label = $in_edge->{id} = join q/_/, ($in_edge->{from}, $in_edge->{to}); # probably a general requirement for unique edge IDs should be generally enforced
			$cull_edges->{$edge_label} = $in_edge;

			# add edge.to to frontier (if not in preserve_nodes [???])
			my ($from_node) = (split q[:], $in_edge->{from});
			push @frontier, { node_info => get_node_info($from_node, $flat_graph), };
		}
	}

	return $splice_candidates;
}

sub validate_splice_candidates {
	my ($splice_candidates, $flat_graph) = @_;
	my $valid = 1;

	for my $edge (@{$splice_candidates->{replacement_edges}}) {
		if(not $edge->{to}) { croak q[No to attribute for proposed replacement edge: ], $edge->{id}; }
	}

	my $cull_nodes = $splice_candidates->{cull_nodes};
	my $replacement_edges = $splice_candidates->{replacement_edges};
	my $prune_edges = $splice_candidates->{prune_edges};

	for my $node_info (values %{$cull_nodes}) {
		for my $in_edge (@{$node_info->{all_edges}->{in}}) {
			my ($src_node_id, $src_port) = split q{:}, $in_edge->{from};
			if(not $cull_nodes->{$src_node_id}
			   and not any { $_->{from} eq $in_edge->{from}} @{$replacement_edges}
			   and not any { $_->{from} eq $in_edge->{from}} @{$prune_edges}) {
				carp q[WARNING: node "], $node_info->{node}->{id}, q[" is in cull nodes list but has an unculled source node "], $src_node_id, q["];
			}
		}
	}
	my @keep_edges = ();
	for my $edge (@{$splice_candidates->{replacement_edges}}) {
		my ($src_node_id, $src_port) = split q{:}, $edge->{from};
		my ($dst_node_id, $dst_port) = split q{:}, $edge->{to};
		my $cull_from = $cull_nodes->{$src_node_id};
		my $cull_to = $cull_nodes->{$dst_node_id};

		# replacement edges should have neither end terminating in cull_nodes
		if(not $cull_from and not $cull_to) {
			$logger->($VLMIN, q[INFO: keeping replacement edge ], $edge->{id}, q[ since it starts and ends in unculled nodes]);
			push @keep_edges, $edge;
		}
		elsif($cull_from and $cull_to) {
			$logger->($VLMIN, q[INFO: Removing replacement edge ], $edge->{id}, q[ since it starts and ends in culled nodes]);
		}
		else {
			$logger->($VLMED, q[Warning: Removing replacement edge ], $edge->{id}, q[ since it links a culled and unculled node]);
		}

		# replacement edges must also start and end in ports that appear in culled edges or new_nodes
		if(not any { $_->{id} eq $edge->{from}} @{$splice_candidates->{new_nodes}} and not any { $_->{from} eq $edge->{from}} (values %{$splice_candidates->{cull_edges}})) {
			$logger->($VLMIN, q[ERROR: Replacement edge ], $edge->{id}, q[ (from:], $edge->{from}, q[ to:], $edge->{to}, q[) starts in a port that does not appear in culled edges or new_nodes]);
			$valid = 0;
		}
		if(not any { $_->{id} eq $edge->{to}} @{$splice_candidates->{new_nodes}} and not any { $_->{to} eq $edge->{to}} (values %{$splice_candidates->{cull_edges}})) {
			$logger->($VLMIN, q[ERROR: Replacement edge ], $edge->{id}, q[ (from:], $edge->{from}, q[ to:], $edge->{to}, q[) ends in a port that does not appear in culled edges or new_nodes]);
			$valid = 0;
		}
	}
	$splice_candidates->{replacement_edges} = \@keep_edges;

	#  the endpoints of culled edges must either not appear in the flat_graph, or refer to culled nodes, pruned ports or endpoints of replacement edges
	for my $edge (values %{$splice_candidates->{cull_edges}}) {
		my ($src_node_id, $src_port) = split q{:}, $edge->{from};
		my ($dst_node_id, $dst_port) = split q{:}, $edge->{to};

		if(_port_in_graph($edge->{from}, $flat_graph)
		   and not $cull_nodes->{$src_node_id}
		   and not any { $_->{from} eq $edge->{from} } @{$replacement_edges}
		   and not any { $_->{from} eq $edge->{from} } @{$prune_edges}) {
			$logger->($VLMED, q[Warning: Culled edge "], $edge->{id}, q[" comes from "], $edge->{from}, q[", but the node is not culled and the port has no replacement]);
		}

		if(_port_in_graph($edge->{to}, $flat_graph)
		   and not $cull_nodes->{$dst_node_id}
		   and not any { $_->{to} eq $edge->{to} } @{$replacement_edges}
		   and not any { $_->{to} eq $edge->{to} } @{$prune_edges}) {
			$logger->($VLMIN, q[ERROR: Culled edge "], $edge->{id}, q[" goes to "], $edge->{to}, q[", but the node is not culled and the port has no replacement]);
			$valid = 0;
		}
	}

	#  all edge termini must be unique (over replacement and pruning edges) except for STDIN/STDOUT
	my %endpoints;
	for my $edge (@{$splice_candidates->{replacement_edges}}, @{$prune_edges}) {
		my $from_end = $edge->{from};
		if($from_end and $from_end !~ /:/) { $from_end .= q[:STDOUT] };

		my $to_end = $edge->{to};
		if($to_end and $to_end !~ /:/) { $to_end .= q[:STDIN] };

		if($edge->{from}) { push @{$endpoints{$from_end}}, $edge->{id}; }
		if($edge->{to}) { push @{$endpoints{$to_end}}, $edge->{id}; }
	}
	for my $ep (keys %endpoints) {
		if(@{$endpoints{$ep}} > 1) {
			$logger->($VLMIN, q[ERROR: Edge endpoint ], $ep, q[ appears in multiple edges: ], join q[;], @{$endpoints{$ep}});
			$valid = 0;
		}
	}

	return $valid;
}

sub _port_in_graph {
	my ($edge_endpoint, $flat_graph) = @_;

	return any
		{ defined and /$edge_endpoint/ }
		(
			map
			{
				ref $_->{cmd} eq q[ARRAY]?
				@{$_->{cmd}}[1..$#{$_->{cmd}}]:
				$_->{cmd}
			}
			(grep { $_->{type} eq q[EXEC] } @{$flat_graph->{nodes}})
		);
}

###########################################
# final_splice:
#  actually perform the splicing or pruning
###########################################
sub final_splice {
	my ($flat_graph, $splice_candidates) = @_;

	my $cull_nodes = $splice_candidates->{cull_nodes};
	my $cull_edges = $splice_candidates->{cull_edges};

	# remove from flat_graph the nodes whose ids are in cull_nodes
	$flat_graph->{nodes} = [ (grep { not $cull_nodes->{$_->{id}} } @{$flat_graph->{nodes}}) ];

	# add to flat_graph new nodes generated (STDIN/STDOUT)
	push @{$flat_graph->{nodes}}, @{$splice_candidates->{new_nodes}};

	# remove from flat_graph the edges whose ids are in cull_edges
	$flat_graph->{edges} = [ (grep { not ($_->{id} and $cull_edges->{$_->{id}}) } @{$flat_graph->{edges}}) ];

	# add new edges
	push @{$flat_graph->{edges}}, @{$splice_candidates->{replacement_edges}};

	# remove pruned ports - prune edges are not required to be two-ended; just disregard undefined to/from attributes
	for my $prune_edge (@{$splice_candidates->{prune_edges}}) {
		if($prune_edge->{from}) { remove_port($prune_edge->{from}, $SRC, $flat_graph); }
		if($prune_edge->{to}) { remove_port($prune_edge->{to}, $DST, $flat_graph); }
	}

	return $flat_graph;
}

################################################################################################
# resolve_ports:
#  given a splice_pair specification, fully determine the [set of] source and destination ports
#  and confirm that they exist in the graph. At least one of source and destination is required,
#  other values can be derived
#
#  Returns:
#  [
#   {
#     src => {
#       node => { # node info from graph # },
#       port => <port name>,
#       all_edges => {
#                  in => [ # list of inbound edges ],
#                  out => [ # list of outbound edges ],
#       }
#     },
#     pioneer => { # node_info for successor node to src node:port, first in frontier # },
#     pioneer_edge => { # edge connecting pioneer node to an endpoint in the splice pair # },
#     dst => { # optional destination
#       node => { # node info from graph # },
#       port => <port name>,
#       all_edges => {
#                  in => [ # list of inbound edges ],
#                  out => [ # list of outbound edges ],
#       }
#     },
#   },
#   ...
#  ]
################################################################################################
sub resolve_ports {
	my ($splice_pair, $flat_graph) = @_;
	my $retset = [];

	# use -1 argument for split to distinguish between "a" (node a) and "a-" (a and downstream nodes)
	my ($src_spec, $dst_spec) = (split q/-/, $splice_pair, -1);

	my ($src, $dst);

	# TBD: find set of src, find set of dst, if both sets are not empty, produce Cartesian product; if one is empty, populate the other ends of the non-empty one; both empty croak

	$src = resolve_endpoint($src_spec, $SRC, $flat_graph);
	if(defined $dst_spec) {
		$dst = resolve_endpoint($dst_spec, $DST, $flat_graph);
	}

	if(not defined $src) {
		croak q[badly specified splice/prune request: ], $splice_pair;
	}

	if(@{$src} > 0) {
		for my $src_entry (@{$src}) {
			my $ret = {};

			if(defined $dst) {
				if(@{$dst} > 0) { # src X dst (Cartesian product)
					for my $dst_entry (@{$dst}) {
						$ret->{src} = $src_entry->{endpoint}->{node_info};
						$ret->{src}->{port} = $src_entry->{endpoint}->{port};
						$ret->{dst} = $dst_entry->{endpoint}->{node_info};
						$ret->{dst}->{port} = $dst_entry->{endpoint}->{port};
						$ret->{pioneer} = $src_entry->{pioneer}->{node_info};
						$ret->{pioneer_edge} = $src_entry->{pioneer}->{edge};

						push @{$retset}, $ret;
					}
				}
				else { # create one undef dst endpoint perl src entry
					$ret->{src} = $src_entry->{endpoint}->{node_info};
					$ret->{src}->{port} = $src_entry->{endpoint}->{port};
					$ret->{pioneer} = $src_entry->{pioneer}->{node_info};
					$ret->{pioneer_edge} = $src_entry->{pioneer}->{edge};

					push @{$retset}, $ret;
				}
			}
			else { # resolve one dst endpoint per src entry
				# TBD: I think undefined $dst_spec (with resulting undefined $dst) doesn't makes sense if a port is specified in $src_spec. Detect this and croak.
				my $dst_entry = _resolve_endpoint($src_entry->{endpoint_spec}, $DST, $flat_graph);

				$ret->{src} = $src_entry->{endpoint}->{node_info};
				$ret->{src}->{port} = $src_entry->{endpoint}->{port};
				$ret->{dst} = $dst_entry->{endpoint}->{node_info};
				$ret->{dst}->{port} = $dst_entry->{endpoint}->{port};
				$ret->{pioneer} = $src_entry->{pioneer}->{node_info};
				$ret->{pioneer_edge} = $src_entry->{pioneer}->{edge};

				push @{$retset}, $ret;
			}
		}
	}
	else {
		unless($dst and @{$dst} > 0) {
			croak q[badly specified splice/prune request: ], $splice_pair;
		}

		for my $dst_entry (@{$dst}) {
			my $ret = {};

			$ret->{src} = q[];
			$ret->{dst} = $dst_entry->{endpoint}->{node_info};
			$ret->{dst}->{port} = $dst_entry->{endpoint}->{port};
			$ret->{pioneer} = $dst_entry->{pioneer}->{node_info};
			$ret->{pioneer_edge} = $dst_entry->{pioneer}->{edge};

			push @{$retset}, $ret;
		}
	}

	unless($src or $dst) { croak q[No src or dst spec in splice pair: ], $splice_pair; }

	return $retset;
}

####################################################################################
# resolve_endpoint:
#  expand possibly wildcarded endpoint_spec, then fully resolve individual endpoints
####################################################################################
sub resolve_endpoint {
	my ($endpoint_spec, $which_end, $flat_graph) = @_;

	return [] unless($endpoint_spec);

	my @ep_set = ();

	my ($node_id, $port) = (split q/:/, $endpoint_spec, -1);
	my $full_node_set = get_nodes_info($node_id, $flat_graph);
	my $port_re;
	if($port) { $port_re = qr/:$port/; } # this feels shaky
	for my $node_info (@{$full_node_set}) {
		# if the node has a port which matches the port value (which may be wildcarded) resolve
		#  the node:port combination and add it to the list
		my @all_edges = (@{$node_info->{all_edges}->{in}}, @{$node_info->{all_edges}->{out}});
		my @endpoint_names = ();
		if($port_re) {
			push @endpoint_names, (map { $_->{from} } (grep { $_->{from} =~ /$port_re\z/smx } (@{$node_info->{all_edges}->{in}}, @{$node_info->{all_edges}->{out}})));
			push @endpoint_names, (map { $_->{to} } (grep { $_->{to} =~ /$port_re\z/smx } (@{$node_info->{all_edges}->{in}}, @{$node_info->{all_edges}->{out}})));
		}
		else {
			push @endpoint_names, $node_info->{node}->{id} . (defined $port ? ":$port" : "");
		}

		# we have the names of the endpoints, now fetch more info
		for my $endpoint_name (@endpoint_names) {
			my $rep = _resolve_endpoint($endpoint_name, $which_end, $flat_graph);
			push @ep_set, $rep;
		}
	}

	return \@ep_set;
}

sub _resolve_endpoint {
	my ($endpoint_spec, $which_end, $flat_graph) = @_;

	my $ret = {};

	return unless($endpoint_spec);

	#######################
	# Process endpoint spec
	#######################
	# use -1 argument for split to distinguish between "a" (node a) and "a:" (STDOUT of node a)
	my ($node_id, $port) = (split q/:/, $endpoint_spec, -1);

	if($tver_default < 2) {
		unless(not $port
			or ($which_end == $SRC
				and ($port=~/_OUT__\z/smx or $port=~/\A__OUT_/smx))
			or ($which_end == $DST
				and ($port=~/_IN__\z/smx or $port=~/\A__IN_/smx))
		) {
			croak q[port name ], $port, q[: naming convention incorrect for ], (($which_end == $SRC)? q[out] : q[in]), q[port];
		}
	}

	my $node_info = get_node_info($node_id, $flat_graph); # fetch node and its in and out edges
	if(not $node_info) { croak q[no node ], $node_id, q[ found when searching for ports info]; }

	$ret->{endpoint_spec} = $endpoint_spec;
	if(defined $port) {
		my ($std_port_name, $in_out, $near_end, $far_end) = ($which_end == $SRC) ? qw/ use_STDOUT out from to / : qw/ use_STDIN in to from /;

		# make sure the named port actually exists on this node (by checking the edges) 
		if($port and not any { defined $_ and $_ eq $port } map { (split q/:/, $_->{$near_end})[1] } @{$node_info->{all_edges}->{$in_out}}) { croak q[port ], $port, q[ is not a port of node ], $node_id; }
		# if port name is q[], STD[IN|OUT] is implied. Is this possible for this node?
		if(not $port and $node_info->{node}->{type} !~ /\A(IN|OUT|RA)FILE\Z/smx and not $node_info->{node}->{$std_port_name}) { croak q[port not specified by name, but ], $std_port_name, q[ is false for node ], $node_id; }

		my $from_to_val = $node_id . ($port ? ":$port" : ""); # or just chop any trailing ':' from endpoint_spec?
		my ($pioneer_edge) = grep { $_->{$near_end} eq $from_to_val } @{$node_info->{all_edges}->{$in_out}};
		my $pioneer = $pioneer_edge->{$far_end};
		if(not $pioneer) { croak q[Failed to find "], $far_end, q[" node ], $endpoint_spec; }  # this may be too strict (but when is there (legally) a named output port with no edge?)
		my ($pioneer_node_id) = (split q/:/, $pioneer);  # not interested in the port here (?)

		$ret->{endpoint}->{node_info} = $node_info;
		$ret->{endpoint}->{port} = $port;
		$ret->{pioneer}->{node_info} = get_node_info($pioneer_node_id, $flat_graph);
		$ret->{pioneer}->{edge} = $pioneer_edge;
	}
	else {
		my ($std_port_name, $in_out, $near_end, $far_end) = ($which_end == $SRC) ? qw/ use_STDIN in to from / : qw/ use_STDOUT out from to /;

		# if port in the endpoint_spec is not explicitly named, identify the appropriate up- or downstream edge and node, depending on which end of the splice pair we have. These must be unambiguous.
		if(@{$node_info->{all_edges}->{$in_out}} > 1) { croak q[Splicing error, node ], $node_id, q[ node must have only one ], $in_out, q[ port when implicit, found ], $in_out, q[ports ], join q/,/, (map { q["] . $_->{$near_end} . q["] } @{$node_info->{all_edges}->{$in_out}}); }
		if(@{$node_info->{all_edges}->{$in_out}} < 1 and $node_info->{node}->{type} !~ /\A(IN|OUT|RA)FILE\Z/smx and not $node_info->{node}->{$std_port_name,}) {
			croak q[Splicing error, node ], $node_id, q[ node must have one ], $in_out, q[port (unless ], $std_port_name, q[ is true) when implicit, but no ], $in_out, q[ports found];
		}

		$ret->{pioneer}->{node_info} = $node_info;
		my ($pioneer_edge) = @{$node_info->{all_edges}->{$in_out}}; # Note: there is at most one in/outward-bound edge - see checks above
		if($pioneer_edge) {
			($node_id, $port) = split q/:/, $pioneer_edge->{$far_end}, -1;
			$node_info = get_node_info($node_id, $flat_graph);

		}
		else { # endpoint is STDIN/STDOUT
			return;
		}
		$ret->{endpoint}->{node_info} = $node_info;
		$ret->{endpoint}->{port} = $port;
		$ret->{pioneer}->{edge} = $pioneer_edge;
	}

	return $ret;
}

######################################
# get_node_info:
#  fetch node and its in and out edges
######################################
sub get_node_info {
	my ($node_id, $flat_graph) = @_;

	my $node = (grep { $_->{id} eq $node_id} @{$flat_graph->{nodes}})[0]; # assumption that id is unique
	return if(not $node);

	my $in_edges = [ (grep { $_->{to} =~ /^$node_id(:|$)/; } @{$flat_graph->{edges}}) ];
	my $out_edges = [ (grep { $_->{from} =~ /^$node_id(:|$)/; } @{$flat_graph->{edges}}) ];

	return { node => $node, all_edges => { in => $in_edges, out => $out_edges } };
}

#####################################################
# get_nodes_info:
#  fetch nodes and their in and out edges. Allows use
#   of regexp for id, so returns a set of nodes
#####################################################
sub get_nodes_info {
	my ($node_id_re, $flat_graph) = @_;
	my $ret = {};
	my @retset = ();

	my $re = qr/$node_id_re/;
	my @nodes = (grep { $_->{id} =~ /\A$re\z/smx } @{$flat_graph->{nodes}});
	return if(@nodes < 1);

	for my $node (@nodes) {
		my $in_edges = [ (grep { $_->{to} =~ /^$node->{id}(:|$)/; } @{$flat_graph->{edges}}) ];
		my $out_edges = [ (grep { $_->{from} =~ /^$node->{id}(:|$)/; } @{$flat_graph->{edges}}) ];

		push @retset, { node => $node, all_edges => { in => $in_edges, out => $out_edges } };
	}

	return \@retset;
}

sub remove_port {
	my ($port_spec, $type, $flat_graph) = @_;

	my ($node_id, $port_name) = (split q[:], $port_spec, 2);

	my ($node) = grep { $_->{id} eq $node_id } @{$flat_graph->{nodes}};

	if($node) {
		if($port_name) {
			delete_port($port_name, $node);
		}
		else {
			if($type == $SRC) {
				if(not $node->{use_STDOUT} and $node->{type} !~ /\A(IN|OUT|RA)FILE\Z/smx) { carp q[Trying to switch off STDOUT in node ], $node_id, q[, but it is already off]; }

				$node->{use_STDOUT} = JSON::false;
			}
			elsif($type == $DST) {
				if(not $node->{use_STDIN} and $node->{type} !~ /\A(IN|OUT|RA)FILE\Z/smx) { carp q[Trying to switch off STDIN in node ], $node_id, q[, but it is already off]; }

				$node->{use_STDIN} = JSON::false;
			}
			else {
				carp q[unrecognised type ], $type, q[ when attempting to remove nameless port];
			}
		}
	}
	else {
		carp q[Failed to find node ], $node_id, q[ when removing old ports (maybe node was pruned?)];
	}

	return;
}

sub delete_port {
	my ($port_name, $node) = @_;

	if(ref $node->{cmd} eq 'ARRAY') {
		if($tver_default >= 2 and (not exists $node->{tver} or $node->{tver} >= 2)) {
			# remove any references from $node->{ports} section
			if(exists $node->{ports}->{$port_name}) { delete $node->{ports}->{$port_name}; }
			my $port_locs = _extract_ports($node->{cmd}, $node->{id});
			for my $occ (sort { $b->{idx} <=> $a->{idx} } @{$port_locs->{$port_name}->{occurrences}}) {
				splice @{$occ->{arr}}, $occ->{idx}, 1;
			}

			return;
		}
		else {
			# this sweeping approach should be replaced when syntax for port specification is improved
			if(any { $_ =~ /$port_name/ } @{$node->{cmd}}) {
				$node->{cmd} = [ (grep { $_ !~ /$port_name/ } @{$node->{cmd}}) ];
				return;
			}
		}
	}
	else {
		return if ($node->{cmd} =~ s/\Q$port_name\E//smx);
	}

	carp 'delete_port: node '.($node->{id})." has no port $port_name";

	return;
}

sub _extract_ports {
	my ($cmd, $id) = @_;
	my %ports;

	unless($cmd and ref $cmd eq q[ARRAY]) {
		return;
	}

	for my $i (0..$#{$cmd}) {
		my $elem = $cmd->[$i];
		if(ref $elem eq q[HASH]) {
			if($elem->{port}) {
				$ports{$elem->{port}}->{attribs} = reconcile_port_info($elem, $ports{$elem->{port}}->{attribs});
				$ports{$elem->{port}}->{occurrences} ||= [];
				push @{$ports{$elem->{port}}->{occurrences}}, {arr => $cmd, idx => $i}; # note location for later substitution
			}
			elsif($elem->{packflag}) {
				if(ref $elem->{packflag} eq q[ARRAY]) {
					for my $j (0..$#{$elem->{packflag}}) {
						my $pf_elem = $elem->{packflag}->[$j];
						if(ref $pf_elem eq q[HASH] and $pf_elem->{port}) {
							$ports{$pf_elem->{port}}->{attribs} = reconcile_port_info($pf_elem, $ports{$pf_elem->{port}}->{attribs});
							$ports{$pf_elem->{port}}->{occurrences} ||= [];
							push @{$ports{$pf_elem->{port}}->{occurrences}}, {arr => $elem->{packflag}, idx => $j}; # note location for later substitution
						}
					}
				}
				else {
					$logger->($VLMIN, "WARN: packflag with non-array value, node id: ", $id);
				}
			}	
		}
	}

	return \%ports;
}

sub reconcile_port_info {
	my ($port_elem, $current_attribs) = @_;
	my $attribs;

	if($current_attribs) { # multiple occurrences of this port in the node
		if($current_attribs->{direction} and $current_attribs->{direction} ne $port_elem->{direction}) {
			$attribs->{direction} = q[bi];
		}
		else {
			$attribs->{direction} = $port_elem->{direction};
		}
		if($current_attribs->{type} and $current_attribs->{type} ne $port_elem->{type}) {
			$attribs->{type} = q[seekable]; # use the more restrictive option
		}
		else {
			$attribs->{type} = $port_elem->{type};
		}
	}
	else {
		$attribs->{direction} = $port_elem->{direction};
		$attribs->{type} = $port_elem->{type};
	}

	return $attribs;
}

###########################################################################
# split_csl:
#  split comma-separated string, allowing the commas to be escaped with '\'
###########################################################################
sub split_csl {
	my ($csl) = @_;

	$csl =~ s/\\,/\xff/g;
	my @a = (split /,/, $csl);
	for (@a) { $_ =~ s/\xff/,/g; }

	return @a;
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
	my ($keys, $vals, $nullkeys, $splice_list, $prune_list, $param_vals_fns) = @_;

	my $pv = {};

	$pv = construct_pv($keys, $vals, $nullkeys);

	$pv = combine_pvs($param_vals_fns, $pv);

	$pv = add_ops($pv, $splice_list, $prune_list);

	return $pv;
}

sub construct_pv {
	my ($keys, $vals, $nullkeys) = @_;
	my $pv = { param_store =>  [], assign => [], assign_local => {}, ops => { splice => [], prune => [], }, };;
	my $subst_requests;
	my $subst_map_overrides;

	if(@$keys != @$vals) {
		croak q[Mismatch between keys and vals];
	}

	if(@{$keys} == 0 and @{$nullkeys} == 0) {
		return;
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
	}

	if(defined $subst_requests) { $pv->{assign} = [ $subst_requests ]; };
	if(defined $subst_map_overrides) { $pv->{assign_local} = $subst_map_overrides; };

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
	my $target = {
			assign => [],
			assign_local => {},
			param_store => [],
			ops => {
				splice => [],
				prune => [],
			}
		};
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

		if($pv->{ops}->{splice} and ref $pv->{ops}->{splice} eq q[ARRAY]) { push @{$target->{ops}->{splice}}, @{$pv->{ops}->{splice}}; }
		if($pv->{ops}->{prune} and ref $pv->{ops}->{prune} eq q[ARRAY]) { push @{$target->{ops}->{prune}}, @{$pv->{ops}->{prune}}; }
	}

	return $target;
}

######################################################################
# add_ops:
# lightly parse any splice or prune from the command line and add them
#  to the ops section of the param_vals hash
######################################################################
sub add_ops {
	my ($pv, $splice_list, $prune_list) = @_;

	$pv->{ops}->{splice} ||= [];
	$pv->{ops}->{prune} ||= [];
	if($splice_list) { push @{$pv->{ops}->{splice}}, ( (split q{;}, $splice_list) ) };
	if($prune_list) { push @{$pv->{ops}->{prune}}, ( (split q{;}, $prune_list) ) };

	return $pv;
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

########################################################
# finalise_cmd: postprocess EXEC nodes
#    flatten cmd element to array ref, transfer any port
#    attributes from node to cmd level
########################################################
sub finalise_cmd {
	my ($cmd_node) = @_;

	$cmd_node->{cmd} = finalise_array($cmd_node->{cmd});

	my $cmd = $cmd_node->{cmd};
	my $r=ref $cmd;
	if(not $r) {
		$cmd = [ $cmd ];
	}
	elsif($r ne q[ARRAY]) {
		$logger->($VLMAX, q[Cannot post-process node cmd element unless it is scalar or array ref (node id: ], $cmd_node->{id}, q[ ; type: ], $r, q[)] );
		return $cmd_node;
	}

	if(not defined $cmd_node->{tver} or $cmd_node->{tver} >= 2) {
		my $node_ports = $cmd_node->{ports};
		if(defined $node_ports) {
			my %ports_seen;
			for my $e (@{$cmd}) {
				if(ref $e eq q[HASH] and $e->{port} and $node_ports->{$e->{port}}) {
					# move all key/val pairs from node ports section to cmd port element
					@{$e}{keys %{$node_ports->{$e->{port}}}} = @{$node_ports->{$e->{port}}}{keys %{$node_ports->{$e->{port}}}};
					$ports_seen{$e->{port}} = 1;
				}
			}

			for my $k (keys %{$node_ports}) {
				if(not exists $ports_seen{$k} and defined $node_ports->{$k}->{required} and not $node_ports->{$k}->{required}) { # unless explicitly flagged as unrequired
					$logger->($VLFATAL, q[Unused node port: ], $k, q[ ; node id: ], $cmd_node->{id}, q[ ; cmd: ], join q[ ], @{$cmd} );
				}
			}

			delete $cmd_node->{ports};
		}
	}

	return $cmd_node;
}

##############################################################
# finalise_array: used to postprocess arrays (e.g. cmd attribs
#   of EXEC nodes). Input is either:
#    i) a string - return it
#    ii) or a ref to an array of (possibly undef) scalars or
#      similar array refs - convert this an array of strings
# Note: tree input assumed; don't apply this to anything with
#  referential cycles
##############################################################
sub finalise_array {
	my ($arr) = @_;

	if(ref $arr eq q[ARRAY]) {
		while(any { not defined($_) or ref $_ eq q[ARRAY] } @{$arr}) {
			$arr = [ (grep { defined($_) } @{$arr}) ]; # first remove any undefined elements

			for my $i (reverse (0..$#{$arr})) {
				if(ref $arr->[$i] eq q[ARRAY]) {
					$arr->[$i] = finalise_array($arr->[$i]);
					splice @{$arr}, $i, 1, @{$arr->[$i]};
				}
			}
		}
	}

	return $arr;
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
	my $tag = q[];

	return {
		additem => sub {
			my ($type, $subclass, @ms) = @_;

			my $label = join(":", @labels);
			my $ms = join("", @ms);

			my $full_ms = sprintf "(%s) - %s", $label, $ms;

			push @list, { type => $type, subclass => $subclass, ms => $full_ms, tag => $tag, };

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
		settag => sub {
			my ($id) = @_;

			my $ret = $tag;
			$tag = $id;

			return $ret;
		},
		removetag => sub {
			my $ret = $tag;

			$tag = q[];

			return $ret;
		},
		report => sub {
			my ($fatality_level, $logger, $exclude_list) = @_;
			my $ewi_retstat = 0;
			my %ewi_type_names = ( $EWI_ERROR => q[Error], $EWI_WARNING => q[Warning], $EWI_INFO => q[Info], );

			for my $ewi_item (@list) {
				if($ewi_item->{type} == $EWI_ERROR and $ewi_item->{subclass} <= $fatality_level) {
					my $tag = (defined $ewi_item->{tag} and ref $ewi_item->{tag} eq q[SCALAR] and ${$ewi_item->{tag}});
					if($exclude_list and $tag and any { /$tag/ } @{$exclude_list}) {
						return 0; # disregard this "error"
					}
					else {
						$ewi_retstat = 1;
					}
				}

				$logger->($VLMIN, join("\t", ($ewi_type_names{$ewi_item->{type}}, $ewi_item->{subclass}, $ewi_item->{ms},)));
			}

			return $ewi_retstat;
		}
	}
}

