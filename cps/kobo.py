#!/usr/bin/env python
# -*- coding: utf-8 -*-

#  This file is part of the Calibre-Web (https://github.com/janeczku/calibre-web)
#    Copyright (C) 2018-2019 shavitmichael, OzzieIsaacs
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program. If not, see <http://www.gnu.org/licenses/>.

import base64
import json
import os
import threading
import time
import uuid
import zipfile
from datetime import datetime, timezone
from time import gmtime, strftime
from typing import Any, cast
from urllib.parse import unquote

import requests
from flask import (
    Blueprint,
    Response,
    abort,
    current_app,
    jsonify,
    make_response,
    redirect,
    request,
    url_for,
)
from sqlalchemy import func, literal
from sqlalchemy.exc import StatementError
from sqlalchemy.sql.expression import and_, or_
from werkzeug.datastructures import Headers

from .cw_login import current_user

try:
    from urllib3.util.retry import Retry
except Exception:  # pragma: no cover
    Retry = None

from . import (
    calibre_db,
    config,
    csrf,
    db,
    helper,
    isoLanguages,
    kobo_auth,
    kobo_sync_status,
    logger,
    ub,
)
from . import shelf as shelf_lib
from .constants import (
    COVER_THUMBNAIL_LARGE,
    COVER_THUMBNAIL_MEDIUM,
    COVER_THUMBNAIL_SMALL,
)
from .epub import get_epub_layout
from .generated_shelves import generated_shelf_filter, list_generated_shelves
from .helper import get_download_link
from .kobo_auth import get_auth_token, requires_kobo_auth
from .services import SyncToken as SyncToken
from .services import hardcover
from .web import download_required

KOBO_FORMATS = {"KEPUB": ["KEPUB"], "EPUB": ["EPUB3", "EPUB"]}
KOBO_STOREAPI_URL = "https://storeapi.kobo.com"
KOBO_IMAGEHOST_URL = "https://cdn.kobo.com/book-images"


def get_sync_item_limit(user=None):
    """Return the configured sync item limit clamped to [10, 500].

    This controls how many items (books, reading states, and collections)
    are included in a single sync response to the device.

    Priority: user setting > global config > default (100).
    """
    limit = 100
    try:
        # First try user-level setting
        if user is not None:
            user_limit = getattr(user, "kobo_sync_item_limit", None)
            if user_limit is not None:
                limit = int(user_limit)
            else:
                # Fall back to global config
                limit = int(getattr(config, "config_kobo_sync_item_limit", 100) or 100)
        else:
            limit = int(getattr(config, "config_kobo_sync_item_limit", 100) or 100)
    except Exception:
        limit = 100
    return max(10, min(500, limit))


def get_user_kobo_collections_mode(user=None):
    """Get the Kobo collections sync mode for a user.

    Returns: "all", "selected", or "hybrid"
    Priority: user setting > global config > default ("selected").
    """
    mode = "selected"
    try:
        # First try user-level setting
        if user is not None:
            user_mode = getattr(user, "kobo_sync_collections_mode", None)
            if user_mode:
                mode = user_mode.strip().lower()
            else:
                # Fall back to global config
                mode = (
                    (
                        getattr(config, "config_kobo_sync_collections_mode", "selected")
                        or "selected"
                    )
                    .strip()
                    .lower()
                )
        else:
            mode = (
                (
                    getattr(config, "config_kobo_sync_collections_mode", "selected")
                    or "selected"
                )
                .strip()
                .lower()
            )
    except Exception:
        mode = "selected"
    if mode not in ("all", "selected", "hybrid"):
        mode = "selected"
    return mode


def get_user_generated_shelves_sync(user=None):
    """Check if user has generated shelves sync enabled.

    Returns True if:
    1. User has explicitly enabled generated shelves sync in their settings, OR
    2. User has any generated shelves marked for Kobo sync in GeneratedShelfKoboSync table
    """
    try:
        if user is not None:
            # First check explicit user setting - if True, return immediately
            user_setting = getattr(user, "kobo_generated_shelves_sync", False)
            if user_setting:
                return True

            # Check if user has ANY generated shelves enabled for sync
            # This allows per-shelf control without needing a master toggle
            try:
                enabled_count = (
                    ub.session.query(ub.GeneratedShelfKoboSync)
                    .filter(
                        ub.GeneratedShelfKoboSync.user_id == user.id,
                        ub.GeneratedShelfKoboSync.kobo_sync == True,
                    )
                    .count()
                )
                if enabled_count > 0:
                    log.debug(
                        "get_user_generated_shelves_sync: user %s has %d generated shelves enabled",
                        user.id,
                        enabled_count,
                    )
                    return True
            except Exception as e:
                log.warning(
                    "get_user_generated_shelves_sync: error checking GeneratedShelfKoboSync: %s",
                    e,
                )

            # Default: generated shelves not enabled
            return False
        else:
            return False
    except Exception as e:
        log.warning("get_user_generated_shelves_sync: unexpected error: %s", e)
        return False


def get_user_generated_shelves_all_books(user=None):
    """Check if generated shelves should include all library books.

    User setting controls this; defaults to False (only books in Kobo-synced shelves).
    """
    try:
        if user is not None:
            user_setting = getattr(user, "kobo_generated_shelves_all_books", None)
            if user_setting is not None:
                return bool(user_setting)
            else:
                return False  # Default: only books in kobo-synced shelves
        else:
            return False
    except Exception:
        return False


def get_user_sync_empty_collections(user=None):
    """Check if user wants to sync empty collections (shelves with 0 books).

    User setting controls this; defaults to False (skip empty collections).
    """
    try:
        if user is not None:
            user_setting = getattr(user, "kobo_sync_empty_collections", None)
            if user_setting is not None:
                return bool(user_setting)
            else:
                return False  # Default: don't sync empty collections
        else:
            return False
    except Exception:
        return False


# Reusable session for Kobo store proxy requests (connection pooling)
_kobo_store_session = None
_kobo_store_session_lock = threading.Lock()


def _build_kobo_store_retry():
    if Retry is None:
        return 1

    allowed = frozenset(["HEAD", "GET", "POST", "PUT", "DELETE", "OPTIONS"])
    try:
        return Retry(
            total=3,
            connect=3,
            read=3,
            status=3,
            backoff_factor=0.5,
            status_forcelist=(500, 502, 503, 504),
            raise_on_status=False,
            respect_retry_after_header=True,
            allowed_methods=allowed,
        )
    except TypeError:
        # urllib3 < 1.26
        retry_cls = cast(Any, Retry)
        return retry_cls(
            total=3,
            connect=3,
            read=3,
            status=3,
            backoff_factor=0.5,
            status_forcelist=(500, 502, 503, 504),
            raise_on_status=False,
            respect_retry_after_header=True,
            method_whitelist=allowed,
        )


def _get_kobo_store_session():
    """Get or create a reusable requests session for Kobo store API calls."""
    global _kobo_store_session
    if _kobo_store_session is None:
        with _kobo_store_session_lock:
            if _kobo_store_session is None:
                _kobo_store_session = requests.Session()
                # Configure connection pooling
                adapter = requests.adapters.HTTPAdapter(
                    pool_connections=5,
                    pool_maxsize=10,
                    max_retries=_build_kobo_store_retry(),
                )
                _kobo_store_session.mount("https://", adapter)
    return _kobo_store_session


_kobo_last_calibre_reconnect_mono = None


def _maybe_reconnect_calibre_db(*, force=False, min_interval_seconds=15):
    """Reconnect calibre DB sparingly.

    Kobo sync can take many round-trips; reconnecting on every request is expensive.
    We reconnect at most once per short window, and optionally force reconnect.
    """
    global _kobo_last_calibre_reconnect_mono
    now = time.monotonic()
    try:
        last = _kobo_last_calibre_reconnect_mono
        should = force or last is None or (now - last) >= float(min_interval_seconds)
        if not should:
            return
        calibre_db.reconnect_db(config, ub.app_DB_path)
        _kobo_last_calibre_reconnect_mono = now
    except Exception as e:
        log.debug("Kobo: calibre_db.reconnect_db failed: %s", e)


kobo = Blueprint("kobo", __name__, url_prefix="/kobo/<auth_token>")
kobo_auth.disable_failed_auth_redirect_for_blueprint(kobo)
kobo_auth.register_url_value_preprocessor(kobo)

log = logger.create()


_kobo_cover_telemetry_lock = threading.Lock()
_kobo_cover_telemetry = {}


def _kobo_cover_telemetry_enabled() -> bool:
    return os.environ.get("ACW_KOBO_COVER_TELEMETRY", "0") in {
        "1",
        "true",
        "TRUE",
        "yes",
        "YES",
    }


def _record_kobo_cover_telemetry(user_id, book_uuid, resolution):
    if not _kobo_cover_telemetry_enabled():
        return None
    now_wall = datetime.now(timezone.utc)
    now_mono = time.monotonic()
    with _kobo_cover_telemetry_lock:
        entry = _kobo_cover_telemetry.get(user_id)
        if not entry:
            entry = {
                "count": 0,
                "first_wall": now_wall,
                "last_wall": None,
                "last_mono": None,
                "last_uuid": None,
                "last_resolution": None,
            }
            _kobo_cover_telemetry[user_id] = entry

        prev_last_mono = entry.get("last_mono")
        entry["count"] = int(entry.get("count") or 0) + 1
        entry["last_wall"] = now_wall
        entry["last_mono"] = now_mono
        entry["last_uuid"] = book_uuid
        entry["last_resolution"] = resolution

    since_prev = None
    try:
        if prev_last_mono is not None:
            since_prev = now_mono - prev_last_mono
    except Exception:
        since_prev = None

    return {
        "count": entry["count"],
        "last_wall": now_wall,
        "since_prev": since_prev,
        "last_uuid": book_uuid,
        "last_resolution": resolution,
    }


def _log_kobo_cover_telemetry_snapshot(user_id, context: str):
    if not _kobo_cover_telemetry_enabled():
        return
    with _kobo_cover_telemetry_lock:
        entry = _kobo_cover_telemetry.get(user_id)
        if not entry:
            log.debug("Kobo cover telemetry (%s): user_id=%s no data", context, user_id)
            return
        last_wall = entry.get("last_wall")
        first_wall = entry.get("first_wall")
        count = entry.get("count")
        last_uuid = entry.get("last_uuid")
        last_resolution = entry.get("last_resolution")
    now_wall = datetime.now(timezone.utc)
    since_last_s = None
    try:
        if last_wall:
            since_last_s = (now_wall - last_wall).total_seconds()
    except Exception:
        since_last_s = None
    log.debug(
        "Kobo cover telemetry (%s): user_id=%s count=%s first=%s last=%s since_last_s=%s last_uuid=%s last_res=%s",
        context,
        user_id,
        count,
        first_wall,
        last_wall,
        since_last_s,
        last_uuid,
        last_resolution,
    )


def _redact_auth_token_in_path(path: str) -> str:
    if not path:
        return path
    marker = "/kobo/"
    try:
        idx = path.find(marker)
        if idx == -1:
            return path
        after = path[idx + len(marker) :]
        slash = after.find("/")
        if slash == -1:
            return path[: idx + len(marker)] + "<token>"
        return path[: idx + len(marker)] + "<token>" + after[slash:]
    except Exception:
        return path


def _effective_only_kobo_shelves_sync(user=None):
    """Determine whether book sync should be restricted to kobo_sync-enabled shelves.

    Returns False (sync all books) when mode is "all".
    Returns True (restrict to kobo_sync shelves) for "selected" or "hybrid" modes.
    """
    mode = get_user_kobo_collections_mode(user)
    return mode in ("selected", "hybrid")


def get_store_url_for_current_request():
    # Programmatically modify the current url to point to the official Kobo store
    __, __, request_path_with_auth_token = request.full_path.rpartition("/kobo/")
    __, __, request_path = request_path_with_auth_token.rstrip("?").partition("/")
    return KOBO_STOREAPI_URL + "/" + request_path


CONNECTION_SPECIFIC_HEADERS = [
    "connection",
    "content-encoding",
    "content-length",
    "transfer-encoding",
]


def get_kobo_activated():
    return config.config_kobo_sync


def make_request_to_kobo_store(sync_token=None):
    outgoing_headers = Headers(request.headers)
    outgoing_headers.remove("Host")
    if sync_token:
        sync_token.set_kobo_store_header(outgoing_headers)

    store_url = get_store_url_for_current_request()
    started = time.monotonic()

    # Use session for connection pooling
    session = _get_kobo_store_session()
    store_response = session.request(
        method=request.method,
        url=store_url,
        headers=dict(outgoing_headers),
        data=request.get_data(),
        allow_redirects=False,
        timeout=(2, 10),
    )
    elapsed_ms = int((time.monotonic() - started) * 1000)
    log.debug(
        "Kobo proxy %s %s -> %s (%sms)",
        request.method,
        _redact_auth_token_in_path(
            getattr(request, "full_path", "") or getattr(request, "path", "")
        ),
        store_url,
        elapsed_ms,
    )
    log.debug("Content: " + str(store_response.content))
    log.debug("StatusCode: " + str(store_response.status_code))
    return store_response


def redirect_or_proxy_request(auth=False):
    if config.config_kobo_proxy:
        try:
            if request.method == "GET":
                alfa = redirect(get_store_url_for_current_request(), 307)
                return alfa
            else:
                # The Kobo device turns other request types into GET requests on redirects,
                # so we instead proxy to the Kobo store ourselves.
                store_response = make_request_to_kobo_store()
                return make_proxy_response(store_response)
        except Exception as e:
            log.error(
                "Failed to receive or parse response from Kobo's endpoint: {}".format(e)
            )
            if auth:
                return make_calibre_web_auth_response()
    return make_response(jsonify({}))


def make_proxy_response(store_response: requests.Response) -> Response:
    headers = store_response.headers

    for key in CONNECTION_SPECIFIC_HEADERS:
        headers.pop(key, default=None)

    return make_response(
        store_response.content, store_response.status_code, headers.items()
    )


def convert_to_kobo_timestamp_string(timestamp):
    try:
        return timestamp.strftime("%Y-%m-%dT%H:%M:%SZ")
    except AttributeError as exc:
        log.debug("Timestamp not valid: {}".format(exc))
        return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@kobo.route("/v1/library/sync")
