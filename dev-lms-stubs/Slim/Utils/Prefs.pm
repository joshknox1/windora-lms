package Slim::Utils::Prefs;
sub preferences { bless { store => {} }, shift }
sub get { my ($s, $k) = @_; $s->{store}{$k} }
sub set { my ($s, $k, $v) = @_; $s->{store}{$k} = $v; 1 }
1;
