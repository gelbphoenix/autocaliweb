/* This file is part of the Calibre-Web (https://github.com/janeczku/calibre-web)
 *    Copyright (C) 2018-2023 jkrehm, OzzieIsaacs
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

/* global _ */

function handleResponse (data) {
    $(".row-fluid.text-center").remove();
    $("#flash_danger").remove();
    $("#flash_success").remove();
    if (!jQuery.isEmptyObject(data)) {
        if($("#bookDetailsModal").is(":visible")) {
            data.forEach(function (item) {
                $(".modal-header").after('<div id="flash_' + item.type +
                    '" class="text-center alert alert-' + item.type + '">' + item.message + '</div>');
            });
        } else {
            data.forEach(function (item) {
                $(".navbar").after('<div class="row-fluid text-center">' +
                    '<div id="flash_' + item.type + '" class="alert alert-' + item.type + '">' + item.message + '</div>' +
                    '</div>');
            });
        }
    }
}
$(".sendbtn-form").click(function() {
    $.ajax({
        method: 'post',
        url: $(this).data('href'),
        data: {csrf_token: $("input[name='csrf_token']").val()},
        success: function (data) {
            handleResponse(data)
        }
    })
});

$(function() {
    $("#have_read_form").ajaxForm();
});

$("#have_read_cb").on("change", function() {
    $.ajax({
        url: this.closest("form").action,
        method:"post",
        data: $(this).closest("form").serialize(),
        error: function(response) {
            var data = [{type:"danger", message:response.responseText}]
            // $("#flash_success").parent().remove();
            $("#flash_danger").remove();
            $(".row-fluid.text-center").remove();
            if (!jQuery.isEmptyObject(data)) {
                $("#have_read_cb").prop("checked", !$("#have_read_cb").prop("checked"));
                if($("#bookDetailsModal").is(":visible")) {
                    data.forEach(function (item) {
                        $(".modal-header").after('<div id="flash_' + item.type +
                            '" class="text-center alert alert-' + item.type + '">' + item.message + '</div>');
                    });
                } else
                {
                    data.forEach(function (item) {
                        $(".navbar").after('<div class="row-fluid text-center" >' +
                            '<div id="flash_' + item.type + '" class="alert alert-' + item.type + '">' + item.message + '</div>' +
                            '</div>');
                    });
                }
            }
        }
    });
});

$(function() {
    $("#archived_form").ajaxForm();
});

$("#archived_cb").on("change", function() {
    $(this).closest("form").submit();
});

(function() {
    var templates = {
        add: _.template(
            $("#template-shelf-add").html()
        ),
        remove: _.template(
            $("#template-shelf-remove").html()
        )
    };

    function parseShelfAndBookFromUrl(url) {
        if (!url) return null;
        var match = String(url).match(/\/shelf\/(?:add|remove)\/(\d+)\/(\d+)/);
        if (!match) return null;
        return {
            shelfId: parseInt(match[1], 10),
            bookId: parseInt(match[2], 10)
        };
    }

    function updateShelfEmptyPlaceholder($container) {
        if (!$container || !$container.length) return;

        var $grid = $container.find('.row.display-flex').first();
        var $placeholder = $('#shelf-empty-placeholder');
        if (!$placeholder.length) return;

        var $entryControls = $container.find('#shelf_down, #order_shelf, #toggle_order_shelf, .filterheader');
        var remaining = $grid.find('.book').length;
        if (remaining === 0) {
            $placeholder.removeClass('hidden');
            $entryControls.addClass('hidden');
        } else {
            $placeholder.addClass('hidden');
            $entryControls.removeClass('hidden');
        }
    }

    function initShelfEmptyObserver($container) {
        if (!$container || !$container.length) return;
        if (typeof MutationObserver === 'undefined') return;

        var gridEl = $container.find('.row.display-flex').first().get(0);
        if (!gridEl) return;

        var pending = null;
        var observer = new MutationObserver(function() {
            if (pending) {
                clearTimeout(pending);
            }
            pending = setTimeout(function() {
                pending = null;
                updateShelfEmptyPlaceholder($container);
            }, 50);
        });

        observer.observe(gridEl, { childList: true });
    }

    function removeBookFromCurrentShelfPage(shelfId, bookId) {
        var $container = $('.discover[data-current-shelf-id]');
        if (!$container.length) return;

        var currentShelfId = parseInt($container.data('current-shelf-id'), 10);
        if (!currentShelfId || currentShelfId !== shelfId) return;

        var $grid = $container.find('.row.display-flex').first();
        var $book = $grid.find(".book[data-book-id='" + bookId + "']").first();
        if (!$book.length) return;

        if ($grid.length && typeof $grid.isotope === 'function' && $grid.data('isotope')) {
            var didUpdate = false;
            var doUpdate = function() {
                if (didUpdate) return;
                didUpdate = true;
                updateShelfEmptyPlaceholder($container);
            };

            $grid.one('layoutComplete', doUpdate);
            $grid.one('arrangeComplete', doUpdate);
            $grid.isotope('remove', $book).isotope('layout');
            setTimeout(doUpdate, 300);
        } else {
            $book.remove();
            updateShelfEmptyPlaceholder($container);
        }
    }

    $(function() {
        var $container = $('.discover[data-current-shelf-id]');
        if ($container.length) {
            updateShelfEmptyPlaceholder($container);
            initShelfEmptyObserver($container);
        }
    });

    $("#add-to-shelves, #remove-from-shelves").on("click", "[data-shelf-action]", function (e) {
        e.preventDefault();
        $.ajax({
                url: $(this).data('href'),
                method:"post",
                data: {csrf_token:$("input[name='csrf_token']").val()},
            })
            .done(function() {
                var $this = $(this);
                switch ($this.data("shelf-action")) {
                    case "add":
                        $("#remove-from-shelves").append(
                            templates.remove({
                                add: $this.data('href'),
                                remove: $this.data("remove-href"),
                                content: $("<div>").text(this.textContent).html()
                            })
                        );
                        break;
                    case "remove":
                        var parsed = parseShelfAndBookFromUrl($this.data('href'));
                        $("#add-to-shelves").append(
                            templates.add({
                                add: $this.data("add-href"),
                                remove: $this.data('href'),
                                content: $("<div>").text(this.textContent).html(),
                            })
                        );
                        if (parsed) {
                            removeBookFromCurrentShelfPage(parsed.shelfId, parsed.bookId);
                        }
                        break;
                }
                this.parentNode.removeChild(this);

                if (window.refreshShelfCountPills) {
                    window.refreshShelfCountPills();
                }
            }.bind(this))
            .fail(function(xhr) {
                var $msg = $("<span/>", { "class": "text-danger"}).text(xhr.responseText);
                $("#shelf-action-errors").html($msg);

                setTimeout(function() {
                    $msg.remove();
                }, 10000);
            });
    });
})();
