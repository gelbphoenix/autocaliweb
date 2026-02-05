# -*- coding: utf-8 -*-

#  This file is part of the Calibre-Web (https://github.com/janeczku/calibre-web)
#    Copyright (C) 2012-2019 mutschler, jkrehm, cervinko, janeczku, OzzieIsaacs, csitko
#                            ok11, issmirnov, idalin
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

import atexit
import os
import sys
from datetime import datetime, timezone, timedelta
import itertools
import uuid
from flask import session as flask_session
from binascii import hexlify

from .cw_login import AnonymousUserMixin, current_user, user_logged_in

try:
    from flask_dance.consumer.backend.sqla import OAuthConsumerMixin
    oauth_support = True
except ImportError:
    # fails on flask-dance >1.3, due to renaming
    try:
        from flask_dance.consumer.storage.sqla import OAuthConsumerMixin
        oauth_support = True
    except ImportError:
        OAuthConsumerMixin = BaseException
        oauth_support = False
from sqlalchemy import create_engine, exc, exists, event, text, Column, ForeignKey, Index, String, Integer, SmallInteger, Boolean, DateTime, Float, JSON
from sqlalchemy.orm.attributes import flag_modified
from sqlalchemy.sql.expression import func
try:
    # Compatibility with sqlalchemy 2.0
    from sqlalchemy.orm import declarative_base
except ImportError:
    from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import backref, relationship, sessionmaker, Session, scoped_session
from werkzeug.security import generate_password_hash

from . import constants, logger
from .string_helper import strip_whitespaces

log = logger.create()

session: Session | None = None
app_DB_path = None
Base = declarative_base()
searched_ids = {}

logged_in = dict()


def signal_store_user_session(object, user):
    store_user_session()


def store_user_session():
    _user = flask_session.get('_user_id', "")
    _id = flask_session.get('_id', "")
    _random = flask_session.get('_random', "")
    if flask_session.get('_user_id', ""):
        try:
            if not check_user_session(_user, _id, _random):
                expiry = int((datetime.now()  + timedelta(days=31)).timestamp())
                user_session = User_Sessions(_user, _id, _random, expiry)
                session.add(user_session)
                session.commit()
                log.debug("Login and store session : " + _id)
            else:
                log.debug("Found stored session: " + _id)
        except (exc.OperationalError, exc.InvalidRequestError) as e:
            session.rollback()
            log.exception(e)
    else:
        log.error("No user id in session")


def delete_user_session(user_id, session_key):
    try:
        log.debug("Deleted session_key: " + session_key)
        session.query(User_Sessions).filter(User_Sessions.user_id == user_id,
                                            User_Sessions.session_key == session_key).delete()
        session.commit()
    except (exc.OperationalError, exc.InvalidRequestError) as ex:
        session.rollback()
        log.exception(ex)


def check_user_session(user_id, session_key, random):
    try:
        found = session.query(User_Sessions).filter(User_Sessions.user_id==user_id,
                                                    User_Sessions.session_key==session_key,
                                                    User_Sessions.random == random,
                                                    ).one_or_none()
        if found is not None:
            new_expiry = int((datetime.now()  + timedelta(days=31)).timestamp())
            if new_expiry - found.expiry > 86400:
                found.expiry = new_expiry
                session.merge(found)
                session.commit()
        return bool(found)
    except (exc.OperationalError, exc.InvalidRequestError) as e:
        session.rollback()
        log.exception(e)
        return False


user_logged_in.connect(signal_store_user_session)

def store_ids(result):
    ids = list()
    for element in result:
        ids.append(element.id)
    searched_ids[current_user.id] = ids

def store_combo_ids(result):
    ids = list()
    for element in result:
        ids.append(element[0].id)
    searched_ids[current_user.id] = ids


