package LWP::UserAgent;
sub new { bless {}, shift }
sub get {
    my ($self, $url, %h) = @_;
    bless { is_success => 0, status_line => "stub", decoded_content => "" }, 'LWP::Response';
}
sub post {
    my ($self, $url, %h) = @_;
    bless { is_success => 0, status_line => "stub", decoded_content => "" }, 'LWP::Response';
}
package LWP::Response;
sub is_success { $_[0]->{is_success} }
sub status_line { $_[0]->{status_line} }
sub decoded_content { $_[0]->{decoded_content} }
1;
