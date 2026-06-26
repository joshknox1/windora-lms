package Plugins::Pandora::Settings;

# LMS web settings page: helper connection + Pandora sign-in.
#
# helperHost/helperPort are ordinary prefs the base class saves for us. The
# Pandora email/password are NOT stored in the LMS prefs DB — submitting the
# sign-in form POSTs them to the helper, which validates against Pandora and
# persists them itself (0600) on the helper host.

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.pandora');
my $prefs = preferences('plugin.pandora');

sub name { 'PLUGIN_PANDORA' }

sub page { 'plugins/Pandora/settings/basic.html' }

sub prefs {
    return ($prefs, qw(helperHost helperPort));
}

sub handler {
    my ($class, $client, $params, $callback, @args) = @_;

    # Sign-in submission (separate from the standard prefs save).
    if ($params->{signin} && $params->{pref_email}) {
        my $email = $params->{pref_email};
        my $pass  = $params->{pref_password} // '';

        if (!length $pass) {
            $params->{warning} = Slim::Utils::Strings::string('PLUGIN_PANDORA_NEED_PASSWORD');
        }
        else {
            my $resp = Plugins::Pandora::Plugin::authenticate($email, $pass);
            if ($resp && $resp->{ok}) {
                $prefs->set('authEmail', $email);
                $params->{warning} =
                    Slim::Utils::Strings::string('PLUGIN_PANDORA_SIGNED_IN') . " $email";
            }
            else {
                my $err = ($resp && $resp->{error}) || 'unknown error';
                $params->{warning} =
                    Slim::Utils::Strings::string('PLUGIN_PANDORA_SIGNIN_FAILED') . " $err";
            }
        }
    }

    # Surface live helper status to the template.
    my $status = Plugins::Pandora::Plugin::getHelperStatus();
    if ($status) {
        $params->{helperReachable} = 1;
        $params->{helperLoggedIn}  = $status->{logged_in} ? 1 : 0;
        $params->{helperUserId}    = $status->{user_id};
        $params->{helperStations}  = $status->{station_count};
    }
    else {
        $params->{helperReachable} = 0;
    }

    $params->{prefs}->{authEmail} = $prefs->get('authEmail');

    return $class->SUPER::handler($client, $params, $callback, @args);
}

1;