class UserBase:

    @property
    def is_authenticated(self):
        return self.is_active

    def _has_role(self, role_flag):
        return constants.has_flag(self.role, role_flag)

    def role_admin(self):
        return self._has_role(constants.ROLE_ADMIN)

    def role_download(self):
        return self._has_role(constants.ROLE_DOWNLOAD)

    def role_upload(self):
        return self._has_role(constants.ROLE_UPLOAD)

    def role_edit(self):
        return self._has_role(constants.ROLE_EDIT)

    def role_passwd(self):
        return self._has_role(constants.ROLE_PASSWD)

    def role_anonymous(self):
        return self._has_role(constants.ROLE_ANONYMOUS)

    def role_edit_shelfs(self):
        return self._has_role(constants.ROLE_EDIT_SHELFS)

    def role_delete_books(self):
        return self._has_role(constants.ROLE_DELETE_BOOKS)

    def role_viewer(self):
        return self._has_role(constants.ROLE_VIEWER)

    @property
    def is_active(self):
        return True

    @property
    def is_anonymous(self):
        return self.role_anonymous()

    def get_id(self):
        return str(self.id)

    def filter_language(self):
        return self.default_language

    def check_visibility(self, value):
        if value == constants.SIDEBAR_RECENT:
            return True
        return constants.has_flag(self.sidebar_view, value)

    def show_detail_random(self):
        return self.check_visibility(constants.DETAIL_RANDOM)

    def list_denied_tags(self):
        mct = self.denied_tags or ""
        return [strip_whitespaces(t) for t in mct.split(",")]

    def list_allowed_tags(self):
        mct = self.allowed_tags or ""
        return [strip_whitespaces(t) for t in mct.split(",")]

    def list_denied_column_values(self):
        mct = self.denied_column_value or ""
        return [strip_whitespaces(t) for t in mct.split(",")]

    def list_allowed_column_values(self):
        mct = self.allowed_column_value or ""
        return [strip_whitespaces(t) for t in mct.split(",")]

    def get_view_property(self, page, prop):
        if not self.view_settings.get(page):
            return None
        return self.view_settings[page].get(prop)

    def set_view_property(self, page, prop, value):
        if not self.view_settings.get(page):
            self.view_settings[page] = dict()
        self.view_settings[page][prop] = value
        try:
            flag_modified(self, "view_settings")
        except AttributeError:
            pass
        try:
            session.commit()
        except (exc.OperationalError, exc.InvalidRequestError) as e:
            session.rollback()
            log.error_or_exception(e)

    def __repr__(self):
        return '<User %r>' % self.name


# Baseclass for Users in Autocaliweb, settings which depend on certain users are stored here. It is derived from
# User Base (all access methods are declared there)
class User(UserBase, Base):
    __tablename__ = 'user'
    __table_args__ = {'sqlite_autoincrement': True}

    id = Column(Integer, primary_key=True)
    name = Column(String(64), unique=True)
    email = Column(String(120), unique=True, default="")
    role = Column(SmallInteger, default=constants.ROLE_USER)
    password = Column(String)
    kindle_mail = Column(String(120), default="")
    shelf = relationship('Shelf', backref='user', lazy='dynamic', order_by='Shelf.name')
    downloads = relationship('Downloads', backref='user', lazy='dynamic')
    locale = Column(String(2), default="en")
    sidebar_view = Column(Integer, default=1)
    default_language = Column(String(3), default="all")
    denied_tags = Column(String, default="")
    allowed_tags = Column(String, default="")
    denied_column_value = Column(String, default="")
    allowed_column_value = Column(String, default="")
    remote_auth_token = relationship('RemoteAuthToken', backref='user', lazy='dynamic')
    view_settings = Column(JSON, default={})
    # Legacy field - replaced by kobo_sync_collections_mode, kept for migration
    kobo_only_shelves_sync = Column(Integer, default=0)
    kobo_plus = Column(Integer, default=0)
    kobo_overdrive = Column(Integer, default=0)
    kobo_audiobooks = Column(Integer, default=0)
    kobo_instapaper = Column(Integer, default=0)
    # Per-user Kobo sync settings (moved from global config)
    # Kobo Collections sync mode: "all", "selected", or "hybrid"
    kobo_sync_collections_mode = Column(String, default="selected")
    # Enable generated shelf sync (Author, Series, etc.)
    kobo_generated_shelves_sync = Column(Boolean, default=False)
    # When true, generated shelves include ALL books in library
    kobo_generated_shelves_all_books = Column(Boolean, default=False)
    # When true, sync empty collections (shelves with 0 books) to Kobo
    kobo_sync_empty_collections = Column(Boolean, default=False)
    # Max items per sync response (10-500)
    kobo_sync_item_limit = Column(Integer, default=100)
    hardcover_token = Column(String, default="")
    auto_send_enabled = Column(Boolean, default=False)

if oauth_support:
    class OAuth(OAuthConsumerMixin, Base):
        provider_user_id = Column(String(256))
        user_id = Column(Integer, ForeignKey(User.id))
        user = relationship(User)