@requires_kobo_auth
# @download_required
def HandleSyncRequest():
    if not current_user.role_download():
        log.info("Users need download permissions for syncing library to Kobo reader")
        return abort(403)
    sync_token = SyncToken.SyncToken.from_headers(request.headers)
    log.info("Kobo library sync request received")
    log.debug("SyncToken: {}".format(sync_token))
    log.debug(
        "Download link format {}".format(
            get_download_url_for_book("[bookid]", "[bookformat]")
        )
    )
    if not current_app.wsgi_app.is_proxied:
        log.debug(
            "Kobo: Received unproxied request, changed request port to external server port"
        )

    # if no books synced don't respect sync_token
    if (
        not ub.session.query(ub.KoboSyncedBooks)
        .filter(ub.KoboSyncedBooks.user_id == current_user.id)
        .count()
    ):
        sync_token.books_last_modified = datetime.min
        sync_token.books_last_created = datetime.min
        sync_token.reading_state_last_modified = datetime.min
        sync_token.tags_last_modified = (
            datetime.min
        )  # Reset to resync all shelves/collections

    new_books_last_modified = (
        sync_token.books_last_modified
    )  # needed for sync selected shelfs only
    new_books_last_created = (
        sync_token.books_last_created
    )  # needed to distinguish between new and changed entitlement
    new_reading_state_last_modified = sync_token.reading_state_last_modified

    new_archived_last_modified = datetime.min
    sync_results = []

    # We reload the book database so that the user gets a fresh view of the library
    # in case of external changes (e.g: adding a book through Calibre). Kobo sync can
    # involve many round-trips, so reconnect sparingly.
    force_reconnect = (
        sync_token.books_last_modified == datetime.min
        or sync_token.books_last_created == datetime.min
        or sync_token.reading_state_last_modified == datetime.min
        or sync_token.tags_last_modified == datetime.min
    )
    _maybe_reconnect_calibre_db(force=force_reconnect)
    # Do not trigger a full-library thumbnail generation pass during Kobo sync.
    # That job can be CPU-heavy (ImageMagick/Wand) and makes the device appear stuck
    # on "Downloading book covers" while requests slow down.
    # Use the scheduler/admin task to generate thumbnails instead.

    kobo_collections_mode = get_user_kobo_collections_mode(current_user)
    kobo_opt_in_shelf_name = "Kobo Sync"
    hybrid_opt_in_book_ids = set()

    if kobo_collections_mode == "hybrid":
        try:
            opt_in_shelf = (
                ub.session.query(ub.Shelf)
                .filter(
                    ub.Shelf.user_id == current_user.id,
                    ub.Shelf.name == kobo_opt_in_shelf_name,
                )
                .first()
            )
            if opt_in_shelf:
                # Hybrid opt-in shelf should respect "archived" visibility for this user.
                # Exclude archived books so hybrid mode's gate matches the UI shelf visibility.
                opt_in_book_ids = [
                    row[0]
                    for row in (
                        ub.session.query(ub.BookShelf.book_id)
                        .outerjoin(
                            ub.ArchivedBook,
                            and_(
                                ub.ArchivedBook.user_id == int(current_user.id),
                                ub.ArchivedBook.book_id == ub.BookShelf.book_id,
                                ub.ArchivedBook.is_archived == True,
                            ),
                        )
                        .filter(ub.BookShelf.shelf == opt_in_shelf.id)
                        .filter(ub.ArchivedBook.book_id == None)
                        .all()
                    )
                    if row and row[0]
                ]
                hybrid_opt_in_book_ids = set(opt_in_book_ids)
                log.debug(
                    "Hybrid opt-in shelf '%s' id=%s contains %s books (sample=%s)",
                    kobo_opt_in_shelf_name,
                    opt_in_shelf.id,
                    len(opt_in_book_ids),
                    opt_in_book_ids[:10],
                )
                if opt_in_book_ids:
                    synced_ids = {
                        row[0]
                        for row in ub.session.query(ub.KoboSyncedBooks.book_id)
                        .filter(
                            ub.KoboSyncedBooks.user_id == current_user.id,
                            ub.KoboSyncedBooks.book_id.in_(opt_in_book_ids),
                        )
                        .all()
                        if row and row[0]
                    }
                    log.debug(
                        "Hybrid opt-in books already marked synced: %s (sample=%s)",
                        len(synced_ids),
                        sorted(list(synced_ids))[:10],
                    )
                    fmt_rows = (
                        calibre_db.session.query(db.Data.book, db.Data.format)
                        .filter(db.Data.book.in_(opt_in_book_ids))
                        .all()
                    )
                    fmt_map = {}
                    for b_id, fmt in fmt_rows:
                        if not b_id or not fmt:
                            continue
                        fmt_map.setdefault(int(b_id), set()).add(str(fmt))
                    fmt_preview = {
                        k: sorted(list(v)) for k, v in list(fmt_map.items())[:10]
                    }
                    log.debug(
                        "Hybrid opt-in books calibre formats (sample): %s", fmt_preview
                    )
        except Exception as e:
            log.debug("Hybrid opt-in debug failed: %s", e)

    only_kobo_shelves = _effective_only_kobo_shelves_sync(current_user)

    if only_kobo_shelves:
        try:
            synced_books_query = ub.session.query(ub.KoboSyncedBooks.book_id).filter(
                ub.KoboSyncedBooks.user_id == current_user.id
            )
            synced_books_ids = {item.book_id for item in synced_books_query}

            if kobo_collections_mode == "hybrid":
                # Hybrid mode: the local-only opt-in shelf is the single gate.
                allowed_shelf_filter = ub.Shelf.name == kobo_opt_in_shelf_name
            else:
                allowed_shelf_filter = ub.Shelf.kobo_sync == True

            # Get books from regular shelves with kobo_sync enabled.
            # Exclude archived books so the Kobo sync eligibility set matches shelf visibility.
            allowed_books_query = (
                ub.session.query(ub.BookShelf.book_id)
                .join(ub.Shelf, ub.BookShelf.shelf == ub.Shelf.id)
                .outerjoin(
                    ub.ArchivedBook,
                    and_(
                        ub.ArchivedBook.user_id == int(current_user.id),
                        ub.ArchivedBook.book_id == ub.BookShelf.book_id,
                        ub.ArchivedBook.is_archived == True,
                    ),
                )
                .filter(
                    ub.Shelf.user_id == current_user.id,
                    allowed_shelf_filter,
                )
                .filter(ub.ArchivedBook.book_id == None)
                .distinct()
            )
            allowed_books_ids = {item.book_id for item in allowed_books_query}

            # In selected mode, also include books from generated shelves with kobo_sync enabled
            if kobo_collections_mode == "selected" and get_user_generated_shelves_sync(
                current_user
            ):
                try:
                    # Get all generated shelves the user has enabled for sync
                    enabled_gen_shelves = (
                        ub.session.query(
                            ub.GeneratedShelfKoboSync.source,
                            ub.GeneratedShelfKoboSync.value,
                        )
                        .filter(
                            ub.GeneratedShelfKoboSync.user_id == current_user.id,
                            ub.GeneratedShelfKoboSync.kobo_sync == True,
                        )
                        .all()
                    )
                    log.debug(
                        "Kobo sync: found %d generated shelves enabled for sync",
                        len(enabled_gen_shelves),
                    )

                    # For each enabled generated shelf, get the books that match
                    for source, value in enabled_gen_shelves:
                        shelf_filter = generated_shelf_filter(source, value)
                        if shelf_filter is not None:
                            gen_books = (
                                calibre_db.session.query(db.Books.id)
                                .filter(calibre_db.common_filters(), shelf_filter)
                                .all()
                            )
                            gen_book_ids = {row[0] for row in gen_books if row}
                            allowed_books_ids.update(gen_book_ids)
                            log.debug(
                                "Kobo sync: generated shelf %s:%s adds %d books",
                                source,
                                value,
                                len(gen_book_ids),
                            )
                except Exception as e:
                    log.warning("Error fetching books from generated shelves: %s", e)

            log.debug("Kobo sync: total allowed_books_ids = %d", len(allowed_books_ids))

            if kobo_collections_mode == "hybrid":
                try:
                    to_delete_preview = sorted(
                        list(synced_books_ids - allowed_books_ids)
                    )[:25]
                    extra_allowed_preview = sorted(
                        list(allowed_books_ids - synced_books_ids)
                    )[:25]
                    log.debug(
                        "Hybrid deletion check: tracked_synced=%s opt_in_allowed=%s to_delete=%s extra_allowed=%s",
                        len(synced_books_ids),
                        len(allowed_books_ids),
                        to_delete_preview,
                        extra_allowed_preview,
                    )
                except Exception:
                    pass

            book_ids_to_delete = synced_books_ids - allowed_books_ids

            if book_ids_to_delete:
                sorted_delete_ids = sorted(list(book_ids_to_delete))
                log.info(
                    "Kobo Sync: Found %s books to delete from device for user %s",
                    len(sorted_delete_ids),
                    current_user.id,
                )
                log.debug(
                    "Kobo Sync: Books to delete from device (sample): %s",
                    sorted_delete_ids[:25],
                )

                resolved_delete_ids = []
                for book_id in sorted_delete_ids:
                    book = calibre_db.get_book(book_id)
                    if book:
                        resolved_delete_ids.append(book_id)
                        log.debug(
                            "Kobo Sync: Archiving entitlement for book_id=%s uuid=%s title=%s",
                            book_id,
                            getattr(book, "uuid", None),
                            getattr(book, "title", None),
                        )
                        entitlement = {
                            "BookEntitlement": create_book_entitlement(
                                book, archived=True
                            ),
                            "BookMetadata": get_metadata(book),
                        }
                        sync_results.append({"ChangedEntitlement": entitlement})
                    else:
                        # If we can't resolve the book (e.g. removed from calibre), we can't emit an entitlement.
                        # Keep the DB row so the book isn't silently stranded on the device.
                        log.warning(
                            "Kobo Sync: Unable to archive book_id=%s (not found in calibre DB); leaving it marked synced",
                            book_id,
                        )

                # NOTE: Do not remove KoboSyncedBooks rows here.
                # Kobo does not acknowledge removals, and dropping our tracking too early can strand books on-device.
                # We keep the row so we'll keep emitting archive entitlements until the device state converges.
                ub.session.commit()

        except Exception as e:
            log.error(f"Kobo Sync: Error during deletion logic: {e}")
            ub.session.rollback()

    if only_kobo_shelves:
        extra_filters = []
        if kobo_collections_mode == "hybrid":
            # Hybrid mode: only books in the opt-in shelf are eligible for syncing.
            extra_filters.append(ub.Shelf.name == kobo_opt_in_shelf_name)
        else:
            extra_filters.append(ub.Shelf.kobo_sync)

        # In hybrid/selected shelf-sync modes, "newly allowed" is a shelf membership event.
        # Gate that using tags_last_modified (the shelf/collection token), not books_last_modified,
        # because the device's books_last_modified can advance for reasons unrelated to shelf changes.
        shelf_membership_gate_ts = sync_token.tags_last_modified

        shelf_entries = calibre_db.session.query(
            db.Books,
            ub.ArchivedBook.last_modified,
            ub.BookShelf.date_added,
            ub.ArchivedBook.is_archived,
            literal(False).label("deleted"),
        )
        shelf_entries = (
            shelf_entries.join(db.Data)
            .outerjoin(
                ub.ArchivedBook,
                and_(
                    db.Books.id == ub.ArchivedBook.book_id,
                    ub.ArchivedBook.user_id == current_user.id,
                ),
            )
            .filter(
                or_(
                    db.Books.id.notin_(
                        calibre_db.session.query(ub.KoboSyncedBooks.book_id).filter(
                            ub.KoboSyncedBooks.user_id == current_user.id
                        )
                    ),
                    func.datetime(db.Books.last_modified)
                    > sync_token.books_last_modified,
                    func.datetime(ub.BookShelf.date_added) > shelf_membership_gate_ts,
                )
            )
            .filter(db.Data.format.in_(KOBO_FORMATS))
            .filter(calibre_db.common_filters(allow_show_archived=True))
            .join(ub.BookShelf, db.Books.id == ub.BookShelf.book_id)
            .join(ub.Shelf)
            .filter(ub.Shelf.user_id == current_user.id)
            .filter(*extra_filters)
            .distinct()
        )

        # In selected mode, include books from generated shelves with kobo_sync enabled
        if kobo_collections_mode == "selected" and allowed_books_ids:
            # IMPORTANT:
            # Generated shelves don't have a ub.BookShelf.date_added to indicate "newly allowed".
            # To ensure "newly allowed but older timestamp" books get emitted without a full reset,
            # we rely on the "not yet synced" branch of the OR below.
            generated_shelf_entries = (
                calibre_db.session.query(
                    db.Books,
                    ub.ArchivedBook.last_modified,
                    literal(None).label(
                        "date_added"
                    ),  # Generated shelves don't have date_added
                    ub.ArchivedBook.is_archived,
                    literal(False).label("deleted"),
                )
                .join(db.Data)
                .outerjoin(
                    ub.ArchivedBook,
                    and_(
                        db.Books.id == ub.ArchivedBook.book_id,
                        ub.ArchivedBook.user_id == current_user.id,
                    ),
                )
                .filter(
                    db.Books.id.in_(list(allowed_books_ids)),
                    or_(
                        # Newly allowed (present in allowed_books_ids) but not yet synced -> emit
                        db.Books.id.notin_(
                            calibre_db.session.query(ub.KoboSyncedBooks.book_id).filter(
                                ub.KoboSyncedBooks.user_id == current_user.id
                            )
                        ),
                        # Or modified since last sync -> emit
                        func.datetime(db.Books.last_modified)
                        > sync_token.books_last_modified,
                    ),
                )
                .filter(db.Data.format.in_(KOBO_FORMATS))
                .filter(calibre_db.common_filters(allow_show_archived=True))
                .distinct()
            )
            shelf_entries = shelf_entries.union_all(generated_shelf_entries)
            log.debug("Kobo sync: added generated shelf books query to sync entries")

        # In hybrid mode, the opt-in shelf is already represented by extra_filters.
        # Do not union all opt-in books unconditionally, otherwise the sync will never converge
        # (it bypasses sync_token gating and keeps returning the same first page forever).

        shelf_exists = (
            calibre_db.session.query(ub.BookShelf)
            .join(ub.Shelf)
            .filter(ub.BookShelf.book_id == db.Books.id, *extra_filters)
            .exists()
        )

        # Build deletion query: synced books that are no longer in any kobo_sync-enabled shelf
        # For generated shelves, we exclude books that are in allowed_books_ids
        deleted_entries = (
            calibre_db.session.query(
                db.Books,
                ub.ArchivedBook.last_modified,
                func.current_timestamp().label("deleted"),
                ub.ArchivedBook.is_archived,
                literal(True).label("deleted"),
            )
            .join(
                ub.KoboSyncedBooks,
                and_(
                    ub.KoboSyncedBooks.book_id == db.Books.id,
                    ub.KoboSyncedBooks.user_id == current_user.id,
                ),
            )
            .outerjoin(
                ub.ArchivedBook,
                and_(
                    db.Books.id == ub.ArchivedBook.book_id,
                    ub.ArchivedBook.user_id == current_user.id,
                ),
            )
            .filter(~shelf_exists)
        )
        # Exclude books from generated shelves (they're in allowed_books_ids but not in BookShelf)
        if allowed_books_ids:
            deleted_entries = deleted_entries.filter(
                db.Books.id.notin_(list(allowed_books_ids))
            )

        changed_entries = shelf_entries.union_all(deleted_entries).order_by(
            db.Books.id, db.Books.last_modified, ub.ArchivedBook.last_modified
        )

    else:
        changed_entries = calibre_db.session.query(
            db.Books, ub.ArchivedBook.last_modified, ub.ArchivedBook.is_archived
        )
        changed_entries = (
            changed_entries.join(db.Data)
            .outerjoin(
                ub.ArchivedBook,
                and_(
                    db.Books.id == ub.ArchivedBook.book_id,
                    ub.ArchivedBook.user_id == current_user.id,
                ),
            )
            .filter(
                or_(
                    db.Books.id.notin_(
                        calibre_db.session.query(ub.KoboSyncedBooks.book_id).filter(
                            ub.KoboSyncedBooks.user_id == current_user.id
                        )
                    ),
                    func.datetime(db.Books.last_modified)
                    > sync_token.books_last_modified,
                )
            )
            .filter(calibre_db.common_filters(allow_show_archived=True))
            .filter(db.Data.format.in_(KOBO_FORMATS))
            .order_by(db.Books.last_modified)
            .order_by(db.Books.id)
        )

    reading_states_in_new_entitlements = []
    sync_item_limit = get_sync_item_limit(current_user)
    books = changed_entries.limit(sync_item_limit)
    books_list = books.all()
    log.debug("Books to Sync: {}".format(len(books_list)))
    log.debug("sync_token.books_last_created: %s" % sync_token.books_last_created)

    # NOTE: Shelf membership changes are now gated using the shelf/collection token
    # (sync_token.tags_last_modified), and that token is advanced in `sync_shelves()`.
    # Advancing `new_books_last_modified` based on shelf membership here is redundant and can
    # be confusing, so it has been removed.

    # Debug: Log total library book count and format info for troubleshooting incomplete syncs
    try:
        total_books = (
            calibre_db.session.query(db.Books)
            .filter(calibre_db.common_filters())
            .count()
        )
        total_books_unfiltered = calibre_db.session.query(db.Books).count()
        books_with_kobo_formats = (
            calibre_db.session.query(db.Books.id)
            .join(db.Data)
            .filter(calibre_db.common_filters())
            .filter(db.Data.format.in_(KOBO_FORMATS))
            .distinct()
            .count()
        )
        already_synced = (
            ub.session.query(ub.KoboSyncedBooks.book_id)
            .filter(ub.KoboSyncedBooks.user_id == current_user.id)
            .count()
        )
        # Count synced books that still exist in library (fetch IDs first to avoid cross-DB subquery)
        existing_book_ids = set(
            row[0]
            for row in calibre_db.session.query(db.Books.id)
            .filter(calibre_db.common_filters())
            .all()
        )
        synced_book_ids = set(
            row[0]
            for row in ub.session.query(ub.KoboSyncedBooks.book_id)
            .filter(ub.KoboSyncedBooks.user_id == current_user.id)
            .all()
        )
        synced_and_exists = len(synced_book_ids & existing_book_ids)
        orphaned_sync_records = len(synced_book_ids - existing_book_ids)
        archived_count = (
            ub.session.query(ub.ArchivedBook.book_id)
            .filter(
                ub.ArchivedBook.user_id == current_user.id,
                ub.ArchivedBook.is_archived == True,
            )
            .count()
        )
        log.info(
            "Kobo sync stats: total_library=%s (unfiltered=%s) books_with_kobo_formats=%s "
            "already_synced=%s synced_and_exists=%s orphaned_sync_records=%s archived=%s "
            "to_sync_this_batch=%s limit=%s mode=%s only_kobo_shelves=%s",
            total_books,
            total_books_unfiltered,
            books_with_kobo_formats,
            already_synced,
            synced_and_exists,
            orphaned_sync_records,
            archived_count,
            len(books_list),
            sync_item_limit,
            kobo_collections_mode,
            only_kobo_shelves,
        )
        # Log detailed sync status for debugging
        log.debug(
            "Kobo sync detail: synced_book_ids=%s, existing_book_ids_count=%s, "
            "synced_and_exists=%s, books_in_batch=%s",
            sorted(list(synced_book_ids))[:20],  # First 20 to avoid log spam
            len(existing_book_ids),
            synced_and_exists,
            [b.Books.id for b in books_list][:20] if books_list else [],
        )
    except Exception as e:
        log.debug("Kobo sync stats debug failed: %s", e)

    entitled_book_ids = set()
    for book in books_list:
        formats = [data.format for data in book.Books.data]
        if "KEPUB" not in formats and config.config_kepubifypath and "EPUB" in formats:
            helper.convert_book_format(
                book.Books.id,
                config.get_book_path(),
                "EPUB",
                "KEPUB",
                current_user.name,
            )

        kobo_reading_state = get_or_create_reading_state(book.Books.id)
        archived_flag = (book.is_archived == True) or (
            only_kobo_shelves and book.deleted
        )
        if (
            only_kobo_shelves
            and kobo_collections_mode == "hybrid"
            and (book.Books.id in hybrid_opt_in_book_ids)
            and not book.deleted
        ):
            # Treat opt-in shelf membership as an explicit unarchive/download request.
            archived_flag = False
        entitlement = {
            "BookEntitlement": create_book_entitlement(
                book.Books, archived=archived_flag
            ),
            "BookMetadata": get_metadata(book.Books),
        }

        if kobo_reading_state.last_modified > sync_token.reading_state_last_modified:
            entitlement["ReadingState"] = get_kobo_reading_state_response(
                book.Books, kobo_reading_state
            )
            new_reading_state_last_modified = max(
                new_reading_state_last_modified, kobo_reading_state.last_modified
            )
            reading_states_in_new_entitlements.append(book.Books.id)

        ts_created = book.Books.timestamp.replace(tzinfo=None)

        try:
            ts_created = max(ts_created, book.date_added.replace(tzinfo=None))
        except AttributeError:
            pass

        log.debug("Syncing book: %s, ts_created: %s", book.Books.id, ts_created)
        entitled_book_ids.add(book.Books.id)
        if ts_created > sync_token.books_last_created:
            entitlement["BookMetadata"] = get_metadata(book.Books)
            sync_results.append({"NewEntitlement": entitlement})
        elif only_kobo_shelves and book.deleted:
            sync_results.append({"ChangedEntitlement": entitlement})
        else:
            entitlement["BookMetadata"] = get_metadata(book.Books)
            sync_results.append({"ChangedEntitlement": entitlement})

        new_books_last_modified = max(
            book.Books.last_modified.replace(tzinfo=None), new_books_last_modified
        )

        # Hybrid/selected shelf-sync relies on shelf membership changes as a signal.
        # If a book becomes newly allowed (added to Kobo Sync shelf) but has an older
        # calibre last_modified timestamp, we must advance the sync token using the
        # shelf link's date_added as well, otherwise the device can miss the window and
        # the newly-allowed book will never be emitted again without a full reset.
        try:
            if getattr(book, "date_added", None):
                new_books_last_modified = max(
                    new_books_last_modified, book.date_added.replace(tzinfo=None)
                )
        except Exception:
            pass
        # NOTE: date_added handling moved above with a broader safety net; keep this
        # block as a no-op for backwards compatibility in case older code paths still
        # expect it to exist.
        try:
            new_books_last_modified = max(
                new_books_last_modified, book.date_added.replace(tzinfo=None)
            )
        except Exception:
            pass

        new_books_last_created = max(ts_created, new_books_last_created)
        if only_kobo_shelves and book.deleted:
            kobo_sync_status.remove_synced_book(
                book.Books.id, reason="entitlement:deleted"
            )
        else:
            if (
                only_kobo_shelves
                and kobo_collections_mode == "hybrid"
                and (book.Books.id in hybrid_opt_in_book_ids)
            ):
                reason = "entitlement:hybrid-opt-in"
            elif ts_created > sync_token.books_last_created:
                reason = "entitlement:new"
            else:
                reason = "entitlement:changed"
            kobo_sync_status.add_synced_books(book.Books.id, reason=reason)

    # NOTE: Avoid filtering unioned queries using ub.ArchivedBook columns, which creates a cartesian product.
    # We only need the max archived timestamp for the current user.
    max_archived_ts = None
    try:
        max_archived_ts = (
            ub.session.query(func.max(ub.ArchivedBook.last_modified))
            .filter(
                ub.ArchivedBook.user_id == current_user.id,
                ub.ArchivedBook.is_archived == True,
            )
            .scalar()
        )
    except Exception:
        max_archived_ts = None
    if max_archived_ts:
        new_archived_last_modified = max(
            new_archived_last_modified, _to_naive_datetime(max_archived_ts)
        )

    # no. of books returned
    book_count = changed_entries.count() - books.count()
    # last entry:
    cont_sync = bool(book_count)
    log.debug("Remaining books to Sync: {}".format(book_count))
    # generate reading state data
    changed_reading_states = ub.session.query(ub.KoboReadingState)

    if only_kobo_shelves:
        changed_reading_states = (
            changed_reading_states.join(
                ub.BookShelf, ub.KoboReadingState.book_id == ub.BookShelf.book_id
            )
            .join(ub.Shelf)
            .filter(current_user.id == ub.Shelf.user_id)
            .filter(
                extra_filters[0],
                or_(
                    ub.KoboReadingState.last_modified
                    > sync_token.reading_state_last_modified,
                    func.datetime(ub.BookShelf.date_added)
                    > sync_token.books_last_modified,
                ),
            )
            .distinct()
        )
    else:
        changed_reading_states = changed_reading_states.filter(
            ub.KoboReadingState.last_modified > sync_token.reading_state_last_modified
        )

    changed_reading_states = changed_reading_states.filter(
        and_(
            ub.KoboReadingState.user_id == current_user.id,
            ub.KoboReadingState.book_id.notin_(reading_states_in_new_entitlements),
        )
    ).order_by(ub.KoboReadingState.last_modified)
    cont_sync |= bool(changed_reading_states.count() > sync_item_limit)
    for kobo_reading_state in changed_reading_states.limit(sync_item_limit).all():
        book = (
            calibre_db.session.query(db.Books)
            .filter(db.Books.id == kobo_reading_state.book_id)
            .one_or_none()
        )
        if book:
            sync_results.append(
                {
                    "ChangedReadingState": {
                        "ReadingState": get_kobo_reading_state_response(
                            book, kobo_reading_state
                        )
                    }
                }
            )
            new_reading_state_last_modified = max(
                new_reading_state_last_modified, kobo_reading_state.last_modified
            )

    sync_shelves(
        sync_token,
        sync_results,
        only_kobo_shelves,
        force_book_ids=sorted(entitled_book_ids),
    )

    # update last created timestamp to distinguish between new and changed entitlements
    if not cont_sync:
        sync_token.books_last_created = new_books_last_created
    sync_token.books_last_modified = new_books_last_modified
    sync_token.archive_last_modified = new_archived_last_modified
    sync_token.reading_state_last_modified = new_reading_state_last_modified

    response = generate_sync_response(sync_token, sync_results, cont_sync)
    # Useful to tell whether the device is still actively fetching covers.
    # If ACW logs are quiet and since_last_s grows, the Kobo is likely doing local processing.
    _log_kobo_cover_telemetry_snapshot(
        getattr(current_user, "id", None), context="after-sync"
    )
    return response


