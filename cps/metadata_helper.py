# -*- coding: utf-8 -*-
# Calibre-Web Automated – fork of Calibre-Web
# Copyright (C) 2018-2025 Calibre-Web contributors
# Copyright (C) 2024-2025 Calibre-Web Automated contributors
# Copyright (C) 2025 Autocaliweb contributors
# SPDX-License-Identifier: GPL-3.0-or-later
# See CONTRIBUTORS for full list of authors.

import json
import os
from typing import Optional, List, Dict
from sqlalchemy.sql.expression import func

from cps import logger, calibre_db, db, constants, config, cli_param
from cps.search_metadata import cl as metadata_providers
import sys
INSTALL_BASE_DIR = os.environ.get("ACW_INSTALL_DIR", "/app/autocaliweb")
SCRIPTS_PATH = os.path.join(INSTALL_BASE_DIR, "scripts")
sys.path.insert(1, SCRIPTS_PATH)
from acw_db import ACW_DB

# Ensure CalibreDB is configured
if not hasattr(calibre_db, '_session') or calibre_db._session is None:
    db.CalibreDB.update_config(config, config.config_calibre_dir, cli_param.settings_path)

log = logger.create()

def fetch_and_apply_metadata(book_id: int, user_enabled: bool = False) -> bool:
    """
    Fetch metadata for a newly ingested book and apply it if settings allow.

    Args:
        book_id: The ID of the book to fetch metadata for
        user_enabled: Deprecated parameter - metadata fetching is now admin-controlled only

    Returns:
        bool: True if metadata was successfully fetched and applied, False otherwise
    """
    from cps import app  # Import at function level to avoid circular imports
    # The function msut work within the Flask application's request-response cycle
    with app.app_context():
        try:
            # Check global settings
            acw_db = ACW_DB()
            acw_settings = acw_db.get_acw_settings()

            if not acw_settings.get('auto_metadata_fetch_enabled', False):
                log.debug("Auto metadata fetch disabled by administrator")
                return False

            # Get the book - needs app context
            # Use the imported singleton instead of creating new instance
            book = calibre_db.get_book(book_id)
            if not book:
                log.error(f"Book with ID {book_id} not found")
                return False

            # Create search query from book title and author
            search_query = book.title
            if book.authors:
                author_names = [author.name for author in book.authors]
                search_query += " " + " ".join(author_names)

            log.info(f"Fetching metadata for: {search_query}")

            # Get provider hierarchy
            try:
                provider_hierarchy = json.loads(acw_settings.get('metadata_provider_hierarchy', '["google","douban","dnb","ibdb","comicvine"]'))
            except (json.JSONDecodeError, TypeError):
                provider_hierarchy = ["google", "douban", "dnb", "ibdb", "comicvine"]

            # Try each provider in order
            metadata_found = False
            for provider_id in provider_hierarchy:
                try:
                    # Find the provider
                    provider = None
                    for p in metadata_providers:
                        if p.__id__ == provider_id:
                            provider = p
                            break

                    if not provider or not provider.active:
                        continue

                    log.debug(f"Trying metadata provider: {provider.__name__}")

                    # Search for metadata
                    results = provider.search(search_query, "", "en")
                    if not results or len(results) == 0:
                        continue

                    # Use the first result
                    metadata = results[0]

                    # Apply metadata to book
                    if _apply_metadata_to_book(book, metadata, acw_settings):
                        log.info(f"Successfully applied metadata from {provider.__name__} for book: {book.title}")
                        metadata_found = True
                        break

                except Exception as e:
                    log.warning(f"Error fetching metadata from provider {provider_id}: {e}")
                    continue

            calibre_db.session.close()
            return metadata_found

        except Exception as e:
            log.error(f"Error in fetch_and_apply_metadata: {e}")
            return False


