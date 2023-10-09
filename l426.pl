use strict;
use warnings;
use utf8;

package TCPProxyServer {
    use IO::Select;
    use Socket qw/inet_aton inet_ntoa inet_ntop sockaddr_in sockaddr_in6 INADDR_LOOPBACK IN6ADDR_LOOPBACK SOL_SOCKET SO_REUSEADDR SOMAXCONN SOCK_STREAM AF_INET AF_INET6/;
    use Scalar::Util qw/refaddr/;
    use List::Util qw/first any/;
    use Hash::Util::FieldHash qw/fieldhash/;

    fieldhash my %FH_ADDRESS;
    fieldhash my %FH_PORT;

    sub new {
        my ($class, @ports) = @_;

        my %listeners;
        for my $port (@ports) {
            socket my $socket, AF_INET6, SOCK_STREAM, getprotobyname('tcp')
                or die "socket: $!";
            setsockopt $socket, SOL_SOCKET, SO_REUSEADDR, pack("l", 1);
            bind $socket, sockaddr_in6($port, IN6ADDR_LOOPBACK)
                or die "bind: $!";
            listen $socket, SOMAXCONN
                or die "listen: $!";
            _make_fh_as_nonblocking($socket);
            $listeners{$port} = $socket;
            $FH_ADDRESS{$socket} = '::1';
            $FH_PORT{$socket} = $port;
        }

        my $readers = IO::Select->new(values %listeners);
        my $writers = IO::Select->new();
        bless {
            connecting => {},
            connected  => {},
            readers    => $readers,
            writers    => $writers,
            listeners  => \%listeners,
        }, $class;
    }

    sub _make_fh_as_blocking {
        my $fh = shift;
        my $old_fh = select $fh;
        $| = 0; # blocking
        select $old_fh;
    }

    sub _make_fh_as_nonblocking {
        my $fh = shift;
        my $old_fh = select $fh;
        $| = 1; # non-blocking
        select $old_fh;
    }

    sub _is_listener_socket {
        my ($self, $handle) = @_;
        return unless $FH_ADDRESS{$handle} eq '::1';
        return unless exists $self->{listeners}->{$FH_PORT{$handle}};
        return refaddr($self->{listeners}->{$FH_PORT{$handle}}) == refaddr($handle);
    }

    sub _is_connecting_upstream_socket {
        my ($self, $handle) = @_;
        return unless $FH_ADDRESS{$handle} eq '127.0.0.1';
        return unless exists $self->{connecting}->{$FH_PORT{$handle}};
        return any { refaddr($_->{upstream}) == refaddr($handle) } @{ $self->{connecting}->{$FH_PORT{$handle}} };
    }

    sub _is_connecting_host_socket {
        my ($self, $handle) = @_;
        return unless $FH_ADDRESS{$handle} eq '127.0.0.1';
        return unless exists $self->{connecting}->{$FH_PORT{$handle}};
        return any { refaddr($_->{host}) == refaddr($handle) } @{ $self->{connecting}->{$FH_PORT{$handle}} };
    }

    sub _is_connected_upstream_socket {
        my ($self, $handle) = @_;
        return unless $FH_ADDRESS{$handle} eq '127.0.0.1';
        return unless exists $self->{connected}->{$FH_PORT{$handle}};
        return any { refaddr($_->{upstream}) == refaddr($handle) } @{ $self->{connected}->{$FH_PORT{$handle}} };
    }

    sub _is_connected_client_socket {
        my ($self, $handle) = @_;
        return unless $FH_ADDRESS{$handle} eq '::1';
        return unless exists $self->{connected}->{$FH_PORT{$handle}};
        return any { refaddr($_->{client}) == refaddr($handle) } @{ $self->{connected}->{$FH_PORT{$handle}} };
    }

    sub execute {
        my $self = shift;
    
        my $shutdown = 0;
        local $SIG{INT} = sub { $shutdown = 1 };
        local $SIG{TERM} = sub { $shutdown = 1 };
        while (!$shutdown) {
            my ($readables, $writables) = IO::Select->select($self->{readers}, $self->{writers}, undef, undef);
            for my $handle (@$readables) {
                if ($self->_is_listener_socket($handle)) {
                    if ($self->_is_connecting_host_socket($handle)) {
                        my $connecting = first { refaddr($_->{host}) == refaddr($handle) } @{ $self->{connecting}->{$FH_PORT{$handle}} };
                        $self->_accept_and_pairing($handle, $connecting->{upstream});
                    } else {
                        my $upstream = $self->_create_new_upstream($FH_PORT{$handle});
                        $self->_connect_to_upstream($upstream);
                    }
                } elsif ($self->_is_connecting_upstream_socket($handle)) {
                    $self->_connect_to_upstream($handle);
                } elsif ($self->_is_connected_upstream_socket($handle)) {
                    my $connected = first { refaddr($_->{upstream}) == refaddr($handle) } @{ $self->{connected}->{$FH_PORT{$handle}} };
                    $self->_proxy_payload(@{$connected}{qw/upstream client/});
                } elsif ($self->_is_connected_client_socket($handle)) {
                    my $connected = first { refaddr($_->{client}) == refaddr($handle) } @{ $self->{connected}->{$FH_PORT{$handle}} };
                    $self->_proxy_payload(@{$connected}{qw/client upstream/});
                }
            }
            for my $handle (@$writables) {
                if ($self->{pending_writes}->{refaddr($handle)}) {
                    while (my $payload = shift @{ $self->{pending_writes}->{refaddr($handle)} }) {
                        $self->_write_payload($handle, $payload);
                    }
                } elsif ($self->_is_connecting_upstream_socket($handle)) {
                    $self->_connect_to_upstream($handle);
                }
            }
        }
    }

    sub _create_new_upstream {
        my ($self, $port) = @_;
        socket my $socket, AF_INET, SOCK_STREAM, getprotobyname('tcp')
            or die "socket: $!";
        _make_fh_as_nonblocking($socket);
        $FH_ADDRESS{$socket} = '127.0.0.1';
        $FH_PORT{$socket} = $port;
        return $socket;
    }

    sub _connect_to_upstream {
        my ($self, $upstream) = @_;
        if (connect $upstream, sockaddr_in($FH_PORT{$upstream}, inet_aton($FH_ADDRESS{$upstream}))) {
            my $listener = $self->{listeners}->{$FH_PORT{$upstream}};
            $self->_accept_and_pairing($listener, $upstream);
        } else {
            if ($!{EINPROGRESS} || $!{EWOULDBLOCK}) {
                my $port = $FH_PORT{$upstream};
                push @{ $self->{connecting}->{$port} } => { upstream => $upstream, host => $self->{listeners}->{$port} };
                $self->{readers}->add($upstream);
            } else {
                my $port = $FH_PORT{$upstream};

                warn "failed to connect 127.0.0.1:$port: $!";

                # shutdown
                my $listener = $self->{listeners}->{$port};
                _make_fh_as_blocking($listener);
                close $listener;
                $self->{readers}->remove($listener);
                undef $listener;

                # recreate
                socket $listener, AF_INET6, SOCK_STREAM, getprotobyname('tcp')
                or die "socket: $!";
                setsockopt $listener, SOL_SOCKET, SO_REUSEADDR, pack("l", 1);
                bind $listener, sockaddr_in6($port, IN6ADDR_LOOPBACK)
                    or die "bind: $!";
                listen $listener, SOMAXCONN
                    or die "listen: $!";
                _make_fh_as_nonblocking($listener);
                $self->{readers}->add($listener);
                $FH_ADDRESS{$listener} = '::1';
                $FH_PORT{$listener} = $port;
            }
        }
    }

    sub _accept_and_pairing {
        my ($self, $listener, $upstream) = @_;
        if (my $paddr = accept(my $client, $listener)) {
            _make_fh_as_nonblocking($client);
            my (undef, $peer_address) = sockaddr_in6($paddr);
            $FH_ADDRESS{$client} = inet_ntop(AF_INET6, $peer_address);
            $FH_PORT{$client} = $FH_PORT{$listener};
            $self->{readers}->add($client, $upstream);
            $self->{writers}->add($client, $upstream);
            push @{ $self->{connected}->{$FH_PORT{$listener}} } => { upstream => $upstream, client => $client };
        } else {
            if ($!{EINPROGRESS} || $!{EWOULDBLOCK}) {
                return;
            }

            $self->{connecting}->{$FH_PORT{$upstream}} = [grep { refaddr($_->{upstream}) != refaddr($upstream) } @{ $self->{connecting}->{$FH_PORT{$upstream}} }];
            $upstream->close();
            delete $self->{pending_writes}->{refaddr($upstream)};
        }
    }

    sub _proxy_payload {
        my ($self, $reader, $writer) = @_;
        my $size = sysread $reader, my $payload, 8192;
        if ((defined $size && $size == 0) || $!{ECONNRESET}) {
            for ($reader, $writer) {
                $_->close();
                $self->{readers}->remove($_);
                $self->{writers}->remove($_);
            }
            return;
        }
        if (!defined $size || $size == -1) {
            return if $!{EWOULDBLOCK};

            warn "failed to read: $!";
            return;
        }

        $self->_write_payload($writer, $payload);
    }

    sub _write_payload {
        my ($self, $writer, $payload) = @_;
        if (exists $self->{pending_writes}->{refaddr($writer)} && @{ $self->{pending_writes}->{refaddr($writer)} }) {
            push @{ $self->{pending_writes}->{refaddr($writer)} } => $payload;
            return;
        }

        my $size = syswrite $writer, $payload;
        if ($size == -1) {
            return if $!{EWOULDBLOCK};

            warn "failed to write: $!";
            return;
        }
        if ($size < length $payload) {
            push @{ $self->{pending_writes}->{refaddr($writer)} } => substr($payload, $size);
        }
    }
}

TCPProxyServer->new(@ARGV)->execute();