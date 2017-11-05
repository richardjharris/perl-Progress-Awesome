package Progress::Awesome;

use strict;
use warnings;
use Carp qw(croak);
use Devel::GlobalDestruction qw(in_global_destruction);
use Encode qw(encode);
use Time::HiRes qw(time);
use Term::ANSIColor qw(colored);
use Scalar::Util qw(weaken);

use overload
    '++' => \&inc,
    '+=' => \&inc,
    '-=' => \&dec,
    '--' => \&dec;

our $VERSION = '0.1';

if ($Term::ANSIColor::VERSION < 4.06) {
    for my $code (16 .. 255) {
        $Term::ANSIColor::ATTRIBUTES{"ansi$code"}    = "38;5;$code";
        $Term::ANSIColor::ATTRIBUTES{"on_ansi$code"} = "48;5;$code";
    }
}

# Global bar registry for seamless multiple bars at the same time
our %REGISTRY;

# TODO rate calculation should look at sample times, reject those
#      that are too close...
#
# TODO unicode support (grapheme awareness / wide characters)
# TODO colours
# TODO tests
# TODO proper numberformatting, fixed sizes for stuff like ETA
#      e.g. :items should use same space as :count
#           :eta should have a sensible default min width
#           :rate also
#
# Proxy reader:
# my $fh = $bar->proxy($fh);
# # Use $fh normally, bar updates
#
# Multiple bars! Should 'just work' (via behind the scenes magic)
#  - no titles?
#  - work with regular logs
#  - try to sync the log size or bar size somehow
# 
# Rename 'items' to 'total' perhaps, or something else
#
# When decreasing, it might be useful to reverse the rate polarity
# and not 100% the bar the end. How to detect? Maybe just a 'flip' option

my $DEFAULT_TERMINAL_WIDTH = 80;
my %FORMAT_STRINGS = map { $_ => 1 } qw(: bar ts count items max eta rate percent);
my $MAX_SAMPLES = 10;
my @MONTH = qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );

my %STYLES = (
    simple  => \&_style_simple,
    rainbow => \&_style_rainbow,
);

sub new {
    my $class = shift;
    my $self = bless {}, $class;
    
    # Map ctor arguments to hashref
    my $args;
    if (@_ == 1 && ref $_[0] && ref $_[0] eq 'HASH') {
        $args = $_[0];
    }
    elsif (@_ >= 1) {
        my $items = shift;
        $args = { items => $items, @_ };
    }
    
    # Apply defaults
    my %defaults = (
        fh => \*STDERR,
        format => '[:bar] :count/:items :eta :rate',
        log_format => '[:ts] :percent% :count/:items :eta :rate',
        log => 1,
        color => 1,
        remove => 0,
        items => 0,
        title => '',
        count => 0,
        style => 'simple',
    );  
    $args = { %defaults, %$args };

    $self->{fh} = delete $args->{fh};
    
    # Set and validate arguments
    for my $key (qw(items format log_format log color remove title style)) {
        $self->$key(delete $args->{$key}) if exists $args->{$key};
    }

    if (exists $args->{count}) {
        $self->update(delete $args->{count});
    }

    if (keys %$args) {
        croak "Invalid argument: " . join(', ', sort keys %$args);
    }

    # Historic samples uses for rate/ETA calculation
    $self->{_samples} = [];

    _register_bar($self);
    
    # Draw initial bar
    $self->{draw_ok} = 1;
    $self->_redraw;
    
    return $self;
}

sub inc {
    my ($self, $amount) = @_;
    
    @_ == 1 and $amount = 1;
    defined $amount or croak "inc: undefined amount";
    
    $self->{count} += $amount;
    $self->_add_sample;
    $self->_redraw;
}

sub update {
    my ($self, $count) = @_;
    defined $count or croak "update: undefined count";

    $self->{count} = $count;
    $self->_add_sample;
    $self->_redraw;
}

