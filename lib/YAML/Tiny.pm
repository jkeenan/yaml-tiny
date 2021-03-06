package YAML::Tiny;
use 5.008001; # sane UTF-8 support
use strict;
use warnings;

use Exporter;
our @ISA       = qw{ Exporter  };
our @EXPORT    = qw{ Load Dump };
our @EXPORT_OK = qw{ LoadFile DumpFile freeze thaw };

# XXX Use to detect nv or iv for now. Find something better (Ingy).
use Data::Dumper;

# Error storage
our $errstr    = '';

# Some platforms can't flock :-(
my $HAS_FLOCK;
sub _can_flock {
    if ( defined $HAS_FLOCK ) {
        return $HAS_FLOCK;
    }
    else {
        require Config;
        my $c = \%Config::Config;
        $HAS_FLOCK = grep { $c->{$_} } qw/d_flock d_fcntl_can_lock d_lockf/;
        require Fcntl if $HAS_FLOCK;
        return $HAS_FLOCK;
    }
}

# The character class of all characters we need to escape
# NOTE: Inlined, since it's only used once
# my $RE_ESCAPE = '[\\x00-\\x08\\x0b-\\x0d\\x0e-\\x1f\"\n]';

# Printed form of the unprintable characters in the lowest range
# of ASCII characters, listed by ASCII ordinal position.
my @UNPRINTABLE = qw(
    0    x01  x02  x03  x04  x05  x06  a
    b    t    n    v    f    r    x0E  x0F
    x10  x11  x12  x13  x14  x15  x16  x17
    x18  x19  x1A  e    x1C  x1D  x1E  x1F
);

# Printable characters for escapes
my %UNESCAPES = (
    0 => "\x00", z => "\x00", N    => "\x85",
    a => "\x07", b => "\x08", t    => "\x09",
    n => "\x0a", v => "\x0b", f    => "\x0c",
    r => "\x0d", e => "\x1b", '\\' => '\\',
);

# Special magic boolean words
my %QUOTE = map { $_ => 1 } qw{
    null true false
};

