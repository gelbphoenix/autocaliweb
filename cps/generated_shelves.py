# -*- coding: utf-8 -*-

from __future__ import annotations

from dataclasses import dataclass
import uuid

from flask_babel import gettext as _

from . import calibre_db, config, db


def _normalize_author_display(value: str) -> str:
    value = (value or "").strip()
    if not value:
        return value
    # In this codebase, '|' is an internal placeholder for commas inside a single author name.
    return value.replace("|", ",")


@dataclass(frozen=True)
class GeneratedShelf:
    source: str
    value: str
    name: str

    is_generated: bool = True
    is_public: int = 0

    @property
    def id(self) -> str:
        # Used in templates for data attributes. Must be stable and unique.
        return f"generated:{self.source}:{self.value}"

    @property
    def uuid(self) -> str:
        # Used by Kobo sync as the Tag Id. Must be stable across requests.
        return generated_shelf_uuid(self.source, self.value)


def generated_shelf_uuid(source: str, value: str) -> str:
    # Use UUIDv5 so the same (source,value) yields the same uuid.
    # Kobo Tag IDs are UUID-shaped strings.
    stable_key = f"autocaliweb:generated-shelf:{(source or '').strip()}:{(value or '').strip()}"
    return str(uuid.uuid5(uuid.NAMESPACE_URL, stable_key))


def _parse_selector(selector: str) -> tuple[str | None, int | None]:
    selector = (selector or "").strip()
    if not selector:
        return None, None
    if selector.startswith("cc:"):
        try:
            return "cc", int(selector.split(":", 1)[1])
        except (TypeError, ValueError):
            return None, None
    return selector, None


def list_generated_shelves(max_items: int = 500, book_ids=None) -> list[GeneratedShelf]:
    selector, cc_id = _parse_selector(getattr(config, "config_generate_shelves_from_calibre_column", ""))
    if not selector:
        return []

    try:
        eligible_ids = None
        if book_ids:
            try:
                eligible_ids = list(dict.fromkeys([int(b) for b in book_ids if b is not None]))
            except Exception:
                eligible_ids = None

        if selector == "tags":
            q = (
                calibre_db.session.query(db.Tags.name)
                .select_from(db.Tags)
                .join(db.Tags.books)
                .filter(calibre_db.common_filters())
            )
            if eligible_ids:
                q = q.filter(db.Books.id.in_(eligible_ids))
            rows = q.distinct().order_by(db.Tags.name).limit(max_items).all()
            return [GeneratedShelf(source="tags", value=r[0], name=r[0]) for r in rows if r and r[0]]

        if selector == "authors":
            q = (
                calibre_db.session.query(db.Authors.name)
                .select_from(db.Authors)
                .join(db.Authors.books)
                .filter(calibre_db.common_filters())
            )
            if eligible_ids:
                q = q.filter(db.Books.id.in_(eligible_ids))
            rows = q.distinct().order_by(db.Authors.name).limit(max_items).all()
            return [
                GeneratedShelf(source="authors", value=r[0], name=_normalize_author_display(r[0]))
                for r in rows
                if r and r[0]
            ]

        if selector == "publishers":
            q = (
                calibre_db.session.query(db.Publishers.name)
                .select_from(db.Publishers)
                .join(db.Publishers.books)
                .filter(calibre_db.common_filters())
            )
            if eligible_ids:
                q = q.filter(db.Books.id.in_(eligible_ids))
            rows = q.distinct().order_by(db.Publishers.name).limit(max_items).all()
            return [GeneratedShelf(source="publishers", value=r[0], name=r[0]) for r in rows if r and r[0]]

        if selector == "languages":
            q = (
                calibre_db.session.query(db.Languages.lang_code)
                .select_from(db.Languages)
                .join(db.Languages.books)
                .filter(calibre_db.common_filters())
            )
            if eligible_ids:
                q = q.filter(db.Books.id.in_(eligible_ids))
            rows = q.distinct().order_by(db.Languages.lang_code).limit(max_items).all()
            # Languages are stored as lang codes; display name may be derived in UI elsewhere.
            return [GeneratedShelf(source="languages", value=r[0], name=r[0]) for r in rows if r and r[0]]

        if selector == "cc" and cc_id:
            cc_class = db.cc_classes.get(cc_id)
            if cc_class is None:
                return []
            rel = getattr(db.Books, f"custom_column_{cc_id}", None)
            if rel is None:
                return []

            q = (
                calibre_db.session.query(cc_class.value)
                .select_from(db.Books)
                .join(rel)
                .filter(calibre_db.common_filters())
            )
            if eligible_ids:
                q = q.filter(db.Books.id.in_(eligible_ids))
            rows = q.distinct().order_by(cc_class.value).limit(max_items).all()
            return [GeneratedShelf(source=f"cc:{cc_id}", value=r[0], name=r[0]) for r in rows if r and r[0]]

    except Exception:
        # Fail closed: no generated shelves if anything goes wrong.
        return []

    return []


