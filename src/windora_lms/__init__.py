"""windora-lms — Pandora streaming for Logitech Media Server.

Two parts:

* `windora_lms.pandora.*` — vendored copy of the reverse-engineered Pandora
  JSON protocol (originally from the Windora Windows client). Keep in sync
  with https://github.com/anomalyco/windora — see ``scripts/sync-from-windora.sh``.

* `windora_lms.lms_helper` — the HTTP service the LMS Perl plugin talks to.
  Run it via ``python -m windora_lms.lms_helper`` or the
  ``windora-lms-helper`` console script installed by ``pip install .``.
"""

__version__ = "0.1.0"
