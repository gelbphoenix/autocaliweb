# -*- coding: utf-8 -*-

#  This file is part of the Calibre-Web (https://github.com/janeczku/calibre-web)
#    Copyright (C) 2018-2019 OzzieIsaacs, cervinko, jkrehm, bodybybuddha, ok11,
#                            andy29485, idalin, Kyosfonica, wuqi, Kennyl, lemmsh,
#                            falgh1, grunjol, csitko, ytils, xybydy, trasba, vrabe,
#                            ruben-herold, marblepebble, JackED42, SiphonSquirrel,
#                            apetresc, nanu-c, mutschler
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

import sys
from datetime import datetime, timezone

from flask import Blueprint, abort, flash, jsonify, redirect, request, url_for
from flask_babel import gettext as _
from sqlalchemy import and_, or_
from sqlalchemy.exc import InvalidRequestError, OperationalError
from sqlalchemy.sql.expression import func, true

from . import calibre_db, config, db, logger, ub
from .cw_login import current_user
from .generated_shelves import (
    GeneratedShelf,
    generated_shelf_filter,
    list_generated_shelves,
)
from .render_template import render_title_template
from .services import hardcover
from .usermanagement import login_required_if_no_ano, user_login_required

log = logger.create()

shelf = Blueprint("shelf", __name__)

KOBO_OPT_IN_SHELF_NAME = "Kobo Sync"


def _mark_force_resync_generated(user_id: int) -> None:
    """Ensure the next Kobo sync re-emits generated collections.

    Generated shelves are computed from metadata and can be timestamp-gated during sync.
    When a user changes generated-shelf sync preferences, we need to force a one-time
    resync so newly-enabled collections get created (and newly-disabled ones removed).
    """
    try:
        state = (
            ub.session.query(ub.KoboTagSyncState)
            .filter(ub.KoboTagSyncState.user_id == user_id)
            .one_or_none()
        )
        if not state:
            state = ub.KoboTagSyncState(user_id=user_id)
            ub.session.add(state)
        state.force_resync_generated = True
        try:
            log.debug("Marked force_resync_generated for user_id=%s", user_id)
        except Exception:
            pass
    except Exception:
        # Best-effort only; sync will still proceed.
        return


