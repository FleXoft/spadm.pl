#
# TSM server call concept 
#
# Call TSM client once and send commands thru pipe
#
# TODO Write documentation
#
# v0.000, 2017-01-20 Rakoshegy, TrueY
#    Add: Derived from tsm_concept_ego.pl v0.003
#
###############################################################################

package Dodder;

use strict;
use warnings;
use 5.010; # state
use Exporter;
use Carp;

use Symbol;     # gensym
use IPC::Open3; # open3
use Coffer;     # D, X, any, un, uns, bt

our $VERSION = '0.000';
our @ISA = 'Exporter';
our @EXPORT = qw();

#######################################################################
#
# Handle signals
#
# SIGCHLD received when child proc dies
# SIGPIPE received when pipe tried to be read, but other end not exists
# SIGINT  received when ^C  is pressed
#

my %dodderPid;
sub my_sig_chld {
  my $cpid = wait; # There should be at least the dead zombie
  my $it = $dodderPid{$cpid};
  if (defined $it) {
    print "SIG@_ reveived, CHLD=$cpid\n";
    $it = $dodderPid{$cpid};
    $it->_clr_pid;
    $it = $it->{auto_reconnect} ? $it : undef;
  }
  $SIG{CHLD} = \&my_sig_chld;
  $it and $it->connect;
};
$SIG{CHLD} = \&my_sig_chld;
 

sub my_sig_pipe {
  print "SIG@_ reveived\n";
  $SIG{PIPE} = \&my_sig_pipe;
};
$SIG{PIPE} = \&my_sig_pipe;
 

sub my_sig_int { # Maybe issue an Exit
  print "Use quit instead of ^C\n";
  $SIG{INT} = \&my_sig_int;
}
$SIG{INT} = \&my_sig_int;


#######################################################################
#
# Launch a background process
#
# IN: agrs hash
#   command     => \@exe - command to execute
#   out         => \@out     - Where to put STDOUT of child
#   err         => \@err     - Where to put STDERR of child
#   prompt      => qr(^\w+: \w[-\w]*>\s*) - Prompt to wait
#   auto_reconnect => reconnect when disconnect detected
#   exit_string => 'quit' - Send this command to exit
#   exit_prompt =>  - Wait until this string after exit_string sent
#
#   _cmd => \@ to command line
#   _wrh, _rdh, _erh => PIPE handlers.
#   _rd_fno, _er_fno, _wr_fno - PIPE filenos
#   _ro_flg, _re_flg, _rd_flg, _wr_flg, _er_flg - SELECT flags
#   _pid
#   _out, _err - translated out, err
#
#   TODO timeout
#
#   Default for out is to print to STDOUT
#   Default for err is to print to STDERR
#   If out or err is an ARRAY ref, rows added to this array
#   If out or err is an CODE ref, each rows sent to this CODE one-by-one
#   If out or err is a string, dump into a file named by the string
#     if string is ">>file" then append
#   If out or err is a GLOB ref, dump into that file handler
#   XXX (If out or err is an int, dump into that file handler)
#
# public: new, connect, disconnect, dodder, prompt
# private: _init, _clr_pid, _putline, _getline, _eatline, _snack, _decode_ref
#
# Do not call connect directly! Always use dodder, as it automatically connect
# and can listen.
# Do not call disconnect directly! It is called when object is destroyed.
#

sub new {
  my $class = shift;
  if (ref $class ne '') { croak "Class method";}
  my %arg = @_;

  my $self = {};
  bless $self, $class;
  
  # Process args
  for (qw(auto_reconnect command err exit_prompt exit_string out
      prompt timeout)
  ) {
    $self->{$_} = delete $arg{$_};
  }
  if (%arg) { croak "Unsupported arguments: ".join ", ", keys %arg; }
  #D "self=$self";
  $self->_init;

  return $self;
} # new


#
# Init self
# IN: -, OUT: -
#

