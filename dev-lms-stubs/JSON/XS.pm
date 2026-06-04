package JSON::XS;
sub new { bless {}, shift }
sub utf8 { $_[0] }
sub canonical { $_[0] }
sub decode { $_[1] }
sub encode { "$_[1]" }
1;