sub dec {
    my ($self, $amount) = @_;

    @_ == 1 and $amount = 1;
    defined $amount or croak "dec undefined amount";

    $self->{count} -= $amount;
    $self->_add_sample;
    $self->_redraw;
}

sub finish {
    my $self = shift;

    if (defined $self->items) {
        # Set the bar to maximum
        $self->update($self->items);
    }
    
    if ($self->remove) {
        # Destroy the bar, assuming nobody has printed anything in the interim
        $self->_wipe_current_line;
    }    

    # TODO self->remove behaviour will change here too
    _unregister_bar($self);
    
}

sub DESTROY {
    my $self = shift;
    if (in_global_destruction) {
        # Unlikely that most method calls will work. The least we can do
        # is move the cursor past our progress bar(s) so the screen is not
        # corrupted.
        if (defined $self && defined $self->{fh}) {
            my $lines = $REGISTRY{$self->{fh}}->{maxbars};
            print {$self->{fh}} "\033[${lines}B";
        }
    }
    else {
        $self->finish;
    }
}

sub items {
    my ($self, $items) = @_;
    @_ == 1 and return $self->{items};
    if (defined $items) {
        $items >= 0 or croak "items: items must be undefined or positive (>=0)";
    }
    $self->{items} = $items;
    $self->_redraw;
}

for my $param (qw(format log_format)) {
    no strict 'refs';
    *{$param} = sub {
        my ($self, $format) = @_;
        @_ == 1 and return $self->{$param};
        $self->{$param} = _check_format($param, $format);
        $self->_redraw;
    };
}

for my $param (qw(log color remove title)) {
    no strict 'refs';
    *{$param} = sub {
        my ($self, $new) = @_;
        @_ == 1 and return $self->{$param};
        $self->{$param} = $new;
        $self->_redraw;
    };
}

sub fh { shift->{fh} }

sub style {
    my ($self, $style) = @_;
    if (@_ != 2 or !defined $style or !(ref $style eq 'CODE' || ref $style eq '')) {
        croak "style usage: style(stylename) or style(coderef)";
    }
    if (!ref $style) {
        if (!exists $STYLES{$style}) {
            croak "style: no such style '$STYLES{$style}'. Valid styles are "
                . join(', ', sort keys %STYLES);
        }
        $style = $STYLES{$style};
    }

    $self->{style} = $style;
    $self->_redraw;
}

sub each_item {
    my ($self, $ref, $sub) = @_;
    my $reftype = ref $ref;
    if ($reftype eq 'ARRAY') {
        $self->items(scalar @$ref);
        for my $item (@$ref) {
            $sub->($item);
            $self->inc;
        }
        $self->finish;
    }
    elsif ($reftype eq 'HASH') {
        $self->items(scalar keys %$ref);
        for my $key (keys %$ref) {
            $sub->($key, $ref->{$key});
            $self->inc;
        }
        $self->finish;
    }
    else {
        croak "each_item: unsupported value (should be arrayref or hashref)";
    }
}

sub each_line {
    my $sub = pop @_;
    my ($self, $file, $extra) = @_;
    defined ref $file or croak "each_line: filename is undefined";
    
    if (ref $file eq '') {
        my $encoding = $extra || ':raw';
    
        # We have a filename
        my $size = -s $file;
        # size will be 0 for /proc/self/fd/XX (e.g. subshell via <(...)) or
        # undefined for STDIN
        $self->items($size) if $size;
        open my $fh, "<$encoding", $file or croak "each_line: unable to open '$file': $!";  
        while (<$fh>) {
            my $line = shift;
            $sub->($line);
            my $pos = tell $fh;
            if ($pos == -1) {
                # STDIN/pipe always returns -1, so this is the best we can do.
                $self->inc(bytes::length($line));
            }
            else {
                # Most other filehandles (including /proc/self/fd...) work fine
                $self->update($pos);
            }
        }
        $self->finish;
        close $file;
    }
    elsif (ref $file eq 'GLOB') {
        # We have a glob
        my $items = $extra;
        $self->items($items);
        while (<$file>) {
            $sub->($_);    
        }
        $self->finish;        
    }
    else {
        croak "each_line: unsupported value (should be filename as scalar, or file handle)";
    }
}

