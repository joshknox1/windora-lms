package Plugins::Pandora::Plugin;

# LMS plugin: Pandora stations via the Windora helper.
#
# The plugin is intentionally thin. All the Pandora protocol work lives in
# the windora-lms-helper Python service. This file only:
#   1. Registers a "Pandora" entry in LMS's "My Apps" menu.
#   2. Serves an OPML feed of the user's stations for the menu UI.
#   3. Handles two CLI queries: "play a station" and "get the next track".
#   4. Exposes helper status to the web UI for the Settings page.
#
# MVP scope (matches the chosen "stations + playback only" feature set):
#   - List stations as a menu
#   - Clicking a station starts playback of the first track and pre-queues
#     a small batch so playback continues without user action
#   - "Next" replaces the current track and re-fills the queue
#   - Ads are filtered server-side; the player only ever sees playable audio
#
# Known MVP limitations:
#   - The pre-queue only refills on user "play"/"next" actions. The current
#     batch plays through naturally, then stops. To keep going, pick the
#     station again or press next once.
#   - No thumbs up/down, no sleep, no station create/delete. v0.2.

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use JSON::XS;
use LWP::UserAgent;
use Slim::Control::Request;
use Slim::Menu::AppMenu;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Web::Pages;

my $log    = logger('plugin.pandora');
my $prefs  = preferences('plugin.pandora');
my $json   = JSON::XS->new->utf8->canonical(1);
my $ua     = LWP::UserAgent->new(
    agent   => 'windora-lms-plugin/0.1',
    timeout => 15,
);

# Per-client "what station is this player listening to?". Keyed by MAC.
my %currentStation;  # client_id => token

# How many tracks to pre-queue behind the one we just started.
use constant KEEP_AHEAD => 2;

# --- lifecycle -------------------------------------------------------------

sub initPlugin {
    my $class = shift;
    $class->SUPER::initPlugin(@_);

    # Web page function — serves the OPML menu for "My Apps → Pandora".
    Slim::Web::Pages->addPageFunction(
        'plugins/Pandora/opml.xml',
        \&_serveOpml,
    );

    # Icon for the menu entry. Drop your own PNG here, or remove the line
    # and LMS will use a default icon.
    Slim::Menu::AppMenu->addEntry('pandora', {
        name  => 'Pandora',
        type  => 'opml',
        url   => 'plugins/Pandora/opml.xml',
        icon  => 'plugins/Pandora/html/images/pandora.png',
    });

    # CLI queries.
    Slim::Control::Request::addDispatch([
        'pandora', 'play', 'xml', __PACKAGE__, 'handlePlay',
    ]);
    Slim::Control::Request::addDispatch([
        'pandora', 'next', 'xml', __PACKAGE__, 'handleNext',
    ]);
    Slim::Control::Request::addDispatch([
        'pandora', 'status', 'json', __PACKAGE__, 'handleStatus',
    ]);

    $log->info("Pandora plugin initialised (helper=%s:%s)",
        $prefs->get('helperHost') || '127.0.0.1',
        $prefs->get('helperPort') || 9123);
}

# --- web UI: OPML menu ----------------------------------------------------