class OAuthProvider(Base):
    __tablename__ = 'oauthProvider'

    id = Column(Integer, primary_key=True)
    provider_name = Column(String)
    oauth_client_id = Column(String)
    oauth_client_secret = Column(String)
    oauth_base_url = Column(String)
    oauth_auth_url = Column(String)
    oauth_token_url = Column(String)
    oauth_userinfo_url = Column(String)
    scope = Column(String, default="openid profile email")
    username_mapper = Column(String, default="preferred_username")
    email_mapper = Column(String, default="email")
    login_button = Column(String, default="OpenID Connect")
    metadata_url = Column(String)
    active = Column(Boolean)


# Class for anonymous user is derived from User base and completely overrides methods and properties for the
# anonymous user
class Anonymous(AnonymousUserMixin, UserBase):
    def __init__(self):
        self.kobo_only_shelves_sync = None
        self.kobo_plus = None
        self.kobo_overdrive = None
        self.kobo_audiobooks = None
        self.kobo_instapaper = None
        self.view_settings = None
        self.allowed_column_value = None
        self.allowed_tags = None
        self.denied_tags = None
        self.kindle_mail = None
        self.locale = None
        self.default_language = None
        self.sidebar_view = None
        self.id = None
        self.role = None
        self.name = None
        self.auto_send_enabled = False
        self.loadSettings()

    def loadSettings(self):
        data = session.query(User).filter(User.role.op('&')(constants.ROLE_ANONYMOUS) == constants.ROLE_ANONYMOUS)\
            .first()  # type: User
        self.name = data.name
        self.role = data.role
        self.id=data.id
        self.sidebar_view = data.sidebar_view
        self.default_language = data.default_language
        self.locale = data.locale
        self.kindle_mail = data.kindle_mail
        self.denied_tags = data.denied_tags
        self.allowed_tags = data.allowed_tags
        self.denied_column_value = data.denied_column_value
        self.allowed_column_value = data.allowed_column_value
        self.view_settings = data.view_settings
        self.kobo_only_shelves_sync = data.kobo_only_shelves_sync
        self.kobo_plus = data.kobo_plus
        self.kobo_overdrive = data.kobo_overdrive
        self.kobo_audiobooks = data.kobo_audiobooks
        self.kobo_instapaper = data.kobo_instapaper
        self.auto_send_enabled = data.auto_send_enabled

    def role_admin(self):
        return False

    @property
    def is_active(self):
        return False

    @property
    def is_anonymous(self):
        return True

    @property
    def is_authenticated(self):
        return False

    def get_view_property(self, page, prop):
        if 'view' in flask_session:
            if not flask_session['view'].get(page):
                return None
            return flask_session['view'][page].get(prop)
        return None

    def set_view_property(self, page, prop, value):
        if 'view' not in flask_session:
            flask_session['view'] = dict()
        if not flask_session['view'].get(page):
            flask_session['view'][page] = dict()
        flask_session['view'][page][prop] = value

class User_Sessions(Base):
    __tablename__ = 'user_session'

    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey('user.id'))
    session_key = Column(String, default="")
    random = Column(String, default="")
    expiry = Column(Integer)


    def __init__(self, user_id, session_key, random, expiry):
        super().__init__()
        self.user_id = user_id
        self.session_key = session_key
        self.random = random
        self.expiry = expiry


# Baseclass representing Shelfs in autocaliweb in app.db
class Shelf(Base):
    __tablename__ = 'shelf'

    id = Column(Integer, primary_key=True)
    uuid = Column(String, default=lambda: str(uuid.uuid4()))
    name = Column(String)
    is_public = Column(Integer, default=0)
    user_id = Column(Integer, ForeignKey('user.id'))
    kobo_sync = Column(Boolean, default=False)
    books = relationship("BookShelf", backref="ub_shelf", cascade="all, delete-orphan", lazy="dynamic")
    created = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    last_modified = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

    def __repr__(self):
        return '<Shelf %d:%r>' % (self.id, self.name)


# Baseclass representing Relationship between books and Shelfs in Autocaliweb in app.db (N:M)
class BookShelf(Base):
    __tablename__ = 'book_shelf_link'

    id = Column(Integer, primary_key=True)
    book_id = Column(Integer)
    order = Column(Integer)
    shelf = Column(Integer, ForeignKey('shelf.id'))
    date_added = Column(DateTime, default=lambda: datetime.now(timezone.utc))

    def __repr__(self):
        return '<Book %r>' % self.id