sub _init {
  my $self = shift;
  if (ref $self eq '') { croak "Object method"; }

  my @cmd;
  if (exists $self->{command}) {
    my $ref = ref $self->{command};
    if (!defined $self->{command}) { croak 'Command is missing';}
    if (!$ref) { push @cmd, $self->{command};
    } elsif ($ref eq 'ARRAY') { push @cmd, @{$self->{command}};
    } else { croak "Bad command ref '$ref'";
    }
  }

  # Default is 
  if (!exists $self->{out}) { $self->{out} = \*STDOUT;}
  if (!exists $self->{err}) { $self->{err} = \*STDERR;}

  D "CMD '@cmd'\n";
  $self->{_cmd} = \@cmd;
  # define all private vars to have them listed
  map { undef $self->{$_} } qw(_wrh _rdh _erh _rd_fno _er_fno _wr_fno
      _ro_flg _re_flg _rd_flg _wr_flg _er_flg _pid);
  # Must not define: _out _err - open possible file handler only if needed

  #Du $self;
  #if ($self->{auto_connect}) { $self->connect;}
} # _init


#
# Connect to background process
# IN: -, OUT: -
#

sub connect {
  my $self = shift;
  if (ref $self eq '') { croak "Object method"; }

  my ($wrh, $rdh, $erh, $cmd);
  $erh = gensym; # Why this needed? Retuns an anonymous glob
  $cmd = $self->{_cmd};
  if (!defined $cmd) { croak "Command not defined";}
  D "Connect ".$cmd->[0];
  my $pid = open3 $wrh, $rdh, $erh, @$cmd or croak "Cannot run @$cmd ($!)";

  my ($wr_fno, $rd_fno, $er_fno) = map { fileno $_ } $wrh, $rdh, $erh;
  D "pid=$pid, wr_fno=$wr_fno, rd_fno=$rd_fno, er_fno=$er_fno";

  # Set 'select' bits
  my ($ro_flg, $re_flg, $rd_flg, $wr_flg, $er_flg) = ('') x 5; # LOCALs
  vec($wr_flg, $wr_fno, 1) = 1;
  vec($ro_flg, $rd_fno, 1) = 1;
  vec($re_flg, $er_fno, 1) = 1;
  $rd_flg = $ro_flg | $re_flg;;
  $er_flg = $rd_flg | $wr_flg; # Outbound errors for sockets

  $dodderPid{$pid} = $self;
  $self->{_pid} = $pid;

  $self->{_wrh} = $wrh;
  $self->{_rdh} = $rdh;
  $self->{_erh} = $erh;
  $self->{_wr_fno} = $wr_fno;
  $self->{_rd_fno} = $rd_fno;
  $self->{_er_fno} = $er_fno;

  $self->{_ro_flg} = $ro_flg;
  $self->{_re_flg} = $re_flg;
  $self->{_rd_flg} = $rd_flg;
  $self->{_wr_flg} = $wr_flg;
  $self->{_er_flg} = $er_flg;

  #Du $self;
} # connect


sub disconnect {
  my $self = shift;
  if (ref $self eq '') { croak "Object method"; }

  my $r;
  my $pid = $self->{_pid};
  D "Close connection ".un $pid;
  if ($pid && kill 0, $pid) { # pid set and proc exists
    if ($self->{exit_string}) { 
      #D "$pid: Send exit string '".$self->{exit_string}."'\n";
      $self->_putline($self->{exit_string});
    }
    if ($self->{exit_prompt}) { $self->_snack($self->{exit_prompt});}

    my $wpid = waitpid $pid, 0;
    $r = decode_exit $?, $!;
  }

  return $r;
} # disconnect


#
# Shut down server when exited
#

sub DESTROY {
  my $self = shift;
  if (ref $self eq '') { croak "Object method"; }
  D "$self";

  my $r = $self->disconnect;
  if (defined $r) { print $r->[3], "\n";}
}


sub _clr_pid {
  my $self = shift;
  if (ref $self eq '') { croak "Object method"; }

  undef $self->{_pid};
} # _clr_pid


