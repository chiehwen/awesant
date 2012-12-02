=head1 NAME

Awesant::Output::Socket - Send messages to a Socket database.

=head1 SYNOPSIS

    my $output = Awesant::Output::Socket->new(
        host => "127.0.0.1",
        port => 4711,
        timeout => 10,
    );

    $output->push($line);

=head1 DESCRIPTION

This transport module connects to a tcp socket and ships data plain or via ssl.

=head1 OPTIONS

=head2 host

The hostname or ip address of the Socket server.

Default: 127.0.0.1

=head2 port

The port number where the Socket server is listen on.

Default: no default

=head2 timeout

The timeout in seconds to transport data to the tcp server.

Default: 10

=head2 connect_timeout

The timeout in seconds to connect to the tcp server.

=head2 proto

The protocol to use. At the moment only tcp is allowed.

Default: tcp

=head2 response

If a response is excepted then you can set the excepted message here as a perl regular expression.

If the regular expression matched, then the transport of the message was successful.

Example:

    response ^(ok|yes|accept)$

Default: no default

=head2 ssl_ca_file, ssl_cert_file, ssl_key_file

If you want to use ssl connections to the server you can set the path to your ca, certificate and key file.

This options are equivalent to the options of IO::Socket::SSL.

See cpan http://search.cpan.org/~sullr/IO-Socket-SSL/.

Default: no set

=head2 ssl_passwd_cb

The password for the certificate, if one exists.

Default: no default

=head1 METHODS

=head2 new

Create a new output object.

=head2 connect

Connect to the redis database.

=head2 push

Push data to redis via LPUSH command.

=head2 validate

Validate the configuration that is passed to the C<new> constructor.

=head2 log

Just a accessor to the logger.

=head1 PREREQUISITES

    IO::Socket::INET
    Log::Handler
    Params::Validate

=head1 EXPORTS

No exports.

=head1 REPORT BUGS

Please report all bugs to <support(at)bloonix.de>.

=head1 AUTHOR

Jonny Schulz <support(at)bloonix.de>.

=head1 COPYRIGHT

Copyright (C) 2012 by Jonny Schulz. All rights reserved.

=cut

package Awesant::Output::Socket;

use strict;
use warnings;
use IO::Socket::INET;
use Log::Handler;
use Params::Validate qw();

our $VERSION = "0.1";

sub new {
    my $class = shift;
    my $opts = $class->validate(@_);
    my $self = bless $opts, $class;

    $self->{log} = Log::Handler->get_logger("awesant");

    $self->{__alarm_sub} = sub {
        alarm(0);
    };

    $self->{__timeout_sub} = sub {
        die "connection timed out";
    };

    $self->log->notice("$class initialized");

    return $self;
}

sub connect {
    my $self = shift;

    # If the socket is still active, then just return true.
    # This works only if the sock is set to undef on errors.
    if ($self->{sock}) {
        return 1;
    }

    my $module = $self->{sockmod};
    my $port   = $self->{port};
    my $hosts  = $self->{hosts};
    my @order  = @$hosts;
    my $sock;

    # Try to connect to the hosts in the configured order.
    while (my $host = shift @order) {
        # Although the connection was successful, the host is pushed
        # at the end of the array. If the connection lost later, then
        # the next host will be connected.
        push @$hosts, shift @$hosts;

        # Set the currently used host to the object.
        $self->{host} = $host;

        # Set the PeerAddr to the host that we a try to connect.
        $self->{sockopts}->{PeerAddr} = $host;

        # We don't want that the daemon dies if the connection
        # was not successful. The eval block is also great to
        # break out on errors.
        $self->log->notice("connect to server $host:$port");
        eval {
            local $SIG{ALRM} = $self->{__timeout_sub};
            local $SIG{__DIE__} = $self->{__alarm_sub};
            alarm($self->{connect_timeout});
            $sock = $module->new(%{$self->{sockopts}});
            die $! unless $sock;
            alarm(0);
        };

        # If no error message exists and the socket is created,
        # then the connection was successful. In this case we
        # just jump out of the loop.
        if (!$@ && $sock) {
            last;
        }

        # At this point the connection was not successful.
        if ($@) {
            $self->log->error($@);
        }

        $self->log->error("unable to connect to server $host:$port");
    }

    # It's possible that no connection could be established to any host.
    # If a connection could be established, then the socket will be
    # stored to $self->{sock} and autoflush flag is set to the socket.
    if ($sock) {
        $sock->autoflush(1);
        $self->log->notice("connected to server $self->{host}:$self->{port}");
        $self->{sock} = $sock;
        return 1;
    }

    return undef;
}

