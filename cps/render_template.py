# -*- coding: utf-8 -*-

#  This file is part of the Calibre-Web (https://github.com/janeczku/calibre-web)
#    Copyright (C) 2018-2020 OzzieIsaacs
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

from typing import cast

from flask import abort, flash, g, render_template, request
from flask_babel import gettext as _
from sqlalchemy.sql.expression import and_, func, or_
from werkzeug.local import LocalProxy

from . import calibre_db, config, constants, db, logger, ub
from .cw_login import current_user
from .generated_shelves import list_generated_shelves
from .ub import User


def _get_user_kobo_collections_mode(user=None):
    """Get the Kobo collections sync mode for a user.

    Returns: 'all', 'selected', or 'hybrid'
    Priority: user setting > global config > default ('selected').
    Note: Duplicated here to avoid circular imports from shelf module.
    """
    mode = "selected"
    try:
        if user is not None:
            user_mode = getattr(user, "kobo_sync_collections_mode", None)
            if user_mode:
                mode = user_mode.strip().lower()
            else:
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


# CWA specific imports
import os
import sys
from datetime import datetime

import requests

INSTALL_BASE_DIR = os.environ.get("ACW_INSTALL_DIR", "/app/autocaliweb")
SCRIPTS_PATH = os.path.join(INSTALL_BASE_DIR, "scripts")
REPO_SCRIPTS_PATH = os.path.abspath(
    os.path.join(os.path.dirname(os.path.dirname(__file__)), "scripts")
)
for _p in (SCRIPTS_PATH, REPO_SCRIPTS_PATH):
    try:
        if _p and _p not in sys.path:
            sys.path.insert(1, _p)
    except Exception:
        pass

try:
    from acw_db import ACW_DB
except Exception:
    ACW_DB = None


log = logger.create()