sub prompt { # Getter/Setter
  my $self = shift;
  if (ref $self eq '') { croak "Object method"; }

  my $rv = $self->{prompt};
  @_ and $self->{prompt} = $_[0];

  return $rv;
}


#
# XXX Do not mix 'select' and buffered I/O. So use sysread and syswrite
#

#
# Put lines using unbuffered syswrite. Write concatenated 4KiB chunks.
# IN: lines (w/o LF) (max line lengthe is 1 KiB)
# OUT: -
#

sub _putline {
  my $self = shift;
  if (ref $self eq '') { croak "Object method"; }
  #D "send = '@_'";

  my $buf = join " ", @_;
  if (length $buf) { $buf .= "\n"; my $r = syswrite $self->{_wrh}, $buf; }
} # _putline


#
# Get next line from handle (buffered read using unbuffered sysread)
# (Each lines (incl. prompt) ends with LF)
# IN: GLOB
# OUT: Bytes read 
#

my @rd_buf;
sub _getline { # Local non obj function!
  my $h = $_[0];
  my ($fno,   $pos) = fileno $h;
  if (!defined $rd_buf[$fno]) { $rd_buf[$fno] = '';}
  my $r = \$rd_buf[$fno];

  #D "Read buf: fno=$fno, buf_len=".length($$r);
  while (1) { # Read until LF found
    $pos = index $$r, "\n";
    if ($pos > -1) { last;}
    my $rn = sysread $h, $$r, 0x1000, length $$r;
    if ($rn == 0) { croak "End of read handle: $fno";}
    if (length $$r > 0x10000) { croak "Too large line";}
  }

  my $rv = substr $$r, 0, $pos;
  $$r = substr $$r, $pos + 1;

  return $rv;
} # _getline


#
# Handle IO requests. Read a line from stdout and/or stderr of background proc
# IN: -
# OUT: (out, err)
#

sub _eatline {
  my $self = shift;
  if (ref $self eq '') { croak "Object method"; }
  #D "self=$self";

  my ($rdh, $erh, $rd_fno, $er_fno, $rd_flg) = 
      @{$self}{qw(_rdh _erh _rd_fno _er_fno _rd_flg)};
  my ($T, $n, $out, $err);

  do {
    my $rd_out; # =chr(0) If this set it does not work

    # Check if data is already in the buffer
    if ($rd_buf[$rd_fno] && 0 <= index $rd_buf[$rd_fno], "\n") {
      if (!defined $rd_out) { $rd_out = chr(0);}
      vec($rd_out, $rd_fno, 1) = 1; ++$n;
    }
    if ($rd_buf[$er_fno] && 0 <= index $rd_buf[$er_fno], "\n") {
      if (!defined $rd_out) { $rd_out = chr(0);}
      vec($rd_out, $er_fno, 1) = 1; ++$n;
    }

    # If buffer is empty check if data available
    if (defined $rd_out) { $T = $self->{timeout};
    } else { 
      $rd_out = $rd_flg;
      ($n, $T) = select $rd_out, undef, undef, $self->{timeout};
    }

    if (!defined $n) { croak "N not defined in select: '$!'"; last;}
    if ($n == -1) { croak "Error detected in select(): $!"; last;}
    if (vec($rd_out, $rd_fno, 1) == 1) { $out = _getline $rdh; }
    if (vec($rd_out, $er_fno, 1) == 1) { $err = _getline $erh; }
  } while (!$n);

  return ($out, $err);
} # _eatline


#
# Read lines from child's stdout and stderr and call defined proc
# IN: ((closing string/RE)), \@/\&/GLOB,  \@/\&/GLOB 
#   ref can be
#      undef - nothing
#      \@    - if 1st item is CODE callback; otherwise add to array
#      \&    - call CODE
#      GLOB - write that file handle
# OUT: undef - if found
#
# TODO timeout (return undef)
#

