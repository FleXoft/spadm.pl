#
# TSM server call concept 
#
# Call TSM client once and send commands thru pipe
#
# TODO Write documentation
# TODO GetOptions. Consider opt!, opt+, opt:, &c.
# TODO Replace uasge of system tput command
#
# v0.002, 2017-01-21 Rakoshegy, TrueY
#    Add: Use first, not grep
#
# v0.001, 2017-01-18 Rakoshegy, TrueY
#    Add: Derived from tsm_concept_ego.pl v0.003
#
# v0.000, 2016-12-19, Rakoshegy, TrueY
#    Add: Improve GetXOptions (Auto --help, option hash ref)
#    Add: Use ! i/o = mandatory value; Additional type 'D' for YYYYMMDD type
#    Add: 
#      option[=!][iofsD][%@]?(\('|' separated list of possible values\))?
#          (<help text>)?
#      or a hashref: key => '', mandatory => 1, type => [iofsD],
#           help => "HELP text", values => [possible values in ARRAY ref]
#           default => val, list => [%@]
#
###############################################################################

package GetXOptions;

use strict;
use warnings;
use Exporter;
use Carp;
use Getopt::Long;    # Getoptions
use List::Util qw(first);

our $VERSION = '0.002';
our @ISA = 'Exporter';
our @EXPORT = qw(GetXOptions);

#
# Extend Getopt::Long::GetOptions (1st arg has to be a hash ref)
# Not full implementation (e.g. /!$/, :, +; 1st arg must be hashref)
# See http://perldoc.perl.org/Getopt/Long.html
# IN: hash ref, opt string | hash ref
#    option string
#      option[=!][iofsD][%@]?(\('|' separated list of possible values\))?(<help text)?>
#        '!' i/o '=' makes option mandatory (cannot changed to ':')
#        =s[@%](val[|val2[...]]) - allowed values
#        =D - date (YYYYMMDD)
#     option hash ref = { 
#       # required:
#         key=>'opt_name',
#       # optional:
#         help=>"help text",
#         type=>[iofsD], # Option type if not a flag
#         values=>[1,2,3], default=>'3', mandatory=>1, list => [%@]
#     }
# OUT: undef if failed
#
# TODO Set  D => '^\d{8}', any other pattern
#

