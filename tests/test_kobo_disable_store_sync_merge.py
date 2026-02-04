import datetime

import cps.kobo as kobo
from cps import config, app


class DummyToken:
    books_last_modified = datetime.datetime.min
    books_last_created = datetime.datetime.min
    tags_last_modified = datetime.datetime.min

    def to_headers(self, headers: dict):
        # Any header is fine; generate_sync_response is resilient if SyncToken isn't available.
        headers["x-kobo-sync-token"] = "dummy"


def test_generate_sync_response_skips_store_merge_when_disabled(monkeypatch):
    # Save originals
    orig_proxy = getattr(config, "config_kobo_proxy", None)
    orig_disable = getattr(config, "config_kobo_disable_store_sync_merge", None)

    try:
        config.config_kobo_proxy = True
        config.config_kobo_disable_store_sync_merge = True

        def _boom(*args, **kwargs):
            raise AssertionError("make_request_to_kobo_store should not be called when store sync merge is disabled")

        monkeypatch.setattr(kobo, "make_request_to_kobo_store", _boom)

        with app.app_context():
            resp = kobo.generate_sync_response(DummyToken(), [], set_cont=False)
            assert resp.status_code == 200
    finally:
        # Restore
        if orig_proxy is None:
            try:
                delattr(config, "config_kobo_proxy")
            except Exception:
                pass
        else:
            config.config_kobo_proxy = orig_proxy

        if orig_disable is None:
            try:
                delattr(config, "config_kobo_disable_store_sync_merge")
            except Exception:
                pass
        else:
            config.config_kobo_disable_store_sync_merge = orig_disable
