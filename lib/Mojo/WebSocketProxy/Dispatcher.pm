package Mojo::WebSocketProxy::Dispatcher;

use Mojo::Base 'Mojolicious::Controller';
use Mojo::WebSocketProxy::Dispatcher::Parser;
use Mojo::WebSocketProxy::Config;
use Mojo::WebSocketProxy::CallingEngine;

use Time::Out qw(timeout);

sub ok {
    my $c      = shift;
    my $source = 1;       # check http origin here
    $c->stash(source => $source);
    return 1;
}

sub open_connection {
    my ($c) = @_;

    my $log = $c->app->log;
    $log->debug("opening a websocket for " . $c->tx->remote_address);

    # Enable permessage-deflate
    $c->tx->with_compression;

    my $config = Mojo::WebSocketProxy::Config->new->{config};

    Mojo::IOLoop->singleton->stream($c->tx->connection)->timeout($config->{stream_timeout}) if $config->{stream_timeout};
    Mojo::IOLoop->singleton->max_connections($config->{max_connections}) if $config->{max_connections};

    $config->{opened_connection}->($c) if $config->{opened_connection} and ref($config->{opened_connection}) eq 'CODE';

    $c->on(json => \&on_message);
    $c->on(finish => $config->{finish_connection}) if $config->{finish_connection} and ref($config->{opened_connection}) eq 'CODE';

    return;
}

sub on_message {
    my ($c, $args) = @_;

    my $config = Mojo::WebSocketProxy::Config->new->{config};

    my $result;
    my $req_storage = {};
    $req_storage->{args} = $args;
    timeout 15 => sub {
        $result = Mojo::WebSocketProxy::Dispatcher::Parser::parse_req($c, $req_storage);
        if (!$result
            && (my $action = $c->dispatch($args)))
        {
            %$req_storage = (%$req_storage, %$action);
            $req_storage->{method} = $req_storage->{name};
            $result = $c->before_forward($req_storage);

            # Don't forward call to RPC if any before_forward hook returns response
            # Or if there is instead_of_forward action
            unless ($result) {
                $result =
                      $req_storage->{instead_of_forward}
                    ? $req_storage->{instead_of_forward}->($c, $req_storage)
                    : $c->forward($req_storage);
            }

            $c->after_forward($result, $req_storage);
        } elsif (!$result) {
            $c->app->log->debug("unrecognised request: " . $c->dumper($args));
            $result = $c->wsp_error('error', 'UnrecognisedRequest', 'Unrecognised request.');
        }
    };
    if ($@) {
        $c->app->log->info("$$ timeout for " . JSON::to_json($args));
    }

    $c->send_api_response($req_storage, $result) if $result;

    $c->_run_hooks($config->{after_dispatch} || []);

    return;
}

sub before_forward {
    my ($c, $req_storage) = @_;

    my $config = Mojo::WebSocketProxy::Config->new->{config};

    # Should first call global hooks
    my $before_forward_hooks = [
        ref($config->{before_forward}) eq 'ARRAY'      ? @{$config->{before_forward}}             : $config->{before_forward},
        ref($req_storage->{before_forward}) eq 'ARRAY' ? @{delete $req_storage->{before_forward}} : delete $req_storage->{before_forward},
    ];

    return $c->_run_hooks($before_forward_hooks, $req_storage);
}

sub after_forward {
    my ($c, $result, $req_storage) = @_;

    my $config = Mojo::WebSocketProxy::Config->new->{config};
    return $c->_run_hooks($config->{after_forward} || [], $result, $req_storage);
}

sub _run_hooks {
    my @hook_params = @_;
    my $c           = shift @hook_params;
    my $hooks       = shift @hook_params;

    my $i = 0;
    my $result;
    while (!$result && $i < @$hooks) {
        my $hook = $hooks->[$i++];
        next unless $hook;
        $result = $hook->($c, @hook_params);
    }

    return $result;
}

sub dispatch {
    my ($c, $args) = @_;

    my $log = $c->app->log;
    $log->debug("websocket got json " . $c->dumper($args));

    my ($action) =
        sort { $a->{order} <=> $b->{order} }
        grep { defined }
        map  { Mojo::WebSocketProxy::Config->new->{actions}->{$_} } keys %$args;

    return $action;
}

sub forward {
    my ($c, $req_storage) = @_;

    my $config = Mojo::WebSocketProxy::Config->new->{config};

    $req_storage->{url} ||= $config->{url};
    die 'No url found' unless $req_storage->{url};

    for my $hook (qw/ before_call before_get_rpc_response after_got_rpc_response before_send_api_response after_sent_api_response /) {
        $req_storage->{$hook} = [
            grep { $_ } (ref $config->{$hook} eq 'ARRAY'      ? @{$config->{$hook}}      : $config->{$hook}),
            grep { $_ } (ref $req_storage->{$hook} eq 'ARRAY' ? @{$req_storage->{$hook}} : $req_storage->{$hook}),
        ];
    }

    Mojo::WebSocketProxy::CallingEngine::call_rpc($c, $req_storage);
    return;
}

sub send_api_response {
    my ($c, $req_storage, $result) = @_;

    my $config = Mojo::WebSocketProxy::Config->new->{config};
    for my $hook (qw/ before_send_api_response after_sent_api_response /) {
        $req_storage->{$hook} ||= [grep { $_ } (ref $config->{$hook} eq 'ARRAY' ? @{$config->{$hook}} : $config->{$hook})];
    }
    Mojo::WebSocketProxy::CallingEngine::send_api_response($c, $req_storage, $result);
    return;
}

1;

__END__

=head1 NAME

Mojo::WebSocketProxy::Dispatcher

=head1 DESCRIPTION

Using this module you can forward websocket JSON-RPC 2.0 requests to RPC server.
See L<Mojo::WebSocketProxy> for details on how to use hooks and parameters.

=head1 METHODS

=head2 open_connection

Run while openning new wss connection.
Run hook when connection is opened.
Set finish connection callback.

=head2 on_message

Handle message - parse and dispatch request messages.
Dispatching action and forward to RPC server.

=head2 before_forward

Run hooks.

=head2 after_forward

Run hooks.

=head2 dispatch

Dispatch request using message json key.

=head2 forward

Forward call to RPC server using global and action hooks.
Don't forward call to RPC if any before_forward hook returns response.
Or if there is instead_of_forward action.

=head2 send_api_response

Send asynchronous response to client websocket, doing hooks.

=head1 SEE ALSO
 
L<Mojolicious::Plugin::WebSocketProxy>, 
L<Mojo::WebSocketProxy>,
L<Mojo::WebSocketProxy::CallingEngine>,
L<Mojo::WebSocketProxy::Dispatcher>,
L<Mojo::WebSocketProxy::Config>
L<Mojo::WebSocketProxy::Dispatcher::Parser>

=cut