def get_sidebar_config(kwargs=None):
    kwargs = kwargs or []
    simple = bool(
        [
            e
            for e in ["kindle", "tolino", "kobo", "bookeen"]
            if (e in request.headers.get("User-Agent", "").lower())
        ]
    )
    if "content" in kwargs:
        content = kwargs["content"]
        content = (
            isinstance(content, (User, LocalProxy)) and not content.role_anonymous()
        )
    else:
        content = "conf" in kwargs
    sidebar = list()
    sidebar.append(
        {
            "glyph": "glyphicon-book",
            "text": _("Books"),
            "link": "web.index",
            "id": "new",
            "visibility": constants.SIDEBAR_RECENT,
            "public": True,
            "page": "root",
            "show_text": _("Show recent books"),
            "config_show": False,
        }
    )
    sidebar.append(
        {
            "glyph": "glyphicon-fire",
            "text": _("Hot Books"),
            "link": "web.books_list",
            "id": "hot",
            "visibility": constants.SIDEBAR_HOT,
            "public": True,
            "page": "hot",
            "show_text": _("Show Hot Books"),
            "config_show": True,
        }
    )
    if current_user.role_admin():
        sidebar.append(
            {
                "glyph": "glyphicon-download",
                "text": _("Downloaded Books"),
                "link": "web.download_list",
                "id": "download",
                "visibility": constants.SIDEBAR_DOWNLOAD,
                "public": (not current_user.is_anonymous),
                "page": "download",
                "show_text": _("Show Downloaded Books"),
                "config_show": content,
            }
        )
    else:
        sidebar.append(
            {
                "glyph": "glyphicon-download",
                "text": _("Downloaded Books"),
                "link": "web.books_list",
                "id": "download",
                "visibility": constants.SIDEBAR_DOWNLOAD,
                "public": (not current_user.is_anonymous),
                "page": "download",
                "show_text": _("Show Downloaded Books"),
                "config_show": content,
            }
        )
    sidebar.append(
        {
            "glyph": "glyphicon-star",
            "text": _("Top Rated Books"),
            "link": "web.books_list",
            "id": "rated",
            "visibility": constants.SIDEBAR_BEST_RATED,
            "public": True,
            "page": "rated",
            "show_text": _("Show Top Rated Books"),
            "config_show": True,
        }
    )
    sidebar.append(
        {
            "glyph": "glyphicon-eye-open",
            "text": _("Read Books"),
            "link": "web.books_list",
            "id": "read",
            "visibility": constants.SIDEBAR_READ_AND_UNREAD,
            "public": (not current_user.is_anonymous),
            "page": "read",
            "show_text": _("Show Read and Unread"),
            "config_show": content,
        }
    )
    sidebar.append(
        {
            "glyph": "glyphicon-eye-close",
            "text": _("Unread Books"),
            "link": "web.books_list",
            "id": "unread",
            "visibility": constants.SIDEBAR_READ_AND_UNREAD,
            "public": (not current_user.is_anonymous),
            "page": "unread",
            "show_text": _("Show unread"),
            "config_show": False,
        }
    )
    sidebar.append(
        {
            "glyph": "glyphicon-random",
            "text": _("Discover"),
            "link": "web.books_list",
            "id": "rand",
            "visibility": constants.SIDEBAR_RANDOM,
            "public": True,
            "page": "discover",
            "show_text": _("Show Random Books"),
            "config_show": True,
        }
    )
    sidebar.append(
        {
            "glyph": "glyphicon-inbox",
            "text": _("Categories"),
            "link": "web.category_list",
            "id": "cat",
            "visibility": constants.SIDEBAR_CATEGORY,
            "public": True,
            "page": "category",
            "show_text": _("Show Category Section"),
            "config_show": True,
        }
    )
    sidebar.append(
        {
            "glyph": "glyphicon-bookmark",
            "text": _("Series"),
            "link": "web.series_list",
            "id": "serie",
            "visibility": constants.SIDEBAR_SERIES,
            "public": True,
            "page": "series",
            "show_text": _("Show Series Section"),
            "config_show": True,
        }
    )
    sidebar.append(
        {
            "glyph": "glyphicon-user",
            "text": _("Authors"),
            "link": "web.author_list",
            "id": "author",
            "visibility": constants.SIDEBAR_AUTHOR,
            "public": True,
            "page": "author",
            "show_text": _("Show Author Section"),
            "config_show": True,
        }
    )
    sidebar.append(
        {
            "glyph": "glyphicon-text-size",
            "text": _("Publishers"),
            "link": "web.publisher_list",
            "id": "publisher",
            "visibility": constants.SIDEBAR_PUBLISHER,
            "public": True,
            "page": "publisher",
            "show_text": _("Show Publisher Section"),
            "config_show": True,
        }
    )
    sidebar.append(
        {
            "glyph": "glyphicon-flag",
            "text": _("Languages"),
            "link": "web.language_overview",
            "id": "lang",
            "visibility": constants.SIDEBAR_LANGUAGE,
            "public": (current_user.filter_language() == "all"),
            "page": "language",
            "show_text": _("Show Language Section"),
            "config_show": True,
        }
    )
    sidebar.append(
        {
            "glyph": "glyphicon-star-empty",
            "text": _("Ratings"),
            "link": "web.ratings_list",
            "id": "rate",
            "visibility": constants.SIDEBAR_RATING,
            "public": True,
            "page": "rating",
            "show_text": _("Show Ratings Section"),
            "config_show": True,
        }
    )
    sidebar.append(
        {
            "glyph": "glyphicon-file",
            "text": _("File formats"),
            "link": "web.formats_list",
            "id": "format",
            "visibility": constants.SIDEBAR_FORMAT,
            "public": True,
            "page": "format",
            "show_text": _("Show File Formats Section"),
            "config_show": True,
        }
    )
    sidebar.append(
        {
            "glyph": "glyphicon-folder-open",
            "text": _("Archived Books"),
            "link": "web.books_list",
            "id": "archived",
            "visibility": constants.SIDEBAR_ARCHIVED,
            "public": (not current_user.is_anonymous),
            "page": "archived",
            "show_text": _("Show Archived Books"),
            "config_show": content,
        }
    )
    if not simple:
        sidebar.append(
            {
                "glyph": "glyphicon-th-list",
                "text": _("Books List"),
                "link": "web.books_table",
                "id": "list",
                "visibility": constants.SIDEBAR_LIST,
                "public": (not current_user.is_anonymous),
                "page": "list",
                "show_text": _("Show Books List"),
                "config_show": content,
            }
        )
    if current_user.role_admin():
        sidebar.append(
            {
                "glyph": "glyphicon-copy",
                "text": _("Duplicates"),
                "link": "duplicates.show_duplicates",
                "id": "duplicates",
                "visibility": constants.SIDEBAR_DUPLICATES,
                "public": (not current_user.is_anonymous),
                "page": "duplicates",
                "show_text": _("Show Duplicate Books"),
                "config_show": content,
            }
        )

    # In Kobo hybrid mode we use a local-only opt-in shelf. Ensure it exists so it can be managed from the UI.
    try:
        kobo_collections_mode = _get_user_kobo_collections_mode(current_user)
        if (not current_user.is_anonymous) and kobo_collections_mode == "hybrid":
            shelf_name = "Kobo Sync"
            shelf = (
                ub.session.query(ub.Shelf)
                .filter(
                    ub.Shelf.user_id == current_user.id, ub.Shelf.name == shelf_name
                )
                .first()
            )
            if not shelf:
                shelf = ub.Shelf()
                shelf.name = shelf_name
                shelf.is_public = 0
                shelf.user_id = current_user.id
                shelf.kobo_sync = False
                ub.session.add(shelf)
                ub.session_commit()
    except Exception:
        pass

    manual_shelves_query = ub.session.query(ub.Shelf).filter(
        or_(ub.Shelf.is_public == 1, ub.Shelf.user_id == current_user.id)
    )
    # Hide the local-only Kobo opt-in shelf unless it is used (Hybrid mode).
    try:
        kobo_collections_mode = _get_user_kobo_collections_mode(current_user)
        if (not current_user.is_anonymous) and kobo_collections_mode != "hybrid":
            manual_shelves_query = manual_shelves_query.filter(
                or_(ub.Shelf.user_id != current_user.id, ub.Shelf.name != "Kobo Sync")
            )
    except Exception:
        pass
    except Exception:
        pass
    manual_shelves = manual_shelves_query.order_by(ub.Shelf.name).all()
    generated_shelves = list_generated_shelves()
    g.shelves_access = sorted(
        list(manual_shelves) + list(generated_shelves),
        key=lambda s: (getattr(s, "name", "") or "").lower(),
    )

    # Sidebar: optional per-shelf count indicator (0=off, 1=books, 2=unread).
    g.shelf_count_indicator_mode = config.config_shelf_count_indicator
    shelf_book_counts: dict[object, int] = {}
    # Only manual shelves have per-shelf counts and are eligible for BookShelf operations.
    shelf_ids = [s.id for s in manual_shelves if getattr(s, "id", None)]
    if shelf_ids and g.shelf_count_indicator_mode:
        if g.shelf_count_indicator_mode == 1:
            # Mode 1: "Books on shelf" indicator.
            # Exclude archived books so the badge matches shelf visibility and Kobo availability.
            shelf_book_counts = cast(
                dict[object, int],
                dict(
                    ub.session.query(ub.BookShelf.shelf, ub.func.count(ub.BookShelf.id))
                    .outerjoin(
                        ub.ArchivedBook,
                        and_(
                            ub.ArchivedBook.user_id == int(current_user.id),
                            ub.ArchivedBook.book_id == ub.BookShelf.book_id,
                            ub.ArchivedBook.is_archived == True,
                        ),
                    )
                    .filter(ub.BookShelf.shelf.in_(shelf_ids))
                    .filter(ub.ArchivedBook.book_id.is_(None))
                    .group_by(ub.BookShelf.shelf)
                    .all()
                ),
            )
        elif g.shelf_count_indicator_mode == 2 and not current_user.is_anonymous:
            if not config.config_read_column:
                shelf_book_counts = cast(
                    dict[object, int],
                    dict(
                        ub.session.query(
                            ub.BookShelf.shelf, ub.func.count(ub.BookShelf.id)
                        )
                        .outerjoin(
                            ub.ReadBook,
                            and_(
                                ub.ReadBook.user_id == int(current_user.id),
                                ub.ReadBook.book_id == ub.BookShelf.book_id,
                            ),
                        )
                        .outerjoin(
                            ub.ArchivedBook,
                            and_(
                                ub.ArchivedBook.user_id == int(current_user.id),
                                ub.ArchivedBook.book_id == ub.BookShelf.book_id,
                                ub.ArchivedBook.is_archived == True,
                            ),
                        )
                        .filter(ub.BookShelf.shelf.in_(shelf_ids))
                        .filter(ub.ArchivedBook.book_id.is_(None))
                        .filter(
                            ub.func.coalesce(ub.ReadBook.read_status, 0)
                            != ub.ReadBook.STATUS_FINISHED
                        )
                        .group_by(ub.BookShelf.shelf)
                        .all()
                    ),
                )
            else:
                try:
                    read_column = db.cc_classes[config.config_read_column]
                except (KeyError, AttributeError, IndexError):
                    log.error(
                        "Custom Column No.%s does not exist in calibre database",
                        config.config_read_column,
                    )
                    read_column = None

                if read_column is not None:
                    shelf_links = (
                        ub.session.query(ub.BookShelf.shelf, ub.BookShelf.book_id)
                        .filter(ub.BookShelf.shelf.in_(shelf_ids))
                        .all()
                    )
                    shelf_to_books = {}
                    all_book_ids = set()
                    for shelf_id, book_id in shelf_links:
                        shelf_to_books.setdefault(shelf_id, set()).add(book_id)
                        all_book_ids.add(book_id)

                    if all_book_ids:
                        read_true_ids = {
                            row[0]
                            for row in calibre_db.session.query(read_column.book)
                            .filter(
                                read_column.book.in_(all_book_ids),
                                read_column.value == True,
                            )
                            .all()
                        }
                        unread_ids = all_book_ids - read_true_ids
                        shelf_book_counts = {
                            shelf_id: sum(
                                1 for book_id in books if book_id in unread_ids
                            )
                            for shelf_id, books in shelf_to_books.items()
                        }

    # Generated shelf counts (Books on Shelf) are computed from the Calibre DB.
    # We only do this for mode==1 to avoid expensive per-shelf unread computations.
    if generated_shelves and g.shelf_count_indicator_mode == 1:
        selector = (
            getattr(config, "config_generate_shelves_from_calibre_column", "") or ""
        ).strip()
        try:
            if selector == "tags":
                rows = (
                    calibre_db.session.query(
                        db.Tags.name,
                        func.count(db.Books.id.distinct()),
                    )
                    .join(db.books_tags_link)
                    .join(db.Books)
                    .filter(calibre_db.common_filters())
                    .group_by(db.Tags.name)
                    .order_by(db.Tags.name)
                    .limit(len(generated_shelves))
                    .all()
                )
                shelf_book_counts.update(
                    {
                        f"generated:tags:{name}": int(count or 0)
                        for name, count in rows
                        if name
                    }
                )
            elif selector == "authors":
                rows = (
                    calibre_db.session.query(
                        db.Authors.name,
                        func.count(db.Books.id.distinct()),
                    )
                    .join(db.books_authors_link)
                    .join(db.Books)
                    .filter(calibre_db.common_filters())
                    .group_by(db.Authors.name)
                    .order_by(db.Authors.name)
                    .limit(len(generated_shelves))
                    .all()
                )
                shelf_book_counts.update(
                    {
                        f"generated:authors:{name}": int(count or 0)
                        for name, count in rows
                        if name
                    }
                )
            elif selector == "publishers":
                rows = (
                    calibre_db.session.query(
                        db.Publishers.name,
                        func.count(db.Books.id.distinct()),
                    )
                    .join(db.books_publishers_link)
                    .join(db.Books)
                    .filter(calibre_db.common_filters())
                    .group_by(db.Publishers.name)
                    .order_by(db.Publishers.name)
                    .limit(len(generated_shelves))
                    .all()
                )
                shelf_book_counts.update(
                    {
                        f"generated:publishers:{name}": int(count or 0)
                        for name, count in rows
                        if name
                    }
                )
            elif selector == "languages":
                rows = (
                    calibre_db.session.query(
                        db.Languages.lang_code,
                        func.count(db.Books.id.distinct()),
                    )
                    .join(db.books_languages_link)
                    .join(db.Books)
                    .filter(calibre_db.common_filters())
                    .group_by(db.Languages.lang_code)
                    .order_by(db.Languages.lang_code)
                    .limit(len(generated_shelves))
                    .all()
                )
                shelf_book_counts.update(
                    {
                        f"generated:languages:{code}": int(count or 0)
                        for code, count in rows
                        if code
                    }
                )
            elif selector.startswith("cc:"):
                try:
                    cc_id = int(selector.split(":", 1)[1])
                except (TypeError, ValueError):
                    cc_id = None
                if cc_id:
                    cc_class = db.cc_classes.get(cc_id)
                    rel = getattr(db.Books, f"custom_column_{cc_id}", None)
                    if cc_class is not None and rel is not None:
                        rows = (
                            calibre_db.session.query(
                                cc_class.value,
                                func.count(db.Books.id.distinct()),
                            )
                            .select_from(db.Books)
                            .join(rel)
                            .filter(calibre_db.common_filters())
                            .group_by(cc_class.value)
                            .order_by(cc_class.value)
                            .limit(len(generated_shelves))
                            .all()
                        )
                        shelf_book_counts.update(
                            {
                                f"generated:cc:{cc_id}:{val}": int(count or 0)
                                for val, count in rows
                                if val
                            }
                        )
        except Exception:
            # If anything goes wrong, keep generated shelf counts empty.
            pass

    g.shelf_book_counts = shelf_book_counts
    return sidebar, simple