# This table keeps track of deleted Shelves so that deletes can be propagated to any paired Kobo device.
class ShelfArchive(Base):
    __tablename__ = 'shelf_archive'

    id = Column(Integer, primary_key=True)
    uuid = Column(String)
    user_id = Column(Integer, ForeignKey('user.id'))
    last_modified = Column(DateTime, default=lambda: datetime.now(timezone.utc))


class ReadBook(Base):
    __tablename__ = 'book_read_link'

    STATUS_UNREAD = 0
    STATUS_FINISHED = 1
    STATUS_IN_PROGRESS = 2

    id = Column(Integer, primary_key=True)
    book_id = Column(Integer, unique=False)
    user_id = Column(Integer, ForeignKey('user.id'), unique=False)
    read_status = Column(Integer, unique=False, default=STATUS_UNREAD, nullable=False)
    kobo_reading_state = relationship("KoboReadingState", uselist=False,
                                      primaryjoin="and_(ReadBook.user_id == foreign(KoboReadingState.user_id), "
                                                  "ReadBook.book_id == foreign(KoboReadingState.book_id))",
                                      cascade="all",
                                      backref=backref("book_read_link",
                                                      uselist=False))
    last_modified = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))
    last_time_started_reading = Column(DateTime, nullable=True)
    times_started_reading = Column(Integer, default=0, nullable=False)


class Bookmark(Base):
    __tablename__ = 'bookmark'

    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey('user.id'))
    book_id = Column(Integer)
    format = Column(String(collation='NOCASE'))
    bookmark_key = Column(String)


# Baseclass representing books that are archived on the user's Kobo device.
class ArchivedBook(Base):
    __tablename__ = 'archived_book'

    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey('user.id'))
    book_id = Column(Integer)
    is_archived = Column(Boolean, unique=False)
    last_modified = Column(DateTime, default=lambda: datetime.now(timezone.utc))


class KoboSyncedBooks(Base):
    __tablename__ = 'kobo_synced_books'
    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey('user.id'))
    book_id = Column(Integer)


class KoboTagSyncState(Base):
    __tablename__ = 'kobo_tag_sync_state'

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey('user.id'), unique=True)

    generated_selector = Column(String, default='')
    include_generated_in_selected = Column(Boolean, default=False)
    collections_mode = Column(String, default='')
    sync_all_generated = Column(Boolean, default=False)

    # Set true when the server needs to re-emit all generated collections at least once
    # (e.g., user enabled generated shelves in selected mode).
    force_resync_generated = Column(Boolean, default=False)

    last_modified = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

# The Kobo ReadingState API keeps track of 4 timestamped entities:
#   ReadingState, StatusInfo, Statistics, CurrentBookmark
# Which we map to the following 4 tables:
#   KoboReadingState, ReadBook, KoboStatistics and KoboBookmark
class KoboReadingState(Base):
    __tablename__ = 'kobo_reading_state'

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey('user.id'))
    book_id = Column(Integer)
    last_modified = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))
    priority_timestamp = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))
    current_bookmark = relationship("KoboBookmark", uselist=False, backref="kobo_reading_state", cascade="all, delete")
    statistics = relationship("KoboStatistics", uselist=False, backref="kobo_reading_state", cascade="all, delete")


class KoboBookmark(Base):
    __tablename__ = 'kobo_bookmark'

    id = Column(Integer, primary_key=True)
    kobo_reading_state_id = Column(Integer, ForeignKey('kobo_reading_state.id'))
    last_modified = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))
    location_source = Column(String)
    location_type = Column(String)
    location_value = Column(String)
    progress_percent = Column(Float)
    content_source_progress_percent = Column(Float)


class KoboStatistics(Base):
    __tablename__ = 'kobo_statistics'

    id = Column(Integer, primary_key=True)
    kobo_reading_state_id = Column(Integer, ForeignKey('kobo_reading_state.id'))
    last_modified = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))
    remaining_time_minutes = Column(Integer)
    spent_reading_minutes = Column(Integer)

class KoboAnnotationSync(Base):
    """Track which Kobo annotations have been synced to external services (e.g., Hardcover)."""
    __tablename__ = 'kobo_annotation_sync'

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey('user.id'), nullable=False)
    annotation_id = Column(String, nullable=False)  # Kobo annotation UUID
    book_id = Column(Integer, nullable=False)  # Calibre book ID
    synced_to_hardcover = Column(Boolean, default=False)
    hardcover_journal_id = Column(Integer)  # Hardcover journal entry ID
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    last_synced = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))
    highlighted_text = Column(String, nullable=True)
    highlight_color = Column(String, nullable=True)
    note_text = Column(String, nullable=True)

    __table_args__ = (
        Index('ix_kobo_annotation_sync_user_annotation', 'user_id', 'annotation_id'),
    )

    def __repr__(self):
        return f'<KoboAnnotationSync annotation_id={self.annotation_id} book_id={self.book_id}>'


