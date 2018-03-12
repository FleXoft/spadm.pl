#
# Color text based on a set of RegExps
#
# TODO Check for multiple capture group PRE
# TODO Check @patterns when started
# TODO Check all attributes (colorvalidate) - collect largest attr set
# TODO Use colour schemes
# TODO Determine current bg/fg colour of the terminal
# TODO Simplify dye proc -> prio not needed
# TODO List of preferred schemas. If some fails during pre-check, choose other
# TODO Get the current screen/Term settings
# TODO Build up DEFAULT from all Attributes from all Stlyes and then check
#      against colorvalid. Maybe DEFAULT has to be added automatically to each
#      style.
# TODO Check patterns having the same abount of capture group as STYLES added.
#      If only one Style is added (not \@), use it for all. If some is missing,
#      use DEFAULT_ERROR (is exists);
#
# v0.001, 2017-01-22, Rakoshegy, TrueY
#    Add: @patterns reduction. Modify sytax
#    Add: Implement push_attribute
#    Add: Simplify dye (1 pass)
#    Add: Derived from colorize_concept.pl v0.001
#    Add: Push/pop_pattern: grep colour to @re2style
#    Add: load_schema, load_pattern. Not complete.
#
# v0.000, 2017-01-17, Rakoshegy, TrueY
#    Add: First working version 
#    Add: Update Term::ANSIColor to support ITALIC
#
##############################################################################

package Dye;

use strict;
use warnings;

use Exporter;
use Carp;
use Term::ANSIColor;
use Coffer;

our $VERSION = '0.001';
our @ISA = 'Exporter';
our @EXPORT_OK = qw(dye pop_pattern push_pattern show_ANSI); # set_schema

#system 'setterm -term linux -back black -fore yellow -clear';

#
# Supported attibutes: Foregorund color, background color, Italic, Bold, Underline,
#   Blink. Blink is swtiched off when bg is set on Cygwin uxterm.
#   On some terminal only 8 colours can be used.
#
# http://search.cpan.org/~rra/Term-ANSIColor-4.06/lib/Term/ANSIColor.pm
#

sub load_schema {
  my ($name) = @_;
  # TODO $name can be filename, is no ext, add .schema. Or ARRAY ref
  my $r = do "$name.schema";
  if (!defined $r) { croak "Cannot load '$name'";}
  if (ref $r ne 'HASH') { croak "Schema file should return an HASH ref";}

  my %default;
  for my $k (keys %$r) {
    my $v = $r->{$k};
    if (!defined $v) { croak "Not defined value in schema '$k'";}
    my $ref = ref $v;
    if ($ref eq '') { next; # Ok, link
    } elsif ($ref eq 'HASH') { 
      # Collect all attrubutes
      for my $kk (keys %{$r->{$k}}) {
	if (!exists $default{$kk})  { $default{$kk} = [];}
	@{$default{$kk}} = keys {map { $_ => 1} @{$default{$kk}}, $r->{$k}{$kk}};
      }
    } else { croak "Shema '$k' has to be a string or HASH";
    }
  }

  # Now all attrubutes are here. Check them.
  # TODO this is just for ANSI coloring!!!
  for my $k (keys %default) {
    if ($k =~ /^[FB]G/) {
      for my $v (@{$default{$k}}) {
	my $clr = $k eq 'BG' ? "on_$v" : $v;
	if (!Term::ANSIColor::colorvalid $clr) { croak "Bad color name '$clr'"; }
      }
    } elsif (!Term::ANSIColor::colorvalid $k) { croak "Bad attribute name '$k'";
    }
    $default{$k} = 'DEFAULT';
  }
  # Attributes validated

  if (!exists $r->{DEFAULT}) {
    $r->{DEFAULT} = \%default;
  } else { croak "Do not use DEFAULT Style in color schema";
  }

  return $r;
} # load_concept_ego

my %schema = (
  'DEFAULT' => load_schema 'tsm_concept_ego',
);
my $schema = 'DEFAULT';
my $style = $schema{$schema};

sub set_schema {
  my ($sch) = @_;
  if (!defined $sch) { $sch = 'DEFAULT';}
  if (!exists $schema{$sch}) { 
    croak "Schema '$sch' not found. Try: ".join(", ", keys %schema);
  }

  my $org = $schema;
  $schema = $sch;
  $style = $schema{$sch};

  return $org;
} # set_schema

# TODO May be generated automatically from %default_skin. AUTOLOAD?
sub ERROR()    { 'ERROR' };
sub WARN()     { 'WARN' };
sub INFO()     { 'INFO' };
sub SIZE()     { 'SIZE' };
sub BAD_SIZE() { 'BAD_SIZE' };
sub GREP()     { 'GREP' };
sub DEBUG()    { 'DEBUG' };

# Test of @-, @+, %
# Whole pattern is between $-[0] and $+[0].
# The 1st capture group is between $-[1] and $+[1], ...
# %+ contains the 1st value in a capture group
# %- contains the all values in a capture group