sub push {
    my ($self, $data) = @_;

    # At a newline to the end of the data.
    $data = "$data\n";

    # At first try to connect to the server.
    # If the connect was successful, the socket
    # is stored in $self->{sock}.
    $self->connect
        or return undef;

    my $sock = $self->{sock};
    my $timeout = $self->{timeout};
    my $response = "";

    eval {
        local $SIG{ALRM} = $self->{__timeout_sub};
        local $SIG{__DIE__} = $self->{__alarm_sub};
        alarm($timeout);

        my $rest = length($data);
        my $offset = 0;

        if ($self->log->is_debug) {
            $self->log->debug("set timeout to $timeout seconds");
            $self->log->debug("send data to server $self->{host}:$self->{port}: $data");
        }

        while ($rest) {
            my $written = syswrite $sock, $data, $rest, $offset;

            if (!defined $written) {
                die "system write error: $!\n";
            }

            $rest -= $written;
            $offset += $written;
        }

        if (defined $self->{response}) {
            $response = <$sock>;
        }

        alarm(0);
    };

    if ($@) {
        $self->log->error($@);
        $self->{sock} = undef;
        return undef;
    }

    if (!defined $self->{response}) {
        return 1;
    }

    if (!defined $response) {
        $self->log->error("no response received from server $self->{host}:$self->{port}");
        $self->{sock} = undef;
        return undef;
    }

    if ($response =~ /$self->{response}/) {
        return 1;
    }

    $self->log->error("unknown response from server: $response");
    $self->{sock} = undef;
    return undef;
}

sub validate {
    my $self = shift;

    my %options = Params::Validate::validate(@_, {
        host => {
            type => Params::Validate::SCALAR | Params::Validate::ARRAYREF,
            default => "127.0.0.1",
        },
        port => {
            type => Params::Validate::SCALAR,  
            default => 6379,
        },
        connect_timeout => {
            type => Params::Validate::SCALAR,
            default => 10,
        },
        timeout => {  
            type => Params::Validate::SCALAR,  
            default => 10,
        },
        proto => {
            type => Params::Validate::SCALAR,
            regex => qr/^tcp\z/,
            default => "tcp",
        },
        response => {
            type => Params::Validate::SCALAR,
            optional => 1,
        },
        ssl_ca_file => {
            type => Params::Validate::SCALAR,
            optional => 1,
        },
        ssl_cert_file => {
            type => Params::Validate::SCALAR,
            optional => 1,
        },
        ssl_key_file => {
            type => Params::Validate::SCALAR,
            optional => 1,
        },
        ssl_passwd_cb => {
            type => Params::Validate::SCALAR,
            optional => 1,
        },
    });

    if ($options{ssl_cert_file} && $options{ssl_key_file}) {
        require IO::Socket::SSL;
        $options{sockmod} = "IO::Socket::SSL";
    } elsif ($options{ssl_cert_file} || $options{ssl_key_file}) {
        die "parameter ssl_cert_file and ssl_key_file are both mandatory for ssl sockets";
    }

    if (!$options{sockmod}) {
        $options{sockmod} = "IO::Socket::INET";
    }

    my %sockopts = (
        port => 'PeerPort',
        ssl_ca_file   => 'SSL_ca_file',
        ssl_cert_file => 'SSL_cert_file',
        ssl_key_file  => 'SSL_key_file',
        ssl_passwd_cb => 'SSL_passwd_cb',
    );

    while (my ($opt, $modopt) = each %sockopts) {
        if ($options{$opt}) {
            $options{sockopts}{$modopt} = $options{$opt};
        }
    }

    $options{host} =~ s/\s//g;
    $options{hosts} = [ split /,/, $options{host} ];

    return \%options;
}

sub log {
    my $self = shift;

    return $self->{log};
}

1;