class GeneratedShelfKoboSync(Base):
    """Track Kobo sync preferences for generated shelves (author, series, tags, etc.).

    Generated shelves are computed dynamically from Calibre metadata and don't exist in the
    ub.Shelf table. This table stores the user's kobo_sync preference for each generated shelf.
    """
    __tablename__ = 'generated_shelf_kobo_sync'

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey('user.id'), nullable=False)
    source = Column(String, nullable=False)  # e.g., "authors", "series", "tags", "publishers", "languages"
    value = Column(String, nullable=False)   # e.g., "Brandon Sanderson", "The Expanse"
    kobo_sync = Column(Boolean, default=False)
    created = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    last_modified = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

    __table_args__ = (
        Index('ix_generated_shelf_kobo_sync_user_source_value', 'user_id', 'source', 'value', unique=True),
    )

    def __repr__(self):
        return f'<GeneratedShelfKoboSync user={self.user_id} source={self.source} value={self.value} sync={self.kobo_sync}>'


class HardcoverBookBlacklist(Base):
    """Track book-level blacklisting for hardcover sync features."""
    __tablename__ = 'hardcover_book_blacklist'

    id = Column(Integer, primary_key=True, autoincrement=True)
    book_id = Column(Integer, nullable=False, unique=True)  # Calibre book ID
    blacklist_annotations = Column(Boolean, default=False)  # Block annotation syncing
    blacklist_reading_progress = Column(Boolean, default=False)  # Block reading progress syncing

    def __repr__(self):
        return f'<HardcoverBookBlacklist book_id={self.book_id} annotations={self.blacklist_annotations} progress={self.blacklist_reading_progress}>'


# Updates the last_modified timestamp in the KoboReadingState table if any of its children tables are modified.
@event.listens_for(Session, 'before_flush')
def receive_before_flush(session, flush_context, instances):
    for change in itertools.chain(session.new, session.dirty):
        if isinstance(change, (ReadBook, KoboStatistics, KoboBookmark)):
            if change.kobo_reading_state:
                change.kobo_reading_state.last_modified = datetime.now(timezone.utc)
    # Maintain the last_modified_bit for the Shelf table.
    for change in itertools.chain(session.new, session.deleted):
        if isinstance(change, BookShelf):
            change.ub_shelf.last_modified = datetime.now(timezone.utc)


# Baseclass representing Downloads from autocaliweb in app.db
class Downloads(Base):
    __tablename__ = 'downloads'

    id = Column(Integer, primary_key=True)
    book_id = Column(Integer)
    user_id = Column(Integer, ForeignKey('user.id'))

    def __repr__(self):
        return '<Download %r' % self.book_id


class KOSyncProgress(Base):
    __tablename__ = 'kosync_progress'

    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey('user.id'), nullable=False)
    document = Column(String, nullable=False)
    progress = Column(String, nullable=False)
    percentage = Column(Float, nullable=False)
    device = Column(String, nullable=False)
    device_id = Column(String)
    timestamp = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

    def __repr__(self):
        return '<KOSyncProgress %r - %r>' % (self.user_id, self.document)



# Baseclass representing allowed domains for registration
class Registration(Base):
    __tablename__ = 'registration'

    id = Column(Integer, primary_key=True)
    domain = Column(String)
    allow = Column(Integer)

    def __repr__(self):
        return "<Registration('{0}')>".format(self.domain)


class RemoteAuthToken(Base):
    __tablename__ = 'remote_auth_token'

    id = Column(Integer, primary_key=True)
    auth_token = Column(String, unique=True)
    user_id = Column(Integer, ForeignKey('user.id'))
    verified = Column(Boolean, default=False)
    expiration = Column(DateTime)
    token_type = Column(Integer, default=0)

    def __init__(self):
        super().__init__()
        self.auth_token = (hexlify(os.urandom(4))).decode('utf-8')
        self.expiration = datetime.now() + timedelta(minutes=10)  # 10 min from now

    def __repr__(self):
        return '<Token %r>' % self.id


