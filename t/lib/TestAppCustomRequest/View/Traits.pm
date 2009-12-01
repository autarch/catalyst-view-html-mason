package TestAppCustomRequest::View::Traits;

use Moose;
use namespace::autoclean;

extends 'Catalyst::View::HTML::Mason';

__PACKAGE__->config(
    globals => [ '$affe', ],
    request_class => 'HTML::Mason::Request::Catalyst',
    request_class_roles => [
        'TestAppCustomRequest::Trait::One',
        'TestAppCustomRequest::Trait::Two',
    ],
    interp_args => {
        code_cache_max_size => 0,
        use_object_files => 0,
    },
);

__PACKAGE__->meta->make_immutable;

1;