sub _snack {
  my ($self, $prmpt, $rout, $rerr) = @_;
  if (ref $self eq '') { croak "Object method"; }
  #D "self=$self, prmpt=".un($prmpt).", rout=".un($rout).", rerr=".un($rerr);

  sub proc {
    my ($r, $txt) = @_;
    #D "ref=".un($r).", txt=".un($txt);
    if (!defined $r) { ; # Do nothing
    } elsif (ref $r eq 'ARRAY') { 
      if (ref $r->[0] eq 'CODE') { &{$r->[0]}(@{$r}[1..$#$r], $txt);
      } else { push @$r, $txt;
      }
    } elsif (ref $r eq 'CODE') { &{$r}($txt);
    } elsif (ref $r eq 'GLOB') { print $r $txt, "\n";
    } else { croak "Bad proc ref ", ref $r;
    }
  } # proc

  while(1) {
    my ($o, $e) = $self->_eatline;

    if (defined $e) {
      #D "ERR($rerr): '$e'\n";
      proc $rerr, $e
    }

    if (defined $o) {
      #D "OUT(".un($rout)."): '$o'\n";
      proc $rout, $o;

      if (defined $prmpt) {
        my $ref = ref $prmpt;
        if ($ref eq '') { if ($o eq $prmpt) { return 1;}
        } elsif ($ref eq "Regexp") { if ($o =~ $prmpt) { return 1;}
        } else { croak "Bad reference '$ref' for prompt";
        }
      }
    }

    if (!defined $o && !defined $e) { return undef;} # timeout
  };
} # _snack


# Can be \@, \&, GLOB, string, undef
sub _decode_ref { # Local non-class sub
  my ($r) = @_;
  state %handle; # multiple odders may share the same file handle...
  my $ref = ref $r; # ref(undef) eq ''
  #D "ref=".un($ref);
  $ref =~ /^(?:|ARRAY|CODE|GLOB)$/ or croak "Bad output reference: '$ref'";
  if ($ref eq '' && defined $r) { #Filename, >filename, >>filename
    # TODO ?Implement >&= for unix file handler
    $r =~ s/^(>*)//; # Remove leading '>' or '>>'
    my $mod = $1 ? $1 : '>';
    # Maybe add abs_path to be sure to have same filename
    if (exists $handle{$r}) { $r = $handle{$r};
    } else {
      open my $h, $mod, $r or croak  "Cannot open output file '$r'";
      $handle{$r} = $h;
      $r = $h;
    }
  }

  return $r;
} # _decode_ref

  
#
# Execute a process in the background
# Reconnect if disconnected
#
# IN: args hash. Changeable args hash:
#     out && err => [GLOB|filename|>filename|>>filename]
#     prompt => [string|Regexp]
#     order => string - send a command and no wait
#     talk => string - send a command and wait 
#     If args given, use them instead of the default
#

sub dodder {
  my ($self, %args) = @_;
  if (ref $self eq '') { croak "Object method"; }

  # TODO Implement timeout
  #$timeout = $args{_timeout}; # _timeout [sec], LOCAL

  my $out = exists $args{out} ? _decode_ref $args{out}
      : exists $self->{_out} ? $self->{_out}
      : do { $self->{_out} = _decode_ref $self->{out} };
  my $err = exists $args{err} ? _decode_ref $args{err}
      : exists $self->{_err} ? $self->{_err}
      : do { $self->{_err} = _decode_ref $self->{err} };
  my $prompt = exists $args{prompt} ? $args{prompt}
      : $self->{prompt};
  if (exists $args{order} && exists $args{talk}) {
    croak "Cannot order and talk at once";
  }
  #D "out=".un($out).", err=".un($err).", prompt=".un($prompt);

  if (!defined $self->{_pid} || !kill 0, $self->{_pid}) { # execute
    D "Reconnect '".join(" ", @{$self->{_cmd}})."'\n";
    $self->connect;
  }

  return exists $args{order} ? do { $self->_putline($args{order}); 1;}
      : exists $args{talk} ? do { # order and listen
          $self->_putline($args{talk});
	  $self->_snack($prompt, $out, $err);
	}
      : $self->_snack($prompt, $out, $err); # Just listen
} # dodder


1;