def filename(context):
    file_format = context.get_current_parameters()['format']
    if file_format == 'jpeg':
        return context.get_current_parameters()['uuid'] + '.jpg'
    else:
        return context.get_current_parameters()['uuid'] + '.' + file_format


def default_expiration():
    return datetime.now(timezone.utc) + timedelta(days=10)


class Thumbnail(Base):
    __tablename__ = 'thumbnail'

    id = Column(Integer, primary_key=True)
    entity_id = Column(Integer)
    uuid = Column(String, default=lambda: str(uuid.uuid4()), unique=True)
    format = Column(String, default='jpeg')
    type = Column(SmallInteger, default=constants.THUMBNAIL_TYPE_COVER)
    resolution = Column(SmallInteger, default=constants.COVER_THUMBNAIL_SMALL)
    filename = Column(String, default=filename)
    generated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    expiration = Column(DateTime, default=default_expiration)


# Add missing tables during migration of database
def add_missing_tables(engine, _session):
    if not engine.dialect.has_table(engine.connect(), "archived_book"):
        ArchivedBook.__table__.create(bind=engine)
    if not engine.dialect.has_table(engine.connect(), "thumbnail"):
        Thumbnail.__table__.create(bind=engine)
    # Indexes: keep thumbnail lookups fast even on large libraries.
    # (No Alembic here; create indexes opportunistically.)
    try:
        with engine.connect() as conn:
            conn.execute(text(
                "CREATE INDEX IF NOT EXISTS ix_thumbnail_lookup "
                "ON thumbnail (type, entity_id, resolution, format, expiration, generated_at, id)"
            ))
    except Exception:
        # Non-fatal: index creation can fail on read-only DBs.
        pass
    if not engine.dialect.has_table(engine.connect(), "kosync_progress"):
        KOSyncProgress.__table__.create(bind=engine)

    if not engine.dialect.has_table(engine.connect(), "kobo_tag_sync_state"):
        KoboTagSyncState.__table__.create(bind=engine)

    # Add missing columns to kobo_tag_sync_state table
    try:
        with engine.connect() as conn:
            # Check if sync_all_generated column exists
            result = conn.execute(text("PRAGMA table_info(kobo_tag_sync_state)"))
            columns = [row[1] for row in result.fetchall()]
            if "sync_all_generated" not in columns:
                conn.execute(text("ALTER TABLE kobo_tag_sync_state ADD COLUMN sync_all_generated BOOLEAN DEFAULT 0"))
                conn.commit()
    except Exception:
        # Non-fatal: DB might be read-only
        pass

    # Backfill missing shelf UUIDs (required for Kobo Collections IDs).
    try:
        shelves_missing_uuid = (
            _session.query(Shelf)
            .filter(or_(Shelf.uuid.is_(None), Shelf.uuid == ""))
            .all()
        )
        for shelf in shelves_missing_uuid or []:
            try:
                shelf.uuid = str(uuid.uuid4())
            except Exception:
                continue
        if shelves_missing_uuid:
            _session.commit()
    except Exception:
        # Non-fatal: DB might be read-only.
        try:
            _session.rollback()
        except Exception:
            pass


# migrate all settings missing in registration table
def migrate_registration_table(engine, _session):
    try:
        # Handle table exists, but no content
        cnt = _session.query(Registration).count()
        if not cnt:
            with engine.connect() as conn:
                trans = conn.begin()
                conn.execute(text("insert into registration (domain, allow) values('%.%',1)"))
                trans.commit()
    except exc.OperationalError:  # Database is not writeable
        print('Settings database is not writeable. Exiting...')
        sys.exit(2)


def migrate_user_session_table(engine, _session):
    try:
        _session.query(exists().where(User_Sessions.random)).scalar()
        _session.commit()
    except exc.OperationalError:  # Database is not compatible, some columns are missing
        with engine.connect() as conn:
            trans = conn.begin()
            conn.execute(text("ALTER TABLE user_session ADD column 'random' String"))
            conn.execute(text("ALTER TABLE user_session ADD column 'expiry' Integer"))
            trans.commit()