def generate_sync_response(sync_token, sync_results, set_cont=False):
    extra_headers = {}
    if (
        config.config_kobo_proxy
        and not set_cont
        and not getattr(config, "config_kobo_disable_store_sync_merge", False)
    ):
        # Merge in sync results from the official Kobo store.
        try:
            store_response = make_request_to_kobo_store(sync_token)

            store_sync_results = store_response.json()
            sync_results += store_sync_results
            sync_token.merge_from_store_response(store_response)
            extra_headers["x-kobo-sync"] = store_response.headers.get("x-kobo-sync")
            extra_headers["x-kobo-sync-mode"] = store_response.headers.get(
                "x-kobo-sync-mode"
            )
            extra_headers["x-kobo-recent-reads"] = store_response.headers.get(
                "x-kobo-recent-reads"
            )

        except Exception as ex:
            log.error_or_exception(
                "Failed to receive or parse response from Kobo's sync endpoint: {}".format(
                    ex
                )
            )
    if set_cont:
        extra_headers["x-kobo-sync"] = "continue"
    sync_token.to_headers(extra_headers)

    try:
        token_val = extra_headers.get(SyncToken.SyncToken.SYNC_TOKEN_HEADER, "")
        log.debug(
            "Kobo sync response token: cont=%s header_len=%s header_prefix=%s books_last_modified=%s books_last_created=%s tags_last_modified=%s",
            bool(set_cont),
            len(token_val) if token_val else 0,
            token_val[:12] if token_val else "",
            getattr(sync_token, "books_last_modified", None),
            getattr(sync_token, "books_last_created", None),
            getattr(sync_token, "tags_last_modified", None),
        )
    except Exception:
        pass

    # log.debug("Kobo Sync Content: {}".format(sync_results))
    # jsonify decodes the Unicode string different to what kobo expects
    # NOTE: Don't rely on make_response() positional argument heuristics for headers.
    # Some Flask/Werkzeug combinations won't apply a dict passed as the 2nd arg.
    response = make_response(json.dumps(sync_results))
    response.headers.update(extra_headers)
    response.headers["Content-Type"] = "application/json; charset=utf-8"
    return response


@kobo.route("/v1/library/<book_uuid>/metadata")
@requires_kobo_auth
@download_required
def HandleMetadataRequest(book_uuid):
    if not current_app.wsgi_app.is_proxied:
        log.debug(
            "Kobo: Received unproxied request, changed request port to external server port"
        )
    log.info("Kobo library metadata request received for book %s" % book_uuid)
    book = calibre_db.get_book_by_uuid(book_uuid)
    if not book or not book.data:
        log.info("Book %s not found in database", book_uuid)
        return redirect_or_proxy_request()

    # Helpful diagnostics for the common "why is this book on device?" question.
    try:
        kobo_collections_mode = get_user_kobo_collections_mode(current_user)
        if kobo_collections_mode == "hybrid" and _effective_only_kobo_shelves_sync(
            current_user
        ):
            opt_in_shelf = _ensure_kobo_opt_in_shelf(current_user.id, "Kobo Sync")
            in_opt_in = bool(
                ub.session.query(ub.BookShelf)
                .filter(
                    ub.BookShelf.book_id == book.id,
                    ub.BookShelf.shelf == opt_in_shelf.id,
                )
                .first()
            )
            log.debug(
                "Hybrid metadata request: calibre_book_id=%s uuid=%s title=%s in_opt_in=%s",
                book.id,
                getattr(book, "uuid", None),
                getattr(book, "title", None),
                in_opt_in,
            )
            if not in_opt_in:
                # If the device is requesting metadata for a local book that's not opted-in,
                # make sure we track it so the next sync can archive/remove it.
                kobo_sync_status.add_synced_books(
                    book.id, reason="observed:metadata-non-opt-in"
                )
    except Exception:
        pass

    metadata = get_metadata(book)
    response = make_response(json.dumps([metadata], ensure_ascii=False))
    response.headers["Content-Type"] = "application/json; charset=utf-8"
    return response


def get_download_url_for_book(book_id, book_format):
    if not current_app.wsgi_app.is_proxied:
        if ":" in request.host and not request.host.endswith("]"):
            host = "".join(request.host.split(":")[:-1])
        else:
            host = request.host

        return "{url_scheme}://{url_base}:{url_port}/kobo/{auth_token}/download/{book_id}/{book_format}".format(
            url_scheme=request.scheme,
            url_base=host,
            url_port=config.config_external_port,
            auth_token=get_auth_token(),
            book_id=book_id,
            book_format=book_format.lower(),
        )
    return url_for(
        "kobo.download_book",
        auth_token=kobo_auth.get_auth_token(),
        book_id=book_id,
        book_format=book_format.lower(),
        _external=True,
    )


def create_book_entitlement(book, archived):
    book_uuid = str(book.uuid)
    return {
        "Accessibility": "Full",
        "ActivePeriod": {
            "From": convert_to_kobo_timestamp_string(datetime.now(timezone.utc))
        },
        "Created": convert_to_kobo_timestamp_string(book.timestamp),
        "CrossRevisionId": book_uuid,
        "Id": book_uuid,
        "IsRemoved": archived,
        "IsHiddenFromArchive": False,
        "IsLocked": False,
        "LastModified": convert_to_kobo_timestamp_string(book.last_modified),
        "OriginCategory": "Imported",
        "RevisionId": book_uuid,
        "Status": "Active",
    }


def current_time():
    return strftime("%Y-%m-%dT%H:%M:%SZ", gmtime())


def get_description(book):
    if not book.comments:
        return None
    return book.comments[0].text


def get_author(book):
    if not book.authors:
        return {"Contributors": None, "ContributorRoles": None, "Attribution": None}
    author_list = []
    autor_roles = []
    seen = set()
    for author in book.authors:
        # Use author.sort for "Last, First" format; fall back to name if sort is empty
        raw_name = getattr(author, "sort", "") or getattr(author, "name", "") or ""
        if not raw_name or not raw_name.strip():
            log.debug(
                "Kobo get_author: skipping empty author for book '%s' (id=%s)",
                book.title,
                book.id,
            )
            continue
        # In this codebase, '|' is used as an internal placeholder for commas
        # in names like "Lastname| Firstname" to avoid delimiter ambiguity.
        name = raw_name.replace("|", ",").strip()
        if "|" in raw_name:
            log.debug("Kobo get_author: replaced pipe in '%s' -> '%s'", raw_name, name)
        if not name or name in seen:
            continue
        seen.add(name)
        autor_roles.append({"Name": name})
        author_list.append(name)
    log.debug(
        "Kobo get_author: book='%s' (id=%s) raw_authors=%s final_list=%s",
        book.title,
        book.id,
        [
            getattr(a, "sort", None) or getattr(a, "name", None)
            for a in (book.authors or [])
        ],
        author_list,
    )
    return {
        "ContributorRoles": autor_roles or None,
        "Contributors": author_list or None,
        "Attribution": ", ".join(author_list) if author_list else None,
    }


def get_publisher(book):
    if not book.publishers:
        return None
    return book.publishers[0].name


def get_series(book):
    if not book.series:
        return None
    return book.series[0].name


def get_seriesindex(book):
    return book.series_index if isinstance(book.series_index, float) else 1


def get_language(book):
    if not book.languages:
        return "en"
    return isoLanguages.get(part3=book.languages[0].lang_code).part1


def get_metadata(book):
    download_urls = []

    # Prefer serving KEPUB to Kobo if available.
    # In some deployments the Calibre library DB (metadata.db) is mounted read-only,
    # so the KEPUB format may exist on disk but not be registered in the DB `data` table.
    kepub = [data for data in book.data if data.format == "KEPUB"]

    # If no KEPUB is registered in the DB, but a .kepub file exists alongside the book,
    # advertise KEPUB anyway so the device can download it.
    if len(kepub) == 0:
        try:
            base_dir = os.path.join(config.get_book_path(), book.path)

            # Try to derive the Calibre filename prefix from any existing format entry.
            # This matches typical Calibre naming (Data.name + .ext).
            base_name = None
            try:
                if getattr(book, "data", None) and len(book.data) > 0:
                    base_name = getattr(book.data[0], "name", None)
            except Exception:
                base_name = None

            if base_name:
                kepub_path = os.path.join(base_dir, base_name + ".kepub")
                if os.path.isfile(kepub_path):
                    dummy = type("DataLike", (), {})()
                    dummy.format = "KEPUB"
                    dummy.uncompressed_size = os.path.getsize(kepub_path)
                    # Provide a `name` attribute for downstream code that may expect it.
                    dummy.name = base_name
                    kepub = [dummy]
        except Exception:
            # Fall back to existing DB-listed formats
            pass

    for book_data in kepub if len(kepub) > 0 else book.data:
        if book_data.format not in KOBO_FORMATS:
            continue
        for kobo_format in KOBO_FORMATS[book_data.format]:
            # log.debug('Id: %s, Format: %s' % (book.id, kobo_format))
            try:
                if get_epub_layout(book, book_data) == "pre-paginated":
                    kobo_format = "EPUB3FL"
                download_urls.append(
                    {
                        "Format": kobo_format,
                        "Size": book_data.uncompressed_size,
                        "Url": get_download_url_for_book(book.id, book_data.format),
                        # The Kobo forma accepts platforms: (Generic, Android)
                        "Platform": "Generic",
                        # "DrmType": "None", # Not required
                    }
                )
            except (zipfile.BadZipfile, FileNotFoundError) as e:
                log.error(e)

    book_uuid = book.uuid
    book_isbn = None

    for i in book.identifiers:
        if i.format_type() == "ISBN":
            book_isbn = i.val

    coverVersion = helper.get_book_cover_epoch_date_with_uuid(book_uuid)
    if coverVersion:
        coverImageId = book_uuid + "/" + coverVersion
    else:
        coverImageId = book_uuid

    metadata = {
        "Categories": [
            "00000000-0000-0000-0000-000000000001",
        ],
        # "Contributors": get_author(book),
        "CoverImageId": coverImageId,
        "CrossRevisionId": book_uuid,
        "CurrentDisplayPrice": {"CurrencyCode": "USD", "TotalAmount": 0},
        "CurrentLoveDisplayPrice": {"TotalAmount": 0},
        "Description": get_description(book),
        "DownloadUrls": download_urls,
        "EntitlementId": book_uuid,
        "ExternalIds": [],
        "Genre": "00000000-0000-0000-0000-000000000001",
        "IsEligibleForKoboLove": False,
        "IsInternetArchive": False,
        "IsPreOrder": False,
        "IsSocialEnabled": True,
        "Language": get_language(book),
        "PhoneticPronunciations": {},
        "PublicationDate": convert_to_kobo_timestamp_string(book.pubdate),
        "Publisher": {
            "Imprint": "",
            "Name": get_publisher(book),
        },
        "RevisionId": book_uuid,
        "Title": book.title,
        "WorkId": book_uuid,
        "ISBN": book_isbn,
    }
    metadata.update(get_author(book))

    if get_series(book):
        name = get_series(book)
        try:
            metadata["Series"] = {
                "Name": get_series(book),
                "Number": get_seriesindex(book),  # ToDo Check int() ?
                "NumberFloat": float(get_seriesindex(book)),
                # Get a deterministic id based on the series name.
                "Id": str(uuid.uuid3(uuid.NAMESPACE_DNS, name)),
            }
        except Exception as e:
            print(e)
    return metadata


