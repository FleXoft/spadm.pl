#!/usr/bin/env perl
#
# TSM server call concept 
#
# Call TSM client once and send commands thru pipe
#
# TODO Write documentation
# TODO less dsmerror.log
# TODO double ^C to quit
#
# INFO Needed tput (external) - maybe Term::ReadLine if enough
# INFO Needed Getopt::Long, 
# INFO If the command is a sudo select will fail and return with undef.
#      So start this script with sudo.
#
# v0.003, 2017-01-22 Rakoshegy, TrueY
#    Add: 1st stage: Create packages for MyTools, GetXOptions and Dodder
#    Add: generate all commands with shortcuts and write into a package file
#    Add: Term code
#    Add: Dye module
#
# v0.002, 2017-01-07 Rakoshegy, TrueY
#    Add: Check for UID
#    Add: Handle signals: CHLD, INT (, PIPE)
#    Add: Collect all commands from help
#
# v0.001, 2017-01-03 Rakoshegy, TrueY
#    Add: Dodder to launch a program in the background
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

use strict;
use warnings;
#use 5.010; # state

# Find modules right next to this script
use FindBin;
use lib "$FindBin::Bin";

use Carp;
use Symbol;         # gensym
use IPC::Open3;     # open3
use Data::Dumper;   # Dumper
use List::Util      qw(first);
use POSIX           qw(strftime);
use Term::ReadLine;

use Coffer;         # open_debug_terminal, D, X, any, un, uns, bt
use GetXOptions;    # GetXOptions
use Dodder;         # Dodder class
use Dye             qw(dye pop_pattern push_pattern show_ANSI);

sub tsm_start;
sub tsm_talk;
sub tsm_get_all_cmds;
sub tsm_clean;

sub term_attempted_completion;
sub term_completion_entry;
sub term_guess;

# http://www.ibm.com/support/knowledgecenter/SSGSG7_7.1.7/srv.reference/r_cmdline_adclient_options.html
my @exe = qw(dsmadmc -ID=truey -PAssword=password1234
    -ALWAYSPrompt -NEWLINEAFTERPrompt -DISPLaymode=LISt
);
#-TABdelimited
#-COMMAdelimited

# TODO remove later. It calls a help page
sub help { X tsm_talk \@exe, 'help '.$_[0]; exit;}

#
# Check environment
#

if ($^O ne "cygwin" && $< != 0) {
  carp "Should be rooted. Use sudo su -c \"$0 @ARGV\"";
  D "@ARGV";
  system 'sudo', $0, @ARGV;
  exit;
}

(my $PROG = $0) =~ s{^.*/}{};
$PROG  =~ s{\.pl$}{};

# Command package. Generated if not exists
my $command_pkg = "TsmCommands"; # .pm
# Readline history file
my $histFile = "$PROG.hist";
my $histSize = 50;

my $term = new Term::ReadLine 'ProgramName';
$term->ReadHistory($histFile);
$term->read_init_file; # read ~/.inputrc
print "Loaded version: ", $term->ReadLine, " v", $term->VERSION, "\n";
my $attr = $term->Attribs;
$attr->{attempted_completion_function} = \&term_attempted_completion;
$attr->{completion_entry_function} = \&term_completion_entry;

#
# Process options
#

my %opt = (debug => 0);
GetXOptions \%opt, "debug=i<Set debug terminal>", "color_test=i<Test dying>"
  or croak;
my $debug = $opt{debug};
$debug and open_debug_terminal $debug;

my $tsm_all_commands = tsm_get_all_cmds \@exe, $command_pkg;
#X $tsm_all_commands;

my $my_prompt = "Test prompt [TSMSERVER]> ";

if ($opt{color_test}) {
  for (<DATA>) {
    if (/dbDailyIncrements|full/) {
      push_pattern([ "dbDailyIncrements", "full" ] => 'GREP');
      my $ra = dye $_;
      my $li = show_ANSI $ra;
      print $li;
      pop_pattern;
    }
    my $ra = dye $_;
    my $li = show_ANSI $ra;
    print $li;
  }
  exit;
}

my $str = '';
while (defined ($_ = $term->readline($my_prompt, $str))) {
  s/^\s+|\s+$//g;
  next if /^$/;
  $str = '';
  $_ = uc $_;
  if ($_ eq "X") { last;}
  my $guessed = term_guess $_; # commands have different attributes
  if (!defined $guessed) { $str = $_; next;}
  print "CMD: '$guessed'\n";
  my ($ro, $re) = tsm_talk $_;
  # TODO handle $re
  tsm_clean $ro;
  print Dumper $ro;
  #$term->addhistory($_); # Automatically ads to history. Default set
}