def migrate_user_table(engine, _session):
    with engine.connect() as conn:
        needed = [
            ('name', "VARCHAR(64) NOT NULL"),
            ('email', "VARCHAR(120) NOT NULL DEFAULT ''"),
            ('role', "SMALLINT NOT NULL DEFAULT 0"),
            ('password', "VARCHAR(255) NOT NULL"),
            ('kindle_mail', "VARCHAR(120) NOT NULL DEFAULT ''"),
            ('shelf', "INTEGER NOT NULL DEFAULT 0"),
            ('downloads', "INTEGER NOT NULL DEFAULT 0"),
            ('locale', "VARCHAR(2) NOT NULL DEFAULT 'en'"),
            ('sidebar_view', "INTEGER NOT NULL DEFAULT 1"),
            ('default_language', "VARCHAR(3) NOT NULL DEFAULT 'all'"),
            ('denied_tags', "VARCHAR(255) NOT NULL DEFAULT ''"),
            ('allowed_tags', "VARCHAR(255) NOT NULL DEFAULT ''"),
            ('denied_column_value', "VARCHAR(255) NOT NULL DEFAULT ''"),
            ('allowed_column_value', "VARCHAR(255) NOT NULL DEFAULT ''"),
            ('remote_auth_token', "INTEGER NOT NULL DEFAULT 0"),
            ('view_settings', "JSON NOT NULL DEFAULT '{}'"),
            ('kobo_only_shelves_sync', "INTEGER NOT NULL DEFAULT 0"),
            ('kobo_plus', "INTEGER NOT NULL DEFAULT 0"),
            ('kobo_overdrive', "INTEGER NOT NULL DEFAULT 0"),
            ('kobo_audiobooks', "INTEGER NOT NULL DEFAULT 0"),
            ('kobo_instapaper', "INTEGER NOT NULL DEFAULT 0"),
            ('kobo_sync_collections_mode', "VARCHAR(32) NOT NULL DEFAULT 'selected'"),
            ('kobo_generated_shelves_sync', "BOOLEAN NOT NULL DEFAULT 0"),
            ('kobo_generated_shelves_all_books', "BOOLEAN NOT NULL DEFAULT 0"),
            ('kobo_sync_empty_collections', "BOOLEAN NOT NULL DEFAULT 0"),
            ('kobo_sync_item_limit', "INTEGER NOT NULL DEFAULT 100"),
            ('hardcover_token', "VARCHAR(255) NOT NULL DEFAULT ''"),
            ('auto_send_enabled', "BOOLEAN NOT NULL DEFAULT 0"),
        ]
        for col_name, col_def in needed:
            exists = conn.execute(text("PRAGMA table_info(user)")).fetchall()
            if not any(row[1] == col_name for row in exists):
                conn.execute(text(f"ALTER TABLE user ADD COLUMN {col_name} {col_def}"))

def migrate_oauth_table(engine, _session):
    with engine.connect() as conn:
        needed = [
            ('id', "INTEGER PRIMARY KEY AUTOINCREMENT"),
            ('provider_name', "VARCHAR(255) NOT NULL"),
            ('oauth_client_id', "VARCHAR(255)"),
            ('oauth_client_secret', "VARCHAR(255)"),
            ('oauth_base_url', "VARCHAR(255)"),
            ('oauth_auth_url', "VARCHAR(255)"),
            ('oauth_token_url', "VARCHAR(255)"),
            ('oauth_userinfo_url', "VARCHAR(255)"),
            ('scope', "VARCHAR(255) NOT NULL DEFAULT 'openid profile email'"),
            ('username_mapper', "VARCHAR(255) NOT NULL DEFAULT 'preferred_username'"),
            ('email_mapper', "VARCHAR(255) NOT NULL DEFAULT 'email'"),
            ('login_button', "VARCHAR(255) NOT NULL DEFAULT 'OpenID Connect'"),
            ('metadata_url', "VARCHAR(255)"),
            ('active', "BOOLEAN NOT NULL DEFAULT 0"),
        ]
        for col_name, col_def in needed:
            exists = conn.execute(text("PRAGMA table_info(oauthProvider)")).fetchall()
            if not any(row[1] == col_name for row in exists):
                conn.execute(text(f"ALTER TABLE oauthProvider ADD COLUMN {col_name} {col_def}"))


# Migrate database to current version, has to be updated after every database change. Currently, migration from
# maybe 4/5 versions back to current should work.
# Migration is done by checking if relevant columns are existing, and then adding rows with SQL commands
def migrate_Database(_session):
    engine = _session.bind
    add_missing_tables(engine, _session)
    migrate_registration_table(engine, _session)
    migrate_user_session_table(engine, _session)
    migrate_user_table(engine, _session)
    migrate_oauth_table(engine, _session)


