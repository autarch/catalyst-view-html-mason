package Catalyst::View::HTML::Mason;
# ABSTRACT: HTML::Mason rendering for Catalyst

use Moose;
use Try::Tiny;
use MooseX::Types::Moose qw/ArrayRef HashRef ClassName Str Bool Object CodeRef/;
use MooseX::Types::Structured qw/Tuple/;
use Encode::Encoding;
use Data::Visitor::Callback;

use namespace::autoclean;

extends 'Catalyst::View';

=head1 SYNOPSIS

    package MyApp::View::Mason;

    use Moose;
    use namespace::autoclean;

    extends 'Catalyst::View::HTML::Mason';

    __PACKAGE__->config(
        interp_args => {
            comp_root => MyApp->path_to('root'),
        },
    );

    1;

=head1 DESCRIPTION

This module provides rendering of HTML::Mason templates for Catalyst
applications.

It's basically a rewrite of L<Catalyst::View::Mason|Catalyst::View::Mason>,
which became increasingly hard to maintain over time, while keeping backward
compatibility.

=head1 A NOTE ABOUT DHANDLERS

Note that this view does not support automatic dispatching to Mason
dhandlers.  Dhandlers can still be used, but they must be referred to
explicitly like any other component.

=attr interp

The mason interpreter instance responsible for rendering templates.

=cut

has interp => (
    is      => 'ro',
    isa     => Object,
    lazy    => 1,
    builder => '_build_interp',
);

=attr interp_class

The class the C<interp> instance is constructed from. Defaults to
C<HTML::Mason::Interp>.

=cut

{
    use Moose::Util::TypeConstraints;

    my $tc = subtype as ClassName;
    coerce $tc, from Str, via { Class::MOP::load_class($_); $_ };

    has interp_class => (
        is      => 'ro',
        isa     => $tc,
        coerce  => 1,
        builder => '_build_interp_class',
    );
}

=attr interp_args

Arguments to be passed to the construction of C<interp>. Defaults to an empty
hash reference.

=cut

has interp_args => (
    is      => 'ro',
    isa     => HashRef,
    default => sub { +{} },
);

=attr template_extension

File extension to be appended to every component file. By default it's only
appended if no explicit component file has been provided in
C<< $ctx->stash->{template} >>.

=cut

has template_extension => (
    is      => 'ro',
    isa     => Str,
    default => '',
);

=attr always_append_template_extension

If this is set to a true value, C<template_extension> will also be appended to
component paths provided in C<< $ctx->stash->{template} >>.

=cut

has always_append_template_extension => (
    is      => 'ro',
    isa     => Bool,
    default => 0,
);

=attr encoding

Encode Mason output with the given encoding.  Can be a string encoding
name (which will be resolved using Encode::find_encoding()), or an
Encode::Encoding object.  See L<Encode::Supported> for a list of
encodings.

=cut

{
    my $tc = subtype as 'Encode::Encoding';
    coerce $tc, from Str, via { Encode::find_encoding($_) };

    has encoding => (
        is        => 'ro',
        isa       => $tc,
        coerce    => 1,
        predicate => 'has_encoding',
    );
}

=attr globals

Arrayref of string names to export into each rendered component.  Off by default.

Example:

  globals => [ '$foo', '%bar' ]

  #or

  globals => '$baz',

Would export $foo and %bar to every Mason component as globals using
identically-named values in the stash, similar to:

   our $foo = $c->stash->{foo};
   our %bar = %{ $c->stash->{bar} };

To export just the context as $c, one would set globals => '$c' and
make sure to set $c->stash->{c} = $c on each request, such as in an
C<auto> in the root controller.

=cut