$term->WriteHistory($histFile);
$term->history_truncate_file($histFile, $histSize);

print "eXit\n";
exit;

##############################################################################
#
# F U N C T I O N
#

#### TSM #####################################################################

my $prc; # TODO call tsm_prc
#
# Connect to tsm
sub tsm_start {
  D $prc;
  if (defined $prc) { carp "Proc already started"; return;}
  my ($rexe) = @_;
  my (@out, @err);
  $prc = Dodder->new(command => $rexe, out => \@out, err => \@err,
      exit_string => 'quit', prompt => qr(^\w+: \w[-\w]*>\s*));
  $prc->dodder; # Just start
  $prc->prompt($out[-1]); # current prompt
  
  return \@out;
} # tsm_start


# Send a command && get result &c dump
sub tsm_talk {
  #D $prc;
  if (ref $_[0] eq 'ARRAY') { tsm_start shift;}
  my (@out, @err);
  if (!defined $prc) { croak "Background process not started";}
  $prc->dodder(out => \@out, err => \@err, talk => $_[0]);

  return wantarray ? (\@out, \@err) : \@out;
} # tsm_talk

sub tsm_clean {
  my ($r) = @_;
  if ($r->[-1] eq $prc->prompt) { pop @$r;}
  while ($r->[-1] eq '') { pop @$r;}
} # tsm_clean

#
# Load or generate all commands
# IN: \@ - command line; name of module
#

