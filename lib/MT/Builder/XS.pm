package MT::Builder::XS;

use 5.012004;
use strict;
use warnings;
use base 'MT::Builder';
use Encode;

our $VERSION = '0.01';
our $compiler_version = 1.0;

require XSLoader;
XSLoader::load('MT::Builder::XS', $VERSION);

# Preloaded methods go here.


1;
__END__

=head1 NAME

MT::Builder::XS - Perl extension replacing the MT::Builder compiler with XS version

=head1 SYNOPSIS

The following is being done inside MT::Builder:

    my $compiler;
    {
        local $@;
        eval { require MT::Builder::XS; };
        if ((not $@) and ($MT::Builder::XS::compiler_version >= $compiler_version)) {
            $compiler = \&MT::Builder::XS::compiler;
        }
        else {
            $compiler = \&compilerPP;
        }
    }

    ... afterwards ...
    my $tokens = $compiler->($handlers, $modifiers, $ids, $classes, $error, $text, $tmpl);

=head1 DESCRIPTION

A drop-in replacement to the pure-perl compilerPP function inside MT::Builder.
The parameters are:

$handlers - hashref to all the handlers. 
each handler is an array whose second element specify which handler type it is:
function, block or conditional

$modifiers - hashref of all the modifiers. 
The compiler does not care the values, just if a modifier exists

$ids - an empty hashref, will be filled with references to tokens by their ids

$classes - an empty hashref, will be filled with references to tokens by their classes

$error - an empty array ref, if the is an error in templace compilation, it will
be filled with ($pos, $error_message, @params)
You should:

   my $msg = MT->translate($error_message, @params);
   my $line = # calcualte line number from pos
   $msg =~ s/#/$line/;

$text - the template text to compile

$tmpl - the original template object. each token includes a (weak) reference to it.
can be undef.

=head2 EXPORT

None by default.

=head1 SEE ALSO

lib/MT/Builder.pm

=head1 AUTHOR

Shmuel Fomberg, E<lt>sfomberg@sixapart.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012 by Six Apart

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.12.4 or,
at your option, any later version of Perl 5 you may have available.


=cut