sub _serveOpml {
    my ($client, $params) = @_;
    $log->info("Serving Pandora OPML menu");

    my $stations = helperGet('/stations');
    unless ($stations && ref $stations eq 'ARRAY') {
        return _errorPage("Pandora helper is unreachable, or you're not "
            . "logged in. Open Settings → Plugins → Pandora to sign in.");
    }

    my $body = '<?xml version="1.0" encoding="utf-8"?>' . "\n";
    $body .= "<opml version=\"2.0\">\n";
    $body .= "  <head><title>Pandora</title></head>\n";
    $body .= "  <body>\n";
    for my $s (@$stations) {
        my $name = $s->{name} // 'Untitled';
        my $qm   = $s->{is_quickmix} ? ' [QuickMix]' : '';
        $body .= "    <outline text=\"" . _xmlEscape("$name$qm")
              .  "\" type=\"link\" URL=\"pandora/play?token="
              .  _urlEncode($s->{id} // '') . "\"/>\n";
    }
    $body .= "  </body>\n</opml>\n";
    return $body;
}

# --- CLI handlers ---------------------------------------------------------

# Called when the user picks a station from the menu.
sub handlePlay {
    my ($request, $response) = @_;
    my $token = $request->getParam('token') || '';
    return _xmlError($response, "Missing station token") unless $token;

    my $track = _fetchNext($token);
    return _xmlError($response, $track->{_error}) if ref $track eq 'HASH' && $track->{_error};

    my $client = $request->client;
    return _xmlError($response, "No active player") unless $client;

    $currentStation{ $client->id } = $token;
    $client->execute(['playlist', 'play', _audioArgs($track)]);
    _queueFollowers($client, $token);

    $response->content_type('text/xml');
    $response->body('<slim><success/></slim>');
}

# Called when the user presses "next" on the player.
sub handleNext {
    my ($request, $response) = @_;
    my $client = $request->client;
    return _xmlError($response, "No active player") unless $client;

    my $token = $currentStation{ $client->id };
    unless ($token) {
        return _xmlError($response, "No station selected. Pick one from "
            . "My Apps → Pandora first.");
    }

    my $track = _fetchNext($token);
    return _xmlError($response, $track->{_error}) if ref $track eq 'HASH' && $track->{_error};

    $client->execute(['playlist', 'play', _audioArgs($track)]);
    _queueFollowers($client, $token);

    $response->content_type('text/xml');
    $response->body('<slim><success/></slim>');
}

# Called by the web UI to display helper status on the Settings page.
sub handleStatus {
    my ($request, $response) = @_;
    my $status = helperGet('/status') || { logged_in => 0, error => 'helper unreachable' };
    $response->content_type('application/json');
    $response->body($json->encode($status));
}

# --- queue keeping --------------------------------------------------------

# Add a small batch of follow-up tracks behind the currently-playing one
# so the player doesn't fall silent right after the first song ends.
sub _queueFollowers {
    my ($client, $token) = @_;
    return unless $client && $token;

    for (1..KEEP_AHEAD) {
        my $track = _fetchNext($token);
        last if ref $track eq 'HASH' && $track->{_error};
        $client->execute(['playlist', 'add', _audioArgs($track)]);
    }
}

# --- helpers --------------------------------------------------------------

sub helperBase {
    return sprintf('http://%s:%d',
        $prefs->get('helperHost') || '127.0.0.1',
        $prefs->get('helperPort') || 9123);
}

sub helperGet {
    my ($path) = @_;
    my $url = helperBase() . $path;
    my $resp = $ua->get($url, 'Cache-Control' => 'no-store');
    unless ($resp->is_success) {
        $log->warn("helper GET $url failed: " . $resp->status_line);
        return undef;
    }
    my $data = eval { $json->decode($resp->decoded_content) };
    if ($@) {
        $log->error("helper GET $url returned non-JSON: $@");
        return undef;
    }
    return $data;
}

sub helperPost {
    my ($path, $payload) = @_;
    my $url = helperBase() . $path;
    my $body = $json->encode($payload);
    my $resp = $ua->post($url,
        'Content-Type' => 'application/json',
        'Cache-Control' => 'no-store',
        Content         => $body,
    );
    unless ($resp->is_success) {
        return { ok => 0, error => $resp->status_line, _status => $resp->code };
    }
    my $data = eval { $json->decode($resp->decoded_content) };
    if ($@) {
        return { ok => 0, error => "non-JSON response" };
    }
    return $data;
}

sub _fetchNext {
    my ($token) = @_;
    my $path = '/station/' . _urlEncode($token) . '/next';
    my $track = helperGet($path);
    unless ($track && ref $track eq 'HASH' && $track->{audio_url}) {
        my $err = $track->{error} // 'no track returned';
        return { _error => "Pandora: $err" };
    }
    return $track;
}

# LMS audio item format: title|artist|album|duration|bitrate|cover|url
# (URL is last — that's the LMS convention).
sub _audioArgs {
    my ($track) = @_;
    my @parts = (
        $track->{title}         // '',
        $track->{artist}        // '',
        $track->{album}         // '',
        $track->{duration_s}    // '',
        $track->{bitrate_kbps}  // '',
        $track->{album_art_url} // '',
        $track->{audio_url}     // '',
    );
    return join('|', @parts);
}

sub _xmlError {
    my ($response, $msg) = @_;
    $response->content_type('text/xml');
    $response->body('<?xml version="1.0" encoding="utf-8"?><slim>'
        . '<error>' . _xmlEscape($msg) . '</error></slim>');
    return undef;
}

sub _errorPage {
    my ($msg) = @_;
    return '<?xml version="1.0" encoding="utf-8"?><opml version="2.0"><body>'
        . '<outline text="' . _xmlEscape($msg) . '"/></body></opml>';
}

sub _xmlEscape {
    my ($s) = @_;
    $s //= '';
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

sub _urlEncode {
    my ($s) = @_;
    $s //= '';
    $s =~ s/([^A-Za-z0-9_\-.\~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}

# Exposed for Settings.pm.
sub authenticate {
    my ($email, $password) = @_;
    return helperPost('/auth', { email => $email, password => $password });
}

sub getHelperStatus {
    return helperGet('/status');
}

1;
