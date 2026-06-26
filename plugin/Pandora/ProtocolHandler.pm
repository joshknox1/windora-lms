package Plugins::Pandora::ProtocolHandler;

# The piece that makes Pandora behave like real LMS radio.
#
# A station is represented by the pseudo-URL  pandora://<stationToken> .
# Because isRepeatingStream() is true, LMS asks us for "the next track" every
# time the current one ends (or the user hits Next/skip). For each request we
# call the helper's /station/<token>/next, which hands back ONE freshly-signed
# Pandora CDN URL. We point the song's stream at that URL and let the parent
# HTTP protocol handler do the actual streaming.
#
# This avoids the trap the first attempt fell into: pre-stuffing the LMS
# playlist with several Pandora URLs that expire (~30-60s) before the player
# ever reaches them.

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTP);

use Slim::Utils::Log;
use Slim::Utils::Errno;
use Slim::Player::ProtocolHandlers;
use Slim::Networking::SimpleAsyncHTTP;

use Plugins::Pandora::Plugin;

my $log = logger('plugin.pandora');

# Current track metadata, keyed by the master player's id, so the now-playing
# screen and CLI status can show title/artist/album/cover.
my %currentMeta;

Slim::Player::ProtocolHandlers->registerHandler('pandora', __PACKAGE__);

sub isRemote { 1 }

# Stations never end — keep asking us for the next track.
sub isRepeatingStream { 1 }

# We resolve a fresh URL per track, so don't let LMS cache/seek the station URL.
sub canSeek { 0 }
sub canDoAction { 0 }

# A pandora:// url has no fixed format LMS can scan; treat it as audio.
sub isAudioURL { 1 }

sub getFormatForURL {
    my ($class, $url) = @_;
    # Pandora (iPhone partner) serves 64k HE-AAC in an .mp4 container. The
    # android partner — which used to give MP3 — is rejected by Pandora now,
    # so everything is AAC. LMS transcodes it via ffmpeg/faad for the player.
    # If a real stream URL is passed, still honour an explicit mp3 extension.
    return 'mp3' if $url =~ /\.mp3\b/i;
    return 'aac';
}

# Pull the station token out of pandora://<token>.
sub _stationToken {
    my ($url) = @_;
    my ($token) = $url =~ m{^pandora://(.+)$};
    return $token;
}

# Called by LMS each time it needs the next song for a repeating station.
sub getNextTrack {
    my ($class, $song, $successCb, $errorCb) = @_;

    my $stationToken = _stationToken($song->track->url);
    unless ($stationToken) {
        return $errorCb->('Not a Pandora station URL');
    }

    my $client = $song->master;

    Plugins::Pandora::Plugin::helperAsyncGet(
        '/station/' . Plugins::Pandora::Plugin::urlEncode($stationToken) . '/next',
        sub {
            my $track = shift;  # decoded JSON hashref

            if (!$track || ref $track ne 'HASH' || !$track->{audio_url}) {
                my $err = (ref $track eq 'HASH' && $track->{error})
                          ? $track->{error} : 'no track returned';
                $log->warn("getNextTrack: $err");
                return $errorCb->("Pandora: $err");
            }

            # Point the song at the real, freshly-signed CDN URL.
            $song->streamUrl($track->{audio_url});

            if (my $br = $track->{bitrate_kbps}) {
                $song->bitrate($br * 1000);
            }
            if (my $secs = $track->{duration_s}) {
                $song->duration($secs);
            }

            # Pick a format from the stream URL extension (mp3 vs aac/m4a).
            my $fmt = 'mp3';
            $fmt = 'aac' if $track->{audio_url} =~ /\.(?:aac|m4a|mp4)\b/i;
            $song->pluginData(format => $fmt);

            my $meta = {
                title    => $track->{title}         // '',
                artist   => $track->{artist}        // '',
                album    => $track->{album}         // '',
                cover    => $track->{album_art_url} // __PACKAGE__->getIcon,
                icon     => $track->{album_art_url} // __PACKAGE__->getIcon,
                bitrate  => $track->{bitrate_kbps} ? ($track->{bitrate_kbps} . 'k') : undef,
                duration => $track->{duration_s},
                type     => 'Pandora',
                track_token   => $track->{track_token},
                station_token => $stationToken,
            };
            $song->pluginData(meta => $meta);
            $currentMeta{ $client->id } = $meta if $client;

            $log->info(sprintf('Now playing: %s - %s', $meta->{artist}, $meta->{title}));
            $successCb->();
        },
        sub {
            my $error = shift // 'helper unreachable';
            $log->error("getNextTrack helper error: $error");
            $errorCb->("Pandora helper: $error");
        },
    );
}

# Open the resolved CDN URL. By the time LMS calls new(), getNextTrack() has
# already set $song->streamUrl to the real http(s) URL.
sub new {
    my ($class, $args) = @_;

    my $song = $args->{song};
    my $streamUrl = $song->streamUrl || return;

    $log->debug("Opening stream: $streamUrl");
    $args->{url} = $streamUrl;

    return $class->SUPER::new($args);
}

# Metadata for the now-playing screen / CLI. LMS calls this as
# ($class, $client, $url, $forceCurrent).
sub getMetadataFor {
    my ($class, $client, $url) = @_;

    # Prefer the live song's stashed metadata, then the per-player fallback.
    if ($client) {
        my $song = $client->playingSong;
        if ($song && (my $m = $song->pluginData('meta'))) {
            return $m;
        }
        if (my $cm = $currentMeta{ $client->master->id }) {
            return $cm;
        }
    }
    return {
        title => 'Pandora',
        cover => $class->getIcon,
        icon  => $class->getIcon,
        type  => 'Pandora',
    };
}

sub getIcon {
    return 'plugins/Pandora/html/images/pandora.png';
}

# Helpers used by the menu/CLI for thumbs + sleep (v0.2 wiring).
sub currentTrackToken {
    my ($class, $client) = @_;
    return unless $client;
    my $m = $currentMeta{ $client->master->id } or return;
    return $m->{track_token};
}

1;
