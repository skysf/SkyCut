# Swift source as code only, for scan guards that may count executable code and nothing else
# (checks/audio-engine-idle-wiring.sh section 11, checks/app-update-wiring.sh section 10; review CXC2, 2026-11-27).
# swift_code($text) returns the text with comments and string literals blanked out to spaces. Newlines are kept, so offsets
# and line numbers stay right. It reads left to right, so a `//` inside a string, or a `/*` or a quote inside a line comment,
# is not taken for what it looks like.
# Approximate, not a Swift lexer: raw strings (#"…"#), nested block comments and string interpolation that holds a quote
# are not modelled. Used with `require "./checks/Shared/swift-code.pl"` from the repository root.
use strict;
use warnings;

sub swift_code {
    my ($text) = @_;
    my $out = '';
    pos($text) = 0;
    while (pos($text) < length $text) {
        if ($text =~ /\G("""(?s:.)*?""")/gc
            || $text =~ /\G("(?:[^"\\\n]|\\.)*")/gc
            || $text =~ m{\G(/\*(?s:.)*?\*/)}gc
            || $text =~ m{\G(//[^\n]*)}gc) {
            (my $blank = $1) =~ s/[^\n]/ /g;
            $out .= $blank;
        } elsif ($text =~ m{\G([^"/]+|(?s:.))}gc) {
            $out .= $1;
        }
    }
    return $out;
}

1;
