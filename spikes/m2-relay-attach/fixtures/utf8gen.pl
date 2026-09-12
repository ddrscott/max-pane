#!/usr/bin/perl
# Emits a deterministic multi-byte UTF-8 stream and writes the identical bytes to a
# file, so a client can prove byte-exactness across frame boundaries.
# usage: utf8gen.pl <ground-truth-file> <lines>
use strict; use warnings;
binmode(STDOUT, ":raw");
my ($path, $lines) = (@ARGV);
$lines ||= 4000;
open(my $fh, ">:raw", $path) or die $!;
$| = 1;
my @glyph = ("\x{250c}\x{2500}\x{2510}", "\x{65e5}\x{672c}\x{8a9e}", "\x{1F600}",
             "caf\x{e9}", "\x{3b1}\x{3b2}\x{3b3}", "\x{2502}\x{2588}\x{2591}",
             "\x{d55c}\x{ad6d}\x{c5b4}", "\x{1F680}\x{1F6E0}");
for my $i (1 .. $lines) {
    my $s = sprintf("L%06d ", $i);
    $s .= join(" ", map { $glyph[($i * 7 + $_) % scalar @glyph] } 0 .. 5);
    $s .= "\n";
    utf8::encode($s) if utf8::is_utf8($s);
    print $s;
    print $fh $s;
}
close($fh);
select(undef, undef, undef, 86400) while 1;
