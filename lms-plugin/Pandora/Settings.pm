package Plugins::Pandora::Settings;

# Web UI for the Pandora plugin. The screen renders the helper status and
# a login form; submitting the form calls the helper's /auth endpoint, which
# persists the credentials to disk and starts a session.

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Web::HTTP;
use Slim::Web::Pages;

my $log   = logger('plugin.pandora');
my $prefs = preferences('plugin.pandora');

# Mounted at /plugins/Pandora/settings.html. See install.xml.
sub handler {
    my ($class, $client, $params, @args) = @_;

    my $body = _render($params);
    return Slim::Web::HTTP::filltemplatefile(
        $body, $params, $client);
}

# Form posts to the same URL with action=auth.
sub _render {
    my ($params) = @_;
    my $status = Plugins::Pandora::Plugin::getHelperStatus() || {};
    my $email  = $prefs->get('authEmail') // '';

    my $loggedIn  = $status->{logged_in} ? 'yes' : 'no';
    my $userId    = _h($status->{user_id}   // '');
    my $stations  = _h($status->{station_count} // 0);
    my $err       = _h($status->{error}     // '');
    my $hEmail    = _h($email);
    my $hHost     = _h($prefs->get('helperHost') // '127.0.0.1');
    my $hPort     = _h($prefs->get('helperPort') // 9123);

    my $msg = $params->{msg}     // '';
    my $merr = $params->{error}  // '';

    return <<"HTML";
<!doctype html>
<html><head><meta charset="utf-8"><title>Pandora</title>
<style>
  body { font: 14px/1.4 system-ui, sans-serif; max-width: 560px; margin: 2em auto; color: #222; }
  h1 { font-size: 1.2em; margin-top: 0; }
  .card { border: 1px solid #ddd; border-radius: 6px; padding: 1em 1.2em; margin: 1em 0; background: #fafafa; }
  .row { display: flex; align-items: center; gap: 0.6em; margin: 0.4em 0; }
  label { width: 8em; color: #555; }
  input[type=text], input[type=password], input[type=number] {
      flex: 1; padding: 0.4em 0.6em; border: 1px solid #ccc; border-radius: 4px; font: inherit;
  }
  button { padding: 0.5em 1em; border: 0; border-radius: 4px; background: #2d6cdf; color: #fff; cursor: pointer; }
  button:hover { background: #1f56b8; }
  .ok   { color: #1a7f37; }
  .bad  { color: #b42318; }
  code  { background: #eee; padding: 0 0.3em; border-radius: 3px; }
  .hint { color: #777; font-size: 0.85em; }
</style></head>
<body>
  <h1>Pandora plugin</h1>

  <div class="card">
    <strong>Helper status:</strong>
    <span class="${\($status->{logged_in} ? 'ok' : 'bad')}">
      ${\($status->{logged_in} ? 'logged in' : 'not logged in')}
    </span>
    ${\($userId ? qq{ (user <code>$userId</code>)} : '')}
    ${\($status->{logged_in} ? qq{ &mdash; $stations stations cached} : '')}
    ${\($err ? qq{ <div class="bad">$err</div>} : '')}
  </div>

  <div class="card">
    <h2 style="font-size:1em;margin:0 0 0.5em">Helper connection</h2>
    <form method="post" action="plugins/Pandora/settings.html">
      <input type="hidden" name="action" value="config">
      <div class="row"><label>Host</label><input type="text" name="helperHost" value="$hHost"></div>
      <div class="row"><label>Port</label><input type="number" name="helperPort" value="$hPort" min="1" max="65535"></div>
      <div class="row"><label></label><button type="submit">Save</button></div>
    </form>
    <div class="hint">Default: <code>127.0.0.1:9123</code>. The helper must be reachable from the LMS process.</div>
  </div>

  <div class="card">
    <h2 style="font-size:1em;margin:0 0 0.5em">Sign in to Pandora</h2>
    <form method="post" action="plugins/Pandora/settings.html">
      <input type="hidden" name="action" value="auth">
      <div class="row"><label>Email</label><input type="text" name="email" value="$hEmail" autocomplete="username"></div>
      <div class="row"><label>Password</label><input type="password" name="password" autocomplete="current-password"></div>
      <div class="row"><label></label><button type="submit">Sign in</button></div>
    </form>
    <div class="hint">Credentials are stored by the helper at
      <code>~/.config/windora/credentials.json</code> with mode 0600. They are
      never written to the LMS database.</div>
  </div>

  ${\($msg  ? qq{<div class="card ok">$msg</div>}  : '')}
  ${\($merr ? qq{<div class="card bad">$merr</div>} : '')}
</body></html>
HTML
}

# Form dispatcher. LMS routes POSTs to /plugins/Pandora/settings.html here
# with `action=auth` or `action=config`.
sub handler_post {
    my ($class, $client, $params, @args) = @_;

    my $action = $params->{action} // '';

    if ($action eq 'config') {
        $prefs->set('helperHost', $params->{helperHost} // '127.0.0.1');
        $prefs->set('helperPort', int($params->{helperPort} // 9123));
        return _redirect($params, msg => "Helper connection saved.");
    }

    if ($action eq 'auth') {
        my $email    = $params->{email}    // '';
        my $password = $params->{password} // '';
        unless ($email && $password) {
            return _redirect($params, error => "Email and password are required.");
        }
        my $resp = Plugins::Pandora::Plugin::authenticate($email, $password);
        $prefs->set('authEmail', $email);
        if ($resp && $resp->{ok}) {
            return _redirect($params, msg => "Signed in as $email.");
        }
        my $err = $resp->{error} // 'unknown error';
        return _redirect($params, error => "Pandora rejected the credentials: $err");
    }

    return _redirect($params, error => "Unknown action.");
}

sub _redirect {
    my ($params, %kv) = @_;
    my $qs = join('&', map { _urlEnc($_) . '=' . _urlEnc($kv{$_}) } keys %kv);
    return [302, ['Location' => "plugins/Pandora/settings.html?$qs"]];
}

sub _h {
    my $s = $_[0] // '';
    $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g;
    return $s;
}

sub _urlEnc {
    my ($s) = @_;
    $s //= '';
    $s =~ s/([^A-Za-z0-9_\-.\~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}

1;
