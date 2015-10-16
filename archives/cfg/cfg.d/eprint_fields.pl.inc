	#
	# Eprint fields for citation data. These must be included as elements in the
	# $c->{fields}->{eprint} array.
	#
	# $c->{fields}->{eprint} = [
	#

	{  'name'     => 'gscholar',
	   'type'     => 'compound',
	   'volatile' => 1,
	   'fields'   => [
			 { 'sub_name' => 'impact',    'type' => 'int', },
			 { 'sub_name' => 'cluster',   'type' => 'id', },
			 { 'sub_name' => 'datestamp', 'type' => 'time', 'render_style' => 'short', },
	   ],
	   'sql_index' => 0,
	},

	  { 'name'     => 'scopus',
	    'type'     => 'compound',
	    'volatile' => 1,
	    'fields'   => [
			  { 'sub_name' => 'impact',    'type' => 'int', },
			  { 'sub_name' => 'cluster',   'type' => 'id', },
			  { 'sub_name' => 'datestamp', 'type' => 'time', 'render_style' => 'short', },
	    ],
	    'sql_index' => 0,
	  },

	  { 'name'     => 'wos',
	    'type'     => 'compound',
	    'volatile' => 1,
	    'fields'   => [
			  { 'sub_name' => 'impact',    'type' => 'int', },
			  { 'sub_name' => 'cluster',   'type' => 'id', },
			  { 'sub_name' => 'datestamp', 'type' => 'time', 'render_style' => 'short', },
	    ],
	    'sql_index' => 0,
	  },

	  #];