@csrf.exempt
@kobo.route("/v1/library/tags", methods=["POST", "DELETE"])
@requires_kobo_auth
# Creates a Shelf with the given items, and returns the shelf's uuid.
def HandleTagCreate():
    # catch delete requests, otherwise they are handled in the book delete handler
    if request.method == "DELETE":
        abort(405)
    name, items = None, None
    try:
        shelf_request = request.json
        name = shelf_request["Name"]
        items = shelf_request["Items"]
        if not name:
            raise TypeError
    except (KeyError, TypeError):
        log.debug("Received malformed v1/library/tags request.")
        abort(
            400,
            description="Malformed tags POST request. Data has empty 'Name', missing 'Name' or 'Items' field",
        )

    shelf = (
        ub.session.query(ub.Shelf)
        .filter(ub.Shelf.name == name, ub.Shelf.user_id == current_user.id)
        .one_or_none()
    )
    if shelf and not shelf_lib.check_shelf_edit_permissions(shelf):
        abort(401, description="User is unauthaurized to create shelf.")

    if not shelf:
        shelf = ub.Shelf(user_id=current_user.id, name=name, uuid=str(uuid.uuid4()))
        ub.session.add(shelf)

    items_unknown_to_calibre = add_items_to_shelf(items, shelf)
    if items_unknown_to_calibre:
        log.debug(
            "Received request to add unknown books to a collection. Silently ignoring items."
        )
    ub.session_commit()
    return make_response(jsonify(str(shelf.uuid)), 201)


@csrf.exempt
@kobo.route("/v1/library/tags/<tag_id>", methods=["DELETE", "PUT"])
@requires_kobo_auth
def HandleTagUpdate(tag_id):
    shelf = (
        ub.session.query(ub.Shelf)
        .filter(ub.Shelf.uuid == tag_id, ub.Shelf.user_id == current_user.id)
        .one_or_none()
    )
    if not shelf:
        log.debug(
            "Received Kobo tag update request on a collection unknown to Autocaliweb"
        )
        if config.config_kobo_proxy:
            return redirect_or_proxy_request()
        else:
            abort(404, description="Collection isn't known to Autocaliweb")

    if request.method == "DELETE":
        if not shelf_lib.delete_shelf_helper(shelf):
            abort(401, description="Error deleting Shelf")
    else:
        name = None
        try:
            shelf_request = request.json
            name = shelf_request["Name"]
        except (KeyError, TypeError):
            log.debug("Received malformed v1/library/tags rename request.")
            abort(
                400,
                description="Malformed tags POST request. Data is missing 'Name' field",
            )

        shelf.name = name
        ub.session.merge(shelf)
        ub.session_commit()
    return make_response(" ", 200)


# Adds items to the given shelf.
def add_items_to_shelf(items, shelf):
    book_ids_already_in_shelf = set([book_shelf.book_id for book_shelf in shelf.books])
    items_unknown_to_calibre = []
    for item in items:
        try:
            if item["Type"] != "ProductRevisionTagItem":
                items_unknown_to_calibre.append(item)
                continue

            book = calibre_db.get_book_by_uuid(item["RevisionId"])
            if not book:
                items_unknown_to_calibre.append(item)
                continue

            book_id = book.id
            if book_id not in book_ids_already_in_shelf:
                shelf.books.append(ub.BookShelf(book_id=book_id))
        except KeyError:
            items_unknown_to_calibre.append(item)
    return items_unknown_to_calibre


@csrf.exempt
@kobo.route("/v1/library/tags/<tag_id>/items", methods=["POST"])
@requires_kobo_auth
def HandleTagAddItem(tag_id):
    items = None
    try:
        tag_request = request.json
        items = tag_request["Items"]
    except (KeyError, TypeError):
        log.debug("Received malformed v1/library/tags/<tag_id>/items/delete request.")
        abort(
            400,
            description="Malformed tags POST request. Data is missing 'Items' field",
        )

    shelf = (
        ub.session.query(ub.Shelf)
        .filter(ub.Shelf.uuid == tag_id, ub.Shelf.user_id == current_user.id)
        .one_or_none()
    )
    if not shelf:
        log.debug("Received Kobo request on a collection unknown to Autocaliweb")
        abort(404, description="Collection isn't known to Autocaliweb")

    if not shelf_lib.check_shelf_edit_permissions(shelf):
        abort(401, description="User is unauthaurized to edit shelf.")

    items_unknown_to_calibre = add_items_to_shelf(items, shelf)
    if items_unknown_to_calibre:
        log.debug(
            "Received request to add an unknown book to a collection. Silently ignoring item."
        )

    ub.session.merge(shelf)
    ub.session_commit()
    return make_response("", 201)


@csrf.exempt
@kobo.route("/v1/library/tags/<tag_id>/items/delete", methods=["POST"])
@requires_kobo_auth
def HandleTagRemoveItem(tag_id):
    items = None
    try:
        tag_request = request.json
        items = tag_request["Items"]
    except (KeyError, TypeError):
        log.debug("Received malformed v1/library/tags/<tag_id>/items/delete request.")
        abort(
            400,
            description="Malformed tags POST request. Data is missing 'Items' field",
        )

    shelf = (
        ub.session.query(ub.Shelf)
        .filter(ub.Shelf.uuid == tag_id, ub.Shelf.user_id == current_user.id)
        .one_or_none()
    )
    if not shelf:
        log.debug(
            "Received a request to remove an item from a Collection unknown to Autocaliweb."
        )
        abort(404, description="Collection isn't known to Autocaliweb")

    if not shelf_lib.check_shelf_edit_permissions(shelf):
        abort(401, description="User is unauthaurized to edit shelf.")

    items_unknown_to_calibre = []
    for item in items:
        try:
            if item["Type"] != "ProductRevisionTagItem":
                items_unknown_to_calibre.append(item)
                continue

            book = calibre_db.get_book_by_uuid(item["RevisionId"])
            if not book:
                items_unknown_to_calibre.append(item)
                continue

            shelf.books.filter(ub.BookShelf.book_id == book.id).delete()
        except KeyError:
            items_unknown_to_calibre.append(item)
    ub.session_commit()

    if items_unknown_to_calibre:
        log.debug(
            "Received request to remove an unknown book to a collecition. Silently ignoring item."
        )

    return make_response("", 200)


# Add new, changed, or deleted shelves to the sync_results.
# Note: Public shelves that aren't owned by the user aren't supported.
def sync_shelves(
    sync_token, sync_results, only_kobo_shelves=False, force_book_ids=None
):
    kobo_collections_mode = get_user_kobo_collections_mode(current_user)
    kobo_opt_in_shelf_name = "Kobo Sync"
    opt_in_shelf_id = None
    allow_empty_collections = get_user_sync_empty_collections(current_user)

    only_kobo_collections = kobo_collections_mode in ("selected", "hybrid")

    # Ensure shelves have stable UUIDs (older DBs may have NULL/empty uuid for pre-existing shelves).
    # Without UUIDs, Kobo cannot create Collections from these shelves.
    uuid_backfilled_shelves = []
    try:
        uuid_query = ub.session.query(ub.Shelf).filter(
            ub.Shelf.user_id == current_user.id,
            or_(ub.Shelf.uuid.is_(None), ub.Shelf.uuid == ""),
        )
        # Do not treat the opt-in shelf as a Kobo Collection in any mode.
        uuid_query = uuid_query.filter(ub.Shelf.name != kobo_opt_in_shelf_name)
        if only_kobo_collections:
            uuid_query = uuid_query.filter(ub.Shelf.kobo_sync == True)
        uuid_backfilled_shelves = uuid_query.all()
        for shelf in uuid_backfilled_shelves or []:
            shelf.uuid = str(uuid.uuid4())
        if uuid_backfilled_shelves:
            ub.session_commit()
    except Exception:
        uuid_backfilled_shelves = []

    allowed_book_ids = None
    if only_kobo_collections:
        if kobo_collections_mode == "hybrid":
            # Hybrid mode: only books opted-in via the local-only shelf are eligible.
            opt_in_shelf = _ensure_kobo_opt_in_shelf(
                current_user.id, kobo_opt_in_shelf_name
            )
            try:
                opt_in_shelf_id = opt_in_shelf.id
            except Exception:
                opt_in_shelf_id = None
            allowed_book_ids = {
                row[0]
                for row in ub.session.query(ub.BookShelf.book_id)
                .filter(ub.BookShelf.shelf == opt_in_shelf.id)
                .all()
                if row and row[0]
            }
        else:
            # Selected mode: collections should reflect eligible (kobo_sync) shelf membership.
            # (KoboSyncedBooks is tracking state, not eligibility.)
            allowed_book_ids = {
                row[0]
                for row in (
                    ub.session.query(ub.BookShelf.book_id)
                    .join(ub.Shelf, ub.Shelf.id == ub.BookShelf.shelf)
                    .filter(
                        ub.Shelf.user_id == current_user.id,
                        ub.Shelf.kobo_sync == True,
                    )
                    .distinct()
                    .all()
                )
                if row and row[0]
            }

    new_tags_last_modified = sync_token.tags_last_modified

    # In hybrid/selected shelf-sync modes, newly-allowed books are driven by shelf membership
    # changes (book_shelf_link.date_added). The device's books_last_modified can advance for
    # reasons unrelated to shelf changes, so we must also advance tags_last_modified using the
    # latest membership timestamp to keep "newly allowed but older timestamp" books emitting
    # reliably in future syncs.
    try:
        latest_membership_change = (
            ub.session.query(func.max(ub.BookShelf.date_added))
            .join(ub.Shelf, ub.Shelf.id == ub.BookShelf.shelf)
            .filter(ub.Shelf.user_id == current_user.id)
            .scalar()
        )
        if latest_membership_change:
            new_tags_last_modified = max(
                _to_naive_datetime(latest_membership_change), new_tags_last_modified
            )
            log.debug(
                "Kobo shelfs sync: advancing new_tags_last_modified using latest shelf membership date_added=%s",
                latest_membership_change,
            )
    except Exception as e:
        log.debug(
            "Kobo shelfs sync: unable to compute latest shelf membership date_added: %s",
            e,
        )
    # transmit all archived shelfs independent of last sync (why should this matter?)
    for shelf in ub.session.query(ub.ShelfArchive).filter(
        ub.ShelfArchive.user_id == current_user.id
    ):
        new_tags_last_modified = max(shelf.last_modified, new_tags_last_modified)
        sync_results.append(
            {
                "DeletedTag": {
                    "Tag": {
                        "Id": shelf.uuid,
                        "LastModified": convert_to_kobo_timestamp_string(
                            shelf.last_modified
                        ),
                    }
                }
            }
        )
        ub.session.delete(shelf)
        ub.session_commit()

    extra_filters = []
    now_ts = datetime.now(timezone.utc)
    now_ts_naive = _to_naive_datetime(now_ts)
    if only_kobo_collections:
        if kobo_collections_mode == "hybrid":
            # Hybrid mode: manage only shelves explicitly marked for Kobo sync (plus generated shelves).
            # Also remove shelves not marked for Kobo sync so they don't linger from earlier modes.
            extra_filters.append(ub.Shelf.kobo_sync == True)
            if opt_in_shelf_id is not None:
                extra_filters.append(ub.Shelf.id != opt_in_shelf_id)
            else:
                extra_filters.append(ub.Shelf.name != kobo_opt_in_shelf_name)

            # Remove any non-kobo_sync shelves (including the opt-in shelf) from the device.
            try:
                shelves_to_delete = (
                    ub.session.query(ub.Shelf)
                    .filter(
                        ub.Shelf.user_id == current_user.id,
                        or_(ub.Shelf.kobo_sync == False, ub.Shelf.kobo_sync == None),
                    )
                    .all()
                )
            except Exception:
                shelves_to_delete = []
            for del_shelf in shelves_to_delete or []:
                try:
                    if not getattr(del_shelf, "uuid", None):
                        continue
                    sync_results.append(
                        {
                            "DeletedTag": {
                                "Tag": {
                                    "Id": del_shelf.uuid,
                                    "LastModified": convert_to_kobo_timestamp_string(
                                        now_ts
                                    ),
                                }
                            }
                        }
                    )
                    new_tags_last_modified = max(now_ts_naive, new_tags_last_modified)
                except Exception:
                    continue
        else:
            # Selected mode: if we previously ran in "all" mode, the device may still have
            # Collections for shelves that are no longer eligible. Those shelves won't necessarily
            # get a new last_modified, so we must actively delete them.
            try:
                shelves_to_delete = (
                    ub.session.query(ub.Shelf)
                    .filter(
                        ub.Shelf.user_id == current_user.id,
                        or_(ub.Shelf.kobo_sync == False, ub.Shelf.kobo_sync == None),
                        ub.Shelf.name != kobo_opt_in_shelf_name,
                    )
                    .all()
                )
            except Exception:
                shelves_to_delete = []
            for shelf in shelves_to_delete or []:
                try:
                    if not getattr(shelf, "uuid", None):
                        continue
                    sync_results.append(
                        {
                            "DeletedTag": {
                                "Tag": {
                                    "Id": shelf.uuid,
                                    "LastModified": convert_to_kobo_timestamp_string(
                                        now_ts
                                    ),
                                }
                            }
                        }
                    )
                    new_tags_last_modified = max(now_ts_naive, new_tags_last_modified)
                except Exception:
                    continue
            extra_filters.append(ub.Shelf.kobo_sync)

    if kobo_collections_mode == "hybrid":
        # Hybrid mode: resync collections every time because eligibility changes with opt-in shelf membership
        # and we don't have a reliable "date removed" for BookShelf.
        shelflist = (
            ub.session.query(ub.Shelf)
            .filter(
                ub.Shelf.user_id == current_user.id,
                *extra_filters,
            )
            .order_by(func.lower(ub.Shelf.name).asc())
        )
    else:
        shelflist = (
            ub.session.query(ub.Shelf)
            .outerjoin(ub.BookShelf)
            .filter(
                or_(
                    func.datetime(ub.Shelf.last_modified)
                    > sync_token.tags_last_modified,
                    func.datetime(ub.BookShelf.date_added)
                    > sync_token.tags_last_modified,
                ),
                ub.Shelf.user_id == current_user.id,
                *extra_filters,
            )
            .distinct()
            .order_by(func.datetime(ub.Shelf.last_modified).asc())
        )

    # In non-hybrid modes, never sync the opt-in shelf even if users manually toggle it.
    if kobo_collections_mode != "hybrid":
        try:
            shelflist = shelflist.filter(ub.Shelf.name != kobo_opt_in_shelf_name)
        except Exception:
            pass

    shelves_to_force = []
    if force_book_ids:
        try:
            shelves_to_force = (
                ub.session.query(ub.Shelf)
                .join(ub.BookShelf, ub.BookShelf.shelf == ub.Shelf.id)
                .filter(
                    ub.Shelf.user_id == current_user.id,
                    ub.BookShelf.book_id.in_(list(force_book_ids)),
                    *extra_filters,
                )
                .distinct()
                .all()
            )
        except Exception:
            shelves_to_force = []

    processed_shelf_ids = set()

    # Force-create shelves whose UUIDs were backfilled so they appear immediately on device.
    for shelf in uuid_backfilled_shelves or []:
        if getattr(shelf, "id", None) in processed_shelf_ids:
            continue
        processed_shelf_ids.add(getattr(shelf, "id", None))
        if not shelf_lib.check_shelf_view_permissions(shelf):
            continue
        tag = create_kobo_tag(
            shelf,
            allowed_book_ids=allowed_book_ids,
            allow_empty=allow_empty_collections,
        )
        if not tag:
            continue
        sync_results.append({"NewTag": tag})
        try:
            new_tags_last_modified = max(now_ts_naive, new_tags_last_modified)
        except Exception:
            pass

    # Process forced shelves first so collections appear as soon as a book entitlement is synced.
    for shelf in shelves_to_force:
        if getattr(shelf, "id", None) in processed_shelf_ids:
            continue
        processed_shelf_ids.add(getattr(shelf, "id", None))
        if not shelf_lib.check_shelf_view_permissions(shelf):
            continue
        if kobo_collections_mode == "hybrid" and (
            (
                opt_in_shelf_id is not None
                and getattr(shelf, "id", None) == opt_in_shelf_id
            )
            or (opt_in_shelf_id is None and shelf.name == kobo_opt_in_shelf_name)
        ):
            continue

        tag = create_kobo_tag(
            shelf,
            allowed_book_ids=allowed_book_ids,
            allow_empty=allow_empty_collections,
        )
        if tag:
            try:
                items = tag.get("Tag", {}).get("Items")
            except Exception:
                items = None
            if allow_empty_collections and items == []:
                # Some devices won't create a brand-new collection from ChangedTag.
                try:
                    log.debug(
                        "Kobo shelves: forcing NewTag for empty shelf %r (uuid=%s)",
                        shelf.name,
                        shelf.uuid,
                    )
                except Exception:
                    pass
                sync_results.append({"NewTag": tag})
            else:
                sync_results.append({"ChangedTag": tag})
        elif allowed_book_ids is not None and not allow_empty_collections:
            # Shelf has no eligible items; ensure the collection is removed from the device.
            delete_ts = datetime.now(timezone.utc)
            new_tags_last_modified = max(
                _to_naive_datetime(delete_ts), new_tags_last_modified
            )
            sync_results.append(
                {
                    "DeletedTag": {
                        "Tag": {
                            "Id": shelf.uuid,
                            "LastModified": convert_to_kobo_timestamp_string(delete_ts),
                        }
                    }
                }
            )

    for shelf in shelflist:
        if getattr(shelf, "id", None) in processed_shelf_ids:
            continue
        processed_shelf_ids.add(getattr(shelf, "id", None))
        if not shelf_lib.check_shelf_view_permissions(shelf):
            continue

        if kobo_collections_mode == "hybrid" and (
            (
                opt_in_shelf_id is not None
                and getattr(shelf, "id", None) == opt_in_shelf_id
            )
            or (opt_in_shelf_id is None and shelf.name == kobo_opt_in_shelf_name)
        ):
            # Never sync the opt-in shelf to the Kobo
            continue

        new_tags_last_modified = max(shelf.last_modified, new_tags_last_modified)

        tag = create_kobo_tag(
            shelf,
            allowed_book_ids=allowed_book_ids,
            allow_empty=allow_empty_collections,
        )
        if not tag:
            if allowed_book_ids is not None and not allow_empty_collections:
                # Shelf has no eligible items; ensure the collection is removed from the device.
                delete_ts = now_ts
                new_tags_last_modified = max(now_ts_naive, new_tags_last_modified)
                sync_results.append(
                    {
                        "DeletedTag": {
                            "Tag": {
                                "Id": shelf.uuid,
                                "LastModified": convert_to_kobo_timestamp_string(
                                    delete_ts
                                ),
                            }
                        }
                    }
                )
            continue

        if kobo_collections_mode == "hybrid":
            # Force-create/update collections deterministically in hybrid.
            tag["Tag"]["Created"] = convert_to_kobo_timestamp_string(now_ts)
            tag["Tag"]["LastModified"] = convert_to_kobo_timestamp_string(now_ts)
            sync_results.append({"NewTag": tag})
            new_tags_last_modified = max(now_ts_naive, new_tags_last_modified)
        else:
            try:
                items = tag.get("Tag", {}).get("Items")
            except Exception:
                items = None
            if allow_empty_collections and items == []:
                # Ensure empty collections get created even if the shelf itself is old.
                try:
                    log.debug(
                        "Kobo shelves: forcing NewTag for empty shelf %r (uuid=%s)",
                        shelf.name,
                        shelf.uuid,
                    )
                except Exception:
                    pass
                sync_results.append({"NewTag": tag})
            elif shelf.created > sync_token.tags_last_modified:
                sync_results.append({"NewTag": tag})
            else:
                sync_results.append({"ChangedTag": tag})

    # If "sync empty collections" is enabled, make sure empty shelves are still emitted
    # even when they haven't changed since the last sync token.
    # Otherwise, pre-existing empty shelves can never be created on the device.
    if allow_empty_collections:
        try:
            empty_shelves = (
                ub.session.query(ub.Shelf)
                .outerjoin(ub.BookShelf)
                .filter(
                    ub.Shelf.user_id == current_user.id,
                    ub.BookShelf.id.is_(None),
                    *extra_filters,
                )
                .all()
            )
        except Exception:
            empty_shelves = []

        for empty_shelf in empty_shelves or []:
            if getattr(empty_shelf, "id", None) in processed_shelf_ids:
                continue
            processed_shelf_ids.add(getattr(empty_shelf, "id", None))
            if not shelf_lib.check_shelf_view_permissions(empty_shelf):
                continue
            if kobo_collections_mode == "hybrid" and (
                (
                    opt_in_shelf_id is not None
                    and getattr(empty_shelf, "id", None) == opt_in_shelf_id
                )
                or (
                    opt_in_shelf_id is None
                    and empty_shelf.name == kobo_opt_in_shelf_name
                )
            ):
                continue
            if empty_shelf.name == kobo_opt_in_shelf_name:
                continue

            tag = create_kobo_tag(
                empty_shelf, allowed_book_ids=allowed_book_ids, allow_empty=True
            )
            if not tag:
                continue
            try:
                log.debug(
                    "Kobo shelves: emitting empty shelf %r (uuid=%s) due to sync-empty-collections",
                    empty_shelf.name,
                    empty_shelf.uuid,
                )
            except Exception:
                pass
            sync_results.append({"NewTag": tag})
            try:
                new_tags_last_modified = max(now_ts_naive, new_tags_last_modified)
            except Exception:
                pass

    # Generated shelves don't exist in the ub.Shelf table, so we sync them separately.
    # Mode meanings (Shelves in Autocaliweb == Collections on Kobo):
    # - all: sync all shelves as collections; include generated shelves for all eligible books
    # - selected: sync only shelves marked for Kobo; optionally include generated shelves (restricted to those books)
    # - hybrid: sync only shelves marked for Kobo; include generated shelves, but only for books opted-in via
    #          the local-only 'Kobo Sync' shelf
    include_generated_in_selected = (
        kobo_collections_mode == "selected"
        and get_user_generated_shelves_sync(current_user)
    )
    sync_all_generated = (
        include_generated_in_selected
        and get_user_generated_shelves_all_books(current_user)
    )

    # If the user enables generated shelves in selected mode (or changes the selector), the device's
    # tags_last_modified can be newer than any book timestamps, so generated collections would never
    # get emitted. Track a one-time force flag in the settings DB.
    if kobo_collections_mode == "selected":
        try:
            state = _get_or_create_kobo_tag_sync_state(current_user.id)
            selector = (
                getattr(config, "config_generate_shelves_from_calibre_column", "") or ""
            )
            if state:
                prev_enabled = bool(
                    getattr(state, "include_generated_in_selected", False)
                )
                prev_selector = getattr(state, "generated_selector", "") or ""
                prev_mode = getattr(state, "collections_mode", "") or ""
                prev_sync_all = bool(getattr(state, "sync_all_generated", False))

                # Trigger force resync if any relevant setting changed
                if include_generated_in_selected and (
                    not prev_enabled
                    or prev_selector != selector
                    or prev_mode != kobo_collections_mode
                    or sync_all_generated != prev_sync_all
                ):
                    state.force_resync_generated = True

                state.include_generated_in_selected = bool(
                    include_generated_in_selected
                )
                state.generated_selector = selector
                state.collections_mode = kobo_collections_mode
                state.sync_all_generated = bool(sync_all_generated)
                ub.session_commit()
        except Exception:
            pass
    # Always run generated-shelf sync in selected mode as well.
    # Even when generated shelves are disabled, we may need to emit DeletedTag
    # to remove collections previously created in other modes.
    if (
        kobo_collections_mode in ("all", "hybrid", "selected")
        or include_generated_in_selected
    ):
        new_tags_last_modified = sync_generated_shelves(
            sync_token,
            sync_results,
            new_tags_last_modified,
            kobo_collections_mode=kobo_collections_mode,
            opt_in_shelf_name=kobo_opt_in_shelf_name,
        )
    sync_token.tags_last_modified = new_tags_last_modified
    ub.session_commit()


