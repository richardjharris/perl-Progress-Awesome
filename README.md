# HEAD

    Progress::Awesome - an awesome progress bar that just works
    
![Animated gif of progress bar in action](https://i.imgur.com/g2MeL7q.gif)

# SYNOPSIS

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

# DESCRIPTION

Similar to the venerable [Term::ProgressBar](https://metacpan.org/pod/Term::ProgressBar) with several enhancements:

- Does the right thing when non-interactive - hides the progress bar and logs
intermittently with timestamps.
- Completes itself when `finish` is called or it goes out of scope, just in case
you forget.
- Customisable format includes number of items, item processing rate, file transfer
rate (if items=bytes) and ETA. When non-interactive, logging format can also be
customised.
- Gets out of your way - won't noisily complain if it can't work out the terminal
size, and won't die if you set the progress bar to its max value when it's already
reached the max (or for any other reason).
- Can be incremented using `++` or `+=` if you like.
- Handy `each_item` and `each_line` functions loop through items/filehandles while
updating progress.
- Works fine if max is undefined, set halfway through, or updated halfway through.
- Estimates ETA with more intelligent prediction than simple linear.
- Colours!!
- Multiple process bars at once 'just works'.

# METHODS

## new ( items, %args )

## new ( \\%args )

Create a new progress bar. It is convenient to pass the number of items and any
optional arguments, although you may also be explicit and pass a hashref.

XXX not sure about this!

- items (optional)

    Number of items in the progress bar.

- format (default: '\[:bar\] :count/:items :eta :rate')

    Specify a format for the progress bar (see [FORMATS](https://metacpan.org/pod/FORMATS) below). The `:bar` part will fill to
    all available space.

- style (optional)

    Specify the bar style. This may be a string ('rainbow' or 'boring') or a function
    that accepts the percentage and size of the bar (in chars) and returns ANSI data
    for the bar.

- title (optional)

    Optional bar title.

- log\_format (default: '\[:ts\] :percent% :count/:items :eta :rate')

    Specify a format for log output used when the script is run non-interactively.

- log (default: 1)

    If set to 0, don't log anything when run non-interactively.

- color (default: 1)

    If set to 0, suppress colors when rendering the progress bar.

- remove (default: 0)

    If set to 1, remove the progress bar after completion via `finish`.

- fh (default: \\\*STDERR)

    The filehandle to output to.

- count (default: 0)

    Starting count.

## update ( value )

Update the progress bar to the specified value. If undefined, the progress bar will go into
a spinning/unknown state.

## inc ( \[value\] )

Increment progress bar by this many items, or 1 if omitted.

## finish

Set the progress bar to maximum. Any further updates will not take effect. Happens automatically
when the progress bar goes out of scope.

## items ( \[VALUE\] )

Updates the number of items for the progress bar. May be set to undef if unknown. With zero
arguments, returns the number of items.

## dec ( value )

Decrement the progress bar (if needed).

## each\_item ( ref, function )

Calls `function` for each item in `ref`. The function will be passed each item (if an array ref)
or each key and value (if a hash ref). The progress bar will be updated to reflect the progress
as each item's callback is executed.

## each\_line ( filename, \[encoding\], function )

## each\_line ( filehandle, \[items\], function )

Calls `function` for each line in the given file. If the first argument is a filename, the progress bar
will automatically update as the file is traversed (like the `pv(1)` tool) based on the byte count.
If the first argument is a filehandle, only rate and items processed can be shown unless `items` is
also defined.

# FORMATS

Blah

# REPORTING BUGS

TBD

# AUTHOR

Richard Harris richardjharris@gmail.com

# COPYRIGHT

Copyright (c) 2017 Richard Harris.  This program is
free software; you can redistribute it and/or modify it under the same terms
as Perl itself.
