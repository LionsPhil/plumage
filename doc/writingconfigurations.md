Writing configurations
======================

Polygraph configurations handled by Plumage are Template::Toolkit templates which are processed down to standard PGL files. Therefore if you write a configuration for plain Polygraph, so long as you avoid Template::Toolkit syntax, it should work through Plumage as-is. However, it is far more useful to use template variables that runs can vary, and if you have multiple hardware setups, that hosts can vary.

Run parameters
--------------

TODO

Host parameters
---------------

TODO

Host parameters and run parameters cannot have the same names. If they do, Plumage will refuse to start the run to avoid confusing results. Therefore you should consider prefixing your host parameters with a suitable namespace, like "host\_".

Plumage metadata
----------------

Special comments within the PGL configuration will be detected by Plumage, of the format:

	//plumage//key//value

The comment must be at the very start of the line. The value proceeds to the end of the line.

Recognized keys are:

- **reportname**: defines the name of the generated Polygraph report. Plumage will insist this contains only alphanumerics, periods, colons, hyphens, and underscores since report generation is prone to shell metacharacter confusion. It does not have to be unique; the only affect it has is on the heading Polygraph gives the report pages. The value is parsed after template processing, so may be built from template parameters, e.g. '//plumage//reportname//Standard-load\_[% proxy\_ip %]'. Plumage will automatically append an ISO 8601 datestamp.