def generated_shelf_filter(source: str, value: str):
    """Return a SQLAlchemy filter for selecting books in the generated shelf."""
    source = (source or "").strip()
    value = (value or "").strip()
    if not source or not value:
        return None

    if source == "tags":
        return db.Books.tags.any(db.Tags.name == value)
    if source == "authors":
        return db.Books.authors.any(db.Authors.name == value)
    if source == "publishers":
        return db.Books.publishers.any(db.Publishers.name == value)
    if source == "languages":
        return db.Books.languages.any(db.Languages.lang_code == value)

    if source.startswith("cc:"):
        try:
            cc_id = int(source.split(":", 1)[1])
        except (TypeError, ValueError):
            return None

        cc_class = db.cc_classes.get(cc_id)
        if not cc_class:
            return None

        rel = getattr(db.Books, f"custom_column_{cc_id}", None)
        if not rel:
            return None

        return rel.any(cc_class.value == value)

    return None


def generated_shelf_badge_text(source: str) -> str:
    source = (source or "").strip()
    response = _("Auto-generated shelf")

    if source == "tags":
        return _("Auto-generated shelf from Tags")
    if source == "authors":
        return _("Auto-generated shelf from Authors")
    if source == "publishers":
        return _("Auto-generated shelf from Publishers")
    if source == "languages":
        return _("Auto-generated shelf from Languages")
    if source.startswith("cc:"):
        return _("Auto-generated shelf from Calibre Column")
    return response


def generated_shelves_for_book(book_id: int, max_items: int = 200) -> list[GeneratedShelf]:
    selector, cc_id = _parse_selector(getattr(config, "config_generate_shelves_from_calibre_column", ""))
    if not selector or not book_id:
        return []

    try:
        if selector == "tags":
            rows = (
                calibre_db.session.query(db.Tags.name)
                .select_from(db.Books)
                .join(db.Books.tags)
                .filter(db.Books.id == book_id)
                .distinct()
                .order_by(db.Tags.name)
                .limit(max_items)
                .all()
            )
            return [GeneratedShelf(source="tags", value=r[0], name=r[0]) for r in rows if r and r[0]]

        if selector == "authors":
            rows = (
                calibre_db.session.query(db.Authors.name)
                .select_from(db.Books)
                .join(db.Books.authors)
                .filter(db.Books.id == book_id)
                .distinct()
                .order_by(db.Authors.name)
                .limit(max_items)
                .all()
            )
            return [
                GeneratedShelf(source="authors", value=r[0], name=_normalize_author_display(r[0]))
                for r in rows
                if r and r[0]
            ]

        if selector == "publishers":
            rows = (
                calibre_db.session.query(db.Publishers.name)
                .select_from(db.Books)
                .join(db.Books.publishers)
                .filter(db.Books.id == book_id)
                .distinct()
                .order_by(db.Publishers.name)
                .limit(max_items)
                .all()
            )
            return [GeneratedShelf(source="publishers", value=r[0], name=r[0]) for r in rows if r and r[0]]

        if selector == "languages":
            rows = (
                calibre_db.session.query(db.Languages.lang_code)
                .select_from(db.Books)
                .join(db.Books.languages)
                .filter(db.Books.id == book_id)
                .distinct()
                .order_by(db.Languages.lang_code)
                .limit(max_items)
                .all()
            )
            return [GeneratedShelf(source="languages", value=r[0], name=r[0]) for r in rows if r and r[0]]

        if selector == "cc" and cc_id:
            cc_class = db.cc_classes.get(cc_id)
            if cc_class is None:
                return []
            rel = getattr(db.Books, f"custom_column_{cc_id}", None)
            if rel is None:
                return []

            rows = (
                calibre_db.session.query(cc_class.value)
                .select_from(db.Books)
                .join(rel)
                .filter(db.Books.id == book_id)
                .distinct()
                .order_by(cc_class.value)
                .limit(max_items)
                .all()
            )
            return [GeneratedShelf(source=f"cc:{cc_id}", value=r[0], name=r[0]) for r in rows if r and r[0]]

    except Exception:
        return []

    return []