def _to_naive_datetime(value):
    if not value:
        return value
    try:
        if getattr(value, "tzinfo", None) is not None:
            return value.replace(tzinfo=None)
    except Exception:
        return value
    return value


def _ensure_kobo_opt_in_shelf(user_id, shelf_name: str):
    shelf = (
        ub.session.query(ub.Shelf)
        .filter(ub.Shelf.user_id == user_id, ub.Shelf.name == shelf_name)
        .first()
    )
    if shelf:
        changed = False
        try:
            if getattr(shelf, "kobo_sync", None) is not False:
                shelf.kobo_sync = False
                changed = True
        except Exception:
            pass
        try:
            if getattr(shelf, "is_public", None):
                shelf.is_public = 0
                changed = True
        except Exception:
            pass
        if changed:
            try:
                ub.session_commit()
            except Exception:
                pass
        return shelf
    shelf = ub.Shelf()
    shelf.name = shelf_name
    shelf.is_public = 0
    shelf.user_id = user_id
    shelf.kobo_sync = False
    ub.session.add(shelf)
    ub.session_commit()
    return shelf


def _get_or_create_kobo_tag_sync_state(user_id: int):
    try:
        state = (
            ub.session.query(ub.KoboTagSyncState)
            .filter(ub.KoboTagSyncState.user_id == user_id)
            .one_or_none()
        )
    except Exception:
        state = None
    if state:
        return state
    try:
        state = ub.KoboTagSyncState(user_id=user_id)
        ub.session.add(state)
        ub.session_commit()
        return state
    except Exception:
        return None


def _filter_books_by_ids(query, book_ids, chunk_size: int = 900):
    if book_ids is None:
        return query
    if not book_ids:
        # Empty list means no books should match - add an impossible filter
        return query.filter(db.Books.id.in_([]))
    try:
        book_ids = list(dict.fromkeys(book_ids))
    except Exception:
        pass
    if len(book_ids) <= chunk_size:
        return query.filter(db.Books.id.in_(book_ids))
    return query.filter(
        or_(
            *[
                db.Books.id.in_(book_ids[i : i + chunk_size])
                for i in range(0, len(book_ids), chunk_size)
            ]
        )
    )


