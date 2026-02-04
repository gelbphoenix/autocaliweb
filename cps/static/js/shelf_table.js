/* This file is part of the Calibre-Web (https://github.com/janeczku/calibre-web)
 *    Copyright (C) 2024
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

/* global getPath */

var shelfSelections = [];
var shelfTableI18n = null;

function getShelfTableI18n() {
    var el = document.getElementById("shelf-table-i18n");
    return el && el.dataset ? el.dataset : {};
}

function stI18n(key, fallback) {
    if (shelfTableI18n === null) {
        shelfTableI18n = getShelfTableI18n();
    }
    if (shelfTableI18n && shelfTableI18n[key]) {
        return shelfTableI18n[key];
    }
    return fallback;
}

function stFormatNamed(template, values) {
    if (!template) return "";
    var result = String(template).replace(
        /%\(([^)]+)\)s/g,
        function (match, key) {
            if (!values || values[key] === undefined || values[key] === null) {
                return match;
            }
            return String(values[key]);
        },
    );
    return result;
}

function updateShelfSelectionStatus() {
    var $el = $("#shelf-selection-status");
    if (!$el.length) return;
    if (shelfSelections.length) {
        var template = stI18n("selectionCount", "__COUNT__ selected");
        $el.text(template.replace("__COUNT__", shelfSelections.length));
    } else {
        $el.text("");
    }
}

function setShelfBulkButtonsEnabled(enabled) {
    [
        "#enable_kobo_sync",
        "#disable_kobo_sync",
        "#delete_selected_shelves",
    ].forEach(function (selector) {
        var $btn = $(selector);
        if (!$btn.length) return;
        $btn.toggleClass("disabled", !enabled);
        $btn.attr("aria-disabled", !enabled);
    });
}

function showShelfActionStatus(message, type) {
    var $status = $("#shelf-action-status");
    if (!$status.length) return;

    var $text = $status.find(".shelf-status-text");
    $status
        .removeClass("alert-success alert-danger alert-warning alert-info")
        .addClass(
            type === "success"
                ? "alert-success"
                : type === "error"
                  ? "alert-danger"
                  : "alert-info",
        );
    $text.text(message);
    $status.show();
}

function hideShelfActionStatus() {
    $("#shelf-action-status").hide();
}

// Formatters
function shelfNameFormatter(value, row) {
    var url;
    if (row.is_generated) {
        // Generated shelves use a different URL pattern
        url =
            getPath() +
            "/shelf/generated/" +
            encodeURIComponent(row.source) +
            "/" +
            encodeURIComponent(row.value);
    } else {
        url = getPath() + "/shelf/" + row.id;
    }
    var html =
        '<a href="' + url + '">' + $("<div>").text(value).html() + "</a>";
    if (row.is_public) {
        html +=
            ' <span class="label label-info">' +
            stI18n("public", "Public") +
            "</span>";
    }
    return html;
}

function shelfTypeFormatter(value, row) {
    if (row.is_generated) {
        return (
            '<span class="label label-default">' +
            stI18n("typeGenerated", "Generated") +
            "</span>"
        );
    } else {
        return (
            '<span class="label label-primary">' +
            stI18n("typeManual", "Manual") +
            "</span>"
        );
    }
}

function publicFormatter(value) {
    return value
        ? '<span class="glyphicon glyphicon-ok text-success"></span>'
        : "";
}

function koboSyncFormatter(value, row) {
    if (!row.can_edit) {
        return value
            ? '<span class="glyphicon glyphicon-ok text-success"></span>'
            : "";
    }
    var checked = value ? "checked" : "";
    return (
        '<input type="checkbox" class="kobo-sync-toggle" data-shelf-id="' +
        row.id +
        '" ' +
        checked +
        ' title="Toggle Kobo sync">'
    );
}

function dateFormatter(value) {
    if (!value) return "";
    try {
        var date = new Date(value);
        return date.toLocaleDateString();
    } catch (e) {
        return value;
    }
}

function shelfActionsFormatter(value, row) {
    if (!row.can_edit || row.is_generated) {
        // Generated shelves don't have an edit page - sync is toggled inline
        return "";
    }
    var editUrl = getPath() + "/shelf/edit/" + row.id;
    return (
        '<a href="' +
        editUrl +
        '" class="btn btn-xs btn-default" title="Edit">' +
        '<span class="glyphicon glyphicon-pencil"></span></a>'
    );
}