def get_user_kobo_collections_mode(user=None):
    """Get the Kobo collections sync mode for a user.

    Returns: 'all', 'selected', or 'hybrid'
    Priority: user setting > global config > default ('selected').
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


def ensure_kobo_opt_in_shelf(user_id: int):
    """Ensure the 'Kobo Sync' opt-in shelf exists for hybrid mode.

    This shelf is used as a gate in hybrid mode - only books added to it will sync.
    The shelf itself does NOT sync to the device as a collection.
    """
    shelf = (
        ub.session.query(ub.Shelf)
        .filter(ub.Shelf.user_id == user_id, ub.Shelf.name == KOBO_OPT_IN_SHELF_NAME)
        .first()
    )
    if shelf:
        # Ensure it has correct properties
        changed = False
        if getattr(shelf, "kobo_sync", None) is not False:
            shelf.kobo_sync = False
            changed = True
        if getattr(shelf, "is_public", None):
            shelf.is_public = 0
            changed = True
        if changed:
            try:
                ub.session_commit()
            except Exception:
                pass
        return shelf
    # Create new shelf
    shelf = ub.Shelf()
    shelf.name = KOBO_OPT_IN_SHELF_NAME
    shelf.is_public = 0
    shelf.user_id = user_id
    shelf.kobo_sync = False
    ub.session.add(shelf)
    try:
        ub.session_commit()
    except Exception:
        ub.session.rollback()
    return shelf


MAX_BULK_SHELF_SELECTION = 1000


def _parse_selection_ids_from_request():
    payload = request.get_json(silent=True) or {}
    selections = payload.get("selections") or payload.get("book_ids") or []
    if selections is None:
        selections = []
    if not isinstance(selections, (list, tuple)):
        return []
    result = []
    for value in selections:
        try:
            result.append(int(value))
        except (TypeError, ValueError):
            continue
    # De-dupe while keeping order
    seen = set()
    deduped = []
    for book_id in result:
        if book_id not in seen:
            seen.add(book_id)
            deduped.append(book_id)
    return deduped


@shelf.route("/shelf/sidebar_counts", methods=["GET"])
@user_login_required
def sidebar_counts():
    mode = config.config_shelf_count_indicator
    shelves = (
        ub.session.query(ub.Shelf.id)
        .filter(or_(ub.Shelf.is_public == 1, ub.Shelf.user_id == current_user.id))
        .all()
    )
    shelf_ids = [row[0] for row in shelves if row and row[0]]

    if not mode:
        return jsonify({"success": True, "mode": mode, "counts": {}}), 200

    if mode == 1:
        counts = {}
        if shelf_ids:
            counts.update(
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
                    .filter(ub.ArchivedBook.book_id == None)
                    .group_by(ub.BookShelf.shelf)
                    .all()
                )
            )

        # Generated shelves (Books on Shelf): group counts from Calibre DB.
        selector = (
            getattr(config, "config_generate_shelves_from_calibre_column", "") or ""
        ).strip()
        try:
            from sqlalchemy.sql.expression import func as sa_func

            if selector == "tags":
                rows = (
                    calibre_db.session.query(
                        db.Tags.name, sa_func.count(db.Books.id.distinct())
                    )
                    .select_from(db.Tags)
                    .join(db.Tags.books)
                    .filter(calibre_db.common_filters())
                    .group_by(db.Tags.name)
                    .all()
                )
                counts.update(
                    {f"generated:tags:{name}": int(c or 0) for name, c in rows if name}
                )
            elif selector == "authors":
                rows = (
                    calibre_db.session.query(
                        db.Authors.name, sa_func.count(db.Books.id.distinct())
                    )
                    .select_from(db.Authors)
                    .join(db.Authors.books)
                    .filter(calibre_db.common_filters())
                    .group_by(db.Authors.name)
                    .all()
                )
                counts.update(
                    {
                        f"generated:authors:{name}": int(c or 0)
                        for name, c in rows
                        if name
                    }
                )
            elif selector == "publishers":
                rows = (
                    calibre_db.session.query(
                        db.Publishers.name, sa_func.count(db.Books.id.distinct())
                    )
                    .select_from(db.Publishers)
                    .join(db.Publishers.books)
                    .filter(calibre_db.common_filters())
                    .group_by(db.Publishers.name)
                    .all()
                )
                counts.update(
                    {
                        f"generated:publishers:{name}": int(c or 0)
                        for name, c in rows
                        if name
                    }
                )
            elif selector == "languages":
                rows = (
                    calibre_db.session.query(
                        db.Languages.lang_code, sa_func.count(db.Books.id.distinct())
                    )
                    .select_from(db.Languages)
                    .join(db.Languages.books)
                    .filter(calibre_db.common_filters())
                    .group_by(db.Languages.lang_code)
                    .all()
                )
                counts.update(
                    {
                        f"generated:languages:{code}": int(c or 0)
                        for code, c in rows
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
                                cc_class.value, sa_func.count(db.Books.id.distinct())
                            )
                            .select_from(db.Books)
                            .join(rel)
                            .filter(calibre_db.common_filters())
                            .group_by(cc_class.value)
                            .all()
                        )
                        counts.update(
                            {
                                f"generated:cc:{cc_id}:{val}": int(c or 0)
                                for val, c in rows
                                if val
                            }
                        )
        except Exception:
            log.exception(
                "Failed to compute generated shelf sidebar counts (selector=%r)",
                selector,
            )
        counts = {str(k): int(v or 0) for k, v in counts.items()}
        return jsonify({"success": True, "mode": mode, "counts": counts}), 200

    if mode == 2:
        if current_user.is_anonymous:
            return jsonify({"success": True, "mode": mode, "counts": {}}), 200

        if not config.config_read_column:
            counts = dict(
                ub.session.query(ub.BookShelf.shelf, ub.func.count(ub.BookShelf.id))
                .outerjoin(
                    ub.ReadBook,
                    and_(
                        ub.ReadBook.user_id == int(current_user.id),
                        ub.ReadBook.book_id == ub.BookShelf.book_id,
                    ),
                )
                .filter(ub.BookShelf.shelf.in_(shelf_ids))
                .filter(
                    ub.func.coalesce(ub.ReadBook.read_status, 0)
                    != ub.ReadBook.STATUS_FINISHED
                )
                .group_by(ub.BookShelf.shelf)
                .all()
            )
            counts = {str(k): int(v or 0) for k, v in counts.items()}
            return jsonify({"success": True, "mode": mode, "counts": counts}), 200

        try:
            read_column = db.cc_classes[config.config_read_column]
        except (KeyError, AttributeError, IndexError):
            log.error(
                "Custom Column No.%s does not exist in calibre database",
                config.config_read_column,
            )
            read_column = None

        if read_column is None:
            return jsonify({"success": True, "mode": mode, "counts": {}}), 200

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

        if not all_book_ids:
            return jsonify({"success": True, "mode": mode, "counts": {}}), 200

        read_true_ids = {
            row[0]
            for row in calibre_db.session.query(read_column.book)
            .filter(read_column.book.in_(all_book_ids), read_column.value == True)
            .all()
        }
        unread_ids = all_book_ids - read_true_ids
        counts = {
            shelf_id: sum(1 for book_id in books if book_id in unread_ids)
            for shelf_id, books in shelf_to_books.items()
        }
        counts = {str(k): int(v or 0) for k, v in counts.items()}
        return jsonify({"success": True, "mode": mode, "counts": counts}), 200

    return jsonify({"success": True, "mode": mode, "counts": {}}), 200


@shelf.route("/shelf/bulkadd/<int:shelf_id>", methods=["POST"])
@user_login_required
def bulk_add_to_shelf(shelf_id):
    selections = _parse_selection_ids_from_request()
    shelf_obj = ub.session.query(ub.Shelf).filter(ub.Shelf.id == shelf_id).first()
    if shelf_obj is None:
        return jsonify({"success": False, "msg": _("Invalid shelf specified")}), 400
    if not check_shelf_edit_permissions(shelf_obj):
        return jsonify(
            {
                "success": False,
                "msg": _("Sorry you are not allowed to add a book to that shelf"),
            }
        ), 403
    if not selections:
        return jsonify({"success": False, "msg": _("No books selected")}), 400

    if len(selections) > MAX_BULK_SHELF_SELECTION:
        return jsonify(
            {
                "success": False,
                "msg": _(
                    "Too many books selected (max %(max)d)",
                    max=MAX_BULK_SHELF_SELECTION,
                ),
            }
        ), 400

    # Validate book ids exist in calibre db.
    existing_book_ids = {
        row[0]
        for row in calibre_db.session.query(db.Books.id)
        .filter(db.Books.id.in_(selections))
        .all()
    }
    invalid_ids = [
        book_id for book_id in selections if book_id not in existing_book_ids
    ]
    valid_ids = [book_id for book_id in selections if book_id in existing_book_ids]

    if not valid_ids:
        return jsonify(
            {
                "success": False,
                "msg": _("No valid books selected"),
                "invalid": invalid_ids,
            }
        ), 400

    already_in_shelf = {
        row[0]
        for row in ub.session.query(ub.BookShelf.book_id)
        .filter(ub.BookShelf.shelf == shelf_id)
        .filter(ub.BookShelf.book_id.in_(valid_ids))
        .all()
    }
    to_add = [book_id for book_id in valid_ids if book_id not in already_in_shelf]

    if not to_add:
        return jsonify(
            {
                "success": True,
                "added": 0,
                "already_in_shelf": len(valid_ids),
                "invalid": invalid_ids,
                "msg": _(
                    "Books are already part of the shelf: %(name)s", name=shelf_obj.name
                ),
            }
        ), 200

    try:
        max_order = (
            ub.session.query(func.max(ub.BookShelf.order))
            .filter(ub.BookShelf.shelf == shelf_id)
            .first()[0]
            or 0
        )
        for book_id in to_add:
            max_order += 1
            shelf_obj.books.append(
                ub.BookShelf(shelf=shelf_id, book_id=book_id, order=max_order)
            )
        shelf_obj.last_modified = datetime.now(timezone.utc)
        ub.session.commit()
    except (OperationalError, InvalidRequestError) as e:
        ub.session.rollback()
        log.error_or_exception("Settings Database error: {}".format(e))
        error = getattr(e, "orig", e)
        return jsonify(
            {
                "success": False,
                "msg": _("Oops! Database Error: %(error)s.", error=error),
            }
        ), 500

    return jsonify(
        {
            "success": True,
            "added": len(to_add),
            "already_in_shelf": len(already_in_shelf),
            "invalid": invalid_ids,
            "msg": _("Books have been added to shelf: %(sname)s", sname=shelf_obj.name),
        }
    ), 200


@shelf.route("/shelf/bulkremove/<int:shelf_id>", methods=["POST"])
@user_login_required
def bulk_remove_from_shelf(shelf_id):
    selections = _parse_selection_ids_from_request()
    shelf_obj = ub.session.query(ub.Shelf).filter(ub.Shelf.id == shelf_id).first()
    if shelf_obj is None:
        return jsonify({"success": False, "msg": _("Invalid shelf specified")}), 400
    if not check_shelf_edit_permissions(shelf_obj):
        return jsonify(
            {
                "success": False,
                "msg": _("Sorry you are not allowed to remove a book from this shelf"),
            }
        ), 403
    if not selections:
        return jsonify({"success": False, "msg": _("No books selected")}), 400

    if len(selections) > MAX_BULK_SHELF_SELECTION:
        return jsonify(
            {
                "success": False,
                "msg": _(
                    "Too many books selected (max %(max)d)",
                    max=MAX_BULK_SHELF_SELECTION,
                ),
            }
        ), 400

    existing_links = ub.session.query(ub.BookShelf.book_id)
    existing_links = existing_links.filter(ub.BookShelf.shelf == shelf_id)
    existing_links = existing_links.filter(ub.BookShelf.book_id.in_(selections)).all()
    existing_in_shelf = {row[0] for row in existing_links}
    not_in_shelf = [
        book_id for book_id in selections if book_id not in existing_in_shelf
    ]

    if not existing_in_shelf:
        return jsonify(
            {
                "success": True,
                "removed": 0,
                "not_in_shelf": len(not_in_shelf),
                "msg": _("No selected books were part of this shelf"),
            }
        ), 200

    try:
        removed_count = ub.session.query(ub.BookShelf)
        removed_count = removed_count.filter(ub.BookShelf.shelf == shelf_id)
        removed_count = removed_count.filter(
            ub.BookShelf.book_id.in_(list(existing_in_shelf))
        )
        removed_count = removed_count.delete(synchronize_session=False)
        shelf_obj.last_modified = datetime.now(timezone.utc)
        ub.session.commit()
    except (OperationalError, InvalidRequestError) as e:
        ub.session.rollback()
        log.error_or_exception("Settings Database error: {}".format(e))
        error = getattr(e, "orig", e)
        return jsonify(
            {
                "success": False,
                "msg": _("Oops! Database Error: %(error)s.", error=error),
            }
        ), 500

    return jsonify(
        {
            "success": True,
            "removed": int(removed_count or 0),
            "not_in_shelf": len(not_in_shelf),
            "msg": _(
                "Books have been removed from shelf: %(sname)s", sname=shelf_obj.name
            ),
        }
    ), 200


# ============================================================================
# Shelves Table / List View
# ============================================================================


@shelf.route("/shelf/table")
@user_login_required
def shelves_table():
    """Render the shelves list/table page."""
    return render_title_template(
        "shelf_table.html",
        title=_("Shelves List"),
        page="shelf_table",
        kobo_sync_enabled=config.config_kobo_sync,
    )


@shelf.route("/ajax/listshelves")
@user_login_required
def list_shelves():
    """AJAX endpoint for shelves table data (includes both regular and generated shelves)."""
    try:
        search_param = request.args.get("search", "").strip().lower()
        sort_param = request.args.get("sort", "name")
        order = request.args.get("order", "asc").lower()

        rows = []

        # -------------------------------------------------------------------------
        # 1. Regular shelves from ub.Shelf
        # -------------------------------------------------------------------------
        regular_shelves = (
            ub.session.query(ub.Shelf)
            .filter(or_(ub.Shelf.is_public == 1, ub.Shelf.user_id == current_user.id))
            .all()
        )
        log.debug("list_shelves: found %d regular shelves", len(regular_shelves))

        # Get book counts for regular shelves
        shelf_ids = [s.id for s in regular_shelves]
        book_counts = {}
        if shelf_ids:
            counts = (
                ub.session.query(ub.BookShelf.shelf, func.count(ub.BookShelf.id))
                .outerjoin(
                    ub.ArchivedBook,
                    and_(
                        ub.ArchivedBook.user_id == int(current_user.id),
                        ub.ArchivedBook.book_id == ub.BookShelf.book_id,
                        ub.ArchivedBook.is_archived == True,
                    ),
                )
                .filter(ub.BookShelf.shelf.in_(shelf_ids))
                .filter(ub.ArchivedBook.book_id == None)
                .group_by(ub.BookShelf.shelf)
                .all()
            )
            book_counts = {shelf_id: count for shelf_id, count in counts}

        # Get owner names for public shelves
        owner_ids = {s.user_id for s in regular_shelves if s.is_public}
        owner_names = {}
        if owner_ids:
            owners = (
                ub.session.query(ub.User.id, ub.User.name)
                .filter(ub.User.id.in_(owner_ids))
                .all()
            )
            owner_names = {uid: name for uid, name in owners}

        for s in regular_shelves:
            is_own = s.user_id == current_user.id
            name = s.name or ""
            if search_param and search_param not in name.lower():
                continue
            rows.append(
                {
                    "id": s.id,
                    "shelf_type": "regular",
                    "name": name,
                    "is_public": s.is_public == 1,
                    "is_generated": False,
                    "is_own": is_own,
                    "owner": owner_names.get(s.user_id, "") if s.is_public else "",
                    "kobo_sync": getattr(s, "kobo_sync", False) or False,
                    "book_count": book_counts.get(s.id, 0),
                    "created": s.created.isoformat() if s.created else "",
                    "last_modified": s.last_modified.isoformat()
                    if s.last_modified
                    else "",
                    "can_edit": is_own
                    or (s.is_public and current_user.role_edit_shelfs()),
                    "source": "",
                    "value": "",
                }
            )

        # -------------------------------------------------------------------------
        # 2. Generated shelves (from Calibre metadata column)
        # -------------------------------------------------------------------------
        generated_shelves = list_generated_shelves(max_items=1000)
        log.debug("list_shelves: found %d generated shelves", len(generated_shelves))

        # Get kobo_sync status for generated shelves from GeneratedShelfKoboSync
        gen_sync_status = {}
        if generated_shelves:
            try:
                sync_rows = (
                    ub.session.query(
                        ub.GeneratedShelfKoboSync.source,
                        ub.GeneratedShelfKoboSync.value,
                        ub.GeneratedShelfKoboSync.kobo_sync,
                    )
                    .filter(ub.GeneratedShelfKoboSync.user_id == current_user.id)
                    .all()
                )
                for src, val, sync in sync_rows:
                    gen_sync_status[(src, val)] = bool(sync)
            except Exception as e:
                log.warning("Error fetching generated shelf sync status: %s", e)

        # Get book counts for generated shelves
        gen_book_counts = {}
        selector = (
            getattr(config, "config_generate_shelves_from_calibre_column", "") or ""
        )
        if generated_shelves and selector:
            try:
                for gs in generated_shelves:
                    shelf_filter = generated_shelf_filter(gs.source, gs.value)
                    if shelf_filter is not None:
                        count = (
                            calibre_db.session.query(db.Books)
                            .filter(calibre_db.common_filters(), shelf_filter)
                            .count()
                        )
                        gen_book_counts[(gs.source, gs.value)] = count
            except Exception as e:
                log.warning("Error counting generated shelf books: %s", e)

        for gs in generated_shelves:
            name = gs.name or ""
            if search_param and search_param not in name.lower():
                continue
            rows.append(
                {
                    "id": gs.id,  # "generated:source:value"
                    "shelf_type": "generated",
                    "name": name,
                    "is_public": False,
                    "is_generated": True,
                    "is_own": True,  # Generated shelves are per-user in terms of sync settings
                    "owner": "",
                    "kobo_sync": gen_sync_status.get((gs.source, gs.value), False),
                    "book_count": gen_book_counts.get((gs.source, gs.value), 0),
                    "created": "",
                    "last_modified": "",
                    "can_edit": True,  # Users can always toggle their own generated shelf sync
                    "source": gs.source,
                    "value": gs.value,
                }
            )

        # -------------------------------------------------------------------------
        # 3. Sort combined results
        # -------------------------------------------------------------------------
        reverse = order == "desc"
        if sort_param == "name":
            rows.sort(key=lambda r: (r.get("name") or "").lower(), reverse=reverse)
        elif sort_param == "book_count":
            rows.sort(key=lambda r: r.get("book_count", 0), reverse=reverse)
        elif sort_param == "kobo_sync":
            rows.sort(key=lambda r: r.get("kobo_sync", False), reverse=reverse)
        elif sort_param == "is_public":
            rows.sort(key=lambda r: r.get("is_public", False), reverse=reverse)
        elif sort_param == "is_generated":
            rows.sort(key=lambda r: r.get("is_generated", False), reverse=reverse)
        else:
            # Default: name
            rows.sort(key=lambda r: (r.get("name") or "").lower(), reverse=reverse)

        # -------------------------------------------------------------------------
        # 4. Pagination (client-side bootstrap-table handles this, but we support it)
        # -------------------------------------------------------------------------
        total_count = len(rows)
        off = int(request.args.get("offset") or 0)
        limit = int(request.args.get("limit") or 100)
        paginated_rows = rows[off : off + limit]

        log.debug(
            "list_shelves: returning %d rows (total: %d)",
            len(paginated_rows),
            total_count,
        )
        return jsonify(
            {
                "total": total_count,
                "totalNotFiltered": total_count,
                "rows": paginated_rows,
            }
        )
    except Exception as e:
        log.exception("Error in list_shelves: %s", e)
        return jsonify(
            {
                "total": 0,
                "totalNotFiltered": 0,
                "rows": [],
                "error": str(e),
            }
        )


@shelf.route("/shelf/bulk_kobo_sync", methods=["POST"])
@user_login_required
def bulk_kobo_sync():
    """Bulk enable/disable Kobo sync for multiple shelves (regular and generated)."""
    if not config.config_kobo_sync:
        return jsonify({"success": False, "msg": _("Kobo sync is not enabled")}), 400

    payload = request.get_json(silent=True) or {}
    shelf_ids = payload.get("shelf_ids", [])
    enable = payload.get("enable", True)

    if not shelf_ids:
        return jsonify({"success": False, "msg": _("No shelves selected")}), 400

    modified = 0
    regular_ids = []
    generated_items = []  # List of (source, value) tuples

    # Separate regular shelf IDs from generated shelf IDs
    for sid in shelf_ids:
        if isinstance(sid, str) and sid.startswith("generated:"):
            # Format: "generated:source:value"
            parts = sid.split(":", 2)
            if len(parts) == 3:
                generated_items.append((parts[1], parts[2]))
        else:
            try:
                regular_ids.append(int(sid))
            except (ValueError, TypeError):
                pass

    # -------------------------------------------------------------------------
    # Handle regular shelves
    # -------------------------------------------------------------------------
    if regular_ids:
        editable_shelves = (
            ub.session.query(ub.Shelf)
            .filter(
                ub.Shelf.id.in_(regular_ids),
                or_(
                    ub.Shelf.user_id == current_user.id,
                    and_(ub.Shelf.is_public == 1, current_user.role_edit_shelfs()),
                ),
            )
            .all()
        )

        for s in editable_shelves:
            if s.name == KOBO_OPT_IN_SHELF_NAME:
                continue  # Skip the opt-in shelf
            s.kobo_sync = enable
            modified += 1

    # -------------------------------------------------------------------------
    # Handle generated shelves
    # -------------------------------------------------------------------------
    for source, value in generated_items:
        # Upsert into GeneratedShelfKoboSync
        existing = (
            ub.session.query(ub.GeneratedShelfKoboSync)
            .filter(
                ub.GeneratedShelfKoboSync.user_id == current_user.id,
                ub.GeneratedShelfKoboSync.source == source,
                ub.GeneratedShelfKoboSync.value == value,
            )
            .first()
        )
        if existing:
            existing.kobo_sync = enable
        else:
            new_sync = ub.GeneratedShelfKoboSync(
                user_id=current_user.id,
                source=source,
                value=value,
                kobo_sync=enable,
            )
            ub.session.add(new_sync)
        modified += 1

    if generated_items:
        _mark_force_resync_generated(current_user.id)

    try:
        ub.session.commit()
    except Exception as e:
        ub.session.rollback()
        return jsonify({"success": False, "msg": str(e)}), 500

    action = _("enabled") if enable else _("disabled")
    return jsonify(
        {
            "success": True,
            "modified": modified,
            "msg": _(
                "Kobo sync %(action)s for %(count)s shelves",
                action=action,
                count=modified,
            ),
        }
    )


@shelf.route("/shelf/bulk_delete", methods=["POST"])
@user_login_required
def bulk_delete_shelves():
    """Bulk delete multiple shelves."""
    payload = request.get_json(silent=True) or {}
    shelf_ids = payload.get("shelf_ids", [])

    if not shelf_ids:
        return jsonify({"success": False, "msg": _("No shelves selected")}), 400

    # Get shelves user can delete (own shelves only, or public if admin)
    deletable = (
        ub.session.query(ub.Shelf)
        .filter(
            ub.Shelf.id.in_(shelf_ids),
            ub.Shelf.user_id == current_user.id,  # Can only delete own shelves
        )
        .all()
    )

    if not deletable:
        return jsonify({"success": False, "msg": _("No deletable shelves found")}), 403

    deleted = 0
    protected = 0
    mode = get_user_kobo_collections_mode(current_user)

    for s in deletable:
        # Protect Kobo Sync shelf in hybrid mode
        if s.name == KOBO_OPT_IN_SHELF_NAME and mode == "hybrid":
            protected += 1
            continue
        # Delete book-shelf links
        ub.session.query(ub.BookShelf).filter(ub.BookShelf.shelf == s.id).delete()
        # Archive the shelf
        ub.session.add(ub.ShelfArchive(uuid=s.uuid, user_id=s.user_id))
        ub.session.delete(s)
        deleted += 1

    try:
        ub.session.commit()
    except Exception as e:
        ub.session.rollback()
        return jsonify({"success": False, "msg": str(e)}), 500

    msg = _("Deleted %(count)s shelves", count=deleted)
    if protected:
        msg += " " + _("(%(count)s protected)", count=protected)

    return jsonify(
        {
            "success": True,
            "deleted": deleted,
            "protected": protected,
            "msg": msg,
        }
    )


@shelf.route("/shelf/add/<int:shelf_id>/<int:book_id>", methods=["POST"])
@user_login_required
def add_to_shelf(shelf_id, book_id):
    xhr = request.headers.get("X-Requested-With") == "XMLHttpRequest"
    shelf = ub.session.query(ub.Shelf).filter(ub.Shelf.id == shelf_id).first()
    if shelf is None:
        log.error("Invalid shelf specified: %s", shelf_id)
        if not xhr:
            flash(_("Invalid shelf specified"), category="error")
            return redirect(url_for("web.index"))
        return "Invalid shelf specified", 400

    if not check_shelf_edit_permissions(shelf):
        if not xhr:
            flash(
                _("Sorry you are not allowed to add a book to that shelf"),
                category="error",
            )
            return redirect(url_for("web.index"))
        return "Sorry you are not allowed to add a book to the that shelf", 403

    book_in_shelf = (
        ub.session.query(ub.BookShelf)
        .filter(ub.BookShelf.shelf == shelf_id, ub.BookShelf.book_id == book_id)
        .first()
    )
    if book_in_shelf:
        log.error("Book %s is already part of %s", book_id, shelf)
        if not xhr:
            flash(
                _(
                    "Book is already part of the shelf: %(shelfname)s",
                    shelfname=shelf.name,
                ),
                category="error",
            )
            return redirect(url_for("web.index"))
        return "Book is already part of the shelf: %s" % shelf.name, 400

    maxOrder = (
        ub.session.query(func.max(ub.BookShelf.order))
        .filter(ub.BookShelf.shelf == shelf_id)
        .first()
    )
    if maxOrder[0] is None:
        maxOrder = 0
    else:
        maxOrder = maxOrder[0]

    book = (
        calibre_db.session.query(db.Books).filter(db.Books.id == book_id).one_or_none()
    )
    if (
        not calibre_db.session.query(db.Books)
        .filter(db.Books.id == book_id)
        .one_or_none()
    ):
        log.error(
            "Invalid Book Id: %s. Could not be added to shelf %s", book_id, shelf.name
        )
        if not xhr:
            flash(
                _(
                    "%(book_id)s is a invalid Book Id. Could not be added to Shelf",
                    book_id=book_id,
                ),
                category="error",
            )
            return redirect(url_for("web.index"))
        return "%s is a invalid Book Id. Could not be added to Shelf" % book_id, 400

    shelf.books.append(
        ub.BookShelf(shelf=shelf.id, book_id=book_id, order=maxOrder + 1)
    )
    shelf.last_modified = datetime.now(timezone.utc)
    try:
        ub.session.merge(shelf)
        ub.session.commit()
    except (OperationalError, InvalidRequestError) as e:
        ub.session.rollback()
        log.error_or_exception("Settings Database error: {}".format(e))
        flash(_("Oops! Database Error: %(error)s.", error=e.orig), category="error")
        if "HTTP_REFERER" in request.environ:
            return redirect(request.environ["HTTP_REFERER"])
        else:
            return redirect(url_for("web.index"))
    if not xhr:
        log.debug("Book has been added to shelf: {}".format(shelf.name))
        flash(
            _("Book has been added to shelf: %(sname)s", sname=shelf.name),
            category="success",
        )
        if "HTTP_REFERER" in request.environ:
            return redirect(request.environ["HTTP_REFERER"])
        else:
            return redirect(url_for("web.index"))
    if shelf.kobo_sync and config.config_hardcover_sync and bool(hardcover):
        try:
            hardcoverClient = hardcover.HardcoverClient(current_user.hardcover_token)
            if not hardcoverClient.get_user_book(book.identifiers):
                hardcoverClient.add_book(book.identifiers)
        except hardcover.MissingHardcoverToken:
            log.info(
                f"User {current_user.name} has no token for Hardcover configured, cannot add to Hardcover."
            )
        except Exception as e:
            log.debug(
                f"Failed to create Hardcover client for user {current_user.name}: {e}"
            )
    return "", 204


@shelf.route("/shelf/massadd/<int:shelf_id>", methods=["POST"])
@user_login_required
def search_to_shelf(shelf_id):
    shelf = ub.session.query(ub.Shelf).filter(ub.Shelf.id == shelf_id).first()
    if shelf is None:
        log.error("Invalid shelf specified: {}".format(shelf_id))
        flash(_("Invalid shelf specified"), category="error")
        return redirect(url_for("web.index"))

    if not check_shelf_edit_permissions(shelf):
        log.warning("You are not allowed to add a book to the shelf")
        flash(_("You are not allowed to add a book to the shelf"), category="error")
        return redirect(url_for("web.index"))

    if current_user.id in ub.searched_ids and ub.searched_ids[current_user.id]:
        books_for_shelf = list()
        books_in_shelf = (
            ub.session.query(ub.BookShelf).filter(ub.BookShelf.shelf == shelf_id).all()
        )
        if books_in_shelf:
            book_ids = list()
            for book_id in books_in_shelf:
                book_ids.append(book_id.book_id)
            for searchid in ub.searched_ids[current_user.id]:
                if searchid not in book_ids:
                    books_for_shelf.append(searchid)
        else:
            books_for_shelf = ub.searched_ids[current_user.id]

        if not books_for_shelf:
            log.error("Books are already part of {}".format(shelf.name))
            flash(
                _("Books are already part of the shelf: %(name)s", name=shelf.name),
                category="error",
            )
            return redirect(url_for("web.index"))

        maxOrder = (
            ub.session.query(func.max(ub.BookShelf.order))
            .filter(ub.BookShelf.shelf == shelf_id)
            .first()[0]
            or 0
        )

        for book in books_for_shelf:
            maxOrder += 1
            shelf.books.append(
                ub.BookShelf(shelf=shelf.id, book_id=book, order=maxOrder)
            )
        shelf.last_modified = datetime.now(timezone.utc)
        try:
            ub.session.merge(shelf)
            ub.session.commit()
            flash(
                _("Books have been added to shelf: %(sname)s", sname=shelf.name),
                category="success",
            )
        except (OperationalError, InvalidRequestError) as e:
            ub.session.rollback()
            log.error_or_exception("Settings Database error: {}".format(e))
            flash(_("Oops! Database Error: %(error)s.", error=e.orig), category="error")
    else:
        log.error("Could not add books to shelf: {}".format(shelf.name))
        flash(
            _("Could not add books to shelf: %(sname)s", sname=shelf.name),
            category="error",
        )
    return redirect(url_for("web.index"))


@shelf.route("/shelf/remove/<int:shelf_id>/<int:book_id>", methods=["POST"])
@user_login_required
def remove_from_shelf(shelf_id, book_id):
    xhr = request.headers.get("X-Requested-With") == "XMLHttpRequest"
    shelf = ub.session.query(ub.Shelf).filter(ub.Shelf.id == shelf_id).first()
    if shelf is None:
        log.error("Invalid shelf specified: {}".format(shelf_id))
        if not xhr:
            return redirect(url_for("web.index"))
        return "Invalid shelf specified", 400

    # if shelf is public and use is allowed to edit shelfs, or if shelf is private and user is owner
    # allow editing shelfs
    # result   shelf public   user allowed    user owner
    #   false        1             0             x
    #   true         1             1             x
    #   true         0             x             1
    #   false        0             x             0

    if check_shelf_edit_permissions(shelf):
        book_shelf = (
            ub.session.query(ub.BookShelf)
            .filter(ub.BookShelf.shelf == shelf_id, ub.BookShelf.book_id == book_id)
            .first()
        )

        if book_shelf is None:
            log.error("Book %s already removed from %s", book_id, shelf)
            if not xhr:
                return redirect(url_for("web.index"))
            return "Book already removed from shelf", 410

        try:
            ub.session.delete(book_shelf)
            shelf.last_modified = datetime.now(timezone.utc)
            ub.session.commit()
        except (OperationalError, InvalidRequestError) as e:
            ub.session.rollback()
            log.error_or_exception("Settings Database error: {}".format(e))
            flash(_("Oops! Database Error: %(error)s.", error=e.orig), category="error")
            if "HTTP_REFERER" in request.environ:
                return redirect(request.environ["HTTP_REFERER"])
            else:
                return redirect(url_for("web.index"))
        if not xhr:
            flash(
                _("Book has been removed from shelf: %(sname)s", sname=shelf.name),
                category="success",
            )
            if "HTTP_REFERER" in request.environ:
                return redirect(request.environ["HTTP_REFERER"])
            else:
                return redirect(url_for("web.index"))
        return "", 204
    else:
        if not xhr:
            log.warning(
                "You are not allowed to remove a book from shelf: {}".format(shelf.name)
            )
            flash(
                _("Sorry you are not allowed to remove a book from this shelf"),
                category="error",
            )
            return redirect(url_for("web.index"))
        return "Sorry you are not allowed to remove a book from this shelf", 403


@shelf.route("/shelf/create", methods=["GET", "POST"])
@user_login_required
def create_shelf():
    shelf = ub.Shelf()
    return create_edit_shelf(shelf, page_title=_("Create a Shelf"), page="shelfcreate")


@shelf.route("/shelf/edit/<int:shelf_id>", methods=["GET", "POST"])
@user_login_required
def edit_shelf(shelf_id):
    shelf = ub.session.query(ub.Shelf).filter(ub.Shelf.id == shelf_id).first()
    if not check_shelf_edit_permissions(shelf):
        flash(_("Sorry you are not allowed to edit this shelf"), category="error")
        return redirect(url_for("web.index"))
    return create_edit_shelf(
        shelf, page_title=_("Edit a shelf"), page="shelfedit", shelf_id=shelf_id
    )


@shelf.route("/shelf/generated/edit/<source>/<path:value>", methods=["GET", "POST"])
@user_login_required
def edit_generated_shelf(source, value):
    """Edit settings for a generated shelf (e.g., enable/disable Kobo sync)."""
    if not config.config_kobo_sync:
        flash(_("Kobo sync is not enabled"), category="error")
        return redirect(url_for("web.index"))

    # Create a GeneratedShelf object for display purposes
    gen_shelf = GeneratedShelf(source=source, value=value, name=value)

    # Get or create the sync preference record
    sync_pref = (
        ub.session.query(ub.GeneratedShelfKoboSync)
        .filter(
            ub.GeneratedShelfKoboSync.user_id == current_user.id,
            ub.GeneratedShelfKoboSync.source == source,
            ub.GeneratedShelfKoboSync.value == value,
        )
        .first()
    )

    if request.method == "POST":
        to_save = request.form.to_dict()
        kobo_sync_enabled = to_save.get("kobo_sync") == "on"

        if sync_pref:
            sync_pref.kobo_sync = kobo_sync_enabled
        else:
            sync_pref = ub.GeneratedShelfKoboSync(
                user_id=current_user.id,
                source=source,
                value=value,
                kobo_sync=kobo_sync_enabled,
            )
            ub.session.add(sync_pref)

        _mark_force_resync_generated(current_user.id)

        try:
            ub.session.commit()
            flash(
                _("Shelf %(title)s changed", title=gen_shelf.name), category="success"
            )
            return redirect(
                url_for("shelf.show_generated_shelf", source=source, value=value)
            )
        except (OperationalError, InvalidRequestError) as ex:
            ub.session.rollback()
            log.error_or_exception("Settings Database error: {}".format(ex))
            flash(
                _("Oops! Database Error: %(error)s.", error=ex.orig), category="error"
            )

    # For GET request, render the edit form
    # Show Kobo sync toggle when mode is 'selected' or 'hybrid' (not 'all')
    kobo_mode = get_user_kobo_collections_mode(current_user)
    sync_only_selected_shelves = kobo_mode in ("selected", "hybrid")
    kobo_sync_checked = sync_pref.kobo_sync if sync_pref else False

    return render_title_template(
        "generated_shelf_edit.html",
        shelf=gen_shelf,
        kobo_sync_checked=kobo_sync_checked,
        title=_("Edit a shelf"),
        page="shelfedit",
        kobo_sync_enabled=config.config_kobo_sync,
        sync_only_selected_shelves=sync_only_selected_shelves,
    )


@shelf.route("/shelf/delete/<int:shelf_id>", methods=["POST"])
@user_login_required
def delete_shelf(shelf_id):
    cur_shelf = ub.session.query(ub.Shelf).filter(ub.Shelf.id == shelf_id).first()
    try:
        if not delete_shelf_helper(cur_shelf):
            flash(_("Error deleting Shelf"), category="error")
        else:
            flash(_("Shelf successfully deleted"), category="success")
    except InvalidRequestError as e:
        ub.session.rollback()
        log.error_or_exception("Settings Database error: {}".format(e))
        flash(_("Oops! Database Error: %(error)s.", error=e.orig), category="error")
    return redirect(url_for("web.index"))


@shelf.route("/simpleshelf/<int:shelf_id>")
@login_required_if_no_ano
def show_simpleshelf(shelf_id):
    return render_show_shelf(2, shelf_id, 1, None)


@shelf.route("/shelf/<int:shelf_id>", defaults={"sort_param": "stored", "page": 1})
@shelf.route("/shelf/<int:shelf_id>/<sort_param>", defaults={"page": 1})
@shelf.route("/shelf/<int:shelf_id>/<sort_param>/<int:page>")
@login_required_if_no_ano
def show_shelf(shelf_id, sort_param, page):
    return render_show_shelf(1, shelf_id, page, sort_param)


@shelf.route(
    "/shelf/generated/<source>/<path:value>",
    defaults={"sort_param": "stored", "page": 1},
)
@shelf.route(
    "/shelf/generated/<source>/<path:value>/<any(stored,abc,zyx,new,old,authaz,authza,pubnew,pubold):sort_param>",
    defaults={"page": 1},
)
@shelf.route(
    "/shelf/generated/<source>/<path:value>/<any(stored,abc,zyx,new,old,authaz,authza,pubnew,pubold):sort_param>/<int:page>"
)
@login_required_if_no_ano
def show_generated_shelf(source, value, sort_param, page):
    return render_show_generated_shelf(source, value, page, sort_param)


@shelf.route("/shelf/order/<int:shelf_id>", methods=["GET", "POST"])
@user_login_required
def order_shelf(shelf_id):
    shelf = ub.session.query(ub.Shelf).filter(ub.Shelf.id == shelf_id).first()
    if shelf and check_shelf_view_permissions(shelf):
        if request.method == "POST":
            to_save = request.form.to_dict()
            books_in_shelf = (
                ub.session.query(ub.BookShelf)
                .filter(ub.BookShelf.shelf == shelf_id)
                .order_by(ub.BookShelf.order.asc())
                .all()
            )
            counter = 0
            for book in books_in_shelf:
                setattr(book, "order", to_save[str(book.book_id)])
                counter += 1
                # if order different from before -> shelf.last_modified = datetime.now(timezone.utc)
            try:
                ub.session.commit()
            except (OperationalError, InvalidRequestError) as e:
                ub.session.rollback()
                log.error_or_exception("Settings Database error: {}".format(e))
                flash(
                    _("Oops! Database Error: %(error)s.", error=e.orig),
                    category="error",
                )

        result = list()
        if shelf:
            result = (
                calibre_db.session.query(db.Books)
                .join(ub.BookShelf, ub.BookShelf.book_id == db.Books.id, isouter=True)
                .add_columns(calibre_db.common_filters().label("visible"))
                .filter(ub.BookShelf.shelf == shelf_id)
                .order_by(ub.BookShelf.order.asc())
                .all()
            )
        return render_title_template(
            "shelf_order.html",
            entries=result,
            title=_("Change order of Shelf: '%(name)s'", name=shelf.name),
            shelf=shelf,
            page="shelforder",
        )
    else:
        abort(404)


def check_shelf_edit_permissions(cur_shelf):
    if not cur_shelf.is_public and not cur_shelf.user_id == int(current_user.id):
        log.error(
            "User {} not allowed to edit shelf: {}".format(
                current_user.id, cur_shelf.name
            )
        )
        return False
    if cur_shelf.is_public and not current_user.role_edit_shelfs():
        log.info("User {} not allowed to edit public shelves".format(current_user.id))
        return False
    return True


def check_shelf_view_permissions(cur_shelf):
    try:
        if cur_shelf.is_public:
            return True
        if current_user.is_anonymous or cur_shelf.user_id != current_user.id:
            log.error(
                "User is unauthorized to view non-public shelf: {}".format(
                    cur_shelf.name
                )
            )
            return False
    except Exception as e:
        log.error(e)
    return True


# if shelf ID is set, we are editing a shelf
def create_edit_shelf(shelf, page_title, page, shelf_id=False):
    # Show Kobo sync toggle when mode is 'selected' or 'hybrid' (not 'all')
    kobo_mode = get_user_kobo_collections_mode(current_user)
    sync_only_selected_shelves = kobo_mode in ("selected", "hybrid")
    is_kobo_opt_in_shelf = getattr(shelf, "name", None) == KOBO_OPT_IN_SHELF_NAME
    # calibre_db.session.query(ub.Shelf).filter(ub.Shelf.user_id == current_user.id).filter(ub.Shelf.kobo_sync).count()
    if request.method == "POST":
        to_save = request.form.to_dict()
        if not current_user.role_edit_shelfs() and to_save.get("is_public") == "on":
            flash(
                _("Sorry you are not allowed to create a public shelf"),
                category="error",
            )
            return redirect(url_for("web.index"))
        is_public = 1 if to_save.get("is_public") == "on" else 0

        shelf_title = to_save.get("title", "")
        reserved_opt_in_name = KOBO_OPT_IN_SHELF_NAME
        is_reserved_opt_in_shelf = False
        try:
            is_reserved_opt_in_shelf = (shelf.name == reserved_opt_in_name) or (
                shelf_title.strip() == reserved_opt_in_name
            )
        except Exception:
            is_reserved_opt_in_shelf = shelf_title.strip() == reserved_opt_in_name

        if is_reserved_opt_in_shelf:
            # This shelf is reserved for hybrid opt-in and must never sync to the device as a collection.
            shelf_title = reserved_opt_in_name
            is_public = 0
            shelf.kobo_sync = False
            is_kobo_opt_in_shelf = True
        elif config.config_kobo_sync:
            shelf.kobo_sync = True if to_save.get("kobo_sync") else False
            if shelf.kobo_sync:
                ub.session.query(ub.ShelfArchive).filter(
                    ub.ShelfArchive.user_id == current_user.id
                ).filter(ub.ShelfArchive.uuid == shelf.uuid).delete()
                ub.session_commit()

        if check_shelf_is_unique(shelf_title, is_public, shelf_id):
            shelf.name = shelf_title
            shelf.is_public = is_public
            if not shelf_id:
                shelf.user_id = int(current_user.id)
                ub.session.add(shelf)
                shelf_action = "created"
                flash_text = _("Shelf %(title)s created", title=shelf_title)
            else:
                shelf_action = "changed"
                flash_text = _("Shelf %(title)s changed", title=shelf_title)
            try:
                ub.session.commit()
                log.info("Shelf {} {}".format(shelf_title, shelf_action))
                flash(flash_text, category="success")
                return redirect(url_for("shelf.show_shelf", shelf_id=shelf.id))
            except (OperationalError, InvalidRequestError) as ex:
                ub.session.rollback()
                log.error_or_exception(ex)
                log.error_or_exception("Settings Database error: {}".format(ex))
                flash(
                    _("Oops! Database Error: %(error)s.", error=ex.orig),
                    category="error",
                )
            except Exception as ex:
                ub.session.rollback()
                log.error_or_exception(ex)
                flash(_("There was an error"), category="error")
    return render_title_template(
        "shelf_edit.html",
        shelf=shelf,
        is_kobo_opt_in_shelf=is_kobo_opt_in_shelf,
        title=page_title,
        page=page,
        kobo_sync_enabled=config.config_kobo_sync,
        sync_only_selected_shelves=sync_only_selected_shelves,
    )


def check_shelf_is_unique(title, is_public, shelf_id=False):
    if shelf_id:
        ident = ub.Shelf.id != shelf_id
    else:
        ident = true()
    if is_public == 1:
        is_shelf_name_unique = (
            ub.session.query(ub.Shelf)
            .filter((ub.Shelf.name == title) & (ub.Shelf.is_public == 1))
            .filter(ident)
            .first()
            is None
        )

        if not is_shelf_name_unique:
            log.error("A public shelf with the name '{}' already exists.".format(title))
            flash(
                _(
                    "A public shelf with the name '%(title)s' already exists.",
                    title=title,
                ),
                category="error",
            )
    else:
        is_shelf_name_unique = (
            ub.session.query(ub.Shelf)
            .filter(
                (ub.Shelf.name == title)
                & (ub.Shelf.is_public == 0)
                & (ub.Shelf.user_id == int(current_user.id))
            )
            .filter(ident)
            .first()
            is None
        )

        if not is_shelf_name_unique:
            log.error(
                "A private shelf with the name '{}' already exists.".format(title)
            )
            flash(
                _(
                    "A private shelf with the name '%(title)s' already exists.",
                    title=title,
                ),
                category="error",
            )
    return is_shelf_name_unique


def delete_shelf_helper(cur_shelf):
    if not cur_shelf or not check_shelf_edit_permissions(cur_shelf):
        return False
    # Protect the Kobo Sync opt-in shelf from deletion when in hybrid mode
    if cur_shelf.name == KOBO_OPT_IN_SHELF_NAME:
        mode = get_user_kobo_collections_mode(current_user)
        if mode == "hybrid":
            flash(
                _(
                    "The '%(name)s' shelf cannot be deleted while in 'Sync Selected Books' mode.",
                    name=KOBO_OPT_IN_SHELF_NAME,
                ),
                category="error",
            )
            return False
    shelf_id = cur_shelf.id
    ub.session.delete(cur_shelf)
    ub.session.query(ub.BookShelf).filter(ub.BookShelf.shelf == shelf_id).delete()
    ub.session.add(ub.ShelfArchive(uuid=cur_shelf.uuid, user_id=cur_shelf.user_id))
    ub.session_commit("successfully deleted Shelf {}".format(cur_shelf.name))
    return True


def change_shelf_order(shelf_id, order):
    result = (
        calibre_db.session.query(db.Books)
        .outerjoin(db.books_series_link, db.Books.id == db.books_series_link.c.book)
        .outerjoin(db.Series)
        .join(ub.BookShelf, ub.BookShelf.book_id == db.Books.id)
        .filter(ub.BookShelf.shelf == shelf_id)
        .order_by(*order)
        .all()
    )
    for index, entry in enumerate(result):
        book = (
            ub.session.query(ub.BookShelf)
            .filter(ub.BookShelf.shelf == shelf_id)
            .filter(ub.BookShelf.book_id == entry.id)
            .first()
        )
        book.order = index
    ub.session_commit("Shelf-id:{} - Order changed".format(shelf_id))


def render_show_shelf(shelf_type, shelf_id, page_no, sort_param):
    shelf = ub.session.query(ub.Shelf).filter(ub.Shelf.id == shelf_id).first()
    status = current_user.get_view_property("shelf", "man")
    # check user is allowed to access shelf
    if shelf and check_shelf_view_permissions(shelf):
        if shelf_type == 1:
            if status != "on":
                if sort_param == "stored":
                    sort_param = current_user.get_view_property("shelf", "stored")
                else:
                    current_user.set_view_property("shelf", "stored", sort_param)
                if sort_param == "pubnew":
                    change_shelf_order(shelf_id, [db.Books.pubdate.desc()])
                if sort_param == "pubold":
                    change_shelf_order(shelf_id, [db.Books.pubdate])
                if sort_param == "shelfnew":
                    change_shelf_order(shelf_id, [ub.BookShelf.date_added.desc()])
                if sort_param == "shelfold":
                    change_shelf_order(shelf_id, [ub.BookShelf.date_added])
                if sort_param == "abc":
                    change_shelf_order(shelf_id, [db.Books.sort])
                if sort_param == "zyx":
                    change_shelf_order(shelf_id, [db.Books.sort.desc()])
                if sort_param == "new":
                    change_shelf_order(shelf_id, [db.Books.timestamp.desc()])
                if sort_param == "old":
                    change_shelf_order(shelf_id, [db.Books.timestamp])
                if sort_param == "authaz":
                    change_shelf_order(
                        shelf_id,
                        [
                            db.Books.author_sort.asc(),
                            db.Series.name,
                            db.Books.series_index,
                        ],
                    )
                if sort_param == "authza":
                    change_shelf_order(
                        shelf_id,
                        [
                            db.Books.author_sort.desc(),
                            db.Series.name.desc(),
                            db.Books.series_index.desc(),
                        ],
                    )
            page = "shelf.html"
            pagesize = 0
        else:
            pagesize = sys.maxsize
            page = "shelfdown.html"

        result, __, pagination = calibre_db.fill_indexpage(
            page_no,
            pagesize,
            db.Books,
            ub.BookShelf.shelf == shelf_id,
            [ub.BookShelf.order.asc()],
            True,
            config.config_read_column,
            ub.BookShelf,
            ub.BookShelf.book_id == db.Books.id,
        )
        # delete shelf entries where book is not existent anymore, can happen if book is deleted outside autocaliweb
        wrong_entries = (
            calibre_db.session.query(ub.BookShelf)
            .join(db.Books, ub.BookShelf.book_id == db.Books.id, isouter=True)
            .filter(db.Books.id == None)
            .all()
        )
        for entry in wrong_entries:
            log.info("Not existing book {} in {} deleted".format(entry.book_id, shelf))
            try:
                ub.session.query(ub.BookShelf).filter(
                    ub.BookShelf.book_id == entry.book_id
                ).delete()
                ub.session.commit()
            except (OperationalError, InvalidRequestError) as e:
                ub.session.rollback()
                log.error_or_exception("Settings Database error: {}".format(e))
                flash(
                    _("Oops! Database Error: %(error)s.", error=e.orig),
                    category="error",
                )

        return render_title_template(
            page,
            entries=result,
            pagination=pagination,
            title=_("Shelf: '%(name)s'", name=shelf.name),
            shelf=shelf,
            page="shelf",
            status=status,
            order=sort_param,
            config=config,
        )
    else:
        flash(
            _("Error opening shelf. Shelf does not exist or is not accessible"),
            category="error",
        )
        return redirect(url_for("web.index"))


def render_show_generated_shelf(source, value, page_no, sort_param):
    shelf_filter = generated_shelf_filter(source, value)
    if shelf_filter is None:
        flash(
            _("Error opening shelf. Shelf does not exist or is not accessible"),
            category="error",
        )
        return redirect(url_for("web.index"))

    status = "off"
    if sort_param == "stored":
        sort_param = current_user.get_view_property("genshelf", "stored") or "abc"
    else:
        current_user.set_view_property("genshelf", "stored", sort_param)

    order_map = {
        "abc": [db.Books.sort],
        "zyx": [db.Books.sort.desc()],
        "new": [db.Books.timestamp.desc()],
        "old": [db.Books.timestamp],
        "authaz": [db.Books.author_sort.asc(), db.Series.name, db.Books.series_index],
        "authza": [
            db.Books.author_sort.desc(),
            db.Series.name.desc(),
            db.Books.series_index.desc(),
        ],
        "pubnew": [db.Books.pubdate.desc()],
        "pubold": [db.Books.pubdate],
    }
    if sort_param not in order_map:
        sort_param = "abc"

    gen_shelf = GeneratedShelf(source=source, value=value, name=value)
    result, __, pagination = calibre_db.fill_indexpage(
        page_no,
        0,
        db.Books,
        shelf_filter,
        order_map[sort_param],
        True,
        config.config_read_column,
        db.books_series_link,
        db.Books.id == db.books_series_link.c.book,
        db.Series,
    )

    return render_title_template(
        "shelf.html",
        entries=result,
        pagination=pagination,
        title=_("Shelf: '%(name)s'", name=gen_shelf.name),
        shelf=gen_shelf,
        page="shelf",
        status=status,
        order=sort_param,
        config=config,
    )