# Draw all progress bars to keep positioning
sub _redraw {
    my $self = shift;
    my $drawn = 0;
    for my $bar (_bars_for($self->{fh})) {
        $drawn += $bar->_redraw_me;
        print {$self->fh} "\n";
    }
    # Move back up
    print {$self->fh} "\033[" . $drawn . "A" if $drawn;
} 

sub _redraw_me {
    my $self = shift;

    # Don't draw while setting arguments in constructor
    return 0 if !$self->{draw_ok};

    my ($max_width, $format, $interval);
    if ($self->_is_interactive) {
        # Drawing a progress bar
        $max_width = $self->_terminal_width;
        $format = $self->format;
    }
    else {
        # Outputting log events
        $format = $self->log_format . "\n";
    }
    
    # Determine draw interval and don't print if recent enough
    # (TODO)
    
    # Draw the components
    $format =~ s/:(\w+)/$self->_redraw_component($1)/ge;

    if (defined $self->{title}) {
        $format = $self->{title} . ": " . $format;
    }
 
    # Work out format length. bar length, and fill in bar
    if ($format =~ /:bar/) {
        my $remaining_space = $max_width - length($format) + length(':bar');
        if ($remaining_space >= 1) {
            my $bar = $self->{style}->($self->_percent, $remaining_space);
            $format =~ s/:bar/$bar/g; 
        }
        else {
            # It's already too big
            $format =~ s/:bar//g;

            # XXX this needs to account for ANSI codes
            if (defined $max_width && length($format) > $max_width) {
                $format = substr($format, 0, $max_width);
            }
        }
    }
    
    # Draw it
    print {$self->fh} $format;
    $self->fh->flush;

    return 1; # indicate we drew the bar
}

sub _style_rainbow {
    my ($percent, $size) = @_;

    my $rainbow = _ansi_rainbow();
    if (!defined $percent) {
        # Render a 100% width gray rainbow instead
        $percent = 100;
        $rainbow = _ansi_holding_pattern();
    }

    my $to_fill = ($size * $percent / 100);
    my $whole_block = encode('UTF-8', chr(0x2588));  # full block
    my $last_block = $percent < 100 ? _last_block_from_rounding($to_fill) : $whole_block;
    $to_fill = int($to_fill);

    # Make the rainbow move too
    my $t = time * 10;

    my $bar = join('', map {
        my $block = $_ == $to_fill ? $last_block : $whole_block;

        colored($block, $rainbow->[($_ + $t) % @$rainbow])
    } (1..$to_fill));

    $bar .= ' ' x ($size - $to_fill);
    return $bar;
}

sub _last_block_from_rounding {
    my $val = shift;
    my $float = $val - int($val);
    return ' ' if $float == 0;

    # Block range is U+2588 (full block) .. U+258F (left one eighth block)
    my $offset = int((1 - $float) * 8);
    return encode('UTF-8', chr(0x2588 + $offset));
}

sub _style_simple {
    my ($percent, $size) = @_;
    my $bar;
    if (defined $percent) {
        my $to_fill = int( $size * $percent / 100 );
        $bar = ('#' x $to_fill) . (' ' x ($size - $to_fill));
    }
    else {
        $bar = '-' x $size;
    }
    return $bar;
}
    