def _apply_metadata_to_book(book, metadata, acw_settings: dict) -> bool:
    """
    Apply fetched metadata to a book record.

    Args:
        book: The book database record
        metadata: The metadata record from provider
        calibre_db: Database instance

    Returns:
        bool: True if metadata was successfully applied
    """
    try:
        # Register custom SQLite functions (including title_sort)
        calibre_db.create_functions(config)
        # Get CWA settings to check smart application preference
        # acw_db = ACW_DB() # no need for a new instance
        # acw_settings = acw_db.get_acw_settings() # use passed acw_settings
        use_smart_application = acw_settings.get('auto_metadata_smart_application', False)

        updated = False

        # Update title - smart mode: only if longer, normal mode: always replace
        if metadata.title and metadata.title.strip():
            if use_smart_application:
                if len(metadata.title.strip()) > len(book.title.strip()):
                    book.title = metadata.title.strip()
                    updated = True
            else:
                book.title = metadata.title.strip()
                updated = True

        # Update authors - always update if available (both modes)
        if metadata.authors and len(metadata.authors) > 0:
            try:
                # Clear existing authors
                book.authors.clear()
                for author_name in metadata.authors:
                    if author_name and author_name.strip():
                        author = calibre_db.session.query(db.Authors).filter(
                            func.lower(db.Authors.name).ilike(author_name.strip())
                        ).first()
                        if not author:
                            author = db.Authors(name=author_name.strip(), sort=author_name.strip())
                            calibre_db.session.add(author)
                        book.authors.append(author)
                calibre_db.session.flush()  # Flush to catch errors early
                updated = True
            except Exception as e:
                log.warning(f"Error updating authors: {e}")
                calibre_db.session.rollback()
        # Update description - smart mode: only if longer, normal mode: always replace
        if metadata.description and metadata.description.strip():
            try:
                current_description = book.comments[0].text if book.comments else ""
                if use_smart_application:
                    if len(metadata.description.strip()) > len(current_description):
                        if book.comments:
                            book.comments[0].text = metadata.description.strip()
                        else:
                            comment = db.Comments(comment=metadata.description.strip(), book=book.id)
                            calibre_db.session.add(comment)
                        updated = True
                else:
                    if book.comments:
                        book.comments[0].text = metadata.description.strip()
                    else:
                        comment = db.Comments(comment=metadata.description.strip(), book=book.id)
                        calibre_db.session.add(comment)
                    updated = True
                calibre_db.session.flush()
            except Exception as e:
                log.warning(f"Error updating description: {e}")
                calibre_db.session.rollback()
        # Update publisher - smart mode: only if current is empty, normal mode: always replace
        if metadata.publisher and metadata.publisher.strip():
            if use_smart_application:
                if not book.publishers or len(book.publishers) == 0:
                    publisher = calibre_db.session.query(db.Publishers).filter(
                        func.lower(db.Publishers.name) == metadata.publisher.strip().lower()
                    ).first()
                    if not publisher:
                        publisher = db.Publishers(name=metadata.publisher.strip())
                        calibre_db.session.add(publisher)
                        try:
                            calibre_db.session.flush()
                        except Exception as e:
                            log.warning(f"Error creating publisher: {e}")
                            calibre_db.session.rollback()
                    # Update book's publisher
                    if len(book.publishers) == 0 or book.publishers[0].name != publisher.name:
                        book.publishers = [publisher]
                        updated = True

            else:
                # Clear existing publishers and add new one
                book.publishers.clear()
                publisher = calibre_db.session.query(db.Publishers).filter(
                    func.lower(db.Publishers.name) == metadata.publisher.strip().lower()
                ).first()
                if not publisher:
                    publisher = db.Publishers(name=metadata.publisher.strip())
                    calibre_db.session.add(publisher)
                book.publishers = [publisher]
                updated = True

        # Update tags if available (both modes)
        if hasattr(metadata, 'tags') and metadata.tags:
            for tag_name in metadata.tags:
                if tag_name and tag_name.strip():
                    # Check if tag exists
                    stored_tag = calibre_db.session.query(db.Tags).filter(
                        func.lower(db.Tags.name) == tag_name.lower()
                    ).first()

                    if not stored_tag:
                        # Create new tag
                        stored_tag = db.Tags(tag_name)
                        calibre_db.session.add(stored_tag)
                        try:
                            calibre_db.session.flush()
                        except Exception as e:
                            log.warning(f"Error creating tag: {e}")
                            calibre_db.session.rollback()

                    # Add tag to book if not already present
                    if stored_tag not in book.tags:
                        book.tags.append(stored_tag)
                        updated = True

        # Update series if available (both modes)
        if hasattr(metadata, 'series') and metadata.series and metadata.series.strip():
            series = calibre_db.session.query(db.Series).filter(
                func.lower(db.Series.name) == metadata.series.strip().lower()
            ).first()
            if not series:
                series = db.Series(name=metadata.series.strip(), sort=metadata.series.strip())
                calibre_db.session.add(series)
            book.series.clear()
            book.series.append(series)

            # Set series index if available
            if hasattr(metadata, 'series_index') and metadata.series_index:
                try:
                    book.series_index = float(metadata.series_index)
                except (ValueError, TypeError):
                    book.series_index = 1.0
            updated = True

        # Update published date if available (both modes)
        if hasattr(metadata, 'publishedDate') and metadata.publishedDate:
            try:
                from datetime import datetime
                if isinstance(metadata.publishedDate, str):
                    # Try to parse various date formats
                    for fmt in ['%Y-%m-%d', '%Y-%m', '%Y']:
                        try:
                            book.pubdate = datetime.strptime(metadata.publishedDate, fmt).date()
                            updated = True
                            break
                        except ValueError:
                            continue
                elif hasattr(metadata.publishedDate, 'date'):
                    book.pubdate = metadata.publishedDate.date()
                    updated = True
            except Exception as e:
                log.warning(f"Error parsing published date: {e}")

        # Update rating if available (both modes)
        if hasattr(metadata, 'rating') and metadata.rating:
            try:
                rating_value = float(metadata.rating)
                if 0 <= rating_value <= 10:  # Calibre uses 0-10 scale
                    if book.ratings:
                        book.ratings[0].rating = int(rating_value * 2)  # Convert to Calibre's 0-10 scale
                    else:
                        rating = db.Ratings(rating=int(rating_value * 2))
                        calibre_db.session.add(rating)
                        book.ratings = [rating]
                    updated = True
            except (ValueError, TypeError):
                pass

        # Update identifiers if available (both modes)
        if hasattr(metadata, 'identifiers') and metadata.identifiers:
            for identifier_type, identifier_value in metadata.identifiers.items():
                if identifier_type and identifier_value:
                    # Check if identifier already exists
                    existing = False
                    for identifier in book.identifiers:
                        if identifier.type == identifier_type:
                            identifier.val = identifier_value
                            existing = True
                            break
                    if not existing:
                        new_identifier = db.Identifiers(identifier_value, identifier_type, book.id)
                        calibre_db.session.add(new_identifier)
                        book.identifiers.append(new_identifier)
                    updated = True

        # Handle cover image - with resolution checking
        if hasattr(metadata, 'cover') and metadata.cover:
            try:
                import requests
                from io import BytesIO
                from PIL import Image as PILImage

                # Download the cover image
                response = requests.get(metadata.cover, timeout=10)
                if response.status_code == 200:
                    # Get current cover path
                    book_path = os.path.join(config.get_book_path(), book.path)
                    cover_path = os.path.join(book_path, 'cover.jpg')

                    # Check if we should replace the cover
                    should_replace = False

                    if use_smart_application:
                        # Smart mode: only replace if new cover has higher resolution
                        if os.path.exists(cover_path):
                            try:
                                # Get current cover dimensions
                                with PILImage.open(cover_path) as current_img:
                                    current_pixels = current_img.width * current_img.height

                                # Get new cover dimensions
                                new_img_data = BytesIO(response.content)
                                with PILImage.open(new_img_data) as new_img:
                                    new_pixels = new_img.width * new_img.height

                                # Replace if new cover has more pixels
                                if new_pixels > current_pixels:
                                    should_replace = True
                                    log.debug(f"New cover has higher resolution ({new_pixels} vs {current_pixels} pixels)")
                            except Exception as e:
                                log.warning(f"Error comparing cover resolutions: {e}")
                                should_replace = False
                        else:
                            # No existing cover, add the new one
                            should_replace = True
                    else:
                        # Normal mode: always replace
                        should_replace = True

                    if should_replace:
                        # Ensure book directory exists
                        os.makedirs(book_path, exist_ok=True)

                        # Save the new cover
                        with open(cover_path, 'wb') as f:
                            f.write(response.content)

                        # Mark metadata as dirty so Calibre knows to update
                        calibre_db.set_metadata_dirty(book.id)

                        log.info(f"Successfully updated cover for book {book.id}")
                        updated = True

            except requests.RequestException as e:
                log.warning(f"Error downloading cover image: {e}")
            except Exception as e:
                log.warning(f"Error saving cover image: {e}")

        if updated:
            try:
                calibre_db.session.commit()
                return True
            except Exception as e:
                log.error(f"Error committing metadata changes: {e}")
                calibre_db.session.rollback()
                return False
        return False

    except Exception as e:
        log.error(f"Error applying metadata to book {getattr(book, 'id', 'unknown')}: {e}")
        calibre_db.session.rollback()
        return False
