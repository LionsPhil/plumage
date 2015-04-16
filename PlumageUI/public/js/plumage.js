"use strict";
/* Copyright 2015 Philip Boulain <philip.boulain@smoothwall.net>
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License v3 or later.
 * See LICENSE.txt for details. */

/* TODO TypeScript */
/* TODO Break out page-specific to BE page-specific and dynload */

jQuery(document).ready(function() {
	jQuery('#add-configuration').click(function(ev) {
		ev.preventDefault();
		ev.stopPropagation();
		jQuery.post('/configurations/')
			.done(function(data, text_status, jqxhr) {
				document.location.assign(data);
			})
			.fail(function(jqxhr, text_status, error_thrown) {
				console.error(jqxhr, text_status, error_thrown);
			});
	});
});

/* TODO Various progressive enhancements:
 *  - Run listing
 *    - Format dates more pleasantly
 *    - Truncate over-long comments
 *  - Configuration editing
 *    - Extra parameter rows
 *    - Re-order (swap) parameter rows
 *    - Supporting file drag-and-drop, other modern UX
 *    - Supporting file multiple upload (buffer or AJAX save)
 *    - Adjust remote filename placeholder to match selected file (maybe)
 *    - File upload/remove without also saving form (maybe)
 */
