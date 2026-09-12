#!/usr/bin/perl
# Synthetic output generator with a monotonic sequence number per line, so a
# client can detect frames dropped by the 256-frame broadcast channel (Lagged).
# usage: gen.pl <lines-per-second> <total-lines or 0 for endless>
$| = 1;
my $rate  = defined $ARGV[0] ? $ARGV[0] + 0 : 100;
my $total = defined $ARGV[1] ? $ARGV[1] : 0;
my @w = qw(alpha bravo charlie delta echo foxtrot golf hotel india juliet
           kilo lima mike november oscar papa quebec romeo sierra tango);
my $n = 0;
my $flat  = ($rate <= 0);
my $batch = $flat ? 1000 : ($rate > 50 ? int($rate / 50) : 1);
$batch = 1 if $batch < 1;
my $sleep = $flat ? 0 : $batch / $rate;
while (1) {
    for (1 .. $batch) {
        $n++;
        my $body = join(" ", map { $w[int(rand(scalar @w))] } 1 .. 6);
        printf("\033[36mSEQ\033[0m %08d %s %04x\n", $n, $body, int(rand(65536)));
        if ($total && $n >= $total) { select(undef,undef,undef,86400) while 1; }
    }
    select(undef, undef, undef, $sleep) unless $flat;
}
