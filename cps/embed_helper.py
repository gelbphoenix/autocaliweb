# -*- coding: utf-8 -*-

# NOTE: This module uses a best-effort temp-copy strategy for Calibre's metadata.db when the
# library DB is mounted read-only. To avoid copying the DB on every export, we keep a small
# in-process cache keyed by (source mtime, source size) with a short TTL.

#  This file is part of the Calibre-Web (https://github.com/janeczku/calibre-web)
#    Copyright (C) 2024 OzzieIsaacs
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
import os
import shutil
import time
from uuid import uuid4

from . import config, logger
from .constants import SUPPORTED_CALIBRE_BINARIES
from .file_helper import get_temp_dir
from .subproc_wrapper import process_open

log = logger.create()

# -----------------------------------------------------------------------------
# Read-only Calibre DB export cache
# -----------------------------------------------------------------------------
# Cache the most recent writable copy of metadata.db so repeated exports during a short window
# don't re-copy the DB on every request.
_DB_CACHE_TTL_SECONDS = 60
_db_copy_cache = {
    "src_db": None,  # type: str | None
    "src_mtime": None,  # type: float | None
    "src_size": None,  # type: int | None
    "dst_db": None,  # type: str | None
    "created_at": 0.0,  # type: float
}


def _path_is_writable(path: str) -> bool:
    """
    Return True if `path` is writable (best-effort). If `path` is a directory, we try to create a
    tiny temp file inside it. If it's a file, we try to open it for append.
    """
    try:
        if os.path.isdir(path):
            test_path = os.path.join(path, f".autocaliweb-write-test-{uuid4()}")
            with open(test_path, "w", encoding="utf-8") as f:
                f.write("1")
            os.remove(test_path)
            return True
        # file
        with open(path, "a", encoding="utf-8"):
            pass
        return True
    except Exception:
        return False


def _ensure_writable_calibre_db_env(my_env: dict) -> None:
    """
    If the Calibre DB is mounted read-only but Calibre CLI needs to touch it, copy metadata.db into a
    writable temp dir and point Calibre at the copy via CALIBRE_OVERRIDE_DATABASE_PATH.

    This only activates when:
      - config.config_calibre_split is enabled, AND
      - metadata.db exists at the expected location, AND
      - the DB path is not writable.

    To reduce repeated copies, we reuse a cached temp copy for a short TTL as long as the source
    metadata.db hasn't changed (mtime + size).
    """
    try:
        if not config.config_calibre_split:
            return

        calibre_dir = config.config_calibre_dir
        if not calibre_dir:
            return

        src_db = os.path.join(calibre_dir, "metadata.db")
        if not os.path.exists(src_db):
            return

        # If the DB file itself is writable, use it directly.
        if _path_is_writable(src_db):
            my_env["CALIBRE_OVERRIDE_DATABASE_PATH"] = src_db
            return

        try:
            st = os.stat(src_db)
            src_mtime = float(getattr(st, "st_mtime", 0.0) or 0.0)
            src_size = int(getattr(st, "st_size", 0) or 0)
        except Exception:
            src_mtime = 0.0
            src_size = 0

        now = time.time()
        cached_src = _db_copy_cache.get("src_db")
        cached_mtime = _db_copy_cache.get("src_mtime")
        cached_size = _db_copy_cache.get("src_size")
        cached_dst = _db_copy_cache.get("dst_db")
        cached_created = float(_db_copy_cache.get("created_at") or 0.0)

        cache_fresh = (now - cached_created) <= _DB_CACHE_TTL_SECONDS
        cache_matches_source = (
            cached_src == src_db
            and cached_mtime == src_mtime
            and cached_size == src_size
        )
        if (
            cache_fresh
            and cache_matches_source
            and cached_dst
            and os.path.exists(cached_dst)
        ):
            my_env["CALIBRE_OVERRIDE_DATABASE_PATH"] = cached_dst
            return

        tmp_dir = get_temp_dir()
        tmp_db_dir = os.path.join(tmp_dir, "calibre-db-tmp")
        os.makedirs(tmp_db_dir, exist_ok=True)
        dst_db = os.path.join(tmp_db_dir, f"metadata-{uuid4()}.db")

        shutil.copy2(src_db, dst_db)

        # Best-effort cleanup of the previous cached file to avoid unbounded temp growth.
        try:
            if cached_dst and cached_dst != dst_db and os.path.exists(cached_dst):
                os.remove(cached_dst)
        except Exception:
            pass

        _db_copy_cache["src_db"] = src_db
        _db_copy_cache["src_mtime"] = src_mtime
        _db_copy_cache["src_size"] = src_size
        _db_copy_cache["dst_db"] = dst_db
        _db_copy_cache["created_at"] = now

        my_env["CALIBRE_OVERRIDE_DATABASE_PATH"] = dst_db
        log.info(
            "Calibre DB is read-only; using cached temp metadata.db copy for export: %s",
            dst_db,
        )
    except Exception as e:
        # Best-effort only; keep original behavior if anything goes wrong.
        log.debug("Failed to set up temp Calibre DB copy for export: %s", e)
        return


def do_calibre_export(book_id, book_format):
    try:
        quotes = [4, 6]
        tmp_dir = get_temp_dir()
        calibredb_binarypath = get_calibre_binarypath("calibredb")
        temp_file_name = str(uuid4())
        my_env = os.environ.copy()

        # If the library DB is mounted read-only, Calibre CLI may still attempt internal writes.
        # In that case, use a temp copy of metadata.db (only when RO is detected).
        _ensure_writable_calibre_db_env(my_env)

        library_path = config.get_book_path()
        opf_command = [
            calibredb_binarypath,
            "export",
            "--dont-write-opf",
            "--with-library",
            library_path,
            "--to-dir",
            tmp_dir,
            "--formats",
            book_format,
            "--template",
            "{}".format(temp_file_name),
            str(book_id),
        ]
        p = process_open(opf_command, quotes, my_env)
        _, err = p.communicate()
        if err:
            log.error("Metadata embedder encountered an error: %s", err)

        export_dir = os.path.join(tmp_dir, temp_file_name)
        if os.path.isdir(export_dir):
            # Look for the book file with the specified format
            for filename in os.listdir(export_dir):
                if filename.lower().endswith("." + book_format.lower()):
                    # Found the exported file - return the directory and the filename without extension
                    actual_filename = os.path.splitext(filename)[0]
                    return export_dir, actual_filename

            log.warning(
                f"No {book_format} file found in export directory: {export_dir}"
            )
        else:
            # No subdirectory - look for files directly in tmp_dir
            for filename in os.listdir(tmp_dir):
                if filename.lower().endswith("." + book_format.lower()):
                    actual_filename = os.path.splitext(filename)[0]
                    return tmp_dir, actual_filename

            log.warning(f"No {book_format} file found in {tmp_dir}")

        return tmp_dir, temp_file_name
    except OSError as ex:
        # ToDo real error handling
        log.error_or_exception(ex)
        return None, None


def get_calibre_binarypath(binary):
    binariesdir = config.config_binariesdir
    if binariesdir:
        try:
            return os.path.join(binariesdir, SUPPORTED_CALIBRE_BINARIES[binary])
        except KeyError as ex:
            log.error(
                "Binary not supported by Autocaliweb: %s",
                SUPPORTED_CALIBRE_BINARIES[binary],
            )
            pass
    return ""
