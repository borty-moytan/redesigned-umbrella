#!/usr/bin/env perl
# Backup JSON implementation using JSON::PP (core Perl module on modern Perl).
use strict;
use warnings;
use JSON::PP;
use File::Basename qw(dirname);
use File::Temp qw(tempfile);

sub fail { my ($m, $code) = @_; print STDERR "f_json: $m\n"; exit($code // 2); }
my @args = @ARGV;
my $source = '-';
if (@args && ($args[0] eq '-' || -f $args[0] || $args[0] =~ m{/} || $args[0] =~ /\.json\z/)) { $source = shift @args; }
my $mode = 'get'; my ($path, $raw);
if (@args == 1 && index($args[0], '=') >= 0) {
  ($path, $raw) = split(/=/, $args[0], 2); $mode = 'set';
} elsif (@args == 1) { $path = $args[0]; }
elsif (@args >= 3 && $args[1] eq '=') { $path = shift @args; shift @args; $raw = join(' ', @args); $mode = 'set'; }
elsif (@args) { fail('expected DOTTED.PATH, DOTTED.PATH=VALUE, or DOTTED.PATH = VALUE'); }
my $raw_json;
if ($source eq '-' && -t STDIN) { fail('no JSON input provided; pass a filename or pipe JSON into f_json'); }
if ($source eq '-') { local $/; $raw_json = <STDIN>; }
else { open my $fh, '<:encoding(UTF-8)', $source or fail("cannot read '$source': $!", 1); local $/; $raw_json = <$fh>; close $fh; }
my $json = JSON::PP->new->utf8(0)->allow_nonref(1);
my $data = eval { $json->decode($raw_json) };
if ($@) { my $e = $@; $e =~ s/\s+\z//; fail("invalid JSON: $e", 1); }
sub walk_get {
  my ($obj, $p) = @_;
  for my $key (split(/\./, $p, -1)) {
    if (ref($obj) eq 'HASH' && exists $obj->{$key}) { $obj = $obj->{$key}; }
    elsif (ref($obj) eq 'ARRAY' && $key =~ /^\d+$/ && $key < @$obj) { $obj = $obj->[$key]; }
    else { fail("key path '$p' does not exist (missing '$key')", 1); }
  }
  return $obj;
}
sub set_path {
  my ($obj, $p, $val) = @_;
  fail('setting a dotted path requires the JSON root to be an object', 1) unless ref($obj) eq 'HASH';
  my @parts = split(/\./, $p, -1); fail('dotted paths cannot contain empty key segments') if grep { $_ eq '' } @parts;
  for (my $i = 0; $i < $#parts; $i++) {
    my $key = $parts[$i];
    if (ref($obj->{$key}) ne 'HASH') { $obj->{$key} = {}; }
    $obj = $obj->{$key};
  }
  $obj->{$parts[-1]} = $val;
}
sub parse_val {
  my ($s) = @_;
  my $v = eval { $json->decode($s) };
  return $v unless $@;
  return $s;
}
sub output_val {
  my ($v) = @_;
  if (!defined $v) { print "null\n"; }
  elsif (ref($v)) { print JSON::PP->new->canonical(1)->pretty(1)->encode($v); }
  elsif ($v eq '1' || $v eq '0') { print $v, "\n"; }
  else { print $v, "\n"; }
}
if ($mode eq 'set') {
  fail("a dotted path is required before '='") unless defined($path) && length($path);
  set_path($data, $path, parse_val($raw));
  if ($source eq '-') { print JSON::PP->new->canonical(1)->pretty(1)->encode($data); exit 0; }
  my $dir = dirname($source);
  my ($tmp, $tempname) = tempfile('.f-json-XXXXXX', DIR => $dir, UNLINK => 0);
  my @old_stat = stat($source); chmod($old_stat[2] & 07777, $tempname) if @old_stat;
  print {$tmp} JSON::PP->new->canonical(1)->pretty(1)->encode($data) or fail("cannot write temporary file: $!", 1);
  close $tmp or fail("cannot close temporary file: $!", 1);
  rename($tempname, $source) or do { unlink $tempname; fail("cannot update '$source': $!", 1); };
  output_val(walk_get($data, $path));
} elsif (defined $path) { output_val(walk_get($data, $path)); }
else { print JSON::PP->new->canonical(1)->pretty(1)->encode($data); }