# Checks if an update for CWA is available, returning True if yes
def acw_update_available() -> tuple[bool, str, str]:
    try:
        with open(
            os.path.join(os.environ.get("ACW_INSTALL_DIR", "/app"), "ACW_RELEASE"), "r"
        ) as f:
            current_version = f.read().strip()
        response = requests.get(
            "https://api.github.com/repos/gelbphoenix/autocaliweb/releases/latest"
        )
        tag_name = response.json().get("tag_name", current_version)
        return (tag_name != current_version), current_version, tag_name
    except Exception as e:
        print(
            f"[acw-update-notification-service] Error checking for updates: {e}",
            flush=True,
        )
        return False, "Unknown", "Unknown"


# Gets the date the last cwa update notification was displayed
def get_acw_last_notification() -> str:
    current_date = datetime.now().strftime("%Y-%m-%d")
    if not os.path.isfile(
        os.path.join(os.environ.get("ACW_INSTALL_DIR", "/app"), "acw_update_notice")
    ):
        with open(
            os.path.join(
                os.environ.get("ACW_INSTALL_DIR", "/app"), "acw_update_notice"
            ),
            "w",
        ) as f:
            f.write(current_date)
        return "0001-01-01"
    else:
        with open(
            os.path.join(
                os.environ.get("ACW_INSTALL_DIR", "/app"), "acw_update_notice"
            ),
            "r",
        ) as f:
            last_notification = f.read()
    return last_notification