def sync_generated_shelves(
    sync_token,
    sync_results,
    new_tags_last_modified,
    kobo_collections_mode="all",
    opt_in_shelf_name="Kobo Sync",
):
    kobo_collections_mode = (kobo_collections_mode or "").strip().lower()
    if kobo_collections_mode not in ("all", "selected", "hybrid"):
        return new_tags_last_modified
    selector = getattr(config, "config_generate_shelves_from_calibre_column", "")
    if not selector:
        return new_tags_last_modified

    allow_empty_collections = get_user_sync_empty_collections(current_user)
    eligible_book_ids = None
    trigger_ts = None
    if kobo_collections_mode == "hybrid":
        opt_in_shelf = _ensure_kobo_opt_in_shelf(current_user.id, opt_in_shelf_name)
        # Exclude archived books so generated-shelf eligibility matches shelf visibility.
        eligible_book_ids = [
            row[0]
            for row in (
                ub.session.query(ub.BookShelf.book_id)
                .outerjoin(
                    ub.ArchivedBook,
                    and_(
                        ub.ArchivedBook.user_id == int(current_user.id),
                        ub.ArchivedBook.book_id == ub.BookShelf.book_id,
                        ub.ArchivedBook.is_archived == True,
                    ),
                )
                .filter(ub.BookShelf.shelf == opt_in_shelf.id)
                .filter(ub.ArchivedBook.book_id == None)
                .all()
            )
            if row and row[0]
        ]
        if not eligible_book_ids:
            # No opted-in books => all generated collections should be removed.
            try:
                shelves = list_generated_shelves()
            except Exception:
                return new_tags_last_modified
            delete_ts = datetime.now(timezone.utc)
            delete_ts_naive = _to_naive_datetime(delete_ts)
            for gen_shelf in shelves or []:
                tag_id = getattr(gen_shelf, "uuid", None)
                if not tag_id:
                    continue
                sync_results.append(
                    {
                        "DeletedTag": {
                            "Tag": {
                                "Id": tag_id,
                                "LastModified": convert_to_kobo_timestamp_string(
                                    delete_ts
                                ),
                            }
                        }
                    }
                )
            return max(delete_ts_naive, new_tags_last_modified)
        try:
            trigger_ts = (
                ub.session.query(func.max(ub.BookShelf.date_added))
                .filter(ub.BookShelf.shelf == opt_in_shelf.id)
                .scalar()
            )
        except Exception:
            trigger_ts = None
    elif kobo_collections_mode == "selected":
        if not get_user_generated_shelves_sync(current_user):
            # Generated collections may have been created earlier in "all" mode.
            # If generation is disabled in selected mode, actively remove them so they don't linger.
            try:
                shelves = list_generated_shelves()
            except Exception:
                return new_tags_last_modified
            delete_ts = datetime.now(timezone.utc)
            delete_ts_naive = _to_naive_datetime(delete_ts)
            for gen_shelf in shelves or []:
                tag_id = getattr(gen_shelf, "uuid", None)
                if not tag_id:
                    continue
                sync_results.append(
                    {
                        "DeletedTag": {
                            "Tag": {
                                "Id": tag_id,
                                "LastModified": convert_to_kobo_timestamp_string(
                                    delete_ts
                                ),
                            }
                        }
                    }
                )
            return max(delete_ts_naive, new_tags_last_modified)

        # Check if user wants ALL generated shelves or just those for books in Kobo-synced shelves
        sync_all_generated = get_user_generated_shelves_all_books(current_user)

        if not sync_all_generated:
            # Only include generated shelves for books that are in Kobo-synced shelves
            # Start with books from regular shelves with kobo_sync enabled
            eligible_book_ids = set(
                row[0]
                for row in (
                    ub.session.query(ub.BookShelf.book_id)
                    .join(ub.Shelf, ub.Shelf.id == ub.BookShelf.shelf)
                    .outerjoin(
                        ub.ArchivedBook,
                        and_(
                            ub.ArchivedBook.user_id == int(current_user.id),
                            ub.ArchivedBook.book_id == ub.BookShelf.book_id,
                            ub.ArchivedBook.is_archived == True,
                        ),
                    )
                    .filter(
                        ub.Shelf.user_id == current_user.id,
                        ub.Shelf.kobo_sync == True,
                    )
                    .filter(ub.ArchivedBook.book_id == None)
                    .distinct()
                    .all()
                )
                if row and row[0]
            )

            # Also include books from generated shelves the user has enabled
            try:
                enabled_gen_shelves = (
                    ub.session.query(
                        ub.GeneratedShelfKoboSync.source,
                        ub.GeneratedShelfKoboSync.value,
                    )
                    .filter(
                        ub.GeneratedShelfKoboSync.user_id == current_user.id,
                        ub.GeneratedShelfKoboSync.kobo_sync == True,
                    )
                    .all()
                )
                for source, value in enabled_gen_shelves:
                    shelf_filter = generated_shelf_filter(source, value)
                    if shelf_filter is not None:
                        gen_book_ids = {
                            row[0]
                            for row in calibre_db.session.query(db.Books.id)
                            .filter(calibre_db.common_filters(), shelf_filter)
                            .all()
                            if row
                        }
                        eligible_book_ids.update(gen_book_ids)
            except Exception as e:
                log.debug(
                    "Kobo generated shelves: error fetching generated shelf books: %s",
                    e,
                )

            eligible_book_ids = list(eligible_book_ids) if eligible_book_ids else []

            if not eligible_book_ids and not allow_empty_collections:
                # No eligible books => all generated collections should be removed (unless empty collections allowed).
                try:
                    shelves = list_generated_shelves()
                except Exception:
                    return new_tags_last_modified
                delete_ts = datetime.now(timezone.utc)
                delete_ts_naive = _to_naive_datetime(delete_ts)
                for gen_shelf in shelves or []:
                    tag_id = getattr(gen_shelf, "uuid", None)
                    if not tag_id:
                        continue
                    sync_results.append(
                        {
                            "DeletedTag": {
                                "Tag": {
                                    "Id": tag_id,
                                    "LastModified": convert_to_kobo_timestamp_string(
                                        delete_ts
                                    ),
                                }
                            }
                        }
                    )
                return max(delete_ts_naive, new_tags_last_modified)
            try:
                trigger_ts = (
                    ub.session.query(func.max(ub.BookShelf.date_added))
                    .join(ub.Shelf, ub.Shelf.id == ub.BookShelf.shelf)
                    .filter(
                        ub.Shelf.user_id == current_user.id,
                        ub.Shelf.kobo_sync == True,
                    )
                    .scalar()
                )
            except Exception:
                trigger_ts = None
        else:
            # Sync ALL generated shelves - no book filtering
            eligible_book_ids = None
            trigger_ts = None

    new_tags_last_modified = _to_naive_datetime(new_tags_last_modified)
    trigger_ts = _to_naive_datetime(trigger_ts)

    try:
        shelves = list_generated_shelves(book_ids=eligible_book_ids)
    except Exception:
        return new_tags_last_modified

    # Force-resync support: when enabling generated shelves in selected mode, the device's
    # tags_last_modified can be newer than any book metadata, so nothing would ever be emitted.
    # We mark a one-time force flag in our settings DB and use it to bypass the timestamp gate.
    force_resync = False
    try:
        state = _get_or_create_kobo_tag_sync_state(current_user.id)
        if state and getattr(state, "force_resync_generated", False):
            force_resync = True
    except Exception:
        force_resync = False

    sync_all_generated = get_user_generated_shelves_all_books(current_user)

    # Fallback: if sync_all is enabled and we have shelves, but the sync token is newer than
    # all book timestamps, nothing would ever be emitted. Force a one-time resync.
    if not force_resync and sync_all_generated and shelves:
        try:
            # Check if the newest book is older than the sync token
            newest_book = calibre_db.session.query(
                func.max(db.Books.last_modified)
            ).scalar()
            newest_book = _to_naive_datetime(newest_book)
            sync_ts = _to_naive_datetime(sync_token.tags_last_modified)
            if newest_book and sync_ts and newest_book <= sync_ts:
                log.debug(
                    "Kobo generated shelves: forcing resync because all books are older than sync token"
                )
                force_resync = True
        except Exception:
            pass

    try:
        log.debug(
            "Kobo generated shelves: mode=%s selector=%s sync_all=%s eligible_books=%s force_resync=%s tags_last_modified=%s shelves_count=%s",
            kobo_collections_mode,
            selector,
            sync_all_generated,
            (len(eligible_book_ids) if eligible_book_ids is not None else "ALL"),
            force_resync,
            getattr(sync_token, "tags_last_modified", None),
            len(shelves) if shelves else 0,
        )
    except Exception:
        pass

    effective_last_sync = (
        datetime.min if force_resync else sync_token.tags_last_modified
    )

    now_force_ts = datetime.now(timezone.utc)
    now_force_ts_naive = _to_naive_datetime(now_force_ts)

    # For "selected" mode with sync_all_generated=False, pre-fetch which generated shelves
    # the user has marked for Kobo sync.
    user_enabled_generated_shelves = None
    user_enabled_generated_shelves_modified = {}
    if kobo_collections_mode == "selected" and not sync_all_generated:
        try:
            enabled_rows = (
                ub.session.query(
                    ub.GeneratedShelfKoboSync.source,
                    ub.GeneratedShelfKoboSync.value,
                    ub.GeneratedShelfKoboSync.last_modified,
                )
                .filter(
                    ub.GeneratedShelfKoboSync.user_id == current_user.id,
                    ub.GeneratedShelfKoboSync.kobo_sync == True,
                )
                .all()
            )
            user_enabled_generated_shelves = {
                (row.source, row.value) for row in enabled_rows
            }
            user_enabled_generated_shelves_modified = {
                (row.source, row.value): _to_naive_datetime(
                    getattr(row, "last_modified", None)
                )
                for row in enabled_rows
            }
            log.debug(
                "Kobo generated shelves: user has %s shelves enabled for sync",
                len(user_enabled_generated_shelves),
            )
        except Exception as e:
            log.debug("Kobo generated shelves: failed to fetch user preferences: %s", e)
            user_enabled_generated_shelves = set()
            user_enabled_generated_shelves_modified = {}

    emitted = 0
    emitted_items = 0
    for gen_shelf in shelves:
        # In "selected" mode with sync_all_generated=False, only sync shelves the user has enabled
        if user_enabled_generated_shelves is not None:
            if (
                gen_shelf.source,
                gen_shelf.value,
            ) not in user_enabled_generated_shelves:
                continue

        pref_last_modified = None
        try:
            pref_last_modified = user_enabled_generated_shelves_modified.get(
                (gen_shelf.source, gen_shelf.value)
            )
        except Exception:
            pref_last_modified = None

        shelf_filter = generated_shelf_filter(gen_shelf.source, gen_shelf.value)
        if shelf_filter is None:
            continue

        if force_resync:
            effective_modified = now_force_ts_naive
        else:
            max_modified_query = (
                calibre_db.session.query(func.max(db.Books.last_modified))
                .filter(calibre_db.common_filters())
                .filter(shelf_filter)
            )
            if eligible_book_ids is not None:
                max_modified_query = _filter_books_by_ids(
                    max_modified_query, eligible_book_ids
                )
            max_modified = max_modified_query.scalar()
            max_modified = _to_naive_datetime(max_modified)
            if not max_modified:
                # No eligible books (or no timestamps). If empty collections are allowed, still emit
                # using a preference/trigger timestamp so newly-enabled shelves can be created.
                if allow_empty_collections and (pref_last_modified or trigger_ts):
                    effective_modified = pref_last_modified or trigger_ts
                else:
                    continue
            else:
                effective_modified = max_modified
            if trigger_ts is not None:
                effective_modified = max(effective_modified, trigger_ts)
            if pref_last_modified is not None:
                effective_modified = max(effective_modified, pref_last_modified)
            if effective_modified <= effective_last_sync:
                continue

        book_uuid_query = (
            calibre_db.session.query(db.Books.uuid)
            .filter(calibre_db.common_filters())
            .filter(shelf_filter)
            .filter(db.Books.uuid != None)
        )
        if eligible_book_ids is not None:
            book_uuid_query = _filter_books_by_ids(book_uuid_query, eligible_book_ids)
        book_uuid_rows = book_uuid_query.all()
        book_uuids = [row[0] for row in book_uuid_rows if row and row[0]]

        if not book_uuids:
            # Generated shelf exists but has no eligible books
            if not allow_empty_collections:
                # Ensure collection is removed
                delete_ts = datetime.now(timezone.utc)
                tag_id = getattr(gen_shelf, "uuid", None)
                if tag_id:
                    sync_results.append(
                        {
                            "DeletedTag": {
                                "Tag": {
                                    "Id": tag_id,
                                    "LastModified": convert_to_kobo_timestamp_string(
                                        delete_ts
                                    ),
                                }
                            }
                        }
                    )
                    new_tags_last_modified = max(
                        _to_naive_datetime(delete_ts), new_tags_last_modified
                    )
                continue
            # else: allow_empty_collections is True, fall through to create the empty tag

        tag = create_kobo_tag_generated(
            gen_shelf, book_uuids, effective_modified, effective_modified
        )
        if not tag:
            continue

        new_tags_last_modified = max(effective_modified, new_tags_last_modified)
        # Use NewTag to ensure Kobo creates the collection if it doesn't exist yet.
        sync_results.append({"NewTag": tag})
        emitted += 1
        try:
            emitted_items += len(book_uuids)
        except Exception:
            pass

    try:
        log.debug(
            "Kobo generated shelves: emitted=%s items=%s (force_resync=%s)",
            emitted,
            emitted_items,
            force_resync,
        )
    except Exception:
        pass

    # If filtering by user preferences, delete collections for generated shelves that are NOT enabled.
    # Note: when eligible_book_ids is used, `shelves` may be filtered to only those with eligible books.
    # We still need to delete disabled shelves that may linger on the device from earlier syncs.
    if user_enabled_generated_shelves is not None:
        delete_candidates = shelves
        try:
            if eligible_book_ids is not None:
                delete_candidates = list_generated_shelves()
        except Exception:
            delete_candidates = shelves

        delete_ts = datetime.now(timezone.utc)
        for gen_shelf in delete_candidates or []:
            if (gen_shelf.source, gen_shelf.value) in user_enabled_generated_shelves:
                continue  # This one is enabled, don't delete
            tag_id = getattr(gen_shelf, "uuid", None)
            if tag_id:
                sync_results.append(
                    {
                        "DeletedTag": {
                            "Tag": {
                                "Id": tag_id,
                                "LastModified": convert_to_kobo_timestamp_string(
                                    delete_ts
                                ),
                            }
                        }
                    }
                )
        new_tags_last_modified = max(
            _to_naive_datetime(delete_ts), new_tags_last_modified
        )

    if force_resync:
        try:
            state = _get_or_create_kobo_tag_sync_state(current_user.id)
            if state and getattr(state, "force_resync_generated", False):
                state.force_resync_generated = False
                ub.session_commit()
        except Exception:
            pass

    return new_tags_last_modified


# Creates a Kobo "Tag" object from an ub.Shelf object
def create_kobo_tag(shelf, allowed_book_ids=None, allow_empty=False):
    tag = {
        "Created": convert_to_kobo_timestamp_string(shelf.created),
        "Id": shelf.uuid,
        "Items": [],
        "LastModified": convert_to_kobo_timestamp_string(shelf.last_modified),
        "Name": shelf.name,
        "Type": "UserTag",
    }
    for book_shelf in shelf.books:
        if allowed_book_ids is not None and book_shelf.book_id not in allowed_book_ids:
            continue
        book = calibre_db.get_book(book_shelf.book_id)
        if not book:
            log.info(
                "Book (id: %s) in BookShelf (id: %s) not found in book database",
                book_shelf.book_id,
                shelf.id,
            )
            continue
        tag["Items"].append({"RevisionId": book.uuid, "Type": "ProductRevisionTagItem"})
    if allowed_book_ids is not None and not tag["Items"] and not allow_empty:
        return None
    return {"Tag": tag}


def create_kobo_tag_generated(gen_shelf, book_uuids, last_modified, created):
    tag = {
        "Created": convert_to_kobo_timestamp_string(created),
        "Id": getattr(gen_shelf, "uuid", None),
        "Items": [],
        "LastModified": convert_to_kobo_timestamp_string(last_modified),
        "Name": getattr(gen_shelf, "name", ""),
        "Type": "UserTag",
    }
    if not tag["Id"] or not tag["Name"]:
        return None
    for book_uuid in book_uuids or []:
        tag["Items"].append({"RevisionId": book_uuid, "Type": "ProductRevisionTagItem"})
    return {"Tag": tag}


@csrf.exempt
@kobo.route("/v1/library/<book_uuid>/state", methods=["GET", "PUT"])
@requires_kobo_auth
def HandleStateRequest(book_uuid):
    book = calibre_db.get_book_by_uuid(book_uuid)
    if not book or not book.data:
        log.info("Book %s not found in database", book_uuid)
        return redirect_or_proxy_request()

    kobo_reading_state = get_or_create_reading_state(book.id)

    if request.method == "GET":
        return jsonify([get_kobo_reading_state_response(book, kobo_reading_state)])
    else:
        update_results_response = {"EntitlementId": book_uuid}

        try:
            request_data = request.json
            request_reading_state = request_data["ReadingStates"][0]

            request_bookmark = request_reading_state["CurrentBookmark"]
            if request_bookmark:
                current_bookmark = kobo_reading_state.current_bookmark
                current_bookmark.progress_percent = request_bookmark["ProgressPercent"]
                current_bookmark.content_source_progress_percent = request_bookmark[
                    "ContentSourceProgressPercent"
                ]
                location = request_bookmark["Location"]
                if location:
                    current_bookmark.location_value = location["Value"]
                    current_bookmark.location_type = location["Type"]
                    current_bookmark.location_source = location["Source"]
                update_results_response["CurrentBookmarkResult"] = {"Result": "Success"}

            request_statistics = request_reading_state["Statistics"]
            if request_statistics:
                statistics = kobo_reading_state.statistics
                statistics.spent_reading_minutes = int(
                    request_statistics["SpentReadingMinutes"]
                )
                statistics.remaining_time_minutes = int(
                    request_statistics["RemainingTimeMinutes"]
                )
                update_results_response["StatisticsResult"] = {"Result": "Success"}

            request_status_info = request_reading_state["StatusInfo"]
            if request_status_info:
                book_read = kobo_reading_state.book_read_link
                new_book_read_status = get_ub_read_status(request_status_info["Status"])
                if (
                    new_book_read_status == ub.ReadBook.STATUS_IN_PROGRESS
                    and new_book_read_status != book_read.read_status
                ):
                    book_read.times_started_reading += 1
                    book_read.last_time_started_reading = datetime.now(timezone.utc)
                book_read.read_status = new_book_read_status
                update_results_response["StatusInfoResult"] = {"Result": "Success"}
        except (KeyError, TypeError, ValueError, StatementError):
            log.debug("Received malformed v1/library/<book_uuid>/state request.")
            ub.session.rollback()
            abort(
                400, description="Malformed request data is missing 'ReadingStates' key"
            )

        push_reading_state_to_hardcover(book, request_bookmark)

        ub.session.merge(kobo_reading_state)
        ub.session_commit()
        return jsonify(
            {
                "RequestResult": "Success",
                "UpdateResults": [update_results_response],
            }
        )


def push_reading_state_to_hardcover(book: db.Books, request_bookmark: dict):
    """
    Sync reading progress to Hardcover if enabled for the user and book is not blacklisted.

    Most exceptions are caught and logged so that issues with Hardcover do not prevent
    the Kobo from clearing its reading state sync queue.

    :param book: The book for which to sync reading progress.
    :param request_bookmark: The bookmark data from the Kobo request.
    :return: None
    """
    if not config.config_hardcover_sync or not bool(hardcover):
        return

    blacklist = (
        ub.session.query(ub.HardcoverBookBlacklist)
        .filter(ub.HardcoverBookBlacklist.book_id == book.id)
        .first()
    )

    if blacklist and blacklist.blacklist_reading_progress:
        log.debug(
            f"Skipping reading progress sync for book {book.id} - blacklisted for reading progress"
        )
        return

    try:
        hardcoverClient = hardcover.HardcoverClient(current_user.hardcover_token)
    except hardcover.MissingHardcoverToken:
        log.info(
            f"User {current_user.name} has no token for Hardcover configured, no syncing to Hardcover."
        )
        return
    except Exception as e:
        log.error(
            f"Failed to create Hardcover client for user {current_user.name}: {e}"
        )
        return

    try:
        hardcoverClient.update_reading_progress(
            book.identifiers, request_bookmark["ProgressPercent"]
        )
    except Exception as e:
        log.error(f"Failed to update progress for book {book.id} in Hardcover: {e}")


def get_read_status_for_kobo(ub_book_read):
    enum_to_string_map = {
        None: "ReadyToRead",
        ub.ReadBook.STATUS_UNREAD: "ReadyToRead",
        ub.ReadBook.STATUS_FINISHED: "Finished",
        ub.ReadBook.STATUS_IN_PROGRESS: "Reading",
    }
    return enum_to_string_map[ub_book_read.read_status]


def get_ub_read_status(kobo_read_status):
    string_to_enum_map = {
        None: None,
        "ReadyToRead": ub.ReadBook.STATUS_UNREAD,
        "Finished": ub.ReadBook.STATUS_FINISHED,
        "Reading": ub.ReadBook.STATUS_IN_PROGRESS,
    }
    return string_to_enum_map[kobo_read_status]


def get_or_create_reading_state(book_id):
    book_read = (
        ub.session.query(ub.ReadBook)
        .filter(
            ub.ReadBook.book_id == book_id, ub.ReadBook.user_id == int(current_user.id)
        )
        .one_or_none()
    )
    if not book_read:
        book_read = ub.ReadBook(user_id=current_user.id, book_id=book_id)
    if not book_read.kobo_reading_state:
        kobo_reading_state = ub.KoboReadingState(
            user_id=book_read.user_id, book_id=book_id
        )
        kobo_reading_state.current_bookmark = ub.KoboBookmark()
        kobo_reading_state.statistics = ub.KoboStatistics()
        book_read.kobo_reading_state = kobo_reading_state
    ub.session.add(book_read)
    ub.session_commit()
    return book_read.kobo_reading_state


def get_kobo_reading_state_response(book, kobo_reading_state):
    return {
        "EntitlementId": book.uuid,
        "Created": convert_to_kobo_timestamp_string(book.timestamp),
        "LastModified": convert_to_kobo_timestamp_string(
            kobo_reading_state.last_modified
        ),
        # AFAICT PriorityTimestamp is always equal to LastModified.
        "PriorityTimestamp": convert_to_kobo_timestamp_string(
            kobo_reading_state.priority_timestamp
        ),
        "StatusInfo": get_status_info_response(kobo_reading_state.book_read_link),
        "Statistics": get_statistics_response(kobo_reading_state.statistics),
        "CurrentBookmark": get_current_bookmark_response(
            kobo_reading_state.current_bookmark
        ),
    }


