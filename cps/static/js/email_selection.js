/**
 * Email Selection functionality for selective eReader sending
 * Handles both modal and redirect scenarios
 */

$(document).ready(function() {
    // Handle the Send to eReader button click
    $(document).on('click', '#sendToEReaderBtn', function(e) {
        e.preventDefault();
        e.stopPropagation();

        var bookId = $(this).data('book-id');

        // Check if we're in the floating modal context
        var isInFloatingModal = $('#bookDetailsModal').length > 0 &&
                               ($('#bookDetailsModal').hasClass('in') || $('#bookDetailsModal').is(':visible'));

        if (isInFloatingModal) {
            // Redirect to full page
            window.location.href = '/book/' + bookId;
        } else {
            // Show the email selection modal
            $('#emailSelectModal').modal('show');
        }
    });

    // Handle send button click in email selection modal
    $('#sendSelectedBtn').click(function() {
        var selectedEmails = [];
        $('input[name="selected_emails"]:checked').each(function() {
            selectedEmails.push($(this).val());
        });

        if (selectedEmails.length === 0) {
            alert($('#emailSelectModal').data('no-email-message') || 'Please select at least one email address');
            return;
        }

        var formatSelect = $('select[name="format_selection"]');
        var selectedFormat = formatSelect.val();
        var convertFlag = formatSelect.find(':selected').data('convert');
        var bookId = $('#emailSelectModal').data('book-id');

        // Send AJAX request to endpoint
        $.ajax({
            url: '/send_selected/' + bookId,
            method: 'POST',
            data: {
                'csrf_token': $('input[name="csrf_token"]').val(),
                'selected_emails': selectedEmails.join(','),
                'book_format': selectedFormat,
                'convert': convertFlag
            },
            success: function(response) {
                $('#emailSelectModal').modal('hide');
                if (response.length > 0 && response[0].type === 'success') {
                    alert(response[0].message);
                } else if (response.length > 0) {
                    alert(response[0].message);
                }
            },
            error: function() {
                alert($('#emailSelectModal').data('error-message') || 'Error sending email');
            }
        });
    });

    // Handle select all/none functionality
    $('#selectAllEmails').change(function() {
        $('input[name="selected_emails"]').prop('checked', this.checked);
    });

    // Update select all checkbox when individual checkboxes change
    $('input[name="selected_emails"]').change(function() {
        var totalCheckboxes = $('input[name="selected_emails"]').length;
        var checkedCheckboxes = $('input[name="selected_emails"]:checked').length;
        $('#selectAllEmails').prop('checked', totalCheckboxes === checkedCheckboxes);
    });
});