sub tsm_get_all_cmds {
  my ($rexe, $cmd_pkg) = @_;
  my $rhdr = tsm_start $rexe; # Start server even is commands are collected

  my $name = "$FindBin::Bin/$cmd_pkg.txt";
  if (-f $name) {
    my $rv = do $name;
    if (!defined $rv) { croak "Cannot load '$name'";}
    # TODO If file is corrupted, delete and recreate
    if (ref $rv ne 'HASH') { croak "Bad return value of $name";}
    return $rv;
  }
  
  print "\n$cmd_pkg module not found! Creation started...\n";
  my $rout = tsm_talk 'help';
  #X $rout;
  
  # concatenate continuation lines and remove leading spaces
  my ($li, @li) = '';
  for (@$rout) {
    s/^\s+//; # Remove leading spaces
    if (/ $/) { $li .= $_; next;} # Continuation line
    push @li, $li.$_;
    $li = '';
  }
  #X \@li;

  # Read until Administrative commands
  my $i = 0;
  my $sect;
  for (; $i < @li && !defined $sect; ++$i) {
    if ($li[$i] =~ /^\s*(\d+(?:\.\d+)+)\s+Administrative commands/) {
      $sect = $1;
    }
  }
  if (!defined $sect) { croak "'Administrative commands' section not found";}

  # Process admin commands
  my ($last, @admin_cmd) = '';
  $sect =~ s/\.0$//; # Main section is not 3, but 3.0 !?
  for (; $i < @li; ++$i) {
    my $li = $li[$i];
    if ($li !~ /^\Q$sect\E\.\d+/) { last;}
    $li =~ s/\s+[-\(].*//;
    my ($sub, $cmd) = split /\s+/, $li, 2;
    if ($last eq $cmd) { next;}
    $last = $cmd;

    my $li1 = $li[$i + 1]; # Check next line
    $li1 =~ s/\s+[-\(].*//;
    my ($sub1, $cmd1) = split /\s+/, $li1, 2;

    if ($sub1 =~ /^\Q$sub.\E/) {
      if ($cmd ne $cmd1) { D "Head command '$cmd' vs '$cmd1'"; next; }
    }
    D "$sub - $cmd";
    push @admin_cmd, $cmd;
  }
  #X \@admin_cmd;

  print 0+@admin_cmd, " TSM commands found.\n";
  #exit;#X \@lines;

  # Remove head sections
  # Some help pages refereces to sub-sections. If the sub-section dest has
  # extended command, then this is a head secion. If it has the same commands
  # then this command is real and it is detailed on other pages.
  my $setopt;
  my $n = 0;
  local $| = 1;
  for (@admin_cmd) {
    print ++$n."/".(0+@admin_cmd)."...\r";
    my (@out, @err);
    my $rout = tsm_talk "help $_";
    my $info = $rout->[0];
    #if ($out[0] eq "ANR2307E No help text could be found for this message: $_.") {
    #  D "Not command '$_'";
    #  next;
    #}
    if ($rout->[0] =~ /^AN.\d{4}[EIW] /) {
      pop @$rout; pop @$rout;
      carp "Problem with '$_' processing help\n", map { "  $_\n" } @$rout;
      next;
    } 

    my $syn = first {/^>>-/} @$rout;
    if (!$syn) { # Get more detailed description
      D "No syntax '$_'. Read more ...";
      my ($sect_no, $cmd) = split /\s+/, $rout->[0], 2; # Examine 1st line
      $cmd =~ s/\s+[-\(].*//; # Trim explanation
      my $rout = tsm_talk "help $sect_no.1";
      if ($rout->[0] =~ /^AN.\d{4}[EIW] /) {
	pop @$rout; pop @$rout;
	carp "Problem with '$_' processing help\n", map { "  $_\n" } @$rout;
      } 
      $syn = first {/^>>-/} @$rout; #use 'any' instead
      if (!$syn) { warn "Deep read failed $sect_no - '$_'"; }
    }

    # Store for later processing
    if ($_ eq 'SETOPT') { $setopt = $rout;}

    if (!defined $syn) { $syn = $_;
    } else {
      $syn =~ s/^>>-+\s*//;
      my $syn2 = $syn;
      $syn =~ s/-.*//;
      if ($syn !~ /\w/) {
	my $i = 0;
	for (; $i < @$rout && $rout->[$i] !~ /^>>-/; ++$i) { }
        D "Foolish syntax. Look around for '$_'";
	$syn = $rout->[$i-1];
	$syn =~ s/^\s+\.-+\s*//;
	$syn =~ s/-.*//;
      }
      # Correct mistake in the doc '-' separate command name
      if (length $syn < length) { 
	($syn = $syn2) =~ s/-+/ /;
	$syn =~ s/-.*//;
        warn "Cheat cut command: '$syn'\n";
      }
      if (length $syn > length) { 
	$syn = substr $syn, 0, length;
        warn "Cheat too long command '$syn'\n";
      }

      # Correct mistakes in the doc
      if ($syn =~ s/^AUDIT /AUDit /) { warn "Cheat Audit for '$syn'\n";}
      if ($syn =~ s/^COPY /COPy /)   { warn "Cheat Copy for '$syn'\n";}
      if ($syn =~ s/^QUERY /Query /) { warn "Cheat QUERY for '$syn'\n";}
      if ($syn =~ s/^SET /Set /)     { warn "Cheat SET for '$syn'\n";}
    }

    my $s = sprintf "%-30s '%s'", $_, $syn;
    D $s;
    if (uc $syn ne $_) { croak "Nonmathing shorcut '$syn'. Apply a cheat";}
    $_ = $syn;
  }
  #X \@admin_cmd, $setopt;

  if (defined $setopt) { # Read options from SETOPT help page
    my $i = 0;
    for (; $i <@$setopt; ++$i) {
      if ($setopt->[$i] =~ 'following options are available:') { last;}
    }
    my @setopts;
    for (++$i; $i <@$setopt; ++$i) {
      if ($setopt->[$i] eq '') { last;}
      push @setopts, $setopt->[$i] =~ s/^\s+//r;
    }

    for (my $i = 0; $i < @admin_cmd; ++$i) {
      if ($admin_cmd[$i] eq 'SETOPT') {
	splice @admin_cmd, $i, 1, map { "SETOPT $_" } @setopts;
	last;
      }
    }
  }
  #X \@admin_cmd;

  # Make a hash from all commands
  sub make_hash; # recursion
  sub make_hash {
    my ($ra) = @_;
    my %cmd;
    # Format 1st level hash
    for (map { [ split /\s+/, $_, 2 ] } @$ra) {
      my ($cmd, $arg) = @$_;
      my $Cmd = uc $cmd;
      (my $cm_ = $cmd) =~ s/[a-z]//g; # Chmop lower case letters
      if ($cm_ eq $cmd) { $cm_ = undef;}
      if (!exists $cmd{$Cmd}) { $cmd{$Cmd} = [defined $cm_ ? "~$cm_" : undef];}
      $arg and push @{$cmd{$Cmd}}, $arg;
    }

    # Convert ARRAY values to HASH
    for my $k (keys %cmd) {
      my $v = $cmd{$k};
      my $abbrev = shift @$v;
      if (@$v) { 
        $v = make_hash $v; 
	defined $abbrev and $v->{$abbrev} = undef;
      } else { $v = $abbrev;
      }
      $cmd{$k} = $v;
    }

    return \%cmd;
  }

  my $all = make_hash \@admin_cmd;

  if ($rhdr->[-1] eq $prc->prompt) { pop @$rhdr;}
  while ($rhdr->[-1] eq '') { pop @$rhdr;}

  local $Data::Dumper::Terse = 1; # Do not write '$VAR1 = '
  my $txt = Dumper $all;
  open my $h, '>', $name or croak "Cannot open '$name' for write ($!)";
  print $h "#\n# DO NOT MODIFY THIS FILE!\n#\n",
      "# Automatically generated by $0\n",
      "# Date: ", strftime("%Y-%m-%d %T%n", localtime),
      "#\n# Source:\n",
      map({ "# $_\n" } @$rhdr),
      "#\n".("#"x79)."\n\n$txt;\n";
  close $h or croak "Error during close ($!)";

  # Try again to load after creation
  my $rv = do $name;
  if (!defined $rv) { croak "Cannot load '$name'";}
  if (ref $rv ne 'HASH') { croak "Bad return value of $name";}

  return $rv;
} # read_all_commands

#### Term ####################################################################

my $term_rcmd; # Used be completion_entry
# Sets $term_rcmd to the proper level
sub term_attempted_completion {
  my ($txt, $buf, $start, $end) = @_;
  D "txt=$txt, buf=$buf, start=$start, end=$end";
  # Get completed commands
  (my $t = uc substr $buf, 0, $start) =~ s/^\s+|\s+$//g;
  my @t = split /\s+/, $t;
  D "txt='$txt', t='$t', <@t>";
  $term_rcmd = $tsm_all_commands; # XXX GLOBAL
  for my $c (@t) {
    if (!exists $term_rcmd->{$t}) { 
      my $shortcut;
      for my $w (keys %$term_rcmd) {
        if ($term_rcmd->{$w} eq "~$c" || exists $term_rcmd->{$w}{"~$c"}) { 
	  $shortcut = $w; last; 
	}
      }
      if (!$shortcut) { croak "Cmd/arg not found '$_' in '$t'";}
      $c = $shortcut;
    }
    D "Changed using '$c'";
    $term_rcmd = $term_rcmd->{$c}
  }

  return undef; # Always use default completion_entry_function
} # term_attempted_completion

my @l;
# Called implicitly from attempted_completion when it returns undef
sub term_completion_entry {
  my ($txt, $state) = @_;
  $txt = uc $txt;
  D uns @_;
  if ($state == 0) {
    @l = grep /^\Q$txt\E/ && !/^~/, keys %$term_rcmd;
    D "LIST: '@l'";
  }
  D "Return($state/".(0+@l)."): ".un $l[$state];

  return $l[$state];
} # term_completion_entry


# Guess the name of the command
sub term_guess {
  my ($cm) = @_;
  my @cm = split /\s+/, $cm;
  my @gcm;
  D "CM: ", uns @cm;
  my $rcmd = $tsm_all_commands; # XXX use GLOBAL
  while (@cm) {
    my $c = shift @cm;
    if (!exists $rcmd->{$c}) { # Cmd not found. Extend
      my @k = sort keys %$rcmd;
      D "K: <$c> ".uns @k;
      my @keys = sort grep /^\Q$c\E/i, keys %$rcmd;
      D "KEYS: ".uns @keys;
      if (@keys == 0) { carp "Cmd/arg '$c' not found"; return undef;}
      if (@keys > 1) { # Check for shortcuts
        my $shortcut;
        for (@keys) {
	  D "_='$_', c=$c, ->=".un $rcmd->{$_};
	  my $r = $rcmd->{$_};
          if (defined $r && $r eq "~$c" || exists $r->{"~$c"}) {
            D "Shorcut ~$c for $_";
            if (defined $shortcut) { 
              carp "Duplicated shorcut '$c' for '$_' & '$shortcut'";
              return undef;
            }
            $shortcut = $_; 
          }
        }
        if (!defined $shortcut) {
          carp "Amiguous cmd/arg '$c' not unique (@keys)"; 
          return undef;
        }
        @keys = ( $shortcut );
      }
      $c = $keys[0];
    }
    $rcmd = $rcmd->{$c};
    push @gcm, $c;
    if (!defined $rcmd || ref $rcmd eq '') { last;}
  }
  if (defined $rcmd && ref $rcmd eq "HASH") {
    carp "Command not completed. Use ", uns keys %$rcmd;
    return undef;
  }

  return join " ", @gcm, @cm;
} # term_guess


__DATA__
Primary Pool MKB_OS4_J, Copy Pool MKB_OS4_C1_J, Files Backed Up: 24, Bytes Backed Up: 1,134,000,815,259, Unreadable Files: 0, Unreadable Bytes: 0. Current Physical File (bytes): 246,120,144,486 Current input volume: A00448JA. Current output volume: MKB510JA.

Volume MKB195JA (storage pool MKB_SQL_C1_J), Moved Files: 4, Moved Bytes: 7,904,512, Unreadable Files: 0, Unreadable Bytes: 0. Current Physical File (bytes): 55,534,602,514 Current input volume: MKB195JA. Current output volume: MKB216JA.
"Volume MKB195JA (storage pool MKB_SQL_C1_J), Moved Files: 4, Moved Bytes: 7,904,512, Unreadable Files: 0, Unreadable Bytes: 1. Current Physical File (bytes): 55,534,602,514 Current input volume: MKB195JA. Current output volume: MKB216JA.
Volume MKB195JA (storage pool MKB_SQL_C1_J), Moved Files: 4, Moved Bytes: 7,904,512, Unreadable Files: 0, Unreadable Bytes: 1,234. Current Physical File (bytes): 55,534,602,514 Current input volume: MKB195JA. Current output volume: MKB216JA.
"Incremental backup: 0 pages of 77452 backed up. Current output volume: /tsm/blackhole/dbDailyIncrements/21536884.DBB.
Incremental backup: 0 pages of 77452 backed up. Current output volume: D:\tsm\blackhole\dbDailyIncrements\21536884.DBB.

ANR2020E Incremental backup: 0 pages of 77452 backed up. Current output volume: /tsm/blackhole/dbDailyIncrements/21536884.DBB.
print dye 'ANR2020E Incremental backup: 0 pages of 77452 backed up. Current output volume: D:\tsm\blackhole\dbDailyIncrements\21536884.DBB.

ANR2020W Incremental backup: 0 pages of 77452 backed up. Current output volume: /tsm/blackhole/dbDailyIncrements/21536884.DBB.1212122.
print dye 'ANR2020W Incremental backup: 0 pages of 77452 backed up. Current output volume: D:\tsm\blackhole\dbDailyIncrements\21536884.DBB.12121.'

ANR2020E RECLAIM STGPOOL: Invalid parameter - TRE.
TSMADM [USERTSM.SR]:reclaim stgp files_vtl tres60

ANR2020W RECLAIM STGPOOL: Invalid parameter - TRE.\
ANR2020I RECLAIM STGPOOL: Invalid parameter - TRE.
TSMADM [USERTSM.SR]:reclaim stgp files_vtl tres60

ANR2020E RECLAIM STGPOOL: Invalid para\\\\meter - TRE.
ANR2020W RECLAIM STGPOOL: Invalid para /tsm/alam.DBB meter - TRE.

ANR8209E Unable to establish TCP/IP session with 10.16.2.234 - connection refused. (SESSION: 94)
ANR8209E Unable to establish TCP/IP session with 10.16.2.234 - connection refused. (SESSION: 94)

ANR2020E Incremental backup: 0 pages of 77452 backed up. Current output volume: /tsm/blackhole/dbDailyIncrements/21536884.DBB.
ANR2020E Incremental backup: 0 pages of 77452 backed up. Current output volume: D:\tsm\blackhole\dbDailyIncrements\21536884.DBB.

01/09/2012 06:04:29      BACKUPFULL            842             0          1     DCFILE_01        /tsmdata/full/26085469.DBB
01/09/2012 06:04:29      BACKUPFULL            842             0          1     DCFILE_01        /tsmdata/full/26085469.DBB

Primary Pool DB2_VTL, Copy Pool DB2_C_LTO, Files Backed Up: 295, Bytes Backed Up: 666,553,401,841, Unreadable Files: 0, Unreadable Bytes: 0. Current Physical File (bytes): 228,001,965,291 Current input volume: V00359. Current output volume(s): B00252L3.
Current input volume: V00359. Current output volume(s): B00252L3.