sub _redraw_component {
    my ($self, $field) = @_;

    if ($field eq 'bar') {
        # Skip :bar as this needs to go last
        return ':bar';
    }
    elsif ($field eq ':') {
        # Literal ':'
        return ':';
    }
    elsif ($field eq 'ts') {
        # Emulate the ts(1) tool
        my ($sec, $min, $hour, $day, $month) = gmtime();
        $month = $MONTH[$month] or croak "_redraw_component: unknown month $month ??;";
        return sprintf('%s %02d %02d:%02d:%02d', $month, $day, $hour, $min, $sec);
    }
    elsif ($field eq 'count') {
        return defined $self->{count} ? $self->{count} : '-';
    }
    elsif ($field eq 'items' or $field eq 'max') {
        return defined $self->{items} ? $self->{items} : '-';
    }
    elsif ($field eq 'eta') {
        return $self->_eta;
    }
    elsif ($field eq 'rate') {
        return _human_readable_item_rate($self->_rate);
    }
    elsif ($field eq 'bytes') {
        return _human_readable_byte_rate($self->_rate);
    }
    elsif ($field eq 'percent') {
        my $pc = $self->_percent;
        return defined $pc ? sprintf('%2.1f', $pc) : '-';
    }
    else {
        die "_redraw_component assert failed: invalid field '$field'";
    }
}

sub _wipe_current_line {
    my $self = shift;
    print {$self->fh} "\r", ' ' x $self->_terminal_width, "\r";
}

# Returns terminal width, or a fake value if we can't figure it out
sub _terminal_width {
    my $self = shift;
    return $self->_real_terminal_width || $DEFAULT_TERMINAL_WIDTH;
}

# Returns the width of the terminal (filehandle) in chars, or 0 if it could not be determined
sub _real_terminal_width {
    my $self = shift;
    eval { require Term::ReadKey } or return 0;
    my $result = eval { (Term::ReadKey::GetTerminalSize($self->fh))[0] } || 0;
    if ($result) {
        # This logic is from Term::ProgressBar
        $result-- if $^O eq 'MSWin32' or $^O eq 'cygwin';
    }
    return $result;
}

# Should we display progress bar?
# Display bar if output is a TTY
# XXX could use Term::ReadKey instead (width == 0)
sub _is_interactive {
    my $self = shift;
    return $self->{_is_interactive} if exists $self->{_is_interactive};

    return $self->{_is_interactive} = (-t $self->fh);
}

sub _add_sample {
    my $self = shift;
    my $s = $self->{_samples};
    unshift @$s, [$self->{count}, time];
    pop @$s if @$s > $MAX_SAMPLES;
}

# Return ETA for current progress (actually a duration)
sub _eta {
    my $self = shift;

    # Predict finishing time using current rate
    my $rate = $self->_rate;
    return 'unknown' if !defined $rate or $rate <= 0;

    return 'finished' if $self->{count} >= $self->{items};

    my $duration = ($self->{items} - $self->{count}) / $rate;
    return _human_readable_duration($duration);
}

# Return rate for current progress
sub _rate {
    my $self = shift;
    return if !defined $self->{items};

    my $s = $self->{_samples};
    return if @$s < 2;

    # Work out the last 5 rates and average them
    my ($sum, $count) = (0,0);
    for my $i (0..4) {
        last if $i+1 > $#{$s};

        # Sample is a tuple of [count, time]
        $sum += ($s->[$i][0] - $s->[$i+1][0]) / ($s->[$i][1] - $s->[$i+1][1]);
        $count++;
    }

    return $sum/$count;
}

# Return current percentage complete, or undef if unknown
sub _percent {
    my $self = shift;
    return undef if !defined $self->{count} or !defined $self->{items};
    my $pc = ($self->{count} / $self->{items}) * 100;
    return $pc > 100 ? 100 : $pc;
}

## Utilities

# Check format string to ensure it is valid
sub _check_format {
    my ($param, $format) = @_;
    defined $format or croak "format is undefined";
    
    while ($format =~ /:(\w+)/g) {
        exists $FORMAT_STRINGS{$1} or croak "$param: invalid format string ':$1'";
    }

    return $format;
}