my %RE = (
    # The commented out form is simpler, but overloaded the Perl regex
    # engine due to recursion and backtracking problems on strings
    # larger than 32,000ish characters. Keep it for reference purposes.
    # qr/\"((?:\\.|[^\"])*)\"/
    capture_double_quoted   => qr/\"([^\\"]*(?:\\.[^\\"]*)*)\"/,
    capture_single_quoted   => qr/\'([^\']*(?:\'\'[^\']*)*)\'/,
    capture_unquoted_key    => qr/(.*?)(?=\s*\:(?:\s+|$))/,
    trailing_comment        => qr/(?:\s+\#.*)?/,
    key_value_separator     => qr/\s*:(?:\s+(?:\#.*)?|$)/,
);

#####################################################################
# Implementation

# Create an empty YAML::Tiny object
sub new {
    my $class = shift;
    bless [ @_ ], $class;
}

# Return all documents
sub documents { return @{$_[0]} }

# Create an object from a file
sub read {
    my $class = ref $_[0] ? ref shift : shift;

    # Check the file
    my $file = shift or return $class->_error( 'You did not specify a file name' );
    return $class->_error( "File '$file' does not exist" )              unless -e $file;
    return $class->_error( "'$file' is a directory, not a file" )       unless -f _;
    return $class->_error( "Insufficient permissions to read '$file'" ) unless -r _;

    # Open unbuffered with strict UTF-8 decoding and no translation layers
    open( my $fh, "<:unix:encoding(UTF-8)", $file );
    unless ( $fh ) {
        return $class->_error("Failed to open file '$file': $!");
    }

    # flock if available (or warn if not possible for OS-specific reasons)
    if ( _can_flock ) {
        flock( $fh, Fcntl::LOCK_SH() )
            or warn "Couldn't lock '$file' for reading: $!";
    }

    # slurp the contents
    my $contents = eval {
        use warnings FATAL => 'utf8';
        local $/;
        <$fh>
    };
    if ( my $err = $@ ) {
        return $class->_error("Error reading from file '$file': $err");
    }

    # close the file (release the lock)
    unless ( close $fh ) {
        return $class->_error("Failed to close file '$file': $!");
    }

    $class->read_string( $contents );
}

# Create an object from a string
sub read_string {
    my $class  = ref $_[0] ? ref shift : shift;
    my $self   = bless [], $class;
    my $string = $_[0];
    eval {
        unless ( defined $string ) {
            die \"Did not provide a string to load";
        }

        # Check if Perl has it marked as characters, but it's internally
        # inconsistent.  E.g. maybe latin1 got read on a :utf8 layer
        if ( utf8::is_utf8($string) && ! utf8::valid($string) ) {
            die \(
                'Read an invalid UTF-8 string (maybe mixed UTF-8 and 8-bit character set).'
                . 'Did you decode with lax ":utf8" instead of strict ":encoding(UTF-8)"?' );
        }

        # Ensure Unicode character semantics, even for 0x80-0xff
        utf8::upgrade($string);

        # Check for and strip any leading UTF-8 BOM
        $string =~ s/^\x{FEFF}//;

        # Check for some special cases
        return $self unless length $string;

        # Split the file into lines
        my @lines = grep { ! /^\s*(?:\#.*)?\z/ }
                split /(?:\015{1,2}\012|\015|\012)/, $string;

        # Strip the initial YAML header
        @lines and $lines[0] =~ /^\%YAML[: ][\d\.]+.*\z/ and shift @lines;

        # A nibbling parser
        my $in_document = 0;
        while ( @lines ) {
            # Do we have a document header?
            if ( $lines[0] =~ /^---\s*(?:(.+)\s*)?\z/ ) {
                # Handle scalar documents
                shift @lines;
                if ( defined $1 and $1 !~ /^(?:\#.+|\%YAML[: ][\d\.]+)\z/ ) {
                    push @$self, $self->_read_scalar( "$1", [ undef ], \@lines );
                    next;
                }
                $in_document = 1;
            }

            if ( ! @lines or $lines[0] =~ /^(?:---|\.\.\.)/ ) {
                # A naked document
                push @$self, undef;
                while ( @lines and $lines[0] !~ /^---/ ) {
                    shift @lines;
                }
                $in_document = 0;

            # XXX The final '-+$' is to look for -- which ends up being an
            # error later.
            } elsif ( ! $in_document && @$self ) {
                # only the first document can be explicit
                die \"YAML::Tiny failed to classify the line '$lines[0]'";
            } elsif ( $lines[0] =~ /^\s*\-(?:\s|$|-+$)/ ) {
                # An array at the root
                my $document = [ ];
                push @$self, $document;
                $self->_read_array( $document, [ 0 ], \@lines );

            } elsif ( $lines[0] =~ /^(\s*)\S/ ) {
                # A hash at the root
                my $document = { };
                push @$self, $document;
                $self->_read_hash( $document, [ length($1) ], \@lines );

            } else {
                # Shouldn't get here.  @lines have whitespace-only lines
                # stripped, and previous match is a line with any
                # non-whitespace.  So this clause should only be reachable via
                # a perlbug where \s is not symmetric with \S

                # uncoverable statement
                die \"YAML::Tiny failed to classify the line '$lines[0]'";
            }
        }
    };
    if ( ref $@ eq 'SCALAR' ) {
        return $self->_error(${$@});
    } elsif ( $@ ) {
        $self->_error($@);
    }

    return $self;
}

sub _unquote_single {
    my ($self, $string) = @_;
    return '' unless length $string;
    $string =~ s/\'\'/\'/g;
    return $string;
}

sub _unquote_double {
    my ($self, $string) = @_;
    return '' unless length $string;
    $string =~ s/\\"/"/g;
    $string =~ s/\\([Nnever\\fartz0b]|x([0-9a-fA-F]{2}))/(length($1)>1)?pack("H2",$2):$UNESCAPES{$1}/gex;
    return $string;
}

# Deparse a scalar string to the actual scalar
sub _read_scalar {
    my ($self, $string, $indent, $lines) = @_;

    # Trim trailing whitespace
    $string =~ s/\s*\z//;

    # Explitic null/undef
    return undef if $string eq '~';

    # Single quote
    if ( $string =~ /^$RE{capture_single_quoted}$RE{trailing_comment}\z/ ) {
        return $self->_unquote_single($1);
    }

    # Double quote.
    if ( $string =~ /^$RE{capture_double_quoted}$RE{trailing_comment}\z/ ) {
        return $self->_unquote_double($1);
    }

    # Special cases
    if ( $string =~ /^[\'\"!&]/ ) {
        die \"YAML::Tiny does not support a feature in line '$string'";
    }
    return {} if $string =~ /^{}(?:\s+\#.*)?\z/;
    return [] if $string =~ /^\[\](?:\s+\#.*)?\z/;

    # Regular unquoted string
    if ( $string !~ /^[>|]/ ) {
        if (
            $string =~ /^(?:-(?:\s|$)|[\@\%\`])/
            or
            $string =~ /:(?:\s|$)/
        ) {
            die \"YAML::Tiny found illegal characters in plain scalar: '$string'";
        }
        $string =~ s/\s+#.*\z//;
        return $string;
    }

    # Error
    die \"YAML::Tiny failed to find multi-line scalar content" unless @$lines;

    # Check the indent depth
    $lines->[0]   =~ /^(\s*)/;
    $indent->[-1] = length("$1");
    if ( defined $indent->[-2] and $indent->[-1] <= $indent->[-2] ) {
        die \"YAML::Tiny found bad indenting in line '$lines->[0]'";
    }

    # Pull the lines
    my @multiline = ();
    while ( @$lines ) {
        $lines->[0] =~ /^(\s*)/;
        last unless length($1) >= $indent->[-1];
        push @multiline, substr(shift(@$lines), length($1));
    }

    my $j = (substr($string, 0, 1) eq '>') ? ' ' : "\n";
    my $t = (substr($string, 1, 1) eq '-') ? ''  : "\n";
    return join( $j, @multiline ) . $t;
}

# Parse an array
sub _read_array {
    my ($self, $array, $indent, $lines) = @_;

    while ( @$lines ) {
        # Check for a new document
        if ( $lines->[0] =~ /^(?:---|\.\.\.)/ ) {
            while ( @$lines and $lines->[0] !~ /^---/ ) {
                shift @$lines;
            }
            return 1;
        }

        # Check the indent level
        $lines->[0] =~ /^(\s*)/;
        if ( length($1) < $indent->[-1] ) {
            return 1;
        } elsif ( length($1) > $indent->[-1] ) {
            die \"YAML::Tiny found bad indenting in line '$lines->[0]'";
        }

        if ( $lines->[0] =~ /^(\s*\-\s+)[^\'\"]\S*\s*:(?:\s+|$)/ ) {
            # Inline nested hash
            my $indent2 = length("$1");
            $lines->[0] =~ s/-/ /;
            push @$array, { };
            $self->_read_hash( $array->[-1], [ @$indent, $indent2 ], $lines );

        } elsif ( $lines->[0] =~ /^\s*\-\s*\z/ ) {
            shift @$lines;
            unless ( @$lines ) {
                push @$array, undef;
                return 1;
            }
            if ( $lines->[0] =~ /^(\s*)\-/ ) {
                my $indent2 = length("$1");
                if ( $indent->[-1] == $indent2 ) {
                    # Null array entry
                    push @$array, undef;
                } else {
                    # Naked indenter
                    push @$array, [ ];
                    $self->_read_array( $array->[-1], [ @$indent, $indent2 ], $lines );
                }

            } elsif ( $lines->[0] =~ /^(\s*)\S/ ) {
                push @$array, { };
                $self->_read_hash( $array->[-1], [ @$indent, length("$1") ], $lines );

            } else {
                die \"YAML::Tiny failed to classify line '$lines->[0]'";
            }

        } elsif ( $lines->[0] =~ /^\s*\-(\s*)(.+?)\s*\z/ ) {
            # Array entry with a value
            shift @$lines;
            push @$array, $self->_read_scalar( "$2", [ @$indent, undef ], $lines );

        } elsif ( defined $indent->[-2] and $indent->[-1] == $indent->[-2] ) {
            # This is probably a structure like the following...
            # ---
            # foo:
            # - list
            # bar: value
            #
            # ... so lets return and let the hash parser handle it
            return 1;

        } else {
            die \"YAML::Tiny failed to classify line '$lines->[0]'";
        }
    }

    return 1;
}

# Parse a hash
sub _read_hash {
    my ($self, $hash, $indent, $lines) = @_;

    while ( @$lines ) {
        # Check for a new document
        if ( $lines->[0] =~ /^(?:---|\.\.\.)/ ) {
            while ( @$lines and $lines->[0] !~ /^---/ ) {
                shift @$lines;
            }
            return 1;
        }

        # Check the indent level
        $lines->[0] =~ /^(\s*)/;
        if ( length($1) < $indent->[-1] ) {
            return 1;
        } elsif ( length($1) > $indent->[-1] ) {
            die \"YAML::Tiny found bad indenting in line '$lines->[0]'";
        }

        # Find the key
        my $key;

        # Quoted keys
        if ( $lines->[0] =~ s/^\s*$RE{capture_single_quoted}$RE{key_value_separator}// ) {
            $key = $self->_unquote_single($1);
        }
        elsif ( $lines->[0] =~ s/^\s*$RE{capture_double_quoted}$RE{key_value_separator}// ) {
            $key = $self->_unquote_double($1);
        }
        elsif ( $lines->[0] =~ s/^\s*$RE{capture_unquoted_key}$RE{key_value_separator}// ) {
            $key = $1;
        }
        elsif ( $lines->[0] =~ /^\s*\?/ ) {
            die \"YAML::Tiny does not support a feature in line '$lines->[0]'";
        }
        else {
            die \"YAML::Tiny failed to classify line '$lines->[0]'";
        }

        # Do we have a value?
        if ( length $lines->[0] ) {
            # Yes
            $hash->{$key} = $self->_read_scalar( shift(@$lines), [ @$indent, undef ], $lines );
        } else {
            # An indent
            shift @$lines;
            unless ( @$lines ) {
                $hash->{$key} = undef;
                return 1;
            }
            if ( $lines->[0] =~ /^(\s*)-/ ) {
                $hash->{$key} = [];
                $self->_read_array( $hash->{$key}, [ @$indent, length($1) ], $lines );
            } elsif ( $lines->[0] =~ /^(\s*)./ ) {
                my $indent2 = length("$1");
                if ( $indent->[-1] >= $indent2 ) {
                    # Null hash entry
                    $hash->{$key} = undef;
                } else {
                    $hash->{$key} = {};
                    $self->_read_hash( $hash->{$key}, [ @$indent, length($1) ], $lines );
                }
            }
        }
    }

    return 1;
}

# Save an object to a file
sub write {
    my $self = shift;

    require Fcntl;

    # Check the file
    my $file = shift or return $self->_error( 'You did not specify a file name' );

    my $fh;
    # flock if available (or warn if not possible for OS-specific reasons)
    if ( _can_flock ) {
        # Open without truncation (truncate comes after lock)
        my $flags = Fcntl::O_WRONLY()|Fcntl::O_CREAT();
        sysopen( $fh, $file, $flags );
        unless ( $fh ) {
            return $self->_error("Failed to open file '$file' for writing: $!");
        }

        # Use no translation and strict UTF-8
        binmode( $fh, ":raw:encoding(UTF-8)");

        flock( $fh, Fcntl::LOCK_EX() )
            or warn "Couldn't lock '$file' for reading: $!";

        # truncate and spew contents
        truncate $fh, 0;
        seek $fh, 0, 0;
    }
    else {
        open $fh, ">:unix:encoding(UTF-8)", $file;
    }

    # serialize and spew to the handle
    print {$fh} $self->write_string;

    # close the file (release the lock)
    unless ( close $fh ) {
        return $self->_error("Failed to close file '$file': $!");
    }

    return 1;
}

# Save an object to a string
sub write_string {
    my $self = shift;
    return '' unless ref $self && @$self;

    local $Data::Dumper::Terse = 1;

    # Iterate over the documents
    my $indent = 0;
    my @lines  = ();

    eval {
        foreach my $cursor ( @$self ) {
            push @lines, '---';

            # An empty document
            if ( ! defined $cursor ) {
                # Do nothing

            # A scalar document
            } elsif ( ! ref $cursor ) {
                $lines[-1] .= ' ' . $self->_write_scalar( $cursor, $indent );

            # A list at the root
            } elsif ( ref $cursor eq 'ARRAY' ) {
                unless ( @$cursor ) {
                    $lines[-1] .= ' []';
                    next;
                }
                push @lines, $self->_write_array( $cursor, $indent, {} );

            # A hash at the root
            } elsif ( ref $cursor eq 'HASH' ) {
                unless ( %$cursor ) {
                    $lines[-1] .= ' {}';
                    next;
                }
                push @lines, $self->_write_hash( $cursor, $indent, {} );

            } else {
                die \("Cannot serialize " . ref($cursor));
            }
        }
    };
    if ( ref $@ eq 'SCALAR' ) {
        return $self->_error(${$@});
    } elsif ( $@ ) {
        $self->_error($@);
    }

    join '', map { "$_\n" } @lines;
}

# use XXX -with => 'YAML::XS';
sub _write_scalar {
    my $string = $_[1];
    return '~'  unless defined $string;
    return "''" unless length  $string;
    if (Scalar::Util::looks_like_number($string)) {
        $string = Data::Dumper::Dumper($string);
        chomp $string;
        return $string;
    }
    if ( $string =~ /[\x00-\x09\x0b-\x0d\x0e-\x1f\x7f-\x9f\'\n]/ ) {
        $string =~ s/\\/\\\\/g;
        $string =~ s/"/\\"/g;
        $string =~ s/\n/\\n/g;
        $string =~ s/[\x85]/\\N/g;
        $string =~ s/([\x00-\x1f])/\\$UNPRINTABLE[ord($1)]/g;
        $string =~ s/([\x7f-\x9f])/'\x' . uc(unpack "H*", $1)/ge;
        return qq|"$string"|;
    }
    if ( $string =~ /(?:^[~!@#%&*|>?:,'"`{}\[\]]|^-+$|\s|:\z)/ or $QUOTE{$string} ) {
        return "'$string'";
    }
    return $string;
}

sub _write_array {
    my ($self, $array, $indent, $seen) = @_;
    if ( $seen->{refaddr($array)}++ ) {
        die \"YAML::Tiny does not support circular references";
    }
    my @lines  = ();
    foreach my $el ( @$array ) {
        my $line = ('  ' x $indent) . '-';
        my $type = ref $el;
        if ( ! $type ) {
            $line .= ' ' . $self->_write_scalar( $el, $indent + 1 );
            push @lines, $line;

        } elsif ( $type eq 'ARRAY' ) {
            if ( @$el ) {
                push @lines, $line;
                push @lines, $self->_write_array( $el, $indent + 1, $seen );
            } else {
                $line .= ' []';
                push @lines, $line;
            }

        } elsif ( $type eq 'HASH' ) {
            if ( keys %$el ) {
                push @lines, $line;
                push @lines, $self->_write_hash( $el, $indent + 1, $seen );
            } else {
                $line .= ' {}';
                push @lines, $line;
            }

        } else {
            die \"YAML::Tiny does not support $type references";
        }
    }

    @lines;
}

sub _write_hash {
    my ($self, $hash, $indent, $seen) = @_;
    if ( $seen->{refaddr($hash)}++ ) {
        die \"YAML::Tiny does not support circular references";
    }
    my @lines  = ();
    foreach my $name ( sort keys %$hash ) {
        my $el   = $hash->{$name};
        my $line = ('  ' x $indent) . $self->_write_scalar($name) . ":";
        my $type = ref $el;
        if ( ! $type ) {
            $line .= ' ' . $self->_write_scalar( $el, $indent + 1 );
            push @lines, $line;

        } elsif ( $type eq 'ARRAY' ) {
            if ( @$el ) {
                push @lines, $line;
                push @lines, $self->_write_array( $el, $indent + 1, $seen );
            } else {
                $line .= ' []';
                push @lines, $line;
            }

        } elsif ( $type eq 'HASH' ) {
            if ( keys %$el ) {
                push @lines, $line;
                push @lines, $self->_write_hash( $el, $indent + 1, $seen );
            } else {
                $line .= ' {}';
                push @lines, $line;
            }

        } else {
            die \"YAML::Tiny does not support $type references";
        }
    }

    @lines;
}

# Set error
sub _error {
    $errstr = $_[1];
    $errstr =~ s/ at \S+ line \d+.*//;
    undef;
}

# Retrieve error
sub errstr {
    $errstr;
}





#####################################################################
# YAML Compatibility

sub Dump {
    my $string = YAML::Tiny->new(@_)->write_string;
    unless ( defined $string ) {
        require Carp;
        Carp::croak("Failed to dump data to YAML string: $errstr");
    }
    return $string;
}

sub Load {
    my $self = YAML::Tiny->read_string(@_);
    unless ( $self ) {
        require Carp;
        Carp::croak("Failed to load YAML document from string: $errstr");
    }
    if ( wantarray ) {
        return @$self;
    } else {
        # To match YAML.pm, return the last document
        return $self->[-1];
    }
}

BEGIN {
    *freeze = *Dump;
    *thaw   = *Load;
}

sub DumpFile {
    my $file = shift;
    unless ( YAML::Tiny->new(@_)->write($file) ) {
        require Carp;
        Carp::croak("Failed to dump data to file '$file': $errstr");
    }
    return 1;
}

sub LoadFile {
    my $file = shift;
    my $self = YAML::Tiny->read($file);
    unless ( $self ) {
        require Carp;
        Carp::croak("Failed to load YAML document from file '$file': $errstr");
    }
    if ( wantarray ) {
        return @$self;
    } else {
        # Return only the last document to match YAML.pm,
        return $self->[-1];
    }
}





#####################################################################
# Use Scalar::Util if possible, otherwise emulate it

BEGIN {
    local $@;
    eval {
        require Scalar::Util;
    };
    my $v = eval("$Scalar::Util::VERSION") || 0;
    if ( $@ or $v < 1.18 ) {
        eval <<'END_PERL';
# Scalar::Util failed to load or too old
sub refaddr {
    my $pkg = ref($_[0]) or return undef;
    if ( !! UNIVERSAL::can($_[0], 'can') ) {
        bless $_[0], 'Scalar::Util::Fake';
    } else {
        $pkg = undef;
    }
    "$_[0]" =~ /0x(\w+)/;
    my $i = do { local $^W; hex $1 };
    bless $_[0], $pkg if defined $pkg;
    $i;
}
END_PERL
    } else {
        *refaddr = *Scalar::Util::refaddr;
    }
}

1;

__END__

=pod

=head1 NAME

YAML::Tiny - Read/Write YAML files with as little code as possible

=head1 PREAMBLE

The YAML specification is huge. Really, B<really> huge. It contains all the
functionality of XML, except with flexibility and choice, which makes it
easier to read, but with a formal specification that is more complex than
XML.

The original pure-Perl implementation L<YAML> costs just over 4 megabytes
of memory to load. Just like with Windows F<.ini> files (3 meg to load) and
CSS (3.5 meg to load) the situation is just asking for a B<YAML::Tiny>
module, an incomplete but correct and usable subset of the functionality,
in as little code as possible.

Like the other C<::Tiny> modules, YAML::Tiny has no non-core dependencies,
does not require a compiler to install, is back-compatible to Perl v5.8.1,
and can be inlined into other modules if needed.

In exchange for this adding this extreme flexibility, it provides support
for only a limited subset of YAML. But the subset supported contains most
of the features for the more common uses of YAML.

=head1 SYNOPSIS

Assuming F<file.yml> like this:

    ---
    rootproperty: blah
    section:
      one: two
      three: four
      Foo: Bar
      empty: ~


Read and write F<file.yml> like this:

    use YAML::Tiny;

    # Open the config
    my $yaml = YAML::Tiny->read( 'file.yml' );

    # Get a reference to the document
    my ($config) = $yaml->documents;

    # Or read properties directly
    my $root = $yaml->[0]->{rootproperty};
    my $one  = $yaml->[0]->{section}->{one};
    my $Foo  = $yaml->[0]->{section}->{Foo};

    # Change data directly
    $yaml->[0]->{newsection} = { this => 'that' }; # Add a section
    $yaml->[0]->{section}->{Foo} = 'Not Bar!';     # Change a value
    delete $yaml->[0]->{section};                  # Delete a value

    # Save the document back to the file
    $yaml->write( 'file.yml' );

To create a new YAML file from scratch:

    # Create a new object with a single hashref document
    my $yaml = YAML::Tiny->new( { wibble => "wobble" } );

    # Add an arrayref document
    push @$yaml, [ 'foo', 'bar', 'baz' ];

    # Save both documents to a file
    $yaml->write( 'data.yml' );

Then F<data.yml> will contain:

    ---
    wibble: wobble
    ---
    - foo
    - bar
    - baz

=head1 DESCRIPTION

B<YAML::Tiny> is a perl class for reading and writing YAML-style files,
written with as little code as possible, reducing load time and memory
overhead.

Most of the time it is accepted that Perl applications use a lot
of memory and modules. The B<::Tiny> family of modules is specifically
intended to provide an ultralight and zero-dependency alternative to
many more-thorough standard modules.

This module is primarily for reading human-written files (like simple
config files) and generating very simple human-readable files. Note that
I said B<human-readable> and not B<geek-readable>. The sort of files that
your average manager or secretary should be able to look at and make
sense of.

=for stopwords normalise

L<YAML::Tiny> does not generate comments, it won't necessarily preserve the
order of your hashes, and it will normalise if reading in and writing out
again.

It only supports a very basic subset of the full YAML specification.

=for stopwords embeddable

Usage is targeted at files like Perl's META.yml, for which a small and
easily-embeddable module is extremely attractive.

Features will only be added if they are human readable, and can be written
in a few lines of code. Please don't be offended if your request is
refused. Someone has to draw the line, and for YAML::Tiny that someone
is me.

If you need something with more power move up to L<YAML> (7 megabytes of
memory overhead) or L<YAML::XS> (6 megabytes memory overhead and requires
a C compiler).

To restate, L<YAML::Tiny> does B<not> preserve your comments, whitespace,
or the order of your YAML data. But it should round-trip from Perl
structure to file and back again just fine.

=head1 METHODS

=for Pod::Coverage HAVE_UTF8 refaddr

=head2 new

The constructor C<new> creates a C<YAML::Tiny> object as a blessed array
reference.  Any arguments provided are taken as separate documents
to be serialized.

=head2 documents

    my @docs = $yaml->documents;
    my $count = $yaml->documents;

In list context, returns all documents contained in the object (i.e. a list of
Perl scalars or references).  In scalar context, returns the count of documents.

=head2 read $filename

The C<read> constructor reads a YAML file from a file name,
and returns a new C<YAML::Tiny> object containing the parsed content.

Returns the object on success, or C<undef> on error.

When C<read> fails, C<YAML::Tiny> sets an error message internally
you can recover via C<< YAML::Tiny->errstr >>. Although in B<some>
cases a failed C<read> will also set the operating system error
variable C<$!>, not all errors do and you should not rely on using
the C<$!> variable.

=head2 read_string $string;

The C<read_string> constructor reads YAML data from a character string, and
returns a new C<YAML::Tiny> object containing the parsed content.  If you have
read the string from a file yourself, be sure that you have correctly decoded
it into characters first.

Returns the object on success, or C<undef> on error.
Use C<< YAML::Tiny->errstr> >> for error details.

=head2 write $filename

The C<write> method generates the file content for the properties, and
writes it to disk using UTF-8 encoding to the filename specified.

Returns true on success or C<undef> on error.
Use C<< YAML::Tiny->errstr> >> for error details.

=head2 write_string

Generates the file content for the object and returns it as a character
string.  This may contain non-ASCII characters and should be encoded
before writing it to a file.

Returns true on success or C<undef> on error.
Use C<< YAML::Tiny->errstr> >> for error details.

=for stopwords errstr

=head2 errstr

When an error occurs, you can retrieve the error message either from the
C<$YAML::Tiny::errstr> variable, or using the C<errstr()> method.

=head1 FUNCTIONS

YAML::Tiny implements a number of functions to add compatibility with
the L<YAML> API. These should be a drop-in replacement, except that
YAML::Tiny will B<not> export functions by default, and so you will need
to explicitly import the functions.

=head2 Dump

  my $string = Dump(list-of-Perl-data-structures);

Turn Perl data into YAML. This function works very much like
Data::Dumper::Dumper().

It takes a list of Perl data structures and dumps them into a serialized
form.

It returns a character string containing the YAML stream.  Be sure to encode
it as UTF-8 before serializing to a file or socket.

The structures can be references or plain scalars.

Dies on any error.

=head2 Load

  my @documents = Load(string-containing-a-YAML-stream);

Turn YAML into Perl data. This is the opposite of Dump.

Just like L<Storable>'s thaw() function or the eval() function in relation
to L<Data::Dumper>.

It parses a character string containing a valid YAML stream into a list of Perl data
structures.  Be sure to decode it correctly if the string came from a file or socket.

Dies on any error.

=head2 freeze() and thaw()

Aliases to Dump() and Load() for L<Storable> fans. This will also allow
YAML::Tiny to be plugged directly into modules like POE.pm, that use the
freeze/thaw API for internal serialization.

=head2 DumpFile(filepath, list)

Writes the YAML stream to a file with UTF-8 encoding instead of just returning a string.

Dies on any error.

=head2 LoadFile(filepath)

Reads the YAML stream from a UTF-8 encoded file instead of a string.

Dies on any error.

=head1 YAML TINY SPECIFICATION

This section of the documentation provides a specification for "YAML Tiny",
a subset of the YAML specification.

It is based on and described comparatively to the YAML 1.1 Working Draft
2004-12-28 specification, located at L<http://yaml.org/spec/current.html>.

Terminology and chapter numbers are based on that specification.

=head2 1. Introduction and Goals

The purpose of the YAML Tiny specification is to describe a useful subset
of the YAML specification that can be used for typical document-oriented
use cases such as configuration files and simple data structure dumps.

=for stopwords extensibility

Many specification elements that add flexibility or extensibility are
intentionally removed, as is support for complex data structures, class
and object-orientation.

In general, the YAML Tiny language targets only those data structures
available in JSON, with the additional limitation that only simple keys
are supported.

As a result, all possible YAML Tiny documents should be able to be
transformed into an equivalent JSON document, although the reverse is
not necessarily true (but will be true in simple cases).

=for stopwords PCRE

As a result of these simplifications the YAML Tiny specification should
be implementable in a (relatively) small amount of code in any language
that supports Perl Compatible Regular Expressions (PCRE).

=head2 2. Introduction

YAML Tiny supports three data structures. These are scalars (in a variety
of forms), block-form sequences and block-form mappings. Flow-style
sequences and mappings are not supported, with some minor exceptions
detailed later.

The use of three dashes "---" to indicate the start of a new document is
supported, and multiple documents per file/stream is allowed.

Both line and inline comments are supported.

Scalars are supported via the plain style, single quote and double quote,
as well as literal-style and folded-style multi-line scalars.

The use of explicit tags is not supported.

The use of "null" type scalars is supported via the ~ character.

The use of "bool" type scalars is not supported.

=for stopwords serializer

However, serializer implementations should take care to explicitly escape
strings that match a "bool" keyword in the following set to prevent other
implementations that do support "bool" accidentally reading a string as a
boolean

  y|Y|yes|Yes|YES|n|N|no|No|NO
  |true|True|TRUE|false|False|FALSE
  |on|On|ON|off|Off|OFF

The use of anchors and aliases is not supported.

The use of directives is supported only for the %YAML directive.

=head2 3. Processing YAML Tiny Information

B<Processes>

=for stopwords deserialization

The YAML specification dictates three-phase serialization and three-phase
deserialization.

The YAML Tiny specification does not mandate any particular methodology
or mechanism for parsing.

Any compliant parser is only required to parse a single document at a
time. The ability to support streaming documents is optional and most
likely non-typical.

=for stopwords acyclic

Because anchors and aliases are not supported, the resulting representation
graph is thus directed but (unlike the main YAML specification) B<acyclic>.

Circular references/pointers are not possible, and any YAML Tiny serializer
detecting a circular reference should error with an appropriate message.

B<Presentation Stream>

=for stopwords unicode

YAML Tiny reads and write UTF-8 encoded files.  Operations on strings expect
or produce Unicode characters not UTF-8 encoded bytes.

B<Loading Failure Points>

=for stopwords modality

=for stopwords parsers

YAML Tiny parsers and emitters are not expected to recover from, or
adapt to, errors. The specific error modality of any implementation is
not dictated (return codes, exceptions, etc.) but is expected to be
consistent.

=head2 4. Syntax

B<Character Set>

YAML Tiny streams are processed in memory as Unicode characters and read/written
with UTF-8 encoding.

The escaping and unescaping of the 8-bit YAML escapes is required.

The escaping and unescaping of 16-bit and 32-bit YAML escapes is not
required.

B<Indicator Characters>

Support for the "~" null/undefined indicator is required.

Implementations may represent this as appropriate for the underlying
language.

Support for the "-" block sequence indicator is required.

Support for the "?" mapping key indicator is B<not> required.

Support for the ":" mapping value indicator is required.

Support for the "," flow collection indicator is B<not> required.

Support for the "[" flow sequence indicator is B<not> required, with
one exception (detailed below).

Support for the "]" flow sequence indicator is B<not> required, with
one exception (detailed below).

Support for the "{" flow mapping indicator is B<not> required, with
one exception (detailed below).

Support for the "}" flow mapping indicator is B<not> required, with
one exception (detailed below).

Support for the "#" comment indicator is required.

Support for the "&" anchor indicator is B<not> required.

Support for the "*" alias indicator is B<not> required.

Support for the "!" tag indicator is B<not> required.

Support for the "|" literal block indicator is required.

Support for the ">" folded block indicator is required.

Support for the "'" single quote indicator is required.

Support for the """ double quote indicator is required.

Support for the "%" directive indicator is required, but only
for the special case of a %YAML version directive before the
"---" document header, or on the same line as the document header.

For example:

  %YAML 1.1
  ---
  - A sequence with a single element

Special Exception:

To provide the ability to support empty sequences
and mappings, support for the constructs [] (empty sequence) and {}
(empty mapping) are required.

For example,

  %YAML 1.1
  # A document consisting of only an empty mapping
  --- {}
  # A document consisting of only an empty sequence
  --- []
  # A document consisting of an empty mapping within a sequence
  - foo
  - {}
  - bar

B<Syntax Primitives>

Other than the empty sequence and mapping cases described above, YAML Tiny
supports only the indentation-based block-style group of contexts.

All five scalar contexts are supported.

Indentation spaces work as per the YAML specification in all cases.

Comments work as per the YAML specification in all simple cases.
Support for indented multi-line comments is B<not> required.

Separation spaces work as per the YAML specification in all cases.

B<YAML Tiny Character Stream>

The only directive supported by the YAML Tiny specification is the
%YAML language/version identifier. Although detected, this directive
will have no control over the parsing itself.

=for stopwords recognise

The parser must recognise both the YAML 1.0 and YAML 1.1+ formatting
of this directive (as well as the commented form, although no explicit
code should be needed to deal with this case, being a comment anyway)

That is, all of the following should be supported.

  --- #YAML:1.0
  - foo

  %YAML:1.0
  ---
  - foo

  % YAML 1.1
  ---
  - foo

Support for the %TAG directive is B<not> required.

Support for additional directives is B<not> required.

Support for the document boundary marker "---" is required.

Support for the document boundary market "..." is B<not> required.

If necessary, a document boundary should simply by indicated with a
"---" marker, with not preceding "..." marker.

Support for empty streams (containing no documents) is required.

Support for implicit document starts is required.

That is, the following must be equivalent.

 # Full form
 %YAML 1.1
 ---
 foo: bar

 # Implicit form
 foo: bar

B<Nodes>

Support for nodes optional anchor and tag properties is B<not> required.

Support for node anchors is B<not> required.

Support for node tags is B<not> required.

Support for alias nodes is B<not> required.

Support for flow nodes is B<not> required.

Support for block nodes is required.

B<Scalar Styles>

Support for all five scalar styles is required as per the YAML
specification, although support for quoted scalars spanning more
than one line is B<not> required.

Support for the chomping indicators on multi-line scalar styles
is required.

B<Collection Styles>

Support for block-style sequences is required.

Support for flow-style sequences is B<not> required.

Support for block-style mappings is required.

Support for flow-style mappings is B<not> required.

Both sequences and mappings should be able to be arbitrarily
nested.

Support for plain-style mapping keys is required.

Support for quoted keys in mappings is B<not> required.

Support for "?"-indicated explicit keys is B<not> required.

=for stopwords endeth

Here endeth the specification.

=head2 Additional Perl-Specific Notes

For some Perl applications, it's important to know if you really have a
number and not a string.

That is, in some contexts is important that 3 the number is distinctive
from "3" the string.

Because even Perl itself is not trivially able to understand the difference
(certainly without XS-based modules) Perl implementations of the YAML Tiny
specification are not required to retain the distinctiveness of 3 vs "3".

=head1 SUPPORT

Bugs should be reported via the CPAN bug tracker at

L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=YAML-Tiny>

=begin html

For other issues, or commercial enhancement or support, please contact
<a href="http://ali.as/">Adam Kennedy</a> directly.

=end html

=head1 AUTHOR

Adam Kennedy E<lt>adamk@cpan.orgE<gt>

=head1 SEE ALSO

=over 4

=item * L<YAML>

=item * L<YAML::Syck>

=item * L<Config::Tiny>

=item * L<CSS::Tiny>

=item * L<http://use.perl.org/use.perl.org/_Alias/journal/29427.html>

=item * L<http://ali.as/>

=back

=head1 COPYRIGHT

Copyright 2006 - 2013 Adam Kennedy.

This program is free software; you can redistribute
it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the
LICENSE file included with this module.

=cut
