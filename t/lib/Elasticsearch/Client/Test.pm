package Elasticsearch::Client::Test;

use strict;
use warnings;
use YAML qw(LoadFile);
use Elasticsearch;

use Test::More;
use Test::Deep;
use Data::Dump qw(pp);
use File::Spec::Functions qw(rel2abs);
use File::BaseName;

require Exporter;
our @ISA    = 'Exporter';
our @EXPORT = 'test_dir';

our %Test_Types = (
    ok => sub {
        my ( $got, undef, $name ) = @_;
        ok( $got, $name );
    },
    not_ok => sub {
        my ( $got, undef, $name ) = @_;
        not_ok( $got, $name );
    },
    lt => sub {
        my ( $got, $expect, $name ) = @_;
        ok( $got < $expect, $name );
    },
    gt => sub {
        my ( $got, $expect, $name ) = @_;
        ok( $got > $expect, $name );
    },
    match  => \&cmp_deeply,
    length => \&test_length,
    catch  => \&test_error,
);

our %Errors = (
    missing  => 'Elasticsearch::Error::Missing',
    conflict => 'Elasticsearch::Error::Conflict',
    param    => 'Elasticsearch::Error::Param',
    request  => 'Elasticsearch::Error::Request',
);

my $es = Elasticsearch->new;

#===================================
sub test_dir {
#===================================
    my ($path) = @_;
    $path = rel2abs($path);
    my $name = File::Basename::basename($path);

    my @files = grep {/.yaml$/} <"$path/*">;

    if (@files) {
        plan tests => 0 + @files;
        for my $file (@files) {
            my $title
                = $name . "/" . File::Basename::basename( $file, '.yaml' );
            subtest $name => sub { test_file( $title, $file ) }
        }
    }
    else {
        plan tests => 1;
        fail "No YAML test files found in $path";
    }
    done_testing;
}

#===================================
sub test_file {
#===================================
    my ( $name, $file ) = @_;
    my @ast = eval { LoadFile($file) } or do {
        plan tests => 1;
        fail "Error parsing test file ($file): $@";
        return;
    };

    my $total = 0;
    map { $total += @$_ } map { values %$_ } @ast;

    plan tests => $total;

    for my $pair (@ast) {
        my ( $title, $tests ) = key_val($pair);
        $title = $name . '/' . $title;
        reset_es();
        run_tests( $title, $tests );
    }
}

#===================================
sub run_tests {
#===================================
    my ( $title, $tests ) = @_;

    fail "Expected an ARRAY of tests, got: " . pp($tests)
        unless ref $tests eq 'ARRAY';

    my $val;
    my $counter = 1;
    my %stash;

    for (@$tests) {
        my $test_name = "$title - " . ( $counter++ );
        my ( $type, $test ) = key_val($_);

        if ( $type eq 'do' ) {
            my $error = delete $test->{catch};
            eval {
                $test = populate_vars( $test, \%stash );
                $val = run_cmd($test);
                pass($test_name);
            } or do {
                if ($error) {
                    test_error( $@, $error, $test_name );
                }
                else {
                    fail($test_name);
                    diag $@;
                }
                }
        }
        else {
            my ( $field, $expect );
            if ( ref $test ) {
                ( $field, $expect ) = key_val($test);
            }
            else {
                $field = $test;
            }
            my $got = get_val( $val, $field );
            if ( $type eq 'set' ) {
                $stash{$expect} = $got;
                pass($test_name);
                next;
            }
            $expect = populate_vars( $expect, \%stash );
            run_test( $test_name, $type, $expect, $got );
        }
    }
}

#===================================
sub run_test {
#===================================
    my ( $name, $type, $expect, $got ) = @_;
    my $handler = $Test_Types{$type}
        or die "Unknown test type ($type)";
    $handler->( $got, $expect, $name );
}

#===================================
sub populate_vars {
#===================================
    my ( $val, $stash ) = @_;

    if ( ref $val eq 'HASH' ) {
        return {
            map { $_ => populate_vars( $val->{$_}, $stash ) }
                keys %$val
        };
    }
    if ( ref $val eq 'ARRAY' ) {
        return [ map { populate_vars( $_, $stash ) } @$val ];
    }
    return $val unless defined $val and $val =~ /^\$(\w+)/;
    return $stash->{$1};
}

#===================================
sub get_val {
#===================================
    my ( $val, $field ) = @_;
    return undef unless defined $val;
    return $val  unless defined $field;

    for my $next ( split /\./, $field ) {
        if ( ref $val eq 'ARRAY' ) {
            return undef
                unless $next =~ /^\d+$/;
            $val = $val->[$next];
            next;
        }
        if ( ref $val eq 'HASH' ) {
            $val = $val->{$next};
            next;
        }
        last;
    }
    return $val;
}

#===================================
sub run_cmd {
#===================================
    my ( $method, $params ) = key_val(@_);

    $params ||= {};
    my @methods = split /\./, $method;
    my $final   = pop @methods;
    my $obj     = $es;
    for (@methods) {
        $obj = $obj->$_;
    }
    return $obj->$final(%$params);
}

#===================================
sub reset_es {
#===================================
    $es->indices->delete( index => 'test*', ignore_missing => 1 );
}

#===================================
sub key_val {
#===================================
    my $val = shift;
    die "Expected HASH, got: " . pp($val)
        unless defined $val
        and ref $val
        and ref $val eq 'HASH';
    die "Expected single key-value pair, got: " . pp($val)
        unless keys(%$val) == 1;
    return (%$val);
}

#===================================
sub test_length {
#===================================
    my ( $got, $expected, $name ) = @_;
    if ( ref $got eq 'ARRAY' ) {
        is( @$got + 0, $expected, $name );
    }
    elsif ( ref $got eq 'HASH' ) {
        is( scalar keys(%$got), $expected, $name );
    }
    else {
        is( length($got), $expected, $name );
    }
}

#===================================
sub test_error {
#===================================
    my ( $got, $expect, $name ) = @_;
    if ( $expect =~ m{^/(.+)/$} ) {
        like( $got, qr/$1/, $name );
    }
    else {
        my $class = $Errors{$expect}
            or die "Unknown error type ($expect)";
        is( ref($got) || $got, $class, $name );
    }
}

1;