#
# Convert styl string to HASH ref. Use possible linking
# GLOBAL $style
#
sub get_attrs {
  my ($styl) = @_;
  if (ref $style ne 'HASH') { croak "Style for HASH";}
  while (1) {
    if (!exists $style->{$styl}) { croak "Style '$styl' not found";}
    my $ostyl = $styl;
    $styl = $style->{$styl};
    my $ref = ref $styl;
    if (!defined $styl) { croak "Style '$ostyl' has an undefined value";
    } elsif ($ref eq '') { next; # Link until HASH ref
    } elsif ($ref eq 'HASH') { return $styl;
    } else { croak "Bad style 'ostyl' ref $ref";
    }
  }
} # get_attrs


#
# Translate @patterns to [ [ RegExp, [ Attibs ], Modifiers ], ... ] triplets
# XXX Regexp conversion may be done later when the check done 1st
# GLOBAL @patterns
#

my @re2style; # GLOBAL
sub push_pattern {
  my $patterns;
  if (@_ == 1) { 
    if (ref $_[0] eq 'ARRAY') { $patterns = $_[0];
    } else { croak "Single value should be ARRAY ref";
    }
  } else { $patterns = [ @_ ];
  }
  if (@$patterns % 2) { croak 'Not even sized pattern list';}

  my @rv;

  for (my $i = 0; $i < @$patterns; $i += 2) {
    my $n = ($i >> 1) + 1;
    my ($rDef, $styl) = @{$patterns}[$i, $i + 1];
    if (!defined $rDef) { carp "Undefined pattern ($n)"; next;}
    if (!defined $styl) { carp "Undefined style ($n)"; next;}
    my $ref = ref $rDef;
    if ($ref eq '' || $ref eq 'Regexp') { $rDef = [ $rDef ];
    } elsif ($ref ne 'ARRAY') { 
      croak "Bad pattern ref '$ref'! Should be string, Regexp or ARRAY ref ($n)";
    }
    ref $styl eq '' and $styl = [ $styl ];
    ref $styl eq 'ARRAY'
	or croak "Stlye definition should be string or ARRAY ref";
    for my $s (@$styl) { $s = get_attrs $s; }

    for my $pat (@$rDef) {
      my ($modif, $smodif); # modif - only for g, smodif for normal modifiers
      my $ref = ref $pat;
      if ($ref eq '') { if ($pat =~ s/^\*([^*]+)\*//) { $modif = $1;}
      } elsif ($ref eq 'ARRAY') { ($pat, $modif) = @$pat;
      } elsif ($ref ne 'Regexp') {
	croak "Bad pattern ref '$ref'. Sould be string, Regexp or ARRAY ref";
      }
      defined $modif or $modif = '';
      $smodif = $modif;
      $modif = $smodif =~ s/g// ? 'g' : '';
      if ($smodif ne '' && $smodif !~ /^[adluimnsx]*(-[imnsx]+)?$/) {
	croak "Bad Regexp modifiers ($smodif). Allowed adluimnsx-imnsx";
      }
      if ($smodif ne '') { $pat = qr/(?$smodif)$pat/; # In case of PRE, repack
      } elsif (ref $pat eq '') { $pat = qr/$pat/;
      }
      ref $pat eq 'Regexp' or croak "Not Regexp '$pat'", ref $pat;
      # TODO in case of multiple capture groups, check the number of styles
      # [ Regexp, [ $style ], ? $modif ]
      push @rv, $modif ? [ $pat, $styl, $modif ] : [ $pat, $styl ];
    }
  }
  push @re2style, \@rv;
} # push_pattern


sub pop_pattern { pop @re2style;}


#
# contains Pattern => Style pairs.
# Add multiple patterns into one anonymous ARRAY ref. The last item should
# be the style to be used. 
# If multiple capture groups are defined Sytles can be listed in a \@.
# If no capture group in PRE, then use the whole pattern matched
# Items can be Regexp or string. String will be converted Regexp soon.
#
# TODO if refereced style is a CODE ref, call it with the matched string
#      and PRE. ??? Sub return the Style
#

sub load_pattern {
  my ($name) = @_;
  # Can be an ARRAY ref or filename w/o ext, of full filename
  my $r = do "$name.pattern";
  if (!defined $r) { croak "Cannot load pattern file '$name'"; }
  # TODO check patterns

  return $r;
}


INIT { # Array is populated. In BEGIN it is empty
  # Default patterns
  push_pattern load_pattern 'tsm_concept_ego';
}


#
# Get matching intervals to be dyed for a single line
# GLOBAL: @re2style (array of array of patterns)
# IN: text line
# OUT: [ [ { Attrs }, $txt ], ... ]
#

sub dye {
  my ($line) = @_;
  # Get disjuct coloured areas. At the end this will be transformed to
  # At first use [ { Attr }, from, to ] items. At the end convert it into
  # [ { Attr }, Txt ]
  my (@area) = [ $style->{DEFAULT}, 0, length $line ];

  for my $re2styl (@re2style) {
    for (my $i = 0; $i < @$re2styl; ++$i) { # Check a line for all patterns
      #X $re2styl->[$i];
      my ($re, $styl, $modif) = @{$re2styl->[$i]};

      # Find ares containing pos. Areas are continuous, disjunct intervals
      # ordered by position.
      sub find_area { # GLOCAL @area
	my ($rarea, $pos, $tip) = @_;
	my $i = defined $tip ? $tip : 0;
	for (; $i < @$rarea && $rarea->[$i][2] < $pos; ++$i) {}
	$i < @$rarea or croak "Area not found";

	return $i;
      } # find_area

      sub add_new_chunk {
        my ($rarea, $fr, $to, $styl) = @_;
	my $le = find_area $rarea, $fr;
	my $ri = find_area $rarea, $to, $le;

	D "fr=$fr, to=$to, le=$le, ri=$ri";
	# Cut left area and adjust sides
	my $r = $rarea->[$le];
	if ($r->[1] < $fr) { # Cut left area if needed
	  # Insert before
	  splice @$rarea, $le, 0, [ deep_copy($r->[0]), $r->[1], $fr ];
	  ++$le; ++$ri;
	  $rarea->[$le][1] = $fr;
	}

	# Cut right area and adjust sides
	$r = $rarea->[$ri];
	if ($r->[2] > $to) { # Cut right area if needed
	  splice @$rarea, $ri, 0, [ deep_copy($r->[0]), $r->[1], $to ];
	  $rarea->[$ri+1][1] = $to;
	}

	# Repaint new section
	for (my $i = $le; $i <= $ri; ++$i) {
	  my $ra = $rarea->[$i][0];
	  for my $k (keys %$styl) {
	    if (!exists $ra->{$k}) { carp "Attribute '$k' not set";}
	    $ra->{$k} = $styl->{$k};
	  }
	}
      } # add_new_chunk

      sub match {
	my ($rarea, $fr, $to, $styl) = @_;
	my @fr = @$fr;
	my @to = @$to;
	if (@fr != @to) { croak "Different capture group items";}
	my @styl = @$styl;
	if (@fr > 1) { shift @fr; shift @to;}
	while (@fr < @styl) { push @styl, $style->{DEFAULT_ERROR};}
	for (my $i = 0; $i < @fr; ++$i) {
	  add_new_chunk $rarea, $fr[$i], $to[$i], $styl[$i];
	}
      } # match

      # TODO Values in @- & @+ are strings. Adding 0 does not convert them
      #      into integers. But they should...
      my @part;
      if (defined $modif && $modif =~ /g/) {
	while ($line =~ /$re/g) {
	  D "", "*** GMatch ***", "'$line', '$re', @-, @+";
	  match \@area, \@-, \@+, $styl;
	}
      } else { # Single match
	if ($line =~ $re) {
	  D "", "*** Match ***", "'$line', '$re', @-, @+";
	  match \@area, \@-, \@+, $styl;
	}
      }
    }
  }

  # Concatenate areas having exactly the same attributes
  for (my $i = 1; $i < @area; ++$i) {
    my ($rs0, $rs1) = ($area[$i-1][0], $area[$i][0]);
    my $s0= join "|", map { "$_=>".$rs0->{$_} } sort keys %$rs0;
    my $s1= join "|", map { "$_=>".$rs1->{$_} } sort keys %$rs1;
    if ($s0 eq $s1) {
      D "Melting $i";
      $area[$i-1][2] = $area[$i][2]; # Exted previous
      splice @area, $i, 1; # Remove this item
      redo;
    }
  }

  # Replace string positions with text chunks
  for my $ra (@area) {
    my $txt = substr $line, $ra->[1], $ra->[2] - $ra->[1];
    splice @$ra, 1, 2, $txt;
  }

  return \@area;
}


sub show_ANSI {
  my ($rdye) = @_;
  my @rv;

  for my $rchunk (@$rdye) {
    my ($rattr, $txt) = @$rchunk;
    # XXX ITALIC does not work on xterm under Linux
    my @styl = grep $rattr->{$_} && $rattr->{$_} ne 'DEFAULT',
        qw/BLINK BOLD ITALIC UNDERLINE/;
    $rattr->{FG} && $rattr->{FG} ne 'DEFAULT' and push @styl, $rattr->{FG};
    $rattr->{BG} && $rattr->{BG} ne 'DEFAULT' and push @styl, "ON_".$rattr->{BG};
    my $styl = join " ", @styl;
    D "'$styl' - '$txt'";
    push @rv, $styl eq '' ? $txt : colored($txt, $styl);
  }

  return join "", @rv;
} # show_ANSI


1;
