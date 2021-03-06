package Plack::Server::FCGI;
use strict;
use warnings;
use constant RUNNING_IN_HELL => $^O eq 'MSWin32';

use Plack::Util;
use FCGI;

sub new {
    my $class = shift;
    my $self  = bless {@_}, $class;

    $self->{leave_umask} ||= 0;
    $self->{keep_stderr} ||= 0;
    $self->{nointr}      ||= 0;
    $self->{detach}      ||= 0;
    $self->{nproc}       ||= 1;
    $self->{pidfile}     ||= undef;
    $self->{listen}      ||= ":$self->{port}" if $self->{port};
    $self->{manager}     = 'FCGI::ProcManager' unless exists $self->{manager};

    $self;
}

sub run {
    my ($self, $app) = @_;

    my $sock = 0;
    if ($self->{listen}) {
        my $old_umask = umask;
        unless ($self->{leave_umask}) {
            umask(0);
        }
        $sock = FCGI::OpenSocket( $self->{listen}, 100 )
            or die "failed to open FastCGI socket: $!";
        unless ($self->{leave_umask}) {
            umask($old_umask);
        }
    }
    elsif (!RUNNING_IN_HELL) {
        -S STDIN
            or die "STDIN is not a socket: specify a listen location";
    }

    my %env;
    my $request = FCGI::Request(
        \*STDIN, \*STDOUT,
        ($self->{keep_stderr} ? \*STDOUT : \*STDERR), \%env, $sock,
        ($self->{nointr} ? 0 : &FCGI::FAIL_ACCEPT_ON_INTR),
    );

    my $proc_manager;

    if ($self->{listen}) {
        $self->daemon_fork if $self->{detach};

        if ($self->{manager}) {
            Plack::Util::load_class($self->{manager});
            $proc_manager = $self->{manager}->new({
                n_processes => $self->{nproc},
                pid_fname   => $self->{pidfile},
            });

            # detach *before* the ProcManager inits
            $self->daemon_detach if $self->{detach};

            $proc_manager->pm_manage;
        }
        elsif ($self->{detach}) {
            $self->daemon_detach;
        }
    }

    while ($request->Accept >= 0) {
        $proc_manager && $proc_manager->pm_pre_dispatch;

        my $env = {
            %env,
            'psgi.version'      => [1,0],
            'psgi.url_scheme'   => ($env{HTTPS}||'off') =~ /^(?:on|1)$/i ? 'https' : 'http',
            'psgi.input'        => *STDIN,
            'psgi.errors'       => *STDERR, # FCGI.pm redirects STDERR in Accept() loop, so just print STDERR
                                            # print to the correct error handle based on keep_stderr
            'psgi.multithread'  => Plack::Util::FALSE,
            'psgi.multiprocess' => Plack::Util::TRUE,
            'psgi.run_once'     => Plack::Util::FALSE,
        };

        # If we're running under Lighttpd, swap PATH_INFO and SCRIPT_NAME if PATH_INFO is empty
        # http://lists.rawmode.org/pipermail/catalyst/2006-June/008361.html
        # Thanks to Mark Blythe for this fix
        if ($env->{SERVER_SOFTWARE} && $env->{SERVER_SOFTWARE} =~ /lighttpd/) {
            $env->{PATH_INFO}   ||= delete $env->{SCRIPT_NAME};
            $env->{SCRIPT_NAME} ||= '';
            $env->{SERVER_NAME} =~ s/:\d+$//; # cut off port number
        }

        my $res = Plack::Util::run_app $app, $env;
        print "Status: $res->[0]\n";
        my $headers = $res->[1];
        while (my ($k, $v) = splice @$headers, 0, 2) {
            print "$k: $v\n";
        }
        print "\n";

        my $body = $res->[2];
        my $cb = sub { print STDOUT $_[0] };

        Plack::Util::foreach($body, $cb);

        $proc_manager && $proc_manager->pm_post_dispatch();
    }
}

sub daemon_fork {
    require POSIX;
    fork && exit;
}

sub daemon_detach {
    my $self = shift;
    print "FastCGI daemon started (pid $$)\n";
    open STDIN,  "+</dev/null" or die $!; ## no critic
    open STDOUT, ">&STDIN"     or die $!;
    open STDERR, ">&STDIN"     or die $!;
    POSIX::setsid();
}

1;

__END__

=head1 SYNOPSIS

    my $server = Plack::Server::FCGI->new(
        nproc  => $num_proc,
        listen => $listen,
        detach => 1,
    );
    $server->run($app);

Starts the FastCGI server.  If C<$listen> is set, then it specifies a
location to listen for FastCGI requests;

=head2 OPTIONS

=over 4

=item listen

    listen => '/path/to/socket'
    listen => ':8080'

Listen on a socket path, hostname:port, or :port.

=item port

listen via TCP on port on all interfaces (Same as C<< listen => ":$port" >>)

=item leave-umask

Set to 1 to disable setting umask to 0 for socket open

=item nointr

Do not allow the listener to be interrupted by Ctrl+C

=item nproc

Specify a number of processes for FCGI::ProcManager

=item pidfile

Specify a filename for the pid file

=item manager

Specify a FCGI::ProcManager sub-class

=item detach

Detach from console

=item keep-stderr

Send STDERR to STDOUT instead of the webserver

=back

=head2 WEB SERVER CONFIGURATIONS

=head3 nginx

This is an example nginx configuration to run your FCGI daemon on a
Unix domain socket and run it at the server's root URL (/).

  http {
    server {
      listen 3001;
      location / {
        set $script "";
        set $path_info $uri;
        fastcgi_pass unix:/tmp/fastcgi.sock;
        fastcgi_param  SCRIPT_NAME      $script;
        fastcgi_param  PATH_INFO        $path_info;
        fastcgi_param  QUERY_STRING     $query_string;
        fastcgi_param  REQUEST_METHOD   $request_method;
        fastcgi_param  CONTENT_TYPE     $content_type;
        fastcgi_param  CONTENT_LENGTH   $content_length;
        fastcgi_param  REQUEST_URI      $request_uri;
        fastcgi_param  SEREVR_PROTOCOL  $server_protocol;
        fastcgi_param  REMOTE_ADDR      $remote_addr;
        fastcgi_param  REMOTE_PORT      $remote_port;
        fastcgi_param  SERVER_ADDR      $server_addr;
        fastcgi_param  SERVER_PORT      $server_port;
        fastcgi_param  SERVER_NAME      $server_name;
      }
    }
  }

If you want to host your application in a non-root path, then you
should mangle this configuration to set the path to C<SCRIPT_NAME> and
the rest of the path in C<PATH_INFO>.

See L<http://wiki.nginx.org/NginxFcgiExample> for more details.

=head3 Apache mod_fastcgi

You can use C<FastCgiExternalServer> as normal.

  FastCgiExternalServer /tmp/myapp.fcgi -socket /tmp/fcgi.sock

See L<http://www.fastcgi.com/mod_fastcgi/docs/mod_fastcgi.html#FastCgiExternalServer> for more details.

=head3 lighttpd

Host in the root path:

  fastcgi.server = ( "" =>
     ((
       "socket" => "/tmp/fcgi.sock",
       "check-local" => "disable"
     ))

Or in the non-root path over TCP:

  fastcgi.server = ( "/foo" =>
     ((
       "host" = "127.0.0.1"
       "port" = "5000"
       "check-local" => "disable"
     ))

Plack::Server::FCGI has a workaround for lighttpd's weird
C<SCRIPT_NAME> and C<PATH_INFO> setting when you set I<check-local> to
C<disable> so both configurations (root or non-root) should work fine.

=cut
