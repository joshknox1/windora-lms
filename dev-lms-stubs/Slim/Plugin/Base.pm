package Slim::Plugin::Base;
sub new { bless {}, shift }
sub initPlugin {}
sub postinitPlugin {}
sub registerMenu {}
1;
