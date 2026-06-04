# dev-lms-stubs

Tiny stand-ins for LMS Perl modules (`Slim::*`, `LWP::UserAgent`, `JSON::XS`),
used only to `perl -c` the LMS plugin in environments where LMS itself is not
installed (CI, dev machines, etc.).

**Not part of the plugin.** Do not copy this directory to the LMS `Plugins/`
location — it only exists so you can verify `Plugin.pm` / `Settings.pm` parse
cleanly.

Usage:

    perl -Idev-lms-stubs -c lms-plugin/Pandora/Plugin.pm
    perl -Idev-lms-stubs -c lms-plugin/Pandora/Settings.pm
