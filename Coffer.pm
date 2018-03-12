#
# My toolbox
#
# Call TSM client once and send commands thru pipe
#
# TODO Write documentation
#
# INFO Needed tput (external) - maybe Term::ReadLine if enough
#
# v0.001, 2017-01-18 Rakoshegy, TrueY
#    Add: Derived from tsm_concept_ego.pl v0.003
#
###############################################################################

package Coffer;

use strict;
use warnings;
use 5.010; # state

use Exporter;
use Carp;
use Data::Dumper;    # Dumper
use Config;

our $VERSION = '0.001';
our @ISA = 'Exporter';
our @EXPORT = qw(any bt D decode_exit deep_copy Du open_debug_terminal 
    sig_name un uns X);

my $h;

sub open_debug_terminal {
  my ($dev) = @_;
  if (!defined $dev || $dev eq '') { 
    carp 'List all /dev/pts with this user';
  }
  $dev =~ s/^\s+|\s+$//g;
  if ($dev =~ /^\d+/) { $dev = '/dev/pts/'.$dev;
  } elsif ($dev =~ m{^[^/]}) { $dev = '/dev/'.$dev;
  }
  if (!-c $dev) {
    croak "Debug terminal '$dev' not a char dev\n";
  }
  my $uid = (stat $dev)[4];
  if ($uid != $<) {
    print "uid=$uid, uid=$<, euid=$>\n";
    my $uname = getpwuid($uid);
    my $euname = getpwuid($<);
    carp "Owner ($uname) is not you ($euname) for $dev";
  }
  open $h, '>', $dev or croak "Cannot open '$dev', ($!)";
  print $h "==== START ".('=' x 70)."\n";
}

sub D { my $sub = (caller(1))[3]; $sub = defined $sub ? $sub : "MAIN";
  $h and print $h map { $_ ? "$sub: $_\n" : "\n" } @_; 
}
sub Du {  my $sub = (caller(1))[3]; $sub = defined $sub ? $sub : "MAIN";
  $h and print $h "$sub: ", Dumper @_; 
}
sub X { print Dumper @_; exit;}
sub any(&@) { my $cmd = shift; for (@_) { return 1 if &$cmd;} }
sub un($) { return defined $_[0] ? $_[0] : "#NA";}
sub uns { return join ', ', map { un $_ } @_;}
sub bt($) { return defined $_[0] ? unpack "b*", $_[0] : "#NA";}

sub deep_copy { # Clone::clone is missing. So some hack needed.
  local $Data::Dumper::Terse = 1;
  my $s = Dumper $_[0];

  return eval $s;
} # deep_copy


sub sig_name {
  state $sig_name = [ split /\s+/, $Config{sig_name} ];
  return @_ ? ($sig_name->[$_[0]] ? $sig_name->[$_[0]] : '???') : @$sig_name;
} # sig_name 


sub decode_exit {
  my ($ex, $er) = @_;
  my ($exit_no, $sig_no, $sig_name, $core_dump);
  my $rem = "Failed with";
  $exit_no = $ex >> 8;
  if ($exit_no) { $rem .= " Exit $exit_no";}
  if ($ex & 127) {
    $sig_no = $ex & 127;
    $sig_name = sig_name $sig_no;
    $rem .= " SIG$sig_name ($sig_no)";
    $core_dump = $ex & 128;
    if ($core_dump) { $rem .= " with coredump";}
  }
  if ($ex == 0) { $rem = "Done ok";}
  if ($!) { $rem .= " ($!)";}
  return [ $exit_no, $sig_no, $core_dump, $rem, $ex, $sig_name ];
} # decode_exit 

1;
