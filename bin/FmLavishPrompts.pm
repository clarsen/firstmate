# Shared parser for the queued-content block of a captured lavish-axi result.
# Owned contract: fm-procevent-lavish.sh's `read`, `answers`, and `reconciles`
# all enumerate captured prompts through parse_blocks, so no reader can see a
# different item set than another.
#
# lavish-axi frames the block in TOON, in two shapes that carry the same rows:
#   tabular  `prompts[N]{uid,prompt,selector,tag,text}:` then N indented CSV rows
#   list     `prompts[N]:` then N `- key: value` items whose scalar fields are the
#            same names, plus optional nested objects (for example `target:`)
# The list shape appears when items carry fields outside a uniform column set
# (a text-range annotation with a `target`). No TOON parser library is available
# to the shell tooling, so both shapes are read here; the scalar fields of each
# item are retained and nested objects are skipped, never mistaken for fields.
#
# A column-zero `prompts`/`feedback` line that matches neither shape is a parse
# failure and is reported through `error`, never as an empty item list, because
# "zero items" would look like "the captain said nothing".
package FmLavishPrompts;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(parse_blocks);

sub _unescape {
  my ($s) = @_;
  $s =~ s/\\(.)/$1 eq "n" ? "\n" : $1 eq "t" ? "\t" : $1 eq "r" ? "\r" : $1/ge;
  return $s;
}

# One CSV row of a tabular block into raw (still escaped) values.
sub _csv_row {
  my ($row) = @_;
  $row =~ s/^\s+//;
  my @vals;
  while (length $row) {
    if ($row =~ s/^"((?:[^"\\]|\\.)*)"//) {
      push @vals, $1;
    } else {
      $row =~ s/^([^,]*)//;
      push @vals, $1;
    }
    last unless $row =~ s/^,//;
  }
  return @vals;
}

# One list-item scalar: JSON-style quoted string or a bare token.
sub _scalar {
  my ($v) = @_;
  $v =~ s/^\s+//;
  $v =~ s/\s+$//;
  return _unescape($1) if $v =~ /^"((?:[^"\\]|\\.)*)"$/;
  return $v;
}

# parse_blocks($path, @names) -> { declared, rows, malformed, error }
# Reads the first top-level block whose name is in @names. `rows` are hashrefs
# of scalar fields; `malformed` counts declared rows that could not be read as
# a full item; `error` is set when a block header is present but unreadable.
sub parse_blocks {
  my ($path, @names) = @_;
  my $alt = join "|", @names;
  open my $fh, "<", $path or return { error => "cannot read $path: $!" };
  my @lines = <$fh>;
  close $fh;
  my %r = (declared => 0, rows => [], malformed => 0, error => undef);
  my $i = 0;
  for (; $i < @lines; $i++) {
    my $line = $lines[$i];
    next unless $line =~ /^(?:$alt)/;
    if ($line =~ /^(?:$alt)\[(\d+)\]\{([^}]*)\}:\s*$/) {
      my ($want, @fields) = ($1, split /,/, $2);
      $r{declared} = $want;
      my $n = 0;
      for (my $j = $i + 1; $j < @lines && $n < $want; $j++, $n++) {
        last unless $lines[$j] =~ /^\s/;
        my $row = $lines[$j];
        chomp $row;
        my @vals = _csv_row($row);
        if (@vals > @fields) {
          my ($p) = grep { $fields[$_] eq "prompt" } 0 .. $#fields;
          ($p) = grep { $fields[$_] eq "text" } 0 .. $#fields unless defined $p;
          if (defined $p) {
            my @parts = splice @vals, $p, @vals - @fields + 1;
            splice @vals, $p, 0, join(",", @parts);
          }
        }
        if (@vals != @fields) { $r{malformed}++; next }
        my %f;
        $f{$fields[$_]} = _unescape($vals[$_]) for 0 .. $#fields;
        push @{ $r{rows} }, \%f;
      }
      return \%r;
    }
    if ($line =~ /^(?:$alt)\[(\d+)\]:\s*$/) {
      $r{declared} = $1;
      my ($dash, $cur);
      for (my $j = $i + 1; $j < @lines; $j++) {
        my $l = $lines[$j];
        chomp $l;
        last unless $l =~ /^\s/;
        if ($l =~ /^(\s*)- (\w+):(?:\s+(.*))?$/ && (!defined $dash || length($1) == $dash)) {
          $dash = length $1;
          push @{ $r{rows} }, ($cur = {});
          $cur->{$2} = defined $3 ? _scalar($3) : "";
          next;
        }
        if (defined $cur && $l =~ /^\s{$dash}  (\w+):(?:\s+(.*))?$/ ) {
          # Scalar field at the item's own field indent. A key with no inline
          # value opens a nested object, whose deeper lines never match here.
          $cur->{$1} = _scalar($2) if defined $2;
          next;
        }
        next if defined $cur && $l =~ /^\s{$dash}    /;
        $r{error} = "unreadable line in $alt list block: $l";
        return \%r;
      }
      $r{malformed} = $r{declared} - @{ $r{rows} } if @{ $r{rows} } < $r{declared};
      return \%r;
    }
    $r{error} = "unrecognized $alt block header: $line";
    chomp $r{error};
    return \%r;
  }
  return \%r;
}

1;