sub GetXOptions {
  my ($r_opt, @o) = @_;
  if (ref $r_opt ne "HASH") {
    carp "First argument should be a HASH ref";
    return undef;
  }
  my %_opt;
  my $fail = 0;
  my (@mandatory, @date, %val_set);
  my %typ = (o=>'XINT', f=>'FLOAT', i=>'INT', s=>'STRING', D=>'DATE');

  # Convert new syntax to original GetOptions. Not all arg combination is
  # implemented.
  push @o, "help<This help text>"; # Default option
  for (my $i = 0; $i < @o; ++$i) {
    my ($o, $hlp, $key) = $o[$i];
    if (ref $o eq "") {
      #Cut off help
      $o =~ s/<([^\>]*)>$//s and $hlp = $1;
      #Cut off value-set
      my $rvs = $o =~ s/\(([^\)]*)\)$// ? [ split /\|/, $1 ] : undef;

      ($key = $o) =~ s/([=!])([siofD])([%@])?$//;
      my ($mandatory, $type, $list) = ($1, $2, $3);
      if (defined $type && !exists $typ{$type}) {
        carp "Wrong type $type"; ++$fail; next;
      }

      #Check for date (YYYYMMDD)
      my $type_old = $type;
      #Check for mandatory options. Cannot be replaced as ':' for now...
      if ($mandatory eq "!") { push @mandatory, $key; }
      $o = "$key";
      if (defined $type) { 
        if ($type eq "D") { push @date, $key; $type_old = "s"; }
        $o .= "=".$type_old;
      }
      if (defined $list) { $o .= $list;}

      my %opt = ( old => $o, );
      defined $hlp and $opt{help} = $hlp;
      defined $rvs and $val_set{$key} = $opt{values} = $rvs;
      defined $list and $opt{list} = $list;
      defined $type and $opt{type} = $type;
      defined $mandatory && $mandatory eq "!" and $opt{mandatory} = 1;
      exists $r_opt->{$key} and $opt{default} = $r_opt->{$key};

      $_opt{$key} = \%opt;
    } elsif (ref $o eq "HASH") {
      if (!exists $o->{key}) {
        carp "Tag 'key' is missing in option definition\n";
        ++$fail;
        next;
      }
      $key = $o->{key};
      delete $o->{key}; # not needed any more
      $_opt{$key} = $o;
      $o = $key;
      exists $o->{type} and $o .= "=".$o->{type};
      exists $o->{list} and $o .= $o->{list}; # maybe [@%]

      if (exists $o->{default} && exists $r_opt->{$key} 
          && " ".un $o->{default} ne " ".un $r_opt->{$key}
      ) {
        carp "Default value set twice for option $key.",
            " Explicit definition is used.\n";
      }
      exists $o->{default} && !exists $r_opt->{$key} and 
          $r_opt->{$key} = $o->{default};

      if (exists $o->{type} && (exists $o->{list} || exists $o->{values} 
          || exists $o->{default})
      ) {
        carp "Flag option cannot have list, values or default tag\n";
        ++$fail;
        next;
      }
      $_opt{$key}{old} = $o;
    } else {
      carp "Bad reference '", ref $o, "' in option definition\n";
      ++$fail;
      next;
    }

    if (exists $_opt{$key}{values} && exists $_opt{$key}{default}
        && !any {$_ eq $_opt{$key}{default}} @{$_opt{$key}{values}}
    ) {
      carp "Default value ", $_opt{$key}{default}, " is not in allowed values (",
        join(",", @{$_opt{$key}{values}}),")\n";
      ++$fail;
      next;
    }

    $o[$i] = $o;
  }

  if ($fail) { return undef;}
    
  # Store defatult value
  my $rv = GetOptions $r_opt, @o;

  if (exists $r_opt->{help}) { # Handle if help requested
    # Collect data
    my ($mx, @hlp) = 0;

    for my $opt (sort keys %_opt) {
      my $r = $_opt{$opt};
      my $l = "  --$opt";
      if (exists $r->{type}) { $l .= '='.$typ{$r->{type}};}
      if (length $l > $mx) { $mx = length $l;}
      my ($rem, @rem) = exists $r->{help} ? $r->{help} : "";
      $rem =~ s/(?:\s*\n)+\s*$/\n/s; # Trailing multiple LFs reduced to one
      if (exists $r->{default}) { push @rem, "default value ".$r->{default};}
      if (exists $r->{mandatory}) { push @rem, "mandatory option";}
      if (exists $r->{values}) { 
        push @rem, "allowed values = ".join(", ",@{$r->{values}});
      }
      if (@rem) { 
        if ($rem) { $rem .= " ";}
        $rem .= "(".join("; ", @rem).")";
      }
      # TODO show format, D, o, f - maybe in comment
      push @hlp, [ $l, $rem ];
    }

    # Show help
    my $wid = `tput cols`; # Get screen width
    chomp $wid;
    --$wid;
    print "\nUsage:\n\n";
    for (@hlp) {
      my ($key, $rem) = @$_;
      my $l = sprintf("%-*s", $mx, $key);
      if ($rem ne "") { $l .= " - $rem";}
      $l =~ s/\t/ /g; # Eliminate TABs
      $l =~ s/(?:\s*\n*)+$//s; # Trim ending LFs and SPACEs
      if ($mx + 23 < $wid) { # Screen is wide enough
        do {
          my $p1 = substr($l, 0, $wid);
          $l = length $l > $wid ?  substr $l, $wid : "";
          my $p = index $p1, "\n";
          if ($p > 0) {
            $l = substr($p1, $p + 1).$l;
            $p1 = substr($p1, 0, $p);
          } elsif ($l ne "") {
            my $p = rindex $p1, " ";
            if ($p >= 0 && $p > $mx + 3) {
              $l = substr($p1, $p + 1).$l;
              $p1 = substr($p1, 0, $p)
            }
          }
          print "$p1\n";
          $l =~ s/^\s+//; # Trim heading spaces
          if ($l ne "") { $l = " "x($mx+3).$l;} # Add margin
        } while $l ne "";
      } else { print $l, "\n";
      }
    }
    exit 0;
  }

  # Now check the mandatory options!
  for (@mandatory) {
    if (!exists $r_opt->{$_}) { 
      carp "Missing mandatory option --$_\n"; 
      ++$fail;
    }
  }
  # Check for date format
  for (@date) {
    if (exists $r_opt->{$_} && $r_opt->{$_} !~ /^\d{8}$/) {
      carp "Value '".$r_opt->{$_}.
	  "' invalid for option $_ (Date expected YYYYMMDD)\n"; 
      ++$fail;
    }
  }
  # Check for not allowed values
  for my $k (keys %$r_opt) {
    if (exists $val_set{$k} && !first {$_ eq $r_opt->{$k}} @{$val_set{$k}}) {
      carp "Value '$r_opt->{$k}' invalid for option $k (Expected value in ",
          join(", ", map {"'$_'"} @{$val_set{$k}}), ")\n";
      ++$fail;
    }
  }

  return $rv && !$fail;
} # GetXOptions

1;
