# -*- coding: utf-8 -*-

#  This file is part of the Calibre-Web (https://github.com/janeczku/calibre-web)
#    Copyright (C) 2018-2019 OzzieIsaacs, pwr
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

from datetime import datetime
import requests
import time

from .. import logger, constants

log = logger.create()

GRAPHQL_ENDPOINT = "https://api.hardcover.app/v1/graphql"

USER_BOOK_FRAGMENT = """
    fragment userBookFragment on user_books {
        id
        status_id
        book_id
        book {
            slug
            title
        }
        edition  {
            id
            pages
        }
        user_book_reads(order_by: {started_at: desc}, where: {finished_at: {_is_null: true}}) {
            id
            started_at
            finished_at
            edition_id
            progress_pages
        }
    }"""

_AUTHORS_CACHE = {}
_CACHE_TIMEOUT = 167 * 60 * 60  # 167 hours (in seconds)
_AUTHORS_BOOKS_CACHE = {}

def escape_md(text):
    """Escape markdown special characters to prevent injection."""
    if not text:
        return text
    
    special_chars = ['\\', '`', '*', '_', '{', '}', '[', ']', '(', ')', '#', '+', '-', '.', '!', '|']
    
    for char in special_chars:
        text = text.replace(char, '\\' + char)
    
    return text