# Convert (positive) duration in seconds to a human-readable string
# e.g. '2 days', '14 hrs', '2 mins'
sub _human_readable_duration {
    my $dur = shift;
    return 'unknown' if !defined $dur;

    my ($val, $unit) = $dur < 60    ? ($dur,         'sec')
                     : $dur < 3600  ? ($dur / 60,    'min')
                     : $dur < 86400 ? ($dur / 3600,  'hr')
                                    : ($dur / 86400, 'day')
                                    ;
    return int($val) . " $unit" . (int($val) == 1 ? '' : 's') . " left";
}

# Convert rate (a number, assumed to be items/second) into a more
# appropriate form
sub _human_readable_item_rate {
    my $rate = shift;
    return 'unknown' if !defined $rate;

    my ($val, $unit) = $rate < 10**3  ? ($rate,          '')
                     : $rate < 10**6  ? ($rate / 10**3,  'K')
                     : $rate < 10**9  ? ($rate / 10**6,  'M')
                     : $rate < 10**12 ? ($rate / 10**9,  'B')
                                      : ($rate / 10**12, 'T')
                                      ;
    return sprintf('%.1f', $val) . "$unit/s";
}

# Convert rate (a number, assumed to be bytes/second) into a more
# appropriate human-readable unit
# e.g. '3 KB/s', '14 MB/s'
sub _human_readable_byte_rate {
    my $rate = shift;
    return 'unknown' if !defined $rate;

    my ($val, $unit) = $rate < 1024     ? ($rate,           'byte')
                     : $rate < 1024**2  ? ($rate / 1024,    'KB')
                     : $rate < 1024**3  ? ($rate / 1024**2, 'MB')
                     : $rate < 1024**4  ? ($rate / 1024**3, 'GB')
                                        : ($rate / 1024**4, 'TB')
                                        ;
    return int($val) . " $unit/s";
}

sub _term_is_256color {
    return $ENV{TERM} eq 'xterm-256color';
}

sub _ansi_rainbow {
    if (_term_is_256color()) {
        return [map { "ansi$_" } (92, 93, 57, 21, 27, 33, 39, 45, 51, 50, 49, 48, 47, 46, 82, 118, 154, 190, 226, 220, 214, 208, 202, 196)];
    }
    else {
        return [qw(magenta blue cyan green yellow red)];
    }

}

sub _ansi_holding_pattern {
    if (_term_is_256color()) {
        return [map { "grey$_" } (0..23), reverse(1..22)];
    }
    else {
        # Use a dotted pattern. XXX Maybe should be related to rate?
        # XXX in genral animating by rate is good for finished bars too
        # XXX rate does not drop to 0 when finished
        return ['black', 'black', 'black', 'black', 'white'];
    }
}

# Multiple bar support
sub _register_bar {
    my $bar = shift;
    my $data = $REGISTRY{$bar->{fh}} ||= {};
    push @{ $data->{bars} ||= [] }, $bar;
    if (!defined $data->{maxbars} or $data->{maxbars} < @{$data->{bars}}) {
        $data->{maxbars} = @{$data->{bars}};
    }
}

sub _unregister_bar {
    my $bar = shift;
    my $data = $REGISTRY{$bar->{fh}};

    @{$data->{bars}} = grep { $_ != $bar } @{$data->{bars}};

    # Are we the last bar? Move the cursor to the bottom of the bars.
    if (@{$data->{bars}} == 0) {
        print {$bar->{fh}} "\033[" . $data->{maxbars} . "B";
    }
}

sub _bars_for {
    my $fh = shift;
    return if !defined $fh;
    return if !exists $REGISTRY{$fh};
    return @{ $REGISTRY{$fh}{bars} || [] };
}

1;

=head1 HEAD

 Progress::Awesome - an awesome progress bar that just works