$(document).ready(function () {
    var $table = $("#shelves-table");
    if (!$table.length) return;

    // Initialize bootstrap-table
    $table.bootstrapTable({
        responseHandler: function (res) {
            return res;
        },
        onCheck: function (row) {
            shelfSelections.push(row.id);
            updateShelfSelectionStatus();
            setShelfBulkButtonsEnabled(shelfSelections.length > 0);
        },
        onUncheck: function (row) {
            var idx = shelfSelections.indexOf(row.id);
            if (idx !== -1) {
                shelfSelections.splice(idx, 1);
            }
            updateShelfSelectionStatus();
            setShelfBulkButtonsEnabled(shelfSelections.length > 0);
        },
        onCheckAll: function (rows) {
            shelfSelections = $.map(rows, function (row) {
                return row.id;
            });
            updateShelfSelectionStatus();
            setShelfBulkButtonsEnabled(shelfSelections.length > 0);
        },
        onUncheckAll: function () {
            shelfSelections = [];
            updateShelfSelectionStatus();
            setShelfBulkButtonsEnabled(false);
        },
    });

    // Handle inline Kobo sync toggle
    $table.on("change", ".kobo-sync-toggle", function () {
        var $cb = $(this);
        var shelfId = $cb.data("shelf-id");
        var enable = $cb.is(":checked");

        $.ajax({
            url: getPath() + "/shelf/bulk_kobo_sync",
            type: "POST",
            contentType: "application/json",
            data: JSON.stringify({ shelf_ids: [shelfId], enable: enable }),
            success: function (data) {
                if (data.success) {
                    showShelfActionStatus(data.msg, "success");
                } else {
                    showShelfActionStatus(
                        data.msg || stI18n("error", "Error"),
                        "error",
                    );
                    $cb.prop("checked", !enable); // Revert
                }
            },
            error: function () {
                showShelfActionStatus(stI18n("error", "Error"), "error");
                $cb.prop("checked", !enable); // Revert
            },
        });
    });

    // Enable Kobo Sync bulk button
    $("#enable_kobo_sync").on("click", function () {
        if ($(this).hasClass("disabled")) return;
        bulkKoboSync(true);
    });

    // Disable Kobo Sync bulk button
    $("#disable_kobo_sync").on("click", function () {
        if ($(this).hasClass("disabled")) return;
        bulkKoboSync(false);
    });

    function bulkKoboSync(enable) {
        if (!shelfSelections.length) return;

        $.ajax({
            url: getPath() + "/shelf/bulk_kobo_sync",
            type: "POST",
            contentType: "application/json",
            data: JSON.stringify({
                shelf_ids: shelfSelections,
                enable: enable,
            }),
            success: function (data) {
                if (data.success) {
                    showShelfActionStatus(data.msg, "success");
                    $table.bootstrapTable("refresh");
                    shelfSelections = [];
                    updateShelfSelectionStatus();
                    setShelfBulkButtonsEnabled(false);
                } else {
                    showShelfActionStatus(
                        data.msg || stI18n("error", "Error"),
                        "error",
                    );
                }
            },
            error: function () {
                showShelfActionStatus(stI18n("error", "Error"), "error");
            },
        });
    }

    // Delete selected shelves button
    $("#delete_selected_shelves").on("click", function () {
        if ($(this).hasClass("disabled")) return;

        // Get shelf names for confirmation
        var allRows = $table.bootstrapTable("getData");
        var selectedNames = [];
        for (var i = 0; i < allRows.length; i++) {
            if (shelfSelections.indexOf(allRows[i].id) !== -1) {
                selectedNames.push(allRows[i].name);
            }
        }

        $("#display-delete-shelves").html(
            "<ul><li>" + selectedNames.join("</li><li>") + "</li></ul>",
        );
        $("#delete_shelves_modal").modal("show");
    });

    // Confirm delete
    $("#delete_shelves_confirm").on("click", function () {
        if (!shelfSelections.length) return;

        $.ajax({
            url: getPath() + "/shelf/bulk_delete",
            type: "POST",
            contentType: "application/json",
            data: JSON.stringify({ shelf_ids: shelfSelections }),
            success: function (data) {
                if (data.success) {
                    showShelfActionStatus(data.msg, "success");
                    $table.bootstrapTable("refresh");
                    shelfSelections = [];
                    updateShelfSelectionStatus();
                    setShelfBulkButtonsEnabled(false);
                } else {
                    showShelfActionStatus(
                        data.msg || stI18n("error", "Error"),
                        "error",
                    );
                }
            },
            error: function () {
                showShelfActionStatus(stI18n("error", "Error"), "error");
            },
        });
    });

    // Close status alert
    $("#shelf-action-status-close").on("click", function () {
        hideShelfActionStatus();
    });
});
