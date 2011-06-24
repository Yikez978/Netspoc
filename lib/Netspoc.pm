package Netspoc;

=head1 NAME

Netspoc - A Network Security Policy Compiler

=head1 COPYRIGHT AND DISCLAIMER

(C) 2011 by Heinz Knutzen <heinzknutzen@users.berlios.de>

http://netspoc.berlios.de

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

$Id$

=cut

use strict;
use warnings;
use open qw(:std :utf8);
use Encode;
my $filename_encode = 'UTF-8';

my $program = 'Network Security Policy Compiler';
our $VERSION = sprintf "%d.%03d", q$Revision$ =~ /(\d+)/g;

use Exporter;
our @ISA    = qw(Exporter);
our @EXPORT = qw(
  %routers
  %interfaces
  %networks
  %hosts
  %anys
  %owners
  %admins
  %areas
  %pathrestrictions
  %global_nat
  %groups
  %services
  %servicegroups
  %policies
  %isakmp
  %ipsec
  %crypto
  %expanded_rules
  $error_counter
  $store_description
  store_description
  get_config_keys
  get_config_pattern
  check_config_pair
  read_config
  set_config
  info
  progress
  abort_on_error
  set_abort_immediately
  err_msg
  fatal_err
  read_ip
  print_ip
  show_version
  split_typed_name
  is_network
  is_router
  is_interface
  is_host
  is_subnet
  is_any
  is_every
  is_group
  is_servicegroup
  is_objectgroup
  is_chain
  is_autointerface
  read_netspoc
  read_file
  read_file_or_dir
  show_read_statistics
  order_services
  link_topology
  mark_disabled
  find_subnets
  setany
  set_policy_owner
  expand_policies
  expand_crypto
  check_unused_groups
  setpath
  path_walk
  find_active_routes_and_statics
  check_any_rules
  optimize_and_warn_deleted
  optimize
  distribute_nat_info
  gen_reverse_rules
  mark_secondary_rules
  rules_distribution
  local_optimization
  check_output_dir
  print_code );

####################################################################
# User configurable options.
####################################################################

# Valid values:
# - Default: 0|1
# - Option with name "check_*": 0,1,'warn' 
#  - 0: no check
#  - 1: throw an error if check fails
#  - warn: print warning if check fails
# - Option with name "max_*": integer
# Other: string
our %config =
    (

# Check for unused groups and servicegroups.
     check_unused_groups => 'warn',

# Allow subnets only
# - if the enclosing network is marked as 'route_hint' or
# - if the subnet is marked as 'subnet_of'
     check_subnets => 'warn',

# Check for unenforceable rules, i.e. no managed device between src and dst.
     check_unenforceable => 'warn',

# Check for duplicate rules.
     check_duplicate_rules => 'warn',

# Check for redundant rules.
     check_redundant_rules => 'warn',

# Check for policies where owner can't be derived.
     check_policy_unknown_owner => 0,

# Check for policies where multiple owners have been derived.
     check_policy_multi_owner => 0,

# Check for inconsistent use of attributes 'extend' and 'extend_only' in owner.
     check_owner_extend => 0,

# Check for transient any rules.
     check_transient_any_rules => 0,

# Optimize the number of routing entries per router:
# For each router find the hop, where the largest
# number of routing entries points to
# and replace them with a single default route.
# This is only applicable for internal networks
# which have no default route to the internet.
     auto_default_route => 1,

# Add comments to generated code.
     comment_acls   => 0,
     comment_routes => 0,

# Print warning about ignored ICMP code fields at PIX firewalls.
     warn_pix_icmp_code => 0,

# Ignore these names when reading directories:
# - CVS and RCS directories
# - CVS working files
# - Editor backup files: emacs: *~
     ignore_files => '^(CVS|RCS|\.#.*|.*~)$',

# Abort after this many errors.
     max_errors => 10,

# Print progress messages.
     verbose => 1,

# Print progress messages with time stamps.
# Print "finished" with time stamp when finished.
     time_stamps => 0,
     );

# Valid values for config options in %config.
# Key is prefix or string "default".
# Value is pattern for checking valid values.
our %config_type =
(
 check_  => '0|1|warn',
 max_    => '\d+',
 ignore_ => '\S+',
 _default => '0|1',
 );

sub get_config_keys {
    keys %config;
}

sub valid_config_key {
    my ($key) = @_;
    exists $config{$key}
}

sub get_config_pattern {
    my ($key) = @_;
    my $pattern;
    for my $prefix (keys %config_type) {
	if ($key =~ /^$prefix/) {
	    $pattern = $config_type{$prefix};
	    last;
	}
    }
    $pattern || $config_type{_default};
}

# Checks for valid config key/value pair.
# Returns false on success, the expected pattern on failure.
sub check_config_pair {
    my ($key, $value) = @_;
    my $pattern = get_config_pattern($key);
    return($value =~ /^($pattern)$/ ? undef : $pattern);
}

# Set %config with pairs from one or more hashrefs. 
# Rightmost hash overrides previous values with same key.
sub set_config {
    my (@hrefs) = @_;
    for my $href (@hrefs) {
	while (my ($key, $val) = each %$href) {
	    $config{$key} = $val;
	}
    }
}

# Store descriptions as an attribute of definitions.
# This may be useful when called from a reporting tool.
our $store_description => 0;

# New interface, modified by sub store_description.
my $new_store_description => 0;

sub store_description {
    my ($set) = @_;
    if (defined $set) {
	$new_store_description = $set;
    }
    else {
	$new_store_description;
    }
}

# Use non-local function exit for efficiency.
# Perl profiler doesn't work if this is active.
my $use_nonlocal_exit => 1;

####################################################################
# Attributes of supported router models
####################################################################
my %router_info = (
    IOS => {
        name           => 'IOS',
        stateless      => 1,
        stateless_self => 1,
	stateless_icmp => 1,
        routing        => 'IOS',
        filter         => 'IOS',
	can_vrf        => 1,
	has_out_acl    => 1,
        crypto         => 'IOS',
        comment_char   => '!',
        extension      => {
            EZVPN => { crypto => 'EZVPN' },
            FW    => {
                name      => 'IOS_FW',
                stateless => 0
            },
	    # Migration flags for approve code.
	    n => { add_n => 1},
	    o => { add_o => 1},
        },
    },
    PIX => {
        name                => 'PIX',
	stateless_icmp      => 1,
        routing             => 'PIX',
        filter              => 'PIX',
        comment_char        => '!',
        has_interface_level => 1,
        need_identity_nat   => 1,
        no_filter_icmp_code => 1,
    },

    # Like PIX, but without identity NAT.
    ASA => {
        name                => 'ASA',
	stateless_icmp      => 1,
        routing             => 'PIX',
        filter              => 'PIX',
	has_out_acl         => 1,
        crypto              => 'ASA',
        no_crypto_filter    => 1,
        comment_char        => '!',
        has_interface_level => 1,
        no_filter_icmp_code => 1,
        extension           => {
            VPN => {
                crypto           => 'ASA_VPN',
                no_crypto_filter => 0,
                stateless_tunnel => 1,
                do_auth          => 1,
            },
        },
    },
    Linux => {
        name         => 'Linux',
        routing      => 'iproute',
        filter       => 'iptables',
	has_io_acl  => 1,
        comment_char => '#',
    },

    # Cisco VPN 3000 Concentrator including RADIUS config.
    VPN3K => {
        name           => 'VPN3K',
        stateless      => 1,
        stateless_self => 1,
	stateless_icmp => 1,
        routing        => 'none',
        filter         => 'VPN3K',
        need_radius    => 1,
        do_auth        => 1,
        crypto         => 'ignore',
        comment_char   => '!',
    },
);

# All arguments are true.
#sub all { $_ || return 0 for @_; 1 }
sub all { 
    for my $e (@_) {
	$_ || return 0;
    }
    1;
}

# All arguments are 'eq'.
sub equal {
    return 1 if not @_;
    my $first = $_[0];
    return not grep { $_ ne $first } @_[ 1 .. $#_ ];
}

my $start_time = time();

sub info( @ ) {
    return if not $config{verbose};
    print STDERR @_, "\n";
}

sub progress ( @ ) {
    if ($config{time_stamps}) {
	my $diff = time() - $start_time;
        printf STDERR "%3ds ", $diff;
    }
    info @_;
}

sub warn_msg ( @ ) {
    print STDERR "Warning: ", @_, "\n";
}

sub debug ( @ ) {
    print STDERR @_, "\n";
}

# Name of current input file.
our $file;

# Rules and objects read from directories and files with
# special name 'xxx.private' are marked with attribute {private} = 'xxx'.
# This variable is used to propagate the value from directories to its
# files and sub-directories.
our $private;

# Content of current file.
our $input;

# Current line number of input file.
our $line;

sub context() {
    my $context;
    if (pos $input == length $input) {
        $context = 'at EOF';
    }
    else {
        my ($pre, $post) =
          $input =~ m/([^ \t\n,;={}]*[,;={} \t]*)\G([,;={} \t]*[^ \t\n,;={}]*)/;
        $context = qq/near "$pre<--HERE-->$post"/;
    }
    return qq/ at line $line of $file, $context\n/;
}

sub at_line() {
    return qq/ at line $line of $file\n/;
}

our $error_counter = 0;

sub check_abort() {
    $error_counter++;
    if ($error_counter == $config{max_errors}) {
        die "Aborted after $error_counter errors\n";
    }
    elsif ($error_counter > $config{max_errors}) {
        die "Aborted\n";
    }
}

sub abort_on_error {
    die "Aborted with $error_counter error(s)\n" if $error_counter;
}

sub set_abort_immediately {
    $error_counter = $config{max_errors};
}

sub error_atline( @ ) {
    print STDERR "Error: ", @_, at_line;
    check_abort;
}

sub err_msg( @ ) {
    print STDERR "Error: ", @_, "\n";
    check_abort;
}

sub fatal_err( @ ) {
    print STDERR "Error: ", @_, "\n";
    die "Aborted\n";
}

sub syntax_err( @ ) {
    die "Syntax error: ", @_, context;
}

sub internal_err( @ ) {
    my ($package, $file, $line, $sub) = caller 1;
    die "Internal error in $sub: ", @_, "\n";
}

####################################################################
# Helper functions for reading configuration
####################################################################

# $input is used as input buffer, it holds content of current input file.
# Progressive matching is used. \G is used to match current position.
sub skip_space_and_comment() {

    # Ignore trailing white space and comments.
    while ($input =~ m'\G[ \t]*(?:[#].*)?(?:\n|$)'gc) {
        $line++;
    }

    # Ignore leading white space.
    $input =~ m/\G[ \t]*/gc;
}

# Check for a string and skip if available.
sub check( $ ) {
    my $token = shift;
    skip_space_and_comment;
    return $input =~ m/\G$token/gc;
}

# Skip a string.
sub skip ( $ ) {
    my $token = shift;
    check $token or syntax_err "Expected '$token'";
}

# Check, if an integer is available.
sub check_int() {
    skip_space_and_comment;
    if ($input =~ m/\G(\d+)/gc) {
        return $1;
    }
    else {
        return undef;
    }
}

sub read_int() {
    check_int or syntax_err "Integer expected";
}

# Read IP address. Internally it is stored as an integer.
sub read_ip() {
    skip_space_and_comment;
    if ($input =~ m/\G(\d+)\.(\d+)\.(\d+)\.(\d+)/gc) {
        if ($1 > 255 or $2 > 255 or $3 > 255 or $4 > 255) {
            error_atline "Invalid IP address";
        }
        return unpack 'N', pack 'C4', $1, $2, $3, $4;
    }
    else {
        syntax_err "IP address expected";
    }
}

# Read IP address with optional prefix length: x.x.x.x or x.x.x.x/n.
sub read_ip_opt_prefixlen() {
    my $ip  = read_ip;
    my $len = undef;
    if ($input =~ m/\G\/(\d+)/gc) {
        if ($1 <= 32) {
            $len = $1;
        }
        else {
            error_atline "Prefix length must be <= 32";
        }
    }
    return $ip, $len;
}

sub gen_ip( $$$$ ) {
    return unpack 'N', pack 'C4', @_;
}

# Convert IP address from internal integer representation to
# readable string.
sub print_ip( $ ) {
    my $ip = shift;
    return sprintf "%vd", pack 'N', $ip;
}

# Generate a list of IP strings from an ref of an array of integers.
sub print_ip_aref( $ ) {
    my $aref = shift;
    return map { print_ip $_; } @$aref;
}

# Conversion from netmask to prefix and vice versa.
{

    # Initialize private variables of this block.
    my %mask2prefix;
    my %prefix2mask;
    for my $prefix (0 .. 32) {
        my $mask = 2**32 - 2**(32 - $prefix);
        $mask2prefix{$mask}   = $prefix;
        $prefix2mask{$prefix} = $mask;
    }

    # Convert a network mask to a prefix ranging from 0 to 32.
    sub mask2prefix( $ ) {
        my $mask = shift;
        if (defined(my $prefix = $mask2prefix{$mask})) {
            return $prefix;
        }
        internal_err "Network mask ", print_ip $mask, " isn't a valid prefix";
    }

    sub prefix2mask( $ ) {
        my $prefix = shift;
        if (defined(my $mask = $prefix2mask{$prefix})) {
            return $mask;
        }
        internal_err "Invalid prefix: $prefix";
    }
}

sub complement_32bit( $ ) {
    my ($ip) = @_;
    return ~$ip & 0xffffffff;
}

sub read_identifier() {
    skip_space_and_comment;
    if ($input =~ m/(\G[\w-]+)/gc) {
        return $1;
    }
    else {
        syntax_err "Identifier expected";
    }
}

# Pattrern for attribute "visible": "*" or "name*".
sub read_owner_pattern() {
    skip_space_and_comment;
    if ($input =~ m/ ( \G [\w-]* [*] ) /gcx) {
        return $1;
    }
    else {
        syntax_err "Pattern '*' or 'name*' expected";
    }
}

# Used for reading interface names and attribute 'id'.
sub read_name() {
    skip_space_and_comment;
    if ($input =~ m/(\G[^;,\s""'']+)/gc) {
        return $1;
    }
    else {
        syntax_err "String expected";
    }
}

# Used for reading RADIUS attributes.
sub read_string() {
    skip_space_and_comment;
    if ($input =~ m/\G([^;,""''\n]+)/gc) {
        return $1;
    }
    else {
        syntax_err "String expected";
    }
}

sub read_intersection();

# Object representing 'user'.
# This is only 'active' while parsing src or dst of the rule of a policy.
my $user_object = { active => 0, refcount => 0, elements => undef };

sub read_union( $ ) {
    my ($delimiter) = @_;
    my @vals;
    my $count = $user_object->{refcount};
    push @vals, read_intersection;
    my $has_user_ref   = $user_object->{refcount} > $count;
    my $user_ref_error = 0;
    while (1) {
        last if check $delimiter;
        my $comma_seen = check ',';

        # Allow trailing comma.
        last if check $delimiter;

        $comma_seen or syntax_err "Comma expected in union of values";
        $count = $user_object->{refcount};
        push @vals, read_intersection;
        $user_ref_error ||=
          $has_user_ref != ($user_object->{refcount} > $count);
    }
    $user_ref_error
      and error_atline "The sub-expressions of union equally must\n",
      " either reference 'user' or must not reference 'user'";
    return @vals;
}

# Check for xxx:xxx | router:xx@xx
sub check_typed_name() {
    skip_space_and_comment;
    my ($type) = $input =~ m/ \G (\w+) : /gcx or return undef;
    my ($name) = $type eq 'router' 
	       ? $input =~ m/ \G ( [\w-]+ (?: \@ [\w-]+ )? ) /gcx
	       : $input =~ m/ \G ( [\w-]+ ) /gcx
	       or return undef;
    return [ $type, $name ];
}

sub read_typed_name() {
    check_typed_name or syntax_err "Typed name expected";
}

{

    # user@domain or @domain or user
    my $domain_regex   = qr/@(?:[\w-]+\.)+[\w-]+/;
    my $user_regex     = qr/[\w-]+(?:\.[\w-]+)*/;
    my $user_id_regex  = qr/$user_regex(?:$domain_regex)?/;
    my $id_regex       = qr/$user_id_regex|$domain_regex/;
    my $hostname_regex = qr/(?:id:$id_regex|[\w-]+)/;

# Check for xxx:xxx or xxx:[xxx:xxx, ...]
# or interface:rrr.xxx 
# or interface:rrr.xxx.xxx 
# or interface:rrr.[xxx]
# or interface:[xxx:xxx, ...].[xxx] 
# or interface:[managed & xxx:xxx, ...].[xxx]
# or host:id:user@domain.network
#
# with rrr = xxx | xxx@xxx
    sub read_extended_name() {
        if (check 'user') {

            # Global variable for linking occurrences of 'user'.
            $user_object->{active}
              or syntax_err "Unexpected reference to 'user'";
            $user_object->{refcount}++;
            return [ 'user', $user_object ];
        }
        $input =~ m/\G([\w-]+):/gc or syntax_err "Type expected";
        my $type = $1;
        my $interface = $type eq 'interface';
        my $managed;
        my $name;
        my $ext;
        if ($type eq 'host') {

            if ($input =~ m/\G($hostname_regex)/gco) {
                $name = $1;
            }
            else {
                syntax_err "Hostname expected";
            }
        }
        elsif ($input =~ m/ \G \[ /gcox) {
            my @list;
            if ($interface && check 'managed') {
                $managed = 1;
                skip '&';
            }
            $name = [ read_union ']' ];
        }
	elsif ($interface && 
	       $input =~ m/ \G ( [\w-]+ (?: \@ [\w-]+ ) ) /gcx ||
	       $input =~ m/ \G ( [\w-]+ ) /gcx) 
	{
	    $name = $1;
	}
        else {
	    syntax_err "Identifier or '[' expected";
        }
        if ($interface) {
            $input =~ m/ \G \. /gcox or syntax_err "Expected '.'";
            if ($input =~ m/ \G \[ /gcox) {
                my $selector = read_identifier;
                $selector =~ /^(auto|all)$/ or syntax_err "Expected [auto|all]";
                $ext = [ $selector, $managed ];
                skip '\]';
            }
            else {
                $ext = read_identifier;
                if ($input =~ m/ \G \. /gcox) {
                    $ext .= '.' . read_identifier;
                }
                $managed
                  and syntax_err "Keyword 'managed' not allowed";
            }
            [ $type, $name, $ext ];
        }
        else {
            [ $type, $name ];
        }
    }

# user@domain or user
    sub read_user_id() {
        skip_space_and_comment;
        if ($input =~ m/\G($user_id_regex)/gco) {
            return $1;
        }
        else {
            syntax_err "Id expected ('user\@domain' or 'user')";
        }
    }

# host:xxx or host:id:user@domain or host:id:@domain or host:id:user
    sub check_hostname() {
        skip_space_and_comment;
        if ($input =~ m/\G host:/gcx) {
            if ($input =~ m/\G($hostname_regex)/gco) {
                return "host:$1";
            }
            else {
                syntax_err "Hostname expected";
            }
        }
        else {
            return undef;
        }
    }
}

sub read_complement() {
    if (check '!') {
        [ '!', read_extended_name ];
    }
    else {
        read_extended_name;
    }
}

sub read_intersection() {
    my @result = read_complement;
    while (check '&') {
        push @result, read_complement;
    }
    if (@result == 1) {
        $result[0];
    }
    else {
        [ '&', \@result ];
    }
}

# Setup standard time units with different names and plural forms.
my %timeunits = (sec => 1, min => 60, hour => 3600, day => 86400,);
$timeunits{second} = $timeunits{sec};
$timeunits{minute} = $timeunits{min};
for my $key (keys %timeunits) {
    $timeunits{"${key}s"} = $timeunits{$key};
}

# Read time value in different units, return seconds.
sub read_time_val() {
    my $int    = read_int;
    my $unit   = read_identifier;
    my $factor = $timeunits{$unit} or syntax_err "Invalid time unit";
    return $int * $factor;
}

sub add_description {
    my ($obj) = @_;
    skip_space_and_comment;
    check 'description' or return;
    skip '=';

    # Read up to end of line, but ignore ';' at EOL.
    # We must use '$' here to match EOL,
    # otherwise $line would be out of sync.
    $input =~ m/\G([ \t]*(.*?)[ \t]*;?[ \t]*)$/gcm;

    # Old interface for report, includes leading and trailing whitespace.
    if ($store_description) {
	$obj->{description} = $1;
    }

    # New interface without leading and trailing whitespace.
    elsif (store_description()) {
	$obj->{description} = $2;
    }
}

# Check if one of the keywords 'permit' or 'deny' is available.
sub check_permit_deny() {
    skip_space_and_comment;
    if ($input =~ m/\G(permit|deny)/gc) {
        return $1;
    }
    else {
        return undef;
    }
}

sub split_typed_name( $ ) {
    my ($name) = @_;

    # Split at first colon; the name may contain further colons.
    split /[:]/, $name, 2;
}

sub check_flag( $ ) {
    my $token = shift;
    if (check $token) {
        skip ';';
        return 1;
    }
    else {
        return undef;
    }
}

sub read_assign($&) {
    my ($token, $fun) = @_;
    skip $token;
    skip '=';
    if (wantarray) {
        my @val = &$fun;
        skip ';';
        return @val;
    }
    else {
        my $val = &$fun;
        skip ';';
        return $val;
    }
}

sub check_assign($&) {
    my ($token, $fun) = @_;
    if (check $token) {
        skip '=';
        if (wantarray) {
            my @val = &$fun;
            skip ';';
            return @val;
        }
        else {
            my $val = &$fun;
            skip ';';
            return $val;
        }
    }
    return;
}

sub read_list(&) {
    my ($fun) = @_;
    my @vals;
    while (1) {
        push @vals, &$fun;
        last if check ';';
        my $comma_seen = check ',';

        # Allow trailing comma.
        last if check ';';

        $comma_seen or syntax_err "Comma expected in list of values";
    }
    return @vals;
}

sub read_list_or_null(&) {
    return () if check ';';
    &read_list(@_);
}

sub read_assign_list($&) {
    my ($token, $fun) = @_;
    skip $token;
    skip '=';
    &read_list($fun);
}

sub check_assign_list($&) {
    my ($token, $fun) = @_;
    if (check $token) {
        skip '=';
        return &read_list($fun);
    }
    return ();
}

sub check_assign_range($&) {
    my ($token, $fun) = @_;
    if (check $token) {
        skip '=';
        my $v1 = &$fun;
        skip '-';
        my $v2 = &$fun;
        skip ';';
        return $v1, $v2;
    }
    return ();
}

# Delete an element from an array reference.
# Return 1 if found, 0 otherwise.
sub aref_delete( $$ ) {
    my ($aref, $elt) = @_;
    for (my $i = 0 ; $i < @$aref ; $i++) {
        if ($aref->[$i] eq $elt) {
            splice @$aref, $i, 1;

#debug "aref_delete: $elt->{name}";
            return 1;
        }
    }
    return 0;
}

# Compare two array references element wise.
sub aref_eq ( $$ ) {
    my ($a1, $a2) = @_;
    return 0 if @$a1 ne @$a2;
    for (my $i = 0; $i < @$a1; $i++) {
        return 0 if $a1->[$i] ne $a2->[$i];
    }
    return 1;
}

# Unique union of all elements.
sub unique(@) {
	return values %{ {map { $_ => $_ } @_}}; 
}

####################################################################
# Creation of typed structures
# Currently we don't use OO features;
# We use 'bless' only to give each structure a distinct type.
####################################################################

# Create a new structure of given type;
# initialize it with key / value pairs.
sub new( $@ ) {
    my $type = shift;
    my $self = {@_};
    return bless $self, $type;
}

our %hosts;

# A single host which gets the attribute {policy_distribution_point}
# is stored here.
# This is typically the netspoc server or some other server
# which is used to distribute the generated configuration files
# to managed devices.
my $policy_distribution_point;

sub check_radius_attributes() {
    my $result = {};
    check 'radius_attributes'
      or return undef;
    skip '=';
    skip '{';
    while (1) {
        last if check '}';
        my $key = read_identifier;
        skip '=';
        my $val = read_string;
        skip ';';
        $result->{$key} and error_atline "Duplicate attribute '$key'";
        $result->{$key} = $val;
    }
    return $result;
}

sub read_host( $$ ) {
    my ($name, $network_name) = @_;
    my $host = new('Host');
    $host->{private} = $private if $private;
    if (my ($id) = ($name =~ /^host:id:(.*)$/)) {

        # Make ID unique by appending name of enclosing network.
        $name = "$name.$network_name";
        $host->{id} = $id;
    }
    $host->{name} = $name;
    skip '=';
    skip '{';
    add_description($host);
    while (1) {
        last if check '}';
        if (my $ip = check_assign 'ip', \&read_ip) {
            $host->{ip} and error_atline "Duplicate attribute 'ip'";
            $host->{ip} = $ip;
        }
        elsif (my ($ip1, $ip2) = check_assign_range 'range', \&read_ip) {
            $ip1 <= $ip2 or error_atline "Invalid IP range";
            $host->{range} and error_atline "Duplicate attribute 'range'";
            $host->{range} = [ $ip1, $ip2 ];
        }
        elsif (my $owner = check_assign 'owner', \&read_identifier) {
            $host->{owner} and error_atline "Duplicate attribute 'owner'";
            $host->{owner} = $owner;
        }
        elsif (my $radius_attributes = check_radius_attributes) {
            $host->{radius_attributes}
              and error_atline "Duplicate attribute 'radius_attributes'";
            $host->{radius_attributes} = $radius_attributes;
        }
        elsif (check_flag 'policy_distribution_point') {
            $policy_distribution_point
              and error_atline
              "'policy_distribution_point' must be defined only once";
            $policy_distribution_point = $host;
        }
        elsif (my $pair = check_typed_name) {
            my ($type, $name) = @$pair;
            if ($type eq 'nat') {
                skip '=';
                skip '{';
                skip 'ip';
                skip '=';
                my $nat_ip = read_ip;
                skip ';';
                skip '}';
                $host->{nat}->{$name}
                  and error_atline "Duplicate NAT definition";
                $host->{nat}->{$name} = $nat_ip;
            }
            else {
                syntax_err "Expected NAT definition";
            }
        }
        else {
            syntax_err "Unexpected attribute";
        }
    }
    $host->{ip} xor $host->{range}
      or error_atline "Exactly one of attributes 'ip' and 'range' is needed";

    if ($host->{id}) {
        $host->{radius_attributes} ||= {};
    }
    else {
        $host->{radius_attributes}
          and error_atline
          "Attribute 'radius_attributes' is not allowed for $name";
    }
    if ($host->{nat}) {
        if ($host->{range}) {

            # Look at print_pix_static before changing this.
            error_atline "No NAT supported for host with IP range";
        }
    }
    return $host;
}

sub read_nat( $ ) {
    my $name = shift;

    # Currently this needs not to be blessed.
    my $nat = { name => $name };
    (my $nat_tag = $name) =~ s/^nat://;
    skip '=';
    skip '{';
    while (1) {
        last if check '}';
        if (my ($ip, $prefixlen) = check_assign 'ip', \&read_ip_opt_prefixlen) {
            if ($prefixlen) {
                my $mask = prefix2mask $prefixlen;
                $nat->{mask} and error_atline "Duplicate IP mask";
                $nat->{mask} = $mask;
            }
            $nat->{ip} and error_atline "Duplicate IP address";
            $nat->{ip} = $ip;
        }
        elsif (my $mask = check_assign 'mask', \&read_ip) {
            $nat->{mask} and error_atline "Duplicate IP mask";
            $nat->{mask} = $mask;
        }
        elsif (check_flag 'hidden') {
            $nat->{hidden} = 1;
        }
        elsif (check_flag 'dynamic') {

            # $nat_tag is used later to look up static translation
            # of hosts inside a dynamically translated network.
            $nat->{dynamic} = $nat_tag;
        }
        elsif (my $pair = check_assign 'subnet_of', \&read_typed_name) {
            $nat->{subnet_of}
              and error_atline "Duplicate attribute 'subnet_of'";
            $nat->{subnet_of} = $pair;
        }
        else {
            syntax_err "Expected some valid NAT attribute";
        }
    }
    if ($nat->{hidden}) {
	for my $key (keys %$nat) {
	    next if grep { $key eq $_ } qw( name hidden);
	    error_atline "Hidden NAT must not use attribute $key";
	}

	# This simplifies error checks for overlapping addresses.
	$nat->{dynamic} = $nat_tag;
    }
    else {
	$nat->{ip} or error_atline "Missing IP address";
    }
    return $nat;
}

our %networks;

sub read_network( $ ) {
    my $name = shift;

    # Network name without prefix "network:" is needed to build
    # name of ID-hosts.
    (my $net_name = $name) =~ s/^network://;
    my $network = new('Network', name => $name);
    $network->{private} = $private if $private;
    skip '=';
    skip '{';
    add_description($network);
    while (1) {
        last if check '}';
        if (my ($ip, $prefixlen) = check_assign 'ip', \&read_ip_opt_prefixlen) {
            if (defined $prefixlen) {
                my $mask = prefix2mask $prefixlen;
                defined $network->{mask} and error_atline "Duplicate IP mask";
                $network->{mask} = $mask;
            }
            $network->{ip} and error_atline "Duplicate IP address";
            $network->{ip} = $ip;
        }
        elsif (defined(my $mask = check_assign 'mask', \&read_ip)) {
            defined $network->{mask} and error_atline "Duplicate IP mask";
            $network->{mask} = $mask;
        }
        elsif (check_flag 'unnumbered') {
            defined $network->{ip} and error_atline "Duplicate IP address";
            $network->{ip} = 'unnumbered';
        }
        elsif (check_flag 'route_hint') {

            # Duplicate use of this flag doesn't matter.
            $network->{route_hint} = 1;
        }
        elsif (check_flag 'crosslink') {

            # Duplicate use of this flag doesn't matter.
            $network->{crosslink} = 1;
        }
        elsif (check_flag 'isolated_ports') {

            # Duplicate use of this flag doesn't matter.
            $network->{isolated_ports} = 1;
        }
        elsif (my $id = check_assign 'id', \&read_user_id) {
            $network->{id}
              and error_atline "Duplicate attribute 'id'";
            $network->{id} = $id;
        }
        elsif (my $pair = check_assign 'subnet_of', \&read_typed_name) {
            $network->{subnet_of}
              and error_atline "Duplicate attribute 'subnet_of'";
            $network->{subnet_of} = $pair;
        }
        elsif (my $owner = check_assign 'owner', \&read_identifier) {
            $network->{owner}
              and error_atline "Duplicate attribute 'owner'";
            $network->{owner} = $owner;
        }
        elsif (my $radius_attributes = check_radius_attributes) {
            $network->{radius_attributes}
              and error_atline "Duplicate attribute 'radius_attributes'";
            $network->{radius_attributes} = $radius_attributes;
        }
        elsif (my $string = check_hostname) {
            my $host = read_host $string, $net_name;
            push @{ $network->{hosts} }, $host;
            my ($dummy, $host_name) = split_typed_name $host->{name};
            $hosts{$host_name} and error_atline "Duplicate host:$host_name";
            $hosts{$host_name} = $host;
        }
        else {
            my $pair = read_typed_name;
            my ($type, $nat_name) = @$pair;
            if ($type eq 'nat') {
                my $nat = read_nat "nat:$nat_name";
		$nat->{name} .= "($name)";
                $network->{nat}->{$nat_name}
                  and error_atline "Duplicate NAT definition";
                $network->{nat}->{$nat_name} = $nat;
            }
            else {
                syntax_err "Expected NAT or host definition";
            }
        }
    }

    # Network needs at least IP and mask to be defined.
    my $ip = $network->{ip};

    # Use 'defined' here because IP may have value '0'.
    defined $ip or syntax_err "Missing network IP";
    if ($ip eq 'unnumbered') {

        # Unnumbered network must not have any other attributes.
        for my $key (keys %$network) {
            next if $key eq 'ip' or $key eq 'name';
            error_atline "Unnumbered $network->{name} must not have ",
                ($key eq 'hosts') ? "host definition"
              : ($key eq 'nat')   ? "nat definition"
              :                     "attribute '$key'";
        }
    }
    else {
        my $mask = $network->{mask};

        # Use 'defined' here because mask may have value '0'.
        defined $mask or syntax_err "Missing network mask";

        # Check if network IP matches mask.
        if (($ip & $mask) != $ip) {
            error_atline "IP and mask don't match";

            # Prevent further errors.
            $network->{ip} &= $mask;
        }
        for my $host (@{ $network->{hosts} }) {

            # Link host with network.
            $host->{network} = $network;

            # Check compatibility of host IP and network IP/mask.
            if (my $host_ip = $host->{ip}) {
		if ($ip != ($host_ip & $mask)) {
		    error_atline
			"$host->{name}'s IP doesn't match network IP/mask";
                }
            }
            elsif ($host->{range}) {
                my ($ip1, $ip2) = @{ $host->{range} };
                if (   $ip != ($ip1 & $mask)
                    or $ip != ($ip2 & $mask))
                {
                    error_atline "$host->{name}'s IP range doesn't match",
                      " network IP/mask";
                }
            }
            else {
                internal_err;
            }

            # Compatibility of host and network NAT will be checked later,
            # after global NAT definitions have been processed.
        }
        if (@{ $network->{hosts} } and $network->{crosslink}) {
            error_atline "Crosslink network must not have host definitions";
        }
        if ($network->{nat}) {
	    $network->{isolated_ports} and 
		error_atline("Attribute 'isolated_ports' isn't supported",
			     " together with NAT");

	    # Check NAT definitions.
            for my $nat (values %{ $network->{nat} }) {
		next if $nat->{hidden};
                if (defined $nat->{mask}) {
                    unless ($nat->{dynamic}) {
                        $nat->{mask} == $mask
                          or error_atline "Mask for non dynamic $nat->{name}",
                          " must be equal to network mask";
                    }
                }
                else {

                    # Inherit mask from network.
                    $nat->{mask} = $mask;
                }

                # Check if IP matches mask.
                if (($nat->{ip} & $nat->{mask}) != $nat->{ip}) {
                    error_atline "IP for $nat->{name} of doesn't",
                      " match its mask";

                    # Prevent further errors.
                    $nat->{ip} &= $nat->{mask};
                }
            }
        }

        # Check and mark networks with ID-hosts.
        if (my $id_hosts_count = grep { $_->{id} } @{ $network->{hosts} }) {

            # If one host has ID, all hosts must have ID.
            @{ $network->{hosts} } == $id_hosts_count
              or error_atline "All hosts must have ID in $name";

            # Mark network.
            $network->{has_id_hosts} = 1;

            $network->{id}
              and error_atline
              "Must not use attribute 'id' at $network->{name}\n",
              " when hosts with ID are defined inside";
        }
        if ($network->{id} or $network->{has_id_hosts}) {
            $network->{radius_attributes} ||= {};
        }
        else {
            $network->{radius_attributes}
              and error_atline
              "Attribute 'radius_attributes' is not allowed for $name";
        }
    }
    return $network;
}

# Definition of dynamic routing protocols.
# Services below need not to be ordered using order_services
# since they are only used at code generation time.
my %routing_info = (
    EIGRP => {
        name  => 'EIGRP',
        srv   => { name => 'auto_srv:EIGRP', proto => 88 },
        mcast => [
            new(
                'Network',
                name => "auto_network:EIGRP_multicast",
                ip   => gen_ip(224, 0, 0, 10),
                mask => gen_ip(255, 255, 255, 255)
            )
        ]
    },
    OSPF => {
        name  => 'OSPF',
        srv   => { name => 'auto_srv:OSPF', proto => 89 },
        mcast => [
            new(
                'Network',
                name => "auto_network:OSPF_multicast5",
                ip   => gen_ip(224, 0, 0, 5),
                mask => gen_ip(255, 255, 255, 255),
            ),
            new(
                'Network',
                name => "auto_network:OSPF_multicast6",
                ip   => gen_ip(224, 0, 0, 6),
                mask => gen_ip(255, 255, 255, 255)
            )
        ]
    },
    manual => { name => 'manual' },
);

# Definition of redundancy protocols.
my %xxrp_info = (
    VRRP => {
        srv   => { name => 'auto_srv:VRRP', proto => 112 },
        mcast => new(
            'Network',
            name => "auto_network:VRRP_multicast",
            ip   => gen_ip(224, 0, 0, 18),
            mask => gen_ip(255, 255, 255, 255)
        )
    },
    HSRP => {
        srv => {
            name      => 'auto_srv:HSRP',
            proto     => 'udp',
            src_range => {
                name  => 'auto_srv:HSRP',
                proto => 'udp',
                range => [ 1, 65535 ]
            },
            dst_range => {
                name  => 'auto_srv:HSRP',
                proto => 'udp',
                range => [ 1985, 1985 ]
            }
        },
        mcast => new(
            'Network',
            name => "auto_network:HSRP_multicast",
            ip   => gen_ip(224, 0, 0, 2),
            mask => gen_ip(255, 255, 255, 255)
        )
    }
);

our %interfaces;
my @virtual_interfaces;
my $global_active_pathrestriction = new(
    'Pathrestriction',
    name        => 'global_pathrestriction',
    active_path => 1
);

# Tunnel networks which are already attached to tunnel interfaces
# at spoke devices. Key is crypto name, not crypto object.
my %crypto2spokes;

# Real interfaces at crypto hub, where tunnels are attached.
# Key is crypto name, not crypto object.
my %crypto2hubs;

sub read_interface( $ ) {
    my ($name) = @_;
    my $interface = new('Interface', name => $name);

    # Short form of interface definition.
    if (not check '=') {
        skip ';';
        $interface->{ip} = 'short';
        return $interface;
    }

    my @secondary_interfaces = ();
    my $virtual;
    skip '{';
    add_description($interface);
    while (1) {
        last if check '}';
        if (my @ip = check_assign_list 'ip', \&read_ip) {
            $interface->{ip} and error_atline "Duplicate attribute 'ip'";
            $interface->{ip} = shift @ip;

            # Build interface objects for secondary IP addresses.
            # These objects are named interface:router.name.2, ...
            my $counter = 2;
            for my $ip (@ip) {
                push @secondary_interfaces,
                  new('Interface', name => "$name.$counter", ip => $ip);
                $counter++;
            }
        }
        elsif (check_flag 'unnumbered') {
            $interface->{ip} and error_atline "Duplicate attribute 'ip'";
            $interface->{ip} = 'unnumbered';
        }
        elsif (check_flag 'negotiated') {
            $interface->{ip} and error_atline "Duplicate attribute 'ip'";
            $interface->{ip} = 'negotiated';
        }
        elsif (check_flag 'loopback') {
            $interface->{loopback} = 1;
        }
        elsif (check_flag 'no_in_acl') {
            $interface->{no_in_acl} = 1;
        }

        # Needed for the implicitly defined network of 'loopback'.
        elsif (my $pair = check_assign 'subnet_of', \&read_typed_name) {
            $interface->{subnet_of}
              and error_atline "Duplicate attribute 'subnet_of'";
            $interface->{subnet_of} = $pair;
        }
        elsif (my @pairs = check_assign_list 'hub', \&read_typed_name) {
	    for my $pair (@pairs) {
		my ($type, $name2) = @$pair;
		$type eq 'crypto' or error_atline "Expected type crypto";
		push @{$interface->{hub}}, "$type:$name2";
	    }
        }
        elsif ($pair = check_assign 'spoke', \&read_typed_name) {
            my ($type, $name2) = @$pair;
            $type eq 'crypto' or error_atline "Expected type crypto";
            $interface->{spoke} and error_atline "Duplicate attribute 'spoke'";
            $interface->{spoke} = "$type:$name2";
        }
        elsif ($pair = check_typed_name) {
            my ($type, $name2) = @$pair;
            if ($type eq 'nat') {
                skip '=';
                skip '{';
                skip 'ip';
                skip '=';
                my $nat_ip = read_ip;
                skip ';';
                skip '}';
                $interface->{nat}->{$name2}
                  and error_atline "Duplicate NAT definition";
                $interface->{nat}->{$name2} = $nat_ip;
            }
            elsif ($type eq 'secondary') {

                # Build new interface for secondary IP addresses.
                my $secondary = new('Interface', name => "$name.$name2");
                skip '=';
                skip '{';
                while (1) {
                    last if check '}';
                    if (my $ip = check_assign 'ip', \&read_ip) {
                        $secondary->{ip}
                          and error_atline "Duplicate IP address";
                        $secondary->{ip} = $ip;
                    }
                    else {
                        syntax_err "Expected attribute IP";
                    }
                }
                $secondary->{ip} or error_atline "Missing IP address";
                push @secondary_interfaces, $secondary;
            }
            else {
                syntax_err "Expected nat or secondary interface definition";
            }
        }
        elsif (check 'virtual') {
            $virtual and error_atline "Duplicate virtual interface";

            # Read attributes of redundancy protocol (VRRP/HSRP).
            $virtual = new('Interface', name => "$name.virtual");
            skip '=';
            skip '{';
            while (1) {
                last if check '}';
                if (my $ip = check_assign 'ip', \&read_ip) {
                    $virtual->{ip}
                      and error_atline "Duplicate virtual IP address";
                    $virtual->{ip} = $ip;
                }
                elsif (my $type = check_assign 'type', \&read_name) {
                    $xxrp_info{$type}
                      or error_atline "Unknown redundancy protocol";
                    $virtual->{redundancy_type}
                      and error_atline "Duplicate redundancy type";
                    $virtual->{redundancy_type} = $type;
                }
                elsif (my $id = check_assign 'id', \&read_name) {
                    $id =~ /^\d+$/
                      or error_atline "Redundancy ID must be numeric";
                    $id < 256 or error_atline "Redundancy ID must be < 256";
                    $virtual->{redundancy_id}
                      and error_atline "Duplicate redundancy ID";
                    $virtual->{redundancy_id} = $id;
                }
                else {
                    syntax_err "Expected valid attribute for virtual IP";
                }
            }
            $virtual->{ip} or error_atline "Missing virtual IP";
            $virtual->{redundancy_type}
              or error_atline "Missing type of redundancy protocol";
        }
        elsif (my @tags = check_assign_list 'bind_nat', \&read_identifier) {
            $interface->{bind_nat} and error_atline "Duplicate NAT binding";
            $interface->{bind_nat} = [ unique sort @tags ];
        }
        elsif (my $hardware = check_assign 'hardware', \&read_name) {
            $interface->{hardware}
              and error_atline "Duplicate definition of hardware";
            $interface->{hardware} = $hardware;
        }
        elsif (my $protocol = check_assign 'routing', \&read_name) {
            my $routing = $routing_info{$protocol}
              or error_atline "Unknown routing protocol";
            $interface->{routing} and error_atline "Duplicate routing protocol";
            $interface->{routing} = $routing;
        }
        elsif (@pairs = check_assign_list 'reroute_permit',
            \&read_typed_name)
        {
            $interface->{reroute_permit}
              and error_atline 'Duplicate definition of reroute_permit';
            $interface->{reroute_permit} = \@pairs;
        }
        elsif (check_flag 'disabled') {
            $interface->{disabled} = 1;
        }
        elsif (check_flag 'no_check') {
            $interface->{no_check} = 1;
        }
        elsif (check_flag 'promiscuous_port') {
            $interface->{promiscuous_port} = 1;
        }
        else {
            syntax_err 'Expected some valid attribute';
        }
    }

    # Swap virtual interface and main interface
    # or take virtual interface as main interface if no main IP available.
    # Subsequent code becomes simpler if virtual interface is main interface.
    if ($virtual) {
        if (my $ip = $interface->{ip}) {
            if ($ip =~ /unnumbered|negotiated|short/) {
                error_atline "No virtual IP supported for $ip interface";
            }

            # Move main IP to secondary.
            my $secondary =
              new('Interface', name => $interface->{name}, ip => $ip);
            push @secondary_interfaces, $secondary;

            # But we need the original main interface when handling auto interfaces.
            $interface->{orig_main} = $secondary;
        }
        @{$interface}{qw(name ip redundancy_type redundancy_id)} =
          @{$virtual}{qw(name ip redundancy_type redundancy_id)};
        push @virtual_interfaces, $interface;
    }
    else {
        $interface->{ip} ||= 'short';
    }
    if ($interface->{nat}) {
        if ($interface->{ip} =~ /unnumbered|negotiated|short/) {
            error_atline "No NAT supported for $interface->{ip} interface";
        }
    }
    if ($interface->{loopback}) {
        my %copy = %$interface;

        # Only these attributes are valid.
        delete @copy{
            qw(name ip nat bind_nat hardware loopback subnet_of
              redundancy_type redundancy_id)
          };
        if (keys %copy) {
            my $attr = join ", ", map "'$_'", keys %copy;
            error_atline "Invalid attributes $attr for loopback interface";
        }
        if ($interface->{ip} =~ /unnumbered|negotiated|short/) {
            error_atline "Loopback interface must not be $interface->{ip}";
        }
    }
    elsif ($interface->{subnet_of}) {
        error_atline
          "Attribute 'subnet_of' is only valid for loopback interface";
    }
    if (my $crypto = $interface->{spoke}) {
	@secondary_interfaces
	    and error_atline "Interface with attribute 'spoke'",
	    " must not have secondary interfaces";
	$interface->{hub}
	  and error_atline "Interface with attribute 'spoke'",
	  " must not have attribute 'hub'";
    }
    if (my $hubs = $interface->{hub}) {
        if ($interface->{ip} =~ /unnumbered|negotiated|short/) {
            error_atline "Crypto hub must not be $interface->{ip} interface";
        }
	for my $crypto (@$hubs) {
	    push @{ $crypto2hubs{$crypto} }, $interface;
	}
    }
    for my $secondary (@secondary_interfaces) {
        $secondary->{main_interface} = $interface;
        $secondary->{hardware}       = $interface->{hardware};
        $secondary->{bind_nat}       = $interface->{bind_nat};
        $secondary->{disabled}       = $interface->{disabled};

        # No traffic must pass secondary interface.
        # If secondary interface is start- or endpoint of a path,
        # the corresponding router is entered by main interface.
        push @{ $secondary->{path_restrict} }, $global_active_pathrestriction;
    }
    return $interface, @secondary_interfaces;
}

# PIX firewalls have a security level associated with each interface.
# We don't want to expand our syntax to state them explicitly,
# but instead we try to derive the level from the interface name.
# It is not necessary the find the exact level; what we need to know
# is the relation of the security levels to each other.
sub set_pix_interface_level( $ ) {
    my ($router) = @_;
    for my $hardware (@{ $router->{hardware} }) {
        my $hwname = $hardware->{name};
        my $level;
        if ($hwname eq 'inside') {
            $level = 100;
        }
        elsif ($hwname eq 'outside') {
            $level = 0;
        }
        else {
            unless (($level) =
                    ($hwname =~ /(\d+)$/)
                and 0 < $level
                and $level < 100)
            {
                err_msg "Can't derive PIX security level for ",
                  "$hardware->{interfaces}->[0]->{name}\n",
                  " Interface name should contain a number",
                  " which is used as level";
                $level = 0;
            }
        }
        $hardware->{level} = $level;
    }
}

# Routers which reference one or more RADIUS servers.
my @radius_routers;

my $bind_nat0 = [];

our %routers;

sub read_router( $ ) {
    my $name = shift;

    # Extract
    # - router name without prefix "router:", needed to build interface name
    # - optional vrf name
    my ($rname, $device_name, $vrf) = 
	$name =~ /^ router : ( (.*?) (?: \@ (.*) )? ) $/x;
    my $router = new('Router', name => $name, device_name => $device_name);
    $router->{vrf} = $vrf if $vrf;
    skip '=';
    skip '{';
    add_description($router);
    while (1) {
        last if check '}';
        if (check 'managed') {
            $router->{managed}
              and error_atline "Redefining 'managed' attribute";
            my $managed;
            if (check ';') {
                $managed = 'standard';
            }
            elsif (check '=') {
                my $value = read_identifier;
                if ($value =~ /^(?:secondary|standard|full|primary)$/) {
                    $managed = $value;
                }
                else {
                    error_atline
                      "Expected value: secondary|standard|full|primary";
                }
                check ';';
            }
            else {
                syntax_err "Expected ';' or '='";
            }
            $router->{managed} = $managed;
        }
        elsif (my ($model, @attributes) = check_assign_list 'model',
            \&read_identifier)
        {
            my @attr2;
            ($model, @attr2) = split /_/, $model;
            push @attributes, @attr2;
            $router->{model} and error_atline "Redefining 'model' attribute";
            my $info = $router_info{$model};
            if (not $info) {
                error_atline "Unknown router model";
                next;
            }
            my $extension_info = $info->{extension};
            if (@attributes and not $extension_info) {
                error_atline "Unexpected extension for this model";
                next;
            }

            my @ext_list = map {
                my $ext = $extension_info->{$_};
                $ext or error_atline "Unknown extension $_";
                $ext ? %$ext : ();
            } @attributes;
            if (@ext_list) {
                $info = { %$info, @ext_list };
                delete $info->{extension};
            }
            $router->{model} = $info;
        }
        elsif (check_flag 'no_group_code') {
            $router->{no_group_code} = 1;
        }
        elsif (check_flag 'no_crypto_filter') {
            $router->{no_crypto_filter} = 1;
        }
        elsif (check_flag 'std_in_acl') {
            $router->{std_in_acl} = 1;
        }
        elsif (my $owner = check_assign 'owner', \&read_identifier) {
            $router->{owner} and error_atline "Duplicate attribute 'owner'";
            $router->{owner} = $owner;
        }
        elsif (my @pairs = check_assign_list 'radius_servers',
            \&read_typed_name)
        {
            $router->{radius_servers}
              and error_atline "Redefining 'radius' attribute";
            $router->{radius_servers} = \@pairs;
            push @radius_routers, $router;
        }
        elsif (my $radius_attributes = check_radius_attributes) {
            $router->{radius_attributes}
              and error_atline "Duplicate attribute 'radius_attributes'";
            $router->{radius_attributes} = $radius_attributes;
        }
        else {
            my $pair = read_typed_name;
            my ($type, $network) = @$pair;
            $type eq 'interface'
              or syntax_err "Expected interface definition";

            # Derive interface name from router name.
            my $iname = "$rname.$network";
            for my $interface (read_interface "interface:$iname") {
                push @{ $router->{interfaces} }, $interface;
                ($iname = $interface->{name}) =~ s/interface://;
                if ($interfaces{$iname}) {
                    error_atline "Redefining $interface->{name}";
                }

                # Assign interface to global hash of interfaces.
                $interfaces{$iname} = $interface;

                # Link interface with router object.
                $interface->{router} = $router;

		# Link interface with network name (will be resolved later).
		$interface->{network} = $network;

                # Set private attribute of interface.
                # If a loopback network is created below it doesn't need to get
                # this attribute because the network can't be referenced.
                $interface->{private} = $private if $private;

                # Automatically create a network for loopback interface.
                if ($interface->{loopback}) {
                    my $name;
                    my $net_name;

                    # Special handling needed for virtual loopback interfaces.
                    # The created network needs to be shared among a group of
                    # interfaces.
                    if (my $virtual = $interface->{redundancy_type}) {

                        # Shared virtual loopback network gets name
                        # 'virtual:netname'. Don't use standard name to prevent
                        # network from getting referenced from rules.
                        $net_name = "virtual:$network";
                        $name     = "network:$net_name";
                    }
                    else {

                        # Single loopback network needs not to get an unique name.
                        # Take an invalid name 'router.loopback' to prevent name
                        # clashes with real networks or other loopback networks.
                        $name = $interface->{name};
                        ($net_name = $name) =~ s/^interface://;
                    }
                    if (not $networks{$net_name}) {
                        $networks{$net_name} = new(
                            'Network',
                            name => $name,
                            ip   => $interface->{ip},
                            mask => 0xffffffff,

                            # Mark as automatically created.
                            loopback  => 1,
                            subnet_of => delete $interface->{subnet_of}
                        );
                    }
                    $interface->{network} = $net_name;
                }

		# Generate tunnel interface.
		elsif (my $crypto = $interface->{spoke}) {
		    my $net_name    = "tunnel:$rname";
		    my $iname = "$rname.$net_name";
		    my $tunnel_intf = new(
					  'Interface',
					  name           => "interface:$iname",
					  ip             => 'tunnel',
					  router         => $router,
					  network        => $net_name,
					  real_interface => $interface
					  );
		    for my $key (qw(hardware routing private bind_nat)) {
			if ($interface->{$key}) {
			    $tunnel_intf->{$key} = $interface->{$key} 
			}
		    }
		    if ($interfaces{$iname}) {
			error_atline "Redefining $tunnel_intf->{name}";
		    }
		    $interfaces{$iname} = $tunnel_intf;
		    push @{ $router->{interfaces} }, $tunnel_intf;

		    # Create tunnel network.
		    my $tunnel_net = new(
					 'Network',
					 name => "network:$net_name",
					 ip   => 'tunnel'
					 );
		    $networks{$net_name} = $tunnel_net;

		    # Tunnel network will later be attached to crypto hub.
		    push @{ $crypto2spokes{$crypto} }, $tunnel_net;
		}
            }
        }
    }

    # Detailed interface processing for managed routers.
    if (my $managed = $router->{managed}) {
        my $model = $router->{model};

        unless ($model) {
            err_msg "Missing 'model' for managed $router->{name}";

            # Prevent further errors.
            $router->{model} = { name => 'unknown' };
        }
	
	$router->{vrf} and not $model->{can_vrf} and
	    err_msg("Must not use VRF at $router->{name}",
		    " of type $model->{name}");

        # Create objects representing hardware interfaces.
        # All logical interfaces using the same hardware are linked
        # to the same hardware object.
        my %hardware;
        for my $interface (@{ $router->{interfaces} }) {
            if (my $hw_name = $interface->{hardware}) {
                my $hardware;
                if ($hardware = $hardware{$hw_name}) {

                    # All logical interfaces of one hardware interface
                    # need to use the same NAT binding,
                    # because NAT operates on hardware, not on logic.
                    aref_eq($interface->{bind_nat} || $bind_nat0, 
                            $hardware->{bind_nat} || $bind_nat0)
                      or err_msg "All logical interfaces of $hw_name\n",
                      " at $router->{name} must use identical NAT binding";
		}
                else {
                    $hardware = { name => $hw_name };
                    $hardware{$hw_name} = $hardware;
                    push @{ $router->{hardware} }, $hardware;
                    if (my $nat = $interface->{bind_nat}) {
                        $hardware->{bind_nat} = $nat;
                    }
                }
                $interface->{hardware} = $hardware;

                # Remember, which logical interfaces are bound
                # to which hardware.
                push @{ $hardware->{interfaces} }, $interface;
            }
            else {

                # Managed router must not have short interface.
                if ($interface->{ip} eq 'short') {
                    err_msg
                      "Short definition of $interface->{name} not allowed";
                }
                else {

                    # Interface of managed router needs to
                    # have a hardware name.
                    err_msg "Missing 'hardware' for $interface->{name}";
                }
            }
	    if ($interface->{hub} or $interface->{spoke}) {
		$model->{crypto}
		or err_msg "Crypto not supported for $router->{name}",
		" of type $model->{name}";
	    }
        }

        if ($router->{model}->{has_interface_level}) {
            set_pix_interface_level $router;
        }
        if ($router->{model}->{need_radius}) {
            $router->{radius_servers}
              or err_msg "Attribute 'radius_servers' needs to be defined",
              " for $router->{name}";
        }
        else {
            $router->{radius_servers}
              and err_msg "Attribute 'radius_servers' is not allowed",
              " for $router->{name}";
        }
        if ($router->{model}->{do_auth}) {

            # Don't support NAT for VPN, otherwise code generation for VPN
            # devices will become more difficult.
            grep { $_->{bind_nat} } @{ $router->{interfaces} }
              and err_msg "Attribute 'bind_nat' is not allowed",
              " at interface of $router->{name}",
              " of type $router->{model}->{name}";

            grep({ $_->{no_check} } @{ $router->{interfaces} }) >= 1
              or err_msg
              "At least one interface needs to have attribute 'no_check'",
              " at $router->{name}";

            $router->{radius_attributes} ||= {};
        }
        else {
            grep { $_->{no_check} } @{ $router->{interfaces} }
              and err_msg "Attribute 'no_check' is not allowed",
              " at interface of $router->{name}";
            $router->{radius_attributes}
              and err_msg "Attribute 'radius_attributes' is not allowed",
              " for $router->{name}";
        }
	if ($router->{model}->{no_crypto_filter}) {
	    $router->{no_crypto_filter} = 1;
	}
    }

    # Unmanaged device.
    else {
	$router->{owner} and
	    error_atline "Attribute 'owner' must only be used at",
	    " managed device";

        for my $interface (@{ $router->{interfaces} }) {
	    if ($interface->{hub}) {
                error_atline "Interface with attribute 'hub' must only be",
                  " used at managed device";
            }
	    if ($interface->{spoke}) {
		$router->{semi_managed} = 1;
	    }
	    if ($interface->{promiscuous_port}) {
		error_atline "Interface with attribute 'promiscuous_port'",
		" must only be used at managed device";
	    }
	}
    }
    return $router;
}

our %anys;

sub read_any( $ ) {
    my $name = shift;
    my $any = new('Any', name => $name);
    $any->{private} = $private if $private;
    skip '=';
    skip '{';
    add_description($any);
    while (1) {
        last if check '}';
	if (my $owner = check_assign 'owner', \&read_identifier) {
            $any->{owner}
	      and error_atline 'Duplicate definition of owner';
	    $any->{owner} = $owner;
	}
	elsif (my $link = check_assign 'link', \&read_typed_name) {
            $any->{link}
	      and error_atline 'Duplicate definition of link';
	    $any->{link} = $link;
	}
        elsif (check_flag 'no_in_acl') {
            $any->{no_in_acl} = 1;
        }
        else {
            syntax_err "Expected some valid attribute";
        }
    }
    $any->{link} or err_msg "Attribute 'link' must be defined for $name";
    return $any;
}

sub check_router_attributes() {
    my $result = {};
    check 'router_attributes'
      or return undef;
    skip '=';
    skip '{';
    while (1) {
        last if check '}';
        if (my $owner = check_assign 'owner', \&read_identifier) {
            $result->{owner} and error_atline "Duplicate attribute 'owner'";
            $result->{owner} = $owner;
        }
        else {
            syntax_err "Unexpected attribute";
        }
    }
    return $result;
}

our %areas;

sub read_area( $ ) {
    my $name = shift;
    my $area = new('Area', name => $name);
    skip '=';
    skip '{';
    add_description($area);
    while (1) {
        last if check '}';
        if (my @elements = check_assign_list 'border', \&read_intersection) {
            $area->{border}
              and error_atline 'Duplicate definition of border';
            $area->{border} = \@elements;
        }
        elsif (check_flag 'auto_border') {
            $area->{auto_border} = 1;
        }
        elsif (my $pair = check_assign 'anchor', \&read_typed_name) {
            $area->{anchor} and error_atline "Duplicate attribute 'anchor'";
            $area->{anchor} = $pair;
        }
        elsif (my $owner = check_assign 'owner', \&read_identifier) {
            $area->{owner} and error_atline "Duplicate attribute 'owner'";
            $area->{owner} = $owner;
        }
	elsif (my $router_attributes = check_router_attributes()) {
            $area->{router_attributes} and 
		error_atline "Duplicate attribute 'router_attributes'";
            $area->{router_attributes} = $router_attributes;
	}
        else {
            syntax_err "Expected some valid attribute";
        }
    }
    $area->{border}
      and $area->{anchor}
      and err_msg "Only one of attributes 'border' and 'anchor'",
      " may be defined for $name";
    $area->{anchor}
      or $area->{border}
      or err_msg "At least one of attributes 'border' and 'anchor'",
      " must be defined for $name";
    return $area;
}

our %groups;

sub read_group( $ ) {
    my $name = shift;
    skip '=';
    my $group = new('Group', name => $name);
    $group->{private} = $private if $private;
    add_description($group);
    my @elements = read_list_or_null \&read_intersection;
    $group->{elements} = \@elements;
    return $group;
}

our %servicegroups;

sub read_servicegroup( $ ) {
    my $name = shift;
    skip '=';
    my @pairs = read_list_or_null \&read_typed_name;
    return new('Servicegroup', name => $name, elements => \@pairs);
}

# Use this if src or dst port isn't defined.
# Don't allocate memory again and again.
my $aref_tcp_any = [ 1, 65535 ];

sub read_port_range() {
    if (defined(my $port1 = check_int)) {
        error_atline "Too large port number $port1" if $port1 > 65535;
        error_atline "Invalid port number '0'" if $port1 == 0;
        if (check '-') {
            if (defined(my $port2 = check_int)) {
                error_atline "Too large port number $port2" if $port2 > 65535;
                error_atline "Invalid port number '0'" if $port2 == 0;
                error_atline "Invalid port range $port1-$port2"
                  if $port1 > $port2;
                return [ $port1, $port2 ];
            }
            else {
                syntax_err "Missing second port in port range";
            }
        }
        else {
            return [ $port1, $port1 ];
        }
    }
    else {
        return $aref_tcp_any;
    }
}

sub read_port_ranges( $ ) {
    my ($srv) = @_;
    my $range = read_port_range;
    if (check ':') {
        $srv->{src_range} = $range;
        $srv->{dst_range} = read_port_range;
    }
    else {
        $srv->{src_range} = $aref_tcp_any;
        $srv->{dst_range} = $range;
    }
}

sub read_icmp_type_code( $ ) {
    my ($srv) = @_;
    if (defined(my $type = check_int)) {
        error_atline "Too large ICMP type $type" if $type > 255;
        if (check '/') {
            if (defined(my $code = check_int)) {
                error_atline "Too large ICMP code $code" if $code > 255;
                $srv->{type} = $type;
                $srv->{code} = $code;
            }
            else {
                syntax_err "Expected ICMP code";
            }
        }
        else {
            $srv->{type} = $type;
	    if ($type == 0 || $type == 3 || $type == 11) {
		$srv->{flags}->{stateless_icmp} = 1;
	    }
        }
    }
    else {

        # No type and code given.
    }
}

sub read_proto_nr( $ ) {
    my ($srv) = @_;
    if (defined(my $nr = check_int)) {
        error_atline "Too large protocol number $nr" if $nr > 255;
        error_atline "Invalid protocol number '0'"   if $nr == 0;
        if ($nr == 1) {
            $srv->{proto} = 'icmp';

            # No ICMP type and code given.
        }
        elsif ($nr == 4) {
            $srv->{proto} = 'tcp';
            $srv->{src_range} = $srv->{dst_range} = $aref_tcp_any;
        }
        elsif ($nr == 17) {
            $srv->{proto} = 'udp';
            $srv->{src_range} = $srv->{dst_range} = $aref_tcp_any;
        }
        else {
            $srv->{proto} = $nr;
        }
    }
    else {
        syntax_err "Expected protocol number";
    }
}

our %services;

sub read_service( $ ) {
    my $name = shift;
    my $service = { name => $name };
    skip '=';
    if (check 'ip') {
        $service->{proto} = 'ip';
    }
    elsif (check 'tcp') {
        $service->{proto} = 'tcp';
        read_port_ranges($service);
    }
    elsif (check 'udp') {
        $service->{proto} = 'udp';
        read_port_ranges $service;
    }
    elsif (check 'icmp') {
        $service->{proto} = 'icmp';
        read_icmp_type_code $service;
    }
    elsif (check 'proto') {
        read_proto_nr $service;
    }
    else {
        my $string = read_name;
        error_atline "Unknown protocol $string in definition of $name";
    }
    while (check ',') {
        my $flag = read_identifier;
        if ($flag =~ /^(src|dst)_(path|net|any)$/) {
            $service->{flags}->{$1}->{$2} = 1;
        }
        elsif ($flag =~ /^(?:stateless|reversed|oneway)/) {
            $service->{flags}->{$flag} = 1;
        }
        else {
            syntax_err "Unknown flag '$flag'";
        }
    }
    skip ';';
    return $service;
}

our %policies;

sub assign_union_allow_user( $ ) {
    my ($name) = @_;
    skip $name;
    skip '=';
    $user_object->{active}   = 1;
    $user_object->{refcount} = 0;
    my @result = read_union ';';
    $user_object->{active} = 0;
    return \@result, $user_object->{refcount};
}

sub read_policy( $ ) {
    my ($name) = @_;
    my $policy = { name => $name, rules => [] };
    $policy->{private} = $private if $private;
    skip '=';
    skip '{';
    add_description($policy);
    while (1) {
        last if check 'user';
	if (my @other = check_assign_list 'overlaps', \&read_typed_name) {
            $policy->{overlaps} 
	      and error_atline "Duplicate attribute 'overlaps'";
	    $policy->{overlaps} = \@other;
	}
	elsif (my $visible = check_assign('visible', \&read_owner_pattern)) {
            $policy->{visible} 
	      and error_atline "Duplicate attribute 'visible'";
	    $policy->{visible} = $visible;
	}
	elsif (my $multi_owner = check_flag('multi_owner')) {
            $policy->{multi_owner} 
	      and error_atline "Duplicate attribute 'multi_owner'";
	    $policy->{multi_owner} = $multi_owner;
	}
	elsif (my $unknown_owner = check_flag('unknown_owner')) {
            $policy->{unknown_owner} 
	      and error_atline "Duplicate attribute 'unknown_owner'";
	    $policy->{unknown_owner} = $unknown_owner;
	}
        else {
            syntax_err "Expected some valid attribute or definition of 'user'";
        }
    }
	
    # 'user' has already been read above.
    skip '=';
    if (check 'foreach') {
        $policy->{foreach} = 1;
    }
    my @elements = read_list \&read_intersection;
    $policy->{user} = \@elements;

    while (1) {
        last if check '}';
        if (my $action = check_permit_deny) {
            my ($src, $src_user) = assign_union_allow_user 'src';
            my ($dst, $dst_user) = assign_union_allow_user 'dst';
            my $srv = [ read_assign_list 'srv', \&read_typed_name ];
            $src_user
              or $dst_user
              or error_atline "Rule must use keyword 'user'";
            if ($policy->{foreach} and not($src_user and $dst_user)) {
                warn_msg "Rule of $name should reference 'user'",
                  " in 'src' and 'dst'\n",
                  " because policy has keyword 'foreach'";
            }
            my $rule = {
                policy => $policy,
                action => $action,
                src    => $src,
                dst    => $dst,
                srv    => $srv,
		has_user => $src_user ? $dst_user ? 'both' : 'src' : 'dst',
            };
            push @{ $policy->{rules} }, $rule;
        }
        else {
            syntax_err "Expected 'permit' or 'deny'";
        }
    }
    return $policy;
}

our %global;

sub read_global( $ ) {
    my ($name) = @_;
    skip '=';
    (my $action = $name) =~ s/^global://;
    $action eq 'permit' or error_atline "Unexpected name, use 'global:permit'";
    my $srv = [ read_list \&read_typed_name ];
    return { name   => $name,
	     action => $action,
	     srv    => $srv };
}

our %pathrestrictions;

sub read_pathrestriction( $ ) {
    my $name = shift;
    skip '=';
    my $restriction = new('Pathrestriction', name => $name);
    $restriction->{private} = $private if $private;
    add_description($restriction);
    my @elements = read_list \&read_intersection;
    $restriction->{elements} = \@elements;
    return $restriction;
}

our %global_nat;

sub read_global_nat( $ ) {
    my $name = shift;
    my $nat  = read_nat $name;
    if (defined $nat->{mask}) {
        if (($nat->{ip} & $nat->{mask}) != $nat->{ip}) {
            error_atline "Global $nat->{name}'s IP doesn't match its mask";
            $nat->{ip} &= $nat->{mask};
        }
    }
    else {
        error_atline "Missing mask for global $nat->{name}";
    }
    $nat->{dynamic}
      or error_atline "Global $nat->{name} must be dynamic";
    return $nat;
}

sub read_attributed_object( $$ ) {
    my ($name, $attr_descr) = @_;
    my $object = { name => $name };
    skip '=';
    skip '{';
    add_description($object);
    while (1) {
        last if check '}';
        my $attribute = read_identifier;
        my $val_descr = $attr_descr->{$attribute}
          or syntax_err "Unknown attribute '$attribute'";
        skip '=';
        my $val;
        if (my $values = $val_descr->{values}) {
            $val = read_identifier;
            grep { $_ eq $val } @$values
              or syntax_err "Invalid value";
        }
        elsif (my $fun = $val_descr->{function}) {
            $val = &$fun;
        }
        else {
            internal_err;
        }
        skip ';';
        $object->{$attribute} and error_atline "Duplicate attribute";
        $object->{$attribute} = $val;
    }
    for my $attribute (keys %$attr_descr) {
        my $description = $attr_descr->{$attribute};
        unless (defined $object->{$attribute}) {
            if (my $default = $description->{default}) {
                $object->{$attribute} = $default;
            }
            else {
                error_atline "Missing '$attribute' for $object->{name}";
            }
        }

        # Convert to from syntax to internal values, e.g. 'none' => undef.
        if (my $map = $description->{map}) {
            my $value = $object->{$attribute};
            if (exists $map->{$value}) {
                $object->{$attribute} = $map->{$value};
            }
        }
    }
    return $object;
}

# Some attributes are currently commented out,
# because they aren't supported by back-end currently.
my %isakmp_attributes = 
    (
     identity      => { values => [qw( address fqdn )], },
     nat_traversal => {
	 values  => [qw( on additional off )],
	 default => 'off',
	 map     => { off => undef }
     },
     authentication => { values   => [qw( preshare rsasig )], },
     encryption     => { values   => [qw( aes aes192 aes256 des 3des )], },
     hash           => { values   => [qw( md5 sha )], },
     group          => { values   => [qw( 1 2 5 )], },
     lifetime       => { function => \&read_time_val, },
     trust_point    => { function  => \&read_identifier,
			 default => 'none',
			 map     => { none => undef } },
);

our %isakmp;

sub read_isakmp( $ ) {
    my ($name) = @_;
    return read_attributed_object $name, \%isakmp_attributes;
}

my %ipsec_attributes = (
    key_exchange   => { function => \&read_typed_name, },
    esp_encryption => {
        values  => [qw( none aes aes192 aes256 des 3des )],
        default => 'none',
        map     => { none => undef }
    },
    esp_authentication => {
        values  => [qw( none md5_hmac sha_hmac )],
        default => 'none',
        map     => { none => undef }
    },
    ah => {
        values  => [qw( none md5_hmac sha_hmac )],
        default => 'none',
        map     => { none => undef }
    },
    pfs_group => {
        values  => [qw( none 1 2 5 )],
        default => 'none',
        map     => { none => undef }
    },
    lifetime => { function => \&read_time_val, },
);

our %ipsec;

sub read_ipsec( $ ) {
    my ($name) = @_;
    return read_attributed_object $name, \%ipsec_attributes;
}

our %crypto;

sub read_crypto( $ ) {
    my ($name) = @_;
    skip '=';
    skip '{';
    my $crypto = { name => $name };
    $crypto->{private} = $private if $private;
    add_description($crypto);
    while (1) {
        last if check '}';
        if (check_flag 'tunnel_all') {
            $crypto->{tunnel_all} = 1;
        }
        elsif (my $type = check_assign 'type', \&read_typed_name) {
            $crypto->{type}
              and error_atline "Redefining 'type' attribute";
            $crypto->{type} = $type;
        }
        else {
            syntax_err "Expected valid attribute";
        }
    }
    $crypto->{type} or error_atline "Missing 'type' for $name";
    $crypto->{tunnel_all}
      or error_atline "Must define attribute 'tunnel_all' for $name";
    return $crypto;
}

sub find_duplicates {
    my %dupl;
    $dupl{$_}++ for @_;
    return grep { $dupl{$_} > 1 } keys %dupl;
}

our %owners;

sub read_owner( $ ) {
    my $name  = shift;
    my $owner = new('Owner', name => $name);
    skip '=';
    skip '{';
    add_description($owner);
    while (1) {
        last if check '}';
	if ( my @admins = check_assign_list 'admins', \&read_identifier ) {
	    $owner->{admins}
	      and error_atline "Redefining 'admins' attribute";
	    $owner->{admins} = \@admins;
	}
	elsif ( my @watchers = check_assign_list 'watchers', \&read_identifier )
	{
	    $owner->{watchers}
	      and error_atline "Redefining 'watchers' attribute";
	    $owner->{watchers} = \@watchers;
	}
	elsif (check_flag 'extend_only') {
	    $owner->{extend_only} = 1;
	}
	elsif (check_flag 'extend') {
	    $owner->{extend} = 1;
	}
	else {
	    syntax_err "Expected valid attribute";
	}
    }
    $owner->{admins} or error_atline "Missing attribute 'admins'";
    if (my @duplicates = find_duplicates(@{ $owner->{admins} }, 
					  @{ $owner->{watchers} }))
    {
	error_atline "Duplicate admins: ", join(', ', @duplicates);
    }
    return $owner;
}

our %admins;

sub read_admin( $ ) {
    my $name  = shift;
    my $admin = new('Admin', name => $name);
    skip '=';
    skip '{';
    add_description($admin);
    while (1) {
        last if check '}';
	if ( my $full_name = check_assign 'name', \&read_to_semicolon ) {
	    $admin->{full_name}
	      and error_atline "Redefining 'name' attribute";
	    $admin->{full_name} = $full_name;
	}
	elsif ( my $email = check_assign 'email', \&read_to_semicolon ) {
	    $admin->{email}
	      and error_atline "Redefining 'email' attribute";

	    # Normalize email to lower case.
	    $admin->{email} = lc $email;
	}
	else {
	    syntax_err "Expected attribute 'name' or 'email'.";
	}
    }
    return $admin;
}

# For reading arbitrary names.
# Don't be greedy in regex, to prevent reading over multiple semicolons.
sub read_to_semicolon() {
    skip_space_and_comment;
    if ( $input =~ m/\G(.*?)(?=\s*;)/gco ) {
	return $1;
    }
    else {
	syntax_err "Expected string ending with semicolon!";
    }
}

my %global_type = (
    router          => [ \&read_router,          \%routers          ],
    network         => [ \&read_network,         \%networks         ],
    any             => [ \&read_any,             \%anys             ],
    area            => [ \&read_area,            \%areas            ],
    owner           => [ \&read_owner,           \%owners           ],
    admin           => [ \&read_admin,           \%admins           ],
    group           => [ \&read_group,           \%groups           ],
    service         => [ \&read_service,         \%services         ],
    servicegroup    => [ \&read_servicegroup,    \%servicegroups    ],
    policy          => [ \&read_policy,          \%policies         ],
    global          => [ \&read_global,          \%global           ],
    pathrestriction => [ \&read_pathrestriction, \%pathrestrictions ],
    nat             => [ \&read_global_nat,      \%global_nat       ],
    isakmp          => [ \&read_isakmp,          \%isakmp           ],
    ipsec           => [ \&read_ipsec,           \%ipsec            ],
    crypto          => [ \&read_crypto,          \%crypto           ],
);

sub read_netspoc() {

    # Check for global definitions.
    my $pair = check_typed_name or syntax_err '';
    my ($type, $name) = @$pair;
    my $descr = $global_type{$type}
      or syntax_err "Unknown global definition";
    my ($fun, $hash) = @$descr;
    my $result = $fun->("$type:$name");
    $result->{file} = $file;
    if ($hash->{$name}) {
        error_atline "Redefining $type:$name";
    }

    # Result is not used in this module but can be useful
    # when this function is called from outside.
    return $hash->{$name} = $result;
}

# Read input from file and process it by function which is given as argument.
sub read_file( $$ ) {
    local $file = shift;
    my $read_syntax = shift;

    # Read file as one large line.
    local $/;

    open my $fh, $file or fatal_err "Can't open $file: $!";

    # Fill buffer with content of whole file.
    # Content is implicitly freed when subroutine is left.
    local $input = <$fh>;
    close $fh;
    local $line = 1;
    while (skip_space_and_comment, pos $input != length $input) {
        &$read_syntax;
    }
}

# Try to read file 'config' in toplevel directory $path.
sub read_config {
    my ($path) = @_;
    my %result;
    my $read_config_data = sub {
	my $key = read_identifier();
	valid_config_key($key) or syntax_err "Invalid keyword";
	skip('=');
	my $val = read_identifier;
	if (my $expected = check_config_pair($key, $val)) {
	    syntax_err "Expected value matching '$expected'";
	}
	skip(';');
	$result{$key} = $val;
    };

    if (-d $path) {
	opendir(my $dh, $path) or fatal_err "Can't opendir $path: $!";
	if (grep { $_ eq 'config' } readdir $dh) {
	    $path = "$path/config";
	    read_file $path, $read_config_data;
	}
	closedir $dh;
    }
    \%result;
}

sub read_file_or_dir( $;$ ) {
    my ($path, $read_syntax) = @_;
    $read_syntax ||= \&read_netspoc;

    # Handle toplevel file.
    if ( not -d $path) {
	read_file $path, $read_syntax;
	return;
    }

    # Recursively handle non toplevel files and directories.
    # No special handling for "config", "raw" and "*.private".
    my $read_nested_files;
    $read_nested_files = sub {
	my ($path, $read_syntax) = @_;
	if (-d $path) {
	    opendir(my $dh, $path) or fatal_err "Can't opendir $path: $!";
	    while (my $file = Encode::decode($filename_encode, readdir $dh)) {
		next if $file eq '.' or $file eq '..';
		next if $file =~ m/$config{ignore_files}/o;
		my $path = "$path/$file";
		$read_nested_files->($path, $read_syntax);
	    }
	    closedir $dh;
	}
	else {
	    read_file $path, $read_syntax;
	}
    };

    # Strip trailing slash for nicer file names in messages.
    $path =~ s</$><>;

    # Handle toplevel directory.
    # Special handling for "config", "raw" and "*.private".
    opendir(my $dh, $path) or fatal_err "Can't opendir $path: $!";
    my @files = map({ Encode::decode($filename_encode, $_) } readdir $dh);

    for my $file (@files) {
    
	next if $file eq '.' or $file eq '..';
	next if $file =~ m/$config{ignore_files}/o;

	# Ignore file/directory 'raw' and 'config'.
	next if $file eq 'config' or $file eq 'raw';

	my $path = "$path/$file";

	# Handle private directories and files.
	if ($file =~ m'([^/]*)\.private$') {
	    local $private = $1;
            $read_nested_files->($path, $read_syntax);
        }
	else {
	    $read_nested_files->($path, $read_syntax);
	}
    }
    closedir $dh;
}

sub show_read_statistics() {
    my $n  = keys %networks;
    my $h  = keys %hosts;
    my $r  = keys %routers;
    my $g  = keys %groups;
    my $s  = keys %services;
    my $sg = keys %servicegroups;
    my $p  = keys %policies;
    info "Read $r routers, $n networks, $h hosts";
    info "Read $p policies, $g groups, $s services, $sg service groups";
}

##############################################################################
# Helper functions
##############################################################################

# Type checking functions
sub is_network( $ )       { ref($_[0]) eq 'Network'; }
sub is_router( $ )        { ref($_[0]) eq 'Router'; }
sub is_interface( $ )     { ref($_[0]) eq 'Interface'; }
sub is_host( $ )          { ref($_[0]) eq 'Host'; }
sub is_subnet( $ )        { ref($_[0]) eq 'Subnet'; }
sub is_any( $ )           { ref($_[0]) eq 'Any'; }
sub is_area( $ )          { ref($_[0]) eq 'Area'; }
sub is_group( $ )         { ref($_[0]) eq 'Group'; }
sub is_servicegroup( $ )  { ref($_[0]) eq 'Servicegroup'; }
sub is_objectgroup( $ )   { ref($_[0]) eq 'Objectgroup'; }
sub is_chain( $ )         { ref($_[0]) eq 'Chain'; }
sub is_autointerface( $ ) { ref($_[0]) eq 'Autointerface'; }

# Get VPN id of network object, if available.
sub get_id( $ ) {
    my ($obj) = @_;
    return $obj->{id}
      || (is_subnet $obj || is_interface $obj) && $obj->{network}->{id};
}

sub print_rule( $ ) {
    my ($rule) = @_;
    my $extra = '';
    $extra .= " $rule->{for_router}" if $rule->{for_router};
    $extra .= " stateless"           if $rule->{stateless};
    $extra .= " stateless_icmp"      if $rule->{stateless_icmp};
    my $srv = exists $rule->{orig_srv} ? 'orig_srv' : 'srv';
    my $action = $rule->{action};
    $action = $action->{name} if is_chain $action;
    return
        $action
      . " src=$rule->{src}->{name}; dst=$rule->{dst}->{name}; "
      . "srv=$rule->{$srv}->{name};$extra";
}

##############################################################################
# Order services
##############################################################################
my %srv_hash;

sub prepare_srv_ordering( $ ) {
    my ($srv) = @_;
    my $proto = $srv->{proto};
    my $main_srv;
    if ($proto eq 'tcp' or $proto eq 'udp') {

        # Convert src and dst port ranges from arrays to real service objects.
        # This is used in function expand_rules: An unexpanded rule has
        # references to TCP and UDP services with combined src and dst port
        # ranges.  An expanded rule has distinct references to src and dst
        # services with a single port range.
        for my $where ('src_range', 'dst_range') {

            # An array with low and high port.
            my $range     = $srv->{$where};
            my $key       = join ':', @$range;
            my $range_srv = $srv_hash{$proto}->{$key};
            unless ($range_srv) {
                $range_srv = {
                    name  => $srv->{name},
                    proto => $proto,
                    range => $range
                };
                $srv_hash{$proto}->{$key} = $range_srv;
            }
            $srv->{$where} = $range_srv;
        }
    }
    elsif ($proto eq 'icmp') {
        my $type = $srv->{type};
        my $code = $srv->{code};
        my $key  = defined $type ? (defined $code ? "$type:$code" : $type) : '';
        $main_srv = $srv_hash{$proto}->{$key}
          or $srv_hash{$proto}->{$key} = $srv;
    }
    elsif ($proto eq 'ip') {
        $main_srv = $srv_hash{$proto}
          or $srv_hash{$proto} = $srv;
    }
    else {

        # Other protocol.
        my $key = $proto;
        $main_srv = $srv_hash{proto}->{$key}
          or $srv_hash{proto}->{$key} = $srv;
    }
    if ($main_srv) {

        # Found duplicate service definition.  Link $srv with $main_srv.
        # We link all duplicate services to the first service found.
        # This assures that we always reach the main service from any duplicate
        # service in one step via ->{main}.  This is used later to substitute
        # occurrences of $srv with $main_srv.
        $srv->{main} = $main_srv;
    }
}

sub order_icmp( $$ ) {
    my ($hash, $up) = @_;

    # Handle 'icmp any'.
    if (my $srv = $hash->{''}) {
        $srv->{up} = $up;
        $up = $srv;
    }
    for my $srv (values %$hash) {

        # 'icmp any' has been handled above.
        next unless defined $srv->{type};
        if (defined $srv->{code}) {
            $srv->{up} = ($hash->{ $srv->{type} } or $up);
        }
        else {
            $srv->{up} = $up;
        }
    }
}

sub order_proto( $$ ) {
    my ($hash, $up) = @_;
    for my $srv (values %$hash) {
        $srv->{up} = $up;
    }
}

# Link each port range with the smallest port range which includes it.
# If no including range is found, link it with the next larger service.
sub order_ranges( $$ ) {
    my ($range_href, $up) = @_;
    my @sorted =

      # Sort by low port. If low ports are equal, sort reverse by high port.
      # I.e. larger ranges coming first, if there are multiple ranges
      # with identical low port.
      sort {
             $a->{range}->[0] <=> $b->{range}->[0]
          || $b->{range}->[1] <=> $a->{range}->[1]
      } values %$range_href;

    # Check current range [a1, a2] for sub-ranges, starting at position $i.
    # Return position of range which isn't sub-range or undef
    # if end of array is reached.
    my $check_subrange;

    $check_subrange = sub ( $$$$ ) {
        my ($a, $a1, $a2, $i) = @_;
        while (1) {
            return if $i == @sorted;
            my $b = $sorted[$i];
            my ($b1, $b2) = @{ $b->{range} };

            # Neighbors
            # aaaabbbb
            if ($a2 + 1 == $b1) {

                # Mark service as candidate for joining of port ranges during
                # optimization.
                $a->{has_neighbor} = $b->{has_neighbor} = 1;
            }

            # Not related.
            # aaaa    bbbbb
            return $i if $a2 < $b1;

            # $a includes $b.
            # aaaaaaa
            #  bbbbb
            if ($a2 >= $b2) {
                $b->{up} = $a;

#           debug "$b->{name} [$b1-$b2] < $a->{name} [$a1-$a2]";
                $i = $check_subrange->($b, $b1, $b2, $i + 1);

                # Stop at end of array.
                $i or return;
                next;
            }

            # $a and $b are overlapping.
            # aaaaa
            #   bbbbbb
            # Split $b in two parts $x and $y with $x included by $b:
            # aaaaa
            #   xxxyyy
            my $x1 = $b1;
            my $x2 = $a2;
            my $y1 = $a2 + 1;
            my $y2 = $b2;

#        debug "$b->{name} [$b1-$b2] split into [$x1-$x2] and [$y1-$y2]";
            my $find_or_insert_range = sub( $$$$$ ) {
                my ($a1, $a2, $i, $orig, $prefix) = @_;
                while (1) {
                    if ($i == @sorted) {
                        last;
                    }
                    my $b = $sorted[$i];
                    my ($b1, $b2) = @{ $b->{range} };

                    # New range starts at higher position and therefore must
                    # be inserted behind current range.
                    if ($a1 > $b1) {
                        $i++;
                        next;
                    }

                    # New and current range start a same position.
                    if ($a1 == $b1) {

                        # New range is smaller and therefore must be inserted
                        # behind current range.
                        if ($a2 < $b2) {
                            $i++;
                            next;
                        }

                        # Found identical range, return this one.
                        if ($a2 == $b2) {

#                    debug "Splitted range is already defined: $b->{name}";
                            return $b;
                        }

                        # New range is larger than current range and therefore
                        # must be inserted before current one.
                        last;
                    }

                    # New range starts at lower position than current one.
                    # It must be inserted before current range.
                    last;
                }
                my $new = {
                    name  => "$prefix$orig->{name}",
                    proto => $orig->{proto},
                    range => [ $a1, $a2 ],

                    # Mark for range optimization.
                    has_neighbor => 1
                };

                # Insert new range at position $i.
                splice @sorted, $i, 0, $new;
                return $new;
            };
            my $left  = $find_or_insert_range->($x1, $x2, $i + 1, $b, 'lpart_');
            my $rigth = $find_or_insert_range->($y1, $y2, $i + 1, $b, 'rpart_');
            $b->{split} = [ $left, $rigth ];

            # Continue processing with next element.
            $i++;
        }
    };

    # Array wont be empty because $srv_tcp and $srv_udp are defined internally.
    @sorted or internal_err "Unexpected empty array";

    my $a = $sorted[0];
    $a->{up} = $up;
    my ($a1, $a2) = @{ $a->{range} };

    # Ranges "TCP any" and "UDP any" 1..65535 are defined internally,
    # they include all other ranges.
    $a1 == 1 and $a2 == 65535
      or internal_err "Expected $a->{name} to have range 1..65535";

    # There can't be any port which isn't included by ranges "TCP any" or "UDP
    # any".
    $check_subrange->($a, $a1, $a2, 1) and internal_err;
}

sub expand_splitted_services ( $ );

sub expand_splitted_services ( $ ) {
    my ($srv) = @_;
    if (my $split = $srv->{split}) {
        my ($srv1, $srv2) = @$split;
        return expand_splitted_services $srv1, expand_splitted_services $srv2;
    }
    else {
        return $srv;
    }
}

# Service 'ip' is needed later for implementing secondary rules and
# automatically generated deny rules.
my $srv_ip = { name => 'auto_srv:ip', proto => 'ip' };

# Service 'ICMP any', needed in optimization of chains for iptables.
my $srv_icmp = {
    name  => 'auto_srv:icmp',
    proto => 'icmp'
};

# Service 'TCP any'.
my $srv_tcp = {
    name      => 'auto_srv:tcp',
    proto     => 'tcp',
    src_range => $aref_tcp_any,
    dst_range => $aref_tcp_any
};

# Service 'UDP any'.
my $srv_udp = {
    name      => 'auto_srv:udp',
    proto     => 'udp',
    src_range => $aref_tcp_any,
    dst_range => $aref_tcp_any
};

# IPSec: Internet key exchange.
# Source and destination port (range) is set to 500.
my $srv_ike = {
    name      => 'auto_srv:IPSec_IKE',
    proto     => 'udp',
    src_range => [ 500, 500 ],
    dst_range => [ 500, 500 ]
};

# IPSec: NAT traversal.
my $srv_natt = {
    name      => 'auto_srv:IPSec_NATT',
    proto     => 'udp',
    src_range => [ 4500, 4500 ],
    dst_range => [ 4500, 4500 ]
};

# IPSec: encryption security payload.
my $srv_esp = { name => 'auto_srv:IPSec_ESP', proto => 50, prio => 100, };

# IPSec: authentication header.
my $srv_ah = { name => 'auto_srv:IPSec_AH', proto => 51, prio => 99, };

# Port range 'TCP any'; assigned in sub order_services below.
my $range_tcp_any;

# Port range 'tcp established' is needed later for reverse rules
# and assigned below.
my $range_tcp_established;

# Order services. We need this to simplify optimization.
# Additionally add internal predefined services.
sub order_services() {
    progress 'Arranging services';

    # Internal services need to be processed before user defined services,
    # because we want to avoid handling of {main} for internal services.
    # $srv_tcp and $srv_udp need to be processed before all other TCP and UDP
    # services, because otherwise the range 1..65535 would get a misleading
    # name.
    for my $srv (
        $srv_ip,  $srv_icmp, $srv_tcp,
        $srv_udp, $srv_ike,  $srv_natt,
        $srv_esp, $srv_ah,   values %services
      )
    {
        prepare_srv_ordering $srv;
    }
    my $up = $srv_ip;

    # This is guaranteed to be defined, because $srv_tcp has been processed
    # already.
    $range_tcp_any         = $srv_hash{tcp}->{'1:65535'};
    $range_tcp_established = {
        %$range_tcp_any,
        name        => 'reverse:TCP_ANY',
        established => 1
    };
    $range_tcp_established->{up} = $range_tcp_any;

    order_ranges($srv_hash{tcp}, $up);
    order_ranges($srv_hash{udp}, $up);
    order_icmp($srv_hash{icmp}, $up) if $srv_hash{icmp};
    order_proto($srv_hash{proto}, $up) if $srv_hash{proto};
}

# Used in expand_services.
sub set_src_dst_range_list ( $ ) {
    my ($srv) = @_;
    $srv = $srv->{main} if $srv->{main};
    my $proto = $srv->{proto};
    if ($proto eq 'tcp' or $proto eq 'udp') {
        my @src_dst_range_list;
        for my $src_range (expand_splitted_services $srv->{src_range}) {
            for my $dst_range (expand_splitted_services $srv->{dst_range}) {
                push @src_dst_range_list, [ $src_range, $dst_range ];
            }
        }
        $srv->{src_dst_range_list} = \@src_dst_range_list;
    }
    else {
        $srv->{src_dst_range_list} = [ [ $srv_ip, $srv ] ];
    }
}

####################################################################
# Link topology elements each with another
####################################################################

sub expand_group( $$;$ );

sub link_to_owner {
    my ($obj) = @_;
    if (my $value = $obj->{owner}) {
	if (my $owner = $owners{$value}) {
	    $obj->{owner} = $owner;    
	}
	else {
	    err_msg "Can't resolve reference to '$value'",
              " in attribute 'owner' of $obj->{name}";
	    delete $obj->{owner};
	}
    }
}

sub link_owners () {

    # One email address must not belong to different admins.
    my %email2admin;
    for my $admin (values %admins) {
	if (my $admin2 = $email2admin{$admin->{email}}) {
	    err_msg("Address $admin->{email} is used at",
		     " $admin->{name} and $admin2->{name}");
	}
	else {
	    $email2admin{$admin->{email}} = $admin;
	}
    }
	
    for my $owner (values %owners) {

        # Convert names of admin and watcher objects to admin objects.
	for my $attr (qw( admins watchers )) {
	    for my $name (@{ $owner->{$attr} } ) {
		if (my $admin = $admins{$name}) {
		    $name = $admin;
		}
		else {
		    err_msg "Can't resolve reference to '$name'",
		    " in attribute '$attr' of $owner->{name}";
		    $name = { name => 'unknown' };
		}
	    }
        }
    }
    for my $network (values %networks) {
	link_to_owner($network);
        for my $host (@{ $network->{hosts} }) {
	    link_to_owner($host);
	}
    }
    for my $any (values %anys) {
	link_to_owner($any);
    }
    for my $area (values %areas) {
	link_to_owner($area);
	if (my $router_attributes = $area->{router_attributes}) {
	    link_to_owner($router_attributes);
	}
    }
    for my $router (values %routers) {
	link_to_owner($router);
    }
}

# Link 'any' objects with referenced objects.
sub link_any() {
    for my $obj (values %anys) {
        my $private1 = $obj->{private} || 'public';
        my ($type, $name) = @{ $obj->{link} };
        if ($type eq 'network') {
            $obj->{link} = $networks{$name};
        }
        elsif ($type eq 'router') {
            if (my $router = $routers{$name}) {
                $router->{managed}
                  and err_msg "$obj->{name} must not be linked to",
                  " managed $router->{name}";
                $router->{semi_managed}
                  and err_msg "$obj->{name} must not be linked to",
                  " $router->{name} with pathrestriction";

                # Take some network connected to this router.
                # Since this router is unmanaged, all connected networks
                # will belong to the same security domain.
                unless ($router->{interfaces}) {
                    err_msg "$obj->{name} must not be linked to",
                      " $router->{name} without interfaces";
                    $obj->{disabled} = 1;
                    next;
                }
                $obj->{link} = $router->{interfaces}->[0]->{network};
            }

            # Force error handling below.
            else {
                $obj->{link} = undef;
            }
        }
        else {
            err_msg "$obj->{name} must not be linked to $type:$name";
            $obj->{disabled} = 1;
            next;
        }
        if (my $network = $obj->{link}) {
            my $private2 = $network->{private} || 'public';
            $private1 eq $private2
              or err_msg "$private1 $obj->{name} must not be linked",
              " with $private2 $type:$name";
        }
        else {
            err_msg "Referencing undefined $type:$name from $obj->{name}";
            $obj->{disabled} = 1;
        }
    }
}

# Link areas with referenced interfaces or network.
sub link_areas() {
    for my $area (values %areas) {
        if ($area->{anchor}) {
            my @elements =
              @{ expand_group([ $area->{anchor} ], $area->{name}) };
            if (@elements == 1) {
                my $obj = $elements[0];
                if (is_network $obj) {
                    $area->{anchor} = $obj;
                }
                else {
                    err_msg
                      "Unexpected $obj->{name} in anchor of $area->{name}";

                    # Prevent further errors.
                    delete $area->{anchor};
                }
            }
            else {
                err_msg
                  "Expected exactly one element in anchor of $area->{name}";
                delete $area->{anchor};
            }

        }
        else {
            $area->{border} = expand_group $area->{border}, $area->{name};
            for my $obj (@{ $area->{border} }) {
                if (is_interface $obj) {
		    my $router = $obj->{router};
                    $router->{managed} or $router->{semi_managed}
                      or err_msg "Referencing unmanaged $obj->{name} ",
                      "from $area->{name}";

                    # Reverse swapped main and virtual interface.
                    if (my $main_interface = $obj->{main_interface}) {
                        $obj = $main_interface;
                    }
                }
                else {
                    err_msg
                      "Unexpected $obj->{name} in border of $area->{name}";

                    # Prevent further errors.
                    delete $area->{border};
                }
            }
        }
    }
}

# Link interfaces with networks in both directions.
sub link_interfaces {
    for my $interface (values %interfaces) {
	my $net_name    = $interface->{network};
	my $network     = $networks{$net_name};

	unless ($network) {
	    my $msg = "Referencing undefined network:$net_name" .
		" from $interface->{name}";
	    if ($interface->{disabled}) {
		warn_msg $msg;
	    }
	    else {
		err_msg $msg;

		# Prevent further errors.
		$interface->{disabled} = 1;
	    }

	    # Prevent further errors.
	    # This case is handled in disable_behind.
	    $interface->{network} = undef;
	    next;
	}
	$interface->{network} = $network;

	# Private network must be connected to private interface 
	# of same context.
	if (my $private1 = $network->{private}) {
	    if (my $private2 = $interface->{private}) {
		$private1 eq $private2
		    or err_msg "$private2.private $interface->{name} must not",
		    " be connected to $private1.private $network->{name}";
	    }
	    else {
		err_msg "Public $interface->{name} must not be connected to",
		" $private1.private $network->{name}";
	    }
	}

	# Public network may connect to private interface.
	# The owner of a private context can prevent a public network from
	# connecting to a private interface by simply connecting an own private
	# network to the private interface.

	push @{ $network->{interfaces} }, $interface;
	if ($interface->{reroute_permit}) {
	    $interface->{reroute_permit} =
		expand_group $interface->{reroute_permit},
		"'reroute_permit' of $interface->{name}";
	    for my $obj (@{ $interface->{reroute_permit} }) {

		if (not is_network $obj) {
		    err_msg "$obj->{name} not allowed in attribute",
			" 'reroute_permit'\n of $interface->{name}";

		    # Prevent further errors.
		    delete $interface->{reroute_permit};
		}
	    }
	}
	my $ip         = $interface->{ip};
	my $network_ip = $network->{ip};
	if ($ip =~ /^(?:short|tunnel)$/) {

	    # Nothing to check:
	    # short interface may be linked to arbitrary network,
	    # tunnel interfaces and networks have been generated internally.
	}
	elsif ($ip eq 'unnumbered') {
	    $network_ip eq 'unnumbered'
		or err_msg "Unnumbered $interface->{name} must not be linked ",
		"to $network->{name}";
	}
	elsif ($network_ip eq 'unnumbered') {
	    err_msg "$interface->{name} must not be linked ",
	    "to unnumbered $network->{name}";
	}
	elsif ($ip eq 'negotiated') {

	    # Nothing to be checked: negotiated interface may be linked to
	    # any numbered network.
	}
	else {

	    # Check compatibility of interface IP and network IP/mask.
	    my $mask = $network->{mask};
	    if ($network_ip != ($ip & $mask)) {
		err_msg "$interface->{name}'s IP doesn't match ",
		"$network->{name}'s IP/mask";
	    }
	    if ($mask == 0xffffffff) {
		if (not $network->{loopback}) {
		    warn_msg 
			"$interface->{name} has address of its network.\n",
			" Remove definition of $network->{name}.\n",
			" Add attribute 'loopback' at interface definition.";
		}
	    }
	    else {
		if ($ip == $network_ip) {
		    err_msg "$interface->{name} has address of its network";
		}
		my $broadcast = $network_ip + complement_32bit $mask;
		if ($ip == $broadcast) {
		    err_msg "$interface->{name} has broadcast address";
		}
	    }
	}
    }
}

# Link RADIUS servers referenced in authenticating routers.
sub link_radius() {
    for my $router (@radius_routers) {
        next if $router->{disabled};

        $router->{radius_servers} = expand_group $router->{radius_servers},
          $router->{name};
        for my $element (@{ $router->{radius_servers} }) {
            if (is_host $element) {
                if ($element->{range}) {
                    err_msg "$element->{name} must have single IP address\n",
                      " because it is used as RADIUS server";
                }
            }
            else {
                err_msg "$element->{name} can't be used as RADIUS server";
            }
        }
    }
}

sub link_subnet ( $$ ) {
    my ($object, $parent) = @_;

    my $context = sub {
        !$parent        ? $object->{name}
          : ref $parent ? "$object->{name} of $parent->{name}"
          :               "$parent $object->{name}";
    };
    return if not $object->{subnet_of};
    my ($type, $name) = @{ $object->{subnet_of} };
    if ($type ne 'network') {
        err_msg "Attribute 'subnet_of' of ", $context->(), "\n",
          " must not be linked to $type:$name";

        # Prevent further errors;
        delete $object->{subnet_of};
        return;
    }
    my $network = $networks{$name};
    if (not $network) {
        warn_msg "Ignoring undefined network:$name",
          " from attribute 'subnet_of'\n of ", $context->();

        # Prevent further errors;
        delete $object->{subnet_of};
        return;
    }
    $object->{subnet_of} = $network;
    my $ip     = $network->{ip};
    my $mask   = $network->{mask};
    my $sub_ip = $object->{ip};
#    debug $network->{name} if not defined $ip;
    if ($ip eq 'unnumbered') {
        err_msg "Unnumbered $network->{name} must not be referenced from",
          " attribute 'subnet_of'\n of ", $context->();

        # Prevent further errors;
        delete $object->{subnet_of};
        return;
    }

    # $sub_mask needs not to be tested here,
    # because it has already been checked for $object.
    if (($sub_ip & $mask) != $ip) {
        err_msg $context->(), " is subnet_of $network->{name}",
          " but its IP doesn't match that's IP/mask";
    }

    # Used to check for overlaps with hosts or interfaces of $network.
    push @{ $network->{own_subnets} }, $object;
}

sub link_subnets () {
    for my $network (values %networks) {
        link_subnet $network, undef;
        for my $nat (values %{ $network->{nat} }) {
            link_subnet $nat, $network;
        }
    }
    for my $nat (values %global_nat) {
        link_subnet $nat, 'global';
    }
}

sub link_pathrestrictions() {
    for my $restrict (values %pathrestrictions) {
        $restrict->{elements} = expand_group $restrict->{elements},
          $restrict->{name};
        my $changed;
        my $private = my $no_private = $restrict->{private};
        for my $obj (@{ $restrict->{elements} }) {
            if (not is_interface $obj) {
                err_msg "$restrict->{name} must not reference $obj->{name}";
                $obj     = undef;
                $changed = 1;
                next;
            }

            # Add pathrestriction to interface.
            # Multiple restrictions may be applied to a single
            # interface.
            push @{ $obj->{path_restrict} }, $restrict;

            # Unmanaged router with pathrestriction is handled special.
	    # It is separating 'any' objects, but gets no code.
	    my $router = $obj->{router};
	    $router->{managed} or $router->{semi_managed} = 1;

            # Pathrestrictions must not be applied to secondary interfaces
            $obj->{main_interface}
              and err_msg "secondary $obj->{name} must not be used",
              " in pathrestriction";

            # Private pathrestriction must reference at least one interface
            # of its own context.
            if ($private) {
                if (my $obj_p = $obj->{private}) {
                    $private eq $obj_p and $no_private = 0;
                }
            }

            # Public pathrestriction must not reference private interface.
            else {
                if (my $obj_p = $obj->{private}) {
                    err_msg "Public $restrict->{name} must not reference",
                      " $obj_p.private $obj->{name}";
                }
            }
	}
        if ($no_private) {
            err_msg "$private.private $restrict->{name} must reference",
              " at least one interface out of $private.private";
        }
        if ($changed) {
            $restrict->{elements} = [ grep $_, @{ $restrict->{elements} } ];
        }
        my $count = @{ $restrict->{elements} };
        if ($count == 1) {
            warn_msg
              "Ignoring $restrict->{name} with only $restrict->{elements}->[0]->{name}";
        }
        elsif ($count == 0) {
            warn_msg "Ignoring $restrict->{name} without elements";
        }

        # Add pathrestriction to tunnel interfaces,
        # which belong to real interface.
        # Don't count them as extra elements.
        for my $interface (@{ $restrict->{elements} }) {
            next if not($interface->{spoke} or $interface->{hub});

            # Don't add for no_check interface because traffic would
            # pass the pathrestriction two times.
            next if $interface->{no_check};
            my $router = $interface->{router};
            for my $intf (@{ $router->{interfaces} }) {
                my $real_intf = $intf->{real_interface};
                next if not $real_intf;
                next if not $real_intf eq $interface;

#               debug "Adding $restrict->{name} to $intf->{name}";
                push @{ $restrict->{elements} },  $intf;
                push @{ $intf->{path_restrict} }, $restrict;
            }
        }
    }
}

# Check consistency of virtual interfaces:
# Interfaces with identical virtual IP must
# - be connected to the same network,
# - use the same redundancy protocol,
# - use the same id (currently optional).
# Link all virtual interface information to a single object.
# Add a list of all member interfaces.
sub link_virtual_interfaces () {
    my %ip2net2virtual;

    # Unrelated virtual interfaces with identical ID must be located
    # in different networks.
    my %same_id;
    for my $virtual1 (@virtual_interfaces) {
        my $ip = $virtual1->{ip};
	my $net = $virtual1->{network};
        my $id1 = $virtual1->{redundancy_id} || '';
        if (my $interfaces = $ip2net2virtual{$net}->{$ip}) {
            my $virtual2 = $interfaces->[0];
            if ($virtual1->{router}->{managed} xor 
		$virtual2->{router}->{managed})
	    {
                err_msg "Virtual IP: $virtual1->{name} and $virtual2->{name}",
                  " must both be managed or both be unmanaged";
                next;
            }
            if (
                not $virtual1->{redundancy_type} eq
                $virtual2->{redundancy_type})
            {
                err_msg "Virtual IP: $virtual1->{name} and $virtual2->{name}",
                  " use different redundancy protocols";
                next;
            }
            if (not $id1 eq ($virtual2->{redundancy_id} || '')) {
                err_msg "Virtual IP: $virtual1->{name} and $virtual2->{name}",
                  " use different ID";
                next;
            }

	    # This changes value of %ip2net2virtual and all attributes 
	    # {redundancy_interfaces} where this array is referenced.
            push @$interfaces, $virtual1;
            $virtual1->{redundancy_interfaces} = $interfaces;
        }
        else {
            $ip2net2virtual{$net}->{$ip} = 
		$virtual1->{redundancy_interfaces} = [$virtual1];
            if ($id1) {
                my $other;
                if (    $other = $same_id{$id1}
                    and $virtual1->{network} eq $other->{network})
                {
                    err_msg "Virtual IP:",
                      " Unrelated $virtual1->{name} and $other->{name}",
                      " have identical ID";
                }
                else {
                    $same_id{$id1} = $virtual1;
                }
            }
        }
    }
    for my $href (values %ip2net2virtual) {
	for my $interfaces (values %$href) {
	    if (@$interfaces == 1) {
		err_msg "Virtual IP: Missing second interface for",
		" $interfaces->[0]->{name}";
		$interfaces->[0]->{redundancy_interfaces} = undef;
		next;
	    }

	    # Automatically add pathrestriction to managed interfaces
	    # belonging to $ip2net2virtual.
	    # Pathrestriction would be useless for unmanaged device.
	    elsif ($interfaces->[0]->{router}->{managed}) {
		my $name = "auto-virtual-" . print_ip $interfaces->[0]->{ip};
		my $restrict = new('Pathrestriction', name => $name);
		for my $interface (@$interfaces) {

#               debug "pathrestriction $name at $interface->{name}";
		    push @{ $interface->{path_restrict} }, $restrict;
		}
	    }
	}
    }
}

sub check_ip_addresses {
    for my $network (values %networks) {
        if (    $network->{ip} eq 'unnumbered'
            and $network->{interfaces}
            and @{ $network->{interfaces} } > 2)
        {
            my $msg = "Unnumbered $network->{name} is connected to"
              . " more than two interfaces:";
            for my $interface (@{ $network->{interfaces} }) {
                $msg .= "\n $interface->{name}";
            }
            err_msg $msg;
        }

        my %ip;

        # 1. Check for duplicate interface addresses.
        # 2. Short interfaces must not be used, if a managed interface
        #    with static routing exists in the same network.
        my ($short_intf, $route_intf);
        for my $interface (@{ $network->{interfaces} }) {
            my $ip = $interface->{ip};
            if ($ip eq 'short') {
		my $restrict = $interface->{path_restrict};

		# Ignore short interface with globally active pathrestriction
		# where all traffic goes through a VPN tunnel.
		if (not $restrict or 
		    not grep({ $_ eq $global_active_pathrestriction } 
			     @$restrict))
		{
		    $short_intf = $interface;
		}
            }
            else {
                unless ($ip =~ /^(?:unnumbered|negotiated|tunnel)$/) {
                    if ($interface->{router}->{managed}
                        and not $interface->{routing})
                    {
                        $route_intf = $interface;
                    }
                    if (my $old_intf = $ip{$ip}) {
                        unless ($old_intf->{redundancy_type}
                            and $interface->{redundancy_type})
                        {
                            err_msg "Duplicate IP address for",
                              " $old_intf->{name} and $interface->{name}";
                        }
                    }
                    else {
                        $ip{$ip} = $interface;
                    }
                }
            }
            if ($short_intf and $route_intf) {
                err_msg "$short_intf->{name} must be defined in more detail,",
                  " since there is\n",
                  " a managed $route_intf->{name} with static routing enabled.";
            }
        }
        for my $host (@{ $network->{hosts} }) {
            if (my $ip = $host->{ip}) {
		if (my $other_device = $ip{$ip}) {
		    err_msg
			"Duplicate IP address for $other_device->{name}",
			" and $host->{name}";
		}
		else {
		    $ip{$ip} = $host;
		}
            }
        }
        for my $host (@{ $network->{hosts} }) {
            if (my $range = $host->{range}) { 
                for (my $ip = $range->[0] ; $ip <= $range->[1] ; $ip++) {
                    if (my $other_device = $ip{$ip}) {
                        is_host $other_device
                          or err_msg
                          "Duplicate IP address for $other_device->{name}",
                          " and $host->{name}";
                    }
                }
            }
        }
    }
}

sub link_ipsec ();
sub link_crypto ();
sub link_tunnels ();

sub link_topology() {
    progress "Linking topology";
    link_interfaces;
    link_ipsec;
    link_crypto;
    link_tunnels;
    link_pathrestrictions;
    link_virtual_interfaces;
    link_any;
    link_areas;
    link_radius;
    link_subnets;
    link_owners;
    check_ip_addresses();
}

####################################################################
# Mark all parts of the topology located behind disabled interfaces.
# "Behind" is defined like this:
# Look from a router to its interfaces;
# if an interface is marked as disabled,
# recursively mark the whole part of the topology located behind
# this interface as disabled.
# Be cautious with loops:
# Mark all interfaces at loop entry as disabled,
# otherwise the whole topology will get disabled.
####################################################################

sub disable_behind( $ );

sub disable_behind( $ ) {
    my ($in_interface) = @_;

#  debug "disable_behind $in_interface->{name}";
    $in_interface->{disabled} = 1;
    my $network = $in_interface->{network};
    if (not $network or $network->{disabled}) {

#     debug "Stop disabling at $network->{name}";
        return;
    }
    $network->{disabled} = 1;
    for my $host (@{ $network->{hosts} }) {
        $host->{disabled} = 1;
    }
    for my $interface (@{ $network->{interfaces} }) {
        next if $interface eq $in_interface;

        # This stops at other entry of a loop as well.
        if ($interface->{disabled}) {

#        debug "Stop disabling at $interface->{name}";
            next;
        }
        $interface->{disabled} = 1;
        my $router = $interface->{router};
        $router->{disabled} = 1;
        for my $out_interface (@{ $router->{interfaces} }) {
            next if $out_interface eq $interface;
            disable_behind $out_interface ;
        }
    }
}

# Lists of network objects which are left over after disabling.
my @managed_routers;
my @managed_vpnhub;
my @routers;
my @networks;
my @all_anys;
my @all_areas;

# Transform topology for networks with isolated ports.
# If a network has attribute 'isolated_ports',
# hosts inside this network are not allowed to talk directly to each other.
# Instead the traffic must go through an interface which is marked as 
# 'promiscuous_port'.
# To achieve the desired traffic flow, we transform the topology such 
# that each host is moved to a separate /32 network.
# Non promiscuous interfaces are isolated as well. They are handled like hosts
# and get a separate network too.
sub transform_isolated_ports {
  NETWORK:
    for my $network (@networks) {
	if (not $network->{isolated_ports}) {
	    for my $interface (@{ $network->{interfaces} }) {
		$interface->{promiscuous_port} and
		    warn_msg
		       "Useless 'promiscuous_port' at $interface->{name}";
	    }
	    next;
	}
	$network->{ip} eq 'unnumbered' and internal_err;
	my @promiscuous_ports;
	my @isolated_interfaces;
	my @secondary_isolated;
	for my $interface (@{ $network->{interfaces} }) {
	    if ($interface->{promiscuous_port}) {
		push @promiscuous_ports, $interface;
	    }
	    elsif ($interface->{redundancy_type}) {
		err_msg 
		    "Redundant $interface->{name} must not be isolated port";
	    }
	    elsif ($interface->{main_interface}) {
		push @secondary_isolated, $interface
		    if not $interface->{main_interface}->{promiscuous_port};
	    }
	    else {
		push @isolated_interfaces, $interface;
	    }
	}

	if (not @promiscuous_ports) {
	    err_msg("Missing 'promiscuous_port' for $network->{name}",
		    " with 'isolated_ports'");

	    # Abort transformation.
	    next NETWORK;
	}
	elsif (@promiscuous_ports > 1) {
	    equal(map { $_->{redundancy_interfaces} || 0 } @promiscuous_ports)
		or err_msg "All 'promiscuous_port's of $network->{name}",
		" need to be redundant to each other";
	}
 	$network->{hosts} or @isolated_interfaces or
	    warn_msg "Useless attribute 'isolated_ports' at $network->{name}";

	for my $obj (@{ $network->{hosts} }, @isolated_interfaces) {
	    my $ip = $obj->{ip};

	    # Add separate network for each isolated host or interface.
	    my $obj_name = $obj->{name};
	    my $new_net = new(
			      'Network',

			      # Take name of $obj for artificial network.
			      name => $obj_name,
			      ip   => $ip,
			      mask => 0xffffffff,
			      subnet_of => $network,
			      isolated => 1,
			      );
	    if (is_host($obj)) {
		$new_net->{hosts} =  [ $obj ];
	    }
	    else {

		#  Don't use unnumbered, negotiated, tunnel interfaces.
		$ip =~ /^\w/ or internal_err;
		$new_net->{interfaces} =  [ $obj ];
		$obj->{network} = $new_net;
	    }
		
	    push @{ $network->{own_subnets} }, $new_net;
	    push @networks, $new_net;

	    # Copy promiscuous interface(s) and use it to link new network 
	    # with router.
	    my @redundancy_interfaces;
	    for my $interface (@promiscuous_ports) {
		my $router = $interface->{router};
		(my $router_name = $router->{name}) =~ s/^router://;
		my $hardware = $interface->{hardware};
		my $new_intf = new('Interface',
				   name => "interface:$router_name.$obj_name",
				   ip => $interface->{ip},
				   hardware => $hardware,
				   router => $router,
				   network => $new_net,
				   );
		push @{ $hardware->{interfaces} }, $new_intf;
		push @{ $new_net->{interfaces} }, $new_intf;
		push @{ $router->{interfaces} }, $new_intf;
		if ($interface->{redundancy_type}) {
		    @{$new_intf}{qw(redundancy_type redundancy_id)} = 
			@{$interface}{qw(redundancy_type redundancy_id)};
		    push @redundancy_interfaces, $new_intf;
		}
	    }	

	    # Automatically add pathrestriction to redundant interfaces.
	    if (@redundancy_interfaces) {
		my $restrict = new('Pathrestriction', 
				   name => "auto-virtual-$obj_name");
		for my $interface (@redundancy_interfaces) {
		    push @{ $interface->{path_restrict} }, $restrict;
#		    debug "pathrestriction at $interface->{name}";
		    $interface->{redundancy_interfaces} = 
			\@redundancy_interfaces;
		}
	    }
	}

	# Move secondary isolated interfaces to same artificial network
	# where the corresponding main interface has been moved to.
	for my $secondary (@secondary_isolated) {
	    my $new_net = $secondary->{main_interface}->{network};
	    push @{ $new_net->{interfaces} }, $secondary;
	    $secondary->{network} = $new_net;
	}

	# Remove hosts and isolated interfaces from original network.
	$network->{hosts} = undef;
	for my $interface (@isolated_interfaces, @secondary_isolated) {
	    aref_delete $network->{interfaces}, $interface;
	}	
    }
}

sub mark_disabled() {
    my @disabled_interfaces = grep { $_->{disabled} } values %interfaces;

    for my $interface (@disabled_interfaces) {
        next if $interface->{router}->{disabled};
        disable_behind($interface);
        if ($interface->{router}->{disabled}) {

            # We reached an initial element of @disabled_interfaces,
            # which seems to be part of a loop.
            # This is dangerous, since the whole topology
            # may be disabled by accident.
            err_msg "$interface->{name} must not be disabled,\n",
              " since it is part of a loop";
        }
    }
    for my $interface (@disabled_interfaces) {

        # Delete disabled interfaces from routers.
        my $router = $interface->{router};
        aref_delete($router->{interfaces}, $interface);
        if ($router->{managed}) {
            aref_delete($interface->{hardware}->{interfaces}, $interface);
        }
    }
    for my $obj (values %anys) {
        next if $obj->{disabled};
        if ($obj->{link}->{disabled}) {
            $obj->{disabled} = 1;
        }
        else {
            push @all_anys, $obj;
        }
    }
    for my $area (values %areas) {
        if (my $anchor = $area->{anchor}) {
            push @all_areas, $area if not $anchor->{disabled};
        }
        else {
            $area->{border} =
              [ grep { not $_->{disabled} } @{ $area->{border} } ];
            if (@{ $area->{border} }) {
                push @all_areas, $area;
            }
            else {
                $area->{disabled} = 1;
            }
        }
    }
    my %name2vrf;
    for my $router (values %routers) {
        next if $router->{disabled};
	push @routers, $router;
	my $device_name = $router->{device_name};
	push @{ $name2vrf{$device_name} }, $router;
	if ($router->{managed}) {
	    push @managed_routers, $router;
	    if (grep { $_->{hub} && $router->{model}->{do_auth} } 
		@{ $router->{interfaces} }) 
	    {
		push @managed_vpnhub,  $router;
	    }
        }
    }

    # Collect vrf instances belonging to one device.
    for my $aref (values %name2vrf) {
	next if @$aref == 1;
	all(map $_->{managed}, @$aref) or
	    err_msg("All VRF instances of router:$aref->[0]->{device_name}",
		    " must be managed");
	equal(map $_->{model}->{name}, @$aref) or
	    err_msg("All VRF instances of router:$aref->[0]->{device_name}",
		    " must have identical model");

	my %hardware;
	for my $router (@$aref) {
	    for my $hardware (@{ $router->{hardware} }) {
		my $name = $hardware->{name};
		if (my $other = $hardware{$name}) {
		    err_msg("Duplicate hardware '$name' at",
			    " $other->{name} and $router->{name}");
		}
		else {
		    $hardware{$name} = $router;
		}
	    }
	}
	for my $router (@$aref) {
	    $router->{vrf_members} = $aref;
	}
    }

    for my $network (values %networks) {
        unless ($network->{disabled}) {
            push @networks, $network;
        }
    }
    @virtual_interfaces = grep { not $_->{disabled} } @virtual_interfaces;
    if ($policy_distribution_point and $policy_distribution_point->{disabled}) {
        $policy_distribution_point = undef;
    }
    transform_isolated_ports();
}

####################################################################
# Convert hosts to subnets.
# Find adjacent subnets.
# Mark subnet relation of subnets.
####################################################################

# 255.255.255.255, 127.255.255.255, ..., 0.0.0.3, 0.0.0.1, 0.0.0.0
my @inverse_masks = map { complement_32bit prefix2mask $_ } (0 .. 32);

# Convert an IP range to a set of covering IP/mask pairs.
sub split_ip_range( $$ ) {
    my ($low, $high) = @_;
    my @result;
  IP:
    while ($low <= $high) {
        for my $mask (@inverse_masks) {
            if (($low & $mask) == 0 && ($low + $mask) <= $high) {
                push @result, [ $low, complement_32bit $mask ];
                $low = $low + $mask + 1;
                next IP;
            }
        }
    }
    return @result;
}

sub convert_hosts() {
    progress "Converting hosts to subnets";
    for my $network (@networks) {
        next if $network->{ip} =~ /^(?:unnumbered|tunnel)$/;
        my @inv_prefix_aref;

        # Converts hosts and ranges to subnets.
        # Eliminate duplicate subnets.
        for my $host (@{ $network->{hosts} }) {
            my ($name, $nat, $id, $private) = @{$host}{qw(name nat id private)};
            my @ip_mask;
            if (my $ip = $host->{ip}) {
                @ip_mask = [ $ip, 0xffffffff ];
            }
            elsif ($host->{range}) {
                my ($ip1, $ip2) = @{ $host->{range} };
                @ip_mask = split_ip_range $ip1, $ip2;
            }
            else {
                internal_err "unexpected host type";
            }
            for my $ip_mask (@ip_mask) {
                my ($ip, $mask) = @$ip_mask;
                my $inv_prefix = 32 - mask2prefix $mask;
                if (my $other_subnet = $inv_prefix_aref[$inv_prefix]->{$ip}) {
                    my $nat2 = $other_subnet->{nat};
                    if ($nat xor $nat2) {
                        err_msg "Inconsistent NAT definition for",
                          "$other_subnet->{name} and $host->{name}";
                    }
                    elsif ($nat and $nat2) {

                        # Number of entries is equal.
                        if (keys %$nat == keys %$nat2) {

                            # Entries are equal.
                            for my $name (keys %$nat) {
                                unless ($nat2->{$name}
                                    and $nat->{$name} eq $nat2->{$name})
                                {
                                    err_msg "Inconsistent NAT definition for",
                                      "$other_subnet->{name} and $host->{name}";
                                    last;
                                }
                            }
                        }
                        else {
                            err_msg "Inconsistent NAT definition for",
                              "$other_subnet->{name} and $host->{name}";
                        }
                    }
                    push @{ $host->{subnets} }, $other_subnet;
                }
                else {
                    my $subnet = new(
                        'Subnet',
                        name    => $name,
                        network => $network,
                        ip      => $ip,
                        mask    => $mask,
                    );
                    $subnet->{nat}     = $nat     if $nat;
                    $subnet->{private} = $private if $private;
                    if ($id) {
                        $subnet->{id} = $id;
                        $subnet->{radius_attributes} =
                          $host->{radius_attributes};
                    }
                    $inv_prefix_aref[$inv_prefix]->{$ip} = $subnet;
                    push @{ $host->{subnets} },    $subnet;
                    push @{ $network->{subnets} }, $subnet;
                }
            }
        }

        # Find adjacent subnets which build a larger subnet.
        my $network_inv_prefix = 32 - mask2prefix $network->{mask};
        for (my $i = 0 ; $i < @inv_prefix_aref ; $i++) {
            if (my $ip2subnet = $inv_prefix_aref[$i]) {
                my $next   = 2**$i;
                my $modulo = 2 * $next;
                for my $ip (keys %$ip2subnet) {
                    my $subnet = $ip2subnet->{$ip};

                    if (

                        # Don't combine subnets with NAT
                        # ToDo: This would be possible if all NAT addresses
                        #  match too.
                        # But, attention for PIX firewalls:
                        # static commands for networks / subnets block
                        # network and broadcast address.
                        not $subnet->{nat}

                        # Don't combine subnets having radius-ID.
                        and not $subnet->{id}

                        # Only take the left part of two adjacent subnets.
                        and $ip % $modulo == 0
                      )
                    {
                        my $next_ip = $ip + $next;

                        # Find the right part.
                        if (my $neighbor = $ip2subnet->{$next_ip}) {
                            $subnet->{neighbor} = $neighbor;
                            my $up_inv_prefix = $i + 1;
                            my $up;
                            if ($up_inv_prefix >= $network_inv_prefix) {

                                # Larger subnet is whole network.
                                $up = $network;
                            }
                            elsif ( $up_inv_prefix < @inv_prefix_aref
                                and $up =
                                $inv_prefix_aref[$up_inv_prefix]->{$ip})
                            {
                            }
                            else {
                                (my $name = $subnet->{name}) =~
                                  s/^.*:/auto_subnet:/;
                                my $mask = prefix2mask(32 - $up_inv_prefix);
                                $up = new(
                                    'Subnet',
                                    name    => $name,
                                    network => $network,
                                    ip      => $ip,
                                    mask    => $mask
                                );
                                if (my $private = $subnet->{private}) {
                                    $up->{private} = $private if $private;
                                }
                                $inv_prefix_aref[$up_inv_prefix]->{$ip} = $up;
                            }
                            $subnet->{up}   = $up;
                            $neighbor->{up} = $up;
                            push @{ $network->{subnets} }, $up;

                            # Don't search for enclosing subnet below.
                            next;
                        }
                    }

                    # For neighbors, {up} has been set already.
                    next if $subnet->{up};

                    # Search for enclosing subnet.
                    for (my $j = $i + 1 ; $j < @inv_prefix_aref ; $j++) {
                        my $mask = prefix2mask(32 - $j);
                        $ip &= $mask;
                        if (my $up = $inv_prefix_aref[$j]->{$ip}) {
                            $subnet->{up} = $up;
                            last;
                        }
                    }

                    # Use network, if no enclosing subnet found.
                    $subnet->{up} ||= $network;
                }
            }
        }

        # Attribute {up} has been set for all subnets now.
        # Do the same for interfaces and the network itself.
        $network->{up} = $network->{any};
        for my $interface (@{ $network->{interfaces} }) {
            $interface->{up} = $network;
        }
    }
}

# Find adjacent subnets and substitute them by their enclosing subnet.
sub combine_subnets ( $ ) {
    my ($aref) = @_;
    my %hash;
    for my $subnet (@$aref) {
        $hash{$subnet} = $subnet;
    }
    for my $subnet (@$aref) {
        my $neighbor;
        if ($neighbor = $subnet->{neighbor} and $hash{$neighbor}) {
            my $up = $subnet->{up};
            unless ($hash{$up}) {
                $hash{$up} = $up;
                push @$aref, $up;
            }
            delete $hash{$subnet};
            delete $hash{$neighbor};
        }
    }

    # Sort networks by size of mask,
    # i.e. large subnets coming first and
    # for equal mask by IP address.
    # We need this to make the output deterministic.
    return [ sort { $a->{mask} <=> $b->{mask} || $a->{ip} <=> $b->{ip} }
          values %hash ];
}

####################################################################
# Expand rules
#
# Simplify rules to expanded rules where each rule has exactly one
# src, dst and srv
####################################################################

my %name2object = (
    host      => \%hosts,
    network   => \%networks,
    interface => \%interfaces,
    any       => \%anys,
    group     => \%groups,
    area      => \%areas,
);

my %auto_interfaces;

sub get_auto_intf ( $;$) {
    my ($object, $managed) = @_;
    $managed ||= 0;
    my $result = $auto_interfaces{$object}->{$managed};
    if (not $result) {
        my $name;
        if (is_router $object) {
            ($name = $object->{name}) =~ s/^router://;
        }
        else {
            $name = "[$object->{name}]";
        }
        $name   = "interface:$name.[auto]";
        $result = new(
            'Autointerface',
            name    => $name,
            object  => $object,
            managed => $managed
        );
        $result->{disabled} = 1 if $object->{disabled};
        $auto_interfaces{$object}->{$managed} = $result;

#       debug $result->{name};
    }
    $result;
}

# Get a reference to an array of network object descriptions and
# return a reference to an array of network objects.
sub expand_group1( $$;$ );
sub expand_group1( $$;$ ) {
    my ($aref, $context, $clean_autogrp) = @_;
    my @objects;
    for my $parts (@$aref) {

        my ($type, $name, $ext) = @$parts;
        if ($type eq '&') {
            my @non_compl;
            my @compl;
            my $type;
            for my $element (@$name) {
                my $element1 = $element->[0] eq '!' ? $element->[1] : $element;
                my @elements =
                  map {
                    if (ref $_ =~ /Local|Autointerface/)
                    {
                        err_msg
                          "$_->{name} not allowed in intersection of",
                          " $context";
                        ();
                    }
                    elsif ($type and ref $_ ne $type) {
                        err_msg
                          "All elements must be of same type",
                          " in intersection of $context";
                        ();
                    }
                    else {
                        $_->{is_used} = 1;
                        $type = ref $_;
                        $_;
                    }
                  } @{ expand_group1([$element1], 
				     "intersection of $context", 
				     $clean_autogrp) };

                if ($element->[0] eq '!') {
                    push @compl, @elements;
                }
                else {
                    push @non_compl, \@elements;
                }
            }
            @non_compl >= 1
              or err_msg "Intersection needs at least one element",
              " which is not complement in $context";
            my $result;
            for my $element (@{ $non_compl[0] }) {
                $result->{$element} = $element;
            }
            for my $set (@non_compl[ 1 .. $#non_compl ]) {
                my $intersection;
                for my $element (@$set) {
                    if ($result->{$element}) {
                        $intersection->{$element} = $element;
                    }
                }
                $result = $intersection;
            }
            for my $element (@compl) {
                delete $result->{$element}
		or warn_msg "Useless delete of $element->{name} in $context";
            }

            # Put result into same order as the elements of first non
            # complemented set. This set contains all elements of resulting set,
            # because we are doing intersection here.
            push @objects, grep { $result->{$_} } @{ $non_compl[0] };
        }
        elsif ($type eq '!') {
            err_msg "Complement (!) is only supported as part of intersection";
        }
        elsif ($type eq 'user') {

            # Either a single object or an array of objects.
            my $elements = $name->{elements};
            push @objects, ref($elements) eq 'ARRAY' ? @$elements : $elements;
        }
        elsif ($type eq 'interface') {
            my @check;
            if (ref $name) {
                ref $ext
                  or err_msg "Must not use interface:[..].$ext in $context";
                my ($selector, $managed) = @$ext;
                my $sub_objects = expand_group1 $name,
                  "interface:[..].[$selector] of $context";
                for my $object (@$sub_objects) {
                    next if $object->{disabled};
                    $object->{is_used} = 1;
                    my $type = ref $object;
                    if ($type eq 'Network') {
                        if ($selector eq 'all') {
                            if ($managed) {
                                push @check,
                                  grep { $_->{router}->{managed} }
                                  @{ $object->{interfaces} };
                            }
                            else {
                                push @check, @{ $object->{interfaces} };
                            }
                        }
                        else {
                            push @objects, get_auto_intf $object, $managed;
                        }
                    }
                    elsif ($type eq 'Any') {
                        if ($selector eq 'all') {
                            if ($managed) {
                                push @check,
				  grep { $_->{router}->{managed} }
				  @{ $object->{interfaces} };
                            }
                            else {
				push @check, @{ $object->{interfaces} };
			    }
                        }
                        else {
                            err_msg "Must not use",
                              " interface:[any:..].[auto] in $context";
                        }
                    }
                    elsif ($type eq 'Interface') {
                        my $router = $object->{router};
                        if ($managed and not $router->{managed}) {

                            # Do nothing.
                        }
                        elsif ($selector eq 'all') {
                            push @check, @{ $router->{interfaces} };
                        }
                        else {
                            push @objects, get_auto_intf $router;
                        }
                    }
                    elsif ($type eq 'Area') {
                        my @routers;

                        # Prevent duplicates and border routers.
                        my %seen;
                        
                        # Don't add border routers of this area.
                        for my $interface (@{ $object->{border} }) {
                            $seen{ $interface->{router} } = 1;
                        }

                        # Add border routers of security domains inside 
                        # current area.
                        for my $router (map $_->{router},
                                        map @{ $_->{interfaces} }, 
                                        @{ $object->{anys} })
                        {
                            if (not $seen{$router}) {
                                push @routers, $router;
                                $seen{$router} = 1;
                            }
                        }
                        if ($managed) {
			    @routers = grep { $_->{managed} } @routers;
			}
			else {
                            push @routers, map {
                                my $r = $_->{unmanaged_routers};
                                $r ? @$r : ()
                            } @{ $object->{anys} };
                        }
                        if ($selector eq 'all') {
                            push @check, map @{ $_->{interfaces} }, @routers;
                        }
                        else {
                            push @objects, map { get_auto_intf $_ } @routers;
                        }
                    }
                    elsif ($type eq 'Autointerface') {
                        my $obj = $object->{object};
                        if (is_router $obj) {
                            if ($managed and not $obj->{managed}) {

                                # This router has no managed interfaces.
                            }
                            elsif ($selector eq 'all') {
                                push @check, @{ $obj->{interfaces} };
                            }
                            else {
                                push @objects, get_auto_intf $obj;
                            }
                        }
                        else {
                            err_msg "Can't use $object->{name} inside",
                              " interface:[..].[$selector] of $context";
                        }
                    }
                    else {
                        err_msg
                          "Unexpected type '$type' in interface:[..] of $context";
                    }
                }
            }

            # interface:name.[xxx]
            elsif (ref $ext) {
                my ($selector, $managed) = @$ext;
                if (my $router = $routers{$name}) {

                    # Syntactically impossible.
                    $managed and internal_err;
                    if ($selector eq 'all') {
                        push @check, @{ $router->{interfaces} };
                    }
                    else {
                        push @objects, get_auto_intf $router;
                    }
                }
                else {
                    err_msg
                      "Can't resolve $type:$name.[$selector] in $context";
                }
            }

            # interface:name.name
            elsif (my $interface = $interfaces{"$name.$ext"}) {
                push @objects, $interface;
            }
            else {
                err_msg "Can't resolve $type:$name.$ext in $context";
            }

            # Silently remove unnumbered and tunnel interfaces
            # from automatic groups.
	    push @objects, 
	          $clean_autogrp
		? grep { $_->{ip} !~ /^(?:unnumbered|tunnel)$/ } @check
		: grep { $_->{ip} ne 'tunnel' } @check;
        }
        elsif (ref $name) {
            my $sub_objects = expand_group1 $name, "$type:[..] of $context";
            if ($type eq 'network') {
		my @check;
                for my $object (@$sub_objects) {
                    next if $object->{disabled};
                    $object->{is_used} = 1;
                    my $type = ref $object;
                    if ($type eq 'Area') {
                        push @check,
			  map { @{ $_->{networks} } } @{ $object->{anys} };
                    }
                    elsif ($type eq 'Any') {
                        push @check, @{ $object->{networks} };
                    }
                    elsif ($type eq 'Host' or $type eq 'Interface') {

                        # Don't add implicitly defined network 
			# of loopback interface.
                        if (not $object->{loopback}) {
                            push @check, $object->{network};
                        }
                    }
                    elsif ($type eq 'Network') {
                        push @objects, $object;
                    }
                    else {
                        err_msg
                          "Unexpected type '$type' in network:[..] of $context";
                    }
                }

		# Silently remove route_hint and crosslink networks
		# from automatic groups.
		push @objects, 
		      $clean_autogrp
		    ? grep { not $_->{route_hint} and not $_->{crosslink} }
	              @check
		    : @check;
            }
            elsif ($type eq 'any') {
                for my $object (@$sub_objects) {
                    next if $object->{disabled};
                    $object->{is_used} = 1;
                    my $type = ref $object;
                    if ($type eq 'Area') {
                        push @objects, @{ $object->{anys} };
                    }
                    elsif ($type eq 'Any') {
                        push @objects, $object;
                    }
                    elsif ($type eq 'Host' or $type eq 'Interface') {

                        # Don't add implicitly defined network of loopback interface.
                        if (not $object->{loopback}) {
                            push @objects, $object->{network}->{any};
                        }
                    }
                    elsif ($type eq 'Network') {
                        push @objects, $object->{any};
                    }
                    else {
                        err_msg
                          "Unexpected type '$type' in any:[..] of $context";
                    }
                }
            }
            else {
                err_msg "Unexpected $type:[..] in $context";
            }
        }

        # An object named simply 'type:name'.
        elsif (my $object = $name2object{$type}->{$name}) {

            $ext
              and err_msg "Unexpected '.$ext' after $type:$name in $context";

            # Split a group into its members.
	    # There may be two different versions depending of $clean_autogrp.
            if (is_group $object) {

		# Two differnt expanded values, depending on $clean_autogrp.
		my $ext = $clean_autogrp ? 'clean' : 'noclean';
		my $attr_name = "expanded_$ext";

		my $elements;

		# Check for recursive definition.
		if ($object->{recursive}) {
		    err_msg "Found recursion in definition of $context";
		    $object->{$attr_name} = $elements = [];
		    delete $object->{recursive};
		}

                # Group has not been converted from names to references.
                elsif (not $elements) {

		    # Add marker for detection of recursive group definition.
		    $object->{recursive} = 1;

                    # Mark group as used.
                    $object->{is_used} = 1;

                    $elements = expand_group1($object->{elements}, 
					      "$type:$name", 
					      $clean_autogrp);
		    delete $object->{recursive};

                    # Private group must not reference private element of other
                    # context.
                    # Public group must not reference private element.
                    my $private1 = $object->{private} || 'public';
                    for my $element (@$elements) {
                        if (my $private2 = $element->{private}) {
                            $private1 eq $private2
                              or err_msg(
                                "$private1 $object->{name} must not",
                                " reference $private2 $element->{name}"
                              );
                        }
                    }

		    # Detect and remove duplicate values in group.
		    my %unique;
		    my @duplicate;
		    for my $obj (@$elements) {
			if ($unique{$obj}++) {
			    push @duplicate, $obj;
			    $obj = undef;
			}
		    }
		    if (@duplicate) {
			$elements = [ grep { defined $_ } @$elements ];
			my $msg =  "Duplicate elements in $type:$name:\n " .
			    join("\n ", map { $_->{name} } @duplicate);
			warn_msg $msg;
		    }

                    # Cache result for further references to the same group
		    # in same $clean_autogrp context.
                    $object->{$attr_name} = $elements;
                }
                push @objects, @$elements;
            }
            else {
                push @objects, $object;
            }

        }
        else {
            err_msg "Can't resolve $type:$name in $context";
        }
    }
    return \@objects;
}

sub expand_group( $$;$ ) {
    my ($obref, $context, $convert_hosts) = @_;
    my $aref = expand_group1 $obref, $context, 'clean_autogrp';
    for my $object (@$aref) {
        my $ignore;
        if ($object->{disabled}) {
            $object = undef;
        }
        elsif (is_network $object) {
            if ($object->{ip} eq 'unnumbered') {
                $ignore = "unnumbered $object->{name}";
            }
            elsif ($object->{route_hint}) {
                $ignore = "$object->{name} having attribute 'route_hint'";
            }
            elsif ($object->{crosslink}) {
                $ignore = "crosslink $object->{name}";
            }
        }
        elsif (is_interface $object) {
            if ($object->{ip} =~ /short|unnumbered/) {
                $ignore = "$object->{ip} $object->{name}";
            }
        }
        elsif (is_area $object) {
            $ignore = $object->{name};
        }
        if ($ignore) {
            $object = undef;
            warn_msg "Ignoring $ignore in $context";
        }
    }

    # Detect and remove duplicate values in policy.
    my %unique;
    my @duplicate;
    for my $obj (@$aref) {
	next if not defined $obj;
	if ($unique{$obj}++) {
	    push @duplicate, $obj;
	    $obj = undef;
	}
    }
    if (@duplicate) {
	my $msg =  "Duplicate elements in $context:\n " .
	    join("\n ", map { $_->{name} } @duplicate);
	warn_msg $msg;
    }
    $aref = [ grep { defined $_ } @$aref ];
    if ($convert_hosts) {
        my @subnets;
        my @other;
        for my $obj (@$aref) {

#           debug "group:$obj->{name}";
            if (is_host $obj) {
                push @subnets, @{ $obj->{subnets} };
            }
            else {
                push @other, $obj;
            }
        }
	push @other, ($convert_hosts eq 'no_combine')
	           ? @subnets
	           : @{ combine_subnets \@subnets };
        return \@other;
    }
    else {
        return $aref;
    }

}

sub check_unused_groups() {
    if ($config{check_unused_groups}) {
        for my $obj (values %groups, values %servicegroups) {
            unless ($obj->{is_used}) {
                my $msg;
                if (is_area $obj) {
                    $msg = "unused $obj->{name}";
                }
                elsif (my $size = @{ $obj->{elements} }) {
                    $msg = "unused $obj->{name} with $size element"
                      . ($size == 1 ? '' : 's');
                }
                else {
                    $msg = "unused empty $obj->{name}";
                }
                if ($config{check_unused_groups} eq 'warn') {
                    warn_msg $msg;
                }
                else {
                    err_msg $msg;
                }
            }
        }
    }

    # Not used any longer; free memory.
    %groups = ();

#   %areas = ();
}

sub expand_services( $$ );

sub expand_services( $$ ) {
    my ($aref, $context) = @_;
    my @services;
    for my $pair (@$aref) {
        my ($type, $name) = @$pair;
        if ($type eq 'service') {
            if (my $srv = $services{$name}) {
                push @services, $srv;

                # Currently needed by external program 'cut-netspoc'.
                $srv->{is_used} = 1;

                # Used in expand_rules.
                if (not $srv->{src_dst_range_list}) {
                    set_src_dst_range_list($srv);
                }
            }
            else {
                err_msg "Can't resolve reference to $type:$name in $context";
                next;
            }
        }
        elsif ($type eq 'servicegroup') {
            if (my $srvgroup = $servicegroups{$name}) {
                my $elements = $srvgroup->{elements};
                if ($elements eq 'recursive') {
                    err_msg "Found recursion in definition of $context";
                    $srvgroup->{elements} = $elements = [];
                }

                # Check if it has already been converted
                # from names to references.
                elsif (not $srvgroup->{is_used}) {

                    # Detect recursive definitions.
                    $srvgroup->{elements} = 'recursive';
                    $srvgroup->{is_used}  = 1;
                    $elements = expand_services $elements, "$type:$name";

                    # Cache result for further references to the same group.
                    $srvgroup->{elements} = $elements;
                }
                push @services, @$elements;
            }
            else {
                err_msg "Can't resolve reference to $type:$name in $context";
                next;
            }
        }
        else {
            err_msg "Unknown type of $type:$name in $context";
        }
    }
    return \@services;
}

sub path_auto_interfaces( $$ );

# Hash with attributes deny, any, permit for storing
# expanded rules of different type.
our %expanded_rules = (deny => [], any => [], permit => []);

# Hash for ordering all rules:
# $rule_tree{$stateless}->{$action}->{$src}->{$dst}->{$src_range}->{$srv}
#  = $rule;
my %rule_tree;

# Hash for converting a reference of an service back to this service.
my %ref2srv;

# Collect deleted rules for further inspection.
my @deleted_rules;

# Add rules to %rule_tree for efficient look up.
sub add_rules( $ ) {
    my ($rules_ref) = @_;
    for my $rule (@$rules_ref) {
        my ($stateless, $action, $src, $dst, $src_range, $srv) =
          @{$rule}{ 'stateless', 'action', 'src', 'dst', 'src_range', 'srv' };
        $ref2srv{$src_range} = $src_range;
        $ref2srv{$srv}       = $srv;

        # A rule with an interface as destination may be marked as deleted
        # during global optimization. But in some cases, code for this rule
        # must be generated anyway. This happens, if
        # - it is an interface of a managed router and
        # - code is generated for exactly this router.
        # Mark such rules for easier handling.
        if (is_interface($dst) and $dst->{router}->{managed}) {
            $rule->{managed_intf} = 1;
        }
        my $old_rule =
          $rule_tree{$stateless}->{$action}->{$src}->{$dst}->{$src_range}
          ->{$srv};
        if ($old_rule) {

            # Found identical rule.
            $rule->{deleted} = $old_rule;
	    push @deleted_rules, $rule if $config{check_duplicate_rules};
            next;
        }

#       debug "Add:", print_rule $rule;
        $rule_tree{$stateless}->{$action}->{$src}->{$dst}->{$src_range}
          ->{$srv} = $rule;
    }
}

my %obj2any;

sub get_any( $ ) {
    my ($obj) = @_;
    my $type = ref $obj;
    my $result;

    # A router or network with [auto] interface.
    if ($type eq 'Autointerface') {
        $obj  = $obj->{object};
        $type = ref $obj;
    }
    if ($type eq 'Network') {
        $result = $obj->{any};
    }
    elsif ($type eq 'Subnet') {
        $result = $obj->{network}->{any};
    }
    elsif ($type eq 'Interface') {
        if ($obj->{router}->{managed}) {
            $result = $obj->{router};
        }
        else {
            $result = $obj->{network}->{any};
        }
    }
    elsif ($type eq 'Any') {
        $result = $obj;
    }

    # Only used when called from expand_rules.
    elsif ($type eq 'Router') {
        if ($obj->{managed}) {
            $result = $obj;
        }
        else {
            $result = $obj->{interfaces}->[0]->{network}->{any};
        }
    }
    elsif ($type eq 'Host') {
        $result = $obj->{network}->{any};
    }
    else {
        internal_err "unexpected $obj->{name}";
    }
    $obj2any{$obj} = $result;
}

sub path_walk( $$;$ );

sub get_networks ( $ ) {
    my ($obj) = @_;
    my $type = ref $obj;
    if ($type eq 'Network') {
        $obj;
    }
    elsif ($type eq 'Subnet' or $type eq 'Interface') {
        $obj->{network};
    }
    elsif ($type eq 'Any') {
        @{ $obj->{networks} };
    }
    else {
        internal_err "unexpected $obj->{name}";
    }
}

sub expand_special ( $$$$ ) {
    my ($src, $dst, $flags, $context) = @_;
    my @result;
    if (is_autointerface $src) {
        for my $interface (path_auto_interfaces $src, $dst) {
            if ($interface->{ip} eq 'short') {
                err_msg "'$interface->{ip}' $interface->{name}",
                  " (from .[auto])\n",
                  " must not be used in rule of $context";
            }
            elsif ($interface->{ip} =~ /unnumbered/) {

                # Ignore unnumbered interfaces.
            }
            else {
                push @result, $interface;
            }
        }
    }
    else {
        @result = ($src);
    }
    if ($flags->{path}) {
 	internal_err "Flag 'path' currently disabled";
        my %interfaces;
        for my $src (@result) {
            my $fun = sub {
                my ($rule, $in_intf, $out_intf) = @_;
                if ($in_intf) {
                    $interfaces{$in_intf} = $in_intf;
                }
            };
            my $pseudo_rule = {
                src => is_autointerface $src ? $src->{object} : $src,
                dst => is_autointerface $dst ? $dst->{object} : $dst,
                action => '--',
                srv    => $srv_ip,
            };
            path_walk $pseudo_rule, $fun, 'Network';
        }
        @result = grep { $_->{ip} !~ /unnumbered|short/ } values %interfaces;
    }
    if ($flags->{net}) {
        my %networks;
        my @other;
        for my $obj (@result) {
            my $type = ref $obj;
            my $network;
            if ($type eq 'Network') {
                $network = $obj;
            }
            elsif ($type eq 'Subnet' or $type eq 'Host') {
                if ($obj->{id}) {
                    push @other, $obj;
                    next;
                }
                else {
                    $network = $obj->{network};
                }
            }
            elsif ($type eq 'Interface') {
                if ($obj->{router}->{managed}) {
                    push @other, $obj;
                    next;
                }
                else {
                    $network = $obj->{network};
                }
            }
            elsif ($type eq 'Any') {
                push @other, $obj;
                next;
            }
            else {
                internal_err "unexpected $obj->{name}";
            }
            $networks{$network} = $network if $network->{ip} ne 'unnumbered';
        }
        @result = (@other, values %networks);
    }
    if ($flags->{any}) {
        my %anys;
        for my $obj (@result) {
            my $type = ref $obj;
            my $any;
            if ($type eq 'Network') {
                $any = $obj->{any};
            }
            elsif ($type eq 'Subnet' or $type eq 'Interface' or $type eq 'Host')
            {
                $any = $obj->{network}->{any};
            }
            elsif ($type eq 'Any') {
                $any = $obj;
            }
            else {
                internal_err "unexpected $obj->{name}";
            }
            $anys{$any} = $any;
        }
        @result = values %anys;
    }
    return @result;
}

# This handles a rule between objects inside a single security domain or
# between interfaces of a single managed router.
# Show warning or error message if rule is between
# - different interfaces or
# - different networks or
# - subnets/hosts of different networks.
# Rules between identical objects are silently ignored.
# But a message is shown if a policy only has rules between identical objects.
my %unenforceable_context2src2dst;
my %unenforceable_context;
my %enforceable_context;

sub collect_unenforceable ( $$$$ ) {
    my ($src, $dst, $domain, $context) = @_;

    return if not $config{check_unenforceable};

    $unenforceable_context{$context} = 1;

    # A rule between identical objects is a common case
    # which results from rules with "src=user;dst=user;".
    return if $src eq $dst;

    if (is_router $domain) {

        # Auto interface is assumed to be identical
        # to each other interface of a single router.
        return if is_autointerface $src or is_autointerface $dst;
    }
    else {
        if (is_subnet $src and is_subnet $dst)
        {

	    # For rules with different subnets of a single network we don't 
	    # know if the subnets have been split from a single range.
	    # E.g. range 1-4 becomes four subnets 1,2-3,4
	    # For most splits the resulting subnets would be adjacent.
	    # Hence we check for adjacency.
            if ($src->{network} eq $dst->{network}) {
		my ($a, $b) = 
		    $src->{ip} > $dst->{ip} ? ($dst, $src) : ($src, $dst);
		if ($a->{ip} + complement_32bit($a->{mask}) + 1 == $b->{ip}) {
		    return;
		}
	    }
        }
	if (is_any $src or is_any $dst) {
	    
	    # This is a common case, which results from rules like
	    # group:some_networks -> any:[group:some_networks]
	    return if not (is_any $src and is_any $dst);
	}
    }
    delete $unenforceable_context{$context};
    $unenforceable_context2src2dst{$context}->{$src}->{$dst} ||= [ $src, $dst ];
}

sub show_unenforceable () {
    for my $context (sort keys %unenforceable_context) {
        next if 
	    $unenforceable_context2src2dst{$context} or 
	    $enforceable_context{$context};
        my $msg = "$context is fully unenforceable";
        $config{check_unenforceable} eq 'warn' ? warn_msg $msg : err_msg $msg;
    }
    for my $context (sort keys %unenforceable_context2src2dst) {
        my $msg;
        if (not $enforceable_context{$context}) {
            $msg = "$context is fully unenforceable";
        }
        else {
            $msg = "$context has unenforceable rules:";
            my $hash = $unenforceable_context2src2dst{$context};
            for my $hash (values %$hash) {
                for my $aref (values %$hash) {
                    my ($src, $dst) = @$aref;
                    $msg .= "\n src=$src->{name}; dst=$dst->{name}";
                }
            }
        }
        $config{check_unenforceable} eq 'warn' ? warn_msg $msg : err_msg $msg;
    }
    %enforceable_context           = ();
    %unenforceable_context         = ();
    %unenforceable_context2src2dst = ();
}

sub show_deleted_rules1 {
    return if not @deleted_rules;
    my %pname2oname2deleted;
    my %pname2file;
  RULE:
    for my $rule (@deleted_rules) {
	my $srv = $rule->{srv};
	if ($srv->{proto} eq 'icmp') {
	    my $type = $srv->{type};
	    next if defined $type && ($type == 0 || $type == 8);
	}
	my $other = $rule->{deleted};
	my $policy = $rule->{rule}->{policy};
	my $opolicy = $other->{rule}->{policy};
	if (my $overlaps = $policy->{overlaps}) {
	    for my $overlap (@$overlaps) {
		if ($opolicy eq $overlap) {
		    $policy->{overlaps_used}->{$overlap} = $overlap;
		    next RULE;
		}
	    }
	}
	if (my $overlaps = $opolicy->{overlaps}) {
	    for my $overlap (@$overlaps) {
		if ($policy eq $overlap) {
		    $opolicy->{overlaps_used}->{$overlap} = $overlap;
		    next RULE;
		}
	    }
	}
	my $pname = $policy->{name};
	my $oname = $opolicy->{name};
	my $pfile = $policy->{file};
	my $ofile = $opolicy->{file};
	$pfile =~ s/.*?([^\/]+)$/$1/;
	$ofile =~ s/.*?([^\/]+)$/$1/;
	$pname2file{$pname} = $pfile;
	$pname2file{$oname} = $ofile;
	push(@{ $pname2oname2deleted{$policy->{name}}->{$opolicy->{name}} }, 
	     $rule);
    }
    my $print = 
	$config{check_duplicate_rules} eq 'warn' ? \&warn_msg : \&err_msg;
    for my $pname (sort keys %pname2oname2deleted) {
	my $hash = $pname2oname2deleted{$pname};
	for my $oname (sort keys %$hash) {
	    my $aref = $hash->{$oname};
	    my $msg = "Duplicate rules in $pname and $oname:\n";
	    $msg .= " Files: $pname2file{$pname} $pname2file{$oname}\n  ";
	    $msg .= join("\n  ", map { print_rule $_ } @$aref);
	    $print->($msg);
	}
    }

    # Variable will be reused during sub optimize.
    @deleted_rules = ();
}

sub show_deleted_rules2 {
    return if not @deleted_rules;
    my %pname2oname2deleted;
    my %pname2file;
  RULE:
    for my $rule (@deleted_rules) {
	my $srv = $rule->{srv};
	
	# Ignore automatically generated rules from crypto.
	next if not $rule->{rule};

	# Currently, ignore ICMP echo and echo-reply.
	if ($srv->{proto} eq 'icmp') {
	    my $type = $srv->{type};
	    next if defined $type && ($type == 0 || $type == 8);
	}

	my $policy = $rule->{rule}->{policy};
	my $pname = $policy->{name};

	# Rule is still needed at device of $rule->{dst}.
	if ($rule->{managed_intf} and not $rule->{deleted}->{managed_intf}) {
	    next;
	}

	# Automatically generated reverse rule for stateless router 
	# is still needed, even for stateful routers for static routes.
	my $src = $rule->{src};
	if (is_interface($src)) {
	    my $router = $src->{router};
	    if ($router->{managed}) {
		next;
	    }
	}

	my $other = $rule->{deleted};
	my $opolicy = $other->{rule}->{policy};
	if (my $overlaps = $policy->{overlaps}) {
	    for my $overlap (@$overlaps) {
		if ($opolicy eq $overlap) {
		    $policy->{overlaps_used}->{$overlap} = $overlap;
		    next RULE;
		}
	    }
	}
	my $oname = $opolicy->{name};
	my $pfile = $policy->{file};
	my $ofile = $opolicy->{file};
	$pfile =~ s/.*?([^\/]+)$/$1/;
	$ofile =~ s/.*?([^\/]+)$/$1/;
	$pname2file{$pname} = $pfile;
	$pname2file{$oname} = $ofile;
	push(@{ $pname2oname2deleted{$pname}->{$oname} }, 
	     [ $rule, $other ]);
    }
    my $print = 
	$config{check_redundant_rules} eq 'warn' ? \&warn_msg : \&err_msg;
    for my $pname (sort keys %pname2oname2deleted) {
	my $hash = $pname2oname2deleted{$pname};
	for my $oname (sort keys %$hash) {
	    my $aref = $hash->{$oname};
	    my $msg = "Redundant rules in $pname compared to $oname:\n";
	    $msg .= " Files: $pname2file{$pname} $pname2file{$oname}\n  ";
	    $msg .= join("\n  ", 
			 map { my ($r, $o) = @$_; 
			       print_rule($r) . "\n< " . print_rule($o); } 
			 @$aref);
	    $print->($msg);
	}
    }

    # Free memory.
    @deleted_rules = ();

    # Warn about unused {overlaps} declarations.
    for my $key (sort keys %policies) {
        my $policy = $policies{$key};
	if (my $overlaps = $policy->{overlaps}) {
	    my $used = delete $policy->{overlaps_used};
	    for my $overlap (@$overlaps) {
		$used->{$overlap} or
		    warn_msg "Useless 'overlaps = $overlap->{name}'",
		    " in $policy->{name}";
	    }
	}
    }
}

# Hash of services to permit globally at any device.
my %global_permit;

# Parameters:
# - Reference to array of unexpanded rules.
# - Current context for error messages: name of policy or crypto object.
# - Reference to hash with attributes deny, any, permit for storing
#   resulting expanded rules of different type.
# Optional, used when called from expand_policies:
# - Reference to array of values. Occurrences of 'user' in rules
#   will be substituted by these values.
# - Flag, indicating if values for 'user' are substituted as a whole or
#   a new rules is expanded for each element.
# - Flag which will be passed on to expand_group.
sub expand_rules ( $$$$;$$$ ) {
    my ($rules_ref, $context, $result, $private, $user, $foreach,
        $convert_hosts) = @_;

    # For collecting resulting expanded rules.
    my ($deny, $any, $permit) = @{$result}{ 'deny', 'any', 'permit' };

    for my $unexpanded (@$rules_ref) {
        my $action = $unexpanded->{action};
        my $srv = expand_services $unexpanded->{srv}, "rule in $context";
	if (keys %global_permit and $action eq 'permit') {
	  SRV:
	    for my $srv (@$srv) {
		my $up = $srv;
		while ($up) {
		    if ($global_permit{$up}) {
			warn_msg "$srv->{name} in $context is redundant",
			" to global:permit";
			$srv = undef;
			next SRV;
		    }
		    $up = $up->{up};
		}
	    }
	}
        for my $element ($foreach ? @$user : $user) {
            $user_object->{elements} = $element;
            my $src =
              expand_group($unexpanded->{src}, "src of rule in $context",
                $convert_hosts);
            my $dst =
              expand_group($unexpanded->{dst}, "dst of rule in $context",
                $convert_hosts);

            for my $srv (@$srv) {
		next if not $srv;
                my $flags = $srv->{flags};

                # We must not use a unspecified boolean value but values 0 or 1,
                # because this is used as a hash key in %rule_tree.
                my $stateless = $flags->{stateless} ? 1 : 0;

		my ($src, $dst) =
		  $flags->{reversed} ? ($dst, $src) : ($src, $dst);

                # If $srv is duplicate of an identical service,
                # use the main service, but remember the original
                # one for debugging / comments.
                my $orig_srv;

                # Prevent modification of original array.
                my $srv = $srv;
                if (my $main_srv = $srv->{main}) {
                    $orig_srv = $srv;
                    $srv      = $main_srv;
                }
                else {
                    my $proto = $srv->{proto};
                    if ($proto eq 'tcp' || $proto eq 'udp') {

                        # Remember unsplitted srv.
                        $orig_srv = $srv;
                    }
                }
                $srv->{src_dst_range_list} or internal_err $srv->{name};
                for my $src_dst_range (@{ $srv->{src_dst_range_list} }) {
                    my ($src_range, $srv) = @$src_dst_range;
                    for my $src (@$src) {
                        my $src_any = $obj2any{$src} || get_any $src;
			my $src_any_cluster = $src_any->{any_cluster};
                        for my $dst (@$dst) {
                            my $dst_any = $obj2any{$dst} || get_any $dst;
			    my $dst_any_cluster = $dst_any->{any_cluster};
                            if ($src_any eq $dst_any ||
				$src_any_cluster && $dst_any_cluster &&
				$src_any_cluster == $dst_any_cluster)
			    {
                                collect_unenforceable $src, $dst, $src_any,
                                  $context;
                                next;
                            }

                            # At least one rule is enforceable.
                            # This is used to decide, if a policy is fully 
			    # unenforceable.
                            $enforceable_context{$context} = 1;
                            my @src = expand_special $src, $dst, $flags->{src},
                              $context
                              or next;    # Prevent multiple error messages.
                            my @dst = expand_special $dst, $src, $flags->{dst},
                              $context;
                            for my $src (@src) {
                                for my $dst (@dst) {
                                    if ($private) {
                                        my $src_p = $src->{private};
                                        my $dst_p = $dst->{private};
                                        $src_p and $src_p eq $private
                                          or $dst_p and $dst_p eq $private
                                          or err_msg
                                          "Rule of $private.private $context",
                                          " must reference at least one object",
                                          " out of $private.private";
                                    }
                                    else {
                                        $src->{private}
                                          and err_msg
                                          "Rule of public $context must not",
                                          " reference $src->{name} of",
                                          " $src->{private}.private";
                                        $dst->{private}
                                          and err_msg
                                          "Rule of public $context must not",
                                          " reference $dst->{name} of",
                                          " $dst->{private}.private";
                                    }

                                    my $rule = {
                                        stateless => $stateless,
                                        action    => $action,
                                        src       => $src,
                                        dst       => $dst,
                                        src_range => $src_range,
                                        srv       => $srv,
                                        rule      => $unexpanded
                                    };
                                    $rule->{orig_srv} = $orig_srv if $orig_srv;
                                    $rule->{oneway} = 1 if $flags->{oneway};
				    $rule->{stateless_icmp} = 1 
					if $flags->{stateless_icmp};
                                    if ($action eq 'deny') {
                                        push @$deny, $rule;
                                    }
                                    elsif (is_any($src) or is_any($dst)) {
                                        push @$any, $rule;
                                    }
                                    else {
                                        push @$permit, $rule;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    show_unenforceable;

    # Result is returned indirectly using parameter $result.
}

sub print_rulecount () {
    my $count = 0;
    for my $type ('deny', 'any', 'permit') {
        $count += grep { not $_->{deleted} } @{ $expanded_rules{$type} };
    }
    info "Expanded rule count: $count";
}

sub expand_policies( ;$) {
    my ($convert_hosts) = @_;
    convert_hosts if $convert_hosts;
    progress "Expanding policies";

    # Handle global:permit.
    if (my $global = $global{permit}) {
	%global_permit = map({ $_ => $_ } 
			     @{ expand_services($global->{srv}, 
						"$global->{name}")});
    }

    # Sort by policy name to make output deterministic.
    for my $key (sort keys %policies) {
        my $policy = $policies{$key};
        my $name   = $policy->{name};

	# Substitute policy name by policy object.
	if (my $overlaps = $policy->{overlaps}) {
	    my @pobjects;
	    for my $pair (@$overlaps) {
		my($type, $oname) = @$pair;
		if ($type ne 'policy') {
		    err_msg "Unexpected type '$type' in attribute 'overlaps'",
		    " of $name";
		}
		elsif ( my $other = $policies{$oname}) {
		    push(@pobjects, $other);
		}
		else {
		    warn_msg "Unknown $type:$oname in attribute 'overlaps'",
		    " of $name";
		}
	    }
	    $policy->{overlaps} = \@pobjects;
	}

	# Attribute "visible" is known to have value "*" or "name*".
	# It must match prefix of some owner name.
	# Change value to regex to simplify tests: # name* -> /^name.*$/
	if (my $visible = $policy->{visible}) {
	    if (my ($prefix) = ($visible =~ /^ (\S*) [*] $/x)) {
		if ($prefix) {
		    if (not grep { /^$prefix/ } keys %owners ) {
			warn_msg "Attribute 'visible' of $name doesn't match" .
			    " any owner";
		    }
		}
		$policy->{visible} = qr/^$prefix.*$/;
	    }		    
	}
        my $user   = $policy->{user} =
          expand_group($policy->{user}, "user of $name");
	expand_rules($policy->{rules}, $name, \%expanded_rules,
		     $policy->{private}, $user, $policy->{foreach}, 
		     $convert_hosts);
    }
    print_rulecount;
    progress "Preparing Optimization";
    for my $type ('deny', 'any', 'permit') {
        add_rules $expanded_rules{$type};
    }
    show_deleted_rules1();
}

##############################################################################
# Distribute owner, identify policy owner
##############################################################################

sub propagate_owners {

    # Inversed inheritance:
    # If an 'any' object has no direct owner
    # and if all contained networks have the same owner,
    # then set owner of this 'any' object to the one owner.
    my %any_got_net_owners;
  ANY:
    for my $any (@all_anys) {
	next if $any->{owner};
	my $owner;
	for my $network (@{ $any->{networks} }) {
	    my $net_owner = $network->{owner};
	    next ANY if not $net_owner;
	    if ($owner) {
		next ANY if $net_owner ne $owner;
	    }
	    else {
		$owner = $net_owner;
	    }
	}
	if ($owner) {
	    $any->{owner} = $owner; 
	    $any_got_net_owners{$any} = 1;
	}
    }

    # An any object can be part of multiple areas.
    # Find the smallest enclosing area.
    my %any2area;
    for my $any (@all_anys) {
	my @areas = values %{ $any->{areas} } or next;
        @areas = sort { @{ $a->{anys} } <=> @{ $b->{anys} } } @areas;
	$any2area{$any} = $areas[0];
    }	
	
    # Build tree from inheritance relation:
    # area -> [area|any, ..]
    # any  -> [network, ..]
    # network -> [host|interface, ..]
    my %tree;
    my %is_child;
    my %ref2obj;
    my $add_node = sub {
	my ($super, $sub) = @_;
	push @{ $tree{$super} }, $sub;
	$is_child{$sub} = 1;
	$ref2obj{$sub} = $sub;
	$ref2obj{$super} = $super;
    };
    
    # Find subset relation between areas.
    for my $area (values %areas) {
	if (my $super = $area->{subset_of}) {
	    $add_node->($super, $area);
	}
    }

    # Find direct subset relation between areas and any objects.
    for my $area (values %areas) {
	for my $any (@{ $area->{anys} }) {
	    if ($any2area{$any} eq $area) {
		$add_node->($area, $any);
	    }
	}
    }
    for my $any (@all_anys) {
	for my $network (@{ $any->{networks} }) {
	    $add_node->($any, $network);
	}
    }
    for my $network (@networks) {
	for my $host (@{ $network->{hosts} }) {
	    $add_node->($network, $host);
	}
	for my $interface (@{ $network->{interfaces} }) {
	    if (not $interface->{router}->{managed}) {
		$add_node->($network, $interface);
	    }
	}
    }

    # Find root nodes.
    my @root_nodes = map {$ref2obj{$_} } grep { not $is_child{$_} } keys %tree;

    # owner is extended by e_owner at node.
    # owner->node->[e_owner, .. ]
    my %extended;
    my %used;

    # upper_owner: owner object without attribute extend_only or undef
    # extend: a list of owners with attribute extend
    # extend_only: a list of owners with attribute extend_only
    my $inherit;
    $inherit = sub {
	my ($node, $upper_owner, $upper_node, $extend, $extend_only) = @_;
	my $owner = $node->{owner};
	if (not $owner) {
	    $node->{owner} = $upper_owner;
	}
	else {
	    $used{$owner} = 1;
	    if ($upper_owner) {
		if ($owner eq $upper_owner 
		    and not $any_got_net_owners{$upper_node}) 
		{
		    warn_msg  "Useless $owner->{name} at $node->{name},\n",
		    " it was already inherited from $upper_node->{name}";
		}
		if ($upper_owner->{extend}) {
		    $extend = [ @$extend, $upper_owner ];
		}
	    }
	    $upper_owner = $owner;
	    $upper_node = $node;
	    $extended{$owner}->{$node} = [ @$extend, @$extend_only ];
	}

	my $childs = $tree{$node} or return;
	if ($upper_owner) {
	    if ($upper_owner->{extend_only}) {
		$extend_only = [ @$extend_only, $upper_owner ];
		$upper_owner = undef;
		$upper_node = undef;
	    }
	}		
	for my $child (@$childs) {
	    $inherit
		->($child, $upper_owner, $upper_node, $extend, $extend_only);
	}
    };
    for my $node (@root_nodes) {
	$inherit->($node, undef, undef, [], []);
    }

    # Collect extended owners and check for inconsistent extensions.
    for my $owner (values %owners) {
	my $href = $extended{$owner} or next;
	my $node1;
	my $ext1;
	my $combined;
	for my $ref (keys %$href) {
	    my $node = $ref2obj{$ref};
	    my $ext = { map({ ($_, $_) } @{ $href->{$ref} || [] }) };
	    if ($node1) {
		my $differ;
		if (keys %$ext != keys %$ext1) {
		    $differ = 1;
		}
		else {
		    for my $ref (keys %$ext) {
			if (not $ext1->{$ref}) {
			    $differ = 1;
			    last;
			}
		    }
		}
		if ($differ) {
		    if ($config{check_owner_extend}) {
			warn_msg "$owner->{name} inherits inconsistently:",
			"\n - at $node1->{name}: ", 
			join(', ', map { $_->{name} } values %$ext1),
			"\n - at $node->{name}: ", 
			join(', ', map { $_->{name} } values %$ext);
		    }
		    $combined = { %$ext, %$combined };
		}
	    }
	    else {
		($node1, $ext1) = ($node, $ext);
		$combined = $ext1;
	    }
	}
	if (keys %$ext1) {
	    $owner->{extended_by} = [ values %$combined ];
	}
    }

    # Handle {router_attributes}->{owner} separately.
    # Areas can be nested. Proceed from small to larger ones.
    for my $area (sort { @{$a->{anys}} <=> @{$b->{anys}} } 
		  grep { not $_->{disabled} } values %areas) {
 	if ($area->{router_attributes} and 
	    (my $owner = $area->{router_attributes}->{owner}))
 	{
 	    $used{$owner} = 1;
 	    for my $router (area_managed_routers($area)) {
		if (my $r_owner = $router->{owner}) {
		    if ($r_owner eq $owner) {
			warn_msg  
			    "Useless $r_owner->{name} at $router->{name},\n",
			    " it was already inherited from $area->{name}";
		    }
		}
		else {
		    $router->{owner} = $owner;
		}
  	    }
  	}
    }
    for my $router (@managed_routers) {
 	my $owner = $router->{owner} or next;
	$used{$owner} = 1;
	for my $interface (@{ $router->{interfaces} }) {
 	    $interface->{owner} = $owner;
	}
    }

    for my $owner (values %owners) {
	for my $attr (qw( admins watchers )) {
	    for my $admin (@{ $owner->{$attr} }) {
		$used{$admin} = 1;
	    }
	}
	$used{$owner} or warn_msg "Unused $owner->{name}";
    }
    for my $admin (values %admins) {
	$used{$admin} or warn_msg "Unused $admin->{name}";
    }
}

sub expand_auto_intf {
    my ($src_aref, $dst_aref) = @_;
    for (my $i = 0; $i < @$src_aref; $i++) {
	my $src = $src_aref->[$i];
	next if not is_autointerface($src);
	my @new;
	for my $dst (@$dst_aref) {
	    push @new, Netspoc::path_auto_interfaces($src, $dst);
	}

	# Substitute auto interface by real interface.
	splice(@$src_aref, $i, 1, @new)
    }
}

  
my %unknown2policies;
my %unknown2unknown;
sub show_unknown_owners {
    for my $polices (values %unknown2policies) {
	$polices = join(',', sort @$polices);
    }
    my $print = $config{check_policy_unknown_owner} eq 'warn'
	      ? \&warn_msg
	      : \&err_msg;
  UNKNOWN:
    for my $obj (values %unknown2unknown) {
	my $up = $obj;
	while($up = $up->{up}) {
	    if ($unknown2policies{$up} and
		$unknown2policies{$obj} eq $unknown2policies{$up}) 
	    {
		next UNKNOWN;
	    }
	}

	# Derive owner of any object from its networks.
	my $owner1;
	if (is_any $obj) {
	    for my $network (@{ $obj->{networks} }) {
		if (my $owner = $network->{owner}) {
		    if (not $owner1) {
			$owner1 = $owner;
			next;
		    }
		    elsif ($owner1 eq $owner) {
			next;
		    }
		}
		$owner1 = undef;
		last;
	    }
	    next UNKNOWN if $owner1;
	}
	$print->("Unknown owner for $obj->{name} in $unknown2policies{$obj}");
    }
}

sub set_policy_owner {
    progress "Checking policy owner";
    
    propagate_owners();

    for my $key (sort keys %policies) {
	my $policy = $policies{$key};
	my $pname = $policy->{name};

	my $users = expand_group($policy->{user}, "user of $pname");

	# Non 'user' objects.
	my @objects;

	# Check, if policy contains a coupling rule with only "user" elements.
	my $is_coupling = 0;

	for my $rule (@{ $policy->{rules} }) {
	    my $has_user = $rule->{has_user};
	    if ($has_user eq 'both') {
		$is_coupling = 1;
		next;
	    }
	    for my $what (qw(src dst)) {
		next if $what eq $has_user;
		push(@objects, @{ expand_group($rule->{$what}, 
							"$what of $pname") });
	    }
	}

	# Expand auto interface to set of real interfaces.
	expand_auto_intf(\@objects, $users);
	expand_auto_intf($users, \@objects);

	# Take elements of 'user' object, if policy has coupling rule.
	if ($is_coupling) {
	    push @objects, @$users;
	}

	# Remove duplicate objects;
	my %objects = map { $_ => $_ } @objects;
	@objects = values %objects;

	# Collect policy owners and unknown owners;
	my $policy_owners;
	my $unknown_owners;

	for my $obj (@objects) {
	    my $owner = $obj->{owner};
	    if ($owner) {
		$policy_owners->{$owner} = $owner;
	    }
	    else {
		$unknown_owners->{$obj} = $obj;
	    }
	}

	$policy->{owners} = [ values %$policy_owners ];

	# Check for multiple owners.
	my $multi_count = $is_coupling
	                ? 1
	                : values %$policy_owners;
	if ($multi_count > 1 xor $policy->{multi_owner}) {
	    if ($policy->{multi_owner}) {
		warn_msg "Useless use of attribute 'multi_owner' at $pname";
	    }
	    else {
		my $print = $config{check_policy_multi_owner}
		          ? $config{check_policy_multi_owner} eq 'warn'
			  ? \&warn_msg
			  : \&err_msg
			  : sub {};
		my @names = sort(map { $_->{name} =~ /^owner:(.*)/; $1 }  
				 values %$policy_owners);
		$print->("$pname has multiple owners: ". join(', ', @names));
	    }
	}

	# Check for unknown owners.
	if (($unknown_owners and keys %$unknown_owners) xor 
	    $policy->{unknown_owner}) 
	{
	    if ($policy->{unknown_owner}) {
		warn_msg "Useless use of attribute 'unknown_owner' at $pname";
	    }
	    else {
		if ($config{check_policy_unknown_owner}) {
		    for my $obj (values %$unknown_owners) {
			$unknown2unknown{$obj} = $obj;
			push @{ $unknown2policies{$obj} }, $pname;
		    }
		}
	    }
	}
    }
    show_unknown_owners();
}

##############################################################################
# Distribute NAT bindings
##############################################################################

# We assume that NAT for a single network is applied at most parts of 
# the topology.
# No-NAT-set: a set of NAT tags which are not applied for other networks 
# at current network.
# NAT Domain: a maximal area of our topology (a set of connected networks)
# where the no-NAT-set is identical at each network.
sub set_natdomain( $$$ );

sub set_natdomain( $$$ ) {
    my ($network, $domain, $in_interface) = @_;
    $network->{nat_domain} = $domain;

#    debug "$domain->{name}: $network->{name}";
    push @{ $domain->{networks} }, $network;
    my $no_nat_set = $domain->{no_nat_set};
    for my $interface (@{ $network->{interfaces} }) {

        # Ignore interface where we reached this network.
        next if $interface eq $in_interface;
        my $router = $interface->{router};
        next if $router->{active_path};
        $router->{active_path} = 1;
        my $managed = $router->{managed};
        my $nat_tags = $interface->{bind_nat} || $bind_nat0;
        for my $out_interface (@{ $router->{interfaces} }) {
            my $out_nat_tags = $out_interface->{bind_nat} || $bind_nat0;

            # Current NAT domain continues behind $out_interface.
            if (aref_eq($out_nat_tags, $nat_tags)) {

                # no_nat_set will be collected at NAT domains, but is needed at
                # logical and hardware interfaces of managed routers.
                if ($managed) {

#                   debug "$domain->{name}: $out_interface->{name}";
                    $out_interface->{no_nat_set} =
                      $out_interface->{hardware}->{no_nat_set} = $no_nat_set;
                }

                # Don't process interface where we reached this router.
                next if $out_interface eq $interface;

                my $next_net = $out_interface->{network};

                # Found a loop inside a NAT domain.
                next if $next_net->{nat_domain};

                set_natdomain $next_net, $domain, $out_interface;
            }

            # New NAT domain starts at some interface of current router.
            # Remember NAT tag of current domain.
            else {

                # If one router is connected to the same NAT domain
                # by different interfaces, all interfaces must have 
                # the same NAT binding. (This occurs only in loops).
                if (my $old_nat_tags = $router->{nat_tags}->{$domain}) {
                    if (not aref_eq($old_nat_tags, $nat_tags)) {
                        my $old_tag_names = join(',', @$old_nat_tags);
                        my $tag_names = join(',', @$nat_tags);
                        err_msg
                          "Inconsistent NAT in loop at $router->{name}:\n",
                          "nat:$old_tag_names vs. nat:$tag_names";
                    }

                    # NAT domain and router have been linked together already.
                    next;
                }
                $router->{nat_tags}->{$domain} = $nat_tags;
                push @{ $domain->{routers} },     $router;
                push @{ $router->{nat_domains} }, $domain;
            }
        }
        $router->{active_path} = 0;
    }
}

# Distribute no_nat_sets from NAT domain to NAT domain.
# Collect a used boud nat_tags in $nat_bound as 
#  nat_tag => router->{name} => used
sub distribute_no_nat_set;
sub distribute_no_nat_set {
    my ($domain, $no_nat_set, $in_router, $nat_bound) = @_;

    if (not $no_nat_set or not keys %$no_nat_set) {

#        debug "Emtpy tags at $domain->{name}";
        return;
    }

#    my $tags = join(',',keys %$no_nat_set);
#    debug "distribute $tags to $domain->{name}" 
#	. ($in_router ? " from $in_router->{name}" : '');
    if ($domain->{active_path}) {

#	debug "$domain->{name} loop";
        # Found a loop
        return;
    }

    my $changed;
    for my $tag (keys %$no_nat_set) {
	next if $domain->{no_nat_set}->{$tag};
	$domain->{no_nat_set}->{$tag} = $no_nat_set->{$tag};
	$changed = 1;
    }
    return if not $changed;
    
    # Activate loop detection.
    $domain->{active_path} = 1;

    # Distribute no_nat_set to adjacent NAT domains.
    for my $router (@{ $domain->{routers} }) {
        next if $router eq $in_router;
        my $in_nat_tags = $router->{nat_tags}->{$domain};

	for my $tag (@$in_nat_tags) {
	    if (my $href = $no_nat_set->{$tag}) {
		my $net_name = (values %$href)[0]->{name};
		err_msg "$net_name is translated by $tag,\n",
		" but is located inside the translation domain of $tag.\n",
		" Probably $tag was bound to wrong interface",
		" at $router->{name}.";
	    }
	}
	for my $out_dom (@{ $router->{nat_domains} }) {
	    next if $out_dom eq $domain;
	    my %next_no_nat_set = %$no_nat_set;
	    my $nat_tags = $router->{nat_tags}->{$out_dom};
	    if (@$nat_tags >= 2) {

		# href -> [nat_tag, ..]
		my %multi;
		for my $tag (@$nat_tags) {
		    if (keys %{ $next_no_nat_set{$tag} } >=2) {
			push @{ $multi{$next_no_nat_set{$tag}} }, $tag;
		    }
		}
		if (keys %multi) {
		    for my $aref (values %multi) {
			if (@$aref >= 2) {
			    my $tags = join(',', @$aref);
			    my $net_name = 
				(values %{ $next_no_nat_set{$aref->[0]} })[0]
				->{name};
			    err_msg 
				"Must not use multiple NAT tags '$tags'",
				" of $net_name at $router->{name}";
			}
		    }
		}
	    }

	    # NAT binding removes tag from no_nat_set.
	    for my $nat_tag (@$nat_tags) {
		if (my $href = delete $next_no_nat_set{$nat_tag}) {
		    $nat_bound->{$nat_tag}->{$router->{name}} = 'used';

		    # Add other tags again if one of a group of tags 
		    # was removed.
		    if (keys %$href >= 2) {
                        
			for my $multi (keys %$href) {
			    next if $multi eq $nat_tag;
                            if (not $next_no_nat_set{$multi}) {
                                $next_no_nat_set{$multi} = $href;

                                # Prevent transition from dynamic back to 
                                # static NAT for current network.
                                if ($href->{$multi}->{dynamic} and
                                    not $href->{$nat_tag}->{dynamic} and
				    not $href->{$nat_tag}->{hidden})
                                {
                                    my $net_name = $href->{$multi}->{name};
                                    err_msg "Must not change NAT",
				    " from dynamic to static",
				    " for $net_name at $router->{name}";
                                }
				elsif ($href->{$multi}->{hidden}) {
                                    my $net_name = $href->{$multi}->{name};
                                    err_msg "Must not change hidden NAT",
				    " for $net_name at $router->{name}";
				}
                            }
			}
		    }
		}
	    }
	    distribute_no_nat_set($out_dom, \%next_no_nat_set, $router, 
				  $nat_bound);
	}
    }
    delete $domain->{active_path};
}

my @natdomains;

sub keys_equal {
    my ($href1, $href2) = @_;
    keys %$href1 == keys %$href2 or return 0;
    for my $key (keys %$href1) {
        exists $href2->{$key} or return 0;
    }
    return 1;
}

sub distribute_nat_info() {
    progress "Distributing NAT";

    # Initial value for each NAT domain, distributed by distribute_no_nat_set.
    my %no_nat_set;

    # A hash with all defined NAT tags as keys and a href as value.
    # The href has those NAT tags as keys which are used together at one 
    # network.
    # This is used to check,
    # - that all bound NAT tags are defined,
    # - that NAT tags are equally used grouped or solitary.
    my %nat_tags2multi;

    # NAT tags bound at some interface, tag => router_name => (1 | 'used').
    my %nat_bound;

    # Find NAT domains.
    for my $network (@networks) {
        my $domain = $network->{nat_domain};
        if (not $domain) {
            (my $name = $network->{name}) =~ s/^network:/nat_domain:/;

#	    debug "$name";
            $domain = new(
                'nat_domain',
                name       => $name,
                networks   => [],
                routers    => [],
                no_nat_set => {},
                );
            push @natdomains, $domain;
            set_natdomain $network, $domain, 0;
        }
#	debug "$domain->{name}: $network->{name}";

        # Collect all NAT tags defined inside one NAT domain.
        # Check consistency of grouped NAT tags at one network.
        # If NAT tags are grouped at one network,
        # the same NAT tags must be used as group at all other networks.
        if (my $href = $network->{nat}) {

            # Print error message only once per network.
            my $err;
            for my $nat_tag (keys %$href) {
                if (my $href2 = $nat_tags2multi{$nat_tag}) {
                    if (not $err and not keys_equal($href, $href2)) {
                        my $tags = join(',', keys %$href);
                        my $name = $network->{name};
                        my $tags2 = join(',', keys %$href2);

                        # Use hash as list of pairs, take first value.
                        # Value is a NAT entry with name of the network.
                        my $name2 = (%$href2)[1]->{name};
                        err_msg
                            "If multiple NAT tags are used at one network,\n",
                            " the same NAT tags must be used together at all",
                            " other networks.\n",
                            " - $name: $tags\n",
                            " - $name2: $tags2";
                        $err = 1;
                    }
                }
		else {
		    $nat_tags2multi{$nat_tag} = $href;
		}

#		debug "$domain->{name} no_nat_set: $nat_tag";
		$no_nat_set{$domain}->{$nat_tag} = $href;
            }
        }
    }
    
    # Find location where nat_tag of global NAT is bound.
    # Add this nat_tag to attribute {no_nat_set} of other NAT domains 
    # at same router, where this global NAT is not active.
    # The added nat_tag will be distributed to all NAT domains where
    # global NAT is not active.
    #
    # Find all bound nat_tags for error checks.
    my %dom_routers;
    for my $domain (@natdomains) {
        for my $router (@{ $domain->{routers} }) {
	    $dom_routers{$router} = $router;
	}
    }
    for my $router (values %dom_routers) {
	my %global;
	for my $domain (@{ $router->{nat_domains} }) {
            my $nat_tags = $router->{nat_tags}->{$domain};
            for my $tag (@$nat_tags) {
		if (my $global = $global_nat{$tag}) {
		    $global{$tag} = $global;
		}
		$nat_bound{$tag}->{$router->{name}} = 1;
	    }
	}

	# Handle router where global NAT tag is bound at one interface.
	# Add this tag to no_nat_set of NAT domains connected to this router 
	# at other interfaces.
	for my $tag (keys %global) {
	    for my $domain (@{ $router->{nat_domains} }) {
		my $nat_tags = $router->{nat_tags}->{$domain};
		if (not grep { $tag eq $_ } @$nat_tags) {
                    $no_nat_set{$domain}->{$tag} = { $tag => $global{$tag} };
		}
	    }
	}
    }

    # Distribute no_nat_set to neighbor NAT domains.
    for my $domain (@natdomains) {
	distribute_no_nat_set($domain, $no_nat_set{$domain}, 0, \%nat_bound);
    }

    # Distribute global NAT to all networks where it is applicable.
    # Add other NAT tags at networks where global NAT is added,
    # to no_nat_set of NAT domain where global NAT is applicable.
    for my $nat_tag (keys %global_nat) {
        my $global = $global_nat{$nat_tag};
	my @applicable;
	my %add;
        for my $domain (@natdomains) {
            if (not $domain->{no_nat_set}->{$nat_tag}) {
		push @applicable, $domain;
		next;
            }

#	    debug "$domain->{name}";
            for my $network (@{ $domain->{networks} }) {

                # If network has local NAT definition,
                # then skip global NAT definition.
                next if $network->{nat}->{$nat_tag};

#		debug "global nat:$nat_tag to $network->{name}";
		@add{keys %{ $network->{nat} }} = values %{ $network->{nat} };
                $network->{nat}->{$nat_tag} = { 
		    %$global, 

		    # Needed for error messages.
		    name => "nat:$nat_tag($network->{name})", };
            }
        }
	for my $domain (@applicable) {
	    @{$domain->{no_nat_set}}{keys %add} = values %add;
	}
    }

    # Check compatibility of host/interface and network NAT.
    # A NAT definition for a single host/interface is only allowed,
    # if the network has a dynamic NAT definition.
    for my $network (@networks) {
        for my $obj (@{ $network->{hosts} }, @{ $network->{interfaces} }) {
            if ($obj->{nat}) {
                for my $nat_tag (keys %{ $obj->{nat} }) {
                    my $nat_info;
                    if (    $nat_info = $network->{nat}->{$nat_tag}
                        and $nat_info->{dynamic})
                    {
                        my $obj_ip = $obj->{nat}->{$nat_tag};
                        my ($ip, $mask) = @{$nat_info}{ 'ip', 'mask' };
                        if ($ip != ($obj_ip & $mask)) {
                            err_msg "nat:$nat_tag: $obj->{name}'s IP ",
                              "doesn't match $network->{name}'s IP/mask";
                        }
                    }
                    else {
                        err_msg "nat:$nat_tag not allowed for ",
                          "$obj->{name} because $network->{name} ",
                          "doesn't have dynamic NAT definition";
                    }
                }
            }
        }
    }
    for my $tag (keys %nat_tags2multi) {
	$nat_bound{$tag} or
	    warn_msg "nat:$tag is defined, but not bound to any interafce";
    }
    for my $tag (keys %nat_bound) {
	my $href = $nat_bound{$tag};
	for my $router_name (keys %$href) {
	    $href->{$router_name} eq 'used' or
		warn_msg "Ignoring useless nat:$tag bound at $router_name";
	}
    }	
}

####################################################################
# Find sub-networks
# Mark each network with the smallest network enclosing it.
####################################################################

sub get_nat_network {
    my ($network, $no_nat_set) = @_;
    if (my $href = $network->{nat}) {
	for my $tag (keys %$href) {
	    next if $no_nat_set->{$tag};
	    return $href->{$tag}
	}
    }
    return $network;
}

# All interfaces and hosts of a network must be located in that part
# of the network which doesn't overlap with some subnet.
sub check_subnets {
    my ($network, $subnet) = @_;
    my $check = sub {
	my ($ip1, $ip2, $object) = @_;
	my $sub_ip   = $subnet->{ip};
	my $sub_mask = $subnet->{mask};
	if (
	    ($ip1 & $sub_mask) == $sub_ip
	    || $ip2 && (($ip2 & $sub_mask) == $sub_ip
			|| ($ip1 <= $sub_ip && $sub_ip <= $ip2))
	    )
	{

	    # NAT to an interface address (masquerading) is allowed.
	    if (    (my $nat_tags = $object->{bind_nat})
		    and (my ($nat_tag2) = 
			 ($subnet->{name} =~ /^nat:(.*)\(/))
		    )
	    {
		if (    grep { $_ eq $nat_tag2 } @$nat_tags
			and $object->{ip} == $subnet->{ip}
			and $subnet->{mask} == 0xffffffff)
		{
		    next;
		}
	    }

	    # Multiple interfaces with identical address are
	    # allowed on same device or 
	    # for redundancy group belonging to same device.
	    my @interfaces;
	    if (is_interface($object) and
		@interfaces = grep { $_->{ip} eq $ip1 }
		@{ $subnet->{interfaces} })
	    {
		my $interface = $interfaces[0];
		my $router = $object->{router};
		if ($router eq $interface->{router}) {
		    next;
		}
		my $r_intf = $interface->{redundancy_interfaces};
		if ($r_intf and 
		    grep { $_->{router} eq $router } @$r_intf) 
		{
		    next;
		}
	    }
	    warn_msg "$object->{name}'s IP overlaps with subnet",
	    " $subnet->{name}";
	}
    };
    for my $interface (@{ $network->{interfaces} }) {
	my $ip = $interface->{ip};
	next if $ip =~ /^\w/;
	$check->($ip, undef, $interface);
    }
    for my $host (@{ $network->{hosts} }) {
	if (my $ip = $host->{ip}) {
	    $check->($ip, undef, $host);
	}
	elsif (my $range = $host->{range}) { 
	    $check->($range->[0], $range->[1], $host);
	}
    }
}	    

sub find_subnets() {
    progress "Finding subnets";
    my %seen;
    for my $domain (@natdomains) {

#     debug "$domain->{name}";
        my $no_nat_set = $domain->{no_nat_set};
        my %mask_ip_hash;
        my %identical;
        my %key2obj;
        for my $network (@networks) {
            next if $network->{ip} =~ /^(?:unnumbered|tunnel)$/;
            my $nat_network = get_nat_network($network, $no_nat_set);
	    next if $nat_network->{hidden};
            my ($ip, $mask) = @{$nat_network}{ 'ip', 'mask' };

            # Found two different networks with identical IP/mask.
            # in current NAT domain.
            if (my $old_net = $mask_ip_hash{$mask}->{$ip}) {
                my $nat_old_net = get_nat_network($old_net, $no_nat_set);

                # Prevent aliasing of loop variable.
                my $network = $network;
                my $error;
                if ($nat_old_net->{dynamic} and $nat_network->{dynamic}) {

                    # Dynamic NAT of different networks 
		    # to a single new IP/mask is OK.
                }
                elsif ($nat_old_net->{loopback} and $nat_network->{dynamic}
                    or $nat_old_net->{dynamic} and $nat_network->{loopback})
                {

                    # Store loopback network, ignore translated network.
                    if ($nat_old_net->{dynamic}) {
                        $mask_ip_hash{$mask}->{$ip} = $network;
                        ($old_net, $network) = ($network, $old_net);
                        ($nat_old_net, $nat_network) =
                          ($nat_network, $nat_old_net);
                    }

                    # Dynamic NAT to loopback interface is OK,
                    # if NAT is applied at device of loopback interface.
                    my $nat_tag1      = $nat_network->{dynamic};
                    my $all_device_ok = 0;

                    # In case of virtual loopback, the loopback network
                    # is attached to two or more routers.
                    # Loop over these devices.
                    for my $loop_intf (@{ $nat_old_net->{interfaces} }) {
                        my $this_device_ok = 0;

                        # Check all interfaces of attached device.
                        for
                          my $all_intf (@{ $loop_intf->{router}->{interfaces} })
                        {
                            if (my $nat_tags = $all_intf->{bind_nat}) {
                                if (grep { $_ eq $nat_tag1 } @$nat_tags) {
                                    $this_device_ok = 1;
                                }
                            }
                        }
                        $all_device_ok += $this_device_ok;
                    }
                    if ($all_device_ok != @{ $nat_old_net->{interfaces} }) {
                        $error = 1;
                    }
                }
                else {
                    $error = 1;
                }
                if ($error) {
                    my $name1 = $nat_network->{name};
                    my $name2 = $nat_old_net->{name};
                    err_msg "$name1 and $name2 have identical IP/mask";
                }
                else {

                    # Remember identical networks.
                    $identical{$network} = $old_net;
                    $key2obj{$network}   = $network;
                }
            }
            else {

                # Store original network under NAT IP/mask.
                $mask_ip_hash{$mask}->{$ip} = $network;
            }
        }
        for my $net_key (keys %identical) {
            my $one_net = $identical{$net_key};
            while (my $next = $identical{$one_net}) {
                $one_net = $next;
            }
            my $network = $key2obj{$net_key};
            $network->{is_identical}->{$no_nat_set} = $one_net;

#           debug "Identical: $network->{name}: $one_net->{name}";
        }

        # Go from smaller to larger networks.
        for my $mask (reverse sort keys %mask_ip_hash) {

            # Network 0.0.0.0/0.0.0.0 can't be subnet.
            last if $mask == 0;
            for my $ip (keys %{ $mask_ip_hash{$mask} }) {

                my $m = $mask;
                my $i = $ip;
                while ($m) {

                    # Clear upper bit, because left shift is undefined
                    # otherwise.
                    $m &= 0x7fffffff;
                    $m <<= 1;
                    $i &= $m;
                    if ($mask_ip_hash{$m}->{$i}) {
                        my $bignet = $mask_ip_hash{$m}->{$i};
                        my $subnet = $mask_ip_hash{$mask}->{$ip};
			my $nat_subnet = get_nat_network($subnet, $no_nat_set);
			my $nat_bignet = get_nat_network($bignet, $no_nat_set);

                        # Mark subnet relation.
                        # This may differ for different NAT domains.
                        $subnet->{is_in}->{$no_nat_set} = $bignet;

			last if $seen{$nat_bignet}->{$nat_subnet};
			$seen{$nat_bignet}->{$nat_subnet} = 1;
                        if ($config{check_subnets}) {

                            # Take original $bignet, because currently
                            # there's no method to specify a natted network
                            # as value of subnet_of.
                            if (not ($bignet->{route_hint}
				     or $nat_subnet->{subnet_of}
				     and $nat_subnet->{subnet_of} eq $bignet))
                            {

                                # Prevent multiple error messages in different
                                # NAT domains.
                                $nat_subnet->{subnet_of} = $bignet;

                                my $msg =
                                    "$nat_subnet->{name} is subnet of"
				    . " $nat_bignet->{name}\n"
				    . " if desired, either declare attribute"
				    . " 'subnet_of' or attribute 'route_hint'";

                                if ($config{check_subnets} eq 'warn') {
                                    warn_msg $msg;
                                }
                                else {
                                    err_msg $msg;
                                }
                            }
                        }

			check_subnets($nat_bignet, $nat_subnet);

                        # We only need to find the smallest enclosing network.
                        last;
                    }
                }
            }
        }
    }
}

# Clear-text interfaces of VPN cluster servers need to be attached
# to the same security domain.
# We need this to get consistent auto_deny_networks for all cluster members.
sub check_vpnhub () {
    my %hub2routers;
    for my $router (@managed_vpnhub) {
        for my $interface (@{ $router->{interfaces} }) {
            if (my $hubs = $interface->{hub}) {
		for my $hub (@$hubs) {
		    push @{ $hub2routers{$hub} }, $router;
		}
            }
        }
    }
    my $all_eq_cluster = sub {
        my (@obj) = @_;
        my $obj1 = pop @obj;
	my $cluster1 = $obj1->{any_cluster};
        not grep { $_->{any_cluster} != $cluster1 } @obj;
    };
    for my $routers (values %hub2routers) {
        my @anys =
          map {
            (grep { $_->{no_check} } @{ $_->{interfaces} })[0]->{any}
          } @$routers;
        $all_eq_cluster->(@anys)
          or err_msg "Clear-text interfaces of\n ",
          join(', ', map({ $_->{name} } @$routers)),
          "\n must all be connected to the same security domain.";
    }
}

sub check_no_in_acl () {
    
    # Propagate attribute 'no_in_acl' from 'any' objects to interfaces.
    for my $any (@all_anys) {
	next if not $any->{no_in_acl};
#	debug "$any->{name} has attribute 'no_in_acl'";
	for my $interface (@{ $any->{interfaces} }) {

	    # Ignore secondary interface.
	    next if $interface->{main_interface};

	    my $router = $interface->{router};

	    # Directly attached attribute 'no_in_acl' or 
	    # attribute 'std_in_acl' at device overrides.
	    if ($router->{std_in_acl} or
		grep({ $_->{no_in_acl} and not ref $_->{no_in_acl} } 
		     @{ $router->{interfaces} })) 
	    {
		next;
	    }
	    $interface->{no_in_acl} = $any;
	}
    }

    # Move attribute 'no_in_acl' to hardware interface
    # because ACLs operate on hardware, not on logic.
    for my $router (@managed_routers) {

	# At most one interface with 'no_in_acl' allowed.
	# Move attribute to hardware interface.
	my $counter = 0;
        for my $interface (@{ $router->{interfaces} }) {
	    if (delete $interface->{no_in_acl}) {
		my $hardware = $interface->{hardware};
		$hardware->{no_in_acl} = 1;

		# Ignore secondary interface.
		1 == grep({ not $_->{main_interface} } 
			  @{ $hardware->{interfaces} }) or
		    err_msg 
		    "Only one logical interface allowed at $hardware->{name}",
		    " because it has attribute 'no_in_acl'";
		$counter++;
		$router->{no_in_acl} = $interface;
	    }
	}
	next if not $counter;
	$counter == 1 or
	    err_msg "At most one interface of $router->{name}",
	    " may use flag 'no_in_acl'";
	$router->{model}->{has_out_acl} or
	    err_msg "$router->{name} doesn't support outgoing ACL";

	if (grep { $_->{hub} or $_->{spoke} } @{ $router->{interfaces} }) {
	    err_msg "Don't use attribute 'no_in_acl' together",
	    " with crypto tunnel at $router->{name}";
	}

	# Mark other hardware with attribute 'need_out_acl'.
	for my $hardware (@{ $router->{hardware} }) {
	    $hardware->{no_in_acl} or 
		$hardware->{need_out_acl} = 1;
	}
    }	
}

# This uses attributes from sub check_no_in_acl.
sub check_crosslink () {
    for my $network (values %networks) {
	next if not $network->{crosslink};

	# A crosslink network combines two or more routers
	# to one virtual router.
	# No filtering occurs at the crosslink interfaces.
	my @managed_type;
	my $out_acl_count = 0;
	my @no_in_acl_intf;
	for my $interface (@{ $network->{interfaces} }) {
	    my $router = $interface->{router};
	    if (my $managed = $router->{managed}) {
		push @managed_type, $managed;
	    }
	    else {
		err_msg "Crosslink $network->{name} must not be",
		"connected to unmanged $router->{name}";
		next;
	    }
	    my $hardware = $interface->{hardware};
	    @{ $hardware->{interfaces} } == 1 or
		err_msg 
		"Crosslink $network->{name} must be the only  network\n",
		" connected to $hardware->{name} of $router->{name}";
	    if ($hardware->{need_out_acl}) {
		$out_acl_count++;
	    }
	    push @no_in_acl_intf, grep({ $_->{hardware}->{no_in_acl} }
				       @{ $router->{interfaces} });
	    $hardware->{crosslink} = 1;
	}

	# Ensure clear resposibility for filtering.
	equal(@managed_type) or
	    err_msg "All devices at crosslink $network->{name}",
	    " must have identical managed type";

	not $out_acl_count or
	    $out_acl_count == @{ $network->{interfaces}} or
	    err_msg "All interfaces must equally use or not use outgoing ACLs",
	    " at crosslink $network->{name}";
	equal(map { $_->{any} } @no_in_acl_intf) or
	    err_msg "All interfaces with attribute 'no_in_acl'",
	    " at routers connected by\n crosslink $network->{name}",
	    " must be border of the same security domain";
    }
}

####################################################################
# Borders of security domains are
# a) interfaces of managed devices and
# b) interfaces of devices, which have at least one pathrestriction applied.
#
# For each security domain find its associated 'any' object or
# generate a new one if none was declared.
# Link each interface at the border of this security domain with
# its 'any' object and vice versa.
# Additionally link each network and unmanaged router in this security
# domain with the associated 'any' object.
# Add a list of all numbered networks of a security domain to its
# 'any' object.
####################################################################
sub setany_network( $$$ );

sub setany_network( $$$ ) {
    my ($network, $any, $in_interface) = @_;
    if ($network->{any}) {

        # Found a loop inside a security domain.
        return;
    }
    $network->{any} = $any;

    # Add network to the corresponding 'any' object,
    # to have all networks of a security domain available.
    # Unnumbered networks are left out here because
    # they aren't a valid src or dst.
    unless ($network->{ip} =~ /^(?:unnumbered|tunnel)$/) {
        push @{ $any->{networks} }, $network;
    }
    for my $interface (@{ $network->{interfaces} }) {

        # Ignore interface where we reached this network.
        next if $interface eq $in_interface;
        my $router = $interface->{router};
        if ($router->{managed} or $router->{semi_managed}) {
            $interface->{any} = $any;
            push @{ $any->{interfaces} }, $interface;
        }
        else {
            push @{ $any->{unmanaged_routers} }, $router;
            for my $out_interface (@{ $router->{interfaces} }) {

                # Ignore interface where we reached this router.
                next if $out_interface eq $interface;
                setany_network $out_interface->{network}, $any, $out_interface;
            }
        }
    }
}

# Mark cluster of 'any' objects which is connected by unmanaged devices.
sub setany_cluster( $$$ );
sub setany_cluster( $$$ ) {
    my ($any, $in_interface, $counter) = @_;
    my $restrict;
    $any->{any_cluster} = $counter;
#    debug "$counter: $any->{name}";
    for my $interface (@{ $any->{interfaces} }) {
        next if $interface eq $in_interface;

	# Ignore interface with globally active pathrestriction
	# where all traffic goes through a VPN tunnel.
	next if $restrict = $interface->{path_restrict} and
	    grep { $_ eq $global_active_pathrestriction } @$restrict;
        my $router = $interface->{router};
        if (not $router->{managed}) {
            for my $out_interface (@{ $router->{interfaces} }) {
                next if $out_interface eq $interface;
		my $next = $out_interface->{any};
		next if $next->{any_cluster};
		next if $restrict = $out_interface->{path_restrict} and
		    grep { $_ eq $global_active_pathrestriction } @$restrict;
                setany_cluster $next, $out_interface, $counter;
            }
        }
    }
}

# Collect all 'any' objects belonging to an area.
# Set attribute {border} for areas defined by anchor and auto_border.
sub setarea1( $$$ );

sub setarea1( $$$ ) {
    my ($any, $area, $in_interface) = @_;
    if ($any->{areas}->{$area}) {

        # Found a loop.
        return;
    }

    # Add any object to the corresponding area,
    # to have all any objects of an area available.
    push @{ $area->{anys} }, $any;

    # This will be used to prevent duplicate traversal of loops and
    # later to check for duplicate and overlapping areas.
    $any->{areas}->{$area} = $area;
    my $auto_border = $area->{auto_border};
    my $lookup      = $area->{intf_lookup};
    for my $interface (@{ $any->{interfaces} }) {

        # Ignore interface where we reached this area.
        next if $interface eq $in_interface;

        if ($auto_border) {
            if ($interface->{is_border}) {
                push @{ $area->{border} }, $interface;
                next;
            }
        }

        # Found another border of current area.
        elsif ($lookup->{$interface}) {

            # Remember that we have found this other border.
            $lookup->{$interface} = 'found';
            next;
        }

        # Ignore secondary or virtual interface, because we check main interface.
        next if $interface->{main_interface};

        # Ignore tunnel interface. We can't test for {real_interface} here
        # because it may still be unknown.
        next if $interface->{ip} eq 'tunnel';

        my $router = $interface->{router};
        for my $out_interface (@{ $router->{interfaces} }) {

            # Ignore interface where we reached this router.
            next if $out_interface eq $interface;

            if ($auto_border) {
                if ($out_interface->{is_border}) {

                    # Take interface where we reached this router.
                    push @{ $area->{border} }, $interface;
                    next;
                }
            }

            # Found another border of current area from wrong side.
            elsif ($lookup->{$out_interface}) {
                err_msg "Inconsistent definition of $area->{name}",
                  " in loop at $out_interface->{name}";
                next;
            }
            setarea1 $out_interface->{any}, $area, $out_interface;
        }
    }
}


# Find managed routers _inside_ an area.
sub area_managed_routers {
    my ($area) = @_;

    # Fill hash with all border routers of security domains
    # including border routers of current area.
    my %routers =
	map {
            my $router = $_->{router};
            ($router => $router)
	    }
    map @{ $_->{interfaces} }, @{ $area->{anys} };

    # Remove border routers, because we only
    # need routers inside this area.
    for my $interface (@{ $area->{border} }) {
	delete $routers{ $interface->{router} };
    }

    # Remove semi_managed routers.
    return grep { $_->{managed} } values %routers;
}
    
sub inherit_router_attributes () {

    # Areas can be nested. Proceed from small to larger ones.
    for my $area (sort { @{$a->{anys}} <=> @{$b->{anys}} }
		  grep { not $_->{disabled} } values %areas) {
	my $attributes = $area->{router_attributes} or next;
	$attributes->{owner} and keys %$attributes == 1 and next;
	for my $router (area_managed_routers($area)) {
	    for my $key (keys %$attributes) {

		# Owner is handled in propagate_owners.
		if (not $key eq 'owner') {
		    $router->{$key} ||= $attributes->{$key};
		}
	    }
	}
    }
}

sub setany() {
    progress "Preparing security domains and areas";
    for my $any (@all_anys) {
        $any->{networks} = [];
        my $network = $any->{link};
        if (my $old_any = $network->{any}) {
            err_msg
              "More than one 'any' object defined in a security domain:\n",
              " $old_any->{name} and $any->{name}";
        }
        is_network $network
          or internal_err "unexpected object $network->{name}";
        setany_network $network, $any, 0;
    }

    # Automatically add an 'any' object to each security domain
    # where none has been declared.
    for my $network (@networks) {
        next if $network->{any};
        my $name = "any:[$network->{name}]";
        my $any = new('Any', name => $name, link => $network);
        $any->{networks} = [];
        push @all_anys, $any;
        setany_network $network, $any, 0;
    }

    my $cluster_counter = 1;
    for my $any (@all_anys) {

        # Make results deterministic.
        @{ $any->{networks} } =
          sort { $a->{mask} <=> $b->{mask} || $a->{ip} <=> $b->{ip} }
          @{ $any->{networks} };

	# Mark clusters of 'any' objects, which are connected by an
	# unmanaged (semi_managed) device.
	next if $any->{any_cluster};
	setany_cluster($any, 0, $cluster_counter++);
    }

    check_no_in_acl;
    check_crosslink;
    check_vpnhub;

    # Mark interfaces, which are border of some area.
    # This is needed to locate auto_borders.
    for my $area (@all_areas) {
        next unless $area->{border};
        for my $interface (@{ $area->{border} }) {
            $interface->{is_border} = 1;
        }
    }
    for my $area (@all_areas) {
        if (my $network = $area->{anchor}) {
            setarea1 $network->{any}, $area, 0;
        }
        elsif (my $interfaces = $area->{border}) {

            # For efficient look up if some interface is border of current area.
            my %lookup;
            for my $interface (@$interfaces) {
                $lookup{$interface} = 1;
            }
            $area->{intf_lookup} = \%lookup;
            my $start = $interfaces->[0];
            $lookup{$start} = 'found';
            setarea1 $start->{any}, $area, $start;
            if (my @bad_intf = grep { $lookup{$_} ne 'found' } @$interfaces) {
                err_msg "Invalid border of $area->{name}\n ", join "\n ",
                  map $_->{name}, @bad_intf;
                $area->{border} =
                  [ grep { $lookup{$_} eq 'found' } @$interfaces ];
            }
        }

#     debug "$area->{name}:\n ", join "\n ", map $_->{name}, @{$area->{anys}};
    }

    # Find subset relation between areas.
    # Complain about duplicate and overlapping areas.
    for my $any (@all_anys) {
        next unless $any->{areas};

        # Ignore empty hash.
        my @areas = values %{ $any->{areas} } or next;
        @areas = sort { @{ $a->{anys} } <=> @{ $b->{anys} } } @areas;

        # Take the smallest area.
        my $small = shift @areas;
        while (@areas) {
            my $next = shift @areas;
            if (my $big = $small->{subset_of}) {
                $big eq $next
                  or internal_err "$small->{name} is subset of",
                  " $big->{name} and $next->{name}";
            }
            else {

                # Each 'any' object of $small must be part of $next.
                my $ok = 1;
                for my $any (@{ $small->{anys} }) {
                    unless ($any->{areas}->{$small}) {
                        $ok = 0;
                        err_msg "Overlapping $small->{name} and $next->{name}";
                        last;
                    }
                }
                if ($ok) {
                    if (@{ $small->{anys} } == @{ $next->{anys} }) {
                        err_msg "Duplicate $small->{name} and $next->{name}";
                    }
                    else {
                        $small->{subset_of} = $next;
                    }
                }
            }
            $small = $next;
        }
    }
    for my $area (@all_areas) {

        # Make result deterministic. Needed for network:[area:xx].
        @{ $area->{anys} } =
          sort { $a->{name} cmp $b->{name} } @{ $area->{anys} };

        # Tidy up: Delete unused attribute.
        delete $area->{intf_lookup};
        for my $interface (@{ $area->{border} }) {
            delete $interface->{is_border};
        }
    }
    inherit_router_attributes();
}

####################################################################
# Virtual interfaces
####################################################################

# Interfaces with identical virtual IP must be located inside the same loop.
sub check_virtual_interfaces () {
    my %seen;
    for my $interface (@virtual_interfaces) {
	my $related = $interface->{redundancy_interfaces};

	# Is not set, if other errors have been reported.
	next if not $related;

	# Loops inside a security domain are not known
	# and therefore can't be checked.
	my $router = $interface->{router};
	next if not ($router->{managed} or $router->{semi_managed});
	
	my $err;
	for my $v (@$related) {
	    next if $seen{$v};
	    $seen{$v} = 1;
	    if (not $v->{router}->{loop}) {
		err_msg "Virtual IP of $v->{name}\n",
		" must be located inside cyclic sub-graph";
		$err = 1;
		next;
	    }
	}
	next if $err;
	equal(map { $_->{loop} } @$related)
	    or err_msg "Virtual interfaces\n ",
	    join(', ', map({ $_->{name} } @$related)),
	    "\n must all be part of the same cyclic sub-graph";
    }
}

####################################################################
# Check pathrestrictions
####################################################################

sub check_pathrestrictions() {
    for my $restrict (values %pathrestrictions) {
        for my $obj (@{ $restrict->{elements} }) {

            # Interfaces with pathrestriction need to be located
            # inside or at the border of cyclic graphs.
            if (not ($obj->{loop} || 
		     $obj->{router}->{loop} || 
		     $obj->{any}->{loop})) 
	    {
		delete $obj->{path_restrict};
		warn_msg "Ignoring $restrict->{name} at $obj->{name}\n",
		" because it isn't located inside cyclic graph";
	    }
        }
    }
}

####################################################################
# Set paths for efficient topology traversal
####################################################################

# Parameters:
# $obj: a managed or semi-managed router or an 'any' object
# $to_any1: interface of $obj; go this direction to reach any1
# $distance: distance to any1
# Return value:
# - undef: found path is not part of a loop
# - loop-marker: 
#   - found path is part of a loop
#   - a hash, which is referenced by all members of the loop
#     with this attributes:
#     - exit: that node of the loop where any1 is reached
#     - distance: distance of the exit node + 1.
sub setpath_obj( $$$ );
sub setpath_obj( $$$ ) {
    my ($obj, $to_any1, $distance) = @_;

#    debug("-- $distance: $obj->{name} --> $to_any1->{name}");
    if ($obj->{active_path}) {

        # Found a loop; this is possibly exit of the loop to any1.
        # Generate unique loop marker which references this object.
        # Distance is needed for cluster navigation.
        # We need a copy of the distance value inside the loop marker
        # because distance at object is reset later to the value of the 
	# cluster exit object.
        # We must use an intermediate distance value for cluster_navigation 
	# to work.
        return $to_any1->{loop} = { exit => $obj,
                                    distance => $obj->{distance} + 1, };
    }

    # Mark current path for loop detection.
    $obj->{active_path} = 1;
    $obj->{distance}    = $distance;

    my $get_next = is_router $obj ? 'any' : 'router';
    for my $interface (@{ $obj->{interfaces} }) {

        # Ignore interface where we reached this obj.
        next if $interface eq $to_any1;

        # Ignore interface which is the other entry of a loop which is
        # already marked.
        next if $interface->{loop};
        my $next = $interface->{$get_next};

        # Increment by 2 because we need an intermediate value above.
        if (my $loop = setpath_obj $next, $interface, $distance + 2) {
            my $loop_obj = $loop->{exit};

            # Found exit of loop in direction to any1.
            if ($obj eq $loop_obj) {

                # Mark with a different marker linking to itself.
                # If current loop is part of a cluster, 
                # this marker will be overwritten later.
                # Otherwise this is the exit of a cluster of loops.
                $obj->{loop} ||= { exit => $obj, distance => $distance, };
            }

            # Found intermediate loop node which was marked before.
            elsif (my $loop2 = $obj->{loop}) {
                if ($loop ne $loop2) {
                    if ($loop->{distance} < $loop2->{distance}) {
                        $loop2->{redirect} = $loop;
                        $obj->{loop} = $loop;
                    }
                    else {
                        $loop->{redirect} = $loop2;
                    }
                }
            }

            # Found intermediate loop node.
            else {
                $obj->{loop} = $loop;
            }
            $interface->{loop} = $loop;
        }
        else {

            # Continue marking loop-less path.
            $interface->{main} = $obj;
        }
    }
    delete $obj->{active_path};
    if($obj->{loop} and $obj->{loop}->{exit} ne $obj) {
        return $obj->{loop};

    }
    else {
        $obj->{main} = $to_any1;
        return 0;
    }
}

# Find cluster of directly connected loops.
# Find exit node of the cluster in direction to any1;
# Its loop attribute has a reference to the node itself.
# Add this exit node as marker to all loops belonging to the cluster.
sub set_loop_cluster {
    my ($loop) = @_;
    if(my $marker = $loop->{cluster_exit}) {
        return $marker;
    }
    else {
        my $exit = $loop->{exit};

        # Exit node has loop marker which references the node itself.
        if ($exit->{loop} eq $loop) {
#           debug "Loop $exit->{name},$loop->{distance} is in cluster $exit->{name}";
            return $loop->{cluster_exit} = $exit;
        }
        else {
            my $cluster = set_loop_cluster($exit->{loop});
#           debug "Loop $exit->{name},$loop->{distance} is in cluster $cluster->{name}";
            return $loop->{cluster_exit} = $cluster;
        }
    }
}

sub setpath() {
    progress "Preparing fast path traversal";

    # Take a random object from @all_anys, name it "any1".
    @all_anys or fatal_err "Topology seems to be empty";
    my $any1 = $all_anys[0];

    # Starting with any1, do a traversal of the whole topology
    # to find a path from every 'any' object and router to any1.
    # Second  parameter is used as placeholder for a not existing
    # starting interface. Value must be "true" and unequal to any interface.
    # Third parameter is distance from $any1 to $any1.
    setpath_obj $any1, {}, 0;

    # Check if all objects are connected with any1.
    my @unconnected;
    my @path_routers = grep { $_->{managed} || $_->{semi_managed} } @routers;
    for my $object (@all_anys, @path_routers) {
        next if $object->{main} or $object->{loop};
        push @unconnected, $object;

        # Ignore all other objects connected to the just found object.
        setpath_obj $object, {}, 0;
    }
    if (@unconnected) {
        my $msg = "Topology has unconnected parts:";
        for my $object ($any1, @unconnected) {
            $msg .= "\n $object->{name}";
        }
        fatal_err $msg;
    }

    for my $obj (@all_anys, @path_routers) {
        my $loop = $obj->{loop} or next;

        # Check all 'any' objects and routers located inside a cyclic
        # graph. Propagate loop exit into sub-loops.
        while (my $next = $loop->{redirect}) {
#           debug "Redirect: $loop->{exit}->{name} -> $next->{exit}->{name}";
            $loop = $next;
        }
        $obj->{loop} = $loop;

        # Mark connected loops with cluster exit.
        set_loop_cluster($loop);

        # Set distance of loop objects to value of cluster exit.
        $obj->{distance} = $loop->{cluster_exit}->{distance};
    }
    for my $router (@path_routers) {
        for my $interface (@{$router->{interfaces}}) {
            if(my $loop = $interface->{loop}) {
                while (my $next = $loop->{redirect}) {
                    $loop = $next;
                }
                $interface->{loop} = $loop;
            }
        }
    }

    # This is called here and not at link_topology because it needs
    # attribute {loop}.
    check_pathrestrictions;
    check_virtual_interfaces;
}

####################################################################
# Efficient path traversal.
####################################################################

my %obj2path;

sub get_path( $ ) {
    my ($obj) = @_;
    my $type = ref $obj;
    my $result;
    if ($type eq 'Network') {
        $result = $obj->{any};
    }
    elsif ($type eq 'Subnet') {
        $result = $obj->{network}->{any};
    }
    elsif ($type eq 'Interface') {
 	if($obj->{router}->{managed}) {

	    # If this is a secondary interface, we can't use it to enter
	    # the router, because it has an active pathrestriction attached.
	    # But it doesn't matter if we use the main interface instead.
	    my $obj2 = $obj->{main_interface} || $obj;

	    # Special handling needed if $src or $dst is interface
	    # which has pathrestriction attached.
	    if ($obj->{path_restrict}) {
		$result = $obj2;
	    }
	    else {
		$result = $obj2->{router};
	    }
	}
	else {
	    $result = $obj->{network}->{any};
	}
    }
    elsif ($type eq 'Any') {
        $result = $obj;
    }

    # This is only used, when called from path_auto_interfaces.
    elsif ($type eq 'Router') {
 	if($obj->{managed} || $obj->{semi_managed}) {
	    $result = $obj;
	}
	else {
	    $result = $obj->{interfaces}->[0]->{network}->{any};  
	}
    }

    # This is only used, if Netspoc.pm is called from report.pl.
    elsif ($type eq 'Host') {
        $result = $obj->{network}->{any};
    }
    else {
        internal_err "unexpected $obj->{name}";
    }

#    debug "get_path: $obj->{name} -> $result->{name}";
    $obj2path{$obj} = $result;
}

# Converts hash key of reference back to reference.
my %key2obj;

sub cluster_path_mark1( $$$$$$$$ );

sub cluster_path_mark1( $$$$$$$$ ) {

    my ($obj, $in_intf, $end, $path_tuples, $loop_leave, 
        $start_intf, $end_intf, $navi) = @_;
    my @pathrestriction =
      $in_intf->{path_restrict}
      ? @{ $in_intf->{path_restrict} }
      : ();

    # Handle special case where path starts or ends at an interface with
    # pathrestriction.
    # If the router is left / entered via the same interface, ignore the PR.
    # If the router is left / entered via some other interface,
    # activate the PR of the start- / end interface before checking the current
    # interface.
    for my $intf ($start_intf, $end_intf) {
        if ($intf and $in_intf->{router} eq $intf->{router}) {
            if ($in_intf eq $intf) {
                @pathrestriction = ();
            }
            else {
                for my $restrict1 (@{ $intf->{path_restrict} }) {
                    for my $restrict2 (@pathrestriction) {
                        return 0 if $restrict1 eq $restrict2;
                    }
                }
                push @pathrestriction, @{ $intf->{path_restrict} };
            }
        }
    }

#  debug "cluster_path_mark1: obj: $obj->{name},
#        in_intf: $in_intf->{name} to: $end->{name}";
    # Check for second occurrence of path restriction.
    for my $restrict (@pathrestriction) {
        if ($restrict->{active_path}) {

#           debug " effective $restrict->{name} at $in_intf->{name}";
            return 0;
        }
    }

    # Don't walk loops.
    if ($obj->{active_path}) {

#       debug " active: $obj->{name}";
        return 0;
    }

    # Found a path to router or 'any' object.
    if ($obj eq $end) {

        # Mark interface where we leave the loop.
        $loop_leave->{$in_intf} = $in_intf;

#     debug " leave: $in_intf->{name} -> $end->{name}";
        return 1;
    }

    # Mark current path for loop detection.
    $obj->{active_path} = 1;

    # Mark first occurrence of path restriction.
    for my $restrict (@pathrestriction) {

#       debug " enabled $restrict->{name} at $in_intf->{name}";
        $restrict->{active_path} = 1;
    }
    my $get_next = is_router $obj ? 'any' : 'router';
    my $success = 0;

    # Fill hash for restoring reference from hash key.
    $key2obj{$in_intf} = $in_intf;
    my $allowed = $navi->{$obj->{loop}};
    for my $interface (@{ $obj->{interfaces} }) {
        next if $interface eq $in_intf;
        my $loop = $interface->{loop};
	$allowed or internal_err "Loop with empty navigation";
        next if not $loop or not $allowed->{$loop};
        my $next = $interface->{$get_next};
        if (
            cluster_path_mark1(
                $next,       $interface,  $end,      $path_tuples,
                $loop_leave, $start_intf, $end_intf, $navi
            )
          )
        {

            # Found a valid path from $next to $end.
            $key2obj{$interface} = $interface;
	    $path_tuples->{$in_intf}->{$interface} = is_router $obj;

#	    debug " loop: $in_intf->{name} -> $interface->{name}";
            $success = 1;
        }
    }
    delete $obj->{active_path};
    for my $restrict (@pathrestriction) {

#     debug " disabled $restrict->{name} at $in_intf->{name}";
        $restrict->{active_path} = undef;
    }
    return $success;
}

# Optimize navigation inside a cluster of loops.
# Mark each loop marker
# with the allowed loops to be gone to reach $to.
# The direction is given as a loop object.
# It can be used to look up interfaces which reference 
# this loop object in attribute {loop}.
# Return value: 
# A hash with pairs: object -> loop-marker
sub cluster_navigation( $$ ) {
    my ($from, $to) = @_;
    my $from_loop = $from->{loop};
    my $to_loop   = $to->{loop};

#    debug "Navi: $from->{name}, $to->{name}";

    my $navi;
    if(($navi = $from->{navi}->{$to}) and scalar keys %$navi) {
#	debug " Cached";
	return $navi;
    }
    $navi = $from->{navi}->{$to} = {};

    while(1) {
        if ($from_loop eq $to_loop) {
	    last if $from eq $to;
	    $navi->{$from_loop}->{$from_loop} = 1;
#	    debug "- Eq: $from_loop->{exit}->{name}$from_loop to itself";

	    # Path $from -> $to goes through $from_loop and through $exit_loop.
	    # Inside $exit_loop, enter only $from_loop, but no other loops.
	    my $exit_loop = $from_loop->{exit}->{loop};
	    $navi->{$exit_loop}->{$from_loop} = 1;
#	    debug "- Add $from_loop->{exit}->{name}$from_loop to exit $exit_loop->{exit}->{name}$exit_loop";
            last;
        }
        elsif ($from_loop->{distance} >= $to_loop->{distance}) {
	    $navi->{$from_loop}->{$from_loop} = 1;
#	    debug "- Fr: $from_loop->{exit}->{name}$from_loop to itself";
	    $from = $from_loop->{exit};
            $from_loop = $from->{loop};
        }
        else {
	    $navi->{$to_loop}->{$to_loop} = 1;
#	    debug "- To: $to_loop->{exit}->{name}$to_loop to itself";
	    $to = $to_loop->{exit};
            my $entry_loop = $to->{loop};
	    $navi->{$entry_loop}->{$to_loop} = 1;
#	    debug "- Add $to_loop->{exit}->{name}$to_loop to entry $entry_loop->{exit}->{name}$entry_loop";
            $to_loop = $entry_loop;
        }
    }
    $navi;
}

# Mark paths inside a cluster of loops.
# $from and $to are entry and exit objects inside the cluster.
# The cluster is entered at interface $from_in and left at interface $to_out.
# For each pair of $from / $to, we collect attributes:
# {loop_enter}: interfaces of $from, where the cluster is entered,
# {path_tuples}: tuples of interfaces, which describe all valid paths,
# {loop_leave}: interfaces of $to, where the cluster is left.
# Return value is true if a valid path was found.
#
# $from_store is the starting object of the whole path.
# If the path starts at an interface of a loop and it has a pathrestriction attached,
# $from_store contains this interface.
sub cluster_path_mark ( $$$$$$ ) {
    my ($from, $to, $from_in, $to_out, $from_store, $to_store) = @_;

    # This particular path through this sub-graph is already known.
    return 1 if $from_in->{path}->{$to_store};

    # Start and end interface or undef.
    # It is set, if the path starts / ends
    # - at an interface inside the loop or
    # - at an interface at the border of the loop
    #   (an interface of a router/any inside the loop)
    # - this interface has a pathrestriction attached.
    my ($start_intf, $end_intf);

    # Check, if loop is entered or left at interface with pathrestriction.
    # - is $from_store located inside or at border of current loop?
    # - does $from_in at border of current loop have pathrestriction ?
    # dito for $to_store and $to_out.
    my ($start_store, $end_store);
    if (is_interface $from_store
        and ($from_store->{router} eq $from or $from_store->{any} eq $from))
    {
        $start_intf  = $from_store;
        $start_store = $from_store;
    }
    elsif ($from_in and $from_in->{path_restrict}) {
        $start_store = $from_in;
    }
    else {
        $start_store = $from;
    }
    if (is_interface $to_store
        and ($to_store->{router} eq $to or $to_store->{any} eq $to))
    {
        $end_intf  = $to_store;
        $end_store = $to_store;
    }
    elsif ($to_out and $to_out->{path_restrict}) {
        $end_store = $to_out;
    }
    else {
        $end_store = $to;
    }

    my $success = 1;

#    debug "cluster_path_mark: $start_store->{name} -> $end_store->{name}";

    # Activate pathrestriction of interface at border of loop, if path starts
    # or ends outside the loop and enters the loop at such an interface.
    for my $intf ($from_in, $to_out) {
        if (    $intf
            and not $intf->{loop}
            and (my $restrictions = $intf->{path_restrict}))
        {
            for my $restrict (@$restrictions) {
                if ($restrict->{active_path}) {

                    # Pathrestriction at start and end interface
                    # prevents traffic through loop.
                    $success = 0;
                }
                $restrict->{active_path} = 1;
            }
        }
    }

    # If start / end interface is part of a group of virtual
    # interfaces (VRRP, HSRP),
    # prevent traffic through other interfaces of this group.
    for my $intf ($start_intf, $end_intf) {
        if ($intf and (my $interfaces = $intf->{redundancy_interfaces})) {
            for my $interface (@$interfaces) {
                next if $interface eq $intf;
                push @{ $interface->{path_restrict} },
                  $global_active_pathrestriction;
            }
        }
    }

  BLOCK:
    {
        last BLOCK if not $success;
        $success = 0;

        # When entering sub-graph at $from_in we will leave it at $to_out.
        $from_in->{path}->{$to_store} = $to_out;

        $from_in->{loop_entry}->{$to_store}    = $start_store;
        $start_store->{loop_exit}->{$to_store} = $end_store;

        # Path from $start_store to $end_store inside cyclic graph
        # has been marked already.
        if ($start_store->{loop_enter}->{$end_store}) {
            $success = 1;
            last BLOCK;
        }

        my $loop_enter  = [];
        my $path_tuples = {};
        my $loop_leave  = {};

        my $navi = cluster_navigation($from, $to) or internal_err "Empty navi";
#	use Dumpvalue;
#	Dumpvalue->new->dumpValue($navi);

        # Mark current path for loop detection.
        $from->{active_path} = 1;
        my $get_next = is_router $from ? 'any' : 'router';
        my $allowed = $navi->{$from->{loop}}
	or internal_err( "Loop $from->{loop}->{exit}->{name}$from->{loop}",
			 " with empty navi");
        for my $interface (@{ $from->{interfaces} }) {
            my $loop = $interface->{loop};
            next if not $loop;
	    if(not $allowed->{$loop}) {
#		debug "No: $loop->{exit}->{name}$loop";
		next;
	    }

            # Don't enter network which connects pair of virtual loopback
            # interfaces.
            next if $interface->{loopback} and $get_next eq 'any';
            my $next = $interface->{$get_next};

#           debug " try: $from->{name} -> $interface->{name}";
            if (
                cluster_path_mark1(
                    $next,       $interface,  $to,       $path_tuples,
                    $loop_leave, $start_intf, $end_intf, $navi
                )
              )
            {
                $success = 1;
                push @$loop_enter, $interface;

#               debug " enter: $from->{name} -> $interface->{name}";
            }
        }
        delete $from->{active_path};

	# Convert { intf->intf->node_type } to [ intf, intf, node_type ]
	my $tuples_aref = [];
	for my $in_intf_ref (keys %$path_tuples) {
	    my $in_intf = $key2obj{$in_intf_ref}
	    or internal_err "Unknown in_intf at tuple";
	    my $hash = $path_tuples->{$in_intf_ref};
	    for my $out_intf_ref (keys %$hash) {
		my $out_intf = $key2obj{$out_intf_ref}
		or internal_err "Unknown out_intf at tuple";
		my $at_router = $hash->{$out_intf_ref};
		push @$tuples_aref, [ $in_intf, $out_intf, $at_router ];
#		debug "Tuple: $in_intf->{name}, $out_intf->{name} $at_router";
	    }
	}

        # Convert hash of interfaces to array of interfaces.
	$loop_leave =  [ values %$loop_leave ];

	$start_store->{loop_enter}->{$end_store}  = $loop_enter;
        $start_store->{loop_leave}->{$end_store}  = $loop_leave;
	$start_store->{path_tuples}->{$end_store} = $tuples_aref;

	# Add data for reverse path.
	$end_store->{loop_enter}->{$start_store}  = $loop_leave;
	$end_store->{loop_leave}->{$start_store}  = $loop_enter;
	$end_store->{path_tuples}->{$start_store} = 
	    [ map { [ @{$_}[1,0,2] ] } @$tuples_aref ];
    }

    # Remove temporary added path restrictions.
    for my $intf ($start_intf, $end_intf) {
        if ($intf and (my $interfaces = $intf->{redundancy_interfaces})) {
            for my $interface (@$interfaces) {
                next if $interface eq $intf;
                pop @{ $interface->{path_restrict} };
            }
        }
    }

    # Disable pathrestriction at border of loop.
    for my $intf ($from_in, $to_out) {
        if (    $intf
            and not $intf->{loop}
            and (my $restrictions = $intf->{path_restrict}))
        {
            for my $restrict (@$restrictions) {
                $restrict->{active_path} = 0;
            }
        }
    }
    return $success;
}

# Mark path from $from to $to.
# $from and $to are either a router or an 'any' object.
# For a path without loops, $from_store equals $from and $to_store equals $to.
# If the path starts at an interface inside a cluster of loops 
# or at the border of a cluster,
# and the interface has a pathrestriction attached,
# then $from_store contains this interface.
# If the path ends at an interface inside a loop or at the border of a loop,
# $to_store contains this interface.
# At each interface on the path from $from to $to,
# we place a reference to the next interface on the path to $to_store.
# This reference is found in a hash at attribute {path}.
# Additionally we attach the path attribute to the src object.
# Return value is true if a valid path was found.
sub path_mark( $$$$ ) {
    my ($from, $to, $from_store, $to_store) = @_;

#    debug "path_mark $from_store->{name} --> $to_store->{name}";

    my $from_loop = $from->{loop};
    my $to_loop   = $to->{loop};

    # $from_store and $from differ if path starts at an interface
    # with pathrestriction.
    # Inside a loop, use $from_store, not $from, 
    # because the path may differ depending on the start interface.
    # But outside a loop (pathrestriction is allowed at the border of a loop)
    # we have only a single path which enters the loop.
    # In this case we must not use the interface but the router,
    # otherwise we would get an invalid {path}: 
    # $from_store->{path}->{$to_store} = $from_store;
    my $from_in   = $from_store->{loop} ? $from_store : $from;
    my $to_out    = undef;
    while (1) {

#        debug "Dist: $from->{distance} $from->{name} ->Dist: $to->{distance} $to->{name}";
        # Paths meet outside a loop or at the edge of a loop.
        if ($from eq $to) {

#            debug " $from_in->{name} -> ".($to_out ? $to_out->{name}:'');
            $from_in->{path}->{$to_store} = $to_out;
            return 1;
        }

        # Paths meet inside a loop.
        if($from_loop && $to_loop && 
           $from_loop->{cluster_exit} eq $to_loop->{cluster_exit}) 
        {
            return cluster_path_mark($from, $to, $from_in, $to_out, 
                                     $from_store, $to_store);
        }

        if ($from->{distance} >= $to->{distance}) {

            # Mark has already been set for a sub-path.
            return 1 if $from_in->{path}->{$to_store};
            my $from_out = $from->{main};
            unless ($from_out) {

                # $from_loop references object which is loop's exit.
                my $exit = $from_loop->{cluster_exit};
                $from_out = $exit->{main};
                cluster_path_mark($from, $exit, $from_in, $from_out, 
                                  $from_store, $to_store) 
                  or return 0;
            }

#            debug " $from_in->{name} -> ".($from_out ? $from_out->{name}:'');
            $from_in->{path}->{$to_store} = $from_out;
            $from_in                      = $from_out;
            $from                         = $from_out->{main};
            $from_loop                    = $from->{loop};
        }
        else {
            my $to_in = $to->{main};
            unless ($to_in) {
                my $entry = $to_loop->{cluster_exit};
                $to_in = $entry->{main};
                cluster_path_mark($entry, $to, $to_in, $to_out, 
                                  $from_store, $to_store)
                  or return 0;
            }

#            debug " $to_in->{name} -> ".($to_out ? $to_out->{name}:'');
            $to_in->{path}->{$to_store} = $to_out;
            $to_out                     = $to_in;
            $to                         = $to_in->{main};
            $to_loop                    = $to->{loop};
        }
    }
}

# Walk paths inside cyclic graph
sub loop_path_walk( $$$$$$$ ) {
    my ($in, $out, $loop_entry, $loop_exit, $call_at_router, $rule, $fun) = @_;

#    my $info = "loop_path_walk: ";
#    $info .= "$in->{name}->" if $in;
#    $info .= "$loop_entry->{name}=>$loop_exit->{name}";
#    $info .= "->$out->{name}" if $out;
#    debug $info;

    # Process entry of cyclic graph.
    # Note: not .. xor is similar to eq, but operates on boolean values.
    if (not(is_router $loop_entry 
	    or

	    # $loop_entry is interface with pathrestriction of original
	    # loop_entry.
	    is_interface $loop_entry
	    and

	    # Take only interface which originally was a router.
	    $loop_entry->{router} eq
	    $loop_entry->{loop_enter}->{$loop_exit}->[0]->{router}
	    )
        xor $call_at_router)
    {

#     debug " loop_enter";
        for my $out_intf (@{ $loop_entry->{loop_enter}->{$loop_exit} }) {
            $fun->($rule, $in, $out_intf);
        }
    }

    # Process paths inside cyclic graph.
    my $path_tuples = $loop_entry->{path_tuples}->{$loop_exit};

#    debug " loop_tuples";
    for my $tuple (@$path_tuples) {
	my ($in_intf, $out_intf, $at_router) = @$tuple;
	$fun->($rule, $in_intf, $out_intf) if not $at_router xor $call_at_router;
    }

    # Process paths at exit of cyclic graph.
    if (not(is_router $loop_exit 
	    or 
	    is_interface $loop_exit 
	    and
	    $loop_exit->{router} eq
	    $loop_entry->{loop_leave}->{$loop_exit}->[0]->{router}
	    )
        xor $call_at_router)
    {

#     debug " loop_leave";
        for my $in_intf (@{ $loop_entry->{loop_leave}->{$loop_exit} }) {
            $fun->($rule, $in_intf, $out);
        }
    }
}

# Apply a function to a rule at every router or 'any'
# on the path from src to dst of the rule.
# $where tells, where the function gets called: at 'Router' or 'Any'.
sub path_walk( $$;$ ) {
    my ($rule, $fun, $where) = @_;
    internal_err "undefined rule" unless $rule;
    my $src = $rule->{src};
    my $dst = $rule->{dst};

    my $from_store = $obj2path{$src}       || get_path $src;
    my $to_store   = $obj2path{$dst}       || get_path $dst;
    my $from       = $from_store->{router} || $from_store;
    my $to         = $to_store->{router}   || $to_store;

#    debug print_rule $rule;
#    debug(" start: $from->{name}, $to->{name}" . ($where?", at $where":''));
#    my $fun2 = $fun;
#    $fun = sub ( $$$ ) {
#       my($rule, $in, $out) = @_;
#       my $in_name = $in?$in->{name}:'-';
#       my $out_name = $out?$out->{name}:'-';
#       debug " Walk: $in_name, $out_name";
#       $fun2->(@_);
#    };
    $from and $to or internal_err print_rule $rule;
    $from eq  $to and internal_err "Unenforceable:\n ", print_rule $rule;

    if (not(($from->{loop} ? $from_store : $from)->{path}->{$to_store})) {
        path_mark($from, $to, $from_store, $to_store)
          or err_msg
          "No valid path from $from_store->{name} to $to_store->{name}\n",
          " for rule ", print_rule $rule, "\n",
          " Check path restrictions and crypto interfaces.";
    }
    my $in = undef;
    my $out;
    my $at_router = not($where && $where eq 'Any');
    my $call_it   = (is_any($from) xor $at_router);

    # Path starts inside a cyclic graph.
    if ($from_store->{loop_exit}
        and my $loop_exit = $from_store->{loop_exit}->{$to_store})
    {
        my $loop_out = $from_store->{path}->{$to_store};
        loop_path_walk($in, $loop_out, $from_store, $loop_exit, $at_router,
            $rule, $fun);
        if (not $loop_out) {

#           debug "exit: path_walk: dst in loop";
            return;
        }

        # Continue behind loop.
        $call_it = not(is_any($loop_exit) xor $at_router);
        $in      = $loop_out;
        $out     = $in->{path}->{$to_store};
    }
    else {
        $out = $from->{path}->{$to_store};
    }
    while (1) {
        if (    $in
            and $in->{loop_entry}
            and my $loop_entry = $in->{loop_entry}->{$to_store})
        {
            my $loop_exit = $loop_entry->{loop_exit}->{$to_store};
            my $loop_out  = $in->{path}->{$to_store};
            loop_path_walk($in, $loop_out, $loop_entry, $loop_exit, $at_router,
                $rule, $fun);
            if (not $loop_out) {

#               debug "exit: path_walk: reached dst in loop";
                return;
            }
	    $call_it = not(is_any($loop_exit) xor $at_router);
            $in      = $loop_out;
            $out     = $in->{path}->{$to_store};
        }
        else {
            if ($call_it) {
                $fun->($rule, $in, $out);
            }

            # End of path has been reached.
            if (not $out) {

#               debug "exit: path_walk: reached dst";
                return;
            }
            $call_it = !$call_it;
            $in      = $out;
            $out     = $in->{path}->{$to_store};
        }
    }
}
  
my %border2router2auto;
sub set_auto_intf_from_border ( $ ) {
    my ($border) = @_;
    my %active_path;
    my $reach_from_border;
    $reach_from_border = sub {
      my($network, $in_intf, $result) = @_;
      $active_path{$network} = 1;
      for my $interface (@{ $network->{interfaces} }) {
          next if $interface eq $in_intf;
          next if $interface->{any};
	  next if $interface->{orig_main};
          my $router = $interface->{router};
          next if $result->{$router}->{$interface};
	  next if $active_path{$router};
	  $active_path{$router} = 1;
          $result->{$router}->{$interface} = $interface;
          for my $out_intf (@{ $router->{interfaces} }) {
              next if $out_intf eq $interface;
	      next if $out_intf->{orig_main};
              my $out_net = $out_intf->{network};
              next if $active_path{$out_net};
              $reach_from_border->($out_net, $out_intf, $result);
          }
	  $active_path{$router} = 0;
      }
      $active_path{$network} = 0;
    };
    my $result = {};
    $reach_from_border->($border->{network}, $border, $result);
    for my $href (values %$result) {
      $href = [ values %$href ];
    }
    $border2router2auto{$border} = $result;
}

# $src is an auto_interface, interface or router.
# Result is the set of interfaces of $src located at the front side
# of the direction to $dst.
sub path_auto_interfaces( $$ ) {
    my ($src, $dst) = @_;
    my @result;
    my ($src2, $managed) =
      (is_autointerface $src)
      ? @{$src}{ 'object', 'managed' }
      : ($src, undef);
    my $dst2 = is_autointerface $dst ? $dst->{object} : $dst;

    my $from_store = $obj2path{$src2}      || get_path $src2;
    my $to_store   = $obj2path{$dst2}      || get_path $dst2;
    my $from       = $from_store->{router} || $from_store;
    my $to         = $to_store->{router}   || $to_store;

    $from eq $to and return ();
    if (not $from_store->{path}->{$to_store}) {
        path_mark($from, $to, $from_store, $to_store)
          or err_msg
          "No valid path from $from_store->{name} to $to_store->{name}\n",
          " while resolving $src->{name} (destination is $dst->{name}).\n",
          " Check path restrictions and crypto interfaces.";
    }
    if ($from_store->{loop_exit}
        and my $exit = $from_store->{loop_exit}->{$to_store})
    {
        @result =
          grep { $_->{ip} ne 'tunnel' } @{ $from->{loop_enter}->{$exit} };
    }
    else {
        @result = ($from_store->{path}->{$to_store});
    }
    my $router = is_router $src2 ? $src2 : $src2->{router};
    if(is_any $from) {
	my %result;
	for my $border (@result) {
	    if(not $border2router2auto{$border}) {
		set_auto_intf_from_border($border);
	    }
	    my $auto_intf = $border2router2auto{$border}->{$router};
	    for my $interface (@$auto_intf) {
		$result{$interface} = $interface;
	    }
	}
	@result = values %result;
    }

    # If device has virtual interface, main and virtual interface are swapped.
    # Swap it back here because we need the original main interface
    # if an interface is used in a rule.
    for my $interface (@result) {
        if (my $orig = $interface->{orig_main}) {
            $interface = $orig;
        }
    }

#    debug "$from->{name}.[auto] = ", join ',', map {$_->{name}} @result;
    $managed ? grep { $_->{router}->{managed} } @result : @result;
}

########################################################################
# Handling of crypto tunnels.
########################################################################

sub link_ipsec () {
    for my $ipsec (values %ipsec) {

        # Convert name of ISAKMP definition to object with ISAKMP definition.
        my ($type, $name) = @{ $ipsec->{key_exchange} };
        if ($type eq 'isakmp') {
            my $isakmp = $isakmp{$name}
              or err_msg "Can't resolve reference to $type:$name",
              " for $ipsec->{name}";
            $ipsec->{key_exchange} = $isakmp;
        }
        else {
            err_msg "Unknown key_exchange type '$type' for $ipsec->{name}";
        }
    }
}

sub link_crypto () {
    for my $crypto (values %crypto) {
        my $name = $crypto->{name};

        # Convert name of IPSec definition to object with IPSec definition.
        my ($type, $name2) = @{ $crypto->{type} };

        if ($type eq 'ipsec') {
            my $ipsec = $ipsec{$name2}
              or err_msg "Can't resolve reference to $type:$name2",
              " for $name";
            $crypto->{type} = $ipsec;
        }
        else {
            err_msg "Unknown type '$type' for $name";
        }
    }
}

# Generate rules to permit crypto traffic between tunnel endpoints.
sub gen_tunnel_rules ( $$$ ) {
    my ($intf1, $intf2, $ipsec) = @_;
    my $use_ah = $ipsec->{ah};
    my $use_esp = $ipsec->{esp_authentication} || $ipsec->{esp_encryption};
    my $nat_traversal = $ipsec->{key_exchange}->{nat_traversal};
    my @rules;
    my $rule =
      { stateless => 0, action => 'permit', src => $intf1, dst => $intf2 };
    if (not $nat_traversal or $nat_traversal ne 'on') {
        $use_ah
          and push @rules, { %$rule, src_range => $srv_ip, srv => $srv_ah };
        $use_esp
          and push @rules, { %$rule, src_range => $srv_ip, srv => $srv_esp };
        push @rules,
          {
            %$rule,
            src_range => $srv_ike->{src_range},
            srv       => $srv_ike->{dst_range}
          };
    }
    if ($nat_traversal) {
        push @rules,
          {
            %$rule,
            src_range => $srv_natt->{src_range},
            srv       => $srv_natt->{dst_range}
          };
    }
    return \@rules;
}

# Link tunnel networks with tunnel hubs.
# ToDo: Are tunnels between different private contexts allowed?
sub link_tunnels () {

    # Collect clear-text interfaces of all tunnels.
    my @real_interfaces;

    for my $crypto (values %crypto) {
        my $name        = $crypto->{name};
        my $private     = $crypto->{private};
        my $real_hubs   = delete $crypto2hubs{$name};
        my $real_spokes = delete $crypto2spokes{$name};
        $real_hubs and @$real_hubs
          or err_msg "No hubs have been defined for $name";

	# Substitute crypto name by crypto object.
        for my $real_hub (@$real_hubs) {
	    for my $hub (@{ $real_hub->{hub} }) {
		$hub eq $name and $hub = $crypto;
	    }
        }
	push @real_interfaces, @$real_hubs;

        # Generate a single tunnel from each spoke to a single hub.
        # If there are multiple hubs, they are assumed to form
        # a high availability cluster. In this case a single tunnel is created
        # with all hubs as possible endpoints. Traffic between hubs is
        # prevented by automatically added pathrestrictions.
        for my $spoke_net (@$real_spokes) {
            (my $net_name = $spoke_net->{name}) =~ s/network://;
            push @{ $crypto->{tunnels} }, $spoke_net;
            my $spoke = $spoke_net->{interfaces}->[0];
            $spoke->{crypto} = $crypto;
            my $real_spoke = $spoke->{real_interface};
	    $real_spoke->{spoke} = $crypto;

            # Each spoke gets a fresh hub interface.
            my @hubs;
            for my $real_hub (@$real_hubs) {
                my $router   = $real_hub->{router};
                my $hardware = $real_hub->{hardware};
                (my $intf_name = $real_hub->{name}) =~ s/\..*$/.$net_name/;
                my $hub = new(
                    'Interface',
                    name           => $intf_name,
                    ip             => 'tunnel',
                    crypto         => $crypto,
                    hardware       => $hardware,
                    is_hub         => 1,
                    real_interface => $real_hub,
                    router         => $router,
                    network        => $spoke_net
                );
		$hub->{bind_nat} = $real_hub->{bind_nat} if $hub->{bind_nat};
                push @{ $router->{interfaces} },    $hub;
                push @{ $hardware->{interfaces} },  $hub;
                push @{ $spoke_net->{interfaces} }, $hub;
                push @{ $hub->{peers} },            $spoke;
                push @{ $spoke->{peers} },          $hub;
                push @hubs, $hub;

		# Dynamic crypto-map isn't implemented currently.
		if ($real_spoke->{ip} eq 'negotiated') {
		    if (not $router->{model}->{do_auth}) {
			err_msg "$router->{name} can't establish crypto",
			"tunnel to $real_spoke->{name} with negotiated IP";
		    }
		}

                if ($private) {
                    my $s_p = $real_spoke->{private};
                    my $h_p = $real_hub->{private};
                    $s_p and $s_p eq $private
                      or $h_p and $h_p eq $private
                      or err_msg "Tunnel $real_spoke->{name} to $real_hub->{name}",
                      " of $private.private $name",
                      " must reference at least one object",
                      " out of $private.private";
                }
                else {
                    $real_spoke->{private}
                      and err_msg "Tunnel of public $name must not",
                      " reference $real_spoke->{name} of",
                      " $real_spoke->{private}.private";
                    $real_hub->{private}
                      and err_msg "Tunnel of public $name must not",
                      " reference $real_hub->{name} of",
                      " $real_hub->{private}.private";
                }
            }

	    # Remove real interface at virtual router with only 
	    # software clients attached.
	    # This is necessary, because we must not add pathrestriction
	    # to this unmanaged device.
	    my $router = $real_spoke->{router};
	    my @other;
	    my $has_id_hosts;
	    for my $interface (@{ $router->{interfaces} }) {
		my $network = $interface->{network};
		if ($network->{has_id_hosts}) {
		    $has_id_hosts = 1;
		}
		elsif($interface ne $real_spoke && 
		      $interface->{ip} ne 'tunnel') 
		{
		    push @other, $interface;
		}
	    }
	    if($has_id_hosts and @other) {
		err_msg "Must not use network with ID hosts together with",
		" networks having no ID host: ", 
		join( ',', map {$_->{name}} @other);
	    }
	    push @real_interfaces, $real_spoke;
	    
            # Automatically add pathrestriction between interfaces
            # of redundant hubs.
            if (@hubs > 1) {
                my $name2 = "auto-restriction:$crypto->{name}";
                my $restrict = new('Pathrestriction', name => $name2);
                for my $hub (@hubs) {
                    push @{ $hub->{path_restrict} }, $restrict;
                }
            }
        }
    }

    # Check for undefined crypto references.
    for my $crypto (keys %crypto2hubs) {
        for my $interface (@{ $crypto2hubs{$crypto} }) {
            err_msg "$interface->{name} references unknown $crypto";
        }
    }
    for my $crypto (keys %crypto2spokes) {
        for my $network (@{ $crypto2spokes{$crypto} }) {
            err_msg "$network->{interfaces}->[0]->{name}",
              " references unknown $crypto";
        }
    }

    # Automatically add active pathrestriction to the real interface.
    # This allows direct traffic to the real interface from outside,
    # but no traffic from or to the real interface passing the router.
    for my $intf1 (@real_interfaces) {
        next if $intf1->{no_check};
        push @{ $intf1->{path_restrict} }, $global_active_pathrestriction;
    }
}

# Needed for crypto_rules,
# for default route optimization,
# while generating chains of iptables and
# for local optimization.
my $network_00 = new('Network', name => "network:0/0", ip => 0, mask => 0);

sub expand_crypto () {
    progress "Expanding crypto rules";

    my %id2network;

    for my $crypto (values %crypto) {
        my $name = $crypto->{name};

        # Add crypto rules to encrypt traffic for all networks
        # at the remote location.
        if ($crypto->{tunnel_all}) {
            for my $tunnel (@{ $crypto->{tunnels} }) {
                next if $tunnel->{disabled};
                for my $tunnel_intf (@{ $tunnel->{interfaces} }) {
                    next if $tunnel_intf->{is_hub};
                    my $router  = $tunnel_intf->{router};
                    my $managed = $router->{managed};
                    my @encrypted;
		    my $has_id_network;
		    my $has_id_hosts;
		    my $has_other_network;
                    for my $interface (@{ $router->{interfaces} }) {
                        next if $interface->{ip} eq 'tunnel';
                        next if $interface->{spoke};

                        my $network = $interface->{network};
                        if ($network->{has_id_hosts}) {
			    $has_id_hosts = 1;
                            $managed
                              and err_msg
                              "$network->{name} having ID hosts must not",
                              " be located behind managed $router->{name}";

                            # Rules for single software clients are stored
                            # individually at crypto hub interface.
                            for my $host (@{ $network->{hosts} }) {
                                my $id      = $host->{id};
                                my $subnets = $host->{subnets};
                                @$subnets > 1
                                  and err_msg
                                  "$host->{name} with ID must expand to",
                                  "exactly one subnet";
                                my $subnet = $subnets->[0];
                                for my $peer (@{ $tunnel_intf->{peers} }) {
                                    $peer->{id_rules}->{$id} = {
                                        name       => "$peer->{name}.$id",
                                        ip         => 'tunnel',
                                        src        => $subnet,
                                        no_nat_set => $peer->{no_nat_set},

                                        # Needed during local_optimization.
                                        router => $peer->{router},
                                    };
                                }
                            }
                            push @encrypted, $network;
                        }
                        else {
			    if (my $id = $network->{id}) {
				if (my $net2 = $id2network{$id}) {
				    err_msg "Same ID '$id' is used at",
				    " $network->{name} and $net2->{name}";
				}
				$id2network{$id} = $network;
				$has_id_network = 1;
			    }
			    else {
				$has_other_network = 1;
			    }
                            push @encrypted, $network;
			    $network->{radius_attributes} = {};
                        }
                    }
		    if ($has_id_network and $has_other_network) {
			err_msg
			    "Must not use network with ID and other network",
			    " together at $router->{name}";
		    }
                    $has_id_hosts and $has_other_network
                      and err_msg
                      "Must not use host with ID and network",
                      " together at $tunnel_intf->{name}: ",
		      join(', ', map { $_->{name} } @encrypted);
                    $has_id_hosts or $has_id_network or $has_other_network
                      or err_msg "Must use network or host with ID",
			" at $tunnel_intf->{name}: ",
			join(', ', map { $_->{name} } @encrypted);

		    for my $peer (@{ $tunnel_intf->{peers} }) {
			$peer->{peer_networks} = \@encrypted;
		    }

                    # Traffic from spoke to hub(s).
                    my $crypto_rules = [
                        map {
                            {
                                action    => 'permit',
                                src       => $_,
                                dst       => $network_00,
                                src_range => $srv_ip,
                                srv       => $srv_ip
                            }
                          } @encrypted
                    ];
                    $tunnel_intf->{crypto_rules} = $crypto_rules;

                    # Traffic from hubs to spoke.
                    $crypto_rules = [
                        map {
                            {
                                action    => 'permit',
                                src       => $network_00,
                                dst       => $_,
                                src_range => $srv_ip,
                                srv       => $srv_ip
                            }
                          } @encrypted
                    ];
                    for my $peer (@{ $tunnel_intf->{peers} }) {
                        $peer->{crypto_rules} = $crypto_rules;

			# ID can only be checked at hub with attribute do_auth.
			my $router = $peer->{router};
			my $do_auth = $router->{model}->{do_auth};
			for my $network (@encrypted) {
			    if ($network->{has_id_hosts} || $network->{id}) {
				$do_auth or
				    err_msg "$router->{name} can't check IDs",
				    " of $network->{name}";
			    }
			    else {
				$do_auth and 
				    err_msg "$router->{name} can only check",
				    " network having ID, not $network->{name}";
			    }
			}
                    }

                    # Add rules to permit crypto traffic between
                    # tunnel endpoints.
                    # If one tunnel endpoint has no known IP address,
                    # these rules have to be added manually.
                    my $real_spoke = $tunnel_intf->{real_interface};
                    if (    $real_spoke
                        and $real_spoke->{ip} !~ /^(?:short|unnumbered)$/)
                    {
                        for my $hub (@{ $tunnel_intf->{peers} }) {
                            my $real_hub = $hub->{real_interface};
                            for my $pair (
                                [ $real_spoke, $real_hub ],
                                [ $real_hub,   $real_spoke ]
                              )
                            {
                                my ($intf1, $intf2) = @$pair;
                                next if $intf1->{ip} eq 'negotiated';
                                my $rules_ref =
                                  gen_tunnel_rules($intf1, $intf2,
                                    $crypto->{type});
                                push @{ $expanded_rules{permit} }, @$rules_ref;
                                add_rules $rules_ref;
                            }
                        }
                    }
                }
            }
        }
    }

    # Check for duplicate IDs of different hosts
    # coming into current hardware interface / current device.
    for my $router (@managed_vpnhub) {
        my $is_asavpn = $router->{model}->{crypto} eq 'ASA_VPN';
        my %hardware2id2tunnel;
        for my $interface (@{ $router->{interfaces} }) {
            next if not $interface->{ip} eq 'tunnel';

            # ASA_VPN can't distinguish different hosts with same ID
            # coming into different hardware interfaces.
            my $hardware = $is_asavpn ? 'one4all' : $interface->{hardware};
            my $tunnel = $interface->{network};
            if (my $hash = $interface->{id_rules}) {
                for my $id (keys %$hash) {
                    if (my $tunnel2 = $hardware2id2tunnel{$hardware}->{$id}) {
                        err_msg "Using identical ID $id from different",
                          " $tunnel->{name} and $tunnel2->{name}";
                    }
                    else {
                        $hardware2id2tunnel{$hardware}->{$id} = $tunnel;
                    }
                }
            }
        }
    }

    # Hash only needed during expand_group and expand_rules.
    %auto_interfaces = ();
}

# Hash for converting a reference of an object back to this object.
my %ref2obj;

sub setup_ref2obj () {
    for my $network (@networks) {
        $ref2obj{$network} = $network;
        for my $obj (@{ $network->{subnets} }, @{ $network->{interfaces} }) {
            $ref2obj{$obj} = $obj;
        }
    }
    for my $any (@all_anys) {
        $ref2obj{$any} = $any;
    }
}

##############################################################################
# Check if high-level and low-level semantics of rules with an 'any' object
# as source or destination are equivalent.
#
# I. Typically, we only use incoming ACLs.
# (A) rule "permit any:X dst"
# high-level: all networks of security domain X get access to dst
# low-level: like above, but additionally, the networks of
#            all security domains on the path from any:x to dst
#            get access to dst.
# (B) rule permit src any:X
# high-level: src gets access to all networks of security domain X
# low-level: like above, but additionally, src gets access to the networks of
#            all security domains located directly behind all routers on the
#            path from src to any:X
#
# II. Alternatively, we have a single interface Y (with attached any:Y)
#     without ACL and all other interfaces having incoming and outgoing ACLs.
# (A) rule "permit any:X dst"
#  a)  dst behind Y: filtering occurs at incoming ACL of X, good.
#  b)  dst not behind Y:
#    1. any:X == any:Y: filtering occurs at outgoing ACL, good.
#    2. any:X != any:Y: outgoing ACL would accidently permit any:Y->dst, bad.
#                additional rule required: "permit any:Y->dst" 
# (B) rule "permit src any:X"
#  a)  src behind Y: filtering occurs at ougoing ACL, good
#  b)  src not behind Y:
#    1. any:X == any:Y: filtering occurs at incoming ACL at src and at
#                       outgoing ACls of other non-any:X interfaces, good.
#    2. any:X != any:Y: incoming ACL at src would permit src->any:Y, bad
#                       additional rule required: "permit src->any:Y".
##############################################################################

{

    # Prevent multiple error messages about missing 'any' rules;
    my %missing_any;

    sub err_missing_any ( $$$$ ) {
        my ($rule, $any, $where, $router) = @_;
        return if $missing_any{$any};
        $missing_any{$any} = $any;
        my $policy = $rule->{rule}->{policy}->{name};
        $rule   = print_rule $rule;
        $router = $router->{name};
        err_msg "Missing 'any' rule.\n", " $rule\n", " of $policy\n",
          " can't be effective at $router.\n",
          " There needs to be defined a similar rule with\n",
          " $where=$any->{name}";
    }
}

# If such rule is defined
#  permit any1 dst
#
# and topology is like this:
#
# any1-R1-any2-R2-any3-R3-dst
#         any4-/
#
# additional rules need to be defined as well:
#  permit any2 dst
#  permit any3 dst
#
# If R2 is stateless, we need one more rule to be defined:
#  permit any4 dst
# This is, because at R2 we would get an automatically generated
# reverse rule
#  permit dst any1
# which would accidentally permit traffic to any4 as well.
sub check_any_src_rule( $$$ ) {

    # Function is called from path_walk.
    my ($rule, $in_intf, $out_intf) = @_;

    # Check only for the first router, because next test will be done
    # for rule "permit any2 dst" anyway.
    return unless $in_intf->{any} eq $rule->{src};

    # Destination is interface of current router and therefore there is
    # nothing to be checked.
    return unless $out_intf;

    my $out_any = $out_intf->{any};
    my ($stateless, $action, $src, $dst, $src_range, $srv) =
      @{$rule}{ 'stateless', 'action', 'src', 'dst', 'src_range', 'srv' };
    if ($out_any eq $dst) {

        # Both src and dst are 'any' objects and are directly connected
        # at current router. Hence there can't be any missing rules.
        # But we need to know about this situation later during code
        # generation.
        # Note: Additional checks will be done for this situation at
        # check_any_dst_rule
        $rule->{any_are_neighbors} = 1;
        return;
    }

    my $dst_any = get_any $dst;
    my $router  = $in_intf->{router};

    # Check case II, outgoing ACL, (A)
    my $no_acl_intf;
    if ($no_acl_intf = $router->{no_in_acl}) {
	my $no_acl_any = $no_acl_intf->{any};

	# a),  dst behind Y
	if ($dst_any eq $no_acl_any) {
	}

	# b), 1. any:X == any:Y
	elsif ($in_intf eq $no_acl_intf) {
	}

	# b), 2. any:X != any:Y
	elsif (not $rule_tree{$stateless}->{$action}->{$no_acl_any}->{$dst}
	       ->{$src_range}->{$srv})
	{
	    err_missing_any $rule, $no_acl_any, 'src', $router;
	}
    }

    # Check if reverse rule would need additional rules.
    if ($router->{model}->{stateless} and not $rule->{oneway}) {
        my $proto = $rule->{srv}->{proto};
        if ($proto eq 'tcp' or $proto eq 'udp' or $proto eq 'ip') {

	    # Check case II, outgoing ACL, (B), interface Y without ACL.
	    if (my $no_acl_intf = $router->{no_in_acl}) {
		my $no_acl_any = $no_acl_intf->{any};

		# a) dst behind Y
		if ($no_acl_any eq $dst_any) {
		}

		# b) dst not behind Y
		# any:X == any:Y
		elsif ($no_acl_any eq $src) {
		}

		# any:X != any:Y
		elsif (not $rule_tree{$stateless}->{$action}->{$no_acl_any}
		       ->{$dst}->{$src_range}->{$srv})
		{
		    err_missing_any $rule, $no_acl_any, 'src', $router;
		}
	    }

	    # Standard incoming ACL at all interfaces.
	    else {

		# Find security domains at all interfaces except the in_intf.
		for my $intf (@{ $router->{interfaces} }) {
		    next if $intf eq $in_intf;

		    # Nothing to be checked for an interface directly connected
		    # to the destination 'any' object.
		    my $any = $intf->{any};
		    next if $any eq $out_any;
		    next if $any eq $dst_any;
		    if (not $rule_tree{$stateless}->{$action}->{$any}->{$dst}
			->{$src_range}->{$srv})
		    {
			err_missing_any $rule, $any, 'src', $router;
		    }
		}
            }
        }
    }

    # Security domain of dst is directly connected with current router.
    # Hence there can't be any missing rules.
    return if $out_any eq $dst_any;

    # Check if rule "any2 -> dst" is defined.
    if (not $rule_tree{$stateless}->{$action}->{$out_any}->{$dst}->{$src_range}
        ->{$srv})
    {
        err_missing_any $rule, $out_any, 'src', $router;
    }
}

# If such rule is defined
#  permit src any5
#
# and topology is like this:
#
#                      /-any4
# src-R1-any2-R2-any3-R3-any5
#      \-any1
#
# additional rules need to be defined as well:
#  permit src any1
#  permit src any2
#  permit src any3
#  permit src any4
sub check_any_dst_rule( $$$ ) {

    # Function is called from path_walk.
    my ($rule, $in_intf, $out_intf) = @_;

    # Source is interface of current router.
    return unless $in_intf;

    my $in_any  = $in_intf->{any};
    my $out_any = $out_intf->{any};
    my ($stateless, $action, $src, $dst, $src_range, $srv) =
      @{$rule}{ 'stateless', 'action', 'src', 'dst', 'src_range', 'srv' };

    # We only need to check last router on path.
    return unless $dst eq $out_any;

    my $router  = $in_intf->{router};
    my $src_any = get_any $src;

    # Check case II, outgoing ACL, (B), interface Y without ACL.
    if (my $no_acl_intf = $router->{no_in_acl}) {
	my $no_acl_any = $no_acl_intf->{any};

	# a) src behind Y
	if ($no_acl_any eq $src_any) {
	}

	# b) src not behind Y
	# any:X == any:Y
	elsif ($no_acl_any eq $dst) {
	}

	# any:X != any:Y
	elsif (not $rule_tree{$stateless}->{$action}->{$src}->{$no_acl_any}
	       ->{$src_range}->{$srv})
	{
	    err_missing_any $rule, $no_acl_any, 'dst', $router;
	}
	return;
    }

    # Check security domains at all interfaces except the out_intf.
    # For devices which have rules for each pair of incoming and outgoing
    # interfaces we only need to check the direct path.
    for my $intf (  $router->{model}->{has_io_acl} 
		  ? ($in_intf) 
		  : @{ $router->{interfaces} }) 
    {

        # Nothing to be checked for the interface which is connected
        # directly to the destination 'any' object.
        next if $intf eq $out_intf;
        my $any = $intf->{any};

        # Nothing to be checked if src is directly attached to current router.
        next if $any eq $src_any;
        if (not $rule_tree{$stateless}->{$action}->{$src}->{$any}
            ->{$src_range}->{$srv})
        {
            err_missing_any $rule, $any, 'dst', $router;
        }
    }
}

# Find smaller service of two services.
# Cache results.
my %smaller_srv;

sub find_smaller_srv ( $$ ) {
    my ($srv1, $srv2) = @_;

    if ($srv1 eq $srv2) {
        return $srv1;
    }
    if (defined(my $srv = $smaller_srv{$srv1}->{$srv2})) {
        return $srv;
    }

    my $srv = $srv1;
    while ($srv = $srv->{up}) {
        if ($srv eq $srv2) {
            $smaller_srv{$srv1}->{$srv2} = $srv1;
            $smaller_srv{$srv2}->{$srv1} = $srv1;
            return $srv1;
        }
    }
    $srv = $srv2;
    while ($srv = $srv->{up}) {
        if ($srv eq $srv1) {
            $smaller_srv{$srv1}->{$srv2} = $srv2;
            $smaller_srv{$srv2}->{$srv1} = $srv2;
            return $srv2;
        }
    }
    $smaller_srv{$srv1}->{$srv2} = 0;
    $smaller_srv{$srv2}->{$srv1} = 0;
    return 0;
}

# Example:
# XX--R1--any_A--R2--R3--R4--YY
#
# If we have rules
#   permit XX any_A
#   permit any_A YY
# this implies
#   permit XX YY
# which may not have been wanted.
# In order to avoid this, a warning is generated if the last rule is not
# explicitly defined.
#
# ToDo:
# Do we need to check for {any_cluster} equality?
#
sub check_for_transient_any_rule () {

    # Collect info about unwanted implied rules.
    my %missing_rule_tree;
    my $missing_count = 0;

    for my $rule (@{ $expanded_rules{any} }) {
        next if $rule->{deleted};
        next if $rule->{action} ne 'permit';
        my $dst = $rule->{dst};
        next if not is_any($dst);

        # A leaf security domain has only one interface.
        # It can't lead to unwanted rule chains.
        next if @{ $dst->{interfaces} } <= 1;

        my ($stateless1, $src1, $dst1, $src_range1, $srv1) =
          @$rule{ 'stateless', 'src', 'dst', 'src_range', 'srv' };

        # Find all rules with $dst1 as source.
        my $src2 = $dst1;
        for my $stateless2 (1, 0) {
            while (my ($dst2_str, $hash) =
                each %{ $rule_tree{$stateless2}->{permit}->{$src2} })
            {

                # Skip reverse rules.
                next if $src1 eq $dst2_str;

                my $dst2 = $ref2obj{$dst2_str};

                # Skip rules with src and dst inside a single security domain.
                next
                  if (($obj2any{$src1} || get_any $src1) eq
                    ($obj2any{$dst2} || get_any $dst2));

                while (my ($src_range2_str, $hash) = each %$hash) {
                  RULE2:
                    while (my ($srv2_str, $rule2) = each %$hash) {

                        my $srv2       = $rule2->{srv};
                        my $src_range2 = $rule2->{src_range};

                        # Find smaller service of two rules found.
                        my $smaller_srv = find_smaller_srv $srv1, $srv2;
                        my $smaller_src_range = find_smaller_srv $src_range1,
                          $src_range2;

                        # If services are disjoint, we do not have 
			# transient-any-problem for $rule and $rule2.
                        next if not $smaller_srv or not $smaller_src_range;

			# Stateless rule < stateful rule, hence use ||.
                        # Force a unique value for boolean result.
                        my $stateless = ($stateless1 || $stateless2) + 0;

                        # Check for a rule with $src1 and $dst2 and
                        # with $smaller_service.
                        while (1) {
                            my $action = 'permit';
                            if (my $hash = $rule_tree{$stateless}) {
                                while (1) {
                                    my $src = $src1;
                                    if (my $hash = $hash->{$action}) {
                                        while (1) {
                                            my $dst = $dst2;
                                            if (my $hash = $hash->{$src}) {
                                                while (1) {
                                                    my $src_range =
                                                      $smaller_src_range;
                                                    if (my $hash =
                                                        $hash->{$dst})
                                                    {
                                                        while (1) {
                                                            my $srv =
                                                              $smaller_srv;
                                                            if (my $hash =
                                                                $hash
                                                                ->{$src_range})
                                                            {
                                                                while (1) {
                                                                    if (
                                                                        my $other_rule
                                                                        = $hash
                                                                        ->{$srv}
                                                                      )
                                                                    {

# debug print_rule $other_rule;
                                                                        next
                                                                          RULE2;
                                                                    }
                                                                    $srv =
                                                                      $srv->{up}
                                                                      or last;
                                                                }
                                                            }
                                                            $src_range =
                                                              $src_range->{up}
                                                              or last;
                                                        }
                                                    }
                                                    $dst = $dst->{up} or last;
                                                }
                                            }
                                            $src = $src->{up} or last;
                                        }
                                    }
                                    last if $action eq 'deny';
                                    $action = 'deny';
                                }
                            }
                            last if !$stateless;

                            # Boolean value "false" is used as hash key, hence we take '0'.
                            $stateless = 0;
                        }

# debug "Src: ", print_rule $rule;
# debug "Dst: ", print_rule $rule2;
                        my $src_policy = $rule->{rule}->{policy}->{name};
                        my $dst_policy = $rule2->{rule}->{policy}->{name};
			my $srv_name = $smaller_srv->{name};
			$srv_name =~ s/^.part_/[part]/;
			if ($smaller_src_range ne $range_tcp_any
			    and
			    $smaller_src_range ne $srv_ip) 
			{
			    my ($p1, $p2) = @{ $smaller_src_range->{range} };
			    if ($p1 != 1 or $p2 != 65535) {
				$srv_name = "[src:$p1-$p2]$srv_name";
			    }
			}
			my $new =
			  not
			  $missing_rule_tree
			    { $src_policy }
                          ->{ $dst_policy }

			# The matching 'any' object.
  			  ->{ $dst1->{name} }

			# The missing rule
			  ->{ $src1->{name} }
			  ->{ $dst2->{name} }
                          ->{ $srv_name }++;
                        $missing_count++ if $new;
                    }
                }
            }
        }
    }

    # No longer needed; free some memory.
    %smaller_srv = ();

    if ($missing_count) {

	my $print = $config{check_transient_any_rules}  eq 'warn'
	          ? \&warn_msg
	          : \&err_msg;
        $print->("Missing transient rules: $missing_count");
	
        while (my ($src_policy, $hash) = each %missing_rule_tree) {
	    while (my ($dst_policy, $hash) = each %$hash) {
		while (my ($any, $hash) = each %$hash) {
		    info "Rules of $src_policy and $dst_policy match at $any";
		    info "Missing transient rules:";
		    while (my ($src, $hash) = each %$hash) {
			while (my ($dst, $hash) = each %$hash) {
			    while (my ($srv, $hash) = each %$hash) {
				info " permit src=$src; dst=$dst; srv=$srv";
			    }
                        }
                    }
                }
            }
        }
    }
}


# Handling of any rules created by gen_reverse_rules.
#
# 1. dst is any
#
# src--r1:stateful--dst1=any1--r2:stateless--dst2=any2
#
# gen_reverse_rule will create one additional rule
# any2-->src, but not a rule any1-->src, because r1 is stateful.
# check_any_src_rule would complain, that any1-->src is missing.
# But that doesn't matter, because r1 would permit answer packets
# from any2 anyway, because it's stateful.
# Hence we can skip check_any_src_rule for this situation.
#
# 2. src is any
#
# a) no stateful router on the path between stateless routers and dst.
#
#        any2---\
# src=any1--r1:stateless--dst
#
# gen_reverse_rules will create one additional rule dst-->any1.
# check_any_dst_rule would complain about a missing rule
# dst-->any2.
# To prevent this situation, check_any_src_rule checks for a rule
# any2 --> dst
#
# b) at least one stateful router on the path between
#    stateless router and dst.
#
#        any3---\
# src1=any1--r1:stateless--src2=any2--r2:stateful--dst
#
# gen_reverse_rules will create one additional rule
# dst-->any1, but not dst-->any2 because second router is stateful.
# check_any_dst_rule would complain about missing rules
# dst-->any2 and dst-->any3.
# But answer packets back from dst have been filtered by r2 already,
# hence it doesn't hurt if the rules at r1 are a bit too relaxed,
# i.e. r1 would permit dst to any, but should only permit dst to any1.
# Hence we can skip check_any_dst_rule for this situation.
# (Case b isn't implemented currently.)
#

sub check_any_rules() {
    progress "Checking rules with 'any' objects";
    for my $rule (@{ $expanded_rules{any} }) {
        next if $rule->{deleted};
        if (is_any($rule->{src})) {
            path_walk($rule, \&check_any_src_rule);
        }
        if (is_any($rule->{dst})) {
            path_walk($rule, \&check_any_dst_rule);
        }
    }
    check_for_transient_any_rule if $config{check_transient_any_rules};

    # no longer needed; free some memory.
    %obj2any = ();
}

##############################################################################
# Generate reverse rules for stateless packet filters:
# For each rule with protocol tcp, udp or ip we need a reverse rule
# with swapped src, dst and src-port, dst-port.
# For rules with a tcp service, the reverse rule gets a tcp service
# without range checking but with checking for 'established` flag.
##############################################################################

sub gen_reverse_rules1 ( $ ) {
    my ($rule_aref) = @_;
    my @extra_rules;
    for my $rule (@$rule_aref) {
        if ($rule->{deleted}) {
            my $src = $rule->{src};

            # If source is a managed interface,
            # reversed will get attribute managed_intf.
            unless (is_interface($src) and $src->{router}->{managed}) {
                next;
            }
        }
        my $srv   = $rule->{srv};
        my $proto = $srv->{proto};
        next unless $proto eq 'tcp' or $proto eq 'udp' or $proto eq 'ip';
        next if $rule->{oneway};

        # No reverse rules will be generated for denied TCP packets, because
        # - there can't be an answer if the request is already denied and
        # - the 'established' optimization for TCP below would produce
        #   wrong results.
        next if $proto eq 'tcp' and $rule->{action} eq 'deny';

        my $has_stateless_router;
      PATH_WALK:
        {

            # Local function.
            # It uses free variable $has_stateless_router.
            my $mark_reverse_rule = sub( $$$ ) {
                my ($rule, $in_intf, $out_intf) = @_;

                # Destination of current rule is current router.
                # Outgoing packets from a router itself are never filtered.
                # Hence we don't need a reverse rule for current router.
                return if not $out_intf;
                my $router = $out_intf->{router};

		# It doesn't matter if a semi_managed device is stateless
		# because no code is generated.
		return if not $router->{managed};
                my $model = $router->{model};

                if (
                    $model->{stateless}

                    # Source of current rule is current router.
                    or not $in_intf and $model->{stateless_self}

                    # Stateless tunnel interface of ASA-VPN.
                    or $model->{stateless_tunnel}
                    and $out_intf->{ip} eq 'tunnel'
                  )
                {
                    $has_stateless_router = 1;

                    # Jump out of path_walk.
                    no warnings "exiting";
                    last PATH_WALK if $use_nonlocal_exit;
                }
            };
            path_walk($rule, $mark_reverse_rule);
        }
        if ($has_stateless_router) {
            my $new_src_range;
            my $new_srv;
            if ($proto eq 'tcp') {
                $new_src_range = $range_tcp_any;
                $new_srv       = $range_tcp_established;
            }
            elsif ($proto eq 'udp') {

                # Swap src and dst range.
                $new_src_range = $rule->{srv};
                $new_srv       = $rule->{src_range};
            }
            elsif ($proto eq 'ip') {
                $new_srv       = $rule->{srv};
                $new_src_range = $rule->{src_range};
            }
            else {
                internal_err;
            }
            my $new_rule = {

                # This rule must only be applied to stateless routers.
                stateless => 1,
                action    => $rule->{action},
                src       => $rule->{dst},
                dst       => $rule->{src},
                src_range => $new_src_range,
                srv       => $new_srv,
            };
            $new_rule->{any_are_neighbors} = 1 if $rule->{any_are_neighbors};

            # Don't push to @$rule_aref while we are iterating over it.
            push @extra_rules, $new_rule;
        }
    }
    push @$rule_aref, @extra_rules;
    add_rules \@extra_rules;
}

sub gen_reverse_rules() {
    progress "Generating reverse rules for stateless routers";
    for my $type ('deny', 'any', 'permit') {
        gen_reverse_rules1 $expanded_rules{$type};
    }
}

##############################################################################
# Mark rules for secondary filtering.
# A rule is implemented at a device
# either as a 'typical' or as a 'secondary' filter.
# A filter is called to be 'secondary' if it only checks
# for the source and destination network and not for the service.
# A typical filter checks for full source and destination IP and
# for the service of the rule.
#
# There are four types of packet filters: secondary, standard, full, primary.
# A rule is marked by two attributes which are determined by the type of
# devices located on the path from source to destination.
# - 'some_primary': at least one device is primary packet filter,
# - 'some_non_secondary': at least one device is not secondary packet filter.
# A rule is implemented as a secondary filter at a device if
# - the device is secondary and the rule has attribute 'some_non_secondary' or
# - the device is standard and the rule has attribute 'some_primary'.
# Otherwise a rules is implemented typical.
##############################################################################

sub get_any2( $ ) {
    my ($obj) = @_;
    my $type = ref $obj;
    if ($type eq 'Network') {
        return $obj->{any};
    }
    elsif ($type eq 'Subnet') {
        return $obj->{network}->{any};
    }
    elsif ($type eq 'Interface') {
        return $obj->{network}->{any};
    }
    elsif ($type eq 'Any') {
        return $obj;
    }
}

# Mark security domain $any with $mark and
# additionally mark all security domains
# which are connected with $any by secondary packet filters.
sub mark_secondary ( $$ );

sub mark_secondary ( $$ ) {
    my ($any, $mark) = @_;
    $any->{secondary_mark} = $mark;
    for my $in_interface (@{ $any->{interfaces} }) {
        my $router = $in_interface->{router};
	if(my $managed = $router->{managed}) {
	    next if $managed ne 'secondary';
	}
        next if $router->{active_path};
        $router->{active_path} = 1;
        for my $out_interface (@{ $router->{interfaces} }) {
            next if $out_interface eq $in_interface;
            my $next_any = $out_interface->{any};
            next if $next_any->{secondary_mark};
            mark_secondary $next_any, $mark;
        }
        delete $router->{active_path};
    }
}

# Mark security domain $any with $mark and
# additionally mark all security domains
# which are connected with $any by non-primary packet filters.
# Test for {active_path} has been added to prevent deep recursion.
sub mark_primary ( $$ );

sub mark_primary ( $$ ) {
    my ($any, $mark) = @_;
    $any->{primary_mark} = $mark;
    for my $in_interface (@{ $any->{interfaces} }) {
        my $router = $in_interface->{router};
	if(my $managed = $router->{managed}) {
	    next if $managed eq 'primary';
	}
        next if $router->{active_path};
        $router->{active_path} = 1;
        for my $out_interface (@{ $router->{interfaces} }) {
            next if $out_interface eq $in_interface;
            my $next_any = $out_interface->{any};
            next if $next_any->{primary_mark};
            mark_primary $next_any, $mark;
        }
        delete $router->{active_path};
    }
}

sub mark_secondary_rules() {
    progress "Marking rules for secondary optimization";

    my $secondary_mark = 1;
    my $primary_mark   = 1;
    for my $any (@all_anys) {
        if (not $any->{secondary_mark}) {
            mark_secondary $any, $secondary_mark++;
        }
        if (not $any->{primary_mark}) {
            mark_primary $any, $primary_mark++;
        }
    }

    # Mark only normal rules for secondary optimization.
    # We can't change a deny rule from e.g. tcp to ip.
    # We can't change 'any' rules, because path is unknown.
    for my $rule (@{ $expanded_rules{permit} }) {
        next
          if $rule->{deleted}
              and
              (not $rule->{managed_intf} or $rule->{deleted}->{managed_intf});

        my $src_any = get_any2 $rule->{src};
        my $dst_any = get_any2 $rule->{dst};

        if ($src_any->{secondary_mark} ne $dst_any->{secondary_mark}) {
            $rule->{some_non_secondary} = 1;
        }
        if ($src_any->{primary_mark} ne $dst_any->{primary_mark}) {
            $rule->{some_primary} = 1;
        }
    }

    # Find rules where dynamic NAT is applied to host or interface at
    # src or dst on path to other end of rule.
    # Mark found rule with attribute {dynamic_nat} and value src|dst|src,dst.
    progress "Marking rules with dynamic NAT";
    for my $rule (@{ $expanded_rules{permit} }, 
                  @{ $expanded_rules{any} }, 
                  @{ $expanded_rules{deny} }) 
    {
        next
          if $rule->{deleted}
              and
              (not $rule->{managed_intf} or $rule->{deleted}->{managed_intf});

        my $dynamic_nat;
        for my $where ('src', 'dst') {
            my $obj = $rule->{$where};
            my $type = ref $obj;
	    next if $type eq 'Any';
            my $network = ($type eq 'Network') 
                        ? $obj
			: $obj->{network};
            my $nat_hash = $network->{nat} or next;
            my $other = $where eq 'src' ? $rule->{dst} : $rule->{src};
	    my $otype = ref $other;
            my $nat_domain = ($otype eq 'Network') 
                           ? $other->{nat_domain}
                           : ($otype eq 'Subnet' or $otype eq 'Interface')
                           ? $other->{network}->{nat_domain}
                           : undef;	# $otype eq 'Any'
            my $no_nat_set = $nat_domain ? $nat_domain->{no_nat_set} : {};
	    my $hidden;
	    my $dynamic;
            for my $nat_tag (keys %$nat_hash) {
                next if $no_nat_set->{$nat_tag};
                my $nat_network = $nat_hash->{$nat_tag};

                # Network is hidden by NAT.
                if ($nat_network->{hidden} and not $hidden) {
		    if ($nat_domain) {
			$hidden = 1;
		    }

		    # Other is any, check interface where any is entered.
		    else {
			my @interfaces;
			path_walk ($rule, sub {
			    my ($rule, $in_intf, $out_intf) = @_;
			    push @interfaces, $out_intf 
				if $out_intf->{any} eq $other;
			});
			for my $interface (@interfaces)
			{
			    my $no_nat_set = $interface->{no_nat_set};
			    next if $no_nat_set->{$nat_tag};
			    my $nat_network = $nat_hash->{$nat_tag};
			    if ($nat_network->{hidden}) {
				$hidden = 1;
			    }			    
			}
		    }
		    if ($hidden) {
			err_msg "$obj->{name} is hidden by NAT in rule\n ",
			print_rule $rule;
		    }
		}

		# Network has dynamic NAT.
		# Host / interface doesn't have static NAT.
		if ($nat_network->{dynamic} and
		    $type eq 'Subnet' or $type eq 'Interface' and
		    not $obj->{nat}->{$nat_tag} and 
		    not $dynamic) 
		{
		    $dynamic_nat = $dynamic_nat 
			         ? "$dynamic_nat,$where" 
				 : $where;
#		    debug "dynamic_nat: $where at ", print_rule $rule;
		    $dynamic = 1;
		}
	    }
        }
        $rule->{dynamic_nat} = $dynamic_nat if $dynamic_nat;
    }                        
}

##############################################################################
# Optimize expanded rules by deleting identical rules and
# rules which are overlapped by a more general rule
##############################################################################

sub optimize_rules( $$ ) {
    my ($cmp_hash, $chg_hash) = @_;
    while (my ($stateless, $chg_hash) = each %$chg_hash) {
        while (1) {
            if (my $cmp_hash = $cmp_hash->{$stateless}) {
                while (my ($action, $chg_hash) = each %$chg_hash) {
                    while (1) {
                        if (my $cmp_hash = $cmp_hash->{$action}) {
                            while (my ($src_ref, $chg_hash) = each %$chg_hash) {
                                my $src = $ref2obj{$src_ref};
                                while (1) {
                                    if (my $cmp_hash = $cmp_hash->{$src}) {
                                        while (my ($dst_ref, $chg_hash) =
                                            each %$chg_hash)
                                        {
                                            my $dst = $ref2obj{$dst_ref};
                                            while (1) {
                                                if (my $cmp_hash =
                                                    $cmp_hash->{$dst})
                                                {
                                                    while (
                                                        my ($src_range_ref,
                                                            $chg_hash)
                                                        = each %$chg_hash
                                                      )
                                                    {
                                                        my $src_range =
                                                          $ref2srv{
                                                            $src_range_ref};
                                                        while (1) {
                                                            if (my $cmp_hash =
                                                                $cmp_hash
                                                                ->{$src_range})
                                                            {
                                                                for
                                                                  my $chg_rule (
                                                                    values
                                                                    %$chg_hash)
                                                                {
                                                                    next
                                                                      if
                                                                        $chg_rule
                                                                          ->{deleted};
                                                                    my $srv =
                                                                      $chg_rule
                                                                      ->{srv};
                                                                    while (1) {
                                                                        if (
                                                                            my $cmp_rule
                                                                            = $cmp_hash
                                                                            ->{
                                                                                $srv
                                                                            }
                                                                          )
                                                                        {
                                                                            unless
                                                                              (
                                                                                $cmp_rule
                                                                                eq
                                                                                $chg_rule
                                                                              )
                                                                            {

# debug "Del:", print_rule $chg_rule;
# debug "Oth:", print_rule $cmp_rule;
                                                                                $chg_rule
                                                                                  ->
                                                                                  {deleted}
                                                                                  =
                                                                                  $cmp_rule;
										push @deleted_rules, $chg_rule if $config{check_redundant_rules};
                                                                                last;
                                                                            }
                                                                        }
                                                                        $srv =
                                                                          $srv
                                                                          ->{up}
                                                                          or
                                                                          last;
                                                                    }
                                                                }
                                                            }
                                                            $src_range =
                                                              $src_range->{up}
                                                              or last;
                                                        }
                                                    }
                                                }
                                                $dst = $dst->{up} or last;
                                            }
                                        }
                                    }
                                    $src = $src->{up} or last;
                                }
                            }
                        }
                        last if $action eq 'deny';
                        $action = 'deny';
                    }
                }
            }
            last if !$stateless;
            $stateless = 0;
        }
    }
}

sub optimize() {
    progress "Optimizing globally";
    setup_ref2obj;
    optimize_rules \%rule_tree, \%rule_tree;
    print_rulecount;
}

sub optimize_and_warn_deleted() {
    optimize();
    show_deleted_rules2;
}

# Collect networks which need NAT commands.
sub mark_networks_for_static( $$$ ) {
    my ($rule, $in_intf, $out_intf) = @_;

    # No NAT needed for directly attached interface.
    return unless $out_intf;

    # No NAT needed for traffic originating from the device itself.
    return unless $in_intf;

    my $router = $out_intf->{router};
    return unless $router->{managed};
    my $model = $router->{model};
    return unless $model->{has_interface_level};

    # We need in_hw and out_hw for
    # - attaching attribute src_nat and
    # - getting the NAT tag.
    my $in_hw  = $in_intf->{hardware};
    my $out_hw = $out_intf->{hardware};
    if ($in_hw->{level} == $out_hw->{level}) {
	return if $in_intf->{ip} eq 'tunnel' or $out_intf->{ip} eq 'tunnel';
        err_msg "Traffic of rule\n", print_rule $rule,
          "\n can't pass from  $in_intf->{name} to $out_intf->{name},\n",
          " which have equal security levels.\n";
    }

    my $identity_nat = $model->{need_identity_nat};
    if ($identity_nat) {

        # Static dst NAT is equivalent to reversed src NAT.
        for my $dst (@{ $rule->{dst_net} }) {
            $out_hw->{src_nat}->{$in_hw}->{$dst} = $dst;
        }
        if ($in_hw->{level} > $out_hw->{level}) {
            $in_hw->{need_nat_0} = 1;
        }
    }

    # Not identity NAT, handle real dst NAT.
    elsif (my $nat_tags = $in_hw->{bind_nat}) {
        for my $dst (@{ $rule->{dst_net} }) {
            my $nat_info = $dst->{nat} or next;
            grep({ $nat_info->{$_} } @$nat_tags) or next;

            # Store reversed dst NAT for real translation.
            $out_hw->{src_nat}->{$in_hw}->{$dst} = $dst;
        }
    }

    # Handle real src NAT.
    # Remember:
    # NAT tag for network located behind in_hw is attached to out_hw.
    my $nat_tags = $out_hw->{bind_nat} or return;
    for my $src (@{ $rule->{src_net} }) {
        my $nat_info = $src->{nat} or next;

	# We can be sure to get a single result.
	# Binding for different NAT of a single network has been 
	# rejected in distribute_nat_info.
        my ($nat_net) = map({ $nat_info->{$_} || () } @$nat_tags) or next;

        # Store src NAT for real translation.
        $in_hw->{src_nat}->{$out_hw}->{$src} = $src;

        if ($identity_nat) {

            # Check if there is a dynamic NAT of src address from lower
            # to higher security level. We need this info to decide,
            # if static commands with "identity mapping" and a "nat 0" command
            # need to be generated.
            if ($nat_net->{dynamic} and $in_hw->{level} < $out_hw->{level}) {
                $in_hw->{need_identity_nat} = 1;
                $in_hw->{need_nat_0}        = 1;
            }
        }
    }
}

sub get_any3( $ ) {
    my ($obj) = @_;
    my $type = ref $obj;
    if ($type eq 'Network') {
        return $obj->{any};
    }
    elsif ($type eq 'Subnet') {
        return $obj->{network}->{any};
    }
    elsif ($type eq 'Interface') {
        if ($obj->{router}->{managed} or $obj->{router}->{semi_managed}) {
            return $obj;
        }
        else {
            return $obj->{network}->{any};
        }
    }
    elsif ($type eq 'Any') {
        return $obj;
    }
    else {
        internal_err;
    }
}

sub find_statics () {
    progress "Finding statics";

    # We only need to traverse the topology for each pair of
    # src-(any/router), dst-(any/router)
    my %any2any2rule;
    my $pseudo_srv = { name => '--' };
    for my $rule (@{ $expanded_rules{permit} }, @{ $expanded_rules{any} }) {
        my ($src, $dst) = @{$rule}{qw(src dst)};
        my $from = get_any3 $src;
        my $to   = get_any3 $dst;
        $any2any2rule{$from}->{$to} ||= {
            src     => $from,
            dst     => $to,
            action  => '--',
            srv     => $pseudo_srv,
            src_net => {},
            dst_net => {},
        };
        my $rule2 = $any2any2rule{$from}->{$to};
        for my $network (get_networks($src)) {
            $rule2->{src_net}->{$network} = $network;
        }
        for my $network (get_networks($dst)) {
            $rule2->{dst_net}->{$network} = $network;
        }
    }
    for my $hash (values %any2any2rule) {
        for my $rule (values %$hash) {
            $rule->{src_net} = [ values %{ $rule->{src_net} } ];
            $rule->{dst_net} = [ values %{ $rule->{dst_net} } ];

#           debug "$rule->{src}->{name}, $rule->{dst}->{name}";
            path_walk($rule, \&mark_networks_for_static, 'Router');
        }
    }
}
  
########################################################################
# Routing
########################################################################

# Set up data structure to find routing info inside a security domain.
# Some definitions:
# - Border interfaces are directly attached to the security domain.
# - Border networks are located inside the security domain and are attached
#   to border interfaces.
# - All interfaces of border networks, which are not border interfaces, 
#   are called hop interfaces, because they are used as next hop from
#   border interfaces.
# - A cluster is a maximal set of networks of the security domain,
#   which is surrounded by hop interfaces.
# For each border interface I and each network N inside the security domain
# we need to find the hop interface H via which N is reached from I.
# This is stored in an attribute {route_in_any} of I.
sub set_routes_in_any ( $ ) {
    my ($any) = @_;

    # Mark border networks and hop interfaces.
    my %border_networks;
    my %hop_interfaces;
    for my $in_interface (@{ $any->{interfaces} }) {
	next if $in_interface->{main_interface};
	my $network = $in_interface->{network};
	next if $border_networks{$network};
	$border_networks{$network} = $network;
	for my $out_interface (@{ $network->{interfaces} }) {
	    next if $out_interface->{any};
	    next if $out_interface->{main_interface};
	    $hop_interfaces{$out_interface} = $out_interface;
	}
    }
    return if not keys %hop_interfaces;
    my %hop2cluster;
    my %cluster2borders;
    my $set_cluster;
    $set_cluster = sub {
	my ($router, $in_intf, $cluster) = @_;
	for my $interface (@{ $router->{interfaces} }) {
	    next if $interface->{main_interface};
	    if($hop_interfaces{$interface}) {
		$hop2cluster{$interface} = $cluster;
		my $network = $interface->{network};
		$cluster2borders{$cluster}->{$network} = $network;
		next;
	    }
	    next if $interface eq $in_intf;
	    my $network = $interface->{network};
	    next if $cluster->{$network};
	    $cluster->{$network} = $network;
	    for my $out_intf (@{ $network->{interfaces} }) {
		next if $out_intf eq $interface;
		next if $out_intf->{main_interface};
		$set_cluster->($out_intf->{router}, $out_intf, $cluster);
	    }
	}
    };
    for my $interface (values %hop_interfaces) {
	next if $hop2cluster{$interface};
	my $cluster = {};
	$set_cluster->($interface->{router}, $interface, $cluster);
#	debug $interface->{name};
#	debug join ',', map {$_->{name}} values %$cluster if keys %$cluster;
    }

    # Find all networks located behind a hop interface.
    my %hop2networks;
    my $set_networks_behind;
    $set_networks_behind = sub {
	my($hop, $in_border) = @_;
	return if $hop2networks{$hop};
	my $cluster = $hop2cluster{$hop};

	# Add networks of directly attached cluster to result.
	my @result = values %$cluster;

	for my $border (values %{ $cluster2borders{$cluster} }) {
	    next if $border eq $in_border;

	    # Add other border networks to result.
	    push @result, $border;
	    for my $out_hop (@{ $border->{interfaces} }) {
		next if not $hop_interfaces{$out_hop};
		next if $hop2cluster{$out_hop} eq $cluster;
		$set_networks_behind->($out_hop, $border);

		# Add networks from clusters located behind 
		# other border networks.
		push @result, @{ $hop2networks{$out_hop} };
	    }
	}
	$hop2networks{$hop} = \@result;
    };
    for my $border (values %border_networks) {
	my @border_intf;
	my @hop_intf;
	for my $interface (@{ $border->{interfaces} }) {
	    next if $interface->{main_interface};
	    if($interface->{any}) {
		push @border_intf, $interface;
	    }
	    else {
		push @hop_intf, $interface;
	    }
	}
	for my $hop (@hop_intf) {
	    $set_networks_behind->($hop, $border);
	    for my $interface (@border_intf) {
		for my $network (@{ $hop2networks{$hop} }) {
		    push @{ $interface->{route_in_any}->{$network} }, $hop;
		}
	    }
	}
    }
}

# A security domain is entered at $in_intf and exited at $out_intf.
# Find the hop H to reach $out_intf from $in_intf.
# Add routing entries at $in_intf that $dst_networks are reachable via H.
sub add_path_routes ( $$$ ) {
    my($in_intf, $out_intf, $dst_networks) = @_;
    return if $in_intf->{routing};
    my $out_net = $out_intf->{network};
    my $hops = $in_intf->{route_in_any}->{$out_net} || [$out_intf];
    for my $hop (@$hops) {
	$in_intf->{hop}->{$hop} = $hop;
	for my $network (@$dst_networks) {
#	    debug "$in_intf->{name} -> $hop->{name}: $network->{name}";
	    $in_intf->{routes}->{$hop}->{$network} = $network;
	}
    }
}

# A security domain is entered at $interface.
# $dst_networks are located inside the security domain.
# For each element N of $dst_networks find the next hop H to reach N.
# Add routing entries at $interface that N is reachable via H.
sub add_end_routes ( $$ ) {
    my($interface, $dst_networks) = @_;
    return if $interface->{routing};
    my $intf_net = $interface->{network};
    my $route_in_any = $interface->{route_in_any};
    for my $network (@$dst_networks) {
	next if $network eq $intf_net;
	my $hops = $route_in_any->{$network} or
	    internal_err 
	    "Missing route for $network->{name} at $interface->{name}";
	for my $hop (@$hops) {
	    $interface->{hop}->{$hop} = $hop;
#	    debug "$interface->{name} -> $hop->{name}: $network->{name}";
	    $interface->{routes}->{$hop}->{$network} = $network;
	}
    }
}

# This function is called for each 'any' on the path from src to dst
# of $rule.
# If $in_intf and $out_intf are both defined, packets traverse this 'any'.
# If $in_intf is not defined, the src is this 'any'.
# If $out_intf is not defined, dst is this 'any';
sub get_route_path( $$$ ) {
    my ($rule, $in_intf, $out_intf) = @_;

#    debug "collect: $rule->{src}->{name} -> $rule->{dst}->{name}";
#    my $info = '';
#    $info .= $in_intf->{name} if $in_intf;
#    $info .= ' -> ';
#    $info .= $out_intf->{name} if $out_intf;
#    debug $info;;

    if($in_intf and $out_intf) {
	push @{ $rule->{path} }, [ $in_intf, $out_intf ];
    }
    elsif(not $in_intf) {
	push @{$rule->{path_entries}}, $out_intf;
    }
    else {
	push @{$rule->{path_exits}}, $in_intf;
    }
}

sub check_and_convert_routes ();

sub find_active_routes () {
    progress "Finding routes";
    for my $any (@all_anys) {
	set_routes_in_any $any;
    }
    my %routing_tree;
    my $pseudo_srv = { name => '--' };
    for my $rule (@{ $expanded_rules{permit} }, @{ $expanded_rules{any} }) {
        my ($src, $dst) = ($rule->{src}, $rule->{dst});

	# Ignore deleted rules.
	# Add the typical check for {managed_intf} 
	# which covers the destination interface.
	# Because we handle both directions at once,
	# we would need an attribute {managed_intf} 
	# for the source interface as well. But this attribute doesn't exist
	# and we add an equivalent check for source.
	if ($rule->{deleted}
	    and (not $rule->{managed_intf} or $rule->{deleted}->{managed_intf})
	    and (not (is_interface $src and $src->{router}->{managed})
		 or (is_interface $rule->{deleted}->{src} 
		     and $rule->{deleted}->{src}->{router}->{managed}))) {
	    next;
	}
	my $src_any = get_any2 $src;
	my $dst_any = get_any2 $dst;

	# Source interface is located in security domain of destination or
	# destination interface is located in security domain of source.
	# path_walk will do nothing.
	if($src_any eq $dst_any) {
	    for my $from ($src, $dst) {
		my $to = $from eq $src ? $dst : $src;
		next if not is_interface $from;
		next if not $from->{any};
		$from = $from->{main_interface} || $from;
		my @networks = get_networks($to);
		add_end_routes($from, \@networks);
	    }
	    next;
	}
	my $pseudo_rule;
	if($pseudo_rule = $routing_tree{$src_any}->{$dst_any}) {
	}
	elsif($pseudo_rule = $routing_tree{$dst_any}->{$src_any}) {
	    ($src, $dst) = ($dst, $src);
	    ($src_any, $dst_any) = ($dst_any, $src_any);
	}
	else {
	    $pseudo_rule = {
		src    => $src_any,
		dst    => $dst_any,
		action => '--',
		srv    => $pseudo_srv,
	    };
	    $routing_tree{$src_any}->{$dst_any} = $pseudo_rule;
	}
	my @src_networks = get_networks($src);
        for my $network (@src_networks) {
	    $pseudo_rule->{src_networks}->{$network} = $network;
	}
	my @dst_networks = get_networks($dst);
        for my $network (@dst_networks) {
	    $pseudo_rule->{dst_networks}->{$network} = $network;
	}
	if(is_interface $src and $src->{router}->{managed}) {
	    $src = $src->{main_interface} || $src;
	    $pseudo_rule->{src_interfaces}->{$src} = $src;
	    for my $network (@dst_networks) {
		$pseudo_rule->{src_intf2nets}->{$src}->{$network} = $network;
	    }
	}
	if(is_interface $dst and $dst->{router}->{managed}) {
	    $dst = $dst->{main_interface} || $dst;
	    $pseudo_rule->{dst_interfaces}->{$dst} = $dst;
	    for my $network (@src_networks) {
		$pseudo_rule->{dst_intf2nets}->{$dst}->{$network} = $network;
	    }
	}
    }
    for my $href (values %routing_tree) {
	for my $pseudo_rule (values %$href) {
	    path_walk($pseudo_rule, \&get_route_path, 'Any');
	    my $src_networks = [ values %{ $pseudo_rule->{src_networks} } ];
	    my $dst_networks = [ values %{ $pseudo_rule->{dst_networks} } ];
	    my @src_interfaces =  values %{ $pseudo_rule->{src_interfaces} };
	    my @dst_interfaces =  values %{ $pseudo_rule->{dst_interfaces} };
	    for my $tuple (@{ $pseudo_rule->{path} }) {
		my($in_intf, $out_intf) = @$tuple;
		add_path_routes($in_intf, $out_intf, $dst_networks);
		add_path_routes($out_intf, $in_intf, $src_networks);
	    }
	    for my $entry (@{ $pseudo_rule->{path_entries} }) {
		for my $src_intf (@src_interfaces) {
		    next if $src_intf->{router} eq $entry->{router};
		    if(my $redun_intf = $src_intf->{redundancy_interfaces}) {
			if(grep { $_->{router} eq $entry->{router} } 
			   @$redun_intf)
			{
			    next;
			}
		    }
		    my $intf_nets = 
			[values %{$pseudo_rule->{src_intf2nets}->{$src_intf}}];
		    add_path_routes($src_intf, $entry, $intf_nets);
		}
		add_end_routes($entry, $src_networks);	    
	    }
	    for my $exit (@{ $pseudo_rule->{path_exits} }) {
		for my $dst_intf (@dst_interfaces) {
		    next if $dst_intf->{router} eq $exit->{router};
		    if(my $redun_intf = $dst_intf->{redundancy_interfaces}) {
			if(grep { $_->{router} eq $exit->{router} } 
			   @$redun_intf)
			{
			    next;
			}
		    }
		    my $intf_nets = 
			[values %{$pseudo_rule->{dst_intf2nets}->{$dst_intf}}];
		    add_path_routes($dst_intf, $exit, $intf_nets);
		}
		add_end_routes($exit, $dst_networks);
	    }
	}
    }
    check_and_convert_routes;
}

sub check_and_convert_routes () {
    progress "Checking for duplicate routes";
    for my $router (@managed_routers) {

	# Adjust routes through VPN tunnel to cleartext interface.
	for my $interface (@{ $router->{interfaces} }) {
	    next if not $interface->{ip} eq 'tunnel';
	    my $tunnel_routes = $interface->{routes};
	    $interface->{routes} = $interface->{hop} = {};
	    my $real_intf = $interface->{real_interface};
	    next if $real_intf->{routing};
	    for my $peer (@{ $interface->{peers} }) {
		my $real_peer = $peer->{real_interface};
		my $peer_net = $real_peer->{network};

		# Find hop to peer network and add tunnel networks to this hop.
		my $hop_routes;

		# Special case: peer network is directly connected.
		if ($real_intf->{network} eq $peer_net) {
		    if ($real_peer->{ip} !~ /^(?:short|negotiated)$/) {
			$hop_routes = 
			    $real_intf->{routes}->{$real_peer} ||= {};
			$real_intf->{hop}->{$real_peer} = $real_peer;
		    }
		}

		# Search peer network behind all available hops.
		else {
		    for my $net_hash (values %{ $real_intf->{routes}}) {
			if ($net_hash->{$peer_net}) {
			    $hop_routes = $net_hash;
			    last;
			}
		    }
		}

		if (not $hop_routes) {

		    # Try to guess default route, if only one hop is available.
		    my @try_hops = 
			grep({ $_ ne $real_intf }
			     grep({ $_->{ip} !~ /^(?:short|negotiated)$/ }
				  @{ $real_intf->{network}->{interfaces} }));

		    if (@try_hops == 1) {
			my $hop = $try_hops[0];
			$hop_routes = $real_intf->{routes}->{$hop} ||= {};
			$real_intf->{hop}->{$hop} = $hop;
		    }
		}

		# Use found hop to reach tunneled networks in $tunnel_routes.
		if ($hop_routes) {
		    for my $tunnel_net_hash (values %$tunnel_routes) {
			for my $tunnel_net (values %$tunnel_net_hash) {
			    $hop_routes->{$tunnel_net} = $tunnel_net;
			}
		    }
		}

		# Inform user that route will be missing.
		else {
		    warn_msg 
			"Can't determine next hop while moving routes\n",
			" of $interface->{name} to $real_intf->{name}.\n";
		}
	    }
	}

        # Remember, via which local interface a network is reached.
        my %net2intf;
        for my $interface (@{ $router->{interfaces} }) {

            # Remember, via which remote interface a network is reached.
            my %net2hop;

	    # Remember, via which remote redundancy interfaces a network
	    # is reached. We use this to check, if alle members of a group
	    # of redundancy interfaces are used to reach the network.
	    # Otherwise it would be wrong to route to the virtual interface.
	    my %net2group;

            # Convert to array, because hash isn't needed any longer.
            # Array is sorted to get deterministic output.
            $interface->{hop} =
		[ sort { $a->{name} cmp $b->{name} }
                  values %{ $interface->{hop} } ];

	    next if $interface->{loop} and $interface->{routing};
            for my $hop (@{ $interface->{hop} }) {
                for my $network (values %{ $interface->{routes}->{$hop} }) {
                    if (my $interface2 = $net2intf{$network}) {
                        if ($interface2 ne $interface) {

                            # Network is reached via two different
                            # local interfaces.  Show warning if static
                            # routing is enabled for both interfaces.
                            if (    not $interface->{routing}
                                and not $interface2->{routing})
                            {
                                warn_msg
				    "Two static routes for $network->{name}\n",
				    " via $interface->{name} and ",
				    "$interface2->{name}";
                            }
                        }
                    }
                    else {
                        $net2intf{$network} = $interface;
                    }
                    unless ($interface->{routing}) {
			my $group = $hop->{redundancy_interfaces} || '';
			if($group) {
			    push @{ $net2group{$network} }, $hop;
			}
                        if (my $hop2 = $net2hop{$network}) {

                            # Network is reached via two different hops.
                            # Check if both belong to same group 
			    # of redundancy interfaces.
			    my $group2 = $hop2->{redundancy_interfaces} || '';
                            if ($group eq $group2) {

                                # Prevent multiple identical routes to 
				# different interfaces 
				# with identical virtual IP.
                                delete $interface->{routes}->{$hop}->{$network};
                            }
                            else {
                                warn_msg
				    "Two static routes for $network->{name}\n",
				    " at $interface->{name}",
				    " via $hop->{name} and $hop2->{name}";
                            }
                        }
                        else {
                            $net2hop{$network} = $hop;
                        }
                    }
                }
	    }
	    for my $net_ref (keys %net2group) {
		my $hops = $net2group{$net_ref};
		my $hop1 = $hops->[0];
		if(@$hops != @{ $hop1->{redundancy_interfaces}}) {
		    my ($network) = grep { $_ eq $net_ref } 
		                      values %{ $interface->{routes}->{$hop1} };
		    # Test for loopback isn't realy needed.
		    # It's only a temporary hack to prevent some warnings.
		    $network->{loopback} or
		    warn_msg "$network->{name} is reached via $hop1->{name}",
		    " but not via related redundancy interfaces";
		}
	    }
	}
    }
}

sub find_active_routes_and_statics () {
    find_statics;
    find_active_routes;
}

sub ios_route_code( $ );
sub prefix_code( $ );
sub address( $$ );

sub numerically { $a <=> $b }

sub print_routes( $ ) {
    my ($router)     = @_;
    my $type         = $router->{model}->{routing};
    my $vrf          = $router->{vrf};
    my $comment_char = $router->{model}->{comment_char};
    my $do_auto_default_route = $config{auto_default_route};
    my %intf2hop2nets;
    for my $interface (@{ $router->{interfaces} }) {
        if ($interface->{routing}) {
            $do_auto_default_route = 0;
            next;
        }
        my $no_nat_set = $interface->{no_nat_set};

        for my $hop (@{ $interface->{hop} }) {
            my %mask_ip_hash;

            # A hash having all networks reachable via current hop
            # both as key and as value.
            my $net_hash = $interface->{routes}->{$hop};
            for my $network ( values %$net_hash ) {
		my $nat_network = get_nat_network($network, $no_nat_set);
		my ($ip, $mask) = @{$nat_network}{ 'ip', 'mask' };
		if ($ip == 0 and $mask == 0) {
		    $do_auto_default_route = 1;
		}

		# Implicitly overwrite duplicate networks.
                $mask_ip_hash{$mask}->{$ip} = $nat_network;
            } 

	    # Find and remove duplicate networks.
	    # Go from smaller to larger networks.
	    my @netinfo;
	    for my $mask (reverse sort keys %mask_ip_hash) {

		# Network 0.0.0.0/0.0.0.0 can't be subnet.
		last if $mask == 0;
	      NETWORK:
		for my $ip (sort numerically keys %{ $mask_ip_hash{$mask} }) 
		{

		    my $m = $mask;
		    my $i = $ip;
		    while ($m) {

			# Clear upper bit, because left shift is undefined 
			# otherwise.
			$m &= 0x7fffffff;
			$m <<= 1;
			$i &= $m;
			if ($mask_ip_hash{$m}->{$i}) {

			    # Network {$mask}->{$ip} is redundant.
			    # It is covered by {$m}->{$i}.
			    next NETWORK;
			}
		    }
		    push(@netinfo, 
			 [ $ip, $mask, $mask_ip_hash{$mask}->{$ip} ]);
		}
	    }
	    $intf2hop2nets{$interface}->{$hop} = \@netinfo;
        }
    }
    if ($do_auto_default_route) {

        # Find interface and hop with largest number of routing entries.
        my $max_intf;
        my $max_hop;

        # Substitute routes to one hop with a default route,
        # if there are at least two entries.
        my $max = 1;
        for my $interface (@{ $router->{interfaces} }) {
            for my $hop (@{ $interface->{hop} }) {
                my $count = @{ $intf2hop2nets{$interface}->{$hop} };
                if ($count > $max) {
                    $max_intf = $interface;
                    $max_hop  = $hop;
                    $max      = $count;
                }
            }
        }
        if ($max_intf && $max_hop) {

            # Use default route for this direction.
            $intf2hop2nets{$max_intf}->{$max_hop} = [[0, 0]];
        }
    }
    print "$comment_char [ Routing ]\n";

    # Prepare extension for IOS route command.
    $vrf = $vrf ? "vrf $vrf " : '';

    for my $interface (@{ $router->{interfaces} }) {

        # Don't generate static routing entries,
        # if a dynamic routing protocol is activated
        if ($interface->{routing}) {
            if ($config{comment_routes}) {
                print "$comment_char Routing $interface->{routing}->{name}",
                  " at $interface->{name}\n";
            }
            next;
        }

        for my $hop (@{ $interface->{hop} }) {

            # For unnumbered and negotiated interfaces use interface name
            # as next hop.
            my $hop_addr =
                $interface->{ip} =~ /^(?:unnumbered|negotiated|tunnel)$/
              ? $interface->{hardware}->{name}
              : print_ip $hop->{ip};

            for my $netinfo (@{ $intf2hop2nets{$interface}->{$hop} }) {
                if ($config{comment_routes}) {
                    print 
			"$comment_char route $netinfo->[2] -> $hop->{name}\n";
                }
                if ($type eq 'IOS') {
                    my $adr = ios_route_code($netinfo);
                    print "ip route $vrf$adr $hop_addr\n";
                }
                elsif ($type eq 'PIX') {
                    my $adr = ios_route_code($netinfo);
                    print
                      "route $interface->{hardware}->{name} $adr $hop_addr\n";
                }
                elsif ($type eq 'iproute') {
                    my $adr = prefix_code($netinfo);
                    print "ip route add $adr via $hop_addr\n";
                }
                elsif ($type eq 'none') {

                    # Do nothing.
                }
                else {
                    internal_err "unexpected routing type '$type'";
                }
            }
        }
    }
}

##############################################################################
# 'static' commands for pix firewalls
##############################################################################

sub print_pix_static( $ ) {
    my ($router) = @_;
    my $comment_char = $router->{model}->{comment_char};
    print "$comment_char [ NAT ]\n";

    my @hardware =
      sort { $a->{level} <=> $b->{level} } @{ $router->{hardware} };

    # Print security level relation for each interface.
    print "! Security levels: ";
    my $prev_level;
    for my $hardware (@hardware) {
        my $level = $hardware->{level};
        if (defined $prev_level) {
            print(($prev_level == $level) ? " = " : " < ");
        }
        print $hardware->{name};
        $prev_level = $level;
    }
    print "\n";

    # Index for naming NAT pools. This is also referenced in "nat" command.
    my $nat_index = 1;

    # Hash of indexes for reusing of NAT pools.
    my %intf2net2mask2index;

    for my $in_hw (@hardware) {
        my $src_nat = $in_hw->{src_nat} or next;
        my $in_name = $in_hw->{name};
        my $in_nat  = $in_hw->{no_nat_set};
        for my $out_hw (@hardware) {

            # Value is { net => net, .. }
            my $net_hash = $src_nat->{$out_hw} or next;
            my $out_name = $out_hw->{name};
            my $out_nat  = $out_hw->{no_nat_set};

            # Needed for "global (outside) interface" command.
            my $out_intf_ip = $out_hw->{interfaces}->[0]->{ip};

            # Prevent duplicate entries from different networks translated
            # to an identical address.
            my @has_indentical;
            for my $network (values %$net_hash) {
                my $identical = $network->{is_identical} or next;
                my $in        = $identical->{$in_nat};
                my $out       = $identical->{$out_nat};
                if ($in && $out && $in eq $out) {
                    push @has_indentical, $network;
                }
            }
            for my $network (@has_indentical) {
                delete $net_hash->{$network};
                my $one_net = $network->{is_identical}->{$out_nat};
                $net_hash->{$one_net} = $one_net;
            }

            # Sorting is only needed for getting output deterministic.
            # For equal addresses look at the NAT address.
            my @networks =
              sort {
                     $a->{ip} <=> $b->{ip}
                  || $a->{mask} <=> $b->{mask}
                  || get_nat_network($a, $out_nat)->{ip} <=> 
		      get_nat_network($b, $out_nat)->{ip}
              } values %$net_hash;

            # Mark redundant network as deleted.
            # A network is redundant if some enclosing network is found
            # in both NAT domains of incoming and outgoing interface.
            for my $network (@networks) {
                my $net = $network->{is_in}->{$out_nat};
                while ($net) {
                    my $net2;
                    if (    $net_hash->{$net}
                        and $net2 = $network->{is_in}->{$in_nat}
                        and $net_hash->{$net2})
                    {
                        $network = undef;
                        last;
                    }
                    else {
                        $net = $net->{is_in}->{$out_nat};
                    }
                }
            }
            for my $network (@networks) {
                next if not $network;
                my ($in_ip, $in_mask, $in_dynamic) =
                  @{ get_nat_network($network, $in_nat) }{qw(ip mask dynamic)};
                my ($out_ip, $out_mask, $out_dynamic) =
                  @{ get_nat_network($network, $out_nat) }{qw(ip mask dynamic)};
                if ($in_mask == 0 || $out_mask == 0) {
                    err_msg
                      "$router->{name} doesn't support static command for ",
                      "mask 0.0.0.0 of $network->{name}\n";
                }

                # Ignore dynamic translation, which doesn't occur
                # at current router
                if (    $out_dynamic
                    and $in_dynamic
                    and $out_dynamic eq $in_dynamic)
                {
                    $out_dynamic = $in_dynamic = undef;
                }

                # We are talking about source addresses.
                if ($in_dynamic) {
                    warn_msg "Duplicate NAT for already dynamically",
                      " translated $network->{name}\n",
                      "at hardware $in_hw->{name} of $router->{name}";
                }
                if ($out_dynamic) {

                    # Use a single "global" command if multiple networks are
                    # mapped to a single pool.
                    my $index =
                      $intf2net2mask2index{$out_name}->{$out_ip}->{$out_mask};
                    if (not $index) {
                        $index = $nat_index++;
                        $intf2net2mask2index{$out_name}->{$out_ip}
                          ->{$out_mask} = $index;
                        my $pool;

                        # global (outside) 1 interface
                        if (   $out_ip == $out_intf_ip
                            && $out_mask == 0xffffffff)
                        {
                            $pool = 'interface';
                        }

                        # global (outside) 1 \
                        #   10.70.167.0-10.70.167.255 netmask 255.255.255.0
                        # nat (inside) 1 141.4.136.0 255.255.252.0
                        else {
                            my $max  = $out_ip | complement_32bit $out_mask;
                            my $mask = print_ip $out_mask;
                            my $range =
                              ($out_ip == $max)
                              ? print_ip($out_ip)
                              : print_ip($out_ip) . '-' . print_ip($max);
                            $pool = "$range netmask $mask";
                        }
                        print "global ($out_name) $index $pool\n";
                    }
                    my $in   = print_ip $in_ip;
                    my $mask = print_ip $in_mask;
                    print "nat ($in_name) $index $in $mask";
                    print " outside" if $in_hw->{level} < $out_hw->{level};
                    print "\n";
                    $nat_index++;

                    # Check for static NAT entries of hosts and interfaces.
                    for my $host (@{ $network->{subnets} },
                        @{ $network->{interfaces} })
                    {
                        if (my $out_ip = $host->{nat}->{$out_dynamic}) {
                            my $pair = address($host, $out_nat);
                            my ($out_ip, $out_mask) = @$pair;
                            my $in   = print_ip $in_ip;
                            my $out  = print_ip $out_ip;
                            my $mask = print_ip $out_mask;
                            print "static ($in_name,$out_name) ",
                              "$out $in netmask $mask\n";
                        }
                    }
                }

                # Static translation.
                else {
                    if (   $in_hw->{level} > $out_hw->{level}
                        || $in_hw->{need_identity_nat}
                        || $in_ip != $out_ip)
                    {
                        my $in   = print_ip $in_ip;
                        my $out  = print_ip $out_ip;
                        my $mask = print_ip $in_mask;

                        # static (inside,outside) \
                        #   10.111.0.0 111.0.0.0 netmask 255.255.252.0
                        print "static ($in_name,$out_name) ",
                          "$out $in netmask $mask\n";
                    }
                }
            }
        }
        print "nat ($in_name) 0 0.0.0.0 0.0.0.0\n" if $in_hw->{need_nat_0};
    }
}

##############################################################################
# Distributing rules to managed devices
##############################################################################

sub distribute_rule( $$$ ) {
    my ($rule, $in_intf, $out_intf) = @_;

    # Traffic from src reaches this router via in_intf
    # and leaves it via out_intf.
    # in_intf is undefined if src is an interface of current router.
    # out_intf is undefined if dst is an interface of current router.
    # Outgoing packets from a router itself are never filtered.
    return unless $in_intf;
    my $router = $in_intf->{router};
    return if not $router->{managed};
    my $model = $router->{model};

    # Rules of type stateless must only be processed at
    # - stateless routers or
    # - routers which are stateless for packets destined for
    #   their own interfaces or
    # - stateless tunnel interfaces of ASA-VPN.
    if ($rule->{stateless}) {
        if (
            not(   $model->{stateless}
                or not $out_intf and $model->{stateless_self}
                or $model->{stateless_tunnel} and $in_intf->{ip} eq 'tunnel')
          )
        {
            return;
        }
    }

    # Rules of type stateless_icmp must only be processed at routers
    # which don't handle stateless_icmp automatically;
    return if $rule->{stateless_icmp} and not $model->{stateless_icmp};

    # Rules to managed interfaces must be processed
    # at the corresponding router even if they are marked as deleted,
    # because code for interfaces is placed before the 'normal' code.
    if ($rule->{deleted}) {

        # We are on an intermediate router if $out_intf is defined.
        return if $out_intf;

        # No code needed if it is deleted by another rule to the same interface.
        return if $rule->{deleted}->{managed_intf};
    }

    # Validate dynamic NAT.
    if (my $dynamic_nat = $rule->{dynamic_nat}) {
        my $no_nat_set = $in_intf->{no_nat_set};
        for my $where (split(/,/, $dynamic_nat)) {
            my $obj = $rule->{$where};
            my $network = $obj->{network};
	    my $nat_network = get_nat_network($network, $no_nat_set);
            next if $nat_network eq $network;
            my $nat_tag = $nat_network->{dynamic} or next;

            # Ignore object with static translation.
            next if $obj->{nat}->{$nat_tag};

            # Object is located in the same security domain, hence
            # there is no other managed router in between.
            # $intf could have value 'undef' if $obj is interface of
            # current router and destination of rule.
            my $intf = $where eq 'src' ? $in_intf : $out_intf;
            if (!$intf || $network->{any} eq $intf->{any}) {
                err_msg "$obj->{name} needs static translation",
                " for nat:$nat_tag\n",
                " to be valid in rule\n ", print_rule $rule;
            }

            # Otherwise, filtering occurs at other router, therefore
            # the whole network can pass here.
            # But attention, this assumption only holds, if the other
            # router filters fully.  Hence disable optimization of
            # secondary rules.
            delete $rule->{some_non_secondary};
            delete $rule->{some_primary};

            # Permit whole network, because no static address is known.
            # Make a copy of current rule, because the original rule
            # must not be changed.
            $rule = {%$rule, $where => $network};
        }
    }

    my $key;
    if (not $out_intf) {

        # Packets for the router itself.  For PIX we can only reach that
        # interface, where traffic enters the PIX.
	if ($model->{filter} eq 'PIX') {
	    my $dst = $rule->{dst};
	    if ($dst eq $in_intf) {
	    }
	    elsif ($dst eq $network_00 or $dst eq $in_intf->{network}) {

		# Change destination in $rule to interface
		# because pix_self_code needs interface.
		#
		# Make a copy of current rule, because the
		# original rule must not be changed.
		$rule = {%$rule};
		$rule->{dst} = $in_intf;
	    }
	    else {
		return;
	    }		
	}
        $key = 'intf_rules';
    }
    elsif ($out_intf->{hardware}->{need_out_acl}) {
	$key = 'out_rules';
	if (not $in_intf->{hardware}->{no_in_acl}) {
	    push @{ $in_intf->{hardware}->{rules} }, $rule;
	}
    }
    else {
        $key = 'rules';
    }

    if ($in_intf->{ip} eq 'tunnel') {

	# Rules for single software clients are stored individually.
	# Consistency checks have already been done at expand_crypto.
	# Rules are needed at tunnel for generating split tunnel ACL
	# regardless of $router->{no_crypto_filter} value.
        if (my $id2rules = $in_intf->{id_rules}) {
	    my $src = $rule->{src};
	    if (is_subnet $src) {
		my $id = $src->{id}
	           or internal_err "$src->{name} must have ID";
		my $id_intf = $id2rules->{$id}
                   or internal_err "No entry for $id at id_rules";
		push @{ $id_intf->{$key} }, $rule;
	    }
	    elsif (is_network $src) {
		$src->{has_id_hosts} or
		    internal_err "$src->{name} must have ID-hosts";
		for my $id (map { $_->{id} } @{ $src->{hosts} }) {
		    push @{ $id2rules->{$id}->{$key} }, $rule;
		}
	    }
	    else {
		internal_err 
		    "Expected host or network as src but got $src->{name}";
	    }
	}

	if ($router->{no_crypto_filter}) {
	    push @{ $in_intf->{real_interface}->{hardware}->{$key} }, $rule;
	}
	elsif (not $in_intf->{id_rules}) {
	    push @{ $in_intf->{$key} }, $rule;
	}
    }
    elsif ($key eq 'out_rules') {
	push @{ $out_intf->{hardware}->{$key} }, $rule;
    }

    # Remember outgoing interface.
    elsif ($key eq 'rules' and $model->{has_io_acl}) {
	push @{ $in_intf->{hardware}->{io_rules}
	       ->{$out_intf->{hardware}->{name}} }, $rule;
    }
    else {
	push @{ $in_intf->{hardware}->{$key} }, $rule;
    }
}

# For rules with src=any:*, call distribute_rule only for
# the first router on the path from src to dst.
sub distribute_rule_at_src( $$$ ) {
    my ($rule, $in_intf, $out_intf) = @_;
    my $src = $rule->{src};
    is_any $src or internal_err "$src must be of type 'any'";

    # Rule is only processed at the first router on the path.
    if ($in_intf->{any} eq $src) {
        &distribute_rule(@_);
    }
}

# For rules with dst=any:*, call distribute_rule only for
# the last router on the path from src to dst.
sub distribute_rule_at_dst( $$$ ) {
    my ($rule, $in_intf, $out_intf) = @_;
    my $dst = $rule->{dst};
    is_any $dst or internal_err "$dst must be of type 'any'";

    # Rule is only processed at the last router on the path.
    if ($out_intf->{any} eq $dst) {
        &distribute_rule(@_);
    }
}

# For each device, find the IP address which is used
# to manage the device from a central policy distribution point.
# This address is added as a comment line to each generated code file.
# This is to used later when approving the generated code file.
sub set_policy_distribution_ip () {
    return if not $policy_distribution_point;
    progress "Setting policy distribution IP";

    # Find all TCP ranges which include port 22 and 23.
    my @admin_tcp_keys = grep({ my ($p1, $p2) = split(':', $_); 
				$p1 <= 22 && 22 <= $p2 || 
				    $p1 <= 23 && 23 <= $p2; }
			      keys %{ $srv_hash{tcp} });
    my @srv_list = (@{$srv_hash{tcp}}{@admin_tcp_keys}, $srv_hash{ip});
    my %admin_srv;
    @admin_srv{@srv_list} = @srv_list;

    my %pdp_src;
    for my $pdp (map $_, @{ $policy_distribution_point->{subnets} }) {
        while ($pdp) {
            $pdp_src{$pdp} = $pdp;
            $pdp = $pdp->{up};
        }
    }
    my $no_nat_set =
      $policy_distribution_point->{network}->{nat_domain}->{no_nat_set};
    for my $router (@managed_routers) {
        my %interfaces;

	# Find interfaces where some rule permits management traffic.
        for my $intf (@{ $router->{hardware} },
            grep { $_->{ip} eq 'tunnel' } @{ $router->{interfaces} })
        {
            next if not $intf->{intf_rules};
            for my $rule (@{ $intf->{intf_rules} }) {
                my ($action, $src, $dst, $srv) =
                  @{$rule}{qw(action src dst srv)};
                next if $action eq 'deny';
                next if not $pdp_src{$src};
                next if not $admin_srv{$srv};
                $interfaces{$dst} = $dst;
            }
        }
        my @result;

	# Ready, if exactly one management interface was found.
        if (keys %interfaces == 1) {
            @result = values %interfaces;
        }
        else {

#           debug "$router->{name}: ", scalar keys %interfaces;
            my @front =
              path_auto_interfaces($router, $policy_distribution_point);

	    # If multiple management interfaces were found, take that which is
	    # directed to policy_distribution_point.
            for my $front (@front) {
                if ($interfaces{$front}) {
                    push @result, $front;
                }
            }
	    
	    # Try all management interfaces.
	    @result = values %interfaces if not @result;

#	    # Try all interfaces directed to policy_distribution_point.
#	    @result = grep({ $_->{ip} !~ /^(?:unnumbered|negotiated|tunnel)$/ }
#			   @front) if not @result;
	    
	    # Don't set {admin_ip} if no address is found.
	    # Warning is printed later when all VRFs are joined.
	    next if not @result;
	}

	# Prefer loopback interface if available.
        $router->{admin_ip} =
          [ map { print_ip((address($_, $no_nat_set))->[0]) } 
	    sort { ($b->{loopback}||'') cmp ($a->{loopback}||'') } @result ];
    }
}

my $permit_any_rule =  
{
    action    => 'permit',
    src       => $network_00,
    dst       => $network_00,
    src_range => $srv_ip,
    srv       => $srv_ip
    };

sub add_router_acls () {
    for my $router (@managed_routers) {
	my $has_io_acl = $router->{model}->{has_io_acl};
        for my $hardware (@{ $router->{hardware} }) {

	    # Some managed devices are connected by a crosslink network.
	    # Permit any traffic at the internal crosslink interface.
	    if ($hardware->{crosslink}) {
		
		# We can savely change rules at hardware interface
		# because it has been checked that no other logical
		# networks are attached to the same hardware.
		#
		# Substitute rules for each outgoing interface.
		if ($has_io_acl) {
		    for my $rules (values %{ $hardware->{io_rules} }) {
			$rules = [ $permit_any_rule ];
		    }
		}
		else {
		    $hardware->{rules} = [ $permit_any_rule ];
		}
		$hardware->{intf_rules} = [ $permit_any_rule ];
		next;
	    }
	    
	    for my $interface (@{ $hardware->{interfaces} }) {

                # Current router is used as default router even for
                # some internal networks.
                if ($interface->{reroute_permit}) {
                    for my $net (@{ $interface->{reroute_permit} }) {

                        # This is not allowed between different
                        # security domains.
                        if ($net->{any}->{any_cluster} != 
			    $interface->{any}->{any_cluster}) 
			{
                            err_msg "Invalid reroute_permit for $net->{name} ",
                              "at $interface->{name}: different security domains";
                            next;
                        }

                        # Prepend to all other rules.
                        unshift(
                            @{  $has_io_acl

				# Incoming and outgoing interface are equal.
			      ? $hardware->{io_rules}->{$hardware->{name}} 
			      : $hardware->{rules} },
                            {
                                action    => 'permit',
                                src       => $network_00,
                                dst       => $net,
                                src_range => $srv_ip,
                                srv       => $srv_ip
                            }
                        );
                    }
                }

                # Is dynamic routing used?
                if (my $routing = $interface->{routing}) {
                    unless ($routing->{name} eq 'manual') {
                        my $srv       = $routing->{srv};
                        my $src_range = $srv_ip;
                        if (my $dst_range = $srv->{dst_range}) {
                            $src_range = $srv->{src_range};
                            $srv       = $srv->{dst_range};
                        }
                        my $network = $interface->{network};

                        # Permit multicast packets from current network.
                        for my $mcast (@{ $routing->{mcast} }) {
                            push @{ $hardware->{intf_rules} },
                              {
                                action    => 'permit',
                                src       => $network,
                                dst       => $mcast,
                                src_range => $src_range,
                                srv       => $srv
                              };
                            $ref2obj{$mcast}     = $mcast;
                            $ref2srv{$src_range} = $src_range;
                            $ref2srv{$srv}       = $srv;
                        }

                        # Additionally permit unicast packets.
                        # We use the network address as destination
                        # instead of the interface address,
                        # because we need fewer rules if the interface has
                        # multiple addresses.
                        push @{ $hardware->{intf_rules} },
                          {
                            action    => 'permit',
                            src       => $network,
                            dst       => $network,
                            src_range => $src_range,
                            srv       => $srv
                          };
                    }
                }

                # Handle multicast packets of redundancy protocols.
                if (my $type = $interface->{redundancy_type}) {
                    my $network   = $interface->{network};
                    my $mcast     = $xxrp_info{$type}->{mcast};
                    my $srv       = $xxrp_info{$type}->{srv};
                    my $src_range = $srv_ip;

                    # Is srv TCP or UDP with destination port range?
                    # Then use source port range as well.
                    if (my $dst_range = $srv->{dst_range}) {
                        $src_range = $srv->{src_range};
                        $srv       = $dst_range;
                    }
                    push @{ $hardware->{intf_rules} },
                      {
                        action    => 'permit',
                        src       => $network,
                        dst       => $mcast,
                        src_range => $src_range,
                        srv       => $srv
                      };
                    $ref2obj{$mcast}     = $mcast;
                    $ref2srv{$src_range} = $src_range;
                    $ref2srv{$srv}       = $srv;
                }
            }
        }
    }
}

# At least for $srv_esp and $srv_ah the ACL lines need to have a fixed order.
# Otherwise, 
# - if the device is accessed over an IPSec tunnel
# - and we change the ACL incrementally,
# the connection may be lost.
sub cmp_address {
    my ($obj) = @_;
    my $type = ref $obj;
    if ($type eq 'Network' or $type eq 'Subnet') {
	"$obj->{ip},$obj->{mask}";
    }
    elsif ($type eq 'Interface') {
	"$obj->{ip},".0xffffffff;
    }
    elsif ($type eq 'Any') {
        "0,0";
    }
    else {
	internal_err;
    }
}
    
sub distribute_global_permit {
    for my $srv (sort { $a->{name} cmp $b->{name} } values %global_permit) {
	my $stateless = $srv->{flags} && $srv->{flags}->{stateless};
	my $stateless_icmp = $srv->{flags} && $srv->{flags}->{stateless_icmp};
	$srv = $srv->{main} if $srv->{main};
	$srv->{src_dst_range_list} or internal_err $srv->{name};
	for my $src_dst_range (@{ $srv->{src_dst_range_list} }) {
	    my ($src_range, $srv) = @$src_dst_range;
	    $ref2srv{$src_range} = $src_range;
	    $ref2srv{$srv}       = $srv;
	    my $rule = { action => 'permit',
			 src => $network_00,
			 dst => $network_00,
			 src_range => $src_range,
			 srv => $srv,
			 stateless => $stateless,
			 stateless_icmp => $stateless_icmp,
		     };
	    for my $router (@managed_routers) {
		my $is_ios = ($router->{model}->{filter} eq 'IOS');
	      INTERFACE:
		for my $in_intf (@{ $router->{interfaces} }) {
		    if (my $restrictions = $in_intf->{path_restrict}) {
			for my $restrict (@$restrictions) {
			    next INTERFACE if $restrict->{active_path};
			}
		    }

		    # At VPN hub, don't permit any -> any, but only traffic
		    # from each encrypted network.
		    if ($in_intf->{is_hub}) {
			my $id_rules = $in_intf->{id_rules};
			for my $src ($id_rules
				     ? map({ $_->{src} } values %$id_rules )
				     : @{ $in_intf->{peer_networks} }) 
		    {
			    my $rule = { %$rule };
			    $rule->{src} = $src;
			    for my $out_intf (@{ $router->{interfaces} }) {
				next if $out_intf eq $in_intf;
				next if $out_intf->{ip} eq 'tunnel' and
				    not $out_intf->{no_check};

				# Traffic traverses the device.
				# Traffic for the device itself isn't needed
				# at VPN hub.
				distribute_rule($rule, $in_intf, $out_intf);
			    }			    
			}
		    }
		    else {
			for my $out_intf (@{ $router->{interfaces} }) {
			    next if $out_intf eq $in_intf;

			    # For IOS print this rule only once
			    # at interface block.
			    next if $is_ios;

			    # Traffic traverses the device.
			    distribute_rule($rule, $in_intf, $out_intf);
			}

			# Traffic for the device itself.
			distribute_rule($rule, $in_intf, undef);
		    }
		}
	    }
	}
    }
}
    
sub rules_distribution() {
    progress "Distributing rules";

    # Not longer used, free memory.
    %rule_tree = ();

    # Sort rules by reverse priority of service.
    # This should be done late to get all auxiliary rules processed.
    for my $type ('deny', 'any', 'permit') {
        $expanded_rules{$type} =
          [ sort { ($b->{srv}->{prio} || 0) <=> ($a->{srv}->{prio} || 0) ||
		       ($a->{srv}->{prio} || 0) &&
		       (cmp_address($a->{src}) cmp cmp_address($b->{src}) ||
			cmp_address($a->{dst}) cmp cmp_address($b->{dst}))
		   }
              @{ $expanded_rules{$type} } ];
    }

    # Deny rules
    for my $rule (@{ $expanded_rules{deny} }) {
        next if $rule->{deleted};
        path_walk($rule, \&distribute_rule);
    }

    # handle global permit after deny rules.
    distribute_global_permit();

    # Rules with 'any' object as src or dst.
    for my $rule (@{ $expanded_rules{any} }) {
        next
          if $rule->{deleted}
              and
              (not $rule->{managed_intf} or $rule->{deleted}->{managed_intf});
        if (is_any $rule->{src}) {
            if (is_any $rule->{dst}) {

                # Both, src and dst are 'any' objects.
                # We only need to generate code if they are directly connected
                # by a managed router.
                # See check_any_both_rule above for details.
                if ($rule->{any_are_neighbors}) {
                    path_walk($rule, \&distribute_rule_at_dst);
                }
            }
            else {
                path_walk($rule, \&distribute_rule_at_src);
            }
        }
        elsif (is_any $rule->{dst}) {
            path_walk($rule, \&distribute_rule_at_dst);
        }
        else {
            internal_err "unexpected rule ", print_rule $rule, "\n";
        }
    }

    # Other permit rules
    for my $rule (@{ $expanded_rules{permit} }) {
        next
          if $rule->{deleted}
              and
              (not $rule->{managed_intf} or $rule->{deleted}->{managed_intf});
        path_walk($rule, \&distribute_rule, 'Router');
    }

    # Find management IP of device before ACL lines are cleared for
    # crosslink interfaces during add_router_acls.
    set_policy_distribution_ip();
    add_router_acls();

    # Prepare rules for local_optimization.
    for my $rule (@{ $expanded_rules{any} }) {
        next if $rule->{deleted} and not $rule->{managed_intf};
        $rule->{src} = $network_00 if is_any $rule->{src};
        $rule->{dst} = $network_00 if is_any $rule->{dst};
    }

    # No longer needed, free some memory.
    %expanded_rules = ();
    %obj2path       = ();
    %key2obj        = ();
}

##############################################################################
# ACL Generation
##############################################################################

# Parameters:
# obj: this address we want to know
# network: look inside this NAT domain
# returns a list of [ ip, mask ] pairs
sub address( $$ ) {
    my ($obj, $no_nat_set) = @_;
    my $type = ref $obj;
    if ($type eq 'Network') {
        $obj = get_nat_network($obj, $no_nat_set);

        # ToDo: Is it OK to permit a dynamic address as destination?
        if ($obj->{ip} eq 'unnumbered') {
            internal_err "Unexpected unnumbered $obj->{name}\n";
        }
        else {
            return [ $obj->{ip}, $obj->{mask} ];
        }
    }
    elsif ($type eq 'Subnet') {
        my $network = get_nat_network($obj->{network}, $no_nat_set);
        if (my $nat_tag = $network->{dynamic}) {
            if (my $ip = $obj->{nat}->{$nat_tag}) {

                # Single static NAT IP for this host.
                return [ $ip, 0xffffffff ];
            }
            else {

                # This has been converted to the  whole network before.
                internal_err "Unexpected $obj->{name} with dynamic NAT";
            }
        }
        else {

            # Take higher bits from network NAT, lower bits from original IP.
            # This works with and without NAT.
            my $ip =
              $network->{ip} | $obj->{ip} & complement_32bit $network->{mask};
            return [ $ip, $obj->{mask} ];
        }
    }
    if ($type eq 'Interface') {
        if ($obj->{ip} =~ /unnumbered|short/) {
            internal_err "Unexpected $obj->{ip} $obj->{name}\n";
        }

        my $network = get_nat_network($obj->{network}, $no_nat_set);

        # Negotiated interfaces are dangerous:
        # If the attached network has address 0.0.0.0/0,
        # we would accidentally permit 'any'.
        # We allow this only, if local networks are protected by tunnel_all.
        if ($obj->{ip} eq 'negotiated') {
            my ($network_ip, $network_mask) = @{$network}{ 'ip', 'mask' };
            if (    $network_mask eq 0
                and not $obj->{spoke}
                and not $obj->{no_check})
            {
                err_msg "$obj->{name} has negotiated IP in range 0.0.0.0/0.\n",
                  "This is only allowed for interfaces protected by 'tunnel_all'.";
            }
            return [ $network_ip, $network_mask ];
        }
        if (my $nat_tag = $network->{dynamic}) {
            if (my $ip = $obj->{nat}->{$nat_tag}) {

                # Single static NAT IP for this interface.
                return [ $ip, 0xffffffff ];
            }
            else {
                internal_err "Unexpected $obj->{name} with dynamic NAT";
            }
        }
	elsif ($network->{isolated}) {

	    # NAT not allowed for isolated ports. Take no bits from network, 
	    # because secondary isolated ports don't match network.
	    return [ $obj->{ip}, 0xffffffff ];
	}
        else {

            # Take higher bits from network NAT, lower bits from original IP.
            # This works with and without NAT.
            my $ip =
              $network->{ip} | $obj->{ip} & complement_32bit $network->{mask};
            return [ $ip, 0xffffffff ];
        }
    }
    elsif ($type eq 'Any') {
        return [ 0, 0 ];
    }
    elsif ($type eq 'Objectgroup') {
        $obj;
    }
    else {
        internal_err "Unexpected object $obj->{name}";
    }
}

# Given an IP and mask, return its address in IOS syntax.
# If optional third parameter is true, use inverted netmask for IOS ACLs.
sub ios_code( $;$ ) {
    my ($pair, $inv_mask) = @_;
    if (is_objectgroup $pair) {
        return "object-group $pair->{name}";
    }
    else {
        my ($ip, $mask) = @$pair;
        my $ip_code = print_ip($ip);
        if ($mask == 0xffffffff) {
            return "host $ip_code";
        }
        elsif ($mask == 0) {
            return "any";
        }
        else {
            my $mask_code =
              print_ip($inv_mask ? complement_32bit $mask : $mask);
            return "$ip_code $mask_code";
        }
    }
}

sub ios_route_code( $ ) {
    my ($pair) = @_;
    my ($ip, $mask) = @$pair;
    my $ip_code   = print_ip($ip);
    my $mask_code = print_ip($mask);
    return "$ip_code $mask_code";
}

# Given an IP and mask, return its address
# as "x.x.x.x/x" or "x.x.x.x" if prefix == 32.
sub prefix_code( $ ) {
    my ($pair) = @_;
    my ($ip, $mask) = @$pair;
    my $ip_code     = print_ip($ip);
    my $prefix_code = mask2prefix($mask);
    return $prefix_code == 32 ? $ip_code : "$ip_code/$prefix_code";
}

my %pix_srv_hole;

# Print warnings about the PIX service hole.
sub warn_pix_icmp() {
    if (%pix_srv_hole) {
        warn_msg "Ignored the code field of the following ICMP services\n",
          " while generating code for pix firewalls:";
        while (my ($name, $count) = each %pix_srv_hole) {
            print STDERR " $name: $count times\n";
        }
    }
}

# Returns 3 values for building an IOS or PIX ACL:
# permit <val1> <src> <val2> <dst> <val3>
sub cisco_srv_code( $$$ ) {
    my ($src_range, $srv, $model) = @_;
    my $proto = $srv->{proto};

    if ($proto eq 'ip') {
        return ('ip', undef, undef);
    }
    elsif ($proto eq 'tcp' or $proto eq 'udp') {
        my $port_code = sub ( $$ ) {
            my ($v1, $v2) = @_;
            if ($v1 == $v2) {
                return ("eq $v1");
            }

            # PIX doesn't allow port 0; can port 0 be used anyhow?
            elsif ($v1 == 1 and $v2 == 65535) {
                return (undef);
            }
            elsif ($v2 == 65535) {
                return 'gt ' . ($v1 - 1);
            }
            elsif ($v1 == 1) {
                return 'lt ' . ($v2 + 1);
            }
            else {
                return ("range $v1 $v2");
            }
        };
        my $dst_srv = $port_code->(@{ $srv->{range} });
        if (my $established = $srv->{established}) {
            if ($model->{filter} eq 'PIX') {
                err_msg "Must not use 'established' at '$model->{name}'\n",
                  " - try model=secondary or \n",
                  " - don't use outgoing connection to VPN client";
            }
            if (defined $dst_srv) {
                $dst_srv .= ' established';
            }
            else {
                $dst_srv = 'established';
            }
        }
        return ($proto, $port_code->(@{ $src_range->{range} }), $dst_srv);
    }
    elsif ($proto eq 'icmp') {
        if (defined(my $type = $srv->{type})) {
            if (defined(my $code = $srv->{code})) {
                if ($model->{filter} eq 'VPN3K') {
                    err_msg "$model->{name} device can handle",
                      " only simple ICMP\n but not $srv->{name}";
                }
                if ($model->{no_filter_icmp_code}) {

                    # PIX can't handle the ICMP code field.
                    # If we try to permit e.g. "port unreachable",
                    # "unreachable any" could pass the PIX.
                    $pix_srv_hole{ $srv->{name} }++;
                    return ($proto, undef, $type);
                }
                else {
                    return ($proto, undef, "$type $code");
                }
            }
            else {
                return ($proto, undef, $type);
            }
        }
        else {
            return ($proto, undef, undef);
        }
    }
    else {
        return ($proto, undef, undef);
    }
}

# Code filtering traffic with PIX as destination.
sub pix_self_code ( $$$$$$ ) {
    my ($action, $spair, $dst, $src_range, $srv, $model) = @_;
    my $src_code = ios_route_code $spair;
    my $dst_intf = $dst->{hardware}->{name};
    my $proto    = $srv->{proto};
    if ($proto eq 'icmp') {
        my ($proto_code, $src_port_code, $dst_port_code) =
          cisco_srv_code($src_range, $srv, $model);
        my $result = "icmp $action $src_code";
        $result .= " $dst_port_code" if defined $dst_port_code;
        $result .= " $dst_intf";
        return $result;
    }
    elsif ($proto eq 'tcp' and $action eq 'permit') {
        my @code;
        my ($v1, $v2) = @{ $srv->{range} };
        if ($v1 <= 23 && 23 <= $v2) {
            push @code, "telnet $src_code $dst_intf";
        }
        if ($v1 <= 22 && 22 <= $v2) {
            push @code, "ssh $src_code $dst_intf";
        }
        if ($v1 <= 80 && 80 <= $v2) {
            push @code, "http $src_code $dst_intf";
        }
        return join "\n", @code;
    }
    else {
        return undef;
    }
}

# Returns iptables code for filtering a service.
sub iptables_srv_code( $$ ) {
    my ($src_range, $srv) = @_;
    my $proto = $srv->{proto};

    if ($proto eq 'ip') {
        return '';
    }
    elsif ($proto eq 'tcp' or $proto eq 'udp') {
        my $port_code = sub ( $$ ) {
            my ($v1, $v2) = @_;
            if ($v1 == $v2) {
                return $v1;
            }
            elsif ($v1 == 1 and $v2 == 65535) {
                return '';
            }
            elsif ($v2 == 65535) {
                return "$v1:";
            }
            elsif ($v1 == 1) {
                return ":$v2";
            }
            else {
                return "$v1:$v2";
            }
        };
        my $sport  = $port_code->(@{ $src_range->{range} });
        my $dport  = $port_code->(@{ $srv->{range} });
        my $result = "-p $proto";
        $result .= " --sport $sport" if $sport;
        $result .= " --dport $dport" if $dport;
        $srv->{established}
          and internal_err "Unexpected service $srv->{name} with",
          " 'established' flag while generating code for iptables";
        return $result;
    }
    elsif ($proto eq 'icmp') {
        if (defined(my $type = $srv->{type})) {
            if (defined(my $code = $srv->{code})) {
                return "-p $proto --icmp-type $type/$code";
            }
            else {
                return "-p $proto --icmp-type $type";
            }
        }
        else {
            return "-p $proto";
        }
    }
    else {
        return "-p $proto";
    }
}

sub cisco_acl_line {
    my ($rules_aref, $no_nat_set, $prefix, $model) = @_;
    my $filter_type = $model->{filter};
    for my $rule (@$rules_aref) {
        my ($action, $src, $dst, $src_range, $srv) =
          @{$rule}{ 'action', 'src', 'dst', 'src_range', 'srv' };
        print "$model->{comment_char} " . print_rule($rule) . "\n"
	    if $config{comment_acls};
        my $spair = address($src, $no_nat_set);
        my $dpair = address($dst, $no_nat_set);
        if ($filter_type eq 'PIX') {
            if ($prefix) {

                # Traffic passing through the PIX.
                my ($proto_code, $src_port_code, $dst_port_code) =
                  cisco_srv_code($src_range, $srv, $model);
                my $result = "$prefix $action $proto_code";
                $result .= ' ' . ios_code($spair);
                $result .= " $src_port_code" if defined $src_port_code;
                $result .= ' ' . ios_code($dpair);
                $result .= " $dst_port_code" if defined $dst_port_code;
                print "$result\n";
            }
            else {

                # Traffic for the PIX itself.
                if (my $code = pix_self_code $action, $spair, $dst,
                    $src_range, $srv, $model)
                {

                    # Attention: $code might have multiple lines.
                    print "$code\n";
                }
                else {

                    # Other rules are ignored silently.
                }
            }
        }
        elsif ($filter_type eq 'IOS') {
            my $inv_mask = $filter_type eq 'IOS';
            my ($proto_code, $src_port_code, $dst_port_code) =
              cisco_srv_code($src_range, $srv, $model);
            my $result = "$prefix $action $proto_code";
            $result .= ' ' . ios_code($spair, $inv_mask);
            $result .= " $src_port_code" if defined $src_port_code;
            $result .= ' ' . ios_code($dpair, $inv_mask);
            $result .= " $dst_port_code" if defined $dst_port_code;
            print "$result\n";
        }
        else {
            internal_err "Unknown filter_type $filter_type";
        }
    }
}

my $min_object_group_size = 2;

sub find_object_groups ( $$ ) {
    my ($router, $hardware) = @_;

    # Find identical groups in identical NAT domain and of same size.
    my $nat2size2group = ($router->{nat2size2group} ||= {});
    $router->{obj_group_counter} ||= 0;

    for my $rule_type ('rules', 'out_rules') {
	next if not $hardware->{$rule_type};

	# Find object-groups in src / dst of rules.
	for my $this ('src', 'dst') {
	    my $that = $this eq 'src' ? 'dst' : 'src';
	    my %group_rule_tree;

	    # Find groups of rules with identical
	    # action, srv, src/dst and different dst/src.
	    for my $rule (@{ $hardware->{$rule_type} }) {
		my $action    = $rule->{action};
		my $that      = $rule->{$that};
		my $this      = $rule->{$this};
		my $srv       = $rule->{srv};
		my $src_range = $rule->{src_range};
		$group_rule_tree{$action}->{$src_range}->{$srv}
		->{$that}->{$this} = $rule;
	    }

	    # Find groups >= $min_object_group_size,
	    # mark rules belonging to one group,
	    # put groups into an array / hash.
	    for my $href (values %group_rule_tree) {

		# $href is {src_range => href, ...}
		for my $href (values %$href) {

		    # $href is {srv => href, ...}
		    for my $href (values %$href) {

			# $href is {src/dst => href, ...}
			for my $href (values %$href) {

			    # $href is {dst/src => rule, ...}
			    my $size = keys %$href;
			    if ($size >= $min_object_group_size) {
				my $glue = {

				# Indicator, that no further rules need
				# to be processed.
				    active => 0,

				# NAT map for address calculation.
				    no_nat_set => $hardware->{no_nat_set},

				# object-ref => rule, ...
				    hash => $href
				    };

				# All this rules have identical
				# action, srv, src/dst  and dst/src
				# and shall be replaced by a new object group.
				for my $rule (values %$href) {
				    $rule->{group_glue} = $glue;
				}
			    }
			}
		    }
		}
	    }

	    # Find a group with identical elements or define a new one.
	    my $get_group = sub ( $ ) {
		my ($glue)     = @_;
		my $hash       = $glue->{hash};
		my $no_nat_set = $glue->{no_nat_set};
		my @keys       = keys %$hash;
		my $size       = @keys;

		# This occurs if optimization didn't work correctly.
		if (grep { $_ eq $network_00 } @keys) {
		    internal_err
			"Unexpected $network_00->{name} in object-group",
			" of $router->{name}";
		}

		# Find group with identical elements.
		for my $group (@{ $nat2size2group->{$no_nat_set}->{$size} }) {
		    my $href = $group->{hash};
		    my $eq   = 1;
		    for my $key (@keys) {
			unless ($href->{$key}) {
			    $eq = 0;
			    last;
			}
		    }
		    if ($eq) {
			return $group;
		    }
		}

		# Not found, build new group.
		my $group = new(
				'Objectgroup',
				name       => "g$router->{obj_group_counter}",
				elements   => [ map { $ref2obj{$_} } @keys ],
				hash       => $hash,
				no_nat_set => $no_nat_set
				);
		push @{ $nat2size2group->{$no_nat_set}->{$size} }, $group;

		# Print object-group.
		print "object-group network $group->{name}\n";
		for my $pair (
			      sort({ $a->[0] <=> $b->[0] || 
				     $a->[1] <=> $b->[1] }
			      map({ address($_, $no_nat_set) } 
				  @{ $group->{elements} }))
			      )
		{
		    my $adr = ios_code($pair);
		    print " network-object $adr\n";
		}
		$router->{obj_group_counter}++;
		return $group;
	    };

	    # Build new list of rules using object groups.
	    my @new_rules;
	    for my $rule (@{ $hardware->{$rule_type} }) {

		# Remove tag, otherwise call to find_object_groups
		# for another router would become confused.
		if (my $glue = delete $rule->{group_glue}) {

#              debug print_rule $rule;
		    if ($glue->{active}) {

#                 debug " deleted: $glue->{group}->{name}";
			next;
		    }
		    my $group = $get_group->($glue);

#              debug " generated: $group->{name}";
#              # Only needed when debugging.
#              $glue->{group} = $group;

		    $glue->{active} = 1;
		    $rule = {
			action    => $rule->{action},
			$that     => $rule->{$that},
			$this     => $group,
			src_range => $rule->{src_range},
			srv       => $rule->{srv}
		    };
		}
		push @new_rules, $rule;
	    }
	    $hardware->{$rule_type} = \@new_rules;
	}
    }
}

# Handle iptables.
#
sub debug_bintree ( $;$ );

sub debug_bintree ( $;$ ) {
    my ($tree, $depth) = @_;
    $depth ||= '';
    my $ip      = print_ip $tree->{ip};
    my $mask    = print_ip $tree->{mask};
    my $subtree = $tree->{subtree} ? 'subtree' : '';
#    debug $depth, " $ip/$mask $subtree";
#    debug_bintree $tree->{lo}, "${depth}l" if $tree->{lo};
#    debug_bintree $tree->{hi}, "${depth}h" if $tree->{hi};
}

# Nodes are reverse sorted before being added to bintree.
# Redundant nodes are discarded while inserting.
# A node with value of sub-tree S is discarded,
# if some parent node already has sub-tree S.
sub add_bintree ( $$ );

sub add_bintree ( $$ ) {
    my ($tree,    $node)      = @_;
    my ($tree_ip, $tree_mask) = @{$tree}{qw(ip mask)};
    my ($node_ip, $node_mask) = @{$node}{qw(ip mask)};
    my $result;

    # The case where new node is larger than root node will never
    # occur, because nodes are sorted before being added.

    if ($tree_mask < $node_mask && ($node_ip & $tree_mask) == $tree_ip) {

        # Optimization for this special case:
        # Root of tree has attribute {subtree} which is identical to
        # attribute {subtree} of current node.
        # Node is known to be less than root node.
        # Hence node together with its subtree can be discarded
        # because it is redundant compared to root node.
        # ToDo:
        # If this optimization had been done before merge_subtrees,
        # it could have merged more subtrees.
        if (   not $tree->{subtree}
            or not $node->{subtree}
            or $tree->{subtree} ne $node->{subtree})
        {
            my $mask = ($tree_mask >> 1) | 0x80000000;
            my $branch = ($node_ip & $mask) == $tree_ip ? 'lo' : 'hi';
            if (my $subtree = $tree->{$branch}) {
                $tree->{$branch} = add_bintree $subtree, $node;
            }
            else {
                $tree->{$branch} = $node;
            }
        }
        $result = $tree;
    }

    # Different nodes with identical IP address.
    # This occurs for two cases:
    # 1. Different interfaces of redundancy protocols like VRRP or HSRP.
    #    In this case, the subtrees should be identical.
    # 2. Dynamic NAT of different networks or hosts to a single address
    #    or range.
    #    Currently this case isn't handled properly.
    #    The first subtree is taken, the other ones are ignored.
    #
    # ToDo: Merge subtrees for case 2.
    elsif ($tree_mask == $node_mask && $tree_ip == $node_ip) {
        my $sub1 = $tree->{subtree} || '';
        my $sub2 = $node->{subtree} || '';
        if ($sub1 ne $sub2) {
            my $ip   = print_ip $tree_ip;
            my $mask = print_ip $tree_mask;
            warn_msg "Inconsistent rules for iptables for $ip/$mask";
        }
        $result = $tree;
    }

    # Create common root for tree and node.
    else {
        while (1) {
            $tree_mask = ($tree_mask & 0x7fffffff) << 1;
            last if ($node_ip & $tree_mask) == ($tree_ip & $tree_mask);
        }
        $result = new(
            'Network',
            ip   => ($node_ip & $tree_mask),
            mask => $tree_mask
        );
        @{$result}{qw(lo hi)} =
          $node_ip < $tree_ip ? ($node, $tree) : ($tree, $node);
    }

    # Merge adjacent sub-networks.
  MERGE:
    {
        $result->{subtree} and last;
        my $lo = $result->{lo} or last;
        my $hi = $result->{hi} or last;
        my $mask = ($result->{mask} >> 1) | 0x80000000;
        $lo->{mask} == $mask or last;
        $hi->{mask} == $mask or last;
        $lo->{subtree} and $hi->{subtree} or last;
        $lo->{subtree} eq $hi->{subtree} or last;

        for my $key (qw(lo hi)) {
            $lo->{$key} and last MERGE;
            $hi->{$key} and last MERGE;
        }

#       debug 'Merged: ', print_ip $lo->{ip},' ',
#       print_ip $hi->{ip},'/',print_ip $hi->{mask};
        $result->{subtree} = $lo->{subtree};
        delete $result->{lo};
        delete $result->{hi};
    }
    return $result;
}

# Build a binary tree for src/dst objects.
sub gen_addr_bintree ( $$$ ) {
    my ($elements, $tree, $no_nat_set) = @_;

    # Sort in reverse order my mask and then by IP.
    my @nodes =
      sort { $b->{mask} <=> $a->{mask} || $b->{ip} <=> $a->{ip} }
      map {
        my ($ip, $mask) = @{ address($_, $no_nat_set) };

        # The tree's node is a simplified network object with
        # missing attribute 'name' and extra 'subtree'.
        new(
            'Network',
            ip      => $ip,
            mask    => $mask,
            subtree => $tree->{$_}
          )
      } @$elements;
    my $bintree = pop @nodes;
    while (my $next = pop @nodes) {
        $bintree = add_bintree $bintree, $next;
    }

    # Add attribute {noop} to node which doesn't add any
    # test to generated rule.
    $bintree->{noop} = 1 if $bintree->{mask} == 0;

#    debug_bintree $bintree;
    return $bintree;
}

# Build a tree for src-range/srv objects. Sub-trees for tcp and udp
# will be binary trees. Nodes have attributes {proto}, {range},
# {type}, {code} like services (but without {name}).
# Additional attributes for building the tree:
# For tcp and udp:
# {lo}, {hi} for sub-ranges of current node.
# For other services:
# {seq} an array of ordered nodes for sub services of current node.
# Elements of {lo} and {hi} or elements of {seq} are guaranteed to be
# disjoint.
# Additional attribute {subtree} is set with corresponding subtree of
# service object if current node comes from a rule and wasn't inserted
# for optimization.
sub gen_srv_bintree ( $$ ) {
    my ($elements, $tree) = @_;

    my $ip_srv;
    my %top_srv;
    my %sub_srv;

    # Add all services directly below service 'ip' into hash %top_srv
    # grouped by protocol.  Add services below top services or below
    # other services of current set of services to hash %sub_srv.
  SRV:
    for my $srv (@$elements) {
        my $proto = $srv->{proto};
        if ($proto eq 'ip') {
            $ip_srv = $srv;
        }
        else {
            my $up = $srv->{up};

            # Check if $srv is sub service of any other service of
            # current set. But handle direct sub services of 'ip' as
            # top services.
            while ($up->{up}) {
                if ($tree->{$up}) {

                    # Found sub service of current set.
                    push @{ $sub_srv{$up} }, $srv;
                    next SRV;
                }
                $up = $up->{up};
            }

            # Not a sub service (except possibly of IP).
            my $key = $proto =~ /^\d+$/ ? 'proto' : $proto;
            push @{ $top_srv{$key} }, $srv;
        }
    }

    # Collect subtrees for tcp, udp, proto and icmp.
    my @seq;

# Build subtree of tcp and udp services.
    #
    # We need not to handle 'tcp established' because it is only used
    # for stateless routers, but iptables is stateful.
    my $gen_lohitrees;
    my $gen_rangetree;
    $gen_lohitrees = sub {
        my ($srv_aref) = @_;
        if (not $srv_aref) {
            return (undef, undef);
        }
        elsif (@$srv_aref == 1) {
            my $srv = $srv_aref->[0];
            my ($lo, $hi) = $gen_lohitrees->($sub_srv{$srv});
            my $node = {
                proto   => $srv->{proto},
                range   => $srv->{range},
                subtree => $tree->{$srv},
                lo      => $lo,
                hi      => $hi
            };
            return ($node, undef);
        }
        else {
            my @ranges =
              sort { $a->{range}->[0] <=> $b->{range}->[0] } @$srv_aref;

            # Split array in two halves.
            my $mid   = int($#ranges / 2);
            my $left  = [ @ranges[ 0 .. $mid ] ];
            my $right = [ @ranges[ $mid + 1 .. $#ranges ] ];
            return ($gen_rangetree->($left), $gen_rangetree->($right));
        }
    };
    $gen_rangetree = sub {
        my ($srv_aref) = @_;
        my ($lo, $hi) = $gen_lohitrees->($srv_aref);
        return $lo if not $hi;
        my $proto = $lo->{proto};

        # Take low port from lower tree and high port from high tree.
        my $range = [ $lo->{range}->[0], $hi->{range}->[1] ];

        # Merge adjacent port ranges.
        if (    $lo->{range}->[1] + 1 == $hi->{range}->[0]
            and $lo->{subtree}
            and $hi->{subtree}
            and $lo->{subtree} eq $hi->{subtree})
        {

#           debug "Merged: $lo->{range}->[0]-$lo->{range}->[1]",
#           " $hi->{range}->[0]-$hi->{range}->[1]";
            {
                proto   => $proto,
                range   => $range,
                subtree => $lo->{subtree}
            };
        }
        else {
            {
                proto => $proto,
                range => $range,
                lo    => $lo,
                hi    => $hi
            };
        }
    };
    for my $what (qw(tcp udp)) {
        next if not $top_srv{$what};
        push @seq, $gen_rangetree->($top_srv{$what});
    }

# Add single nodes for numeric protocols.
    if (my $aref = $top_srv{proto}) {
        for my $srv (sort { $a->{proto} <=> $b->{proto} } @$aref) {
            my $node = { proto => $srv->{proto}, subtree => $tree->{$srv} };
            push @seq, $node;
        }
    }

# Build subtree of icmp services.
    if (my $icmp_aref = $top_srv{icmp}) {
        my %type2srv;
        my $icmp_any;

        # If one service is 'icmp any' it is the only top service,
        # all other icmp services are sub services.
        if (not defined $icmp_aref->[0]->{type}) {
            $icmp_any  = $icmp_aref->[0];
            $icmp_aref = $sub_srv{$icmp_any};
        }

        # Process icmp services having defined type and possibly defined code.
        # Group services by type.
        for my $srv (@$icmp_aref) {
            my $type = $srv->{type};
            push @{ $type2srv{$type} }, $srv;
        }

        # Parameter is array of icmp services all having
        # the same type and different but defined code.
        # Return reference to array of nodes sorted by code.
        my $gen_icmp_type_code_sorted = sub {
            my ($aref) = @_;
            [
                map {
                    {
                        proto   => 'icmp',
                        type    => $_->{proto},
                        code    => $_->{code},
                        subtree => $tree->{$_}
                    }
                  }
                  sort { $a->{code} <=> $b->{code} } @$aref
            ];
        };

        # For collecting subtrees of icmp subtree.
        my @seq2;

        # Process grouped icmp services having the same type.
        for my $type (sort { $a <=> $b } keys %type2srv) {
            my $aref2 = $type2srv{$type};
            my $node2;

            # If there is more than one service,
            # all have same type and defined code.
            if (@$aref2 > 1) {
                my $seq3 = $gen_icmp_type_code_sorted->($aref2);

                # Add a node 'icmp type any' as root.
                $node2 = {
                    proto => 'icmp',
                    type  => $type,
                    seq   => $seq3,
                };
            }

            # One service 'icmp type any'.
            else {
                my $srv = $aref2->[0];
                $node2 = {
                    proto   => 'icmp',
                    type    => $type,
                    subtree => $tree->{$srv}
                };
                if (my $aref3 = $sub_srv{$srv}) {
                    $node2->{seq} = $gen_icmp_type_code_sorted->($aref3);
                }
            }
            push @seq2, $node2;
        }

        # Add root node for icmp subtree.
        my $node;
        if ($icmp_any) {
            $node = {
                proto   => 'icmp',
                seq     => \@seq2,
                subtree => $tree->{$icmp_any}
            };
        }
        elsif (@seq2 > 1) {
            $node = { proto => 'icmp', seq => \@seq2 };
        }
        else {
            $node = $seq2[0];
        }
        push @seq, $node;
    }

# Add root node for whole tree.
    my $bintree;
    if ($ip_srv) {
        $bintree = {
            proto   => 'ip',
            seq     => \@seq,
            subtree => $tree->{$ip_srv}
        };
    }
    elsif (@seq > 1) {
        $bintree = { proto => 'ip', seq => \@seq };
    }
    else {
        $bintree = $seq[0];
    }

    # Add attribute {noop} to node which doesn't need any test in
    # generated chain.
    $bintree->{noop} = 1 if $bintree->{proto} eq 'ip';
    return $bintree;
}

my %ref_type = (
    srv       => \%ref2srv,
    src_range => \%ref2srv,
    src       => \%ref2obj,
    dst       => \%ref2obj
);
$ref2srv{$srv_icmp} = $srv_icmp;

sub find_chains ( $$ ) {
    my ($router, $hardware) = @_;

    # For generating names of chains.
    # Initialize if called first time.
    $router->{chain_counter} ||= 1;

    my $no_nat_set = $hardware->{no_nat_set};
    my @rule_arefs = values %{ $hardware->{io_rules} };
    my $intf_rules = $hardware->{intf_rules};
    push @rule_arefs, $intf_rules if $intf_rules;

    for my $rules (@rule_arefs) {
        my %cache;

        my $print_tree;
        $print_tree = sub {
            my ($tree, $order, $depth) = @_;
            my $key      = $order->[$depth];
            my $ref2x    = $ref_type{$key};
            my @elements = map { $ref2x->{$_} } keys %$tree;
            for my $elem (@elements) {
#                debug ' ' x $depth, "$elem->{name}";
                if ($depth < $#$order) {
                    $print_tree->($tree->{$elem}, $order, $depth + 1);
                }
            }
        };

        my $insert_bintree = sub {
            my ($tree, $order, $depth) = @_;
            my $key      = $order->[$depth];
            my $ref2x    = $ref_type{$key};
            my @elements = map { $ref2x->{$_} } keys %$tree;

            # Put srv/src/dst objects at the root of some subtree into a
            # (binary) tree. This is used later to convert subsequent tests
            # for ip/mask or port ranges into more efficient nested chains.
            my $bintree;
            if ($ref2x eq \%ref2obj) {
                $bintree = gen_addr_bintree(\@elements, $tree, $no_nat_set);
            }
            else {    # $ref2x eq \%ref2srv
                $bintree = gen_srv_bintree(\@elements, $tree);
            }
            return $bintree;
        };

        # Used by $merge_subtrees1 to find identical subtrees.
        # Use hash for efficient lookup.
        my %depth2size2subtrees;
        my %subtree2bintree;

        # Find and merge identical subtrees.
        my $merge_subtrees1 = sub {
            my ($tree, $order, $depth) = @_;

          SUBTREE:
            for my $subtree (values %$tree) {
                my @keys = keys %$subtree;
                my $size = @keys;

                # Find subtree with identical keys and values;
              FIND:
                for my $subtree2 (@{ $depth2size2subtrees{$depth}->{$size} }) {
                    for my $key (@keys) {
                        if (not $subtree2->{$key}
                            or $subtree2->{$key} ne $subtree->{$key})
                        {
                            next FIND;
                        }
                    }

                    # Substitute current subtree with found subtree.
                    $subtree = $subtree2bintree{$subtree2};
                    next SUBTREE;

                }

                # Found a new subtree.
                push @{ $depth2size2subtrees{$depth}->{$size} }, $subtree;
                $subtree = $subtree2bintree{$subtree} =
                  $insert_bintree->($subtree, $order, $depth + 1);
            }
        };

        my $merge_subtrees = sub {
            my ($tree, $order) = @_;

            # Process leaf nodes first.
            for my $href (values %$tree) {
                for my $href (values %$href) {
                    $merge_subtrees1->($href, $order, 2);
                }
            }

            # Process nodes next to leaf nodes.
            for my $href (values %$tree) {
                $merge_subtrees1->($href, $order, 1);
            }

            # Process nodes next to root.
            $merge_subtrees1->($tree, $order, 0);
            return $insert_bintree->($tree, $order, 0);
        };

        # Add new chain to current router.
        my $new_chain = sub {
            my ($rules) = @_;
            my $chain = new(
                'Chain',
                name  => "c$router->{chain_counter}",
                rules => $rules,
            );
            push @{ $router->{chains} }, $chain;
            $router->{chain_counter}++;
            $chain;
        };

        my $gen_chain;
        $gen_chain = sub {
            my ($tree, $order, $depth) = @_;
            my $key = $order->[$depth];
            my @rules;

            # We need the original value later.
            my $bintree = $tree;
            while (1) {
                my ($hi, $lo, $seq, $subtree) =
                  @{$bintree}{qw(hi lo seq subtree)};
                $seq = undef if $seq and not @$seq;
                if (not $seq) {
                    push @$seq, $hi if $hi;
                    push @$seq, $lo if $lo;
                }
                if ($subtree) {

#                   if($order->[$depth+1]&&
#                      $order->[$depth+1] =~ /^(src|dst)$/) {
#                       debug $order->[$depth+1];
#                       debug_bintree $subtree;
#                   }
                    my $rules = $cache{$subtree};
                    if (not $rules) {
                        $rules =
                          $depth + 1 >= @$order
                          ? [ { action => $subtree } ]
                          : $gen_chain->($subtree, $order, $depth + 1);
                        if (@$rules > 1 and not $bintree->{noop}) {
                            my $chain = $new_chain->($rules);
                            $rules = [ { action => $chain, goto => 1 } ];
                        }
                        $cache{$subtree} = $rules;
                    }

                    my @add_keys;

                    # Don't use "goto", if some tests for sub-nodes of
                    # $subtree are following.
                    push @add_keys, (goto => 0)        if $seq;
                    push @add_keys, ($key => $bintree) if not $bintree->{noop};
                    if (@add_keys) {

                        # Create a copy of each rule because we must not change
                        # the original cached rules.
                        push @rules, map {
                            { %$_, @add_keys }
                        } @$rules;
                    }
                    else {
                        push @rules, @$rules;
                    }
                }
                last if not $seq;

                # Take this value in next iteration.
                $bintree = pop @$seq;

                # Process remaining elements.
                for my $node (@$seq) {
                    my $rules = $gen_chain->($node, $order, $depth);
                    push @rules, @$rules;
                }
            }
            if (@rules > 1 and not $tree->{noop}) {

                # Generate new chain. All elements of @seq are
                # known to be disjoint. If one element has matched
                # and branched to a chain, then the other elements
                # need not be tested again. This is implemented by
                # calling the chain using '-g' instead of the usual '-j'.
                my $chain = $new_chain->(\@rules);
                return [ { action => $chain, goto => 1, $key => $tree } ];
            }
            else {
                return \@rules;
            }
        };

        # Build rule trees. Generate and process separate tree for
        # adjacent rules with same action.
        my @rule_trees;
        my %tree2order;
        if ($rules and @$rules) {
            my $prev_action = $rules->[0]->{action};
            push @$rules, { action => 0 };
            my $start = my $i = 0;
            my $last = $#$rules;
            my %count;
            while (1) {
                my $rule   = $rules->[$i];
                my $action = $rule->{action};
                if ($action eq $prev_action) {

                    # Count, which key has the largest number of
                    # different values.
                    for my $what (qw(src dst src_range srv)) {
                        $count{$what}{ $rule->{$what} } = 1;
                    }
                    $i++;
                }
                else {

                    # Use key with smaller number of different values
                    # first in rule tree. This gives smaller tree and
                    # fewer tests in chains.
                    my @test_order =
                      sort { keys %{ $count{$a} } <=> keys %{ $count{$b} } }
                      qw(src_range dst srv src);
                    my $rule_tree;
                    my $end = $i - 1;
                    for (my $j = $start ; $j <= $end ; $j++) {
                        my $rule = $rules->[$j];
                        if ($rule->{srv}->{proto} eq 'icmp') {
                            $rule->{src_range} = $srv_icmp;
                        }
                        my ($action, $t1, $t2, $t3, $t4) =
                          @{$rule}{ 'action', @test_order };
                        $rule_tree->{$t1}->{$t2}->{$t3}->{$t4} = $action;
                    }
                    push @rule_trees, $rule_tree;

#		    debug join ', ', @test_order;
                    $tree2order{$rule_tree} = \@test_order;
                    last if not $action;
                    $start       = $i;
                    $prev_action = $action;
                }
            }
            @$rules = ();
        }

        for (my $i = 0 ; $i < @rule_trees ; $i++) {
            my $tree  = $rule_trees[$i];
            my $order = $tree2order{$tree};

#           $print_tree->($tree, $order, 0);
            $tree = $merge_subtrees->($tree, $order);
            my $result = $gen_chain->($tree, $order, 0);

            # Goto must not be used in last rule of rule tree which is
            # not the last tree.
            if ($i != $#rule_trees) {
                my $rule = $result->[$#$result];
                delete $rule->{goto};
            }

            # Postprocess rules: Add missing attributes src_range,
            # srv, src, dst with no-op values.
            for my $rule (@$result) {
                $rule->{src} ||= $network_00;
                $rule->{dst} ||= $network_00;
                my $srv       = $rule->{srv};
                my $src_range = $rule->{src_range};
                if (not $srv and not $src_range) {
                    $rule->{srv} = $rule->{src_range} = $srv_ip;
                }
                else {
                    $rule->{srv} ||=
                        $src_range->{proto} eq 'tcp'  ? $srv_tcp->{dst_range}
                      : $src_range->{proto} eq 'udp'  ? $srv_udp->{dst_range}
                      : $src_range->{proto} eq 'icmp' ? $srv_icmp
                      :                                 $srv_ip;
                    $rule->{src_range} ||=
                        $srv->{proto} eq 'tcp' ? $srv_tcp->{src_range}
                      : $srv->{proto} eq 'udp' ? $srv_udp->{src_range}
                      :                          $srv_ip;
                }
            }
            push @$rules, @$result;
        }
    }
}

sub max {
    my $max = shift(@_);
    for my $el (@_) {
	$max = $el if $max < $el;
    }
    return $max;
}

# Print chains of iptables.
# Objects have already been normalized to ip/mask pairs.
# NAT has already been applied.
sub print_chains ( $ ) {
    my ($router) = @_;

    # Declare chain names.
    for my $chain (@{ $router->{chains} }) {
        my $name = $chain->{name};
        print ":$name -\n";
    }

    # Add user defined chain 'droplog'.
    print ":droplog -\n";
    print "-A droplog -j LOG --log-level debug\n";
    print "-A droplog -j DROP\n";

    # Define chains.
    for my $chain (@{ $router->{chains} }) {
        my $name   = $chain->{name};
        my $prefix = "-A $name";
#	my $steps = my $accept = my $deny = 0;
        for my $rule (@{ $chain->{rules} }) {
            my $action = $rule->{action};
            my $action_code =
                is_chain $action ? $action->{name}
              : $action eq 'permit' ? 'ACCEPT'
              :                       'droplog';

	    # Calculate maximal number of matches if
	    # - some rules matches (accept) or
	    # - all rules don't match (deny).
#	    $steps += 1;
#	    if ($action eq 'permit') {
#		$accept = max($accept, $steps);
#	    }
#	    elsif ($action eq 'deny') {
#		$deny = max($deny, $steps);
#	    }
#	    elsif ($rule->{goto}) {
#		$accept = max($accept, $steps + $action->{a});
#	    }
#	    else {
#		$accept = max($accept, $steps + $action->{a});
#		$steps += $action->{d};
#	    }

            my $jump = $rule->{goto} ? '-g' : '-j';
            my $result = "$jump $action_code";
            if (my $src = $rule->{src}) {
                my $ip_mask = [ @{$src}{qw(ip mask)} ];
                if ($ip_mask->[1] != 0) {
                    $result .= ' -s ' . prefix_code($ip_mask);
                }
            }
            if (my $dst = $rule->{dst}) {
                my $ip_mask = [ @{$dst}{qw(ip mask)} ];
                if ($ip_mask->[1] != 0) {
                    $result .= ' -d ' . prefix_code($ip_mask);
                }
            }
          BLOCK:
            {
                my $src_range = $rule->{src_range};
                my $srv       = $rule->{srv};
                last BLOCK if not $src_range and not $srv;
                last BLOCK if $srv and $srv->{proto} eq 'ip';
                $src_range ||=
                    $srv->{proto} eq 'tcp' ? $srv_tcp->{src_range}
                  : $srv->{proto} eq 'udp' ? $srv_udp->{src_range}
                  :                          $srv_ip;
                if (not $srv) {
                    last BLOCK if $src_range->{proto} eq 'ip';
                    $srv =
                        $src_range->{proto} eq 'tcp'  ? $srv_tcp->{dst_range}
                      : $src_range->{proto} eq 'udp'  ? $srv_udp->{dst_range}
                      : $src_range->{proto} eq 'icmp' ? $srv_icmp
                      :                                 $srv_ip;
                }

#               debug "c ",print_rule $rule if not $src_range or not $srv;
                $result .= ' ' . iptables_srv_code($src_range, $srv);
            }
            print "$prefix $result\n";
        }
#	$deny = max($deny, $steps);
#	$chain->{a} = $accept;
#	$chain->{d} = $deny;
#	print "# Max tests: Accept: $accept, Deny: $deny\n";
    }

    # Empty line as delimiter.
    print "\n";
}

# Find adjacent port ranges.
sub join_ranges ( $ ) {
    my ($hardware) = @_;
    my $changed;
    for my $rules ('intf_rules', 'rules', 'out_rules') {
        my %hash = ();
        for my $rule (@{ $hardware->{$rules} }) {
            my ($action, $src, $dst, $src_range, $srv) =
              @{$rule}{ 'action', 'src', 'dst', 'src_range', 'srv' };

            # Only ranges which have a neighbor may be successfully optimized.
            $srv->{has_neighbor} or next;
            $hash{$action}->{$src}->{$dst}->{$src_range}->{$srv} = $rule;
        }

        # %hash is {action => href, ...}
        for my $href (values %hash) {

            # $href is {src => href, ...}
            for my $href (values %$href) {

                # $href is {dst => href, ...}
                for my $href (values %$href) {

                    # $href is {src_port => href, ...}
                    for my $src_range_ref (keys %$href) {
                        my $src_range = $ref2srv{$src_range_ref};
                        my $href      = $href->{$src_range_ref};

                        # Values of %$href are rules with identical
                        # action/src/dst/src_port and a TCP or UDP
                        # service.  When sorting these rules by low
                        # port number, rules with adjacent services
                        # will placed side by side.  There can't be
                        # overlaps, because they have been split in
                        # function 'order_ranges'.  There can't be
                        # sub-ranges, because they have been deleted
                        # as redundant above.
                        my @sorted = sort {
                            $a->{srv}->{range}->[0] <=> $b->{srv}->{range}->[0]
                        } (values %$href);
                        @sorted >= 2 or next;
                        my $i      = 0;
                        my $rule_a = $sorted[$i];
                        my ($a1, $a2) = @{ $rule_a->{srv}->{range} };
                        while (++$i < @sorted) {
                            my $rule_b = $sorted[$i];
                            my ($b1, $b2) = @{ $rule_b->{srv}->{range} };
                            if ($a2 + 1 == $b1) {

                                # Found adjacent port ranges.
                                if (my $range = delete $rule_a->{range}) {

                                    # Extend range of previous two or
                                    # more elements.
                                    $range->[1] = $b2;
                                    $rule_b->{range} = $range;
                                }
                                else {

                                    # Combine ranges of $rule_a and $rule_b.
                                    $rule_b->{range} = [ $a1, $b2 ];
                                }

                                # Mark previous rule as deleted.
                                # Don't use attribute 'deleted', this
                                # may still be set by global
                                # optimization pass.
                                $rule_a->{local_del} = 1;
                                $changed = 1;
                            }
                            $rule_a = $rule_b;
                            ($a1, $a2) = ($b1, $b2);
                        }
                    }
                }
            }
        }
        if ($changed) {
            my @rules;
            for my $rule (@{ $hardware->{$rules} }) {

                # Check and remove attribute 'local_del'.
                next if delete $rule->{local_del};

                # Process rules with joined port ranges.
                # Remove auxiliary attribute {range} from rules.
                if (my $range = delete $rule->{range}) {
                    my $srv   = $rule->{srv};
                    my $proto = $srv->{proto};
                    my $key   = join ':', @$range;

                    # Try to find existing srv with matching range.
                    # This is needed for find_object_groups to work.
                    my $new_srv = $srv_hash{$proto}->{$key};
                    unless ($new_srv) {
                        $new_srv = {
                            name  => "joined_$srv->{name}",
                            proto => $proto,
                            range => $range
                        };
                        $srv_hash{$proto}->{$key} = $new_srv;
                    }
                    my $new_rule = { %$rule, srv => $new_srv };
                    push @rules, $new_rule;
                }
                else {
                    push @rules, $rule;
                }
            }
            $hardware->{$rules} = \@rules;
        }
    }
}

sub local_optimization() {
    progress "Optimizing locally";

    # Prepare removal of duplicate occurences of the same IP address from
    # a group of virtual interfaces.
    # Bring the group of interfaces into an arbitrary order.
    # This used below to remove all but one interface.
    for my $interface (@virtual_interfaces) {

        # Interface has already been processed.
        next if is_interface $interface->{up};
        my $up;
        for my $v_intf (@{ $interface->{redundancy_interfaces} }) {

            # Set new value but first interface keeps standard attribute value.
            $v_intf->{up} = $up if $up;

            # Get  value for next interface.
            $up = $v_intf;
        }
    }

    # Needed in find_chains.
    $ref2obj{$network_00} = $network_00;

    my %seen;
    for my $domain (@natdomains) {
        my $no_nat_set = $domain->{no_nat_set};

        # Subnet relation may be different for each NAT domain,
        # therefore it is set up again for each NAT domain.
        for my $network (@networks) {
            $network->{up} =
                 $network->{is_in}->{$no_nat_set}
              || $network->{is_identical}->{$no_nat_set}
              || $network_00;
        }

        for my $network (@{ $domain->{networks} }) {

            # Iterate over all interfaces attached to current network.
            # If interface is virtual tunnel for multiple software clients,
            # take separate rules for each software client.
            for my $interface (
                map { $_->{id_rules} ? values %{ $_->{id_rules} } : $_ }
                @{ $network->{interfaces} })
            {
                my $router           = $interface->{router};
                my $managed          = $router->{managed} or next;
                my $secondary_filter = $managed eq 'secondary';
                my $standard_filter  = $managed eq 'standard';
                my $do_auth          = $router->{model}->{do_auth};
                my $hardware =
                    $interface->{ip} eq 'tunnel'
                  ? $interface
                  : $interface->{hardware};

                # Do local optimization only once for each hardware interface.
                next if $seen{$hardware};
                $seen{$hardware} = 1;
                if ($router->{model}->{filter} eq 'iptables') {
                    find_chains $router, $hardware;
                    next;
                }

#               debug "$router->{name}";
                for my $rules ('intf_rules', 'rules', 'out_rules') {
                    my %hash;
                    my $changed = 0;
                    for my $rule (@{ $hardware->{$rules} }) {
                        my ($action, $src, $dst, $src_range, $srv) =
                          @{$rule}{ 'action', 'src', 'dst', 'src_range',
                            'srv' };

			# Prevent duplicate code from duplicate rules,
			# resulting from loops or global:permit.
			if ($hash{$action}
			    ->{$src}->{$dst}->{$src_range}->{$srv}) 
			{
			    $rule = undef;
			    $changed = 1;
			}
			else {
			    $hash{$action}
			    ->{$src}->{$dst}->{$src_range}->{$srv} = $rule;
			}
                    }
                  RULE:
                    for my $rule (@{ $hardware->{$rules} }) {
			next if not $rule;

#                       debug print_rule $rule;
                        my ($action, $src, $dst, $src_range, $srv) =
                          @{$rule}{ 'action', 'src', 'dst', 'src_range',
                            'srv' };

                        while (1) {
                            my $src = $src;
                            if (my $hash = $hash{$action}) {
                                while (1) {
                                    my $dst = $dst;
                                    if (my $hash = $hash->{$src}) {
                                        while (1) {
                                            my $src_range = $src_range;
                                            if (my $hash = $hash->{$dst}) {
                                                while (1) {
                                                    my $srv = $srv;
                                                    if (my $hash =
                                                        $hash->{$src_range})
                                                    {
                                                        while (1) {
                                                            if (my $other_rule =
                                                                $hash->{$srv})
                                                            {
                                                                unless ($rule eq
                                                                    $other_rule)
                                                                {

# debug "del:", print_rule $rule;
# debug "oth:", print_rule $other_rule;
                                                                    $rule =
                                                                      undef;
                                                                    $changed =
                                                                      1;
                                                                    next RULE;
                                                                }
                                                            }
                                                            $srv = $srv->{up}
                                                              or last;
                                                        }
                                                    }
                                                    $src_range =
                                                      $src_range->{up}
                                                      or last;
                                                }
                                            }
                                            $dst = $dst->{up} or last;
                                        }
                                    }
                                    $src = $src->{up} or last;
                                }
                            }
                            last if $action eq 'deny';
                            $action = 'deny';
                        }

                        # Implement remaining rules as secondary rule,
                        # if possible.
                        if (   $secondary_filter && $rule->{some_non_secondary}
                            || $standard_filter && $rule->{some_primary})
                        {
                            $action = $rule->{action};
                            $src    = $rule->{src};

                            # Single ID-hosts must not be converted to
                            # network at authenticating router.
                            if (
                                not(is_interface $src
                                    and $src->{network}->{route_hint})
                                and not(is_subnet $src
                                    and ($src->{id}
				    and $do_auth
				    or  $src->{network}->{route_hint}))
                              )
                            {

                                # get_networks has a single result if
                                # not called with an 'any' object as argument.
                                $src = get_networks $src;

                                # Prevent duplicate ACLs for networks which
                                # are translated to the same ip address.
                                if (my $identical = $src->{is_identical}) {
                                    if (my $one_net = 
					$identical->{$no_nat_set}) 
				    {
                                        $src = $one_net;
                                    }
                                }
                            }
                            $dst = $rule->{dst};
                            if (
                                not(is_interface $dst
                                    and ($dst->{router} eq $router
					 or $dst->{network}->{route_hint}))
                                and not(is_subnet $dst
                                    and ($dst->{id}
                                    and $do_auth
				    or  $dst->{network}->{route_hint}))
                              )
                            {
                                $dst = get_networks $dst;
                                if (my $identical = $dst->{is_identical}) {
                                    if (my $one_net = 
					$identical->{$no_nat_set}) 
				    {
                                        $dst = $one_net;
                                    }
                                }
                            }

                            # Don't modify original rule, because the
                            # identical rule is referenced at different
                            # routers.
                            my $new_rule = {
                                action    => $action,
                                src       => $src,
                                dst       => $dst,
                                src_range => $srv_ip,
                                srv       => $srv_ip,
                            };

#                           debug "sec:", print_rule $new_rule;

                            # Add new rule to hash. If there are multiple
                            # rules which could be converted to the same
                            # weak filter, only the first one will be
                            # generated.
                            $hash{$action}->{$src}->{$dst}->{$srv_ip}
                              ->{$srv_ip} = $new_rule;

                            # This changes @{$hardware->{$rules}} !
                            $rule = $new_rule;
                        }
                    }
                    if ($changed) {
                        $hardware->{$rules} =
                          [ grep { defined $_ } @{ $hardware->{$rules} } ];
                    }
                }

                # Join adjacent port ranges.  This must be called after local
                # optimization has been finished because services will be
                # overlapping again after joining.
                join_ranges $hardware;
            }
        }
    }
}

sub print_xml( $ );

sub print_xml( $ ) {
    my ($arg) = @_;
    my $ref = ref $arg;
    if (not $ref) {
        print "$arg";
    }
    elsif ($ref eq 'HASH') {
        for my $tag (sort keys %$arg) {
            my $arg = $arg->{$tag};
            if (ref $arg) {
                print "<$tag>\n";
                print_xml $arg;
                print "</$tag>\n";
            }
            else {

                # Handle simple case separately for formatting reasons.
                print "<$tag>$arg</$tag>\n";
            }
        }
    }
    else {
        for my $element (@$arg) {
            print_xml $element;
        }
    }
}

sub print_vpn3k( $ ) {
    my ($router) = @_;
    my $model = $router->{model};

    # Build a hash of hashes of ... which will later be converted to XML.
    my %vpn_config = ();
    ($vpn_config{'vpn-device'} = $router->{name}) =~ s/^router://;
    $vpn_config{'aaa-server'} =
      [ map { { radius => print_ip $_->{ip} } }
          @{ $router->{radius_servers} } ];

    # Build a sub structure of %vpn_config
    my @entries = ();

    # no_nat_set of all hardware interfaces is identical, 
    # because we don't allow bind_nat at vpn3k devices.
    # Hence we can take no_nat_set of first hardware interface.
    my $no_nat_set = $router->{hardware}->[0]->{no_nat_set};

    # Find networks, which are attached to current device (cleartext or tunnel)
    # but which are not protected by some other managed device.
    my %auto_deny_networks;
    for my $interface (@{ $router->{interfaces} }) {
        next if $interface->{hub} and not $interface->{no_check};
        if ($interface->{ip} eq 'tunnel') {

            # Mark network of VPN clients or VPN networks behind
            # unmanaged router to be protected by deny rules.
            for my $peer (@{ $interface->{peers} }) {
                my $router = $peer->{router};
                next if $router->{managed};
                for my $out_intf (@{ $router->{interfaces} }) {
                    next if $out_intf->{ip} eq 'tunnel';
                    next if $out_intf->{spoke};
                    my $network = $out_intf->{network};
                    $auto_deny_networks{$network} = $network;
                }
            }
        }
        else {

            # Add all networks in security domain
            # located at cleartext interface.
            for my $network (@{ $interface->{any}->{networks} }) {
                $auto_deny_networks{$network} = $network;
            }
        }
    }
    my @deny_rules =
      map { "deny ip any $_" }
      sort
      map { ios_code $_, 1 }
      map { address($_,  $no_nat_set) } values %auto_deny_networks;

    my $add_filter = sub {
        my ($entry, $intf, $src, $add_split_tunnel) = @_;
        my @acl_lines;
        my %split_tunnel_networks;
        my $inv_mask = 1;
        for my $rule (@{ $intf->{rules} }, @{ $intf->{intf_rules} }) {
            my ($action, $src, $dst, $src_range, $srv) =
              @{$rule}{ 'action', 'src', 'dst', 'src_range', 'srv' };
            my $dst_network = is_network $dst ? $dst : $dst->{network};

	    # Add split tunnel networks, but not for 'any' from global:permit.
            if ($add_split_tunnel and $dst_network ne $network_00) {
                $split_tunnel_networks{$dst_network} = $dst_network;
            }

            # Permit access to auto denied networks.
            if ($auto_deny_networks{$dst_network}) {
                my ($proto_code, $src_port_code, $dst_port_code) =
                  cisco_srv_code($src_range, $srv, $model);
                my $result = "$action $proto_code";
                $result .= ' ' . 
		    ios_code(address($src, $no_nat_set), $inv_mask);
                $result .= " $src_port_code" if defined $src_port_code;
                $result .= ' ' . 
		    ios_code(address($dst, $no_nat_set), $inv_mask);
                $result .= " $dst_port_code" if defined $dst_port_code;
                push @acl_lines, $result;
            }
        }
        my $spair = address($src, $no_nat_set);
        my $src_code = ios_code($spair, $inv_mask);
        my $permit_rule = "permit ip $src_code any";
        push @acl_lines, @deny_rules, $permit_rule;
        $entry->{in_acl} = [ map { { ace => $_ } } @acl_lines ];
        if ((my $lines = @acl_lines) > 39) {
            my $msg = "Too many ACL lines at $router->{name}"
              . " for $src->{name}: $lines > 39";

            # Print error, but don't abort.
            print STDERR "Error: $msg\n";

            # Force generated config to be syntactically incorrect.
            $entry->{error} = $msg;
        }

        # Add split tunnel list.
        my @split_tunnel_networks;
        for my $network (
            sort { $a->{ip} <=> $b->{ip} || $a->{mask} <=> $b->{mask} }
            values %split_tunnel_networks)
        {
            my $ip   = print_ip $network->{ip};
            my $mask = print_ip complement_32bit $network->{mask};
            push @split_tunnel_networks, { base => $ip, mask => $mask };
        }
        $entry->{split_tunnel_networks} =
          [ map { { network => $_ } } @split_tunnel_networks ];
    };

    for my $interface (@{ $router->{interfaces} }) {
        next if not $interface->{ip} eq 'tunnel';
        my $hardware = $interface->{hardware};
        my $hw_name  = $hardware->{name};

        # Many single VPN software clients terminate at one tunnel interface.
        if (my $hash = $interface->{id_rules}) {
            for my $id (keys %$hash) {
                my $id_intf = $hash->{$id};
                my $src     = $id_intf->{src};
                my %entry;
                $entry{'Called-Station-Id'} = $hw_name;

                my $id = $src->{id};
                my $ip = print_ip $src->{ip};
                if ($src->{mask} == 0xffffffff) {
                    $id =~ /^\@/
                      and err_msg
                      "ID of $src->{name} must not start with character '\@'";

                    $entry{id} = $id;
                    $entry{'Framed-IP-Address'} = $ip;
                }
                else {
                    $id =~ /^\@/
                      or err_msg
                      "ID of $src->{name} must start with character '\@'";
                    $entry{suffix} = $id;
                    my $mask = print_ip complement_32bit $src->{mask};
                    $entry{network} = { base => $ip, mask => $mask };
                }
                $entry{inherited} = {
                    %{ $router->{radius_attributes} },
                    %{ $src->{network}->{radius_attributes} },
                    %{ $src->{radius_attributes} },
                };

                $add_filter->(\%entry, $id_intf, $src, 'add_split_t');
                push @entries, { user_entry => \%entry };
            }
        }

        # A VPN network behind a VPN hardware client.
        else {
            my $src = $interface->{peer_networks}->[0];
            my $id  = $src->{id};
            my %entry;
            $entry{'Called-Station-Id'} = $hw_name;
            $entry{id}                  = $id;
            $entry{inherited}           = {
                %{ $router->{radius_attributes} },
                %{ $src->{radius_attributes} },
            };
            $add_filter->(\%entry, $interface, $src);
            push @entries, { user_entry => \%entry };
        }
    }
    $vpn_config{entries} = \@entries;
    my $result = { 'vpn-config' => \%vpn_config };
    print_xml $result;
}

my $deny_any_rule =  
{
    action    => 'deny',
    src       => $network_00,
    dst       => $network_00,
    src_range => $srv_ip,
    srv       => $srv_ip
    };

sub print_cisco_acl_add_deny ( $$$$$$ ) {
    my ($router, $hardware, $no_nat_set, $model, $intf_prefix, $prefix) = @_;
    my $filter = $model->{filter};

    if ($filter eq 'IOS') {

        # Add deny rules to protect own interfaces.
        # If a rule permits traffic to a directly connected network
        # behind the device, this would accidently permit traffic
        # to an interface of this device as well.

	# This is needless if there is no such permit rule.
	# Try to optimize this case.
        my %need_protect;
        my $protect_all;
      RULE:
        for my $rule (@{ $hardware->{rules} }) {

            next if $rule->{action} eq 'deny';
            my $dst = $rule->{dst};

	    # We only need to check networks:
            # - any has been converted to network_00 already.
            # - subnet/host and interface already have been checked to
            #   have disjoint ip addresses to interfaces of current router.
            next if not is_network $dst;
            if ($dst eq $network_00) {
                $protect_all = 1;

#               debug "Protect all $router->{name}:$hardware->{name}";
                last RULE;
            }

            # Find interfaces of network or subnets of network,
            # which are directly attached to current router.
            for my $net ($dst,
                ($dst->{own_subnets}) ? @{ $dst->{own_subnets} } : ())
            {
                for my $intf (grep { $_->{router} eq $router }
                    @{ $net->{interfaces} })
                {
                    $need_protect{$intf} = $intf;

#                   debug "Need protect $intf->{name} at $hardware->{name}";
                }
            }
        }
        for my $interface (@{ $router->{interfaces} }) {
	    if (not $protect_all and not $need_protect{$interface}

		# Interface with 'no_in_acl' gets 'permit any any' added
		# and hence needs deny rules.
		and not $hardware->{no_in_acl}) 
	    {
		next;
	    } 

            # Ignore 'unnumbered' interfaces.
            next if $interface->{ip} =~ /^(?:unnumbered|negotiated|tunnel)$/;
            internal_err "Managed router has short $interface->{name}"
              if $interface->{ip} eq 'short';

            # IP of other interface may be unknown if dynamic NAT is used.
            if ($interface->{hardware} ne $hardware) {
                my $nat_network = 
		    get_nat_network($interface->{network}, $no_nat_set);
                next if $nat_network->{dynamic};
            }

            # Protect own interfaces.
            push @{ $hardware->{intf_rules} },
              {
                action    => 'deny',
                src       => $network_00,
                dst       => $interface,
                src_range => $srv_ip,
                srv       => $srv_ip
              };
        }
	if($hardware->{crosslink}) {
	    $hardware->{intf_rules} = [];
	}
    }

    # Add permit or deny rule at end of ACL.
    push(@{ $hardware->{rules} }, 
	 $hardware->{no_in_acl} ? $permit_any_rule : $deny_any_rule);

    # Interface rules
    cisco_acl_line($hardware->{intf_rules}, $no_nat_set, $intf_prefix, $model);

    # Ordinary rules
    cisco_acl_line($hardware->{rules}, $no_nat_set, $prefix, $model);
}

# Valid group-policy attributes.
# Hash describes usage:
# - need_value: value of attribute must have prefix 'value'
# - also_user: attribute is applicable to 'username'
# - internal: internally generated
my %asa_vpn_attributes = (

    # group-policy attributes
    banner                    => { need_value => 1 },
    'dns-server'              => { need_value => 1 },
    'default-domain'          => { need_value => 1 },
    'split-dns'               => { need_value => 1 },
    'wins-server'             => { need_value => 1 },
    'vpn-access-hours'        => { also_user  => 1 },
    'vpn-idle-timeout'        => { also_user  => 1 },
    'vpn-session-timeout'     => { also_user  => 1 },
    'vpn-simultaneous-logins' => { also_user  => 1 },
    vlan                      => {},
    'address-pools'             => { need_value => 1, internal => 1 },
    'split-tunnel-network-list' => { need_value => 1, internal => 1 },
    'split-tunnel-policy'       => { internal   => 1 },
    'vpn-filter'                => { need_value => 1, internal => 1 },
);

sub print_asavpn ( $ ) {
    my ($router)          = @_;
    my $model             = $router->{model};
    my $no_crypto_filter  = $router->{no_crypto_filter};
    my $no_nat_set        = $router->{hardware}->[0]->{no_nat_set};

    if ($no_crypto_filter) {
	print "! VPN traffic is filtered at interface ACL\n";
	print "no sysopt connection permit-vpn\n";
    }
    my $global_group_name = 'global';
    print <<"EOF";
! Used for all VPN users: single, suffix, hardware
group-policy $global_group_name internal
group-policy $global_group_name attributes
 pfs enable

EOF

    # Define tunnel group used for single VPN users.
    my $tunnel_group_name = 'VPN-single';
    my $trust_point       = 
	delete $router->{radius_attributes}->{'trust-point'}
    or err_msg
	"Missing 'trust-point' in radius_attributes of $router->{name}";

    print <<"EOF";
! Used for all single VPN users
tunnel-group $tunnel_group_name type remote-access
tunnel-group $tunnel_group_name general-attributes
! Use internal user database
 authorization-server-group LOCAL
 default-group-policy $global_group_name
 authorization-required
! Take username from email address field of certificate.
 username-from-certificate EA
tunnel-group $tunnel_group_name ipsec-attributes
 chain
 trust-point $trust_point
! Disable extended authentication.
 isakmp ikev1-user-authentication none
tunnel-group-map default-group $tunnel_group_name

EOF

    my $print_group_policy = sub {
        my ($name, $attributes) = @_;
        print "group-policy $name internal\n";
        print "group-policy $name attributes\n";
        for my $key (sort keys %$attributes) {
            my $value = $attributes->{$key};
            my $spec  = $asa_vpn_attributes{$key}
              or err_msg "unknown radius_attribute '$key' for $router->{name}";
            my $vstring = $spec->{need_value} ? 'value ' : '';
            print " $key $vstring$value\n";
        }
    };

    my %network2group_policy;
    my $user_counter = 0;
    for my $interface (@{ $router->{interfaces} }) {
        next if not $interface->{ip} eq 'tunnel';
        my %split_t_cache;

        if (my $hash = $interface->{id_rules}) {
            for my $id (keys %$hash) {
                my $id_intf = $hash->{$id};
                my $src     = $id_intf->{src};
                $user_counter++;
                my $pool_name;
                my $attributes = {
                    %{ $router->{radius_attributes} },
                    %{ $src->{network}->{radius_attributes} },
                    %{ $src->{radius_attributes} },
                };

                # Define split tunnel ACL.
                # Use default value if not defined.
                my $split_tunnel_policy = $attributes->{'split-tunnel-policy'};
                if (not defined $split_tunnel_policy) {

                    # Do nothing.
                }
                elsif ($split_tunnel_policy eq 'tunnelall') {

                    # This is the default value.
                    # Prevent new group-policy to be created.
                    delete $attributes->{'split-tunnel-policy'};
                }
                elsif ($split_tunnel_policy eq 'tunnelspecified') {

                    # Get destination networks for split tunnel configuration.
                    my %split_tunnel_nets;
                    for my $rule (@{ $id_intf->{rules} },
                        @{ $id_intf->{intf_rules} })
                    {
                        next if not $rule->{action} eq 'permit';
                        my $dst = $rule->{dst};
                        my $dst_network =
                          is_network $dst ? $dst : $dst->{network};

			# Dont add 'any' (resulting from global:permit)
			# to split_tunnel networks.
			next if $dst_network eq $network_00;
                        $split_tunnel_nets{$dst_network} = $dst_network;
                    }
                    my @split_tunnel_nets =
                      sort {
                             $a->{ip} <=> $b->{ip}
                          || $a->{mask} <=> $b->{mask}
                      } values %split_tunnel_nets;
                    my $acl_name;
                    if (my $href = $split_t_cache{@split_tunnel_nets}) {
                      CACHED_NETS:
                        for my $cached_name (keys %$href) {
                            my $cached_nets = $href->{$cached_name};
                            for (my $i = 0 ; $i < @$cached_nets ; $i++) {
                                if ($split_tunnel_nets[$i] ne 
				    $cached_nets->[$i])
                                {
                                    next CACHED_NETS;
                                }
                            }
                            $acl_name = $cached_name;
                            last;
                        }
                    }
                    if (not $acl_name) {
                        $acl_name = "split-tunnel-$user_counter";
                        if (@split_tunnel_nets) {
                            for my $network (@split_tunnel_nets) {
                                my $line =
                                  "access-list $acl_name standard permit ";
                                $line .= 
				    ios_code(address($network, $no_nat_set));
                                print "$line\n";
                            }
                        }
                        else {
                            print "access-list $acl_name standard deny any\n";
                        }
                        $split_t_cache{@split_tunnel_nets}->{$acl_name} =
                          \@split_tunnel_nets;
                    }
                    else {
                        print "! Use cached $acl_name\n";
                    }
                    $attributes->{'split-tunnel-network-list'} = $acl_name;
                }
                else {
                    err_msg "Unsupported value of 'split-tunnel-policy':",
                      " $split_tunnel_policy";
                }

		# Access list will be bound to cleartext interface.
		# Only check for valid source address at vpn-filter.
		if ($no_crypto_filter) {
		    $id_intf->{intf_rules} = [];
		    $id_intf->{rules} = 
			[ { action => 'permit', src => $src, dst => $network_00,
			    src_range => $srv_ip, srv => $srv_ip, } ];
		};
                find_object_groups($router, $id_intf);

                # Define filter ACL to be used in username or group-policy.
                my $filter_name = "vpn-filter-$user_counter";
                my $prefix      = "access-list $filter_name extended";
                my $intf_prefix = '';

# Why was NAT disabled?
#                $nat_map = undef;
                print_cisco_acl_add_deny $router, $id_intf, $no_nat_set, 
		$model, $intf_prefix, $prefix;

                my $ip      = print_ip $src->{ip};
                my $network = $src->{network};
                if ($src->{mask} == 0xffffffff) {
                    $id =~ /^\@/
                      and err_msg "ID of $src->{name} must not start with",
                      " character '\@'";
                    my $mask = print_ip $network->{mask};
                    my $group_policy_name;
                    if (%$attributes) {
                        $group_policy_name = "VPN-group-$user_counter";
                        $print_group_policy->($group_policy_name, $attributes);
                    }
                    print "username $id nopassword\n";
                    print "username $id attributes\n";
                    print " vpn-framed-ip-address $ip $mask\n";
                    print " service-type remote-access\n";
                    print " vpn-filter value $filter_name\n";
                    print " vpn-group-policy $group_policy_name\n"
                      if $group_policy_name;
                    print "\n";
                }
                else {
                    $id =~ /^\@/
                      or err_msg "ID of $src->{name} must start with",
                      " character '\@'";
                    $pool_name = "pool-$user_counter";
                    my $mask = print_ip $src->{mask};
                    my $max =
                      print_ip($src->{ip} | complement_32bit $src->{mask});
                    print "crypto ca certificate map ca-map-$user_counter 10\n";
                    print " subject-name attr ea co $id\n";
                    print "ip local pool $pool_name $ip-$max mask $mask\n";
                    $attributes->{'vpn-filter'}    = $filter_name;
                    $attributes->{'address-pools'} = $pool_name;
                    my $group_policy_name = "VPN-group-$user_counter";
                    my %tunnel_gen_att;
                    $tunnel_gen_att{'default-group-policy'} =
                      $group_policy_name;

                    if (my $auth_server =
                        delete $attributes->{'authentication-server-group'})
                    {
                        $tunnel_gen_att{'authentication-server-group'} =
                          $auth_server;
                    }
                    my %tunnel_ipsec_att;
                    $tunnel_ipsec_att{isakmp} =
                      'ikev1-user-authentication none';

		    # Don't generate default value.
                    ##$tunnel_ipsec_att{'peer-id-validate'} = 'req';
                    my $trustpoint2 = delete $attributes->{'trust-point'}
                      || $trust_point;
                    $tunnel_ipsec_att{'trust-point'} = $trustpoint2;
                    $print_group_policy->($group_policy_name, $attributes);

                    my $tunnel_group_name = "VPN-tunnel-$user_counter";
                    print <<"EOF";
tunnel-group $tunnel_group_name type remote-access
tunnel-group $tunnel_group_name general-attributes
EOF

                    while (my ($key, $value) = each %tunnel_gen_att) {
                        print " $key $value\n";
                    }
                    print <<"EOF";
tunnel-group $tunnel_group_name ipsec-attributes
EOF

                    while (my ($key, $value) = each %tunnel_ipsec_att) {
                        print " $key $value\n";
                    }
                    print <<"EOF";
tunnel-group-map ca-map-$user_counter 10 $tunnel_group_name

EOF
                }
            }
        }

        # A VPN network.
        else {
            $user_counter++;
            my $src = $interface->{peer_networks}->[0];

	    # Access list will be bound to cleartext interface.
	    # Only check for correct source address at vpn-filter.
	    if ($no_crypto_filter) {
		$interface->{intf_rules} = [];
		$interface->{rules} = 
		    [ { action => 'permit', src => $src, dst => $network_00,
			src_range => $srv_ip, srv => $srv_ip, } ];
	    };
            find_object_groups($router, $interface);

            # Define filter ACL to be used in username or group-policy.
            my $filter_name = "vpn-filter-$user_counter";
            my $prefix      = "access-list $filter_name extended";
            my $intf_prefix = '';

# Why was NAT disabled?
#            $nat_map = undef;
            print_cisco_acl_add_deny $router, $interface, $no_nat_set, $model,
              $intf_prefix, $prefix;

            my $id         = $src->{id};
            my $attributes = {
                %{ $router->{radius_attributes} },
                %{ $src->{radius_attributes} }
            };

            my $group_policy_name;
	    if (keys %$attributes) {
		$group_policy_name = "VPN-router-$user_counter";
		$print_group_policy->($group_policy_name, $attributes);
	    }
	    print "username $id nopassword\n";
	    print "username $id attributes\n";
	    print " service-type remote-access\n";
	    print " vpn-filter value $filter_name\n";
	    print " vpn-group-policy $group_policy_name\n" if $group_policy_name;
	    print "\n";
        }
    }
}

sub iptables_acl_line {
    my ($rule, $no_nat_set, $prefix) = @_;
    my ($action, $src, $dst, $src_range, $srv) =
	@{$rule}{ 'action', 'src', 'dst', 'src_range', 'srv' };
    my $spair = address($src, $no_nat_set);
    my $dpair = address($dst, $no_nat_set);
    my $action_code = is_chain $action 
	? $action->{name} : $action eq 'permit' ? 'ACCEPT' : 'droplog';
    my $jump = $rule->{goto} ? '-g' : '-j';
    my $result = "$prefix $jump $action_code";
    if ($spair->[1] != 0) {
	$result .= ' -s ' . prefix_code($spair);
    }
    if ($dpair->[1] != 0) {
	$result .= ' -d ' . prefix_code($dpair);
    }
    if ($srv ne $srv_ip) {
	$result .= ' ' . iptables_srv_code($src_range, $srv);
    }
    print "$result\n";
}

sub print_iptables_acls {
    my ($router) = @_;
    my $model        = $router->{model};
    my $filter       = $model->{filter};
    my $comment_char = $model->{comment_char};

    # Pre-processing for all interfaces.
    print "#!/sbin/iptables-restore <<EOF\n";
    print "*filter\n";
    print ":INPUT DROP\n";
    print ":FORWARD DROP\n";
    print ":OUTPUT ACCEPT\n";
    print "-A INPUT -j ACCEPT -m state --state ESTABLISHED,RELATED\n";
    print "-A FORWARD -j ACCEPT -m state --state ESTABLISHED,RELATED\n";
    print_chains $router;

    for my $hardware (@{ $router->{hardware} }) {

        # Ignore if all logical interfaces are loopback interfaces.
        next if not grep { not $_->{loopback} } @{ $hardware->{interfaces} };

	my $in_hw = $hardware->{name};
        my $no_nat_set = $hardware->{no_nat_set};
	if ($config{comment_acls}) {

	    # Name of first logical interface
	    print "$comment_char $hardware->{interfaces}->[0]->{name}\n";
	}

	# Print chain and declaration for interface rules.
	# Add call to chain in INPUT chain.
	my $intf_acl_name = "${in_hw}_self";
	print ":$intf_acl_name -\n";
	print "-A INPUT -j $intf_acl_name -i $in_hw\n";
	my $intf_prefix = "-A $intf_acl_name";
	for my $rule (@{ $hardware->{intf_rules} }) {
	    iptables_acl_line($rule, $no_nat_set, $intf_prefix);
	}

	# Print chain and declaration for forward rules.
	# Add call to chain in FORRWARD chain.
	# One chain for each pair of in_intf / out_intf.
	my $rules_hash = $hardware->{io_rules};
	for my $out_hw (sort keys %$rules_hash) {
	    my $acl_name = "${in_hw}_$out_hw";
	    print ":$acl_name -\n";
	    print "-A FORWARD -j $acl_name -i $in_hw -o $out_hw\n";
	    my $prefix     = "-A $acl_name";
	    my $rules_aref = $rules_hash->{$out_hw};
	    for my $rule (@$rules_aref) {
		iptables_acl_line($rule, $no_nat_set, $prefix, $model);
	    }
	}

	# Empty line after each chain.
	print "\n";
    }
    print "-A INPUT -j droplog\n";
    print "-A FORWARD -j droplog\n";
    print "COMMIT\n";
    print "EOF\n";
}

sub print_cisco_acls {
    my ($router)     = @_;
    my $model        = $router->{model};
    my $filter       = $model->{filter};
    my $comment_char = $model->{comment_char};

    for my $hardware (@{ $router->{hardware} }) {

        # Ignore if all logical interfaces are loopback interfaces.
        next if not grep { not $_->{loopback} } @{ $hardware->{interfaces} };

        # Force valid array reference to prevent error
        # when checking for non empty array.
        $hardware->{rules} ||= [];

        if ($filter eq 'PIX') {
            my $interfaces = [ @{ $router->{hardware} } ];
            if (not $router->{no_group_code}) {
                find_object_groups($router, $hardware);
            }
        }

        my $no_nat_set = $hardware->{no_nat_set};

	# Generate code for incoming and possibly for outgoing ACL.
	for my $suffix ('in', 'out') {
	    next if $suffix eq 'out' and not $hardware->{need_out_acl};

	    my $acl_name = "$hardware->{name}_$suffix";
	    my $prefix;
	    my $intf_prefix;
	    if ($config{comment_acls}) {
	    
		# Name of first logical interface
		print "$comment_char $hardware->{interfaces}->[0]->{name}\n";
	    }
	    if ($filter eq 'IOS') {
		$intf_prefix = $prefix = '';
		print "ip access-list extended $acl_name\n";
	    }
	    elsif ($filter eq 'PIX') {
		$intf_prefix = '';
		$prefix      = "access-list $acl_name";
		$prefix     .= ' extended' if $model->{name} eq 'ASA';
	    }

	    # Incoming ACL and protect own interfaces.
	    if ($suffix eq 'in') {
		print_cisco_acl_add_deny($router, $hardware, $no_nat_set, 
					 $model, $intf_prefix, $prefix);
	    }

	    # Outgoing ACL
	    else {

		# Add deny rule at end of ACL.
		push(@{ $hardware->{out_rules} }, $deny_any_rule);

		if (my $out_rules = $hardware->{out_rules}) {
		    cisco_acl_line($out_rules, $no_nat_set, $prefix, $model);
		}
	    }

	    # Post-processing for hardware interface
	    if ($filter eq 'IOS') {
		push(@{ $hardware->{subcmd} }, 
		     "ip access-group $acl_name $suffix");
	    }
	    elsif ($filter eq 'PIX') {
		print "access-group $acl_name $suffix interface", 
		" $hardware->{name}\n";
	    }

	    # Empty line after each ACL.
	    print "\n";	
	}
    }
}

sub print_acls {
    my ($router)     = @_;
    my $model        = $router->{model};
    my $filter       = $model->{filter};
    my $comment_char = $model->{comment_char};
    print "$comment_char [ ACL ]\n";

    if ($filter eq 'iptables') {
	print_iptables_acls($router);
    }
    else {
	print_cisco_acls($router);
    }
}

sub print_ezvpn( $ ) {
    my ($router)     = @_;
    my $model        = $router->{model};
    my $comment_char = $model->{comment_char};
    my @interfaces   = @{ $router->{interfaces} };
    my @tunnel_intf = grep { $_->{ip} eq 'tunnel' } @interfaces;
    @tunnel_intf == 1
      or err_msg
      "Exactly 1 crypto tunnel expected for $router->{name} with EZVPN";
    my ($tunnel_intf) = @tunnel_intf;
    my $wan_intf = $tunnel_intf->{real_interface};
    my @lan_intf = grep { $_ ne $wan_intf and $_ ne $tunnel_intf } @interfaces;
    @lan_intf == 1
      or err_msg
      "Exactly 1 LAN interface expected for $router->{name} with EZVPN";
    my ($lan_intf) = @lan_intf;
    my ($wan_hw, $lan_hw) = ($wan_intf->{hardware}, $lan_intf->{hardware});
    print "$comment_char [ Crypto ]\n";

    # Ezvpn configuration.
    my $ezvpn_name               = 'vpn';
    my $crypto_acl_name          = 'ACL-Split-Tunnel';
    my $crypto_filter_name       = 'ACL-crypto-filter';
    my $virtual_interface_number = 1;
    print "crypto ipsec client ezvpn $ezvpn_name\n";
    print " connect auto\n";
    print " mode network-extension\n";

    for my $peer (@{ $tunnel_intf->{peers} }) {

        # Unnumbered, negotiated and short interfaces have been
        # rejected already.
        my $peer_ip = print_ip $peer->{real_interface}->{ip};
        print " peer $peer_ip\n";
    }

    # Bind split tunnel ACL.
    print " acl $crypto_acl_name\n";

    # Use virtual template defined above.
    print " virtual-interface $virtual_interface_number\n";

    # xauth is unused, but syntactically needed.
    print " username test pass test\n";
    print " xauth userid mode local\n";

    # Apply ezvpn to WAN and LAN interface.
    push(@{ $lan_hw->{subcmd} },
        "crypto ipsec client ezvpn $ezvpn_name inside");
    push(@{ $wan_hw->{subcmd} }, "crypto ipsec client ezvpn $ezvpn_name");

    # Split tunnel ACL. It controls which traffic needs to be encrypted.
    print "ip access-list extended $crypto_acl_name\n";
    my $no_nat_set = $wan_hw->{no_nat_set};
    my $prefix  = '';
    cisco_acl_line($tunnel_intf->{crypto_rules}, $no_nat_set, $prefix, $model);

    # Crypto filter ACL.
    $prefix = '';
    $tunnel_intf->{intf_rules} ||= [];
    $prefix = '';
    $tunnel_intf->{rules} ||= [];
    print "ip access-list extended $crypto_filter_name\n";
    print_cisco_acl_add_deny $router, $tunnel_intf, $no_nat_set, $model, 
      $prefix, $prefix;

    # Bind crypto filter ACL to virtual template.
    print "interface Virtual-Template$virtual_interface_number type tunnel\n";
    $crypto_filter_name
      and print " ip access-group $crypto_filter_name in\n";
}

sub print_crypto( $ ) {
    my ($router) = @_;
    my $model = $router->{model};
    my $crypto_type = $model->{crypto} || '';
    return if $crypto_type eq 'ignore';
    if ($crypto_type eq 'EZVPN') {
        print_ezvpn $router;
        return;
    }

    # List of ipsec definitions used at current router.
    # Sort entries by name to get deterministic output.
    my @ipsec = sort { $a->{name} cmp $b->{name} }
                 unique(map  { $_->{crypto}->{type} }
		       grep { $_->{ip} eq 'tunnel' } 
		       @{ $router->{interfaces} });

    # Return if no crypto is used at current router.
    return unless @ipsec;

    # List of isakmp definitions used at current router.
    # Sort entries by name to get deterministic output.
    my @isakmp = sort { $a->{name} cmp $b->{name} }
                 unique(map { $_->{key_exchange} } @ipsec);

    my $comment_char = $model->{comment_char};
    print "$comment_char [ Crypto ]\n";
    if ($crypto_type eq 'ASA_VPN') {
        print_asavpn $router;
        return;
    }
    $crypto_type =~ /^(:?IOS|ASA)$/ 
	or internal_err "Unexptected crypto type $crypto_type";

    # Use interface access lists to filter incoming crypto traffic.
    # Group policy and per-user authorization access list can't be used
    # because they are stateless.
    if ($crypto_type eq 'ASA') {
	print "! VPN traffic is filtered at interface ACL\n";
	print "no sysopt connection permit-vpn\n";
    }

    # Handle ISAKMP definition.
    my @identity = unique(map { $_->{identity} } @isakmp);
    @identity > 1 and 
	err_msg "All isakmp definitions used at $router->{name}",
	"must use the same value for attribute 'identity'";
    my $identity = $identity[0];
    my @nat_traversal = unique(grep { defined $_ } 
			       map { $_->{nat_traversal} } @isakmp);
    @nat_traversal > 1 and 
	err_msg "All isakmp definitions used at $router->{name}",
	"must use the same value for attribute 'nat_traversal'";
			  
    my $prefix = $crypto_type eq 'IOS' ? 'crypto isakmp' : 'isakmp';
    $identity = 'hostname' if $identity eq 'fqdn';

    # Don't print default value for backend IOS.
    if (not ($identity eq 'address' and $crypto_type eq 'IOS')) {
	print "$prefix identity $identity\n";
    }
    if (@nat_traversal and $nat_traversal[0] eq 'on') {
	print "$prefix nat-traversal\n";
    }
    my $isakmp_count = 0;
    for my $isakmp (@isakmp) {
	$isakmp_count++;
	print "crypto isakmp policy $isakmp_count\n";

	my $authentication = $isakmp->{authentication};
	$authentication =~ s/preshare/pre-share/;
	$authentication =~ s/rsasig/rsa-sig/;

        # Don't print default value for backend IOS.
	if (not ($authentication eq 'rsa-sig' and $crypto_type eq 'IOS')) {
	    print " authentication $authentication\n";
	}

	my $encryption = $isakmp->{encryption};
	if ($encryption =~ /^aes(\d+)$/) {
	    my $len = $crypto_type eq 'ASA' ? "-$1" : " $1";
	    $encryption = "aes$len";
	}
	print " encryption $encryption\n";
	my $hash = $isakmp->{hash};
	print " hash $hash\n";
	my $group = $isakmp->{group};
	print " group $group\n";

	my $lifetime = $isakmp->{lifetime};

	# Don't print default value for backend IOS.
	if (not ($lifetime == 86400 and $crypto_type eq 'IOS')) {
	    print " lifetime $lifetime\n";
	}
    }

    # Handle IPSEC definition.
    my $transform_count = 0;
    my %ipsec2trans_name;
    for my $ipsec (@ipsec) {
	$transform_count++;
	my $transform = '';
	if (my $ah = $ipsec->{ah}) {
	    if ($ah =~ /^(md5|sha)_hmac$/) {
		$transform .= "ah-$1-hmac ";
	    }
	    else {
		err_msg "Unsupported IPSec AH method for $crypto_type: $ah";
	    }
	}
	if (not(my $esp = $ipsec->{esp_encryption})) {
	    $transform .= 'esp-null ';
	}
	elsif ($esp =~ /^(aes|des|3des)$/) {
	    $transform .= "esp-$1 ";
	}
	elsif ($esp =~ /^aes(192|256)$/) {
	    my $len = $crypto_type eq 'ASA' ? "-$1" : " $1";
	    $transform .= "esp-aes$len ";
	}
	else {
	    err_msg "Unsupported IPSec ESP method for $crypto_type: $esp";
	}
	if (my $esp_ah = $ipsec->{esp_authentication}) {
	    if ($esp_ah =~ /^(md5|sha)_hmac$/) {
		$transform .= "esp-$1-hmac";
	    }
	    else {
		err_msg "Unsupported IPSec ESP auth. method for",
		" $crypto_type: $esp_ah";
	    }
	}

	# Syntax is identical for IOS and ASA.
	my $transform_name = "Trans$transform_count";
	$ipsec2trans_name{$ipsec} = $transform_name;
	print "crypto ipsec transform-set $transform_name $transform\n";
    }

    # Collect tunnel interfaces attached to one hardware interface.
    my %hardware2crypto;
    for my $interface (@{ $router->{interfaces} }) {
        if ($interface->{ip} eq 'tunnel') {
	    push @{ $hardware2crypto{ $interface->{hardware} } }, $interface;
	}
    }

    for my $hardware (@{ $router->{hardware} }) {
        next if not $hardware2crypto{$hardware};
        my $name = $hardware->{name};

        # Name of crypto map.
        my $map_name = "crypto-$name";

        # Sequence number for parts of crypto map with different peers.
        my $seq_num = 0;

        # Crypto ACLs must obey NAT.
        my $no_nat_set = $hardware->{no_nat_set};

	# Sort crypto maps by peer IP to get deterministic output.
	my @tunnels =  sort { $a->{peers}->[0]->{real_interface}->{ip} <=>
			      $b->{peers}->[0]->{real_interface}->{ip} } 
	@{ $hardware2crypto{$hardware} };
	
	# Build crypto map for each tunnel interface.
        for my $interface (@tunnels) {
            $seq_num++;

	    my $ipsec = $interface->{crypto}->{type};
	    my $isakmp = $ipsec->{key_exchange};

            # Print crypto ACL. 
	    # It controls which traffic needs to be encrypted.
            my $crypto_acl_name = "crypto-$name-$seq_num";
            my $prefix;
            if ($crypto_type eq 'IOS') {
                $prefix = '';
                print "ip access-list extended $crypto_acl_name\n";
            }
            elsif ($crypto_type eq 'ASA') {
                $prefix = "access-list $crypto_acl_name extended";
            }
            else {
                internal_err;
            }
            cisco_acl_line($interface->{crypto_rules}, $no_nat_set, $prefix, 
			   $model);

            # Print filter ACL. It controls which traffic is allowed to leave
            # from crypto tunnel. This may be needed, if we don't fully trust
            # our peer.
            my $crypto_filter_name;
	    if ($router->{no_crypto_filter}) {
		if (@{$interface->{intf_rules}} || @{$interface->{rules}}) {
		    internal_err;
		}
	    }
	    else {
                $crypto_filter_name = "crypto-filter-$name-$seq_num";
                if ($crypto_type eq 'IOS') {
                    $prefix = '';
                    print "ip access-list extended $crypto_filter_name\n";
                }
                else {
		    internal_err;
                }
                print_cisco_acl_add_deny $router, $interface, $no_nat_set, 
		  $model, $prefix, $prefix;
            }

	    # Define crypto map.
            if ($crypto_type eq 'IOS') {
                $prefix = '';
                print "crypto map $map_name $seq_num ipsec-isakmp\n";
            }
            elsif ($crypto_type eq 'ASA') {
                $prefix = "crypto map $map_name $seq_num";
            }

	    # Bind crypto ACL to crypto map.
            print "$prefix match address $crypto_acl_name\n";

	    # Bind crypto filter ACL to crypto map.
            if ($crypto_filter_name) {
		print "$prefix set ip access-group $crypto_filter_name in\n";
	    }

	    # Set crypto peers.
	    # Unnumbered, negotiated and short interfaces have been
	    # rejected already.
	    if ($crypto_type eq 'IOS') {
		for my $peer (@{ $interface->{peers} }) {
		    my $peer_ip = print_ip $peer->{real_interface}->{ip};
		    print "$prefix set peer $peer_ip\n";
		}
	    }
	    elsif ($crypto_type eq 'ASA') {
		print "$prefix set peer ", 
		join(' ', map { print_ip $_->{real_interface}->{ip} } 
		     @{ $interface->{peers} }),
		"\n";
	    }

	    my $transform_name = $ipsec2trans_name{$ipsec};
            print "$prefix set transform-set $transform_name\n";

	    if (my $pfs_group = $ipsec->{pfs_group}) {
		if ($pfs_group =~ /^(1|2)$/) {
		    $pfs_group = "group$1";
		}
		else {
		    err_msg "Unsupported pfs group for $crypto_type: $pfs_group";
		}
		print "$prefix set pfs $pfs_group\n";
	    }

	    if (my $lifetime = $ipsec->{lifetime}) {
		
		# Don't print default value for backend IOS.
		if (not ($lifetime == 3600 and $crypto_type eq 'IOS')) {
		    print "$prefix set security-association" . 
			" lifetime seconds $lifetime\n";
		}
	    }

	    if ($crypto_type eq 'ASA') {
		my $authentication = $isakmp->{authentication};
		for my $peer (@{ $interface->{peers} }) {
		    my $peer_ip = print_ip $peer->{real_interface}->{ip};
		    print "tunnel-group $peer_ip type ipsec-l2l\n";
		    print "tunnel-group $peer_ip ipsec-attributes\n";
		    if ($authentication eq 'preshare') {
			print " pre-shared-key *****\n";
			print " peer-id-validate nocheck\n";
		    }
		    elsif ($authentication eq 'rsasig') {
			my $trust_point = $isakmp->{trust_point} or
			    err_msg "Missing 'trust_point' in",
			    " isakmp attributes for $router->{name}";
			print " chain\n";
			print " trust-point $trust_point\n";
			print " isakmp ikev1-user-authentication none\n";
		    }
		}
	    }
        }
        if ($crypto_type eq 'IOS') {
            push(@{ $hardware->{subcmd} }, "crypto map $map_name");
        }
        elsif ($crypto_type eq 'ASA') {
            print "crypto map $map_name interface $name\n";
            print "crypto isakmp enable $name\n";
        }
    }
}

sub print_interface( $ ) {
    my ($router) = @_;
    my $vrf_subcmd;
    if (my $vrf = $router->{vrf}) {
	$vrf_subcmd = "ip vrf forwarding $vrf";
    }
    for my $hardware (@{ $router->{hardware} }) {
	unshift @{ $hardware->{subcmd} }, $vrf_subcmd if $vrf_subcmd;
        my $subcmd = $hardware->{subcmd} || [];
        my $name = $hardware->{name};
        print "interface $name\n";
        for my $cmd (@$subcmd) {
            print " $cmd\n";
        }
    }
    print "\n";
}

# Make output directory available.
sub check_output_dir( $ ) {
    my ($dir) = @_;
    unless (-e $dir) {
        mkdir $dir
          or fatal_err "Can't create output directory $dir: $!";
    }
    -d $dir or fatal_err "$dir isn't a directory";
}

# Print generated code for each managed router.
sub print_code( $ ) {
    my ($dir) = @_;

    # Untaint $dir. This is necessary if running setuid.
    # We can trust value of $dir because it is set by setuid wrapper.
    if ($dir) {
        $dir =~ /(.*)/;
        $dir = $1;
        check_output_dir $dir;
    }

    progress "Printing code";
    my %seen;
    for my $router (@managed_routers) {
	next if $seen{$router};
        my $device_name = $router->{device_name};
        if ($dir) {
            my $file = $device_name;

            # Untaint $file. It has already been checked for word characters,
            # but check again for the case of a weird locale setting.
            $file =~ /^(.*)/;
            $file = "$dir/$1";
            open STDOUT, ">$file"
              or fatal_err "Can't open $file for writing: $!";
        }

	my $vrf_members = $router->{vrf_members};
	if ($vrf_members) {
	    if (not grep $_->{admin_ip}, @$vrf_members) {
		warn_msg("No IP found to reach router:$device_name");
	    }

	    # Print VRF instance with known admin_ip first.
	    $vrf_members = 
		[ 
		  sort { 
		      not($a->{admin_ip}) <=> not($b->{admin_ip})
			  || $a->{name} cmp $b->{name}
		  } 
		  @$vrf_members ];
	}
	for my $vrouter ($vrf_members ? @$vrf_members : ($router) ) {
	    $seen{$vrouter} = 1;
	    my $model        = $router->{model};
	    my $comment_char = $model->{comment_char};
	    my $name         = $vrouter->{name};

	    # Handle VPN3K separately;
	    if ($model->{filter} eq 'VPN3K') {
		print_vpn3k $vrouter;
		next;
	    }

	    print "$comment_char Generated by $program, version $VERSION\n\n";
	    print "$comment_char [ BEGIN $name ]\n";
	    print "$comment_char [ NewApprove ]\n" if $model->{add_n};
	    print "$comment_char [ OldApprove ]\n" if $model->{add_o};
	    print "$comment_char [ Model = $model->{name} ]\n";
	    if ($policy_distribution_point) {
		if (my $ips = $vrouter->{admin_ip}) {
		    printf("$comment_char [ IP = %s ]\n", join(',', @$ips));
		}
	    }
	    
	    print_routes $vrouter;
	    print_crypto $vrouter;
	    print_acls $vrouter;
	    print_interface $vrouter if $model->{name} =~ /^IOS/;
	    print_pix_static $vrouter if $model->{has_interface_level};
	    print "$comment_char [ END $name ]\n\n";
	}
        if ($dir) {
            close STDOUT or fatal_err "Can't close $file: $!";
        }
    }
    $config{warn_pix_icmp_code} && warn_pix_icmp;
    progress "Finished" if $config{time_stamps};
}

sub show_version() {
    progress "$program, version $VERSION";
}

1

#  LocalWords:  Netspoc Knutzen internet CVS IOS iproute iptables STDERR Perl
#  LocalWords:  netmask EOL ToDo IPSec unicast utf hk src dst ICMP IPs EIGRP
#  LocalWords:  OSPF VRRP HSRP Arnes loop's ISAKMP stateful ACLs negatable
#  LocalWords:  STDOUT