def get_status_info_response(book_read):
    resp = {
        "LastModified": convert_to_kobo_timestamp_string(book_read.last_modified),
        "Status": get_read_status_for_kobo(book_read),
        "TimesStartedReading": book_read.times_started_reading,
    }
    if book_read.last_time_started_reading:
        resp["LastTimeStartedReading"] = convert_to_kobo_timestamp_string(
            book_read.last_time_started_reading
        )
    return resp


def get_statistics_response(statistics):
    resp = {
        "LastModified": convert_to_kobo_timestamp_string(statistics.last_modified),
    }
    if statistics.spent_reading_minutes:
        resp["SpentReadingMinutes"] = statistics.spent_reading_minutes
    if statistics.remaining_time_minutes:
        resp["RemainingTimeMinutes"] = statistics.remaining_time_minutes
    return resp


def get_current_bookmark_response(current_bookmark):
    resp = {
        "LastModified": convert_to_kobo_timestamp_string(
            current_bookmark.last_modified
        ),
    }
    if current_bookmark.progress_percent:
        resp["ProgressPercent"] = current_bookmark.progress_percent
    if current_bookmark.content_source_progress_percent:
        resp["ContentSourceProgressPercent"] = (
            current_bookmark.content_source_progress_percent
        )
    if current_bookmark.location_value:
        resp["Location"] = {
            "Value": current_bookmark.location_value,
            "Type": current_bookmark.location_type,
            "Source": current_bookmark.location_source,
        }
    return resp


@kobo.route(
    "/<book_uuid>/<width>/<height>/<isGreyscale>/image.jpg", defaults={"Quality": ""}
)
@kobo.route("/<book_uuid>/<width>/<height>/<Quality>/<isGreyscale>/image.jpg")
@kobo.route(
    "/<book_uuid>/<version>/<width>/<height>/<isGreyscale>/image.jpg",
    defaults={"Quality": ""},
)
@kobo.route("/<book_uuid>/<version>/<width>/<height>/<Quality>/<isGreyscale>/image.jpg")
@requires_kobo_auth
def HandleCoverImageRequest(book_uuid, version, width, height, Quality, isGreyscale):
    try:
        if int(height) > 1000:
            resolution = COVER_THUMBNAIL_LARGE
        elif int(height) > 500:
            resolution = COVER_THUMBNAIL_MEDIUM
        else:
            resolution = COVER_THUMBNAIL_SMALL
    except ValueError:
        log.error("Requested height %s of book %s is invalid" % (book_uuid, height))
        resolution = COVER_THUMBNAIL_SMALL
    book_cover = helper.get_book_cover_with_uuid(book_uuid, resolution=resolution)
    if book_cover:
        log.debug("Serving local cover image of book %s" % book_uuid)

        # In hybrid mode, cover requests are a good signal that the device still has/cares about a local book.
        # If it's not opted-in, track it so the next sync can archive/remove it.
        try:
            kobo_collections_mode = get_user_kobo_collections_mode(current_user)
            if kobo_collections_mode == "hybrid" and _effective_only_kobo_shelves_sync(
                current_user
            ):
                book = calibre_db.get_book_by_uuid(book_uuid)
                if book:
                    opt_in_shelf = _ensure_kobo_opt_in_shelf(
                        current_user.id, "Kobo Sync"
                    )
                    in_opt_in = bool(
                        ub.session.query(ub.BookShelf)
                        .filter(
                            ub.BookShelf.book_id == book.id,
                            ub.BookShelf.shelf == opt_in_shelf.id,
                        )
                        .first()
                    )
                    if not in_opt_in:
                        log.debug(
                            "Hybrid cover request: calibre_book_id=%s uuid=%s title=%s in_opt_in=%s",
                            book.id,
                            getattr(book, "uuid", None),
                            getattr(book, "title", None),
                            in_opt_in,
                        )
                        kobo_sync_status.add_synced_books(
                            book.id, reason="observed:cover-non-opt-in"
                        )
        except Exception:
            pass
        telemetry = _record_kobo_cover_telemetry(
            getattr(current_user, "id", None), book_uuid, resolution
        )
        if telemetry:
            # Avoid log spam: always log the first few, then every 25th, and after pauses.
            since_prev = telemetry.get("since_prev")
            cnt = telemetry.get("count")
            if (
                cnt <= 5
                or (cnt % 25) == 0
                or (since_prev is not None and since_prev > 15)
            ):
                log.debug(
                    "Kobo cover telemetry: user_id=%s count=%s since_prev_s=%s uuid=%s res=%s",
                    getattr(current_user, "id", None),
                    cnt,
                    since_prev,
                    book_uuid,
                    resolution,
                )
        return book_cover

    if not config.config_kobo_proxy:
        log.debug("Returning 404 for cover image of unknown book %s" % book_uuid)
        # additional proxy request make no sense, -> direct return
        return abort(404)

    log.debug(
        "Redirecting request for cover image of unknown book %s to Kobo" % book_uuid
    )
    return redirect(
        KOBO_IMAGEHOST_URL
        + "/{book_uuid}/{width}/{height}/false/image.jpg".format(
            book_uuid=book_uuid, width=width, height=height
        ),
        307,
    )


@kobo.route("")
def TopLevelEndpoint():
    return make_response(jsonify({}))


@csrf.exempt
@kobo.route("/v1/library/<book_uuid>", methods=["DELETE"])
@requires_kobo_auth
def HandleBookDeletionRequest(book_uuid):
    log.debug("Kobo book delete request received for book %s", book_uuid)
    book = calibre_db.get_book_by_uuid(book_uuid)
    if not book:
        log.debug(
            "Book %s not found in database, returning success to clear device reference",
            book_uuid,
        )
        # Book doesn't exist in our database. Return success so the device
        # clears its stale reference. Don't proxy to Kobo - these are likely
        # old numeric Calibre IDs or deleted local books, not Kobo store books.
        return "", 204

    book_id = book.id

    if not _effective_only_kobo_shelves_sync(
        current_user
    ) and current_user.check_visibility(32768):
        kobo_sync_status.change_archived_books(book_id, True)

    is_archived = kobo_sync_status.change_archived_books(book_id, True)
    if is_archived:
        kobo_sync_status.remove_synced_book(book_id)
    return "", 204


# TODO: Implement the following routes
@csrf.exempt
@kobo.route("/v1/library/<dummy>", methods=["DELETE", "GET", "POST"])
@kobo.route("/v1/library/<dummy>/preview", methods=["POST"])
def HandleUnimplementedRequest(dummy=None):
    log.debug(
        "Unimplemented Library Request received: %s (%s)",
        request.base_url,
        "forwarded to Kobo Store"
        if config.config_kobo_proxy
        else "returning empty response",
    )
    return redirect_or_proxy_request()


# TODO: Implement the following routes
@csrf.exempt
@kobo.route("/v1/user/loyalty/<dummy>", methods=["GET", "POST"])
def HandleLoyaltyRequest(dummy=None):
    log.debug("Loyalty request received, returning empty response")
    return make_response(jsonify({}))


@csrf.exempt
@kobo.route("/v1/user/profile", methods=["GET", "POST"])
def HandleUserProfileRequest():
    log.debug("User profile request received, returning empty response")
    return make_response(jsonify({}))


@csrf.exempt
@kobo.route("/v1/user/wishlist", methods=["GET", "POST"])
def HandleWishlistRequest():
    log.debug("Wishlist request received, returning empty response")
    return make_response(jsonify({"Items": [], "TotalCount": 0}))


@csrf.exempt
@kobo.route("/v1/user/recommendations", methods=["GET", "POST"])
def HandleRecommendationsRequest():
    log.debug("Recommendations request received, returning empty response")
    return make_response(jsonify({"Items": [], "TotalCount": 0}))


@csrf.exempt
@kobo.route("/v1/analytics/<dummy>", methods=["GET", "POST"])
def HandleAnalyticsRequest(dummy=None):
    log.debug("Analytics request received, returning empty response (not proxied)")
    return make_response(jsonify({}))


@csrf.exempt
@kobo.route("/v1/assets", methods=["GET"])
def HandleAssetsRequest():
    log.debug("Assets request received, returning empty response")
    return make_response(jsonify([]))


@csrf.exempt
@kobo.route("/v2/user/tasteprofile/genre", methods=["GET", "POST"])
@kobo.route("/v2/user/tasteprofile/complete", methods=["GET", "POST"])
def HandleTasteProfileRequest():
    log.debug("Taste profile request received, returning empty response")
    return make_response(jsonify({}))


@csrf.exempt
@kobo.route("/v1/user/loyalty/benefits", methods=["GET"])
def handle_benefits():
    return make_response(jsonify({"Benefits": {}}))


@csrf.exempt
@kobo.route("/v1/analytics/gettests", methods=["GET", "POST"])
def handle_getests():
    testkey = request.headers.get("X-Kobo-userkey", "")
    return make_response(
        jsonify({"Result": "Success", "TestKey": testkey, "Tests": {}})
    )


@csrf.exempt
@kobo.route("/v1/products/<dummy>/prices", methods=["GET", "POST"])
@kobo.route("/v1/products/<dummy>/recommendations", methods=["GET", "POST"])
@kobo.route("/v1/products/<dummy>/nextread", methods=["GET", "POST"])
@kobo.route("/v1/products/<dummy>/reviews", methods=["GET", "POST"])
@kobo.route("/v1/products/featured/<dummy>", methods=["GET", "POST"])
@kobo.route("/v1/products/featured/", methods=["GET", "POST"])
@kobo.route("/v1/products/books/external/<dummy>", methods=["GET", "POST"])
@kobo.route("/v1/products/books/series/<dummy>", methods=["GET", "POST"])
@kobo.route("/v1/products/books/<dummy>", methods=["GET", "POST"])
@kobo.route("/v1/products/books/<dummy>/", methods=["GET", "POST"])
@kobo.route("/v1/products/dailydeal", methods=["GET", "POST"])
@kobo.route("/v1/products/deals", methods=["GET", "POST"])
@kobo.route("/v1/products", methods=["GET", "POST"])
@kobo.route("/v1/products/<path:dummy>", methods=["GET", "POST"])
@kobo.route("/v1/products/<path:dummy>/", methods=["GET", "POST"])
@kobo.route("/v1/affiliate", methods=["GET", "POST"])
@kobo.route("/v1/deals", methods=["GET", "POST"])
@kobo.route("/v1/categories/<dummy>", methods=["GET", "POST"])
@kobo.route("/v1/categories/<dummy>/featured", methods=["GET", "POST"])
@kobo.route("/v2/products", methods=["GET", "POST"])
@kobo.route("/v2/products/<path:dummy>", methods=["GET", "POST"])
@kobo.route("/v2/products/<path:dummy>/", methods=["GET", "POST"])
@kobo.route("/api/v2/Categories/Top", methods=["GET", "POST"])
def HandleProductsRequest(dummy=None):
    log.debug(
        "Unimplemented Products Request received: %s (request is forwarded to kobo if configured)",
        request.base_url,
    )
    return redirect_or_proxy_request()


def make_calibre_web_auth_response():
    # As described in kobo_auth.py, Autocaliweb doesn't make use practical use of this auth/device API call for
    # authentation (nor for authorization). We return a dummy response just to keep the device happy.
    content = request.get_json()
    AccessToken = base64.b64encode(os.urandom(24)).decode("utf-8")
    RefreshToken = base64.b64encode(os.urandom(24)).decode("utf-8")
    return make_response(
        jsonify(
            {
                "AccessToken": AccessToken,
                "RefreshToken": RefreshToken,
                "TokenType": "Bearer",
                "TrackingId": str(uuid.uuid4()),
                "UserKey": content.get("UserKey", ""),
            }
        )
    )


@csrf.exempt
@kobo.route("/v1/auth/device", methods=["POST"])
@requires_kobo_auth
def HandleAuthRequest():
    log.debug("Kobo Auth request")
    if config.config_kobo_proxy:
        try:
            return redirect_or_proxy_request(auth=True)
        except Exception:
            log.error(
                "Failed to receive or parse response from Kobo's auth endpoint. Falling back to un-proxied mode."
            )
    return make_calibre_web_auth_response()


@kobo.route("/v1/initialization")
@requires_kobo_auth
def HandleInitRequest():
    log.info("Init")

    kobo_resources = None
    if config.config_kobo_proxy:
        try:
            store_response = make_request_to_kobo_store()
            store_response_json = store_response.json()

            if rs := store_response_json.get("ResponseStatus", {}):
                if ec := rs.get("ErrorCode", ""):
                    msg = rs.get("Message", "(No message provided)")
                    if ec == "ExpiredToken":
                        log.info(
                            f"Kobo Store session expired: {msg}. Reauthentication triggered."
                        )
                        return make_proxy_response(store_response)
                    log.warning(
                        f"Kobo: Kobo Store initialization returned error code {ec}: {msg}"
                    )

            if "Resources" in store_response_json:
                kobo_resources = store_response_json["Resources"]
            else:
                log.error(
                    "Kobo: Kobo Store initialization response missing 'Resources' field."
                )
        except Exception as e:
            log.error(
                f"Failed to receive or parse response from Kobo's initialization endpoint: {e}"
            )
    if not kobo_resources:
        log.debug("Using fallback Kobo recource definitions")
        kobo_resources = NATIVE_KOBO_RESOURCES()

    if current_user is not None:
        try:
            plus_enabled = bool(getattr(current_user, "kobo_plus", False))
            borrow_enabled = bool(getattr(current_user, "kobo_overdrive", False))
            audiobooks_enabled = bool(getattr(current_user, "kobo_audiobooks", False))
            ip_enabled = bool(getattr(current_user, "kobo_instapaper", False))
        except AttributeError:
            pass

    if not current_app.wsgi_app.is_proxied:
        log.debug(
            "Kobo: Received unproxied request, changed request port to external server port"
        )
        if ":" in request.host and not request.host.endswith("]"):
            host = "".join(request.host.split(":")[:-1])
        else:
            host = request.host
        calibre_web_url = "{url_scheme}://{url_base}:{url_port}".format(
            url_scheme=request.scheme,
            url_base=host,
            url_port=config.config_external_port,
        )
        log.debug(
            "Kobo: Received unproxied request, changed request url to %s",
            calibre_web_url,
        )
        kobo_resources["image_host"] = calibre_web_url
        kobo_resources["image_url_quality_template"] = unquote(
            calibre_web_url
            + url_for(
                "kobo.HandleCoverImageRequest",
                auth_token=kobo_auth.get_auth_token(),
                book_uuid="{ImageId}",
                width="{width}",
                height="{height}",
                Quality="{Quality}",
                isGreyscale="isGreyscale",
            )
        )
        kobo_resources["image_url_template"] = unquote(
            calibre_web_url
            + url_for(
                "kobo.HandleCoverImageRequest",
                auth_token=kobo_auth.get_auth_token(),
                book_uuid="{ImageId}",
                width="{width}",
                height="{height}",
                isGreyscale="false",
            )
        )
        if config.config_hardcover_annosync and bool(hardcover):
            kobo_resources["reading_services_host"] = calibre_web_url
        kobo_resources["kobo_subscriptions_enabled"] = plus_enabled
        kobo_resources["kobo_nativeborrow_enabled"] = borrow_enabled
        kobo_resources["kobo_audiobooks_enabled"] = audiobooks_enabled
        kobo_resources["instapaper_enabled"] = ip_enabled
        if ip_enabled:
            log.debug("Kobo: Instapaper integration enabled, checking endpoints")
            if (
                kobo_resources["instapaper_env_url"]
                != "https://www.instapaper.com/api/kobo"
            ):
                log.debug(
                    'Kobo: Changed instapaper_env_url to "https://www.instapaper.com/api/kobo"'
                )
                kobo_resources["instapaper_env_url"] = (
                    "https://www.instapaper.com/api/kobo"
                )
            if (
                kobo_resources["instapaper_link_account_start"]
                != "https://authorize.kobo.com/{region}/{language}/linkinstapaper"
            ):
                log.debug(
                    'Kobo: Changed instapaper_link_account_start to "https://authorize.kobo.com/{region}/{language}/linkinstapaper"'
                )
                kobo_resources["instapaper_link_account_start"] = (
                    "https://authorize.kobo.com/{region}/{language}/linkinstapaper"
                )
    else:
        kobo_resources["image_host"] = url_for("web.index", _external=True).strip("/")
        kobo_resources["image_url_quality_template"] = unquote(
            url_for(
                "kobo.HandleCoverImageRequest",
                auth_token=kobo_auth.get_auth_token(),
                book_uuid="{ImageId}",
                width="{width}",
                height="{height}",
                Quality="{Quality}",
                isGreyscale="isGreyscale",
                _external=True,
            )
        )
        kobo_resources["image_url_template"] = unquote(
            url_for(
                "kobo.HandleCoverImageRequest",
                auth_token=kobo_auth.get_auth_token(),
                book_uuid="{ImageId}",
                width="{width}",
                height="{height}",
                isGreyscale="false",
                _external=True,
            )
        )
        if config.config_hardcover_annosync and bool(hardcover):
            kobo_resources["reading_services_host"] = url_for(
                "web.index", _external=True
            ).strip("/")
        kobo_resources["kobo_subscriptions_enabled"] = plus_enabled
        kobo_resources["kobo_nativeborrow_enabled"] = borrow_enabled
        kobo_resources["kobo_audiobooks_enabled"] = audiobooks_enabled
        kobo_resources["instapaper_enabled"] = ip_enabled
        if ip_enabled:
            log.debug("Kobo: Instapaper integration enabled, checking endpoints")
            if (
                kobo_resources["instapaper_env_url"]
                != "https://www.instapaper.com/api/kobo"
            ):
                log.debug(
                    'Kobo: Changed instapaper_env_url to "https://www.instapaper.com/api/kobo"'
                )
                kobo_resources["instapaper_env_url"] = (
                    "https://www.instapaper.com/api/kobo"
                )
            if (
                kobo_resources["instapaper_link_account_start"]
                != "https://authorize.kobo.com/{region}/{language}/linkinstapaper"
            ):
                log.debug(
                    'Kobo: Changed instapaper_link_account_start to "https://authorize.kobo.com/{region}/{language}/linkinstapaper"'
                )
                kobo_resources["instapaper_link_account_start"] = (
                    "https://authorize.kobo.com/{region}/{language}/linkinstapaper"
                )

    response = make_response(jsonify({"Resources": kobo_resources}))
    response.headers["x-kobo-apitoken"] = "e30="

    return response


