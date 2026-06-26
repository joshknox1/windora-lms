package Plugins::Pandora::Plugin;

# Thin LMS plugin: shows your Pandora stations under "My Apps" and hands
# playback off to Plugins::Pandora::ProtocolHandler (pandora:// URLs).
#
# All Pandora protocol work lives in the windora-lms-helper Python service on
# the LMS host; this plugin only talks to it over localhost HTTP.

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use JSON::XS;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::Pandora::ProtocolHandler;

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.pandora',
    defaultLevel => 'INFO',
    description  => 'PLUGIN_PANDORA',
});

my $prefs = preferences('plugin.pandora');

$prefs->init({
    helperHost => '127.0.0.1',
    helperPort => 9123,
    authEmail  => '',
});

my $json = JSON::XS->new->utf8->canonical(1);

# --- lifecycle -------------------------------------------------------------

sub initPlugin {
    my $class = shift;

    $class->SUPER::initPlugin(
        feed   => \&stationsFeed,
        tag    => 'pandora',
        menu   => 'radios',
        is_app => 1,
        weight => 10,
    );

    if (main::WEBUI) {
        require Plugins::Pandora::Settings;
        Plugins::Pandora::Settings->new;
    }

    $log->info(sprintf('Pandora plugin initialised (helper=%s)', helperBase()));
}

sub getDisplayName { 'PLUGIN_PANDORA' }

# This is an "app", so it appears under My Apps.
sub playerMenu { }

# --- station menu (OPML feed) ---------------------------------------------

# OPMLBased async feed: ($client, $callback, $args).
sub stationsFeed {
    my ($client, $callback, $args) = @_;

    helperAsyncGet('/stations',
        sub {
            my $stations = shift;

            unless ($stations && ref $stations eq 'ARRAY') {
                return $callback->(_messageOpml(string('PLUGIN_PANDORA_NOT_SIGNED_IN')));
            }

            my @items = map {
                my $name = $_->{name} // 'Untitled';
                $name .= ' [QuickMix]' if $_->{is_quickmix};
                {
                    name      => $name,
                    type      => 'audio',
                    url       => 'pandora://' . ($_->{token} // ''),
                    play      => 'pandora://' . ($_->{token} // ''),
                    on_select => 'play',
                    icon      => Plugins::Pandora::ProtocolHandler->getIcon,
                };
            } @$stations;

            @items = ({ name => string('PLUGIN_PANDORA_NO_STATIONS'), type => 'text' })
                unless @items;

            $callback->({
                type  => 'opml',
                title => 'Pandora',
                items => \@items,
            });
        },
        sub {
            my $error = shift // 'helper unreachable';
            $callback->(_messageOpml(
                string('PLUGIN_PANDORA_HELPER_ERROR') . ": $error"));
        },
    );
}

sub _messageOpml {
    my ($msg) = @_;
    return {
        type  => 'opml',
        title => 'Pandora',
        items => [ { name => $msg, type => 'text' } ],
    };
}

# --- helper service plumbing ----------------------------------------------

sub helperBase {
    return sprintf('http://%s:%d',
        $prefs->get('helperHost') || '127.0.0.1',
        $prefs->get('helperPort') || 9123);
}

# Async GET — decodes JSON and calls $okCb->($data) / $errCb->($message).
sub helperAsyncGet {
    my ($path, $okCb, $errCb) = @_;
    my $url = helperBase() . $path;

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $data = eval { $json->decode($http->content) };
            if ($@) {
                $log->error("helper GET $url: non-JSON response: $@");
                return $errCb->('bad response from helper');
            }
            $okCb->($data);
        },
        sub {
            my ($http, $error) = @_;
            $log->warn("helper GET $url failed: " . ($error // 'unknown'));
            $errCb->($error // 'unreachable');
        },
        { timeout => 15 },
    )->get($url, 'Cache-Control' => 'no-store');
}

# Sync GET — used by the settings page only. Returns decoded JSON or undef.
sub helperGet {
    my ($path) = @_;
    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new(agent => 'windora-lms-plugin/0.1', timeout => 10);
    my $resp = $ua->get(helperBase() . $path, 'Cache-Control' => 'no-store');
    return undef unless $resp->is_success;
    my $data = eval { $json->decode($resp->decoded_content) };
    return $@ ? undef : $data;
}

# Sync POST — used by the settings page sign-in. Returns decoded JSON hashref.
sub helperPost {
    my ($path, $payload) = @_;
    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new(agent => 'windora-lms-plugin/0.1', timeout => 20);
    my $resp = $ua->post(helperBase() . $path,
        'Content-Type'  => 'application/json',
        'Cache-Control' => 'no-store',
        Content         => $json->encode($payload),
    );
    unless ($resp->is_success) {
        my $data = eval { $json->decode($resp->decoded_content) };
        return (ref $data eq 'HASH') ? $data
            : { ok => 0, error => $resp->status_line };
    }
    my $data = eval { $json->decode($resp->decoded_content) };
    return $@ ? { ok => 0, error => 'non-JSON response' } : $data;
}

# Exposed for Settings.pm.
sub authenticate {
    my ($email, $password) = @_;
    return helperPost('/auth', { email => $email, password => $password });
}

sub getHelperStatus {
    return helperGet('/status');
}

sub urlEncode {
    my ($s) = @_;
    $s //= '';
    $s =~ s/([^A-Za-z0-9_\-.\~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}

1;