class HardcoverClient:
    def __init__(self, token):
        self.endpoint = GRAPHQL_ENDPOINT

        self.headers = {
            "Content-Type": "application/json",
            "Authorization" : f"Bearer {token}",
            "User-Agent": constants.USER_AGENT,
        }
        self.privacy = self.get_privacy()
        
    def get_privacy(self):
        query = """
            {
                me {
                    account_privacy_setting_id
                }
            }"""
        response = self.execute(query)
        return (response.get("me")[0] or [{}]).get("account_privacy_setting_id", 1)

    def get_user_book(self, ids):
        if not ids or not any(key in self.parse_identifiers(ids) for key in ["hardcover-edition", "hardcover-id", "hardcover"]):
            return None

        query = ""
        variables = {}
        if "hardcover-edition" in ids: 
            query = """
                query ($query: Int) {
                    me {
                        user_books(where:  {edition_id: {_eq: $query}}) {
                            ...userBookFragment
                        }
                    }
                }"""
            variables["query"] = ids["hardcover-edition"]
        elif "hardcover-id" in ids:
            query = """
                query ($query: Int) {
                    me {
                        user_books(where: {book: {id: {_eq: $query}}}) {
                            ...userBookFragment
                        }
                    }
                }"""
            variables["query"] = ids["hardcover-id"]
        elif "hardcover" in ids:
            query = """
                query ($slug: String!) {
                    me {
                        user_books(where: {book: {slug: {_eq: $slug}}}) {
                            ...userBookFragment
                        }
                    }
                }"""
            variables["slug"] = ids["hardcover"]
        query += USER_BOOK_FRAGMENT
        response = self.execute(query, variables)
        return next(iter(response.get("me")[0].get("user_books")), None)
        
    def update_reading_progress(self, identifiers, progress_percent):
        ids = self.parse_identifiers(identifiers)
        if len(ids) != 0:
            book = self.get_user_book(ids)
            # Book doesn't exist, add it in Reading status
            if not book: 
                book = self.add_book(ids, status=2)
                log.info("Added book %s to Hardcover in 'Reading' status", book.get("book", {}).get("title"))
            # Edge case: if book doesn't exist and add_book failed to add it
            if book is None:
                print(f"Warning: Could not find book with identifiers {ids} for progress update. Skipping.")
                return # Exit early if the book object is None
            # Book is either WTR or Read, and we aren't finished reading
            if book.get("status_id") != 2 and progress_percent != 100: 
                book = self.change_book_status(book, 2)
                log.info("Changed book status to 'Reading' for book %s", book.get("book", {}).get("title"))
            # Book is already marked as read, and we are also done
            if book.get("status_id") == 3 and progress_percent == 100: 
                log.info("Book %s is already marked as 'Read'. No update needed.", book.get("book", {}).get("title"))
                return
            pages = book.get("edition",{}).get("pages",0)
            if pages:
                pages_read = round(pages * (progress_percent / 100))
                read = next(iter(book.get("user_book_reads")),None)
                if not read:
                    read = self.add_read(book, pages_read)
                else:
                    mutation = """
                    mutation ($readId: Int!, $pages: Int, $editionId: Int, $startedAt: date, $finishedAt: date) {
                        update_user_book_read(id: $readId, object: {
                            progress_pages: $pages,
                            edition_id: $editionId,
                            started_at: $startedAt,
                            finished_at: $finishedAt
                        }) {
                            id
                        }
                    }""" 
                    variables = {
                        "readId": int(read.get("id")),
                        "pages": pages_read,
                        "editionId": int(book.get("edition").get("id")),
                        "startedAt":read.get("started_at",datetime.now().strftime("%Y-%m-%d")),
                        "finishedAt": datetime.now().strftime("%Y-%m-%d") if progress_percent == 100 else None
                    }
                    if progress_percent == 100:
                        self.change_book_status(book, 3)
                        log.info("Changed book status to 'Read' for book %s", book.get("book", {}).get("title"))
                    self.execute(query=mutation, variables=variables)
                    log.info("Updated reading progress to %d%% for book %s", progress_percent, book.get("book", {}).get("title"))
            return
        else:
            return
    
    def change_book_status(self, book, status):
        mutation = """
            mutation ($id:Int!, $status_id: Int!) {
                update_user_book(id: $id, object: {status_id: $status_id}) {
                    error
                    user_book {
                        ...userBookFragment
                    }
                }
            }""" + USER_BOOK_FRAGMENT
        variables = {
            "id":book.get("id"),
            "status_id":status
        }
        response = self.execute(query=mutation, variables=variables)
        return response.get("update_user_book",{}).get("user_book",{})
    
    def add_journal_entry(self, identifiers, note_text, progress_percent=None, progress_page=None, highlighted_text=None):
        """
        Add a journal entry (reading note) to Hardcover.
        
        Args:
            identifiers: Book identifiers (hardcover-id, hardcover-edition, isbn)
            note_text: The note text to add
            progress_percent: Optional reading progress (0-100)
            highlighted_text: Optional highlighted quote
        
        Returns:
            Response from Hardcover API or None if failed
        """
        ids = self.parse_identifiers(identifiers)
        if len(ids) == 0:
            log.warning("No valid Hardcover identifiers found")
            return None

        book = self.get_user_book(ids)
        if not book:
            log.warning("Book not found on Hardcover, cannot add journal entry")
            return None

        user_book_id = book.get("book_id")
        if not user_book_id:
            log.warning("No user_book_id found")
            return None

        # Combine highlighted text and note
        # Escape markdown special characters to prevent injection
        journal_text = ""
        if highlighted_text:
            escaped_highlight = escape_md(highlighted_text)
            if note_text:
                escaped_note = escape_md(note_text)
                journal_text = f'> {escaped_highlight}' + '\n\n -- ' + escaped_note
            else:
                journal_text = f'> {escaped_highlight}'
        elif note_text:
            # This shouldn't happen but just in case
            journal_text = escape_md(note_text)
        else:
            log.warning("No text provided for journal entry")
            return None

        # Calculate page number and prepare metadata if progress is provided
        metadata = {}
        if progress_percent is not None or progress_page is not None:
            pages = book.get("edition", {}).get("pages", 0)
            page_number = progress_page if progress_page else round(pages * (progress_percent / 100))
            page_percent = round ((page_number / pages) * 100, 2) if pages else None
            percent = round(progress_percent, 2) if progress_percent is not None else page_percent
            # Match Hardcover's web UI metadata structure
            metadata["position"] = {
                "type": "pages",
                "value": page_number,
                "percent": percent,
                "possible": pages
            }
            log.info(f"Calculated page {page_number} from {progress_percent:.1f}% of {pages} pages")

        mutation = """
            mutation ($bookId: Int!, $entry: String!, $event: String!, $privacySettingId: Int!, $editionId: Int, $actionAt: date, $tags: [BasicTag]!, $metadata: jsonb) {
                insert_reading_journal(object: {
                    book_id: $bookId,
                    entry: $entry,
                    event: $event,
                    privacy_setting_id: $privacySettingId,
                    edition_id: $editionId,
                    action_at: $actionAt,
                    tags: $tags,
                    metadata: $metadata
                }) {
                    errors
                    id
                    reading_journal {
                        id
                        entry
                    }
                }
            }"""
        variables = {
            "bookId": int(book.get("book_id")),
            "entry": journal_text,
            # quote or note in Hardcover, 
            "event": "note" if note_text else "quote",
            "privacySettingId": self.privacy,
            "editionId": int(book.get("edition", {}).get("id")) if book.get("edition") else None,
            "tags": [
                {"tag": "CWA", "category": "general", "spoiler": False},
                {"tag": "Kobo", "category": "general", "spoiler": False}
            ],
            "metadata": metadata if metadata else None
        }

        try:
            response = self.execute(query=mutation, variables=variables)

            if not response:
                log.error("Empty response from Hardcover API")
                return None

            errors = response.get("insert_reading_journal", {}).get("errors")
            if errors:
                log.error(f"Hardcover journal entry errors: {errors}")
                return None

            journal_entry = response.get("insert_reading_journal", {}).get("reading_journal")
            if not journal_entry:
                log.error("No journal entry returned in response")
                return None

            return journal_entry
        except requests.exceptions.Timeout as e:
            log.error(f"Timeout syncing to Hardcover: {e}")
            return None
        except requests.exceptions.RequestException as e:
            log.error(f"Network error syncing to Hardcover: {e}")
            return None
        except (KeyError, AttributeError) as e:
            log.error(f"Malformed Hardcover API response: {e}")
            return None
        except Exception as e:
            log.error(f"Unexpected error adding journal entry: {e}")
            import traceback
            log.error(traceback.format_exc())
            return None


    def update_journal_entry(self, journal_id: int, note_text: str | None = None, highlighted_text: str | None = None):
        """
        Update a journal entry (reading note) in Hardcover.
        
        Args:
            journal_id: The ID of the journal entry to update
            note_text: The note text to update
            highlighted_text: The highlighted text to update
        """
        # Combine highlighted text and note
        # Escape markdown special characters to prevent injection
        journal_text = ""
        if highlighted_text:
            escaped_highlight = escape_md(highlighted_text)
            if note_text:
                escaped_note = escape_md(note_text)
                journal_text = f'> {escaped_highlight}' + '\n\n -- ' + escaped_note
            else:
                journal_text = f'> {escaped_highlight}'
        elif note_text:
            # This shouldn't happen but just in case
            journal_text = escape_md(note_text)
        else:
            log.warning("No text provided for journal entry")
            return None
        mutation = """
            mutation ($journalId: Int!, $entry: String!, $event: String!) {
                update_reading_journal(id: $journalId, object: {
                    entry: $entry,
                    event: $event,
                }) {
                    errors
                    id
                }
            }"""
        variables = {
            "journalId": journal_id,
            "entry": journal_text,
            # quote or note in Hardcover, 
            "event": "note" if note_text else "quote",
        }
        try:
            response = self.execute(query=mutation, variables=variables)

            if not response:
                log.error("Empty response from Hardcover API")
                return None

            errors = response.get("update_reading_journal", {}).get("errors")
            if errors:
                log.error(f"Hardcover journal entry errors: {errors}")
                return None

            journal_entry = response.get("update_reading_journal", {}).get("reading_journal")
            if not journal_entry:
                log.error("No journal entry returned in response")
                return None

            return journal_entry
        except requests.exceptions.Timeout as e:
            log.error(f"Timeout syncing to Hardcover: {e}")
            return None
        except requests.exceptions.RequestException as e:
            log.error(f"Network error syncing to Hardcover: {e}")
            return None
        except (KeyError, AttributeError) as e:
            log.error(f"Malformed Hardcover API response: {e}")
            return None
        except Exception as e:
            log.error(f"Unexpected error adding journal entry: {e}")
            import traceback
            log.error(traceback.format_exc())
            return None

    def delete_journal_entry(self, journal_id: int):
        mutation = """
            mutation ($journal_id: Int!) {
                delete_reading_journal(id: $journal_id) {
                    id
                }
            }"""
        variables = {"journal_id": journal_id}
        response = self.execute(query=mutation, variables=variables)
        return response.get("delete_reading_journal", {}).get("id")
    
    def add_book(self, identifiers, status=1):
        ids = self.parse_identifiers(identifiers)
        mutation = """     
            mutation ($object: UserBookCreateInput!) {
                insert_user_book(object: $object) {
                    error
                    user_book {
                        ...userBookFragment
                    }
                }
            }""" + USER_BOOK_FRAGMENT
        variables = {
            "object": {
                "book_id":int(ids.get("hardcover-id")),
                "edition_id":int(ids.get("hardcover-edition")) if ids.get("hardcover-edition") else None,
                "status_id": status,
                "privacy_setting_id": self.privacy
            }
        }
        response = self.execute(query=mutation, variables=variables)
        return response.get("insert_user_book",{}).get("user_book",{})

    def add_read(self, book, pages=0):
        mutation = """     
            mutation ($id: Int!, $pages: Int, $editionId: Int, $startedAt: date) {
                insert_user_book_read(user_book_id: $id, user_book_read: {
                    progress_pages: $pages,
                    edition_id: $editionId,
                    started_at: $startedAt,
                }) {
                    error
                    user_book_read {
                        id
                        started_at
                        finished_at
                        edition_id
                        progress_pages
                    }
                }
            }""" 
        variables = {
            "id":int(book.get("id")),
            "editionId":int(book.get("edition").get("id")) if book.get("edition").get("id") else None,
            "pages": pages,
            "startedAt": datetime.now().strftime("%Y-%m-%d")
        }
        response = self.execute(query=mutation, variables=variables)
        return response.get("insert_user_book_read").get("user_book_read")

    def parse_identifiers(self, identifiers):
        if not isinstance(identifiers, dict):
            identifiers = {id.type:id.val for id in identifiers if id.type.startswith("hardcover") or id.type == "isbn"}
        else:
            identifiers = {t:v for t, v in identifiers.items() if t.startswith("hardcover") or t == "isbn"}

        if "hardcover-id" not in identifiers:
            slug = identifiers.get("hardcover")
            isbn = identifiers.get("isbn")
            if not slug:
                log.error("No hardcover slug in identifiers: %s", identifiers)
                return identifiers
            book_id, edition_id = self.get_book_id(slug, isbn)
            identifiers["hardcover-id"] = book_id
            if edition_id is not None:
                identifiers["hardcover-edition"] = edition_id

        log.debug("Parsed identifiers: %s", identifiers)
        return identifiers
    
    def get_author_info(self, author):
        author_info = _AUTHORS_CACHE.get(author, None)
        if author_info:
            if time.time() < author_info["_timestamp"] + _CACHE_TIMEOUT:
                return author_info["data"]
            del _AUTHORS_CACHE[author]

        query = """
        query GetAuthorInfo($author: String!) {
            authors(where: {slug: {_eq: $author}}) {
                bio
                name
                cached_image
                slug
            }
        }"""
        variables = {
            "author": author
        }
        response = self.execute(query, variables)
        author_info = next(iter(response.get("authors")), None)

        if author_info:
            _AUTHORS_CACHE[author] = {
                "data": author_info,
                "_timestamp": time.time(),
            }

        return author_info
    
    def get_other_author_books(self, author, library_books):
        cached_books = _AUTHORS_BOOKS_CACHE.get(author, None)
        if cached_books:
            if time.time() < cached_books["_timestamp"] + _CACHE_TIMEOUT:
                return cached_books["data"]
            del _AUTHORS_BOOKS_CACHE[author]

        query = """
        query otherBooksFromAuthor($author: String!) {
            authors(where: {slug: {_eq: $author}}) {
                contributions(where: {contributable_type: {_eq: "Book"}}, order_by: {book: {title: asc}}) {
                    book {
                        title
                        slug
                        image {
                            url
                        }
                    }
                }
            }
        }"""
        variables = {
            "author": author
        }
        response = self.execute(query, variables)
        author_res = response.get("authors", [])
        if not author_res:
            return []
        
        books = []
        for contribution in author_res[0].get("contributions", []):
            book = contribution.get("book", {})
            if book.get("slug") and book["slug"] not in library_books:
                books.append(book)

        _AUTHORS_BOOKS_CACHE[author] = {
            "data": books,
            "_timestamp": time.time(),
        }

        return books
    
    def get_book_id(self, slug, isbn=None):
        if isbn and len(isbn) == 13:
            query = """
            query ($slug: String!, $isbn: String!) {
                books(where: {slug: {_eq: $slug}}) {
                    id
                    editions(where: {isbn_13: {_eq: $isbn}}) {
                        id
                    }
                }
            }"""
            variables = {
                "slug": slug,
                "isbn": isbn
            }
        else:
            query = """
            query ($slug: String!) {
                books(where: {slug: {_eq: $slug}}) {
                    id
                }
            }"""
            variables = {
                "slug": slug
            }
        response = self.execute(query, variables)
        books = response.get("books", [])
        if not books:
            raise ValueError(f"Book with slug '{slug}' not found.")
        book = books[0]
        book_id = book.get("id")
        editions_list = book.get("editions", [])
        edition_id = editions_list[0]["id"] if editions_list else None
        return book_id, edition_id
    
    def execute(self, query, variables=None):
        payload = {
            "query": query,
            "variables": variables or {}
        }
        response = requests.post(self.endpoint, json=payload, headers=self.headers)
        try:
            response.raise_for_status()
        except requests.exceptions.HTTPError as e:
            raise Exception(f"HTTP error occurred: {e}")
        result = response.json()
        if "errors" in result:
            raise Exception(f"GraphQL error: {result['errors']}")
        return result.get("data", {})
    
    def get_existing_slugs(self, entries):
        slugs = []
        for entry in entries:
            book = entry.Books if hasattr(entry, "Books") else entry
            for identifier in getattr(book, "identifiers", []):
                if identifier.type == "hardcover":
                    slugs.append(identifier.val)
        return slugs
