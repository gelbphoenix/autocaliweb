import importlib

import pytest

import cps.kobo as kobo
from cps import config


def test_get_sync_item_limit_defaults_and_clamping():
    # Save original value
    orig = getattr(config, "config_kobo_sync_item_limit", None)
    try:
        # Default when not set
        if hasattr(config, "config_kobo_sync_item_limit"):
            delattr(config, "config_kobo_sync_item_limit")
        assert kobo.get_sync_item_limit() == 100

        # Valid numeric value
        config.config_kobo_sync_item_limit = 50
        assert kobo.get_sync_item_limit() == 50

        # Below minimum -> clamped to 10
        config.config_kobo_sync_item_limit = 5
        assert kobo.get_sync_item_limit() == 10

        # Above maximum -> clamped to 500
        config.config_kobo_sync_item_limit = 1000
        assert kobo.get_sync_item_limit() == 500

        # String value
        config.config_kobo_sync_item_limit = '25'
        assert kobo.get_sync_item_limit() == 25

        # Invalid value -> fallback to 100
        config.config_kobo_sync_item_limit = 'not-an-int'
        assert kobo.get_sync_item_limit() == 100

    finally:
        # Restore original
        if orig is None:
            try:
                delattr(config, "config_kobo_sync_item_limit")
            except Exception:
                pass
        else:
            config.config_kobo_sync_item_limit = orig