def clean_database(_session):
    # Remove expired remote login tokens
    now = datetime.now()
    try:
        _session.query(RemoteAuthToken).filter(now > RemoteAuthToken.expiration).\
            filter(RemoteAuthToken.token_type != 1).delete()
        _session.commit()
    except exc.OperationalError:  # Database is not writeable
        print('Settings database is not writeable. Exiting...')
        sys.exit(2)


# Save downloaded books per user in autocaliweb's own database
def update_download(book_id, user_id):
    check = session.query(Downloads).filter(Downloads.user_id == user_id).filter(Downloads.book_id == book_id).first()

    if not check:
        new_download = Downloads(user_id=user_id, book_id=book_id)
        session.add(new_download)
        try:
            session.commit()
        except exc.OperationalError:
            session.rollback()


# Delete non-existing downloaded books in autocaliweb's own database
def delete_download(book_id):
    session.query(Downloads).filter(book_id == Downloads.book_id).delete()
    try:
        session.commit()
    except exc.OperationalError:
        session.rollback()

# Generate user Guest (translated text), as anonymous user, no rights
def create_anonymous_user(_session):
    existing_guest = _session.query(User).filter(User.email == 'no@email').first()
    if existing_guest:
        log.info("Anonymous user already exists, skipping creation")
        return

    user = User()
    user.name = "Guest"
    user.email = 'no@email'
    user.role = constants.ROLE_ANONYMOUS
    user.password = ''

    _session.add(user)
    try:
        _session.commit()
    except Exception as e:
        _session.rollback()
        log.error_or_exception(e)


def generate_fips_safe_password_hash(password):
    try:
        return generate_password_hash(password)
    except ValueError as e:
        if "digest" not in str(e).lower():
            raise
        # FIPS fallback
        return generate_password_hash(
            password,
            method="pbkdf2:sha256",
            salt_length=16
        )


# Generate User admin with admin123 password, and access to everything
def create_admin_user(_session):
    user = User()
    user.name = "admin"
    user.email = "admin@example.org"
    user.role = constants.ADMIN_USER_ROLES
    user.sidebar_view = constants.ADMIN_USER_SIDEBAR

    user.password = generate_fips_safe_password_hash(constants.DEFAULT_PASSWORD)

    _session.add(user)
    try:
        _session.commit()
    except Exception:
        _session.rollback()
        log.error_or_exception(e)

def init_db_thread():
    global app_DB_path
    engine = create_engine('sqlite:///{0}'.format(app_DB_path), echo=False)

    Session = scoped_session(sessionmaker())
    Session.configure(bind=engine)
    return Session()


def init_db(app_db_path):
    # Open session for database connection
    global session
    global app_DB_path

    app_DB_path = app_db_path
    engine = create_engine('sqlite:///{0}'.format(app_db_path), echo=False)

    Session = scoped_session(sessionmaker())
    Session.configure(bind=engine)
    session = Session()

    if os.path.exists(app_db_path):
        Base.metadata.create_all(engine)
        migrate_Database(session)
        clean_database(session)
    else:
        Base.metadata.create_all(engine)
        create_admin_user(session)
        create_anonymous_user(session)

def password_change(user_credentials=None):
    if user_credentials:
        username, password = user_credentials.split(':', 1)
        user = session.query(User).filter(func.lower(User.name) == username.lower()).first()
        if user:
            if not password:
                print("Empty password is not allowed")
                sys.exit(4)
            try:
                from .helper import valid_password
                user.password = generate_password_hash(valid_password(password))
            except Exception:
                print("Password doesn't comply with password validation rules")
                sys.exit(4)
            if session_commit() == "":
                print("Password for user '{}' changed".format(username))
                sys.exit(0)
            else:
                print("Failed changing password")
                sys.exit(3)
        else:
            print("Username '{}' not valid, can't change password".format(username))
            sys.exit(3)


def get_new_session_instance():
    new_engine = create_engine('sqlite:///{0}'.format(app_DB_path), echo=False)
    new_session = scoped_session(sessionmaker())
    new_session.configure(bind=new_engine)

    atexit.register(lambda: new_session.remove() if new_session else True)

    return new_session


def dispose():
    global session

    old_session = session
    session = None
    if old_session:
        try:
            old_session.close()
        except Exception:
            pass
        if old_session.bind:
            try:
                old_session.bind.dispose()
            except Exception:
                pass

def session_commit(success=None, _session=None):
    s = _session if _session else session
    try:
        s.commit()
        if success:
            log.info(success)
    except (exc.OperationalError, exc.InvalidRequestError) as e:
        s.rollback()
        log.error_or_exception(e)
    return ""