# Displays a notification to the user that an update for CWA is available, no matter which page they're on
# Currently set to only display once per calender day
def acw_update_notification() -> None:
    if ACW_DB is None:
        return
    db = ACW_DB()
    if db.acw_settings["acw_update_notifications"]:
        current_date = datetime.now().strftime("%Y-%m-%d")
        acw_last_notification = get_acw_last_notification()

        if acw_last_notification == current_date:
            return

        update_available, current_version, tag_name = acw_update_available()
        if update_available:
            message = f"⚡🚨 ACW UPDATE AVAILABLE! 🚨⚡ Current - {current_version} | Newest - {tag_name} | To update, just re-pull the image! This message will only display once per day |"
            flash(_(message), category="acw_update")
            print(f"[acw-update-notification-service] {message}", flush=True)

        with open(
            os.path.join(
                os.environ.get("ACW_INSTALL_DIR", "/app"), "acw_update_notice"
            ),
            "w",
        ) as f:
            f.write(current_date)
        return
    else:
        return


# Returns the template for rendering and includes the instance name
def render_title_template(*args, **kwargs):
    sidebar, simple = get_sidebar_config(kwargs)
    if current_user.role_admin():
        try:
            acw_update_notification()
        except Exception as e:
            print(
                f"[acw-update-notification-service] The following error occurred when checking for available updates:\n{e}",
                flush=True,
            )
    try:
        return render_template(
            instance=config.config_calibre_web_title,
            sidebar=sidebar,
            simple=simple,
            accept=config.config_upload_formats.split(","),
            *args,
            **kwargs,
        )
    except PermissionError:
        log.error("No permission to access {} file.".format(args[0]))
        abort(403)