@kobo.route("/download/<book_id>/<book_format>")
@requires_kobo_auth
@download_required
def download_book(book_id, book_format):
    # In hybrid mode, a download request for a non-opt-in book indicates the device is trying to keep/restore it.
    # Track it so the next sync can archive/remove it if needed.
    try:
        kobo_collections_mode = get_user_kobo_collections_mode(current_user)
        if kobo_collections_mode == "hybrid" and _effective_only_kobo_shelves_sync(
            current_user
        ):
            try:
                calibre_book_id = int(book_id)
            except Exception:
                calibre_book_id = None
            if calibre_book_id:
                opt_in_shelf = _ensure_kobo_opt_in_shelf(current_user.id, "Kobo Sync")
                in_opt_in = bool(
                    ub.session.query(ub.BookShelf)
                    .filter(
                        ub.BookShelf.book_id == calibre_book_id,
                        ub.BookShelf.shelf == opt_in_shelf.id,
                    )
                    .first()
                )
                if not in_opt_in:
                    log.debug(
                        "Hybrid download request: calibre_book_id=%s format=%s in_opt_in=%s",
                        calibre_book_id,
                        book_format,
                        in_opt_in,
                    )
                    kobo_sync_status.add_synced_books(
                        calibre_book_id, reason="observed:download-non-opt-in"
                    )
    except Exception:
        pass
    return get_download_link(book_id, book_format, "kobo")


def NATIVE_KOBO_RESOURCES():
    return {
        "account_page": "https://www.kobo.com/account/settings",
        "account_page_rakuten": "https://my.rakuten.co.jp/",
        "add_device": "https://storeapi.kobo.com/v1/user/add-device",
        "add_entitlement": "https://storeapi.kobo.com/v1/library/{RevisionIds}",
        "affiliaterequest": "https://storeapi.kobo.com/v1/affiliate",
        "assets": "https://storeapi.kobo.com/v1/assets",
        "audiobook": "https://storeapi.kobo.com/v1/products/audiobooks/{ProductId}",
        "audiobook_detail_page": "https://www.kobo.com/{region}/{language}/audiobook/{slug}",
        "audiobook_get_credits": "https://www.kobo.com/{region}/{language}/audiobooks/plans",
        "audiobook_landing_page": "https://www.kobo.com/{region}/{language}/audiobooks",
        "audiobook_preview": "https://storeapi.kobo.com/v1/products/audiobooks/{Id}/preview",
        "audiobook_purchase_withcredit": "https://storeapi.kobo.com/v1/store/audiobook/{Id}",
        "audiobook_subscription_management": "https://www.kobo.com/{region}/{language}/account/subscriptions",
        "audiobook_subscription_orange_deal_inclusion_url": "https://authorize.kobo.com/inclusion",
        "audiobook_subscription_purchase": "https://www.kobo.com/{region}/{language}/checkoutoption/21C6D938-934B-4A91-B979-E14D70B2F280",
        "audiobook_subscription_tiers": "https://www.kobo.com/{region}/{language}/checkoutoption/21C6D938-934B-4A91-B979-E14D70B2F280",
        "authorproduct_recommendations": "https://storeapi.kobo.com/v1/products/books/authors/recommendations",
        "autocomplete": "https://storeapi.kobo.com/v1/products/autocomplete",
        "blackstone_header": {"key": "x-amz-request-payer", "value": "requester"},
        "book": "https://storeapi.kobo.com/v1/products/books/{ProductId}",
        "book_detail_page": "https://www.kobo.com/{region}/{language}/ebook/{slug}",
        "book_detail_page_rakuten": "http://books.rakuten.co.jp/rk/{crossrevisionid}",
        "book_landing_page": "https://www.kobo.com/ebooks",
        "book_subscription": "https://storeapi.kobo.com/v1/products/books/subscriptions",
        "browse_history": "https://storeapi.kobo.com/v1/user/browsehistory",
        "categories": "https://storeapi.kobo.com/v1/categories",
        "categories_page": "https://www.kobo.com/ebooks/categories",
        "category": "https://storeapi.kobo.com/v1/categories/{CategoryId}",
        "category_featured_lists": "https://storeapi.kobo.com/v1/categories/{CategoryId}/featured",
        "category_products": "https://storeapi.kobo.com/v1/categories/{CategoryId}/products",
        "checkout_borrowed_book": "https://storeapi.kobo.com/v1/library/borrow",
        "client_authd_referral": "https://authorize.kobo.com/api/AuthenticatedReferral/client/v1/getLink",
        "configuration_data": "https://storeapi.kobo.com/v1/configuration",
        "content_access_book": "https://storeapi.kobo.com/v1/products/books/{ProductId}/access",
        "customer_care_live_chat": "https://v2.zopim.com/widget/livechat.html?key=Y6gwUmnu4OATxN3Tli4Av9bYN319BTdO",
        "daily_deal": "https://storeapi.kobo.com/v1/products/dailydeal",
        "deals": "https://storeapi.kobo.com/v1/deals",
        "delete_entitlement": "https://storeapi.kobo.com/v1/library/{Ids}",
        "delete_tag": "https://storeapi.kobo.com/v1/library/tags/{TagId}",
        "delete_tag_items": "https://storeapi.kobo.com/v1/library/tags/{TagId}/items/delete",
        "device_auth": "https://storeapi.kobo.com/v1/auth/device",
        "device_refresh": "https://storeapi.kobo.com/v1/auth/refresh",
        "dictionary_host": "https://ereaderfiles.kobo.com",
        "discovery_host": "https://discovery.kobobooks.com",
        "dropbox_link_account_poll": "https://authorize.kobo.com/{region}/{language}/LinkDropbox",
        "dropbox_link_account_start": "https://authorize.kobo.com/LinkDropbox/start",
        "ereaderdevices": "https://storeapi.kobo.com/v2/products/EReaderDeviceFeeds",
        "eula_page": "https://www.kobo.com/termsofuse?style=onestore",
        "exchange_auth": "https://storeapi.kobo.com/v1/auth/exchange",
        "external_book": "https://storeapi.kobo.com/v1/products/books/external/{Ids}",
        "facebook_sso_page": "https://authorize.kobo.com/signin/provider/Facebook/login?returnUrl=http://kobo.com/",
        "featured_list": "https://storeapi.kobo.com/v1/products/featured/{FeaturedListId}",
        "featured_lists": "https://storeapi.kobo.com/v1/products/featured",
        "free_books_page": {
            "EN": "https://www.kobo.com/{region}/{language}/p/free-ebooks",
            "FR": "https://www.kobo.com/{region}/{language}/p/livres-gratuits",
            "IT": "https://www.kobo.com/{region}/{language}/p/libri-gratuiti",
            "NL": "https://www.kobo.com/{region}/{language}/List/bekijk-het-overzicht-van-gratis-ebooks/QpkkVWnUw8sxmgjSlCbJRg",
            "PT": "https://www.kobo.com/{region}/{language}/p/livros-gratis",
        },
        "fte_feedback": "https://storeapi.kobo.com/v1/products/ftefeedback",
        "funnel_metrics": "https://storeapi.kobo.com/v1/funnelmetrics",
        "get_download_keys": "https://storeapi.kobo.com/v1/library/downloadkeys",
        "get_download_link": "https://storeapi.kobo.com/v1/library/downloadlink",
        "get_tests_request": "https://storeapi.kobo.com/v1/analytics/gettests",
        "giftcard_epd_redeem_url": "https://www.kobo.com/{storefront}/{language}/redeem-ereader",
        "giftcard_redeem_url": "https://www.kobo.com/{storefront}/{language}/redeem",
        "googledrive_link_account_start": "https://authorize.kobo.com/{region}/{language}/linkcloudstorage/provider/google_drive",
        "gpb_flow_enabled": "False",
        "help_page": "https://www.kobo.com/help",
        "image_host": "https://cdn.kobo.com/book-images/",
        "image_url_quality_template": "https://cdn.kobo.com/book-images/{ImageId}/{Width}/{Height}/{Quality}/{IsGreyscale}/image.jpg",
        "image_url_template": "https://cdn.kobo.com/book-images/{ImageId}/{Width}/{Height}/false/image.jpg",
        "instapaper_enabled": "False",
        "instapaper_env_url": "https://www.instapaper.com/api/kobo",
        "instapaper_link_account_start": "https://authorize.kobo.com/{region}/{language}/linkinstapaper",
        "kobo_audiobooks_credit_redemption": "True",
        "kobo_audiobooks_enabled": "True",
        "kobo_audiobooks_orange_deal_enabled": "True",
        "kobo_audiobooks_subscriptions_enabled": "True",
        "kobo_display_price": "True",
        "kobo_dropbox_link_account_enabled": "True",
        "kobo_google_tax": "False",
        "kobo_googledrive_link_account_enabled": "True",
        "kobo_nativeborrow_enabled": "False",
        "kobo_onedrive_link_account_enabled": "False",
        "kobo_onestorelibrary_enabled": "False",
        "kobo_privacyCentre_url": "https://www.kobo.com/privacy",
        "kobo_redeem_enabled": "True",
        "kobo_shelfie_enabled": "False",
        "kobo_subscriptions_enabled": "True",
        "kobo_superpoints_enabled": "True",
        "kobo_wishlist_enabled": "True",
        "library_book": "https://storeapi.kobo.com/v1/user/library/books/{LibraryItemId}",
        "library_items": "https://storeapi.kobo.com/v1/user/library",
        "library_metadata": "https://storeapi.kobo.com/v1/library/{Ids}/metadata",
        "library_prices": "https://storeapi.kobo.com/v1/user/library/previews/prices",
        "library_search": "https://storeapi.kobo.com/v1/library/search",
        "library_sync": "https://storeapi.kobo.com/v1/library/sync",
        "love_dashboard_page": "https://www.kobo.com/{region}/{language}/kobosuperpoints",
        "love_points_redemption_page": "https://www.kobo.com/{region}/{language}/KoboSuperPointsRedemption?productId={ProductId}",
        "magazine_landing_page": "https://www.kobo.com/emagazines",
        "more_sign_in_options": "https://authorize.kobo.com/signin?returnUrl=http://kobo.com/#allProviders",
        "notebooks": "https://storeapi.kobo.com/api/internal/notebooks",
        "notifications_registration_issue": "https://storeapi.kobo.com/v1/notifications/registration",
        "oauth_host": "https://oauth.kobo.com",
        "password_retrieval_page": "https://www.kobo.com/passwordretrieval.html",
        "personalizedrecommendations": "https://storeapi.kobo.com/v2/users/personalizedrecommendations",
        "pocket_link_account_start": "https://authorize.kobo.com/{region}/{language}/linkpocket",
        "post_analytics_event": "https://storeapi.kobo.com/v1/analytics/event",
        "ppx_purchasing_url": "https://purchasing.kobo.com",
        "privacy_page": "https://www.kobo.com/privacypolicy?style=onestore",
        "product_nextread": "https://storeapi.kobo.com/v1/products/{ProductIds}/nextread",
        "product_prices": "https://storeapi.kobo.com/v1/products/{ProductIds}/prices",
        "product_recommendations": "https://storeapi.kobo.com/v1/products/{ProductId}/recommendations",
        "product_reviews": "https://storeapi.kobo.com/v1/products/{ProductIds}/reviews",
        "products": "https://storeapi.kobo.com/v1/products",
        "productsv2": "https://storeapi.kobo.com/v2/products",
        "provider_external_sign_in_page": "https://authorize.kobo.com/ExternalSignIn/{providerName}?returnUrl=http://kobo.com/",
        "quickbuy_checkout": "https://storeapi.kobo.com/v1/store/quickbuy/{PurchaseId}/checkout",
        "quickbuy_create": "https://storeapi.kobo.com/v1/store/quickbuy/purchase",
        "rakuten_token_exchange": "https://storeapi.kobo.com/v1/auth/rakuten_token_exchange",
        "rating": "https://storeapi.kobo.com/v1/products/{ProductId}/rating/{Rating}",
        "reading_services_host": "https://readingservices.kobo.com",
        "reading_state": "https://storeapi.kobo.com/v1/library/{Ids}/state",
        "redeem_interstitial_page": "https://www.kobo.com",
        "registration_page": "https://authorize.kobo.com/signup?returnUrl=http://kobo.com/",
        "related_items": "https://storeapi.kobo.com/v1/products/{Id}/related",
        "remaining_book_series": "https://storeapi.kobo.com/v1/products/books/series/{SeriesId}",
        "rename_tag": "https://storeapi.kobo.com/v1/library/tags/{TagId}",
        "review": "https://storeapi.kobo.com/v1/products/reviews/{ReviewId}",
        "review_sentiment": "https://storeapi.kobo.com/v1/products/reviews/{ReviewId}/sentiment/{Sentiment}",
        "shelfie_recommendations": "https://storeapi.kobo.com/v1/user/recommendations/shelfie",
        "sign_in_page": "https://auth.kobobooks.com/ActivateOnWeb",
        "social_authorization_host": "https://social.kobobooks.com:8443",
        "social_host": "https://social.kobobooks.com",
        "store_home": "www.kobo.com/{region}/{language}",
        "store_host": "www.kobo.com",
        "store_newreleases": "https://www.kobo.com/{region}/{language}/List/new-releases/961XUjtsU0qxkFItWOutGA",
        "store_search": "https://www.kobo.com/{region}/{language}/Search?Query={query}",
        "store_top50": "https://www.kobo.com/{region}/{language}/ebooks/Top",
        "subs_landing_page": "https://www.kobo.com/{region}/{language}/plus",
        "subs_management_page": "https://www.kobo.com/{region}/{language}/account/subscriptions",
        "subs_plans_page": "https://www.kobo.com/{region}/{language}/plus/plans",
        "subs_purchase_buy_templated": "https://www.kobo.com/{region}/{language}/Checkoutoption/{ProductId}/{TierId}",
        "subscription_publisher_price_page": "https://www.kobo.com/{region}/{language}/subscriptionpublisherprice",
        "tag_items": "https://storeapi.kobo.com/v1/library/tags/{TagId}/Items",
        "tags": "https://storeapi.kobo.com/v1/library/tags",
        "taste_profile": "https://storeapi.kobo.com/v1/products/tasteprofile",
        "terms_of_sale_page": "https://authorize.kobo.com/{region}/{language}/terms/termsofsale",
        "update_accessibility_to_preview": "https://storeapi.kobo.com/v1/library/{EntitlementIds}/preview",
        "use_one_store": "True",
        "user_loyalty_benefits": "https://storeapi.kobo.com/v1/user/loyalty/benefits",
        "user_platform": "https://storeapi.kobo.com/v1/user/platform",
        "user_profile": "https://storeapi.kobo.com/v1/user/profile",
        "user_ratings": "https://storeapi.kobo.com/v1/user/ratings",
        "user_recommendations": "https://storeapi.kobo.com/v1/user/recommendations",
        "user_reviews": "https://storeapi.kobo.com/v1/user/reviews",
        "user_wishlist": "https://storeapi.kobo.com/v1/user/wishlist",
        "userguide_host": "https://ereaderfiles.kobo.com",
        "wishlist_page": "https://www.kobo.com/{region}/{language}/account/wishlist",
    }
