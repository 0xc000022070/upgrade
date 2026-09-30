use strict;
use warnings;
use IO::Socket::INET;
use JSON::PP;
use Time::HiRes qw(sleep time);

$SIG{CHLD} = 'IGNORE';

my $json = JSON::PP->new->canonical;
my $text = 'Mock Codex response streamed from the isolated host.';

my @rate_limit_headers = (
    'x-codex-primary-used-percent: 12',
    'x-codex-primary-window-minutes: 5',
    'x-codex-primary-reset-at: 4102444800',
    'x-codex-secondary-used-percent: 34',
    'x-codex-secondary-window-minutes: 10080',
    'x-codex-secondary-reset-at: 4102444800',
    'x-codex-credits-has-credits: true',
    'x-codex-credits-unlimited: false',
    'x-codex-credits-balance: 1000',
);

my $usage = {
    plan_type  => 'pro',
    rate_limit => {
        allowed        => JSON::PP::true,
        limit_reached  => JSON::PP::false,
        primary_window => {
            used_percent         => 12,
            limit_window_seconds => 300,
            reset_after_seconds  => 240,
            reset_at             => 4102444800,
        },
        secondary_window => {
            used_percent         => 34,
            limit_window_seconds => 604800,
            reset_after_seconds  => 86400,
            reset_at             => 4102444800,
        },
    },
    credits => {
        has_credits => JSON::PP::true,
        unlimited   => JSON::PP::false,
        balance     => '1000',
    },
};

sub write_json {
    my ($client, $status, $payload) = @_;
    my $body   = $json->encode($payload);
    my $reason = $status == 200 ? 'OK' : 'Not Found';
    print $client "HTTP/1.1 $status $reason\r\n"
      . "Content-Type: application/json\r\n"
      . 'Content-Length: ' . length($body) . "\r\n"
      . "Connection: close\r\n\r\n"
      . $body;
}

sub message {
    my ($id, $content) = @_;
    return {
        type    => 'message',
        role    => 'assistant',
        id      => $id,
        content => [ { type => 'output_text', text => $content } ],
    };
}

sub stream_response {
    my ($client) = @_;
    my $nonce       = int(time * 1e9);
    my $response_id = "fixture-$nonce";
    my $message_id  = "fixture-message-$nonce";
    my @events      = (
        { type => 'response.created', response => { id => $response_id } },
        { type => 'response.output_item.added', item => message($message_id, '') },
        (map { { type => 'response.output_text.delta', delta => $_ } }
            ('Mock Codex ', 'response streamed ', 'from the isolated host.')),
        { type => 'response.output_item.done', item => message($message_id, $text) },
        {
            type     => 'response.completed',
            response => {
                id    => $response_id,
                usage => {
                    input_tokens          => 120,
                    input_tokens_details  => { cached_tokens => 40 },
                    output_tokens         => 12,
                    output_tokens_details => { reasoning_tokens => 3 },
                    total_tokens          => 132,
                },
            },
        },
    );

    print $client "HTTP/1.1 200 OK\r\n"
      . "Content-Type: text/event-stream\r\n"
      . "Cache-Control: no-cache\r\n"
      . "Connection: close\r\n"
      . join('', map { "$_\r\n" } @rate_limit_headers)
      . "\r\n";
    for my $event (@events) {
        print $client "event: $event->{type}\ndata: " . $json->encode($event) . "\n\n";
        sleep 0.15;
    }
}

sub handle {
    my ($client) = @_;
    $client->autoflush(1);
    my $request_line = <$client> // return;
    my ($method, $target) = split ' ', $request_line;
    my $length = 0;
    while (my $line = <$client>) {
        last if $line =~ /^\r?\n$/;
        $length = $1 if $line =~ /^content-length:\s*(\d+)/i;
    }
    read($client, my $body, $length) if $length;
    (my $path = $target // '') =~ s/\?.*//;
    print STDERR "$method $target\n";

    return stream_response($client) if $method eq 'POST' && $path =~ m{/responses$};
    return write_json($client, 200, $usage) if $method eq 'GET' && $path =~ m{/wham/usage$};
    return write_json($client, 200, { credits => [], available_count => 0, total_earned_count => 0 })
      if $method eq 'GET' && $path =~ m{/wham/rate-limit-reset-credits$};
    return write_json($client, 200, { models => [] }) if $method eq 'GET' && $path =~ m{/models$};
    write_json($client, 404, { error => 'unsupported fixture endpoint', path => $path });
}

my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => $ARGV[0],
    Listen    => 16,
    ReuseAddr => 1,
) or die "listen: $!";
STDERR->autoflush(1);

while (my $client = $server->accept) {
    my $pid = fork;
    if (defined $pid && $pid == 0) {
        $server->close;
        handle($client);
        $client->close;
        exit 0;
    }
    $client->close;
}