=head1 SYNOPSIS

 my $p = Progress::Awesome->new({
    items => 100,
    format => '[:bar] :count/:items :eta :rate',
    title => 'Woooop',
 });
 $p->inc;
 $p->update($value);
 $p->finish;

 $p->each_item(\@items, sub { 
	# ...
 });

 # Quicker!
 my $p = Progress::Awesome->new(100);
 for (1..100) {
    do_stuff();
    $p++;
 }

=head1 DESCRIPTION

Similar to the venerable L<Term::ProgressBar> with several enhancements:

=over

=item *

Does the right thing when non-interactive - hides the progress bar and logs
intermittently with timestamps.

=item *

Completes itself when C<finish> is called or it goes out of scope, just in case
you forget.

=item *

Customisable format includes number of items, item processing rate, file transfer
rate (if items=bytes) and ETA. When non-interactive, logging format can also be
customised.

=item *

Gets out of your way - won't noisily complain if it can't work out the terminal
size, and won't die if you set the progress bar to its max value when it's already
reached the max (or for any other reason).

=item *

Can be incremented using C<++> or C<+=> if you like.

=item *

Handy C<each_item> and C<each_line> functions loop through items/filehandles while
updating progress.

=item *

Works fine if max is undefined, set halfway through, or updated halfway through.

=item *

Estimates ETA with more intelligent prediction than simple linear.

=item *

Colours!!

=item *

Multiple process bars at once 'just works'.

=back

=head1 METHODS

=head2 new ( items, %args )

=head2 new ( \%args )

Create a new progress bar. It is convenient to pass the number of items and any
optional arguments, although you may also be explicit and pass a hashref.

XXX not sure about this!

=over

=item items (optional)

Number of items in the progress bar.

=item format (default: '[:bar] :count/:items :eta :rate')

Specify a format for the progress bar (see L<FORMATS> below). The C<:bar> part will fill to
all available space.

=item style (optional)

Specify the bar style. This may be a string ('rainbow' or 'boring') or a function
that accepts the percentage and size of the bar (in chars) and returns ANSI data
for the bar.

=item title (optional)

Optional bar title.

=item log_format (default: '[:ts] :percent% :count/:items :eta :rate')

Specify a format for log output used when the script is run non-interactively.

=item log (default: 1)

If set to 0, don't log anything when run non-interactively.

=item color (default: 1)

If set to 0, suppress colors when rendering the progress bar.

=item remove (default: 0)

If set to 1, remove the progress bar after completion via C<finish>.

=item fh (default: \*STDERR)

The filehandle to output to.

=item count (default: 0)

Starting count.

=back

=head2 update ( value )

Update the progress bar to the specified value. If undefined, the progress bar will go into
a spinning/unknown state.

=head2 inc ( [value] )

Increment progress bar by this many items, or 1 if omitted.

=head2 finish

Set the progress bar to maximum. Any further updates will not take effect. Happens automatically
when the progress bar goes out of scope.

=head2 items ( [VALUE] )

Updates the number of items for the progress bar. May be set to undef if unknown. With zero
arguments, returns the number of items.

=head2 dec ( value )

Decrement the progress bar (if needed).

=head2 each_item ( ref, function )

Calls C<function> for each item in C<ref>. The function will be passed each item (if an array ref)
or each key and value (if a hash ref). The progress bar will be updated to reflect the progress
as each item's callback is executed.

=head2 each_line ( filename, [encoding], function )

=head2 each_line ( filehandle, [items], function )

Calls C<function> for each line in the given file. If the first argument is a filename, the progress bar
will automatically update as the file is traversed (like the C<pv(1)> tool) based on the byte count.
If the first argument is a filehandle, only rate and items processed can be shown unless C<items> is
also defined.

=head1 FORMATS

Blah

=head1 REPORTING BUGS

TBD

=head1 AUTHOR

Richard Harris richardjharris@gmail.com

=head1 COPYRIGHT

Copyright (c) 2017 Richard Harris.  This program is
free software; you can redistribute it and/or modify it under the same terms
as Perl itself.

=cut

__END__