{
    my $glob_spec = subtype as Tuple[Str,CodeRef];
    coerce $glob_spec, from Str, via {
        my ($type, $var) = split q//, $_, 2;
        my $fn = {
            '$' => sub { $_[0] },
            '@' => sub {
                return unless defined $_[0];
                ref $_[0] eq 'ARRAY'
                    ? @{ $_[0] }
                    : !ref $_[0]
                        ? $_[0]
                        : ();
            },
            '%' => sub {
                return unless defined $_[0];
                ref $_[0] eq 'HASH'
                    ? %{ $_[0] }
                    : ();
            },
        }->{ $type };
        [$_ => sub { $fn->( $_[1]->stash->{$var} ) }];
    };

    my $tc = subtype as ArrayRef[$glob_spec];
    coerce $tc, from ArrayRef, via { [map { $glob_spec->coerce($_) } @{ $_ } ]};
    coerce $tc, from Str, via { [ $glob_spec->coerce( $_ ) ] };

    has globals => (
        is      => 'ro',
        isa     => $tc,
        coerce  => 1,
        builder => '_build_globals',
    );
}

sub BUILD {
    my ($self) = @_;
    $self->interp;
}

sub _build_globals { [] }

sub _build_interp_class { 'HTML::Mason::Interp' }

sub _build_interp {
    my ($self) = @_;

    my %args = %{ $self->interp_args };
    if ($self->has_encoding) {
        my $old_func = delete $args{postprocess_text};
        $args{postprocess_text} = sub {
            $old_func->($_[0]) if $old_func;
            ${ $_[0] } = $self->encoding->decode(${ $_[0] });
        };
    }

    $args{allow_globals} ||= [];
    unshift @{ $args{allow_globals}}, map { $_->[0] } @{ $self->globals };

    $args{in_package} ||= sprintf '%s::Commands', do {
        if (my $meta = Class::MOP::class_of($self)) {
            $meta->name;
        } else {
            ref $self;
        }
    } ;

    my $v = Data::Visitor::Callback->new(
        'Path::Class::Entity' => sub { blessed $_ ? $_->stringify : $_ },
    );

    return $self->interp_class->new( $v->visit(%args) );
}

=method render($ctx, $component, \%args)

Renders the given component and returns its output.

A hash of template variables may be provided in C<$args>. If C<$args> isn't
given, template variables will be taken from C<< $ctx->stash >>.

=cut

sub render {
    my ($self, $ctx, $comp, $args) = @_;
    my $output = '';

    for (@{ $self->globals }) {
        my ($decl, @values) = ($_->[0] => $_->[1]->($self, $ctx));
        if (@values) {
            $self->interp->set_global($decl, @values);
        } else {
            # HTML::Mason::Interp->set_global would crash on empty lists
            $self->_unset_interp_global($decl);
        }
    }

    try {
        $self->interp->make_request(
            comp => $self->_fetch_comp($comp),
            args => [$args ? %{ $args } : %{ $ctx->stash }],
            out_method => \$output,
        )->exec;
    }
    catch {
        confess $_;
    };

    return $output;
}

sub process {
    my ($self, $ctx) = @_;

    my $comp   = $self->_get_component($ctx);
    my $output = $self->render($ctx, $comp);

    $ctx->response->body($output);
}

sub _fetch_comp {
    my ($self, $comp) = @_;
    my $method;

    $comp = $comp->stringify
        if blessed $comp && $comp->isa( 'Path::Class' );

    return $comp
        if blessed $comp;

    ($comp, $method) = @{ $comp }
        if ref $comp && ref $comp eq 'ARRAY';

    $comp = "/$comp"
        unless $comp =~ m{^/};

    my $component = $self->interp->load($comp);
    confess "Can't find component for path $comp"
        unless $component;

    $component = $component->methods($method)
        if defined $method;

    return $component;
}


sub _get_component {
    my ($self, $ctx) = @_;

    my $comp = $ctx->stash->{template};
    my $extension = $self->template_extension;

    if (defined $comp) {
        $comp .= $extension
            if !ref $comp && $self->always_append_template_extension;

        return $comp;
    }

    return $ctx->action->reverse . $extension;
}

sub _unset_interp_global {
    my ($self, $decl) = @_;
    my ($prefix, $name) = split q//, $decl, 2;
    my $package = $self->interp->compiler->in_package;
    my $varname = sprintf "%s::%s", $package, $name;

    no strict 'refs';
    if    ($prefix eq '$') { $$varname = undef }
    elsif ($prefix eq '@') { @$varname = () }
    else                   { %$varname = () }
}

__PACKAGE__->meta->make_immutable;

1;

=begin Pod::Coverage

BUILD

=end Pod::Coverage
