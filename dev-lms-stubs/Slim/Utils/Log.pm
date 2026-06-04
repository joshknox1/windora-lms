package Slim::Utils::Log;
sub logger { bless {}, shift }
sub debug  { print "DEBUG: @_\n" }
sub info   { print "INFO: @_\n" }
sub warn   { print "WARN: @_\n" }
sub error  { print "ERROR: @_\n" }
1;
